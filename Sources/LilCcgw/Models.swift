import Foundation

// Mirrors of the ccgw HTTP contract. The gateway lives in another repo on a
// moving branch, so treat every field here as an external contract — see
// .claude/skills/ccgw-api-contract/SKILL.md before changing a name.
//
// Numerics the gateway can legitimately report as null (a budget with no
// traffic yet has no pace or ETA) are optional. Decoding uses
// .convertFromSnakeCase, so Swift property names stay camelCase.

// MARK: - GET /api/status

struct GatewayStatus: Decodable {
    let enforcement: String
    let enforcementResumeAt: Double?
    let degraded: Bool
    let softThresholdPct: Double
    let primary: PrimaryBudget?
    let budgets: [Budget]

    var isPaused: Bool { enforcement == "off" }

    /// Absolute time enforcement comes back on, if paused.
    var resumeDate: Date? {
        enforcementResumeAt.map { Date(timeIntervalSince1970: $0 / 1000) }
    }
}

struct PrimaryBudget: Decodable {
    let id: String
    let window: String
    let pace: Double?
    let burnRateHr: Double?
    let sustainableHr: Double?
    let etaHours: Double?
    let fitsWindow: Bool?
}

struct Budget: Decodable, Identifiable {
    let id: String
    let scope: String
    let window: String
    let effectiveLimitUsd: Double
    let spentUsd: Double
    let remainingUsd: Double
    let pct: Double
    let action: String
    let exhausted: Bool
    let soft: Bool
    let burnRateHr: Double?
    let sustainableHr: Double?
    let pace: Double?
    let bumpUsd: Double?
    let bumpExpiresAt: Double?

    /// 0…1 for progress rendering; pct arrives as 0…100 and can exceed it.
    var fraction: Double { max(0, min(1, pct / 100)) }

    /// The budget's rolling window as a duration, parsed from the gateway's
    /// shorthand ("5h", "7d", "30d"). Used to scope the model breakdown to the
    /// same window as the budget it sits under, so the two cannot disagree.
    var windowSeconds: TimeInterval? { Budget.parseWindow(window) }

    static func parseWindow(_ text: String) -> TimeInterval? {
        guard let unit = text.last, let value = Double(text.dropLast()) else { return nil }
        switch unit {
        case "s": return value
        case "m": return value * 60
        case "h": return value * 3600
        case "d": return value * 86_400
        case "w": return value * 604_800
        default: return nil
        }
    }
}

// MARK: - GET /api/health

struct GatewayHealth: Decodable {
    let ok: Bool
    let version: String
    let uptimeS: Double
    let upstream: String
    let ledgerRows: Int?
    let sessionsTracked: Int?
    let telemetryDegraded: Bool?
}

// MARK: - GET /api/spend?group_by=model

struct SpendReport: Decodable {
    let groupBy: String
    let rows: [SpendRow]
}

struct SpendRow: Decodable, Identifiable {
    let key: String
    let requests: Int
    let costUsd: Double

    var id: String { key }

    /// "claude-haiku-4-5-20251001" reads as "haiku-4-5" in a menu this narrow.
    var shortName: String {
        var name = key
        if name.hasPrefix("claude-") { name.removeFirst("claude-".count) }
        // Strip a trailing yyyymmdd date stamp.
        let parts = name.split(separator: "-")
        if let last = parts.last, last.count == 8, last.allSatisfy(\.isNumber) {
            name = parts.dropLast().joined(separator: "-")
        }
        return name
    }
}

// MARK: - Composite snapshot

/// One coherent read of the gateway. `nil` fields mean that endpoint failed
/// while others succeeded — the panel degrades per-section rather than going
/// blank.
struct GatewaySnapshot {
    var status: GatewayStatus?
    var health: GatewayHealth?
    var spend: SpendReport?

    /// The budget the menu bar title tracks. Honours an explicit user choice,
    /// otherwise follows whichever budget the gateway nominates as primary —
    /// the gateway owns that decision, not this app.
    func titleBudget(preferredId: String?) -> Budget? {
        guard let status else { return nil }
        if let preferredId, let match = status.budgets.first(where: { $0.id == preferredId }) {
            return match
        }
        if let primaryId = status.primary?.id,
           let match = status.budgets.first(where: { $0.id == primaryId }) {
            return match
        }
        return status.budgets.first
    }
}
