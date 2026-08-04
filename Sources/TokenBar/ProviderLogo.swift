import AppKit

/// Lazy-loaded provider brand icons, copied from CodexBar's resources.
/// Rendered as 16×16 template images, matching CodexBar's ProviderBrandIcon size.
@MainActor
enum ProviderLogo {
    private static let size = NSSize(width: 16, height: 16)
    private static var cache: [ProviderTab: NSImage] = [:]

    static func image(for tab: ProviderTab) -> NSImage? {
        if let cached = cache[tab] {
            return cached
        }
        let image: NSImage?
        switch tab {
        case .nebula:
            // Official site logo (PNG icon). Template so it adopts the menu tint.
            image = loadResource(named: "ProviderIcon-nebula", extension: "png")
        case .ark, .opencode, .deepseek:
            image = loadResource(named: fileName(for: tab), extension: "svg")
        }
        if let image {
            cache[tab] = image
        }
        return image
    }

    private static func loadResource(named name: String, extension ext: String) -> NSImage? {
        guard let resource = resourceBundle?.url(
            forResource: name,
            withExtension: ext),
            let image = NSImage(contentsOf: resource)
        else {
            return nil
        }
        image.size = size
        image.isTemplate = true
        return image
    }

    /// A ringed planet on a faint orbit: reads as a small template glyph at
    /// 16pt and stays neutral across light/dark menu appearances.
    private static func fileName(for tab: ProviderTab) -> String {
        switch tab {
        case .ark: "ProviderIcon-doubao"
        case .opencode: "ProviderIcon-opencode"
        case .deepseek: "ProviderIcon-deepseek"
        case .nebula: "ProviderIcon-nebula"
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
