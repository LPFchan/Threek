// Renders Resources/Assets.xcassets/AppIcon.appiconset: a white three-pronged
// fork on a neutral grey rounded square. Run: swift scripts/make-icon.swift
import AppKit

let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
let iconset = root.appending(path: "Resources/Assets.xcassets/AppIcon.appiconset")

func color(_ hex: UInt32) -> CGColor {
    CGColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255, alpha: 1)
}

// Apple's continuous-corner squircle, approximated by a superellipse.
func squircle(in r: CGRect) -> CGPath {
    let n = 5.0, path = CGMutablePath(), steps = 720
    for i in 0...steps {
        let t = Double(i) / Double(steps) * 2 * .pi
        let x = pow(abs(cos(t)), 2 / n) * (cos(t) < 0 ? -1 : 1)
        let y = pow(abs(sin(t)), 2 / n) * (sin(t) < 0 ? -1 : 1)
        let p = CGPoint(x: r.midX + x * r.width / 2, y: r.midY + y * r.height / 2)
        i == 0 ? path.move(to: p) : path.addLine(to: p)
    }
    path.closeSubpath()
    return path
}

// Drawn by hand: Apple's licence doesn't allow SF Symbols in app icons.
// The menu bar glyph (App/ForkGlyph.swift) copies this outline; keep in step.
// 1024-pt coordinates, y up: tines on top, handle at the bottom.
func fork(cx: CGFloat) -> CGPath {
    let tineW: CGFloat = 46, gap: CGFloat = 30, headW = tineW * 3 + gap * 2
    let tineTop: CGFloat = 780, tineBottom: CGFloat = 600
    let neckW: CGFloat = 70, neckY: CGFloat = 470, endW: CGFloat = 84, endY: CGFloat = 234
    var shape = CGPath(rect: .zero, transform: nil)
    for i in 0..<3 {
        let x = cx - headW / 2 + CGFloat(i) * (tineW + gap)
        shape = shape.union(CGPath(roundedRect: CGRect(x: x, y: tineBottom - 10, width: tineW,
                                                       height: tineTop - tineBottom + 10),
                                   cornerWidth: tineW / 2, cornerHeight: tineW / 2, transform: nil))
    }
    let head = CGMutablePath()   // joins the tines and tapers into the neck
    head.move(to: CGPoint(x: cx - headW / 2, y: tineBottom))
    head.addLine(to: CGPoint(x: cx + headW / 2, y: tineBottom))
    head.addCurve(to: CGPoint(x: cx + neckW / 2, y: neckY),
                  control1: CGPoint(x: cx + headW / 2, y: 520), control2: CGPoint(x: cx + neckW / 2, y: 505))
    head.addLine(to: CGPoint(x: cx - neckW / 2, y: neckY))
    head.addCurve(to: CGPoint(x: cx - headW / 2, y: tineBottom),
                  control1: CGPoint(x: cx - neckW / 2, y: 505), control2: CGPoint(x: cx - headW / 2, y: 520))
    head.closeSubpath()
    let handle = CGMutablePath() // flares slightly toward a round end
    handle.move(to: CGPoint(x: cx - neckW / 2, y: neckY + 2))
    handle.addLine(to: CGPoint(x: cx + neckW / 2, y: neckY + 2))
    handle.addCurve(to: CGPoint(x: cx + endW / 2, y: endY + endW / 2),
                    control1: CGPoint(x: cx + neckW / 2, y: 380), control2: CGPoint(x: cx + endW / 2, y: 330))
    handle.addArc(center: CGPoint(x: cx, y: endY + endW / 2), radius: endW / 2,
                  startAngle: 0, endAngle: .pi, clockwise: true)
    handle.addCurve(to: CGPoint(x: cx - neckW / 2, y: neckY + 2),
                    control1: CGPoint(x: cx - endW / 2, y: 330), control2: CGPoint(x: cx - neckW / 2, y: 380))
    handle.closeSubpath()
    return shape.union(head).union(handle)
}

func render(_ px: Int) -> Data {
    let ctx = CGContext(data: nil, width: px, height: px, bitsPerComponent: 8, bytesPerRow: 0,
                        space: CGColorSpace(name: CGColorSpace.sRGB)!,
                        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    ctx.scaleBy(x: CGFloat(px) / 1024, y: CGFloat(px) / 1024)
    // macOS icon grid: an 824-pt rounded square centred on a 1024-pt canvas.
    let body = squircle(in: CGRect(x: 100, y: 100, width: 824, height: 824))
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -10), blur: 20, color: CGColor(gray: 0, alpha: 0.3))
    ctx.addPath(body); ctx.setFillColor(color(0x6A6C74)); ctx.fillPath()
    ctx.restoreGState()
    ctx.addPath(body); ctx.clip()
    let bg = CGGradient(colorsSpace: nil, colors: [color(0xA4A6AD), color(0x6A6C74)] as CFArray, locations: [0, 1])!
    ctx.drawLinearGradient(bg, start: CGPoint(x: 512, y: 924), end: CGPoint(x: 512, y: 100), options: [])
    let f = fork(cx: 512)
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -14), blur: 28, color: CGColor(gray: 0, alpha: 0.35))
    ctx.addPath(f); ctx.setFillColor(color(0xE6E7EA)); ctx.fillPath()
    ctx.restoreGState()
    ctx.addPath(f); ctx.clip()
    let fg = CGGradient(colorsSpace: nil, colors: [color(0xFFFFFF), color(0xE6E7EA)] as CFArray, locations: [0, 1])!
    ctx.drawLinearGradient(fg, start: CGPoint(x: 512, y: 780), end: CGPoint(x: 512, y: 234), options: [])
    return NSBitmapImageRep(cgImage: ctx.makeImage()!).representation(using: .png, properties: [:])!
}

var images: [String] = []
for size in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let name = "icon_\(size)x\(size)\(scale == 2 ? "@2x" : "").png"
        try! render(size * scale).write(to: iconset.appending(path: name))
        images.append("""
            { "filename" : "\(name)", "idiom" : "mac", "scale" : "\(scale)x", "size" : "\(size)x\(size)" }
        """)
    }
}
let contents = "{\n  \"images\" : [\n\(images.joined(separator: ",\n"))\n  ],\n  \"info\" : { \"author\" : \"xcode\", \"version\" : 1 }\n}\n"
try! contents.write(to: iconset.appending(path: "Contents.json"), atomically: true, encoding: .utf8)
print(iconset.path)
