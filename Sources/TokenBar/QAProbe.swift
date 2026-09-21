import AppKit
import Foundation
import SweetCookieKit

/// QA-only diagnostic: dumps cookie names (never values) per browser/profile
/// for a fixed domain list, so support sessions can locate where a sign-in
/// lives without guessing profiles. Enabled by TOKENBAR_QA_PROBE_COOKIES=1.
enum QAProbe {
    static func run() {
        let domains = ["platform.stepfun.com", "stepfun.com",
                       "platform.sensenova.cn", "sensenova.cn", "console.sensecore.cn"]
        let query = BrowserCookieQuery(domains: domains)
        var lines: [String] = []
        for browser in Browser.allCases {
            let stores = BrowserCookieClient().stores(for: browser)
            for store in stores {
                do {
                    let sources = try BrowserCookieClient().records(matching: query, in: browser)
                    let names = sources
                        .flatMap(\.records)
                        .map { "\($0.domain)::\($0.name)" }
                        .sorted()
                    lines.append("BROWSER \(browser.displayName) [\(store.label)] count=\(names.count)")
                    lines.append(contentsOf: names.map { "  \($0)" })
                } catch {
                    lines.append("BROWSER \(browser.displayName) [\(store.label)] ERROR \(error.localizedDescription)")
                }
            }
        }
        let text = lines.joined(separator: "\n")
        guard let dir = FileManager.default.urls(
            for: .applicationSupportDirectory, in: .userDomainMask).first?
            .appendingPathComponent("TokenBar", isDirectory: true)
        else { return }
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try? text.write(
            to: dir.appendingPathComponent("qa-cookie-probe.txt"),
            atomically: true, encoding: .utf8)
    }
}
