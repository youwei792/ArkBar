import AppKit

/// A rich plan card drawn entirely with AppKit. Avoids NSHostingView/SwiftUI
/// rendering issues inside NSMenuItem.
///
/// Uses standard (unflipped) coordinates: origin at bottom-left, y up.
/// Layout starts from the top (bounds.height - padding) and works downward.
///
/// Layout:
///   [Plan Name]                    [tier] [edition] [seat]
///   [ring]  [session  N% used]
///           [weekly   N% used]
///           [monthly  N% used]
///   Session  resets in Xd Xh
///   Weekly   resets in Xd Xh
///   Monthly  resets in Xd Xh
///   📅 还有 X 天到期
final class PlanCardView: NSView {
    private let plan: PlanSnapshot
    private let now: Date

    private let horizontalPadding: CGFloat = 14
    private let verticalPadding: CGFloat = 12
    private let ringSize: CGFloat = 132
    private var hoverTrackingArea: NSTrackingArea?

    init(plan: PlanSnapshot, now: Date, width: CGFloat) {
        self.plan = plan
        self.now = now
        let height = Self.computeHeight(plan)
        super.init(frame: NSRect(x: 0, y: 0, width: width, height: height))
        wantsLayer = true
        layer?.cornerRadius = 10
        build()
    }

    required init?(coder: NSCoder) { fatalError() }

    override func updateTrackingAreas() {
        if let hoverTrackingArea { removeTrackingArea(hoverTrackingArea) }
        let area = NSTrackingArea(
            rect: bounds,
            options: [.mouseEnteredAndExited, .activeInActiveApp, .inVisibleRect],
            owner: self,
            userInfo: nil)
        addTrackingArea(area)
        hoverTrackingArea = area
    }

    override func mouseEntered(with event: NSEvent) { setHovered(true) }
    override func mouseExited(with event: NSEvent) { setHovered(false) }

