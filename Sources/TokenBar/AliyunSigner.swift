import CryptoKit
import Foundation

/// Alibaba Cloud (阿里云百炼) IAM key pair.
struct AliyunCredentials: Sendable {
    let accessKeyID: String
    let secretAccessKey: String
}

/// Resolves Aliyun AK/SK from environment variables (the standard Aliyun
/// names). Settings (Keychain) values take precedence; these are the fallback.
enum AliyunCredentialResolver {
    static let accessKeyIDKeys = [
        "ALIYUN_ACCESS_KEY_ID",
        "ALIBABA_CLOUD_ACCESS_KEY_ID",
    ]
    static let secretAccessKeyKeys = [
        "ALIYUN_ACCESS_KEY_SECRET",
        "ALIBABA_CLOUD_ACCESS_KEY_SECRET",
    ]

    static func resolve(environment: [String: String]) -> AliyunCredentials? {
        guard let id = firstValue(in: environment, keys: accessKeyIDKeys),
              let secret = firstValue(in: environment, keys: secretAccessKeyKeys)
        else { return nil }
        return AliyunCredentials(accessKeyID: id, secretAccessKey: secret)
    }

    private static func firstValue(in env: [String: String], keys: [String]) -> String? {
        for key in keys {
            guard var v = env[key]?.trimmingCharacters(in: .whitespacesAndNewlines), !v.isEmpty else {
                continue
            }
            if (v.hasPrefix("\"") && v.hasSuffix("\"")) || (v.hasPrefix("'") && v.hasSuffix("'")) {
                v = String(v.dropFirst().dropLast())
            }
            v = v.trimmingCharacters(in: .whitespacesAndNewlines)
            if !v.isEmpty { return v }
        }
        return nil
    }
}

/// Resolves the plan `sk-sp-` key from the environment. It authenticates
/// model calls, not the console gateway — used only as a last-resort Bearer
/// attempt on the usage API.
enum AliyunAPIKeyResolver {
    static let apiKeyKeys = ["ALIYUN_CODING_PLAN_API_KEY"]

    static func resolve(environment: [String: String]) -> String? {
        for key in apiKeyKeys {
            guard var v = environment[key]?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !v.isEmpty
            else { continue }
            if (v.hasPrefix("\"") && v.hasSuffix("\"")) || (v.hasPrefix("'") && v.hasSuffix("'")) {
                v = String(v.dropFirst().dropLast())
            }
            v = v.trimmingCharacters(in: .whitespacesAndNewlines)
            if !v.isEmpty { return v }
        }
        return nil
    }
}

/// Alibaba Cloud ACS3-HMAC-SHA256 request signer, byte-for-byte compatible
/// with the official Model Studio CLI (`bailian-cli`, packages/core/src/client/acs.ts).
/// The signature is a direct HMAC of the string-to-sign with the secret key —
/// no derived signing key like Volcengine's V4.
enum AliyunSigner {
    static func sign(
        request: inout URLRequest,
        body: Data,
        credentials: AliyunCredentials,
        action: String,
        version: String,
        date: Date = Date(),
        nonce: String = UUID().uuidString
    ) {
        let dateISO = Self.iso8601String(from: date)
        let hashedBody = Self.sha256Hex(body)

        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(dateISO, forHTTPHeaderField: "x-acs-date")
        request.setValue(action, forHTTPHeaderField: "x-acs-action")
        request.setValue(version, forHTTPHeaderField: "x-acs-version")
        request.setValue(nonce, forHTTPHeaderField: "x-acs-signature-nonce")
        request.setValue(hashedBody, forHTTPHeaderField: "x-acs-content-sha256")

        guard let url = request.url else { return }
        let host = url.host ?? ""
        request.setValue(host, forHTTPHeaderField: "Host")

        // Signed headers: host, content-type and every x-acs-* header, sorted.
        let signedHeaderKeys = ["content-type", "host", "x-acs-action", "x-acs-content-sha256",
                                "x-acs-date", "x-acs-signature-nonce", "x-acs-version"]
        let values: [String: String] = [
            "content-type": "application/json",
            "host": host,
            "x-acs-action": action,
            "x-acs-content-sha256": hashedBody,
            "x-acs-date": dateISO,
            "x-acs-signature-nonce": nonce,
            "x-acs-version": version,
        ]
        let canonicalHeaders = signedHeaderKeys.map { "\($0):\(values[$0] ?? "")" }.joined(separator: "\n") + "\n"
        let signedHeaders = signedHeaderKeys.joined(separator: ";")

        let canonicalRequest = [
            request.httpMethod ?? "POST",
            url.path.isEmpty ? "/" : url.path,
            Self.canonicalQueryString(url),
            canonicalHeaders,
            signedHeaders,
            hashedBody,
        ].joined(separator: "\n")

        let stringToSign = "ACS3-HMAC-SHA256\n" + Self.sha256Hex(Data(canonicalRequest.utf8))
        let signature = Self.hmacHex(key: Data(credentials.secretAccessKey.utf8), message: stringToSign)
        // No spaces after the commas — the gateway parses this literally.
        request.setValue(
            "ACS3-HMAC-SHA256 Credential=\(credentials.accessKeyID),"
                + "SignedHeaders=\(signedHeaders),Signature=\(signature)",
            forHTTPHeaderField: "Authorization")
    }

