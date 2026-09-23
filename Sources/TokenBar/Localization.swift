import Foundation
import Combine

/// In-app language selection. `.system` follows the OS preferred languages.
enum Language: String, CaseIterable {
    case system
    case zh
    case en

    var displayName: String {
        switch (L10n.shared.language.resolved, self) {
        case (.en, .system): "System Default"
        case (.en, .zh): "Simplified Chinese"
        case (.en, .en): "English"
        case (_, .system): "跟随系统"
        case (_, .zh): "简体中文"
        case (_, .en): "English"
        }
    }

    /// Resolve `.system` to a concrete language using the OS preferred list.
    var resolved: Language {
        switch self {
        case .zh, .en: return self
        case .system:
            let preferred = Locale.preferredLanguages.first ?? "en"
            if preferred.hasPrefix("zh") { return .zh }
            return .en
        }
    }
}

/// Localized string keys. Grouped roughly by surface (menu / settings / status).
enum LKey: String, CaseIterable {
    // Menu - actions
    case refreshNow = "menu.refreshNow"
    case openArkcliLogin = "menu.openArkcliLogin"
    case openArkConsole = "menu.openArkConsole"
    case openCodeGo = "menu.openCodeGo"
    case settings = "menu.settings"
    case quitTokenBar = "menu.quitTokenBar"
    case updated = "menu.updated"
    case updatedJustNow = "menu.updatedJustNow"
    case updatedSecondsAgo = "menu.updatedSecondsAgo"
    case updatedMinutesAgo = "menu.updatedMinutesAgo"
    case updatedHoursAgo = "menu.updatedHoursAgo"
    case refreshDetails = "menu.refreshDetails"

    // Menu - cards
    case loadingUsage = "menu.loadingUsage"
    case refreshing = "menu.refreshing"
    case fetchFailed = "menu.fetchFailed"
    case noDataYet = "menu.noDataYet"
    case left = "menu.left"
    case used = "menu.used"
    case remainingPercent = "menu.remainingPercent"
    case resets = "menu.resets"
    case noResetTime = "menu.noResetTime"
    case now = "menu.now"
    case auth = "menu.auth"
    case seat = "menu.seat"
    case dayShort = "menu.dayShort"
    case hourShort = "menu.hourShort"
    case minShort = "menu.minShort"
    case staleData = "menu.staleData"

    // Ring legend labels
    case monthly = "ring.monthly"
    case weekly = "ring.weekly"
    case session = "ring.session"

    // Plan expiry
    case expiresIn = "plan.expiresIn"
    case expired = "plan.expired"
    case expiresOn = "plan.expiresOn"

    // Settings window
    case settingsTitle = "settings.title"
    case sectionMenuBar = "settings.sectionMenuBar"
    case sectionRefresh = "settings.sectionRefresh"
    case sectionDataSource = "settings.sectionDataSource"
    case sectionOpenCode = "settings.sectionOpenCode"
    case sectionDiagnostics = "settings.sectionDiagnostics"
    case sectionAdvanced = "settings.sectionAdvanced"
    case displayMode = "settings.displayMode"
    case interval = "settings.interval"
    case refreshWhenMenuOpens = "settings.refreshWhenMenuOpens"
    case lastFetch = "settings.lastFetch"
    case source = "settings.source"
    case sourceAuto = "settings.sourceAuto"
    case sourceCli = "settings.sourceCli"
    case sourceApi = "settings.sourceApi"
    case connectedVia = "settings.connectedVia"
    case authLabel = "settings.authLabel"
    case planCount = "settings.planCount"
    case tightest = "settings.tightest"
    case fetchFailedShort = "settings.fetchFailedShort"
    case refreshingStatus = "settings.refreshingStatus"
    case arkcliPath = "settings.arkcliPath"
    case arkcliVersion = "settings.arkcliVersion"
    case shell = "settings.shell"
    case notFound = "settings.notFound"
    case language = "settings.language"
    case noProvider = "settings.noProvider"
    case tabArk = "tab.ark"
    case tabOpenCode = "tab.opencode"
    case tabDeepSeek = "tab.deepseek"
    case tabNebula = "tab.nebula"
    case tabZai = "tab.zai"
    case tabKimi = "tab.kimi"
    case tabGrokPool = "tab.grokPool"
    case tabLongCat = "tab.longcat"
    case tabAliyun = "tab.aliyun"
    case tabStepFun = "tab.stepfun"
    case tabSenseNova = "tab.sensenova"
    case tabSummary = "tab.summary"
    case showProvider = "settings.showProvider"
    case showSummary = "settings.showSummary"
    case sectionDisplay = "settings.sectionDisplay"
    case opencodeCookie = "settings.opencodeCookie"
    case opencodeCookiePlaceholder = "settings.opencodeCookiePlaceholder"
    case opencodeWorkspaceID = "settings.opencodeWorkspaceID"
    case opencodeWorkspaceIDPlaceholder = "settings.opencodeWorkspaceIDPlaceholder"
    case opencodeTestRefresh = "settings.opencodeTestRefresh"
    case opencodeCookieNotSet = "settings.opencodeCookieNotSet"
    case opencodeCookieSet = "settings.opencodeCookieSet"
    case settingsGeneral = "settings.general"
    case settingsArk = "settings.ark"
    case settingsOpenCode = "settings.openCode"
    case settingsDeepSeek = "settings.deepseek"
    case settingsNebula = "settings.nebula"
    case settingsZai = "settings.zai"
    case settingsKimi = "settings.kimi"
    case settingsGrokPool = "settings.grokPool"
    case settingsLongCat = "settings.longcat"
    case settingsAliyun = "settings.aliyun"
    case settingsStepFun = "settings.stepFun"
    case settingsSenseNova = "settings.senseNova"
    case settingsReminder = "settings.reminder"
    case settingsGeneralSubtitle = "settings.generalSubtitle"
    case settingsArkSubtitle = "settings.arkSubtitle"
    case settingsOpenCodeSubtitle = "settings.openCodeSubtitle"
    case settingsDeepSeekSubtitle = "settings.deepseekSubtitle"
    case settingsNebulaSubtitle = "settings.nebulaSubtitle"
    case settingsZaiSubtitle = "settings.zaiSubtitle"
    case settingsKimiSubtitle = "settings.kimiSubtitle"
    case settingsGrokPoolSubtitle = "settings.grokPoolSubtitle"
    case settingsLongCatSubtitle = "settings.longcatSubtitle"
    case settingsAliyunSubtitle = "settings.aliyunSubtitle"
    case settingsReminderSubtitle = "settings.reminderSubtitle"
    case settingsDiagnosticsSubtitle = "settings.diagnosticsSubtitle"
    case settingsDiagnostics = "settings.diagnostics"
    case sectionAppearance = "settings.sectionAppearance"
    case sectionBehavior = "settings.sectionBehavior"
    case sectionConnection = "settings.sectionConnection"
    case sectionActions = "settings.sectionActions"
    case sectionSubscription = "settings.sectionSubscription"
    case status = "settings.status"
    case refreshArk = "settings.refreshArk"
    case refreshOpenCode = "settings.refreshOpenCode"
    case refreshDeepSeek = "settings.refreshDeepSeek"
    case refreshNebula = "settings.refreshNebula"
    case refreshZai = "settings.refreshZai"
    case refreshKimi = "settings.refreshKimi"
    case refreshGrokPool = "settings.refreshGrokPool"
    case refreshLongCat = "settings.refreshLongCat"
    case refreshAliyun = "settings.refreshAliyun"
    case refreshStepFun = "settings.refreshStepFun"
    case refreshSenseNova = "settings.refreshSenseNova"
    case openDeepSeekPlatform = "menu.openDeepSeekPlatform"
    case openNebulaConsole = "menu.openNebulaConsole"
    case openZaiConsole = "menu.openZaiConsole"
    case openKimiConsole = "menu.openKimiConsole"
    case openGrokPoolConsole = "menu.openGrokPoolConsole"
    case openLongCatConsole = "menu.openLongCatConsole"
    case openAliyunConsole = "menu.openAliyunConsole"
    case openStepFunConsole = "menu.openStepFunConsole"
    case openSenseNovaConsole = "menu.openSenseNovaConsole"
    case openCodeCookieSource = "settings.openCodeCookieSource"
    case openCodeCookieAutomatic = "settings.openCodeCookieAutomatic"
    case openCodeCookieManual = "settings.openCodeCookieManual"
    case openCodeAutomaticHint = "settings.openCodeAutomaticHint"
    case openCodeManualHint = "settings.openCodeManualHint"
    case openCodeAuthoritativeHint = "settings.openCodeAuthoritativeHint"
    case reimportBrowserSession = "settings.reimportBrowserSession"
    case reimportStepFunBrowserSession = "settings.reimportStepFunBrowserSession"
    case reimportSenseNovaBrowserSession = "settings.reimportSenseNovaBrowserSession"
    case saveCookie = "settings.saveCookie"
    case lastSuccessfulUpdate = "settings.lastSuccessfulUpdate"
    case noSuccessfulUpdate = "settings.noSuccessfulUpdate"
    case browserSession = "settings.browserSession"
    case manualCookie = "settings.manualCookie"
    case openCodeBrowserAccessTitle = "settings.openCodeBrowserAccessTitle"
    case openCodeBrowserAccessMessage = "settings.openCodeBrowserAccessMessage"
    case continueAction = "settings.continueAction"
    case settingsAppVersion = "settings.appVersion"
    case settingsCurrentSource = "settings.currentSource"
    case settingsPreviousData = "settings.previousData"
    case settingsNoUsage = "settings.noUsage"