    private func setHovered(_ hovered: Bool) {
        guard !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else {
            layer?.backgroundColor = hovered ? NSColor.controlAccentColor.withAlphaComponent(0.08).cgColor : nil
            return
        }
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.16
            layer?.backgroundColor = hovered ? NSColor.controlAccentColor.withAlphaComponent(0.08).cgColor : nil
        }
    }

    nonisolated static func computeHeight(_ plan: PlanSnapshot) -> CGFloat {
        // The reset details live beside the gauge, so the card stays compact and
        // never creates a second, text-heavy block below it.
        12 + 20 + 8 + 132 + 12
    }

    private func build() {
        // Unflipped coords: start from top (bounds.height - padding), y decreases downward.
        var y = bounds.height - verticalPadding

        // Title row.
        buildTitleRow(atY: &y)
        y -= 8

        // Ring + legend.
        buildRingAndLegend(atY: &y)
        y -= 12

    }

    // MARK: - Title row

    private func buildTitleRow(atY y: inout CGFloat) {
        let title = plan.product.displayName
        let titleField = label(title, font: .systemFont(ofSize: 13, weight: .semibold),
                               color: .labelColor)
        let badge = makeExpiryBadge()
        let badgeWidth = badge?.frame.width ?? 0
        titleField.frame = NSRect(x: horizontalPadding, y: y - 17,
                                  width: bounds.width - horizontalPadding * 2 - badgeWidth - (badge == nil ? 0 : 8),
                                  height: 18)
        titleField.toolTip = title
        addSubview(titleField)
        if let badge {
            badge.frame.origin = NSPoint(x: bounds.width - horizontalPadding - badge.frame.width, y: y - 18)
            addSubview(badge)
        }
        y -= 20
    }

    // MARK: - Ring + legend

    private func buildRingAndLegend(atY y: inout CGFloat) {
        // Render the ring gauge into an NSImage and display via NSImageView.
        // This bypasses NSMenu's compositing issues with NSView.draw(_:).
        let ringImage = RingRenderer.makeImage(
            rings: rings,
            tightestRemaining: plan.tightestWindow?.remainingPercent,
            size: ringSize)
        let imageView = NSImageView(frame: NSRect(x: horizontalPadding, y: y - ringSize,
                                                  width: ringSize, height: ringSize))
        imageView.image = ringImage
        imageView.imageScaling = .scaleProportionallyUpOrDown
        imageView.wantsLayer = true
        addSubview(imageView)
        animateGaugeEntrance(imageView)

        // Legend to the right of the ring.
        let legendX = horizontalPadding + ringSize + 14
        let legendWidth = bounds.width - legendX - horizontalPadding
        let percentageWidth: CGFloat = 70
        // Three concise rows occupy the same vertical area as the ring. Each
        // keeps its percentage and reset moment together, rather than splitting
        // the data into a clipped list below the gauge.
        for (index, row) in legendRows.prefix(3).enumerated() {
            let ring = row.ring
            let legendY = y - 8 - CGFloat(index) * 42
            // Color dot.
            let dot = NSView(frame: NSRect(x: legendX, y: legendY - 12, width: 8, height: 8))
            dot.wantsLayer = true
            dot.layer?.backgroundColor = ring.color.cgColor
            dot.layer?.cornerRadius = 4
            addSubview(dot)

            // Reserve a fixed, right-aligned percentage column. `sizeToFit()`
            // makes NSTextField's intrinsic width vulnerable to NSMenu's content
            // inset and was the source of values such as "6..." in the popover.
            let pct = String(format: L(.remainingPercent), Int(row.window.remainingPercent.rounded()))
            let pctField = label(pct, font: .monospacedDigitSystemFont(ofSize: 10, weight: .medium),
                                 color: ring.color)
            pctField.alignment = .right
            let pctX = legendX + legendWidth - percentageWidth
            pctField.frame = NSRect(x: pctX, y: legendY - 17,
                                    width: percentageWidth, height: 14)
            addSubview(pctField)

            // Label (fills the space between the dot and the percent).
            let nameField = label(ring.label, font: .systemFont(ofSize: 11),
                                  color: .labelColor)
            let nameW = max(0, pctX - (legendX + 14) - 8)
            nameField.frame = NSRect(x: legendX + 14, y: legendY - 17,
                                     width: nameW, height: 14)
            addSubview(nameField)

            let resetText = row.window.resetsAt.map {
                "\(L(.resets)) \(MenuBuilder.countdown(from: now, to: $0))"
            } ?? L(.noResetTime)
            let resetField = label(resetText, font: .systemFont(ofSize: 10), color: .secondaryLabelColor)
            resetField.frame = NSRect(x: legendX + 14, y: legendY - 34,
                                      width: legendWidth - 14, height: 13)
            resetField.toolTip = resetText
            addSubview(resetField)
        }

        y -= ringSize
    }

    /// A compact, color-coded expiry badge is intentionally placed next to the
    /// plan name: it conveys subscription urgency at a glance without confusing
    /// it with the quota-reset times beside the ring.
    private func makeExpiryBadge() -> NSView? {
        guard let expiryDate = plan.expiryDate else { return nil }
        let days = plan.daysUntilExpiry ?? 0
        let text = days > 0 ? String(format: L(.expiresIn), days) : L(.expired)
        let color: NSColor
        switch days {
        case ...0: color = .systemRed
        case ...7: color = .systemOrange
        case ...21: color = .systemYellow
        default: color = .systemTeal
        }
        let badge = CapsuleBadgeView(text: text, foregroundColor: color)
        let formatter = DateFormatter()
        formatter.locale = L10n.shared.locale
        formatter.setLocalizedDateFormatFromTemplate("yMMMd")
        badge.toolTip = String(format: L(.expiresOn), formatter.string(from: expiryDate))
        return badge
    }

    // MARK: - Helpers

    private func label(_ text: String, font: NSFont, color: NSColor) -> NSTextField {
        let f = NSTextField(labelWithString: text)
        f.font = font
        f.textColor = color
        f.lineBreakMode = .byTruncatingTail
        return f
    }

    /// A short entrance makes freshly synchronized values feel live while keeping
    /// this utility menu calm. The system Reduce Motion preference always wins.
    private func animateGaugeEntrance(_ imageView: NSImageView) {
        guard !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion,
              let layer = imageView.layer
        else { return }
        let scale = CABasicAnimation(keyPath: "transform.scale")
        scale.fromValue = 0.94
        scale.toValue = 1
        let opacity = CABasicAnimation(keyPath: "opacity")
        opacity.fromValue = 0
        opacity.toValue = 1
        let group = CAAnimationGroup()
        group.animations = [scale, opacity]
        group.duration = 0.26
        group.timingFunction = CAMediaTimingFunction(name: .easeOut)
        layer.add(group, forKey: "arkbar.gaugeEntrance")
    }

    /// Rings in drawing order: outer -> inner = monthly, weekly, session.
    private var rings: [RingRenderer.Ring] {
        let windows = plan.windows
        func find(_ labels: Set<String>) -> UsageWindow? {
            windows.first { labels.contains($0.label.lowercased()) }
        }
        let monthly = find(["monthly", "month"])
        let weekly = find(["weekly", "week"])
        let session = find(["session", "5-hour", "5h", "five_hour"])

        return [
            monthly.map { RingRenderer.Ring(id: "monthly", label: L(.monthly), usedPercent: $0.usedPercent, color: RingRenderer.accentColor(remainingPercent: $0.remainingPercent)) },
            weekly.map { RingRenderer.Ring(id: "weekly", label: L(.weekly), usedPercent: $0.usedPercent, color: RingRenderer.accentColor(remainingPercent: $0.remainingPercent)) },
            session.map { RingRenderer.Ring(id: "session", label: L(.session), usedPercent: $0.usedPercent, color: RingRenderer.accentColor(remainingPercent: $0.remainingPercent)) },
        ].compactMap { $0 }
    }

    /// Rows beside the ring: shortest reset window first, with all of its
    /// information kept together.
    private var legendRows: [(window: UsageWindow, ring: RingRenderer.Ring)] {
        plan.windows
            .filter { $0.sortRank < 3 }
            .sorted { $0.sortRank < $1.sortRank }
            .map { window in
                (window, RingRenderer.Ring(
                    id: window.label,
                    label: window.displayName,
                    usedPercent: window.usedPercent,
                    color: RingRenderer.accentColor(remainingPercent: window.remainingPercent)))
            }
    }
}

