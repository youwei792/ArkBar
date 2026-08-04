import AppKit
import SwiftUI
import Foundation

/// Builds the dropdown NSMenu. Plan sections are rich AppKit cards (not SwiftUI)
/// because NSHostingView does not reliably render SwiftUI inside NSMenuItem.
enum MenuBuilder {
    /// Aggregate state handed to the menu builder.
    struct State {
        enum Status {
            case ok(snapshot: ProviderSnapshot)
            case stale(snapshot: ProviderSnapshot, message: String)
            case error(message: String)
            case loading
            case never
        }

        let status: Status
        let selectedMenu: MenuSelection
        /// Providers shown in the switcher (hidden ones are filtered upstream).
        var visibleTabs: [ProviderTab] = ProviderTab.allCases
        let onSelectTab: (ProviderTab) -> Void
        let onSelectSummary: (() -> Void)?
        let lastUpdatedAt: Date?
        let isRefreshing: Bool
        let now: Date
        let onRefresh: () -> Void
        let onSettings: () -> Void
        let onQuit: () -> Void

        /// All provider statuses for the summary view.
        var allStatuses: [ProviderTab: UsageStore.LoadStatus] = [:]

        var refreshErrorMessage: String? {
            switch status {
            case let .error(message), let .stale(_, message): message
            default: nil
            }
        }
    }

    @MainActor
    static func build(_ state: State) -> NSMenu {
        let menu = NSMenu()
        populate(menu, with: state)
        return menu
    }

    /// Reuses an already-attached menu instead of replacing
    /// `NSStatusItem.menu`. AppKit keeps that menu's tracking session alive, so
    /// provider switches and refresh completions update immediately without
    /// closing the popover or requiring a second status-item click.
    @MainActor
    static func populate(_ menu: NSMenu, with state: State) {
        menu.removeAllItems()
        menu.minimumWidth = 360
        menu.addItem(switcherItem(state: state))

        switch state.selectedMenu {
        case .summary:
            populateSummary(menu, state: state)
        case .provider:
            populateProvider(menu, state: state)
        }

        menu.addItem(.separator())
        menu.addItem(refreshItem(state: state))
        if case let .provider(tab) = state.selectedMenu {
            switch tab {
            case .ark:
                menu.addItem(actionItem(L(.openArkcliLogin), action: {
                    Self.openTerminal(command: "arkcli auth login volc-sso")
                }))
                menu.addItem(actionItem(L(.openArkConsole), action: {
                    NSWorkspace.shared.open(URL(string: "https://console.volcengine.com/ark/region:ark+cn-beijing/openManagement?LLM=%7B%7D&advancedActiveKey=subscribe")!)
                }))
            case .opencode:
                menu.addItem(actionItem(L(.openCodeGo), action: {
                    NSWorkspace.shared.open(URL(string: "https://opencode.ai")!)
                }))
            case .deepseek:
                menu.addItem(actionItem(L(.openDeepSeekPlatform), action: {
                    NSWorkspace.shared.open(URL(string: "https://platform.deepseek.com")!)
                }))
            case .nebula:
                menu.addItem(actionItem(L(.openNebulaConsole), action: {
                    NSWorkspace.shared.open(URL(string: "https://apinebula.ai/console")!)
                }))
            }
        }
        menu.addItem(actionItem(L(.settings), action: state.onSettings))
        menu.addItem(.separator())
        menu.addItem(actionItem(L(.quitTokenBar), action: state.onQuit))
    }

    // MARK: - Summary branch

    @MainActor
    private static func populateSummary(_ menu: NSMenu, state: State) {
        var hasContent = false
        for tab in state.visibleTabs {
            let loadStatus = state.allStatuses[tab] ?? .never
            let row = SummaryRowView(tab: tab, loadStatus: loadStatus, width: cardWidth) {
                state.onSelectTab(tab)
            }
            let item = NSMenuItem()
            item.view = row
            item.isEnabled = false
            menu.addItem(item)
            hasContent = true
        }
        if !hasContent {
            menu.addItem(loadingItem(text: L(.noProvider)))
        }
    }

    // MARK: - Provider branch (existing logic)

