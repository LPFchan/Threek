import AppKit

/// The fork from the app icon, as a menu bar template image. Same outline
/// as scripts/make-icon.swift draws (1024-pt icon coordinates), cropped to
/// the fork and scaled to menu bar height.
enum ForkGlyph {
    /// `dimmed` draws it faint, for "not working yet" (no Accessibility).
    static func menuBarImage(dimmed: Bool) -> NSImage {
        let image = NSImage(size: NSSize(width: 18, height: 18), flipped: false) { rect in
            guard let ctx = NSGraphicsContext.current?.cgContext else { return false }
            // The fork spans x 413–611, y 234–780 on the icon grid.
            let bounds = CGRect(x: 413, y: 234, width: 198, height: 546)
            let s = (rect.height - 2) / bounds.height
            ctx.translateBy(x: rect.midX - bounds.midX * s, y: 1 - bounds.minY * s)
            ctx.scaleBy(x: s, y: s)
            ctx.addPath(path(cx: 512))
            ctx.setFillColor(NSColor.black.withAlphaComponent(dimmed ? 0.4 : 1).cgColor)
            ctx.fillPath()
            return true
        }
        image.isTemplate = true
        image.accessibilityDescription = "Threek"
        return image
    }

    /// Three tines joined by a bowl that tapers into a handle with a round
    /// end; y grows upward. Keep in step with scripts/make-icon.swift.
    static func path(cx: CGFloat) -> CGPath {
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
        let head = CGMutablePath()
        head.move(to: CGPoint(x: cx - headW / 2, y: tineBottom))
        head.addLine(to: CGPoint(x: cx + headW / 2, y: tineBottom))
        head.addCurve(to: CGPoint(x: cx + neckW / 2, y: neckY),
                      control1: CGPoint(x: cx + headW / 2, y: 520), control2: CGPoint(x: cx + neckW / 2, y: 505))
        head.addLine(to: CGPoint(x: cx - neckW / 2, y: neckY))
        head.addCurve(to: CGPoint(x: cx - headW / 2, y: tineBottom),
                      control1: CGPoint(x: cx - neckW / 2, y: 505), control2: CGPoint(x: cx - headW / 2, y: 520))
        head.closeSubpath()
        let handle = CGMutablePath()
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
}
