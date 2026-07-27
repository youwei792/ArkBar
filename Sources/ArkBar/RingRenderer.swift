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
    /// Per-provider color theme. `.ark` is the original mint/blue/indigo palette
    /// and stays the default so all existing call sites render unchanged.
    /// `.opencode` swaps to a violet + amber palette to distinguish the tab.
    enum CardTheme {
        case ark
        case opencode
    }

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
        /// Color theme. Defaults to `.ark` for backward compatibility.
        var theme: CardTheme = .ark

        var color: NSColor {
            RingRenderer.progressPalette(tone: tone, remainingPercent: remainingPercent, theme: theme).start
        }
    }

    private static let ringWidth: CGFloat = 8
    private static let ringGap: CGFloat = 5

    /// Render the ring gauge into an NSImage of the given point size.
    static func makeImage(rings: [Ring], primaryRemaining: Double?, primaryLabel: String?, size: CGFloat, theme: CardTheme = .ark) -> NSImage {
        let outputSize = NSSize(width: size, height: size)
        let image = NSImage(size: outputSize, flipped: false) { rect in
            draw(rings: rings, primaryRemaining: primaryRemaining, primaryLabel: primaryLabel, in: rect, theme: theme)
            return true
        }
        return image
    }

    private static func draw(rings: [Ring], primaryRemaining: Double?, primaryLabel: String?, in rect: CGRect, theme: CardTheme) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }

        let center = CGPoint(x: rect.midX, y: rect.midY)

        for (i, ring) in rings.enumerated() {
            let maxRadius = min(rect.width, rect.height) / 2 - ringWidth / 2 - 4
            let radius = maxRadius - CGFloat(i) * (ringWidth + ringGap)
            drawRing(in: ctx, center: center, radius: radius, width: ringWidth,
                     remainingPercent: ring.remainingPercent, tone: ring.tone, theme: ring.theme)
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
                                 width: CGFloat, remainingPercent: Double, tone: Tone, theme: CardTheme) {
        let palette = progressPalette(tone: tone, remainingPercent: remainingPercent, theme: theme)
        // Track: full circle, translucent.
        ctx.setLineWidth(width)
        ctx.setLineCap(.butt)
        ctx.setStrokeColor(palette.start.withAlphaComponent(0.15).cgColor)
        ctx.addArc(center: center, radius: radius, startAngle: 0, endAngle: .pi * 2, clockwise: false)
        ctx.strokePath()

        // Filled arc: starts at 12 o'clock (top) and sweeps counter-clockwise
        // (i.e. top -> left -> bottom -> right) as remaining quota grows.
        // A 100% remaining window is a complete ring; a depleted window is empty.
        //
        // Core Graphics angle convention: 0 rad = 3 o'clock (right), angles
        // increase counter-clockwise. So 12 o'clock = π/2. Sweeping CCW by
        // `2π·trim` radians reaches endAngle = π/2 + 2π·trim. Using
        // clockwise:false with an increasing endAngle draws exactly that arc,
        // unambiguously, in every bitmap context.
        let trim = CGFloat(min(100, max(0, remainingPercent))) / 100
        guard trim > 0.005 else { return }

        let startAngle: CGFloat = .pi / 2
        let endAngle: CGFloat = .pi / 2 + .pi * 2 * trim
        let sweep = .pi * 2 * trim  // radians, always positive

        // A subtle outer glow makes the current value easier to scan in a dense
        // menu without changing the existing concentric-ring layout.
        ctx.setLineCap(.round)
        ctx.setStrokeColor(palette.start.withAlphaComponent(0.18).cgColor)
        ctx.setLineWidth(width + 5)
        ctx.addArc(center: center, radius: radius,
                   startAngle: startAngle,
                   endAngle: endAngle,
                   clockwise: false)
        ctx.strokePath()

        // Filled arc stroked with a directional gradient. The palette gets
        // deeper as the remaining quota approaches zero.
        ctx.setLineCap(.round)
        ctx.setLineWidth(width)
        ctx.setStrokeColor(palette.start.cgColor)
        ctx.addArc(center: center, radius: radius,
                   startAngle: startAngle,
                   endAngle: endAngle,
                   clockwise: false)
        ctx.strokePath()

        // Overlay the gradient only where the arc is, by clipping to the stroked
        // arc path. This keeps the directional color shift without the full-ring
        // fill that the previous replacePathWithStrokedPath+clip produced.
        ctx.saveGState()
        ctx.setLineWidth(width)
        ctx.addArc(center: center, radius: radius,
                   startAngle: startAngle,
                   endAngle: endAngle,
                   clockwise: false)
        ctx.replacePathWithStrokedPath()
        ctx.clip()
        let colors = [palette.start.cgColor, palette.end.cgColor] as CFArray
        if let gradient = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: colors, locations: [0, 1]) {
            // Gradient runs along the arc's chord direction so the deepening
            // tracks the sweep from start to end of the filled portion.
            let startX = center.x + cos(startAngle) * radius
            let startY = center.y + sin(startAngle) * radius
            let endX = center.x + cos(endAngle) * radius
            let endY = center.y + sin(endAngle) * radius
            ctx.drawLinearGradient(gradient,
                                   start: CGPoint(x: startX, y: startY),
                                   end: CGPoint(x: endX, y: endY),
                                   options: [])
        }
        ctx.restoreGState()

        // A small endpoint indicator gives the most immediate window a lively,
        // dashboard-like focal point while remaining legible in Dark Mode.
        // It sits at the END of the filled arc (where remaining quota runs out).
        let point = CGPoint(x: center.x + cos(endAngle) * radius, y: center.y + sin(endAngle) * radius)
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
    private static func progressPalette(tone: Tone, remainingPercent: Double, theme: CardTheme) -> (start: NSColor, end: NSColor) {
        let remaining = max(0, min(100, remainingPercent)) / 100
        let depth = 1 - remaining

        switch theme {
        case .ark:
            // Original mint/blue/indigo palette. Unchanged.
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
        case .opencode:
            // Violet base per tone (deeper violet for longer windows). As
            // remaining quota drops, the gradient end shifts toward amber
            // (hue ~0.10) so a depleted window reads as a warm warning.
            let baseHue: CGFloat
            switch tone {
            case .session: baseHue = 0.78   // violet
            case .weekly: baseHue = 0.82    // deeper violet
            case .monthly: baseHue = 0.86   // indigo-violet
            }
            let saturation = 0.62 + 0.25 * depth
            let startBrightness = 0.92 - 0.45 * depth
            // Amber drift: 0 depth -> stay violet; 1 depth -> hue ~0.10 (amber).
            let endHue = baseHue + (0.10 + 1.0 - baseHue).truncatingRemainder(dividingBy: 1.0) * depth
            let normalizedEndHue = endHue.truncatingRemainder(dividingBy: 1.0)
            let endBrightness = 0.88 - 0.30 * depth
            return (
                NSColor(calibratedHue: baseHue,
                        saturation: saturation,
                        brightness: startBrightness,
                        alpha: 1),
                NSColor(calibratedHue: normalizedEndHue,
                        saturation: min(1, saturation + 0.10 * depth),
                        brightness: endBrightness,
                        alpha: 1)
            )
        }
    }
}