    @MainActor
    private static func populateProvider(_ menu: NSMenu, state: State) {
        switch state.status {
        case .never:
            menu.addItem(loadingItem(text: L(.loadingUsage)))
        case .loading:
            menu.addItem(loadingItem(text: L(.refreshing)))
        case let .error(message):
            menu.addItem(errorItem(message: message))
        case let .stale(snapshot, message):
            menu.addItem(headerItem(snapshot: snapshot))
            menu.addItem(errorItem(message: "\(L(.staleData))\n\(message)", isWarning: true))
            for plan in snapshot.plans {
                menu.addItem(planItem(plan: plan, now: state.now))
            }
        case let .ok(snapshot):
            menu.addItem(headerItem(snapshot: snapshot))
            if let message = snapshot.errorMessage, !message.isEmpty {
                menu.addItem(errorItem(message: message, isWarning: true))
            }
            for plan in snapshot.plans {
                menu.addItem(planItem(plan: plan, now: state.now))
            }
        }
    }

    // MARK: - Card items (AppKit-based)

    private static let cardWidth: CGFloat = 340

    @MainActor
    private static func switcherItem(state: State) -> NSMenuItem {
        let item = NSMenuItem()
        // Prefer the user's setting, but only show overview when 2+ providers
        // are visible (otherwise the tab is redundant).
        let showSummary = AppSettings.shared.showSummary && state.visibleTabs.count > 1
        item.view = ProviderSwitcherView(
            tabs: state.visibleTabs,
            selected: state.selectedMenu,
            showSummary: showSummary,
            width: cardWidth,
            onSelect: { selection in
                if case let .provider(tab) = selection {
                    state.onSelectTab(tab)
                } else {
                    state.onSelectSummary?()
                }
            })
        item.isEnabled = true
        return item
    }

    @MainActor
    private static func headerItem(snapshot: ProviderSnapshot) -> NSMenuItem {
        let item = NSMenuItem()
        let view = HeaderCardView(snapshot: snapshot, width: cardWidth)
        item.view = view
        item.isEnabled = false
        return item
    }

    @MainActor
    private static func planItem(plan: PlanSnapshot, now: Date) -> NSMenuItem {
        let item = NSMenuItem()
        if plan.deepseek != nil {
            item.view = DeepSeekCardView(plan: plan, now: now, width: cardWidth)
        } else if plan.nebula != nil {
            item.view = NebulaCardView(plan: plan, now: now, width: cardWidth)
        } else {
            item.view = PlanCardView(plan: plan, now: now, width: cardWidth)
        }
        item.isEnabled = false
        return item
    }

    @MainActor
    private static func loadingItem(text: String) -> NSMenuItem {
        let item = NSMenuItem()
        let view = LoadingCardView(text: text, width: cardWidth)
        item.view = view
        item.isEnabled = false
        return item
    }

    @MainActor
    private static func errorItem(message: String, isWarning: Bool = false) -> NSMenuItem {
        let item = NSMenuItem()
        let view = ErrorCardView(message: message, width: cardWidth, isWarning: isWarning)
        item.view = view
        item.isEnabled = false
        return item
    }

    // MARK: - Formatting

    static func progressBar(_ usedPercent: Double) -> String {
        let segments = 10
        let filled = Int((min(100, max(0, usedPercent)) / 100 * Double(segments)).rounded())
        return String(repeating: "█", count: filled) + String(repeating: "░", count: segments - filled)
    }

    static func countdown(from now: Date, to future: Date) -> String {
        let interval = future.timeIntervalSince(now)
        if interval <= 0 { return L(.now) }
        let days = Int(interval) / 86400
        let hours = (Int(interval) % 86400) / 3600
        let minutes = (Int(interval) % 3600) / 60
        return L10n.shared.countdown(days: days, hours: hours, minutes: minutes)
    }

    private static func actionItem(_ title: String, action: @escaping () -> Void) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: #selector(MenuActionTarget.invoke), keyEquivalent: "")
        let target = MenuActionTarget(action: action)
        item.target = target
        item.representedObject = target
        return item
    }

    @MainActor
    private static func refreshItem(state: State) -> NSMenuItem {
        let item = NSMenuItem()
        item.title = L(.refreshNow)
        item.view = RefreshMenuItemView(
            title: L(.refreshNow),
            isRefreshing: state.isRefreshing,
            lastUpdatedAt: state.lastUpdatedAt,
            errorMessage: state.refreshErrorMessage,
            action: state.onRefresh,
            width: cardWidth)
        item.action = nil
        item.target = nil
        return item
    }

    private static func openTerminal(command: String) {
        let script = """
        tell application "Terminal"
            activate
            do script "\(command)"
        end tell
        """
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        process.arguments = ["-e", script]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
        } catch {
            UsageStore.log("openTerminal failed: \(error.localizedDescription)")
        }
    }
}

