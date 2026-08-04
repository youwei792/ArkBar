import Combine
import Foundation

/// Owns the providers and the refresh loop. Ark and OpenCode Go intentionally
/// remain separate tracks: a slow or failed web request must never make the Ark
/// card spin, disable its Refresh row, or overwrite its last successful data.
@MainActor
final class UsageStore: ObservableObject {
    enum LoadStatus: Equatable {
        case never
        case loading
        case ok(snapshot: ProviderSnapshot)
        /// A refresh failed, but the last confirmed snapshot remains useful.
        case stale(snapshot: ProviderSnapshot, message: String)
        case error(message: String)

        var snapshot: ProviderSnapshot? {
            switch self {
            case let .ok(snapshot), let .stale(snapshot, _): snapshot
            case .never, .loading, .error: nil
            }
        }
    }

    @Published private(set) var arkStatus: LoadStatus = .never
    @Published private(set) var opencodeStatus: LoadStatus = .never
    @Published private(set) var deepseekStatus: LoadStatus = .never
    @Published private(set) var nebulaStatus: LoadStatus = .never
    @Published private(set) var arkLastUpdatedAt: Date?
    @Published private(set) var opencodeLastUpdatedAt: Date?
    @Published private(set) var deepseekLastUpdatedAt: Date?
    @Published private(set) var nebulaLastUpdatedAt: Date?
    @Published private(set) var arkIsRefreshing = false
    @Published private(set) var opencodeIsRefreshing = false
    @Published private(set) var deepseekIsRefreshing = false
    @Published private(set) var nebulaIsRefreshing = false

    /// Compatibility conveniences for views that only need the selected tab.
    var status: LoadStatus { currentStatus }
    var lastUpdatedAt: Date? { currentLastUpdatedAt }
    var isRefreshing: Bool { currentIsRefreshing }
    var currentStatus: LoadStatus { status(for: settings.selectedTab) }
    var currentLastUpdatedAt: Date? { lastUpdatedAt(for: settings.selectedTab) }
    var currentIsRefreshing: Bool { isRefreshing(for: settings.selectedTab) }

    private let settings: AppSettings
    private var arkProviders: [UsageProvider] = []
    private var openCodeProvider: OpenCodeGoProvider?
    private var deepSeekProvider: DeepSeekProvider?
    private var nebulaProvider: NebulaProvider?
    private var timer: Timer?
    private var lastSuccessfulArkSnapshot: ProviderSnapshot?
    private var lastSuccessfulOpenCodeSnapshot: ProviderSnapshot?
    private var lastSuccessfulDeepSeekSnapshot: ProviderSnapshot?
    private var lastSuccessfulNebulaSnapshot: ProviderSnapshot?
    private var cancellables = Set<AnyCancellable>()

