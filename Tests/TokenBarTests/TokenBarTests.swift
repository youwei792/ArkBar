import Testing
import Foundation
import AppKit
import ObjectiveC.runtime
@testable import TokenBar

@Suite("ArkCLIProvider decode")
struct ArkCLIDecodeTests {
    /// Standard arkcli output (AgentPlan personal + team), taken from the arkcli-usage skill docs.
    private let sampleJSON = #"""
    {
      "viewer": { "auth_method": "sso", "user_id": "12345", "user_name": "alice" },
      "items": [
        {
          "product": "agent-plan",
          "edition": "personal",
          "tier": "medium",
          "subscribed": true,
          "periods": [
            { "label": "5h",      "used": 250,    "total": 1000,   "percent": 25, "reset_at": "2024-05-30T05:26:40+08:00" },
            { "label": "weekly",  "used": 12500,  "total": 50000,  "percent": 25, "reset_at": "2024-06-06T00:26:40+08:00" },
            { "label": "monthly", "used": 50000,  "total": 200000, "percent": 25, "reset_at": "2024-06-29T05:06:40+08:00" }
          ]
        },
        {
          "product": "coding-plan",
          "edition": "personal",
          "subscribed": true,
          "updated_at": 1717000000000,
          "periods": [
            { "label": "session", "percent": 73 },
            { "label": "weekly",  "percent": 31 },
            { "label": "monthly", "percent": 12 }
          ]
        }
      ]
    }
    """#

    @Test("Parses two subscribed plans with canonical labels")
    func parsesMultiplePlans() throws {
        let data = sampleJSON.data(using: .utf8)!
        let snapshot = try ArkCLIProvider.decode(stdout: data, date: Date(timeIntervalSince1970: 0))

        #expect(snapshot.providerName == "arkcli")
        #expect(snapshot.authMethod == "sso")
        // updated_at (1717000000000 ms -> 2024-05-29) should win over the passed-in date(1970).
        #expect(snapshot.updatedAt.timeIntervalSince1970 > 1_700_000_000)

        #expect(snapshot.plans.count == 2)

        let agentPlan = snapshot.plans.first { $0.product == .agentPlan }
        #expect(agentPlan != nil)
        #expect(agentPlan?.tier == "medium")
        // Windows sorted by rank: 5-hour(0) < weekly(1) < monthly(2).
        #expect(agentPlan?.windows.map(\.label) == ["5-hour", "Weekly", "Monthly"])
        let agent5h = agentPlan?.windows.first
        #expect(agent5h?.usedPercent == 25)
        #expect(agent5h?.used == 250)
        #expect(agent5h?.total == 1000)
        #expect(agent5h?.resetsAt != nil)

        let codingPlan = snapshot.plans.first { $0.product == .codingPlan }
        #expect(codingPlan != nil)
        #expect(codingPlan?.windows.map(\.label) == ["Session", "Weekly", "Monthly"])
        let session = codingPlan?.windows.first
        #expect(session?.usedPercent == 73)
        // CodingPlan omits used/total.
        #expect(session?.used == nil)
        #expect(session?.total == nil)
    }

    @Test("Tightest window across plans is the highest-used one")
    func tightestWindow() throws {
        let data = sampleJSON.data(using: .utf8)!
        let snapshot = try ArkCLIProvider.decode(stdout: data, date: Date())
        // Coding plan session is 73%, agent plan max is 25% -> 73% wins.
        #expect(snapshot.tightestWindow?.usedPercent == 73)
        #expect(snapshot.tightestWindow?.remainingPercent ?? 0 == 27)
    }

    @Test("Menu-bar session window is not replaced by the tightest monthly window")
    func keepsSessionForMenuBar() throws {
        let data = sampleJSON.data(using: .utf8)!
        let snapshot = try ArkCLIProvider.decode(stdout: data, date: Date())
        // The Coding Plan Session is 73% used / 27% remaining. It is the
        // status-item value even though this snapshot may contain other windows.
        #expect(snapshot.sessionWindow?.label == "Session")
        #expect(snapshot.sessionWindow?.remainingPercent == 27)
    }

    @Test("auth_method=none throws not-authenticated")
    func throwsWhenNotAuthenticated() throws {
        let json = #"{"viewer":{"auth_method":"none"},"items":[]}"#
        #expect(throws: UsageError.self) {
            _ = try ArkCLIProvider.decode(stdout: json.data(using: .utf8)!, date: Date())
        }
    }

    @Test("subscribed=false items are skipped")
    func skipsUnsubscribed() throws {
        let json = #"""
        {"viewer":{"auth_method":"sso"},"items":[
          {"product":"coding-plan","subscribed":false,"periods":[]}
        ]}
        """#
        #expect(throws: UsageError.self) {
            _ = try ArkCLIProvider.decode(stdout: json.data(using: .utf8)!, date: Date())
        }
    }

    @Test("epoch-seconds updated_at is handled (not treated as ms)")
    func handlesEpochSeconds() throws {
        // 1717000000 seconds (not ms) - below 1e11, so treated as seconds.
        let json = #"""
        {"viewer":{"auth_method":"sso"},"items":[
          {"product":"coding-plan","subscribed":true,"updated_at":1717000000,
           "periods":[{"label":"session","percent":10}]}
        ]}
        """#
        let data = json.data(using: .utf8)!
        let snapshot = try ArkCLIProvider.decode(stdout: data, date: Date(timeIntervalSince1970: 0))
        #expect(snapshot.updatedAt.timeIntervalSince1970 == 1717000000)
    }

    @Test("reset_at as epoch number (ms vs s) is decoded")
    func resetAtNumber() throws {
        let json = #"""
        {"viewer":{"auth_method":"sso"},"items":[
          {"product":"coding-plan","subscribed":true,
           "periods":[{"label":"session","percent":10,"reset_at":1717000000000}]}
        ]}
        """#
        let data = json.data(using: .utf8)!
        let snapshot = try ArkCLIProvider.decode(stdout: data, date: Date())
        let reset = snapshot.plans.first?.windows.first?.resetsAt
        #expect(reset != nil)
        #expect(reset?.timeIntervalSince1970 == 1717000000)
    }

    @Test("Resolves the executable inside PATH instead of a PATH directory")
    func resolvesExecutablePath() {
        let environment = ["PATH": "/tmp"]
        #expect(ArkCLIProvider.resolveArkcliPath(environment: environment) != "/tmp")
    }

}

@Suite("VolcAPIProvider decode")
struct VolcAPIDecodeTests {
    @Test("Parses Volcengine OpenAPI CodingPlanUsage response")
    func parsesOpenAPIResponse() throws {
        // Volcengine shape uses PascalCase keys under "Result".
        let json = #"""
        {"Result":{"Status":"ok","UpdateTimestamp":1717000000000,
          "QuotaUsage":[
            {"Level":"session","Percent":73,"ResetTimestamp":1717000000000},
            {"Level":"weekly","Percent":31,"ResetTimestamp":1718000000000},
            {"Level":"monthly","Percent":12,"ResetTimestamp":1719000000000}
          ]}}
        """#
        let data = json.data(using: .utf8)!
        let snapshot = try VolcAPIProvider.decodeCodingPlanUsage(from: data, date: Date(timeIntervalSince1970: 0))
        #expect(snapshot.authMethod == "aksk")
        #expect(snapshot.plans.count == 1)
        let plan = snapshot.plans.first
        #expect(plan?.product == .codingPlan)
        #expect(plan?.windows.map(\.label) == ["Session", "Weekly", "Monthly"])
        #expect(plan?.windows.first?.usedPercent == 73)
        // AK/SK path never has used/total absolute values.
        #expect(plan?.windows.first?.used == nil)
    }
}

@Suite("OpenCode Go provider decode")
struct OpenCodeGoProviderTests {
    @Test("Cookie header keeps only the OpenCode session credential")
    func filtersCookieHeader() {
        let header = OpenCodeGoCookieSupport.requestCookieHeader(
            from: "Cookie: analytics=drop; auth=session-value; theme=dark; __Host-auth=host-value")
        #expect(header == "auth=session-value; __Host-auth=host-value")
        #expect(OpenCodeGoCookieSupport.requestCookieHeader(from: "theme=dark") == nil)
    }

    @Test("Nested usage payload decodes percentages, reset dates, and renewal")
    func decodesNestedPayload() throws {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let text = #"""
        {
          "data": {
            "renewAt": "2026-09-24T23:59:00Z",
            "usage": {
              "rollingUsage": { "usagePercent": 0.4, "resetAt": 1700003600 },
              "weeklyUsage": { "used": 12, "limit": 100, "resetInSec": 7200 },
              "monthlyUsage": { "usagePercent": 66.5, "resetInSec": "86400" }
            }
          }
        }
        """#
        let usage = try OpenCodeGoProvider.decodeUsagePage(text, now: now)
        #expect(usage.rolling.usedPercent == 40)
        #expect(usage.weekly?.usedPercent == 12)
        #expect(usage.monthly?.usedPercent == 66.5)
        #expect(usage.rolling.resetsAt?.timeIntervalSince1970 == 1_700_003_600)
        #expect(usage.weekly?.resetsAt?.timeIntervalSince1970 == 1_700_007_200)
        #expect(usage.expiryDate != nil)
    }

    @Test("Workspace override accepts a dashboard URL or bare ID")
    func normalizesWorkspaceID() {
        #expect(OpenCodeGoProvider.normalizeWorkspaceID("wrk_abc123") == "wrk_abc123")
        #expect(OpenCodeGoProvider.normalizeWorkspaceID("https://opencode.ai/workspace/wrk_def456/go") == "wrk_def456")
        #expect(OpenCodeGoProvider.normalizeWorkspaceID("not-a-workspace") == nil)
    }

    @Test("Authoritative 100 percent usage remains zero percent left")
    func preservesExhaustedQuota() throws {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let usage = try OpenCodeGoProvider.decodeUsagePage(
            #"{"rollingUsage":{"usagePercent":100,"resetInSec":3600}}"#,
            now: now)
        let snapshot = OpenCodeGoProvider.makeProviderSnapshot(
            usage,
            authMethod: "browser")

        #expect(snapshot.sessionWindow?.usedPercent == 100)
        #expect(snapshot.sessionWindow?.remainingPercent == 0)
    }

    @Test("Zero usage is not replaced by a local estimate")
    func preservesUnusedQuota() throws {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let usage = try OpenCodeGoProvider.decodeUsagePage(
            #"{"rollingUsage":{"usagePercent":0,"resetInSec":3600}}"#,
            now: now)
        let snapshot = OpenCodeGoProvider.makeProviderSnapshot(
            usage,
            authMethod: "browser")

        #expect(snapshot.sessionWindow?.usedPercent == 0)
        #expect(snapshot.sessionWindow?.remainingPercent == 100)
    }
}

@Suite("MenuBuilder formatting")
struct MenuBuilderTests {
    @Test("Progress bar fills proportionally")
    func progressBar() {
        #expect(MenuBuilder.progressBar(0) == "░░░░░░░░░░")
        #expect(MenuBuilder.progressBar(100) == "██████████")
        #expect(MenuBuilder.progressBar(50) == "█████░░░░░")
        #expect(MenuBuilder.progressBar(73) == "███████░░░")
    }

    @Test("Countdown formats days/hours/minutes")
    func countdown() {
        let now = Date(timeIntervalSince1970: 1_000_000)
        #expect(MenuBuilder.countdown(from: now, to: now.addingTimeInterval(30)) == "in 0m")
        #expect(MenuBuilder.countdown(from: now, to: now.addingTimeInterval(5 * 60)) == "in 5m")
        #expect(MenuBuilder.countdown(from: now, to: now.addingTimeInterval(3 * 3600 + 5 * 60)) == "in 3h 5m")
        #expect(MenuBuilder.countdown(from: now, to: now.addingTimeInterval(2 * 86400 + 3 * 3600)) == "in 2d 3h")
        // Past -> "now".
        #expect(MenuBuilder.countdown(from: now, to: now.addingTimeInterval(-10)) == "now")
    }

    @Test("Refresh is a persistent menu row rather than a closing menu action")
    @MainActor
    func refreshRowStaysInTheMenu() {
        let menu = MenuBuilder.build(.init(
            status: .loading,
            selectedMenu: .provider(.ark),
            onSelectTab: { _ in },
            onSelectSummary: nil,
            lastUpdatedAt: Date(),
            isRefreshing: false,
            now: Date(),
            onRefresh: {},
            onSettings: {},
            onQuit: {}))
        let refreshItem = menu.items.first { $0.title == L(.refreshNow) }
        #expect(refreshItem?.action == nil)
        #expect(refreshItem?.view is RefreshMenuItemView)
        let switcherItem = menu.items.first { $0.view is ProviderSwitcherView }
        #expect(switcherItem?.isEnabled == true)
    }

    @Test("Provider switch mutates one persistent menu and replaces provider-specific actions")
    @MainActor
    func providerSwitchReusesMenu() {
        let menu = NSMenu()
        MenuBuilder.populate(menu, with: .init(
            status: .loading,
            selectedMenu: .provider(.ark),
            onSelectTab: { _ in },
            onSelectSummary: nil,
            lastUpdatedAt: nil,
            isRefreshing: false,
            now: Date(),
            onRefresh: {},
            onSettings: {},
            onQuit: {}))
        #expect(menu.items.contains { $0.title == L(.openArkcliLogin) })
        #expect(!menu.items.contains { $0.title == L(.openCodeGo) })

        let identity = ObjectIdentifier(menu)
        MenuBuilder.populate(menu, with: .init(
            status: .error(message: "OpenCode test error"),
            selectedMenu: .provider(.opencode),
            onSelectTab: { _ in },
            onSelectSummary: nil,
            lastUpdatedAt: nil,
            isRefreshing: false,
            now: Date(),
            onRefresh: {},
            onSettings: {},
            onQuit: {}))
        #expect(ObjectIdentifier(menu) == identity)
        #expect(!menu.items.contains { $0.title == L(.openArkcliLogin) })
        #expect(menu.items.contains { $0.title == L(.openCodeGo) })
    }

    @Test("Provider switching uses a fixed-width live status-item anchor")
    @MainActor
    func providerSwitchKeepsStatusItemAnchor() {
        #expect(StatusItemController.statusItemLength(for: .iconOnly) == 24)
        #expect(StatusItemController.statusItemLength(for: .iconAndPercent) == 58)
        #expect(StatusItemController.statusItemLength(for: .percentOnly) == 40)
        #expect(StatusItemController.statusItemLength(for: .logoOnly) == 24)
        #expect(StatusItemController.statusItemLength(for: .logoAndPercent) == 58)
        #expect(StatusItemController.statusItemLength(for: .logoAndBar) == 46)
    }

    @Test("Clicking OpenCode immediately replaces Ark content in the same menu")
    @MainActor
    func providerSwitcherClickUpdatesContentImmediately() {
        var menu: NSMenu!
        // Keep the switcher at 2 providers so labels stay visible (4+ tabs go icon-only).
        let openCodeState = MenuBuilder.State(
            status: .error(message: "OpenCode test error"),
            selectedMenu: .provider(.opencode),
            visibleTabs: [.ark, .opencode],
            onSelectTab: { _ in },
            onSelectSummary: nil,
            lastUpdatedAt: nil,
            isRefreshing: false,
            now: Date(),
            onRefresh: {},
            onSettings: {},
            onQuit: {})
        menu = MenuBuilder.build(.init(
            status: .loading,
            selectedMenu: .provider(.ark),
            visibleTabs: [.ark, .opencode],
            onSelectTab: { tab in
                if tab == .opencode {
                    MenuBuilder.populate(menu, with: openCodeState)
                }
            },
            onSelectSummary: nil,
            lastUpdatedAt: nil,
            isRefreshing: false,
            now: Date(),
            onRefresh: {},
            onSettings: {},
            onQuit: {}))

        let switcher = menu.items.compactMap { $0.view as? ProviderSwitcherView }.first
        let openCodeButton = switcher?.subviews
            .compactMap { $0 as? NSButton }
            .first {
                $0.title == ProviderTab.opencode.displayName
                    || $0.toolTip == ProviderTab.opencode.displayName
            }
        openCodeButton?.performClick(nil)

        #expect(!menu.items.contains { $0.title == L(.openArkcliLogin) })
        #expect(menu.items.contains { $0.title == L(.openCodeGo) })
        let refreshedSwitcher = menu.items.compactMap { $0.view as? ProviderSwitcherView }.first
        let selectedButton = refreshedSwitcher?.subviews
            .compactMap { $0 as? NSButton }
            .first { $0.state == .on }
        #expect(
            selectedButton?.title == ProviderTab.opencode.displayName
                || selectedButton?.toolTip == ProviderTab.opencode.displayName)
    }

    @Test("Refresh row switches to the in-flight state before its action returns")
    @MainActor
    func refreshRowShowsImmediateFeedback() {
        var refreshCalls = 0
        let view = RefreshMenuItemView(
            title: L(.refreshNow),
            isRefreshing: false,
            lastUpdatedAt: Date(),
            errorMessage: nil,
            action: { refreshCalls += 1 },
            width: 300)

        #expect(view.accessibilityPerformPress())
        #expect(refreshCalls == 1)
        #expect(view.isAccessibilityEnabled() == false)
        let labels = view.subviews.compactMap { $0 as? NSTextField }.map(\.stringValue)
        #expect(labels.contains(L(.refreshing)))
        #expect(labels.contains(L(.refreshDetails)))
        let spinner = view.subviews.compactMap { $0 as? NSProgressIndicator }.first
        #expect(spinner?.isHidden == false)
    }
}

@Suite("IconRenderer")
@MainActor
struct IconRendererTests {
    @Test("Produces a template image at 18x18pt")
    func makesTemplateImage() {
        let icon = IconRenderer.makeBarIcon(remainingPercent: 50, stale: false)
        #expect(icon.size.width == 18)
        #expect(icon.size.height == 18)
        #expect(icon.isTemplate == true)
    }

    @Test("Logo-only and logo+bar icons stay template images")
    func logoIconsAreTemplate() {
        let logo = IconRenderer.makeLogoIcon(tab: .deepseek)
        #expect(logo.isTemplate == true)
        let combo = IconRenderer.makeLogoAndBarIcon(tab: .deepseek, remainingPercent: 73, stale: false)
        #expect(combo.isTemplate == true)
        #expect(combo.size.width == 30)
    }

    @Test("Writes menu-bar style strip for visual inspection")
    func writesMenuBarStylesPNG() throws {
        // One row per DisplayMode so a human can eyeball the combos.
        let modes: [(AppSettings.DisplayMode, String)] = [
            (.iconOnly, "bar"),
            (.iconAndPercent, "bar+%"),
            (.percentOnly, "%"),
            (.logoOnly, "logo"),
            (.logoAndPercent, "logo+%"),
            (.logoAndBar, "logo+bar"),
        ]
        let cell = 96
        let strip = NSImage(size: NSSize(width: cell * modes.count, height: cell), flipped: false) { rect in
            NSColor(calibratedWhite: 0.25, alpha: 1).setFill()
            rect.fill()
            for (i, mode) in modes.enumerated() {
                let sub = NSImage(size: NSSize(width: cell, height: cell), flipped: false) { r in
                    NSColor.clear.setFill()
                    r.fill()
                    let icon: NSImage? = switch mode.0 {
                    case .iconOnly, .iconAndPercent: IconRenderer.makeBarIcon(remainingPercent: 73, stale: false)
                    case .percentOnly: nil
                    case .logoOnly: IconRenderer.makeLogoIcon(tab: .deepseek)
                    case .logoAndPercent: IconRenderer.makeLogoIcon(tab: .deepseek)
                    case .logoAndBar: IconRenderer.makeLogoAndBarIcon(tab: .deepseek, remainingPercent: 73, stale: false)
                    }
                    // Tint template black for visibility on the light strip.
                    let tinted = NSImage(size: icon?.size ?? .zero, flipped: false) { tr in
                        NSColor.black.setFill(); tr.fill()
                        icon?.draw(in: tr, from: .zero, operation: .destinationIn, fraction: 1)
                        return true
                    }
                    if let icon {
                        tinted.draw(in: r.insetBy(dx: 12, dy: 24), from: .zero, operation: .sourceOver, fraction: 1)
                    }
                    let title = mode.1
                    let attrs: [NSAttributedString.Key: Any] = [
                        .font: NSFont.monospacedDigitSystemFont(ofSize: 10, weight: .medium),
                        .foregroundColor: NSColor.black,
                    ]
                    let size = title.size(withAttributes: attrs)
                    title.draw(at: NSPoint(x: r.midX - size.width / 2, y: 6), withAttributes: attrs)
                    return true
                }
                sub.draw(in: NSRect(x: i * cell, y: 0, width: cell, height: cell))
            }
            return true
        }
        let tiff = try #require(strip.tiffRepresentation)
        let rep = try #require(NSBitmapImageRep(data: tiff))
        let png = try #require(rep.representation(using: .png, properties: [:]))
        try png.write(to: URL(fileURLWithPath: "/tmp/tokenbar_menu_styles.png"))
        #expect(FileManager.default.fileExists(atPath: "/tmp/tokenbar_menu_styles.png"))
    }

    @Test("Writes a tinted PNG to /tmp for visual inspection")
    func writesPNG() throws {
        // Render several states onto a white strip so a human can eyeball them.
        let states: [(Double?, Bool, String)] = [
            (27, false, "27%"),
            (73, false, "73%"),
            (nil, true, "no-data/stale"),
            (100, false, "100%"),
        ]
        let cell = 72
        let strip = NSImage(size: NSSize(width: cell * states.count, height: cell), flipped: false) { rect in
            NSColor.white.setFill()
            rect.fill()
            for (i, state) in states.enumerated() {
                let icon = IconRenderer.makeIcon(remainingPercent: state.0, stale: state.1)
                // Tint template icon black on white.
                let tinted = NSImage(size: icon.size, flipped: false) { r in
                    NSColor.black.setFill(); r.fill()
                    icon.draw(in: r, from: .zero, operation: .destinationIn, fraction: 1)
                    return true
                }
                let cellRect = NSRect(x: i * cell, y: 0, width: cell, height: cell)
                tinted.draw(in: cellRect.insetBy(dx: 18, dy: 18), from: .zero, operation: .sourceOver, fraction: 1)
            }
            return true
        }
        let tiff = strip.tiffRepresentation!
        let rep = NSBitmapImageRep(data: tiff)!
        let png = rep.representation(using: .png, properties: [:])!
        try png.write(to: URL(fileURLWithPath: "/tmp/tokenbar_icons.png"))
        #expect(FileManager.default.fileExists(atPath: "/tmp/tokenbar_icons.png"))
    }

    @Test("A 100 percent remaining ring is painted as a full ring")
    func fullRemainingRingIsFilled() throws {
        let full = RingRenderer.makeImage(
            rings: [.init(id: "session", label: "Session", remainingPercent: 100, tone: .session)],
            primaryRemaining: 100,
            primaryLabel: "Session",
            size: 100)
        let empty = RingRenderer.makeImage(
            rings: [.init(id: "session", label: "Session", remainingPercent: 0, tone: .session)],
            primaryRemaining: 0,
            primaryLabel: "Session",
            size: 100)
        let fullRep = NSBitmapImageRep(data: try #require(full.tiffRepresentation))!
        let emptyRep = NSBitmapImageRep(data: try #require(empty.tiffRepresentation))!
        // Bottom centre lies on the only ring. A filled ring is substantially
        // more opaque there than an empty ring's quiet track.
        let fullAlpha = try #require(fullRep.colorAt(x: 50, y: 8)).alphaComponent
        let emptyAlpha = try #require(emptyRep.colorAt(x: 50, y: 8)).alphaComponent
        #expect(fullAlpha > emptyAlpha + 0.4)
    }

    @Test("Status-item hover tracking uses AppKit selector names")
    @MainActor
    func statusItemTrackingSelectorsExist() {
        #expect(class_getInstanceMethod(StatusItemController.self, NSSelectorFromString("mouseEntered:")) != nil)
        #expect(class_getInstanceMethod(StatusItemController.self, NSSelectorFromString("mouseExited:")) != nil)
    }
}

@Suite("Ring arc coverage")
struct RingArcCoverageTests {
    /// Regression: the filled arc used to sweep the wrong direction / wrong span,
    /// so a window with e.g. 69% remaining rendered as a ~full ring. Count the
    /// actual coloured pixels around the circumference rather than assuming the
    /// arc begins at 12 o'clock.
    @MainActor
    private static func isFilled(image: NSImage, ringIndex: Int, at angleDegrees: Int) -> Bool {
        let rep = NSBitmapImageRep(data: image.tiffRepresentation!)!
        let size = Int(rep.size.width)
        let cx = size / 2
        let cy = size / 2
        let ringWidth = 8.0
        let ringGap = 5.0
        let baseRadius = Double(size) / 2 - ringWidth / 2 - 4
        let radius = baseRadius - Double(ringIndex) * (ringWidth + ringGap)
        let radians = Double(angleDegrees) * .pi / 180
        let px = Int((Double(cx) + cos(radians) * radius).rounded())
        let py = Int((Double(size) - (Double(cy) + sin(radians) * radius)).rounded())
        guard px >= 0, px < size, py >= 0, py < size else { return false }
        return rep.colorAt(x: px, y: py)!.alphaComponent > 0.5
    }

    @MainActor
    private static func filledCoverageDegrees(image: NSImage, ringIndex: Int) -> Int {
        stride(from: 0, through: 359, by: 5).reduce(into: 0) { total, degree in
            if isFilled(image: image, ringIndex: ringIndex, at: degree) {
                total += 5
            }
        }
    }

    @Test("A 69%-remaining ring fills ~249°, not the full circle")
    @MainActor
    func partialRingFillsProportionally() throws {
        let ring = RingRenderer.makeImage(
            rings: [.init(id: "monthly", label: "Monthly", remainingPercent: 69, tone: .monthly)],
            primaryRemaining: 69, primaryLabel: "Monthly", size: 132)
        let span = Self.filledCoverageDegrees(image: ring, ringIndex: 0)
        // 69% of 360° = 248.4°. Allow ±20° for the round line-cap overhang.
        #expect(span >= 228 && span <= 268, "expected ~249°, got \(span)°")
    }

    @Test("Real arkcli data: three rings each fill to their own remaining percent")
    @MainActor
    func realDataThreeRings() throws {
        // Exact windows from `arkcli usage plan --format json`.
        let ring = RingRenderer.makeImage(
            rings: [
                .init(id: "monthly", label: "Monthly", remainingPercent: 69.23, tone: .monthly),
                .init(id: "weekly",  label: "Weekly",  remainingPercent: 91.40, tone: .weekly),
                .init(id: "session", label: "Session", remainingPercent: 97.31, tone: .session),
            ],
            primaryRemaining: 97.31, primaryLabel: "Session", size: 132)
        // monthly 69% -> ~249°, weekly 91% -> ~329°, session 97% -> ~350°.
        let monthly = Self.filledCoverageDegrees(image: ring, ringIndex: 0)
        let weekly  = Self.filledCoverageDegrees(image: ring, ringIndex: 1)
        let session = Self.filledCoverageDegrees(image: ring, ringIndex: 2)
        #expect(monthly >= 228 && monthly <= 268, "monthly expected ~249°, got \(monthly)°")
        #expect(weekly  >= 308 && weekly  <= 348, "weekly expected ~329°, got \(weekly)°")
        #expect(session >= 329 && session <= 360, "session expected ~350°, got \(session)°")
    }

    @Test("Arcs start at 12 o'clock and the empty gap grows counterclockwise")
    @MainActor
    func arcsUseReferenceDirection() {
        let ring = RingRenderer.makeImage(
            rings: [.init(id: "session", label: "Session", remainingPercent: 25, tone: .session)],
            primaryRemaining: 25,
            primaryLabel: "Session",
            size: 132)
        // The remaining quarter starts at 12 o'clock and travels clockwise
        // through the upper-right quadrant. The upper-left must stay empty.
        #expect(Self.isFilled(image: ring, ringIndex: 0, at: 70))
        #expect(Self.isFilled(image: ring, ringIndex: 0, at: 20))
        #expect(!Self.isFilled(image: ring, ringIndex: 0, at: 110))
        #expect(!Self.isFilled(image: ring, ringIndex: 0, at: 180))
    }
}

@Suite("Menu card visual regression")
struct MenuCardVisualTests {
    @Test("Long plan metadata and error text stay inside their cards")
    @MainActor
    func longTextCardRendering() throws {
        let now = Date()
        let plan = PlanSnapshot(
            id: "team:extremely-long-seat-identifier-for-layout-regression",
            product: .agentPlanTeam,
            edition: "enterprise-with-a-very-long-edition-name",
            tier: "ultra-long-tier-name",
            seatID: "seat-with-an-unusually-long-identifier",
            subscribed: true,
            windows: [
                UsageWindow(label: "5-hour", usedPercent: 13, used: 13, total: 100, resetsAt: now.addingTimeInterval(5_400)),
                UsageWindow(label: "weekly", usedPercent: 42, used: 420, total: 1_000, resetsAt: now.addingTimeInterval(86_400 * 2)),
                UsageWindow(label: "monthly", usedPercent: 75, used: 750, total: 1_000, resetsAt: now.addingTimeInterval(86_400 * 12)),
            ],
            expiryDate: now.addingTimeInterval(86_400 * 12),
            errorMessage: nil)
        let view = PlanCardView(plan: plan, now: now, width: 340)
        view.updateTrackingAreas()
        #expect(view.trackingAreas.isEmpty)
        #expect(view.subviews.allSatisfy {
            $0.frame.minX >= 0 && $0.frame.maxX <= view.bounds.maxX
        })

        let header = HeaderCardView(
            snapshot: ProviderSnapshot(
                providerName: "arkcli",
                authMethod: "sso",
                plans: [plan],
                updatedAt: now,
                errorMessage: nil),
            width: 340)
        let wordmark = header.subviews
            .compactMap { $0 as? NSTextField }
            .first { $0.stringValue == "TokenBar" }
        #expect(wordmark != nil)
        #expect(wordmark?.frame.width ?? 0 >= ceil(wordmark?.intrinsicContentSize.width ?? 0) + 4)

        // Rendering the ring directly exercises the updated palette and crisp,
        // track-contained endpoint treatment.
        let ring = RingRenderer.makeImage(
            rings: [
                .init(id: "monthly", label: "Monthly", remainingPercent: 25, tone: .monthly),
                .init(id: "weekly", label: "Weekly", remainingPercent: 58, tone: .weekly),
                .init(id: "session", label: "5-hour", remainingPercent: 87, tone: .session),
            ], primaryRemaining: 87, primaryLabel: "5-hour", size: 160)
        // Composite the transparent ring onto the original dark menu-material
        // approximation, so deep violet arcs cannot silently disappear.
        let preview = NSImage(size: ring.size, flipped: false) { rect in
            NSColor(calibratedWhite: 0.30, alpha: 1).setFill()
            rect.fill()
            ring.draw(in: rect)
            return true
        }
        let tiff = preview.tiffRepresentation!
        let rep = NSBitmapImageRep(data: tiff)!
        let png = rep.representation(using: .png, properties: [:])!
        try png.write(to: URL(fileURLWithPath: "/tmp/tokenbar_ring.png"))
        #expect(FileManager.default.fileExists(atPath: "/tmp/tokenbar_ring.png"))

        // Render the real AppKit dashboard hierarchy—not a separately drawn
        // mock—so palette, typography, clipping, and spacing can be inspected
        // together after each visual change.
        let switcher = ProviderSwitcherView(tabs: ProviderTab.allCases, selected: .provider(.ark), showSummary: false, width: 340, onSelect: { _ in })
        let card = PlanCardView(plan: plan, now: now, width: 340)
        let totalHeight = switcher.bounds.height + header.bounds.height + card.bounds.height
        let dashboard = NSView(frame: NSRect(x: 0, y: 0, width: 340, height: totalHeight))
        dashboard.wantsLayer = true
        dashboard.layer?.backgroundColor = NSColor(calibratedWhite: 0.30, alpha: 1).cgColor
        card.frame.origin = .zero
        header.frame.origin = NSPoint(x: 0, y: card.bounds.height)
        switcher.frame.origin = NSPoint(x: 0, y: card.bounds.height + header.bounds.height)
        dashboard.addSubview(card)
        dashboard.addSubview(header)
        dashboard.addSubview(switcher)
        dashboard.layoutSubtreeIfNeeded()

        let dashboardRep = try #require(dashboard.bitmapImageRepForCachingDisplay(in: dashboard.bounds))
        dashboard.cacheDisplay(in: dashboard.bounds, to: dashboardRep)
        let dashboardPNG = try #require(
            dashboardRep.representation(using: .png, properties: [:]))
        try dashboardPNG.write(to: URL(fileURLWithPath: "/tmp/tokenbar_dashboard.png"))
        #expect(FileManager.default.fileExists(atPath: "/tmp/tokenbar_dashboard.png"))
    }
}

@Suite("DeepSeekProvider balance decode")
struct DeepSeekBalanceDecodeTests {
    private static let utcCalendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        return calendar
    }()

    @Test("Parses API-key balance with string amounts, preferring funded USD")
    func parsesApiBalance() throws {
        let json = #"""
        {"is_available": true, "balance_infos": [
          {"currency": "USD", "total_balance": "0.00", "granted_balance": "0.00", "topped_up_balance": "0.00"},
          {"currency": "CNY", "total_balance": "45.30", "granted_balance": "5.00", "topped_up_balance": "40.30"}
        ]}
        """#
        let balance = try DeepSeekProvider.decodeBalance(data: json.data(using: .utf8)!)
        #expect(balance.isAvailable == true)
        #expect(balance.currency == "CNY")
        #expect(balance.totalBalance == 45.30)
        #expect(balance.toppedUpBalance == 40.30)
        #expect(balance.grantedBalance == 5.00)
    }

    @Test("Prefers USD when it has a funded balance")
    func prefersFundedUSD() throws {
        let json = #"""
        {"is_available": true, "balance_infos": [
          {"currency": "USD", "total_balance": "12.34", "granted_balance": "0.00", "topped_up_balance": "12.34"},
          {"currency": "CNY", "total_balance": "1.00", "granted_balance": "0.00", "topped_up_balance": "1.00"}
        ]}
        """#
        let balance = try DeepSeekProvider.decodeBalance(data: json.data(using: .utf8)!)
        #expect(balance.currency == "USD")
        #expect(balance.totalBalance == 12.34)
    }

    @Test("Empty balance_infos yields a zero balance")
    func emptyBalanceInfos() throws {
        let json = #"{"is_available": true, "balance_infos": []}"#
        let balance = try DeepSeekProvider.decodeBalance(data: json.data(using: .utf8)!)
        #expect(balance.totalBalance == 0)
        #expect(balance.isAvailable == false)
    }

    @Test("is_available=false is preserved")
    func unavailableFlag() throws {
        let json = #"""
        {"is_available": false, "balance_infos": [
          {"currency": "USD", "total_balance": "5.00", "granted_balance": "0.00", "topped_up_balance": "5.00"}
        ]}
        """#
        let balance = try DeepSeekProvider.decodeBalance(data: json.data(using: .utf8)!)
        #expect(balance.isAvailable == false)
        #expect(balance.totalBalance == 5.00)
    }

    @Test("Platform wallets accept numeric or string balances")
    func platformWallets() throws {
        let json = #"""
        {"code": 0, "data": {"biz_code": 0, "biz_data": {
          "normal_wallets": [{"balance": 40.3, "currency": "CNY"}],
          "bonus_wallets": [{"balance": "5.00", "currency": "CNY"}]
        }}}
        """#
        let balance = try DeepSeekProvider.decodePlatformBalance(data: json.data(using: .utf8)!)
        #expect(balance.currency == "CNY")
        #expect(balance.totalBalance == 45.30)
        #expect(balance.toppedUpBalance == 40.30)
        #expect(balance.grantedBalance == 5.00)
    }

    @Test("Platform auth error codes throw invalid-token")
    func platformAuthError() {
        let json = #"{"code": 40002, "data": {"biz_code": 0, "biz_data": {}}}"#
        do {
            _ = try DeepSeekProvider.decodePlatformBalance(data: json.data(using: .utf8)!)
            Issue.record("expected deepSeekInvalidPlatformToken")
        } catch let error as UsageError {
            if case .deepSeekInvalidPlatformToken = error {
                // expected
            } else {
                Issue.record("unexpected error: \(error)")
            }
        } catch {
            Issue.record("unexpected error type: \(error)")
        }
    }

    @Test("Aggregates today and month tokens, cost, and requests")
    func aggregatesUsage() throws {
        // UTC calendar so the fixed `now` maps to a deterministic day string.
        let now = Date(timeIntervalSince1970: 1_785_672_000) // 2026-08-02 12:00 UTC
        let amount = #"""
        {"code": 0, "data": {"biz_code": 0, "biz_data": {
          "total": [
            {"model": "deepseek-chat", "usage": [
              {"type": "PROMPT_CACHE_HIT_TOKEN", "amount": "300"},
              {"type": "PROMPT_CACHE_MISS_TOKEN", "amount": "1200"},
              {"type": "RESPONSE_TOKEN", "amount": "600"},
              {"type": "REQUEST", "amount": "5"}
            ]}
          ],
          "days": [
            {"date": "2026-08-01", "data": [
              {"model": "deepseek-chat", "usage": [
                {"type": "PROMPT_CACHE_HIT_TOKEN", "amount": "100"},
                {"type": "PROMPT_CACHE_MISS_TOKEN", "amount": "900"},
                {"type": "RESPONSE_TOKEN", "amount": "500"},
                {"type": "REQUEST", "amount": "3"}
              ]}
            ]},
            {"date": "2026-08-02", "data": [
              {"model": "deepseek-chat", "usage": [
                {"type": "PROMPT_CACHE_HIT_TOKEN", "amount": "200"},
                {"type": "PROMPT_CACHE_MISS_TOKEN", "amount": "300"},
                {"type": "RESPONSE_TOKEN", "amount": "100"},
                {"type": "REQUEST", "amount": "2"}
              ]}
            ]}
          ]
        }}}
        """#
        let cost = #"""
        {"code": 0, "data": {"biz_code": 0, "biz_data": [{
          "currency": "CNY",
          "days": [
            {"date": "2026-08-01", "data": [
              {"model": "deepseek-chat", "usage": [
                {"type": "PROMPT_CACHE_HIT_TOKEN", "amount": "0.01"},
                {"type": "PROMPT_CACHE_MISS_TOKEN", "amount": "0.05"},
                {"type": "RESPONSE_TOKEN", "amount": "0.02"},
                {"type": "REQUEST", "amount": "0.00"}
              ]}
            ]},
            {"date": "2026-08-02", "data": [
              {"model": "deepseek-chat", "usage": [
                {"type": "PROMPT_CACHE_HIT_TOKEN", "amount": "0.02"},
                {"type": "PROMPT_CACHE_MISS_TOKEN", "amount": "0.01"},
                {"type": "RESPONSE_TOKEN", "amount": "0.03"},
                {"type": "REQUEST", "amount": "0.00"}
              ]}
            ]}
          ]
        }]}}
        """#
        let stats = try DeepSeekProvider.decodeUsageSummary(
            amountData: amount.data(using: .utf8)!,
            costData: cost.data(using: .utf8)!,
            now: now,
            calendar: Self.utcCalendar)

        // Today = the 2026-08-02 day only.
        #expect(stats.todayTokens == 600)
        #expect(stats.requestCount == 2)
        #expect(abs((stats.todayCost ?? 0) - 0.06) < 0.0001)
        // Month = both days.
        #expect(stats.currentMonthTokens == 2100)
        #expect(stats.currentMonthRequestCount == 5)
        #expect(abs((stats.currentMonthCost ?? 0) - 0.14) < 0.0001)
        #expect(stats.topModel == "deepseek-chat")
        // Category split comes from the "total" array (current month).
        #expect(stats.promptCacheHitTokens == 300)
        #expect(stats.promptCacheMissTokens == 1200)
        #expect(stats.responseTokens == 600)
    }

    @Test("Ring used percent = month cost / (month cost + balance)")
    func ringUsedPercent() {
        // ¥45.30 balance, ¥10.00 spent this month -> 18.08% used.
        #expect(abs(DeepSeekProvider.ringUsedPercent(balance: 45.30, monthCost: 10.00) - (10.0 / 55.3 * 100)) < 0.001)
        // No usage data: ring stays empty (all remaining).
        #expect(DeepSeekProvider.ringUsedPercent(balance: 45.30, monthCost: nil) == 0)
        // Zero balance: fully used.
        #expect(DeepSeekProvider.ringUsedPercent(balance: 0, monthCost: 5.00) == 100)
        // Recharge raises balance -> used share shrinks.
        let before = DeepSeekProvider.ringUsedPercent(balance: 45.30, monthCost: 10.00)
        let after = DeepSeekProvider.ringUsedPercent(balance: 145.30, monthCost: 10.00)
        #expect(after < before)
    }
}

@Suite("DeepSeek credentials")
struct DeepSeekCredentialsTests {
    @Test("Reads API key and platform token aliases")
    func readsEnvironment() {
        #expect(DeepSeekCredentialResolver.apiKey(environment: ["DEEPSEEK_API_KEY": "sk-abc"]) == "sk-abc")
        #expect(DeepSeekCredentialResolver.apiKey(environment: ["DEEPSEEK_KEY": "sk-abc"]) == "sk-abc")
        #expect(DeepSeekCredentialResolver.platformToken(environment: ["DEEPSEEK_PLATFORM_TOKEN": "tok"]) == "tok")
        #expect(DeepSeekCredentialResolver.platformToken(environment: ["DEEPSEEK_USER_TOKEN": "tok"]) == "tok")
        #expect(DeepSeekCredentialResolver.apiKey(environment: [:]) == nil)
        #expect(DeepSeekCredentialResolver.apiKey(environment: ["DEEPSEEK_API_KEY": "\"sk-abc\""]) == "sk-abc")
    }
}

private struct MockTransport: HTTPTransport {
    var statusCodes: [String: Int] = [:]
    var handler: (@Sendable (URLRequest) -> Int)? = nil

    func response(for request: URLRequest) async throws -> HTTPResponse {
        let status = handler?(request) ?? statusCodes[request.url?.path ?? ""] ?? 200
        return HTTPResponse(
            data: Data(),
            statusCode: status,
            response: HTTPURLResponse(
                url: request.url!,
                statusCode: status,
                httpVersion: nil,
                headerFields: nil)!)
    }
}

@Suite("DeepSeek browser session")
struct DeepSeekBrowserSessionTests {
    @Test("Extracts plain, quoted, and JSON-nested user tokens")
    func extractsUserToken() {
        // Plain string.
        #expect(DeepSeekBrowserSession.extractUserToken(from: "abcdefghijklmnopqrstuvwxyz123456") != nil)
        // JSON string.
        #expect(DeepSeekBrowserSession.extractUserToken(from: "\"abcdefghijklmnopqrstuvwxyz123456\"") != nil)
        // JSON object with a value key (CodexBar token shape).
        let nested = #"{"value":"abcdefghijklmnopqrstuvwxyz123456"}"#
        #expect(DeepSeekBrowserSession.extractUserToken(from: nested) == "abcdefghijklmnopqrstuvwxyz123456")
        // Object with accessToken key.
        let access = #"{"accessToken":"abcdefghijklmnopqrstuvwxyz123456"}"#
        #expect(DeepSeekBrowserSession.extractUserToken(from: access) == "abcdefghijklmnopqrstuvwxyz123456")
    }

    @Test("Rejects implausible values")
    func rejectsImplausible() {
        #expect(DeepSeekBrowserSession.extractUserToken(from: "short") == nil)
        #expect(DeepSeekBrowserSession.extractUserToken(from: "has whitespace inside token") == nil)
        #expect(DeepSeekBrowserSession.extractUserToken(from: "") == nil)
        #expect(DeepSeekBrowserSession.extractUserToken(from: #"{"value":123}"#) == nil)
    }

    @Test("Token validates only against HTTP 200")
    func validatesToken() async {
        let ok = MockTransport(handler: { _ in 200 })
        #expect(await DeepSeekBrowserSession.isValidToken("abcdefghijklmnopqrstuvwxyz123456", transport: ok) == true)
        let forbidden = MockTransport(handler: { _ in 403 })
        #expect(await DeepSeekBrowserSession.isValidToken("abcdefghijklmnopqrstuvwxyz123456", transport: forbidden) == false)
    }

    @Test("Resolve picks the first valid candidate")
    func resolvePicksValid() async {
        let candidates = [
            DeepSeekBrowserSession.TokenInfo(
                id: "chrome:Profile 1", token: "bad-token-value-aaaaaaaaaaaaaaa", sourceLabel: "Chrome — Profile 1"),
            DeepSeekBrowserSession.TokenInfo(
                id: "chrome:Default", token: "good-token-value-aaaaaaaaaaaaaaa", sourceLabel: "Chrome — Default"),
        ]
        // First candidate rejected, second accepted.
        let transport = MockTransport(handler: { request in
            let token = request.value(forHTTPHeaderField: "Authorization") ?? ""
            return token.contains("good") ? 200 : 401
        })
        let session = await DeepSeekBrowserSession.resolve(candidates: candidates, transport: transport)
        #expect(session?.token.contains("good") == true)
        #expect(session?.sourceLabel == "Chrome — Default")
    }

    @Test("Resolve returns nil when every candidate is invalid")
    func resolveAllInvalid() async {
        let candidates = [
            DeepSeekBrowserSession.TokenInfo(
                id: "chrome:Default", token: "bad-token-value-aaaaaaaaaaaaaaa", sourceLabel: "Chrome — Default"),
        ]
        let transport = MockTransport(handler: { _ in 401 })
        let session = await DeepSeekBrowserSession.resolve(candidates: candidates, transport: transport)
        #expect(session == nil)
    }
}

@Suite("DeepSeek card formatting")
struct DeepSeekCardFormattingTests {
    @Test("Tokens render compactly")
    func compactTokens() {
        #expect(DeepSeekCardView.compactTokens(456) == "456")
        #expect(DeepSeekCardView.compactTokens(12_345) == "12.3K")
        #expect(DeepSeekCardView.compactTokens(1_200_000) == "1.2M")
    }

    @Test("Money renders with the currency symbol")
    func money() {
        #expect(DeepSeekCardView.money(45.3, symbol: "¥") == "¥45.30")
        #expect(DeepSeekCardView.money(12.34, symbol: "$") == "$12.34")
        #expect(DeepSeekCardView.currencySymbol("CNY") == "¥")
        #expect(DeepSeekCardView.currencySymbol("USD") == "$")
    }

    @Test("Usage detail combines tokens and requests")
    func usageDetail() {
        let detail = DeepSeekCardView.usageDetail(tokens: 12_345, requests: 43)
        #expect(detail.contains("12.3K"))
        #expect(detail.contains("43"))
    }
}

@Suite("Provider visibility")
@MainActor
struct ProviderVisibilityTests {
    @Test("Hidden providers drop out of the switcher list")
    func visibleTabsFilters() {
        let settings = AppSettings.shared
        let original = (settings.showArk, settings.showOpenCode, settings.showDeepSeek, settings.showNebula, settings.showZai, settings.showKimi)
        defer {
            settings.showArk = original.0
            settings.showOpenCode = original.1
            settings.showDeepSeek = original.2
            settings.showNebula = original.3
            settings.showZai = original.4
            settings.showKimi = original.5
        }
        settings.showArk = false
        settings.showOpenCode = true
        settings.showDeepSeek = true
        settings.showNebula = false
        settings.showZai = false
        settings.showKimi = false
        #expect(settings.visibleTabs == [.opencode, .deepseek])
        #expect(settings.isVisible(.ark) == false)
        settings.showOpenCode = false
        #expect(settings.visibleTabs == [.deepseek])
    }

    @Test("Hiding the selected tab moves the selection to the first visible tab")
    func hidingSelectedTabSwitches() {
        let settings = AppSettings.shared
        let originalTab = settings.selectedMenu
        let original = (settings.showArk, settings.showOpenCode, settings.showDeepSeek, settings.showNebula)
        defer {
            settings.selectedMenu = originalTab
            settings.showArk = original.0
            settings.showOpenCode = original.1
            settings.showDeepSeek = original.2
            settings.showNebula = original.3
        }
        settings.setVisible(.deepseek, true)
        settings.selectedMenu = .provider(.deepseek)
        settings.setVisible(.deepseek, false)
        #expect(settings.selectedMenu != .provider(.deepseek))
        // The selection should move to summary (since showSummary defaults true).
        #expect(settings.selectedMenu == .summary || {
            if case let .provider(tab) = settings.selectedMenu { settings.visibleTabs.contains(tab) } else { false }
        }())
    }
}

@Suite("Provider logos")
@MainActor
struct ProviderLogoTests {
    @Test("All three provider logos load from the resource bundle")
    func logosLoad() {
        for tab in ProviderTab.allCases {
            #expect(ProviderLogo.image(for: tab) != nil, "logo missing for \(tab)")
        }
    }

    @Test("DeepSeek card renders the balance ring and three legend rows")
    func deepSeekCardRenders() throws {
        let summary = DeepSeekSummary(
            currency: "CNY",
            totalBalance: 45.30,
            grantedBalance: 5.00,
            toppedUpBalance: 40.30,
            todayTokens: 12_345,
            currentMonthTokens: 1_200_000,
            todayCost: 1.23,
            currentMonthCost: 10.00,
            requestCount: 43,
            currentMonthRequestCount: 1_203,
            topModel: "deepseek-chat",
            promptCacheHitTokens: 1_200,
            promptCacheMissTokens: 8_100,
            responseTokens: 3_000,
            usageAvailable: true)
        let plan = PlanSnapshot(
            id: "deepseek",
            product: .deepseek,
            edition: nil,
            tier: nil,
            seatID: nil,
            subscribed: true,
            windows: [UsageWindow(label: "balance", usedPercent: 18.08, used: nil, total: nil, resetsAt: nil)],
            expiryDate: nil,
            errorMessage: nil,
            deepseek: summary)
        let view = DeepSeekCardView(plan: plan, now: Date(), width: 340)
        view.updateTrackingAreas()
        #expect(view.subviews.allSatisfy {
            $0.frame.minX >= 0 && $0.frame.maxX <= view.bounds.maxX
        })
        let labels = view.subviews.compactMap { $0 as? NSTextField }.map(\.stringValue)
        #expect(labels.contains(L(.windowBalance)))
        #expect(labels.contains(L(.deepseekToday)))
        #expect(labels.contains(L(.deepseekMonthly)))
        #expect(labels.contains("¥45.30"))
        #expect(labels.contains("¥1.23"))
        #expect(labels.contains("¥10.00"))
        // The balance window drives the status-item icon.
        #expect(plan.windows.first?.sortRank == 0)

        // Render the real card on a dark menu-material approximation for visual
        // inspection (same pattern as MenuCardVisualTests).
        let card = DeepSeekCardView(plan: plan, now: Date(), width: 340)
        let header = HeaderCardView(
            snapshot: ProviderSnapshot(
                providerName: "DeepSeek",
                authMethod: "apikey · platform",
                plans: [plan],
                updatedAt: Date(),
                errorMessage: nil),
            width: 340)
        let switcher = ProviderSwitcherView(tabs: ProviderTab.allCases, selected: .provider(.deepseek), showSummary: false, width: 340, onSelect: { _ in })
        let totalHeight = switcher.bounds.height + header.bounds.height + card.bounds.height
        let dashboard = NSView(frame: NSRect(x: 0, y: 0, width: 340, height: totalHeight))
        dashboard.wantsLayer = true
        dashboard.layer?.backgroundColor = NSColor(calibratedWhite: 0.30, alpha: 1).cgColor
        card.frame.origin = .zero
        header.frame.origin = NSPoint(x: 0, y: card.bounds.height)
        switcher.frame.origin = NSPoint(x: 0, y: card.bounds.height + header.bounds.height)
        dashboard.addSubview(card)
        dashboard.addSubview(header)
        dashboard.addSubview(switcher)
        dashboard.layoutSubtreeIfNeeded()

        let dashboardRep = try #require(dashboard.bitmapImageRepForCachingDisplay(in: dashboard.bounds))
        dashboard.cacheDisplay(in: dashboard.bounds, to: dashboardRep)
        let dashboardPNG = try #require(
            dashboardRep.representation(using: .png, properties: [:]))
        try dashboardPNG.write(to: URL(fileURLWithPath: "/tmp/tokenbar_deepseek_dashboard.png"))
        #expect(FileManager.default.fileExists(atPath: "/tmp/tokenbar_deepseek_dashboard.png"))
    }
}

@Suite("NebulaProvider decode")
struct NebulaProviderTests {
    @Test("Parses user/self quota into currency units")
    func decodesUserSelf() throws {
        let json = #"""
        {"success": true, "message": "", "data": {
          "id": 1, "username": "alice", "quota": 123456789, "used_quota": 9876543
        }}
        """#
        let user = try NebulaProvider.decodeUserSelf(data: json.data(using: .utf8)!)
        #expect(user.quota == 123_456_789)
        #expect(user.usedQuota == 9_876_543)
        // 500000 quota = 1 CNY.
        #expect(user.quotaPerUnit == 500_000)
    }

    @Test("Cache-hit tokens come from the other JSON blob (real response shape)")
    func cacheTokensFromOtherBlob() throws {
        let json = #"""
        {"success": true, "message": "", "data": {"page": 1, "page_size": 1, "total": 64, "items": [
          {"id": 1, "user_id": 12345, "created_at": 1785851253, "type": 2,
           "username": "alice", "token_name": "MyToken", "model_name": "grok-4.5",
           "quota": 53972, "prompt_tokens": 388822, "completion_tokens": 358,
           "use_time": 20, "is_stream": true,
           "other": "{\"billing_source\":\"wallet\",\"cache_ratio\":0.25,\"cache_tokens\":375936,\"completion_ratio\":3,\"group_ratio\":0.5,\"model_ratio\":1,\"request_path\":\"/v1/chat/completions\"}"}
        ]}}
        """#
        let items = try NebulaProvider.decodeLogPage(data: json.data(using: .utf8)!)
        #expect(items.count == 1)
        let item = try #require(items.first)
        #expect(item.modelName == "grok-4.5")
        #expect(item.promptTokens == 388_822)
        #expect(item.completionTokens == 358)
        #expect(item.quota == 53_972)
        // 375936 cached input tokens, matching the console's "缓存读" column.
        #expect(item.cacheTokens() == 375_936)
    }

    @Test("Parses log/self items")
    func decodesLogPage() throws {
        let json = #"""
        {"success": true, "message": "", "data": {
          "items": [
            {"id": 1, "model_name": "gpt-4o", "prompt_tokens": 100, "completion_tokens": 50,
             "quota": 75000, "created_at": 1785672000}
          ],
          "total": 1
        }}
        """#
        let items = try NebulaProvider.decodeLogPage(data: json.data(using: .utf8)!)
        #expect(items.count == 1)
        #expect(items.first?.modelName == "gpt-4o")
        #expect(items.first?.promptTokens == 100)
        #expect(items.first?.completionTokens == 50)
        #expect(items.first?.quota == 75_000)
        #expect(items.first?.createdAt == 1_785_672_000)
    }

    @Test("Aggregates today and month cost, tokens, and requests")
    func aggregatesLogs() {
        let calendar = Calendar.current
        // Fixed local "now": 2026-08-02 12:00.
        var components = DateComponents()
        components.year = 2026
        components.month = 8
        components.day = 2
        components.hour = 12
        let now = calendar.date(from: components)!

        func item(_ day: Int, tokens: Int, quota: Int, model: String = "gpt-4o", cache: Int? = nil) -> NebulaLogItem {
            var dayComponents = DateComponents()
            dayComponents.year = 2026
            dayComponents.month = 8
            dayComponents.day = day
            dayComponents.hour = 10
            var other: String?
            if let cache {
                other = #"{"cache_tokens":\#(cache)}"#
            }
            return NebulaLogItem(
                modelName: model,
                promptTokens: tokens,
                completionTokens: tokens / 2,
                quota: quota,
                createdAt: calendar.date(from: dayComponents)?.timeIntervalSince1970 ?? 0,
                other: other)
        }

        let items = [
            item(2, tokens: 600, quota: 75_000, cache: 500),  // today: 600 tokens, 0.15 CNY
            item(1, tokens: 900, quota: 25_000, model: "deepseek-chat", cache: 400), // this month, not today
            item(0, tokens: 100, quota: 10_000, cache: 50),   // July 31 -> outside this month
        ]
        let stats = NebulaProvider.aggregate(items: items, now: now, calendar: calendar)
        // Each item's tokens = prompt + completion.
        #expect(stats.todayTokens == 900) // 600 + 300
        #expect(stats.requestCount == 1)
        #expect(abs((stats.todayCost ?? 0) - 0.15) < 0.0001)
        #expect(stats.currentMonthTokens == 2250) // (600+300) + (900+450)
        #expect(stats.currentMonthRequestCount == 2)
        #expect(abs((stats.currentMonthCost ?? 0) - 0.20) < 0.0001)
        // Top model by month tokens: gpt-4o (900) vs deepseek-chat (1350) -> deepseek-chat.
        #expect(stats.topModel == "deepseek-chat")
        // Input/output/cache split for the month: prompt 600+900, completion 300+450.
        #expect(stats.promptTokens == 1500)
        #expect(stats.completionTokens == 750)
        #expect(stats.cacheTokens == 900) // 500 + 400 (July item excluded)
    }

    @Test("Ring used percent = cumulative spend / (spend + balance)")
    func ringUsedPercent() {
        // ¥100 balance, ¥50 spent -> 33.3% used.
        #expect(abs(NebulaProvider.ringUsedPercent(balance: 100, usedTotal: 50) - (50.0 / 150.0 * 100)) < 0.001)
        // Zero balance: fully used.
        #expect(NebulaProvider.ringUsedPercent(balance: 0, usedTotal: 50) == 100)
        // Top-up raises balance -> used share shrinks.
        let before = NebulaProvider.ringUsedPercent(balance: 100, usedTotal: 50)
        let after = NebulaProvider.ringUsedPercent(balance: 500, usedTotal: 50)
        #expect(after < before)
    }

    @Test("Base URL normalization strips /v1 and trailing slashes")
    func normalizesBaseURL() {
        #expect(NebulaProvider.normalizedBaseURL("https://apinebula.ai") == "https://apinebula.ai")
        #expect(NebulaProvider.normalizedBaseURL("https://apinebula.ai/") == "https://apinebula.ai")
        #expect(NebulaProvider.normalizedBaseURL("https://apinebula.ai/v1") == "https://apinebula.ai")
        #expect(NebulaProvider.normalizedBaseURL("") == nil)
    }
}

@Suite("Nebula card")
@MainActor
struct NebulaCardTests {
    @Test("Renders balance ring and legend rows")
    func rendersCard() throws {
        let summary = NebulaSummary(
            currency: "CNY",
            quotaPerUnit: 500_000,
            balance: 246.91,
            usedTotal: 19.75,
            todayCost: 0.15,
            currentMonthCost: 1.23,
            todayTokens: 600,
            currentMonthTokens: 12_345,
            requestCount: 3,
            currentMonthRequestCount: 87,
            topModel: "deepseek-chat",
            promptTokens: 8_100,
            completionTokens: 4_245,
            cacheTokens: 3_000,
            usageAvailable: true)
        let plan = PlanSnapshot(
            id: "nebula",
            product: .nebula,
            edition: nil,
            tier: nil,
            seatID: nil,
            subscribed: true,
            windows: [UsageWindow(label: "balance", usedPercent: 7.4, used: nil, total: nil, resetsAt: nil)],
            expiryDate: nil,
            errorMessage: nil,
            deepseek: nil,
            nebula: summary)
        let view = NebulaCardView(plan: plan, now: Date(), width: 340)
        view.updateTrackingAreas()
        #expect(view.subviews.allSatisfy {
            $0.frame.minX >= 0 && $0.frame.maxX <= view.bounds.maxX
        })
        let labels = view.subviews.compactMap { $0 as? NSTextField }.map(\.stringValue)
        #expect(labels.contains(L(.windowBalance)))
        #expect(labels.contains("¥246.91"))

        // Render for visual inspection on a dark material approximation.
        let card = NebulaCardView(plan: plan, now: Date(), width: 340)
        let header = HeaderCardView(
            snapshot: ProviderSnapshot(
                providerName: "Nebula",
                authMethod: "apikey",
                plans: [plan],
                updatedAt: Date(),
                errorMessage: nil),
            width: 340)
        let switcher = ProviderSwitcherView(tabs: ProviderTab.allCases, selected: .provider(.nebula), showSummary: false, width: 340, onSelect: { _ in })
        let totalHeight = switcher.bounds.height + header.bounds.height + card.bounds.height
        let dashboard = NSView(frame: NSRect(x: 0, y: 0, width: 340, height: totalHeight))
        dashboard.wantsLayer = true
        dashboard.layer?.backgroundColor = NSColor(calibratedWhite: 0.30, alpha: 1).cgColor
        card.frame.origin = .zero
        header.frame.origin = NSPoint(x: 0, y: card.bounds.height)
        switcher.frame.origin = NSPoint(x: 0, y: card.bounds.height + header.bounds.height)
        dashboard.addSubview(card)
        dashboard.addSubview(header)
        dashboard.addSubview(switcher)
        dashboard.layoutSubtreeIfNeeded()

        let dashboardRep = try #require(dashboard.bitmapImageRepForCachingDisplay(in: dashboard.bounds))
        dashboard.cacheDisplay(in: dashboard.bounds, to: dashboardRep)
        let dashboardPNG = try #require(
            dashboardRep.representation(using: .png, properties: [:]))
        try dashboardPNG.write(to: URL(fileURLWithPath: "/tmp/tokenbar_nebula_dashboard.png"))
        #expect(FileManager.default.fileExists(atPath: "/tmp/tokenbar_nebula_dashboard.png"))
    }
}

@Suite("Nebula browser session")
struct NebulaBrowserSessionTests {
    @Test("Keeps session-like cookies and drops unrelated ones")
    func filtersCookieHeader() {
        let header = NebulaBrowserSession.requestCookieHeader(
            from: "theme=dark; session=abc123; analytics=drop; access_token=tok-xyz")
        #expect(header?.contains("session=abc123") == true)
        #expect(header?.contains("access_token=tok-xyz") == true)
        #expect(header?.contains("theme=dark") != true)
        #expect(header?.contains("analytics=drop") != true)
    }

    @Test("Rejects empty cookie strings")
    func rejectsEmptyCookie() {
        #expect(NebulaBrowserSession.requestCookieHeader(from: "") == nil)
        #expect(NebulaBrowserSession.requestCookieHeader(from: "theme=dark") != nil)
    }
}

@Suite("Nebula console auth errors")
struct NebulaConsoleAuthErrorTests {
    @Test("user/self unauthorized body maps to invalid token")
    func userSelfUnauthorized() {
        let json = #"{"success":false,"message":"Unauthorized, invalid access token"}"#
        #expect(throws: UsageError.self) {
            _ = try NebulaProvider.decodeUserSelf(data: json.data(using: .utf8)!)
        }
        do {
            _ = try NebulaProvider.decodeUserSelf(data: json.data(using: .utf8)!)
            Issue.record("expected throw")
        } catch let error as UsageError {
            if case .nebulaInvalidToken = error {
                // ok
            } else {
                Issue.record("unexpected \(error)")
            }
        } catch {
            Issue.record("unexpected non-UsageError \(error)")
        }
    }
}

@Suite("ZaiProvider decode")
struct ZaiProviderTests {
    @Test("CREDIT_LIMIT windows (real BigModel payload) parse as token-like")
    func parsesCreditLimits() throws {
        let json = #"""
        {"code":200,"msg":"操作成功","data":{"limits":[
          {"type":"CREDIT_LIMIT","unit":3,"number":5,"usage":2000,"currentValue":1332,"remaining":667,"percentage":66,"nextResetTime":1786708599093},
          {"type":"CREDIT_LIMIT","unit":6,"number":1,"usage":10000,"currentValue":1332,"remaining":8667,"percentage":13,"nextResetTime":1787295317998}],
          "level":"lite"},"success":true}
        """#
        let snapshot = try ZaiProvider.parse(data: json.data(using: .utf8)!)
        // BigModel CN returns the tier under `level`, not `planName`.
        #expect(snapshot.planName == "lite")
        #expect(snapshot.timeLimit == nil)
        let session = try #require(snapshot.sessionTokenLimit)
        let weekly = try #require(snapshot.tokenLimit)
        // 5-hour (unit=3, number=5) drives the session ring; the weekly window
        // (unit=6, number=1) the weekly ring. Neither may be dropped.
        #expect(session.windowMinutes == 300)
        #expect(weekly.windowMinutes == 7 * 24 * 60)
        // Derived from usage/remaining/currentValue (66%/13% are the API's own).
        #expect(session.usedPercent == Double(1333) / Double(2000) * 100)
        #expect(weekly.usedPercent == Double(1333) / Double(10000) * 100)
        #expect(snapshot.isValid)
    }

    @Test("TOKENS_LIMIT + TIME_LIMIT (CodexBar shape) still parses")
    func parsesClassicLimits() throws {
        let json = #"""
        {"code":200,"success":true,"data":{"limits":[
          {"type":"TOKENS_LIMIT","unit":3,"number":5,"usage":2000,"remaining":500,"currentValue":1500,"percentage":75,"nextResetTime":1786708599093},
          {"type":"TIME_LIMIT","unit":5,"number":1,"usage":60,"remaining":45,"percentage":25,"nextResetTime":1786794999093}],
          "planName":"personal"}}
        """#
        let snapshot = try ZaiProvider.parse(data: json.data(using: .utf8)!)
        #expect(snapshot.planName == "personal")
        #expect(snapshot.sessionTokenLimit == nil)
        let token = try #require(snapshot.tokenLimit)
        #expect(token.type == .tokensLimit)
        #expect(token.windowMinutes == 300)
        #expect(token.usedPercent == Double(1500) / Double(2000) * 100)
        let time = try #require(snapshot.timeLimit)
        #expect(time.type == .timeLimit)
        #expect(time.windowMinutes == 1)
        #expect(time.usedPercent == Double(15) / Double(60) * 100)
        #expect(snapshot.isValid)
    }
}

@Suite("KimiProvider decode")
struct KimiProviderTests {
    @Test("Code API payload parses weekly and rate-limit windows (real shape)")
    func parsesCodeAPIUsage() throws {
        let json = #"""
        {
          "usage": {
            "limit": "2048",
            "used": "214",
            "remaining": "1834",
            "resetTime": "2026-01-09T15:23:13.716839300Z"
          },
          "limits": [{
            "window": {"duration": 300, "timeUnit": "TIME_UNIT_MINUTE"},
            "detail": {
              "limit": "200",
              "used": "139",
              "remaining": "61",
              "resetTime": "2026-01-06T13:33:02.717479433Z"
            }
          }]
        }
        """#
        let snapshot = try KimiProvider.parse(data: json.data(using: .utf8)!)
        // Weekly quota: 214 used of 2048.
        #expect(Int(snapshot.weekly.limit) == 2048)
        #expect(Int(snapshot.weekly.used!) == 214)
        // Rate-limit window: 139 used of 200 (5-hour).
        let rate = try #require(snapshot.rateLimit)
        #expect(Int(rate.limit) == 200)
        #expect(Int(rate.used!) == 139)
        // resetTime decodes as ISO8601 with fractional seconds.
        #expect(snapshot.weekly.resetTime != nil)
    }

    @Test("Numeric limit/used fields decode without crashing")
    func parsesNumericFields() throws {
        let json = #"""
        {"usage": {"limit": 1000, "used": 250, "remaining": 750},
         "limits": [{"window": {"duration": 300, "timeUnit": "TIME_UNIT_MINUTE"},
                     "detail": {"limit": 100, "used": 10, "remaining": 90}}]}
        """#
        let snapshot = try KimiProvider.parse(data: json.data(using: .utf8)!)
        #expect(snapshot.weekly.limit == "1000")
        #expect(snapshot.weekly.used == "250")
        #expect(snapshot.rateLimit?.limit == "100")
        #expect(snapshot.rateLimit?.used == "10")
    }

    @Test("Missing rate-limit window still parses weekly quota")
    func parsesWeeklyOnly() throws {
        let json = #"""
        {"usage": {"limit": "2048", "used": "214", "remaining": "1834"}}
        """#
        let snapshot = try KimiProvider.parse(data: json.data(using: .utf8)!)
        #expect(snapshot.rateLimit == nil)
        #expect(Int(snapshot.weekly.limit) == 2048)
    }
}