// MARK: - SummaryRowView (compact per-provider row)

/// A compact row for the summary overview: logo + name + remaining percent +
/// the same capsule meter used by the status-item icon. Tapping navigates to
/// that provider's full card.
@MainActor
final class SummaryRowView: NSView {
    override var isFlipped: Bool { true }

    private let onTap: () -> Void
    private let remainingPercent: Double?
    private let isStale: Bool
    private let hoverView = NSVisualEffectView()

    init(tab: ProviderTab, loadStatus: UsageStore.LoadStatus, width: CGFloat, onTap: @escaping () -> Void) {
        self.onTap = onTap
        let info = Self.statusInfo(for: loadStatus)
        self.remainingPercent = info.remaining
        self.isStale = info.stale
        super.init(frame: NSRect(x: 0, y: 0, width: width, height: 44))
        wantsLayer = true
        build(tab: tab, statusText: info.text, statusColor: info.color, width: width)
        let recognizer = NSClickGestureRecognizer(target: self, action: #selector(handleClick(_:)))
        recognizer.buttonMask = 0x1
        addGestureRecognizer(recognizer)
    }

    required init?(coder: NSCoder) { fatalError() }

    private func build(tab: ProviderTab, statusText: String, statusColor: NSColor, width: CGFloat) {
        let horizontalPadding: CGFloat = 14
        let rowHeight: CGFloat = 44
        let contentY = (rowHeight - 16) / 2

        hoverView.material = .selection
        hoverView.blendingMode = .withinWindow
        hoverView.state = .active
        hoverView.isEmphasized = true
        hoverView.wantsLayer = true
        hoverView.layer?.cornerRadius = 8
        hoverView.isHidden = true
        hoverView.frame = bounds.insetBy(dx: 6, dy: 2)
        addSubview(hoverView)

        // Fixed columns so every row lines up:
        // [logo 16] [name ~92] [percent 44 right-aligned] …… [meter 64]
        let logoSide: CGFloat = 16
        let nameColWidth: CGFloat = 92
        let percentColWidth: CGFloat = 44
        let meterWidth: CGFloat = 64
        let meterHeight: CGFloat = 8
        let gap: CGFloat = 8

        let logoX = horizontalPadding
        let nameX = logoX + logoSide + gap
        let percentX = nameX + nameColWidth + gap
        let meterX = width - horizontalPadding - meterWidth

        if let logo = ProviderLogo.image(for: tab) {
            // Keep brand color in the menu (template only for the status item).
            let logoView = NSImageView(frame: NSRect(
                x: logoX, y: contentY, width: logoSide, height: logoSide))
            let colored = logo.copy() as? NSImage ?? logo
            colored.size = NSSize(width: logoSide, height: logoSide)
            colored.isTemplate = false
            logoView.image = colored
            logoView.imageScaling = .scaleProportionallyDown
            addSubview(logoView)
        }

        let nameField = NSTextField(labelWithString: tab.displayName)
        nameField.font = .systemFont(ofSize: 12, weight: .medium)
        nameField.textColor = .labelColor
        nameField.lineBreakMode = .byTruncatingTail
        nameField.toolTip = tab.displayName
        nameField.frame = NSRect(x: nameX, y: contentY, width: nameColWidth, height: 16)
        addSubview(nameField)

        let detailField = NSTextField(labelWithString: statusText)
        detailField.font = .monospacedDigitSystemFont(ofSize: 12, weight: .semibold)
        detailField.textColor = statusColor
        detailField.alignment = .right
        detailField.lineBreakMode = .byClipping
        detailField.frame = NSRect(x: percentX, y: contentY, width: percentColWidth, height: 16)
        addSubview(detailField)

        if remainingPercent != nil {
            let meter = SummaryMeterView(frame: NSRect(
                x: meterX,
                y: (rowHeight - meterHeight) / 2,
                width: meterWidth,
                height: meterHeight))
            meter.remainingPercent = remainingPercent
            meter.isStale = isStale
            addSubview(meter)
        }

        let sep = NSBox(frame: NSRect(
            x: horizontalPadding, y: 0, width: width - horizontalPadding * 2, height: 0.5))
        sep.boxType = .separator
        addSubview(sep)
    }

    private static func statusInfo(for loadStatus: UsageStore.LoadStatus)
        -> (text: String, color: NSColor, remaining: Double?, stale: Bool)
    {
        switch loadStatus {
        case .never, .loading:
            return (L(.loadingUsage), .secondaryLabelColor, nil, true)
        case let .error(message):
            let short = message.count > 18 ? String(message.prefix(16)) + "…" : message
            return (short, .systemRed, nil, true)
        case let .stale(snapshot, _):
            if let pct = snapshot.sessionWindow?.remainingPercent {
                return ("\(Int(pct.rounded()))%", .labelColor, pct, true)
            }
            return (L(.staleData), .systemOrange, nil, true)
        case let .ok(snapshot):
            if let pct = snapshot.sessionWindow?.remainingPercent {
                return ("\(Int(pct.rounded()))%", .labelColor, pct, false)
            }
            return ("–", .secondaryLabelColor, nil, false)
        }
    }

    @objc private func handleClick(_ recognizer: NSClickGestureRecognizer) {
        guard recognizer.state == .ended else { return }
        onTap()
    }

    override func mouseEntered(with event: NSEvent) {
        hoverView.isHidden = false
    }

    override func mouseExited(with event: NSEvent) {
        hoverView.isHidden = true
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        for area in trackingAreas { removeTrackingArea(area) }
        let area = NSTrackingArea(
            rect: bounds,
            options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
            owner: self, userInfo: nil)
        addTrackingArea(area)
    }

    override func layout() {
        super.layout()
        hoverView.frame = bounds.insetBy(dx: 6, dy: 2)
    }
}

/// Draws the accent-gradient capsule meter used by summary rows.
@MainActor
private final class SummaryMeterView: NSView {
    var remainingPercent: Double?
    var isStale = false

