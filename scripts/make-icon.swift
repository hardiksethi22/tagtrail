import AppKit
import CoreGraphics

// Builds a macOS .icns from the square brand artwork in Assets/. macOS
// (Big Sur and later) renders the icon as-is, so the corners must be
// transparent: this masks the artwork with the system's continuous-corner
// squircle and writes the standard icon set.

let root = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
let source = root.appendingPathComponent("Assets/tagtrail-logo.jpg")
let output = root.appendingPathComponent("Assets/TagTrail.icns")
let work = FileManager.default.temporaryDirectory.appendingPathComponent("TagTrailIcon.iconset")

let cornerFraction = 0.2237   // macOS squircle corner radius / size

func render(size: Int) -> CGImage? {
    let colorSpace = CGColorSpaceCreateDeviceRGB()
    guard let context = CGContext(
        data: nil, width: size, height: size, bitsPerComponent: 8,
        bytesPerRow: 0, space: colorSpace,
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    ) else { return nil }
    guard let image = NSImage(contentsOf: source),
          let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return nil }

    let side = Double(size)
    let path = CGPath(roundedRect: CGRect(x: 0, y: 0, width: side, height: side),
                      cornerWidth: side * cornerFraction, cornerHeight: side * cornerFraction, transform: nil)

    context.clear(CGRect(x: 0, y: 0, width: size, height: size))
    context.addPath(path)
    context.clip()
    context.interpolationQuality = .high
    context.draw(cgImage, in: CGRect(x: 0, y: 0, width: side, height: side))
    return context.makeImage()
}

try? FileManager.default.removeItem(at: work)
try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)

let variants: [(String, Int)] = [
    ("icon_16x16", 16), ("icon_16x16@2x", 32),
    ("icon_32x32", 32), ("icon_32x32@2x", 64),
    ("icon_128x128", 128), ("icon_128x128@2x", 256),
    ("icon_256x256", 256), ("icon_256x256@2x", 512),
    ("icon_512x512", 512), ("icon_512x512@2x", 1024),
]
for (name, size) in variants {
    guard let rendered = render(size: size),
          let data = NSBitmapImageRep(cgImage: rendered).representation(using: .png, properties: [:]) else {
        fatalError("icon render failed at \(size)")
    }
    try data.write(to: work.appendingPathComponent("\(name).png"))
}

let process = Process()
process.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
process.arguments = ["-c", "icns", work.path, "-o", output.path]
try process.run()
process.waitUntilExit()
guard process.terminationStatus == 0 else { fatalError("iconutil failed") }
try? FileManager.default.removeItem(at: work)
print("Wrote \(output.path)")
