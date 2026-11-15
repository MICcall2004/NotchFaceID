// Camera capture and face matching.
import AVFoundation
import Vision

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
