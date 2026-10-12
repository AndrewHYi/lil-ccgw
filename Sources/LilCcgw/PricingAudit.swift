import Foundation

/// A model the gateway priced without a rate of its own.
struct PricingFinding: Equatable {
    let model: String
    /// The table entry it fell back to, or nil when nothing matched and the
    /// gateway priced it at the most expensive rate it knows.
    let pricedAs: String?
    let requests: Int
    let costUsd: Double
}

/// Notices when the gateway is guessing at a price.
///
/// The rate table is maintained out of band and a model is matched to it by
/// longest prefix, so a model that ships before the table is updated is not an
/// error. `claude-opus-5-5` inherits the `claude-opus-5` rates, and a model with
/// no relative at all is priced at the highest rate the table holds. Every figure
/// downstream is then wrong and nothing says so: the ledger ran 87% above the
/// billing page before anyone found out. A model's own id missing from the table
/// is the one signal that catches it on the day the model first appears.
enum PricingAudit {
    /// How recently a model must have been seen to be worth flagging. One nobody
    /// has called for five weeks cannot be inflating this month's figure.
    static let activeWindow: TimeInterval = 35 * 86_400

    /// Costliest first, since that is the one worth fixing first.
    static func findings(
        _ report: PricingReport,
        now: Date = Date(),
        activeWithin: TimeInterval = activeWindow
    ) -> [PricingFinding] {
        let keys = Array(report.rates.keys)
        return (report.seen ?? [])
            .filter { now.timeIntervalSince(Date(timeIntervalSince1970: $0.lastTs / 1000)) <= activeWithin }
            .compactMap { seen -> PricingFinding? in
                if report.rates[seen.model] != nil { return nil }
                // Longest prefix wins, as it does in the gateway's own matcher.
                let match = keys.filter { seen.model.hasPrefix($0) }.max { $0.count < $1.count }
                if let match, isBenignSuffix(seen.model.dropFirst(match.count)) { return nil }
                return PricingFinding(
                    model: seen.model, pricedAs: match, requests: seen.requests, costUsd: seen.costUsd
                )
            }
            .sorted { $0.costUsd > $1.costUsd }
    }

    /// A dated build ("-20251001") or an alias ("-latest") of a model the table
    /// has, as opposed to a different version that merely shares its prefix.
    static func isBenignSuffix(_ suffix: Substring) -> Bool {
        if suffix == "-latest" { return true }
        guard suffix.hasPrefix("-") else { return false }
        let digits = suffix.dropFirst()
        return digits.count == 8 && digits.allSatisfy { $0.isASCII && $0.isNumber }
    }
}
