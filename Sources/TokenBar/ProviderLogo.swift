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
        let image: NSImage?
        switch tab {
        case .nebula:
            // The relay has no official icon; draw a simple nebula/planet glyph.
            image = makeNebulaIcon()
        case .ark, .opencode, .deepseek:
            guard let resource = resourceBundle?.url(
                forResource: fileName(for: tab),
                withExtension: "svg"),
                let loaded = NSImage(contentsOf: resource)
            else {
                return nil
            }
            loaded.size = size
            loaded.isTemplate = true
            image = loaded
        }
        if let image {
            cache[tab] = image
        }
        return image
    }

    /// A ringed planet on a faint orbit: reads as a small template glyph at
    /// 16pt and stays neutral across light/dark menu appearances.
    private static func makeNebulaIcon() -> NSImage {
        let image = NSImage(size: size, flipped: false) { rect in
            let stroke = NSBezierPath(ovalIn: rect.insetBy(dx: 1.4, dy: 1.4))
            stroke.lineWidth = 1.1
            NSColor.labelColor.setStroke()
            stroke.stroke()

            // Orbit ellipse tilted slightly, clipped to the canvas.
            let orbit = NSBezierPath()
            orbit.appendOval(in: NSRect(x: -3, y: 6.2, width: 22, height: 5.6))
            orbit.lineWidth = 0.9
            orbit.stroke()

            // Planet on the orbit + centre dot.
            NSColor.labelColor.setFill()
            NSBezierPath(ovalIn: NSRect(x: 1.8, y: 10.6, width: 2.6, height: 2.6)).fill()
            NSBezierPath(ovalIn: NSRect(x: 7.0, y: 7.0, width: 2.0, height: 2.0)).fill()
            return true
        }
        image.isTemplate = true
        return image
    }

    private static func fileName(for tab: ProviderTab) -> String {
        switch tab {
        case .ark: "ProviderIcon-doubao"
        case .opencode: "ProviderIcon-opencode"
        case .deepseek: "ProviderIcon-deepseek"
        case .nebula: "" // programmatic icon, never a resource
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
