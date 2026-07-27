import AppKit

/// Renders the concentric ring gauge into an NSImage.
///
/// Drawing into a bitmap image (like IconRenderer) bypasses NSMenu's
/// layer-hosting/vibrancy compositing, which silently drops area fills
/// from non-layer-backed NSView.draw(_:) but keeps strokes.
///
/// Layout: outer ring = monthly, middle = weekly, inner = session/5h.
/// Center shows the remaining percent of the tightest window.
enum RingRenderer {
    struct Ring: Identifiable {
        let id: String
        let label: String
        let usedPercent: Double
        let color: NSColor
    }

    private static let ringWidth: CGFloat = 8
    private static let ringGap: CGFloat = 5

    /// Render the ring gauge into an NSImage of the given point size.
    static func makeImage(rings: [Ring], tightestRemaining: Double?, size: CGFloat) -> NSImage {
        let outputSize = NSSize(width: size, height: size)
        let image = NSImage(size: outputSize, flipped: false) { rect in
            draw(rings: rings, tightestRemaining: tightestRemaining, in: rect)
            return true
        }
        return image
    }

    private static func draw(rings: [Ring], tightestRemaining: Double?, in rect: CGRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }

        let center = CGPoint(x: rect.midX, y: rect.midY)

        for (i, ring) in rings.enumerated() {
            let maxRadius = min(rect.width, rect.height) / 2 - ringWidth / 2 - 4
            let radius = maxRadius - CGFloat(i) * (ringWidth + ringGap)
            drawRing(in: ctx, center: center, radius: radius, width: ringWidth,
                     usedPercent: ring.usedPercent, color: ring.color)
        }

        // Center text (unflipped coords: y up). draw(at:) uses the point as the
        // text's lower-left, so to vertically center we subtract half the height.
        if let remaining = tightestRemaining {
            let text = "\(Int(remaining.rounded()))%"
            let attrs: [NSAttributedString.Key: Any] = [
                .font: NSFont.systemFont(ofSize: 20, weight: .semibold),
                .foregroundColor: NSColor.labelColor,
            ]
            let pctSize = text.size(withAttributes: attrs)
            text.draw(at: NSPoint(x: center.x - pctSize.width / 2,
                                  y: center.y - pctSize.height / 2),
                      withAttributes: attrs)

            // Caption directly below the percentage.
            let sub = L(.left)
            let subAttrs: [NSAttributedString.Key: Any] = [
                .font: NSFont.systemFont(ofSize: 9),
                .foregroundColor: NSColor.secondaryLabelColor,
            ]
            let subSize = sub.size(withAttributes: subAttrs)
            sub.draw(at: NSPoint(x: center.x - subSize.width / 2,
                                 y: center.y - pctSize.height / 2 - subSize.height - 1),
                     withAttributes: subAttrs)
        } else {
            let text = "–"
            let attrs: [NSAttributedString.Key: Any] = [
                .font: NSFont.systemFont(ofSize: 20, weight: .semibold),
                .foregroundColor: NSColor.secondaryLabelColor,
            ]
            let size = text.size(withAttributes: attrs)
            text.draw(at: NSPoint(x: center.x - size.width / 2,
                                  y: center.y - size.height / 2),
                      withAttributes: attrs)
        }
    }

    private static func drawRing(in ctx: CGContext, center: CGPoint, radius: CGFloat,
                                 width: CGFloat, usedPercent: Double, color: NSColor) {
        let palette = progressPalette(remainingPercent: 100 - usedPercent)
        // Track: full circle, translucent.
        ctx.setLineWidth(width)
        ctx.setLineCap(.butt)
        ctx.setStrokeColor(palette.start.withAlphaComponent(0.15).cgColor)
        ctx.addArc(center: center, radius: radius, startAngle: 0, endAngle: .pi * 2, clockwise: false)
        ctx.strokePath()

        // A subtle outer glow makes the current value easier to scan in a dense
        // menu without changing the existing concentric-ring layout.
        let trim = CGFloat(min(100, max(0, usedPercent))) / 100
        guard trim > 0.005 else { return }
        ctx.setLineCap(.round)
        ctx.setStrokeColor(palette.start.withAlphaComponent(0.18).cgColor)
        ctx.setLineWidth(width + 5)
        ctx.addArc(center: center, radius: radius,
                   startAngle: .pi / 2,
                   endAngle: .pi / 2 - .pi * 2 * trim,
                   clockwise: true)
        ctx.strokePath()

        // Filled arc: starts at 12 o'clock (top), goes counter-clockwise
        // (visually "downward on the left side" as usage grows).
        // In this CGContext, clockwise:true + decreasing endAngle produces the
        // counter-clockwise visual sweep we want (verified empirically).
        ctx.setLineCap(.round)
        // Clip the arc's stroked path and fill it with a directional gradient.
        // The palette gets deeper as the remaining quota approaches zero.
        ctx.saveGState()
        ctx.setLineWidth(width)
        ctx.addArc(center: center, radius: radius,
                   startAngle: .pi / 2,
                   endAngle: .pi / 2 - .pi * 2 * trim,
                   clockwise: true)
        ctx.replacePathWithStrokedPath()
        ctx.clip()
        let colors = [palette.start.cgColor, palette.end.cgColor] as CFArray
        if let gradient = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: colors, locations: [0, 1]) {
            ctx.drawLinearGradient(gradient,
                                   start: CGPoint(x: center.x - radius, y: center.y + radius),
                                   end: CGPoint(x: center.x + radius, y: center.y - radius),
                                   options: [])
        }
        ctx.restoreGState()

        // A small endpoint indicator gives the most immediate window a lively,
        // dashboard-like focal point while remaining legible in Dark Mode.
        let angle = CGFloat.pi / 2 - .pi * 2 * trim
        let point = CGPoint(x: center.x + cos(angle) * radius, y: center.y + sin(angle) * radius)
        ctx.setFillColor(NSColor.white.withAlphaComponent(0.82).cgColor)
        ctx.fillEllipse(in: CGRect(x: point.x - 2.2, y: point.y - 2.2, width: 4.4, height: 4.4))
    }

    /// Bright cyan conveys plentiful headroom; as quota becomes scarce the hue
    /// moves through blue into a denser indigo-purple. This is data-driven rather
    /// than a decoration assigned to a specific period.
    static func accentColor(remainingPercent: Double) -> NSColor {
        progressPalette(remainingPercent: remainingPercent).start
    }

    private static func progressPalette(remainingPercent: Double) -> (start: NSColor, end: NSColor) {
        switch remainingPercent {
        case ..<25:
            return (
                NSColor(srgbRed: 0.27, green: 0.19, blue: 0.58, alpha: 1),
                NSColor(srgbRed: 0.50, green: 0.24, blue: 0.76, alpha: 1)
            )
        case ..<60:
            return (
                NSColor(srgbRed: 0.05, green: 0.43, blue: 0.88, alpha: 1),
                NSColor(srgbRed: 0.34, green: 0.25, blue: 0.93, alpha: 1)
            )
        default:
            return (
                NSColor(srgbRed: 0.04, green: 0.79, blue: 0.68, alpha: 1),
                NSColor(srgbRed: 0.03, green: 0.56, blue: 0.95, alpha: 1)
            )
        }
    }
}
