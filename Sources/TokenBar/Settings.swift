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

    /// OpenCode Go can reuse a signed-in browser session or a manually pasted
    /// Cookie header. Automatic is the default and mirrors CodexBar's provider
    /// settings without using its inaccurate local quota estimate.
    enum OpenCodeCookieSource: String, CaseIterable {
        case automatic
        case manual
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
    /// The provider currently shown by the menu-bar popover. Provider state is
    /// separate in `UsageStore`; this only persists the presentation choice.
    @Published var selectedTab: ProviderTab {
        didSet { UserDefaults.standard.set(selectedTab.rawValue, forKey: Keys.selectedTab) }
    }
    /// Optional OpenCode workspace override. When empty, the provider resolves
    /// the current workspace from the signed-in session.
    @Published var opencodeWorkspaceID: String {
        didSet { UserDefaults.standard.set(opencodeWorkspaceID, forKey: Keys.opencodeWorkspaceID) }
    }
    @Published var opencodeCookieSource: OpenCodeCookieSource {
        didSet { UserDefaults.standard.set(opencodeCookieSource.rawValue, forKey: Keys.opencodeCookieSource) }
    }
    /// In-memory mirror of the Keychain value. It is never written to defaults.
    @Published private(set) var opencodeCookie: String

    func setOpenCodeCookie(_ value: String?) {
        let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines)
        let cookie = trimmed?.isEmpty == false ? trimmed : nil
        let persisted = CookieKeychainStore.store(cookie: cookie, provider: "opencode")
        // Do not claim a new credential is configured when Keychain rejected
        // the write; keep the in-memory mirror aligned with what can actually
        // be read by the provider on the next refresh.
        opencodeCookie = persisted ? (cookie ?? "") : (CookieKeychainStore.load(provider: "opencode") ?? "")
    }

    func loadOpenCodeCookieFromKeychain() {
        opencodeCookie = CookieKeychainStore.load(provider: "opencode") ?? ""
    }

    var opencodeCookieHasValue: Bool { !opencodeCookie.isEmpty }

    private enum Keys {
        static let refreshInterval = "tokenbar.refreshInterval"
        static let refreshWhenMenuOpens = "tokenbar.refreshWhenMenuOpens"
        static let sourceMode = "tokenbar.sourceMode"
        static let displayMode = "tokenbar.displayMode"
        static let language = "tokenbar.language"
        static let selectedTab = "tokenbar.selectedTab"
        static let opencodeWorkspaceID = "tokenbar.opencodeWorkspaceID"
        static let opencodeCookieSource = "tokenbar.opencodeCookieSource"
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
        let cookieSourceRaw = defaults.string(forKey: Keys.opencodeCookieSource)
            ?? OpenCodeCookieSource.automatic.rawValue
        self.opencodeCookieSource = OpenCodeCookieSource(rawValue: cookieSourceRaw) ?? .automatic
        self.opencodeCookie = CookieKeychainStore.load(provider: "opencode") ?? ""
    }
}
