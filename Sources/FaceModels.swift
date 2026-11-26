// The Core ML face models: SFace identity embedding and MiniFASNet photo/screen detection.
// Converted by Tools/models/convert.py; licenses in Resources/Models/LICENSES.md.
import CoreImage
import CoreML
import Vision

/// What one camera frame says about the face in it.
struct FaceReading {
    let embedding: [Float]  // unit length
    let lives: [Float]      // per spoof model, 0...1, chance the face is real and not a photo or screen
    let box: CGRect         // pixels, bottom-left origin
    let yaw: Double, roll: Double  // radians, in Vision's 45° steps
    let eyes: Float?        // eye height over width, both eyes averaged; drops during a blink
    var live: Float { lives.reduce(0, +) / Float(lives.count) }  // averaged over both models, as the original test.py does
}

enum FaceModels {
    static let sface = load("SFace")
    static let spoof = [(load("MiniFASNetV2"), 2.7 as CGFloat), (load("MiniFASNetV1SE"), 4.0 as CGFloat)]  // model, crop scale

    static func load(_ name: String) -> MLModel? {
        guard let url = Bundle.main.url(forResource: name, withExtension: "mlmodelc", subdirectory: "Models") else { return nil }
        return try? MLModel(contentsOf: url)
    }

    static var available: Bool { sface != nil && spoof.allSatisfy { $0.0 != nil } }

    static func run(_ model: MLModel?, _ buffer: CVPixelBuffer?) -> [Float]? {
        guard let model, let buffer,
              let out = try? model.prediction(from: MLDictionaryFeatureProvider(dictionary: ["image": MLFeatureValue(pixelBuffer: buffer)])),
              let array = out.featureValue(for: "output")?.multiArrayValue else { return nil }
        return (0..<array.count).map { array[$0].floatValue }
    }

    static func embedding(_ image: CIImage, points: [CGPoint]) -> [Float]? {
        guard let v = run(sface, alignedFace(image, points: points)) else { return nil }
        let norm = v.reduce(0) { $0 + $1 * $1 }.squareRoot()
        return norm > 0 ? v.map { $0 / norm } : nil
    }

    /// The real-face probability from each spoof model, in `spoof` order. Class 1 is "real".
    static func liveness(_ image: CIImage, box: CGRect) -> [Float]? {
        var lives: [Float] = []
        for (model, scale) in spoof {
            guard let logits = run(model, spoofPatch(image, face: box, scale: scale)), logits.count == 3 else { return nil }
            let top = logits.max()!, exps = logits.map { exp($0 - top) }
            lives.append(exps[1] / exps.reduce(0, +))
        }
        return lives
    }

    /// Reads the chosen face in `image`: the largest one, or with `central` the one nearest the centre (photos).
    /// Nil when there is no face, it is too small, turned away (unless not `frontalOnly`), or a model is missing.
    static func read(_ image: CIImage, handler: VNImageRequestHandler, central: Bool = false, frontalOnly: Bool = true, minWidth: CGFloat = 0.12) -> FaceReading? {
        let request = VNDetectFaceLandmarksRequest()
        try? handler.perform([request])
        // Vision gives points and boxes from (0, 0), so move the image there to match.
        let image = image.transformed(by: CGAffineTransform(translationX: -image.extent.minX, y: -image.extent.minY))
        let size = image.extent.size
        let mid = CGPoint(x: 0.5, y: 0.5)
        let gap = { (f: VNFaceObservation) in hypot(f.boundingBox.midX - mid.x, f.boundingBox.midY - mid.y) }
        guard let faces = request.results, let face = central ? faces.min(by: { gap($0) < gap($1) }) : faces.max(by: { $0.boundingBox.width < $1.boundingBox.width }),
              face.boundingBox.width > minWidth,
              // Vision reports roll and yaw in 45° steps (0, ±π/4, ...), so this keeps only faces it calls frontal.
              !frontalOnly || (abs(face.roll?.doubleValue ?? 0) < 0.35 && abs(face.yaw?.doubleValue ?? 0) < 0.6),
              let points = fivePoints(face, size: size) else { return nil }
        let box = VNImageRectForNormalizedRect(face.boundingBox, Int(size.width), Int(size.height))
        guard let embedding = embedding(image, points: points), let lives = liveness(image, box: box) else { return nil }
        return FaceReading(embedding: embedding, lives: lives, box: box, yaw: face.yaw?.doubleValue ?? 0, roll: face.roll?.doubleValue ?? 0,
                           eyes: eyeOpenness(face, size: size, along: points[1] - points[0]))
    }

    /// Eye contour height over width, measured across and along the eye line so a tilted head reads the same.
    private static func eyeOpenness(_ face: VNFaceObservation, size: CGSize, along line: CGPoint) -> Float? {
        let length = hypot(line.x, line.y)
        guard length > 0, let marks = face.landmarks else { return nil }
        let (u, v) = (CGPoint(x: line.x / length, y: line.y / length), CGPoint(x: -line.y / length, y: line.x / length))
        let ratios = [marks.leftEye, marks.rightEye].compactMap { eye -> CGFloat? in
            guard let points = eye?.pointsInImage(imageSize: size), points.count > 2 else { return nil }
            let a = points.map { $0.x * u.x + $0.y * u.y }, b = points.map { $0.x * v.x + $0.y * v.y }
            let width = a.max()! - a.min()!
            return width > 0 ? (b.max()! - b.min()!) / width : nil
        }
        return ratios.count == 2 ? Float(ratios.reduce(0, +) / 2) : nil
    }
}

private func - (a: CGPoint, b: CGPoint) -> CGPoint { CGPoint(x: a.x - b.x, y: a.y - b.y) }

/// 1 − cosine similarity of unit vectors: 0 is identical, 2 is opposite. Different lengths never match.
func distance(_ a: [Float], _ b: [Float]) -> Float {
    guard a.count == b.count else { return .infinity }
    return 1 - zip(a, b).reduce(0) { $0 + $1.0 * $1.1 }
}
