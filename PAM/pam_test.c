// Minimal PoC PAM module for macOS sudo_local verification.
// Logs invocation via unified logging (os_log) and unconditionally returns PAM_IGNORE
// so sudo always falls through to password authentication with zero lockout risk.

#include <os/log.h>
#include <security/pam_appl.h>
#include <security/pam_modules.h>

PAM_EXTERN int pam_sm_authenticate(pam_handle_t *pamh, int flags, int argc, const char **argv) {
    (void)flags;
    (void)argc;
    (void)argv;

    const char *user = NULL;
    if (!pamh || pam_get_user(pamh, &user, NULL) != PAM_SUCCESS || user == NULL) {
        user = "(unknown)";
    }

    os_log_t log = os_log_create("local.notchfaceid.pam", "poc");
    os_log_info(log, "pam_test: loaded and invoked for user=%{public}s; returning PAM_IGNORE", user);
    return PAM_IGNORE;
}

PAM_EXTERN int pam_sm_setcred(pam_handle_t *pamh, int flags, int argc, const char **argv) {
    (void)pamh;
    (void)flags;
    (void)argc;
    (void)argv;
    return PAM_IGNORE;
}
