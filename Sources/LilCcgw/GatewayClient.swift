import Foundation

enum GatewayError: LocalizedError {
    case unreachable
    case http(Int, String?)

    var errorDescription: String? {
        switch self {
        case .unreachable:
            return "Gateway not responding"
        case let .http(code, body):
            if let body, !body.isEmpty { return "HTTP \(code): \(body)" }
            return "HTTP \(code)"
        }
    }
}

/// Talks to the local ccgw gateway.
///
/// Two non-obvious rules, both load-bearing:
///
/// 1. Always address the gateway as `127.0.0.1`, never `localhost`. It
///    validates the Host header against loopback names to defeat DNS
///    rebinding, and a `localhost` resolution can arrive as an IPv6 literal.
/// 2. Send `X-CCGW-Token` whenever `~/.ccgw/token` exists, even though
///    `api_token` currently defaults to false. Mutations are open on loopback
///    today; sending the token unconditionally means flipping that config flag
///    later doesn't silently break every button in the menu.
actor GatewayClient {
    private let session: URLSession
    private var host: String
    private var port: Int

    init(host: String = "127.0.0.1", port: Int = 8484) {
        self.host = host
        self.port = port
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 3
        config.waitsForConnectivity = false
        self.session = URLSession(configuration: config)
    }

    func configure(host: String, port: Int) {
        self.host = host
        self.port = port
    }

    var dashboardURL: URL? { URL(string: "http://\(host):\(port)/dash") }

    // MARK: - Reads

    func status() async throws -> GatewayStatus {
        try await get("/api/status")
    }

    func health() async throws -> GatewayHealth {
        try await get("/api/health")
    }

    /// Per-model spend over an explicit window.
    ///
    /// The caller passes the tracked budget's own window so the breakdown
    /// explains the budget it sits beneath. That matters for comparability: the
    /// dashboard's breakdown defaults to 1 day and its widest option is 1 week,
    /// so a hardcoded 30-day window here would read as a discrepancy against
    /// `/dash` the moment any spend ages past a day.
    func spendByModel(windowSeconds: TimeInterval) async throws -> SpendReport {
        let from = Int(Date().addingTimeInterval(-windowSeconds).timeIntervalSince1970 * 1000)
        return try await get("/api/spend?group_by=model&from=\(from)")
    }

    // MARK: - Mutations

    /// Graceful restart: the gateway drains in-flight requests, then exits. It
    /// detects launchd/systemd supervision itself and lets the supervisor
    /// respawn rather than self-spawning, so this is the correct restart path
    /// on a managed install.
    func restart() async throws {
        _ = try await send("/api/restart", method: "POST", body: nil)
    }

    /// Pause budget enforcement. Spend keeps recording; the gateway
    /// auto-resumes at `enforcement_resume_at` so a pause can't be forgotten.
    /// Minutes clamp to 1…1440 server-side.
    func pauseEnforcement(minutes: Int) async throws {
        let body: [String: Any] = ["enforcement": "off", "pause_minutes": minutes]
        _ = try await send("/api/budgets", method: "PUT", body: body)
    }

    func resumeEnforcement() async throws {
        _ = try await send("/api/budgets", method: "PUT", body: ["enforcement": "on"])
    }

    /// Add a temporary allowance to one budget.
    ///
    /// `minutes` nil means "this window" — the gateway defaults to the budget's
    /// own window length. It clamps to 5…10080 and the amount to 0…10000.
    ///
    /// Bumps **stack**: bumping an active bumper adds to it and keeps the later
    /// expiry, so topping up never requires clearing first.
    ///
    /// The gateway refuses to bump the overall ceiling — the widest-window
    /// `block` budget — because that would raise total spend rather than
    /// reshaping it. Callers should not offer the action there; see
    /// `Budget.isCeiling(among:)`.
    func bump(budgetId: String, amountUsd: Double, minutes: Int?) async throws {
        var bump: [String: Any] = ["budget_id": budgetId, "amount_usd": amountUsd]
        if let minutes { bump["minutes"] = minutes }
        _ = try await send("/api/budgets", method: "PUT", body: ["bump": bump])
    }

    func clearBump(budgetId: String) async throws {
        _ = try await send("/api/budgets", method: "PUT",
                           body: ["bump": ["budget_id": budgetId, "clear": true]])
    }

    // MARK: - Plumbing

    private func url(_ path: String) throws -> URL {
        guard let url = URL(string: "http://\(host):\(port)\(path)") else {
            throw GatewayError.unreachable
        }
        return url
    }

    private func request(_ path: String, method: String) throws -> URLRequest {
        var req = URLRequest(url: try url(path))
        req.httpMethod = method
        if let token = Self.apiToken() {
            req.setValue(token, forHTTPHeaderField: "X-CCGW-Token")
        }
        return req
    }

    private func get<T: Decodable>(_ path: String) async throws -> T {
        let data = try await send(path, method: "GET", body: nil)
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return try decoder.decode(T.self, from: data)
    }

    private func send(_ path: String, method: String, body: [String: Any]?) async throws -> Data {
        var req = try request(path, method: method)
        if let body {
            req.setValue("application/json", forHTTPHeaderField: "content-type")
            req.httpBody = try JSONSerialization.data(withJSONObject: body)
        }
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: req)
        } catch {
            throw GatewayError.unreachable
        }
        guard let http = response as? HTTPURLResponse else { throw GatewayError.unreachable }
        guard (200..<300).contains(http.statusCode) else {
            throw GatewayError.http(http.statusCode, String(data: data, encoding: .utf8))
        }
        return data
    }

    /// Read once per call rather than caching: the token file can appear or be
    /// rotated while the app is running.
    private static func apiToken() -> String? {
        let path = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".ccgw/token")
        guard let raw = try? String(contentsOf: path, encoding: .utf8) else { return nil }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    /// The gateway's own config, used to default the host/port so the app
    /// follows a user who moved the gateway off :8484.
    static func configuredPort() -> Int? {
        let path = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".ccgw/config.json")
        guard let data = try? Data(contentsOf: path),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let port = object["port"] as? Int
        else { return nil }
        return port
    }
}