    init(settings: AppSettings = .shared) {
        self.settings = settings
        rebuildProviders()

        settings.$refreshInterval
            .dropFirst()
            .sink { [weak self] _ in self?.scheduleNext() }
            .store(in: &cancellables)
        settings.$sourceMode
            .dropFirst()
            .sink { [weak self] _ in
                self?.rebuildProviders()
                self?.refresh(tab: .ark)
            }
            .store(in: &cancellables)
        settings.$opencodeCookie
            .dropFirst()
            .sink { [weak self] _ in self?.refresh(tab: .opencode) }
            .store(in: &cancellables)
        settings.$opencodeCookieSource
            .dropFirst()
            .sink { [weak self] _ in self?.refresh(tab: .opencode) }
            .store(in: &cancellables)
        settings.$opencodeWorkspaceID
            .dropFirst()
            .debounce(for: .milliseconds(350), scheduler: RunLoop.main)
            .sink { [weak self] _ in self?.refresh(tab: .opencode) }
            .store(in: &cancellables)
        // Saving a DeepSeek key in settings refreshes immediately.
        Publishers.MergeMany(
            settings.$deepseekApiKey.map { _ in },
            settings.$deepseekPlatformToken.map { _ in })
            .dropFirst()
            .sink { [weak self] _ in self?.refresh(tab: .deepseek) }
            .store(in: &cancellables)
        // Saving the Nebula key or base URL refreshes immediately.
        Publishers.MergeMany(
            settings.$nebulaAPIKey.map { _ in },
            settings.$nebulaBaseURL.map { _ in })
            .dropFirst()
            .sink { [weak self] _ in self?.refresh(tab: .nebula) }
            .store(in: &cancellables)
        settings.$selectedTab
            .dropFirst()
            .sink { [weak self] tab in
                guard let self, self.status(for: tab) == .never else { return }
                self.refresh(tab: tab)
            }
            .store(in: &cancellables)
        // Re-enabling a hidden provider fetches it immediately; hiding one stops
        // its background refreshes (refreshAllConfigured filters visible tabs).
        for tab in ProviderTab.allCases {
            let publisher: AnyPublisher<Bool, Never>
            switch tab {
            case .ark: publisher = settings.$showArk.eraseToAnyPublisher()
            case .opencode: publisher = settings.$showOpenCode.eraseToAnyPublisher()
            case .deepseek: publisher = settings.$showDeepSeek.eraseToAnyPublisher()
            case .nebula: publisher = settings.$showNebula.eraseToAnyPublisher()
            }
            publisher
                .dropFirst()
                .removeDuplicates()
                .sink { [weak self] visible in
                    guard let self, visible, self.status(for: tab) == .never else { return }
                    self.refresh(tab: tab)
                }
                .store(in: &cancellables)
        }
    }

    /// Rebuild the Ark provider priority. OpenCode is a distinct provider, not
    /// a fallback candidate, because its account data must never be merged with
    /// Ark usage.
    func rebuildProviders() {
        let environment = ProcessInfo.processInfo.environment
        var providers: [UsageProvider] = []
        switch settings.sourceMode {
        case .cli:
            providers.append(ArkCLIProvider())
        case .api:
            if let credentials = VolcCredentialResolver.resolve(environment: environment) {
                providers.append(VolcAPIProvider(credentials: credentials))
            }
            if let key = ArkAPIKeyResolver.resolve(environment: environment) {
                providers.append(ArkAPIKeyProvider(apiKey: key))
            }
        case .auto:
            if let credentials = VolcCredentialResolver.resolve(environment: environment) {
                providers.append(VolcAPIProvider(credentials: credentials))
            }
            if let key = ArkAPIKeyResolver.resolve(environment: environment) {
                providers.append(ArkAPIKeyProvider(apiKey: key))
            }
            providers.append(ArkCLIProvider())
        }
        arkProviders = providers
        openCodeProvider = OpenCodeGoProvider(settings: settings)
        deepSeekProvider = DeepSeekProvider(settings: settings)
        nebulaProvider = NebulaProvider(settings: settings)
    }

    func start() {
        refreshAllConfigured()
        scheduleNext()
    }

    /// Refresh the currently visible provider. Manual Refresh and the optional
    /// “refresh when opening” setting both use this path, so the UI feedback is
    /// always scoped to the card the user is looking at.
    func refresh() {
        refresh(tab: settings.selectedTab)
    }

    func refresh(tab: ProviderTab) {
        switch tab {
        case .ark: refreshArk()
        case .opencode: refreshOpenCode()
        case .deepseek: refreshDeepSeek()
        case .nebula: refreshNebula()
        }
    }

    /// The only path allowed to interactively read the browser cookie store.
    /// Routine refreshes only use the cached TokenBar Keychain credential.
    func reimportOpenCodeBrowserSession() {
        guard !opencodeIsRefreshing else { return }
        guard let provider = openCodeProvider,
              provider.isAvailable(environment: ProcessInfo.processInfo.environment)
        else {
            if lastSuccessfulOpenCodeSnapshot == nil {
                opencodeStatus = .error(message: L(.errorOpenCodeBrowserAuthorizationRequired))
            }
            return
        }

        opencodeIsRefreshing = true
        switch opencodeStatus {
        case .ok, .stale:
            break
        case .never, .loading, .error:
            opencodeStatus = .loading
        }

        let environment = ProcessInfo.processInfo.environment
        let browser = OpenCodeGoBrowserSession.browserForInteractiveImport()
        Task { [weak self] in
            guard let self else { return }
            do {
                _ = try await Task.detached(priority: .userInitiated) {
                    try OpenCodeGoBrowserSession.importSessionInteractively(from: browser)
                }.value
                await self.runOpenCodeProvider(provider, environment: environment)
            } catch {
                Self.log("✗ OpenCode Go browser import: \(error.localizedDescription)")
                self.finishOpenCodeRefresh(error: error.localizedDescription)
            }
        }
    }

