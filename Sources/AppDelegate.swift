// Notch panel, menu and its actions.
import AppKit
import SwiftUI

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    let ui = UI()
    lazy var engine = Engine(ui: ui)
    var panel: NSPanel!
    var status: NSStatusItem!
    let menu = NSMenu()
    var hit = CGRect.zero  // notch click target, in screen coordinates; set by layout()
    let info = NSMenuItem(title: "", action: nil, keyEquivalent: "")

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
        menu.items = [
            item("얼굴 인식", #selector(scan)), item("얼굴 등록", #selector(enroll)), item("등록 삭제", #selector(reset)),
            .separator(), info,
            item("더 엄격하게 (기준 −10%)", #selector(tune), tag: 90), item("더 느슨하게 (기준 +10%)", #selector(tune), tag: 110),
            .separator(), NSMenuItem(title: "종료", action: #selector(NSApplication.terminate), keyEquivalent: "q"),
        ]
        status.menu = menu

        // A full menu bar pushes the status item behind the notch, so a click on the notch opens the same menu.
        // On mouse-up and after activating: a menu opened mid-click by an inactive app is dismissed at once.
        NSEvent.addGlobalMonitorForEvents(matching: .leftMouseUp) { _ in
            guard self.hit.contains(NSEvent.mouseLocation) else { return }
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
        let size = CGSize(width: max(notch.width + 60, 260) + 40, height: notch.height + 140)
        panel.contentView = NSHostingView(rootView: NotchView(ui: ui, notch: notch))
        panel.setFrame(CGRect(x: screen.frame.midX - size.width / 2, y: screen.frame.maxY - size.height, width: size.width, height: size.height), display: true)
        let height = max(notch.height, 24)
        hit = CGRect(x: screen.frame.midX - notch.width / 2, y: screen.frame.maxY - height, width: notch.width, height: height)
    }

    // Opening the app again (Spotlight, Dock, `open -a NotchFaceID`) starts a scan: a trigger without a hotkey.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        scan()
        return false
    }

    func menuWillOpen(_ menu: NSMenu) {
        let last = ui.last.isFinite ? String(format: "%.2f", ui.last) : "–"
        info.title = String(format: "마지막 거리 \(last) / 기준 %.2f (거리 ≤ 기준이면 통과)", UserDefaults.standard.float(forKey: "threshold"))
    }

    func item(_ title: String, _ action: Selector, tag: Int = 0) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
        item.target = self
        item.tag = tag
        return item
    }

    var busy: Bool { ui.phase == .scanning || ui.phase == .enrolling }

    @objc func scan() {
        guard !busy else { return }
        engine.isEnrolled ? engine.start(.scanning) : engine.show(.notice, "메뉴 막대 아이콘에서 얼굴 등록")
    }

    @objc func enroll() {
        guard !busy else { return }
        engine.start(.enrolling)
    }

    @objc func reset() {
        guard !busy else { return }
        engine.reset()
        engine.show(.notice, "등록 삭제됨")
    }

    @objc func tune(_ sender: NSMenuItem) {
        let defaults = UserDefaults.standard
        defaults.set(defaults.float(forKey: "threshold") * Float(sender.tag) / 100, forKey: "threshold")
    }
}
