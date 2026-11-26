// NotchFaceID: Face ID-style face matcher that animates out of the MacBook notch.
// Entry point and the --selftest self-check. Build: ./build.sh
import AppKit
import CoreImage

func selfTest() -> Never {
    precondition(FaceModels.available, "the face models must load from the app bundle")
    // similarity() must exactly undo a known rotation, scale and shift.
    let known = CGAffineTransform(rotationAngle: 0.3).scaledBy(x: 1.7, y: 1.7).translatedBy(x: 12, y: -5)
    let moved = sfaceTemplate.map { $0.applying(known) }
    let back = similarity(from: moved, to: sfaceTemplate)
    for (p, q) in zip(moved.map { $0.applying(back) }, sfaceTemplate) {
        precondition(hypot(p.x - q.x, p.y - q.y) < 1e-6, "similarity() must undo a known warp")
    }
    // The models run on a frame-sized image and give the shapes the matcher relies on.
    let gray = CIImage(color: CIColor(red: 0.5, green: 0.5, blue: 0.5)).cropped(to: CGRect(x: 0, y: 0, width: 640, height: 480))
    guard let e = FaceModels.embedding(gray, points: moved),
          let live = FaceModels.liveness(gray, box: CGRect(x: 250, y: 150, width: 140, height: 160)) else { fatalError("a face model did not run") }
    precondition(e.count == 128 && abs(distance(e, e)) < 1e-4, "SFace must give a 128-d unit vector")
    precondition((0...1).contains(live), "liveness must be a probability")
    precondition(distance(e, [0]) == .infinity, "embeddings of different sizes must never match")
    precondition(scanPassed(hits: 3, spoofs: 1) && !scanPassed(hits: 2, spoofs: 0) && !scanPassed(hits: 4, spoofs: 2), "scan rule")
    // Templates load back unchanged, and a file from the old matcher counts as not enrolled.
    var store = TemplateStore()
    store.url = FileManager.default.temporaryDirectory.appendingPathComponent("notchfaceid-selftest-\(getpid())")
    store.saveURL = store.url
    try! store.save([e])
    precondition(store.load() == [e], "a saved template must load back unchanged")
    try! PropertyListEncoder().encode([[Float(1)]]).write(to: store.url)
    precondition(store.load().isEmpty, "old feature prints must force a re-enroll")
    store.delete()
    AuthServer.runSelfTest()
    print("selftest ok (liveness of a gray frame: \(live))")
    exit(0)
}

if CommandLine.arguments.contains("--selftest") { selfTest() }
if let i = CommandLine.arguments.firstIndex(of: "--eval"), CommandLine.arguments.count > i + 2 {
    runEval(lfw: URL(fileURLWithPath: CommandLine.arguments[i + 1]), pairs: URL(fileURLWithPath: CommandLine.arguments[i + 2]))
}
let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.run()
