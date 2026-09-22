import AppKit
import SwiftUI

/// CodexBar-style settings window: a stable sidebar and one grouped form per
/// concern. The UI lives in the SwiftUI `Settings` scene (macOS's own settings
/// window), so macOS may open it on its own — see `SettingsSceneHost`.
@MainActor
enum PreferencesRouting {
    /// Pane the window should select the next time its view appears. Needed
    /// because a posted notification can fire before the scene's view
    /// subscribes (the window may not even exist yet).
    static var pendingPane: PreferencesPane?
    /// Posted to switch the pane of an already-visible window. The `object` is
    /// the `PreferencesPane` raw value (e.g. "reminder").
    static let openPane = Notification.Name("tokenbar.openPane")
}

/// Hosts the real settings UI inside the SwiftUI `Settings` scene. macOS opens
/// that scene on ⌘, and whenever a running menu-bar app is reopened, before
/// any delegate callback — an empty placeholder is what used to show up as a
/// blank "TokenBar Settings" window.
struct SettingsSceneHost: View {
    @ObservedObject var environment: AppEnvironment

    var body: some View {
        Group {
            if let store = environment.store {
                PreferencesRootView(settings: .shared, store: store)
            } else {
                // The scene can be evaluated before applicationDidFinishLaunching
                // has built the store; keep the window sensibly sized until then.
                Color.clear.frame(width: 760, height: 520)
            }
        }
        .onAppear(perform: Self.localizeWindowTitle)
        .onReceive(NotificationCenter.default.publisher(for: L10n.languageDidChange)) { _ in
            Self.localizeWindowTitle()
        }
    }

    /// The Settings scene titles its window from the *system* language
    /// ("TokenBar Settings"), which clashes with the in-app language setting;
    /// retitle it to match the app's own string table.
    private static func localizeWindowTitle() {
        for window in NSApp.windows {
            let title = window.title
            if title.contains("Settings") || title.contains("设置") {
                window.title = L(.settingsTitle)
            }
        }
    }
}

enum PreferencesPane: String, CaseIterable, Identifiable {
    case general
    case ark
    case openCode
    case deepseek
    case nebula
    case zai
    case kimi
    case grokPool
    case longcat
    case aliyun
    case stepfun
    case sensenova
    case reminder
    case diagnostics

    var id: Self { self }

    var title: String {
        switch self {
        case .general: L(.settingsGeneral)
        case .ark: L(.settingsArk)
        case .openCode: L(.settingsOpenCode)
        case .deepseek: L(.settingsDeepSeek)
        case .nebula: L(.settingsNebula)
        case .zai: L(.settingsZai)
        case .kimi: L(.settingsKimi)
        case .grokPool: L(.settingsGrokPool)
        case .longcat: L(.settingsLongCat)
        case .aliyun: L(.settingsAliyun)
        case .stepfun: L(.settingsStepFun)
        case .sensenova: L(.settingsSenseNova)
        case .reminder: L(.settingsReminder)
        case .diagnostics: L(.settingsDiagnostics)
        }
    }

    var symbol: String {
        switch self {
        case .general: "gearshape"
        case .ark: "chart.donut"
        case .openCode: "terminal"
        case .deepseek: "fish"
        case .nebula: "cloud"
        case .zai: "sparkles"
        case .kimi: "sparkles"
        case .grokPool: "bolt"
        case .longcat: "cat"
        case .aliyun: "cloud.fill"
        case .stepfun: "stairs"
        case .sensenova: "sparkle.magnifyingglass"
        case .reminder: "bell"
        case .diagnostics: "stethoscope"
        }
    }

    /// Provider panes show their brand logo in the sidebar instead of an SF
    /// Symbol, matching the switcher buttons in the menu bar.
    var providerTab: ProviderTab? {
        switch self {
        case .ark: .ark
        case .openCode: .opencode
        case .deepseek: .deepseek
        case .nebula: .nebula
        case .zai: .zai
        case .kimi: .kimi
        case .grokPool: .grokPool
        case .longcat: .longcat
        case .aliyun: .aliyun
        case .stepfun: .stepfun
        case .sensenova: .sensenova
        case .general, .reminder, .diagnostics: nil
        }
    }
}

struct PreferencesRootView: View {
    @ObservedObject var settings: AppSettings
    @ObservedObject var store: UsageStore
    @ObservedObject private var l10n = L10n.shared
    @State private var selection: PreferencesPane? = nil

    var body: some View {
        HStack(spacing: 0) {
            sidebar
                .frame(width: 218)
                .background(.regularMaterial)

            Divider()

            detail
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Color(nsColor: .windowBackgroundColor))
        }
            .environment(\.locale, l10n.locale)
            .frame(minWidth: 720, minHeight: 500)
            .onAppear {
                if let pending = PreferencesRouting.pendingPane {
                    selection = pending
                    PreferencesRouting.pendingPane = nil
                }
            }
            .onReceive(NotificationCenter.default.publisher(
                for: PreferencesRouting.openPane))
            { notification in
                if let raw = notification.object as? String,
                   let pane = PreferencesPane(rawValue: raw)
                {
                    selection = pane
                }
            }
    }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(L(.settingsTitle))
                .font(.system(size: 16, weight: .semibold))
                .padding(.horizontal, 18)
                .padding(.top, 44)
                .padding(.bottom, 12)

            List(selection: $selection) {
                ForEach(PreferencesPane.allCases) { pane in
                    if let tab = pane.providerTab, let logo = ProviderLogo.image(for: tab) {
                        Label {
                            Text(pane.title)
                        } icon: {
                            Image(nsImage: logo)
                                .resizable()
                                .scaledToFit()
                                .frame(width: 14, height: 14)
                        }
                        .tag(Optional(pane))
                    } else {
                        Label(pane.title, systemImage: pane.symbol)
                            .tag(Optional(pane))
                    }
                }
            }
            .listStyle(.sidebar)
            .scrollContentBackground(.hidden)

            Text(versionText)
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .padding(.horizontal, 18)
                .padding(.bottom, 14)
        }
    }

    @ViewBuilder
    private var detail: some View {
        switch selection ?? .general {
        case .general:
            GeneralPreferencesPane(settings: settings, store: store)
        case .ark:
            ArkPreferencesPane(settings: settings, store: store)
        case .openCode:
            OpenCodePreferencesPane(settings: settings, store: store)
        case .deepseek:
            DeepSeekPreferencesPane(settings: settings, store: store)
        case .nebula:
            NebulaPreferencesPane(settings: settings, store: store)
        case .zai:
            ZaiPreferencesPane(settings: settings, store: store)
        case .kimi:
            KimiPreferencesPane(settings: settings, store: store)
        case .grokPool:
            GrokPoolPreferencesPane(settings: settings, store: store)
        case .longcat:
            LongCatPreferencesPane(settings: settings, store: store)
        case .aliyun:
            AliyunPreferencesPane(settings: settings, store: store)
        case .stepfun:
            StepFunPreferencesPane(settings: settings, store: store)
        case .sensenova:
            SenseNovaPreferencesPane(settings: settings, store: store)
        case .reminder:
            ReminderPreferencesPane(settings: settings)
        case .diagnostics:
            DiagnosticsPreferencesPane()
        }
    }

    private var versionText: String {
        let version = Bundle.main.object(
            forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev"
        return "\(L(.settingsAppVersion)) \(version)"
    }
}