    override var isFlipped: Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        IconRenderer.drawCapsuleBar(
            remainingPercent: remainingPercent,
            stale: isStale,
            in: bounds,
            style: .accentGradient)
    }
}

// MARK: - AppKit card views (unchanged)

/// Header card: TokenBar + provider name + auth method.
final class HeaderCardView: NSView {
    override var isFlipped: Bool { true }

    init(snapshot: ProviderSnapshot, width: CGFloat) {
        super.init(frame: NSRect(x: 0, y: 0, width: width, height: 54))
        wantsLayer = true

        let accent = CAGradientLayer()
        accent.colors = [
            NSColor.systemMint.withAlphaComponent(0.92).cgColor,
            NSColor.systemBlue.withAlphaComponent(0.9).cgColor,
            NSColor.systemIndigo.withAlphaComponent(0.9).cgColor,
        ]
        accent.startPoint = CGPoint(x: 0, y: 0.5)
        accent.endPoint = CGPoint(x: 1, y: 0.5)
        accent.frame = NSRect(x: 14, y: 50, width: width - 28, height: 2)
        layer?.addSublayer(accent)

        let title = NSTextField(labelWithString: "TokenBar")
        title.font = .systemFont(ofSize: 14, weight: .bold)
        title.textColor = .labelColor
        let titleSize = title.intrinsicContentSize
        let titleTrailingInset: CGFloat = 6
        title.frame = NSRect(
            x: 14,
            y: 15,
            width: ceil(titleSize.width) + titleTrailingInset,
            height: ceil(titleSize.height) + 2)
        addSubview(title)

        let detail = [snapshot.providerName, snapshot.authMethod.map { "\(L(.auth)): \($0)" }]
            .compactMap { $0 }
            .joined(separator: "  ·  ")
        let detailField = NSTextField(labelWithString: detail)
        detailField.font = .systemFont(ofSize: 10)
        detailField.textColor = .secondaryLabelColor
        detailField.alignment = .right
        detailField.lineBreakMode = .byTruncatingMiddle
        detailField.toolTip = detail
        detailField.frame = NSRect(x: max(118, title.frame.maxX + 16), y: 17,
                                   width: width - max(118, title.frame.maxX + 16) - 14, height: 14)
        addSubview(detailField)
    }

    required init?(coder: NSCoder) { fatalError() }
}

/// Loading card: centered text.
final class LoadingCardView: NSView {
    override var isFlipped: Bool { true }

    init(text: String, width: CGFloat) {
        super.init(frame: NSRect(x: 0, y: 0, width: width, height: 44))
        wantsLayer = true
        layer?.cornerRadius = 12
        let field = NSTextField(labelWithString: text)
        field.font = .systemFont(ofSize: 12)
        field.textColor = .secondaryLabelColor
        field.alignment = .center
        field.sizeToFit()
        let size = field.intrinsicContentSize
        field.frame = NSRect(x: width / 2 - size.width / 2, y: 22 - size.height / 2,
                             width: size.width, height: size.height)
        addSubview(field)
    }

