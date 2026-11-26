// Opt-in per-frame scores, for tuning the match and spoof bars on this Mac's camera (Tools/eval/README.md).
// Numbers only: never images or embeddings. On when the "recordFrames" setting is true.
import Foundation

enum FrameLog {
    static let url = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("NotchFaceID/frames.csv")
    static let columns = "time,run,mode,distance,centroid,v2Live,v1seLive,live,width,aspect,yaw,roll,eyes,verdict"

    /// One camera frame. `verdict` is what the engine did with it: match, nomatch, spoof, sample, skip.
    static func frame(run: Int, mode: Phase, _ r: FaceReading, distance: Float?, centroid: Float?, verdict: String) {
        let n = { (x: Float?) in x.map { String(format: "%.4f", $0) } ?? "" }
        add([run.description, "\(mode)", n(distance), n(centroid), n(r.lives.first), n(r.lives.last), n(r.live),
             n(Float(r.box.width)), n(Float(r.box.height / r.box.width)), n(Float(r.yaw)), n(Float(r.roll)), n(r.eyes), verdict])
    }

    /// The end of a scan or enrollment, with its result.
    static func end(run: Int, mode: Phase, result: AuthResult) {
        add([run.description, "\(mode)"] + Array(repeating: "", count: 10) + [result.rawValue])
    }

    /// Opens and closes the file per row, so deleting it while recording starts a fresh one.
    private static func add(_ fields: [String]) {
        guard UserDefaults.standard.bool(forKey: "recordFrames") else { return }
        let files = FileManager.default
        if !files.fileExists(atPath: url.path) {
            try? files.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            files.createFile(atPath: url.path, contents: Data((columns + "\n").utf8), attributes: [.posixPermissions: 0o600])
        }
        guard let file = try? FileHandle(forWritingTo: url) else { return }
        defer { try? file.close() }
        _ = try? file.seekToEnd()
        let row = [String(format: "%.3f", Date().timeIntervalSince1970)] + fields
        try? file.write(contentsOf: Data((row.joined(separator: ",") + "\n").utf8))
    }
}