    /// Explicit user action only: import Nebula console login cookies from the
    /// browser, then refresh balance/log endpoints with the cached session.
    func reimportNebulaBrowserSession() {
        guard !nebulaIsRefreshing else { return }
        guard let provider = nebulaProvider else {
            if lastSuccessfulNebulaSnapshot == nil {
                nebulaStatus = .error(message: L(.errorNebulaBrowserAuthorizationRequired))
            }
            return
        }

        nebulaIsRefreshing = true
        switch nebulaStatus {
        case .ok, .stale:
            break
        case .never, .loading, .error:
            nebulaStatus = .loading
        }

        let environment = ProcessInfo.processInfo.environment
        let browser = NebulaBrowserSession.browserForInteractiveImport()
        Task { [weak self] in
            guard let self else { return }
            do {
                _ = try await Task.detached(priority: .userInitiated) {
                    try NebulaBrowserSession.importSessionInteractively(from: browser)
                }.value
                await self.runNebulaProvider(provider, environment: environment)
            } catch {
                Self.log("✗ Nebula browser import: \(error.localizedDescription)")
                self.finishNebulaRefresh(error: error.localizedDescription)
            }
        }
    }

    private func refreshAllConfigured() {
        for tab in settings.visibleTabs {
            refresh(tab: tab)
        }
    }

    private func refreshArk() {
        guard !arkIsRefreshing else { return }
        arkIsRefreshing = true
        switch arkStatus {
        case .ok, .stale:
            break // retain usable data while the request is in flight
        case .never, .loading, .error:
            arkStatus = .loading
        }
        let providers = arkProviders
        let environment = ProcessInfo.processInfo.environment
        Task { [weak self] in
            await self?.runArkProviders(providers, environment: environment)
        }
    }

    private func refreshOpenCode() {
        guard !opencodeIsRefreshing else { return }
        guard let provider = openCodeProvider,
              provider.isAvailable(environment: ProcessInfo.processInfo.environment)
        else {
            if lastSuccessfulOpenCodeSnapshot == nil {
                opencodeStatus = .error(message: L(.errorOpenCodeCookieMissing))
            }
            return
        }
        opencodeIsRefreshing = true
        switch opencodeStatus {
        case .ok, .stale:
            break
        case .never, .loading, .error:
            opencodeStatus = .loading
        }
        let environment = ProcessInfo.processInfo.environment
        Task { [weak self] in
            await self?.runOpenCodeProvider(provider, environment: environment)
        }
    }

    private func runArkProviders(_ providers: [UsageProvider], environment: [String: String]) async {
        guard !providers.isEmpty else {
            finishArkRefresh(error: L(.noProvider))
            return
        }
        var lastError = L(.noProvider)
        for provider in providers {
            do {
                let snapshot = try await provider.fetch(environment: environment)
                Self.log("✓ \(provider.displayName): \(snapshot.plans.count) plan(s)")
                arkLastUpdatedAt = Date()
                lastSuccessfulArkSnapshot = snapshot
                arkStatus = .ok(snapshot: snapshot)
                finishArkRefresh()
                return
            } catch let error as UsageError {
                Self.log("✗ \(provider.displayName): \(error.errorDescription ?? "Unknown error")")
                lastError = error.errorDescription ?? "Unknown error"
            } catch {
                Self.log("✗ \(provider.displayName): \(error.localizedDescription)")
                lastError = error.localizedDescription
            }
        }
        finishArkRefresh(error: lastError)
    }

