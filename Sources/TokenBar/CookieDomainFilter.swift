import Foundation
import SweetCookieKit

/// Strict domain-boundary filter for imported cookie records.
/// SweetCookieKit's default query match is `.contains`, so a lookup for
/// `stepfun.com` also collects `not-stepfun.com` and `stepfun.com.evil.tld`.
/// Sessions forwarded to an API must come from the real domain or a direct
/// subdomain of it — nothing else.
enum CookieDomainFilter {
    static func filter(
        _ records: [BrowserCookieRecord],
        allowedDomains: [String]
    ) -> [BrowserCookieRecord] {
        let allowed = allowedDomains.map { $0.lowercased() }
        return records.filter { record in
            let domain = record.domain.lowercased()
            return allowed.contains { domain == $0 || domain.hasSuffix("." + $0) }
        }
    }
}