private struct PreferencesPaneContainer<Content: View>: View {
    let title: String
    var symbol: String? = nil
    var subtitle: String? = nil
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .center, spacing: 12) {
                if let symbol {
                    ZStack {
                        RoundedRectangle(cornerRadius: 9, style: .continuous)
                            .fill(Color.secondary.opacity(0.12))
                            .frame(width: 36, height: 36)
                        Image(systemName: symbol)
                            .font(.system(size: 16, weight: .semibold))
                            .foregroundStyle(.secondary)
                    }
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.system(size: 17, weight: .semibold))
                    if let subtitle {
                        Text(subtitle)
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 24)
            .padding(.top, 30)
            .padding(.bottom, 12)

            Divider()

            content
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}

private struct GeneralPreferencesPane: View {
    @ObservedObject var settings: AppSettings
    @ObservedObject var store: UsageStore

    var body: some View {
        PreferencesPaneContainer(title: L(.settingsGeneral), symbol: "gearshape") {
            Form {
                Section(L(.sectionAppearance)) {
                    Picker(L(.displayMode), selection: $settings.displayMode) {
                        ForEach(AppSettings.DisplayMode.allCases, id: \.self) { mode in
                            Text(mode.displayName).tag(mode)
                        }
                    }
                    Picker(L(.language), selection: $settings.language) {
                        ForEach(Language.allCases, id: \.self) { language in
                            Text(language.displayName).tag(language)
                        }
                    }
                    Toggle(L(.showSummary), isOn: $settings.showSummary)
                        .toggleStyle(.switch)
                }

                Section(L(.sectionRefresh)) {
                    Picker(L(.interval), selection: $settings.refreshInterval) {
                        ForEach(AppSettings.RefreshInterval.allCases, id: \.self) { interval in
                            Text(interval.displayName).tag(interval)
                        }
                    }
                    .pickerStyle(.menu)
                    Toggle(L(.refreshWhenMenuOpens), isOn: $settings.refreshWhenMenuOpens)
                        .toggleStyle(.switch)
                }

                Section(L(.sectionActions)) {
                    // Five side-by-side buttons truncated every provider name
                    // ("刷新 A…"); a single full-width action plus a menu of
                    // per-provider refreshes keeps every label readable.
                    HStack(spacing: 8) {
                        Button {
                            store.refreshAll()
                        } label: {
                            Label(L(.refreshAll), systemImage: "arrow.clockwise")
                        }
                        .buttonStyle(.bordered)

                        Menu(L(.refreshProviderMenu)) {
                            ForEach(settings.visibleTabs, id: \.self) { tab in
                                Button(tab.displayName) {
                                    store.refresh(tab: tab)
                                }
                            }
                        }
                        .fixedSize()
                    }
                }
            }
            .formStyle(.grouped)
        }
    }
}

private struct ArkPreferencesPane: View {
    @ObservedObject var settings: AppSettings
    @ObservedObject var store: UsageStore
    @State private var accessKeyField: String
    @State private var secretKeyField: String

    init(settings: AppSettings, store: UsageStore) {
        self.settings = settings
        self.store = store
        _accessKeyField = State(initialValue: settings.arkAccessKeyID)
        _secretKeyField = State(initialValue: settings.arkSecretAccessKey)
    }

    var body: some View {
        PreferencesPaneContainer(title: L(.settingsArk), symbol: "chart.donut", subtitle: L(.settingsArkSubtitle)) {
            Form {
                Section(L(.sectionDisplay)) {
                    Toggle(L(.showProvider), isOn: Binding(
                        get: { settings.showArk },
                        set: { settings.setVisible(.ark, $0) }))
                        .toggleStyle(.switch)
                }

                Section(L(.sectionConnection)) {
                    Picker(L(.source), selection: $settings.sourceMode) {
                        ForEach(AppSettings.SourceMode.allCases, id: \.self) { mode in
                            Text(sourceName(mode)).tag(mode)
                        }
                    }

                    SecureField(L(.arkAccessKeyIDLabel), text: $accessKeyField)
                        .onSubmit(saveAccessKeyID)
                    Button(L(.saveCredential), action: saveAccessKeyID)

                    SecureField(L(.arkSecretAccessKeyLabel), text: $secretKeyField)
                        .onSubmit(saveSecretAccessKey)
                    Button(L(.saveCredential), action: saveSecretAccessKey)

                    Label(L(.arkAKSKHint), systemImage: "key")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .textSelection(.enabled)

                    ProviderStatusRows(
                        status: store.status(for: .ark),
                        isRefreshing: store.isRefreshing(for: .ark),
                        lastUpdatedAt: store.lastUpdatedAt(for: .ark))
                }

                Section(L(.sectionActions)) {
                    Button {
                        store.refresh(tab: .ark)
                    } label: {
                        Label(
                            store.isRefreshing(for: .ark) ? L(.refreshing) : L(.refreshArk),
                            systemImage: "arrow.clockwise")
                    }

                    Button {
                        runTerminal("arkcli auth login volc-sso")
                    } label: {
                        Label(L(.openArkcliLogin), systemImage: "terminal")
                    }

                    Button {
                        openArkConsole()
                    } label: {
                        Label(L(.openArkConsole), systemImage: "safari")
                    }
                }
            }
            .formStyle(.grouped)
        }
    }

    private func sourceName(_ mode: AppSettings.SourceMode) -> String {
        switch mode {
        case .auto: L(.sourceAuto)
        case .cli: L(.sourceCli)
        case .api: L(.sourceApi)
        }
    }

    private func saveAccessKeyID() {
        settings.setArkAccessKeyID(accessKeyField)
    }

    private func saveSecretAccessKey() {
        settings.setArkSecretAccessKey(secretKeyField)
    }
}

private struct OpenCodePreferencesPane: View {
    @ObservedObject var settings: AppSettings
    @ObservedObject var store: UsageStore
    @State private var manualCookie: String

    init(settings: AppSettings, store: UsageStore) {
        self.settings = settings
        self.store = store
        _manualCookie = State(initialValue: settings.opencodeCookie)
    }