    private func runOpenCodeProvider(_ provider: OpenCodeGoProvider, environment: [String: String]) async {
        // First attempt: try with the cached credential (fast, no prompt).
        do {
            let snapshot = try await provider.fetch(environment: environment)
            Self.log("✓ \(provider.displayName): \(snapshot.plans.count) plan(s)")
            opencodeLastUpdatedAt = Date()
            lastSuccessfulOpenCodeSnapshot = snapshot
            opencodeStatus = .ok(snapshot: snapshot)
            finishOpenCodeRefresh()
            return
        } catch let UsageError.openCodeBrowserSessionMissing(detail) {
            // No cached credential — run the browser import once. This triggers a
            // macOS Keychain password prompt (SweetCookieKit decrypting Chrome's
            // cookie store). After import the credential is cached in TokenBar's
            // own Keychain so subsequent refreshes are silent.
            Self.log("→ OpenCode Go: no cached session, starting browser import (\(detail))")
        } catch let error as UsageError {
            Self.log("✗ \(provider.displayName): \(error.errorDescription ?? "Unknown error")")
            finishOpenCodeRefresh(error: error.errorDescription ?? "Unknown error")
            return
        } catch {
            Self.log("✗ \(provider.displayName): \(error.localizedDescription)")
            finishOpenCodeRefresh(error: error.localizedDescription)
            return
        }

        // Browser import (runs on main actor for the Keychain prompt).
        let browser = await MainActor.run {
            OpenCodeGoBrowserSession.browserForInteractiveImport()
        }
        do {
            _ = try await Task.detached(priority: .userInitiated) {
                try OpenCodeGoBrowserSession.importSessionInteractively(from: browser)
            }.value
            // Second attempt: now the credential is cached, fetch again.
            let snapshot = try await provider.fetch(environment: environment)
            Self.log("✓ \(provider.displayName): \(snapshot.plans.count) plan(s) (after browser import)")
            opencodeLastUpdatedAt = Date()
            lastSuccessfulOpenCodeSnapshot = snapshot
            opencodeStatus = .ok(snapshot: snapshot)
            finishOpenCodeRefresh()
        } catch {
            Self.log("✗ \(provider.displayName): browser import + fetch failed: \(error.localizedDescription)")
            finishOpenCodeRefresh(error: error.localizedDescription)
        }
    }

    private func finishArkRefresh(error: String? = nil) {
        arkIsRefreshing = false
        if let error {
            if let snapshot = lastSuccessfulArkSnapshot {
                arkStatus = .stale(snapshot: snapshot, message: error)
            } else {
                arkStatus = .error(message: error)
            }
        }
    }

    private func finishOpenCodeRefresh(error: String? = nil) {
        opencodeIsRefreshing = false
        if let error {
            if let snapshot = lastSuccessfulOpenCodeSnapshot {
                opencodeStatus = .stale(snapshot: snapshot, message: error)
            } else {
                opencodeStatus = .error(message: error)
            }
        }
    }

    private func refreshDeepSeek() {
        guard !deepseekIsRefreshing else { return }
        guard let provider = deepSeekProvider,
              provider.isAvailable(environment: ProcessInfo.processInfo.environment)
        else {
            if lastSuccessfulDeepSeekSnapshot == nil {
                deepseekStatus = .error(message: L(.errorDeepSeekMissingCredentials))
            }
            return
        }
        deepseekIsRefreshing = true
        switch deepseekStatus {
        case .ok, .stale:
            break // retain usable data while the request is in flight
        case .never, .loading, .error:
            deepseekStatus = .loading
        }
        let environment = ProcessInfo.processInfo.environment
        Task { [weak self] in
            await self?.runDeepSeekProvider(provider, environment: environment)
        }
    }

