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
        /// Which provider tab is currently shown; drives the switcher's
        /// selected button and the per-tab card theme.
        let selectedTab: ProviderTab
        let onSelectTab: (ProviderTab) -> Void
        let lastUpdatedAt: Date?
        let isRefreshing: Bool
        let now: Date
        let onRefresh: () -> Void
        let onSettings: () -> Void
        let onQuit: () -> Void

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
        // NSMenu reserves horizontal insets around custom item views. Keep the
        // menu slightly wider than the card so AppKit never clips its right edge.
        menu.minimumWidth = 360

        // Top tab switcher (Ark | OpenCode). Always present so the user can
        // flip between tracks regardless of load state.
        menu.addItem(switcherItem(state: state))

        switch state.status {
        case .never:
            menu.addItem(loadingItem(text: L(.loadingUsage)))
        case .loading:
            menu.addItem(loadingItem(text: L(.refreshing)))
        case let .error(message):
            menu.addItem(errorItem(message: message))
        case let .stale(snapshot, message):
            menu.addItem(headerItem(snapshot: snapshot, tab: state.selectedTab))
            menu.addItem(errorItem(message: "\(L(.staleData))\n\(message)", isWarning: true))
            for plan in snapshot.plans {
                menu.addItem(planItem(plan: plan, now: state.now, tab: state.selectedTab))
            }
        case let .ok(snapshot):
            // Header card.
            menu.addItem(headerItem(snapshot: snapshot, tab: state.selectedTab))
            if let message = snapshot.errorMessage, !message.isEmpty {
                menu.addItem(errorItem(message: message, isWarning: true))
            }
            // One rich card per plan.
            for plan in snapshot.plans {
                menu.addItem(planItem(plan: plan, now: state.now, tab: state.selectedTab))
            }
        }

        menu.addItem(.separator())

        menu.addItem(refreshItem(state: state))
        // Ark-tab-only quick actions (login / console) don't apply to OpenCode.
        if state.selectedTab == .ark {
            menu.addItem(actionItem(L(.openArkcliLogin), action: {
                Self.openTerminal(command: "arkcli auth login volc-sso")
            }))
            menu.addItem(actionItem(L(.openArkConsole), action: {
                NSWorkspace.shared.open(URL(string: "https://console.volcengine.com/ark/region:ark+cn-beijing/openManagement?LLM=%7B%7D&advancedActiveKey=subscribe")!)
            }))
        } else {
            menu.addItem(actionItem(L(.openCodeGo), action: {
                NSWorkspace.shared.open(URL(string: "https://opencode.ai")!)
            }))
        }
        menu.addItem(actionItem(L(.settings), action: state.onSettings))
        menu.addItem(.separator())
        menu.addItem(actionItem(L(.quitArkBar), action: state.onQuit))
        return menu
    }

    // MARK: - Card items (AppKit-based)

    private static let cardWidth: CGFloat = 340

    @MainActor
    private static func switcherItem(state: State) -> NSMenuItem {
        let item = NSMenuItem()
        let view = ProviderSwitcherView(selected: state.selectedTab, width: cardWidth) { tab in
            state.onSelectTab(tab)
        }
        item.view = view
        item.isEnabled = false
        return item
    }

    @MainActor
    private static func headerItem(snapshot: ProviderSnapshot, tab: ProviderTab) -> NSMenuItem {
        let item = NSMenuItem()
        let view = HeaderCardView(snapshot: snapshot, width: cardWidth, tab: tab)
        item.view = view
        item.isEnabled = false
        return item
    }

    @MainActor
    private static func planItem(plan: PlanSnapshot, now: Date, tab: ProviderTab) -> NSMenuItem {
        let item = NSMenuItem()
        let theme: RingRenderer.CardTheme = (tab == .opencode) ? .opencode : .ark
        let view = PlanCardView(plan: plan, now: now, width: cardWidth, theme: theme)
        item.view = view
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
        // The embedded gesture recognizer handles the click. Leaving the item
        // without an NSMenu action means AppKit keeps tracking the menu open.
        item.action = nil
        item.target = nil
        return item
    }

    private static func openTerminal(command: String) {
        let script = "tell application \"Terminal\"\nactivate\ndo script \"\(command)\"\nend tell"
        if let appleScript = NSAppleScript(source: script) {
            var error: NSDictionary?
            appleScript.executeAndReturnError(&error)
        }
    }
}

// MARK: - AppKit card views

/// Header card: ArkBar + provider name + auth method.
/// Uses flipped coordinates (origin top-left).
final class HeaderCardView: NSView {
    override var isFlipped: Bool { true }

    init(snapshot: ProviderSnapshot, width: CGFloat, tab: ProviderTab = .ark) {
        super.init(frame: NSRect(x: 0, y: 0, width: width, height: 54))
        wantsLayer = true

        let accent = CAGradientLayer()
        // Accent gradient follows the tab theme: Ark keeps the original
        // mint->blue->indigo; OpenCode swaps to violet->indigo->amber.
        switch tab {
        case .ark:
            accent.colors = [
                NSColor.systemMint.withAlphaComponent(0.92).cgColor,
                NSColor.systemBlue.withAlphaComponent(0.9).cgColor,
                NSColor.systemIndigo.withAlphaComponent(0.9).cgColor,
            ]
        case .opencode:
            accent.colors = [
                NSColor(red: 0.62, green: 0.36, blue: 0.92, alpha: 0.92).cgColor,  // violet
                NSColor.systemIndigo.withAlphaComponent(0.9).cgColor,
                NSColor.systemOrange.withAlphaComponent(0.85).cgColor,              // amber
            ]
        }
        accent.startPoint = CGPoint(x: 0, y: 0.5)
        accent.endPoint = CGPoint(x: 1, y: 0.5)
        accent.frame = NSRect(x: 14, y: 50, width: width - 28, height: 2)
        layer?.addSublayer(accent)

        let title = NSTextField(labelWithString: "ArkBar")
        title.font = .systemFont(ofSize: 14, weight: .bold)
        title.textColor = .labelColor
        let titleSize = title.intrinsicContentSize
        // NSTextField clips glyph overhangs when its frame exactly equals the
        // intrinsic width. Give the wordmark a small trailing safety inset so
        // the terminal “r” is fully antialiased instead of looking cut off.
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

        let icon = NSTextField(labelWithString: "⚠")
        icon.font = .systemFont(ofSize: 16)
        icon.textColor = isWarning ? .systemOrange : .systemRed
        icon.sizeToFit()
        let iconSize = icon.intrinsicContentSize
        icon.frame = NSRect(x: 14, y: 12, width: iconSize.width, height: iconSize.height)
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

/// A persistent refresh row modelled after native menu-bar utilities: it stays
/// inside the tracked menu, surfaces refreshing/success/failure state, and
/// handles its own click rather than selecting a closing NSMenuItem.
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
            owner: self,
            userInfo: nil)
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

        // A native indeterminate indicator keeps its own animation geometry
        // inside this fixed frame. Rotating an NSImageView layer in a tracked
        // status menu can make the glyph orbit outside its icon slot.
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
        // Give the click instant feedback before the async provider request
        // starts. The controller then owns the success/error transition.
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
