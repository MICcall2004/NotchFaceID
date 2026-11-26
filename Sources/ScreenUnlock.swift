// Lock Screen Face Unlock via Keychain + Accessibility (CGEvent auto-type).
//
// Why this path instead of an AuthorizationPlugin:
// - Never modifies `authorizationdb` or `/Library/Security/SecurityAgentPlugins/` -> zero lockout risk.
// - Preserves native Lock Screen UI, Touch ID, and login Keychain unlock.
// - Requires user opt-in: Accessibility permission + storing the login password in Keychain.
import AppKit
import ApplicationServices
import Foundation
import IOKit
import os.log
import Security

enum ScreenUnlockKeychain {
    private static let service = "local.notchfaceid.screenunlock"
    private static var account: String { NSUserName() }

    static var hasPassword: Bool {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnAttributes as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        return SecItemCopyMatching(query as CFDictionary, nil) == errSecSuccess
    }

    @discardableResult
    static func save(password: String) -> Bool {
        guard let data = password.data(using: .utf8), !data.isEmpty else { return false }
        delete()
        let attrs: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
            kSecValueData as String: data,
        ]
        return SecItemAdd(attrs as CFDictionary, nil) == errSecSuccess
    }

    static func loadPassword() -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var result: AnyObject?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              var data = result as? Data else {
            return nil
        }
        defer { data.resetBytes(in: 0..<data.count) }
        return String(data: data, encoding: .utf8)
    }

    @discardableResult
    static func delete() -> Bool {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        let status = SecItemDelete(query as CFDictionary)
        return status == errSecSuccess || status == errSecItemNotFound
    }
}

final class ScreenUnlockManager {
    static let enabledKey = "screenUnlockEnabled"
    private static let maxAttemptsPerLock = 2
    private static let cooldownSeconds: TimeInterval = 4.0
    /// Prevents immediately unlocking right after the user intentionally presses Ctrl+Cmd+Q.
    private static let minLockDwellSeconds: TimeInterval = 3.0
    private static let logger = OSLog(subsystem: "local.notchfaceid.screenunlock", category: "unlock")

    typealias AuthenticateFn = (_ reason: String, _ timeout: TimeInterval, _ completion: @escaping (AuthResult) -> Void) -> Void

    private let authenticate: AuthenticateFn
    private var isLocked = false
    private var lockedAt = Date.distantPast
    private var isScanning = false
    private var attemptsThisLock = 0
    private var lastAttempt = Date.distantPast
    private var observers: [NSObjectProtocol] = []
    private var distributedObservers: [NSObjectProtocol] = []

    var isEnabled: Bool {
        get { UserDefaults.standard.bool(forKey: Self.enabledKey) }
        set { UserDefaults.standard.set(newValue, forKey: Self.enabledKey) }
    }

    static var hasAccessibilityPermission: Bool {
        AXIsProcessTrusted()
    }

    static var hasProtectedTemplate: Bool {
        TemplateStoragePolicy.isTamperProtected(TemplateStoragePolicy.systemTemplateURL)
    }

    @discardableResult
    static func requestAccessibilityPermission() -> Bool {
        let opts = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        return AXIsProcessTrustedWithOptions(opts)
    }

    init(authenticate: @escaping AuthenticateFn) {
        self.authenticate = authenticate
    }

    deinit {
        stop()
    }

