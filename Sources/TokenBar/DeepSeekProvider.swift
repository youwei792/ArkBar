import Foundation

// MARK: - Credentials

/// Reads DeepSeek credentials from the environment. Mirrors CodexBar's
/// DeepSeekSettingsReader (without its browser-profile machinery).
enum DeepSeekCredentialResolver {
    static let apiKeyKeys = ["DEEPSEEK_API_KEY", "DEEPSEEK_KEY"]
    static let platformTokenKeys = ["DEEPSEEK_PLATFORM_TOKEN", "DEEPSEEK_USER_TOKEN"]

    static func apiKey(environment: [String: String]) -> String? {
        value(for: apiKeyKeys, environment: environment)
    }

    static func platformToken(environment: [String: String]) -> String? {
        value(for: platformTokenKeys, environment: environment)
    }

    private static func value(for keys: [String], environment: [String: String]) -> String? {
        for key in keys {
            guard let raw = environment[key]?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !raw.isEmpty
            else {
                continue
            }
            var value = raw
            // Strip accidental quoting from shell exports.
            if (value.hasPrefix("\"") && value.hasSuffix("\"")) ||
                (value.hasPrefix("'") && value.hasSuffix("'"))
            {
                value = String(value.dropFirst().dropLast())
            }
            value = value.trimmingCharacters(in: .whitespacesAndNewlines)
            if !value.isEmpty {
                return value
            }
        }
        return nil
    }
}

// MARK: - Parsed domain values

/// Balance plus today/current-month usage, normalised from either the API-key
/// or the platform-session endpoints.
struct DeepSeekBalance: Sendable, Equatable {
    let isAvailable: Bool
    let currency: String
    let totalBalance: Double
    let grantedBalance: Double
    let toppedUpBalance: Double
}

struct DeepSeekUsageStats: Sendable, Equatable {
    let todayTokens: Int
    let currentMonthTokens: Int
    let todayCost: Double?
    let currentMonthCost: Double?
    let requestCount: Int
    let currentMonthRequestCount: Int
    let topModel: String?
    /// Current-month token split by category (cache hit / cache miss / output).
    let promptCacheHitTokens: Int
    let promptCacheMissTokens: Int
    let responseTokens: Int
}

// MARK: - API response types

private struct DeepSeekBalanceResponse: Decodable {
    let isAvailable: Bool
    let balanceInfos: [DeepSeekBalanceInfo]

    enum CodingKeys: String, CodingKey {
        case isAvailable = "is_available"
        case balanceInfos = "balance_infos"
    }
}

private struct DeepSeekBalanceInfo: Decodable {
    let currency: String
    let totalBalance: String
    let grantedBalance: String
    let toppedUpBalance: String

    enum CodingKeys: String, CodingKey {
        case currency
        case totalBalance = "total_balance"
        case grantedBalance = "granted_balance"
        case toppedUpBalance = "topped_up_balance"
    }
}

private struct DeepSeekPlatformUserSummaryResponse: Decodable {
    let code: Int?
    let data: DeepSeekPlatformUserSummaryData?

    enum CodingKeys: String, CodingKey {
        case code, data
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.code = try container.decodeIfPresent(Int.self, forKey: .code)
        if let code, code != 0 {
            // Error envelopes are not schema-stable. Preserve their code before inspecting `data`.
            self.data = try? container.decodeIfPresent(DeepSeekPlatformUserSummaryData.self, forKey: .data)
        } else {
            self.data = try container.decodeIfPresent(DeepSeekPlatformUserSummaryData.self, forKey: .data)
        }
    }
}

private struct DeepSeekPlatformUserSummaryData: Decodable {
    let bizCode: Int?
    let bizData: DeepSeekPlatformUserSummary?

    enum CodingKeys: String, CodingKey {
        case bizCode = "biz_code"
        case bizData = "biz_data"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.bizCode = try container.decodeIfPresent(Int.self, forKey: .bizCode)
        if let bizCode, bizCode != 0 {
            self.bizData = try? container.decodeIfPresent(DeepSeekPlatformUserSummary.self, forKey: .bizData)
        } else {
            self.bizData = try container.decodeIfPresent(DeepSeekPlatformUserSummary.self, forKey: .bizData)
        }
    }
}

