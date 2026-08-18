import AppKit

/// LongCat (longcat.chat) card: a token-resource-package remaining-percent ring
/// with the quota breakdown (total / used / available) and optional fuel-pack
/// balance below the ring.
final class LongCatCardView: NSView {
    private let plan: PlanSnapshot
    private let summary: LongCatSummary
    private let now: Date

    private let horizontalPadding: CGFloat = 14
    private let verticalPadding: CGFloat = 12
    private let ringSize: CGFloat = 132

    init(plan: PlanSnapshot, now: Date, width: CGFloat) {
        self.plan = plan
        self.summary = plan.longcat ?? LongCatSummary(
            totalToken: 0, usedToken: 0, availableToken: 0,
            fuelPackTotal: nil, fuelPackRemaining: nil,
            nearestFuelExpiry: nil, accountName: nil)
        self.now = now
        let height = Self.computeHeight(hasFuelPack: summary.fuelPackTotal != nil)
        super.init(frame: NSRect(x: 0, y: 0, width: width, height: height))
        build()
    }

    required init?(coder: NSCoder) { fatalError() }

    nonisolated static func computeHeight(hasFuelPack: Bool) -> CGFloat {
        // title + ring + quota rows + optional fuel pack + padding
        12 + 20 + 8 + 132 + 15 + 13 + 13 + (hasFuelPack ? 13 : 0) + 12
    }

    private func build() {
        var y = bounds.height - verticalPadding
        buildTitleRow(atY: &y)
        y -= 8
        buildRingAndLegend(atY: &y)
    }

    // MARK: - Title row

    private func buildTitleRow(atY y: inout CGFloat) {
        let logo = ProviderLogo.image(for: .longcat)
        var titleX = horizontalPadding
        if let logo {
            let logoView = NSImageView(frame: NSRect(x: horizontalPadding, y: y - 16, width: 14, height: 14))
            logoView.image = logo
            logoView.imageScaling = .scaleProportionallyDown
            addSubview(logoView)
            titleX = horizontalPadding + 18
        }

        let titleText = summary.accountName.map { "\(plan.product.displayName) · \($0)" }
            ?? plan.product.displayName
        let titleField = label(titleText, font: .systemFont(ofSize: 13, weight: .semibold),
                               color: .labelColor)
        titleField.frame = NSRect(x: titleX, y: y - 17,
                                  width: bounds.width - titleX - horizontalPadding, height: 18)
        titleField.toolTip = titleText
        addSubview(titleField)
        y -= 20
    }

    // MARK: - Ring + legend

