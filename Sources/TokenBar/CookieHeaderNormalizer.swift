import Foundation

/// Normalizes a raw cookie header pasted from DevTools or exported from an
/// environment variable: strips a leading `Cookie:`/`Set-Cookie:` prefix,
/// drops empty and attribute entries (`Path`, `HttpOnly`, …), and optionally
/// keeps only whitelisted cookie names. Without this, a pasted request line
/// like `Cookie: session=abc` would be sent with a pseudo-cookie literally
/// named `Cookie: session`.
enum CookieHeaderNormalizer {
    private static let attributeNames: Set<String> = [
        "path", "domain", "expires", "max-age", "httponly", "secure",
        "samesite", "priority", "partitioned",
    ]

    static func normalize(_ raw: String, keepOnly allowedNames: Set<String>? = nil) -> String? {
        var text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        // Strip a pasted header-name prefix ("Cookie: …" / "Set-Cookie: …").
        if let colon = text.firstIndex(of: ":") {
            let prefix = text[..<colon].trimmingCharacters(in: .whitespaces).lowercased()
            if prefix == "cookie" || prefix == "set-cookie" {
                text = String(text[text.index(after: colon)...])
            }
        }
        var pairs: [String] = []
        for part in text.split(separator: ";") {
            let trimmed = part.trimmingCharacters(in: .whitespaces)
            guard let eq = trimmed.firstIndex(of: "=") else { continue }
            let name = trimmed[..<eq].trimmingCharacters(in: .whitespaces)
            var value = String(trimmed[trimmed.index(after: eq)...])
                .trimmingCharacters(in: .whitespaces)
            guard !name.isEmpty, !value.isEmpty else { continue }
            guard !attributeNames.contains(name.lowercased()) else { continue }
            if let allowedNames, !allowedNames.contains(name) { continue }
            if value.count >= 2,
               (value.hasPrefix("\"") && value.hasSuffix("\"")) ||
                (value.hasPrefix("'") && value.hasSuffix("'"))
            {
                value = String(value.dropFirst().dropLast())
            }
            guard !value.isEmpty else { continue }
            pairs.append("\(name)=\(value)")
        }
        guard !pairs.isEmpty else { return nil }
        return pairs.joined(separator: "; ")
    }
}