    var body: some View {
        PreferencesPaneContainer(title: L(.settingsOpenCode), symbol: "terminal", subtitle: L(.settingsOpenCodeSubtitle)) {
            Form {
                Section(L(.sectionDisplay)) {
                    Toggle(L(.showProvider), isOn: Binding(
                        get: { settings.showOpenCode },
                        set: { settings.setVisible(.opencode, $0) }))
                        .toggleStyle(.switch)
                }

                Section(L(.sectionConnection)) {
                    Picker(L(.openCodeCookieSource), selection: $settings.opencodeCookieSource) {
                        Text(L(.openCodeCookieAutomatic))
                            .tag(AppSettings.OpenCodeCookieSource.automatic)
                        Text(L(.openCodeCookieManual))
                            .tag(AppSettings.OpenCodeCookieSource.manual)
                    }

                    Text(settings.opencodeCookieSource == .automatic
                         ? L(.openCodeAutomaticHint)
                         : L(.openCodeManualHint))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)

                    if settings.opencodeCookieSource == .manual {
                        SecureField(L(.opencodeCookiePlaceholder), text: $manualCookie)
                            .onSubmit(saveManualCookie)
                        Button(L(.saveCookie), action: saveManualCookie)
                    } else {
                        Button {
                            store.reimportOpenCodeBrowserSession()
                        } label: {
                            Label(
                                store.isRefreshing(for: .opencode)
                                    ? L(.refreshingStatus)
                                    : L(.reimportBrowserSession),
                                systemImage: "person.crop.circle.badge.arrow.trianglehead.counterclockwise")
                        }
                        .disabled(store.isRefreshing(for: .opencode))
                    }

                    TextField(
                        L(.opencodeWorkspaceIDPlaceholder),
                        text: $settings.opencodeWorkspaceID,
                        prompt: Text(L(.opencodeWorkspaceIDPlaceholder)))
                    Text(L(.opencodeWorkspaceID))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Section(L(.sectionSubscription)) {
                    ProviderStatusRows(
                        status: store.status(for: .opencode),
                        isRefreshing: store.isRefreshing(for: .opencode),
                        lastUpdatedAt: store.lastUpdatedAt(for: .opencode))

                    Label(L(.openCodeAuthoritativeHint), systemImage: "checkmark.shield")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Section(L(.sectionActions)) {
                    Button {
                        store.refresh(tab: .opencode)
                    } label: {
                        Label(
                            store.isRefreshing(for: .opencode) ? L(.refreshing) : L(.refreshOpenCode),
                            systemImage: "arrow.clockwise")
                    }
                    Button {
                        NSWorkspace.shared.open(URL(string: "https://opencode.ai")!)
                    } label: {
                        Label(L(.openCodeGo), systemImage: "safari")
                    }
                }
            }
            .formStyle(.grouped)
        }
    }

    private func saveManualCookie() {
        settings.setOpenCodeCookie(manualCookie)
    }
}

private struct DeepSeekPreferencesPane: View {
    @ObservedObject var settings: AppSettings
    @ObservedObject var store: UsageStore
    @State private var apiKeyField: String
    @State private var platformTokenField: String

    init(settings: AppSettings, store: UsageStore) {
        self.settings = settings
        self.store = store
        _apiKeyField = State(initialValue: settings.deepseekApiKey)
        _platformTokenField = State(initialValue: settings.deepseekPlatformToken)
    }

    var body: some View {
        PreferencesPaneContainer(title: L(.settingsDeepSeek), symbol: "fish", subtitle: L(.settingsDeepSeekSubtitle)) {
            Form {
                Section(L(.sectionDisplay)) {
                    Toggle(L(.showProvider), isOn: Binding(
                        get: { settings.showDeepSeek },
                        set: { settings.setVisible(.deepseek, $0) }))
                        .toggleStyle(.switch)
                    Picker(L(.menuBarValue), selection: $settings.deepseekValueDisplay) {
                        ForEach(AppSettings.BalanceDisplay.allCases, id: \.self) { value in
                            Text(value.displayName).tag(value)
                        }
                    }
                    .pickerStyle(.radioGroup)
                }

                Section(L(.sectionConnection)) {
                    SecureField(L(.deepseekAPIKeyLabel), text: $apiKeyField)
                        .onSubmit(saveAPIKey)
                    Button(L(.saveCredential), action: saveAPIKey)

                    SecureField(L(.deepseekPlatformTokenLabel), text: $platformTokenField)
                        .onSubmit(savePlatformToken)
                    Button(L(.saveCredential), action: savePlatformToken)

                    if let source = DeepSeekBrowserSession.cachedSourceLabel() {
                        Label(String(format: L(.deepseekBrowserSession), source), systemImage: "globe")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                            .textSelection(.enabled)
                    }

                    ProviderStatusRows(
                        status: store.status(for: .deepseek),
                        isRefreshing: store.isRefreshing(for: .deepseek),
                        lastUpdatedAt: store.lastUpdatedAt(for: .deepseek))

                    Label(L(.deepseekCredentialsHint), systemImage: "key")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .textSelection(.enabled)

                    Label(L(.deepseekPlatformHint), systemImage: "chart.bar.doc.horizontal")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Section(L(.sectionActions)) {
                    Button {
                        store.refresh(tab: .deepseek)
                    } label: {
                        Label(
                            store.isRefreshing(for: .deepseek) ? L(.refreshing) : L(.refreshDeepSeek),
                            systemImage: "arrow.clockwise")
                    }
                    Button {
                        NSWorkspace.shared.open(URL(string: "https://platform.deepseek.com")!)
                    } label: {
                        Label(L(.openDeepSeekPlatform), systemImage: "safari")
                    }
                }
            }
            .formStyle(.grouped)
        }
    }

    private func saveAPIKey() {
        settings.setDeepSeekAPIKey(apiKeyField)
    }

    private func savePlatformToken() {
        settings.setDeepSeekPlatformToken(platformTokenField)
    }
}

private struct NebulaPreferencesPane: View {
    @ObservedObject var settings: AppSettings
    @ObservedObject var store: UsageStore
    @State private var apiKeyField: String

    init(settings: AppSettings, store: UsageStore) {
        self.settings = settings
        self.store = store
        _apiKeyField = State(initialValue: settings.nebulaAPIKey)
    }

