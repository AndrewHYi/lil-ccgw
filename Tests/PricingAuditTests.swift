import AppKit
import Foundation
import SwiftUI

/// The gateway prices every request from a rate table that is maintained out of
/// band, and matches a model to it by longest prefix. A model that ships before
/// the table is updated is not an error: `claude-opus-5-5` quietly inherits the
/// `claude-opus-5` rates, and a model with no relative at all is priced at the
/// most expensive rate the table knows. Either way every figure downstream is
/// wrong and nothing says so. That is how the ledger came to run 87% above the
/// billing page for weeks.
///
/// These tests pin the one signal that catches it: a model the gateway has
/// priced, whose own id is not in the table and is not merely a dated build of
/// something that is.

private let nowMs = 1_790_000_000_000.0   // 2026-09-21 14:13:20Z
private let now = Date(timeIntervalSince1970: nowMs / 1000)
private let sixtyDaysMs = 60 * 86_400 * 1000.0

private func rate(_ input: Double) -> String {
    #"{"input":\#(input),"output":\#(input * 5),"cache_write_5m":\#(input * 1.25),"cache_write_1h":\#(input * 2),"cache_read":\#(input * 0.1)}"#
}

/// Captured from a live gateway running the 2026-08-04 table, trimmed to the
/// entries that matter. It is the table that priced Opus 5.5 as Opus 5.
func stalePricingJSON(lastTs: Double = nowMs) -> String {
    """
    {
      "version": "2026-08-04", "unit": "per_million_tokens", "notes": "longest-prefix",
      "rates": {
        "claude-opus-5": \(rate(5)),
        "claude-sonnet-5": \(rate(3)),
        "claude-haiku-4-5": \(rate(1)),
        "claude-3-haiku": \(rate(0.25))
      },
      "seen": [
        {"model":"claude-sonnet-5-5","requests":300,"cost_usd":120.0,"last_ts":\(lastTs)},
        {"model":"claude-opus-5-5","requests":900,"cost_usd":500.0,"last_ts":\(lastTs)},
        {"model":"claude-haiku-5-5","requests":20,"cost_usd":2.0,"last_ts":\(lastTs)},
        {"model":"claude-opus-5","requests":1100,"cost_usd":480.0,"last_ts":\(lastTs)},
        {"model":"claude-haiku-4-5-20251001","requests":170,"cost_usd":1.5,"last_ts":\(lastTs)},
        {"model":"claude-opus-4-7","requests":360,"cost_usd":60.0,"last_ts":\(lastTs - sixtyDaysMs)}
      ]
    }
    """
}

private func report(rates: [String], seen: [(String, Double)]) throws -> PricingReport {
    let rateJSON = rates.map { "\"\($0)\": \(rate(5))" }.joined(separator: ",")
    let seenJSON = seen.map {
        #"{"model":"\#($0.0)","requests":10,"cost_usd":\#($0.1),"last_ts":\#(nowMs)}"#
    }.joined(separator: ",")
    return try decodeFixture(PricingReport.self, """
    {"version":"t","rates":{\(rateJSON)},"seen":[\(seenJSON)]}
    """)
}