    private static func hmacHex(key: Data, message: String) -> String {
        let code = HMAC<SHA256>.authenticationCode(for: Data(message.utf8), using: SymmetricKey(data: key))
        return Data(code).map { String(format: "%02x", $0) }.joined()
    }

    private static func sha256Hex(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private static func canonicalQueryString(_ url: URL) -> String {
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let queryItems = components.queryItems, !queryItems.isEmpty
        else {
            return ""
        }
        var pairs: [(key: String, value: String)] = queryItems.map { item in
            (key: Self.percentEncode(item.name), value: Self.percentEncode(item.value ?? ""))
        }
        pairs.sort { lhs, rhs in lhs.key == rhs.key ? lhs.value < rhs.value : lhs.key < rhs.key }
        return pairs.map { "\($0.key)=\($0.value)" }.joined(separator: "&")
    }

    private static func percentEncode(_ value: String) -> String {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-_.~")
        return value.addingPercentEncoding(withAllowedCharacters: allowed) ?? value
    }

    private static func iso8601String(from date: Date) -> String {
        // Constructed per call: ISO8601DateFormatter is not Sendable, and
        // signing happens at most once per token refresh.
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        return formatter.string(from: date)
    }
}

/// Model Studio **console** OpenAPI gateway calls (the endpoints the Bailian
/// console SPA and the official `bl` CLI use).
///
/// Usage data for the Coding Plan is only published through this gateway — the
/// `sk-sp-…` plan key authenticates the model gateway, not the console — so the
/// flow is: ACS3-signed `GenerateCLIAccessToken` (AK/SK) → short-lived
/// `cliAccessToken` Bearer → `queryCodingPlanInstanceInfoV2`.
/// Contracts verified against `github.com/modelstudioai/cli` (packages/core).
enum AliyunConsoleAPI {
    /// Domestic (China) console gateway.
    static let gatewayHost = "bailian-cs.console.aliyun.com"
    static let gatewayAction = "BroadScopeAspnGateway"
    static let tokenHost = "modelstudio.cn-beijing.aliyuncs.com"
    static let tokenPath = "/modelstudio/cli/generateAccessToken"
    static let tokenAction = "GenerateCLIAccessToken"
    static let tokenVersion = "2026-02-10"
    /// Coding Plan (request-count windows). Console API names, from the
    /// official CLI.
    static let codingPlanUsageAPI =
        "zeldaEasy.broadscope-bailian.codingPlan.queryCodingPlanInstanceInfoV2"
    /// Token Plan (credit-ratio windows).
    static let tokenPlanUsageAPI = "zeldaHttp.apikeyMgr./tokenplan/personal/api/v2/usage"
    /// Token Plan subscription record — the usage API publishes no dates, so the
    /// plan's end date and tier come from here (the console page calls both).
    static let tokenPlanSubscriptionAPI =
        "zeldaHttp.apikeyMgr./tokenplan/personal/api/v2/subscription"
    static let commodityCode = "sfm_codingplan_public_cn"