    var body: some View {
        PreferencesPaneContainer(title: L(.settingsNebula), symbol: "cloud", subtitle: L(.settingsNebulaSubtitle)) {
            Form {
                Section(L(.sectionDisplay)) {
                    Toggle(L(.showProvider), isOn: Binding(
                        get: { settings.showNebula },
                        set: { settings.setVisible(.nebula, $0) }))
                        .toggleStyle(.switch)
                    Picker(L(.menuBarValue), selection: $settings.nebulaValueDisplay) {
                        ForEach(AppSettings.BalanceDisplay.allCases, id: \.self) { value in
                            Text(value.displayName).tag(value)
                        }
                    }
                    .pickerStyle(.radioGroup)
                }

                Section(L(.sectionConnection)) {
                    TextField(L(.nebulaBaseURLLabel), text: $settings.nebulaBaseURL,
                              prompt: Text(NebulaProvider.defaultBaseURL))
                    Text(L(.nebulaBaseURLHint))
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    SecureField(L(.nebulaAPIKeyLabel), text: $apiKeyField)
                        .onSubmit(saveAPIKey)
                    Button(L(.saveCredential), action: saveAPIKey)

                    if let source = NebulaBrowserSession.cachedSourceLabel() {
                        Label(String(format: L(.nebulaBrowserSession), source), systemImage: "globe")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                            .textSelection(.enabled)
                    }

                    ProviderStatusRows(
                        status: store.status(for: .nebula),
                        isRefreshing: store.isRefreshing(for: .nebula),
                        lastUpdatedAt: store.lastUpdatedAt(for: .nebula))

                    Label(L(.nebulaCredentialsHint), systemImage: "key")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .textSelection(.enabled)

                    Label(L(.nebulaBrowserHint), systemImage: "safari")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Section(L(.sectionActions)) {
                    Button {
                        store.reimportNebulaBrowserSession()
                    } label: {
                        Label(
                            store.isRefreshing(for: .nebula)
                                ? L(.refreshingStatus)
                                : L(.reimportNebulaBrowserSession),
                            systemImage: "person.crop.circle.badge.arrow.trianglehead.counterclockwise")
                    }
                    .disabled(store.isRefreshing(for: .nebula))

                    Button {
                        store.refresh(tab: .nebula)
                    } label: {
                        Label(
                            store.isRefreshing(for: .nebula) ? L(.refreshing) : L(.refreshNebula),
                            systemImage: "arrow.clockwise")
                    }

                    Button {
                        NSWorkspace.shared.open(URL(string: "https://apinebula.ai/zh/console/topup")!)
                    } label: {
                        Label(L(.openNebulaConsole), systemImage: "safari")
                    }
                }
            }
            .formStyle(.grouped)
        }
    }

    private func saveAPIKey() {
        settings.setNebulaAPIKey(apiKeyField)
    }
}

private struct ZaiPreferencesPane: View {
    @ObservedObject var settings: AppSettings
    @ObservedObject var store: UsageStore
    @State private var apiKeyField: String

    init(settings: AppSettings, store: UsageStore) {
        self.settings = settings
        self.store = store
        _apiKeyField = State(initialValue: settings.zaiAPIKey)
    }

    var body: some View {
        PreferencesPaneContainer(title: L(.settingsZai), symbol: "sparkles", subtitle: L(.settingsZaiSubtitle)) {
            Form {
                Section(L(.sectionDisplay)) {
                    Toggle(L(.showProvider), isOn: Binding(
                        get: { settings.showZai },
                        set: { settings.setVisible(.zai, $0) }))
                        .toggleStyle(.switch)
                }

                Section(L(.sectionConnection)) {
                    Picker(L(.zaiRegionLabel), selection: $settings.zaiRegion) {
                        ForEach(ZaiAPIRegion.allCases, id: \.self) { region in
                            Text(region.displayName).tag(region)
                        }
                    }

                    SecureField(L(.zaiAPIKeyLabel), text: $apiKeyField)
                        .onSubmit(saveAPIKey)
                    Button(L(.saveCredential), action: saveAPIKey)

                    ProviderStatusRows(
                        status: store.status(for: .zai),
                        isRefreshing: store.isRefreshing(for: .zai),
                        lastUpdatedAt: store.lastUpdatedAt(for: .zai))

                    Label(L(.zaiCredentialsHint), systemImage: "key")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .textSelection(.enabled)
                }

                Section(L(.sectionActions)) {
                    Button {
                        store.refresh(tab: .zai)
                    } label: {
                        Label(
                            store.isRefreshing(for: .zai) ? L(.refreshing) : L(.refreshZai),
                            systemImage: "arrow.clockwise")
                    }
                    Button {
                        NSWorkspace.shared.open(settings.zaiRegion.dashboardURL)
                    } label: {
                        Label(L(.openZaiConsole), systemImage: "safari")
                    }
                }
            }
            .formStyle(.grouped)
        }
    }

    private func saveAPIKey() {
        settings.setZaiAPIKey(apiKeyField)
    }
}

private struct GrokPoolPreferencesPane: View {
    @ObservedObject var settings: AppSettings
    @ObservedObject var store: UsageStore
    @State private var usernameField: String
    @State private var passwordField: String

    init(settings: AppSettings, store: UsageStore) {
        self.settings = settings
        self.store = store
        _usernameField = State(initialValue: settings.grokPoolUsername)
        _passwordField = State(initialValue: settings.grokPoolPassword)
    }

    var body: some View {
        PreferencesPaneContainer(title: L(.settingsGrokPool), symbol: "bolt", subtitle: L(.settingsGrokPoolSubtitle)) {
            Form {
                Section(L(.sectionDisplay)) {
                    Toggle(L(.showProvider), isOn: Binding(
                        get: { settings.showGrokPool },
                        set: { settings.setVisible(.grokPool, $0) }))
                        .toggleStyle(.switch)
                    Picker(L(.menuBarValue), selection: $settings.grokPoolValueDisplay) {
                        Text(L(.grokPoolValuePercent)).tag(AppSettings.BalanceDisplay.percent)
                        Text(L(.grokPoolValueCost)).tag(AppSettings.BalanceDisplay.balance)
                    }
                    .pickerStyle(.radioGroup)
                }

                Section(L(.sectionConnection)) {
                    TextField(L(.grokPoolBaseURLLabel), text: $settings.grokPoolBaseURL,
                              prompt: Text(GrokPoolProvider.defaultBaseURL))
                    Text(L(.grokPoolBaseURLHint))
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    TextField(L(.grokPoolUsernameLabel), text: $usernameField)
                        .onSubmit(saveUsername)
                    SecureField(L(.grokPoolPasswordLabel), text: $passwordField)
                        .onSubmit(savePassword)
                    Button(L(.saveCredential), action: saveCredentials)

                    ProviderStatusRows(
                        status: store.status(for: .grokPool),
                        isRefreshing: store.isRefreshing(for: .grokPool),
                        lastUpdatedAt: store.lastUpdatedAt(for: .grokPool))

                    Label(L(.grokPoolCredentialsHint), systemImage: "key")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .textSelection(.enabled)
                }

                Section(L(.sectionActions)) {
                    Button {
                        store.refresh(tab: .grokPool)
                    } label: {
                        Label(
                            store.isRefreshing(for: .grokPool) ? L(.refreshing) : L(.refreshGrokPool),
                            systemImage: "arrow.clockwise")
                    }

                    Button {
                        NSWorkspace.shared.open(URL(string: "https://grok.axonlume.com/console")!)
                    } label: {
                        Label(L(.openGrokPoolConsole), systemImage: "safari")
                    }
                }
            }
            .formStyle(.grouped)
        }
    }

