// Notch panel, menu and its actions.
import AppKit
import SwiftUI

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private struct PendingConsent {
        let reason: String
        let deadline: Date
        let timer: DispatchWorkItem
        let completion: (AuthResult) -> Void
    }

    let ui = UI()
    lazy var engine = Engine(ui: ui)
    var panel: NSPanel!
    var status: NSStatusItem!
    let menu = NSMenu()
    var hit = CGRect.zero          // notch click target, in screen coordinates; set by layout()
    var expandedHit = CGRect.zero  // expanded notch pill click target (for sudo consent)
    let info = NSMenuItem(title: "", action: nil, keyEquivalent: "")
    let authStatus = NSMenuItem(title: "", action: nil, keyEquivalent: "")
    var screenUnlockToggle: NSMenuItem!
    var screenUnlockPasswordItem: NSMenuItem!
    var screenUnlockDeleteItem: NSMenuItem!
    var recordFramesToggle: NSMenuItem!
    var authServer: AuthServer?
    var screenUnlock: ScreenUnlockManager?
    private var pendingConsent: PendingConsent?
    private var badgeToken = 0

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Transparent click-through panel over the notch; the SwiftUI shape animates inside it.
        panel = NSPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.level = .popUpMenu  // above the menu bar
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.ignoresMouseEvents = true
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary]
        layout()
        panel.orderFrontRegardless()
        // Scaling, resolution and displays coming or going all change where the notch is and how big it is in points.
        NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { _ in
            self.layout()
        }

        status = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        status.button?.image = NSImage(systemSymbolName: "faceid", accessibilityDescription: "NotchFaceID")
        menu.delegate = self
        screenUnlockToggle = item("잠금 화면 얼굴 해제", #selector(toggleScreenUnlock))
        screenUnlockPasswordItem = item("잠금 해제 비밀번호 설정...", #selector(setScreenUnlockPassword))
        screenUnlockDeleteItem = item("잠금 해제 비밀번호 삭제", #selector(deleteScreenUnlockPassword))
        recordFramesToggle = item("판정 기록 (CSV)", #selector(toggleRecordFrames))

        menu.items = [
            item("얼굴 인식", #selector(scan)), item("얼굴 등록", #selector(enroll)), item("등록 삭제", #selector(reset)),
            .separator(), authStatus, info,
            item("더 엄격하게 (기준 −10%)", #selector(tune), tag: 90), item("더 느슨하게 (기준 +10%)", #selector(tune), tag: 110),
            .separator(), screenUnlockToggle, screenUnlockPasswordItem, screenUnlockDeleteItem,
            item("손쉬운 사용 권한 확인", #selector(checkAccessibility)),
            .separator(), recordFramesToggle, item("기록 폴더 열기", #selector(openLogFolder)),
            .separator(), NSMenuItem(title: "종료", action: #selector(NSApplication.terminate), keyEquivalent: "q"),
        ]
        status.menu = menu

        let server = AuthServer { [weak self] req, reason, timeout, completion in
            DispatchQueue.main.async {
                self?.requestSudoConsent(req: req, reason: reason, timeout: timeout, completion: completion)
            }
        }
        _ = server.start()
        authServer = server

        let unlock = ScreenUnlockManager { [weak self] reason, timeout, completion in
            DispatchQueue.main.async {
                guard let self else {
                    completion(.failure)
                    return
                }
                guard !self.busy, self.pendingConsent == nil else {
                    completion(.busy)
                    return
                }
                guard ScreenUnlockManager.hasProtectedTemplate else {
                    self.engine.show(.notice, "install-sudo.sh로 보호 템플릿 먼저 설정")
                    completion(.notEnrolled)
                    return
                }
                self.setBadge("잠금 화면")
                self.engine.authenticate(reason: reason, timeout: timeout) { [weak self] result in
                    completion(result)
                    self?.scheduleBadgeClear()
                }
            }
        }
        unlock.start()
        screenUnlock = unlock

        // A full menu bar pushes the status item behind the notch, so a click on the notch opens the same menu.
        // During a pending sudo request, clicking the expanded notch approves starting the face scan (explicit consent).
        // On mouse-up and after activating: a menu opened mid-click by an inactive app is dismissed at once.
        NSEvent.addGlobalMonitorForEvents(matching: .leftMouseUp) { _ in
            let loc = NSEvent.mouseLocation
            if self.pendingConsent != nil {
                if self.expandedHit.contains(loc) {
                    self.approvePendingSudoConsent()
                }
                return
            }
            guard self.hit.contains(loc) else { return }
            NSApp.activate(ignoringOtherApps: true)
            DispatchQueue.main.async { self.menu.popUp(positioning: nil, at: CGPoint(x: self.hit.minX, y: self.hit.minY), in: nil) }
        }

        scan()
    }

    /// Fits the panel, its notch shape and the click target to the current notch. Main thread.
    func layout() {
        guard let screen = NSScreen.screens.first(where: { $0.safeAreaInsets.top > 0 }) ?? NSScreen.main else { return }
        var notch = CGSize(width: 180, height: 0)  // no notch: the pill drops from the screen's top edge
        if let left = screen.auxiliaryTopLeftArea, let right = screen.auxiliaryTopRightArea, screen.safeAreaInsets.top > 0 {
            notch = CGSize(width: screen.frame.width - left.width - right.width, height: screen.safeAreaInsets.top)
        }
        let size = CGSize(width: max(notch.width + 60, 260) + 40, height: notch.height + 162)
        panel.contentView = NSHostingView(rootView: NotchView(ui: ui, notch: notch))
        panel.setFrame(CGRect(x: screen.frame.midX - size.width / 2, y: screen.frame.maxY - size.height, width: size.width, height: size.height), display: true)
        let height = max(notch.height, 24)
        hit = CGRect(x: screen.frame.midX - notch.width / 2, y: screen.frame.maxY - height, width: notch.width, height: height)
        let expandedWidth = max(notch.width + 60, 260)
        let expandedHeight = notch.height + 134
        expandedHit = CGRect(x: screen.frame.midX - expandedWidth / 2, y: screen.frame.maxY - expandedHeight, width: expandedWidth, height: expandedHeight)
    }

    // Opening the app again (Spotlight, Dock, `open -a NotchFaceID`) starts a scan: a trigger without a hotkey.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        scan()
        return false
    }

    func applicationWillTerminate(_ notification: Notification) {
        authServer?.stop()
        screenUnlock?.stop()
    }

    func menuWillOpen(_ menu: NSMenu) {
        let defaults = UserDefaults.standard
        let last = ui.last.isFinite ? String(format: "%.2f", ui.last) : "–"
        let effectiveThreshold = min(max(defaults.float(forKey: "threshold"), 0.2), thresholdCeiling)
        let effectiveLive = max(defaults.float(forKey: "live"), liveFloor)
        info.title = String(format: "마지막 거리 \(last) / 기준 %.2f · 라이브 ≥ %.2f (거리 ≤ 기준이면 통과)", effectiveThreshold, effectiveLive)
        let serverRunning = authServer?.isRunning == true
        let protected = TemplateStoragePolicy.isTamperProtected(TemplateStoragePolicy.systemTemplateURL)
        authStatus.title = serverRunning
            ? (protected ? "sudo 인증 대기 중 (보호 템플릿)" : "sudo 인증 대기 중 (보호 템플릿 필요)")
            : "sudo 인증 서버 비활성"

        let hasPw = ScreenUnlockKeychain.hasPassword
        let hasAx = ScreenUnlockManager.hasAccessibilityPermission
        screenUnlockToggle.state = (screenUnlock?.isEnabled == true && protected) ? .on : .off
        screenUnlockPasswordItem.title = hasPw ? "잠금 해제 비밀번호 변경..." : "잠금 해제 비밀번호 설정..."
        screenUnlockDeleteItem.isEnabled = hasPw
        if !protected {
            screenUnlockToggle.title = "잠금 화면 얼굴 해제 (보호 템플릿 필요)"
        } else if !hasAx && screenUnlock?.isEnabled == true {
            screenUnlockToggle.title = "잠금 화면 얼굴 해제 (손쉬운 사용 권한 필요)"
        } else {
            screenUnlockToggle.title = "잠금 화면 얼굴 해제"
        }

        recordFramesToggle.state = defaults.bool(forKey: "recordFrames") ? .on : .off
    }

    func item(_ title: String, _ action: Selector, tag: Int = 0) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
        item.target = self
        item.tag = tag
        return item
    }

    var busy: Bool { ui.phase == .scanning || ui.phase == .enrolling || ui.phase == .awaitingConsent }

    private func setBadge(_ text: String) {
        badgeToken += 1
        ui.badge = text
    }

    private func scheduleBadgeClear(after delay: TimeInterval = 2.1) {
        let token = badgeToken
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self, self.badgeToken == token, self.ui.phase == .idle else { return }
            self.ui.badge = ""
        }
    }

    /// Requires explicit mouse click on the notch before running face recognition for sudo.
    /// Prevents passive/silent privilege escalation by user-level malware while the user sits at the Mac.
    private func requestSudoConsent(req: AuthRequest, reason: String, timeout: TimeInterval, completion: @escaping (AuthResult) -> Void) {
        guard !busy, pendingConsent == nil else {
            completion(.busy)
            return
        }
        guard engine.canAuthenticate else {
            engine.show(.notice, "얼굴 미등록")
            completion(.notEnrolled)
            return
        }

        let deadline = Date().addingTimeInterval(timeout)
        let consentWindow = max(timeout - 3.5, 2.0)

        setBadge(AuthServer.displayBadge(for: req))
        ui.text = "클릭해서 승인"
        ui.phase = .awaitingConsent

        let timer = DispatchWorkItem { [weak self] in
            guard let self, let expired = self.pendingConsent else { return }
            self.pendingConsent = nil
            if self.ui.phase == .awaitingConsent {
                self.ui.phase = .idle
                self.setBadge("")
            }
            expired.completion(.failure)
        }
        pendingConsent = PendingConsent(reason: reason, deadline: deadline, timer: timer, completion: completion)
        DispatchQueue.main.asyncAfter(deadline: .now() + consentWindow, execute: timer)
    }

    private func approvePendingSudoConsent() {
        guard let consent = pendingConsent else { return }
        pendingConsent = nil
        consent.timer.cancel()

        let remaining = max(consent.deadline.timeIntervalSinceNow, 3.0)
        engine.authenticate(reason: consent.reason, timeout: remaining) { [weak self] result in
            consent.completion(result)
            self?.scheduleBadgeClear()
        }
    }

    @objc func scan() {
        guard !busy else { return }
        setBadge("")
        engine.isEnrolled ? engine.start(.scanning) : engine.show(.notice, "메뉴 막대 아이콘에서 얼굴 등록")
    }

    @objc func enroll() {
        guard !busy else { return }
        setBadge("")
        engine.start(.enrolling)
    }

    @objc func reset() {
        guard !busy else { return }
        setBadge("")
        engine.show(.notice, engine.reset() ? "등록 삭제됨" : "삭제됨 · sudo용 사본은 uninstall-sudo.sh --purge로 삭제")
    }

    @objc func tune(_ sender: NSMenuItem) {
        let defaults = UserDefaults.standard
        let current = min(max(defaults.float(forKey: "threshold"), 0.2), thresholdCeiling)
        let next = min(max(current * Float(sender.tag) / 100, 0.2), thresholdCeiling)
        defaults.set(next, forKey: "threshold")
        if defaults.float(forKey: "live") < liveFloor {
            defaults.set(liveFloor, forKey: "live")
        }
    }

    @objc func toggleRecordFrames() {
        let defaults = UserDefaults.standard
        let next = !defaults.bool(forKey: "recordFrames")
        defaults.set(next, forKey: "recordFrames")
        engine.show(.notice, next ? "판정 기록 켜짐 (이미지 미저장)" : "판정 기록 꺼짐")
    }

    @objc func openLogFolder() {
        let file = FrameLog.url
        let dir = file.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        if FileManager.default.fileExists(atPath: file.path) {
            NSWorkspace.shared.activateFileViewerSelecting([file])
        } else {
            NSWorkspace.shared.open(dir)
        }
    }

    @objc func toggleScreenUnlock() {
        guard let screenUnlock else { return }
        if !screenUnlock.isEnabled {
            guard ScreenUnlockManager.hasProtectedTemplate else {
                engine.show(.notice, "install-sudo.sh로 보호 템플릿 먼저 설정")
                return
            }
            if !ScreenUnlockKeychain.hasPassword {
                guard ScreenUnlockManager.promptAndSavePassword() else { return }
            }
            if !ScreenUnlockManager.hasAccessibilityPermission {
                ScreenUnlockManager.requestAccessibilityPermission()
            }
            screenUnlock.isEnabled = true
            engine.show(.notice, "잠금 화면 얼굴 해제 켜짐")
        } else {
            screenUnlock.isEnabled = false
            engine.show(.notice, "잠금 화면 얼굴 해제 꺼짐")
        }
    }

    @objc func setScreenUnlockPassword() {
        if ScreenUnlockManager.promptAndSavePassword() {
            engine.show(.notice, "잠금 해제 비밀번호 저장됨")
        }
    }

    @objc func deleteScreenUnlockPassword() {
        ScreenUnlockKeychain.delete()
        screenUnlock?.isEnabled = false
        engine.show(.notice, "잠금 해제 비밀번호 삭제됨")
    }

    @objc func checkAccessibility() {
        if ScreenUnlockManager.requestAccessibilityPermission() {
            engine.show(.notice, "손쉬운 사용 권한 허용됨")
        } else {
            engine.show(.notice, "시스템 설정에서 손쉬운 사용 허용 필요")
        }
    }
}