func runPricingAuditTests() {
    T.suite("the pricing report decodes the rate keys and the models seen") {
        let decoded = try decodeFixture(PricingReport.self, stalePricingJSON())
        T.equal(decoded.version, "2026-08-04", "table version decoded")
        T.equal(Set(decoded.rates.keys),
                ["claude-opus-5", "claude-sonnet-5", "claude-haiku-4-5", "claude-3-haiku"],
                "every rate key decoded without modelling the rates")
        T.equal(decoded.seen?.count, 6, "seen models decoded")
        T.equal(decoded.seen?.first?.model, "claude-sonnet-5-5", "model id kept verbatim")
        T.close(decoded.seen?.first?.lastTs ?? 0, nowMs, "last_ts is epoch milliseconds")

        // An older gateway has no `seen`; the audit must treat that as nothing to
        // check rather than failing the whole endpoint.
        let bare = try decodeFixture(PricingReport.self, #"{"rates":{"claude-opus-5":{}}}"#)
        T.expect(bare.seen == nil, "seen is optional")
        T.equal(PricingAudit.findings(bare, now: now), [], "no seen list means nothing to flag")
    }

    T.suite("a model priced as a different version, or not at all, is flagged") {
        let stale = try decodeFixture(PricingReport.self, stalePricingJSON())
        let findings = PricingAudit.findings(stale, now: now)
        T.equal(findings.map(\.model),
                ["claude-opus-5-5", "claude-sonnet-5-5", "claude-haiku-5-5"],
                "the three 5.5 models, costliest first")
        T.equal(findings.map(\.pricedAs),
                ["claude-opus-5", "claude-sonnet-5", nil],
                "a family prefix is named; a model with no relative is priced at the maximum")
        T.equal(findings.first?.requests, 900, "request count carried for the note")
        T.close(findings.first?.costUsd ?? 0, 500.0, "cost carried for ordering")
    }

    T.suite("exact matches and dated builds are never flagged") {
        let fine = try report(
            rates: ["claude-opus-5", "claude-opus-5-5", "claude-haiku-4-5"],
            seen: [
                ("claude-opus-5", 10),                    // exact
                ("claude-opus-5-5", 10),                  // exact, and a prefix of the next
                ("claude-opus-5-5-20261015", 10),         // dated build of an exact key
                ("claude-haiku-4-5-20251001", 10),        // dated build, the common case
                ("claude-haiku-4-5-latest", 10),          // alias spelling
            ])
        T.equal(PricingAudit.findings(fine, now: now), [], "nothing to flag")
    }

    T.suite("the longest matching key decides, as it does in the gateway") {
        // Both keys prefix the model. The gateway uses the longer one, so the
        // shorter family entry must not be reported as the fallback.
        let both = try report(rates: ["claude-opus-5", "claude-opus-5-5"],
                              seen: [("claude-opus-5-5-20261015", 5)])
        T.equal(PricingAudit.findings(both, now: now), [], "dated 5.5 build resolves to the 5.5 key")

        // Drop the specific key and the same model is a guess.
        let family = try report(rates: ["claude-opus-5"], seen: [("claude-opus-5-5-20261015", 5)])
        T.equal(PricingAudit.findings(family, now: now).map(\.pricedAs), ["claude-opus-5"],
                "without the 5.5 key the dated build is priced as Opus 5")
    }

    T.suite("what counts as a date stamp") {
        let rates = ["claude-opus-5"]
        func flagged(_ model: String) throws -> Bool {
            !PricingAudit.findings(try report(rates: rates, seen: [(model, 1)]), now: now).isEmpty
        }
        T.expect(!(try flagged("claude-opus-5-20261015")), "eight digits is a date stamp")
        T.expect(!(try flagged("claude-opus-5-latest")), "latest is an alias, not a version")
        T.expect(try flagged("claude-opus-5-5"), "a version number is not a date")
        T.expect(try flagged("claude-opus-5-6"), "a future point release is a guess")
        T.expect(try flagged("claude-opus-5-2026"), "four digits is a version, not a date")
        T.expect(try flagged("claude-opus-5-202610151"), "nine digits is not a date either")
        T.expect(try flagged("claude-opus-5x"), "any other suffix is a different model")
    }

    T.suite("only models seen recently are flagged") {
        let stale = try decodeFixture(PricingReport.self, stalePricingJSON())
        let later = now.addingTimeInterval(40 * 86_400)
        T.equal(PricingAudit.findings(stale, now: later), [],
                "a model unused for 40 days no longer nags")
        T.equal(PricingAudit.findings(stale, now: now.addingTimeInterval(34 * 86_400)).count, 3,
                "still flagged at 34 days: the window is five weeks, not a few days")
        T.equal(PricingAudit.findings(stale, now: now.addingTimeInterval(36 * 86_400)).count, 0,
                "and gone by 36")
        T.equal(PricingAudit.findings(stale, now: later, activeWithin: 60 * 86_400).count, 3,
                "the window is a parameter, not a constant buried in the loop")
        // claude-opus-4-7 has no rate at all in this table, but was last seen
        // sixty days ago, so it never appears.
        T.expect(!PricingAudit.findings(stale, now: now).map(\.model).contains("claude-opus-4-7"),
                 "a long-idle unknown model is ignored")
    }

    T.suite("the panel note says what is wrong and what it costs") {
        T.equal(PanelDerive.pricingNote([]), nil, "nothing flagged means no note")

        let guessed = PricingFinding(model: "claude-opus-5-5", pricedAs: "claude-opus-5", requests: 9, costUsd: 1)
        let maximum = PricingFinding(model: "claude-haiku-5-5", pricedAs: nil, requests: 3, costUsd: 1)
        let one = PanelDerive.pricingNote([guessed]) ?? ""
        T.expect(one.contains("claude-opus-5-5") && one.contains("claude-opus-5"),
                 "names the model and the rate it was priced with")
        T.expect(one.contains("estimates"), "says what is affected")

        let none = PanelDerive.pricingNote([maximum]) ?? ""
        T.expect(none.contains("claude-haiku-5-5") && none.contains("highest"),
                 "a model with no rate says it was priced at the highest known")

        let many = PanelDerive.pricingNote([guessed, maximum,
            PricingFinding(model: "claude-sonnet-5-5", pricedAs: "claude-sonnet-5", requests: 1, costUsd: 1)]) ?? ""
        T.expect(many.contains("3 models") && many.contains("claude-opus-5-5"),
                 "several models collapse to a count and the costliest name")
        T.expect(!many.contains("claude-haiku-5-5"), "the note stays one short line, not a list")
    }
}

@MainActor
func runPricingModelTests() async {
    T.currentSuite = "the model flags stale pricing from /api/pricing"
    do {
        let transport = MockTransport.healthy().stub("/api/pricing", json: stalePricingJSON(lastTs: Date().timeIntervalSince1970 * 1000))
        let model = GatewayModel(client: GatewayClient(transport: transport))
        await model.refresh()
        T.equal(model.pricingFindings.map(\.model),
                ["claude-opus-5-5", "claude-sonnet-5-5", "claude-haiku-5-5"],
                "findings reach the model after a refresh")
        T.equal(transport.callCount("/api/pricing"), 1, "one request for the table")

        await model.refresh()
        T.equal(transport.callCount("/api/pricing"), 1,
                "a second refresh inside the interval does not ask again: the table changes by release, not by poll")

        model.pricingRefreshInterval = 0
        await model.refresh()
        T.equal(transport.callCount("/api/pricing"), 2, "the interval is what throttles it")
    }

    T.currentSuite = "a healthy table raises nothing"
    do {
        let transport = MockTransport.healthy()
        let model = GatewayModel(client: GatewayClient(transport: transport))
        await model.refresh()
        T.equal(model.pricingFindings, [], "the live-captured table has an exact rate for everything seen")
        T.equal(transport.callCount("/api/pricing"), 1, "still checked once")
    }

    T.currentSuite = "a gateway without /api/pricing degrades silently"
    do {
        let transport = MockTransport.healthy().fail("/api/pricing", with: .http(404, "not found"))
        let model = GatewayModel(client: GatewayClient(transport: transport))
        await model.refresh()
        T.equal(model.pricingFindings, [], "no table means nothing to flag")
        T.equal(model.lastError, nil, "a missing optional endpoint is not an error state")
        T.expect(model.snapshot.status != nil, "the rest of the refresh still landed")
    }

    T.currentSuite = "a down gateway is not asked about pricing"
    do {
        let transport = MockTransport().fail("/api/status").fail("/api/health").fail("/api/spend").fail("/api/pricing")
        let model = GatewayModel(client: GatewayClient(transport: transport))
        await model.refresh()
        T.equal(transport.callCount("/api/pricing"), 0, "nothing to audit while the gateway is unreachable")
    }

    T.currentSuite = "a failed check keeps the last good findings"
    do {
        let transport = MockTransport.healthy().stub("/api/pricing", json: stalePricingJSON(lastTs: Date().timeIntervalSince1970 * 1000))
        let model = GatewayModel(client: GatewayClient(transport: transport))
        model.pricingRefreshInterval = 0
        await model.refresh()
        T.equal(model.pricingFindings.count, 3, "findings present")
        transport.fail("/api/pricing", with: .unreachable)
        await model.refresh()
        T.equal(model.pricingFindings.count, 3, "one failed poll does not make a known problem disappear")
    }

    T.currentSuite = "the panel shows the pricing note"
    do {
        let healthy = GatewayModel(client: GatewayClient(transport: MockTransport.healthy()))
        await healthy.refresh()
        let stale = GatewayModel(client: GatewayClient(transport:
            MockTransport.healthy().stub("/api/pricing", json: stalePricingJSON(lastTs: Date().timeIntervalSince1970 * 1000))))
        await stale.refresh()

        func height(_ model: GatewayModel) -> CGFloat {
            let host = NSHostingController(rootView: PanelView(model: model))
            return host.sizeThatFits(in: CGSize(width: 320, height: 2_000)).height
        }
        T.expect(height(stale) > height(healthy) + 8,
                 "a flagged table adds a visible line to the panel, and a clean one does not")
    }
}