    /// Mints a console access token with the ACS3-signed OpenAPI call.
    static func mintAccessToken(
        credentials: AliyunCredentials,
        transport: any HTTPTransport
    ) async throws -> String {
        var request = URLRequest(url: URL(string: "https://\(tokenHost)\(tokenPath)")!)
        request.httpMethod = "POST"
        request.timeoutInterval = 15
        AliyunSigner.sign(
            request: &request,
            body: Data(),
            credentials: credentials,
            action: tokenAction,
            version: tokenVersion)

        let response = try await transport.response(for: request)
        guard response.statusCode == 200 else {
            if response.statusCode == 401 || response.statusCode == 403 {
                throw UsageError.aliyunInvalidToken
            }
            throw UsageError.apiError(
                statusCode: response.statusCode,
                message: "Alibaba Cloud console token: \(HTTPErrorSummary.summarize(response.data))")
        }
        guard let object = try? JSONSerialization.jsonObject(with: response.data) as? [String: Any],
              let token = (object["cliAccessToken"] as? String)?
                .trimmingCharacters(in: .whitespacesAndNewlines),
              !token.isEmpty
        else {
            throw UsageError.parseFailed("Alibaba Cloud console token: missing cliAccessToken")
        }
        return token
    }

    /// Queries the Coding Plan instance quota with the console Bearer token.
    /// Returns the raw response body; the provider owns parsing.
    static func fetchCodingPlanUsage(
        token: String,
        transport: any HTTPTransport
    ) async throws -> Data {
        try await gatewayCall(
            api: codingPlanUsageAPI,
            data: [
                "queryCodingPlanInstanceInfoRequest": [
                    "commodityCode": commodityCode,
                    "onlyLatestOne": true,
                ],
            ],
            token: token,
            transport: transport)
    }

    /// Queries the Token Plan (personal) credit-ratio usage with the console
    /// Bearer token.
    static func fetchTokenPlanUsage(
        token: String,
        transport: any HTTPTransport
    ) async throws -> Data {
        try await gatewayCall(
            api: tokenPlanUsageAPI,
            data: [:],
            token: token,
            transport: transport)
    }

    /// Queries the Token Plan (personal) subscription record with the console
    /// Bearer token: plan tier and expiry date.
    static func fetchTokenPlanSubscription(
        token: String,
        transport: any HTTPTransport
    ) async throws -> Data {
        try await gatewayCall(
            api: tokenPlanSubscriptionAPI,
            data: [:],
            token: token,
            transport: transport)
    }

    /// The console routing block the official CLI gateway attaches to **every**
    /// call — including the Token Plan one, whose payload is otherwise empty.
    /// Computed rather than a shared `let`: `[String: Any]` is not `Sendable`.
    static var cornerstoneParam: [String: Any] {
        [
            "protocol": "V2",
            "console": "ONE_CONSOLE",
            "productCode": "p_efm",
            "switchUserType": 3,
            "consoleSite": "BAILIAN_ALIYUN",
        ]
    }

    /// Shared console-gateway POST. The gateway answers HTTP 200 with a
    /// `data.success == false` envelope for auth and business errors, so the
    /// envelope is inspected here instead of trusting the status code.
    private static func gatewayCall(
        api: String,
        data: [String: Any],
        token: String,
        transport: any HTTPTransport
    ) async throws -> Data {
        var payload = data
        payload["cornerstoneParam"] = cornerstoneParam
        let params: [String: Any] = ["Api": api, "V": "1.0", "Data": payload]
        let paramsJSON = String(
            data: try JSONSerialization.data(withJSONObject: params),
            encoding: .utf8) ?? "{}"
        let body = "params=\(Self.formEncode(paramsJSON))&region=cn-beijing"

        var request = URLRequest(url: Self.gatewayURL(api: api))
        request.httpMethod = "POST"
        request.timeoutInterval = 15
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.httpBody = Data(body.utf8)

        let response = try await transport.response(for: request)
        guard response.statusCode == 200 else {
            if response.statusCode == 401 || response.statusCode == 403 {
                throw UsageError.aliyunInvalidToken
            }
            throw UsageError.apiError(
                statusCode: response.statusCode,
                message: "Alibaba Cloud console: \(HTTPErrorSummary.summarize(response.data))")
        }
        try Self.assertEnvelopeSucceeded(response.data)
        return response.data
    }

