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
    private var pendingSelectedMenu: MenuSelection?

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

        // Subscribe to all provider status changes so the icon and menu stay
        // fresh regardless of which tab or summary mode is selected.
        store.$arkStatus
            .sink { [weak self] _ in self?.updateIconAndMenu() }
            .store(in: &cancellables)
        store.$opencodeStatus
            .sink { [weak self] _ in self?.updateIconAndMenu() }
            .store(in: &cancellables)
        store.$deepseekStatus
            .sink { [weak self] _ in self?.updateIconAndMenu() }
            .store(in: &cancellables)
        store.$nebulaStatus
            .sink { [weak self] _ in self?.updateIconAndMenu() }
            .store(in: &cancellables)
        store.$zaiStatus
            .sink { [weak self] _ in self?.updateIconAndMenu() }
            .store(in: &cancellables)
        // Refresh view updates.
        store.$arkLastUpdatedAt
            .sink { [weak self] _ in self?.updateActiveRefreshView() }
            .store(in: &cancellables)
        store.$opencodeLastUpdatedAt
            .sink { [weak self] _ in self?.updateActiveRefreshView() }
            .store(in: &cancellables)
        store.$deepseekLastUpdatedAt
            .sink { [weak self] _ in self?.updateActiveRefreshView() }
            .store(in: &cancellables)
        store.$nebulaLastUpdatedAt
            .sink { [weak self] _ in self?.updateActiveRefreshView() }
            .store(in: &cancellables)
        store.$zaiLastUpdatedAt
            .sink { [weak self] _ in self?.updateActiveRefreshView() }
            .store(in: &cancellables)
        store.$arkIsRefreshing
            .sink { [weak self] _ in self?.updateActiveRefreshView() }
            .store(in: &cancellables)
        store.$opencodeIsRefreshing
            .sink { [weak self] _ in self?.updateActiveRefreshView() }
            .store(in: &cancellables)
        store.$deepseekIsRefreshing
            .sink { [weak self] _ in self?.updateActiveRefreshView() }
            .store(in: &cancellables)
        store.$nebulaIsRefreshing
            .sink { [weak self] _ in self?.updateActiveRefreshView() }
            .store(in: &cancellables)
        store.$zaiIsRefreshing
            .sink { [weak self] _ in self?.updateActiveRefreshView() }
            .store(in: &cancellables)
        // Selection change.
        settings.$selectedMenu
            .sink { [weak self] menu in
                guard let self else { return }
                // In summary mode, use the tightest provider's data for the icon.
                // In provider mode, use the explicit tab.
                if case let .provider(tab) = menu {
                    let status = self.store.status(for: tab)
                    self.updateIcon(for: status, tab: tab)
                    self.updateActiveRefreshView(
                        isRefreshing: self.store.isRefreshing(for: tab),
                        lastUpdatedAt: self.store.lastUpdatedAt(for: tab),
                        status: status)
                } else {
                    self.updateIcon()
                    self.updateActiveRefreshView()
                }
                self.scheduleMenuRebuildIfOpen(selectedMenu: menu)
            }
            .store(in: &cancellables)
        settings.$displayMode
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                self?.applyStatusItemLength()
                self?.updateIcon()
            }
            .store(in: &cancellables)
        NotificationCenter.default.publisher(for: L10n.languageDidChange)
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.scheduleMenuRebuildIfOpen() }
            .store(in: &cancellables)
        Publishers.MergeMany(
            settings.$showArk.map { _ in },
            settings.$showOpenCode.map { _ in },
            settings.$showDeepSeek.map { _ in },
            settings.$showNebula.map { _ in },
            settings.$showZai.map { _ in })
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                self?.updateIcon()
                self?.scheduleMenuRebuildIfOpen()
            }
            .store(in: &cancellables)

        updateIcon()
        rebuildMenu()
        statusItem.menu = persistentMenu
    }

    static func statusItemLength(for displayMode: AppSettings.DisplayMode) -> CGFloat {
        switch displayMode {
        case .iconOnly, .logoOnly: 24
        case .iconAndPercent, .logoAndPercent: 58
        case .logoAndBar: 46
        case .percentOnly: 40
        }
    }

    private func applyStatusItemLength() {
        statusItem.length = Self.statusItemLength(for: settings.displayMode)
    }

    /// Picks the best provider tab for the status-item icon: the explicit tab in
    /// provider mode, or the tightest (lowest remaining percent) in summary mode.
    private func iconTab(for loadStatus: UsageStore.LoadStatus?) -> ProviderTab {
        if case let .provider(tab) = settings.selectedMenu {
            return tab
        }
        // Summary mode: pick the provider with the lowest remaining percent.
        let candidates = settings.visibleTabs
            .map { ($0, store.status(for: $0)) }
            .filter { $0.1.snapshot?.sessionWindow != nil }
        if let best = candidates.min(by: { a, b in
            let pa = a.1.snapshot?.sessionWindow?.remainingPercent ?? 100
            let pb = b.1.snapshot?.sessionWindow?.remainingPercent ?? 100
            return pa < pb
        }) {
            return best.0
        }
        // Fallback: first visible provider, or .ark
        return settings.visibleTabs.first ?? .ark
    }

    private func updateIcon(for loadStatus: UsageStore.LoadStatus? = nil, tab explicitTab: ProviderTab? = nil) {
        let remaining: Double?
        let stale: Bool
        let effectiveStatus = loadStatus ?? store.currentStatus
        switch effectiveStatus {
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
        let tab = explicitTab ?? iconTab(for: effectiveStatus)

        switch settings.displayMode {
        case .iconOnly:
            button.image = IconRenderer.makeBarIcon(remainingPercent: remaining, stale: stale)
            button.title = ""
        case .iconAndPercent:
            button.image = IconRenderer.makeBarIcon(remainingPercent: remaining, stale: stale)
            if let remaining, !stale {
                setPercentTitle("\(Int(remaining.rounded()))%", on: button)
            } else {
                setPercentTitle("–", on: button)
            }
        case .percentOnly:
            button.image = nil
            if let remaining, !stale {
                setPercentTitle("\(Int(remaining.rounded()))%", on: button)
            } else {
                setPercentTitle("–", on: button)
            }
        case .logoOnly:
            button.image = IconRenderer.makeLogoIcon(tab: tab)
            button.title = ""
        case .logoAndPercent:
            button.image = IconRenderer.makeLogoIcon(tab: tab)
            if let remaining, !stale {
                setPercentTitle("\(Int(remaining.rounded()))%", on: button)
            } else {
                setPercentTitle("–", on: button)
            }
        case .logoAndBar:
            button.image = IconRenderer.makeLogoAndBarIcon(
                tab: tab, remainingPercent: remaining, stale: stale)
            button.title = ""
        }
    }

    private func setPercentTitle(_ text: String, on button: NSStatusBarButton) {
        button.attributedTitle = NSAttributedString(
            string: text,
            attributes: [
                .font: NSFont.monospacedDigitSystemFont(ofSize: NSFont.systemFontSize, weight: .medium),
                .foregroundColor: NSColor.labelColor,
            ])
    }

    func menuWillOpen(_ menu: NSMenu) {
        guard menu === persistentMenu else { return }
        isMenuOpen = true
        if settings.refreshWhenMenuOpens {
            store.refresh()
        }
        rebuildMenu()
    }

    func menuDidClose(_ menu: NSMenu) {
        guard menu === persistentMenu else { return }
        isMenuOpen = false
        pendingMenuRebuild = false
        pendingSelectedMenu = nil
        updateIcon()
    }

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
        layer.add(animation, forKey: "tokenbar.statusHover")
    }

    private func rebuildMenu(selectedMenu explicitMenu: MenuSelection? = nil) {
        let menu = explicitMenu ?? settings.selectedMenu
        let selectedTab: ProviderTab
        let status: MenuBuilder.State.Status
        switch menu {
        case .summary:
            // Use the tightest provider for the refresh row state.
            selectedTab = settings.visibleTabs.first ?? .ark
            status = .ok(snapshot: ProviderSnapshot(
                providerName: "", authMethod: nil, plans: [],
                updatedAt: Date(), errorMessage: nil))
        case let .provider(tab):
            selectedTab = tab
            switch store.status(for: tab) {
            case .never: status = .never
            case .loading: status = .loading
            case let .error(message): status = .error(message: message)
            case let .stale(snapshot, message): status = .stale(snapshot: snapshot, message: message)
            case let .ok(snapshot): status = .ok(snapshot: snapshot)
            }
        }
        let state = MenuBuilder.State(
            status: status,
            selectedMenu: menu,
            visibleTabs: settings.visibleTabs,
            onSelectTab: { [weak self] tab in self?.settings.selectedMenu = .provider(tab) },
            onSelectSummary: { [weak self] in self?.settings.selectedMenu = .summary },
            lastUpdatedAt: store.lastUpdatedAt(for: selectedTab),
            isRefreshing: store.isRefreshing(for: selectedTab),
            now: Date(),
            onRefresh: { [weak self] in self?.refreshFromMenu() },
            onSettings: { [weak self] in self?.showSettings() },
            onQuit: { NSApp.terminate(nil) },
            allStatuses: store.allStatuses)
        MenuBuilder.populate(persistentMenu, with: state)
        activeRefreshView = persistentMenu.items.compactMap { $0.view as? RefreshMenuItemView }.first
    }

    private func scheduleMenuRebuildIfOpen(selectedMenu: MenuSelection? = nil) {
        guard isMenuOpen else { return }
        if let selectedMenu {
            pendingSelectedMenu = selectedMenu
        }
        guard !pendingMenuRebuild else { return }
        pendingMenuRebuild = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.pendingMenuRebuild = false
            guard self.isMenuOpen else {
                self.pendingSelectedMenu = nil
                return
            }
            let menu = self.pendingSelectedMenu
            self.pendingSelectedMenu = nil
            self.rebuildMenu(selectedMenu: menu)
        }
    }

    private func refreshFromMenu() {
        store.refresh()
        updateActiveRefreshView()
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

    /// Convenience: icon + menu rebuild when any provider status changes.
    private func updateIconAndMenu() {
        updateIcon()
        scheduleMenuRebuildIfOpen()
    }

    private var preferencesController: PreferencesWindowController?
    func showSettings() {
        if preferencesController == nil {
            preferencesController = PreferencesWindowController(settings: settings, store: store)
        }
        preferencesController?.show()
    }
}