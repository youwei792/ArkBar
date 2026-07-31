import AppKit

/// Compact provider switcher at the top of the menu. It changes presentation
/// only; the store owns actual refresh isolation for each provider.
@MainActor
final class ProviderSwitcherView: NSView {
    override var isFlipped: Bool { true }

    private let onSelect: (ProviderTab) -> Void
    private var buttons: [ProviderTab: NSButton] = [:]

    init(selected: ProviderTab, width: CGFloat, onSelect: @escaping (ProviderTab) -> Void) {
        self.onSelect = onSelect
        super.init(frame: NSRect(x: 0, y: 0, width: width, height: 42))
        wantsLayer = true
        build(selected: selected)
    }

    required init?(coder: NSCoder) { fatalError() }

    private func build(selected: ProviderTab) {
        let inset: CGFloat = 14
        let gap: CGFloat = 6
        let buttonHeight: CGFloat = 25
        let buttonWidth = (bounds.width - inset * 2 - gap) / 2
        for (index, tab) in ProviderTab.allCases.enumerated() {
            let button = TabButton(frame: NSRect(
                x: inset + CGFloat(index) * (buttonWidth + gap),
                y: (bounds.height - buttonHeight) / 2,
                width: buttonWidth,
                height: buttonHeight))
            button.title = tab.displayName
            button.tab = tab
            button.state = tab == selected ? .on : .off
            button.target = self
            button.action = #selector(handleTap(_:))
            addSubview(button)
            buttons[tab] = button
        }
    }

    @objc private func handleTap(_ sender: TabButton) {
        for (tab, button) in buttons {
            button.state = tab == sender.tab ? .on : .off
        }
        onSelect(sender.tab)
    }
}

@MainActor
private final class TabButton: NSButton {
    var tab: ProviderTab = .ark
    private let selectedGradient = CAGradientLayer()
    private var hoverTrackingArea: NSTrackingArea?
    private var isHovered = false

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        isBordered = false
        wantsLayer = true
        layer?.cornerRadius = 8
        layer?.masksToBounds = true
        layer?.borderWidth = 0.5
        selectedGradient.startPoint = CGPoint(x: 0, y: 0.5)
        selectedGradient.endPoint = CGPoint(x: 1, y: 0.5)
        selectedGradient.colors = [
            NSColor.systemTeal.cgColor,
            NSColor.controlAccentColor.cgColor,
        ]
        selectedGradient.cornerRadius = 8
        layer?.insertSublayer(selectedGradient, at: 0)
        font = .systemFont(ofSize: 11, weight: .medium)
        updateAppearance()
    }

    required init?(coder: NSCoder) { fatalError() }

    override var state: NSControl.StateValue {
        didSet { updateAppearance() }
    }

    override var title: String {
        didSet { updateAppearance() }
    }

    override func layout() {
        super.layout()
        selectedGradient.frame = bounds
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let hoverTrackingArea { removeTrackingArea(hoverTrackingArea) }
        let area = NSTrackingArea(
            rect: .zero,
            options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
            owner: self,
            userInfo: nil)
        addTrackingArea(area)
        hoverTrackingArea = area
    }

    override func mouseEntered(with event: NSEvent) {
        isHovered = true
        updateAppearance(animated: true)
    }

    override func mouseExited(with event: NSEvent) {
        isHovered = false
        updateAppearance(animated: true)
    }

    private func updateAppearance() {
        updateAppearance(animated: false)
    }

    private func updateAppearance(animated: Bool) {
        let selected = state == .on
        selectedGradient.isHidden = !selected
        layer?.backgroundColor = selected
            ? NSColor.clear.cgColor
            : NSColor.quaternaryLabelColor.withAlphaComponent(isHovered ? 0.30 : 0.14).cgColor
        layer?.borderColor = selected
            ? NSColor.white.withAlphaComponent(0.24).cgColor
            : NSColor.separatorColor.withAlphaComponent(isHovered ? 0.64 : 0.36).cgColor
        attributedTitle = NSAttributedString(
            string: title,
            attributes: [
                .font: NSFont.systemFont(ofSize: 11, weight: selected ? .semibold : .medium),
                .foregroundColor: selected ? NSColor.white : NSColor.labelColor,
            ])

        let target = isHovered && !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
            ? CATransform3DMakeScale(1.018, 1.018, 1)
            : CATransform3DIdentity
        guard animated, !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else {
            layer?.transform = target
            return
        }
        let animation = CABasicAnimation(keyPath: "transform")
        animation.fromValue = layer?.presentation()?.value(forKey: "transform") ?? layer?.transform
        animation.toValue = target
        animation.duration = 0.14
        animation.timingFunction = CAMediaTimingFunction(name: .easeOut)
        layer?.transform = target
        layer?.add(animation, forKey: "tokenbar.tabHover")
    }
}