    private func saveCredentials() {
        settings.setGrokPoolUsername(usernameField)
        settings.setGrokPoolPassword(passwordField)
    }

    private func saveUsername() {
        settings.setGrokPoolUsername(usernameField)
    }

    private func savePassword() {
        settings.setGrokPoolPassword(passwordField)
    }
}

private struct LongCatPreferencesPane: View {
    @ObservedObject var settings: AppSettings
    @ObservedObject var store: UsageStore
    @State private var manualCookie: String

    init(settings: AppSettings, store: UsageStore) {
        self.settings = settings
        self.store = store
        _manualCookie = State(initialValue: settings.longcatCookie)
    }

    var body: some View {
        PreferencesPaneContainer(title: L(.settingsLongCat), symbol: "cat", subtitle: L(.settingsLongCatSubtitle)) {
            Form {
                Section(L(.sectionDisplay)) {
                    Toggle(L(.showProvider), isOn: Binding(
                        get: { settings.showLongCat },
                        set: { settings.setVisible(.longcat, $0) }))
                        .toggleStyle(.switch)
                }

                Section(L(.sectionConnection)) {
                    Picker(L(.longCatCookieSource), selection: $settings.longcatCookieSource) {
                        Text(L(.longCatCookieAutomatic))
                            .tag(AppSettings.LongCatCookieSource.automatic)
                        Text(L(.longCatCookieManual))
                            .tag(AppSettings.LongCatCookieSource.manual)
                    }

                    Text(settings.longcatCookieSource == .automatic
                         ? L(.longCatAutomaticHint)
                         : L(.longCatManualHint))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)

                    if settings.longcatCookieSource == .manual {
                        SecureField(L(.longCatCookiePlaceholder), text: $manualCookie)
                            .onSubmit(saveManualCookie)
                        Button(L(.saveCookie), action: saveManualCookie)
                    } else {
                        Button {
                            store.reimportLongCatBrowserSession()
                        } label: {
                            Label(
                                store.isRefreshing(for: .longcat)
                                    ? L(.refreshingStatus)
                                    : L(.reimportLongCatBrowserSession),
                                systemImage: "person.crop.circle.badge.arrow.trianglehead.counterclockwise")
                        }
                        .disabled(store.isRefreshing(for: .longcat))
                    }

                    if let source = LongCatBrowserSession.cachedSourceLabel() {
                        Label(String(format: L(.longCatBrowserSession), source), systemImage: "globe")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                            .textSelection(.enabled)
                    }

                    ProviderStatusRows(
                        status: store.status(for: .longcat),
                        isRefreshing: store.isRefreshing(for: .longcat),
                        lastUpdatedAt: store.lastUpdatedAt(for: .longcat))

                    Label(L(.longCatCredentialsHint), systemImage: "key")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .textSelection(.enabled)
                }

                Section(L(.sectionActions)) {
                    Button {
                        store.refresh(tab: .longcat)
                    } label: {
                        Label(
                            store.isRefreshing(for: .longcat) ? L(.refreshing) : L(.refreshLongCat),
                            systemImage: "arrow.clockwise")
                    }
                    Button {
                        NSWorkspace.shared.open(URL(string: "https://longcat.chat/platform/usage")!)
                    } label: {
                        Label(L(.openLongCatConsole), systemImage: "safari")
                    }
                }
            }
            .formStyle(.grouped)
        }
    }

    private func saveManualCookie() {
        settings.setLongCatCookie(manualCookie)
    }
}

private struct KimiPreferencesPane: View {
    @ObservedObject var settings: AppSettings
    @ObservedObject var store: UsageStore
    @State private var apiKeyField: String
    @State private var webSessionInvalid = false

    init(settings: AppSettings, store: UsageStore) {
        self.settings = settings
        self.store = store
        _apiKeyField = State(initialValue: settings.kimiAPIKey)
    }

    var body: some View {
        PreferencesPaneContainer(title: L(.settingsKimi), symbol: "sparkles", subtitle: L(.settingsKimiSubtitle)) {
            Form {
                Section(L(.sectionDisplay)) {
                    Toggle(L(.showProvider), isOn: Binding(
                        get: { settings.showKimi },
                        set: { settings.setVisible(.kimi, $0) }))
                        .toggleStyle(.switch)
                }

                Section(L(.sectionConnection)) {
                    SecureField(L(.kimiAPIKeyLabel), text: $apiKeyField)
                        .onSubmit(saveAPIKey)
                    Button(L(.saveCredential), action: saveAPIKey)

                    if let source = KimiBrowserSession.cachedSourceLabel() {
                        Label(String(format: L(.kimiBrowserSession), source), systemImage: "globe")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                            .textSelection(.enabled)
                    }

                    if webSessionInvalid {
                        Label(L(.kimiWebSessionInvalidHint), systemImage: "exclamationmark.triangle")
                            .font(.caption)
                            .foregroundStyle(.orange)
                            .fixedSize(horizontal: false, vertical: true)
                            .textSelection(.enabled)
                    }

                    ProviderStatusRows(
                        status: store.status(for: .kimi),
                        isRefreshing: store.isRefreshing(for: .kimi),
                        lastUpdatedAt: store.lastUpdatedAt(for: .kimi))

                    Label(L(.kimiCredentialsHint), systemImage: "key")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .textSelection(.enabled)

                    Label(L(.kimiBrowserHint), systemImage: "safari")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Section(L(.sectionActions)) {
                    Button {
                        store.reimportKimiBrowserSession()
                        refreshWebSessionFlag()
                    } label: {
                        Label(
                            store.isRefreshing(for: .kimi)
                                ? L(.refreshingStatus)
                                : L(.reimportKimiBrowserSession),
                            systemImage: "person.crop.circle.badge.arrow.trianglehead.counterclockwise")
                    }
                    .disabled(store.isRefreshing(for: .kimi))

                    Button {
                        store.refresh(tab: .kimi)
                        refreshWebSessionFlag()
                    } label: {
                        Label(
                            store.isRefreshing(for: .kimi) ? L(.refreshing) : L(.refreshKimi),
                            systemImage: "arrow.clockwise")
                    }
                    Button {
                        NSWorkspace.shared.open(URL(string: "https://www.kimi.com/code/console")!)
                    } label: {
                        Label(L(.openKimiConsole), systemImage: "safari")
                    }
                }
            }
            .formStyle(.grouped)
        }
        .onAppear(perform: refreshWebSessionFlag)
        .onReceive(store.objectWillChange) { _ in
            refreshWebSessionFlag()
        }
    }

    private func refreshWebSessionFlag() {
        webSessionInvalid = KimiProvider.webSessionInvalid
    }

    private func saveAPIKey() {
        settings.setKimiAPIKey(apiKeyField)
    }
}

private struct AliyunPreferencesPane: View {
    @ObservedObject var settings: AppSettings
    @ObservedObject var store: UsageStore
    @State private var apiKeyField: String

