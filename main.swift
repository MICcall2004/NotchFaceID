// NotchFaceID: Face ID-style face matcher that animates out of the MacBook notch.
// Build: ./build.sh    Self-check: NotchFaceID.app/Contents/MacOS/NotchFaceID --selftest
import AppKit
import AVFoundation
import SwiftUI
import Vision

enum Phase { case idle, notice, scanning, enrolling, success, fail }

final class UI: ObservableObject {
    @Published var phase = Phase.idle
    @Published var text = ""
    @Published var progress = 0.0  // enrollment ring, 0...1
    @Published var fails = 0       // each increment plays one shake
    var last = Float.infinity      // best distance of the last scan, shown in the menu for calibration
}

// MARK: - Matching

// shortcut: Vision has no face-identity embedding, so this compares a generic image feature print
// of the face crop. It tells apart clearly different faces in similar light, has no liveness check
// (a photo passes) and is not a security boundary. Upgrade to a real face-embedding Core ML model
// before gating anything that matters.
func featurePrint(_ handler: VNImageRequestHandler, roi: CGRect) -> [Float]? {
    let request = VNGenerateImageFeaturePrintRequest()
    request.regionOfInterest = roi.intersection(CGRect(x: 0, y: 0, width: 1, height: 1))
    try? handler.perform([request])
    // Raw floats, not the observation: VNFeaturePrintObservation does not survive secure unarchiving.
    guard let print = request.results?.first, print.elementType == .float else { return nil }
    return print.data.withUnsafeBytes { Array($0.bindMemory(to: Float.self)) }
}

/// Euclidean distance. Prints of different sizes (a new OS model) never match, which forces a re-enroll.
func distance(_ a: [Float], _ b: [Float]) -> Float {
    guard a.count == b.count else { return .infinity }
    return zip(a, b).reduce(0) { $0 + ($1.0 - $1.1) * ($1.0 - $1.1) }.squareRoot()
}

let enrollCount = 10
let store = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
    .appendingPathComponent("NotchFaceID/faces")

final class Engine: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate {
    let ui: UI
    private let session = AVCaptureSession()
    private let control = DispatchQueue(label: "control")  // startRunning/stopRunning block: keep them off main and off the frame queue
    private let frames = DispatchQueue(label: "frames")    // owns every var below
    private var mode = Phase.idle
    private var run = 0
    private var enrolled: [[Float]]
    private var samples: [[Float]] = []
    private var lastSample = Date.distantPast
    private var best = Float.infinity

    init(ui: UI) {
        self.ui = ui
        enrolled = (try? Data(contentsOf: store)).flatMap { try? PropertyListDecoder().decode([[Float]].self, from: $0) } ?? []
    }

    var isEnrolled: Bool { frames.sync { !enrolled.isEmpty } }

    func reset() {
        frames.sync { enrolled = [] }
        try? FileManager.default.removeItem(at: store)
    }