    private func runDeepSeekProvider(_ provider: DeepSeekProvider, environment: [String: String]) async {
        do {
            let snapshot = try await provider.fetch(environment: environment)
            Self.log("✓ \(provider.displayName): balance + usage")
            deepseekLastUpdatedAt = Date()
            lastSuccessfulDeepSeekSnapshot = snapshot
            deepseekStatus = .ok(snapshot: snapshot)
            finishDeepSeekRefresh()
        } catch let error as UsageError {
            Self.log("✗ \(provider.displayName): \(error.errorDescription ?? "Unknown error")")
            finishDeepSeekRefresh(error: error.errorDescription ?? "Unknown error")
        } catch {
            Self.log("✗ \(provider.displayName): \(error.localizedDescription)")
            finishDeepSeekRefresh(error: error.localizedDescription)
        }
    }

    private func finishDeepSeekRefresh(error: String? = nil) {
        deepseekIsRefreshing = false
        if let error {
            if let snapshot = lastSuccessfulDeepSeekSnapshot {
                deepseekStatus = .stale(snapshot: snapshot, message: error)
            } else {
                deepseekStatus = .error(message: error)
            }
        }
    }

    private func refreshNebula() {
        guard !nebulaIsRefreshing else { return }
        guard let provider = nebulaProvider else { return }
        nebulaIsRefreshing = true
        switch nebulaStatus {
        case .ok, .stale:
            break // retain usable data while the request is in flight
        case .never, .loading, .error:
            nebulaStatus = .loading
        }
        let environment = ProcessInfo.processInfo.environment
        Task { [weak self] in
            await self?.runNebulaProvider(provider, environment: environment)
        }
    }

    private func runNebulaProvider(_ provider: NebulaProvider, environment: [String: String]) async {
        do {
            let snapshot = try await provider.fetch(environment: environment)
            Self.log("✓ \(provider.displayName): balance + usage")
            nebulaLastUpdatedAt = Date()
            lastSuccessfulNebulaSnapshot = snapshot
            nebulaStatus = .ok(snapshot: snapshot)
            finishNebulaRefresh()
        } catch let error as UsageError {
            Self.log("✗ \(provider.displayName): \(error.errorDescription ?? "Unknown error")")
            finishNebulaRefresh(error: error.errorDescription ?? "Unknown error")
        } catch {
            Self.log("✗ \(provider.displayName): \(error.localizedDescription)")
            finishNebulaRefresh(error: error.localizedDescription)
        }
    }

    private func finishNebulaRefresh(error: String? = nil) {
        nebulaIsRefreshing = false
        if let error {
            if let snapshot = lastSuccessfulNebulaSnapshot {
                nebulaStatus = .stale(snapshot: snapshot, message: error)
            } else {
                nebulaStatus = .error(message: error)
            }
        }
    }

    func status(for tab: ProviderTab) -> LoadStatus {
        switch tab {
        case .ark: return arkStatus
        case .opencode: return opencodeStatus
        case .deepseek: return deepseekStatus
        case .nebula: return nebulaStatus
        }
    }

    func lastUpdatedAt(for tab: ProviderTab) -> Date? {
        switch tab {
        case .ark: return arkLastUpdatedAt
        case .opencode: return opencodeLastUpdatedAt
        case .deepseek: return deepseekLastUpdatedAt
        case .nebula: return nebulaLastUpdatedAt
        }
    }

    func isRefreshing(for tab: ProviderTab) -> Bool {
        switch tab {
        case .ark: return arkIsRefreshing
        case .opencode: return opencodeIsRefreshing
        case .deepseek: return deepseekIsRefreshing
        case .nebula: return nebulaIsRefreshing
        }
    }

    private func scheduleNext() {
        timer?.invalidate()
        let interval = TimeInterval(settings.refreshInterval.rawValue)
        let timer = Timer(timeInterval: interval, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in self?.refreshAllConfigured() }
        }
        // Menu tracking uses a different run-loop mode. Common modes keep the
        // configured cadence alive while the popover is open.
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    nonisolated static func log(_ message: String) {
        let timestamp = ISO8601DateFormatter.string(
            from: Date(),
            timeZone: .current,
            formatOptions: [.withInternetDateTime])
        FileHandle.standardError.write(Data("[TokenBar \(timestamp)] \(message)\n".utf8))
    }
}
