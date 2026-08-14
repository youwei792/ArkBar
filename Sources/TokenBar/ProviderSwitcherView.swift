import AppKit

/// Compact provider switcher at the top of the menu. Shows a "Summary" button
/// when `showSummary` is true, followed by one button per visible provider.
@MainActor
final class ProviderSwitcherView: NSView {
    override var isFlipped: Bool { true }

    private let onSelect: (MenuSelection) -> Void
    private var summaryButton: NSButton?
    private var providerButtons: [ProviderTab: NSButton] = [:]

    init(tabs: [ProviderTab], selected: MenuSelection, showSummary: Bool, width: CGFloat,
         onSelect: @escaping (MenuSelection) -> Void) {
        self.onSelect = onSelect
        super.init(frame: NSRect(x: 0, y: 0, width: width, height: 42))
        wantsLayer = true
        build(tabs: tabs, selected: selected, showSummary: showSummary)
    }

    required init?(coder: NSCoder) { fatalError() }

    private func build(tabs: [ProviderTab], selected: MenuSelection, showSummary: Bool) {
        let inset: CGFloat = 12
        // Tighter gaps when crowded so labels keep more room.
        let countHint = tabs.count + (showSummary ? 1 : 0)
        let gap: CGFloat = countHint >= 4 ? 4 : 6
        let buttonHeight: CGFloat = 26
        var allItems: [Any] = tabs.map { $0 as Any }
        if showSummary {
            allItems.insert(SummaryItem(), at: 0)
        }
        let count = max(1, allItems.count)
        let buttonWidth = (bounds.width - inset * 2 - gap * CGFloat(count - 1)) / CGFloat(count)
        // With 4+ tabs, drop the text and keep the brand glyph so nothing clips.
        let compact = count >= 4

        for (index, item) in allItems.enumerated() {
            let x = inset + CGFloat(index) * (buttonWidth + gap)
            let frame = NSRect(x: x, y: (bounds.height - buttonHeight) / 2,
                               width: buttonWidth, height: buttonHeight)

            if item is SummaryItem {
                let button = SummaryButton(frame: frame)
                button.configure(compact: compact)
                button.state = selected == .summary ? .on : .off
                button.target = self
                button.action = #selector(handleSummaryTap(_:))
                button.toolTip = L(.tabSummary)
                addSubview(button)
                summaryButton = button
            } else if let tab = item as? ProviderTab {
                let button = ProviderTabButton(frame: frame)
                button.tab = tab
                if let logo = ProviderLogo.image(for: tab) {
                    button.image = logo
                }
                button.configure(title: tab.displayName, compact: compact)
                button.state = selected == .provider(tab) ? .on : .off
                button.target = self
                button.action = #selector(handleProviderTap(_:))
                button.toolTip = tab.displayName
                addSubview(button)
                providerButtons[tab] = button
            }
        }
    }

    @objc private func handleSummaryTap(_ sender: SummaryButton) {
        summaryButton?.state = .on
        for (_, btn) in providerButtons { btn.state = .off }
        onSelect(.summary)
    }

    @objc private func handleProviderTap(_ sender: ProviderTabButton) {
        summaryButton?.state = .off
        for (tab, btn) in providerButtons {
            btn.state = tab == sender.tab ? .on : .off
        }
        onSelect(.provider(sender.tab))
    }
}

// MARK: - Summary button (grid icon, no logo)

@MainActor
private final class SummaryButton: NSButton {
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
        imagePosition = .imageLeading
        imageHugsTitle = true
        image = NSImage(systemSymbolName: "square.grid.2x2", accessibilityDescription: L(.tabSummary))
        image?.isTemplate = true
        title = L(.tabSummary)
        updateAppearance()
    }

    required init?(coder: NSCoder) { fatalError() }

    func configure(compact: Bool) {
        if compact {
            title = ""
            imagePosition = .imageOnly
        } else {
            title = L(.tabSummary)
            imagePosition = .imageLeading
            imageHugsTitle = true
        }
        updateAppearance()
    }

    override var state: NSControl.StateValue {
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
            owner: self, userInfo: nil)
        addTrackingArea(area)
        hoverTrackingArea = area
    }

    override func mouseEntered(with event: NSEvent) {
        isHovered = true; updateAppearance(animated: true)
    }

    override func mouseExited(with event: NSEvent) {
        isHovered = false; updateAppearance(animated: true)
    }

    private func updateAppearance() { updateAppearance(animated: false) }

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
        if let img = image {
            img.isTemplate = true
            contentTintColor = selected ? .white : .labelColor
        }
        let target = isHovered && !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
            ? CATransform3DMakeScale(1.018, 1.018, 1)
            : CATransform3DIdentity
        guard animated, !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else {
            layer?.transform = target; return
        }
        let anim = CABasicAnimation(keyPath: "transform")
        anim.fromValue = layer?.presentation()?.value(forKey: "transform") ?? layer?.transform
        anim.toValue = target
        anim.duration = 0.14
        anim.timingFunction = CAMediaTimingFunction(name: .easeOut)
        layer?.transform = target
        layer?.add(anim, forKey: "tokenbar.summaryHover")
    }
}

// MARK: - Provider tab button (reused from original)

@MainActor
private final class ProviderTabButton: NSButton {
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
        imagePosition = .imageLeading
        imageHugsTitle = true
        updateAppearance()
    }

    required init?(coder: NSCoder) { fatalError() }

    func configure(title: String, compact: Bool) {
        if compact {
            self.title = ""
            imagePosition = .imageOnly
        } else {
            self.title = title
            imagePosition = .imageLeading
            imageHugsTitle = true
        }
        updateAppearance()
    }

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
            owner: self, userInfo: nil)
        addTrackingArea(area)
        hoverTrackingArea = area
    }

    override func mouseEntered(with event: NSEvent) {
        isHovered = true; updateAppearance(animated: true)
    }

    override func mouseExited(with event: NSEvent) {
        isHovered = false; updateAppearance(animated: true)
    }

    private func updateAppearance() { updateAppearance(animated: false) }

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
        if let img = image {
            img.isTemplate = true
            contentTintColor = selected ? .white : .labelColor
        }
        let target = isHovered && !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
            ? CATransform3DMakeScale(1.018, 1.018, 1)
            : CATransform3DIdentity
        guard animated, !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else {
            layer?.transform = target; return
        }
        let anim = CABasicAnimation(keyPath: "transform")
        anim.fromValue = layer?.presentation()?.value(forKey: "transform") ?? layer?.transform
        anim.toValue = target
        anim.duration = 0.14
        anim.timingFunction = CAMediaTimingFunction(name: .easeOut)
        layer?.transform = target
        layer?.add(anim, forKey: "tokenbar.tabHover")
    }
}

/// Marker used to reserve a slot for the summary button.
private struct SummaryItem {}