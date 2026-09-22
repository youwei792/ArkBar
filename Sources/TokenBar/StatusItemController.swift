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
    private weak var activeRefreshView: RefreshMenuItemView?
    private var isMenuOpen = false
    private var pendingMenuRebuild = false
    private var pendingSelectedMenu: MenuSelection?
    /// Inputs of the last icon build; rebuilds are skipped while unchanged.
    /// The icon is also re-baked on appearance change (see init) because the
    /// gauge bakes the current appearance's colours in.
    private var iconCacheKey: String?

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
            // The ring gauge bakes the current appearance's colours in, so it
            // must be re-rendered when the menu-bar appearance changes
            // (template icons used to re-tint for free).
            button.publisher(for: \.effectiveAppearance)
                .dropFirst()
                .receive(on: RunLoop.main)
                .sink { [weak self] _ in
                    self?.iconCacheKey = nil
                    self?.updateIcon()
                }
                .store(in: &cancellables)
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
        store.$kimiStatus
            .sink { [weak self] _ in self?.updateIconAndMenu() }
            .store(in: &cancellables)
        store.$grokPoolStatus
            .sink { [weak self] _ in self?.updateIconAndMenu() }
            .store(in: &cancellables)
        store.$longcatStatus
            .sink { [weak self] _ in self?.updateIconAndMenu() }
            .store(in: &cancellables)
        store.$aliyunStatus
            .sink { [weak self] _ in self?.updateIconAndMenu() }
            .store(in: &cancellables)
        store.$stepFunStatus
            .sink { [weak self] _ in self?.updateIconAndMenu() }
            .store(in: &cancellables)
        store.$senseNovaStatus
            .sink { [weak self] _ in self?.updateIconAndMenu() }
            .store(in: &cancellables)
        // Reminder list changes rebuild the menu (the Expiring section).
        store.reminderScheduler.$items
            .sink { [weak self] _ in self?.scheduleMenuRebuildIfOpen() }
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
        store.$kimiLastUpdatedAt
            .sink { [weak self] _ in self?.updateActiveRefreshView() }
            .store(in: &cancellables)
        store.$grokPoolLastUpdatedAt
            .sink { [weak self] _ in self?.updateActiveRefreshView() }
            .store(in: &cancellables)
        store.$longcatLastUpdatedAt
            .sink { [weak self] _ in self?.updateActiveRefreshView() }
            .store(in: &cancellables)
        store.$aliyunLastUpdatedAt
            .sink { [weak self] _ in self?.updateActiveRefreshView() }
            .store(in: &cancellables)
        store.$stepFunLastUpdatedAt
            .sink { [weak self] _ in self?.updateActiveRefreshView() }
            .store(in: &cancellables)
        store.$senseNovaLastUpdatedAt
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
        store.$kimiIsRefreshing
            .sink { [weak self] _ in self?.updateActiveRefreshView() }
            .store(in: &cancellables)
        store.$grokPoolIsRefreshing
            .sink { [weak self] _ in self?.updateActiveRefreshView() }
            .store(in: &cancellables)
        store.$longcatIsRefreshing
            .sink { [weak self] _ in self?.updateActiveRefreshView() }
            .store(in: &cancellables)
        store.$aliyunIsRefreshing
            .sink { [weak self] _ in self?.updateActiveRefreshView() }
            .store(in: &cancellables)
        store.$stepFunIsRefreshing
            .sink { [weak self] _ in self?.updateActiveRefreshView() }
            .store(in: &cancellables)
        store.$senseNovaIsRefreshing
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
        // Per-provider value (percent vs balance) affects both the title text
        // and the item width.
        settings.$deepseekValueDisplay
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                self?.applyStatusItemLength()
                self?.updateIcon()
            }
            .store(in: &cancellables)
        settings.$nebulaValueDisplay
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                self?.applyStatusItemLength()
                self?.updateIcon()
            }
            .store(in: &cancellables)
        settings.$grokPoolValueDisplay
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
            settings.$showZai.map { _ in },
            settings.$showKimi.map { _ in },
            settings.$showGrokPool.map { _ in },
            settings.$showLongCat.map { _ in },
            settings.$showAliyun.map { _ in },
            settings.$showStepFun.map { _ in },
            settings.$showSenseNova.map { _ in })
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

    static func statusItemLength(for displayMode: AppSettings.DisplayMode, showsBalance: Bool = false) -> CGFloat {
        switch displayMode {
        case .iconOnly, .logoOnly: 24
        case .iconAndPercent, .logoAndPercent: showsBalance ? 86 : 58
        case .logoAndRings: 42
        case .percentOnly: showsBalance ? 64 : 40
        }
    }

    private func applyStatusItemLength() {
        statusItem.length = Self.statusItemLength(
            for: settings.displayMode,
            showsBalance: settings.showsBalanceInStatusBar(iconTab(for: store.currentStatus)))
    }

    /// Picks the best provider tab for the status-item icon: the explicit tab in
    /// provider mode, or the tightest (lowest remaining percent) in summary mode.
    private func iconTab(for loadStatus: UsageStore.LoadStatus?) -> ProviderTab {
        if case let .provider(tab) = settings.selectedMenu {
            return tab
        }
        // Summary mode: pick the provider with the lowest remaining percent.
        // Uses menuBarWindow so an exhausted weekly pool outranks a fresh
        // 100% session on another provider.
        let candidates = settings.visibleTabs
            .map { ($0, store.status(for: $0)) }
            .filter { $0.1.snapshot?.menuBarWindow != nil }
        if let best = candidates.min(by: { a, b in
            let pa = a.1.snapshot?.menuBarWindow?.remainingPercent ?? 100
            let pb = b.1.snapshot?.menuBarWindow?.remainingPercent ?? 100
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
            remaining = snapshot.menuBarWindow?.remainingPercent
            stale = true
        case let .ok(snapshot):
            if let window = snapshot.menuBarWindow {
                remaining = window.remainingPercent
                stale = false
            } else {
                remaining = nil
                stale = false
            }
        }
        guard let button = statusItem.button else { return }
        let tab = explicitTab ?? iconTab(for: effectiveStatus)
        let showBalance = settings.showsBalanceInStatusBar(tab)
        let valueText = statusValueText(
            for: effectiveStatus, tab: tab, remaining: remaining,
            stale: stale, showBalance: showBalance)
        let rings = menuBarRings(for: effectiveStatus)
        // Rebuilding the icon marks the status-item replicant dirty and
        // triggers an AppKit snapshot pass, so identical inputs must not
        // rebuild. (Before this guard, every rebuild fed the redraw storm.)
        let ringsKey = rings
            .map { "\($0.id):\(Int($0.remainingPercent.rounded()))" }
            .joined(separator: ",")
        let cacheKey = "\(settings.displayMode.rawValue)|\(tab.rawValue)|\(valueText)|\(stale)|\(ringsKey)"
        guard cacheKey != iconCacheKey else { return }
        iconCacheKey = cacheKey

        // Bake under the button's appearance so dynamic colours (track greys,
        // tinted logo) resolve for the menu bar the icon actually lives in.
        button.effectiveAppearance.performAsCurrentDrawingAppearance {
            switch settings.displayMode {
            case .iconOnly:
                button.image = IconRenderer.makeRingIcon(rings: rings, stale: stale)
                button.title = ""
            case .iconAndPercent:
                button.image = IconRenderer.makeRingIcon(rings: rings, stale: stale)
                setPercentTitle(valueText, on: button)
            case .percentOnly:
                button.image = nil
                setPercentTitle(valueText, on: button)
            case .logoOnly:
                button.image = IconRenderer.makeLogoIcon(tab: tab)
                button.title = ""
            case .logoAndPercent:
                button.image = IconRenderer.makeLogoIcon(tab: tab)
                setPercentTitle(valueText, on: button)
            case .logoAndRings:
                button.image = IconRenderer.makeLogoAndRingIcon(tab: tab, rings: rings, stale: stale)
                button.title = ""
            }
        }
    }

    /// Rings for the status-item gauge: the tightest plan's windows when a
    /// snapshot exists (three rings for session/weekly/monthly plans, one for
    /// single-window providers), or nothing — the renderer then draws faint
    /// placeholder tracks so "no data" keeps the same gauge shape.
    private func menuBarRings(for status: UsageStore.LoadStatus) -> [RingRenderer.Ring] {
        // `tightestWindow` alone cannot rebuild the sibling windows, so use the
        // plan that owns it — the same plan driving the card's rings.
        guard let snapshot = status.snapshot,
              let window = snapshot.tightestWindow,
              let plan = snapshot.plans.first(where: { $0.windows.contains(window) })
                ?? snapshot.plans.first(where: { !$0.windows.isEmpty })
        else {
            return []
        }
        return RingRenderer.menuBarRings(for: plan)
    }

    /// Builds the numeric title shown next to the icon. For balance-capable
    /// providers configured to show balance, this is the remaining money with
    /// its currency symbol; otherwise it is the remaining percent. Falls back to
    /// "–" when there is no value to display.
    private func statusValueText(
        for status: UsageStore.LoadStatus, tab: ProviderTab,
        remaining: Double?, stale: Bool, showBalance: Bool
    ) -> String {
        if showBalance {
            let snapshot = status.snapshot
            if let snapshot, let text = balanceText(for: tab, snapshot: snapshot) {
                return text
            }
        }
        if let remaining {
            return "\(Int(remaining.rounded()))%"
        }
        return "–"
    }

    /// Formats the remaining balance for a balance-capable provider, or nil if
    /// the snapshot carries no balance (e.g. fetch only partially succeeded).
    private func balanceText(for tab: ProviderTab, snapshot: ProviderSnapshot) -> String? {
        switch tab {
        case .deepseek:
            guard let summary = snapshot.plans.first?.deepseek else { return nil }
            let symbol = DeepSeekCardView.currencySymbol(summary.currency)
            return DeepSeekCardView.money(summary.totalBalance, symbol: symbol)
        case .nebula:
            guard let summary = snapshot.plans.first?.nebula else { return nil }
            return NebulaCardView.money(summary.balance, symbol: "¥")
        case .grokPool:
            guard let summary = snapshot.plans.first?.grokPool else { return nil }
            return GrokPoolCardView.money(summary.costUSD, symbol: "$")
        case .ark, .opencode, .zai, .kimi, .longcat, .aliyun, .stepfun, .sensenova:
            return nil
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
            allStatuses: store.allStatuses,
            reminders: store.reminderScheduler.items,
            onReminderTap: { [weak self] item in self?.handleReminderTap(item) })
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
        applyStatusItemLength()
        updateIcon()
        scheduleMenuRebuildIfOpen()
    }

    /// Visual-QA only: opens the status-item menu as if the user clicked it.
    func popMenuForQA() {
        statusItem.button?.performClick(nil)
    }

    /// QA-only entry point that runs the same re-import the settings button
    /// runs, so its result is observable from stderr.
    func reimportOpenCodeForQA() {
        store.reimportOpenCodeBrowserSession()
    }

    /// QA-only StepFun re-import trigger.
    func reimportStepFunForQA() {
        store.reimportStepFunBrowserSession()
    }

    /// QA-only SenseNova re-import trigger.
    func reimportSenseNovaForQA() {
        store.reimportSenseNovaBrowserSession()
    }

    /// Opens (or focuses) the Settings scene — the only settings window —
    /// and optionally switches it to a specific pane.
    func showSettings(initialPane: PreferencesPane? = nil) {
        if let initialPane {
            PreferencesRouting.pendingPane = initialPane
        }
        NSApp.activate(ignoringOtherApps: true)
        NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil)
        // A menu-bar accessory's activate() is often denied, which leaves the
        // scene window visible but behind every other app — indistinguishable
        // from "settings didn't open". Raise it explicitly.
        DispatchQueue.main.async { [weak self] in
            self?.raiseSettingsWindow()
            NSApp.activate(ignoringOtherApps: true)
        }
        // An already-visible window ignores the "appear" path above, so also
        // publish the pane switch live.
        if let initialPane {
            NotificationCenter.default.post(
                name: PreferencesRouting.openPane,
                object: initialPane.rawValue)
        }
    }

    private func raiseSettingsWindow() {
        guard let window = NSApp.windows.first(where: {
            $0.title.contains("Settings") || $0.title.contains("设置")
        }) else { return }
        window.orderFrontRegardless()
        window.makeKeyAndOrderFront(nil)
    }

    /// Integrated subscriptions jump to their provider tab; manual entries
    /// open the reminder settings pane where they are managed.
    private func handleReminderTap(_ item: ExpiryReminderItem) {
        if let tab = item.tab {
            settings.selectedMenu = .provider(tab)
            return
        }
        showSettings(initialPane: .reminder)
    }
}