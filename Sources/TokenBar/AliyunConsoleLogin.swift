import AppKit
import Foundation

/// Browser-login flow for the Bailian console, mirroring the official CLI's
/// `bl auth login --console`: bind a loopback port, open the console login
/// page, and receive the console access token the page posts back to
/// `127.0.0.1`. The resulting token authorizes the same console gateway the
/// AK/SK-minted token does — no Alibaba Cloud AK/SK needed.
enum AliyunConsoleLogin {
    struct Result: Sendable {
        let accessToken: String
    }

    enum LoginError: LocalizedError {
        case timedOut
        case listenerFailed(String)
        case invalidLoginURL

        var errorDescription: String? {
            switch self {
            case .timedOut:
                L(.errorAliyunConsoleLoginTimeout)
            case let .listenerFailed(detail):
                "\(L(.errorAliyunConsoleLoginFailed))（\(detail)）"
            case .invalidLoginURL:
                L(.errorAliyunConsoleLoginFailed)
            }
        }
    }

    static let consoleOrigin = "https://bailian.console.aliyun.com"
    static let defaultTimeout: TimeInterval = 600
    /// Same cap as the official CLI: a callback is tiny, so anything larger is noise.
    static let maxCallbackBody = 65_536

    /// Runs the flow end to end: opens the user's browser and resolves with
    /// the console access token once the login page calls back.
    static func run(timeout: TimeInterval = defaultTimeout) async throws -> Result {
        let state = UUID().uuidString.replacingOccurrences(of: "-", with: "")
        let server = try CallbackServer()
        defer { server.stop() }
        guard let url = URL(string: Self.loginURL(port: server.port, state: state)) else {
            throw LoginError.invalidLoginURL
        }
        _ = await MainActor.run { NSWorkspace.shared.open(url) }
        return Result(accessToken: try await server.serve(state: state, timeout: timeout))
    }

    /// The console login URL. The `notice` value embeds a literal `?`, which
    /// is what the official CLI sends — replicate it byte for byte.
    static func loginURL(port: Int, state: String) -> String {
        "\(consoleOrigin)/console-login?notice=127.0.0.1:\(port)?state=\(state)"
    }

    // MARK: - Callback server

    /// Loopback-only HTTP server for the one callback request.
    ///
    /// Deliberately a plain BSD socket rather than `NWListener`: while a VPN
    /// network extension is active (any WireGuard/TUN setup), `NWListener`
    /// fails every bind with `EINVAL` — regardless of port or interface
    /// parameters — which made this login unreachable on such machines. A
    /// socket bound to 127.0.0.1 also matches the official CLI's
    /// `listenLocalServer`, where `NWListener` would have listened on every
    /// interface.
    final class CallbackServer: @unchecked Sendable {
        private enum Outcome: Sendable {
            case token(String)
            case failure(Error)
        }

        private let lock = NSLock()
        private let fileDescriptor: Int32
        private var source: DispatchSourceRead?
        private var continuation: CheckedContinuation<String, Error>?
        private var settled = false
        private var stopped = false
        private var listenerClosed = false

        let port: Int

        init() throws {
            let descriptor = Darwin.socket(AF_INET, SOCK_STREAM, 0)
            guard descriptor >= 0 else { throw Self.bindError() }
            var reuse: Int32 = 1
            setsockopt(
                descriptor, SOL_SOCKET, SO_REUSEADDR, &reuse,
                socklen_t(MemoryLayout<Int32>.size))

            var address = sockaddr_in()
            address.sin_family = sa_family_t(AF_INET)
            address.sin_port = 0 // let the OS pick a free port
            address.sin_addr = in_addr(s_addr: inet_addr("127.0.0.1"))
            let bound = withUnsafePointer(to: address) { pointer in
                pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    Darwin.bind(descriptor, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
                }
            }
            guard bound == 0 else {
                Darwin.close(descriptor)
                throw Self.bindError()
            }
            guard Darwin.listen(descriptor, 16) == 0 else {
                Darwin.close(descriptor)
                throw Self.bindError()
            }

            var name = sockaddr_in()
            var nameLength = socklen_t(MemoryLayout<sockaddr_in>.size)
            let named = withUnsafeMutablePointer(to: &name) { pointer in
                pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    getsockname(descriptor, $0, &nameLength)
                }
            }
            guard named == 0 else {
                Darwin.close(descriptor)
                throw Self.bindError()
            }
            self.fileDescriptor = descriptor
            self.port = Int(UInt16(bigEndian: name.sin_port))
        }

