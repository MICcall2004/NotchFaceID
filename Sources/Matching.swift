// Camera capture, enrollment, matching, and authenticate() for system sign-in.
import AVFoundation
import CoreImage
import Vision

enum AuthResult: String, Codable { case success, failure, spoof, noFace, notEnrolled, busy, cameraUnavailable }

let enrollCount = 10
/// Matching frames a scan needs, each from the live camera, before it passes.
let matchFrames = 3
/// Pass when 1 − cosine(SFace) ≤ this. From the LFW evaluation (Tools/eval/README.md): cosine 0.431 lets in
/// 0.01% of impostor frames and 97.9% of genuine pairs there. Webcam frames differ from LFW photos, so recheck on real use.
let defaultThreshold: Float = 0.57
/// A frame counts as a real face when MiniFASNet's real-face probability is at least this.
/// shortcut: 0.5 is the model's own decision point, not tuned on this Mac's camera; tune with real and spoof captures.
let defaultLive: Float = 0.5
private let builtInTransport = Int32(bitPattern: 0x626C_746E)  // 'bltn', kIOAudioDeviceTransportTypeBuiltIn

/// Live frames must outnumber fake-looking ones two to one, so a replay that fools the spoof model now and then still fails.
func scanPassed(hits: Int, spoofs: Int) -> Bool { hits >= matchFrames && spoofs * 2 < hits }

/// The enrolled embeddings on disk. The one place that decides where they live.
struct TemplateStore {
    static let model = "SFace-2021dec"
    var url = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("NotchFaceID/faces")

    private struct File: Codable { var model: String; var embeddings: [[Float]] }

    /// Empty when nothing is enrolled or the file is from another model (the old feature prints), which forces a re-enroll.
    func load() -> [[Float]] {
        guard let data = try? Data(contentsOf: url), let file = try? PropertyListDecoder().decode(File.self, from: data),
              file.model == Self.model else { return [] }
        return file.embeddings
    }

    func save(_ embeddings: [[Float]]) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try PropertyListEncoder().encode(File(model: Self.model, embeddings: embeddings)).write(to: url, options: .atomic)
    }

    func delete() { try? FileManager.default.removeItem(at: url) }
}

final class Engine: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate {
    let ui: UI
    let store = TemplateStore()
    private let session = AVCaptureSession()
    private let control = DispatchQueue(label: "control")  // startRunning/stopRunning block: keep them off main and off the frame queue
    private let frames = DispatchQueue(label: "frames")    // owns every var below
    private var mode = Phase.idle
    private var run = 0
    private var enrolled: [[Float]]
    private var samples: [[Float]] = []
    private var lastSample = Date.distantPast
    private var best = Float.infinity
    private var hits = 0, spoofs = 0
    private var done: ((AuthResult) -> Void)?

    init(ui: UI) {
        self.ui = ui
        enrolled = store.load()
        UserDefaults.standard.register(defaults: ["threshold": defaultThreshold, "live": defaultLive])
    }

    var isEnrolled: Bool { frames.sync { !enrolled.isEmpty } }

    func reset() {
        frames.sync { enrolled = [] }
        store.delete()
    }

    /// Main thread. Shows `reason` in the notch, scans once, and calls `completion` on main.
    func authenticate(reason: String, timeout: TimeInterval, completion: @escaping (AuthResult) -> Void) {
        guard ui.phase != .scanning, ui.phase != .enrolling else { return completion(.busy) }
        guard isEnrolled else { return completion(.notEnrolled) }
        start(.scanning, text: reason, timeout: timeout, done: completion)
    }

