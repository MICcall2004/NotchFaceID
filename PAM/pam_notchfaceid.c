// PAM module for NotchFaceID (macOS sudo_local).
//
// Security design:
// - Never accesses the camera directly (avoids TCC/responsible-process issues under setuid root).
// - Connects over a Unix domain socket to the user's running NotchFaceID.app (AuthServer).
// - Verifies server identity via kernel LOCAL_PEERTOKEN + SecCodeCopyGuestWithAttributes:
//   * Mandatory root-owned pinned SecRequirement (/Library/Application Support/NotchFaceID/code_requirement)
//     binding both identifier and exact leaf certificate SHA-1 hash (`certificate leaf = H"..."`).
//   * Exact bundle path match (`/Applications/NotchFaceID.app`) with root:wheel non-writable ownership.
// - Requires explicit user consent click on the notch in NotchFaceID.app before scanning.
// - Uses a fresh 32-byte random hex nonce per request (constant-time verified on response).
// - Fails safe (returns PAM_IGNORE -> falls through to password) on SSH, locked screen,
//   closed clamshell, missing app, verification failure, timeout, or SIGINT.

#include <ApplicationServices/ApplicationServices.h>
#include <CoreFoundation/CoreFoundation.h>
#include <IOKit/IOKitLib.h>
#include <Security/Security.h>
#include <bsm/libbsm.h>
#include <ctype.h>
#include <errno.h>
#include <fcntl.h>
#include <os/log.h>
#include <poll.h>
#include <pwd.h>
#include <security/pam_appl.h>
#include <security/pam_modules.h>
#include <stdbool.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/socket.h>
#include <sys/stat.h>
#include <sys/ucred.h>
#include <sys/un.h>
#include <time.h>
#include <unistd.h>

#define DEFAULT_TIMEOUT_SEC 10
#define MIN_TIMEOUT_SEC 3
#define MAX_TIMEOUT_SEC 20
#define CONNECT_TIMEOUT_MS 500
#define MAX_MSG_BYTES 1024
#define NONCE_BYTES 32
#define NONCE_HEX_LEN (NONCE_BYTES * 2)
#define APP_BUNDLE_PATH "/Applications/NotchFaceID.app"
#define APP_EXEC_PATH "/Applications/NotchFaceID.app/Contents/MacOS/NotchFaceID"
#define REQUIREMENT_PATH "/Library/Application Support/NotchFaceID/code_requirement"

static os_log_t pam_logger(void) {
    static os_log_t logger = NULL;
    if (!logger) {
        logger = os_log_create("local.notchfaceid.pam", "auth");
    }
    return logger;
}

// Fail-safe guard 1: Skip remote / SSH sessions.
static bool is_remote_session(pam_handle_t *pamh) {
    if (getenv("SSH_CONNECTION") || getenv("SSH_TTY") || getenv("SSH_CLIENT")) {
        return true;
    }
    const void *rhost = NULL;
    if (pamh && pam_get_item(pamh, PAM_RHOST, &rhost) == PAM_SUCCESS && rhost != NULL) {
        const char *s = (const char *)rhost;
        if (s[0] != '\0') return true;
    }
    return false;
}

// Fail-safe guard 2: Skip when MacBook lid / clamshell is closed.
static bool is_clamshell_closed(void) {
    io_service_t root_domain = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("IOPMrootDomain"));
    if (root_domain == IO_OBJECT_NULL) return false;

    CFTypeRef prop = IORegistryEntryCreateCFProperty(root_domain, CFSTR("AppleClamshellState"), kCFAllocatorDefault, 0);
    IOObjectRelease(root_domain);
    if (!prop) return false;

    bool closed = (CFGetTypeID(prop) == CFBooleanGetTypeID()) && CFBooleanGetValue((CFBooleanRef)prop);
    CFRelease(prop);
    return closed;
}

