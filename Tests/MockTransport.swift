import Foundation

/// A `Transport` that answers from canned data and records every request.
///
/// The recording is the point. Responses alone can't catch a wrong-request bug —
/// fetching the model breakdown over 30 days while the budget above it covers 5
/// hours produced perfectly valid JSON and a panel that contradicted itself. So
/// these tests assert the bytes that went out, not just what came back.
final class MockTransport: Transport, @unchecked Sendable {
    /// Bodies keyed by path prefix, so `/api/spend?...` matches `/api/spend`.
    private var responses: [String: Data] = [:]
    /// Paths told to fail, and with what.
    private var failures: [String: GatewayError] = [:]

    private let lock = NSLock()
    private var _requests: [(request: GatewayRequest, url: URL, token: String?)] = []

    var requests: [(request: GatewayRequest, url: URL, token: String?)] {
        lock.lock(); defer { lock.unlock() }
        return _requests
    }

    var paths: [String] { requests.map(\.request.path) }

    /// Every URL as sent, query string included — this is where window
    /// parameters are asserted.
    var urls: [String] { requests.map(\.url.absoluteString) }

    init() {}

    // MARK: - Setup

    @discardableResult
    func stub(_ path: String, json: String) -> Self {
        lock.lock(); defer { lock.unlock() }
        responses[path] = Data(json.utf8)
        failures.removeValue(forKey: path)
        return self
    }

    @discardableResult
    func fail(_ path: String, with error: GatewayError = .unreachable) -> Self {
        lock.lock(); defer { lock.unlock() }
        failures[path] = error
        responses.removeValue(forKey: path)
        return self
    }

    /// The healthy default: all three read endpoints stubbed from live-captured
    /// fixtures, and mutations accepted.
    static func healthy() -> MockTransport {
        let m = MockTransport()
        m.stub("/api/status", json: statusFixture)
        m.stub("/api/health", json: healthFixture)
        m.stub("/api/spend", json: spendFixture)
        m.stub("/api/restart", json: #"{"restarting":true}"#)
        m.stub("/api/budgets", json: #"{"budgets":[]}"#)
        return m
    }

    // MARK: - Inspection

    func request(to path: String) -> GatewayRequest? {
        requests.last { $0.request.path.hasPrefix(path) }?.request
    }

    func url(for path: String) -> String? {
        requests.last { $0.request.path.hasPrefix(path) }?.url.absoluteString
    }

    func callCount(_ path: String) -> Int {
        paths.filter { $0.hasPrefix(path) }.count
    }

    func reset() {
        lock.lock(); defer { lock.unlock() }
        _requests.removeAll()
    }

    // MARK: - Transport

    func send(_ request: GatewayRequest, to url: URL, token: String?) async throws -> Data {
        // All locking happens in a synchronous helper: holding an NSLock across
        // an async boundary is an error in Swift 6.
        let (data, error) = recordAndResolve(request, url, token)
        if let error { throw error }
        guard let data else {
            throw GatewayError.http(404, "MockTransport has no stub for \(request.path)")
        }
        return data
    }

    private func recordAndResolve(
        _ request: GatewayRequest, _ url: URL, _ token: String?
    ) -> (Data?, GatewayError?) {
        lock.lock()
        defer { lock.unlock() }
        _requests.append((request, url, token))
        // Longest-prefix match so a stub for "/api/spend" answers
        // "/api/spend?group_by=model&from=…".
        let key = responses.keys
            .filter { request.path.hasPrefix($0) }
            .max(by: { $0.count < $1.count })
        let failure = failures.keys
            .filter { request.path.hasPrefix($0) }
            .max(by: { $0.count < $1.count })
        return (key.flatMap { responses[$0] }, failure.flatMap { failures[$0] })
    }
}
