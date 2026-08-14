import Foundation
import SwiftUI

/// Tests for the panel's decisions, now that they are reachable.
///
/// These were `private` members of a `View`, so nothing could assert them even
/// from inside the module. Rendering the panel does execute them, but only for
/// whatever state a fixture happens to hold — it cannot pin a threshold, and the
/// pace thresholds are copied from the dashboard with nothing to notice if the
/// two drift apart.
func runPanelDeriveTests() {
    func budget(
        pct: Double, exhausted: Bool = false, soft: Bool = false, cost: Double = 10
    ) -> Budget {
        let json = """
        {"id":"session","scope":"global","window":"5h",
         "effective_limit_usd":75,"spent_usd":\(cost),"remaining_usd":1,
         "pct":\(pct),"action":"block","exhausted":\(exhausted),"soft":\(soft),
         "burn_rate_hr":null,"sustainable_hr":null,"pace":null,
         "bump_usd":null,"bump_expires_at":null}
        """
        return try! decodeFixture(Budget.self, json)
    }

    T.suite("exhausted beats everything") {
        // Red is the strongest signal the bar has, and an exhausted budget must
        // get it even when it is somehow below the soft threshold.
        T.equal(PanelDerive.budgetColor(budget(pct: 100, exhausted: true), softThreshold: 80),
                .red, "an exhausted budget is red")
        T.equal(PanelDerive.budgetColor(budget(pct: 5, exhausted: true, soft: false),
                                        softThreshold: 80),
                .red, "exhausted outranks a low percentage")
    }

    T.suite("the gateway's soft flag and the threshold both amber the bar") {
        T.equal(PanelDerive.budgetColor(budget(pct: 10, soft: true), softThreshold: 80),
                .orange, "the gateway's own soft flag is honoured even at 10%")
        T.equal(PanelDerive.budgetColor(budget(pct: 80), softThreshold: 80),
                .orange, "exactly at the threshold counts as soft")
        T.equal(PanelDerive.budgetColor(budget(pct: 79.9), softThreshold: 80),
                .accentColor, "just under it does not")
    }

    T.suite("the soft threshold comes from the gateway, not from 80") {
        // ccgw owns soft_threshold_pct and the contract says not to hardcode it.
        // A budget at 50% is normal under the default and amber under a stricter
        // gateway; both must follow the value passed in.
        T.equal(PanelDerive.budgetColor(budget(pct: 50), softThreshold: 80),
                .accentColor, "50% is normal when the threshold is 80")
        T.equal(PanelDerive.budgetColor(budget(pct: 50), softThreshold: 40),
                .orange, "the same budget ambers when the gateway says 40")
    }

    T.suite("pace colour matches the dashboard's bands") {
        T.equal(PanelDerive.paceColor(nil), .secondary,
                "no pace is grey — a budget with no traffic has no rate")
        T.equal(PanelDerive.paceColor(0.0), .green, "zero burn is green")
        T.equal(PanelDerive.paceColor(0.99), .green, "just under sustainable is green")
        T.equal(PanelDerive.paceColor(1.0), .orange, "exactly sustainable is amber")
        T.equal(PanelDerive.paceColor(1.49), .orange, "well over is still amber")
        T.equal(PanelDerive.paceColor(1.5), .red, "1.5× is the red band")
        T.equal(PanelDerive.paceColor(12), .red, "and anything past it")
    }

    T.suite("the model breakdown is the three costliest, in order") {
        let report = try! decodeFixture(SpendReport.self, spendFixture)
        guard let rows = PanelDerive.topModels(report) else {
            T.fail("a populated report should produce rows")
            return
        }
        T.equal(rows.count, 3, "at most three rows — it is a menu, not a report")
        T.expect(rows[0].costUsd >= rows[1].costUsd && rows[1].costUsd >= rows[2].costUsd,
                 "sorted by cost, descending")
        T.equal(rows[0].key, "claude-opus-5", "the costliest model leads")
    }

    T.suite("nil and empty breakdowns are different things") {
        // Nil means not fetched; empty means no traffic in the window. Both hide
        // the section, but conflating them once produced a header over nothing.
        T.expect(PanelDerive.topModels(nil) == nil, "no report at all stays nil")
        let empty = try! decodeFixture(SpendReport.self, spendFixtureEmpty)
        T.equal(PanelDerive.topModels(empty)?.isEmpty, true,
                "a fetched-but-empty report is an empty list, not nil")
    }

    T.suite("a short breakdown is not padded") {
        let json = """
        {"from":1,"to":2,"group_by":"model","rows":[
          {"key":"claude-opus-5","requests":1,"input_tokens":1,"output_tokens":1,
           "cache_read_tokens":0,"cache_write_tokens":0,"cost_usd":1.5}]}
        """
        let one = try! decodeFixture(SpendReport.self, json)
        T.equal(PanelDerive.topModels(one)?.count, 1, "one model in gives one row out")
    }
}
