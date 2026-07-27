import AppKit
import Combine

/// Owns the NSStatusItem, renders the icon, and rebuilds the menu on demand.
@MainActor
final class StatusItemController {
    private let statusItem: NSStatusItem
    private let store: UsageStore
    private let settings: AppSettings
    private var cancellables = Set<AnyCancellable>()
    private var hoverTrackingArea: NSTrackingArea?

    init(store: UsageStore, settings: AppSettings = .shared) {
        self.store = store
        self.settings = settings
        self.statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        self.statusItem.behavior = .removalAllowed
        self.statusItem.isVisible = true

        if let button = statusItem.button {
            button.imagePosition = .imageLeft
            button.target = self
            button.action = #selector(self.handleClick(_:))
            button.sendAction(on: [.leftMouseDown, .rightMouseDown])
            button.wantsLayer = true
            let trackingArea = NSTrackingArea(
                rect: button.bounds,
                options: [.mouseEnteredAndExited, .activeInActiveApp, .inVisibleRect],
                owner: self,
                userInfo: nil)
            button.addTrackingArea(trackingArea)
            hoverTrackingArea = trackingArea
        }

        store.$status
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.updateIcon() }
            .store(in: &cancellables)
        store.$lastUpdatedAt
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.updateIcon() }
            .store(in: &cancellables)
        settings.$displayMode
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.updateIcon() }
            .store(in: &cancellables)
        // Language changes invalidate nothing in the icon, but if the menu is open
        // we rebuild it so localized labels flip live.
        NotificationCenter.default.publisher(for: L10n.languageDidChange)
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.rebuildMenuIfOpen() }
            .store(in: &cancellables)

        updateIcon()
    }

    private func updateIcon() {
        let remaining: Double?
        let stale: Bool
        switch store.status {
        case .never, .loading:
            remaining = nil
            stale = true
        case .error:
            remaining = nil
            stale = true
        case let .stale(snapshot, _):
            remaining = snapshot.tightestWindow?.remainingPercent
            stale = true
        case let .ok(snapshot):
            if let window = snapshot.tightestWindow {
                remaining = window.remainingPercent
                stale = false
            } else {
                remaining = nil
                stale = false
            }
        }
        guard let button = statusItem.button else { return }

        switch settings.displayMode {
        case .iconOnly:
            button.image = IconRenderer.makeIcon(remainingPercent: remaining, stale: stale)
            button.title = ""
        case .iconAndPercent:
            button.image = IconRenderer.makeIcon(remainingPercent: remaining, stale: stale)
            if let remaining, !stale {
                button.title = "\(Int(remaining.rounded()))%"
            } else {
                button.title = "–"
            }
        case .percentOnly:
            button.image = nil
            if let remaining, !stale {
                button.title = "\(Int(remaining.rounded()))%"
            } else {
                button.title = "–"
            }
        }
    }

    @objc private func handleClick(_ sender: NSStatusBarButton) {
        // Rebuild the menu fresh each time it's opened (so countdowns update).
        if settings.refreshWhenMenuOpens {
            store.refresh()
        }
        rebuildMenu()
        // Setting statusItem.menu makes the button pop the menu on click
        // automatically; no need to call performClick (which would re-enter
        // this handler and double-toggle / loop).
    }

    @objc func mouseEntered(with event: NSEvent) {
        animateStatusButton(hovered: true)
    }

    @objc func mouseExited(with event: NSEvent) {
        animateStatusButton(hovered: false)
    }

    private func animateStatusButton(hovered: Bool) {
        guard !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion,
              let layer = statusItem.button?.layer
        else { return }
        let animation = CABasicAnimation(keyPath: "transform.scale")
        animation.fromValue = hovered ? 0.96 : 1.04
        animation.toValue = hovered ? 1.04 : 1
        animation.duration = 0.16
        animation.timingFunction = CAMediaTimingFunction(name: .easeOut)
        layer.add(animation, forKey: "arkbar.statusHover")
    }

    /// Rebuild the dropdown menu from the current store state.
    private func rebuildMenu() {
        let status: MenuBuilder.State.Status
        switch store.status {
        case .never: status = .never
        case .loading: status = .loading
        case let .error(message): status = .error(message: message)
        case let .stale(snapshot, message): status = .stale(snapshot: snapshot, message: message)
        case let .ok(snapshot): status = .ok(snapshot: snapshot)
        }
        let state = MenuBuilder.State(
            status: status,
            lastUpdatedAt: store.lastUpdatedAt,
            now: Date(),
            onRefresh: { [weak self] in self?.store.refresh() },
            onSettings: { [weak self] in self?.showSettings() },
            onQuit: { NSApp.terminate(nil) })
        statusItem.menu = MenuBuilder.build(state)
    }

    /// Rebuild the menu only if it's currently showing (so a language switch
    /// live-updates an open popover without surprise popups when closed).
    private func rebuildMenuIfOpen() {
        guard statusItem.menu != nil, statusItem.button?.window?.isVisible == true else { return }
        rebuildMenu()
    }

    private var preferencesController: PreferencesWindowController?
    private func showSettings() {
        if preferencesController == nil {
            preferencesController = PreferencesWindowController(settings: settings, store: store)
        }
        preferencesController?.show()
    }
}
