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
            selectedTab: .ark,
            onSelectTab: { _ in },
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
            selectedTab: .ark,
            onSelectTab: { _ in },
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
            selectedTab: .opencode,
            onSelectTab: { _ in },
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
        #expect(StatusItemController.statusItemLength(for: .iconOnly) == 28)
        #expect(StatusItemController.statusItemLength(for: .iconAndPercent) == 68)
        #expect(StatusItemController.statusItemLength(for: .percentOnly) == 46)
    }

    @Test("Clicking OpenCode immediately replaces Ark content in the same menu")
    @MainActor
    func providerSwitcherClickUpdatesContentImmediately() {
        var menu: NSMenu!
        let openCodeState = MenuBuilder.State(
            status: .error(message: "OpenCode test error"),
            selectedTab: .opencode,
            onSelectTab: { _ in },
            lastUpdatedAt: nil,
            isRefreshing: false,
            now: Date(),
            onRefresh: {},
            onSettings: {},
            onQuit: {})
        menu = MenuBuilder.build(.init(
            status: .loading,
            selectedTab: .ark,
            onSelectTab: { tab in
                if tab == .opencode {
                    MenuBuilder.populate(menu, with: openCodeState)
                }
            },
            lastUpdatedAt: nil,
            isRefreshing: false,
            now: Date(),
            onRefresh: {},
            onSettings: {},
            onQuit: {}))

        let switcher = menu.items.compactMap { $0.view as? ProviderSwitcherView }.first
        let openCodeButton = switcher?.subviews
            .compactMap { $0 as? NSButton }
            .first { $0.title == ProviderTab.opencode.displayName }
        openCodeButton?.performClick(nil)

        #expect(!menu.items.contains { $0.title == L(.openArkcliLogin) })
        #expect(menu.items.contains { $0.title == L(.openCodeGo) })
        let refreshedSwitcher = menu.items.compactMap { $0.view as? ProviderSwitcherView }.first
        let selectedTitle = refreshedSwitcher?.subviews
            .compactMap { $0 as? NSButton }
            .first { $0.state == .on }?
            .title
        #expect(selectedTitle == ProviderTab.opencode.displayName)
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
struct IconRendererTests {
    @Test("Produces a template image at 18x18pt")
    func makesTemplateImage() {
        let icon = IconRenderer.makeIcon(remainingPercent: 50, stale: false)
        #expect(icon.size.width == 18)
        #expect(icon.size.height == 18)
        #expect(icon.isTemplate == true)
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
        let switcher = ProviderSwitcherView(selected: .ark, width: 340, onSelect: { _ in })
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
