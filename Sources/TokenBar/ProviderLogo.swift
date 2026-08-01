import AppKit

/// Lazy-loaded provider brand icons, copied from CodexBar's resources.
/// Rendered as 16×16 template images so they adopt the menu's foreground tint.
@MainActor
enum ProviderLogo {
    private static let size = NSSize(width: 16, height: 16)
    private static var cache: [ProviderTab: NSImage] = [:]

    static func image(for tab: ProviderTab) -> NSImage? {
        if let cached = cache[tab] {
            return cached
        }
        guard let resource = resourceBundle?.url(
            forResource: fileName(for: tab),
            withExtension: "svg"),
            let image = NSImage(contentsOf: resource)
        else {
            return nil
        }
        image.size = size
        image.isTemplate = true
        cache[tab] = image
        return image
    }

    private static func fileName(for tab: ProviderTab) -> String {
        switch tab {
        case .ark: "ProviderIcon-doubao"
        case .opencode: "ProviderIcon-opencode"
        case .deepseek: "ProviderIcon-deepseek"
        }
    }

    /// SwiftPM creates a `TokenBar_TokenBar.bundle` for the target's resources.
    /// Inside a packaged .app it is copied next to the executable; tests and
    /// bare `swift run` fall back to Bundle.module or the main bundle.
    private static let resourceBundle: Bundle? = {
        guard Bundle.main.bundleURL.pathExtension == "app" else {
            return Bundle.module
        }
        if let bundleURL = Bundle.main.url(forResource: "TokenBar_TokenBar", withExtension: "bundle"),
           let bundle = Bundle(url: bundleURL)
        {
            return bundle
        }
        return Bundle.main
    }()

    static func resetCacheForTesting() {
        cache.removeAll()
    }
}
