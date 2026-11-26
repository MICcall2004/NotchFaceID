// Unix domain socket IPC server for PAM authentication requests + template storage security policy.
import Darwin
import Foundation

/// Shared template storage locations and integrity checks for Claude's TemplateStore and AuthServer.
enum TemplateStoragePolicy {
    /// System-wide root-owned directory (mode 0755 root:wheel) used when sudo PAM auth is enabled.
    /// Templates inside (mode 0640 root:staff) are readable by NotchFaceID.app but unmodifiable by user-level malware.
    static let systemDirectoryURL = URL(fileURLWithPath: "/Library/Application Support/NotchFaceID", isDirectory: true)
    static let systemTemplateURL = systemDirectoryURL.appendingPathComponent("faces")

    /// Development / user-local fallback path (matches TemplateStore in Matching.swift).
    static var userTemplateURL: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("NotchFaceID/faces")
    }

    /// Returns true iff `url` is a real (non-symlink) regular file owned by root (uid 0) and not
    /// writable by group or others (`mode & 0o022 == 0`), and every ancestor directory up to `/`
    /// is also a real root-owned non-group/world-writable directory.
    static func isTamperProtected(_ url: URL) -> Bool {
        let standardized = url.standardizedFileURL
        var fileStat = stat()
        guard lstat(standardized.path, &fileStat) == 0,
              (fileStat.st_mode & S_IFMT) == S_IFREG,
              fileStat.st_uid == 0,
              (fileStat.st_mode & 0o022) == 0 else {
            return false
        }

        var dir = standardized.deletingLastPathComponent()
        while true {
            var dirStat = stat()
            guard lstat(dir.path, &dirStat) == 0,
                  (dirStat.st_mode & S_IFMT) == S_IFDIR,
                  dirStat.st_uid == 0,
                  (dirStat.st_mode & 0o022) == 0 else {
                return false
            }
            let parent = dir.deletingLastPathComponent()
            if parent.path == dir.path { break }
            dir = parent
        }
        return true
    }
}

struct AuthRequest: Codable {
    let v: Int
    let nonce: String
    let user: String
    let tty: String
    let service: String
    let pid: Int32
    let timeout: Int
}

struct AuthResponse: Codable {
    let v: Int
    let nonce: String
    let result: AuthResult
}

final class AuthServer {
    typealias AuthHandler = (_ request: AuthRequest, _ reason: String, _ timeout: TimeInterval, _ completion: @escaping (AuthResult) -> Void) -> Void

    static var defaultSocketURL: URL {
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        return caches.appendingPathComponent("local.notchfaceid/auth.sock")
    }

    let socketURL: URL
    private let allowSameUserClient: Bool
    private let requireRootTemplates: Bool
    private let handler: AuthHandler
    private let queue = DispatchQueue(label: "local.notchfaceid.authserver", qos: .userInitiated)
    private var listenFD: Int32 = -1
    private var acceptSource: DispatchSourceRead?
    private var inFlight = false
    private(set) var isRunning = false

    init(
        socketURL: URL = AuthServer.defaultSocketURL,
        allowSameUserClient: Bool = false,
        requireRootTemplates: Bool = true,
        handler: @escaping AuthHandler
    ) {
        self.socketURL = socketURL
        self.allowSameUserClient = allowSameUserClient
        self.requireRootTemplates = requireRootTemplates
        self.handler = handler
    }

    deinit {
        stop()
    }

    @discardableResult
    func start() -> Bool {
        guard !isRunning else { return true }

        let dirURL = socketURL.deletingLastPathComponent()
        do {
            try FileManager.default.createDirectory(at: dirURL, withIntermediateDirectories: true)
            chmod(dirURL.path, 0o700)
        } catch {
            return false
        }

        // Reject symlinked directory or socket path to prevent local path hijacking.
        var st = stat()
        if lstat(dirURL.path, &st) != 0 || (st.st_mode & S_IFMT) != S_IFDIR || st.st_uid != getuid() {
            return false
        }

        unlink(socketURL.path)

        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return false }

        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let pathBytes = Array(socketURL.path.utf8CString)
        guard pathBytes.count <= MemoryLayout.size(ofValue: addr.sun_path) else {
            close(fd)
            return false
        }
        withUnsafeMutableBytes(of: &addr.sun_path) { raw in
            pathBytes.withUnsafeBytes { src in
                raw.copyMemory(from: src)
            }
        }