    // Dynamic usage labels and errors
    case productCodingPlan = "product.codingPlan"
    case productAgentPlan = "product.agentPlan"
    case productCodingPlanTeam = "product.codingPlanTeam"
    case productAgentPlanTeam = "product.agentPlanTeam"
    case productOpenCodeGo = "product.openCodeGo"
    case productDeepSeek = "product.deepseek"
    case productNebula = "product.nebula"
    case productGrokPool = "product.grokPool"
    case productLongCat = "product.longcat"
    case productAliyunCodingPlan = "product.aliyunCodingPlan"
    case productStepFunCodingPlan = "product.stepfunCodingPlan"
    case productSenseNovaCodingPlan = "product.sensenovaCodingPlan"
    case windowSession = "window.session"
    case window5Hour = "window.5hour"
    case windowWeekly = "window.weekly"
    case windowMonthly = "window.monthly"
    case windowRequests = "window.requests"
    case windowBalance = "window.balance"
    case deepseekToday = "deepseek.today"
    case deepseekMonthly = "deepseek.monthly"
    case deepseekPaidGranted = "deepseek.paidGranted"
    case deepseekUsageDetail = "deepseek.usageDetail"
    case deepseekUsageUnavailable = "deepseek.usageUnavailable"
    case deepseekTopModel = "deepseek.topModel"
    case deepseekCategoryDetail = "deepseek.categoryDetail"
    case deepseekCredentialsHint = "deepseek.credentialsHint"
    case deepseekPlatformHint = "deepseek.platformHint"
    case deepseekAPIKeyLabel = "deepseek.apiKeyLabel"
    case deepseekPlatformTokenLabel = "deepseek.platformTokenLabel"
    case saveCredential = "deepseek.saveCredential"
    case deepseekBrowserSession = "deepseek.browserSession"
    case arkAccessKeyIDLabel = "ark.accessKeyIDLabel"
    case arkSecretAccessKeyLabel = "ark.secretAccessKeyLabel"
    case arkAKSKHint = "ark.akskHint"
    case nebulaBaseURLLabel = "nebula.baseURLLabel"
    case nebulaBaseURLHint = "nebula.baseURLHint"
    case nebulaAPIKeyLabel = "nebula.apiKeyLabel"
    case nebulaCredentialsHint = "nebula.credentialsHint"
    case nebulaBrowserSession = "nebula.browserSession"
    case nebulaBrowserHint = "nebula.browserHint"
    case reimportNebulaBrowserSession = "settings.reimportNebulaBrowserSession"
    case nebulaUsedTotal = "nebula.usedTotal"
    case nebulaUsageUnavailable = "nebula.usageUnavailable"
    case nebulaTokenDetail = "nebula.tokenDetail"
    case zaiAPIKeyLabel = "zai.apiKeyLabel"
    case zaiRegionLabel = "zai.regionLabel"
    case zaiCredentialsHint = "zai.credentialsHint"
    case kimiAPIKeyLabel = "kimi.apiKeyLabel"
    case kimiCredentialsHint = "kimi.credentialsHint"
    case kimiBrowserSession = "kimi.browserSession"
    case kimiBrowserHint = "kimi.browserHint"
    case kimiWebSessionInvalidHint = "kimi.webSessionInvalidHint"
    case reimportKimiBrowserSession = "settings.reimportKimiBrowserSession"
    case reimportLongCatBrowserSession = "settings.reimportLongCatBrowserSession"
    case grokPoolBaseURLLabel = "grokPool.baseURLLabel"
    case grokPoolBaseURLHint = "grokPool.baseURLHint"
    case grokPoolUsernameLabel = "grokPool.usernameLabel"
    case grokPoolPasswordLabel = "grokPool.passwordLabel"
    case grokPoolCredentialsHint = "grokPool.credentialsHint"
    case grokPoolValuePercent = "grokPool.valuePercent"
    case grokPoolValueCost = "grokPool.valueCost"
    case grokPoolAccountAvailability = "grokPool.accountAvailability"
    case grokPoolRequests = "grokPool.requests"
    case grokPoolRequestDetail = "grokPool.requestDetail"
    case grokPoolCost = "grokPool.cost"
    case grokPoolTokenTotal = "grokPool.tokenTotal"
    case grokPoolTokenDetail = "grokPool.tokenDetail"
    case grokPoolAccounts = "grokPool.accounts"
    case errorArkcliNotFound = "error.arkcliNotFound"
    case errorArkcliNotAuthenticated = "error.arkcliNotAuthenticated"
    case errorArkcliTimedOut = "error.arkcliTimedOut"
    case errorArkcliFailed = "error.arkcliFailed"
    case errorMissingCredentials = "error.missingCredentials"
    case errorNetwork = "error.network"
    case errorAPI = "error.api"
    case errorParse = "error.parse"
    case errorNoPlan = "error.noPlan"
    case errorOpenCodeCookieMissing = "error.openCodeCookieMissing"
    case errorOpenCodeCookieInvalid = "error.openCodeCookieInvalid"
    case errorOpenCodeBrowserSessionMissing = "error.openCodeBrowserSessionMissing"
    case errorOpenCodeBrowserAuthorizationRequired = "error.openCodeBrowserAuthorizationRequired"
    case errorOpenCodeNeedsFullDiskAccess = "error.openCodeNeedsFullDiskAccess"
    case errorDeepSeekMissingCredentials = "error.deepSeekMissingCredentials"
    case errorDeepSeekInvalidPlatformToken = "error.deepSeekInvalidPlatformToken"
    case errorNebulaMissingCredentials = "error.nebulaMissingCredentials"
    case errorNebulaInvalidToken = "error.nebulaInvalidToken"
    case errorNebulaBrowserSessionMissing = "error.nebulaBrowserSessionMissing"
    case errorNebulaBrowserAuthorizationRequired = "error.nebulaBrowserAuthorizationRequired"
    case errorZaiMissingCredentials = "error.zaiMissingCredentials"
    case errorZaiInvalidToken = "error.zaiInvalidToken"
    case errorKimiMissingCredentials = "error.kimiMissingCredentials"
    case errorKimiInvalidToken = "error.kimiInvalidToken"
    case errorKimiBrowserSessionMissing = "error.kimiBrowserSessionMissing"
    case errorKimiBrowserAuthorizationRequired = "error.kimiBrowserAuthorizationRequired"
    case errorGrokPoolMissingCredentials = "error.grokPoolMissingCredentials"
    case errorGrokPoolInvalidToken = "error.grokPoolInvalidToken"
    case errorLongcatMissingCredentials = "error.longcatMissingCredentials"
    case errorLongcatInvalidSession = "error.longcatInvalidSession"
    case errorLongcatBrowserSessionMissing = "error.longcatBrowserSessionMissing"
    case errorLongcatBrowserAuthorizationRequired = "error.longcatBrowserAuthorizationRequired"
    case errorAliyunMissingCredentials = "error.aliyunMissingCredentials"
    case errorAliyunInvalidToken = "error.aliyunInvalidToken"
    case errorAliyunNotActivated = "error.aliyunNotActivated"
    case errorStepFunMissingCredentials = "error.stepFunMissingCredentials"
    case errorStepFunInvalidSession = "error.stepFunInvalidSession"
    case errorStepFunBrowserSessionMissing = "error.stepFunBrowserSessionMissing"
    case errorSenseNovaMissingCredentials = "error.senseNovaMissingCredentials"
    case errorSenseNovaInvalidSession = "error.senseNovaInvalidSession"
    case errorSenseNovaNotSupported = "error.senseNovaNotSupported"
    case errorSenseNovaBrowserSessionMissing = "error.senseNovaBrowserSessionMissing"
    case errorSenseNovaInteractiveAuth = "error.senseNovaInteractiveAuth"
    case errorSenseNovaAuthRejected = "error.senseNovaAuthRejected"
    case errorSenseNovaAuthLoop = "error.senseNovaAuthLoop"
    case errorSenseNovaTokenEndpoint = "error.senseNovaTokenEndpoint"
    case errorSenseNovaTokenFailed = "error.senseNovaTokenFailed"
    case errorSenseNovaTokenUnparseable = "error.senseNovaTokenUnparseable"
    case errorSenseNovaTokenMissing = "error.senseNovaTokenMissing"
    case errorInsecureEndpoint = "error.insecureEndpoint"
    case errorProbeModels = "error.probeModels"
    case apiKeyNoHeaders = "apiKey.noHeaders"
    case apiKeyNoWindow = "apiKey.noWindow"

