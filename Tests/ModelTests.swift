import Foundation

/// End-to-end tests for `GatewayModel` driven by a mock transport.
///
/// These cover the behaviour that only exists when the pieces run together:
/// per-section degradation, the exact requests each control issues, error
/// capture, and the notifier's fire-once rule. All of it was untestable while
/// the client built its own `URLSession`.
///
/// Every assertion here would still hold against a real gateway — the mock
/// supplies fixtures captured verbatim from one, and the wire-level assertions
/// check what this app sends rather than what the mock decides to return.
@MainActor
func runModelTests() async {
    func model(_ transport: MockTransport) -> GatewayModel {
        GatewayModel(client: GatewayClient(transport: transport))
    }

    // MARK: - Reads

    do {
        T.currentSuite = "refresh populates every section"
        let t = MockTransport.healthy()
        let m = model(t)
        await m.refresh()

        T.expect(m.snapshot.status != nil, "status decoded")
        T.expect(m.snapshot.health != nil, "health decoded")
        T.expect(m.snapshot.spend != nil, "spend decoded")
        T.equal(m.snapshot.status?.budgets.count, 4, "all four budgets")
        T.equal(m.snapshot.health?.version, "0.1.52", "version")
        T.equal(m.reachability, .live, "reachable")
        T.expect(m.lastError == nil, "no error on a healthy refresh")
        T.expect(m.lastUpdated != nil, "timestamp recorded")

        // All three endpoints, once each.
        T.equal(t.callCount("/api/status"), 1, "status fetched once")
        T.equal(t.callCount("/api/health"), 1, "health fetched once")
        T.equal(t.callCount("/api/spend"), 1, "spend fetched once")
    }

    do {
        T.currentSuite = "spend window follows the tracked budget"
        // Asserted at the wire, because this is exactly the bug that made the
        // panel disagree with /dash: a 30-day breakdown sitting under a 5-hour
        // budget. The URL is the only place that discrepancy is visible.
        let t = MockTransport.healthy()
        let m = model(t)
        await m.refresh()

        guard let url = t.url(for: "/api/spend") else {
            return T.expect(false, "spend was requested")
        }
        T.expect(url.contains("group_by=model"), "grouped by model")

        // The tracked budget is session/5h, so `from` must be ~5h ago — not 24h,
        // not 30d.
        guard let fromValue = url.split(separator: "from=").last.flatMap({ Double($0) }) else {
            return T.expect(false, "from parameter present and numeric")
        }
        let ageSeconds = Date().timeIntervalSince1970 - fromValue / 1000
        T.expect(abs(ageSeconds - 18_000) < 120,
                 "spend window is ~5h to match the session budget (got \(Int(ageSeconds))s)")
        T.close(m.spendWindowSeconds, 18_000, "model records the same window")
        T.equal(m.spendWindowLabel, "5h", "and labels it honestly")
    }

    do {
        T.currentSuite = "per-section degradation"
        // The reason refresh() fetches independently: one dead endpoint must
        // cost one section, not the whole panel. Never tested until now.
        let t = MockTransport.healthy().fail("/api/spend")
        let m = model(t)
        await m.refresh()

        T.expect(m.snapshot.status != nil, "budgets survive a spend failure")
        T.expect(m.snapshot.health != nil, "health survives too")
        T.expect(m.snapshot.spend == nil, "only the models section is missing")
        T.equal(m.reachability, .live, "still considered reachable")
        T.expect(m.lastError == nil, "a partial failure is not a panel-wide error")

        // And the reverse: health down while status works.
        let t2 = MockTransport.healthy().fail("/api/health")
        let m2 = model(t2)
        await m2.refresh()
        T.expect(m2.snapshot.status != nil, "status survives a health failure")
        T.expect(m2.snapshot.health == nil, "health is absent")
        T.equal(m2.reachability, .live, "status alone is enough to be live")
    }

    do {
        T.currentSuite = "gateway fully down"
        let t = MockTransport().fail("/api")
        let m = model(t)
        await m.refresh()

        T.equal(m.reachability, .down, "both endpoints failing means down")
        T.expect(m.isDown, "isDown agrees")
        T.expect(m.lastError != nil, "an error is surfaced")
        T.expect(m.scene.tier == nil, "the scene ladder yields to the down state")
        T.equal(m.scene.frames.first, "wifi.slash", "and shows the down glyph")
        T.expect(m.trackedBudget == nil, "no budget to track")
    }

    do {
        T.currentSuite = "the down state explains itself"
        // The user's actual problem when the gateway dies is that Claude Code
        // stopped working. The panel has to say that, and it has to name where it
        // looked so a misconfigured port is diagnosable.
        let t = MockTransport().fail("/api")
        let m = model(t)
        await m.refresh()

        T.expect(m.isDown, "down")
        T.expect(m.gatewayAddress.contains("127.0.0.1"), "address names loopback")
        T.expect(m.gatewayAddress.contains(":"), "and includes the port")
        // Recovery is offered rather than only diagnosed.
        T.expect(m.scene.jokes.contains { $0.lowercased().contains("claude code") },
                 "the down scene mentions the consequence for Claude Code")
    }

    do {
        T.currentSuite = "paused enforcement"
        let t = MockTransport.healthy().stub("/api/status", json: statusFixturePaused)
        let m = model(t)
        await m.refresh()

        T.equal(m.reachability, .paused, "paused is its own state")
        T.equal(m.scene.frames.first, "pause.circle.fill", "paused glyph")
        T.expect(m.scene.caption.contains("paused"), "caption says so")
    }

    // MARK: - Controls, asserted by what they send

    do {
        T.currentSuite = "pause sends the documented payload"
        let t = MockTransport.healthy()
        let m = model(t)
        await m.pauseEnforcement(minutes: 90)

        guard let req = t.request(to: "/api/budgets") else {
            return T.expect(false, "budgets endpoint called")
        }
        T.equal(req.method, "PUT", "PUT, not POST")
        T.equal(req.jsonBody?["enforcement"] as? String, "off", "enforcement off")
        T.equal(req.jsonBody?["pause_minutes"] as? Int, 90, "minutes forwarded")
    }

    do {
        T.currentSuite = "resume clears the pause"
        let t = MockTransport.healthy()
        let m = model(t)
        await m.resumeEnforcement()

        let req = t.request(to: "/api/budgets")
        T.equal(req?.jsonBody?["enforcement"] as? String, "on", "enforcement on")
        T.expect(req?.jsonBody?["pause_minutes"] == nil, "no minutes when resuming")
    }

    do {
        T.currentSuite = "bumper sends the documented payload"
        let t = MockTransport.healthy()
        let m = model(t)
        await m.bump(budgetId: "session", amountUsd: 25, minutes: 60)

        guard let bump = t.request(to: "/api/budgets")?.jsonBody?["bump"] as? [String: Any] else {
            return T.expect(false, "bump object sent")
        }
        T.equal(bump["budget_id"] as? String, "session", "target budget")
        T.close(bump["amount_usd"] as? Double ?? -1, 25, "amount")
        T.equal(bump["minutes"] as? Int, 60, "duration")
        T.expect(bump["clear"] == nil, "not a clear")
    }

    do {
        T.currentSuite = "bumper omits minutes for the budget's own window"
        // The gateway defaults to the budget window when `minutes` is absent, so
        // sending nothing is meaningfully different from sending a number.
        let t = MockTransport.healthy()
        let m = model(t)
        await m.bump(budgetId: "session", amountUsd: 10, minutes: nil)

        let bump = t.request(to: "/api/budgets")?.jsonBody?["bump"] as? [String: Any]
        T.expect(bump?["minutes"] == nil, "minutes omitted entirely, not zero")
        T.close(bump?["amount_usd"] as? Double ?? -1, 10, "amount still sent")
    }

    do {
        T.currentSuite = "clearing a bumper"
        let t = MockTransport.healthy()
        let m = model(t)
        await m.clearBump(budgetId: "weekly")

        let bump = t.request(to: "/api/budgets")?.jsonBody?["bump"] as? [String: Any]
        T.equal(bump?["budget_id"] as? String, "weekly", "target")
        T.equal(bump?["clear"] as? Bool, true, "clear flag")
        T.expect(bump?["amount_usd"] == nil, "no amount when clearing")
    }

    do {
        T.currentSuite = "restart uses the API when reachable"
        let t = MockTransport.healthy()
        let m = model(t)
        await m.refresh()
        t.reset()
        await m.restart()

        T.equal(t.callCount("/api/restart"), 1, "graceful restart endpoint used")
        T.equal(t.request(to: "/api/restart")?.method, "POST", "POST")
        // A control action refreshes afterwards so the panel reflects the result.
        T.expect(t.callCount("/api/status") >= 1, "state re-read after the action")
    }

    do {
        T.currentSuite = "errors surface without wedging the model"
        let t = MockTransport.healthy().fail("/api/budgets", with: .http(400, "bump: 'monthly' is the overall ceiling"))
        let m = model(t)
        await m.bump(budgetId: "monthly", amountUsd: 10, minutes: nil)

        T.expect(m.lastError != nil, "the failure is reported")
        T.expect(m.lastError?.contains("ceiling") == true, "and carries the gateway's reason")
        T.expect(!m.isBusy, "busy flag is cleared even on failure")
        // The subsequent refresh still ran, so the panel isn't left stale.
        T.expect(t.callCount("/api/status") >= 1, "still refreshed after the error")
    }

    do {
        T.currentSuite = "a later success clears the error"
        let t = MockTransport.healthy().fail("/api/budgets", with: .http(400, "nope"))
        let m = model(t)
        await m.resumeEnforcement()
        T.expect(m.lastError != nil, "error set")

        t.stub("/api/budgets", json: #"{"budgets":[]}"#)
        await m.resumeEnforcement()
        T.expect(m.lastError == nil, "cleared once the call succeeds")
    }

    do {
        T.currentSuite = "token is forwarded when present"
        let t = MockTransport.healthy()
        let m = model(t)
        await m.refresh()

        // The token file exists on this machine; if it does, every request must
        // carry it, so flipping api_token on later can't break the buttons.
        let tokenPath = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".ccgw/token")
        if FileManager.default.fileExists(atPath: tokenPath.path) {
            T.expect(t.requests.allSatisfy { $0.token != nil },
                     "every request carries X-CCGW-Token when the file exists")
        } else {
            T.expect(t.requests.allSatisfy { $0.token == nil },
                     "no token sent when the file is absent")
        }
    }

    do {
        T.currentSuite = "requests never leave loopback"
        let t = MockTransport.healthy()
        let m = model(t)
        await m.refresh()
        await m.pauseEnforcement(minutes: 5)

        T.expect(!t.urls.isEmpty, "requests were made")
        for url in t.urls {
            T.expect(url.hasPrefix("http://127.0.0.1:"),
                     "\(url) targets loopback by literal IP, never localhost")
        }
    }
}