// Fail-safe guard 3: Skip when GUI console session is locked or not on console.
static bool is_screen_locked_or_off_console(void) {
    CFDictionaryRef dict = CGSessionCopyCurrentDictionary();
    if (!dict) {
        // Under setuid root in some contexts CGSessionCopyCurrentDictionary may return NULL.
        // Do not block purely on NULL if we can still talk to the verified user session app,
        // unless explicitly locked.
        return false;
    }
    bool blocked = false;
    CFBooleanRef locked = (CFBooleanRef)CFDictionaryGetValue(dict, CFSTR("CGSSessionScreenIsLocked"));
    if (locked && CFGetTypeID(locked) == CFBooleanGetTypeID() && CFBooleanGetValue(locked)) {
        blocked = true;
    }
    CFBooleanRef on_console = (CFBooleanRef)CFDictionaryGetValue(dict, kCGSessionOnConsoleKey);
    if (on_console && CFGetTypeID(on_console) == CFBooleanGetTypeID() && !CFBooleanGetValue(on_console)) {
        blocked = true;
    }
    CFRelease(dict);
    return blocked;
}

static bool is_root_protected_path(const char *path, bool expect_dir) {
    struct stat st;
    if (lstat(path, &st) != 0) return false;
    if (S_ISLNK(st.st_mode)) return false;
    if (expect_dir ? !S_ISDIR(st.st_mode) : !S_ISREG(st.st_mode)) return false;
    if (st.st_uid != 0) return false;
    if ((st.st_mode & 0022) != 0) return false;
    return true;
}

// Load optional root-owned designated requirement string (e.g. pinned signing cert).
static CFStringRef load_pinned_requirement(void) {
    if (!is_root_protected_path(REQUIREMENT_PATH, false)) {
        return NULL;
    }
    FILE *f = fopen(REQUIREMENT_PATH, "r");
    if (!f) return NULL;
    char buf[1024];
    size_t n = fread(buf, 1, sizeof(buf) - 1, f);
    fclose(f);
    if (n == 0) return NULL;
    buf[n] = '\0';
    while (n > 0 && (buf[n - 1] == '\n' || buf[n - 1] == '\r' || isspace((unsigned char)buf[n - 1]))) {
        buf[--n] = '\0';
    }
    if (n == 0) return NULL;
    return CFStringCreateWithCString(kCFAllocatorDefault, buf, kCFStringEncodingUTF8);
}

