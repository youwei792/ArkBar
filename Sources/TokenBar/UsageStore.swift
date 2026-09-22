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

    /// Per-provider presentation state. Published as one dictionary so every
    /// observer (status item, reminders, settings) gets a single signal
    /// regardless of which track changed.
    struct TrackState: Equatable {
        var status: LoadStatus = .never
        var lastUpdatedAt: Date?
        var isRefreshing = false
    }

    @Published private(set) var states: [ProviderTab: TrackState] = Dictionary(
        uniqueKeysWithValues: ProviderTab.allCases.map { ($0, TrackState()) })

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
    var allStatuses: [ProviderTab: LoadStatus] { states.mapValues(\.status) }

    /// Expiring-subscription reminders, recomputed whenever any provider
    /// snapshot or reminder setting changes.
    let reminderScheduler: ReminderScheduler

    /// The "tightest" (lowest remaining percent, most urgent) provider.
    /// Used to drive the status-item icon when in summary mode.
    private var tightestStatus: LoadStatus {
        let candidates = settings.visibleTabs.compactMap { tab -> (ProviderTab, LoadStatus)? in
            let s = status(for: tab)
            guard s.snapshot != nil else { return nil }
            return (tab, s)
        }
        if let first = candidates.min(by: { a, b in
            let pa = a.1.snapshot?.menuBarWindow?.remainingPercent ?? 100
            let pb = b.1.snapshot?.menuBarWindow?.remainingPercent ?? 100
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

    /// One fetcher per provider tab, rebuilt when credentials or the Ark
    /// source mode change. Everything `refresh`/`run` needs to know about a
    /// provider lives here, so the refresh flow is written once.
    private struct Track {
        typealias Fetch = @Sendable ([String: String]) async throws -> ProviderSnapshot

        var fetch: Fetch?
        var isAvailable: @Sendable ([String: String]) -> Bool = { _ in true }
        /// Error shown when a refresh is attempted while the track is
        /// unavailable and has never succeeded (nil = silent no-op).
        var refreshUnavailableError: String?
        /// Error shown when a browser-session re-import is attempted while
        /// the track is unavailable and has never succeeded.
        var importUnavailableError: String?
        /// Maps a fetch error to its user-facing message.
        var errorMessage: @Sendable (Error) -> String = Self.defaultErrorMessage
        /// Success log payload, e.g. "3 plan(s)" / "balance + usage".
        var successLog: @Sendable (ProviderSnapshot) -> String = { "\($0.plans.count) plan(s)" }
        /// Label for log lines.
        var logName: String

        static func defaultErrorMessage(_ error: Error) -> String {
            if let usageError = error as? UsageError {
                return usageError.errorDescription ?? "Unknown error"
            }
            if let trackError = error as? TrackFailure {
                return trackError.message
            }
            return error.localizedDescription
        }
    }

    /// Carries a pre-formatted message through the generic error mapping
    /// (used by the Ark multi-provider fallback loop).
    private struct TrackFailure: Error {
        let message: String
    }

    private let settings: AppSettings
    private var tracks: [ProviderTab: Track] = [:]
    private var timer: Timer?
    private var cancellables = Set<AnyCancellable>()

    init(settings: AppSettings = .shared) {
        self.settings = settings
        self.reminderScheduler = ReminderScheduler(settings: settings)
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
        settings.$arkAccessKeyID
            .combineLatest(settings.$arkSecretAccessKey)
            .dropFirst()
            .sink { [weak self] _ in
                // A saved half-pair resolves to nil in resolvedVolcCredentials,
                // so rebuilding is always safe here.
                self?.rebuildProviders()
                self?.refresh(tab: .ark)
            }
            .store(in: &cancellables)
        // Credential changes refresh their tab.
        let credentialTriggers: [(AnyPublisher<Void, Never>, ProviderTab)] = [
            (settings.$opencodeCookie.map { _ in () }.eraseToAnyPublisher(), .opencode),
            (settings.$opencodeCookieSource.map { _ in () }.eraseToAnyPublisher(), .opencode),
            (settings.$opencodeWorkspaceID
                .debounce(for: .milliseconds(350), scheduler: RunLoop.main)
                .map { _ in () }.eraseToAnyPublisher(), .opencode),
            (settings.$deepseekApiKey.map { _ in () }.eraseToAnyPublisher(), .deepseek),
            (settings.$deepseekPlatformToken.map { _ in () }.eraseToAnyPublisher(), .deepseek),
            (settings.$nebulaAPIKey.map { _ in () }.eraseToAnyPublisher(), .nebula),
            (settings.$nebulaBaseURL.map { _ in () }.eraseToAnyPublisher(), .nebula),
            (settings.$zaiAPIKey.map { _ in () }.eraseToAnyPublisher(), .zai),
            (settings.$zaiRegion.map { _ in () }.eraseToAnyPublisher(), .zai),
            (settings.$kimiAPIKey.map { _ in () }.eraseToAnyPublisher(), .kimi),
            (settings.$grokPoolUsername.map { _ in () }.eraseToAnyPublisher(), .grokPool),
            (settings.$grokPoolPassword.map { _ in () }.eraseToAnyPublisher(), .grokPool),
            (settings.$grokPoolBaseURL.map { _ in () }.eraseToAnyPublisher(), .grokPool),
            (settings.$longcatCookie.map { _ in () }.eraseToAnyPublisher(), .longcat),
            (settings.$longcatCookieSource.map { _ in () }.eraseToAnyPublisher(), .longcat),
            (settings.$aliyunAPIKey.map { _ in () }.eraseToAnyPublisher(), .aliyun),
        ]
        for (publisher, tab) in credentialTriggers {
            publisher
                .dropFirst()
                .sink { [weak self] in self?.refresh(tab: tab) }
                .store(in: &cancellables)
        }
        // Reminder inputs: settings and any provider snapshot change.
        Publishers.MergeMany(
            settings.$expiryReminderEnabled.map { _ in () }.eraseToAnyPublisher(),
            settings.$expiryReminderDays.map { _ in () }.eraseToAnyPublisher(),
            settings.$expiryReminderNotify.map { _ in () }.eraseToAnyPublisher(),
            settings.$manualSubscriptions.map { _ in () }.eraseToAnyPublisher())
            .dropFirst()
            .sink { [weak self] _ in self?.updateReminders() }
            .store(in: &cancellables)
        // Recompute reminders only when a status actually changed (not on
        // isRefreshing/lastUpdatedAt flips).
        $states
            .map { $0.mapValues(\.status) }
            .removeDuplicates()
            .sink { [weak self] _ in self?.updateReminders() }
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
            case .longcat: publisher = settings.$showLongCat.eraseToAnyPublisher()
            case .aliyun: publisher = settings.$showAliyun.eraseToAnyPublisher()
            case .stepfun: publisher = settings.$showStepFun.eraseToAnyPublisher()
            case .sensenova: publisher = settings.$showSenseNova.eraseToAnyPublisher()
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

    /// Rebuild the fetcher per provider tab.
    func rebuildProviders() {
        let environment = ProcessInfo.processInfo.environment
        var next: [ProviderTab: Track] = [:]

        // Ark: an ordered list with first-success-wins semantics.
        var arkProviders: [UsageProvider] = []
        switch settings.sourceMode {
        case .cli:
            arkProviders = [ArkCLIProvider()]
        case .api:
            if let credentials = resolvedVolcCredentials(environment: environment) {
                arkProviders.append(VolcAPIProvider(credentials: credentials))
            }
            if let key = ArkAPIKeyResolver.resolve(environment: environment) {
                arkProviders.append(ArkAPIKeyProvider(apiKey: key))
            }
        case .auto:
            if let credentials = resolvedVolcCredentials(environment: environment) {
                arkProviders.append(VolcAPIProvider(credentials: credentials))
            }
            if let key = ArkAPIKeyResolver.resolve(environment: environment) {
                arkProviders.append(ArkAPIKeyProvider(apiKey: key))
            }
            arkProviders.append(ArkCLIProvider())
        }
        next[.ark] = Track(fetch: Self.arkFetch(providers: arkProviders), logName: "Ark")

        let openCode = OpenCodeGoProvider(settings: settings)
        next[.opencode] = singleTrack(
            openCode,
            isAvailable: { openCode.isAvailable(environment: $0) },
            refreshUnavailableError: L(.errorOpenCodeCookieMissing),
            importUnavailableError: L(.errorOpenCodeBrowserAuthorizationRequired),
            errorMessage: { error in
                if let usageError = error as? UsageError,
                   case .openCodeBrowserSessionMissing = usageError
                {
                    return L(.errorOpenCodeBrowserAuthorizationRequired)
                }
                return Track.defaultErrorMessage(error)
            })

        let deepSeek = DeepSeekProvider(settings: settings)
        next[.deepseek] = singleTrack(
            deepSeek,
            isAvailable: { deepSeek.isAvailable(environment: $0) },
            refreshUnavailableError: L(.errorDeepSeekMissingCredentials),
            successLog: { _ in "balance + usage" })

        let nebula = NebulaProvider(settings: settings)
        next[.nebula] = singleTrack(
            nebula,
            importUnavailableError: L(.errorNebulaBrowserAuthorizationRequired),
            successLog: { _ in "balance + usage" })

        next[.zai] = singleTrack(ZaiProvider(settings: settings))

        let kimi = KimiProvider(settings: settings)
        next[.kimi] = singleTrack(
            kimi,
            importUnavailableError: L(.errorKimiBrowserAuthorizationRequired))

        let grokPool = GrokPoolProvider(settings: settings)
        next[.grokPool] = singleTrack(
            grokPool,
            successLog: { _ in "balance + usage" })

        let longCat = LongCatProvider(settings: settings)
        next[.longcat] = singleTrack(
            longCat,
            importUnavailableError: L(.errorLongcatBrowserAuthorizationRequired),
            successLog: { _ in "token quota" })

        next[.aliyun] = singleTrack(AliyunProvider(settings: settings))

        next[.stepfun] = singleTrack(StepFunProvider(settings: settings))
        next[.sensenova] = singleTrack(SenseNovaProvider(settings: settings))

        tracks = next
    }

    private func singleTrack(
        _ provider: some UsageProvider,
        isAvailable: (@Sendable ([String: String]) -> Bool)? = nil,
        refreshUnavailableError: String? = nil,
        importUnavailableError: String? = nil,
        errorMessage: (@Sendable (Error) -> String)? = nil,
        successLog: (@Sendable (ProviderSnapshot) -> String)? = nil
    ) -> Track {
        let fetch: Track.Fetch = { environment in
            try await provider.fetch(environment: environment)
        }
        return Track(
            fetch: fetch,
            isAvailable: isAvailable ?? { _ in true },
            refreshUnavailableError: refreshUnavailableError,
            importUnavailableError: importUnavailableError,
            errorMessage: errorMessage ?? Track.defaultErrorMessage,
            successLog: successLog ?? { "\($0.plans.count) plan(s)" },
            logName: provider.displayName)
    }

    /// Ark signed-OpenAPI credentials, in the same precedence the DeepSeek
    /// provider documents: values entered in Settings (Keychain) first, then
    /// environment variables. A GUI app launched from Finder never sees shell
    /// rc environment variables, so the Keychain entry is what makes this path
    /// actually usable.
    private func resolvedVolcCredentials(environment: [String: String]) -> VolcCredentials? {
        settings.storedVolcCredentials ?? VolcCredentialResolver.resolve(environment: environment)
    }

    /// Ark's first-success-wins loop, preserving per-provider log lines.
    private static func arkFetch(providers: [UsageProvider]) -> Track.Fetch {
        { environment in
            guard !providers.isEmpty else {
                throw TrackFailure(message: L(.noProvider))
            }
            var lastError = L(.noProvider)
            for provider in providers {
                do {
                    let snapshot = try await provider.fetch(environment: environment)
                    Self.log("✓ \(provider.displayName): \(snapshot.plans.count) plan(s)")
                    return snapshot
                } catch let error as UsageError {
                    Self.log("✗ \(provider.displayName): \(error.errorDescription ?? "Unknown error")")
                    lastError = error.errorDescription ?? "Unknown error"
                } catch {
                    Self.log("✗ \(provider.displayName): \(error.localizedDescription)")
                    lastError = error.localizedDescription
                }
            }
            throw TrackFailure(message: lastError)
        }
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

    /// Refresh every visible provider regardless of the current selection —
    /// the General settings pane's "Refresh All" action.
    func refreshAll() {
        refreshAllConfigured()
    }

    func refresh(tab: ProviderTab) {
        // Single-flight per track; mirrors the old per-provider guards.
        guard states[tab]?.isRefreshing != true else { return }
        guard let track = tracks[tab], track.fetch != nil else { return }
        let environment = ProcessInfo.processInfo.environment
        guard track.isAvailable(environment) else {
            if states[tab]?.status.snapshot == nil, let message = track.refreshUnavailableError {
                mutate(tab) { $0.status = .error(message: message) }
            }
            return
        }
        mutate(tab) { state in
            state.isRefreshing = true
            switch state.status {
            case .ok, .stale: break
            case .never, .loading, .error: state.status = .loading
            }
        }
        let fetch = track.fetch!
        Task { [weak self] in
            await self?.run(tab, fetch: fetch, environment: environment)
        }
    }

    func reimportOpenCodeBrowserSession() {
        let browser = OpenCodeGoBrowserSession.browserForInteractiveImport()
        reimportBrowserSession(.opencode) {
            _ = try OpenCodeGoBrowserSession.importSessionInteractively(from: browser)
        }
    }

    func reimportNebulaBrowserSession() {
        let browser = NebulaBrowserSession.browserForInteractiveImport()
        reimportBrowserSession(.nebula) {
            _ = try NebulaBrowserSession.importSessionInteractively(from: browser)
        }
    }

    func reimportKimiBrowserSession() {
        let browser = KimiBrowserSession.browserForInteractiveImport()
        reimportBrowserSession(.kimi) {
            _ = try KimiBrowserSession.importSessionInteractively(from: browser)
        }
    }

    func reimportLongCatBrowserSession() {
        let browser = LongCatBrowserSession.browserForInteractiveImport()
        reimportBrowserSession(.longcat) {
            _ = try LongCatBrowserSession.importSessionInteractively(from: browser)
        }
    }

    func reimportStepFunBrowserSession() {
        let browser = StepFunBrowserSession.browserCandidates().first
        reimportBrowserSession(.stepfun) {
            _ = try StepFunBrowserSession.importSessionInteractively(from: browser)
        }
    }

    func reimportSenseNovaBrowserSession() {
        let browser = SenseNovaBrowserSession.browserCandidates().first
        reimportBrowserSession(.sensenova) {
            _ = try SenseNovaBrowserSession.importSessionInteractively(from: browser)
        }
    }

    /// Shared browser-session re-import: import interactively, then refresh
    /// the track with the freshly imported session.
    private func reimportBrowserSession(
        _ tab: ProviderTab,
        importSession: @escaping @Sendable () throws -> Void
    ) {
        guard states[tab]?.isRefreshing != true else { return }
        let environment = ProcessInfo.processInfo.environment
        guard let track = tracks[tab], track.fetch != nil, track.isAvailable(environment) else {
            if states[tab]?.status.snapshot == nil,
               let message = tracks[tab]?.importUnavailableError
            {
                mutate(tab) { $0.status = .error(message: message) }
            }
            return
        }
        mutate(tab) { state in
            state.isRefreshing = true
            switch state.status {
            case .ok, .stale: break
            case .never, .loading, .error: state.status = .loading
            }
        }
        Task { [weak self] in
            guard let self else { return }
            do {
                _ = try await Task.detached(priority: .userInitiated, operation: importSession).value
                guard let fetch = self.tracks[tab]?.fetch else { return }
                await self.run(tab, fetch: fetch, environment: environment)
            } catch {
                let message = error.localizedDescription
                Self.log("✗ \(self.tracks[tab]?.logName ?? "provider") browser import: \(message)")
                self.mutate(tab) { state in
                    state.isRefreshing = false
                    if let snapshot = state.status.snapshot {
                        state.status = .stale(snapshot: snapshot, message: message)
                    } else {
                        state.status = .error(message: message)
                    }
                }
            }
        }
    }

    private func run(_ tab: ProviderTab, fetch: Track.Fetch, environment: [String: String]) async {
        let track = tracks[tab]
        do {
            let snapshot = try await fetch(environment)
            Self.log("✓ \(track?.logName ?? "provider"): \(track?.successLog(snapshot) ?? "\(snapshot.plans.count) plan(s)")")
            mutate(tab) { state in
                state.lastUpdatedAt = Date()
                state.status = .ok(snapshot: snapshot)
                state.isRefreshing = false
            }
        } catch {
            let message = track?.errorMessage(error) ?? error.localizedDescription
            Self.log("✗ \(track?.logName ?? "provider"): \(message)")
            mutate(tab) { state in
                state.isRefreshing = false
                if let snapshot = state.status.snapshot {
                    state.status = .stale(snapshot: snapshot, message: message)
                } else {
                    state.status = .error(message: message)
                }
            }
        }
    }

    private func refreshAllConfigured() {
        for tab in settings.visibleTabs {
            refresh(tab: tab)
        }
    }

    // MARK: - State access

    private func mutate(_ tab: ProviderTab, _ transform: (inout TrackState) -> Void) {
        var state = states[tab] ?? TrackState()
        transform(&state)
        states[tab] = state
    }

    func status(for tab: ProviderTab) -> LoadStatus {
        states[tab]?.status ?? .never
    }

    func lastUpdatedAt(for tab: ProviderTab) -> Date? {
        states[tab]?.lastUpdatedAt
    }

    func isRefreshing(for tab: ProviderTab) -> Bool {
        states[tab]?.isRefreshing ?? false
    }

    // MARK: - Expiry reminders

    /// Recomputes reminder items from every provider snapshot (plans with a
    /// verified expiry date) plus the user's manual subscriptions.
    private func updateReminders() {
        var sources: [PlanReminderSource] = []
        for (tab, status) in allStatuses {
            guard let snapshot = status.snapshot else { continue }
            for plan in snapshot.plans {
                guard let expiryDate = plan.expiryDate else { continue }
                // The quota that lapses at expiry is the monthly pool when the
                // plan has one; fall back to the tightest window.
                let remaining = plan.windows
                    .first(where: { $0.sortRank == 2 })?
                    .remainingPercent ?? plan.tightestWindow?.remainingPercent
                sources.append(PlanReminderSource(
                    tab: tab,
                    planID: plan.id,
                    expiryDate: expiryDate,
                    remainingPercent: remaining))
            }
        }
        reminderScheduler.update(
            planSources: sources,
            manual: settings.manualSubscriptions)
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
