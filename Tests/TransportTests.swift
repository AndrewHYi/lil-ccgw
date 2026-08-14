import Foundation

/// Tests for the real transport's request building and response mapping.
///
/// `MockTransport` covers what the client *sends* at the protocol level, but it
/// replaces `URLSessionTransport` entirely — so the code that actually builds the
/// `URLRequest` and interprets the reply had no tests at all. That code decides
/// what the whole UI shows when a call goes wrong, and `GatewayError.http` was
/// only ever tested by constructing it by hand rather than by the code that
/// builds it from a response.
///
/// No socket is opened here. `urlRequest` and `result` are pure, which is why
/// they were split out of `send`.
func runTransportTests() {
    let url = URL(string: "http://127.0.0.1:8484/api/status")!

    T.suite("the token header goes out whenever a token exists") {
        // The contract is explicit that the header must be sent even though
        // api_token defaults to false: the day that flag flips, every mutating
        // button breaks at once if this is wrong.
        let req = URLSessionTransport.urlRequest(
            for: GatewayRequest(path: "/api/status", method: "GET", body: nil),
            to: url, token: "sekrit")
        T.equal(req.value(forHTTPHeaderField: "X-CCGW-Token"), "sekrit",
                "the token is sent as X-CCGW-Token")
        T.equal(req.httpMethod, "GET", "the method is carried through")
        T.equal(req.value(forHTTPHeaderField: "content-type"), nil,
                "a bodyless request sets no content type")
    }

    T.suite("no token means no header at all") {
        let req = URLSessionTransport.urlRequest(
            for: GatewayRequest(path: "/api/status", method: "GET", body: nil),
            to: url, token: nil)
        T.equal(req.value(forHTTPHeaderField: "X-CCGW-Token"), nil,
                "the header is absent rather than empty — an empty token would be a value")
    }

    T.suite("a body implies JSON") {
        let body = Data(#"{"enforcement":"on"}"#.utf8)
        let req = URLSessionTransport.urlRequest(
            for: GatewayRequest(path: "/api/budgets", method: "PUT", body: body),
            to: url, token: nil)
        T.equal(req.httpMethod, "PUT", "the method is carried through")
        T.equal(req.httpBody, body, "the body is sent verbatim")
        T.equal(req.value(forHTTPHeaderField: "content-type"), "application/json",
                "a body always declares JSON — the gateway rejects it otherwise")
    }

    T.suite("a 2xx response returns its bytes") {
        let payload = Data(#"{"ok":true}"#.utf8)
        for code in [200, 201, 204, 299] {
            let response = HTTPURLResponse(
                url: url, statusCode: code, httpVersion: nil, headerFields: nil)!
            do {
                let out = try URLSessionTransport.result(data: payload, response: response)
                T.equal(out, payload, "\(code) returns the body unchanged")
            } catch {
                T.fail("\(code) should not throw, threw \(error)")
            }
        }
    }

    T.suite("a non-2xx response becomes a GatewayError.http carrying the message") {
        // The gateway explains its refusals in the body — "bumping it would raise
        // total spend" is the one users hit most — so the text has to survive.
        let body = Data("bumping the ceiling would raise total spend".utf8)
        let response = HTTPURLResponse(
            url: url, statusCode: 400, httpVersion: nil, headerFields: nil)!
        do {
            _ = try URLSessionTransport.result(data: body, response: response)
            T.fail("a 400 should throw")
        } catch let error as GatewayError {
            switch error {
            case let .http(code, message):
                T.equal(code, 400, "the status code is preserved")
                T.expect(message?.contains("raise total spend") == true,
                         "the gateway's own explanation reaches the UI")
            default:
                T.fail("expected .http, got \(error)")
            }
        } catch {
            T.fail("expected a GatewayError, got \(error)")
        }
    }

    T.suite("boundary status codes land on the right side") {
        for (code, shouldThrow) in [(199, true), (200, false), (299, false), (300, true)] {
            let response = HTTPURLResponse(
                url: url, statusCode: code, httpVersion: nil, headerFields: nil)!
            var threw = false
            do { _ = try URLSessionTransport.result(data: Data(), response: response) }
            catch { threw = true }
            T.equal(threw, shouldThrow, "\(code) \(shouldThrow ? "throws" : "succeeds")")
        }
    }

    T.suite("a non-HTTP response is unreachable, not a crash") {
        // A URLResponse that isn't HTTP means the load did not reach the gateway
        // in any meaningful sense. Force-casting here would trap.
        T.expectThrows("a plain URLResponse throws", GatewayError.unreachable) {
            try URLSessionTransport.result(
                data: Data(), response: URLResponse(
                    url: url, mimeType: nil,
                    expectedContentLength: 0, textEncodingName: nil))
        }
        T.expectThrows("a nil response throws", GatewayError.unreachable) {
            try URLSessionTransport.result(data: Data(), response: nil)
        }
    }

    T.suite("notifier explanations cover every authorization state") {
        // Unreachable until `explanation` took its inputs instead of reading
        // them: the test binary has no bundle identifier, so the unavailable
        // branch swallowed the rest — including denied, which is the state an
        // ad-hoc signed app most often lands in.
        T.equal(Notifier.explanation(available: false, status: .notRequested),
                Notifier.unbundledExplanation,
                "unbundled is explained regardless of status")
        T.equal(Notifier.explanation(available: true, status: .unavailable),
                Notifier.unbundledExplanation,
                "an unavailable status says the same thing")
        T.expect(Notifier.explanation(available: true, status: .denied)?
                    .contains("denied") == true,
                 "denial is explained rather than left as a silent no-op toggle")
        T.equal(Notifier.explanation(available: true, status: .authorized), nil,
                "an authorized notifier needs no explanation")
        T.equal(Notifier.explanation(available: true, status: .notRequested), nil,
                "nor does one that has not been asked yet")
    }
}
