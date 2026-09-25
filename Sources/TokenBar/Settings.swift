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

    /// LongCat can reuse a signed-in browser session or a manually pasted
    /// Cookie header. Automatic is the default.
    enum LongCatCookieSource: String, CaseIterable {
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

    /// Menu-bar display layout. The gauge is the concentric ring meter shared
    /// with the plan cards; the provider logo is the brand glyph.
    enum DisplayMode: String, CaseIterable {
        /// Just the ring gauge (monthly outer, weekly middle, session inner).
        case iconOnly
        /// Ring gauge followed by the remaining percent, e.g. rings + `73%`.
        case iconAndPercent
        /// Just the remaining percent text, e.g. `73%`.
        case percentOnly
        /// Just the provider logo.
        case logoOnly
        /// Provider logo followed by the remaining percent, e.g. `🐋 73%`.
        case logoAndPercent
        /// Provider logo followed by the ring gauge.
        case logoAndRings

        var displayName: String {
            switch self {
            case .iconOnly: L(.displayIconOnly)
            case .iconAndPercent: L(.displayIconAndPercent)
            case .percentOnly: L(.displayPercentOnly)
            case .logoOnly: L(.displayLogoOnly)
            case .logoAndPercent: L(.displayLogoAndPercent)
            case .logoAndRings: L(.displayLogoAndRings)
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
    @Published var showGrokPool: Bool {
        didSet { UserDefaults.standard.set(showGrokPool, forKey: Keys.showGrokPool) }
    }
    @Published var showLongCat: Bool {
        didSet { UserDefaults.standard.set(showLongCat, forKey: Keys.showLongCat) }
    }
    @Published var showAliyun: Bool {
        didSet { UserDefaults.standard.set(showAliyun, forKey: Keys.showAliyun) }
    }
    @Published var showStepFun: Bool {
        didSet { UserDefaults.standard.set(showStepFun, forKey: Keys.showStepFun) }
    }
    @Published var showSenseNova: Bool {
        didSet { UserDefaults.standard.set(showSenseNova, forKey: Keys.showSenseNova) }
    }
    /// Master switch for the expiry-reminder feature (menu section + notifications).
    @Published var expiryReminderEnabled: Bool {
        didSet { UserDefaults.standard.set(expiryReminderEnabled, forKey: Keys.expiryReminderEnabled) }
    }
    /// Lead time in days: subscriptions expiring within this window are
    /// surfaced. One of 3 / 7 / 14 / 30.
    @Published var expiryReminderDays: Int {
        didSet { UserDefaults.standard.set(expiryReminderDays, forKey: Keys.expiryReminderDays) }
    }
    /// Whether urgent expirations also post a macOS notification (once per
    /// subscription per day). The menu section shows regardless.
    @Published var expiryReminderNotify: Bool {
        didSet { UserDefaults.standard.set(expiryReminderNotify, forKey: Keys.expiryReminderNotify) }
    }
    /// Manually tracked subscriptions for providers TokenBar does not
    /// integrate. Non-sensitive; persisted as JSON in UserDefaults.
    @Published var manualSubscriptions: [ManualSubscription] {
        didSet { persistManualSubscriptions() }
    }
    /// Whether the menu bar shows the remaining percent or the money balance
    /// for balance-based providers (DeepSeek, Nebula).
    @Published var deepseekValueDisplay: BalanceDisplay {
        didSet { UserDefaults.standard.set(deepseekValueDisplay.rawValue, forKey: Keys.deepseekValueDisplay) }
    }
    @Published var nebulaValueDisplay: BalanceDisplay {
        didSet { UserDefaults.standard.set(nebulaValueDisplay.rawValue, forKey: Keys.nebulaValueDisplay) }
    }
    @Published var grokPoolValueDisplay: BalanceDisplay {
        didSet { UserDefaults.standard.set(grokPoolValueDisplay.rawValue, forKey: Keys.grokPoolValueDisplay) }
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
        case .grokPool: showGrokPool
        case .longcat: showLongCat
        case .aliyun: showAliyun
        case .stepfun: showStepFun
        case .sensenova: showSenseNova
        }
    }

    /// Whether the given tab should display a money balance instead of a
    /// percentage in the menu bar. Only DeepSeek and Nebula carry currency
    /// balances; all other providers return false.
    func showsBalanceInStatusBar(_ tab: ProviderTab) -> Bool {
        switch tab {
        case .deepseek: deepseekValueDisplay == .balance
        case .nebula: nebulaValueDisplay == .balance
        case .grokPool: grokPoolValueDisplay == .balance
        case .ark, .opencode, .zai, .kimi, .longcat, .aliyun, .stepfun, .sensenova: false
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
        case .grokPool: showGrokPool = visible
        case .longcat: showLongCat = visible
        case .aliyun: showAliyun = visible
        case .stepfun: showStepFun = visible
        case .sensenova: showSenseNova = visible
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

    /// Ark IAM long-lived Access Key pair (Keychain mirrors, never persisted
    /// to UserDefaults). Unlike the arkcli SSO session these credentials do not
    /// expire, so the signed OpenAPI keeps working without periodic re-login.
    @Published private(set) var arkAccessKeyID: String
    @Published private(set) var arkSecretAccessKey: String

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

    /// GrokPool (grok2api admin gateway) base URL (a harmless UI preference,
    /// so it lives in UserDefaults) plus the administrator username and
    /// password used to obtain the dashboard access token (Keychain mirrors,
    /// never persisted there). Isolated from the Nebula relay's settings.
    @Published var grokPoolBaseURL: String {
        didSet { UserDefaults.standard.set(grokPoolBaseURL, forKey: Keys.grokPoolBaseURL) }
    }
    @Published private(set) var grokPoolUsername: String
    @Published private(set) var grokPoolPassword: String

    /// Kimi (Kimi For Coding) API key (Keychain mirror, never persisted to
    /// UserDefaults).
    @Published private(set) var kimiAPIKey: String
    /// Kimi web `kimi-auth` JWT (imported from the browser; Keychain mirror).
    @Published private(set) var kimiAuthToken: String

    /// LongCat (longcat.chat) cookie source: automatic (browser import) or
    /// manual (pasted Cookie header).
    @Published var longcatCookieSource: LongCatCookieSource {
        didSet { UserDefaults.standard.set(longcatCookieSource.rawValue, forKey: Keys.longcatCookieSource) }
    }
    /// In-memory mirror of the LongCat manual Cookie header (Keychain mirror,
    /// never persisted to UserDefaults).
    @Published private(set) var longcatCookie: String

    /// Alibaba Cloud (百炼) Coding Plan IAM key pair (Keychain mirrors,
    /// never persisted to UserDefaults). The console usage gateway has no
    /// public API; the AK/SK pair mints the short-lived console access token
    /// the official `bl` CLI uses. Optional — browser login is the primary
    /// path.
    @Published private(set) var aliyunAccessKeyID: String
    @Published private(set) var aliyunSecretAccessKey: String

    /// Console access token from the browser login (Keychain mirror). This is
    /// the primary Alibaba Cloud credential; it expires eventually and is
    /// re-obtained by signing in again.
    @Published private(set) var aliyunConsoleToken: String

    /// Alibaba Cloud Coding Plan dedicated API key, `sk-sp-…` (Keychain
    /// mirror). Scoped to the model gateway; used only as a last-resort
    /// Bearer attempt on the console usage API.
    @Published private(set) var aliyunAPIKey: String

    /// Which Alibaba Cloud plan this account holds (Token Plan vs Coding
    /// Plan), discovered on the first successful fetch. A plain preference —
    /// no credentials — that keeps later refreshes to one usage read.
    @Published var aliyunDetectedPlan: AliyunPlanKind? {
        didSet {
            UserDefaults.standard.set(
                aliyunDetectedPlan?.rawValue, forKey: Keys.aliyunDetectedPlan)
        }
    }

    /// StepFun console session Cookie header (Keychain mirror, never
    /// persisted to UserDefaults). Managed through the browser import.
    @Published private(set) var stepFunCookie: String

    /// SenseNova console session Cookie header (Keychain mirror).
    @Published private(set) var senseNovaCookie: String

    /// StepFun API key (Keychain mirror; the gateway authenticates with
    /// `Authorization: Bearer`). Console plan credit still needs the browser
    /// session; the key path reads whatever the gateway exposes.
    @Published private(set) var stepFunAPIKey: String

    /// SenseNova API key (Keychain mirror; Bearer auth on the token gateway).
    @Published private(set) var senseNovaAPIKey: String

    /// Manual console Cookie headers (Keychain mirrors). Pasting the Cookie
    /// header from the browser's devtools once avoids the Full Disk Access /
    /// Keychain approvals the automatic browser import needs.
    @Published private(set) var stepFunManualCookie: String
    @Published private(set) var senseNovaManualCookie: String

    var deepseekApiKeyHasValue: Bool { !deepseekApiKey.isEmpty }
    var deepseekPlatformTokenHasValue: Bool { !deepseekPlatformToken.isEmpty }
    var arkCredentialsHaveValue: Bool { !arkAccessKeyID.isEmpty && !arkSecretAccessKey.isEmpty }
    var nebulaAPIKeyHasValue: Bool { !nebulaAPIKey.isEmpty }
    var zaiAPIKeyHasValue: Bool { !zaiAPIKey.isEmpty }
    var kimiAPIKeyHasValue: Bool { !kimiAPIKey.isEmpty }
    var grokPoolCredentialsHaveValue: Bool { !grokPoolUsername.isEmpty && !grokPoolPassword.isEmpty }
    var longcatCookieHasValue: Bool { !longcatCookie.isEmpty }
    var aliyunCredentialsHaveValue: Bool { !aliyunAccessKeyID.isEmpty && !aliyunSecretAccessKey.isEmpty }
    var aliyunConsoleLoggedIn: Bool { !aliyunConsoleToken.isEmpty }
    var stepFunCookieHasValue: Bool { !stepFunCookie.isEmpty }
    var stepFunAPIKeyHasValue: Bool { !stepFunAPIKey.isEmpty }
    var senseNovaAPIKeyHasValue: Bool { !senseNovaAPIKey.isEmpty }

    func setStepFunAPIKey(_ value: String?) {
        let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines)
        let key = trimmed?.isEmpty == false ? trimmed : nil
        let persisted = CookieKeychainStore.store(cookie: key, provider: "stepfun-apikey")
        stepFunAPIKey = persisted ? (key ?? "") : (CookieKeychainStore.load(provider: "stepfun-apikey") ?? "")
    }

    func setStepFunManualCookie(_ value: String?) {
        let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines)
        let cookie = trimmed?.isEmpty == false ? trimmed : nil
        let persisted = CookieKeychainStore.store(cookie: cookie, provider: "stepfun-manual-cookie")
        stepFunManualCookie = persisted
            ? (cookie ?? "")
            : (CookieKeychainStore.load(provider: "stepfun-manual-cookie") ?? "")
    }

    func setSenseNovaManualCookie(_ value: String?) {
        let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines)
        let cookie = trimmed?.isEmpty == false ? trimmed : nil
        let persisted = CookieKeychainStore.store(cookie: cookie, provider: "sensenova-manual-cookie")
        senseNovaManualCookie = persisted
            ? (cookie ?? "")
            : (CookieKeychainStore.load(provider: "sensenova-manual-cookie") ?? "")
    }

    func setSenseNovaAPIKey(_ value: String?) {
        let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines)
        let key = trimmed?.isEmpty == false ? trimmed : nil
        let persisted = CookieKeychainStore.store(cookie: key, provider: "sensenova-apikey")
        senseNovaAPIKey = persisted ? (key ?? "") : (CookieKeychainStore.load(provider: "sensenova-apikey") ?? "")
    }

    func loadStepFunFromKeychain() {
        stepFunCookie = CookieKeychainStore.load(provider: "stepfun-browser") ?? ""
    }

    func setSenseNovaCookie(_ value: String?) {
        let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines)
        let cookie = trimmed?.isEmpty == false ? trimmed : nil
        let persisted = CookieKeychainStore.store(cookie: cookie, provider: "sensenova-browser")
        senseNovaCookie = persisted ? (cookie ?? "") : (CookieKeychainStore.load(provider: "sensenova-browser") ?? "")
    }

    func loadSenseNovaFromKeychain() {
        senseNovaCookie = CookieKeychainStore.load(provider: "sensenova-browser") ?? ""
    }

    func setStepFunCookie(_ value: String?) {
        let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines)
        let cookie = trimmed?.isEmpty == false ? trimmed : nil
        let persisted = CookieKeychainStore.store(cookie: cookie, provider: "stepfun-browser")
        stepFunCookie = persisted ? (cookie ?? "") : (CookieKeychainStore.load(provider: "stepfun-browser") ?? "")
    }

    // MARK: - Manual subscriptions

    func addManualSubscription() {
        // Default to the lead time ahead so a freshly added row immediately
        // shows up in the reminder list and the user can see the effect.
        let expiry = Calendar.current.date(
            byAdding: .day, value: expiryReminderDays, to: Date()) ?? Date()
        manualSubscriptions.append(ManualSubscription(name: "", expiryDate: expiry, note: ""))
    }

    func updateManualSubscription(id: String, name: String? = nil,
                                  expiryDate: Date? = nil, note: String? = nil) {
        guard let index = manualSubscriptions.firstIndex(where: { $0.id == id }) else { return }
        if let name { manualSubscriptions[index].name = name }
        if let expiryDate { manualSubscriptions[index].expiryDate = expiryDate }
        if let note { manualSubscriptions[index].note = note }
    }

    func removeManualSubscription(id: String) {
        manualSubscriptions.removeAll { $0.id == id }
        ReminderScheduler.clearNotifiedState(forManualID: id)
    }

    private func persistManualSubscriptions() {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        guard let data = try? encoder.encode(manualSubscriptions) else { return }
        UserDefaults.standard.set(data, forKey: Keys.manualSubscriptions)
    }

    private static func loadManualSubscriptions() -> [ManualSubscription] {
        guard let data = UserDefaults.standard.data(forKey: Keys.manualSubscriptions) else { return [] }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return (try? decoder.decode([ManualSubscription].self, from: data)) ?? []
    }

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

    func setGrokPoolUsername(_ value: String?) {
        let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines)
        let username = trimmed?.isEmpty == false ? trimmed : nil
        let persisted = CookieKeychainStore.store(cookie: username, provider: "grokpool-user")
        grokPoolUsername = persisted ? (username ?? "") : (CookieKeychainStore.load(provider: "grokpool-user") ?? "")
    }

    func setGrokPoolPassword(_ value: String?) {
        let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines)
        let password = trimmed?.isEmpty == false ? trimmed : nil
        let persisted = CookieKeychainStore.store(cookie: password, provider: "grokpool-pass")
        grokPoolPassword = persisted ? (password ?? "") : (CookieKeychainStore.load(provider: "grokpool-pass") ?? "")
    }

    func loadGrokPoolFromKeychain() {
        grokPoolUsername = CookieKeychainStore.load(provider: "grokpool-user") ?? ""
        grokPoolPassword = CookieKeychainStore.load(provider: "grokpool-pass") ?? ""
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

    func setArkAccessKeyID(_ value: String?) {
        let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines)
        let key = trimmed?.isEmpty == false ? trimmed : nil
        let persisted = CookieKeychainStore.store(cookie: key, provider: "ark-accesskey")
        arkAccessKeyID = persisted ? (key ?? "") : (CookieKeychainStore.load(provider: "ark-accesskey") ?? "")
    }

    func setArkSecretAccessKey(_ value: String?) {
        let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines)
        let key = trimmed?.isEmpty == false ? trimmed : nil
        let persisted = CookieKeychainStore.store(cookie: key, provider: "ark-secretkey")
        arkSecretAccessKey = persisted ? (key ?? "") : (CookieKeychainStore.load(provider: "ark-secretkey") ?? "")
    }

    func loadArkFromKeychain() {
        arkAccessKeyID = CookieKeychainStore.load(provider: "ark-accesskey") ?? ""
        arkSecretAccessKey = CookieKeychainStore.load(provider: "ark-secretkey") ?? ""
    }

    /// The stored Ark IAM key pair, when both halves are present. Read on the
    /// main actor by `UsageStore.rebuildProviders` to build the signed-OpenAPI
    /// provider; environment variables remain the fallback.
    var storedVolcCredentials: VolcCredentials? {
        guard !arkAccessKeyID.isEmpty, !arkSecretAccessKey.isEmpty else { return nil }
        return VolcCredentials(accessKeyID: arkAccessKeyID, secretAccessKey: arkSecretAccessKey)
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

    func setLongCatCookie(_ value: String?) {
        let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines)
        let cookie = trimmed?.isEmpty == false ? trimmed : nil
        let persisted = CookieKeychainStore.store(cookie: cookie, provider: "longcat-cookie")
        longcatCookie = persisted ? (cookie ?? "") : (CookieKeychainStore.load(provider: "longcat-cookie") ?? "")
    }

    func loadLongCatCookieFromKeychain() {
        longcatCookie = CookieKeychainStore.load(provider: "longcat-cookie") ?? ""
    }

    func setAliyunAccessKeyID(_ value: String?) {
        let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines)
        let key = trimmed?.isEmpty == false ? trimmed : nil
        let persisted = CookieKeychainStore.store(cookie: key, provider: "aliyun-accesskey")
        aliyunAccessKeyID = persisted ? (key ?? "") : (CookieKeychainStore.load(provider: "aliyun-accesskey") ?? "")
    }

    func setAliyunSecretAccessKey(_ value: String?) {
        let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines)
        let key = trimmed?.isEmpty == false ? trimmed : nil
        let persisted = CookieKeychainStore.store(cookie: key, provider: "aliyun-secretkey")
        aliyunSecretAccessKey = persisted ? (key ?? "") : (CookieKeychainStore.load(provider: "aliyun-secretkey") ?? "")
    }

    func loadAliyunFromKeychain() {
        aliyunAccessKeyID = CookieKeychainStore.load(provider: "aliyun-accesskey") ?? ""
        aliyunSecretAccessKey = CookieKeychainStore.load(provider: "aliyun-secretkey") ?? ""
        aliyunConsoleToken = CookieKeychainStore.load(provider: "aliyun-console") ?? ""
        aliyunAPIKey = CookieKeychainStore.load(provider: "aliyun-key") ?? ""
    }

    func setAliyunConsoleToken(_ value: String?) {
        let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines)
        let token = trimmed?.isEmpty == false ? trimmed : nil
        let persisted = CookieKeychainStore.store(cookie: token, provider: "aliyun-console")
        aliyunConsoleToken = persisted ? (token ?? "") : (CookieKeychainStore.load(provider: "aliyun-console") ?? "")
    }

    func setAliyunAPIKey(_ value: String?) {
        let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines)
        let key = trimmed?.isEmpty == false ? trimmed : nil
        let persisted = CookieKeychainStore.store(cookie: key, provider: "aliyun-key")
        aliyunAPIKey = persisted ? (key ?? "") : (CookieKeychainStore.load(provider: "aliyun-key") ?? "")
    }

    /// The stored Aliyun IAM pair, when both halves are present. Read on the
    /// main actor by the provider; environment variables remain the fallback.
    var storedAliyunCredentials: AliyunCredentials? {
        guard !aliyunAccessKeyID.isEmpty, !aliyunSecretAccessKey.isEmpty else { return nil }
        return AliyunCredentials(
            accessKeyID: aliyunAccessKeyID, secretAccessKey: aliyunSecretAccessKey)
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
        static let showGrokPool = "tokenbar.showGrokPool"
        static let showLongCat = "tokenbar.showLongCat"
        static let showAliyun = "tokenbar.showAliyun"
        static let aliyunDetectedPlan = "tokenbar.aliyunDetectedPlan"
        static let showStepFun = "tokenbar.showStepFun"
        static let showSenseNova = "tokenbar.showSenseNova"
        static let expiryReminderEnabled = "tokenbar.expiryReminderEnabled"
        static let expiryReminderDays = "tokenbar.expiryReminderDays"
        static let expiryReminderNotify = "tokenbar.expiryReminderNotify"
        static let manualSubscriptions = "tokenbar.manualSubscriptions"
        static let longcatCookieSource = "tokenbar.longcatCookieSource"
        static let deepseekValueDisplay = "tokenbar.deepseekValueDisplay"
        static let nebulaValueDisplay = "tokenbar.nebulaValueDisplay"
        static let grokPoolValueDisplay = "tokenbar.grokPoolValueDisplay"
        static let zaiRegion = "tokenbar.zaiRegion"
        static let nebulaBaseURL = "tokenbar.nebulaBaseURL"
        static let grokPoolBaseURL = "tokenbar.grokPoolBaseURL"
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
        if displayRaw == "logoAndBar" {
            // Renamed when the capsule meter became the ring gauge.
            self.displayMode = .logoAndRings
        } else {
            self.displayMode = DisplayMode(rawValue: displayRaw) ?? .iconAndPercent
        }
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
        self.showGrokPool = defaults.object(forKey: Keys.showGrokPool) as? Bool ?? true
        self.showLongCat = defaults.object(forKey: Keys.showLongCat) as? Bool ?? true
        self.showAliyun = defaults.object(forKey: Keys.showAliyun) as? Bool ?? true
        let aliyunPlanRaw = defaults.string(forKey: Keys.aliyunDetectedPlan)
        self.aliyunDetectedPlan = aliyunPlanRaw.flatMap(AliyunPlanKind.init(rawValue:))
        self.showStepFun = defaults.object(forKey: Keys.showStepFun) as? Bool ?? true
        self.showSenseNova = defaults.object(forKey: Keys.showSenseNova) as? Bool ?? true
        self.stepFunCookie = CookieKeychainStore.load(provider: "stepfun-browser") ?? ""
        self.senseNovaCookie = CookieKeychainStore.load(provider: "sensenova-browser") ?? ""
        self.stepFunAPIKey = CookieKeychainStore.load(provider: "stepfun-apikey") ?? ""
        self.senseNovaAPIKey = CookieKeychainStore.load(provider: "sensenova-apikey") ?? ""
        self.stepFunManualCookie = CookieKeychainStore.load(provider: "stepfun-manual-cookie") ?? ""
        self.senseNovaManualCookie = CookieKeychainStore.load(provider: "sensenova-manual-cookie") ?? ""
        self.expiryReminderEnabled = defaults.object(forKey: Keys.expiryReminderEnabled) as? Bool ?? true
        let reminderDays = defaults.object(forKey: Keys.expiryReminderDays) as? Int ?? 7
        self.expiryReminderDays = [3, 7, 14, 30].contains(reminderDays) ? reminderDays : 7
        self.expiryReminderNotify = defaults.object(forKey: Keys.expiryReminderNotify) as? Bool ?? true
        self.manualSubscriptions = Self.loadManualSubscriptions()
        let longcatCookieSourceRaw = defaults.string(forKey: Keys.longcatCookieSource)
            ?? LongCatCookieSource.automatic.rawValue
        self.longcatCookieSource = LongCatCookieSource(rawValue: longcatCookieSourceRaw) ?? .automatic
        self.longcatCookie = CookieKeychainStore.load(provider: "longcat-cookie") ?? ""
        let deepseekValueRaw = defaults.string(forKey: Keys.deepseekValueDisplay)
            ?? BalanceDisplay.percent.rawValue
        self.deepseekValueDisplay = BalanceDisplay(rawValue: deepseekValueRaw) ?? .percent
        let nebulaValueRaw = defaults.string(forKey: Keys.nebulaValueDisplay)
            ?? BalanceDisplay.percent.rawValue
        self.nebulaValueDisplay = BalanceDisplay(rawValue: nebulaValueRaw) ?? .percent
        let grokPoolValueRaw = defaults.string(forKey: Keys.grokPoolValueDisplay)
            ?? BalanceDisplay.percent.rawValue
        self.grokPoolValueDisplay = BalanceDisplay(rawValue: grokPoolValueRaw) ?? .percent
        self.opencodeWorkspaceID = defaults.string(forKey: Keys.opencodeWorkspaceID) ?? ""
        let cookieSourceRaw = defaults.string(forKey: Keys.opencodeCookieSource)
            ?? OpenCodeCookieSource.automatic.rawValue
        self.opencodeCookieSource = OpenCodeCookieSource(rawValue: cookieSourceRaw) ?? .automatic
        self.opencodeCookie = CookieKeychainStore.load(provider: "opencode") ?? ""
        self.deepseekApiKey = CookieKeychainStore.load(provider: "deepseek-apikey") ?? ""
        self.deepseekPlatformToken = CookieKeychainStore.load(provider: "deepseek-platform") ?? ""
        self.arkAccessKeyID = CookieKeychainStore.load(provider: "ark-accesskey") ?? ""
        self.arkSecretAccessKey = CookieKeychainStore.load(provider: "ark-secretkey") ?? ""
        self.nebulaBaseURL = defaults.string(forKey: Keys.nebulaBaseURL)
            ?? NebulaProvider.defaultBaseURL
        self.nebulaAPIKey = CookieKeychainStore.load(provider: "nebula-key") ?? ""
        self.grokPoolBaseURL = defaults.string(forKey: Keys.grokPoolBaseURL)
            ?? GrokPoolProvider.defaultBaseURL
        self.grokPoolUsername = CookieKeychainStore.load(provider: "grokpool-user") ?? ""
        self.grokPoolPassword = CookieKeychainStore.load(provider: "grokpool-pass") ?? ""
        let zaiRegionRaw = defaults.string(forKey: Keys.zaiRegion) ?? ZaiAPIRegion.bigmodelCN.rawValue
        self.zaiRegion = ZaiAPIRegion(rawValue: zaiRegionRaw) ?? .bigmodelCN
        self.zaiAPIKey = CookieKeychainStore.load(provider: "zai-token") ?? ""
        self.kimiAPIKey = CookieKeychainStore.load(provider: "kimi-key") ?? ""
        self.kimiAuthToken = CookieKeychainStore.load(provider: "kimi-auth") ?? ""
        self.aliyunAccessKeyID = CookieKeychainStore.load(provider: "aliyun-accesskey") ?? ""
        self.aliyunSecretAccessKey = CookieKeychainStore.load(provider: "aliyun-secretkey") ?? ""
        self.aliyunConsoleToken = CookieKeychainStore.load(provider: "aliyun-console") ?? ""
        self.aliyunAPIKey = CookieKeychainStore.load(provider: "aliyun-key") ?? ""
    }
}