    init(settings: AppSettings, store: UsageStore) {
        self.settings = settings
        self.store = store
        _apiKeyField = State(initialValue: settings.aliyunAPIKey)
    }

    var body: some View {
        PreferencesPaneContainer(title: L(.settingsAliyun), symbol: "cloud.fill", subtitle: L(.settingsAliyunSubtitle)) {
            Form {
                // Key field and Save share one row (a Save button floating on
                // its own line below the field is a web-form habit); the
                // explanatory text is a section footer, not a second card.
                Section {
                    Toggle(L(.showProvider), isOn: Binding(
                        get: { settings.showAliyun },
                        set: { settings.setVisible(.aliyun, $0) }))
                        .toggleStyle(.switch)

                    HStack(spacing: 8) {
                        SecureField(
                            L(.aliyunAPIKeyLabel),
                            text: $apiKeyField,
                            prompt: Text("sk-sp-…"))
                            .onSubmit(saveAPIKey)
                        Button(L(.saveCredential), action: saveAPIKey)
                            .buttonStyle(.bordered)
                    }

                    ProviderStatusRows(
                        status: store.status(for: .aliyun),
                        isRefreshing: store.isRefreshing(for: .aliyun),
                        lastUpdatedAt: store.lastUpdatedAt(for: .aliyun))
                } header: {
                    Text(L(.sectionConnection))
                } footer: {
                    VStack(alignment: .leading, spacing: 6) {
                        Text(L(.aliyunCredentialsHint))
                        Text(L(.aliyunPendingHint))
                    }
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
                }

                Section(L(.sectionActions)) {
                    HStack(spacing: 8) {
                        Button {
                            store.refresh(tab: .aliyun)
                        } label: {
                            Label(
                                store.isRefreshing(for: .aliyun) ? L(.refreshing) : L(.refreshAliyun),
                                systemImage: "arrow.clockwise")
                        }
                        .buttonStyle(.bordered)

                        Button {
                            NSWorkspace.shared.open(AliyunConsole.dashboardURL)
                        } label: {
                            Label(L(.openAliyunConsole), systemImage: "safari")
                        }
                        .buttonStyle(.bordered)
                    }
                }
            }
            .formStyle(.grouped)
        }
    }

    private func saveAPIKey() {
        settings.setAliyunAPIKey(apiKeyField)
    }
}

private struct StepFunPreferencesPane: View {
    @ObservedObject var settings: AppSettings
    @ObservedObject var store: UsageStore
    @State private var apiKeyField: String
    @State private var manualCookieField: String

    init(settings: AppSettings, store: UsageStore) {
        self.settings = settings
        self.store = store
        _apiKeyField = State(initialValue: settings.stepFunAPIKey)
        _manualCookieField = State(initialValue: settings.stepFunManualCookie)
    }

    var body: some View {
        PreferencesPaneContainer(title: L(.settingsStepFun), symbol: "stairs", subtitle: "阶跃 Step Plan 月度 Credit 额度") {
            Form {
                Section(L(.sectionDisplay)) {
                    Toggle(L(.showProvider), isOn: Binding(
                        get: { settings.showStepFun },
                        set: { settings.setVisible(.stepfun, $0) }))
                        .toggleStyle(.switch)
                }

                Section(L(.sectionConnection)) {
                    HStack(spacing: 8) {
                        SecureField(L(.stepFunAPIKeyLabel), text: $apiKeyField)
                            .onSubmit(saveAPIKey)
                        Button(L(.saveCredential), action: saveAPIKey)
                            .buttonStyle(.bordered)
                    }
                    HStack(spacing: 8) {
                        SecureField(L(.stepFunManualCookiePlaceholder), text: $manualCookieField)
                            .onSubmit(saveManualCookie)
                        Button(L(.saveCookie), action: saveManualCookie)
                            .buttonStyle(.bordered)
                    }

                    Button {
                        store.reimportStepFunBrowserSession()
                    } label: {
                        Label(
                            store.isRefreshing(for: .stepfun)
                                ? L(.refreshingStatus)
                                : L(.reimportStepFunBrowserSession),
                            systemImage: "person.crop.circle.badge.arrow.trianglehead.counterclockwise")
                    }
                    .disabled(store.isRefreshing(for: .stepfun))

                    if let source = StepFunBrowserSession.cachedSession()?.sourceLabel {
                        Label(String(format: L(.browserSession), source), systemImage: "globe")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                            .textSelection(.enabled)
                    }

                    ProviderStatusRows(
                        status: store.status(for: .stepfun),
                        isRefreshing: store.isRefreshing(for: .stepfun),
                        lastUpdatedAt: store.lastUpdatedAt(for: .stepfun))

                    Label(L(.stepFunCredentialsHint), systemImage: "key")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .textSelection(.enabled)
                }

                Section(L(.sectionActions)) {
                    Button {
                        store.refresh(tab: .stepfun)
                    } label: {
                        Label(
                            store.isRefreshing(for: .stepfun) ? L(.refreshing) : L(.refreshStepFun),
                            systemImage: "arrow.clockwise")
                    }
                    Button {
                        NSWorkspace.shared.open(URL(string: "https://platform.stepfun.com/account-overview")!)
                    } label: {
                        Label(L(.openStepFunConsole), systemImage: "safari")
                    }
                }
            }
            .formStyle(.grouped)
        }
    }

    private func saveAPIKey() {
        settings.setStepFunAPIKey(apiKeyField)
        store.refresh(tab: .stepfun)
    }

    private func saveManualCookie() {
        settings.setStepFunManualCookie(manualCookieField)
        store.refresh(tab: .stepfun)
    }
}

private struct SenseNovaPreferencesPane: View {
    @ObservedObject var settings: AppSettings
    @ObservedObject var store: UsageStore
    @State private var apiKeyField: String
    @State private var manualCookieField: String

    init(settings: AppSettings, store: UsageStore) {
        self.settings = settings
        self.store = store
        _apiKeyField = State(initialValue: settings.senseNovaAPIKey)
        _manualCookieField = State(initialValue: settings.senseNovaManualCookie)
    }

