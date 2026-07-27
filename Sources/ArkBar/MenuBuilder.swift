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
        let lastUpdatedAt: Date?
        let now: Date
        let onRefresh: () -> Void
        let onSettings: () -> Void
        let onQuit: () -> Void
    }

    @MainActor
    static func build(_ state: State) -> NSMenu {
        let menu = NSMenu()
        // NSMenu reserves horizontal insets around custom item views. Keep the
        // menu slightly wider than the card so AppKit never clips its right edge.
        menu.minimumWidth = 360

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
            // Header card.
            menu.addItem(headerItem(snapshot: snapshot))
            if let message = snapshot.errorMessage, !message.isEmpty {
                menu.addItem(errorItem(message: message, isWarning: true))
            }
            // One rich card per plan.
            for plan in snapshot.plans {
                menu.addItem(planItem(plan: plan, now: state.now))
            }
        }

        menu.addItem(.separator())

        if let updated = state.lastUpdatedAt {
            let item = NSMenuItem(title: "\(L(.updated)) \(Self.timeString(updated))", action: nil, keyEquivalent: "")
            item.isEnabled = false
            menu.addItem(item)
        }
        menu.addItem(actionItem(L(.refreshNow), action: state.onRefresh))
        menu.addItem(actionItem(L(.openArkcliLogin), action: {
            Self.openTerminal(command: "arkcli auth login volc-sso")
        }))
        menu.addItem(actionItem(L(.openArkConsole), action: {
            NSWorkspace.shared.open(URL(string: "https://console.volcengine.com/ark/region:ark+cn-beijing/openManagement?LLM=%7B%7D&advancedActiveKey=subscribe")!)
        }))
        menu.addItem(actionItem(L(.settings), action: state.onSettings))
        menu.addItem(.separator())
        menu.addItem(actionItem(L(.quitArkBar), action: state.onQuit))
        return menu
    }

    // MARK: - Card items (AppKit-based)

    private static let cardWidth: CGFloat = 340

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
        let view = PlanCardView(plan: plan, now: now, width: cardWidth)
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

    private static func timeString(_ date: Date) -> String {
        let f = DateFormatter()
        f.locale = L10n.shared.locale
        f.setLocalizedDateFormatFromTemplate("HHmm")
        return f.string(from: date)
    }

    private static func actionItem(_ title: String, action: @escaping () -> Void) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: #selector(MenuActionTarget.invoke), keyEquivalent: "")
        let target = MenuActionTarget(action: action)
        item.target = target
        item.representedObject = target
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

        let title = NSTextField(labelWithString: "ArkBar")
        title.font = .systemFont(ofSize: 14, weight: .bold)
        title.textColor = .labelColor
        title.sizeToFit()
        let titleSize = title.intrinsicContentSize
        title.frame = NSRect(x: 14, y: 16, width: titleSize.width, height: titleSize.height)
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
