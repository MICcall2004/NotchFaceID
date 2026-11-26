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
/// The menu and `defaults write` move the bars for the menu's own scans, but never past these: any process of this
/// user can write UserDefaults. 0.64 is about SFace's own decision point (cosine 0.363).
/// sudo and screen unlock never go looser than defaultThreshold and defaultLive.
let thresholdCeiling: Float = 0.64
let liveFloor: Float = 0.3
private let builtInTransport = Int32(bitPattern: 0x626C_746E)  // 'bltn', kIOAudioDeviceTransportTypeBuiltIn

/// Frame counts for one scan or enrollment.
struct ScanTally {
    var hits = 0, spoofs = 0, streak = 0

    /// A fake-looking frame counts even when it does not match, and breaks the run of good frames.
    mutating func add(match: Bool, live: Bool) {
        if !live { spoofs += 1; streak = 0 } else if match { hits += 1; streak += 1 } else { streak = 0 }
    }

    /// `matchFrames` live matching frames in a row, and live frames outnumber fake-looking ones two to one,
    /// so a replay that fools the spoof model now and then still fails.
    var passed: Bool { streak >= matchFrames && spoofs * 2 < hits }
}

/// The enrolled embeddings on disk. The one place that decides where they live.
struct TemplateStore {
    static let model = "SFace-2021dec"
    /// The user's own copy, which enrollment writes and the menu's scans read.
    var url = TemplateStoragePolicy.userTemplateURL

    /// The root-owned copy Scripts/install-sudo.sh promotes, the only one sudo and screen unlock may use.
    /// Empty unless it is tamper-protected. Read it fresh each time, so a copy installed while the app runs counts.
    static var protected: [[Float]] {
        TemplateStoragePolicy.isTamperProtected(TemplateStoragePolicy.systemTemplateURL)
            ? TemplateStore(url: TemplateStoragePolicy.systemTemplateURL).load() : []
    }

    private struct File: Codable { var model: String; var embeddings: [[Float]] }