    var body: some View {
        PreferencesPaneContainer(title: L(.settingsSenseNova), symbol: "sparkle.magnifyingglass", subtitle: "日日新 Token Plan（公测免费：60,000 积分/5 小时）") {
            Form {
                Section(L(.sectionDisplay)) {
                    Toggle(L(.showProvider), isOn: Binding(
                        get: { settings.showSenseNova },
                        set: { settings.setVisible(.sensenova, $0) }))
                        .toggleStyle(.switch)
                }

                Section(L(.sectionConnection)) {
                    HStack(spacing: 8) {
                        SecureField(L(.senseNovaAPIKeyLabel), text: $apiKeyField)
                            .onSubmit(saveAPIKey)
                        Button(L(.saveCredential), action: saveAPIKey)
                            .buttonStyle(.bordered)
                    }
                    HStack(spacing: 8) {
                        SecureField(L(.senseNovaManualCookiePlaceholder), text: $manualCookieField)
                            .onSubmit(saveManualCookie)
                        Button(L(.saveCookie), action: saveManualCookie)
                            .buttonStyle(.bordered)
                    }

                    Button {
                        store.reimportSenseNovaBrowserSession()
                    } label: {
                        Label(
                            store.isRefreshing(for: .sensenova)
                                ? L(.refreshingStatus)
                                : L(.reimportSenseNovaBrowserSession),
                            systemImage: "person.crop.circle.badge.arrow.trianglehead.counterclockwise")
                    }
                    .disabled(store.isRefreshing(for: .sensenova))

                    if let source = SenseNovaBrowserSession.cachedSession()?.sourceLabel {
                        Label(String(format: L(.browserSession), source), systemImage: "globe")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                            .textSelection(.enabled)
                    }

                    ProviderStatusRows(
                        status: store.status(for: .sensenova),
                        isRefreshing: store.isRefreshing(for: .sensenova),
                        lastUpdatedAt: store.lastUpdatedAt(for: .sensenova))

                    Label(L(.senseNovaCredentialsHint), systemImage: "key")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .textSelection(.enabled)
                }

                Section(L(.sectionActions)) {
                    Button {
                        store.refresh(tab: .sensenova)
                    } label: {
                        Label(
                            store.isRefreshing(for: .sensenova) ? L(.refreshing) : L(.refreshSenseNova),
                            systemImage: "arrow.clockwise")
                    }
                    Button {
                        NSWorkspace.shared.open(URL(string: "https://platform.sensenova.cn/console")!)
                    } label: {
                        Label(L(.openSenseNovaConsole), systemImage: "safari")
                    }
                }
            }
            .formStyle(.grouped)
        }
    }

    private func saveAPIKey() {
        settings.setSenseNovaAPIKey(apiKeyField)
        store.refresh(tab: .sensenova)
    }

    private func saveManualCookie() {
        settings.setSenseNovaManualCookie(manualCookieField)
        store.refresh(tab: .sensenova)
    }
}

private struct ReminderPreferencesPane: View {
    @ObservedObject var settings: AppSettings

    private let dayOptions = [3, 7, 14, 30]

    var body: some View {
        PreferencesPaneContainer(title: L(.settingsReminder), symbol: "bell", subtitle: L(.settingsReminderSubtitle)) {
            Form {
                // Hints are a section footer, not a second card: the previous
                // two-label card looked like a web callout and pushed the
                // manual-subscription list below the fold.
                Section {
                    Toggle(L(.reminderEnabledLabel), isOn: $settings.expiryReminderEnabled)
                        .toggleStyle(.switch)
                    Picker(L(.reminderDaysLabel), selection: $settings.expiryReminderDays) {
                        ForEach(dayOptions, id: \.self) { days in
                            Text(String(format: L(.reminderDaysOption), days)).tag(days)
                        }
                    }
                    .pickerStyle(.menu)
                    Toggle(L(.reminderNotifyLabel), isOn: $settings.expiryReminderNotify)
                        .toggleStyle(.switch)
                } header: {
                    Text(L(.reminderSectionTitle))
                } footer: {
                    VStack(alignment: .leading, spacing: 6) {
                        Text(L(.reminderRuleHint))
                        Text(L(.reminderNotifyHint))
                    }
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
                }

                Section(L(.reminderManualSection)) {
                    if settings.manualSubscriptions.isEmpty {
                        Text(L(.reminderManualEmpty))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    ForEach(settings.manualSubscriptions) { subscription in
                        ManualSubscriptionRow(
                            subscription: subscription,
                            onCommit: { name, expiry, note in
                                settings.updateManualSubscription(
                                    id: subscription.id,
                                    name: name,
                                    expiryDate: expiry,
                                    note: note)
                            },
                            onDelete: {
                                settings.removeManualSubscription(id: subscription.id)
                            })
                    }

                    Button {
                        settings.addManualSubscription()
                    } label: {
                        Label(L(.reminderManualAdd), systemImage: "plus")
                    }
                }
            }
            .formStyle(.grouped)
        }
    }
}

/// One manual-subscription editor. The text fields bind to local @State and
/// commit through `onCommit`; binding them directly to the @Published array
/// rebuilt the whole Form on every keystroke and swallowed the input. This
/// mirrors the State + save pattern the credential fields use.
private struct ManualSubscriptionRow: View {
    @State private var name: String
    @State private var note: String
    @State private var expiryDate: Date

    private let onCommit: (_ name: String, _ expiry: Date, _ note: String) -> Void
    private let onDelete: () -> Void

    init(subscription: ManualSubscription,
         onCommit: @escaping (_ name: String, _ expiry: Date, _ note: String) -> Void,
         onDelete: @escaping () -> Void)
    {
        _name = State(initialValue: subscription.name)
        _note = State(initialValue: subscription.note)
        _expiryDate = State(initialValue: subscription.expiryDate)
        self.onCommit = onCommit
        self.onDelete = onDelete
    }

    var body: some View {
        HStack(alignment: .center, spacing: 10) {
            VStack(alignment: .leading, spacing: 6) {
                DatePicker(
                    L(.reminderManualExpiryLabel),
                    selection: $expiryDate,
                    displayedComponents: .date)
                    .datePickerStyle(.field)
                // A grouped Form ignores .textFieldStyle(.roundedBorder) for
                // custom rows, so the bordered value box is drawn explicitly —
                // label outside, bordered value inside, matching the date
                // field above it.
                labeledField(
                    L(.reminderManualNamePlaceholder),
                    text: $name,
                    prompt: L(.reminderManualNamePrompt))
                labeledField(
                    L(.reminderManualNotePlaceholder),
                    text: $note,
                    prompt: L(.reminderManualNotePrompt))
            }
            Button(action: onDelete) {
                Image(systemName: "trash")
            }
            .buttonStyle(.plain)
            .frame(width: 20, height: 20)
            .help(L(.reminderManualDelete))
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(.quaternary.opacity(0.4)))
        .onChange(of: name) { _, _ in commit() }
        .onChange(of: note) { _, _ in commit() }
        .onChange(of: expiryDate) { _, _ in commit() }
    }