private struct DeepSeekPlatformUserSummary: Decodable {
    let normalWallets: [DeepSeekPlatformWallet]
    let bonusWallets: [DeepSeekPlatformWallet]

    enum CodingKeys: String, CodingKey {
        case normalWallets = "normal_wallets"
        case bonusWallets = "bonus_wallets"
    }
}

private struct DeepSeekPlatformWallet: Decodable {
    let balance: Double
    let currency: String

    enum CodingKeys: String, CodingKey {
        case balance, currency
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.currency = try container.decode(String.self, forKey: .currency)
        if let number = try? container.decode(Double.self, forKey: .balance) {
            self.balance = number
            return
        }
        let value = try container.decode(String.self, forKey: .balance)
        guard let number = Double(value) else {
            throw DecodingError.dataCorruptedError(
                forKey: .balance,
                in: container,
                debugDescription: "Expected a numeric wallet balance")
        }
        self.balance = number
    }
}

// Amount payloads (usage/amount)

private struct DeepSeekAmountPayload: Decodable {
    let code: Int?
    let data: DeepSeekAmountData?

    enum CodingKeys: String, CodingKey {
        case code, data
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.code = try container.decodeIfPresent(Int.self, forKey: .code)
        if let code, code != 0 {
            self.data = try? container.decodeIfPresent(DeepSeekAmountData.self, forKey: .data)
        } else {
            self.data = try container.decodeIfPresent(DeepSeekAmountData.self, forKey: .data)
        }
    }
}

private struct DeepSeekAmountData: Decodable {
    let bizCode: Int?
    let bizData: DeepSeekAmountBizData?

    enum CodingKeys: String, CodingKey {
        case bizCode = "biz_code"
        case bizData = "biz_data"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.bizCode = try container.decodeIfPresent(Int.self, forKey: .bizCode)
        if let bizCode, bizCode != 0 {
            self.bizData = try? container.decodeIfPresent(DeepSeekAmountBizData.self, forKey: .bizData)
        } else {
            self.bizData = try container.decodeIfPresent(DeepSeekAmountBizData.self, forKey: .bizData)
        }
    }
}

private struct DeepSeekAmountBizData: Decodable {
    let total: [DeepSeekModelUsage]?
    let days: [DeepSeekDayUsage]?

    enum CodingKeys: String, CodingKey {
        case total, days
    }
}

// Cost payloads (usage/cost)

private struct DeepSeekCostPayload: Decodable {
    let code: Int?
    let data: DeepSeekCostData?

    enum CodingKeys: String, CodingKey {
        case code, data
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.code = try container.decodeIfPresent(Int.self, forKey: .code)
        if let code, code != 0 {
            self.data = try? container.decodeIfPresent(DeepSeekCostData.self, forKey: .data)
        } else {
            self.data = try container.decodeIfPresent(DeepSeekCostData.self, forKey: .data)
        }
    }
}

private struct DeepSeekCostData: Decodable {
    let bizCode: Int?
    let bizData: [DeepSeekCostBizDataItem]?

    enum CodingKeys: String, CodingKey {
        case bizCode = "biz_code"
        case bizData = "biz_data"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.bizCode = try container.decodeIfPresent(Int.self, forKey: .bizCode)
        if let bizCode, bizCode != 0 {
            self.bizData = try? container.decodeIfPresent([DeepSeekCostBizDataItem].self, forKey: .bizData)
        } else {
            self.bizData = try container.decodeIfPresent([DeepSeekCostBizDataItem].self, forKey: .bizData)
        }
    }
}

private struct DeepSeekCostBizDataItem: Decodable {
    let total: [DeepSeekCostModelUsage]?
    let days: [DeepSeekCostDayUsage]?
    let currency: String?

    enum CodingKeys: String, CodingKey {
        case total, days, currency
    }
}

// Shared leaf models

private struct DeepSeekModelUsage: Decodable {
    let model: String?
    let usage: [DeepSeekUsageItem]?

    enum CodingKeys: String, CodingKey {
        case model, usage
    }
}

private struct DeepSeekDayUsage: Decodable {
    let date: String?
    let data: [DeepSeekModelUsage]?

    enum CodingKeys: String, CodingKey {
        case date, data
    }
}