    /// Empty when nothing is enrolled or the file is from another model (the old feature prints), which forces a re-enroll.
    func load() -> [[Float]] {
        guard let data = try? Data(contentsOf: url), let file = try? PropertyListDecoder().decode(File.self, from: data),
              file.model == Self.model else { return [] }
        // Any process of this user can write the user's copy, and install-sudo.sh promotes it: a long vector would
        // make distance() negative and match anyone, so keep only finite SFace-sized vectors, scaled to unit length.
        return file.embeddings.compactMap { e in
            let norm = e.reduce(0) { $0 + $1 * $1 }.squareRoot()
            return e.count == 128 && norm.isFinite && norm > 0 ? e.map { $0 / norm } : nil
        }
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
    private var system = false  // this scan is for sudo or screen unlock
    private var run = 0
    private var enrolled: [[Float]] = []  // loaded from disk when each scan starts
    private var centroid: [Float] = []    // recorded only, to compare against the nearest template
    private var samples: [[Float]] = []
    private var lastSample = Date.distantPast
    private var best = Float.infinity
    private var tally = ScanTally()
    private var done: ((AuthResult) -> Void)?
    private var shown = 0  // main thread: which show() may close the notch

    init(ui: UI) {
        self.ui = ui
        UserDefaults.standard.register(defaults: ["threshold": defaultThreshold, "live": defaultLive, "recordFrames": false])
    }

    /// The menu's own enrollment, in the user's copy.
    var isEnrolled: Bool { !store.load().isEmpty }
    /// What sudo and screen unlock match against.
    var canAuthenticate: Bool { !TemplateStore.protected.isEmpty }

    /// Deletes the user's copy. Returns false when the protected copy sudo uses is still installed.
    func reset() -> Bool {
        store.delete()
        return !FileManager.default.fileExists(atPath: TemplateStoragePolicy.systemTemplateURL.path)
    }

    /// Main thread. For sudo and screen unlock: matches only the protected copy, at the default bars or stricter.
    /// Shows `reason` in the notch, scans once, and calls `completion` on main.
    func authenticate(reason: String, timeout: TimeInterval, completion: @escaping (AuthResult) -> Void) {
        guard ui.phase != .scanning, ui.phase != .enrolling else { return completion(.busy) }
        guard canAuthenticate else { return completion(.notEnrolled) }
        start(.scanning, text: reason, timeout: timeout, system: true, done: completion)
    }

    /// Call on main with `.scanning` or `.enrolling`. `done` gets the result on main.
    func start(_ phase: Phase, text: String? = nil, timeout: TimeInterval? = nil, system: Bool = false, done: ((AuthResult) -> Void)? = nil) {
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
                    self.tally = ScanTally()
                    self.system = system
                    if phase == .scanning {
                        // Read now, not at launch, so the latest enrollment or install counts.
                        self.enrolled = system ? TemplateStore.protected : self.store.load()
                        let sum = self.enrolled.reduce(into: [Float](repeating: 0, count: self.enrolled.first?.count ?? 0)) { s, e in s = zip(s, e).map(+) }
                        let norm = sum.reduce(0) { $0 + $1 * $1 }.squareRoot()
                        self.centroid = norm > 0 ? sum.map { $0 / norm } : []
                    }
                    self.done = done
                    self.run += 1
                    let run = self.run
                    // The timeout is a timer, not a frame check, so a camera that delivers nothing still ends.
                    self.frames.asyncAfter(deadline: .now() + (timeout ?? (phase == .enrolling ? 15 : 4))) {
                        guard self.run == run, self.mode != .idle else { return }
                        let found = phase == .enrolling ? self.samples.count : self.tally.hits
                        if self.tally.spoofs > found { self.finish(.spoof, "사진이나 화면으로 의심됨") }
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
        // NaN or junk in UserDefaults fails closed: every comparison with NaN is false.
        let live = face.live >= max(UserDefaults.standard.float(forKey: "live"), system ? defaultLive : liveFloor)

        if mode == .scanning {
            let d = enrolled.map { distance(face.embedding, $0) }.min() ?? .infinity
            best = min(best, d)
            let match = d <= min(UserDefaults.standard.float(forKey: "threshold"), system ? defaultThreshold : thresholdCeiling)
            tally.add(match: match, live: live)
            FrameLog.frame(run: run, mode: mode, face, distance: d, centroid: distance(face.embedding, centroid),
                           verdict: !live ? "spoof" : match ? "match" : "nomatch")
            if tally.passed { finish(.success, "인식 완료") }
        } else if !live {
            tally.spoofs += 1  // a photo must not become the enrolled face
            FrameLog.frame(run: run, mode: mode, face, distance: nil, centroid: nil, verdict: "spoof")
        } else if Date().timeIntervalSince(lastSample) <= 0.25 {  // spaced out so the samples cover head movement
            FrameLog.frame(run: run, mode: mode, face, distance: nil, centroid: nil, verdict: "skip")
        } else {
            lastSample = Date()
            FrameLog.frame(run: run, mode: mode, face, distance: nil, centroid: nil, verdict: "sample")
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
        UserDefaults.standard.set(defaultThreshold, forKey: "threshold")  // re-enrolling undoes earlier menu tuning
        let installed = FileManager.default.fileExists(atPath: TemplateStoragePolicy.systemTemplateURL.path)
        finish(.success, installed ? "등록 완료 · sudo용은 install-sudo.sh로 갱신" : "등록 완료")
    }

    /// Ends the current scan or enrollment. Frames queue.
    private func finish(_ result: AuthResult, _ text: String) {
        if mode == .scanning {
            let best = best
            DispatchQueue.main.async { self.ui.last = best }
        }
        FrameLog.end(run: run, mode: mode, result: result)
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
            self.shown += 1
            let shown = self.shown
            // Only the latest message closes the notch, not an earlier one that showed the same phase.
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) { if self.shown == shown, ui.phase == phase { ui.phase = .idle } }
        }
    }
}