    required init?(coder: NSCoder) { fatalError() }
}

/// Error card: icon + title + message.
final class ErrorCardView: NSView {
    override var isFlipped: Bool { true }

    init(message: String, width: CGFloat, isWarning: Bool = false) {
        let height = Self.height(message: message, width: width)
        super.init(frame: NSRect(x: 0, y: 0, width: width, height: height))
        wantsLayer = true
        layer?.backgroundColor = NSColor.controlBackgroundColor.withAlphaComponent(0.10).cgColor
        layer?.cornerRadius = 12
        layer?.borderWidth = 0.8
        layer?.borderColor = NSColor.separatorColor.withAlphaComponent(0.55).cgColor

        let icon = NSImageView(frame: NSRect(x: 14, y: 13, width: 16, height: 16))
        icon.image = NSImage(
            systemSymbolName: "exclamationmark.triangle.fill",
            accessibilityDescription: L(.fetchFailed))
        icon.image?.isTemplate = true
        icon.contentTintColor = isWarning ? .systemOrange : .systemRed
        icon.symbolConfiguration = .init(pointSize: 14, weight: .semibold)
        icon.imageScaling = .scaleProportionallyDown
        addSubview(icon)

        let title = NSTextField(labelWithString: L(.fetchFailed))
        title.font = .systemFont(ofSize: 13, weight: .medium)
        title.textColor = .labelColor
        title.sizeToFit()
        let titleSize = title.intrinsicContentSize
        title.frame = NSRect(x: 38, y: 14, width: min(titleSize.width, width - 52), height: titleSize.height)
        addSubview(title)

        let msg = NSTextField(wrappingLabelWithString: message)
        msg.font = .systemFont(ofSize: 11)
        msg.textColor = .secondaryLabelColor
        msg.maximumNumberOfLines = 3
        msg.lineBreakMode = .byTruncatingTail
        msg.toolTip = message
        msg.frame = NSRect(x: 14, y: 38, width: width - 28, height: height - 48)
        addSubview(msg)
    }

    private static func height(message: String, width: CGFloat) -> CGFloat {
        let rect = (message as NSString).boundingRect(
            with: NSSize(width: width - 28, height: 54),
            options: [.usesLineFragmentOrigin, .usesFontLeading],
            attributes: [.font: NSFont.systemFont(ofSize: 11)])
        return max(82, min(112, ceil(rect.height) + 48))
    }

    required init?(coder: NSCoder) { fatalError() }
}

/// Holds a closure so NSMenuItem can invoke it. Retained via `representedObject`.
final class MenuActionTarget: NSObject {
    private let action: () -> Void
    init(action: @escaping () -> Void) { self.action = action }
    @objc func invoke() { action() }
}

/// A persistent refresh row modelled after native menu-bar utilities.
@MainActor
final class RefreshMenuItemView: NSView {
    private let hoverView = NSVisualEffectView()
    private let iconView = NSImageView()
    private let activityIndicator = NSProgressIndicator()
    private let titleField = NSTextField(labelWithString: "")
    private let detailField = NSTextField(labelWithString: "")
    private let action: () -> Void
    private var enabled = true
    private var trackingArea: NSTrackingArea?
    private var displayedTitle = ""
    private var displayedLastUpdatedAt: Date?

    override var isFlipped: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func accessibilityRole() -> NSAccessibility.Role? { .button }
    override func accessibilityLabel() -> String? { titleField.stringValue }
    override func isAccessibilityEnabled() -> Bool { enabled }

