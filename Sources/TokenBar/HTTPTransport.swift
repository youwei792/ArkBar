import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Thin HTTP transport so transports can be swapped/mocked. CodexBar uses the same shape.
struct HTTPResponse: Sendable {
    let data: Data
    let statusCode: Int
    let response: HTTPURLResponse
}

protocol HTTPTransport: Sendable {
    func response(for request: URLRequest) async throws -> HTTPResponse
}

/// Bounded, single-line summaries of error response bodies for UI and logs.
/// A 5xx HTML page or a chatty gateway must never flood the menu or stderr,
/// and structured API errors keep only their Code/Message fields.
enum HTTPErrorSummary {
    static let defaultLimit = 300

    static func summarize(_ data: Data, limit: Int = defaultLimit) -> String {
        if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            // Volcengine OpenAPI shape.
            if let meta = json["ResponseMetadata"] as? [String: Any],
               let err = meta["Error"] as? [String: Any]
            {
                let code = (err["Code"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
                let msg = (err["Message"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
                if let code, let msg, !code.isEmpty, !msg.isEmpty { return truncate("\(code): \(msg)", limit) }
                if let code, !code.isEmpty { return truncate(code, limit) }
                if let msg, !msg.isEmpty { return truncate(msg, limit) }
            }
            if let err = json["error"] as? [String: Any],
               let msg = err["message"] as? String, !msg.isEmpty
            {
                return truncate(msg, limit)
            }
            if let msg = json["message"] as? String, !msg.isEmpty {
                return truncate(msg, limit)
            }
        }
        let text = String(data: data, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return text.isEmpty ? "unexpected response" : truncate(text, limit)
    }

    static func truncate(_ text: String, _ limit: Int = defaultLimit) -> String {
        let singleLine = text.components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
            .joined(separator: " ")
        guard singleLine.count > limit else { return singleLine }
        return String(singleLine.prefix(limit)) + "…"
    }
}

/// Default shared transport used by provider constructors.
func defaultHTTPTransport() -> any HTTPTransport { HTTPClientTransport() }

struct HTTPClientTransport: HTTPTransport {
    func response(for request: URLRequest) async throws -> HTTPResponse {
        var freshRequest = request
        // Usage figures must represent the remote source, never a cached response.
        freshRequest.cachePolicy = .reloadIgnoringLocalCacheData
        let (data, urlResponse) = try await URLSession.shared.data(for: freshRequest)
        guard let http = urlResponse as? HTTPURLResponse else {
            throw UsageError.networkError("non-HTTP response")
        }
        return HTTPResponse(data: data, statusCode: http.statusCode, response: http)
    }
}
