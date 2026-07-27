import Testing
import Foundation
import AppKit
import ObjectiveC.runtime
@testable import ArkBar

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
            lastUpdatedAt: Date(),
            isRefreshing: false,
            now: Date(),
            onRefresh: {},
            onSettings: {},
            onQuit: {}))
        let refreshItem = menu.items.first { $0.title == L(.refreshNow) }
        #expect(refreshItem?.action == nil)
        #expect(refreshItem?.view is RefreshMenuItemView)
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
        try png.write(to: URL(fileURLWithPath: "/tmp/arkbar_icons.png"))
        #expect(FileManager.default.fileExists(atPath: "/tmp/arkbar_icons.png"))
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
        #expect(view.subviews.allSatisfy {
            $0.frame.minX >= 0 && $0.frame.maxX <= view.bounds.maxX
        })

        // Rendering the ring directly exercises the updated palette and endpoint glow.
        let ring = RingRenderer.makeImage(
            rings: [
                .init(id: "monthly", label: "Monthly", remainingPercent: 25, tone: .monthly),
                .init(id: "weekly", label: "Weekly", remainingPercent: 58, tone: .weekly),
                .init(id: "session", label: "5-hour", remainingPercent: 87, tone: .session),
            ], primaryRemaining: 87, primaryLabel: "5-hour", size: 160)
        let tiff = ring.tiffRepresentation!
        let rep = NSBitmapImageRep(data: tiff)!
        let png = rep.representation(using: .png, properties: [:])!
        try png.write(to: URL(fileURLWithPath: "/tmp/arkbar_ring.png"))
        #expect(FileManager.default.fileExists(atPath: "/tmp/arkbar_ring.png"))
    }
}
