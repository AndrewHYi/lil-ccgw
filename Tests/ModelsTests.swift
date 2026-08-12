import Foundation

/// Decoding and derived-value tests.
///
/// These exist because the gateway is an external contract with no
/// compile-time protection: a renamed or re-typed field shows up as `nil` in the
/// UI, never as a build error. Every assertion here is a field the panel would
/// silently lose.
func runModelsTests() {
    T.suite("status decoding") {
        let status = try decodeFixture(GatewayStatus.self, statusFixture)

        T.equal(status.enforcement, "on", "enforcement")
        T.equal(status.degraded, false, "degraded")
        T.close(status.softThresholdPct, 80, "soft_threshold_pct")
        T.equal(status.isPaused, false, "isPaused when enforcement on")
        T.expect(status.enforcementResumeAt == nil, "resume_at is null when not paused")
        T.expect(status.resumeDate == nil, "resumeDate nil when not paused")
        T.equal(status.budgets.count, 4, "budget count")

        // The gateway nominates which budget matters; the app must read it
        // rather than assuming the 5h window.
        T.equal(status.primary?.id, "session", "primary id")
        T.equal(status.primary?.window, "5h", "primary window")
        T.close(status.primary?.pace ?? -1, 0.91, "primary pace")
        T.close(status.primary?.burnRateHr ?? -1, 13.58, "primary burn rate")
        T.close(status.primary?.sustainableHr ?? -1, 15, "primary sustainable rate")
        T.close(status.primary?.etaHours ?? -1, 4.1, "primary eta hours")
        T.equal(status.primary?.fitsWindow, true, "primary fits window")
    }

    T.suite("budget decoding") {
        let status = try decodeFixture(GatewayStatus.self, statusFixture)
        guard let session = status.budgets.first(where: { $0.id == "session" }) else {
            return T.expect(false, "session budget missing")
        }

        T.equal(session.window, "5h", "session window")
        T.close(session.spentUsd, 19.62, "session spent")
        T.close(session.effectiveLimitUsd, 75, "session effective limit")
        T.close(session.remainingUsd, 55.38, "session remaining")
        T.close(session.pct, 26.2, "session pct")
        T.equal(session.action, "block", "session action")
        T.equal(session.exhausted, false, "session exhausted")
        T.equal(session.soft, false, "session soft")

        // A budget with no traffic in its window reports null rates. These must
        // stay optional — making them non-optional would throw on decode and
        // blank the whole panel.
        guard let weekly = status.budgets.first(where: { $0.id == "weekly" }) else {
            return T.expect(false, "weekly budget missing")
        }
        T.expect(weekly.pace == nil, "weekly pace decodes as nil")
        T.expect(weekly.burnRateHr == nil, "weekly burn rate decodes as nil")
        T.expect(weekly.sustainableHr == nil, "weekly sustainable rate decodes as nil")
        T.equal(weekly.action, "warn", "weekly action is warn")

        // 'degrade' is a third action beyond block/warn; the app must not
        // assume a two-value enum.
        let degrade = status.budgets.first(where: { $0.id == "monthly-degrade" })
        T.equal(degrade?.action, "degrade", "degrade action decodes")
    }

    T.suite("budget fraction clamping") {
        // pct arrives 0-100 and legitimately exceeds 100 once a budget is over
        // its limit; an unclamped value would overflow the progress bar.
        T.close(makeBudget(pct: 26.2).fraction, 0.262, "in-range pct")
        T.close(makeBudget(pct: 0).fraction, 0, "zero pct")
        T.close(makeBudget(pct: 100).fraction, 1, "exactly at limit")
        T.close(makeBudget(pct: 143.7).fraction, 1, "over limit clamps to 1")
        T.close(makeBudget(pct: -5).fraction, 0, "negative clamps to 0")
    }

    T.suite("window parsing") {
        T.close(Budget.parseWindow("5h") ?? -1, 18_000, "5h")
        T.close(Budget.parseWindow("7d") ?? -1, 604_800, "7d")
        T.close(Budget.parseWindow("30d") ?? -1, 2_592_000, "30d")
        T.close(Budget.parseWindow("90m") ?? -1, 5_400, "90m")
        T.close(Budget.parseWindow("2w") ?? -1, 1_209_600, "2w")
        T.expect(Budget.parseWindow("") == nil, "empty string is nil")
        T.expect(Budget.parseWindow("5x") == nil, "unknown unit is nil")
        T.expect(Budget.parseWindow("h") == nil, "missing value is nil")

        let status = try decodeFixture(GatewayStatus.self, statusFixture)
        let session = status.budgets[0]
        T.close(session.windowSeconds ?? -1, 18_000, "session windowSeconds via budget")
    }

    T.suite("title budget selection") {
        let status = try decodeFixture(GatewayStatus.self, statusFixture)
        var snapshot = GatewaySnapshot()
        snapshot.status = status

        // An explicit user choice wins.
        T.equal(snapshot.titleBudget(preferredId: "monthly")?.id, "monthly", "explicit preference honoured")

        // No preference falls back to the gateway's own nomination.
        T.equal(snapshot.titleBudget(preferredId: nil)?.id, "session", "falls back to primary")

        // A stale preference — a budget the user selected that has since been
        // removed from config — must not blank the title.
        T.equal(
            snapshot.titleBudget(preferredId: "deleted-budget")?.id, "session",
            "unknown preference falls back to primary"
        )

        // No primary nominated at all: take the first budget rather than nil.
        var noPrimary = GatewaySnapshot()
        noPrimary.status = try decodeFixture(GatewayStatus.self, statusFixtureNoPrimary)
        T.expect(noPrimary.status?.primary == nil, "primary decodes as nil when absent")
        T.equal(noPrimary.titleBudget(preferredId: nil)?.id, "weekly", "no primary uses first budget")

        // Empty snapshot must not crash or invent a budget.
        T.expect(GatewaySnapshot().titleBudget(preferredId: nil) == nil, "empty snapshot yields nil")
    }

    T.suite("paused enforcement decoding") {
        let status = try decodeFixture(GatewayStatus.self, statusFixturePaused)
        T.equal(status.enforcement, "off", "enforcement off")
        T.equal(status.isPaused, true, "isPaused true")

        // epoch milliseconds, not seconds — treating it as seconds would put the
        // resume time in 1970 and the panel would claim enforcement was already
        // back on.
        guard let resume = status.resumeDate else {
            return T.expect(false, "resumeDate missing when paused")
        }
        T.close(resume.timeIntervalSince1970, 1_786_550_000, "resume converted from ms")
        T.expect(resume.timeIntervalSince1970 > 1_700_000_000, "resume date is not epoch 1970")
    }

    T.suite("health decoding") {
        let health = try decodeFixture(GatewayHealth.self, healthFixture)
        T.equal(health.ok, true, "ok")
        T.equal(health.version, "0.1.52", "version")
        T.close(health.uptimeS, 11_640, "uptime_s")
        T.equal(health.upstream, "https://api.anthropic.com", "upstream")
        T.equal(health.ledgerRows, 233, "ledger_rows")
        T.equal(health.sessionsTracked, 7, "sessions_tracked")
    }

    T.suite("spend decoding and model names") {
        let spend = try decodeFixture(SpendReport.self, spendFixture)
        T.equal(spend.groupBy, "model", "group_by")
        T.equal(spend.rows.count, 3, "row count")
        T.close(spend.rows[0].costUsd, 18.16, "opus cost")
        T.equal(spend.rows[0].requests, 55, "opus requests")

        // Raw model ids are too long for a 320pt menu; shortName trims the
        // vendor prefix and any trailing date stamp.
        T.equal(spend.rows[0].shortName, "opus-5", "opus short name")
        T.equal(spend.rows[1].shortName, "sonnet-5", "sonnet short name")
        T.equal(spend.rows[2].shortName, "haiku-4-5", "date stamp stripped")

        // Names that don't match the expected shape must pass through
        // unmangled rather than losing their last segment.
        T.equal(makeSpendRow(key: "gpt-4").shortName, "gpt-4", "non-claude id untouched")
        T.equal(makeSpendRow(key: "claude-opus-5").shortName, "opus-5", "prefix only")
        T.equal(
            makeSpendRow(key: "claude-future-9-1234567").shortName, "future-9-1234567",
            "7-digit suffix is not a date stamp"
        )
        T.equal(makeSpendRow(key: "").shortName, "", "empty key survives")
    }
}

// MARK: - Fixtures builders

func makeBudget(pct: Double, id: String = "test", window: String = "5h", action: String = "block") -> Budget {
    let json = """
    {
      "id": "\(id)", "scope": "global", "window": "\(window)",
      "effective_limit_usd": 75, "spent_usd": 10, "remaining_usd": 65,
      "pct": \(pct), "action": "\(action)", "exhausted": false, "soft": false,
      "burn_rate_hr": null, "sustainable_hr": null, "pace": null,
      "bump_usd": null, "bump_expires_at": null
    }
    """
    return try! decodeFixture(Budget.self, json)
}

func makeSpendRow(key: String) -> SpendRow {
    let escaped = key.replacingOccurrences(of: "\"", with: "")
    let json = """
    { "key": "\(escaped)", "requests": 1, "cost_usd": 1.0 }
    """
    return try! decodeFixture(SpendRow.self, json)
}
