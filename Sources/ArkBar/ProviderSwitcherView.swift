import AppKit

/// Top-of-menu tab switcher between Ark and OpenCode Go.
///
/// Two side-by-side toggle buttons in a single `NSMenuItem.view`. Clicking a
/// button fires `onSelect`; the controller rebuilds the menu so cards flip live.
/// Modelled after CodexBar's `ProviderSwitcherView` + `PaddedToggleButton`,
/// trimmed to ArkBar's two-tab case (no stacked layout needed).
@MainActor
final class ProviderSwitcherView: NSView {
    override var isFlipped: Bool { true }

    private let onSelect: (ProviderTab) -> Void
    private var buttons: [ProviderTab: NSButton] = [:]

    init(selected: ProviderTab, width: CGFloat, onSelect: @escaping (ProviderTab) -> Void) {
        self.onSelect = onSelect
        super.init(frame: NSRect(x: 0, y: 0, width: width, height: 34))
        wantsLayer = true
        build(selected: selected)
    }

    required init?(coder: NSCoder) { fatalError() }

    private func build(selected: ProviderTab) {
        // Two equal-width buttons with a 6pt gap, inset to match the card padding.
        let inset: CGFloat = 14
        let gap: CGFloat = 6
        let available = bounds.width - inset * 2 - gap
        let buttonWidth = available / 2
        let buttonHeight: CGFloat = 24
        let buttonY = (bounds.height - buttonHeight) / 2

        for (index, tab) in ProviderTab.allCases.enumerated() {
            let button = TabButton(frame: NSRect(
                x: inset + CGFloat(index) * (buttonWidth + gap),
                y: buttonY,
                width: buttonWidth,
                height: buttonHeight))
            button.title = tab.displayName
            button.setButtonType(.toggle)
            button.state = (tab == selected) ? .on : .off
            button.target = self
            button.action = #selector(handleTap(_:))
            button.tab = tab
            button.tag = ProviderTab.allCases.firstIndex(of: tab) ?? index
            addSubview(button)
            buttons[tab] = button
        }
    }

    @objc private func handleTap(_ sender: NSButton) {
        // Map the button back to its tab via tag (robust against title localization).
        let idx = sender.tag
        guard ProviderTab.allCases.indices.contains(idx) else { return }
        let tab = ProviderTab.allCases[idx]
        // Reflect the selection immediately so the toggle visual flips before
        // the menu rebuilds; the rebuild will re-create this view anyway.
        for (t, b) in buttons { b.state = (t == tab) ? .on : .off }
        onSelect(tab)
    }
}

/// Rounded toggle button with a filled selected state. Kept private to this
/// file because it's only used by `ProviderSwitcherView`.
@MainActor
private final class TabButton: NSButton {
    var tab: ProviderTab = .ark

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        isBordered = false
        wantsLayer = true
        layer?.cornerRadius = 6
        font = .systemFont(ofSize: 11, weight: .medium)
        title = ""
        updateAppearance()
    }

    required init?(coder: NSCoder) { fatalError() }

    override var state: NSControl.StateValue {
        didSet { updateAppearance() }
    }

    private func updateAppearance() {
        if state == .on {
            layer?.backgroundColor = NSColor.controlAccentColor.withAlphaComponent(0.85).cgColor
            // Use a light title color on the filled accent background.
            attributedTitle = NSAttributedString(
                string: title,
                attributes: [
                    .font: NSFont.systemFont(ofSize: 11, weight: .semibold),
                    .foregroundColor: NSColor.white,
                ])
        } else {
            layer?.backgroundColor = NSColor.secondarySystemFill.withAlphaComponent(0.5).cgColor
            attributedTitle = NSAttributedString(
                string: title,
                attributes: [
                    .font: NSFont.systemFont(ofSize: 11, weight: .medium),
                    .foregroundColor: NSColor.labelColor,
                ])
        }
    }
}
