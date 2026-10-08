import Foundation
import SwiftUI

private let billingFixture = """
{
  "enforcement":"on", "degraded":true, "enforcement_resume_at":null,
  "soft_threshold_pct":80, "primary":null,
  "effort":{"effective_cap":null},
  "budgets":[{
    "id":"billing", "scope":"global", "window":"month", "action":"warn",
    "effective_limit_usd":200, "spent_usd":125.45, "remaining_usd":74.55,
    "pct":62.7, "exhausted":false, "soft":false,
    "window_started_at":1790812800000, "window_ends_at":1793491200000,
    "billing_snapshot":{"at":1791385580000,"spent_usd":123.45}
  }]
}
"""

func runBillingTests() {
    T.suite("billing snapshot and UTC calendar boundaries") {
        let status = try decodeFixture(GatewayStatus.self, billingFixture)
        let budget = status.budgets[0]
        T.equal(budget.windowLabel, "month UTC", "month is explicitly UTC")
        T.close(budget.spendFrom().timeIntervalSince1970 * 1000, 1791385580001,
                "model breakdown excludes costs already in the baseline")
        T.close(budget.billingSnapshot?.spentUsd ?? -1, 123.45, "observed total decoded")
        T.close(budget.windowEndsAt ?? -1, 1793491200000, "exact reset decoded")
        T.expect((budget.windowSeconds ?? 0) > 28 * 86_400, "month sorts above short budgets")
        T.expect((Budget.parseWindow("1mo") ?? 0) > 28 * 86_400, "legacy calendar spelling supported")
        let ceiling = try decodeFixture(GatewayStatus.self, billingFixture.replacingOccurrences(of: "\"action\":\"warn\"", with: "\"action\":\"block\"")).budgets[0]
        let session = makeBudget(pct: 0, window: "5h")
        T.expect(ceiling.isCeiling(among: [session, ceiling]), "UTC month is the overall ceiling")
        T.expect(!session.isCeiling(among: [session, ceiling]), "session can be bumped under UTC monthly ceiling")

        let raw = billingFixture.replacingOccurrences(of: 
            ",\n    \"billing_snapshot\":{\"at\":1791385580000,\"spent_usd\":123.45}", with: "")
        let uncalibrated = try decodeFixture(GatewayStatus.self, raw).budgets[0]
        T.close(uncalibrated.spendFrom().timeIntervalSince1970 * 1000, 1790812800000,
                "without a baseline use the server's window boundary")
        let fallback = makeBudget(pct: 0, window: "month")
        T.close(fallback.spendFrom(now: Date(timeIntervalSince1970: 1791385580)).timeIntervalSince1970,
                1790812800, "UTC month starts correctly without gateway boundaries")
    }

    T.suite("warnings cannot claim a block or effort throttle") {
        let warning = billingFixture
            .replacingOccurrences(of: "\"exhausted\":false", with: "\"exhausted\":true")
            .replacingOccurrences(of: "\"pct\":62.7", with: "\"pct\":130")
        let status = try decodeFixture(GatewayStatus.self, warning)
        let budget = status.budgets[0]
        T.equal(PanelDerive.budgetColor(budget, softThreshold: 80), .orange, "warning is amber")
        T.equal(BudgetHeat.resolve(status: status, budget: budget), .soft, "menu heat is warning")
        T.equal(PanelDerive.budgetNote(budget, enforcementOn: true), "warning only", "warning says so")
        T.equal(PanelDerive.enforcementNote(status, health: nil), "warning", "legacy degraded flag is not a cap")

        let blocked = try decodeFixture(GatewayStatus.self, warning.replacingOccurrences(of: "\"action\":\"warn\"", with: "\"action\":\"block\""))
        T.equal(PanelDerive.budgetColor(blocked.budgets[0], softThreshold: 80), .red, "real block is red")
        T.equal(PanelDerive.budgetColor(blocked.budgets[0], softThreshold: 80, enforcementOn: false), .orange,
                "paused enforcement cannot claim a red block")
        let capped = try decodeFixture(GatewayStatus.self, warning.replacingOccurrences(of: "\"effective_cap\":null", with: "\"effective_cap\":\"low\""))
        T.equal(PanelDerive.enforcementNote(capped, health: nil), "effort capped: low", "real cap is explicit")
    }
}

@MainActor
func runBillingModelTests() async {
    T.currentSuite = "billing breakdown request uses baseline timestamp"
    let transport = MockTransport.healthy().stub("/api/status", json: billingFixture)
    let model = GatewayModel(client: GatewayClient(transport: transport))
    await model.refresh()
    T.expect(transport.url(for: "/api/spend")?.contains("from=1791385580001") == true,
             "the outgoing request only fetches estimates after billing sync")
    T.equal(model.spendWindowLabel, "", "do not label post-sync estimates as a full month")

    T.currentSuite = "billing sync patches the baseline without replacing budgets"
    let observedAt = Date(timeIntervalSince1970: 1791385580)
    await model.syncBilling(spentUsd: 123.45, at: observedAt)
    let body = transport.request(to: "/api/budgets")?.jsonBody
    let snapshot = body?["billing_snapshot"] as? [String: Any]
    T.close(snapshot?["spent_usd"] as? Double ?? -1, 123.45, "send observed spend")
    T.close(snapshot?["at"] as? Double ?? -1, 1791385580000, "send observation in epoch milliseconds")
    T.expect(body?["budgets"] == nil, "sync cannot overwrite a concurrent bumper or limit edit")
    T.expect(BillingSyncForm.validAmount("0"), "zero is a valid billing observation")
    for invalid in ["", "NaN", "inf", "-1"] {
        T.expect(!BillingSyncForm.validAmount(invalid), "reject invalid spend: \(invalid)")
    }
    transport.fail("/api/budgets", with: .http(400, "invalid observation"))
    await model.syncBilling(spentUsd: 100, at: observedAt)
    T.expect(model.lastError?.contains("invalid observation") == true, "sync failure survives refresh")
}
