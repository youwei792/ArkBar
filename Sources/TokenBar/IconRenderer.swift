import AppKit

/// Renders the menu-bar icon: an 18×18pt template meter capsule that fills
/// left-to-right according to the remaining percent, optionally combined with
/// the provider logo (mirroring CodexBar's "bars" / "icon & percent" styles).
///
/// Approach ported from CodexBar's `IconRenderer` / `drawBar`: 2× pixel grid (36×36px),
/// template image so the system tints it for light/dark mode, capsule track + inset stroke
/// + clipped fill. Kept intentionally simpler (no face/notches/animation).
@MainActor
enum IconRenderer {
    private static let outputSize = NSSize(width: 18, height: 18)
    private static let scale: CGFloat = 2
    private static let canvasPx = Int(outputSize.width * scale)

    /// - Parameters:
    ///   - remainingPercent: 0–100. `nil` means "no data" (drawn dim/empty).
    ///   - stale: draw dimmed to signal error/stale state.
    static func makeBarIcon(remainingPercent: Double?, stale: Bool) -> NSImage {
        let image = NSImage(size: outputSize, flipped: false) { rect in
            Self.drawBar(remainingPercent: remainingPercent, stale: stale, in: rect)
            return true
        }
        image.isTemplate = true
        return image
    }

    /// Just the provider logo, centered in the 18×18 canvas.
    static func makeLogoIcon(tab: ProviderTab) -> NSImage {
        let image = NSImage(size: outputSize, flipped: false) { rect in
            if let logo = ProviderLogo.image(for: tab) {
                let side: CGFloat = 16
                logo.draw(
                    in: NSRect(x: rect.midX - side / 2, y: rect.midY - side / 2,
                               width: side, height: side),
                    from: .zero,
                    operation: .sourceOver,
                    fraction: 1)
            }
            return true
        }
        image.isTemplate = true
        return image
    }

    /// Logo on the left plus a compact meter capsule on the right, in one
    /// template image so the whole glyph adopts the menu-bar foreground tint.
    static func makeLogoAndBarIcon(tab: ProviderTab, remainingPercent: Double?, stale: Bool) -> NSImage {
        let size = NSSize(width: 30, height: 18)
        let image = NSImage(size: size, flipped: false) { rect in
            if let logo = ProviderLogo.image(for: tab) {
                logo.draw(
                    in: NSRect(x: 0, y: 1, width: 16, height: 16),
                    from: .zero,
                    operation: .sourceOver,
                    fraction: 1)
            }
            Self.drawBar(remainingPercent: remainingPercent, stale: stale, in: NSRect(x: 16, y: 0, width: 14, height: 18))
            return true
        }
        image.isTemplate = true
        return image
    }

    /// Legacy name kept for callers that only need the capsule.
    static func makeIcon(remainingPercent: Double?, stale: Bool) -> NSImage {
        makeBarIcon(remainingPercent: remainingPercent, stale: stale)
    }

    private static func drawBar(remainingPercent: Double?, stale: Bool, in rect: CGRect) {
        // Menu-bar meter: 15pt × 6pt capsule centred in the 18×18 canvas.
        let barWidthPx = 30
        let barHeightPx = 12
        let barXPx = (canvasPx - barWidthPx) / 2
        let barYPx = (canvasPx - barHeightPx) / 2
        let barRect = CGRect(
            x: rect.minX + CGFloat(barXPx) / scale,
            y: rect.minY + CGFloat(barYPx) / scale,
            width: CGFloat(barWidthPx) / scale,
            height: CGFloat(barHeightPx) / scale)
        drawCapsuleBar(remainingPercent: remainingPercent, stale: stale, in: barRect)
    }

    enum CapsuleStyle {
        /// Monochrome template fill — used by the status-item meter.
        case monochrome
        /// Teal→blue gradient fill — used by the summary overview rows.
        case accentGradient
    }

    /// Shared capsule progress bar used by the status-item meter and the
    /// summary overview rows, so both surfaces share the same geometry.
    static func drawCapsuleBar(
        remainingPercent: Double?,
        stale: Bool,
        in barRect: CGRect,
        style: CapsuleStyle = .monochrome)
    {
        let radius = barRect.height / 2
        let trackPath = NSBezierPath(roundedRect: barRect, xRadius: radius, yRadius: radius)

        switch style {
        case .monochrome:
            let baseFill = NSColor.labelColor
            let trackFillAlpha: CGFloat = stale ? 0.16 : 0.26
            let trackStrokeAlpha: CGFloat = stale ? 0.26 : 0.42
            let fillAlpha: CGFloat = stale ? 0.5 : 1.0
            baseFill.withAlphaComponent(trackFillAlpha).setFill()
            trackPath.fill()

            let strokeInset: CGFloat = 0.5
            let strokeRect = barRect.insetBy(dx: strokeInset, dy: strokeInset)
            let strokePath = NSBezierPath(
                roundedRect: strokeRect,
                xRadius: max(0, radius - strokeInset),
                yRadius: max(0, radius - strokeInset))
            strokePath.lineWidth = 1
            baseFill.withAlphaComponent(trackStrokeAlpha).setStroke()
            strokePath.stroke()

            if let remainingPercent {
                let clamped = max(0, min(remainingPercent / 100, 1))
                let fillWidth = barRect.width * CGFloat(clamped)
                if fillWidth > 0, let ctx = NSGraphicsContext.current?.cgContext {
                    ctx.saveGState()
                    trackPath.addClip()
                    baseFill.withAlphaComponent(fillAlpha).setFill()
                    NSBezierPath(rect: CGRect(
                        x: barRect.minX, y: barRect.minY,
                        width: fillWidth, height: barRect.height)).fill()
                    ctx.restoreGState()
                }
            }

        case .accentGradient:
            // Soft track.
            NSColor.separatorColor.withAlphaComponent(stale ? 0.18 : 0.28).setFill()
            trackPath.fill()
            NSColor.separatorColor.withAlphaComponent(stale ? 0.28 : 0.42).setStroke()
            let strokePath = NSBezierPath(
                roundedRect: barRect.insetBy(dx: 0.5, dy: 0.5),
                xRadius: max(0, radius - 0.5),
                yRadius: max(0, radius - 0.5))
            strokePath.lineWidth = 1
            strokePath.stroke()

            if let remainingPercent {
                let clamped = max(0, min(remainingPercent / 100, 1))
                let fillWidth = barRect.width * CGFloat(clamped)
                if fillWidth > 0.5, let ctx = NSGraphicsContext.current?.cgContext {
                    ctx.saveGState()
                    trackPath.addClip()
                    let fillRect = CGRect(
                        x: barRect.minX, y: barRect.minY,
                        width: fillWidth, height: barRect.height)
                    let colors = [
                        NSColor.systemTeal.withAlphaComponent(stale ? 0.55 : 0.95).cgColor,
                        NSColor.systemBlue.withAlphaComponent(stale ? 0.55 : 1.0).cgColor,
                    ] as CFArray
                    if let gradient = CGGradient(
                        colorsSpace: CGColorSpaceCreateDeviceRGB(),
                        colors: colors,
                        locations: [0, 1])
                    {
                        ctx.drawLinearGradient(
                            gradient,
                            start: CGPoint(x: fillRect.minX, y: fillRect.midY),
                            end: CGPoint(x: fillRect.maxX, y: fillRect.midY),
                            options: [])
                    }
                    ctx.restoreGState()
                }
            }
        }
    }
}
