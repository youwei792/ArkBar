import AppKit

/// Renders the menu-bar gauge: the same concentric ring meter as the plan
/// cards (monthly outer, weekly middle, session inner), shrunk onto the
/// status-item canvas, optionally combined with the provider logo.
///
/// The gauge is intentionally full-colour (not a template image) so the ring
/// hues match the cards. Because the artwork bakes in the current appearance's
/// colours, `StatusItemController` re-renders it when the theme changes.
enum IconRenderer {
    private static let ringSize: CGFloat = 18

    /// Renders `draw` into a static bitmap (1x + 2x) instead of an
    /// `NSImage(drawingHandler:)`. Drawing-handler images re-execute their
    /// closure on every render, and on a layer-backed NSStatusItem button
    /// that re-execution keeps the menu-bar replicant redrawing in a tight
    /// loop (measured at ~65% CPU sustained). A bitmap is blitted.
    /// Dynamic colours (label/tertiaryLabel) resolve against the appearance
    /// that is current during the bake; callers bake inside
    /// `performAsCurrentDrawingAppearance` and re-bake on appearance change.
    static func bakedImage(size: NSSize, template: Bool, _ draw: (NSRect) -> Void) -> NSImage {
        let image = NSImage(size: size)
        for scale in [1, 2] {
            let pixelsWide = max(1, Int((size.width * CGFloat(scale)).rounded()))
            let pixelsHigh = max(1, Int((size.height * CGFloat(scale)).rounded()))
            guard let rep = NSBitmapImageRep(
                bitmapDataPlanes: nil,
                pixelsWide: pixelsWide,
                pixelsHigh: pixelsHigh,
                bitsPerSample: 8,
                samplesPerPixel: 4,
                hasAlpha: true,
                isPlanar: false,
                colorSpaceName: .deviceRGB,
                bytesPerRow: 0,
                bitsPerPixel: 0)
            else { continue }
            NSGraphicsContext.saveGraphicsState()
            let context = NSGraphicsContext(bitmapImageRep: rep)!
            NSGraphicsContext.current = context
            context.cgContext.scaleBy(x: CGFloat(scale), y: CGFloat(scale))
            draw(NSRect(origin: .zero, size: size))
            NSGraphicsContext.restoreGraphicsState()
            image.addRepresentation(rep)
        }
        image.isTemplate = template
        return image
    }

    /// Just the ring gauge on an 18×18pt canvas. An empty ring list draws
    /// faint placeholder tracks so "no data" keeps the same gauge shape.
    static func makeRingIcon(rings: [RingRenderer.Ring], stale: Bool) -> NSImage {
        RingRenderer.makeMenuBarImage(rings: rings, stale: stale, size: ringSize)
    }

    /// Just the provider logo, centered in the 18×18 canvas.
    @MainActor
    static func makeLogoIcon(tab: ProviderTab) -> NSImage {
        let outputSize = NSSize(width: 18, height: 18)
        return bakedImage(size: outputSize, template: true) { rect in
            if let logo = ProviderLogo.image(for: tab) {
                let side: CGFloat = 16
                logo.draw(
                    in: NSRect(x: rect.midX - side / 2, y: rect.midY - side / 2,
                               width: side, height: side),
                    from: .zero,
                    operation: .sourceOver,
                    fraction: 1)
            }
        }
    }

    /// Logo on the left plus the ring gauge on the right. The logo is tinted
    /// with the label colour at bake time so it stays legible in both menu-bar
    /// appearances; the rings keep their card hues.
    @MainActor
    static func makeLogoAndRingIcon(tab: ProviderTab, rings: [RingRenderer.Ring], stale: Bool) -> NSImage {
        let size = NSSize(width: 36, height: 18)
        return bakedImage(size: size, template: false) { _ in
            if let logo = ProviderLogo.image(for: tab) {
                tintedLogo(logo).draw(
                    in: NSRect(x: 0, y: 1, width: 16, height: 16),
                    from: .zero,
                    operation: .sourceOver,
                    fraction: 1)
            }
            let ringsImage = RingRenderer.makeMenuBarImage(rings: rings, stale: stale, size: ringSize)
            ringsImage.draw(
                in: NSRect(x: size.width - ringSize, y: 0, width: ringSize, height: ringSize),
                from: .zero,
                operation: .sourceOver,
                fraction: 1)
        }
    }

    /// A template logo re-coloured with the current label colour, so it stays
    /// legible on both light and dark menu bars once baked into a colour image.
    private static func tintedLogo(_ logo: NSImage) -> NSImage {
        let size = NSSize(width: 16, height: 16)
        return NSImage(size: size, flipped: false) { rect in
            NSColor.labelColor.setFill()
            rect.fill()
            logo.draw(in: rect, from: .zero, operation: .destinationIn, fraction: 1)
            return true
        }
    }

    /// The teal→blue gradient meter used by the summary overview rows, so all
    /// rows share the same geometry.
    static func drawCapsuleBar(
        remainingPercent: Double?,
        stale: Bool,
        in barRect: CGRect)
    {
        let radius = barRect.height / 2
        let trackPath = NSBezierPath(roundedRect: barRect, xRadius: radius, yRadius: radius)

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

        if let remainingPercent, let ctx = NSGraphicsContext.current?.cgContext {
            let clamped = max(0, min(remainingPercent / 100, 1))
            let fillWidth = barRect.width * CGFloat(clamped)
            if fillWidth > 0.5 {
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