    private func buildRingAndLegend(atY y: inout CGFloat) {
        let remaining = min(100, max(0, summary.remainingPercent))
        let ringImage = RingRenderer.makeImage(
            rings: [RingRenderer.Ring(
                id: "quota",
                label: L(.longCatTokenQuota),
                remainingPercent: remaining,
                tone: .balance)],
            primaryRemaining: remaining,
            primaryLabel: L(.longCatTokenQuota),
            size: ringSize)
        let imageView = NSImageView(frame: NSRect(x: horizontalPadding, y: y - ringSize,
                                                  width: ringSize, height: ringSize))
        imageView.image = ringImage
        imageView.imageScaling = .scaleNone
        imageView.imageAlignment = .alignCenter
        imageView.wantsLayer = true
        addSubview(imageView)

        var rows: [(label: String, value: String, detail: String)] = []
        rows.append((
            label: L(.longCatTotalTokens),
            value: Self.compactTokens(summary.totalToken),
            detail: ""))
        rows.append((
            label: L(.longCatUsedTokens),
            value: Self.compactTokens(summary.usedToken),
            detail: String(format: L(.longCatUsedPercent), summary.usedPercent)))
        rows.append((
            label: L(.longCatAvailableTokens),
            value: Self.compactTokens(summary.availableToken),
            detail: String(format: L(.longCatRemainingPercent), remaining)))

        let legendX = horizontalPadding + ringSize + 14
        let legendWidth = bounds.width - legendX - horizontalPadding
        let valueWidth: CGFloat = 84
        for (index, row) in rows.enumerated() {
            let legendY = y - 8 - CGFloat(index) * 42
            let dot = NSView(frame: NSRect(x: legendX, y: legendY - 12, width: 8, height: 8))
            dot.wantsLayer = true
            let dotColor = index == 2
                ? (remaining >= 20 ? NSColor.systemGreen : NSColor.systemOrange)
                : NSColor.systemBlue
            dot.layer?.backgroundColor = dotColor.withAlphaComponent(0.85).cgColor
            dot.layer?.cornerRadius = 4
            addSubview(dot)

            let value = label(row.value, font: .monospacedDigitSystemFont(ofSize: 10, weight: .medium),
                              color: .labelColor)
            value.alignment = .right
            value.frame = NSRect(x: legendX + legendWidth - valueWidth, y: legendY - 17,
                                 width: valueWidth, height: 14)
            addSubview(value)

            let nameField = label(row.label, font: .systemFont(ofSize: 11), color: .labelColor)
            let nameW = max(0, legendX + legendWidth - valueWidth - (legendX + 14) - 8)
            nameField.frame = NSRect(x: legendX + 14, y: legendY - 17, width: nameW, height: 14)
            addSubview(nameField)

            if !row.detail.isEmpty {
                let detailField = label(row.detail, font: .systemFont(ofSize: 10),
                                        color: .secondaryLabelColor)
                detailField.lineBreakMode = .byTruncatingTail
                detailField.toolTip = row.detail
                detailField.frame = NSRect(x: legendX + 14, y: legendY - 34,
                                           width: legendWidth - 14, height: 13)
                addSubview(detailField)
            }
        }

        // Below the ring: optional fuel-pack balance.
        if let fuelTotal = summary.fuelPackTotal, fuelTotal > 0,
           let fuelRemaining = summary.fuelPackRemaining
        {
            let fuelField = label(
                String(format: L(.longCatFuelPack),
                       Self.compactTokens(fuelRemaining),
                       Self.compactTokens(fuelTotal)),
                font: .systemFont(ofSize: 10),
                color: .secondaryLabelColor)
            fuelField.lineBreakMode = .byTruncatingTail
            fuelField.toolTip = fuelField.stringValue
            fuelField.frame = NSRect(x: horizontalPadding, y: y - ringSize - 15,
                                     width: bounds.width - horizontalPadding * 2, height: 13)
            addSubview(fuelField)

            if let expiry = summary.nearestFuelExpiry {
                let expiryField = label(
                    String(format: L(.longCatFuelExpiry), Self.countdown(to: expiry)),
                    font: .systemFont(ofSize: 9),
                    color: .tertiaryLabelColor)
                expiryField.lineBreakMode = .byTruncatingTail
                expiryField.frame = NSRect(x: horizontalPadding, y: y - ringSize - 28,
                                           width: bounds.width - horizontalPadding * 2, height: 12)
                addSubview(expiryField)
            }
        }
    }

    // MARK: - Formatting (static for tests)

    static func compactTokens(_ count: Double) -> String {
        let abs = abs(count)
        if abs >= 1_000_000_000 {
            return String(format: "%.1fB", count / 1_000_000_000)
        }
        if abs >= 1_000_000 {
            return String(format: "%.1fM", count / 1_000_000)
        }
        if abs >= 1_000 {
            return String(format: "%.1fK", count / 1_000)
        }
        return String(format: "%.0f", count)
    }

    private static func countdown(to future: Date) -> String {
        let interval = future.timeIntervalSinceNow
        if interval <= 0 { return L(.now) }
        let days = Int(interval) / 86400
        if days > 0 { return "\(days)\(L(.dayShort))" }
        let hours = (Int(interval) % 86400) / 3600
        if hours > 0 { return "\(hours)\(L(.hourShort))" }
        let minutes = (Int(interval) % 3600) / 60
        return "\(minutes)\(L(.minShort))"
    }

    // MARK: - Helpers

    private func label(_ text: String, font: NSFont, color: NSColor) -> NSTextField {
        let f = NSTextField(labelWithString: text)
        f.font = font
        f.textColor = color
        f.lineBreakMode = .byTruncatingTail
        return f
    }
}