    /// Call on main with `.scanning` or `.enrolling`.
    func start(_ phase: Phase) {
        ui.progress = 0
        ui.text = phase == .enrolling ? "고개를 천천히 움직이세요" : "얼굴 인식 중"
        ui.phase = phase
        AVCaptureDevice.requestAccess(for: .video) { granted in
            guard granted else { return self.show(.notice, "시스템 설정에서 카메라 권한 허용 필요") }
            self.control.async {
                if self.session.inputs.isEmpty {
                    // Built-in camera first: the plain default can be a nearby iPhone.
                    guard let camera = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .unspecified)
                            ?? AVCaptureDevice.default(for: .video),
                          let input = try? AVCaptureDeviceInput(device: camera), self.session.canAddInput(input)
                    else { return self.show(.notice, "카메라를 찾을 수 없음") }
                    let output = AVCaptureVideoDataOutput()
                    output.setSampleBufferDelegate(self, queue: self.frames)
                    self.session.addInput(input)
                    self.session.addOutput(output)
                }
                self.session.startRunning()
                self.frames.sync {
                    self.mode = phase
                    self.samples = []
                    self.best = .infinity
                    self.run += 1
                    let run = self.run
                    // The timeout is a timer, not a frame check, so a camera that delivers nothing still ends.
                    self.frames.asyncAfter(deadline: .now() + (phase == .enrolling ? 15 : 4)) {
                        if self.run == run, self.mode != .idle {
                            self.finish(.fail, phase == .enrolling ? "얼굴을 찾지 못함" : "인식 실패")
                        }
                    }
                }
            }
        }
    }

    func captureOutput(_ output: AVCaptureOutput, didOutput buffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        guard mode != .idle, let pixels = CMSampleBufferGetImageBuffer(buffer) else { return }
        let handler = VNImageRequestHandler(cvPixelBuffer: pixels)
        let detect = VNDetectFaceRectanglesRequest()
        try? handler.perform([detect])
        // Nearest face only, and close enough that the crop carries detail.
        guard let face = detect.results?.max(by: { $0.boundingBox.width < $1.boundingBox.width }),
              face.boundingBox.width > 0.12,
              let fp = featurePrint(handler, roi: face.boundingBox) else { return }

        if mode == .scanning {
            best = min(best, enrolled.map { distance(fp, $0) }.min() ?? .infinity)
            if best <= UserDefaults.standard.float(forKey: "threshold") { finish(.success, "인식 완료") }
        } else if Date().timeIntervalSince(lastSample) > 0.25 {  // spaced out so the samples cover head movement
            lastSample = Date()
            samples.append(fp)
            let done = Double(samples.count) / Double(enrollCount)
            DispatchQueue.main.async { self.ui.progress = done }
            if samples.count == enrollCount { saveEnrollment() }
        }
    }

    private func saveEnrollment() {
        do {
            try FileManager.default.createDirectory(at: store.deletingLastPathComponent(), withIntermediateDirectories: true)
            try PropertyListEncoder().encode(samples).write(to: store, options: .atomic)
        } catch {
            return finish(.fail, "저장 실패")
        }
        enrolled = samples
        // Calibrate to this camera: a live frame must land as close to a sample as the samples sit to each other.
        // shortcut: the 1.2 margin and 0.3 floor are untested guesses, tune from the menu (distance vs threshold) on real use.
        var spread: Float = 0
        for a in samples { for b in samples { spread = max(spread, distance(a, b)) } }
        UserDefaults.standard.set(max(spread * 1.2, 0.3), forKey: "threshold")
        finish(.success, "등록 완료")
    }

    private func finish(_ phase: Phase, _ text: String) {  // frames queue
        if mode == .scanning {
            let best = best
            DispatchQueue.main.async { self.ui.last = best }
        }
        mode = .idle
        control.async { self.session.stopRunning() }
        show(phase, text)
    }

    /// Shows a result or message in the notch, then closes it. Any thread.
    func show(_ phase: Phase, _ text: String) {
        DispatchQueue.main.async {
            let ui = self.ui
            if phase == .fail { ui.fails += 1 }
            ui.text = text
            ui.phase = phase
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) { if ui.phase == phase { ui.phase = .idle } }
        }
    }
}

// MARK: - Notch UI

struct Shake: GeometryEffect {
    var animatableData: CGFloat
    func effectValue(size: CGSize) -> ProjectionTransform {
        ProjectionTransform(CGAffineTransform(translationX: 8 * sin(animatableData * .pi * 6), y: 0))
    }
}

struct NotchView: View {
    @ObservedObject var ui: UI
    let notch: CGSize