/// Text in a menu-backed NSTextField is baseline-aligned rather than vertically
/// centered. Draw the capsule ourselves so its label remains optically centered
/// on every macOS text rendering scale.
private final class CapsuleBadgeView: NSView {
    private let text: String
    private let foregroundColor: NSColor
    private let font = NSFont.systemFont(ofSize: 10, weight: .semibold)

    init(text: String, foregroundColor: NSColor) {
        self.text = text
        self.foregroundColor = foregroundColor
        let textWidth = (text as NSString).size(withAttributes: [.font: font]).width
        super.init(frame: NSRect(x: 0, y: 0, width: ceil(textWidth) + 16, height: 20))
        wantsLayer = true
    }

    required init?(coder: NSCoder) { fatalError() }

    override func draw(_ dirtyRect: NSRect) {
        foregroundColor.withAlphaComponent(0.16).setFill()
        NSBezierPath(roundedRect: bounds, xRadius: bounds.height / 2, yRadius: bounds.height / 2).fill()

        let style = NSMutableParagraphStyle()
        style.alignment = .center
        style.lineBreakMode = .byClipping
        let attributes: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: foregroundColor,
            .paragraphStyle: style,
        ]
        let textHeight = (text as NSString).boundingRect(
            with: NSSize(width: bounds.width - 8, height: .greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin, .usesFontLeading],
            attributes: attributes).height
        let textRect = NSRect(
            x: 4,
            y: floor((bounds.height - textHeight) / 2),
            width: bounds.width - 8,
            height: ceil(textHeight))
        (text as NSString).draw(with: textRect, options: [.usesLineFragmentOrigin, .usesFontLeading], attributes: attributes)
    }
}
