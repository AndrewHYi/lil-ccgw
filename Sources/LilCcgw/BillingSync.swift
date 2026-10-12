import Foundation

/// What a pasted usage-page figure says.
struct ParsedBilling: Equatable {
    var spentUsd: Double
    /// The limit printed beside the spend ("of $1,000.00"), when there was one.
    var limitUsd: Double?
}

/// What the sync form can say about a figure before it is saved.
struct BillingPreview: Equatable {
    /// Set when the pasted limit is not the one the gateway enforces.
    var limitNote: String?
    /// Set when the gateway's own running estimate can be compared with the figure.
    var estimateNote: String?
}

/// The billing baseline is typed in by a person, from a page that prints
/// "$412.80 of $1,000.00 spent". These keep that gesture cheap and make the two
/// ways it goes wrong visible: a limit that has moved, and an estimate that has
/// drifted from the bill.
extension Derive {
    /// A baseline this old has had a day of unreconciled estimates added to it.
    static let baselineStaleAfter: TimeInterval = 86_400

    /// An estimate is as of now, so an observation only compares with it if it was
    /// made about now. Fifteen minutes is the slack for a person finding the page.
    static let billingComparableWithin: TimeInterval = 900

    /// Past this, a gap is no longer rounding or a few cents of lag. It is
    /// usually the rate table, which is the one cause worth naming.
    static let billingGapNamesPricingAbove = 15.0

    private static let amountPattern = #"\$?\s*([0-9][0-9,]*(?:\.[0-9]+)?)"#
    // Constant patterns: a typo here is a crash on the first test run, not a
    // runtime surprise.
    private static let pairExpression = try! NSRegularExpression(
        pattern: amountPattern + #"\s*(?:of|/)\s*"# + amountPattern)
    private static let bareExpression = try! NSRegularExpression(
        pattern: #"^\s*"# + amountPattern + #"\s*$"#)

    /// Reads "$412.80 of $1,000.00 spent" (or a bare amount) out of pasted text.
    ///
    /// The pair is searched for anywhere in the text, so pasting the whole usage
    /// block works: nothing else in it has an "of" or a slash between two amounts.
    /// A lone amount must be the whole input, so "75% used" and "1e5" are refused
    /// rather than guessed at.
    static func parsedBilling(_ text: String) -> ParsedBilling? {
        let whole = NSRange(text.startIndex..., in: text)
        func value(_ match: NSTextCheckingResult, _ group: Int) -> Double? {
            guard let range = Range(match.range(at: group), in: text),
                  let number = Double(text[range].replacingOccurrences(of: ",", with: "")),
                  number.isFinite else { return nil }
            return number
        }
        if let match = pairExpression.firstMatch(in: text, range: whole),
           let spent = value(match, 1), let limit = value(match, 2), limit > 0 {
            return ParsedBilling(spentUsd: spent, limitUsd: limit)
        }
        if let match = bareExpression.firstMatch(in: text, range: whole), let spent = value(match, 1) {
            return ParsedBilling(spentUsd: spent, limitUsd: nil)
        }
        return nil
    }

    /// The budget an observation is checked against: the global UTC-month budget
    /// that blocks, since that is the one that stops requests, else any global one.
    static func billingBudget(_ budgets: [Budget]) -> Budget? {
        let months = budgets.filter { $0.window == "month" && $0.scope == "global" }
        return months.first { $0.isCeiling(among: budgets) } ?? months.first
    }

    /// The two checks worth making the moment a figure is pasted, before it is
    /// saved. Pure so the thresholds can be asserted: each fails silently otherwise.
    static func billingPreview(
        _ parsed: ParsedBilling, observedAt: Date, now: Date, monthLimit: Double?, estimate: Double?
    ) -> BillingPreview {
        var preview = BillingPreview()

        if let pasted = parsed.limitUsd, let held = monthLimit, abs(pasted - held) >= 1 {
            preview.limitNote = "Your usage page shows a \(Fmt.limit(pasted)) limit, "
                + "but ccgw enforces \(Fmt.limit(held)). Change it in Settings."
        }

        if let estimate, parsed.spentUsd > 0,
           abs(now.timeIntervalSince(observedAt)) <= billingComparableWithin {
            let gap = (estimate - parsed.spentUsd) / parsed.spentUsd * 100
            if abs(gap) < 1 {
                preview.estimateNote = "ccgw's estimate, \(Fmt.usd(estimate)), matches this within 1%."
            } else {
                var note = "ccgw's estimate is \(Fmt.usd(estimate)), "
                    + "\(Int(abs(gap).rounded()))% \(gap > 0 ? "above" : "below") this."
                if abs(gap) > billingGapNamesPricingAbove {
                    note += " A gap this size usually means a stale pricing table."
                }
                preview.estimateNote = note
            }
        }
        return preview
    }

    /// How long ago, in the coarse units a glance needs. A negative age, from a
    /// clock that ran backwards, reads as "just now" rather than as a minus sign.
    static func ageLabel(_ seconds: TimeInterval) -> String {
        switch seconds {
        case ..<60: return "just now"
        case ..<3_600: return "\(Int(seconds / 60))m ago"
        case ..<86_400: return "\(Int(seconds / 3_600))h ago"
        default: return "\(Int(seconds / 86_400))d ago"
        }
    }
}

extension PanelDerive {
    /// The baseline line under a month budget. The age is the point: a baseline
    /// silently loses accuracy as estimates pile on top of it, so a stale one
    /// turns amber and says what to do, instead of looking as trustworthy as one
    /// taken a minute ago.
    static func baselineNote(_ baseline: BillingSnapshot, now: Date = Date()) -> (text: String, stale: Bool) {
        let age = now.timeIntervalSince(Date(timeIntervalSince1970: baseline.at / 1000))
        let when = Derive.ageLabel(age)
        if age >= Derive.baselineStaleAfter {
            return ("Billing baseline \(Fmt.usd(baseline.spentUsd)), \(when). Check your usage page and sync.", true)
        }
        return ("Billing baseline \(Fmt.usd(baseline.spentUsd)), \(when), plus new local estimates", false)
    }
}