    /// Call on main with `.scanning` or `.enrolling`. `done` gets the result on main.
    func start(_ phase: Phase, text: String? = nil, timeout: TimeInterval? = nil, done: ((AuthResult) -> Void)? = nil) {
        ui.progress = 0
        ui.text = text ?? (phase == .enrolling ? "고개를 천천히 움직이세요" : "얼굴 인식 중")
        ui.phase = phase
        guard FaceModels.available else { return abort(done, .failure, "얼굴 모델을 불러오지 못함") }
        AVCaptureDevice.requestAccess(for: .video) { granted in
            guard granted else { return self.abort(done, .cameraUnavailable, "시스템 설정에서 카메라 권한 허용 필요") }
            self.control.async {
                if self.session.inputs.isEmpty {
                    // Built-in camera only: an iPhone (Continuity Camera) or a virtual camera could feed in any video.
                    guard let camera = AVCaptureDevice.DiscoverySession(deviceTypes: [.builtInWideAngleCamera], mediaType: .video, position: .unspecified)
                            .devices.first(where: { $0.transportType == builtInTransport }),
                          let input = try? AVCaptureDeviceInput(device: camera), self.session.canAddInput(input)
                    else { return self.abort(done, .cameraUnavailable, "내장 카메라를 찾을 수 없음") }
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
                    (self.hits, self.spoofs) = (0, 0)
                    self.done = done
                    self.run += 1
                    let run = self.run
                    // The timeout is a timer, not a frame check, so a camera that delivers nothing still ends.
                    self.frames.asyncAfter(deadline: .now() + (timeout ?? (phase == .enrolling ? 15 : 4))) {
                        guard self.run == run, self.mode != .idle else { return }
                        let found = phase == .enrolling ? self.samples.count : self.hits
                        if self.spoofs > found { self.finish(.spoof, "사진이나 화면으로 의심됨") }
                        else if phase == .scanning && self.best.isFinite { self.finish(.failure, "인식 실패") }
                        else { self.finish(.noFace, "얼굴을 찾지 못함") }
                    }
                }
            }
        }
    }

    func captureOutput(_ output: AVCaptureOutput, didOutput buffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        // Each frame makes several buffers and model outputs; without a pool they pile up and model runs start failing.
        autoreleasepool { handle(buffer) }
    }

    private func handle(_ buffer: CMSampleBuffer) {
        guard mode != .idle, let pixels = CMSampleBufferGetImageBuffer(buffer),
              let face = FaceModels.read(CIImage(cvPixelBuffer: pixels), handler: VNImageRequestHandler(cvPixelBuffer: pixels))
        else { return }
        let live = face.live >= UserDefaults.standard.float(forKey: "live")

        if mode == .scanning {
            let d = enrolled.map { distance(face.embedding, $0) }.min() ?? .infinity
            best = min(best, d)
            guard d <= UserDefaults.standard.float(forKey: "threshold") else { return }
            if live { hits += 1 } else { spoofs += 1 }
            if scanPassed(hits: hits, spoofs: spoofs) { finish(.success, "인식 완료") }
        } else if !live {
            spoofs += 1  // a photo must not become the enrolled face
        } else if Date().timeIntervalSince(lastSample) > 0.25 {  // spaced out so the samples cover head movement
            lastSample = Date()
            samples.append(face.embedding)
            let done = Double(samples.count) / Double(enrollCount)
            DispatchQueue.main.async { self.ui.progress = done }
            if samples.count == enrollCount { saveEnrollment() }
        }
    }

    private func saveEnrollment() {
        // Drop frames that disagree with the rest (motion blur, someone walking past): they would widen who matches.
        let kept = samples.filter { s in samples.map { distance(s, $0) }.reduce(0, +) / Float(samples.count - 1) <= defaultThreshold }
        guard kept.count >= enrollCount / 2 else { return finish(.failure, "다시 등록하세요") }
        do {
            try store.save(kept)
        } catch {
            return finish(.failure, "저장 실패")
        }
        enrolled = kept
        UserDefaults.standard.set(defaultThreshold, forKey: "threshold")  // re-enrolling undoes earlier menu tuning
        finish(.success, "등록 완료")
    }

    /// Ends the current scan or enrollment. Frames queue.
    private func finish(_ result: AuthResult, _ text: String) {
        if mode == .scanning {
            let best = best
            DispatchQueue.main.async { self.ui.last = best }
        }
        mode = .idle
        let done = done
        self.done = nil
        control.async { self.session.stopRunning() }
        show(result == .success ? .success : .fail, text)
        DispatchQueue.main.async { done?(result) }
    }

    /// Ends before any frame was read. Any thread.
    private func abort(_ done: ((AuthResult) -> Void)?, _ result: AuthResult, _ text: String) {
        show(.notice, text)
        DispatchQueue.main.async { done?(result) }
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