        let bindResult = withUnsafePointer(to: &addr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockPtr in
                bind(fd, sockPtr, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard bindResult == 0 else {
            close(fd)
            return false
        }

        // Mode 0600: only this user and root (sudo PAM) can connect.
        chmod(socketURL.path, 0o600)

        guard listen(fd, 8) == 0 else {
            close(fd)
            unlink(socketURL.path)
            return false
        }

        let flags = fcntl(fd, F_GETFL, 0)
        _ = fcntl(fd, F_SETFL, flags | O_NONBLOCK)

        let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
        source.setEventHandler { [weak self] in
            self?.acceptPendingConnections()
        }
        source.setCancelHandler {
            close(fd)
        }
        listenFD = fd
        acceptSource = source
        isRunning = true
        source.resume()
        return true
    }

    func stop() {
        guard isRunning else { return }
        isRunning = false
        acceptSource?.cancel()
        acceptSource = nil
        listenFD = -1
        unlink(socketURL.path)
    }

    private func acceptPendingConnections() {
        while true {
            var clientAddr = sockaddr_un()
            var addrLen = socklen_t(MemoryLayout<sockaddr_un>.size)
            let clientFD = withUnsafeMutablePointer(to: &clientAddr) { ptr in
                ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockPtr in
                    accept(listenFD, sockPtr, &addrLen)
                }
            }
            if clientFD < 0 {
                if errno == EAGAIN || errno == EWOULDBLOCK { break }
                break
            }
            handleClient(clientFD)
        }
    }

    private func handleClient(_ fd: Int32) {
        // Prevent SIGPIPE from killing the app if PAM cancels (Ctrl+C).
        var noSigPipe: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &noSigPipe, socklen_t(MemoryLayout<Int32>.size))

        // Verify peer UID via LOCAL_PEERCRED: production only accepts root (uid 0, sudo PAM).
        var cred = xucred()
        var credLen = socklen_t(MemoryLayout<xucred>.size)
        guard getsockopt(fd, SOL_LOCAL, LOCAL_PEERCRED, &cred, &credLen) == 0,
              cred.cr_version == XUCRED_VERSION else {
            close(fd)
            return
        }
        let allowed = (cred.cr_uid == 0) || (allowSameUserClient && cred.cr_uid == getuid())
        guard allowed else {
            close(fd)
            return
        }

        guard let line = readLine(fd: fd, maxBytes: 1024, timeoutMs: 1000),
              let data = line.data(using: .utf8),
              let req = try? JSONDecoder().decode(AuthRequest.self, from: data),
              req.v == 1,
              Self.isValidNonce(req.nonce) else {
            close(fd)
            return
        }

        if requireRootTemplates && !TemplateStoragePolicy.isTamperProtected(TemplateStoragePolicy.systemTemplateURL) {
            sendResponse(AuthResponse(v: 1, nonce: req.nonce, result: .notEnrolled), fd: fd)
            close(fd)
            return
        }

        if inFlight {
            sendResponse(AuthResponse(v: 1, nonce: req.nonce, result: .busy), fd: fd)
            close(fd)
            return
        }

        inFlight = true
        let clampedTimeout = TimeInterval(min(max(req.timeout, 3), 20))
        let reason = Self.displayReason(for: req)

