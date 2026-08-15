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
    @Published private(set) var zaiStatus: LoadStatus = .never
    @Published private(set) var kimiStatus: LoadStatus = .never
    @Published private(set) var grokPoolStatus: LoadStatus = .never
    @Published private(set) var arkLastUpdatedAt: Date?
    @Published private(set) var opencodeLastUpdatedAt: Date?
    @Published private(set) var deepseekLastUpdatedAt: Date?
    @Published private(set) var nebulaLastUpdatedAt: Date?
    @Published private(set) var zaiLastUpdatedAt: Date?
    @Published private(set) var kimiLastUpdatedAt: Date?
    @Published private(set) var grokPoolLastUpdatedAt: Date?
    @Published private(set) var arkIsRefreshing = false
    @Published private(set) var opencodeIsRefreshing = false
    @Published private(set) var deepseekIsRefreshing = false
    @Published private(set) var nebulaIsRefreshing = false
    @Published private(set) var zaiIsRefreshing = false
    @Published private(set) var kimiIsRefreshing = false
    @Published private(set) var grokPoolIsRefreshing = false

    /// Convenience for the status item: in summary mode, pick the tightest
    /// (lowest remaining percent) provider.
    var status: LoadStatus { currentStatus }
    var lastUpdatedAt: Date? { currentLastUpdatedAt }
    var isRefreshing: Bool { currentIsRefreshing }
    var currentStatus: LoadStatus {
        if case let .provider(tab) = settings.selectedMenu {
            return status(for: tab)
        }
        return tightestStatus
    }
    var currentLastUpdatedAt: Date? {
        if case let .provider(tab) = settings.selectedMenu {
            return lastUpdatedAt(for: tab)
        }
        return tightestLastUpdatedAt
    }
    var currentIsRefreshing: Bool {
        if case let .provider(tab) = settings.selectedMenu {
            return isRefreshing(for: tab)
        }
        return settings.visibleTabs.contains { isRefreshing(for: $0) }
    }

    /// All statuses, keyed by provider tab, for the summary view.
    var allStatuses: [ProviderTab: LoadStatus] {
        [.ark: arkStatus, .opencode: opencodeStatus,
         .deepseek: deepseekStatus, .nebula: nebulaStatus, .zai: zaiStatus,
         .kimi: kimiStatus, .grokPool: grokPoolStatus]
    }

    /// The "tightest" (lowest remaining percent, most urgent) provider.
    /// Used to drive the status-item icon when in summary mode.
    private var tightestStatus: LoadStatus {
        let candidates = settings.visibleTabs.compactMap { tab -> (ProviderTab, LoadStatus)? in
            let s = status(for: tab)
            guard s.snapshot != nil else { return nil }
            return (tab, s)
        }
        if let first = candidates.min(by: { a, b in
            let pa = a.1.snapshot?.sessionWindow?.remainingPercent ?? 100
            let pb = b.1.snapshot?.sessionWindow?.remainingPercent ?? 100
            return pa < pb
        }) {
            return first.1
        }
        // Fallback: first with any data, or .never
        return settings.visibleTabs
            .map { status(for: $0) }
            .first { $0 != .never } ?? .never
    }

    private var tightestLastUpdatedAt: Date? {
        settings.visibleTabs
            .compactMap { lastUpdatedAt(for: $0) }
            .max()
    }

    private let settings: AppSettings
    private var arkProviders: [UsageProvider] = []
    private var openCodeProvider: OpenCodeGoProvider?
    private var deepSeekProvider: DeepSeekProvider?
    private var nebulaProvider: NebulaProvider?
    private var zaiProvider: ZaiProvider?
    private var kimiProvider: KimiProvider?
    private var grokPoolProvider: GrokPoolProvider?
    private var timer: Timer?
    private var lastSuccessfulArkSnapshot: ProviderSnapshot?
    private var lastSuccessfulOpenCodeSnapshot: ProviderSnapshot?
    private var lastSuccessfulDeepSeekSnapshot: ProviderSnapshot?
    private var lastSuccessfulNebulaSnapshot: ProviderSnapshot?
    private var lastSuccessfulZaiSnapshot: ProviderSnapshot?
    private var lastSuccessfulKimiSnapshot: ProviderSnapshot?
    private var lastSuccessfulGrokPoolSnapshot: ProviderSnapshot?
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
        Publishers.MergeMany(
            settings.$deepseekApiKey.map { _ in },
            settings.$deepseekPlatformToken.map { _ in })
            .dropFirst()
            .sink { [weak self] _ in self?.refresh(tab: .deepseek) }
            .store(in: &cancellables)
        Publishers.MergeMany(
            settings.$nebulaAPIKey.map { _ in },
            settings.$nebulaBaseURL.map { _ in })
            .dropFirst()
            .sink { [weak self] _ in self?.refresh(tab: .nebula) }
            .store(in: &cancellables)
        settings.$zaiAPIKey
            .dropFirst()
            .sink { [weak self] _ in self?.refresh(tab: .zai) }
            .store(in: &cancellables)
        settings.$zaiRegion
            .dropFirst()
            .sink { [weak self] _ in self?.refresh(tab: .zai) }
            .store(in: &cancellables)
        settings.$kimiAPIKey
            .dropFirst()
            .sink { [weak self] _ in self?.refresh(tab: .kimi) }
            .store(in: &cancellables)
        Publishers.MergeMany(
            settings.$grokPoolAPIKey.map { _ in },
            settings.$grokPoolBaseURL.map { _ in })
            .dropFirst()
            .sink { [weak self] _ in self?.refresh(tab: .grokPool) }
            .store(in: &cancellables)
        // When the selection switches to a provider with no data, refresh it.
        settings.$selectedMenu
            .dropFirst()
            .sink { [weak self] menu in
                guard let self else { return }
                if case let .provider(tab) = menu, self.status(for: tab) == .never {
                    self.refresh(tab: tab)
                }
            }
            .store(in: &cancellables)
        // Re-enabling a hidden provider fetches it immediately.
        for tab in ProviderTab.allCases {
            let publisher: AnyPublisher<Bool, Never>
            switch tab {
            case .ark: publisher = settings.$showArk.eraseToAnyPublisher()
            case .opencode: publisher = settings.$showOpenCode.eraseToAnyPublisher()
            case .deepseek: publisher = settings.$showDeepSeek.eraseToAnyPublisher()
            case .nebula: publisher = settings.$showNebula.eraseToAnyPublisher()
            case .zai: publisher = settings.$showZai.eraseToAnyPublisher()
            case .kimi: publisher = settings.$showKimi.eraseToAnyPublisher()
            case .grokPool: publisher = settings.$showGrokPool.eraseToAnyPublisher()
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

    /// Rebuild the Ark provider priority.
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
        zaiProvider = ZaiProvider(settings: settings)
        kimiProvider = KimiProvider(settings: settings)
        grokPoolProvider = GrokPoolProvider(settings: settings)
    }

    func start() {
        refreshAllConfigured()
        scheduleNext()
    }

    func refresh() {
        if case let .provider(tab) = settings.selectedMenu {
            refresh(tab: tab)
        } else {
            refreshAllConfigured()
        }
    }

    func refresh(tab: ProviderTab) {
        switch tab {
        case .ark: refreshArk()
        case .opencode: refreshOpenCode()
        case .deepseek: refreshDeepSeek()
        case .nebula: refreshNebula()
        case .zai: refreshZai()
        case .kimi: refreshKimi()
        case .grokPool: refreshGrokPool()
        }
    }

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
        case .ok, .stale: break
        case .never, .loading, .error: opencodeStatus = .loading
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
        case .ok, .stale: break
        case .never, .loading, .error: nebulaStatus = .loading
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

    func reimportKimiBrowserSession() {
        guard !kimiIsRefreshing else { return }
        guard let provider = kimiProvider else {
            if lastSuccessfulKimiSnapshot == nil {
                kimiStatus = .error(message: L(.errorKimiBrowserAuthorizationRequired))
            }
            return
        }

        kimiIsRefreshing = true
        switch kimiStatus {
        case .ok, .stale: break
        case .never, .loading, .error: kimiStatus = .loading
        }

        let environment = ProcessInfo.processInfo.environment
        let browser = KimiBrowserSession.browserForInteractiveImport()
        Task { [weak self] in
            guard let self else { return }
            do {
                _ = try await Task.detached(priority: .userInitiated) {
                    try KimiBrowserSession.importSessionInteractively(from: browser)
                }.value
                await self.runKimiProvider(provider, environment: environment)
            } catch {
                Self.log("✗ Kimi browser import: \(error.localizedDescription)")
                self.finishKimiRefresh(error: error.localizedDescription)
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
        case .ok, .stale: break
        case .never, .loading, .error: arkStatus = .loading
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
        case .ok, .stale: break
        case .never, .loading, .error: opencodeStatus = .loading
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
        do {
            let snapshot = try await provider.fetch(environment: environment)
            Self.log("✓ \(provider.displayName): \(snapshot.plans.count) plan(s)")
            opencodeLastUpdatedAt = Date()
            lastSuccessfulOpenCodeSnapshot = snapshot
            opencodeStatus = .ok(snapshot: snapshot)
            finishOpenCodeRefresh()
            return
        } catch let UsageError.openCodeBrowserSessionMissing(detail) {
            Self.log("→ OpenCode Go: no cached session, skipping auto import (\(detail))")
            finishOpenCodeRefresh(error: L(.errorOpenCodeBrowserAuthorizationRequired))
            return
        } catch let error as UsageError {
            Self.log("✗ \(provider.displayName): \(error.errorDescription ?? "Unknown error")")
            finishOpenCodeRefresh(error: error.errorDescription ?? "Unknown error")
            return
        } catch {
            Self.log("✗ \(provider.displayName): \(error.localizedDescription)")
            finishOpenCodeRefresh(error: error.localizedDescription)
            return
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
        case .ok, .stale: break
        case .never, .loading, .error: deepseekStatus = .loading
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
        case .ok, .stale: break
        case .never, .loading, .error: nebulaStatus = .loading
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

    private func refreshZai() {
        guard !zaiIsRefreshing else { return }
        guard let provider = zaiProvider else { return }
        zaiIsRefreshing = true
        switch zaiStatus {
        case .ok, .stale: break
        case .never, .loading, .error: zaiStatus = .loading
        }
        let environment = ProcessInfo.processInfo.environment
        Task { [weak self] in
            await self?.runZaiProvider(provider, environment: environment)
        }
    }

    private func runZaiProvider(_ provider: ZaiProvider, environment: [String: String]) async {
        do {
            let snapshot = try await provider.fetch(environment: environment)
            Self.log("✓ \(provider.displayName): \(snapshot.plans.count) plan(s)")
            zaiLastUpdatedAt = Date()
            lastSuccessfulZaiSnapshot = snapshot
            zaiStatus = .ok(snapshot: snapshot)
            finishZaiRefresh()
        } catch let error as UsageError {
            Self.log("✗ \(provider.displayName): \(error.errorDescription ?? "Unknown error")")
            finishZaiRefresh(error: error.errorDescription ?? "Unknown error")
        } catch {
            Self.log("✗ \(provider.displayName): \(error.localizedDescription)")
            finishZaiRefresh(error: error.localizedDescription)
        }
    }

    private func finishZaiRefresh(error: String? = nil) {
        zaiIsRefreshing = false
        if let error {
            if let snapshot = lastSuccessfulZaiSnapshot {
                zaiStatus = .stale(snapshot: snapshot, message: error)
            } else {
                zaiStatus = .error(message: error)
            }
        }
    }

    private func refreshKimi() {
        guard !kimiIsRefreshing else { return }
        guard let provider = kimiProvider else { return }
        kimiIsRefreshing = true
        switch kimiStatus {
        case .ok, .stale: break
        case .never, .loading, .error: kimiStatus = .loading
        }
        let environment = ProcessInfo.processInfo.environment
        Task { [weak self] in
            await self?.runKimiProvider(provider, environment: environment)
        }
    }

    private func runKimiProvider(_ provider: KimiProvider, environment: [String: String]) async {
        do {
            let snapshot = try await provider.fetch(environment: environment)
            Self.log("✓ \(provider.displayName): \(snapshot.plans.count) plan(s)")
            kimiLastUpdatedAt = Date()
            lastSuccessfulKimiSnapshot = snapshot
            kimiStatus = .ok(snapshot: snapshot)
            finishKimiRefresh()
        } catch let error as UsageError {
            Self.log("✗ \(provider.displayName): \(error.errorDescription ?? "Unknown error")")
            finishKimiRefresh(error: error.errorDescription ?? "Unknown error")
        } catch {
            Self.log("✗ \(provider.displayName): \(error.localizedDescription)")
            finishKimiRefresh(error: error.localizedDescription)
        }
    }

    private func finishKimiRefresh(error: String? = nil) {
        kimiIsRefreshing = false
        if let error {
            if let snapshot = lastSuccessfulKimiSnapshot {
                kimiStatus = .stale(snapshot: snapshot, message: error)
            } else {
                kimiStatus = .error(message: error)
            }
        }
    }

    private func refreshGrokPool() {
        guard !grokPoolIsRefreshing else { return }
        guard let provider = grokPoolProvider else { return }
        grokPoolIsRefreshing = true
        switch grokPoolStatus {
        case .ok, .stale: break
        case .never, .loading, .error: grokPoolStatus = .loading
        }
        let environment = ProcessInfo.processInfo.environment
        Task { [weak self] in
            await self?.runGrokPoolProvider(provider, environment: environment)
        }
    }

    private func runGrokPoolProvider(_ provider: GrokPoolProvider, environment: [String: String]) async {
        do {
            let snapshot = try await provider.fetch(environment: environment)
            Self.log("✓ \(provider.displayName): balance + usage")
            grokPoolLastUpdatedAt = Date()
            lastSuccessfulGrokPoolSnapshot = snapshot
            grokPoolStatus = .ok(snapshot: snapshot)
            finishGrokPoolRefresh()
        } catch let error as UsageError {
            Self.log("✗ \(provider.displayName): \(error.errorDescription ?? "Unknown error")")
            finishGrokPoolRefresh(error: error.errorDescription ?? "Unknown error")
        } catch {
            Self.log("✗ \(provider.displayName): \(error.localizedDescription)")
            finishGrokPoolRefresh(error: error.localizedDescription)
        }
    }

    private func finishGrokPoolRefresh(error: String? = nil) {
        grokPoolIsRefreshing = false
        if let error {
            if let snapshot = lastSuccessfulGrokPoolSnapshot {
                grokPoolStatus = .stale(snapshot: snapshot, message: error)
            } else {
                grokPoolStatus = .error(message: error)
            }
        }
    }

    func status(for tab: ProviderTab) -> LoadStatus {
        switch tab {
        case .ark: return arkStatus
        case .opencode: return opencodeStatus
        case .deepseek: return deepseekStatus
        case .nebula: return nebulaStatus
        case .zai: return zaiStatus
        case .kimi: return kimiStatus
        case .grokPool: return grokPoolStatus
        }
    }

    func lastUpdatedAt(for tab: ProviderTab) -> Date? {
        switch tab {
        case .ark: return arkLastUpdatedAt
        case .opencode: return opencodeLastUpdatedAt
        case .deepseek: return deepseekLastUpdatedAt
        case .nebula: return nebulaLastUpdatedAt
        case .zai: return zaiLastUpdatedAt
        case .kimi: return kimiLastUpdatedAt
        case .grokPool: return grokPoolLastUpdatedAt
        }
    }

    func isRefreshing(for tab: ProviderTab) -> Bool {
        switch tab {
        case .ark: return arkIsRefreshing
        case .opencode: return opencodeIsRefreshing
        case .deepseek: return deepseekIsRefreshing
        case .nebula: return nebulaIsRefreshing
        case .zai: return zaiIsRefreshing
        case .kimi: return kimiIsRefreshing
        case .grokPool: return grokPoolIsRefreshing
        }
    }

    private func scheduleNext() {
        timer?.invalidate()
        let interval = TimeInterval(settings.refreshInterval.rawValue)
        let timer = Timer(timeInterval: interval, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in self?.refreshAllConfigured() }
        }
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