        /// Accepts callbacks until the console delivers a token for `state`.
        func serve(state: String, timeout: TimeInterval) async throws -> String {
            try await withTaskCancellationHandler {
                try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<String, Error>) in
                    lock.lock()
                    if stopped {
                        lock.unlock()
                        // `stop()` already released the descriptor. Reaching
                        // here means the task was cancelled before it started
                        // serving, so report the cancellation rather than a
                        // bind failure the caller would have to interpret.
                        continuation.resume(throwing: Task.isCancelled
                            ? CancellationError()
                            : LoginError.listenerFailed("listener is already closed"))
                        return
                    }
                    let source = DispatchSource.makeReadSource(
                        fileDescriptor: fileDescriptor, queue: .global())
                    source.setEventHandler { [weak self] in self?.acceptOne(state: state) }
                    source.setCancelHandler { [weak self] in self?.closeListener() }
                    self.continuation = continuation
                    self.source = source
                    lock.unlock()
                    source.resume()

                    DispatchQueue.global().asyncAfter(deadline: .now() + timeout) { [weak self] in
                        self?.timeoutElapsed()
                    }
                }
            } onCancel: { [weak self] in
                self?.stop()
            }
        }

        func stop() {
            lock.lock()
            guard !stopped else { lock.unlock(); return }
            stopped = true
            let source = self.source
            self.source = nil
            lock.unlock()
            if let source {
                source.cancel() // the cancel handler releases the descriptor
            } else {
                closeListener() // never installed, so nothing else will
            }
            // A listener closed before it delivered a token was cancelled — by
            // a newer sign-in attempt, or by the caller giving up. Success and
            // timeout settle first, so this is a no-op for them.
            fail(CancellationError())
        }

        /// Idempotent: the cancel handler and the never-installed path both
        /// route here, and a descriptor must not be closed twice.
        private func closeListener() {
            lock.lock()
            guard !listenerClosed else { lock.unlock(); return }
            listenerClosed = true
            lock.unlock()
            Darwin.close(fileDescriptor)
        }

        private static func bindError() -> LoginError {
            LoginError.listenerFailed(String(cString: strerror(errno)))
        }

        private func timeoutElapsed() {
            fail(LoginError.timedOut)
            stop()
        }

        private func acceptOne(state: String) {
            var peer = sockaddr()
            var peerLength = socklen_t(MemoryLayout<sockaddr>.size)
            let connection = Darwin.accept(fileDescriptor, &peer, &peerLength)
            guard connection >= 0 else { return }
            // Reading blocks for up to the receive timeout, so it happens off
            // the source's queue: a client that connects and stalls must not
            // hold up the console's real callback.
            DispatchQueue.global().async { [weak self] in
                guard let self else { Darwin.close(connection); return }
                if let request = Self.readRequest(from: connection) {
                    self.handle(request, state: state, connection: connection)
                } else {
                    Self.writeAll(connection, Self.response(status: 400, body: "bad request"))
                }
                Darwin.close(connection)
            }
        }

        private func handle(_ request: CallbackRequest, state: String, connection: Int32) {
            if request.method == "OPTIONS" {
                Self.writeAll(
                    connection,
                    Self.response(status: 204, body: nil, optionsPreflight: true))
                return
            }
            guard request.query["state"] == state else {
                // Not our callback (or a forged one): answer and keep waiting.
                Self.writeAll(connection, Self.response(status: 400, body: "bad state"))
                return
            }
            guard let token = request.accessToken else {
                // The console posts intermediate requests before the token
                // lands; the official CLI answers them and keeps waiting.
                Self.writeAll(connection, Self.response(status: 200, body: "OK\n"))
                return
            }
            Self.writeAll(connection, Self.response(status: 200, body: """
                <html><body style="font-family:system-ui;text-align:center;padding:60px">\
                <h2>登录成功</h2><p>可以关闭这个页面，回到 TokenBar。</p></body></html>
                """, contentType: "text/html; charset=utf-8"))
            succeed(token)
        }

        private func succeed(_ token: String) {
            settle(with: .token(token))
            stop()
        }

        private func fail(_ error: Error) {
            settle(with: .failure(error))
        }

        private func settle(with outcome: Outcome) {
            lock.lock()
            guard !settled, let continuation else { lock.unlock(); return }
            settled = true
            self.continuation = nil
            lock.unlock()
            switch outcome {
            case let .token(token): continuation.resume(returning: token)
            case let .failure(error): continuation.resume(throwing: error)
            }
        }

        // MARK: Wire

        /// Reads one request, stopping once the header block and the body it
        /// promises have arrived (or the size/time cap is hit).
        private static func readRequest(from connection: Int32) -> CallbackRequest? {
            var receiveTimeout = timeval(tv_sec: 2, tv_usec: 0)
            setsockopt(
                connection, SOL_SOCKET, SO_RCVTIMEO, &receiveTimeout,
                socklen_t(MemoryLayout<timeval>.size))
            var data = Data()
            var buffer = [UInt8](repeating: 0, count: 8192)
            while data.count < AliyunConsoleLogin.maxCallbackBody {
                let received = read(connection, &buffer, buffer.count)
                guard received > 0 else { break }
                data.append(contentsOf: buffer[0..<received])
                if isRequestComplete(data) { break }
            }
            return CallbackRequest.parse(data)
        }

        private static func isRequestComplete(_ data: Data) -> Bool {
            guard let headerEnd = data.range(of: CallbackRequest.headerSeparator) else {
                return false
            }
            guard let head = String(data: data[..<headerEnd.lowerBound], encoding: .utf8) else {
                return true
            }
            let declared = head.components(separatedBy: "\r\n").compactMap { line -> Int? in
                guard line.lowercased().hasPrefix("content-length:") else { return nil }
                return Int(line.dropFirst("content-length:".count)
                    .trimmingCharacters(in: .whitespaces))
            }
            // No Content-Length (a GET, or a bodyless POST): headers are enough.
            return data.count - headerEnd.upperBound >= (declared.first ?? 0)
        }

        private static func response(
            status: Int,
            body: String?,
            contentType: String = "text/plain; charset=utf-8",
            optionsPreflight: Bool = false
        ) -> Data {
            let payload = Data((body ?? "").utf8)
            var header = "HTTP/1.1 \(status) \(Self.reasonPhrase(status))\r\n"
            header += "Content-Type: \(contentType)\r\n"
            header += "Content-Length: \(payload.count)\r\n"
            header += "Connection: close\r\n"
            // The console posts the token with a cross-origin `fetch`, so every
            // answer needs the CORS header — without it the browser reports the
            // round trip as failed and the page sits on 「授权中」 even though the
            // token already landed here. The official CLI sends it too.
            header += "Access-Control-Allow-Origin: *\r\n"
            if optionsPreflight {
                header += "Access-Control-Allow-Methods: GET, POST, PUT, PATCH, OPTIONS\r\n"
                header += "Access-Control-Allow-Headers: Content-Type\r\n"
            }
            header += "\r\n"
            return Data(header.utf8) + payload
        }

        private static func reasonPhrase(_ status: Int) -> String {
            switch status {
            case 200: "OK"
            case 204: "No Content"
            case 400: "Bad Request"
            default: "OK"
            }
        }

        private static func writeAll(_ connection: Int32, _ payload: Data) {
            var remaining = payload[...]
            while !remaining.isEmpty {
                let sent = remaining.withUnsafeBytes { buffer in
                    Darwin.write(connection, buffer.baseAddress, buffer.count)
                }
                guard sent > 0 else { return }
                remaining = remaining.dropFirst(sent)
            }
        }
    }

    // MARK: - Request parsing

    /// A parsed callback request: method, query parameters, and body.
    struct CallbackRequest {
        let method: String
        let query: [String: String]
        private let body: Data
        private let contentType: String

        static let headerSeparator = Data("\r\n\r\n".utf8)

        var accessToken: String? {
            if let fromQuery = query["access_token"] ?? query["accessToken"],
               !fromQuery.isEmpty
            {
                return fromQuery
            }
            guard !body.isEmpty else { return nil }
            let lower = contentType.lowercased()
            if lower.contains("multipart/form-data") { return multipartValue() }
            if lower.contains("json") { return jsonValue() }
            if lower.contains("application/x-www-form-urlencoded") { return formValue() }
            // Missing or nonstandard Content-Type: try every shape, like the
            // official CLI does.
            return jsonValue() ?? formValue() ?? multipartValue()
        }

        private func jsonValue() -> String? {
            guard let object = try? JSONSerialization.jsonObject(with: body) as? [String: Any]
            else { return nil }
            for dictionary in [object, object["data"] as? [String: Any]] {
                guard let dictionary else { continue }
                for key in ["access_token", "accessToken"] {
                    if let value = dictionary[key] as? String, !value.isEmpty { return value }
                }
            }
            return nil
        }

        /// `application/x-www-form-urlencoded`, tolerating `+` as a space.
        private func formValue() -> String? {
            let text = String(decoding: body, as: UTF8.self)
            for pair in text.split(separator: "&") {
                let kv = pair.split(separator: "=", maxSplits: 1)
                guard kv.count == 2 else { continue }
                let name = String(kv[0]).replacingOccurrences(of: "+", with: " ")
                guard name == "access_token" || name == "accessToken" else { continue }
                let raw = String(kv[1])
                let value = raw.replacingOccurrences(of: "+", with: " ")
                    .removingPercentEncoding ?? raw
                if !value.isEmpty { return value }
            }
            return nil
        }

        /// A `multipart/form-data` part named `access_token` / `accessToken` —
        /// what a `fetch()` with a `FormData` body sends.
        private func multipartValue() -> String? {
            guard let boundary = Self.boundary(in: contentType) else { return nil }
            let text = String(decoding: body, as: UTF8.self)
            for part in text.components(separatedBy: "--\(boundary)").dropFirst() {
                guard part.range(
                    of: #"name\s*=\s*["'](?:access_token|accessToken)["']"#,
                    options: .regularExpression
                ) != nil else { continue }
                guard let separator = part.range(of: "\r\n\r\n") ?? part.range(of: "\n\n")
                else { continue }
                let value = String(part[separator.upperBound...])
                    .replacingOccurrences(of: "\r\n", with: "")
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                if !value.isEmpty { return value }
            }
            return nil
        }

        private static func boundary(in contentType: String) -> String? {
            for parameter in contentType.components(separatedBy: ";") {
                let trimmed = parameter.trimmingCharacters(in: .whitespaces)
                guard trimmed.lowercased().hasPrefix("boundary=") else { continue }
                let value = String(trimmed.dropFirst("boundary=".count))
                    .trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
                if !value.isEmpty { return value }
            }
            return nil
        }

        static func parse(_ data: Data) -> CallbackRequest? {
            guard let headerEnd = data.range(of: headerSeparator),
                  let head = String(data: data[..<headerEnd.lowerBound], encoding: .utf8)
            else { return nil }
            let lines = head.components(separatedBy: "\r\n")
            guard let requestLine = lines.first?.components(separatedBy: " "),
                  requestLine.count >= 2
            else { return nil }
            let method = requestLine[0]

            var query: [String: String] = [:]
            if let questionMark = requestLine[1].firstIndex(of: "?") {
                for pair in requestLine[1][requestLine[1].index(after: questionMark)...]
                    .split(separator: "&")
                {
                    let kv = pair.split(separator: "=", maxSplits: 1)
                    guard let name = kv.first else { continue }
                    let key = String(name).removingPercentEncoding ?? String(name)
                    let value = kv.count == 2
                        ? (String(kv[1]).replacingOccurrences(of: "+", with: " ")
                            .removingPercentEncoding ?? String(kv[1]))
                        : ""
                    query[key] = value
                }
            }

            var contentType = ""
            var contentLength = 0
            for line in lines.dropFirst() {
                let parts = line.split(separator: ":", maxSplits: 1)
                guard parts.count == 2 else { continue }
                let name = parts[0].trimmingCharacters(in: .whitespaces).lowercased()
                let value = parts[1].trimmingCharacters(in: .whitespaces)
                if name == "content-type" { contentType = value }
                if name == "content-length" { contentLength = Int(value) ?? 0 }
            }
            var body = Data(data[headerEnd.upperBound...])
            if contentLength > 0 { body = body.prefix(contentLength) }
            return CallbackRequest(
                method: method, query: query, body: body, contentType: contentType)
        }
    }
}
