import AppKit
import Combine

/// Owns the NSStatusItem, renders the icon, and rebuilds the menu on demand.
@MainActor
final class StatusItemController: NSObject, NSMenuDelegate {
    private let statusItem: NSStatusItem
    private let store: UsageStore
    private let settings: AppSettings
    private let persistentMenu = NSMenu()
    private var cancellables = Set<AnyCancellable>()
    private var hoverTrackingArea: NSTrackingArea?
    private weak var activeRefreshView: RefreshMenuItemView?
    private var isMenuOpen = false
    private var pendingMenuRebuild = false
    private var pendingSelectedTab: ProviderTab?

    init(store: UsageStore, settings: AppSettings = .shared) {
        self.store = store
        self.settings = settings
        self.statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        super.init()

        self.statusItem.behavior = .removalAllowed
        self.statusItem.isVisible = true
        self.persistentMenu.autoenablesItems = false
        self.persistentMenu.delegate = self

        if let button = statusItem.button {
            button.imagePosition = .imageLeft
            button.wantsLayer = true
            let trackingArea = NSTrackingArea(
                rect: button.bounds,
                options: [.mouseEnteredAndExited, .activeInActiveApp, .inVisibleRect],
                owner: self,
                userInfo: nil)
            button.addTrackingArea(trackingArea)
            hoverTrackingArea = trackingArea
        }
        applyStatusItemLength()

        // UsageStore is main-actor isolated. Do not hop through RunLoop.main:
        // an NSMenu tracks events in a different run-loop mode, so a default-mode
        // hop leaves the persistent refresh row stale until the menu closes.
        store.$arkStatus
            .sink { [weak self] status in
                guard let self, self.settings.selectedTab == .ark else { return }
                self.updateIcon(for: status)
                self.updateActiveRefreshView(status: status)
                self.scheduleMenuRebuildIfOpen()
            }
            .store(in: &cancellables)
        store.$opencodeStatus
            .sink { [weak self] status in
                guard let self, self.settings.selectedTab == .opencode else { return }
                self.updateIcon(for: status)
                self.updateActiveRefreshView(status: status)
                self.scheduleMenuRebuildIfOpen()
            }
            .store(in: &cancellables)
        store.$arkLastUpdatedAt
            .sink { [weak self] lastUpdatedAt in
                guard self?.settings.selectedTab == .ark else { return }
                self?.updateActiveRefreshView(lastUpdatedAt: lastUpdatedAt)
            }
            .store(in: &cancellables)
        store.$opencodeLastUpdatedAt
            .sink { [weak self] lastUpdatedAt in
                guard self?.settings.selectedTab == .opencode else { return }
                self?.updateActiveRefreshView(lastUpdatedAt: lastUpdatedAt)
            }
            .store(in: &cancellables)
        store.$arkIsRefreshing
            .sink { [weak self] isRefreshing in
                guard self?.settings.selectedTab == .ark else { return }
                self?.updateActiveRefreshView(isRefreshing: isRefreshing)
            }
            .store(in: &cancellables)
        store.$opencodeIsRefreshing
            .sink { [weak self] isRefreshing in
                guard self?.settings.selectedTab == .opencode else { return }
                self?.updateActiveRefreshView(isRefreshing: isRefreshing)
            }
            .store(in: &cancellables)
        settings.$selectedTab
            .sink { [weak self] tab in
                guard let self else { return }
                let status = self.store.status(for: tab)
                // Changing the status-item title from e.g. 60% to 100% changes
                // its natural width. The item itself has a fixed maximum width,
                // so the value can update live without moving the menu anchor.
                self.updateIcon(for: status)
                self.updateActiveRefreshView(
                    isRefreshing: self.store.isRefreshing(for: tab),
                    lastUpdatedAt: self.store.lastUpdatedAt(for: tab),
                    status: status)
                // `@Published` sends before the setting is committed. Preserve
                // the emitted tab explicitly, then mutate the already-open menu
                // on the next turn after the switcher's mouse-up transaction.
                self.scheduleMenuRebuildIfOpen(selectedTab: tab)
            }
            .store(in: &cancellables)
        settings.$displayMode
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                self?.applyStatusItemLength()
                self?.updateIcon()
            }
            .store(in: &cancellables)
        // Language changes invalidate nothing in the icon, but if the menu is open
        // we rebuild it so localized labels flip live.
        NotificationCenter.default.publisher(for: L10n.languageDidChange)
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.scheduleMenuRebuildIfOpen() }
            .store(in: &cancellables)

        updateIcon()
        rebuildMenu()
        // Keep one menu attached for the lifetime of the status item. Attaching
        // it only from the click handler makes AppKit consume the first click
        // merely to install the menu, which is why the old build needed two.
        statusItem.menu = persistentMenu
    }

    static func statusItemLength(for displayMode: AppSettings.DisplayMode) -> CGFloat {
        switch displayMode {
        case .iconOnly: 28
        case .iconAndPercent: 68
        case .percentOnly: 46
        }
    }

    private func applyStatusItemLength() {
        statusItem.length = Self.statusItemLength(for: settings.displayMode)
    }

    private func updateIcon(for loadStatus: UsageStore.LoadStatus? = nil) {
        let remaining: Double?
        let stale: Bool
        switch loadStatus ?? store.currentStatus {
        case .never, .loading:
            remaining = nil
            stale = true
        case .error:
            remaining = nil
            stale = true
        case let .stale(snapshot, _):
            remaining = snapshot.sessionWindow?.remainingPercent
            stale = true
        case let .ok(snapshot):
            if let window = snapshot.sessionWindow {
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

    func menuWillOpen(_ menu: NSMenu) {
        guard menu === persistentMenu else { return }
        isMenuOpen = true
        if settings.refreshWhenMenuOpens {
            store.refresh(tab: settings.selectedTab)
        }
        // Countdown strings and provider content are fresh before the very
        // first frame of the popover is presented.
        rebuildMenu()
    }

    func menuDidClose(_ menu: NSMenu) {
        guard menu === persistentMenu else { return }
        isMenuOpen = false
        pendingMenuRebuild = false
        pendingSelectedTab = nil
        updateIcon()
    }

    // NSTrackingArea sends the Objective-C selectors `mouseEntered:` and
    // `mouseExited:`. StatusItemController is an NSObject rather than an
    // NSResponder, so Swift's default `mouseEnteredWithEvent:` bridge crashes.
    @objc(mouseEntered:) func mouseEntered(_ event: NSEvent) {
        animateStatusButton(hovered: true)
    }

    @objc(mouseExited:) func mouseExited(_ event: NSEvent) {
        animateStatusButton(hovered: false)
    }

    private func animateStatusButton(hovered: Bool) {
        guard !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion,
              let layer = statusItem.button?.layer
        else { return }
        let target = hovered
            ? CATransform3DMakeScale(1.045, 1.045, 1)
            : CATransform3DIdentity
        let animation = CABasicAnimation(keyPath: "transform")
        animation.fromValue = layer.presentation()?.value(forKey: "transform") ?? layer.transform
        animation.toValue = target
        animation.duration = 0.16
        animation.timingFunction = CAMediaTimingFunction(name: .easeOut)
        layer.transform = target
        layer.add(animation, forKey: "arkbar.statusHover")
    }

    /// Rebuild the dropdown menu from the current store state.
    private func rebuildMenu(selectedTab explicitTab: ProviderTab? = nil) {
        let selectedTab = explicitTab ?? settings.selectedTab
        let status: MenuBuilder.State.Status
        switch store.status(for: selectedTab) {
        case .never: status = .never
        case .loading: status = .loading
        case let .error(message): status = .error(message: message)
        case let .stale(snapshot, message): status = .stale(snapshot: snapshot, message: message)
        case let .ok(snapshot): status = .ok(snapshot: snapshot)
        }
        let state = MenuBuilder.State(
            status: status,
            selectedTab: selectedTab,
            onSelectTab: { [weak self] tab in self?.settings.selectedTab = tab },
            lastUpdatedAt: store.lastUpdatedAt(for: selectedTab),
            isRefreshing: store.isRefreshing(for: selectedTab),
            now: Date(),
            onRefresh: { [weak self] in self?.refreshFromMenu(tab: selectedTab) },
            onSettings: { [weak self] in self?.showSettings() },
            onQuit: { NSApp.terminate(nil) })
        MenuBuilder.populate(persistentMenu, with: state)
        activeRefreshView = persistentMenu.items.compactMap { $0.view as? RefreshMenuItemView }.first
    }

    /// Coalesce publisher bursts and rebuild only the content of the currently
    /// tracked menu. Replacing `statusItem.menu` while tracking leaves the old
    /// Ark card on screen and was the source of the mixed-tab screenshots.
    private func scheduleMenuRebuildIfOpen(selectedTab: ProviderTab? = nil) {
        guard isMenuOpen else { return }
        if let selectedTab {
            pendingSelectedTab = selectedTab
        }
        guard !pendingMenuRebuild else { return }
        pendingMenuRebuild = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.pendingMenuRebuild = false
            guard self.isMenuOpen else {
                self.pendingSelectedTab = nil
                return
            }
            let selectedTab = self.pendingSelectedTab
            self.pendingSelectedTab = nil
            self.rebuildMenu(selectedTab: selectedTab)
        }
    }

    private func refreshFromMenu(tab: ProviderTab) {
        store.refresh(tab: tab)
        // The row also transitions itself before invoking this callback. This
        // explicit update covers accessibility activation and any AppKit menu
        // delivery quirk without waiting for a publisher scheduling hop.
        updateActiveRefreshView(
            isRefreshing: store.isRefreshing(for: tab),
            lastUpdatedAt: store.lastUpdatedAt(for: tab),
            status: store.status(for: tab))
    }

    private func updateActiveRefreshView(
        isRefreshing: Bool? = nil,
        lastUpdatedAt: Date? = nil,
        status: UsageStore.LoadStatus? = nil)
    {
        let errorMessage: String?
        switch status ?? store.currentStatus {
        case let .error(message), let .stale(_, message): errorMessage = message
        default: errorMessage = nil
        }
        activeRefreshView?.update(
            isRefreshing: isRefreshing ?? store.currentIsRefreshing,
            lastUpdatedAt: lastUpdatedAt ?? store.currentLastUpdatedAt,
            errorMessage: errorMessage,
            title: L(.refreshNow))
    }

    private var preferencesController: PreferencesWindowController?
    func showSettings() {
        if preferencesController == nil {
            preferencesController = PreferencesWindowController(settings: settings, store: store)
        }
        preferencesController?.show()
    }
}