    /// Label outside the box, bordered editable value inside — the same
    /// reading as the `.field`-style date picker above.
    private func labeledField(_ label: String, text: Binding<String>, prompt: String) -> some View {
        HStack(spacing: 8) {
            Text(label)
                .frame(width: 62, alignment: .leading)
            TextField("", text: text, prompt: Text(prompt))
                .textFieldStyle(.plain)
                .padding(.horizontal, 6)
                .padding(.vertical, 3)
                .background(
                    RoundedRectangle(cornerRadius: 5, style: .continuous)
                        .fill(Color(nsColor: .textBackgroundColor)))
                .overlay(
                    RoundedRectangle(cornerRadius: 5, style: .continuous)
                        .strokeBorder(Color.primary.opacity(0.18), lineWidth: 1))
        }
    }

    private func commit() {
        onCommit(name, expiryDate, note)
    }
}

private struct ProviderStatusRows: View {
    let status: UsageStore.LoadStatus
    let isRefreshing: Bool
    let lastUpdatedAt: Date?

    var body: some View {
        LabeledContent(L(.status)) {
            HStack(spacing: 6) {
                if isRefreshing {
                    ProgressView()
                        .controlSize(.small)
                } else {
                    Image(systemName: statusSymbol)
                        .foregroundStyle(statusColor)
                }
                Text(statusTitle)
            }
        }

        if let snapshot = status.snapshot {
            LabeledContent(L(.settingsCurrentSource)) {
                Text([
                    snapshot.providerName,
                    snapshot.authMethod,
                ].compactMap { $0 }.joined(separator: " · "))
                    .multilineTextAlignment(.trailing)
                    .textSelection(.enabled)
            }

            if let tightest = snapshot.tightestWindow {
                LabeledContent(L(.tightest)) {
                    Text("\(tightest.displayName) \(Int(tightest.remainingPercent.rounded()))% \(L(.left))")
                }
            }
        }

        LabeledContent(L(.lastSuccessfulUpdate)) {
            Text(lastUpdatedAt.map(Self.timeText) ?? L(.noSuccessfulUpdate))
                .foregroundStyle(.secondary)
        }

        if let detail = errorDetail {
            Text(detail)
                .font(.caption)
                .foregroundStyle(detailColor)
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
                .padding(8)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(Color(nsColor: .controlBackgroundColor)))
        }
    }

    private var statusTitle: String {
        if isRefreshing { return L(.refreshingStatus) }
        return switch status {
        case .never: L(.noDataYet)
        case .loading: L(.refreshingStatus)
        case .ok: L(.connectedVia)
        case .stale: L(.settingsPreviousData)
        case .error: L(.fetchFailedShort)
        }
    }

    private var statusSymbol: String {
        return switch status {
        case .ok: "checkmark.circle.fill"
        case .stale: "exclamationmark.triangle.fill"
        case .error: "xmark.circle.fill"
        case .never, .loading: "circle.dotted"
        }
    }

    private var statusColor: Color {
        return switch status {
        case .ok: .green
        case .stale: .orange
        case .error: .red
        case .never, .loading: .secondary
        }
    }

    private var errorDetail: String? {
        switch status {
        case let .stale(_, message), let .error(message): message
        case .never, .loading, .ok: nil
        }
    }

    private var detailColor: Color {
        if case .stale = status { return .orange }
        return .red
    }

    private static func timeText(_ date: Date) -> String {
        date.formatted(date: .abbreviated, time: .standard)
    }
}

private struct DiagnosticsPreferencesPane: View {
    @State private var arkcliPath = L(.notFound)
    @State private var arkcliVersion = "—"
    @State private var isChecking = false

    var body: some View {
        PreferencesPaneContainer(title: L(.settingsDiagnostics), symbol: "stethoscope", subtitle: L(.settingsDiagnosticsSubtitle)) {
            Form {
                Section(L(.sectionDiagnostics)) {
                    DiagnosticValueRow(label: L(.arkcliPath), value: arkcliPath)
                    DiagnosticValueRow(label: L(.arkcliVersion), value: arkcliVersion)
                    DiagnosticValueRow(
                        label: L(.shell),
                        value: ProcessInfo.processInfo.environment["SHELL"] ?? "—")
                }

                Section(L(.sectionActions)) {
                    Button {
                        Task { await probeArkcli() }
                    } label: {
                        HStack {
                            if isChecking {
                                ProgressView()
                                    .controlSize(.small)
                            }
                            Label(L(.sectionDiagnostics), systemImage: "stethoscope")
                        }
                    }
                    Button {
                        runTerminal("arkcli auth login volc-sso")
                    } label: {
                        Label(L(.openArkcliLogin), systemImage: "terminal")
                    }
                    Button {
                        openArkConsole()
                    } label: {
                        Label(L(.openArkConsole), systemImage: "safari")
                    }
                }
            }
            .formStyle(.grouped)
            .task {
                await probeArkcli()
            }
        }
    }

    @MainActor
    private func probeArkcli() async {
        guard !isChecking else { return }
        isChecking = true
        defer { isChecking = false }

        guard let path = ArkCLIProvider.resolveArkcliPath(
            environment: ProcessInfo.processInfo.environment)
        else {
            arkcliPath = L(.notFound)
            arkcliVersion = "—"
            return
        }
        arkcliPath = path
        arkcliVersion = await Task.detached(priority: .utility) {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: path)
            process.arguments = ["--version"]
            let pipe = Pipe()
            process.standardOutput = pipe
            process.standardError = pipe
            do {
                try process.run()
                process.waitUntilExit()
            } catch {
                return error.localizedDescription
            }
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            return String(data: data, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .components(separatedBy: .newlines)
                .first ?? "—"
        }.value
    }
}

private struct DiagnosticValueRow: View {
    let label: String
    let value: String

    var body: some View {
        LabeledContent(label) {
            Text(value)
                .font(.system(.body, design: .monospaced))
                .multilineTextAlignment(.trailing)
                .textSelection(.enabled)
                .lineLimit(2)
        }
    }
}

private func runTerminal(_ command: String) {
    let escaped = command.replacingOccurrences(of: "\"", with: "\\\"")
    let script = """
        tell application "Terminal"
            activate
            do script "\(escaped)"
        end tell
        """
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
    process.arguments = ["-e", script]
    process.standardOutput = FileHandle.nullDevice
    process.standardError = FileHandle.nullDevice
    do {
        try process.run()
    } catch {
        UsageStore.log("runTerminal failed: \(error.localizedDescription)")
    }
}

private func openArkConsole() {
    guard let url = URL(
        string: "https://console.volcengine.com/ark/region:ark+cn-beijing/openManagement?LLM=%7B%7D&advancedActiveKey=subscribe")
    else {
        return
    }
    NSWorkspace.shared.open(url)
}