    // LongCat card + settings
    case longCatTokenQuota = "longcat.tokenQuota"
    case longCatTotalTokens = "longcat.totalTokens"
    case longCatUsedTokens = "longcat.usedTokens"
    case longCatAvailableTokens = "longcat.availableTokens"
    case longCatUsedPercent = "longcat.usedPercent"
    case longCatRemainingPercent = "longcat.remainingPercent"
    case longCatFuelPack = "longcat.fuelPack"
    case longCatFuelExpiry = "longcat.fuelExpiry"
    case longCatCookieSource = "longcat.cookieSource"
    case longCatCookieAutomatic = "longcat.cookieAutomatic"
    case longCatCookieManual = "longcat.cookieManual"
    case longCatAutomaticHint = "longcat.automaticHint"
    case longCatManualHint = "longcat.manualHint"
    case longCatCookiePlaceholder = "longcat.cookiePlaceholder"
    case longCatCredentialsHint = "longcat.credentialsHint"
    case longCatBrowserSession = "longcat.browserSession"

    // Alibaba Cloud (阿里云百炼 Coding Plan)
    case aliyunAPIKeyLabel = "aliyun.apiKeyLabel"
    case aliyunCredentialsHint = "aliyun.credentialsHint"
    case aliyunPendingHint = "aliyun.pendingHint"
    case stepFunCredentialsHint = "stepfun.credentialsHint"
    case stepFunAPIKeyLabel = "stepfun.apiKeyLabel"
    case stepFunManualCookiePlaceholder = "stepfun.manualCookiePlaceholder"
    case senseNovaManualCookiePlaceholder = "sensenova.manualCookiePlaceholder"
    case senseNovaCredentialsHint = "sensenova.credentialsHint"
    case senseNovaAPIKeyLabel = "sensenova.apiKeyLabel"

    // Subscription expiry reminders
    case reminderHeader = "reminder.header"
    case reminderDaysLeft = "reminder.daysLeft"
    case reminderQuotaLeft = "reminder.quotaLeft"
    case reminderExpiresToday = "reminder.expiresToday"
    case reminderBodyQuota = "reminder.bodyQuota"
    case reminderEnabledLabel = "reminder.enabledLabel"
    case reminderDaysLabel = "reminder.daysLabel"
    case reminderDaysOption = "reminder.daysOption"
    case reminderNotifyLabel = "reminder.notifyLabel"
    case reminderNotifyHint = "reminder.notifyHint"
    case reminderRuleHint = "reminder.ruleHint"
    case reminderManualSection = "reminder.manualSection"
    case reminderManualNamePlaceholder = "reminder.manualNamePlaceholder"
    case reminderManualNotePlaceholder = "reminder.manualNotePlaceholder"
    case reminderManualExpiryLabel = "reminder.manualExpiryLabel"
    case reminderManualAdd = "reminder.manualAdd"
    case reminderManualEmpty = "reminder.manualEmpty"
    case reminderManualDelete = "reminder.manualDelete"
    case reminderSectionTitle = "reminder.sectionTitle"
    case reminderManualNamePrompt = "reminder.manualNamePrompt"
    case reminderManualNotePrompt = "reminder.manualNotePrompt"
    case refreshAll = "settings.refreshAll"
    case refreshProviderMenu = "settings.refreshProviderMenu"

    // Display mode display names
    case displayIconOnly = "display.iconOnly"
    case displayIconAndPercent = "display.iconAndPercent"
    case displayPercentOnly = "display.percentOnly"
    case displayLogoOnly = "display.logoOnly"
    case displayLogoAndPercent = "display.logoAndPercent"
    case displayLogoAndRings = "display.logoAndRings"
    case menuBarValue = "display.menuBarValue"
    case displayValuePercent = "display.value.percent"
    case displayValueBalance = "display.value.balance"

    // Refresh interval display names
    case interval1m = "interval.1m"
    case interval2m = "interval.2m"
    case interval5m = "interval.5m"
    case interval15m = "interval.15m"
    case interval30m = "interval.30m"
}

/// Runtime localization manager. Observable so SwiftUI views re-render on
/// language change and the menu bar rebuilds.
///
/// Intentionally NOT `@MainActor`: the string table is read-only, and `t(_:)`
/// must be callable from nonisolated computed-property getters (e.g.
/// `AppSettings.DisplayMode.displayName`) and from `MenuBuilder` static funcs.
/// `language` only mutates on the main thread (Settings Picker), so reads from
/// other contexts are safe in practice. Marked `nonisolated(unsafe)` to opt out
/// of the Sendable check for the singleton.
final class L10n: ObservableObject {
    nonisolated(unsafe) static let shared = L10n()

    @Published var language: Language {
        didSet {
            // Persist and notify. AppSettings owns writes from the Settings window;
            // this manager only publishes the visual-language invalidation.
            UserDefaults.standard.set(language.rawValue, forKey: "tokenbar.language")
            // Notify menu controller to rebuild.
            NotificationCenter.default.post(name: Self.languageDidChange, object: nil)
        }
    }

    nonisolated static let languageDidChange = Notification.Name("tokenbar.languageDidChange")

    private init() {
        let raw = UserDefaults.standard.string(forKey: "tokenbar.language") ?? Language.system.rawValue
        self.language = Language(rawValue: raw) ?? .system
    }

    /// Look up a localized string for the current language.
    func t(_ key: LKey) -> String {
        let lang = language.resolved
        return Self.table[key.rawValue]?[lang] ?? Self.table[key.rawValue]?[.en] ?? key.rawValue
    }

    /// Static convenience for use where observing isn't needed (e.g. menu build).
    static func t(_ key: LKey) -> String { shared.t(key) }

    var locale: Locale {
        language.resolved == .zh ? Locale(identifier: "zh_Hans_CN") : Locale(identifier: "en_US")
    }

    func productName(_ product: PlanSnapshot.Product) -> String {
        switch product {
        case .codingPlan: t(.productCodingPlan)
        case .agentPlan: t(.productAgentPlan)
        case .codingPlanTeam: t(.productCodingPlanTeam)
        case .agentPlanTeam: t(.productAgentPlanTeam)
        case .openCodeGo: t(.productOpenCodeGo)
        case .deepseek: t(.productDeepSeek)
        case .nebula: t(.productNebula)
        case .grokPool: t(.productGrokPool)
        case .longcat: t(.productLongCat)
        case .aliyunCodingPlan: t(.productAliyunCodingPlan)
        case .stepfunCodingPlan: t(.productStepFunCodingPlan)
        case .senseNovaCodingPlan: t(.productSenseNovaCodingPlan)
        }
    }

    func windowName(_ label: String) -> String {
        switch label.lowercased() {
        case "session": t(.windowSession)
        case "5h", "5-hour", "five_hour": t(.window5Hour)
        case "weekly", "week": t(.windowWeekly)
        case "monthly", "month": t(.windowMonthly)
        case "requests": t(.windowRequests)
        case "balance": t(.windowBalance)
        default: label
        }
    }

    /// Pluralized countdown string like "in 2d 3h" / "in 3h 5m" / "in 7m".
    func countdown(days: Int, hours: Int, minutes: Int) -> String {
        let body: String
        if days > 0 {
            body = "\(days)\(t(.dayShort)) \(hours)\(t(.hourShort))"
        } else if hours > 0 {
            body = "\(hours)\(t(.hourShort)) \(minutes)\(t(.minShort))"
        } else {
            body = "\(minutes)\(t(.minShort))"
        }
        // English uses "in <body>"; Chinese just shows the body (the surrounding
        // label already reads "重置于 X" which reads naturally without "in").
        return language.resolved == .en ? "in \(body)" : body
    }

