import AppKit
import SwiftUI

@main
struct ArkBarApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        // No real windows; the app lives entirely in the menu bar.
        // A minimal Settings scene keeps SwiftUI happy without showing a window.
        Settings {
            EmptyView()
        }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var store: UsageStore?
    private var statusItem: StatusItemController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        // No Dock icon; pure menu-bar accessory.
        let visualQA = ProcessInfo.processInfo.environment["ARKBAR_SHOW_SETTINGS"] == "1"
        NSApp.setActivationPolicy(visualQA ? .regular : .accessory)
        OpenCodeGoBrowserSession.configureKeychainPrompt()

        let store = UsageStore()
        self.store = store
        self.statusItem = StatusItemController(store: store)
        store.start()

        // Read-only visual QA hook for local development. Normal launches never
        // set this environment variable and retain the menu-bar-only behavior.
        if visualQA {
            statusItem?.showSettings()
        }
    }
}
