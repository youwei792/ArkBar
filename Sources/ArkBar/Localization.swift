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
enum LKey: String {
    // Menu - actions
    case refreshNow = "menu.refreshNow"
    case openArkcliLogin = "menu.openArkcliLogin"
    case openArkConsole = "menu.openArkConsole"
    case openCodeGo = "menu.openCodeGo"
    case settings = "menu.settings"
    case quitArkBar = "menu.quitArkBar"
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
    case settingsDiagnostics = "settings.diagnostics"
    case sectionAppearance = "settings.sectionAppearance"
    case sectionBehavior = "settings.sectionBehavior"
    case sectionConnection = "settings.sectionConnection"
    case sectionActions = "settings.sectionActions"
    case sectionSubscription = "settings.sectionSubscription"
    case status = "settings.status"
    case refreshArk = "settings.refreshArk"
    case refreshOpenCode = "settings.refreshOpenCode"
    case openCodeCookieSource = "settings.openCodeCookieSource"
    case openCodeCookieAutomatic = "settings.openCodeCookieAutomatic"
    case openCodeCookieManual = "settings.openCodeCookieManual"
    case openCodeAutomaticHint = "settings.openCodeAutomaticHint"
    case openCodeManualHint = "settings.openCodeManualHint"
    case openCodeAuthoritativeHint = "settings.openCodeAuthoritativeHint"
    case reimportBrowserSession = "settings.reimportBrowserSession"
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
    case windowSession = "window.session"
    case window5Hour = "window.5hour"
    case windowWeekly = "window.weekly"
    case windowMonthly = "window.monthly"
    case windowRequests = "window.requests"
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
    case errorProbeModels = "error.probeModels"
    case apiKeyNoHeaders = "apiKey.noHeaders"
    case apiKeyNoWindow = "apiKey.noWindow"

