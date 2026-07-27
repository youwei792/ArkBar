import AppKit
import Combine

/// Preferences window controller. Presented from the menu bar.
/// Built with pure AppKit to avoid SwiftUI rendering issues in NSPanel.
@MainActor
final class PreferencesWindowController: NSWindowController {
    private let settings: AppSettings
    private let store: UsageStore

    init(settings: AppSettings, store: UsageStore) {
        self.settings = settings
        self.store = store
        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 460, height: 520),
            styleMask: [.titled, .closable, .miniaturizable],
            backing: .buffered,
            defer: false)
        panel.title = L(.settingsTitle)
        panel.isFloatingPanel = true
        panel.minSize = NSSize(width: 460, height: 520)
        panel.center()
        panel.isReleasedWhenClosed = false
        panel.contentView = Self.makeContentView(settings: settings, store: store)
        super.init(window: panel)
        NotificationCenter.default.publisher(for: L10n.languageDidChange)
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.rebuildLocalizedContent() }
            .store(in: &cancellables)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    func show() {
        NSApp.activate(ignoringOtherApps: true)
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    private var cancellables = Set<AnyCancellable>()

    private func rebuildLocalizedContent() {
        guard let window else { return }
        window.title = L(.settingsTitle)
        window.contentView = Self.makeContentView(settings: settings, store: store)
    }

    private static func makeContentView(settings: AppSettings, store: UsageStore) -> NSView {
        let scrollView = NSScrollView(frame: NSRect(x: 0, y: 0, width: 460, height: 520))
        scrollView.hasVerticalScroller = true
        // Keep the affordance visible: this settings surface intentionally scrolls
        // on compact displays, and an auto-hidden scroller made the Advanced
        // controls appear to be missing.
        scrollView.autohidesScrollers = false
        scrollView.drawsBackground = false
        let preferencesView = PreferencesView(settings: settings, store: store)
        // Only the width tracks the panel. Keeping the calculated document height
        // prevents the last "Advanced" controls from being laid out below the
        // scroll view's document bounds.
        preferencesView.autoresizingMask = [.width]
        scrollView.documentView = preferencesView
        return scrollView
    }
}

/// AppKit-based preferences view. Lays out sections vertically.
private final class PreferencesView: NSView {
    private let settings: AppSettings
    private let store: UsageStore

    // Controls we need to keep references to.
    private var displayModePopup: NSPopUpButton!
    private var intervalPopup: NSPopUpButton!
    private var sourcePopup: NSPopUpButton!
    private var languagePopup: NSPopUpButton!
    private var statusLabel: NSTextField!
    private var authLabel: NSTextField!
    private var planCountLabel: NSTextField!
    private var tightestLabel: NSTextField!
    private var lastFetchLabel: NSTextField!
    private var arkcliPathLabel: NSTextField!
    private var arkcliVersionLabel: NSTextField!
    private var shellLabel: NSTextField!
    private var opencodeCookieField: NSSecureTextField!
    private var opencodeWorkspaceField: NSTextField!
    private var opencodeStatusLabel: NSTextField!

    init(settings: AppSettings, store: UsageStore) {
        self.settings = settings
        self.store = store
        super.init(frame: NSRect(x: 0, y: 0, width: 460, height: 880))
        wantsLayer = true
        build()
        observeStore()
    }

    required init?(coder: NSCoder) { fatalError() }

    // MARK: - Build UI

