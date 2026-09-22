import Foundation

// MARK: - Subscription order

/// One subscription order reported by the Ark OpenAPI action
/// `ListSubscribeTrade`.
///
/// `GetCodingPlanUsage` only reports quota-window resets, which are not the
/// order's end date (a quarterly order resets its monthly window mid-term).
/// This action is where the console's 开始/结束时间 comes from.
struct VolcSubscription: Sendable, Equatable {
    let resourceType: String
    let status: String?
    let endTime: Date?

    /// An order counts as active while the backend reports it as `Running`.
    var isActive: Bool { status?.trimmingCharacters(in: .whitespacesAndNewlines) == "Running" }
}

// MARK: - Lookup

/// Request shape and decoding for `ListSubscribeTrade` (Version 2024-01-01).
enum VolcSubscribeTrade {
    /// Personal Coding + Agent Plan subscriptions in one call.
    ///
    /// `ResourceNames` is required by the API even for personal subscriptions;
    /// the single empty entry is what the Ark console sends. `ProjectName` is
    /// deliberately omitted — the backend resolves the caller's default
    /// project, so a non-default profile still sees its own orders.
    static let requestBodyJSON = """
        {"ResourceTypes":["CodingPlan","AgentPlan"],"ResourceNames":[""],\
        "BizInfos":["lite","pro","small","medium","large","max"]}
        """
    static var requestBody: Data { Data(requestBodyJSON.utf8) }

    /// Decodes the response, tolerating an unexpected shape: a subscription
    /// lookup failure must never take the quota display down with it.
    static func decode(_ data: Data) -> [VolcSubscription] {
        guard let payload = try? JSONDecoder().decode(SubscribeTradeResponse.self, from: data)
        else { return [] }
        return payload.result.infoList.compactMap { order in
            guard let resourceType = order.resourceType, !resourceType.isEmpty else { return nil }
            return VolcSubscription(
                resourceType: resourceType,
                status: order.status,
                endTime: order.endTime.flatMap(Self.parseDate))
        }
    }

    /// The plan's expiry: the latest active order's end date for the matching
    /// resource type. Team editions are seat-scoped (`GetSeatInfo`), so they
    /// are never answered from this personal-scope query.
    static func expiryDate(
        for product: PlanSnapshot.Product,
        in subscriptions: [VolcSubscription]
    ) -> Date? {
        guard !product.isTeam, let resourceType = resourceType(for: product) else { return nil }
        return subscriptions.lazy
            .filter { $0.resourceType == resourceType && $0.isActive }
            .compactMap(\.endTime)
            .max()
    }

    private static func resourceType(for product: PlanSnapshot.Product) -> String? {
        switch product {
        case .codingPlan, .codingPlanTeam: "CodingPlan"
        case .agentPlan, .agentPlanTeam: "AgentPlan"
        default: nil
        }
    }

    private static func parseDate(_ raw: String) -> Date? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        if let date = formatter.date(from: trimmed) { return date }
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = fractional.date(from: trimmed) { return date }
        // Epoch seconds or milliseconds, as a numeric string.
        if let value = Double(trimmed), value > 0 {
            let seconds = value >= 1e11 ? value / 1000 : value
            return Date(timeIntervalSince1970: seconds)
        }
        return nil
    }
}

// MARK: - Wire types

private struct SubscribeTradeResponse: Decodable {
    let result: SubscribeTradeResult
    enum CodingKeys: String, CodingKey { case result = "Result" }
}

private struct SubscribeTradeResult: Decodable {
    let infoList: [SubscribeTradeOrder]
    enum CodingKeys: String, CodingKey { case infoList = "InfoList" }
}

private struct SubscribeTradeOrder: Decodable {
    let resourceType: String?
    let status: String?
    let endTime: String?
    enum CodingKeys: String, CodingKey {
        case resourceType = "ResourceType"
        case status = "Status"
        case endTime = "EndTime"
    }
}