    var body: some View {
        let open = ui.phase != .idle
        let tint: Color = ui.phase == .success ? .green : ui.phase == .fail ? .red : .white
        VStack(spacing: 8) {
            ZStack {
                Circle().trim(from: 0, to: ui.progress)
                    .stroke(.green, style: StrokeStyle(lineWidth: 3, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                    .animation(.linear(duration: 0.2), value: ui.progress)
                Image(systemName: ui.phase == .success ? "checkmark.circle.fill" : "faceid")
                    .font(.system(size: 34))
                    .foregroundStyle(tint)
                    .contentTransition(.symbolEffect(.replace))
                    .symbolEffect(.pulse, isActive: ui.phase == .scanning || ui.phase == .enrolling)
            }
            .frame(width: 60, height: 60)
            Text(ui.text).font(.system(size: 12, weight: .medium)).foregroundStyle(.white.opacity(0.8)).lineLimit(1)
        }
        .padding(.top, notch.height + 6)  // content sits below the physical notch
        .opacity(open ? 1 : 0)
        // Closed, the black shape is exactly the notch, so it is invisible.
        .frame(width: open ? max(notch.width + 60, 260) : notch.width,
               height: open ? notch.height + 112 : notch.height, alignment: .top)
        .background(.black, in: UnevenRoundedRectangle(bottomLeadingRadius: open ? 26 : 8, bottomTrailingRadius: open ? 26 : 8, style: .continuous))
        .modifier(Shake(animatableData: CGFloat(ui.fails)))
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .ignoresSafeArea()
        .animation(.linear(duration: 0.45), value: ui.fails)
        .animation(.spring(response: 0.4, dampingFraction: 0.75), value: ui.phase)
    }
}

// MARK: - App

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    let ui = UI()
    lazy var engine = Engine(ui: ui)
    var panel: NSPanel!
    var status: NSStatusItem!
    let info = NSMenuItem(title: "", action: nil, keyEquivalent: "")

    func applicationDidFinishLaunching(_ notification: Notification) {
        guard let screen = NSScreen.screens.first(where: { $0.safeAreaInsets.top > 0 }) ?? NSScreen.main else { return NSApp.terminate(nil) }
        var notch = CGSize(width: 180, height: 0)  // no notch: the pill drops from the screen's top edge
        if let left = screen.auxiliaryTopLeftArea, let right = screen.auxiliaryTopRightArea, screen.safeAreaInsets.top > 0 {
            notch = CGSize(width: screen.frame.width - left.width - right.width, height: screen.safeAreaInsets.top)
        }

        // Transparent click-through panel over the notch; the SwiftUI shape animates inside it.
        let size = CGSize(width: max(notch.width + 60, 260) + 40, height: notch.height + 140)
        panel = NSPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.level = .popUpMenu  // above the menu bar
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.ignoresMouseEvents = true
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary]
        panel.contentView = NSHostingView(rootView: NotchView(ui: ui, notch: notch))
        panel.setFrame(CGRect(x: screen.frame.midX - size.width / 2, y: screen.frame.maxY - size.height, width: size.width, height: size.height), display: true)
        panel.orderFrontRegardless()

        status = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        status.button?.image = NSImage(systemSymbolName: "faceid", accessibilityDescription: "NotchFaceID")
        let menu = NSMenu()
        menu.delegate = self
        menu.items = [
            item("얼굴 인식", #selector(scan)), item("얼굴 등록", #selector(enroll)), item("등록 삭제", #selector(reset)),
            .separator(), info,
            item("더 엄격하게 (기준 −10%)", #selector(tune), tag: 90), item("더 느슨하게 (기준 +10%)", #selector(tune), tag: 110),
            .separator(), NSMenuItem(title: "종료", action: #selector(NSApplication.terminate), keyEquivalent: "q"),
        ]
        status.menu = menu

        // A full menu bar pushes the status item behind the notch, so a click on the notch opens the same menu.
        let height = max(notch.height, 24)
        let hit = CGRect(x: screen.frame.midX - notch.width / 2, y: screen.frame.maxY - height, width: notch.width, height: height)
        // On mouse-up and after activating: a menu opened mid-click by an inactive app is dismissed at once.
        NSEvent.addGlobalMonitorForEvents(matching: .leftMouseUp) { _ in
            guard hit.contains(NSEvent.mouseLocation) else { return }
            NSApp.activate(ignoringOtherApps: true)
            DispatchQueue.main.async { menu.popUp(positioning: nil, at: CGPoint(x: hit.minX, y: hit.minY), in: nil) }
        }

        scan()
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

// MARK: - Self-check

func selfTest() -> Never {
    let size = 256
    let context = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0,
                            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    context.setFillColor(.white)
    context.fill(CGRect(x: 0, y: 0, width: size, height: size))
    context.setFillColor(.black)
    context.fillEllipse(in: CGRect(x: 20, y: 60, width: 90, height: 120))  // left half: a blob
    for y in stride(from: 0, to: size, by: 16) { context.fill(CGRect(x: 128, y: y, width: 128, height: 8)) }  // right half: stripes
    let handler = VNImageRequestHandler(cgImage: context.makeImage()!)
    let left = CGRect(x: 0, y: 0, width: 0.5, height: 1), right = CGRect(x: 0.5, y: 0, width: 0.5, height: 1)
    guard let a = featurePrint(handler, roi: left), let again = featurePrint(handler, roi: left),
          let b = featurePrint(handler, roi: right) else { fatalError("no feature print") }
    precondition(distance(a, again) < 0.01, "the same crop must match itself")
    precondition(distance(a, b) > 0.1, "regionOfInterest must change the print")
    let back = try! PropertyListDecoder().decode([[Float]].self, from: PropertyListEncoder().encode([a]))
    precondition(back == [a], "a saved print must load back unchanged")
    precondition(distance(a, [0]) == .infinity, "prints of different sizes must never match")
    print("selftest ok (distance between unrelated crops: \(distance(a, b)))")
    exit(0)
}

if CommandLine.arguments.contains("--selftest") { selfTest() }
let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.run()