// Verify the listening peer process via LOCAL_PEERCRED + LOCAL_PEERTOKEN + Security.framework.
// Production-only: requires root-owned pinned code_requirement (cert hash) AND exact root-owned
// /Applications/NotchFaceID.app bundle path. No dev bypass is permitted in PAM.
static bool verify_peer_server(int fd, uid_t target_uid, bool debug) {
    struct xucred cred;
    socklen_t cred_len = sizeof(cred);
    if (getsockopt(fd, SOL_LOCAL, LOCAL_PEERCRED, &cred, &cred_len) != 0 || cred.cr_version != XUCRED_VERSION) {
        if (debug) os_log_error(pam_logger(), "verify_peer: LOCAL_PEERCRED failed errno=%d", errno);
        return false;
    }
    if (cred.cr_uid != target_uid && cred.cr_uid != 0) {
        os_log_error(pam_logger(), "verify_peer: unexpected peer uid=%u (expected %u)", cred.cr_uid, target_uid);
        return false;
    }

    audit_token_t token;
    socklen_t token_len = sizeof(token);
    if (getsockopt(fd, SOL_LOCAL, LOCAL_PEERTOKEN, &token, &token_len) != 0 || token_len != sizeof(token)) {
        os_log_error(pam_logger(), "verify_peer: LOCAL_PEERTOKEN failed errno=%d", errno);
        return false;
    }

    CFStringRef req_str = load_pinned_requirement();
    if (!req_str) {
        os_log_error(pam_logger(), "verify_peer: missing or unprotected root code_requirement at %{public}s", REQUIREMENT_PATH);
        return false;
    }

    CFDataRef token_data = CFDataCreate(kCFAllocatorDefault, (const UInt8 *)&token, sizeof(token));
    if (!token_data) {
        CFRelease(req_str);
        return false;
    }

    const void *keys[] = { kSecGuestAttributeAudit };
    const void *vals[] = { token_data };
    CFDictionaryRef attrs = CFDictionaryCreate(
        kCFAllocatorDefault, keys, vals, 1,
        &kCFTypeDictionaryKeyCallBacks, &kCFTypeDictionaryValueCallBacks
    );
    CFRelease(token_data);
    if (!attrs) {
        CFRelease(req_str);
        return false;
    }

    SecCodeRef guest = NULL;
    OSStatus status = SecCodeCopyGuestWithAttributes(NULL, attrs, kSecCSDefaultFlags, &guest);
    CFRelease(attrs);
    if (status != errSecSuccess || !guest) {
        os_log_error(pam_logger(), "verify_peer: SecCodeCopyGuestWithAttributes failed (%d)", (int)status);
        CFRelease(req_str);
        return false;
    }

    SecRequirementRef req = NULL;
    status = SecRequirementCreateWithString(req_str, kSecCSDefaultFlags, &req);
    CFRelease(req_str);
    if (status != errSecSuccess || !req) {
        os_log_error(pam_logger(), "verify_peer: SecRequirementCreateWithString failed (%d)", (int)status);
        CFRelease(guest);
        return false;
    }

    status = SecCodeCheckValidity(guest, kSecCSDefaultFlags, req);
    CFRelease(req);
    if (status != errSecSuccess) {
        os_log_error(pam_logger(), "verify_peer: code signature validity failed (%d)", (int)status);
        CFRelease(guest);
        return false;
    }

    bool ok = true;
    SecStaticCodeRef static_code = NULL;
    CFURLRef path_url = NULL;
    char exec_path[PATH_MAX];
    if (SecCodeCopyStaticCode(guest, kSecCSDefaultFlags, &static_code) != errSecSuccess || !static_code ||
        SecCodeCopyPath(static_code, kSecCSDefaultFlags, &path_url) != errSecSuccess || !path_url ||
        !CFURLGetFileSystemRepresentation(path_url, true, (UInt8 *)exec_path, sizeof(exec_path))) {
        os_log_error(pam_logger(), "verify_peer: failed to inspect peer bundle path");
        ok = false;
    } else if (strcmp(exec_path, APP_BUNDLE_PATH) != 0 ||
               !is_root_protected_path(APP_BUNDLE_PATH, true) ||
               !is_root_protected_path(APP_EXEC_PATH, false)) {
        os_log_error(pam_logger(), "verify_peer: peer not root-owned /Applications/NotchFaceID.app (path=%{public}s)", exec_path);
        ok = false;
    }
    if (path_url) CFRelease(path_url);
    if (static_code) CFRelease(static_code);

    CFRelease(guest);
    return ok;
}

static void generate_nonce_hex(char out[NONCE_HEX_LEN + 1]) {
    static const char hex[] = "0123456789abcdef";
    uint8_t raw[NONCE_BYTES];
    arc4random_buf(raw, sizeof(raw));
    for (size_t i = 0; i < NONCE_BYTES; i++) {
        out[i * 2] = hex[(raw[i] >> 4) & 0x0f];
        out[i * 2 + 1] = hex[raw[i] & 0x0f];
    }
    out[NONCE_HEX_LEN] = '\0';
}

// Sanitize a string for safe JSON embedding (ASCII printable, no quotes/backslashes/control chars).
static void sanitize_json_field(const char *src, char *dst, size_t dst_size) {
    if (!dst || dst_size == 0) return;
    if (!src) {
        dst[0] = '\0';
        return;
    }
    size_t j = 0;
    for (size_t i = 0; src[i] != '\0' && j + 1 < dst_size; i++) {
        unsigned char c = (unsigned char)src[i];
        if (c >= 0x20 && c < 0x7f && c != '"' && c != '\\') {
            dst[j++] = (char)c;
        }
    }
    dst[j] = '\0';
}