private struct DeepSeekUsageItem: Decodable {
    let type: String?
    let amount: String?

    enum CodingKeys: String, CodingKey {
        case type, amount
    }
}

private struct DeepSeekCostModelUsage: Decodable {
    let model: String?
    let usage: [DeepSeekCostItem]?

    enum CodingKeys: String, CodingKey {
        case model, usage
    }
}

private struct DeepSeekCostDayUsage: Decodable {
    let date: String?
    let data: [DeepSeekCostModelUsage]?

    enum CodingKeys: String, CodingKey {
        case date, data
    }
}

private struct DeepSeekCostItem: Decodable {
    let type: String?
    let amount: String?

    enum CodingKeys: String, CodingKey {
        case type, amount
    }
}

private enum DeepSeekUsageCategory: String {
    case promptCacheHitToken = "PROMPT_CACHE_HIT_TOKEN"
    case promptCacheMissToken = "PROMPT_CACHE_MISS_TOKEN"
    case responseToken = "RESPONSE_TOKEN"
    case request = "REQUEST"

    init?(rawValue: String) {
        switch rawValue.uppercased() {
        case "PROMPT_CACHE_HIT_TOKEN": self = .promptCacheHitToken
        case "PROMPT_CACHE_MISS_TOKEN": self = .promptCacheMissToken
        case "RESPONSE_TOKEN": self = .responseToken
        case "REQUEST": self = .request
        default: return nil
        }
    }
}

// MARK: - Provider

/// DeepSeek usage via the public balance API (API key) and the platform
/// session APIs (token/day counts). Functionality mirrors CodexBar's
/// DeepSeekUsageFetcher + DeepSeekUsageCostParser.
final class DeepSeekProvider: UsageProvider {
    let displayName = "DeepSeek"

    private enum SummaryPayload: Sendable {
        case amount(Data)
        case cost(Data)
    }

    private static let balanceURL = URL(string: "https://api.deepseek.com/user/balance")!
    private static let usageAmountURL = URL(string: "https://platform.deepseek.com/api/v0/usage/amount")!
    private static let usageCostURL = URL(string: "https://platform.deepseek.com/api/v0/usage/cost")!
    private static let platformUserSummaryURL = URL(
        string: "https://platform.deepseek.com/api/v0/users/get_user_summary")!
    static let timeoutSeconds: TimeInterval = 15
    private static let optionalSummaryJoinGrace: Duration = .seconds(5)

