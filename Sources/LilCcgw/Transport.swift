import Foundation

/// One request, described independently of how it's sent.
struct GatewayRequest: Sendable, Equatable {
    let path: String
    let method: String
    /// JSON body, pre-serialised so this stays `Sendable` and comparable.
    let body: Data?

    /// Decoded body as a dictionary, for assertions about what was sent.
    var jsonBody: [String: Any]? {
        guard let body else { return nil }
        return try? JSONSerialization.jsonObject(with: body) as? [String: Any]
    }
}

/// How a `GatewayClient` reaches the gateway.
///
/// This exists so tests can drive `GatewayModel` end to end without a live
/// gateway — and, more usefully, so they can assert *what was sent* rather than
/// only what came back. Several bugs this app has already had were wrong-request
/// bugs (a breakdown fetched over the wrong window, a bumper aimed at a budget
/// the gateway refuses), which are invisible if you only check the response.
///
/// Production uses `URLSessionTransport`; nothing about the shipping path
/// changes.
protocol Transport: Sendable {
    func send(_ request: GatewayRequest, to url: URL, token: String?) async throws -> Data
}

/// The real transport: loopback HTTP with a short timeout.
struct URLSessionTransport: Transport {
    private let session: URLSession

    init(timeout: TimeInterval = 3) {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = timeout
        config.waitsForConnectivity = false
        self.session = URLSession(configuration: config)
    }

    /// Builds the `URLRequest` for a gateway call.
    ///
    /// Split out from `send` so the header and body rules are testable without a
    /// listening socket. The token header in particular has to go out on every
    /// request the moment `~/.ccgw/token` exists — see `ccgw-api-contract` — and
    /// nothing else asserts that it does.
    static func urlRequest(
        for request: GatewayRequest, to url: URL, token: String?
    ) -> URLRequest {
        var req = URLRequest(url: url)
        req.httpMethod = request.method
        if let token {
            req.setValue(token, forHTTPHeaderField: "X-CCGW-Token")
        }
        if let body = request.body {
            req.setValue("application/json", forHTTPHeaderField: "content-type")
            req.httpBody = body
        }
        return req
    }

    /// Turns a completed URL load into either bytes or a `GatewayError`.
    ///
    /// Pure, and separate from `send` because this is the code that decides what
    /// the entire UI shows when a call goes wrong — dashes and "unreachable"
    /// versus a specific HTTP message. It was previously reachable only through
    /// a real socket, so `GatewayError.http` was only ever tested by
    /// constructing it by hand rather than by the code that builds it.
    static func result(data: Data, response: URLResponse?) throws -> Data {
        guard let http = response as? HTTPURLResponse else { throw GatewayError.unreachable }
        guard (200..<300).contains(http.statusCode) else {
            throw GatewayError.http(http.statusCode, String(data: data, encoding: .utf8))
        }
        return data
    }

    func send(_ request: GatewayRequest, to url: URL, token: String?) async throws -> Data {
        let req = Self.urlRequest(for: request, to: url, token: token)

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: req)
        } catch {
            // Any transport-level failure is "the gateway isn't answering" as far
            // as the UI is concerned; the distinction between refused, timed out,
            // and DNS-failed doesn't change what the user can do about it.
            throw GatewayError.unreachable
        }
        return try Self.result(data: data, response: response)
    }
}
