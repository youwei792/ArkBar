import AppKit
import SwiftUI
import UserNotifications

/// Shared environment handed to the SwiftUI `Settings` scene. AppDelegate
/// fills in the store once the app has launched.
@MainActor
final class AppEnvironment: ObservableObject {
    static let shared = AppEnvironment()

    @Published var store: UsageStore?

    private init() {}
}

@main
struct TokenBarApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @ObservedObject private var environment = AppEnvironment.shared

    var body: some Scene {
        // No Dock icon; the app lives in the menu bar. The `Settings` scene is
        // macOS's own settings window — it opens on ⌘, and whenever the app is
        // reopened (double-click / Spotlight / `open`), before the delegate is
        // ever consulted. It must therefore host the real settings UI; an
        // EmptyView placeholder is exactly what used to pop as a blank
        // "TokenBar Settings" window.
        Settings {
            SettingsSceneHost(environment: environment)
        }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var store: UsageStore?
    private var statusItem: StatusItemController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        // No Dock icon; pure menu-bar accessory. The env hooks below are
        // read-only visual-QA aids for local development; normal launches
        // never set them and retain the menu-bar-only behavior.
        let qaPane = ProcessInfo.processInfo.environment["TOKENBAR_SHOW_SETTINGS"]
        let qaPopMenu = ProcessInfo.processInfo.environment["TOKENBAR_POP_MENU"] == "1"
        NSApp.setActivationPolicy((qaPane != nil) ? .regular : .accessory)
        OpenCodeGoBrowserSession.configureKeychainPrompt()

        let store = UsageStore()
        self.store = store
        AppEnvironment.shared.store = store
        self.statusItem = StatusItemController(store: store)
        store.start()

        // Ask once for notification permission up front (the user can still
        // toggle reminders off in settings); denied permission degrades
        // gracefully to the in-menu reminder section. Bare source runs have
        // no bundle and must not touch UNUserNotificationCenter (it crashes).
        if AppSettings.shared.expiryReminderNotify, ReminderScheduler.notificationsAvailable {
            UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
        }

        if let qaPane {
            statusItem?.showSettings(initialPane: PreferencesPane(rawValue: qaPane))
        }
        // QA hook: runs the OpenCode browser re-import in-process (the same
        // code path as the settings button) so the session fetch can be
        // observed from stderr without GUI interaction.
        if ProcessInfo.processInfo.environment["TOKENBAR_QA_REIMPORT_OPENCODE"] == "1" {
            DispatchQueue.main.asyncAfter(deadline: .now() + 4.0) { [weak self] in
                self?.statusItem?.reimportOpenCodeForQA()
            }
        }
        if ProcessInfo.processInfo.environment["TOKENBAR_QA_REIMPORT_SENSENOVA"] == "1" {
            DispatchQueue.main.asyncAfter(deadline: .now() + 3.0) { [weak self] in
                self?.statusItem?.reimportSenseNovaForQA()
            }
        }
        if ProcessInfo.processInfo.environment["TOKENBAR_QA_REIMPORT_STEPFUN"] == "1" {
            DispatchQueue.main.asyncAfter(deadline: .now() + 3.0) { [weak self] in
                self?.statusItem?.reimportStepFunForQA()
            }
        }
        if ProcessInfo.processInfo.environment["TOKENBAR_QA_PROBE_COOKIES"] == "1" {
            DispatchQueue.main.asyncAfter(deadline: .now() + 3.0) {
                QAProbe.run()
            }
        }
        if qaPopMenu {
            // Give the status item + first provider fetch a moment to settle
            // before programmatically clicking the menu open.
            DispatchQueue.main.asyncAfter(deadline: .now() + 4.0) { [weak self] in
                self?.statusItem?.popMenuForQA()
            }
        }
    }

    /// Double-clicking the app, Spotlight/Raycast, or `open` on an
    /// already-running instance all arrive here. The Settings scene carries
    /// the real UI now, so a reopen simply focuses it.
    func applicationShouldHandleReopen(_ sender: NSApplication,
                                       hasVisibleWindows: Bool) -> Bool {
        statusItem?.showSettings()
        return false
    }
}
