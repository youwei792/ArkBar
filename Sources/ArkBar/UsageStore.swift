import Foundation
import Combine

/// Owns the providers and the refresh loop, and publishes the current aggregated state
/// the UI renders. Adding a new subscription/plan = add a new `UsageProvider` to `providers`.
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

    @Published private(set) var status: LoadStatus = .never
    @Published private(set) var lastUpdatedAt: Date?

    private let settings: AppSettings
    private var providers: [UsageProvider] = []
    private var timer: Timer?
    private var inFlight = false
    private var lastSuccessfulSnapshot: ProviderSnapshot?
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
        self.providers = built
    }

    func start() {
        self.refresh()
        self.scheduleNext()
    }

    func refresh() {
        guard !inFlight else {
            // A menu click, timer tick, and explicit button can arrive while a
            // slow CLI/API request is active. Coalescing them prevents a burst
            // of follow-up requests (and the menu crash that used to cause).
            return
        }
        inFlight = true
        switch status {
        case .ok, .stale:
            // Keep confirmed data on screen while the next sync is in flight.
            break
        case .never, .loading, .error:
            status = .loading
        }
        let providers = self.providers
        let env = ProcessInfo.processInfo.environment
        Task { [weak self] in
            await self?.runProviders(providers, environment: env)
        }
    }

    private func runProviders(_ providers: [UsageProvider], environment: [String: String]) async {
        guard !providers.isEmpty else {
            finishRefresh(error: L(.noProvider))
            return
        }
        var lastError = L(.noProvider)
        // Try each provider in priority order; first success wins.
        for provider in providers {
            do {
                let snapshot = try await provider.fetch(environment: environment)
                Self.log("✓ \(provider.displayName): \(snapshot.plans.count) plan(s), tightest=\(snapshot.tightestWindow?.usedPercent ?? -1)%")
                self.lastUpdatedAt = snapshot.updatedAt
                self.lastSuccessfulSnapshot = snapshot
                self.status = .ok(snapshot: snapshot)
                finishRefresh()
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
        finishRefresh(error: lastError)
    }

    private func finishRefresh(error: String? = nil) {
        inFlight = false
        if let error {
            if let snapshot = lastSuccessfulSnapshot {
                status = .stale(snapshot: snapshot, message: error)
            } else {
                status = .error(message: error)
            }
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