    private func build() {
        var y = bounds.height - 20

        // Section: Menu bar.
        y -= sectionHeader(L(.sectionMenuBar), atY: y)
        y -= 8
        y -= row(label: L(.displayMode), control: makeDisplayModePopup(), atY: y)
        y -= 8
        y -= row(label: L(.language), control: makeLanguagePopup(), atY: y)
        y -= 16

        // Section: Refresh.
        y -= sectionHeader(L(.sectionRefresh), atY: y)
        y -= 8
        y -= row(label: L(.interval), control: makeIntervalPopup(), atY: y)
        y -= 4
        y -= refreshOnOpenRow(atY: y)
        y -= 24
        y -= refreshRow(atY: y)
        y -= 24

        // Section: Data source.
        y -= sectionHeader(L(.sectionDataSource), atY: y)
        y -= 8
        y -= row(label: L(.source), control: makeSourcePopup(), atY: y)
        y -= 24
        y -= statusBlock(atY: y)
        y -= 24

        // Section: OpenCode Go.
        y -= sectionHeader(L(.sectionOpenCode), atY: y)
        y -= 8
        y -= opencodeBlock(atY: y)
        y -= 24

        // Section: Diagnostics.
        y -= sectionHeader(L(.sectionDiagnostics), atY: y)
        y -= 8
        y -= diagnosticsBlock(atY: y)
        y -= 24

        // Section: Advanced. Language is deliberately above the fold with the
        // display setting, so it stays reachable even on compact screens.
        y -= sectionHeader(L(.sectionAdvanced), atY: y)
        y -= 8
        y -= advancedBlock(atY: y)
    }

    private func sectionHeader(_ title: String, atY y: CGFloat) -> CGFloat {
        let label = NSTextField(labelWithString: title)
        label.font = .systemFont(ofSize: 13, weight: .semibold)
        label.textColor = .labelColor
        label.sizeToFit()
        label.frame = NSRect(x: 20, y: y - 16, width: bounds.width - 40, height: 16)
        addSubview(label)
        return 24
    }

    private func row(label: String, control: NSView, atY y: CGFloat) -> CGFloat {
        let labelField = NSTextField(labelWithString: label)
        labelField.font = .systemFont(ofSize: 12)
        labelField.textColor = .labelColor
        labelField.sizeToFit()
        labelField.frame = NSRect(x: 20, y: y - 18, width: 110, height: 18)
        addSubview(labelField)

        control.frame = NSRect(x: 130, y: y - 22, width: bounds.width - 150, height: 24)
        addSubview(control)
        return 28
    }

    // MARK: - Controls

    private func makeDisplayModePopup() -> NSPopUpButton {
        let popup = NSPopUpButton(frame: .zero, pullsDown: false)
        for mode in AppSettings.DisplayMode.allCases {
            let item = NSMenuItem(title: mode.displayName, action: nil, keyEquivalent: "")
            item.representedObject = mode
            popup.menu?.addItem(item)
        }
        if let idx = AppSettings.DisplayMode.allCases.firstIndex(of: settings.displayMode) {
            popup.selectItem(at: idx)
        }
        popup.target = self
        popup.action = #selector(displayModeChanged(_:))
        displayModePopup = popup
        return popup
    }

    private func makeIntervalPopup() -> NSPopUpButton {
        let popup = NSPopUpButton(frame: .zero, pullsDown: false)
        for interval in AppSettings.RefreshInterval.allCases {
            popup.addItem(withTitle: interval.displayName)
        }
        if let idx = AppSettings.RefreshInterval.allCases.firstIndex(of: settings.refreshInterval) {
            popup.selectItem(at: idx)
        }
        popup.target = self
        popup.action = #selector(intervalChanged(_:))
        intervalPopup = popup
        return popup
    }

    private func makeSourcePopup() -> NSPopUpButton {
        let popup = NSPopUpButton(frame: .zero, pullsDown: false)
        for mode in AppSettings.SourceMode.allCases {
            popup.addItem(withTitle: sourceModeLabel(mode))
        }
        if let idx = AppSettings.SourceMode.allCases.firstIndex(of: settings.sourceMode) {
            popup.selectItem(at: idx)
        }
        popup.target = self
        popup.action = #selector(sourceModeChanged(_:))
        sourcePopup = popup
        return popup
    }

    private func makeLanguagePopup() -> NSPopUpButton {
        let popup = NSPopUpButton(frame: .zero, pullsDown: false)
        for lang in Language.allCases {
            popup.addItem(withTitle: lang.displayName)
        }
        if let idx = Language.allCases.firstIndex(of: settings.language) {
            popup.selectItem(at: idx)
        }
        popup.target = self
        popup.action = #selector(languageChanged(_:))
        languagePopup = popup
        return popup
    }

    // MARK: - Rows

