// Face matching accuracy on LFW, the new pipeline against the old generic feature print.
// build/NotchFaceID.app/Contents/MacOS/NotchFaceID --eval <lfw-dir> <pairs.txt>   (see Tools/eval/README.md)
import CoreImage
import Vision

/// The old matcher (generic image feature print of the face box), kept only as the baseline. Higher = more alike.
private func oldScore(_ a: [Float]?, _ b: [Float]?) -> Float {
    guard let a, let b, a.count == b.count else { return -.infinity }
    return -zip(a, b).reduce(0) { $0 + ($1.0 - $1.1) * ($1.0 - $1.1) }.squareRoot()
}

private func oldPrint(_ handler: VNImageRequestHandler) -> [Float]? {
    let detect = VNDetectFaceRectanglesRequest()
    try? handler.perform([detect])
    guard let face = detect.results?.min(by: { hypot($0.boundingBox.midX - 0.5, $0.boundingBox.midY - 0.5) < hypot($1.boundingBox.midX - 0.5, $1.boundingBox.midY - 0.5) })
    else { return nil }
    let request = VNGenerateImageFeaturePrintRequest()
    request.regionOfInterest = face.boundingBox.intersection(CGRect(x: 0, y: 0, width: 1, height: 1))
    try? handler.perform([request])
    guard let print = request.results?.first, print.elementType == .float else { return nil }
    return print.data.withUnsafeBytes { Array($0.bindMemory(to: Float.self)) }
}

/// SplitMix64: a seeded generator, so the extra impostor pairs are the same on every run.
private struct Seeded: RandomNumberGenerator {
    var state: UInt64
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}

/// Accuracy at the best threshold on the official pairs, and the share of genuine pairs accepted
/// at a threshold that lets through the given share of impostors (official + extra pairs).
private func report(_ name: String, genuine: [Float], impostor: [Float], extra: [Float]) {
    let total = Float(genuine.count + impostor.count)
    let best = (genuine + impostor).filter(\.isFinite).map { t in
        (t, Float(genuine.filter { $0 >= t }.count + impostor.filter { $0 < t }.count) / total)
    }.max { $0.1 < $1.1 } ?? (0, 0)
    print(String(format: "%@  accuracy %.4f (threshold %.3f)", name, best.1, best.0))
    let impostors = (impostor + extra).sorted(by: >)
    for far in [1e-2, 1e-3, 1e-4] as [Float] {
        let index = Int(far * Float(impostors.count))
        guard index < impostors.count else { continue }
        let t = impostors[index]
        print(String(format: "   FAR %.2f%%: TAR %.4f (threshold %.3f, %d impostor pairs)", far * 100,
                     Float(genuine.filter { $0 > t }.count) / Float(genuine.count), t, impostors.count))
    }
}

func runEval(lfw: URL, pairs: URL) -> Never {
    guard FaceModels.available else { fatalError("face models missing from the app bundle: run ./build.sh") }
    let image = { (name: String, n: String) in lfw.appendingPathComponent("\(name)/\(name)_\(String(format: "%04d", Int(n) ?? 0)).jpg") }
    let fields = (try! String(contentsOf: pairs, encoding: .utf8)).split(whereSeparator: \.isNewline).dropFirst()
        .map { $0.split(whereSeparator: \.isWhitespace).map(String.init) }
    let list: [(URL, URL, Bool)] = fields.compactMap { f in
        f.count == 3 ? (image(f[0], f[1]), image(f[0], f[2]), true) : f.count == 4 ? (image(f[0], f[1]), image(f[2], f[3]), false) : nil
    }
    precondition(list.count == 6000, "pairs.txt should list 6000 pairs, got \(list.count)")

    var new: [URL: [Float]] = [:], old: [URL: [Float]] = [:], missed = Set<URL>()
    let files = Set(list.flatMap { [$0.0, $0.1] }).sorted { $0.path < $1.path }
    for (i, url) in files.enumerated() {
        autoreleasepool {  // without it, frames and buffers pile up until model runs start failing
            guard let ci = CIImage(contentsOf: url) else { missed.insert(url); return }
            let handler = VNImageRequestHandler(ciImage: ci)
            if let reading = FaceModels.read(ci, handler: handler, central: true, frontalOnly: false) { new[url] = reading.embedding } else { missed.insert(url) }
            old[url] = oldPrint(handler)
        }
        if i % 1000 == 0 { print("\(i)/\(files.count) images") }
    }
    print("\(files.count) images, no usable face in \(missed.count) (counted as a rejection)")

    // Extra impostors: random pairs of different people among the same images, for a FAR below 1/3000.
    var random = Seeded(state: 42)
    let person = { (u: URL) in u.deletingLastPathComponent().lastPathComponent }
    var extraNew: [Float] = [], extraOld: [Float] = []
    while extraNew.count < 300_000 {
        let a = files.randomElement(using: &random)!, b = files.randomElement(using: &random)!
        guard person(a) != person(b) else { continue }
        extraNew.append(new[a].flatMap { x in new[b].map { 1 - distance(x, $0) } } ?? -.infinity)
        extraOld.append(oldScore(old[a], old[b]))
    }
    let score = { (u: URL, v: URL) in new[u].flatMap { x in new[v].map { 1 - distance(x, $0) } } ?? -.infinity }
    report("new (SFace, cosine)", genuine: list.filter(\.2).map { score($0.0, $0.1) },
           impostor: list.filter { !$0.2 }.map { score($0.0, $0.1) }, extra: extraNew)
    report("old (feature print, −distance)", genuine: list.filter(\.2).map { oldScore(old[$0.0], old[$0.1]) },
           impostor: list.filter { !$0.2 }.map { oldScore(old[$0.0], old[$0.1]) }, extra: extraOld)
    exit(0)
}