    /// Maps the gateway's error envelope (HTTP 200 + `data.success == false`)
    /// onto the matching `UsageError`.
    private static func assertEnvelopeSucceeded(_ data: Data) throws {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let inner = object["data"] as? [String: Any]
        else { return }
        guard inner["success"] as? Bool == false else { return }
        let rawCode = inner["errorCode"]
        let code = rawCode as? String
            ?? (rawCode.map { String(describing: $0) } ?? "")
        let lower = code.lowercased()
        // Auth-flavoured envelope errors (the gateway answers HTTP 200 with
        // these): token minted but no longer accepted.
        let looksAuth = lower.contains("notlogined")
            || (lower.contains("token") && (lower.contains("invalid")
                || lower.contains("expired") || lower.contains("unauthorized")
                || lower.contains("notfound")))
            || lower.contains("unauthorized")
            || lower.contains("signinrequired")
        if looksAuth {
            throw UsageError.aliyunInvalidToken
        }
        // The gateway spells the detail `errorMessage` in some envelopes and
        // `errorMsg` in others (observed live for
        // `BailianGateway.Login.NotLogined`), so accept both.
        let message = (inner["errorMessage"] as? String ?? inner["errorMsg"] as? String) ?? code
        throw UsageError.apiError(statusCode: 0, message: "Alibaba Cloud console: \(message)")
    }

    private static func gatewayURL(api: String) -> URL {
        URL(string: "https://\(gatewayHost)/cli/api.json"
            + "?action=\(gatewayAction)&product=sfm_bailian"
            + "&api=\(api.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? api)")!
    }

    /// application/x-www-form-urlencoded value encoding (URLSearchParams shape).
    private static func formEncode(_ value: String) -> String {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-_.~*")
        // URLSearchParams encodes space as '+', everything else per RFC 3986.
        let encoded = value.addingPercentEncoding(withAllowedCharacters: allowed) ?? value
        return encoded.replacingOccurrences(of: " ", with: "+")
    }
}

/// In-memory cache of the minted console access token. Resolution order:
/// a browser-login token (Keychain, the user's explicit choice) first, then
/// an AK/SK mint, then the plan API key as a last-resort Bearer attempt.
/// The console gateway is a metadata API — a rejected key costs no quota.
actor AliyunConsoleTokenStore {
    private var minted: (token: String, storedAt: Date)?
    private let ttl: TimeInterval = 10 * 60
    /// Set once the plan key has been rejected by the console gateway; the
    /// attempt is not repeated on every refresh after that.
    private var apiKeyRejected = false

    func accessToken(
        consoleToken: String?,
        credentials: AliyunCredentials?,
        apiKey: String?,
        transport: any HTTPTransport
    ) async throws -> (token: String, source: AliyunConsoleTokenSource) {
        if let consoleToken, !consoleToken.isEmpty {
            return (consoleToken, .browserLogin)
        }
        if let credentials {
            if let minted, Date().timeIntervalSince(minted.storedAt) < ttl {
                return (minted.token, .accessKey)
            }
            let token = try await AliyunConsoleAPI.mintAccessToken(
                credentials: credentials,
                transport: transport)
            minted = (token, Date())
            return (token, .accessKey)
        }
        if let apiKey, !apiKey.isEmpty {
            guard !apiKeyRejected else {
                // Already proven not to authorize the console gateway this
                // run; repeating the attempt every refresh is pointless.
                throw UsageError.aliyunInvalidToken
            }
            return (apiKey, .apiKey)
        }
        throw UsageError.aliyunMissingCredentials
    }

    func invalidateMinted() {
        minted = nil
    }

    func markAPIKeyRejected() {
        apiKeyRejected = true
    }
}

/// Where the console Bearer token came from — decides what an auth failure
/// can do about it.
enum AliyunConsoleTokenSource: Sendable {
    /// From the console-login browser callback (Keychain). Cannot be
    /// refreshed without the user; a 401 clears it.
    case browserLogin
    /// Minted from AK/SK (in-memory). A 401 re-mints once.
    case accessKey
    /// The plan `sk-sp-` key tried directly on the console gateway.
    case apiKey
}
