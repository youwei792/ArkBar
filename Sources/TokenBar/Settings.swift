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

    /// What numeric value the menu bar shows for balance-based providers
    /// (DeepSeek, Nebula). Plan-based providers always show a percentage;
    /// this only affects providers whose "remaining" is a money balance.
    enum BalanceDisplay: String, CaseIterable {
        /// Remaining percentage of the balance/quota, e.g. `73%`.
        case percent
        /// Remaining money balance with currency symbol, e.g. `¥45.00`.
        case balance

        var displayName: String {
            switch self {
            case .percent: L(.displayValuePercent)
            case .balance: L(.displayValueBalance)
            }
        }
    }

    /// Menu-bar display layout. Mirrors CodexBar's menu-bar style options:
    /// a meter capsule, the provider logo, the remaining percent, or combos.
    enum DisplayMode: String, CaseIterable {
        /// Just the meter capsule, e.g. `▮▮▮░░░░░░░`.
        case iconOnly
        /// Meter capsule followed by the remaining percent, e.g. `▮▮ 73%`.
        case iconAndPercent
        /// Just the remaining percent text, e.g. `73%`.
        case percentOnly
        /// Just the provider logo.
        case logoOnly
        /// Provider logo followed by the remaining percent, e.g. `🐋 73%`.
        case logoAndPercent
        /// Provider logo followed by the meter capsule.
        case logoAndBar

        var displayName: String {
            switch self {
            case .iconOnly: L(.displayIconOnly)
            case .iconAndPercent: L(.displayIconAndPercent)
            case .percentOnly: L(.displayPercentOnly)
            case .logoOnly: L(.displayLogoOnly)
            case .logoAndPercent: L(.displayLogoAndPercent)
            case .logoAndBar: L(.displayLogoAndBar)
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
    @Published var selectedMenu: MenuSelection {
        didSet {
            // Persist the provider portion; summary is the default on restart.
            if case let .provider(tab) = selectedMenu {
                UserDefaults.standard.set(tab.rawValue, forKey: Keys.selectedTab)
            } else {
                UserDefaults.standard.removeObject(forKey: Keys.selectedTab)
            }
        }
    }
    /// Whether the overview tab appears in the switcher.
    @Published var showSummary: Bool {
        didSet { UserDefaults.standard.set(showSummary, forKey: Keys.showSummary) }
    }
    /// Whether each provider appears in the menu switcher (and refreshes in the
    /// background). Mirrors CodexBar's per-provider "Enabled" toggle.
    @Published var showArk: Bool {
        didSet { UserDefaults.standard.set(showArk, forKey: Keys.showArk) }
    }
    @Published var showOpenCode: Bool {
        didSet { UserDefaults.standard.set(showOpenCode, forKey: Keys.showOpenCode) }
    }
    @Published var showDeepSeek: Bool {
        didSet { UserDefaults.standard.set(showDeepSeek, forKey: Keys.showDeepSeek) }
    }
    @Published var showNebula: Bool {
        didSet { UserDefaults.standard.set(showNebula, forKey: Keys.showNebula) }
    }
    @Published var showZai: Bool {
        didSet { UserDefaults.standard.set(showZai, forKey: Keys.showZai) }
    }
    @Published var showKimi: Bool {
        didSet { UserDefaults.standard.set(showKimi, forKey: Keys.showKimi) }
    }
    /// Whether the menu bar shows the remaining percent or the money balance
    /// for balance-based providers (DeepSeek, Nebula).
    @Published var deepseekValueDisplay: BalanceDisplay {
        didSet { UserDefaults.standard.set(deepseekValueDisplay.rawValue, forKey: Keys.deepseekValueDisplay) }
    }
    @Published var nebulaValueDisplay: BalanceDisplay {
        didSet { UserDefaults.standard.set(nebulaValueDisplay.rawValue, forKey: Keys.nebulaValueDisplay) }
    }
    /// Providers the switcher offers, in canonical order, minus hidden ones.
    /// When `showSummary` is true, the summary button is always the first item.
    var visibleTabs: [ProviderTab] {
        ProviderTab.allCases.filter(isVisible)
    }

    func isVisible(_ tab: ProviderTab) -> Bool {
        switch tab {
        case .ark: showArk
        case .opencode: showOpenCode
        case .deepseek: showDeepSeek
        case .nebula: showNebula
        case .zai: showZai
        case .kimi: showKimi
        }
    }

    /// Whether the given tab should display a money balance instead of a
    /// percentage in the menu bar. Only DeepSeek and Nebula carry currency
    /// balances; all other providers return false.
    func showsBalanceInStatusBar(_ tab: ProviderTab) -> Bool {
        switch tab {
        case .deepseek: deepseekValueDisplay == .balance
        case .nebula: nebulaValueDisplay == .balance
        case .ark, .opencode, .zai, .kimi: false
        }
    }

    /// Hides/shows a provider in the switcher. Hiding the currently selected
    /// tab moves the selection to summary or the first visible one.
    func setVisible(_ tab: ProviderTab, _ visible: Bool) {
        switch tab {
        case .ark: showArk = visible
        case .opencode: showOpenCode = visible
        case .deepseek: showDeepSeek = visible
        case .nebula: showNebula = visible
        case .zai: showZai = visible
        case .kimi: showKimi = visible
        }
        if !visible, case .provider(tab) = selectedMenu {
            if showSummary {
                selectedMenu = .summary
            } else if let first = visibleTabs.first {
                selectedMenu = .provider(first)
            }
        }
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

    /// In-memory mirrors of the DeepSeek Keychain values. Like the OpenCode
    /// cookie they are never written to UserDefaults; empty means "use the
    /// browser session or environment variable instead".
    @Published private(set) var deepseekApiKey: String
    @Published private(set) var deepseekPlatformToken: String

    /// Nebula relay base URL (a harmless UI preference, so it lives in
    /// UserDefaults) and its API key (Keychain mirror, never persisted there).
    @Published var nebulaBaseURL: String {
        didSet { UserDefaults.standard.set(nebulaBaseURL, forKey: Keys.nebulaBaseURL) }
    }
    @Published private(set) var nebulaAPIKey: String

    /// Z.ai (智谱 GLM) Coding Plan region (Global vs BigModel CN) and its API
    /// key (Keychain mirror, never persisted to UserDefaults).
    @Published var zaiRegion: ZaiAPIRegion {
        didSet { UserDefaults.standard.set(zaiRegion.rawValue, forKey: Keys.zaiRegion) }
    }
    @Published private(set) var zaiAPIKey: String

    /// Kimi (Kimi For Coding) API key (Keychain mirror, never persisted to
    /// UserDefaults).
    @Published private(set) var kimiAPIKey: String
    /// Kimi web `kimi-auth` JWT (imported from the browser; Keychain mirror).
    @Published private(set) var kimiAuthToken: String

    var deepseekApiKeyHasValue: Bool { !deepseekApiKey.isEmpty }
    var deepseekPlatformTokenHasValue: Bool { !deepseekPlatformToken.isEmpty }
    var nebulaAPIKeyHasValue: Bool { !nebulaAPIKey.isEmpty }
    var zaiAPIKeyHasValue: Bool { !zaiAPIKey.isEmpty }
    var kimiAPIKeyHasValue: Bool { !kimiAPIKey.isEmpty }

    func setZaiAPIKey(_ value: String?) {
        let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines)
        let key = trimmed?.isEmpty == false ? trimmed : nil
        let persisted = CookieKeychainStore.store(cookie: key, provider: "zai-token")
        zaiAPIKey = persisted ? (key ?? "") : (CookieKeychainStore.load(provider: "zai-token") ?? "")
    }

    func loadZaiFromKeychain() {
        zaiAPIKey = CookieKeychainStore.load(provider: "zai-token") ?? ""
    }

    func setKimiAPIKey(_ value: String?) {
        let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines)
        let key = trimmed?.isEmpty == false ? trimmed : nil
        let persisted = CookieKeychainStore.store(cookie: key, provider: "kimi-key")
        kimiAPIKey = persisted ? (key ?? "") : (CookieKeychainStore.load(provider: "kimi-key") ?? "")
    }

    func loadKimiFromKeychain() {
        kimiAPIKey = CookieKeychainStore.load(provider: "kimi-key") ?? ""
        kimiAuthToken = CookieKeychainStore.load(provider: "kimi-auth") ?? ""
    }

    func loadKimiAuthFromKeychain() {
        kimiAuthToken = CookieKeychainStore.load(provider: "kimi-auth") ?? ""
    }

    func setNebulaAPIKey(_ value: String?) {
        let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines)
        let key = trimmed?.isEmpty == false ? trimmed : nil
        let persisted = CookieKeychainStore.store(cookie: key, provider: "nebula-key")
        nebulaAPIKey = persisted ? (key ?? "") : (CookieKeychainStore.load(provider: "nebula-key") ?? "")
    }

    func loadNebulaFromKeychain() {
        nebulaAPIKey = CookieKeychainStore.load(provider: "nebula-key") ?? ""
    }

    func setDeepSeekAPIKey(_ value: String?) {
        let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines)
        let key = trimmed?.isEmpty == false ? trimmed : nil
        let persisted = CookieKeychainStore.store(cookie: key, provider: "deepseek-apikey")
        deepseekApiKey = persisted ? (key ?? "") : (CookieKeychainStore.load(provider: "deepseek-apikey") ?? "")
    }

    func setDeepSeekPlatformToken(_ value: String?) {
        let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines)
        let token = trimmed?.isEmpty == false ? trimmed : nil
        let persisted = CookieKeychainStore.store(cookie: token, provider: "deepseek-platform")
        deepseekPlatformToken = persisted ? (token ?? "") : (CookieKeychainStore.load(provider: "deepseek-platform") ?? "")
    }

    func loadDeepSeekFromKeychain() {
        deepseekApiKey = CookieKeychainStore.load(provider: "deepseek-apikey") ?? ""
        deepseekPlatformToken = CookieKeychainStore.load(provider: "deepseek-platform") ?? ""
    }

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
        static let showSummary = "tokenbar.showSummary"
        static let showArk = "tokenbar.showArk"
        static let showOpenCode = "tokenbar.showOpenCode"
        static let showDeepSeek = "tokenbar.showDeepSeek"
        static let showNebula = "tokenbar.showNebula"
        static let showZai = "tokenbar.showZai"
        static let showKimi = "tokenbar.showKimi"
        static let deepseekValueDisplay = "tokenbar.deepseekValueDisplay"
        static let nebulaValueDisplay = "tokenbar.nebulaValueDisplay"
        static let zaiRegion = "tokenbar.zaiRegion"
        static let nebulaBaseURL = "tokenbar.nebulaBaseURL"
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
        if let tab = ProviderTab(rawValue: tabRaw) {
            self.selectedMenu = .provider(tab)
        } else {
            self.selectedMenu = .summary
        }
        self.showSummary = defaults.object(forKey: Keys.showSummary) as? Bool ?? true
        self.showArk = defaults.object(forKey: Keys.showArk) as? Bool ?? true
        self.showOpenCode = defaults.object(forKey: Keys.showOpenCode) as? Bool ?? true
        self.showDeepSeek = defaults.object(forKey: Keys.showDeepSeek) as? Bool ?? true
        self.showNebula = defaults.object(forKey: Keys.showNebula) as? Bool ?? true
        self.showZai = defaults.object(forKey: Keys.showZai) as? Bool ?? true
        self.showKimi = defaults.object(forKey: Keys.showKimi) as? Bool ?? true
        let deepseekValueRaw = defaults.string(forKey: Keys.deepseekValueDisplay)
            ?? BalanceDisplay.percent.rawValue
        self.deepseekValueDisplay = BalanceDisplay(rawValue: deepseekValueRaw) ?? .percent
        let nebulaValueRaw = defaults.string(forKey: Keys.nebulaValueDisplay)
            ?? BalanceDisplay.percent.rawValue
        self.nebulaValueDisplay = BalanceDisplay(rawValue: nebulaValueRaw) ?? .percent
        self.opencodeWorkspaceID = defaults.string(forKey: Keys.opencodeWorkspaceID) ?? ""
        let cookieSourceRaw = defaults.string(forKey: Keys.opencodeCookieSource)
            ?? OpenCodeCookieSource.automatic.rawValue
        self.opencodeCookieSource = OpenCodeCookieSource(rawValue: cookieSourceRaw) ?? .automatic
        self.opencodeCookie = CookieKeychainStore.load(provider: "opencode") ?? ""
        self.deepseekApiKey = CookieKeychainStore.load(provider: "deepseek-apikey") ?? ""
        self.deepseekPlatformToken = CookieKeychainStore.load(provider: "deepseek-platform") ?? ""
        self.nebulaBaseURL = defaults.string(forKey: Keys.nebulaBaseURL)
            ?? NebulaProvider.defaultBaseURL
        self.nebulaAPIKey = CookieKeychainStore.load(provider: "nebula-key") ?? ""
        let zaiRegionRaw = defaults.string(forKey: Keys.zaiRegion) ?? ZaiAPIRegion.bigmodelCN.rawValue
        self.zaiRegion = ZaiAPIRegion(rawValue: zaiRegionRaw) ?? .bigmodelCN
        self.zaiAPIKey = CookieKeychainStore.load(provider: "zai-token") ?? ""
        self.kimiAPIKey = CookieKeychainStore.load(provider: "kimi-key") ?? ""
        self.kimiAuthToken = CookieKeychainStore.load(provider: "kimi-auth") ?? ""
    }
}