    /// The full string table. keyed by LKey.rawValue -> Language -> string.
    private static let table: [String: [Language: String]] = {
        var t: [String: [Language: String]] = [:]
        let add: (LKey, String, String) -> Void = { key, zh, en in
            t[key.rawValue] = [.zh: zh, .en: en]
        }

        // Menu - actions
        add(.refreshNow, "立即刷新", "Refresh Now")
        add(.openArkcliLogin, "打开 arkcli 登录", "Open arkcli auth login")
        add(.openArkConsole, "打开方舟控制台", "Open Ark Console")
        add(.openCodeGo, "打开 OpenCode Go", "Open OpenCode Go")
        add(.settings, "设置…", "Settings…")
        add(.quitTokenBar, "退出 TokenBar", "Quit TokenBar")
        add(.updated, "更新于", "Updated")
        add(.updatedJustNow, "刚刚更新", "Updated just now")
        add(.updatedSecondsAgo, "%d 秒前更新", "Updated %d seconds ago")
        add(.updatedMinutesAgo, "%d 分钟前更新", "Updated %d minutes ago")
        add(.updatedHoursAgo, "%d 小时前更新", "Updated %d hours ago")
        add(.refreshDetails, "正在获取最新用量", "Fetching latest usage")

        // Menu - cards
        add(.loadingUsage, "正在加载用量…", "Loading usage…")
        add(.refreshing, "刷新中…", "Refreshing…")
        add(.fetchFailed, "无法获取用量", "Couldn't fetch usage")
        add(.noDataYet, "暂无数据", "No data yet")
        add(.left, "剩余", "left")
        add(.used, "已用", "used")
        add(.remainingPercent, "剩余 %d%%", "%d%% left")
        add(.resets, "重置于", "resets")
        add(.noResetTime, "无重置时间", "no reset time")
        add(.now, "现在", "now")
        add(.auth, "认证", "auth")
        add(.seat, "席位", "seat")
        add(.dayShort, "天", "d")
        add(.hourShort, "小时", "h")
        add(.minShort, "分", "m")
        add(.staleData, "显示上次成功同步的数据", "Showing data from the last successful sync")

        // Ring legend labels
        add(.monthly, "每月", "Monthly")
        add(.weekly, "每周", "Weekly")
        add(.session, "5 小时", "Session")

        // Plan expiry
        add(.expiresIn, "还有 %d 天到期", "expires in %d days")
        add(.expired, "已到期", "expired")
        add(.expiresOn, "套餐到期 %@", "Plan expires %@")

        // Settings window
        add(.settingsTitle, "TokenBar 设置", "TokenBar Settings")
        add(.sectionMenuBar, "菜单栏", "Menu bar")
        add(.sectionRefresh, "刷新", "Refresh")
        add(.sectionDataSource, "数据源", "Data source")
        add(.sectionOpenCode, "OpenCode Go", "OpenCode Go")
        add(.sectionDiagnostics, "诊断", "Diagnostics")
        add(.sectionAdvanced, "高级", "Advanced")
        add(.displayMode, "显示模式", "Display mode")
        add(.interval, "间隔", "Interval")
        add(.refreshWhenMenuOpens, "点开菜单栏图标时刷新", "Refresh when opening the menu bar item")
        add(.lastFetch, "上次", "Last")
        add(.source, "来源", "Source")
        add(.sourceAuto, "自动 (AK/SK → API Key → arkcli)", "Auto (AK/SK -> API Key -> arkcli)")
        add(.arkAccessKeyIDLabel, "Access Key ID（可选）", "Access Key ID (optional)")
        add(.arkSecretAccessKeyLabel, "Secret Access Key（可选）", "Secret Access Key (optional)")
        add(.arkAKSKHint, "按以下优先级读取：本页填写的 IAM 密钥（保存在钥匙串，长期有效不会过期）> 环境变量（VOLCENGINE_ACCESS_KEY_ID 等）> arkcli 登录。建议在控制台创建只读权限的子账号密钥对填到这里，之后无需再定期 arkcli 重新登录。", "Credentials are read in this order: the IAM key pair entered here (stored in Keychain; long-lived, never expires) > environment variables (VOLCENGINE_ACCESS_KEY_ID etc.) > the arkcli sign-in session. Create a read-only sub-account key pair in the console and enter it here to stop needing periodic arkcli re-logins.")
        add(.sourceCli, "arkcli (SSO)", "arkcli (SSO)")
        add(.sourceApi, "API (AK/SK 或 API Key)", "API (AK/SK or API Key)")
        add(.connectedVia, "已连接 ·", "Connected via")
        add(.authLabel, "认证", "Auth")
        add(.planCount, "个套餐", "plan(s)")
        add(.tightest, "最紧", "Tightest")
        add(.fetchFailedShort, "获取失败", "Fetch failed")
        add(.refreshingStatus, "刷新中…", "Refreshing…")
        add(.arkcliPath, "arkcli 路径：", "arkcli path:")
        add(.arkcliVersion, "arkcli 版本：", "arkcli version:")
        add(.shell, "Shell：", "shell:")
        add(.notFound, "未找到", "not found")
        add(.language, "语言", "Language")
        add(.noProvider, "没有可用的数据源。请设置 AK/SK、ARK_API_KEY，或登录 arkcli。", "No data source is available. Set AK/SK or ARK_API_KEY, or sign in to arkcli.")
        add(.tabArk, "Ark", "Ark")
        add(.tabOpenCode, "OpenCode", "OpenCode")
        add(.tabDeepSeek, "DeepSeek", "DeepSeek")
        add(.tabNebula, "APINebula", "APINebula")
        add(.tabZai, "智谱", "Z.ai")
        add(.tabKimi, "Kimi", "Kimi")
        add(.tabGrokPool, "GrokPool", "GrokPool")
        add(.tabLongCat, "LongCat", "LongCat")
        add(.tabAliyun, "阿里云", "Alibaba Cloud")
        add(.tabStepFun, "阶跃", "StepFun")
        add(.tabSenseNova, "商汤", "SenseNova")
        add(.tabSummary, "概览", "Overview")
        add(.showSummary, "在菜单栏显示概览", "Show overview in menu bar")
        add(.showProvider, "在菜单栏显示", "Show in menu bar")
        add(.sectionDisplay, "显示", "Display")
        add(.opencodeCookie, "会话 Cookie", "Session Cookie")
        add(.opencodeCookiePlaceholder, "粘贴 opencode.ai 的 Cookie 头", "Paste the Cookie header from opencode.ai")
        add(.opencodeWorkspaceID, "Workspace ID", "Workspace ID")
        add(.opencodeWorkspaceIDPlaceholder, "留空自动解析（wrk_…）", "Leave empty to auto-resolve (wrk_…)")
        add(.opencodeTestRefresh, "测试并刷新", "Test and Refresh")
        add(.opencodeCookieNotSet, "未配置 Cookie", "Cookie not configured")
        add(.opencodeCookieSet, "Cookie 已安全保存到钥匙串", "Cookie saved securely in Keychain")
        add(.settingsGeneral, "通用", "General")
        add(.settingsArk, "Ark 套餐", "Ark Plans")
        add(.settingsOpenCode, "OpenCode Go", "OpenCode Go")
        add(.settingsDeepSeek, "DeepSeek", "DeepSeek")
        add(.settingsNebula, "APINebula 中转", "APINebula Relay")
        add(.settingsZai, "智谱 Coding Plan", "Z.ai Coding Plan")
        add(.settingsKimi, "Kimi For Coding", "Kimi For Coding")
        add(.settingsGrokPool, "GrokPool 网关", "GrokPool Gateway")
        add(.settingsLongCat, "LongCat", "LongCat")
        add(.settingsAliyun, "阿里云 Coding Plan", "Alibaba Cloud Coding Plan")
        add(.settingsStepFun, "阶跃 Step Plan", "StepFun Step Plan")
        add(.settingsSenseNova, "商汤 Token Plan", "SenseNova Token Plan")
        add(.settingsReminder, "订阅提醒", "Expiry Reminders")
        add(.settingsGeneralSubtitle, "外观、刷新、语言与操作", "Appearance, refresh, language, and actions")
        add(.settingsArkSubtitle, "火山方舟 Coding / Agent 套餐用量", "Volcengine Ark Coding / Agent plan usage")
        add(.settingsOpenCodeSubtitle, "从 OpenCode Go 订阅页读取的配额", "Quota read from the OpenCode Go subscription page")
        add(.settingsDeepSeekSubtitle, "余额与平台用量明细", "Balance and platform usage detail")
        add(.settingsNebulaSubtitle, "中转站余额与调用日志", "Relay balance and request log")
        add(.settingsZaiSubtitle, "智谱 GLM Coding Plan 额度窗口", "Zhipu GLM Coding Plan quota windows")
        add(.settingsKimiSubtitle, "Kimi For Coding 会员配额与共享总池", "Kimi For Coding membership quota and shared pool")
        add(.settingsGrokPoolSubtitle, "网关 24 小时运营看板", "Gateway 24-hour operations dashboard")
        add(.settingsLongCatSubtitle, "Token 资源包剩余额度", "Token package remaining quota")
        add(.settingsAliyunSubtitle, "百炼 Coding Plan 三档请求额度（开通后生效）", "Bailian Coding Plan request windows (active after activation)")
        add(.settingsReminderSubtitle, "快到期且额度没用完时提醒你", "Nudges you when a plan expires with quota left")
        add(.settingsDiagnosticsSubtitle, "运行环境与 arkcli 检查", "Runtime environment and arkcli checks")
        add(.settingsDiagnostics, "诊断", "Diagnostics")
        add(.sectionAppearance, "外观", "Appearance")
        add(.sectionBehavior, "行为", "Behavior")
        add(.sectionConnection, "连接", "Connection")
        add(.sectionActions, "操作", "Actions")
        add(.sectionSubscription, "套餐用量", "Subscription usage")
        add(.status, "状态", "Status")
        add(.refreshArk, "刷新 Ark 用量", "Refresh Ark Usage")
        add(.refreshOpenCode, "刷新 OpenCode Go", "Refresh OpenCode Go")
        add(.refreshDeepSeek, "刷新 DeepSeek", "Refresh DeepSeek")
        add(.refreshNebula, "刷新 APINebula", "Refresh APINebula")
        add(.refreshZai, "刷新智谱", "Refresh Z.ai")
        add(.refreshKimi, "刷新 Kimi", "Refresh Kimi")
        add(.refreshGrokPool, "刷新 GrokPool", "Refresh GrokPool")
        add(.refreshLongCat, "刷新 LongCat", "Refresh LongCat")
        add(.refreshAliyun, "刷新阿里云", "Refresh Alibaba Cloud")
        add(.refreshStepFun, "刷新阶跃", "Refresh StepFun")
        add(.refreshSenseNova, "刷新商汤", "Refresh SenseNova")
        add(.openDeepSeekPlatform, "打开 DeepSeek 平台", "Open DeepSeek Platform")
        add(.openNebulaConsole, "打开 APINebula 控制台", "Open APINebula Console")
        add(.openZaiConsole, "打开智谱用量页", "Open Z.ai Usage")
        add(.openKimiConsole, "打开 Kimi Code 控制台", "Open Kimi Code Console")
        add(.openGrokPoolConsole, "打开 GrokPool 控制台", "Open GrokPool Console")
        add(.openLongCatConsole, "打开 LongCat 用量页", "Open LongCat Usage")
        add(.openAliyunConsole, "打开阿里云 Coding Plan 控制台", "Open Alibaba Cloud Coding Plan Console")
        add(.openStepFunConsole, "打开阶跃控制台", "Open StepFun Console")
        add(.openSenseNovaConsole, "打开商汤控制台", "Open SenseNova Console")
        add(.openCodeCookieSource, "Cookie 来源", "Cookie source")
        add(.openCodeCookieAutomatic, "自动读取浏览器", "Automatic from browser")
        add(.openCodeCookieManual, "手动 Cookie", "Manual Cookie")
        add(.openCodeAutomaticHint, "普通刷新只使用 TokenBar 已缓存的会话，不会弹出密码框。首次使用或登录失效后，请点“重新读取浏览器登录”；只有这个操作可能请求一次钥匙串授权。", "Routine refreshes only use TokenBar's cached session and never show a password prompt. On first use or after sign-in expires, click “Re-import Browser Sign-in”; only that action may request Keychain access once.")
        add(.openCodeManualHint, "仅在自动读取失败时使用。Cookie 会保存在本机钥匙串，不会写入偏好设置或日志。", "Use only when automatic import fails. The Cookie is stored in Keychain, never preferences or logs.")
        add(.openCodeAuthoritativeHint, "圆环只使用 OpenCode Go 网页返回的套餐用量；不会用本地消费记录估算余额。", "Rings use only subscription usage returned by OpenCode Go; local spending history is never used as quota.")
        add(.reimportBrowserSession, "重新读取浏览器登录", "Re-import Browser Session")
        add(.reimportStepFunBrowserSession, "重新读取浏览器登录", "Re-import Browser Sign-in")
        add(.reimportSenseNovaBrowserSession, "重新读取浏览器登录", "Re-import Browser Sign-in")
        add(.saveCookie, "保存 Cookie", "Save Cookie")
        add(.lastSuccessfulUpdate, "上次成功更新", "Last successful update")
        add(.noSuccessfulUpdate, "尚未成功更新", "No successful update yet")
        add(.browserSession, "浏览器会话", "Browser session")
        add(.manualCookie, "手动 Cookie", "Manual Cookie")
        add(.openCodeBrowserAccessTitle, "允许读取浏览器登录", "Allow Browser Sign-in Access")
        add(.openCodeBrowserAccessMessage, "TokenBar 将请求 macOS 钥匙串中的“%@”，用于解密 opencode.ai 登录 Cookie。TokenBar 只保留认证 Cookie，不读取浏览历史。", "TokenBar will request “%@” from macOS Keychain to decrypt the opencode.ai sign-in Cookie. TokenBar keeps only the authentication Cookie and does not read browsing history.")
        add(.continueAction, "继续", "Continue")
        add(.settingsAppVersion, "TokenBar 版本", "TokenBar version")
        add(.settingsCurrentSource, "当前来源", "Current source")
        add(.settingsPreviousData, "正在显示上次成功数据", "Showing the last successful data")
        add(.settingsNoUsage, "暂无可显示的套餐用量", "No subscription usage to display")

        // Dynamic usage labels and errors
        add(.productCodingPlan, "Coding 套餐", "Coding Plan")
        add(.productAgentPlan, "Agent 套餐", "Agent Plan")
        add(.productCodingPlanTeam, "团队 Coding 套餐", "Coding Plan (Team)")
        add(.productAgentPlanTeam, "团队 Agent 套餐", "Agent Plan (Team)")
        add(.productOpenCodeGo, "OpenCode Go", "OpenCode Go")
        add(.productDeepSeek, "DeepSeek", "DeepSeek")
        add(.productNebula, "APINebula", "APINebula")
        add(.productGrokPool, "GrokPool", "GrokPool")
        add(.productLongCat, "LongCat", "LongCat")
        add(.productAliyunCodingPlan, "阿里云 Coding Plan", "Alibaba Cloud Coding Plan")
        add(.productStepFunCodingPlan, "阶跃 Step Plan", "StepFun Step Plan")
        add(.productSenseNovaCodingPlan, "商汤 Token Plan", "SenseNova Token Plan")
        add(.windowSession, "会话", "Session")
        add(.window5Hour, "5 小时", "5-hour")
        add(.windowWeekly, "每周", "Weekly")
        add(.windowMonthly, "每月", "Monthly")
        add(.windowRequests, "请求数", "Requests")
        add(.windowBalance, "余额", "Balance")
        add(.deepseekToday, "今日", "Today")
        add(.deepseekMonthly, "每月", "This month")
        add(.deepseekPaidGranted, "充值 %@ · 赠送 %@", "Paid %@ · Granted %@")
        add(.deepseekUsageDetail, "%@ tokens · %@ 次请求", "%@ tokens · %@ requests")
        add(.deepseekUsageUnavailable, "配置 DEEPSEEK_PLATFORM_TOKEN 后显示用量", "Set DEEPSEEK_PLATFORM_TOKEN to see usage")
        add(.deepseekTopModel, "常用模型：%@", "Top model: %@")
        add(.deepseekCategoryDetail, "缓存命中 %@ · 未命中 %@ · 输出 %@", "Cache hit %@ · miss %@ · output %@")
        add(.deepseekCredentialsHint, "凭据按以下优先级读取：本页填写的值（保存在钥匙串）> 环境变量（DEEPSEEK_API_KEY / DEEPSEEK_PLATFORM_TOKEN）> Chrome 浏览器登录。只要 Chrome 登录过 platform.deepseek.com，就无需填写任何 Key。", "Credentials are read in this order: values entered here (stored in Keychain) > environment variables (DEEPSEEK_API_KEY / DEEPSEEK_PLATFORM_TOKEN) > Chrome sign-in. If Chrome is signed in to platform.deepseek.com, no key is needed at all.")
        add(.deepseekPlatformHint, "余额来自 platform.deepseek.com；充值后圆环会在下次刷新时自动更新。", "Balance comes from platform.deepseek.com; recharging updates the ring on the next refresh.")
        add(.deepseekAPIKeyLabel, "API Key（可选）", "API Key (optional)")
        add(.deepseekPlatformTokenLabel, "Platform Token（可选）", "Platform Token (optional)")
        add(.saveCredential, "保存", "Save")
        add(.deepseekBrowserSession, "浏览器会话：%@", "Browser session: %@")
        add(.nebulaBaseURLLabel, "API 地址", "API base URL")
        add(.nebulaBaseURLHint, "控制台地址，默认 https://apinebula.ai（不要填 /v1）", "Console base URL, default https://apinebula.ai (do not append /v1)")
        add(.nebulaAPIKeyLabel, "API Key（可选，仅用于 /v1 模型调用）", "API Key (optional; for /v1 model calls only)")
        add(.nebulaCredentialsHint, "官方文档只保证 API Key 调用 /v1 模型接口。余额/使用日志是控制台接口，优先使用浏览器登录会话。", "Official docs only guarantee API keys for /v1 model calls. Balance/usage logs are console APIs and prefer a browser sign-in session.")
        add(.nebulaBrowserSession, "浏览器会话：%@", "Browser session: %@")
        add(.nebulaBrowserHint, "请先在浏览器登录 apinebula.ai 控制台，再点“重新读取浏览器登录”。常规刷新只使用已缓存会话，不会反复弹钥匙串。", "Sign in to the apinebula.ai console in your browser, then click “Re-import Browser Sign-in”. Routine refreshes only use the cached session and will not re-prompt Keychain.")
        add(.reimportNebulaBrowserSession, "重新读取浏览器登录", "Re-import Browser Sign-in")
        add(.nebulaUsedTotal, "已用 %@", "Used %@")
        add(.nebulaUsageUnavailable, "无法读取使用日志", "Usage log unavailable")
        add(.nebulaTokenDetail, "缓存读 %@ · 未缓存 %@ · 输出 %@", "Cache read %@ · Uncached %@ · Output %@")
        add(.zaiAPIKeyLabel, "API Key", "API Key")
        add(.zaiRegionLabel, "API 区域", "API region")
        add(.zaiCredentialsHint, "在 bigmodel.cn 用户中心创建 API Key 并填入；也可设置环境变量 Z_AI_API_KEY。国内用户选 BigModel CN 区域。", "Create an API key at bigmodel.cn and paste it here, or set the Z_AI_API_KEY environment variable. China-mainland users should pick BigModel CN.")
        add(.kimiAPIKeyLabel, "API Key", "API Key")
        add(.kimiCredentialsHint, "API Key 可选（在 kimi.com/code/console 创建）；也可设置环境变量 KIMI_CODE_API_KEY。填 API Key 可看到 Code 自己的配额环；导入浏览器登录后可额外看到共享总池与 Code 7 天环。", "An API key is optional (create it at kimi.com/code/console); KIMI_CODE_API_KEY also works. With an API key you see Code's own quota rings; importing the browser sign-in additionally shows the shared pool and the Code 7-day ring.")
        add(.kimiBrowserSession, "浏览器会话：%@", "Browser session: %@")
        add(.kimiBrowserHint, "共享总池来自 www.kimi.com 的 access_token（不是 kimi-auth cookie）。TokenBar 会静默读取已登录的 Kimi.app；也可点“重新读取浏览器登录”从浏览器 Local Storage 导入。", "The shared pool uses the www.kimi.com access_token (not the kimi-auth cookie). TokenBar silently reads a signed-in Kimi.app, or import the browser Local Storage token with “Re-import Browser Sign-in”.")
        add(.kimiWebSessionInvalidHint, "共享总池会话无效。请先打开并登录本机 Kimi.app，或在浏览器打开 www.kimi.com 后重新读取浏览器登录。kimi-auth cookie 不够，需要 Local Storage 里的 access_token。", "The shared-pool session is invalid. Sign in to the Kimi.app desktop client, or open www.kimi.com in a browser and re-import. The kimi-auth cookie is not enough; the Local Storage access_token is required.")
        add(.reimportKimiBrowserSession, "重新读取浏览器登录", "Re-import Browser Sign-in")
        add(.reimportLongCatBrowserSession, "重新读取浏览器登录", "Re-import Browser Sign-in")
        add(.grokPoolBaseURLLabel, "API 地址", "API base URL")
        add(.grokPoolBaseURLHint, "网关地址，默认 https://grok.axonlume.com（不要填 /v1）", "Gateway base URL, default https://grok.axonlume.com (do not append /v1)")
        add(.grokPoolUsernameLabel, "管理员账号", "Administrator username")
        add(.grokPoolPasswordLabel, "管理员密码", "Administrator password")
        add(.grokPoolCredentialsHint, "使用 Grok2API 控制台的管理员账号密码登录（POST /api/admin/v1/auth/login），用短期访问令牌读取 24h 运营看板（GET /api/admin/v1/dashboard?period=24h）。凭据与令牌只存本机 Keychain；令牌每 15 分钟自动重新获取。", "Sign in with the Grok2API console administrator account (POST /api/admin/v1/auth/login) and read the 24-hour dashboard (GET /api/admin/v1/dashboard?period=24h) with the short-lived access token. Credentials and tokens stay in the local Keychain; the token re-fetches automatically every 15 minutes.")
        add(.grokPoolValuePercent, "账号可用率百分比", "Availability percent")
        add(.grokPoolValueCost, "24h 费用（$）", "24h cost ($)")
        add(.grokPoolAccountAvailability, "账号可用率", "Account availability")
        add(.grokPoolRequests, "24h 请求数", "Requests (24h)")
        add(.grokPoolRequestDetail, "成功 %@ · 失败 %@", "OK %@ · Failed %@")
        add(.grokPoolCost, "24h 费用", "Billed (24h)")
        add(.grokPoolTokenTotal, "总 Token %@", "%@ tokens")
        add(.grokPoolTokenDetail, "输入 %@ · 缓存 %@ · 输出 %@ · 推理 %@", "Input %@ · Cached %@ · Output %@ · Reasoning %@")
        add(.grokPoolAccounts, "活跃账号 %@/%@", "Active accounts %@/%@")
        add(.longCatTokenQuota, "Token 资源包", "Token Quota")
        add(.longCatTotalTokens, "总额度", "Total")
        add(.longCatUsedTokens, "已用", "Used")
        add(.longCatAvailableTokens, "剩余", "Available")
        add(.longCatUsedPercent, "已用 %.1f%%", "%.1f%% used")
        add(.longCatRemainingPercent, "剩余 %.1f%%", "%.1f%% left")
        add(.longCatFuelPack, "加油包 %@ / %@", "Fuel pack %@ / %@")
        add(.longCatFuelExpiry, "最近到期 %@", "Nearest expiry %@")
        add(.longCatCookieSource, "Cookie 来源", "Cookie source")
        add(.longCatCookieAutomatic, "自动读取浏览器", "Automatic from browser")
        add(.longCatCookieManual, "手动 Cookie", "Manual Cookie")
        add(.longCatAutomaticHint, "普通刷新只使用 TokenBar 已缓存的会话，不会弹出密码框。首次使用或登录失效后，请点「重新读取浏览器登录」；只有这个操作可能请求一次钥匙串授权。", "Routine refreshes only use TokenBar's cached session and never show a password prompt. On first use or after sign-in expires, click “Re-import Browser Sign-in”; only that action may request Keychain access once.")
        add(.longCatManualHint, "仅在自动读取失败时使用。Cookie 会保存在本机钥匙串，不会写入偏好设置或日志。", "Use only when automatic import fails. The Cookie is stored in Keychain, never preferences or logs.")
        add(.longCatCookiePlaceholder, "粘贴 longcat.chat 的 Cookie 头", "Paste the Cookie header from longcat.chat")
        add(.longCatCredentialsHint, "LongCat 的用量接口在 longcat.chat 控制台（不是 api.longcat.chat），需要浏览器登录会话。支持自动读取浏览器 Cookie 或手动粘贴。", "LongCat's usage endpoints live behind the longcat.chat console (not api.longcat.chat) and need a browser sign-in session. Automatic browser-Cookie import or a manually pasted Cookie header are both supported.")
        add(.longCatBrowserSession, "浏览器会话：%@", "Browser session: %@")
        add(.errorArkcliNotFound, "未找到 arkcli。请安装后执行 `arkcli auth login volc-sso`。", "arkcli was not found. Install it, then run `arkcli auth login volc-sso`.")
        add(.errorArkcliNotAuthenticated, "arkcli 尚未登录。请执行 `arkcli auth login volc-sso` 后刷新。", "arkcli is not signed in. Run `arkcli auth login volc-sso`, then refresh.")
        add(.errorArkcliTimedOut, "arkcli 查询超时。请检查登录状态后重试。", "arkcli usage timed out. Check authentication and try again.")
        add(.errorArkcliFailed, "arkcli 查询失败 (%d)：%@", "arkcli usage failed (%d): %@")
        add(.errorMissingCredentials, "缺少火山引擎凭证。请设置 AK/SK，或登录 arkcli。", "Missing Volcengine credentials. Set AK/SK or sign in to arkcli.")
        add(.errorNetwork, "网络错误：%@", "Network error: %@")
        // Shared by every provider's apiError, so it must not name one of them:
        // OpenCode Go's 400 used to read "方舟 API 错误".
        add(.errorAPI, "接口返回错误 (%d)：%@", "API error (%d): %@")
        add(.errorParse, "无法解析响应：%@", "Failed to parse response: %@")
        add(.errorNoPlan, "未找到有效的 Coding 或 Agent 套餐用量：%@", "No active Coding or Agent Plan usage: %@")
        add(.errorOpenCodeCookieMissing, "未配置有效的 OpenCode Go 手动 Cookie。", "No valid manual OpenCode Go Cookie is configured.")
        add(.errorOpenCodeCookieInvalid, "OpenCode Go 登录已失效。请重新登录浏览器，或更新手动 Cookie。", "The OpenCode Go sign-in expired. Sign in again in the browser or update the manual Cookie.")
        add(.errorOpenCodeBrowserSessionMissing, "没有在浏览器中找到 opencode.ai 登录会话。请先在浏览器登录，或改用手动 Cookie。", "No opencode.ai browser session was found. Sign in in a browser or use a manual Cookie.")
        add(.errorOpenCodeBrowserAuthorizationRequired, "TokenBar 尚未缓存浏览器登录，或原会话已失效。请在 OpenCode Go 设置中点“重新读取浏览器登录”；后台刷新不会主动弹出密码框。", "TokenBar has no cached browser sign-in, or the previous session expired. Click “Re-import Browser Sign-in” in OpenCode Go settings; background refreshes will not show a password prompt.")
        add(.errorOpenCodeNeedsFullDiskAccess, "检测到 Chrome 已安装但系统不允许 TokenBar 读取其 Cookie。请打开 系统设置 → 隐私与安全性 → 完全磁盘访问权限，添加并允许 TokenBar，然后完全退出并重新打开 TokenBar，再点“重新读取浏览器登录”。", "Chrome is installed but macOS does not allow TokenBar to read its cookies. Grant TokenBar Full Disk Access in System Settings → Privacy & Security, then quit and reopen TokenBar and click “Re-import Browser Sign-in” again.")
        add(.errorDeepSeekMissingCredentials, "未找到 DeepSeek 凭据。可在 DeepSeek 设置中填写，或先在 Chrome 登录 platform.deepseek.com 后刷新。", "No DeepSeek credentials were found. Enter them in the DeepSeek settings, or sign in to platform.deepseek.com in Chrome and refresh.")
        add(.errorDeepSeekInvalidPlatformToken, "DeepSeek 平台会话无效或已过期。请更新 DEEPSEEK_PLATFORM_TOKEN。", "The DeepSeek Platform session is invalid or expired. Update DEEPSEEK_PLATFORM_TOKEN.")
        add(.errorNebulaMissingCredentials, "未配置 APINebula 控制台会话或 API Key。请先在浏览器登录 apinebula.ai，再点“重新读取浏览器登录”。", "No APINebula console session or API key is configured. Sign in at apinebula.ai, then click “Re-import Browser Sign-in”.")
        add(.errorNebulaInvalidToken, "APINebula 控制台会话或 API Key 无效。余额接口通常需要浏览器登录会话，请重新导入。", "The APINebula console session or API key is invalid. Balance endpoints usually need a browser sign-in session; re-import it.")
        add(.errorNebulaBrowserSessionMissing, "没有在浏览器中找到 apinebula.ai 登录会话。请先在浏览器登录控制台。", "No apinebula.ai browser session was found. Sign in to the console in a browser first.")
        add(.errorNebulaBrowserAuthorizationRequired, "TokenBar 尚未缓存 APINebula 浏览器登录。请在 APINebula 设置中点“重新读取浏览器登录”。", "TokenBar has no cached APINebula browser sign-in. Click “Re-import Browser Sign-in” in APINebula settings.")
        add(.errorZaiMissingCredentials, "未找到智谱 API Key。请在智谱设置中填写，或设置环境变量 Z_AI_API_KEY。", "No Z.ai API key found. Enter one in the Z.ai settings, or set Z_AI_API_KEY.")
        add(.errorZaiInvalidToken, "智谱 API Key 无效或已过期。请检查区域与 Key 是否匹配（BigModel CN / Global）。", "The Z.ai API key is invalid or expired. Check that the region and key match (BigModel CN / Global).")
        add(.errorKimiMissingCredentials, "未找到 Kimi API Key。请在 Kimi For Coding 设置中填写，或设置环境变量 KIMI_CODE_API_KEY。", "No Kimi API key found. Enter one in the Kimi For Coding settings, or set KIMI_CODE_API_KEY.")
        add(.errorKimiInvalidToken, "Kimi API Key 无效或已过期。请到 kimi.com/code/console 重新创建。", "The Kimi API key is invalid or expired. Create a new one at kimi.com/code/console.")
        add(.errorKimiBrowserSessionMissing, "没有在浏览器中找到 www.kimi.com 的登录会话（kimi-auth cookie）。请先在浏览器登录 Kimi。", "No www.kimi.com sign-in session (kimi-auth cookie) was found. Sign in to Kimi in a browser first.")
        add(.errorKimiBrowserAuthorizationRequired, "TokenBar 尚未缓存 Kimi 浏览器登录。请在 Kimi For Coding 设置中点“重新读取浏览器登录”。", "TokenBar has no cached Kimi browser sign-in. Click “Re-import Browser Sign-in” in Kimi For Coding settings.")
        add(.errorGrokPoolMissingCredentials, "未配置 GrokPool 管理员账号。请在 GrokPool 设置中填写账号密码，或设置环境变量 GROKPOOL_USERNAME / GROKPOOL_PASSWORD。", "No GrokPool administrator account is configured. Enter the username and password in the GrokPool settings, or set GROKPOOL_USERNAME / GROKPOOL_PASSWORD.")
        add(.errorGrokPoolInvalidToken, "GrokPool 管理员登录失败或会话已过期。请检查账号密码，或在 Grok2API 控制台重新登录。", "GrokPool administrator login failed or the session expired. Check the username and password, or sign in again in the Grok2API console.")
        add(.errorLongcatMissingCredentials, "未找到 LongCat 控制台会话。请在浏览器登录 longcat.chat，或在 LongCat 设置中粘贴 Cookie 头。", "No LongCat console session found. Sign in at longcat.chat, or paste a Cookie header in the LongCat settings.")
        add(.errorLongcatInvalidSession, "LongCat 登录已失效。请重新登录 longcat.chat，或更新手动 Cookie。", "The LongCat sign-in expired. Sign in again at longcat.chat or update the manual Cookie.")
        add(.errorLongcatBrowserSessionMissing, "没有在浏览器中找到 longcat.chat 登录会话。请先在浏览器登录 LongCat 控制台。", "No longcat.chat browser session was found. Sign in to the LongCat console in a browser first.")
        add(.errorLongcatBrowserAuthorizationRequired, "TokenBar 尚未缓存 LongCat 浏览器登录。请在 LongCat 设置中点“重新读取浏览器登录”。", "TokenBar has no cached LongCat browser sign-in. Click “Re-import Browser Sign-in” in LongCat settings.")
        add(.errorAliyunMissingCredentials, "未找到阿里云 Coding Plan API Key。", "No Alibaba Cloud Coding Plan API key found.")
        add(.errorAliyunInvalidToken, "阿里云 Coding Plan API Key 无效。请到百炼控制台「Coding Plan」页面重新获取。", "The Alibaba Cloud Coding Plan API key is invalid. Get a new one from the Bailian console Coding Plan page.")
        add(.errorAliyunNotActivated, "阿里云 Coding Plan 尚未开通或暂不可用。请在百炼控制台开通（注意开通期限）；开通后刷新即可读取用量。", "The Alibaba Cloud Coding Plan is not activated yet. Activate it in the Bailian console (mind the activation deadline); usage will appear on the next refresh.")
        add(.errorStepFunMissingCredentials, "未导入阶跃控制台登录会话。请在阶跃设置中点“重新读取浏览器登录”，或粘贴手动 Cookie。", "No StepFun console sign-in has been imported. Click “Re-import Browser Sign-in” in the StepFun settings, or paste a manual Cookie.")
        add(.errorStepFunInvalidSession, "阶跃控制台登录已失效。请重新读取浏览器登录。", "The StepFun console sign-in expired. Re-import the browser session.")
        add(.errorStepFunBrowserSessionMissing, "没有在浏览器中找到 stepfun.com 登录会话。请先在浏览器登录阶跃控制台。", "No stepfun.com sign-in session was found in the browser. Sign in to the StepFun console first.")
        add(.errorSenseNovaMissingCredentials, "未导入商汤控制台登录会话。请在商汤设置中点“重新读取浏览器登录”。", "No SenseNova console sign-in has been imported. Click “Re-import Browser Sign-in” in the SenseNova settings.")
        add(.errorSenseNovaInvalidSession, "商汤控制台登录已失效。请重新读取浏览器登录。", "The SenseNova console sign-in expired. Re-import the browser session.")
        add(.errorSenseNovaNotSupported, "商汤 Token Plan 的额度接口尚未确认：App 已探测候选接口并把响应写入 资源库/TokenBar/sensenova-last-response.txt，请把它发给开发者完成适配。", "The SenseNova Token Plan endpoint is not confirmed yet: TokenBar probed the candidate endpoints and wrote the responses to Application Support/TokenBar/sensenova-last-response.txt — send that file to the developer to finish the integration.")
        add(.errorSenseNovaBrowserSessionMissing, "没有在浏览器中找到 sensenova.cn 登录会话。请先在浏览器登录商汤控制台。", "No sensenova.cn sign-in session was found in the browser. Sign in to the SenseNova console first.")
        add(.errorSenseNovaInteractiveAuth, "商汤授权需要浏览器交互确认，无法在后台完成。请在浏览器重新登录控制台后再试。", "SenseNova's sign-in requires interactive approval, which cannot be completed in the background. Sign in to the console in a browser and try again.")
        add(.errorSenseNovaAuthRejected, "商汤授权未完成：%@", "SenseNova authorization did not complete: %@")
        add(.errorSenseNovaAuthLoop, "商汤授权跳转链过长，已中止。", "SenseNova's authorization redirect chain never resolved; giving up.")
        add(.errorSenseNovaTokenEndpoint, "商汤令牌地址无效。", "Invalid SenseNova token endpoint.")
        add(.errorSenseNovaTokenFailed, "商汤令牌换取失败（HTTP %d）：%@", "SenseNova token exchange failed (HTTP %d): %@")
        add(.errorSenseNovaTokenUnparseable, "商汤令牌响应无法解析。", "The SenseNova token response could not be parsed.")
        add(.errorSenseNovaTokenMissing, "商汤令牌响应缺少 access_token。", "The SenseNova token response carried no access_token.")
        add(.errorInsecureEndpoint, "自定义地址不安全：%@。凭据会发送到该地址，因此只允许 HTTPS（本地 http://localhost 例外）。", "Insecure custom endpoint: %@. Credentials are sent to this address, so only HTTPS is allowed (http://localhost is exempt).")
        add(.errorProbeModels, "所有探测模型均不可用", "All probe models failed")
        add(.apiKeyNoHeaders, "API Key 有效，但响应未返回请求限额头。", "API key is valid, but no request-limit headers were returned.")
        add(.apiKeyNoWindow, "API Key 有效，但未返回用量窗口。", "API key is valid, but no usage window was returned.")

        // Alibaba Cloud (阿里云百炼 Coding Plan)
        add(.aliyunAPIKeyLabel, "API Key", "API Key")
        add(.aliyunCredentialsHint, "在百炼控制台「Coding Plan」页面获取专属 API Key（sk-sp- 开头）；也可用环境变量 ALIYUN_CODING_PLAN_API_KEY（与按量计费 sk- Key 不互通）。", "Get the dedicated Coding Plan key (sk-sp-…) from the Bailian console; ALIYUN_CODING_PLAN_API_KEY also works. Not interchangeable with pay-as-you-go sk- keys.")
        add(.aliyunPendingHint, "用量读取在套餐开通后自动生效；若仍未显示，需把控制台「Coding Plan」页面的网络请求记录交给开发者。", "Usage reading activates automatically once the plan is activated. If it still does not appear, hand the console Coding Plan page network log to the developer.")
        add(.senseNovaCredentialsHint, "在浏览器登录 https://platform.sensenova.cn/console 后，点“重新读取浏览器登录”导入控制台会话（存 Keychain）；读取浏览器 Cookie 需要 TokenBar 拥有完全磁盘访问权限。Token Plan 的额度接口官方未公开，App 正在通过探测确定接口（探测响应写入资源库 TokenBar/sensenova-last-response.txt）。", "Sign in to https://platform.sensenova.cn/console in a browser, then click “Re-import Browser Sign-in” to capture the console session (stored in Keychain). Reading browser cookies requires Full Disk Access. The Token Plan quota API is not publicly documented; TokenBar probes the candidate endpoints to confirm it (probe responses are written to Application Support/TokenBar/sensenova-last-response.txt).")
        add(.senseNovaAPIKeyLabel, "API Key（Bearer）", "API Key (Bearer)")
        add(.stepFunCredentialsHint, "在浏览器登录 https://platform.stepfun.com 后，点“重新读取浏览器登录”导入控制台会话（存 Keychain，自动续期）。阶跃的套餐额度只认控制台会话——API Key 只能调模型、读不了额度（已实测确认），所以 API Key 栏对查用量无效，可留空。", "Sign in to https://platform.stepfun.com in a browser, then click “Re-import Browser Sign-in” to capture the console session (stored in Keychain, auto-rotated). StepFun plan quota is console-session only — API keys can call models but cannot read quota (verified), so the API-key field is not needed for usage tracking.")
        add(.stepFunAPIKeyLabel, "API Key（Bearer）", "API Key (Bearer)")
        add(.stepFunManualCookiePlaceholder, "手动 Cookie（可选，从浏览器 DevTools 复制）", "Manual Cookie (optional; copy from browser devtools)")
        add(.senseNovaManualCookiePlaceholder, "手动 Cookie（可选，从浏览器 DevTools 复制）", "Manual Cookie (optional; copy from browser devtools)")

        // Subscription expiry reminders
        add(.reminderHeader, "订阅到期（%d）", "Expiring subscriptions (%d)")
        add(.reminderDaysLeft, "%d 天后到期", "in %d days")
        add(.reminderQuotaLeft, "剩余 %d%%", "%d%% left")
        add(.reminderExpiresToday, "今天到期", "Expires today")
        add(.reminderBodyQuota, "剩余额度 %d%%，抓紧用完", "%d%% quota left — use it before it expires")
        add(.reminderEnabledLabel, "启用到期提醒", "Enable expiry reminders")
        add(.reminderDaysLabel, "提前提醒天数", "Remind within")
        add(.reminderDaysOption, "%d 天", "%d days")
        add(.reminderNotifyLabel, "同时发送系统通知", "Also send a system notification")
        add(.reminderNotifyHint, "每个订阅每天最多通知一次。系统通知只在打包后的 App 中显示；源码直接运行时请以下拉菜单中的「订阅到期」为准。", "Each subscription notifies at most once per day. Notifications only appear in the packaged app; when running from source, use the Expiring section in the menu.")
        add(.reminderRuleHint, "提醒规则：距到期不超过提前天数、且剩余额度 ≥ 50% 时，在下拉菜单显示并提醒抓紧用完；额度基本用完的订阅不再打扰。已接入套餐的到期时间自动读取；手动订阅用于提醒未接入的服务。", "Rule: a subscription shows up here and nags you to use it up when it expires within the lead time and still has ≥50% quota left; nearly exhausted plans stay quiet. Integrated plans contribute their expiry automatically; manual entries cover services TokenBar does not integrate.")
        add(.reminderManualSection, "手动订阅", "Manual subscriptions")
        add(.reminderManualNamePlaceholder, "订阅名称", "Subscription name")
        add(.reminderManualNotePlaceholder, "备注", "Note")
        add(.reminderManualExpiryLabel, "到期日", "Expiry date")
        add(.reminderManualAdd, "添加订阅", "Add subscription")
        add(.reminderManualEmpty, "还没有手动订阅。把 TokenBar 没有接入的订阅（年费服务等）加到这里，到期前会一并提醒。", "No manual subscriptions yet. Add services TokenBar does not integrate (annual plans etc.) to get expiry reminders for them too.")
        add(.reminderManualDelete, "删除该订阅", "Delete this subscription")
        add(.reminderSectionTitle, "提醒", "Reminders")
        add(.reminderManualNamePrompt, "如 OpenCode Go", "e.g. OpenCode Go")
        add(.reminderManualNotePrompt, "选填", "Optional")
        add(.refreshAll, "全部刷新", "Refresh All")
        add(.refreshProviderMenu, "单独刷新", "Refresh One")

        // Display mode display names
        add(.displayIconOnly, "圆环", "Rings")
        add(.displayIconAndPercent, "圆环 + 百分比", "Rings + percent")
        add(.displayPercentOnly, "仅百分比", "Percent only")
        add(.displayLogoOnly, "仅 Logo", "Logo only")
        add(.displayLogoAndPercent, "Logo + 百分比", "Logo + percent")
        add(.displayLogoAndRings, "Logo + 圆环", "Logo + rings")
        add(.menuBarValue, "菜单栏显示", "Menu bar shows")
        add(.displayValuePercent, "剩余百分比", "Remaining percent")
        add(.displayValueBalance, "余额（含货币符号）", "Balance with currency")

        // Refresh interval display names
        add(.interval1m, "1 分钟", "1 minute")
        add(.interval2m, "2 分钟", "2 minutes")
        add(.interval5m, "5 分钟", "5 minutes")
        add(.interval15m, "15 分钟", "15 minutes")
        add(.interval30m, "30 分钟", "30 minutes")

        return t
    }()
}

/// Free function for ergonomic use in views: `Text(L(.refreshNow))`.
func L(_ key: LKey) -> String { L10n.t(key) }
