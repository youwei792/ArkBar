import Foundation
import Combine

/// Owns the providers and the refresh loop, and publishes the current aggregated state
/// the UI renders. Adding a new subscription/plan = add a new `UsageProvider` to `providers`.
///
/// ArkBar tracks two independent provider tracks:
/// - **Ark**: the existing priority-ordered list (arkcli / AK-SK / API key).
/// - **OpenCode Go**: a single cookie-authenticated web provider.
/// Each track has its own `LoadStatus` and last-updated timestamp so the user can
/// switch tabs without losing the other track's data. The menu-bar icon reflects
/// whichever tab `AppSettings.selectedTab` currently points at.
@MainActor
final class UsageStore: ObservableObject {
    enum LoadStatus: Equatable {
        case never
        case loading
        case ok(snapshot: ProviderSnapshot)
        /// A refresh failed, but the last confirmed snapshot is still useful.
        case stale(snapshot: ProviderSnapshot, message: String)
        case error(message: String)

        var snapshot: ProviderSnapshot? {
            switch self {
            case let .ok(snapshot), let .stale(snapshot, _): return snapshot
            default: return nil
            }
        }
    }

    // Per-track published state. The UI subscribes to whichever track the
    // selected tab points at; see `currentStatus` / `currentLastUpdatedAt`.
    @Published private(set) var arkStatus: LoadStatus = .never
    @Published private(set) var opencodeStatus: LoadStatus = .never
    @Published private(set) var arkLastUpdatedAt: Date?
    @Published private(set) var opencodeLastUpdatedAt: Date?
    @Published private(set) var isRefreshing = false

    /// Currently-selected tab's status. Convenience for one-off reads.
    var currentStatus: LoadStatus {
        settings.selectedTab == .ark ? arkStatus : opencodeStatus
    }

    var currentLastUpdatedAt: Date? {
        settings.selectedTab == .ark ? arkLastUpdatedAt : opencodeLastUpdatedAt
    }

    private let settings: AppSettings
    private var arkProviders: [UsageProvider] = []
    private var opencodeProvider: OpenCodeGoProvider?
    private var timer: Timer?
    private var lastSuccessfulArkSnapshot: ProviderSnapshot?
    private var lastSuccessfulOpenCodeSnapshot: ProviderSnapshot?
    private var arkRefreshInProgress = false
    private var opencodeRefreshInProgress = false
    private var cancellables = Set<AnyCancellable>()

    init(settings: AppSettings = .shared) {
        self.settings = settings
        self.rebuildProviders()
        settings.$refreshInterval
            .dropFirst()
            .sink { [weak self] _ in self?.scheduleNext() }
            .store(in: &cancellables)
        settings.$sourceMode
            .dropFirst()
            .sink { [weak self] _ in
                self?.rebuildProviders()
                self?.refresh()
            }
            .store(in: &cancellables)
        // Cookie change: rebuild the OpenCode provider (its URLSession is fine
        // to reuse, but `isAvailable` flips, so a refresh is what matters).
        settings.$opencodeCookie
            .dropFirst()
            .sink { [weak self] _ in self?.refresh() }
            .store(in: &cancellables)
    }

    /// Rebuild the provider list from the current settings + environment.
    /// In `auto`: prefer AK/SK, then API key, then arkcli (matches CodexBar's auto order:
    /// configured API credentials first so an ambient arkcli session can't switch accounts).
    func rebuildProviders() {
        let env = ProcessInfo.processInfo.environment
        var built: [UsageProvider] = []
        switch settings.sourceMode {
        case .cli:
            built.append(ArkCLIProvider())
        case .api:
            if let creds = VolcCredentialResolver.resolve(environment: env) {
                built.append(VolcAPIProvider(credentials: creds))
            }
            if let key = ArkAPIKeyResolver.resolve(environment: env) {
                built.append(ArkAPIKeyProvider(apiKey: key))
            }
        case .auto:
            if let creds = VolcCredentialResolver.resolve(environment: env) {
                built.append(VolcAPIProvider(credentials: creds))
            }
            if let key = ArkAPIKeyResolver.resolve(environment: env) {
                built.append(ArkAPIKeyProvider(apiKey: key))
            }
            // arkcli is always appended last in auto so it only runs if no API creds configured.
            // (CodexBar returns early when API creds exist; we instead let it be selectable in UI.)
            built.append(ArkCLIProvider())
        }
        self.arkProviders = built
        self.opencodeProvider = OpenCodeGoProvider(settings: settings)
    }

    func start() {
        self.refresh()
        self.scheduleNext()
    }

