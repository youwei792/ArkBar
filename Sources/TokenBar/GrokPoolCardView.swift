import AppKit

/// GrokPool (grok2api admin gateway) card: a 24-hour request-success ring with
/// three legend rows (Requests / Billed cost / Success rate), plus the token
/// split, account health, and top model below the ring.
final class GrokPoolCardView: NSView {
    private let plan: PlanSnapshot
    private let summary: GrokPoolSummary
    private let now: Date

    private let horizontalPadding: CGFloat = 14
    private let verticalPadding: CGFloat = 12
    private let ringSize: CGFloat = 132

    init(plan: PlanSnapshot, now: Date, width: CGFloat) {
        self.plan = plan
        self.summary = plan.grokPool ?? GrokPoolSummary(
            period: "24h",
            requests: 0, successfulRequests: 0, failedRequests: 0,
            successRate: 0,
            inputTokens: 0, cachedInputTokens: 0, outputTokens: 0, reasoningTokens: 0,
            tokens: 0,
            costUSD: 0,
            activeAccounts: 0, totalAccounts: 0,
            topModel: nil)
        self.now = now
        let height = Self.computeHeight()
        super.init(frame: NSRect(x: 0, y: 0, width: width, height: height))
        build()
    }

    required init?(coder: NSCoder) { fatalError() }

    nonisolated static func computeHeight() -> CGFloat {
        12 + 20 + 8 + 132 + 15 + 13 + 13 + 13 + 12
    }

    private func build() {
        var y = bounds.height - verticalPadding
        buildTitleRow(atY: &y)
        y -= 8
        buildRingAndLegend(atY: &y)
    }

    // MARK: - Title row

    private func buildTitleRow(atY y: inout CGFloat) {
        let logo = ProviderLogo.image(for: .grokPool)
        var titleX = horizontalPadding
        if let logo {
            let logoView = NSImageView(frame: NSRect(x: horizontalPadding, y: y - 16, width: 14, height: 14))
            logoView.image = logo
            logoView.imageScaling = .scaleProportionallyDown
            addSubview(logoView)
            titleX = horizontalPadding + 18
        }

        let titleField = label(plan.product.displayName, font: .systemFont(ofSize: 13, weight: .semibold),
                               color: .labelColor)
        titleField.frame = NSRect(x: titleX, y: y - 17,
                                  width: bounds.width - titleX - horizontalPadding, height: 18)
        titleField.toolTip = titleField.stringValue
        addSubview(titleField)
        y -= 20
    }

    // MARK: - Ring + legend

    private func buildRingAndLegend(atY y: inout CGFloat) {
        let successRate = min(100, max(0, summary.successRate))
        let ringImage = RingRenderer.makeImage(
            rings: [RingRenderer.Ring(
                id: "success",
                label: L(.grokPoolSuccessRate),
                remainingPercent: successRate,
                tone: .balance)],
            primaryRemaining: successRate,
            primaryLabel: L(.grokPoolSuccessRate),
            size: ringSize)
        let imageView = NSImageView(frame: NSRect(x: horizontalPadding, y: y - ringSize,
                                                  width: ringSize, height: ringSize))
        imageView.image = ringImage
        imageView.imageScaling = .scaleNone
        imageView.imageAlignment = .alignCenter
        imageView.wantsLayer = true
        addSubview(imageView)

        let symbol = "$"
        var rows: [(label: String, value: String, detail: String)] = []
        rows.append((
            label: L(.grokPoolRequests),
            value: DeepSeekCardView.grouped(summary.requests),
            detail: String(format: L(.grokPoolRequestDetail),
                           DeepSeekCardView.grouped(summary.successfulRequests),
                           DeepSeekCardView.grouped(summary.failedRequests))))
        rows.append((
            label: L(.grokPoolCost),
            value: Self.money(summary.costUSD, symbol: symbol),
            detail: String(format: L(.grokPoolTokenTotal), DeepSeekCardView.compactTokens(summary.tokens))))
        rows.append((
            label: L(.grokPoolSuccessRate),
            value: String(format: "%.1f%%", successRate),
            detail: ""))

        let legendX = horizontalPadding + ringSize + 14
        let legendWidth = bounds.width - legendX - horizontalPadding
        let valueWidth: CGFloat = 84
        for (index, row) in rows.enumerated() {
            let legendY = y - 8 - CGFloat(index) * 42
            let dot = NSView(frame: NSRect(x: legendX, y: legendY - 12, width: 8, height: 8))
            dot.wantsLayer = true
            dot.layer?.backgroundColor = NSColor.systemGreen.withAlphaComponent(0.85).cgColor
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

        // Below the ring: token split, account health, and the top model.
        let tokenField = label(
            String(format: L(.grokPoolTokenDetail),
                   Self.compactTokens(summary.inputTokens),
                   Self.compactTokens(summary.cachedInputTokens),
                   Self.compactTokens(summary.outputTokens),
                   Self.compactTokens(summary.reasoningTokens)),
            font: .systemFont(ofSize: 10),
            color: .secondaryLabelColor)
        tokenField.lineBreakMode = .byTruncatingTail
        tokenField.toolTip = tokenField.stringValue
        tokenField.frame = NSRect(x: horizontalPadding, y: y - ringSize - 15,
                                  width: bounds.width - horizontalPadding * 2, height: 13)
        addSubview(tokenField)

        let accountField = label(
            String(format: L(.grokPoolAccounts),
                   DeepSeekCardView.grouped(summary.activeAccounts),
                   DeepSeekCardView.grouped(summary.totalAccounts)),
            font: .systemFont(ofSize: 10),
            color: .secondaryLabelColor)
        accountField.lineBreakMode = .byTruncatingTail
        accountField.frame = NSRect(x: horizontalPadding, y: y - ringSize - 28,
                                    width: bounds.width - horizontalPadding * 2, height: 13)
        addSubview(accountField)

        if let topModel = summary.topModel, !topModel.isEmpty {
            let modelField = label(
                String(format: L(.deepseekTopModel), topModel),
                font: .systemFont(ofSize: 9),
                color: .tertiaryLabelColor)
            modelField.lineBreakMode = .byTruncatingTail
            modelField.toolTip = modelField.stringValue
            modelField.frame = NSRect(x: horizontalPadding, y: y - ringSize - 41,
                                      width: bounds.width - horizontalPadding * 2, height: 12)
            addSubview(modelField)
        }
    }



    // MARK: - Formatting (static for tests)

    static func compactTokens(_ count: Int) -> String {
        DeepSeekCardView.compactTokens(count)
    }

    static func money(_ amount: Double, symbol: String) -> String {
        String(format: "%@%.2f", symbol, amount)
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
