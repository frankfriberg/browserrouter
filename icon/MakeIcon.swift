import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

// The app icon, drawn rather than stored: a stem that forks, one arm per profile.
// **The fork is the whole idea** — one link arriving, two places it can land — and the arm
// colours are the two profiles, pink for work and grey for personal, so the icon says
// what the app does at any size.
//
// Kept deliberately blunt: 80/1024 strokes and no fine detail, because the 16 pt rendering
// is the one that has to survive and anything thinner disappears there.

func draw(size: CGFloat, to url: URL) {
    let s = size / 1024
    let space = CGColorSpaceCreateDeviceRGB()
    guard let ctx = CGContext(data: nil, width: Int(size), height: Int(size),
                              bitsPerComponent: 8, bytesPerRow: 0, space: space,
                              bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
    else { return }

    ctx.setAllowsAntialiasing(true)
    ctx.interpolationQuality = .high

    // The rounded square every macOS icon sits in, inset so it never touches the edge.
    let inset: CGFloat = 76 * s
    let rect = CGRect(x: inset, y: inset, width: size - inset * 2, height: size - inset * 2)
    let plate = CGPath(roundedRect: rect, cornerWidth: 228 * s, cornerHeight: 228 * s, transform: nil)

    ctx.saveGState()
    ctx.addPath(plate)
    ctx.clip()
    let top = CGColor(srgbRed: 0.20, green: 0.22, blue: 0.28, alpha: 1)
    let bottom = CGColor(srgbRed: 0.09, green: 0.10, blue: 0.13, alpha: 1)
    if let gradient = CGGradient(colorsSpace: space, colors: [top, bottom] as CFArray, locations: [0, 1]) {
        ctx.drawLinearGradient(gradient,
                               start: CGPoint(x: 0, y: size),
                               end: CGPoint(x: 0, y: 0),
                               options: [])
    }
    ctx.restoreGState()

    ctx.setLineWidth(84 * s)
    ctx.setLineCap(.round)
    ctx.setLineJoin(.round)

    let grey = CGColor(srgbRed: 0.83, green: 0.85, blue: 0.89, alpha: 1)
    let pink = CGColor(srgbRed: 0.90, green: 0.35, blue: 0.50, alpha: 1)

    // The stem: one link, arriving.
    ctx.setStrokeColor(grey)
    ctx.move(to: CGPoint(x: 512 * s, y: 250 * s))
    ctx.addLine(to: CGPoint(x: 512 * s, y: 500 * s))
    ctx.strokePath()

    // The two arms. **Straight, not curved** — a bezier here bulges and the arms cross
    // each other at the join, which at 16 pt reads as a smudge rather than a fork.
    ctx.setStrokeColor(grey)
    ctx.move(to: CGPoint(x: 512 * s, y: 490 * s))
    ctx.addLine(to: CGPoint(x: 330 * s, y: 690 * s))
    ctx.strokePath()

    ctx.setStrokeColor(pink)
    ctx.move(to: CGPoint(x: 512 * s, y: 490 * s))
    ctx.addLine(to: CGPoint(x: 694 * s, y: 690 * s))
    ctx.strokePath()

    // The two destinations.
    let r: CGFloat = 70 * s
    ctx.setFillColor(grey)
    ctx.fillEllipse(in: CGRect(x: 330 * s - r, y: 690 * s - r, width: r * 2, height: r * 2))
    ctx.setFillColor(pink)
    ctx.fillEllipse(in: CGRect(x: 694 * s - r, y: 690 * s - r, width: r * 2, height: r * 2))

    guard let image = ctx.makeImage(),
          let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil)
    else { return }
    CGImageDestinationAddImage(dest, image, nil)
    CGImageDestinationFinalize(dest)
}

let out = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
try? FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
let plan: [(String, CGFloat)] = [
    ("icon_16x16", 16), ("icon_16x16@2x", 32),
    ("icon_32x32", 32), ("icon_32x32@2x", 64),
    ("icon_128x128", 128), ("icon_128x128@2x", 256),
    ("icon_256x256", 256), ("icon_256x256@2x", 512),
    ("icon_512x512", 512), ("icon_512x512@2x", 1024),
]
for (name, size) in plan {
    draw(size: size, to: out.appendingPathComponent("\(name).png"))
}
print("wrote \(plan.count) sizes to \(out.path)")