// Connect non-blocking with short timeout so a wedged server never blocks sudo.
static int connect_auth_socket(const char *dir_path, const char *sock_path, uid_t target_uid, bool debug) {
    struct stat st;
    if (lstat(dir_path, &st) != 0 || !S_ISDIR(st.st_mode) || st.st_uid != target_uid || (st.st_mode & 0077) != 0) {
        if (debug) os_log_info(pam_logger(), "connect: socket dir missing or bad perms: %{public}s", dir_path);
        return -1;
    }
    if (lstat(sock_path, &st) != 0 || !S_ISSOCK(st.st_mode) || st.st_uid != target_uid) {
        if (debug) os_log_info(pam_logger(), "connect: socket missing or bad owner: %{public}s", sock_path);
        return -1;
    }

    int fd = socket(AF_UNIX, SOCK_STREAM, 0);
    if (fd < 0) return -1;

    int no_sigpipe = 1;
    setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &no_sigpipe, sizeof(no_sigpipe));

    int flags = fcntl(fd, F_GETFL, 0);
    if (flags < 0 || fcntl(fd, F_SETFL, flags | O_NONBLOCK) < 0) {
        close(fd);
        return -1;
    }

    struct sockaddr_un addr;
    memset(&addr, 0, sizeof(addr));
    addr.sun_family = AF_UNIX;
    if (strlen(sock_path) >= sizeof(addr.sun_path)) {
        close(fd);
        return -1;
    }
    strlcpy(addr.sun_path, sock_path, sizeof(addr.sun_path));

    int rc = connect(fd, (struct sockaddr *)&addr, sizeof(addr));
    if (rc < 0) {
        if (errno != EINPROGRESS) {
            if (debug) os_log_info(pam_logger(), "connect: failed errno=%d", errno);
            close(fd);
            return -1;
        }
        struct pollfd pfd = { .fd = fd, .events = POLLOUT, .revents = 0 };
        int prc = poll(&pfd, 1, CONNECT_TIMEOUT_MS);
        if (prc <= 0) {
            close(fd);
            return -1;
        }
        int so_err = 0;
        socklen_t err_len = sizeof(so_err);
        if (getsockopt(fd, SOL_SOCKET, SO_ERROR, &so_err, &err_len) != 0 || so_err != 0) {
            close(fd);
            return -1;
        }
    }
    return fd;
}

static bool write_all_timeout(int fd, const char *buf, size_t len, int timeout_ms) {
    size_t sent = 0;
    while (sent < len) {
        struct pollfd pfd = { .fd = fd, .events = POLLOUT, .revents = 0 };
        int prc = poll(&pfd, 1, timeout_ms);
        if (prc <= 0) return false;
        ssize_t n = send(fd, buf + sent, len - sent, MSG_NOSIGNAL);
        if (n <= 0) {
            if (n < 0 && (errno == EAGAIN || errno == EWOULDBLOCK)) continue;
            return false;
        }
        sent += (size_t)n;
    }
    return true;
}

static bool read_line_timeout(int fd, char *buf, size_t cap, int timeout_ms) {
    size_t pos = 0;
    struct timespec start;
    clock_gettime(CLOCK_MONOTONIC, &start);

    while (pos + 1 < cap) {
        struct timespec now;
        clock_gettime(CLOCK_MONOTONIC, &now);
        long elapsed_ms = (now.tv_sec - start.tv_sec) * 1000L + (now.tv_nsec - start.tv_nsec) / 1000000L;
        int remaining = timeout_ms - (int)elapsed_ms;
        if (remaining <= 0) return false;

        struct pollfd pfd = { .fd = fd, .events = POLLIN, .revents = 0 };
        int prc = poll(&pfd, 1, remaining);
        if (prc <= 0) {
            // Includes EINTR (e.g. Ctrl+C) and timeout -> abort cleanly.
            return false;
        }
        ssize_t n = recv(fd, buf + pos, cap - 1 - pos, 0);
        if (n <= 0) {
            if (n < 0 && (errno == EAGAIN || errno == EWOULDBLOCK)) continue;
            break;
        }
        pos += (size_t)n;
        buf[pos] = '\0';
        char *nl = strchr(buf, '\n');
        if (nl) {
            *nl = '\0';
            return true;
        }
    }
    return false;
}

