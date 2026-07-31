import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Provider that calls `GetCodingPlanUsage` on the Volcengine OpenAPI directly with AK/SK signing.
/// Mirrors CodexBar's DoubaoAPIFetchStrategy (signed branch).
final class VolcAPIProvider: UsageProvider {
    let displayName = "Ark (AK/SK)"
    private let credentials: VolcCredentials
    private let transport: HTTPTransport

    init(credentials: VolcCredentials, transport: HTTPTransport = HTTPClientTransport()) {
        self.credentials = credentials
        self.transport = transport
    }

    func isAvailable(environment: [String: String]) -> Bool { true }

    func fetch(environment: [String: String]) async throws -> ProviderSnapshot {
        guard !credentials.accessKeyID.isEmpty, !credentials.secretAccessKey.isEmpty else {
            throw UsageError.missingCredentials
        }
        // The OpenAPI is GET-shaped but Volcengine signing treats it as POST with empty body;
        // this matches the working CodexBar implementation.
        let url = URL(string: "https://open.volcengineapi.com/?Action=GetCodingPlanUsage&Version=2024-01-01")!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 15
        request.httpBody = Data()
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        VolcSigner.sign(request: &request, body: Data(), credentials: credentials)

        let response = try await transport.response(for: request)
        guard response.statusCode == 200 else {
            throw UsageError.apiError(statusCode: response.statusCode, message: Self.errorSummary(response.data))
        }

        let parsed = try Self.decodeCodingPlanUsage(from: response.data, date: Date())
        return parsed
    }

    // MARK: - Decode (Volcengine OpenAPI shape: { Result: { Status, UpdateTimestamp, QuotaUsage: [...] } })

    static func decodeCodingPlanUsage(from data: Data, date: Date) throws -> ProviderSnapshot {
        let payload: CodingPlanUsageResponse
        do {
            payload = try JSONDecoder().decode(CodingPlanUsageResponse.self, from: data)
        } catch {
            throw UsageError.parseFailed(error.localizedDescription)
        }
        let result = payload.result
        let updatedAt: Date = {
            guard let ts = result.updateTimestamp, ts > 0 else { return date }
            let seconds = ts >= 1e11 ? ts / 1000 : ts
            return Date(timeIntervalSince1970: seconds)
        }()

        // The signed API returns CodingPlan quota only (no AgentPlan, no team). Map the
        // canonical CodingPlan levels (session/weekly/monthly) into one PlanSnapshot.
        let windows = result.quotaUsage.map { quota -> UsageWindow in
            UsageWindow(
                label: Self.canonicalLabel(quota.level),
                usedPercent: min(100, max(0, quota.percent)),
                used: nil,
                total: nil,
                resetsAt: Self.date(fromEpoch: quota.resetTimestamp))
        }
        guard !windows.isEmpty else {
            throw UsageError.noPlanUsage(nil)
        }
        let plan = PlanSnapshot(
            id: "coding-plan:aksk",
            product: .codingPlan,
            edition: "personal",
            tier: nil,
            seatID: nil,
            subscribed: true,
            windows: windows.sorted { $0.sortRank < $1.sortRank },
            expiryDate: nil,
            errorMessage: nil)
        return ProviderSnapshot(
            providerName: "Ark (AK/SK)",
            authMethod: "aksk",
            plans: [plan],
            updatedAt: updatedAt,
            errorMessage: nil)
    }

    private static func canonicalLabel(_ raw: String) -> String {
        switch raw.lowercased() {
        case "session": "Session"
        case "5h", "5-hour", "five_hour": "5-hour"
        case "weekly", "week": "Weekly"
        case "monthly", "month": "Monthly"
        default: raw.capitalized
        }
    }

    private static func date(fromEpoch ts: TimeInterval?) -> Date? {
        guard let ts, ts > 0 else { return nil }
        let seconds = ts >= 1e11 ? ts / 1000 : ts
        return Date(timeIntervalSince1970: seconds)
    }

    private static func errorSummary(_ data: Data) -> String {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            let text = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            return text.isEmpty ? "unexpected response" : text
        }
        if let meta = json["ResponseMetadata"] as? [String: Any],
           let err = meta["Error"] as? [String: Any]
        {
            let code = (err["Code"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
            let msg = (err["Message"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
            if let code, let msg, !code.isEmpty, !msg.isEmpty { return "\(code): \(msg)" }
            if let code, !code.isEmpty { return code }
            if let msg, !msg.isEmpty { return msg }
        }
        if let err = json["error"] as? [String: Any], let msg = err["message"] as? String, !msg.isEmpty {
            return msg
        }
        if let msg = json["message"] as? String, !msg.isEmpty { return msg }
        return "unexpected response"
    }
}

private struct CodingPlanUsageResponse: Decodable {
    let result: ResultPayload
    enum CodingKeys: String, CodingKey { case result = "Result" }
}

private struct ResultPayload: Decodable {
    let status: String?
    let updateTimestamp: TimeInterval?
    let quotaUsage: [QuotaPayload]
    enum CodingKeys: String, CodingKey {
        case status = "Status"
        case updateTimestamp = "UpdateTimestamp"
        case quotaUsage = "QuotaUsage"
    }
}

private struct QuotaPayload: Decodable {
    let level: String
    let percent: Double
    let resetTimestamp: TimeInterval?
    enum CodingKeys: String, CodingKey {
        case level = "Level"
        case percent = "Percent"
        case resetTimestamp = "ResetTimestamp"
    }
}