    private func refreshRow(atY y: CGFloat) -> CGFloat {
        let button = NSButton(title: L(.refreshNow), target: self,
                              action: #selector(refreshTapped))
        button.bezelStyle = .rounded
        button.frame = NSRect(x: 130, y: y - 22, width: 120, height: 24)
        addSubview(button)

        let lastFetch = NSTextField(labelWithString: "")
        lastFetch.font = .systemFont(ofSize: 11)
        lastFetch.textColor = .secondaryLabelColor
        lastFetch.sizeToFit()
        lastFetch.lineBreakMode = .byTruncatingTail
        lastFetch.frame = NSRect(x: 260, y: y - 18, width: bounds.width - 280, height: 14)
        addSubview(lastFetch)
        lastFetchLabel = lastFetch
        updateLastFetchLabel()
        return 28
    }

    private func refreshOnOpenRow(atY y: CGFloat) -> CGFloat {
        let checkbox = NSButton(checkboxWithTitle: L(.refreshWhenMenuOpens),
                                target: self,
                                action: #selector(refreshWhenMenuOpensChanged(_:)))
        checkbox.font = .systemFont(ofSize: 12)
        checkbox.state = settings.refreshWhenMenuOpens ? .on : .off
        checkbox.frame = NSRect(x: 126, y: y - 20, width: bounds.width - 146, height: 20)
        addSubview(checkbox)
        return 24
    }

    private func statusBlock(atY y: CGFloat) -> CGFloat {
        let status = NSTextField(labelWithString: "")
        status.font = .systemFont(ofSize: 11)
        status.textColor = .systemGreen
        status.lineBreakMode = .byTruncatingTail
        status.frame = NSRect(x: 130, y: y - 14, width: bounds.width - 150, height: 14)
        addSubview(status)
        statusLabel = status

        let auth = NSTextField(labelWithString: "")
        auth.font = .systemFont(ofSize: 10)
        auth.textColor = .secondaryLabelColor
        auth.lineBreakMode = .byTruncatingMiddle
        auth.frame = NSRect(x: 130, y: y - 30, width: bounds.width - 150, height: 12)
        addSubview(auth)
        authLabel = auth

        let planCount = NSTextField(labelWithString: "")
        planCount.font = .systemFont(ofSize: 10)
        planCount.textColor = .secondaryLabelColor
        planCount.lineBreakMode = .byTruncatingTail
        planCount.frame = NSRect(x: 130, y: y - 44, width: bounds.width - 150, height: 12)
        addSubview(planCount)
        planCountLabel = planCount

        let tightest = NSTextField(labelWithString: "")
        tightest.font = .systemFont(ofSize: 10)
        tightest.textColor = .secondaryLabelColor
        tightest.lineBreakMode = .byTruncatingTail
        tightest.frame = NSRect(x: 130, y: y - 58, width: bounds.width - 150, height: 12)
        addSubview(tightest)
        tightestLabel = tightest

        updateStatusBlock()
        return 64
    }

    private func diagnosticsBlock(atY y: CGFloat) -> CGFloat {
        let pathLabel = NSTextField(labelWithString: L(.arkcliPath))
        pathLabel.font = .systemFont(ofSize: 11)
        pathLabel.textColor = .secondaryLabelColor
        pathLabel.sizeToFit()
        pathLabel.frame = NSRect(x: 20, y: y - 14, width: pathLabel.frame.width, height: 14)
        addSubview(pathLabel)

        let pathValue = NSTextField(labelWithString: L(.notFound))
        pathValue.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        pathValue.textColor = .systemRed
        pathValue.lineBreakMode = .byTruncatingMiddle
        pathValue.frame = NSRect(x: 20, y: y - 30, width: bounds.width - 40, height: 14)
        addSubview(pathValue)
        arkcliPathLabel = pathValue

        let versionLabel = NSTextField(labelWithString: L(.arkcliVersion))
        versionLabel.font = .systemFont(ofSize: 11)
        versionLabel.textColor = .secondaryLabelColor
        versionLabel.sizeToFit()
        versionLabel.frame = NSRect(x: 20, y: y - 46, width: versionLabel.frame.width, height: 14)
        addSubview(versionLabel)

        let versionValue = NSTextField(labelWithString: "")
        versionValue.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        versionValue.textColor = .secondaryLabelColor
        versionValue.lineBreakMode = .byTruncatingMiddle
        versionValue.frame = NSRect(x: 20, y: y - 62, width: bounds.width - 40, height: 14)
        addSubview(versionValue)
        arkcliVersionLabel = versionValue

        let shellLabelField = NSTextField(labelWithString: L(.shell))
        shellLabelField.font = .systemFont(ofSize: 11)
        shellLabelField.textColor = .secondaryLabelColor
        shellLabelField.sizeToFit()
        shellLabelField.frame = NSRect(x: 20, y: y - 78, width: shellLabelField.frame.width, height: 14)
        addSubview(shellLabelField)

        let shellValue = NSTextField(labelWithString: ProcessInfo.processInfo.environment["SHELL"] ?? "-")
        shellValue.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        shellValue.textColor = .secondaryLabelColor
        shellValue.lineBreakMode = .byTruncatingMiddle
        shellValue.frame = NSRect(x: 20, y: y - 94, width: bounds.width - 40, height: 14)
        addSubview(shellValue)
        shellLabel = shellValue

        Task { await detectArkcli() }
        return 100
    }

    private func advancedBlock(atY y: CGFloat) -> CGFloat {
        let loginButton = NSButton(title: L(.openArkcliLogin), target: self,
                                   action: #selector(openLogin))
        loginButton.bezelStyle = .rounded
        loginButton.frame = NSRect(x: 20, y: y - 22, width: 200, height: 24)
        addSubview(loginButton)

        let consoleButton = NSButton(title: L(.openArkConsole), target: self,
                                     action: #selector(openConsole))
        consoleButton.bezelStyle = .rounded
        consoleButton.frame = NSRect(x: 20, y: y - 54, width: 200, height: 24)
        addSubview(consoleButton)

        return 64
    }

    /// OpenCode Go configuration: cookie + workspace ID + status + test button.
    private func opencodeBlock(atY y: CGFloat) -> CGFloat {
        let labelWidth = bounds.width - 40

        // Cookie label + secure field.
        let cookieLabel = NSTextField(labelWithString: L(.opencodeCookie))
        cookieLabel.font = .systemFont(ofSize: 11)
        cookieLabel.textColor = .secondaryLabelColor
        cookieLabel.sizeToFit()
        cookieLabel.frame = NSRect(x: 20, y: y - 14, width: cookieLabel.frame.width, height: 14)
        addSubview(cookieLabel)

        let cookieField = NSSecureTextField(frame: NSRect(x: 20, y: y - 36, width: labelWidth, height: 22))
        cookieField.placeholderString = L(.opencodeCookiePlaceholder)
        cookieField.font = .systemFont(ofSize: 11)
        cookieField.target = self
        cookieField.action = #selector(opencodeCookieChanged(_:))
        // Show the stored cookie so the user knows whether one is configured.
        // NSSecureTextField masks it; the user can clear+re-paste to update.
        cookieField.stringValue = settings.opencodeCookie
        addSubview(cookieField)
        opencodeCookieField = cookieField

        // Workspace ID label + field.
        let wsLabel = NSTextField(labelWithString: L(.opencodeWorkspaceID))
        wsLabel.font = .systemFont(ofSize: 11)
        wsLabel.textColor = .secondaryLabelColor
        wsLabel.sizeToFit()
        wsLabel.frame = NSRect(x: 20, y: y - 58, width: wsLabel.frame.width, height: 14)
        addSubview(wsLabel)

        let wsField = NSTextField(frame: NSRect(x: 20, y: y - 80, width: labelWidth, height: 22))
        wsField.placeholderString = L(.opencodeWorkspaceIDPlaceholder)
        wsField.font = .systemFont(ofSize: 11)
        wsField.stringValue = settings.opencodeWorkspaceID
        wsField.target = self
        wsField.action = #selector(opencodeWorkspaceChanged(_:))
        addSubview(wsField)
        opencodeWorkspaceField = wsField

        // Test / Refresh button + status line.
        let testButton = NSButton(title: L(.opencodeTestRefresh), target: self,
                                  action: #selector(opencodeTestRefresh))
        testButton.bezelStyle = .rounded
        testButton.frame = NSRect(x: 20, y: y - 112, width: 140, height: 24)
        addSubview(testButton)

        let status = NSTextField(labelWithString: "")
        status.font = .systemFont(ofSize: 10)
        status.textColor = .secondaryLabelColor
        status.lineBreakMode = .byTruncatingTail
        status.frame = NSRect(x: 20, y: y - 132, width: labelWidth, height: 14)
        addSubview(status)
        opencodeStatusLabel = status
        updateOpencodeStatus()

        return 146
    }

    // MARK: - OpenCode actions

    @objc private func opencodeCookieChanged(_ sender: NSSecureTextField) {
        settings.setOpenCodeCookie(sender.stringValue)
        updateOpencodeStatus()
        store.refresh()
    }

    @objc private func opencodeWorkspaceChanged(_ sender: NSTextField) {
        settings.opencodeWorkspaceID = sender.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    @objc private func opencodeTestRefresh() {
        // Commit the field values first (in case the user typed but didn't hit
        // Enter, which doesn't fire the action), then refresh.
        settings.setOpenCodeCookie(opencodeCookieField.stringValue)
        settings.opencodeWorkspaceID = opencodeWorkspaceField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        updateOpencodeStatus()
        store.refresh()
    }

    private func updateOpencodeStatus() {
        guard let label = opencodeStatusLabel else { return }
        switch store.opencodeStatus {
        case .never:
            label.stringValue = settings.opencodeCookieHasValue ? L(.refreshingStatus) : L(.opencodeCookieNotSet)
            label.textColor = .secondaryLabelColor
        case .loading:
            label.stringValue = L(.refreshingStatus)
            label.textColor = .secondaryLabelColor
        case let .ok(snapshot):
            let parts = [snapshot.providerName, snapshot.authMethod.map { "\(L(.authLabel)): \($0)" }]
                .compactMap { $0 }
            label.stringValue = "✓ " + parts.joined(separator: " · ")
            label.textColor = .systemGreen
        case let .stale(_, message):
            label.stringValue = "⚠ \(message)"
            label.textColor = .systemOrange
        case let .error(message):
            label.stringValue = "✗ \(message)"
            label.textColor = .systemRed
        }
    }

    // MARK: - Actions

    @objc private func displayModeChanged(_ sender: NSPopUpButton) {
        guard let mode = sender.selectedItem?.representedObject as? AppSettings.DisplayMode else { return }
        settings.displayMode = mode
    }

    @objc private func intervalChanged(_ sender: NSPopUpButton) {
        let idx = sender.indexOfSelectedItem
        guard let interval = AppSettings.RefreshInterval.allCases[safe: idx] else { return }
        settings.refreshInterval = interval
    }

    @objc private func refreshWhenMenuOpensChanged(_ sender: NSButton) {
        settings.refreshWhenMenuOpens = sender.state == .on
    }

    @objc private func sourceModeChanged(_ sender: NSPopUpButton) {
        let idx = sender.indexOfSelectedItem
        guard let mode = AppSettings.SourceMode.allCases[safe: idx] else { return }
        settings.sourceMode = mode
    }

    @objc private func languageChanged(_ sender: NSPopUpButton) {
        let idx = sender.indexOfSelectedItem
        guard let lang = Language.allCases[safe: idx] else { return }
        settings.language = lang
    }

    @objc private func refreshTapped() {
        store.refresh()
    }

    @objc private func openLogin() {
        runTerminal("arkcli auth login volc-sso")
    }

    @objc private func openConsole() {
        NSWorkspace.shared.open(URL(string: "https://console.volcengine.com/ark/region:ark+cn-beijing/openManagement?LLM=%7B%7D&advancedActiveKey=subscribe")!)
    }

    // MARK: - Status updates

    private func observeStore() {
        store.$arkStatus
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                self?.updateStatusBlock()
                self?.updateLastFetchLabel()
            }
            .store(in: &cancellables)
        store.$arkLastUpdatedAt
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                self?.updateLastFetchLabel()
            }
            .store(in: &cancellables)
        store.$opencodeStatus
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                self?.updateOpencodeStatus()
            }
            .store(in: &cancellables)
    }

    private var cancellables = Set<AnyCancellable>()

    private func updateStatusBlock() {
        switch store.arkStatus {
        case let .ok(snapshot):
            statusLabel?.stringValue = "✓ \(L(.connectedVia)) \(snapshot.providerName)"
            statusLabel?.textColor = .systemGreen
            authLabel?.stringValue = "\(L(.authLabel)): \(snapshot.authMethod ?? "-")  ·  \(snapshot.plans.count) \(L(.planCount))"
            if let tight = snapshot.tightestWindow {
                tightestLabel?.stringValue = "\(L(.tightest)): \(tight.displayName) \(Int(tight.remainingPercent))% \(L(.left))"
            } else {
                tightestLabel?.stringValue = ""
            }
        case let .error(msg):
            statusLabel?.stringValue = "✗ \(L(.fetchFailedShort))"
            statusLabel?.textColor = .systemRed
            authLabel?.stringValue = msg
            tightestLabel?.stringValue = ""
        case let .stale(snapshot, msg):
            statusLabel?.stringValue = "⚠ \(L(.staleData))"
            statusLabel?.textColor = .systemOrange
            authLabel?.stringValue = msg
            tightestLabel?.stringValue = snapshot.tightestWindow.map {
                "\(L(.tightest)): \($0.displayName) \(Int($0.usedPercent))% \(L(.used))"
            } ?? ""
        case .loading:
            statusLabel?.stringValue = L(.refreshingStatus)
            statusLabel?.textColor = .secondaryLabelColor
            authLabel?.stringValue = ""
            tightestLabel?.stringValue = ""
        case .never:
            statusLabel?.stringValue = L(.noDataYet)
            statusLabel?.textColor = .secondaryLabelColor
            authLabel?.stringValue = ""
            tightestLabel?.stringValue = ""
        }
    }

    private func updateLastFetchLabel() {
        guard let label = lastFetchLabel else { return }
        if let updated = store.arkLastUpdatedAt {
            let f = DateFormatter()
            f.locale = Locale(identifier: "en_US_POSIX")
            f.dateFormat = "HH:mm:ss"
            label.stringValue = "\(L(.lastFetch)): \(f.string(from: updated))"
        } else {
            label.stringValue = ""
        }
    }

    // MARK: - Helpers

    private func sourceModeLabel(_ mode: AppSettings.SourceMode) -> String {
        switch mode {
        case .auto: L(.sourceAuto)
        case .cli: L(.sourceCli)
        case .api: L(.sourceApi)
        }
    }

    private func runTerminal(_ command: String) {
        let script = "tell application \"Terminal\"\nactivate\ndo script \"\(command)\"\nend tell"
        if let s = NSAppleScript(source: script) {
            var err: NSDictionary?
            s.executeAndReturnError(&err)
        }
    }

    @MainActor
    private func detectArkcli() async {
        let env = ProcessInfo.processInfo.environment
        guard let path = ArkCLIProvider.resolveArkcliPath(environment: env) else {
            arkcliPathLabel?.stringValue = L(.notFound)
            arkcliPathLabel?.textColor = .systemRed
            return
        }
        arkcliPathLabel?.stringValue = path
        arkcliPathLabel?.textColor = .secondaryLabelColor

        let version: String? = await Task.detached(priority: .utility) {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/bin/zsh")
            p.arguments = ["-c", "\(path) --version"]
            let pipe = Pipe()
            p.standardOutput = pipe
            p.standardError = pipe
            do { try p.run() } catch { return nil }
            p.waitUntilExit()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            return String(data: data, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .components(separatedBy: .newlines).first
        }.value
        if let version {
            arkcliVersionLabel?.stringValue = version
        }
    }
}

// MARK: - Safe array access

extension Array {
    subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}