    /// Refresh both tracks concurrently. Each track writes its own status; the
    /// merged `isRefreshing` flag is true while either is in flight.
    func refresh() {
        let env = ProcessInfo.processInfo.environment

        // Ark track.
        if !arkRefreshInProgress {
            arkRefreshInProgress = true
            updateMergedRefreshing()
            switch arkStatus {
            case .ok, .stale:
                break   // keep confirmed data on screen
            case .never, .loading, .error:
                arkStatus = .loading
            }
            let providers = self.arkProviders
            Task { [weak self] in
                await self?.runArkProviders(providers, environment: env)
            }
        }

        // OpenCode Go track. Only runs if the provider is configured.
        if !opencodeRefreshInProgress, let opencode = self.opencodeProvider {
            if opencode.isAvailable(environment: env) {
                opencodeRefreshInProgress = true
                updateMergedRefreshing()
                switch opencodeStatus {
                case .ok, .stale:
                    break
                case .never, .loading, .error:
                    opencodeStatus = .loading
                }
                Task { [weak self] in
                    await self?.runOpenCodeProvider(opencode, environment: env)
                }
            } else if case .never = opencodeStatus {
                // Unconfigured: surface a soft error so the OpenCode tab shows
                // a "configure in Settings" hint instead of an infinite spinner.
                opencodeStatus = .error(message: L(.opencodeCookieNotSet))
            }
        }
    }

    private func runArkProviders(_ providers: [UsageProvider], environment: [String: String]) async {
        guard !providers.isEmpty else {
            finishArkRefresh(error: L(.noProvider))
            return
        }
        var lastError = L(.noProvider)
        // Try each provider in priority order; first success wins.
        for provider in providers {
            do {
                let snapshot = try await provider.fetch(environment: environment)
                Self.log("✓ \(provider.displayName): \(snapshot.plans.count) plan(s), tightest=\(snapshot.tightestWindow?.usedPercent ?? -1)%")
                self.arkLastUpdatedAt = Date()
                self.lastSuccessfulArkSnapshot = snapshot
                self.arkStatus = .ok(snapshot: snapshot)
                finishArkRefresh()
                return
            } catch let error as UsageError {
                Self.log("✗ \(provider.displayName): \(error.errorDescription ?? "Unknown error")")
                lastError = error.errorDescription ?? "Unknown error"
                continue
            } catch {
                Self.log("✗ \(provider.displayName): \(error.localizedDescription)")
                lastError = error.localizedDescription
                continue
            }
        }
        finishArkRefresh(error: lastError)
    }

    private func runOpenCodeProvider(_ provider: OpenCodeGoProvider, environment: [String: String]) async {
        do {
            let snapshot = try await provider.fetch(environment: environment)
            Self.log("✓ \(provider.displayName): \(snapshot.plans.count) plan(s)")
            self.opencodeLastUpdatedAt = Date()
            self.lastSuccessfulOpenCodeSnapshot = snapshot
            self.opencodeStatus = .ok(snapshot: snapshot)
            finishOpenCodeRefresh()
        } catch let error as UsageError {
            Self.log("✗ \(provider.displayName): \(error.errorDescription ?? "Unknown error")")
            finishOpenCodeRefresh(error: error.errorDescription ?? "Unknown error")
        } catch {
            Self.log("✗ \(provider.displayName): \(error.localizedDescription)")
            finishOpenCodeRefresh(error: error.localizedDescription)
        }
    }

    private func finishArkRefresh(error: String? = nil) {
        arkRefreshInProgress = false
        if let error {
            if let snapshot = lastSuccessfulArkSnapshot {
                arkStatus = .stale(snapshot: snapshot, message: error)
            } else {
                arkStatus = .error(message: error)
            }
        }
        updateMergedRefreshing()
    }

    private func finishOpenCodeRefresh(error: String? = nil) {
        opencodeRefreshInProgress = false
        if let error {
            if let snapshot = lastSuccessfulOpenCodeSnapshot {
                opencodeStatus = .stale(snapshot: snapshot, message: error)
            } else {
                opencodeStatus = .error(message: error)
            }
        }
        updateMergedRefreshing()
    }

    private func updateMergedRefreshing() {
        let merged = arkRefreshInProgress || opencodeRefreshInProgress
        if merged != isRefreshing {
            isRefreshing = merged
        }
    }

    private func scheduleNext() {
        timer?.invalidate()
        let interval = TimeInterval(settings.refreshInterval.rawValue)
        let timer = Timer(timeInterval: interval, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in self?.refresh() }
        }
        // Status menus run in an event-tracking mode. Adding the timer to the
        // common modes keeps the configured refresh cadence alive while a menu
        // is being opened or interacted with.
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    /// Diagnostic logger to stderr. Helps debug "menu bar shows nothing" issues;
    // run from terminal to see: `open /Applications/ArkBar.app` won't show this,
    // but launching the binary directly will.
    nonisolated static func log(_ message: String) {
        let stderr = FileHandle.standardError
        let timestamp = ISO8601DateFormatter.string(from: Date(), timeZone: .current, formatOptions: [.withInternetDateTime])
        let line = "[ArkBar \(timestamp)] \(message)\n"
        stderr.write(Data(line.utf8))
    }
}