        handler(req, reason, clampedTimeout) { [weak self] result in
            guard let self else {
                close(fd)
                return
            }
            self.queue.async {
                self.sendResponse(AuthResponse(v: 1, nonce: req.nonce, result: result), fd: fd)
                close(fd)
                self.inFlight = false
            }
        }
    }

    private func readLine(fd: Int32, maxBytes: Int, timeoutMs: Int32) -> String? {
        var buffer = Data()
        var chunk = [UInt8](repeating: 0, count: 256)
        while buffer.count < maxBytes {
            var pfd = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
            let prc = poll(&pfd, 1, timeoutMs)
            if prc <= 0 { return nil }
            let n = recv(fd, &chunk, min(chunk.count, maxBytes - buffer.count), 0)
            if n <= 0 { break }
            buffer.append(contentsOf: chunk[0..<n])
            if let nl = buffer.firstIndex(of: 0x0A) {
                return String(data: buffer[..<nl], encoding: .utf8)
            }
        }
        return nil
    }

    private func sendResponse(_ response: AuthResponse, fd: Int32) {
        guard var data = try? JSONEncoder().encode(response) else { return }
        data.append(0x0A)
        data.withUnsafeBytes { raw in
            guard let base = raw.baseAddress else { return }
            var sent = 0
            while sent < data.count {
                let n = send(fd, base.advanced(by: sent), data.count - sent, 0)
                if n <= 0 { break }
                sent += n
            }
        }
    }

    static func isValidNonce(_ s: String) -> Bool {
        guard s.count == 64 else { return false }
        return s.unicodeScalars.allSatisfy {
            ($0 >= "0" && $0 <= "9") || ($0 >= "a" && $0 <= "f")
        }
    }

    static func displayReason(for req: AuthRequest) -> String {
        let svc = req.service.isEmpty ? "sudo" : req.service
        return "\(svc) 인증 중"
    }

    static func displayBadge(for req: AuthRequest) -> String {
        let svc = req.service.isEmpty ? "sudo" : req.service
        if req.tty.isEmpty { return svc }
        return "\(svc) · \(req.tty)"
    }

    /// Self-test for Unix socket IPC, nonce validation, and TemplateStoragePolicy.
    /// Can be called from main.swift's --selftest after merging feat/face-model.
    static func runSelfTest() {
        func connectUnix(_ path: String) -> Int32 {
            let fd = socket(AF_UNIX, SOCK_STREAM, 0)
            precondition(fd >= 0, "socket() failed")
            var addr = sockaddr_un()
            addr.sun_family = sa_family_t(AF_UNIX)
            let bytes = Array(path.utf8CString)
            withUnsafeMutableBytes(of: &addr.sun_path) { raw in
                bytes.withUnsafeBytes { src in raw.copyMemory(from: src) }
            }
            let rc = withUnsafePointer(to: &addr) { ptr in
                ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockPtr in
                    connect(fd, sockPtr, socklen_t(MemoryLayout<sockaddr_un>.size))
                }
            }
            precondition(rc == 0, "connect() to AuthServer test socket failed: errno=\(errno)")
            return fd
        }

        let tmpDir = URL(fileURLWithPath: "/tmp", isDirectory: true)
            .appendingPathComponent("notchfaceid-selftest-\(getpid())", isDirectory: true)
        let sockURL = tmpDir.appendingPathComponent("auth.sock")
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        try? FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
        let dummyTemplate = tmpDir.appendingPathComponent("faces")
        try? Data("test".utf8).write(to: dummyTemplate)
        precondition(!TemplateStoragePolicy.isTamperProtected(dummyTemplate), "user-owned file must not pass tamper check")

        let server = AuthServer(socketURL: sockURL, allowSameUserClient: true, requireRootTemplates: false) { req, _, _, completion in
            precondition(req.service == "sudo", "unexpected service")
            completion(.success)
        }
        precondition(server.start(), "AuthServer failed to start")
        defer { server.stop() }

        let nonce = String(repeating: "a1b2c3d4", count: 8)
        let fd1 = connectUnix(sockURL.path)
        let validReq = "{\"v\":1,\"nonce\":\"\(nonce)\",\"user\":\"tester\",\"tty\":\"ttys001\",\"service\":\"sudo\",\"pid\":123,\"timeout\":3}\n"
        _ = validReq.withCString { send(fd1, $0, strlen($0), 0) }
        var buf = [UInt8](repeating: 0, count: 512)
        let n1 = recv(fd1, &buf, buf.count, 0)
        close(fd1)
        precondition(n1 > 0, "AuthServer returned no response")
        let resp = try! JSONDecoder().decode(AuthResponse.self, from: Data(buf[0..<n1]))
        precondition(resp.v == 1 && resp.nonce == nonce && resp.result == .success, "AuthServer response mismatch")

        let fd2 = connectUnix(sockURL.path)
        let badReq = "{\"v\":1,\"nonce\":\"short\",\"user\":\"tester\",\"tty\":\"\",\"service\":\"sudo\",\"pid\":123,\"timeout\":3}\n"
        _ = badReq.withCString { send(fd2, $0, strlen($0), 0) }
        let n2 = recv(fd2, &buf, buf.count, 0)
        close(fd2)
        precondition(n2 == 0, "AuthServer must close connection on invalid nonce")
    }
}
