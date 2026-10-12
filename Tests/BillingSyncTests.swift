import Foundation

/// The billing baseline is typed in by a person, from a page that prints
/// "$412.80 of $1,000.00 spent". Three things used to go wrong around that:
///
/// - pasting the line as printed was rejected, because only a bare number parsed;
/// - the baseline never said how old it was, so a stale one looked as trustworthy
///   as one taken a minute ago;
/// - nothing compared the pasted figure with the gateway's own, so a limit that
///   had changed upstream, or an estimate running 87% high, went unnoticed until
///   it blocked someone.

private let at = Date(timeIntervalSince1970: 1_790_000_000)   // 2026-09-21 14:13:20Z

func runBillingSyncTests() {
    T.suite("a baseline states its age and turns amber after a day") {
        func note(_ ago: TimeInterval) -> (text: String, stale: Bool) {
            PanelDerive.baselineNote(
                BillingSnapshot(at: at.timeIntervalSince1970 * 1000, spentUsd: 412.80),
                now: at.addingTimeInterval(ago))
        }
        let fresh = note(30)
        T.expect(fresh.text.contains("$412.80") && fresh.text.contains("just now"), "a fresh baseline says so")
        T.expect(!fresh.stale, "and is not stale")
        T.expect(note(5 * 60).text.contains("5m ago"), "minutes under an hour")
        T.expect(note(3 * 3600).text.contains("3h ago"), "hours under a day")
        // Each unit's edges, both sides: an off-by-one here prints "60m ago".
        T.expect(note(59).text.contains("just now") && note(60).text.contains("1m ago"), "the minute edge")
        T.expect(note(3_599).text.contains("59m ago") && note(3_600).text.contains("1h ago"), "the hour edge")
        T.expect(note(86_399).text.contains("23h ago") && note(86_400).text.contains("1d ago"), "the day edge")
        T.expect(!note(86_399).stale, "one second short of a day is not stale")
        let old = note(86_400)
        T.expect(old.stale, "a day old is stale")
        T.expect(old.text.contains("1d ago") && old.text.contains("usage page"),
                 "and it says what to do about it")
        T.expect(note(3 * 86_400).text.contains("3d ago"), "days")
        T.expect(note(-120).text.contains("just now") && !note(-120).stale,
                 "a clock running backwards must not print a negative age")
    }

    T.suite("a usage-page line parses into spend and limit") {
        func parsed(_ text: String) -> ParsedBilling? { Derive.parsedBilling(text) }
        T.equal(parsed("412.80"), ParsedBilling(spentUsd: 412.80, limitUsd: nil), "a bare number")
        T.equal(parsed("$412.80"), ParsedBilling(spentUsd: 412.80, limitUsd: nil), "with a dollar sign")
        T.equal(parsed("  $1,000.00 "), ParsedBilling(spentUsd: 1000, limitUsd: nil),
                "thousands separators and padding")
        T.equal(parsed("0"), ParsedBilling(spentUsd: 0, limitUsd: nil), "zero is a real observation")

        let line = ParsedBilling(spentUsd: 412.80, limitUsd: 1000)
        T.equal(parsed("$412.80 of $1,000.00 spent"), line, "the line exactly as the page prints it")
        T.equal(parsed("412.80 / 1000"), line, "a slash reads the same")
        T.equal(parsed("""
                 Your usage limits  Enterprise
                 $412.80 of $1,000.00 spent
                 Spend limit · Resets Sat, Oct 31, 8:00 PM EDT
                 """), line,
                "the whole block pasted: the dates and times around it are not amounts")

        for bad in ["", "NaN", "inf", "-1", "abc", "75% used", "1e5", "$412.80 of $0", "412.80 and 1000"] {
            T.expect(parsed(bad) == nil, "rejects \(bad.debugDescription)")
        }
        T.expect(BillingSyncForm.validAmount("$412.80 of $1,000.00 spent"),
                 "the form accepts what the page prints")
    }

    T.suite("the budget a billing sync is compared with") {
        let session = makeBudget(pct: 0, id: "session", window: "5h")
        let warn = makeBudget(pct: 0, id: "warn-month", window: "month", action: "warn")
        let block = makeBudget(pct: 0, id: "block-month", window: "month", action: "block")
        T.equal(Derive.billingBudget([session, warn, block])?.id, "block-month",
                "the blocking month budget is the one that stops requests")
        T.equal(Derive.billingBudget([session, warn])?.id, "warn-month",
                "failing that, any global month budget")
        T.equal(Derive.billingBudget([session])?.id, nil, "no month budget, nothing to compare")
    }

    T.suite("the form compares what you paste with what the gateway holds") {
        let pasted = ParsedBilling(spentUsd: 412.80, limitUsd: 1000)
        func preview(
            _ parsed: ParsedBilling = pasted, ago: TimeInterval = 0,
            limit: Double? = 1000, estimate: Double? = 415
        ) -> BillingPreview {
            Derive.billingPreview(parsed, observedAt: at.addingTimeInterval(-ago), now: at,
                                  monthLimit: limit, estimate: estimate)
        }

        T.equal(preview().limitNote, nil, "a matching limit says nothing")
        let moved = preview(limit: 1500).limitNote ?? ""
        T.expect(moved.contains("$1000") && moved.contains("$1500") && moved.contains("Settings"),
                 "a different limit names both figures and where to change it")
        T.equal(preview(ParsedBilling(spentUsd: 412.80, limitUsd: nil), limit: 1500).limitNote, nil,
                "no limit pasted, nothing to compare")
        T.equal(preview(limit: nil).limitNote, nil, "no monthly budget on the gateway")
        T.equal(preview(limit: 1000.4).limitNote, nil, "under a dollar is rounding, not a different limit")
        T.equal(preview(limit: 999.5).limitNote, nil, "half a dollar short is still rounding")
        T.expect(preview(limit: 999).limitNote != nil, "a dollar is a different limit: the edge is a dollar, not a hundred")
        T.expect(preview(limit: 1005).limitNote != nil, "and so is a small real change")

        T.expect((preview().estimateNote ?? "").contains("within 1%"), "a close estimate says so")
        let high = preview(estimate: 550).estimateNote ?? ""
        T.expect(high.contains("33%") && high.contains("above") && high.contains("pricing table"),
                 "a big overshoot gives its size and the usual cause")
        let low = preview(estimate: 307).estimateNote ?? ""
        T.expect(low.contains("26%") && low.contains("below"), "an undershoot reads the same way")
        let modest = preview(estimate: 438.6).estimateNote ?? ""
        T.expect(modest.contains("6%") && !modest.contains("pricing"),
                 "a modest gap is reported but not blamed on pricing")
        T.equal(preview(ago: 3600).estimateNote, nil,
                "a back-dated observation cannot be compared with an estimate as of now")
        T.equal(preview(ParsedBilling(spentUsd: 0, limitUsd: nil)).estimateNote, nil, "no percentage of zero")
        T.equal(preview(estimate: nil).estimateNote, nil, "no estimate, nothing to say")
    }
}
