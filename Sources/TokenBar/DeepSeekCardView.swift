import AppKit

/// DeepSeek plan card: one balance ring (this month's spend vs spend + balance)
/// with three legend rows (Balance / Today / This month), mirroring the other
/// providers' card layout. Drawn entirely with AppKit like PlanCardView.
///
/// Layout:
///   [logo] DeepSeek
///   [ring]  [Balance  ¥45.00]
///           [Today    ¥1.23  ]
///           [Monthly  ¥10.00 ]
final class DeepSeekCardView: NSView {
    private let plan: PlanSnapshot
    private let summary: DeepSeekSummary
    private let now: Date

    private let horizontalPadding: CGFloat = 14
    private let verticalPadding: CGFloat = 12
    private let ringSize: CGFloat = 132

    init(plan: PlanSnapshot, now: Date, width: CGFloat) {
        self.plan = plan
        self.summary = plan.deepseek ?? DeepSeekSummary(
            currency: "CNY", totalBalance: 0, grantedBalance: 0, toppedUpBalance: 0,
            todayTokens: 0, currentMonthTokens: 0, todayCost: nil, currentMonthCost: nil,
            requestCount: 0, currentMonthRequestCount: 0, topModel: nil,
            promptCacheHitTokens: 0, promptCacheMissTokens: 0, responseTokens: 0,
            usageAvailable: false)
        self.now = now
        let height = Self.computeHeight()
        super.init(frame: NSRect(x: 0, y: 0, width: width, height: height))
        build()
    }

    required init?(coder: NSCoder) { fatalError() }

    nonisolated static func computeHeight() -> CGFloat {
        // Title (20) + gap (8) + ring (132) + category row (15+13) + model row (5+12) + paddings.
        12 + 20 + 8 + 132 + 15 + 13 + 5 + 12 + 12
    }

    private func build() {
        // Unflipped coords: start from top, y decreases downward.
        var y = bounds.height - verticalPadding

        buildTitleRow(atY: &y)
        y -= 8
        buildRingAndLegend(atY: &y)
    }

    // MARK: - Title row

    private func buildTitleRow(atY y: inout CGFloat) {
        let logo = ProviderLogo.image(for: .deepseek)
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
        let primaryWindow = plan.windows.first
        let remaining = primaryWindow?.remainingPercent ?? 0
        let ringImage = RingRenderer.makeImage(
            rings: [RingRenderer.Ring(
                id: "balance",
                label: L(.windowBalance),
                remainingPercent: remaining,
                tone: .balance)],
            primaryRemaining: remaining,
            primaryLabel: L(.windowBalance),
            size: ringSize)
        let imageView = NSImageView(frame: NSRect(x: horizontalPadding, y: y - ringSize,
                                                  width: ringSize, height: ringSize))
        imageView.image = ringImage
        imageView.imageScaling = .scaleNone
        imageView.imageAlignment = .alignCenter
        imageView.wantsLayer = true
        addSubview(imageView)

        let symbol = Self.currencySymbol(summary.currency)
        var rows: [(label: String, value: String, detail: String)] = []
        rows.append((
            label: L(.windowBalance),
            value: Self.money(summary.totalBalance, symbol: symbol),
            detail: String(format: L(.deepseekPaidGranted),
                           Self.money(summary.toppedUpBalance, symbol: symbol),
                           Self.money(summary.grantedBalance, symbol: symbol))))
        if summary.usageAvailable {
            rows.append((
                label: L(.deepseekToday),
                value: summary.todayCost.map { Self.money($0, symbol: symbol) } ?? "—",
                detail: Self.usageDetail(tokens: summary.todayTokens, requests: summary.requestCount)))
            rows.append((
                label: L(.deepseekMonthly),
                value: summary.currentMonthCost.map { Self.money($0, symbol: symbol) } ?? "—",
                detail: Self.usageDetail(tokens: summary.currentMonthTokens,
                                         requests: summary.currentMonthRequestCount)))
        } else {
            rows.append((label: L(.deepseekToday), value: "—", detail: L(.deepseekUsageUnavailable)))
            rows.append((label: L(.deepseekMonthly), value: "—", detail: ""))
        }

        let legendX = horizontalPadding + ringSize + 14
        let legendWidth = bounds.width - legendX - horizontalPadding
        let valueWidth: CGFloat = 78
        for (index, row) in rows.enumerated() {
            let legendY = y - 8 - CGFloat(index) * 42
            let dot = NSView(frame: NSRect(x: legendX, y: legendY - 12, width: 8, height: 8))
            dot.wantsLayer = true
            dot.layer?.backgroundColor = NSColor.systemTeal.withAlphaComponent(0.85).cgColor
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

        // Below the ring: category breakdown (this month) and top model, placed
        // inside the card's own height so nothing is clipped by NSMenu.
        if summary.usageAvailable {
            let categoryField = label(
                String(format: L(.deepseekCategoryDetail),
                       Self.compactTokens(summary.promptCacheHitTokens),
                       Self.compactTokens(summary.promptCacheMissTokens),
                       Self.compactTokens(summary.responseTokens)),
                font: .systemFont(ofSize: 10),
                color: .secondaryLabelColor)
            categoryField.lineBreakMode = .byTruncatingTail
            categoryField.toolTip = categoryField.stringValue
            categoryField.frame = NSRect(x: horizontalPadding, y: y - ringSize - 15,
                                         width: bounds.width - horizontalPadding * 2, height: 13)
            addSubview(categoryField)
        }

        if let topModel = summary.topModel, !topModel.isEmpty {
            let modelField = label(
                String(format: L(.deepseekTopModel), topModel),
                font: .systemFont(ofSize: 9),
                color: .tertiaryLabelColor)
            modelField.lineBreakMode = .byTruncatingTail
            modelField.toolTip = modelField.stringValue
            modelField.frame = NSRect(x: horizontalPadding, y: y - ringSize - 33,
                                      width: bounds.width - horizontalPadding * 2, height: 12)
            addSubview(modelField)
        }
    }

    // MARK: - Formatting (static for tests)

    static func currencySymbol(_ currency: String) -> String {
        currency == "CNY" ? "¥" : "$"
    }

    static func money(_ amount: Double, symbol: String) -> String {
        String(format: "%@%.2f", symbol, amount)
    }

    /// 1_234_567 -> "1.2M", 12_345 -> "12.3K", 456 -> "456".
    static func compactTokens(_ count: Int) -> String {
        if count >= 1_000_000 {
            return String(format: "%.1fM", Double(count) / 1_000_000)
        }
        if count >= 1_000 {
            return String(format: "%.1fK", Double(count) / 1_000)
        }
        return Self.grouped(count)
    }

    static func grouped(_ number: Int) -> String {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        formatter.locale = L10n.shared.locale
        return formatter.string(from: NSNumber(value: number)) ?? String(number)
    }

    static func usageDetail(tokens: Int, requests: Int) -> String {
        String(format: L(.deepseekUsageDetail),
               compactTokens(tokens),
               grouped(requests))
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