// Extract a simple JSON string value for key `"key":"value"` (no escaped quotes expected).
static bool extract_json_string(const char *json, const char *key, char *out, size_t out_size) {
    char pattern[64];
    snprintf(pattern, sizeof(pattern), "\"%s\"", key);
    const char *p = strstr(json, pattern);
    if (!p) return false;
    p += strlen(pattern);
    while (*p && isspace((unsigned char)*p)) p++;
    if (*p != ':') return false;
    p++;
    while (*p && isspace((unsigned char)*p)) p++;
    if (*p != '"') return false;
    p++;
    size_t i = 0;
    while (*p && *p != '"' && i + 1 < out_size) {
        if (*p == '\\') return false;  // unexpected escape
        out[i++] = *p++;
    }
    if (*p != '"') return false;
    out[i] = '\0';
    return true;
}

// Extract integer field `"v":1`.
static bool extract_json_int(const char *json, const char *key, int *out) {
    char pattern[64];
    snprintf(pattern, sizeof(pattern), "\"%s\"", key);
    const char *p = strstr(json, pattern);
    if (!p) return false;
    p += strlen(pattern);
    while (*p && isspace((unsigned char)*p)) p++;
    if (*p != ':') return false;
    p++;
    while (*p && isspace((unsigned char)*p)) p++;
    if (!isdigit((unsigned char)*p)) return false;
    *out = (int)strtol(p, NULL, 10);
    return true;
}

