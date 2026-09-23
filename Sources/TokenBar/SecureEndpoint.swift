import Foundation

/// Endpoint policy for the user-configurable relay addresses.
///
/// Providers send credential material to whatever address Settings holds —
/// APINebula its browser session cookie (plus `New-Api-User`), GrokPool the
/// administrator username and password — so an address that would carry that
/// in cleartext is refused instead of tried. This lives in one place because
/// the policy must not drift between providers.
enum SecureEndpoint {
    /// HTTPS anywhere; plain HTTP only on loopback, where a self-hosted relay
    /// is commonly run during setup.
    static func isTrustworthy(_ raw: String) -> Bool {
        guard let url = URL(string: raw),
              let scheme = url.scheme?.lowercased(),
              let host = url.host?.lowercased(), !host.isEmpty
        else { return false }
        switch scheme {
        case "https": return true
        case "http":
            return host == "localhost" || host == "::1" || host.hasPrefix("127.")
        default: return false
        }
    }
}