    init(
        title: String,
        isRefreshing: Bool,
        lastUpdatedAt: Date?,
        errorMessage: String?,
        action: @escaping () -> Void,
        width: CGFloat)
    {
        self.action = action
        super.init(frame: NSRect(x: 0, y: 0, width: width, height: 38))
        setupViews()
        let recognizer = NSClickGestureRecognizer(target: self, action: #selector(handleClick(_:)))
        recognizer.buttonMask = 0x1
        addGestureRecognizer(recognizer)
        update(isRefreshing: isRefreshing, lastUpdatedAt: lastUpdatedAt, errorMessage: errorMessage, title: title)
    }

    required init?(coder: NSCoder) { fatalError() }

    override func updateTrackingAreas() {
        if let trackingArea { removeTrackingArea(trackingArea) }
        let area = NSTrackingArea(
            rect: bounds,
            options: [.mouseEnteredAndExited, .activeInActiveApp, .inVisibleRect],
            owner: self, userInfo: nil)
        addTrackingArea(area)
        trackingArea = area
    }

    override func layout() {
        super.layout()
        hoverView.frame = bounds.insetBy(dx: 5, dy: 1)
        let iconSide: CGFloat = 15
        iconView.frame = NSRect(x: 15, y: 12, width: iconSide, height: iconSide)
        activityIndicator.frame = NSRect(x: 14, y: 11, width: 17, height: 17)
        titleField.frame = NSRect(x: 39, y: 6, width: bounds.width - 54, height: 15)
        detailField.frame = NSRect(x: 39, y: 21, width: bounds.width - 54, height: 12)
    }

    func update(isRefreshing: Bool, lastUpdatedAt: Date?, errorMessage: String?, title: String) {
        displayedTitle = title
        displayedLastUpdatedAt = lastUpdatedAt
        enabled = !isRefreshing
        iconView.isHidden = isRefreshing
        activityIndicator.isHidden = !isRefreshing
        if isRefreshing {
            activityIndicator.startAnimation(nil)
        } else {
            activityIndicator.stopAnimation(nil)
        }
        titleField.stringValue = isRefreshing ? L(.refreshing) : title
        if isRefreshing {
            detailField.stringValue = L(.refreshDetails)
            detailField.textColor = .secondaryLabelColor
            iconView.contentTintColor = .secondaryLabelColor
        } else if let errorMessage, !errorMessage.isEmpty {
            detailField.stringValue = errorMessage
            detailField.textColor = .systemRed
            iconView.contentTintColor = .systemRed
        } else {
            detailField.stringValue = Self.relativeUpdateText(lastUpdatedAt)
            detailField.textColor = .secondaryLabelColor
            iconView.contentTintColor = .labelColor
        }
        titleField.textColor = enabled ? .labelColor : .secondaryLabelColor
        needsDisplay = true
    }

    override func mouseEntered(with event: NSEvent) {
        guard enabled else { return }
        hoverView.isHidden = false
    }

    override func mouseExited(with event: NSEvent) {
        hoverView.isHidden = true
    }

    override func accessibilityPerformPress() -> Bool {
        guard enabled else { return false }
        beginRefresh()
        return true
    }

    private func setupViews() {
        hoverView.material = .selection
        hoverView.blendingMode = .withinWindow
        hoverView.state = .active
        hoverView.isEmphasized = true
        hoverView.wantsLayer = true
        hoverView.layer?.cornerRadius = 6
        hoverView.isHidden = true
        addSubview(hoverView)

        let image = NSImage(systemSymbolName: "arrow.clockwise", accessibilityDescription: nil)
        image?.isTemplate = true
        iconView.image = image
        iconView.symbolConfiguration = .init(pointSize: 13, weight: .medium)
        iconView.imageScaling = .scaleProportionallyDown
        addSubview(iconView)

        activityIndicator.style = .spinning
        activityIndicator.controlSize = .small
        activityIndicator.isIndeterminate = true
        activityIndicator.isDisplayedWhenStopped = false
        activityIndicator.isHidden = true
        addSubview(activityIndicator)

        titleField.font = .menuFont(ofSize: 0)
        titleField.lineBreakMode = .byTruncatingTail
        addSubview(titleField)
        detailField.font = .systemFont(ofSize: 9)
        detailField.lineBreakMode = .byTruncatingTail
        addSubview(detailField)
    }

    @objc private func handleClick(_ recognizer: NSClickGestureRecognizer) {
        guard recognizer.state == .ended, enabled else { return }
        beginRefresh()
    }

    private func beginRefresh() {
        update(
            isRefreshing: true,
            lastUpdatedAt: displayedLastUpdatedAt,
            errorMessage: nil,
            title: displayedTitle)
        action()
    }

    static func relativeUpdateText(_ date: Date?) -> String {
        guard let date else { return L(.noDataYet) }
        let seconds = max(0, Int(Date().timeIntervalSince(date)))
        switch seconds {
        case ..<15: return L(.updatedJustNow)
        case ..<60: return String(format: L(.updatedSecondsAgo), seconds)
        case ..<3_600: return String(format: L(.updatedMinutesAgo), seconds / 60)
        default: return String(format: L(.updatedHoursAgo), seconds / 3_600)
        }
    }
}