    func start() {
        // Initialize lock state in case the app starts while the screen is already locked.
        if Self.isSessionLocked() {
            isLocked = true
            lockedAt = Date.distantPast
        }

        let dnc = DistributedNotificationCenter.default()
        distributedObservers.append(
            dnc.addObserver(forName: NSNotification.Name("com.apple.screenIsLocked"), object: nil, queue: .main) { [weak self] _ in
                self?.onScreenLocked()
            }
        )
        distributedObservers.append(
            dnc.addObserver(forName: NSNotification.Name("com.apple.screenIsUnlocked"), object: nil, queue: .main) { [weak self] _ in
                self?.onScreenUnlocked()
            }
        )

        let wsnc = NSWorkspace.shared.notificationCenter
        observers.append(
            wsnc.addObserver(forName: NSWorkspace.screensDidWakeNotification, object: nil, queue: .main) { [weak self] _ in
                self?.scheduleUnlockAttempt(delay: 0.6)
            }
        )
        observers.append(
            wsnc.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
                self?.scheduleUnlockAttempt(delay: 1.0)
            }
        )
    }

    func stop() {
        let dnc = DistributedNotificationCenter.default()
        distributedObservers.forEach { dnc.removeObserver($0) }
        distributedObservers.removeAll()

        let wsnc = NSWorkspace.shared.notificationCenter
        observers.forEach { wsnc.removeObserver($0) }
        observers.removeAll()
    }

    /// Returns true iff WindowServer/CGSession reports the screen is currently locked.
    private static func isSessionLocked() -> Bool {
        guard let dict = CGSessionCopyCurrentDictionary() as? [String: Any] else { return false }
        return (dict["CGSSessionScreenIsLocked"] as? Bool) == true
    }

    /// Verifies with WindowServer/CGSession (cannot be spoofed via DistributedNotificationCenter)
    /// that the screen is truly locked AND loginwindow is the frontmost application.
    static func isSystemScreenActuallyLocked() -> Bool {
        guard isSessionLocked() else { return false }
        let frontBundle = NSWorkspace.shared.frontmostApplication?.bundleIdentifier
        guard frontBundle == "com.apple.loginwindow" else {
            os_log("blocking screen unlock: frontmost=%{public}@ (expected com.apple.loginwindow)",
                   log: Self.logger, type: .error, frontBundle ?? "(nil)")
            return false
        }
        return true
    }

    private func markLockedIfConfirmed() {
        guard Self.isSessionLocked() else { return }
        if !isLocked {
            isLocked = true
            lockedAt = Date()
            attemptsThisLock = 0
            os_log("screen locked", log: Self.logger, type: .info)
        }
    }

    private func onScreenLocked() {
        if Self.isSessionLocked() {
            markLockedIfConfirmed()
            return
        }
        // WindowServer can update CGSSessionScreenIsLocked slightly after the distributed notification.
        // Re-check once after 250ms so real locks aren't missed while spoofed notifications stay ignored.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [weak self] in
            guard let self else { return }
            if Self.isSessionLocked() {
                self.markLockedIfConfirmed()
            } else {
                os_log("ignored spoofed com.apple.screenIsLocked notification", log: Self.logger, type: .error)
            }
        }
    }

    private func onScreenUnlocked() {
        isLocked = false
        isScanning = false
        attemptsThisLock = 0
        os_log("screen unlocked", log: Self.logger, type: .info)
    }

    private func scheduleUnlockAttempt(delay: TimeInterval) {
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            self?.attemptUnlockIfEligible()
        }
    }

    private func attemptUnlockIfEligible() {
        guard isEnabled,
              isLocked,
              !isScanning,
              Self.isSystemScreenActuallyLocked(),
              Date().timeIntervalSince(lockedAt) >= Self.minLockDwellSeconds,
              attemptsThisLock < Self.maxAttemptsPerLock,
              Date().timeIntervalSince(lastAttempt) >= Self.cooldownSeconds,
              !Self.isClamshellClosed(),
              Self.hasAccessibilityPermission,
              ScreenUnlockKeychain.hasPassword else {
            return
        }

        guard Self.hasProtectedTemplate else {
            os_log("blocking screen unlock: root-protected template required at %{public}@",
                   log: Self.logger, type: .error, TemplateStoragePolicy.systemTemplateURL.path)
            return
        }

        isScanning = true
        attemptsThisLock += 1
        lastAttempt = Date()
        os_log("starting face unlock attempt %d", log: Self.logger, type: .info, attemptsThisLock)

        authenticate("잠금 화면 해제 중", 5.0) { [weak self] result in
            guard let self else { return }
            self.isScanning = false
            os_log("face unlock scan finished: %{public}@", log: Self.logger, type: .info, result.rawValue)
            // Re-verify actual lock state, frontmost loginwindow, and protected template immediately before typing password.
            guard result == .success, self.isLocked, Self.isSystemScreenActuallyLocked(), Self.hasProtectedTemplate else { return }
            guard let password = ScreenUnlockKeychain.loadPassword() else { return }
            Self.typePasswordAndSubmit(password)
        }
    }

    /// Synthesizes keystrokes at the HID tap to submit the login password on the Lock Screen.
    /// Must be verified on macOS 26.6.2 (Secure Input policies vary across macOS versions).
    static func typePasswordAndSubmit(_ password: String) {
        guard isSystemScreenActuallyLocked() else {
            os_log("aborted password typing: screen not locked or loginwindow not frontmost", log: Self.logger, type: .error)
            return
        }
        guard let source = CGEventSource(stateID: .hidSystemState) else { return }

        // Wake the password text field cleanly before typing.
        for scalar in password.utf16 {
            var codeUnit = scalar
            if let down = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: true),
               let up = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: false) {
                down.keyboardSetUnicodeString(stringLength: 1, unicodeString: &codeUnit)
                up.keyboardSetUnicodeString(stringLength: 1, unicodeString: &codeUnit)
                down.post(tap: .cghidEventTap)
                up.post(tap: .cghidEventTap)
                usleep(8_000)
            }
        }

        usleep(30_000)
        // Return key (virtual keyCode 36)
        if let retDown = CGEvent(keyboardEventSource: source, virtualKey: 36, keyDown: true),
           let retUp = CGEvent(keyboardEventSource: source, virtualKey: 36, keyDown: false) {
            retDown.post(tap: .cghidEventTap)
            retUp.post(tap: .cghidEventTap)
        }
    }

    private static func isClamshellClosed() -> Bool {
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("IOPMrootDomain"))
        guard service != IO_OBJECT_NULL else { return false }
        defer { IOObjectRelease(service) }
        guard let prop = IORegistryEntryCreateCFProperty(service, "AppleClamshellState" as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue() else {
            return false
        }
        return (prop as? Bool) == true
    }

    /// Presents a native modal dialog for saving the user's macOS login password to Keychain.
    @discardableResult
    static func promptAndSavePassword() -> Bool {
        let alert = NSAlert()
        alert.messageText = "잠금 화면 해제 비밀번호 설정"
        alert.informativeText = "얼굴 인식 성공 시 잠금 화면에 자동 입력할 macOS 로그인 비밀번호를 Keychain에 암호화해 저장합니다. (Touch ID·일반 비밀번호는 그대로 유지됩니다.)"
        alert.addButton(withTitle: "저장")
        alert.addButton(withTitle: "취소")

        let field = NSSecureTextField(frame: NSRect(x: 0, y: 0, width: 240, height: 24))
        field.placeholderString = "macOS 로그인 비밀번호"
        alert.accessoryView = field
        alert.window.initialFirstResponder = field

        NSApp.activate(ignoringOtherApps: true)
        guard alert.runModal() == .alertFirstButtonReturn else { return false }
        return ScreenUnlockKeychain.save(password: field.stringValue)
    }
}