    /// The platform APIs aggregate by UTC day, mirroring CodexBar's calendar.
    static var apiCalendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.locale = Locale(identifier: "en_US_POSIX")
        calendar.timeZone = TimeZone(secondsFromGMT: 0) ?? .gmt
        return calendar
    }

    private let settings: AppSettings
    private let transport: any HTTPTransport

    init(settings: AppSettings, transport: any HTTPTransport = defaultHTTPTransport()) {
        self.settings = settings
        self.transport = transport
    }

    /// Always attempts a fetch: credentials may come from Keychain, environment
    /// variables, or a signed-in Chrome session (resolved inside `fetch`).
    func isAvailable(environment: [String: String]) -> Bool {
        true
    }

    func fetch(environment: [String: String]) async throws -> ProviderSnapshot {
        // Precedence: Keychain settings > environment variables > browser session.
        let stored: (apiKey: String?, platformToken: String?) = await MainActor.run {
            (
                self.trimmed(self.settings.deepseekApiKey),
                self.trimmed(self.settings.deepseekPlatformToken)
            )
        }
        let storedAPIKey = stored.apiKey
        let storedPlatformToken = stored.platformToken
        let envAPIKey = DeepSeekCredentialResolver.apiKey(environment: environment)
        let envPlatformToken = DeepSeekCredentialResolver.platformToken(environment: environment)
        let apiKey = storedAPIKey ?? envAPIKey
        var platformToken = storedPlatformToken ?? envPlatformToken
        var browserSourceLabel: String?
        if platformToken == nil {
            // A signed-in Chrome session removes the need for any key: the
            // platform token drives both the balance and today/month usage.
            if let session = await DeepSeekBrowserSession.resolveAutomaticSession(transport: transport) {
                platformToken = session.token
                browserSourceLabel = session.sourceLabel
            }
        }
        guard apiKey != nil || platformToken != nil else {
            throw UsageError.deepSeekMissingCredentials
        }

        // Balance is the primary, required datum.
        let balance: DeepSeekBalance
        if let apiKey {
            balance = try await fetchBalance(apiKey: apiKey)
        } else if let platformToken {
            balance = try await fetchPlatformBalance(platformToken: platformToken)
        } else {
            throw UsageError.deepSeekMissingCredentials
        }

        // Today/month usage is optional: it needs a platform session token and
        // failing it must never take down the balance card.
        var stats: DeepSeekUsageStats?
        if let platformToken {
            do {
                stats = try await fetchUsageSummary(platformToken: platformToken)
            } catch {
                UsageStore.log("✗ DeepSeek usage summary unavailable: \(error.localizedDescription)")
            }
        }

        let summary = DeepSeekSummary(
            currency: balance.currency,
            totalBalance: balance.totalBalance,
            grantedBalance: balance.grantedBalance,
            toppedUpBalance: balance.toppedUpBalance,
            todayTokens: stats?.todayTokens ?? 0,
            currentMonthTokens: stats?.currentMonthTokens ?? 0,
            todayCost: stats?.todayCost,
            currentMonthCost: stats?.currentMonthCost,
            requestCount: stats?.requestCount ?? 0,
            currentMonthRequestCount: stats?.currentMonthRequestCount ?? 0,
            topModel: stats?.topModel,
            promptCacheHitTokens: stats?.promptCacheHitTokens ?? 0,
            promptCacheMissTokens: stats?.promptCacheMissTokens ?? 0,
            responseTokens: stats?.responseTokens ?? 0,
            usageAvailable: stats != nil)

        // Single ring: this month's spend vs (spend + balance). Recharging
        // raises the balance, so the ring's used share shrinks on next refresh.
        let usedPercent = Self.ringUsedPercent(
            balance: balance.totalBalance,
            monthCost: stats?.currentMonthCost)
        let window = UsageWindow(label: "balance", usedPercent: usedPercent,
                                 used: nil, total: nil, resetsAt: nil)
        let plan = PlanSnapshot(
            id: "deepseek",
            product: .deepseek,
            edition: nil,
            tier: nil,
            seatID: nil,
            subscribed: true,
            windows: [window],
            expiryDate: nil,
            errorMessage: nil,
            deepseek: summary)
        let authMethod: String
        if apiKey != nil && platformToken != nil {
            authMethod = "apikey · platform"
        } else if apiKey != nil {
            authMethod = "apikey"
        } else {
            authMethod = browserSourceLabel ?? "platform"
        }
        return ProviderSnapshot(
            providerName: displayName,
            authMethod: authMethod,
            plans: [plan],
            updatedAt: Date(),
            errorMessage: nil)
    }

    private func trimmed(_ value: String) -> String? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    /// Used share of the ring. `monthCost` comes from the platform usage/cost
    /// endpoint; without it the ring stays empty (all remaining).
    static func ringUsedPercent(balance: Double, monthCost: Double?) -> Double {
        guard balance > 0 else { return 100 }
        let cost = monthCost ?? 0
        let total = cost + balance
        guard total > 0 else { return 100 }
        return min(100, max(0, cost / total * 100))
    }

    // MARK: - Balance

    private func fetchBalance(apiKey: String) async throws -> DeepSeekBalance {
        var request = URLRequest(url: Self.balanceURL)
        request.httpMethod = "GET"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.timeoutInterval = Self.timeoutSeconds

        let response = try await transport.response(for: request)
        guard response.statusCode == 200 else {
            throw UsageError.apiError(statusCode: response.statusCode, message: "DeepSeek balance")
        }
        return try Self.decodeBalance(data: response.data)
    }

    private func fetchPlatformBalance(platformToken: String) async throws -> DeepSeekBalance {
        var request = URLRequest(url: Self.platformUserSummaryURL)
        request.httpMethod = "GET"
        request.setValue("Bearer \(platformToken)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.timeoutInterval = Self.timeoutSeconds

        let response = try await transport.response(for: request)
        guard response.statusCode == 200 else {
            if response.statusCode == 401 || response.statusCode == 403 {
                throw UsageError.deepSeekInvalidPlatformToken
            }
            throw UsageError.apiError(statusCode: response.statusCode, message: "DeepSeek user summary")
        }
        return try Self.decodePlatformBalance(data: response.data)
    }

    // MARK: - Usage summary

    private func fetchUsageSummary(platformToken: String) async throws -> DeepSeekUsageStats {
        let period = try Self.usagePeriod(now: Date(), calendar: Self.apiCalendar)
        let payloads = try await fetchUsagePayloads(
            fetchAmount: {
                try await self.fetchAmount(platformToken: platformToken,
                                           month: period.month, year: period.year)
            },
            fetchCost: {
                try await self.fetchCost(platformToken: platformToken,
                                         month: period.month, year: period.year)
            })
        return try Self.decodeUsageSummary(
            amountData: payloads.amount,
            costData: payloads.cost,
            now: Date(),
            calendar: Self.apiCalendar)
    }

    private func fetchUsagePayloads(
        fetchAmount: @escaping @Sendable () async throws -> Data,
        fetchCost: @escaping @Sendable () async throws -> Data) async throws -> (amount: Data, cost: Data)
    {
        try await withThrowingTaskGroup(of: SummaryPayload.self) { group in
            group.addTask { try await .amount(fetchAmount()) }
            group.addTask { try await .cost(fetchCost()) }

            var amountData: Data?
            var costData: Data?
            for try await payload in group {
                switch payload {
                case let .amount(data): amountData = data
                case let .cost(data): costData = data
                }
            }
            guard let amountData, let costData else {
                throw UsageError.parseFailed("Missing DeepSeek usage response")
            }
            return (amount: amountData, cost: costData)
        }
    }

    private func fetchAmount(platformToken: String, month: Int, year: Int) async throws -> Data {
        var request = try Self.usageRequest(
            url: Self.usageAmountURL,
            platformToken: platformToken,
            month: month, year: year)
        request.httpMethod = "GET"
        let response = try await transport.response(for: request)
        guard response.statusCode == 200 else {
            if response.statusCode == 401 || response.statusCode == 403 {
                throw UsageError.deepSeekInvalidPlatformToken
            }
            throw UsageError.apiError(statusCode: response.statusCode, message: "DeepSeek usage amount")
        }
        return response.data
    }

    private func fetchCost(platformToken: String, month: Int, year: Int) async throws -> Data {
        var request = try Self.usageRequest(
            url: Self.usageCostURL,
            platformToken: platformToken,
            month: month, year: year)
        request.httpMethod = "GET"
        let response = try await transport.response(for: request)
        guard response.statusCode == 200 else {
            if response.statusCode == 401 || response.statusCode == 403 {
                throw UsageError.deepSeekInvalidPlatformToken
            }
            throw UsageError.apiError(statusCode: response.statusCode, message: "DeepSeek usage cost")
        }
        return response.data
    }

    private static func usageRequest(
        url: URL, platformToken: String, month: Int, year: Int) throws -> URLRequest
    {
        guard var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
            throw UsageError.networkError("Invalid DeepSeek URL")
        }
        components.queryItems = [
            URLQueryItem(name: "month", value: String(month)),
            URLQueryItem(name: "year", value: String(year)),
        ]
        guard let url = components.url else {
            throw UsageError.networkError("Could not construct DeepSeek URL")
        }
        var request = URLRequest(url: url)
        request.setValue("Bearer \(platformToken)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.timeoutInterval = Self.timeoutSeconds
        return request
    }

    static func currentUsagePeriod() throws -> (month: Int, year: Int) {
        try usagePeriod(now: Date(), calendar: apiCalendar)
    }

    private static func usagePeriod(now: Date, calendar: Calendar) throws -> (month: Int, year: Int) {
        let components = calendar.dateComponents([.month, .year], from: now)
        guard let month = components.month, let year = components.year else {
            throw UsageError.parseFailed("Could not determine current month/year")
        }
        return (month: month, year: year)
    }

    // MARK: - Decoding (static for tests)

    static func decodeBalance(data: Data) throws -> DeepSeekBalance {
        let decoded: DeepSeekBalanceResponse
        do {
            decoded = try JSONDecoder().decode(DeepSeekBalanceResponse.self, from: data)
        } catch {
            throw UsageError.parseFailed(error.localizedDescription)
        }

        let parsed = try decoded.balanceInfos.map { info -> (currency: String, total: Double, granted: Double, toppedUp: Double) in
            guard let total = Double(info.totalBalance),
                  let granted = Double(info.grantedBalance),
                  let toppedUp = Double(info.toppedUpBalance)
            else {
                throw UsageError.parseFailed("Non-numeric DeepSeek balance value")
            }
            return (info.currency, total, granted, toppedUp)
        }
        guard !parsed.isEmpty else {
            return DeepSeekBalance(isAvailable: false, currency: "USD",
                                   totalBalance: 0, grantedBalance: 0, toppedUpBalance: 0)
        }
        // Prefer USD when funded, but do not hide a positive CNY balance behind
        // an empty USD row returned by the API.
        let selected = parsed.first { $0.currency == "USD" && $0.total > 0 }
            ?? parsed.first { $0.total > 0 }
            ?? parsed.first { $0.currency == "USD" }
            ?? parsed[0]
        return DeepSeekBalance(
            isAvailable: decoded.isAvailable,
            currency: selected.currency,
            totalBalance: selected.total,
            grantedBalance: selected.granted,
            toppedUpBalance: selected.toppedUp)
    }

    static func decodePlatformBalance(data: Data) throws -> DeepSeekBalance {
        let payload: DeepSeekPlatformUserSummaryResponse
        do {
            payload = try JSONDecoder().decode(DeepSeekPlatformUserSummaryResponse.self, from: data)
        } catch {
            throw UsageError.parseFailed(error.localizedDescription)
        }
        if let code = payload.code, code != 0 {
            if isPlatformAuthenticationError(code) {
                throw UsageError.deepSeekInvalidPlatformToken
            }
            throw UsageError.apiError(statusCode: code, message: "DeepSeek user summary")
        }
        if let bizCode = payload.data?.bizCode, bizCode != 0 {
            if isPlatformAuthenticationError(bizCode) {
                throw UsageError.deepSeekInvalidPlatformToken
            }
            throw UsageError.apiError(statusCode: bizCode, message: "DeepSeek user summary")
        }
        guard let summary = payload.data?.bizData else {
            throw UsageError.parseFailed("Missing DeepSeek user summary biz_data")
        }

        let toppedUp = Dictionary(grouping: summary.normalWallets, by: \.currency)
            .mapValues { $0.reduce(0) { $0 + $1.balance } }
        let granted = Dictionary(grouping: summary.bonusWallets, by: \.currency)
            .mapValues { $0.reduce(0) { $0 + $1.balance } }
        let currencies = Set(toppedUp.keys).union(granted.keys).sorted()
        guard !currencies.isEmpty else {
            return DeepSeekBalance(isAvailable: false, currency: "USD",
                                   totalBalance: 0, grantedBalance: 0, toppedUpBalance: 0)
        }

        let selectedCurrency = currencies.first { currency in
            currency == "USD" && (toppedUp[currency, default: 0] + granted[currency, default: 0]) > 0
        } ?? currencies.first { currency in
            toppedUp[currency, default: 0] + granted[currency, default: 0] > 0
        } ?? currencies.first(where: { $0 == "USD" }) ?? currencies[0]
        let paidBalance = toppedUp[selectedCurrency, default: 0]
        let grantedBalance = granted[selectedCurrency, default: 0]
        let totalBalance = paidBalance + grantedBalance
        return DeepSeekBalance(
            isAvailable: totalBalance > 0,
            currency: selectedCurrency,
            totalBalance: totalBalance,
            grantedBalance: grantedBalance,
            toppedUpBalance: paidBalance)
    }

    static func decodeUsageSummary(
        amountData: Data, costData: Data, now: Date, calendar: Calendar) throws -> DeepSeekUsageStats
    {
        let amountPayload: DeepSeekAmountPayload
        let costPayload: DeepSeekCostPayload
        do {
            amountPayload = try JSONDecoder().decode(DeepSeekAmountPayload.self, from: amountData)
        } catch {
            throw UsageError.parseFailed("DeepSeek amount: \(error.localizedDescription)")
        }
        do {
            costPayload = try JSONDecoder().decode(DeepSeekCostPayload.self, from: costData)
        } catch {
            throw UsageError.parseFailed("DeepSeek cost: \(error.localizedDescription)")
        }

        if let code = amountPayload.code, code != 0 {
            if isPlatformAuthenticationError(code) {
                throw UsageError.deepSeekInvalidPlatformToken
            }
            throw UsageError.apiError(statusCode: code, message: "DeepSeek amount")
        }
        if let bizCode = amountPayload.data?.bizCode, bizCode != 0 {
            if isPlatformAuthenticationError(bizCode) {
                throw UsageError.deepSeekInvalidPlatformToken
            }
            throw UsageError.apiError(statusCode: bizCode, message: "DeepSeek amount")
        }
        if let code = costPayload.code, code != 0 {
            if isPlatformAuthenticationError(code) {
                throw UsageError.deepSeekInvalidPlatformToken
            }
            throw UsageError.apiError(statusCode: code, message: "DeepSeek cost")
        }
        if let bizCode = costPayload.data?.bizCode, bizCode != 0 {
            if isPlatformAuthenticationError(bizCode) {
                throw UsageError.deepSeekInvalidPlatformToken
            }
            throw UsageError.apiError(statusCode: bizCode, message: "DeepSeek cost")
        }
        guard let amountBizData = amountPayload.data?.bizData else {
            throw UsageError.parseFailed("Missing DeepSeek amount biz_data")
        }

        let totalAmounts = amountBizData.total ?? []
        let dailyAmounts = amountBizData.days ?? []
        let dailyCosts = costPayload.data?.bizData?.first?.days ?? []

        let (today, month) = aggregateDays(
            dailyAmounts: dailyAmounts,
            dailyCosts: dailyCosts,
            now: now,
            calendar: calendar)
        let (topModel, categoryTokens) = buildBreakdowns(from: totalAmounts)

        return DeepSeekUsageStats(
            todayTokens: today.tokens,
            currentMonthTokens: month.tokens,
            todayCost: today.cost,
            currentMonthCost: month.cost,
            requestCount: today.requests,
            currentMonthRequestCount: month.requests,
            topModel: topModel,
            promptCacheHitTokens: categoryTokens[.promptCacheHitToken] ?? 0,
            promptCacheMissTokens: categoryTokens[.promptCacheMissToken] ?? 0,
            responseTokens: categoryTokens[.responseToken] ?? 0)
    }

    private static func isPlatformAuthenticationError(_ code: Int) -> Bool {
        code == 40002 || code == 40003
    }

    // MARK: - Aggregation

    private struct DayAggregation {
        let tokens: Int
        let cost: Double?
        let requests: Int
    }

    /// "Today" uses the UTC day string matching `now`; "month" sums every day
    /// entry between the start of the month and `now`. Mirrors CodexBar's
    /// DeepSeekUsageCostParser aggregation.
    private static func aggregateDays(
        dailyAmounts: [DeepSeekDayUsage],
        dailyCosts: [DeepSeekCostDayUsage],
        now: Date,
        calendar: Calendar) -> (today: DayAggregation, month: DayAggregation)
    {
        let todayString = dayString(now, calendar: calendar)
        let amountMap = buildAmountMap(from: dailyAmounts)
        let costMap = buildCostMap(from: dailyCosts)

        let today = aggregateDay(
            dateString: todayString,
            amountMap: amountMap,
            costMap: costMap)

        var monthTokens = 0
        var monthCost: Double?
        var monthRequests = 0
        for date in Set(amountMap.keys).union(costMap.keys) {
            guard let parsed = parseDate(date, calendar: calendar),
                  parsed >= startOfMonth(now, calendar: calendar),
                  parsed <= now
            else {
                continue
            }
            let day = aggregateDay(dateString: date, amountMap: amountMap, costMap: costMap)
            monthTokens += day.tokens
            monthRequests += day.requests
            if let cost = day.cost {
                monthCost = (monthCost ?? 0) + cost
            }
        }
        return (
            today: today,
            month: DayAggregation(tokens: monthTokens, cost: monthCost, requests: monthRequests))
    }

    private static func aggregateDay(
        dateString: String,
        amountMap: [String: [String: [DeepSeekUsageItem]]],
        costMap: [String: [String: [DeepSeekCostItem]]]) -> DayAggregation
    {
        var tokens = 0
        var cost: Double?
        var requests = 0

        if let amounts = amountMap[dateString] {
            for items in amounts.values {
                for item in items {
                    guard let category = DeepSeekUsageCategory(rawValue: item.type ?? "") else { continue }
                    if category == .request {
                        requests += parseTokenAmount(item.amount)
                    } else {
                        tokens += parseTokenAmount(item.amount)
                    }
                }
            }
        }
        if let costs = costMap[dateString] {
            for items in costs.values {
                for item in items {
                    guard let category = DeepSeekUsageCategory(rawValue: item.type ?? "") else { continue }
                    if category != .request {
                        let amount = parseCostAmount(item.amount)
                        cost = (cost ?? 0) + amount
                    }
                }
            }
        }
        return DayAggregation(tokens: tokens, cost: cost, requests: requests)
    }

    private static func buildAmountMap(
        from dailyAmounts: [DeepSeekDayUsage]) -> [String: [String: [DeepSeekUsageItem]]]
    {
        var result: [String: [String: [DeepSeekUsageItem]]] = [:]
        for day in dailyAmounts {
            guard let date = day.date else { continue }
            var modelMap: [String: [DeepSeekUsageItem]] = [:]
            for model in day.data ?? [] {
                guard let modelName = model.model, let items = model.usage, !items.isEmpty else { continue }
                modelMap[modelName] = items
            }
            if !modelMap.isEmpty {
                result[date] = modelMap
            }
        }
        return result
    }

    private static func buildCostMap(
        from dailyCosts: [DeepSeekCostDayUsage]) -> [String: [String: [DeepSeekCostItem]]]
    {
        var result: [String: [String: [DeepSeekCostItem]]] = [:]
        for day in dailyCosts {
            guard let date = day.date else { continue }
            var modelMap: [String: [DeepSeekCostItem]] = [:]
            for model in day.data ?? [] {
                guard let modelName = model.model, let items = model.usage, !items.isEmpty else { continue }
                modelMap[modelName] = items
            }
            if !modelMap.isEmpty {
                result[date] = modelMap
            }
        }
        return result
    }

    private static func buildBreakdowns(from totalAmounts: [DeepSeekModelUsage])
        -> (topModel: String?, categoryTokens: [DeepSeekUsageCategory: Int])
    {
        var modelTokens: [String: Int] = [:]
        var categoryTokens: [DeepSeekUsageCategory: Int] = [:]

        for modelUsage in totalAmounts {
            guard let model = modelUsage.model else { continue }
            var total = 0
            for item in modelUsage.usage ?? [] {
                guard let category = DeepSeekUsageCategory(rawValue: item.type ?? "") else { continue }
                if category != .request {
                    let amount = parseTokenAmount(item.amount)
                    total += amount
                    categoryTokens[category, default: 0] += amount
                }
            }
            modelTokens[model] = total
        }

        let topModel = modelTokens.max {
            if $0.value == $1.value { return $0.key > $1.key }
            return $0.value < $1.value
        }?.key
        return (topModel, categoryTokens)
    }

    // MARK: - Formatting helpers

    static func dayString(_ date: Date, calendar: Calendar) -> String {
        let components = calendar.dateComponents([.year, .month, .day], from: date)
        guard let year = components.year,
              let month = components.month,
              let day = components.day
        else { return "" }
        return String(format: "%04d-%02d-%02d", year, month, day)
    }

    private static func startOfMonth(_ date: Date, calendar: Calendar) -> Date {
        var components = calendar.dateComponents([.year, .month], from: date)
        components.day = 1
        return calendar.date(from: components) ?? date
    }

    private static func parseDate(_ text: String, calendar: Calendar) -> Date? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = calendar
        formatter.timeZone = calendar.timeZone
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.date(from: trimmed)
    }

    private static func parseTokenAmount(_ value: String?) -> Int {
        guard let value, let intValue = Int64(value.trimmingCharacters(in: .whitespacesAndNewlines)) else {
            return 0
        }
        return Int(intValue)
    }

    private static func parseCostAmount(_ value: String?) -> Double {
        guard let value else { return 0 }
        return Double(value.trimmingCharacters(in: .whitespacesAndNewlines)) ?? 0
    }
}