PAM_EXTERN int pam_sm_authenticate(pam_handle_t *pamh, int flags, int argc, const char **argv) {
    (void)flags;

    int timeout_sec = DEFAULT_TIMEOUT_SEC;
    bool debug = false;

    for (int i = 0; i < argc; i++) {
        if (strncmp(argv[i], "timeout=", 8) == 0) {
            int parsed = (int)strtol(argv[i] + 8, NULL, 10);
            if (parsed >= MIN_TIMEOUT_SEC && parsed <= MAX_TIMEOUT_SEC) {
                timeout_sec = parsed;
            }
        } else if (strcmp(argv[i], "debug") == 0) {
            debug = true;
        }
    }

    if (is_remote_session(pamh)) {
        if (debug) os_log_info(pam_logger(), "skipping: remote/SSH session");
        return PAM_IGNORE;
    }
    if (is_clamshell_closed()) {
        if (debug) os_log_info(pam_logger(), "skipping: clamshell closed");
        return PAM_IGNORE;
    }
    if (is_screen_locked_or_off_console()) {
        if (debug) os_log_info(pam_logger(), "skipping: screen locked or off console");
        return PAM_IGNORE;
    }

    if (!pamh) return PAM_IGNORE;

    const char *user = NULL;
    if (pam_get_user(pamh, &user, NULL) != PAM_SUCCESS || !user || user[0] == '\0') {
        return PAM_IGNORE;
    }

    struct passwd pwd;
    struct passwd *pw_result = NULL;
    char pw_buf[4096];
    if (getpwnam_r(user, &pwd, pw_buf, sizeof(pw_buf), &pw_result) != 0 || !pw_result || !pwd.pw_dir) {
        return PAM_IGNORE;
    }

    char dir_path[PATH_MAX];
    char sock_path[PATH_MAX];
    int dn = snprintf(dir_path, sizeof(dir_path), "%s/Library/Caches/local.notchfaceid", pwd.pw_dir);
    int sn = snprintf(sock_path, sizeof(sock_path), "%s/auth.sock", dir_path);
    if (dn <= 0 || (size_t)dn >= sizeof(dir_path) || sn <= 0 || (size_t)sn >= sizeof(sock_path)) {
        return PAM_IGNORE;
    }

    int fd = connect_auth_socket(dir_path, sock_path, pwd.pw_uid, debug);
    if (fd < 0) {
        return PAM_IGNORE;
    }

    if (!verify_peer_server(fd, pwd.pw_uid, debug)) {
        close(fd);
        return PAM_IGNORE;
    }

    const void *tty_item = NULL;
    const char *raw_tty = "";
    if (pam_get_item(pamh, PAM_TTY, &tty_item) == PAM_SUCCESS && tty_item) {
        raw_tty = (const char *)tty_item;
        if (strncmp(raw_tty, "/dev/", 5) == 0) raw_tty += 5;
    }

    const void *svc_item = NULL;
    const char *raw_svc = "sudo";
    if (pam_get_item(pamh, PAM_SERVICE, &svc_item) == PAM_SUCCESS && svc_item) {
        raw_svc = (const char *)svc_item;
    }

    char safe_user[64], safe_tty[64], safe_svc[64];
    sanitize_json_field(user, safe_user, sizeof(safe_user));
    sanitize_json_field(raw_tty, safe_tty, sizeof(safe_tty));
    sanitize_json_field(raw_svc, safe_svc, sizeof(safe_svc));

    char nonce[NONCE_HEX_LEN + 1];
    generate_nonce_hex(nonce);

    char req_buf[MAX_MSG_BYTES];
    int rn = snprintf(
        req_buf, sizeof(req_buf),
        "{\"v\":1,\"nonce\":\"%s\",\"user\":\"%s\",\"tty\":\"%s\",\"service\":\"%s\",\"pid\":%d,\"timeout\":%d}\n",
        nonce, safe_user, safe_tty, safe_svc, (int)getpid(), timeout_sec
    );
    if (rn <= 0 || (size_t)rn >= sizeof(req_buf)) {
        close(fd);
        return PAM_IGNORE;
    }

    if (!write_all_timeout(fd, req_buf, (size_t)rn, 1000)) {
        close(fd);
        return PAM_IGNORE;
    }

    char resp_buf[MAX_MSG_BYTES];
    if (!read_line_timeout(fd, resp_buf, sizeof(resp_buf), (timeout_sec + 3) * 1000)) {
        if (debug) os_log_info(pam_logger(), "auth timed out or interrupted");
        close(fd);
        return PAM_IGNORE;
    }
    close(fd);

    int version = 0;
    char resp_nonce[NONCE_HEX_LEN + 1];
    char result[32];
    if (!extract_json_int(resp_buf, "v", &version) || version != 1 ||
        !extract_json_string(resp_buf, "nonce", resp_nonce, sizeof(resp_nonce)) ||
        !extract_json_string(resp_buf, "result", result, sizeof(result))) {
        os_log_error(pam_logger(), "malformed auth response from server");
        return PAM_IGNORE;
    }

    if (strlen(resp_nonce) != NONCE_HEX_LEN || timingsafe_bcmp(resp_nonce, nonce, NONCE_HEX_LEN) != 0) {
        os_log_error(pam_logger(), "nonce mismatch in auth response");
        return PAM_IGNORE;
    }

    if (strcmp(result, "success") == 0) {
        os_log_info(pam_logger(), "NotchFaceID auth succeeded for user=%{public}s svc=%{public}s", safe_user, safe_svc);
        return PAM_SUCCESS;
    }

    if (debug) os_log_info(pam_logger(), "NotchFaceID auth did not succeed (result=%{public}s); falling back", result);
    return PAM_IGNORE;
}

PAM_EXTERN int pam_sm_setcred(pam_handle_t *pamh, int flags, int argc, const char **argv) {
    (void)pamh;
    (void)flags;
    (void)argc;
    (void)argv;
    return PAM_IGNORE;
}