    // Display mode display names
    case displayIconOnly = "display.iconOnly"
    case displayIconAndPercent = "display.iconAndPercent"
    case displayPercentOnly = "display.percentOnly"

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
            UserDefaults.standard.set(language.rawValue, forKey: "arkbar.language")
            // Notify menu controller to rebuild.
            NotificationCenter.default.post(name: Self.languageDidChange, object: nil)
        }
    }

    nonisolated static let languageDidChange = Notification.Name("arkbar.languageDidChange")

    private init() {
        let raw = UserDefaults.standard.string(forKey: "arkbar.language") ?? Language.system.rawValue
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
        }
    }

    func windowName(_ label: String) -> String {
        switch label.lowercased() {
        case "session": t(.windowSession)
        case "5h", "5-hour", "five_hour": t(.window5Hour)
        case "weekly", "week": t(.windowWeekly)
        case "monthly", "month": t(.windowMonthly)
        case "requests": t(.windowRequests)
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
        add(.quitArkBar, "退出 ArkBar", "Quit ArkBar")
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
        add(.settingsTitle, "ArkBar 设置", "ArkBar Settings")
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
        add(.settingsDiagnostics, "诊断", "Diagnostics")
        add(.sectionAppearance, "外观", "Appearance")
        add(.sectionBehavior, "行为", "Behavior")
        add(.sectionConnection, "连接", "Connection")
        add(.sectionActions, "操作", "Actions")
        add(.sectionSubscription, "套餐用量", "Subscription usage")
        add(.status, "状态", "Status")
        add(.refreshArk, "刷新 Ark 用量", "Refresh Ark Usage")
        add(.refreshOpenCode, "刷新 OpenCode Go", "Refresh OpenCode Go")
        add(.openCodeCookieSource, "Cookie 来源", "Cookie source")
        add(.openCodeCookieAutomatic, "自动读取浏览器", "Automatic from browser")
        add(.openCodeCookieManual, "手动 Cookie", "Manual Cookie")
        add(.openCodeAutomaticHint, "普通刷新只使用 ArkBar 已缓存的会话，不会弹出密码框。首次使用或登录失效后，请点“重新读取浏览器登录”；只有这个操作可能请求一次钥匙串授权。", "Routine refreshes only use ArkBar's cached session and never show a password prompt. On first use or after sign-in expires, click “Re-import Browser Sign-in”; only that action may request Keychain access once.")
        add(.openCodeManualHint, "仅在自动读取失败时使用。Cookie 会保存在本机钥匙串，不会写入偏好设置或日志。", "Use only when automatic import fails. The Cookie is stored in Keychain, never preferences or logs.")
        add(.openCodeAuthoritativeHint, "圆环只使用 OpenCode Go 网页返回的套餐用量；不会用本地消费记录估算余额。", "Rings use only subscription usage returned by OpenCode Go; local spending history is never used as quota.")
        add(.reimportBrowserSession, "重新读取浏览器登录", "Re-import Browser Session")
        add(.saveCookie, "保存 Cookie", "Save Cookie")
        add(.lastSuccessfulUpdate, "上次成功更新", "Last successful update")
        add(.noSuccessfulUpdate, "尚未成功更新", "No successful update yet")
        add(.browserSession, "浏览器会话", "Browser session")
        add(.manualCookie, "手动 Cookie", "Manual Cookie")
        add(.openCodeBrowserAccessTitle, "允许读取浏览器登录", "Allow Browser Sign-in Access")
        add(.openCodeBrowserAccessMessage, "ArkBar 将请求 macOS 钥匙串中的“%@”，用于解密 opencode.ai 登录 Cookie。ArkBar 只保留认证 Cookie，不读取浏览历史。", "ArkBar will request “%@” from macOS Keychain to decrypt the opencode.ai sign-in Cookie. ArkBar keeps only the authentication Cookie and does not read browsing history.")
        add(.continueAction, "继续", "Continue")
        add(.settingsAppVersion, "ArkBar 版本", "ArkBar version")
        add(.settingsCurrentSource, "当前来源", "Current source")
        add(.settingsPreviousData, "正在显示上次成功数据", "Showing the last successful data")
        add(.settingsNoUsage, "暂无可显示的套餐用量", "No subscription usage to display")

        // Dynamic usage labels and errors
        add(.productCodingPlan, "Coding 套餐", "Coding Plan")
        add(.productAgentPlan, "Agent 套餐", "Agent Plan")
        add(.productCodingPlanTeam, "团队 Coding 套餐", "Coding Plan (Team)")
        add(.productAgentPlanTeam, "团队 Agent 套餐", "Agent Plan (Team)")
        add(.productOpenCodeGo, "OpenCode Go", "OpenCode Go")
        add(.windowSession, "会话", "Session")
        add(.window5Hour, "5 小时", "5-hour")
        add(.windowWeekly, "每周", "Weekly")
        add(.windowMonthly, "每月", "Monthly")
        add(.windowRequests, "请求数", "Requests")
        add(.errorArkcliNotFound, "未找到 arkcli。请安装后执行 `arkcli auth login volc-sso`。", "arkcli was not found. Install it, then run `arkcli auth login volc-sso`.")
        add(.errorArkcliNotAuthenticated, "arkcli 尚未登录。请执行 `arkcli auth login volc-sso` 后刷新。", "arkcli is not signed in. Run `arkcli auth login volc-sso`, then refresh.")
        add(.errorArkcliTimedOut, "arkcli 查询超时。请检查登录状态后重试。", "arkcli usage timed out. Check authentication and try again.")
        add(.errorArkcliFailed, "arkcli 查询失败 (%d)：%@", "arkcli usage failed (%d): %@")
        add(.errorMissingCredentials, "缺少火山引擎凭证。请设置 AK/SK，或登录 arkcli。", "Missing Volcengine credentials. Set AK/SK or sign in to arkcli.")
        add(.errorNetwork, "网络错误：%@", "Network error: %@")
        add(.errorAPI, "方舟 API 错误 (%d)：%@", "Ark API error (%d): %@")
        add(.errorParse, "无法解析响应：%@", "Failed to parse response: %@")
        add(.errorNoPlan, "未找到有效的 Coding 或 Agent 套餐用量：%@", "No active Coding or Agent Plan usage: %@")
        add(.errorOpenCodeCookieMissing, "未配置有效的 OpenCode Go 手动 Cookie。", "No valid manual OpenCode Go Cookie is configured.")
        add(.errorOpenCodeCookieInvalid, "OpenCode Go 登录已失效。请重新登录浏览器，或更新手动 Cookie。", "The OpenCode Go sign-in expired. Sign in again in the browser or update the manual Cookie.")
        add(.errorOpenCodeBrowserSessionMissing, "没有在浏览器中找到 opencode.ai 登录会话。请先在浏览器登录，或改用手动 Cookie。", "No opencode.ai browser session was found. Sign in in a browser or use a manual Cookie.")
        add(.errorOpenCodeBrowserAuthorizationRequired, "ArkBar 尚未缓存浏览器登录，或原会话已失效。请在 OpenCode Go 设置中点“重新读取浏览器登录”；后台刷新不会主动弹出密码框。", "ArkBar has no cached browser sign-in, or the previous session expired. Click “Re-import Browser Sign-in” in OpenCode Go settings; background refreshes will not show a password prompt.")
        add(.errorProbeModels, "所有探测模型均不可用", "All probe models failed")
        add(.apiKeyNoHeaders, "API Key 有效，但响应未返回请求限额头。", "API key is valid, but no request-limit headers were returned.")
        add(.apiKeyNoWindow, "API Key 有效，但未返回用量窗口。", "API key is valid, but no usage window was returned.")

        // Display mode display names
        add(.displayIconOnly, "仅图标", "Icon only")
        add(.displayIconAndPercent, "图标 + 百分比", "Icon + percent")
        add(.displayPercentOnly, "仅百分比", "Percent only")

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
