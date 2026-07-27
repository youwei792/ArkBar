import AppKit
import SwiftUI

/// CodexBar-style settings window: a stable sidebar and one grouped form per
/// concern. This keeps every control reachable without a single oversized
/// document whose final sections disappear below the screen.
@MainActor
final class PreferencesWindowController: NSWindowController {
    private let settings: AppSettings
    private let store: UsageStore

    init(settings: AppSettings, store: UsageStore) {
        self.settings = settings
        self.store = store

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 800, height: 560),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false)
        window.title = L(.settingsTitle)
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.minSize = NSSize(width: 720, height: 500)
        window.isReleasedWhenClosed = false
        window.center()
        window.contentView = NSHostingView(rootView: PreferencesRootView(
            settings: settings,
            store: store))

        super.init(window: window)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    func show() {
        NSApp.activate(ignoringOtherApps: true)
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
    }
}

private enum PreferencesPane: String, CaseIterable, Identifiable {
    case general
    case ark
    case openCode
    case diagnostics

    var id: Self { self }

    var title: String {
        switch self {
        case .general: L(.settingsGeneral)
        case .ark: L(.settingsArk)
        case .openCode: L(.settingsOpenCode)
        case .diagnostics: L(.settingsDiagnostics)
        }
    }

    var symbol: String {
        switch self {
        case .general: "gearshape"
        case .ark: "chart.donut"
        case .openCode: "terminal"
        case .diagnostics: "stethoscope"
        }
    }
}

private struct PreferencesRootView: View {
    @ObservedObject var settings: AppSettings
    @ObservedObject var store: UsageStore
    @ObservedObject private var l10n = L10n.shared
    @State private var selection: PreferencesPane? = .general

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
    }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 3) {
                Text("ArkBar")
                    .font(.system(size: 20, weight: .bold))
                Text(L(.settingsTitle))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 18)
            .padding(.top, 46)
            .padding(.bottom, 14)

            List(selection: $selection) {
                ForEach(PreferencesPane.allCases) { pane in
                    Label(pane.title, systemImage: pane.symbol)
                        .tag(Optional(pane))
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
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(title)
                .font(.system(size: 22, weight: .bold))
                .padding(.horizontal, 24)
                .padding(.top, 42)
                .padding(.bottom, 14)

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
        PreferencesPaneContainer(title: L(.settingsGeneral)) {
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
                }

                Section(L(.sectionRefresh)) {
                    Picker(L(.interval), selection: $settings.refreshInterval) {
                        ForEach(AppSettings.RefreshInterval.allCases, id: \.self) { interval in
                            Text(interval.displayName).tag(interval)
                        }
                    }
                    Toggle(L(.refreshWhenMenuOpens), isOn: $settings.refreshWhenMenuOpens)
                        .toggleStyle(.switch)
                }

                Section(L(.sectionActions)) {
                    HStack(spacing: 12) {
                        Button {
                            store.refresh(tab: .ark)
                        } label: {
                            Label(L(.refreshArk), systemImage: "arrow.clockwise")
                        }
                        Button {
                            store.refresh(tab: .opencode)
                        } label: {
                            Label(L(.refreshOpenCode), systemImage: "arrow.clockwise")
                        }
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

    var body: some View {
        PreferencesPaneContainer(title: L(.settingsArk)) {
            Form {
                Section(L(.sectionConnection)) {
                    Picker(L(.source), selection: $settings.sourceMode) {
                        ForEach(AppSettings.SourceMode.allCases, id: \.self) { mode in
                            Text(sourceName(mode)).tag(mode)
                        }
                    }
                    ProviderStatusRows(
                        status: store.arkStatus,
                        isRefreshing: store.arkIsRefreshing,
                        lastUpdatedAt: store.arkLastUpdatedAt)
                }

                Section(L(.sectionActions)) {
                    Button {
                        store.refresh(tab: .ark)
                    } label: {
                        Label(
                            store.arkIsRefreshing ? L(.refreshing) : L(.refreshArk),
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
        PreferencesPaneContainer(title: L(.settingsOpenCode)) {
            Form {
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
                                store.opencodeIsRefreshing
                                    ? L(.refreshingStatus)
                                    : L(.reimportBrowserSession),
                                systemImage: "person.crop.circle.badge.arrow.trianglehead.counterclockwise")
                        }
                        .disabled(store.opencodeIsRefreshing)
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
                        status: store.opencodeStatus,
                        isRefreshing: store.opencodeIsRefreshing,
                        lastUpdatedAt: store.opencodeLastUpdatedAt)

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
                            store.opencodeIsRefreshing ? L(.refreshing) : L(.refreshOpenCode),
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
        PreferencesPaneContainer(title: L(.settingsDiagnostics)) {
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
    var error: NSDictionary?
    NSAppleScript(source: script)?.executeAndReturnError(&error)
}

private func openArkConsole() {
    guard let url = URL(
        string: "https://console.volcengine.com/ark/region:ark+cn-beijing/openManagement?LLM=%7B%7D&advancedActiveKey=subscribe")
    else {
        return
    }
    NSWorkspace.shared.open(url)
}
