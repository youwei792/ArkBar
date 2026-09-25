import AppKit
import Foundation
import SweetCookieKit

/// Shared, provider-aware keychain prompt for browser-cookie imports.
/// SweetCookieKit invokes one global handler before decrypting any browser's
/// cookie store, so the alert must name the provider whose import the user
/// just triggered — not whichever provider happened to register the handler.
/// The handler is a Void callback (the real gate is the system keychain
/// dialog that follows), so the alert is explanatory and says so.
enum BrowserKeychainPrompt {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var providerName: String?

    /// Names the provider whose import is about to run; reset to nil when it
    /// finishes. Import paths are user-triggered and serialized per provider.
    nonisolated static func setActiveProvider(_ name: String?) {
        lock.withLock { providerName = name }
    }

    nonisolated static func configure() {
        BrowserCookieKeychainPromptHandler.handler = { context in
            let provider = BrowserKeychainPrompt.currentProvider
            if Thread.isMainThread {
                MainActor.assumeIsolated {
                    present(label: context.label, provider: provider)
                }
            } else {
                DispatchQueue.main.sync {
                    MainActor.assumeIsolated {
                        present(label: context.label, provider: provider)
                    }
                }
            }
        }
    }

    private nonisolated static var currentProvider: String? {
        lock.withLock { providerName }
    }

    @MainActor
    private static func present(label: String, provider: String?) {
        let alert = NSAlert()
        alert.alertStyle = .informational
        alert.messageText = L(.browserKeychainAccessTitle)
        alert.informativeText = String(
            format: L(.browserKeychainAccessMessage),
            label,
            provider ?? L(.browserKeychainAccessFallback))
        alert.addButton(withTitle: L(.continueAction))
        alert.runModal()
    }
}
