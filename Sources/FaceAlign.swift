// Turns a camera frame and a detected face into the exact crops the face models were trained on.
// Coordinates are pixels with Core Image's bottom-left origin throughout.
import CoreImage
import CoreVideo
import Vision

/// Where SFace expects eye, eye, nose tip, mouth corner, mouth corner in its 112x112 input
/// (OpenCV FaceRecognizerSF::alignCrop), with y flipped to a bottom-left origin.
let sfaceTemplate = [(38.2946, 51.6963), (73.5318, 51.5014), (56.0252, 71.7366), (41.5493, 92.3655), (70.7299, 92.2041)]
    .map { CGPoint(x: $0.0, y: 112 - $0.1) }

/// The five SFace landmarks, image-left before image-right. Nil when Vision found no landmarks.
func fivePoints(_ face: VNFaceObservation, size: CGSize) -> [CGPoint]? {
    guard let marks = face.landmarks,
          let p = marks.leftPupil?.pointsInImage(imageSize: size).first,
          let q = marks.rightPupil?.pointsInImage(imageSize: size).first,
          let crest = marks.noseCrest?.pointsInImage(imageSize: size), !crest.isEmpty,
          let lips = marks.outerLips?.pointsInImage(imageSize: size), !lips.isEmpty else { return nil }
    let (eyeA, eyeB) = p.x < q.x ? (p, q) : (q, p)
    // Mouth corners are the lip points furthest along the eye line, so a tilted head still gets the true corners.
    let along = { (r: CGPoint) in (r.x - eyeA.x) * (eyeB.x - eyeA.x) + (r.y - eyeA.y) * (eyeB.y - eyeA.y) }
    let mouthA = lips.min { along($0) < along($1) }!, mouthB = lips.max { along($0) < along($1) }!
    let mouth = CGPoint(x: (mouthA.x + mouthB.x) / 2, y: (mouthA.y + mouthB.y) / 2)
    // The crest runs from the bridge down to the tip: the tip is its end nearest the mouth.
    let nose = crest.min { hypot($0.x - mouth.x, $0.y - mouth.y) < hypot($1.x - mouth.x, $1.y - mouth.y) }!
    return [eyeA, eyeB, nose, mouthA, mouthB]
}

/// Least-squares rotation + uniform scale + translation (no reflection) taking `from` onto `to` (Umeyama, 2-D closed form).
func similarity(from: [CGPoint], to: [CGPoint]) -> CGAffineTransform {
    let n = CGFloat(from.count)
    let ms = CGPoint(x: from.map(\.x).reduce(0, +) / n, y: from.map(\.y).reduce(0, +) / n)
    let md = CGPoint(x: to.map(\.x).reduce(0, +) / n, y: to.map(\.y).reduce(0, +) / n)
    var a: CGFloat = 0, b: CGFloat = 0, v: CGFloat = 0
    for (s, d) in zip(from, to) {
        let (sx, sy, dx, dy) = (s.x - ms.x, s.y - ms.y, d.x - md.x, d.y - md.y)
        a += sx * dx + sy * dy
        b += sx * dy - sy * dx
        v += sx * sx + sy * sy
    }
    let (c, s) = (a / v, b / v)  // scale·cos, scale·sin
    return CGAffineTransform(a: c, b: s, c: -s, d: c, tx: md.x - (c * ms.x - s * ms.y), ty: md.y - (s * ms.x + c * ms.y))
}

private let context = CIContext(options: [.workingColorSpace: NSNull(), .outputColorSpace: NSNull()])  // raw pixel values, like OpenCV

/// Renders the square [0, size)² of `image` into a new BGRA buffer, which Core ML image inputs accept.
func render(_ image: CIImage, size: Int) -> CVPixelBuffer? {
    var buffer: CVPixelBuffer?
    CVPixelBufferCreate(nil, size, size, kCVPixelFormatType_32BGRA, [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary, &buffer)
    guard let buffer else { return nil }
    context.render(image, to: buffer, bounds: CGRect(x: 0, y: 0, width: size, height: size), colorSpace: nil)
    return buffer
}

/// The 112x112 face SFace embeds: landmarks warped onto the template.
func alignedFace(_ image: CIImage, points: [CGPoint]) -> CVPixelBuffer? {
    let origin = CGAffineTransform(translationX: -image.extent.minX, y: -image.extent.minY)
    let shifted = points.map { $0.applying(origin) }
    return render(image.transformed(by: origin.concatenating(similarity(from: shifted, to: sfaceTemplate))), size: 112)
}

/// The 80x80 patch MiniFASNet classifies: the face box grown `scale` times around its centre, kept inside the frame,
/// then stretched to a square (CropImage._get_new_box in Silent-Face-Anti-Spoofing).
func spoofPatch(_ image: CIImage, face box: CGRect, scale wanted: CGFloat) -> CVPixelBuffer? {
    let frame = image.extent
    let scale = min((frame.height - 1) / box.height, (frame.width - 1) / box.width, wanted)
    var patch = CGRect(x: box.midX - box.width * scale / 2, y: box.midY - box.height * scale / 2,
                       width: box.width * scale, height: box.height * scale)
    patch.origin.x = min(max(patch.minX, frame.minX), frame.maxX - 1 - patch.width)
    patch.origin.y = min(max(patch.minY, frame.minY), frame.maxY - 1 - patch.height)
    let fit = CGAffineTransform(translationX: -patch.minX, y: -patch.minY).concatenating(CGAffineTransform(scaleX: 80 / patch.width, y: 80 / patch.height))
    return render(image.transformed(by: fit), size: 80)
}
