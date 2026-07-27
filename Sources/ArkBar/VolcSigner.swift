import CryptoKit
import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Volcengine AK/SK credentials for the Coding Plan usage API.
struct VolcCredentials: Sendable {
    let accessKeyID: String
    let secretAccessKey: String
    let region: String

    init(accessKeyID: String, secretAccessKey: String, region: String = "cn-beijing") {
        self.accessKeyID = accessKeyID
        self.secretAccessKey = secretAccessKey
        self.region = region
    }
}

/// Volcengine V4 (HMAC-SHA256) request signer. Ported from CodexBar's DoubaoVolcengineSigner,
/// which is the canonical signing shape for `open.volcengineapi.com` Ark services.
enum VolcSigner {
    private static let algorithm = "HMAC-SHA256"
    private static let service = "ark"
    private static let terminator = "request"
    /// Canonical/signed headers must be sorted alphabetically by lower-cased name;
    /// the server re-sorts and recomputes, so an unsorted list yields HTTP 403.
    private static let signedHeaders = "content-type;host;x-content-sha256;x-date"

    static func sign(
        request: inout URLRequest,
        body: Data,
        credentials: VolcCredentials,
        date: Date = Date()
    ) {
        let timestamp = Self.timestampFormatter.string(from: date)
        let dateStamp = Self.dateFormatter.string(from: date)
        let payloadHash = Self.sha256Hex(body)
        let contentType = request.value(forHTTPHeaderField: "Content-Type")
            ?? "application/x-www-form-urlencoded; charset=utf-8"
        request.setValue(contentType, forHTTPHeaderField: "Content-Type")
        request.setValue(timestamp, forHTTPHeaderField: "X-Date")
        request.setValue(payloadHash, forHTTPHeaderField: "X-Content-Sha256")

        guard let url = request.url else { return }
        let host = url.host ?? ""
        request.setValue(host, forHTTPHeaderField: "Host")

        let canonicalRequest = [
            request.httpMethod ?? "POST",
            Self.canonicalURI(url),
            Self.canonicalQueryString(url),
            "content-type:\(contentType)",
            "host:\(host)",
            "x-content-sha256:\(payloadHash)",
            "x-date:\(timestamp)",
            "",
            Self.signedHeaders,
            payloadHash,
        ].joined(separator: "\n")

        let credentialScope = "\(dateStamp)/\(credentials.region)/\(Self.service)/\(Self.terminator)"
        let stringToSign = [
            Self.algorithm,
            timestamp,
            credentialScope,
            Self.sha256Hex(Data(canonicalRequest.utf8)),
        ].joined(separator: "\n")

        let signature = Self.signature(
            stringToSign: stringToSign,
            secretAccessKey: credentials.secretAccessKey,
            dateStamp: dateStamp,
            region: credentials.region)
        let authorization = "\(Self.algorithm) Credential=\(credentials.accessKeyID)/\(credentialScope), "
            + "SignedHeaders=\(Self.signedHeaders), Signature=\(signature)"
        request.setValue(authorization, forHTTPHeaderField: "Authorization")
    }

    private static func signature(
        stringToSign: String,
        secretAccessKey: String,
        dateStamp: String,
        region: String
    ) -> String {
        let dateKey = Self.hmac(key: SymmetricKey(data: Data(secretAccessKey.utf8)), message: dateStamp)
        let regionKey = Self.hmac(key: SymmetricKey(data: dateKey), message: region)
        let serviceKey = Self.hmac(key: SymmetricKey(data: regionKey), message: Self.service)
        let signingKey = Self.hmac(key: SymmetricKey(data: serviceKey), message: Self.terminator)
        let signature = HMAC<SHA256>.authenticationCode(
            for: Data(stringToSign.utf8),
            using: SymmetricKey(data: signingKey))
        return Data(signature).map { String(format: "%02x", $0) }.joined()
    }

    private static func hmac(key: SymmetricKey, message: String) -> Data {
        Data(HMAC<SHA256>.authenticationCode(for: Data(message.utf8), using: key))
    }

    private static func sha256Hex(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private static func canonicalURI(_ url: URL) -> String {
        let path = url.path.isEmpty ? "/" : url.path
        return Self.percentEncode(path, encodeSlash: false)
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

    private static func percentEncode(_ value: String, encodeSlash: Bool = true) -> String {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-_.~")
        if !encodeSlash { allowed.insert("/") }
        return value.addingPercentEncoding(withAllowedCharacters: allowed) ?? value
    }

    private static let timestampFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(secondsFromGMT: 0)
        f.dateFormat = "yyyyMMdd'T'HHmmss'Z'"
        return f
    }()

    private static let dateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(secondsFromGMT: 0)
        f.dateFormat = "yyyyMMdd"
        return f
    }()
}

/// Resolves Volcengine AK/SK from environment variables (same names arkcli/CodexBar accept).
enum VolcCredentialResolver {
    static let accessKeyKeys = [
        "VOLCENGINE_ACCESS_KEY_ID",
        "VOLCENGINE_ACCESS_KEY",
        "VOLC_ACCESSKEY",
        "DOUBAO_ACCESS_KEY_ID",
    ]
    static let secretKeyKeys = [
        "VOLCENGINE_SECRET_ACCESS_KEY",
        "VOLCENGINE_SECRET_KEY",
        "VOLCENGINE_ACCESS_KEY_SECRET",
        "VOLC_SECRETKEY",
        "DOUBAO_SECRET_ACCESS_KEY",
    ]
    static let regionKeys = ["VOLCENGINE_REGION", "VOLCENGINE_REGION_ID", "VOLC_REGION", "DOUBAO_REGION"]

    static func resolve(environment: [String: String]) -> VolcCredentials? {
        guard let ak = firstValue(in: environment, keys: accessKeyKeys),
              let sk = firstValue(in: environment, keys: secretKeyKeys)
        else { return nil }
        let region = firstValue(in: environment, keys: regionKeys) ?? "cn-beijing"
        return VolcCredentials(accessKeyID: ak, secretAccessKey: sk, region: region)
    }

    private static func firstValue(in env: [String: String], keys: [String]) -> String? {
        for key in keys {
            guard var v = env[key]?.trimmingCharacters(in: .whitespacesAndNewlines), !v.isEmpty else { continue }
            if (v.hasPrefix("\"") && v.hasSuffix("\"")) || (v.hasPrefix("'") && v.hasSuffix("'")) {
                v = String(v.dropFirst().dropLast())
            }
            v = v.trimmingCharacters(in: .whitespacesAndNewlines)
            if !v.isEmpty { return v }
        }
        return nil
    }
}
