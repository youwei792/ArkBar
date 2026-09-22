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
        case balance
    }

    struct Ring: Identifiable {
        let id: String
        let label: String
        /// All visible progress in TokenBar represents remaining quota.
        let remainingPercent: Double
        let tone: Tone
        var color: NSColor {
            RingRenderer.spectrumColor(
                at: 0.38,
                tone: tone,
                remainingPercent: remainingPercent)
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

    /// Compact menu-bar gauge: the same concentric rings (monthly outer,
    /// weekly middle, session inner) shrunk onto a tiny canvas. Missing rings
    /// are skipped and single-window providers collapse to one ring, so the
    /// glyph always mirrors the card's data instead of implying phantom
    /// windows. An empty input draws faint placeholder tracks so "no data"
    /// still reads as the same gauge. No center text and no endpoint dots —
    /// both would smear at menu-bar size. Baked to a static bitmap; see
    /// `IconRenderer.bakedImage` for why drawing-handler images are avoided.
    static func makeMenuBarImage(rings: [Ring], stale: Bool, size: CGFloat = 18) -> NSImage {
        let outputSize = NSSize(width: size, height: size)
        return IconRenderer.bakedImage(size: outputSize, template: false) { rect in
            drawCompact(rings: rings, stale: stale, in: rect)
        }
    }

    /// Rings for the menu-bar gauge, derived from one plan: the dated windows
    /// (monthly outer, weekly middle, session inner) when the plan has any, or
    /// a single balance-toned ring for single-window plans (balance / 24h /
    /// Requests quotas). No windows means no rings — the caller then draws
    /// placeholder tracks.
    static func menuBarRings(for plan: PlanSnapshot) -> [Ring] {
        let windows = plan.windows
        func find(_ labels: Set<String>) -> UsageWindow? {
            windows.first { labels.contains($0.label.lowercased()) }
        }
        let dated: [Ring] = [
            find(["monthly", "month"]).map {
                Ring(id: "monthly", label: $0.displayName,
                     remainingPercent: $0.remainingPercent, tone: .monthly)
            },
            find(["weekly", "week"]).map {
                Ring(id: "weekly", label: $0.displayName,
                     remainingPercent: $0.remainingPercent, tone: .weekly)
            },
            find(["session", "5h", "5-hour", "five_hour"]).map {
                Ring(id: "session", label: $0.displayName,
                     remainingPercent: $0.remainingPercent, tone: .session)
            },
        ].compactMap { $0 }
        if !dated.isEmpty { return dated }
        if let single = windows.first {
            return [Ring(id: single.label, label: single.displayName,
                         remainingPercent: single.remainingPercent, tone: .balance)]
        }
        return []
    }

    private static func drawCompact(rings: [Ring], stale: Bool, in rect: CGRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        let center = CGPoint(x: rect.midX, y: rect.midY)
        // Thin strokes survive the shrink: 1.7pt progress on a ~1pt-wider
        // track, 1pt gaps. Radii step inward so three rings fit the 18pt
        // canvas (outer 7.35, middle 4.65, inner 1.95) without touching.
        let width: CGFloat = 1.7
        let gap: CGFloat = 1.0
        let maxRadius = min(rect.width, rect.height) / 2 - width / 2 - 0.8
        // No data still draws the gauge shape: three faint tracks so an empty
        // status item reads as "rings with nothing yet" rather than blank.
        let trackCount = rings.isEmpty ? 3 : rings.count
        for index in 0 ..< trackCount {
            let radius = maxRadius - CGFloat(index) * (width + gap)
            guard radius > width / 2 else { continue }
            ctx.setLineWidth(width + 0.9)
            ctx.setLineCap(.butt)
            ctx.setStrokeColor(NSColor.tertiaryLabelColor.withAlphaComponent(0.32).cgColor)
            ctx.addArc(center: center, radius: radius, startAngle: 0, endAngle: .pi * 2, clockwise: false)
            ctx.strokePath()

            guard index < rings.count else { continue }
            let ring = rings[index]
            let trim = CGFloat(min(100, max(0, ring.remainingPercent))) / 100
            guard trim > 0.02 else { continue }
            // Solid mid-spectrum colour per ring — the same hue family as the
            // card's gradient, but a flat field reads cleaner at 18pt.
            let startAngle: CGFloat = .pi / 2
            let isFullRing = trim >= 0.995
            ctx.setLineWidth(width)
            // A full circle uses butt caps so the joint has no round-cap bump.
            ctx.setLineCap(isFullRing ? .butt : .round)
            ctx.setStrokeColor(ring.color.withAlphaComponent(stale ? 0.45 : 1.0).cgColor)
            if isFullRing {
                ctx.addArc(center: center, radius: radius, startAngle: 0, endAngle: .pi * 2, clockwise: false)
            } else {
                ctx.addArc(
                    center: center, radius: radius,
                    startAngle: startAngle, endAngle: startAngle - .pi * 2 * trim,
                    clockwise: true)
            }
            ctx.strokePath()
        }
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
                .font: NSFont.monospacedDigitSystemFont(ofSize: 17, weight: .semibold),
                .foregroundColor: NSColor.labelColor,
            ]
            let pctSize = text.size(withAttributes: attrs)

            // The right-hand rows already identify the period. The center
            // answers the user's actual question — how much is left — and
            // mirrors the reference without becoming ambiguous at a glance.
            let sub = L(.left)
            let subAttrs: [NSAttributedString.Key: Any] = [
                .font: NSFont.systemFont(ofSize: 8, weight: .medium),
                .foregroundColor: NSColor.secondaryLabelColor,
            ]
            let subSize = sub.size(withAttributes: subAttrs)
            // Center the percentage and caption as a single visual group. This
            // keeps a three-digit value such as 100% away from the inner ring.
            let groupHeight = pctSize.height + subSize.height + 2
            let percentY = center.y + groupHeight / 2 - pctSize.height
            text.draw(at: NSPoint(x: center.x - pctSize.width / 2, y: percentY),
                      withAttributes: attrs)
            sub.draw(at: NSPoint(x: center.x - subSize.width / 2,
                                 y: percentY - subSize.height - 2),
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
        // The neutral track is deliberately wider than the coloured progress.
        // The progress must sit inside the track rather than spilling over it.
        let trackWidth = width + 2
        let progressWidth = max(2, width - 1)
        ctx.setLineWidth(trackWidth)
        ctx.setLineCap(.butt)
        ctx.setStrokeColor(NSColor.tertiaryLabelColor.withAlphaComponent(0.24).cgColor)
        ctx.addArc(center: center, radius: radius, startAngle: 0, endAngle: .pi * 2, clockwise: false)
        ctx.strokePath()

        // The reference is anchored at 12 o'clock. Remaining quota is drawn
        // clockwise from that fixed top point; as the balance falls, the empty
        // gap therefore expands counterclockwise. At 87% the endpoint lands in
        // the upper-left quadrant, matching the supplied reference image.
        let trim = CGFloat(min(100, max(0, remainingPercent))) / 100
        guard trim > 0.005 else { return }

        let startAngle: CGFloat = .pi / 2
        let endAngle: CGFloat = startAngle - .pi * 2 * trim
        let isFullRing = trim >= 0.995

        // Render the colour field along the path, rather than clipping one
        // linear gradient into each individual circle. That makes all three
        // rings visibly belong to one gauge and keeps the colour direction
        // stable regardless of radius or percentage.
        let segments = max(16, Int(ceil(trim * 128)))
        let angleStep = .pi * 2 * trim / CGFloat(segments)
        ctx.setLineWidth(progressWidth)
        ctx.setLineCap(.round)
        for index in 0 ..< segments {
            let progress = (CGFloat(index) + 0.5) / CGFloat(segments)
            let segmentStart = startAngle - CGFloat(index) * angleStep
            let segmentEnd = startAngle - CGFloat(index + 1) * angleStep
            ctx.setStrokeColor(spectrumColor(at: progress, tone: tone, remainingPercent: remainingPercent).cgColor)
            ctx.addArc(center: center, radius: radius,
                       startAngle: segmentStart, endAngle: segmentEnd, clockwise: true)
            ctx.strokePath()
        }

        // Partial rings get a compact endpoint highlight. A full ring deliberately
        // has no endpoint dot, so 100% reads as a clean, uninterrupted circle.
        guard !isFullRing else { return }
        let point = CGPoint(x: center.x + cos(endAngle) * radius, y: center.y + sin(endAngle) * radius)
        let endpointColor = spectrumColor(at: 1, tone: tone, remainingPercent: remainingPercent)
        let endpointRadius = progressWidth / 2
        ctx.setFillColor(endpointColor.cgColor)
        ctx.fillEllipse(in: CGRect(
            x: point.x - endpointRadius,
            y: point.y - endpointRadius,
            width: endpointRadius * 2,
            height: endpointRadius * 2))
        ctx.setFillColor(NSColor.white.withAlphaComponent(0.94).cgColor)
        ctx.fillEllipse(in: CGRect(x: point.x - 1.6, y: point.y - 1.6, width: 3.2, height: 3.2))
    }

    static func tone(for label: String) -> Tone {
        switch label.lowercased() {
        case "session", "5h", "5-hour", "five_hour": .session
        case "weekly", "week": .weekly
        case "balance": .balance
        default: .monthly
        }
    }

    /// Split the reference's mint → cyan → blue → violet spectrum across the
    /// three periods instead of repeating a full rainbow on every circle.
    /// Lower remaining quota always deepens the corresponding colour family.
    private static func spectrumColor(at progress: CGFloat, tone: Tone, remainingPercent: Double) -> NSColor {
        let stops: [(position: CGFloat, color: RGB)]
        switch tone {
        case .session:
            stops = [
                (0, RGB(red: 0.17, green: 0.91, blue: 0.67)),
                (1, RGB(red: 0.00, green: 0.70, blue: 0.77)),
            ]
        case .weekly:
            stops = [
                (0, RGB(red: 0.16, green: 0.80, blue: 0.96)),
                (1, RGB(red: 0.10, green: 0.48, blue: 0.96)),
            ]
        case .monthly:
            stops = [
                (0, RGB(red: 0.25, green: 0.55, blue: 0.98)),
                (1, RGB(red: 0.42, green: 0.29, blue: 0.91)),
            ]
        case .balance:
            stops = [
                (0, RGB(red: 0.20, green: 0.80, blue: 0.95)),
                (1, RGB(red: 0.16, green: 0.42, blue: 0.98)),
            ]
        }
        let t = min(1, max(0, progress))
        let nextIndex = stops.firstIndex(where: { t <= $0.position }) ?? (stops.count - 1)
        let previous = stops[max(0, nextIndex - 1)]
        let next = stops[nextIndex]
        let local = next.position == previous.position ? 0 : (t - previous.position) / (next.position - previous.position)
        var color = RGB.interpolate(from: previous.color, to: next.color, progress: local)

        let remaining = CGFloat(min(100, max(0, remainingPercent))) / 100
        let depth = 1 - remaining
        let toneBrightness: CGFloat
        switch tone {
        case .session: toneBrightness = 1.00
        case .weekly: toneBrightness = 0.97
        case .monthly: toneBrightness = 0.94
        case .balance: toneBrightness = 0.98
        }
        // 100% is luminous; depleted quota becomes deeper without ever losing
        // enough contrast against the azure card to disappear into it.
        let brightness = toneBrightness * (1.00 - depth * 0.31)
        color = color.scaled(by: brightness)
        return NSColor(calibratedRed: color.red, green: color.green, blue: color.blue, alpha: 1)
    }

    private struct RGB {
        var red: CGFloat
        var green: CGFloat
        var blue: CGFloat

        static func interpolate(from: RGB, to: RGB, progress: CGFloat) -> RGB {
            RGB(
                red: from.red + (to.red - from.red) * progress,
                green: from.green + (to.green - from.green) * progress,
                blue: from.blue + (to.blue - from.blue) * progress)
        }

        func scaled(by multiplier: CGFloat) -> RGB {
            RGB(
                red: min(1, red * multiplier),
                green: min(1, green * multiplier),
                blue: min(1, blue * multiplier))
        }
    }
}
