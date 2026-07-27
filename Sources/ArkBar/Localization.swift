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
    case settings = "menu.settings"
    case quitArkBar = "menu.quitArkBar"
    case updated = "menu.updated"

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

    // Dynamic usage labels and errors
    case productCodingPlan = "product.codingPlan"
    case productAgentPlan = "product.agentPlan"
    case productCodingPlanTeam = "product.codingPlanTeam"
    case productAgentPlanTeam = "product.agentPlanTeam"
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
        add(.settings, "设置…", "Settings…")
        add(.quitArkBar, "退出 ArkBar", "Quit ArkBar")
        add(.updated, "更新于", "Updated")

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

        // Dynamic usage labels and errors
        add(.productCodingPlan, "Coding 套餐", "Coding Plan")
        add(.productAgentPlan, "Agent 套餐", "Agent Plan")
        add(.productCodingPlanTeam, "团队 Coding 套餐", "Coding Plan (Team)")
        add(.productAgentPlanTeam, "团队 Agent 套餐", "Agent Plan (Team)")
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
