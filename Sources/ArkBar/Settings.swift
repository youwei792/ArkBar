import Foundation

/// Persisted preferences, stored in UserDefaults.
@MainActor
final class AppSettings: ObservableObject {
    static let shared = AppSettings()

    enum RefreshInterval: Int, CaseIterable {
        case oneMinute = 60
        case twoMinutes = 120
        case fiveMinutes = 300
        case fifteenMinutes = 900
        case thirtyMinutes = 1800

        var displayName: String {
            switch self {
            case .oneMinute: L(.interval1m)
            case .twoMinutes: L(.interval2m)
            case .fiveMinutes: L(.interval5m)
            case .fifteenMinutes: L(.interval15m)
            case .thirtyMinutes: L(.interval30m)
            }
        }
    }

    /// Which credential path to try first.
    enum SourceMode: String, CaseIterable {
        case auto
        case cli
        case api
    }

    /// Menu-bar display layout. Mirrors CodexBar's MenuBarLayout options.
    enum DisplayMode: String, CaseIterable {
        /// Just the capsule progress icon.
        case iconOnly
        /// Capsule icon followed by the remaining percent, e.g. `▮▮ 73%`.
        case iconAndPercent
        /// Just the remaining percent text, e.g. `73%`.
        case percentOnly

        var displayName: String {
            switch self {
            case .iconOnly: L(.displayIconOnly)
            case .iconAndPercent: L(.displayIconAndPercent)
            case .percentOnly: L(.displayPercentOnly)
            }
        }
    }

    @Published var refreshInterval: RefreshInterval {
        didSet { UserDefaults.standard.set(refreshInterval.rawValue, forKey: Keys.refreshInterval) }
    }
    /// When enabled, opening the menu-bar item starts a refresh. Disabled by
    /// default so the configured interval remains the only automatic trigger.
    @Published var refreshWhenMenuOpens: Bool {
        didSet { UserDefaults.standard.set(refreshWhenMenuOpens, forKey: Keys.refreshWhenMenuOpens) }
    }
    @Published var sourceMode: SourceMode {
        didSet { UserDefaults.standard.set(sourceMode.rawValue, forKey: Keys.sourceMode) }
    }
    @Published var displayMode: DisplayMode {
        didSet { UserDefaults.standard.set(displayMode.rawValue, forKey: Keys.displayMode) }
    }
    @Published var language: Language {
        didSet {
            UserDefaults.standard.set(language.rawValue, forKey: Keys.language)
            if L10n.shared.language != language {
                L10n.shared.language = language
            }
        }
    }
    /// Currently selected menu-bar tab (Ark vs OpenCode Go).
    @Published var selectedTab: ProviderTab {
        didSet { UserDefaults.standard.set(selectedTab.rawValue, forKey: Keys.selectedTab) }
    }
    /// OpenCode Go workspace ID. When empty, the provider auto-resolves it from
    /// the cookie by hitting `opencode.ai/_server`.
    @Published var opencodeWorkspaceID: String {
        didSet { UserDefaults.standard.set(opencodeWorkspaceID, forKey: Keys.opencodeWorkspaceID) }
    }
    /// OpenCode Go cookie header. Persisted to Keychain (not UserDefaults); the
    /// in-memory copy drives `UsageStore` refresh on change. Load on init via
    /// `loadOpenCodeCookieFromKeychain()`; set via `setOpenCodeCookie(_:)`.
    @Published private(set) var opencodeCookie: String

    /// Replace the persisted OpenCode Go cookie. Writes Keychain + updates the
    /// in-memory `@Published` so `UsageStore` re-fetches. Pass nil/empty to clear.
    func setOpenCodeCookie(_ value: String?) {
        let trimmed = value?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .nilIfEmpty
        CookieKeychainStore.store(cookie: trimmed, provider: "opencode")
        opencodeCookie = trimmed ?? ""
    }

    /// Reload the OpenCode cookie from Keychain (e.g. after an external change).
    func loadOpenCodeCookieFromKeychain() {
        opencodeCookie = CookieKeychainStore.load(provider: "opencode") ?? ""
    }

    var opencodeCookieHasValue: Bool { !opencodeCookie.isEmpty }

    private enum Keys {
        static let refreshInterval = "arkbar.refreshInterval"
        static let refreshWhenMenuOpens = "arkbar.refreshWhenMenuOpens"
        static let sourceMode = "arkbar.sourceMode"
        static let displayMode = "arkbar.displayMode"
        static let language = "arkbar.language"
        static let selectedTab = "arkbar.selectedTab"
        static let opencodeWorkspaceID = "arkbar.opencodeWorkspaceID"
    }

    private init() {
        let defaults = UserDefaults.standard
        let intervalRaw = defaults.object(forKey: Keys.refreshInterval) as? Int ?? RefreshInterval.fiveMinutes.rawValue
        self.refreshInterval = RefreshInterval(rawValue: intervalRaw) ?? .fiveMinutes
        self.refreshWhenMenuOpens = defaults.object(forKey: Keys.refreshWhenMenuOpens) as? Bool ?? false
        let modeRaw = defaults.string(forKey: Keys.sourceMode) ?? SourceMode.auto.rawValue
        self.sourceMode = SourceMode(rawValue: modeRaw) ?? .auto
        let displayRaw = defaults.string(forKey: Keys.displayMode) ?? DisplayMode.iconAndPercent.rawValue
        self.displayMode = DisplayMode(rawValue: displayRaw) ?? .iconAndPercent
        let langRaw = defaults.string(forKey: Keys.language) ?? Language.system.rawValue
        self.language = Language(rawValue: langRaw) ?? .system
        let tabRaw = defaults.string(forKey: Keys.selectedTab) ?? ProviderTab.ark.rawValue
        self.selectedTab = ProviderTab(rawValue: tabRaw) ?? .ark
        self.opencodeWorkspaceID = defaults.string(forKey: Keys.opencodeWorkspaceID) ?? ""
        // Cookie lives in Keychain; load once at init. UserDefaults only tracks
        // whether a cookie has ever been configured (for first-run UI hints).
        self.opencodeCookie = CookieKeychainStore.load(provider: "opencode") ?? ""
    }
}

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
