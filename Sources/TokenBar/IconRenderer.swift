import AppKit

/// Renders the menu-bar icon: a 18×18pt template capsule that fills left-to-right
/// according to the remaining percent of the tightest usage window.
///
/// Approach ported from CodexBar's `IconRenderer` / `drawBar`: 2× pixel grid (36×36px),
/// template image so the system tints it for light/dark mode, capsule track + inset stroke
/// + clipped fill. Kept intentionally simpler (no face/notches/animation).
enum IconRenderer {
    private static let outputSize = NSSize(width: 18, height: 18)
    private static let scale: CGFloat = 2
    private static let canvasPx = Int(outputSize.width * scale)

    /// - Parameters:
    ///   - remainingPercent: 0–100. `nil` means "no data" (drawn dim/empty).
    ///   - stale: draw dimmed to signal error/stale state.
    static func makeIcon(remainingPercent: Double?, stale: Bool) -> NSImage {
        let image = NSImage(size: outputSize, flipped: false) { rect in
            Self.draw(remainingPercent: remainingPercent, stale: stale, in: rect)
            return true
        }
        image.isTemplate = true
        return image
    }

    private static func draw(remainingPercent: Double?, stale: Bool, in rect: CGRect) {
        let baseFill = NSColor.labelColor
        let trackFillAlpha: CGFloat = stale ? 0.16 : 0.26
        let trackStrokeAlpha: CGFloat = stale ? 0.26 : 0.42
        let fillAlpha: CGFloat = stale ? 0.5 : 1.0

        // Capsule geometry: 30px wide × 12px tall, centred in the 36×36 canvas.
        let barWidthPx = 30
        let barHeightPx = 12
        let barXPx = (canvasPx - barWidthPx) / 2
        let barYPx = (canvasPx - barHeightPx) / 2

        let barRect = CGRect(
            x: CGFloat(barXPx) / scale,
            y: CGFloat(barYPx) / scale,
            width: CGFloat(barWidthPx) / scale,
            height: CGFloat(barHeightPx) / scale)
        let radius = barRect.height / 2

        // Track fill.
        let trackPath = NSBezierPath(roundedRect: barRect, xRadius: radius, yRadius: radius)
        baseFill.withAlphaComponent(trackFillAlpha).setFill()
        trackPath.fill()

        // Crisp inset stroke (2px so it reads at 1pt).
        let strokeWidthPx = 2
        let insetPx = strokeWidthPx / 2
        let strokeRect = CGRect(
            x: barRect.minX + CGFloat(insetPx) / scale,
            y: barRect.minY + CGFloat(insetPx) / scale,
            width: barRect.width - CGFloat(insetPx * 2) / scale,
            height: barRect.height - CGFloat(insetPx * 2) / scale)
        let strokePath = NSBezierPath(
            roundedRect: strokeRect,
            xRadius: max(0, radius - CGFloat(insetPx) / scale),
            yRadius: max(0, radius - CGFloat(insetPx) / scale))
        strokePath.lineWidth = CGFloat(strokeWidthPx) / scale
        baseFill.withAlphaComponent(trackStrokeAlpha).setStroke()
        strokePath.stroke()

        // Fill: clip to the capsule and paint a left-to-right rect for a straight progress edge.
        if let remainingPercent {
            let clamped = max(0, min(remainingPercent / 100, 1))
            let fillWidthPx = max(0, min(barWidthPx, Int((CGFloat(barWidthPx) * CGFloat(clamped)).rounded())))
            if fillWidthPx > 0 {
                if let ctx = NSGraphicsContext.current?.cgContext {
                    ctx.saveGState()
                    trackPath.addClip()
                    baseFill.withAlphaComponent(fillAlpha).setFill()
                    NSBezierPath(rect: CGRect(
                        x: barRect.minX,
                        y: barRect.minY,
                        width: CGFloat(fillWidthPx) / scale,
                        height: barRect.height)).fill()
                    ctx.restoreGState()
                }
            }
        }
    }
}
