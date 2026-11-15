// NotchFaceID: Face ID-style face matcher that animates out of the MacBook notch.
// Entry point and the --selftest self-check. Build: ./build.sh
import AppKit
import Vision

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
