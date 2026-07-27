import AppKit

/// Renders the concentric ring gauge into an NSImage.
///
/// Drawing into a bitmap image (like IconRenderer) bypasses NSMenu's
/// layer-hosting/vibrancy compositing, which silently drops area fills
/// from non-layer-backed NSView.draw(_:) but keeps strokes.
///
/// Layout: outer ring = monthly, middle = weekly, inner = session/5h.
/// Center shows the remaining percent of the primary (Session / 5-hour) window.
enum RingRenderer {
    enum Tone {
        case session
        case weekly
        case monthly
    }

    struct Ring: Identifiable {
        let id: String
        let label: String
        /// All visible progress in ArkBar represents remaining quota.
        let remainingPercent: Double
        let tone: Tone

        var color: NSColor {
            RingRenderer.progressPalette(tone: tone, remainingPercent: remainingPercent).start
        }
    }

    private static let ringWidth: CGFloat = 8
    private static let ringGap: CGFloat = 5

    /// Render the ring gauge into an NSImage of the given point size.
    static func makeImage(rings: [Ring], primaryRemaining: Double?, primaryLabel: String?, size: CGFloat) -> NSImage {
        let outputSize = NSSize(width: size, height: size)
        let image = NSImage(size: outputSize, flipped: false) { rect in
            draw(rings: rings, primaryRemaining: primaryRemaining, primaryLabel: primaryLabel, in: rect)
            return true
        }
        return image
    }

    private static func draw(rings: [Ring], primaryRemaining: Double?, primaryLabel: String?, in rect: CGRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }

        let center = CGPoint(x: rect.midX, y: rect.midY)

        for (i, ring) in rings.enumerated() {
            let maxRadius = min(rect.width, rect.height) / 2 - ringWidth / 2 - 4
            let radius = maxRadius - CGFloat(i) * (ringWidth + ringGap)
            drawRing(in: ctx, center: center, radius: radius, width: ringWidth,
                     remainingPercent: ring.remainingPercent, tone: ring.tone)
        }

        // Center text (unflipped coords: y up). draw(at:) uses the point as the
        // text's lower-left, so to vertically center we subtract half the height.
        if let remaining = primaryRemaining {
            let text = "\(Int(remaining.rounded()))%"
            let attrs: [NSAttributedString.Key: Any] = [
                .font: NSFont.systemFont(ofSize: 18, weight: .semibold),
                .foregroundColor: NSColor.labelColor,
            ]
            let pctSize = text.size(withAttributes: attrs)
            text.draw(at: NSPoint(x: center.x - pctSize.width / 2,
                                  y: center.y - pctSize.height / 2),
                      withAttributes: attrs)

            // Caption directly below the percentage.
            // The whole card already establishes that values are remaining.
            // Keeping just the period name avoids a long caption overflowing
            // the centre of the innermost ring at 100%.
            let sub = primaryLabel ?? L(.left)
            let subAttrs: [NSAttributedString.Key: Any] = [
                .font: NSFont.systemFont(ofSize: 8, weight: .medium),
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
                                 width: CGFloat, remainingPercent: Double, tone: Tone) {
        let palette = progressPalette(tone: tone, remainingPercent: remainingPercent)
        // Track: full circle, translucent.
        ctx.setLineWidth(width)
        ctx.setLineCap(.butt)
        ctx.setStrokeColor(palette.start.withAlphaComponent(0.15).cgColor)
        ctx.addArc(center: center, radius: radius, startAngle: 0, endAngle: .pi * 2, clockwise: false)
        ctx.strokePath()

        // A subtle outer glow makes the current value easier to scan in a dense
        // menu without changing the existing concentric-ring layout.
        let trim = CGFloat(min(100, max(0, remainingPercent))) / 100
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
        // and grows as available quota grows. A 100% remaining window is a
        // complete ring; a depleted window is empty.
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

    static func tone(for label: String) -> Tone {
        switch label.lowercased() {
        case "session", "5h", "5-hour", "five_hour": .session
        case "weekly", "week": .weekly
        default: .monthly
        }
    }

    /// Periods use distinct hue families, while the same semantic rule applies
    /// to all of them: less remaining quota lowers luminance and deepens color.
    private static func progressPalette(tone: Tone, remainingPercent: Double) -> (start: NSColor, end: NSColor) {
        let remaining = max(0, min(100, remainingPercent)) / 100
        let depth = 1 - remaining
        let baseHue: CGFloat
        switch tone {
        case .session: baseHue = 0.47   // mint / cyan
        case .weekly: baseHue = 0.57    // blue
        case .monthly: baseHue = 0.66   // indigo
        }
        let saturation = 0.70 + 0.20 * depth
        let startBrightness = 0.95 - 0.50 * depth
        let endBrightness = 0.86 - 0.45 * depth
        return (
            NSColor(calibratedHue: baseHue,
                    saturation: saturation,
                    brightness: startBrightness,
                    alpha: 1),
            NSColor(calibratedHue: min(0.75, baseHue + 0.045),
                    saturation: min(1, saturation + 0.04),
                    brightness: endBrightness,
                    alpha: 1)
        )
    }
}
