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
