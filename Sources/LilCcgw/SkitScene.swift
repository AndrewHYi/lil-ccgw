import Foundation

/// The burn-rate escalation ladder, ported from the ccgw dashboard's `#skit`
/// element (`src/dashboard.html`).
///
/// The dashboard renders this as animated NES-style sprites: an intern at a desk
/// with a thriving plant, catching fire by degrees, eventually sprinting out of
/// frame. None of that survives a 22pt menu bar, so the tiers, thresholds, and
/// precedence port exactly while the presentation becomes SF Symbols.
///
/// Driver is `pace` — `burn_rate_hr / sustainable_hr` from `/api/status.primary`.
/// Thresholds are the dashboard's, boundaries included.
enum SkitTier: String, CaseIterable, Identifiable, Equatable {
    case ok, warm, hot, crit, melt, rip, payday, zen

    var id: String { rawValue }

    /// Matches the dashboard's `SKIT_ORDER`, which its 1-8 debug override keys
    /// index into.
    static var ordered: [SkitTier] { allCases }
}

/// Everything needed to draw one tier: the animation frames, how fast they
/// alternate, and what the panel says about it.
struct SkitScene: Equatable {
    /// nil when an app-level state (unreachable, paused) pre-empts the ladder.
    let tier: SkitTier?
    let frames: [String]
    let interval: Double
    let caption: String
    let jokes: [String]

    /// A single-frame scene needs no timer at all, which is what keeps the
    /// common case (`ok`) motionless.
    var isAnimated: Bool { frames.count > 1 && interval > 0 }

    func frame(_ index: Int) -> String {
        guard !frames.isEmpty else { return "circle.dotted" }
        guard isAnimated else { return frames[0] }
        return frames[abs(index) % frames.count]
    }
}

extension SkitScene {
    // MARK: - Thresholds (dashboard.html:1123-1126)

    static let okCeiling = 0.85
    static let warmCeiling = 1.2
    static let hotCeiling = 1.6
    static let critCeiling = 2.0

    /// How long an unbroken meltdown runs before it becomes acceptance.
    static let zenAfter: TimeInterval = 10 * 60

    // MARK: - Resolution

    /// Pure tier resolution.
    ///
    /// Returns the scene plus the meltdown clock the caller should persist —
    /// keeping the clock out here rather than inside makes the whole thing
    /// testable without a stored-state fixture. The dashboard keeps the
    /// equivalent in `localStorage` under `ccgw-melt-since`.
    static func resolve(
        snapshot: GatewaySnapshot,
        reachability: Reachability,
        now: Date,
        meltSince: Date?,
        forced: SkitTier? = nil
    ) -> (scene: SkitScene, meltSince: Date?) {
        // App-level states outrank the ladder: a scene about burn rate is
        // meaningless when there is no burn rate to read. The dashboard has no
        // equivalent because a dead gateway means a dead page.
        if forced == nil {
            switch reachability {
            case .down:
                return (scene(for: nil, frames: ["wifi.slash"], interval: 0,
                              caption: "gateway not responding",
                              jokes: ["Claude Code is getting connection refused until this is back.",
                                      "Nothing is being recorded while it's down.",
                                      "Start it from the panel — the API can't restart a dead process."]),
                        meltSince)
            case .paused:
                let resume = snapshot.status?.resumeDate
                let detail = resume.map { "enforcement paused · resumes \(Fmt.clockTime($0))" }
                    ?? "enforcement paused"
                return (scene(for: nil, frames: ["pause.circle.fill"], interval: 0,
                              caption: detail,
                              jokes: ["Spend is still being recorded, just not blocked.",
                                      "It auto-resumes, so this can't be forgotten.",
                                      "Budgets are advisory until the clock runs out."]),
                        meltSince)
            case .unknown:
                return (scene(for: nil, frames: ["circle.dotted"], interval: 0,
                              caption: "connecting…", jokes: []),
                        meltSince)
            case .live:
                break
            }
        }

        let status = snapshot.status
        let pace = status?.primary?.pace ?? 0
        let burn = status?.primary?.burnRateHr ?? 0
        let idle = burn <= 0

        // dashboard.html:1119 — only a *global block* budget being exhausted is
        // a funeral. A `warn` budget over its limit still admits requests, and a
        // project-scoped one doesn't stop the machine.
        let dead = status?.budgets.first {
            $0.exhausted && $0.action == "block" && $0.scope == "global"
        }
        let isPayday = Calendar.current.component(.day, from: now) == 1

        var tier: SkitTier
        if let forced {
            tier = forced
        } else if dead != nil {
            tier = .rip
        } else if idle || pace <= okCeiling {
            tier = isPayday ? .payday : .ok
        } else if pace <= warmCeiling {
            tier = .warm
        } else if pace <= hotCeiling {
            tier = .hot
        } else if pace <= critCeiling {
            tier = .crit
        } else {
            tier = .melt
        }

        // dashboard.html:1130-1138 — ten unbroken minutes of meltdown stops
        // being an emergency and becomes a state of mind. The clock survives
        // relaunches and resets the moment pace drops out of `melt`.
        var nextMeltSince = meltSince
        if forced == nil {
            if tier == .melt {
                let since = meltSince ?? now
                nextMeltSince = since
                if now.timeIntervalSince(since) > zenAfter { tier = .zen }
            } else if tier != .zen {
                nextMeltSince = nil
            }
        }

        return (scene(for: tier, dead: dead), nextMeltSince)
    }

    // MARK: - Scenes

    /// Frame pairs are chosen to be *shape*-distinct, not colour-distinct.
    ///
    /// Colour is committed to budget consumption in this app, so the pace ladder
    /// can only escalate by silhouette — and `flame` vs `flame.fill` is far too
    /// subtle to be the sole difference between two adjacent tiers at menu bar
    /// size. Leading with a rising thermometer keeps the ladder monotone and
    /// gives every tier its own outline: leaf → thermometer → flame →
    /// flame/alarm → runner → rain → popper → meditation.
    ///
    /// Intervals mirror the dashboard's own sprite frame durations.
    static func scene(for tier: SkitTier?, dead: Budget? = nil) -> SkitScene {
        guard let tier else {
            return SkitScene(tier: nil, frames: ["circle.dotted"], interval: 0,
                             caption: "", jokes: [])
        }
        switch tier {
        case .ok:
            // Deliberately static. The dashboard animates its idle desk, but a
            // permanently twitching menu bar earns nothing, and below 0.85 pace
            // this means no timer runs at all.
            return SkitScene(
                tier: .ok, frames: ["leaf.fill"], interval: 0,
                caption: "sustainable pace",
                jokes: [
                    "Burn is under the sustainable line. Nothing to do.",
                    "The plant is thriving. Nobody is sure why.",
                    "This is what the budget was designed to feel like.",
                    "Cheapest possible outcome: somebody thought before typing.",
                ])
        case .warm:
            return SkitScene(
                tier: .warm, frames: ["thermometer.medium", "thermometer.high"],
                interval: 0.32,
                caption: "running warm",
                jokes: [
                    "Past sustainable, not yet interesting.",
                    "The window absorbs this. For now.",
                    "One agent got ambitious. It happens.",
                    "Warm is a rate, not a verdict.",
                ])
        case .hot:
            return SkitScene(
                tier: .hot, frames: ["flame", "flame.fill"], interval: 0.30,
                caption: "over sustainable",
                jokes: [
                    "Comfortably past the line and pointed the wrong way.",
                    "The five-hour window is doing real work now.",
                    "Worth knowing what's actually running.",
                    "A couple of hours of this empties the window.",
                ])
        case .crit:
            return SkitScene(
                tier: .crit, frames: ["flame.fill", "exclamationmark.triangle.fill"],
                interval: 0.26,
                caption: "burning down the window",
                jokes: [
                    "Twice the sustainable rate is not a plateau.",
                    "The bumper exists for this, and it isn't free.",
                    "Something is looping. It usually is.",
                    "The monthly ceiling is watching and does not negotiate.",
                ])
        case .melt:
            return SkitScene(
                tier: .melt, frames: ["figure.run", "figure.walk"], interval: 0.18,
                caption: "runaway",
                jokes: [
                    "Whatever is running has stopped asking permission.",
                    "This is the failure the five-hour window exists to catch.",
                    "Kill it or pay for it. Those are the options.",
                    "Past 2× the arithmetic stops being funny.",
                ])
        case .rip:
            let detail = dead.map {
                "\($0.id) is spent · \(Fmt.limit($0.effectiveLimitUsd))/\($0.window)"
            } ?? "budget exhausted"
            return SkitScene(
                tier: .rip, frames: ["cloud.rain.fill", "cloud.heavyrain.fill"],
                interval: 0.9,
                caption: detail,
                jokes: [
                    "Blocked until the window rolls. It will roll.",
                    "Requests are failing closed, which is the entire point.",
                    "The other budgets survive it.",
                    "Nothing to fix here — wait, or raise the limit deliberately.",
                ])
        case .payday:
            return SkitScene(
                tier: .payday, frames: ["party.popper.fill", "sparkles"],
                interval: 0.5,
                caption: "budgets reset",
                jokes: [
                    "First of the month. The counters went home.",
                    "Maximum headroom. Spend it on something good.",
                    "Even the plant looks optimistic.",
                    "Everything is affordable on the first.",
                ])
        case .zen:
            return SkitScene(
                tier: .zen, frames: ["figure.mind.and.body", "flame.fill"],
                interval: 0.55,
                caption: "past caring",
                jokes: [
                    "Ten minutes of runaway. Panic has stopped paying for itself.",
                    "The fire and the budget have reached an understanding.",
                    "Still burning. No longer sprinting.",
                    "At this point it's just weather.",
                ])
        }
    }

    private static func scene(
        for tier: SkitTier?, frames: [String], interval: Double,
        caption: String, jokes: [String]
    ) -> SkitScene {
        SkitScene(tier: tier, frames: frames, interval: interval,
                  caption: caption, jokes: jokes)
    }
}

/// Whether the gateway can be read at all, and whether it is enforcing.
///
/// Split out from budget consumption because the two are independent axes: the
/// glyph reports pace, the colour reports how much of the budget is gone.
enum Reachability: Equatable {
    case unknown
    case down
    case paused
    case live
}

/// How much of the tracked budget is gone — the colour axis.
enum BudgetHeat: Equatable {
    case normal
    case soft
    case exhausted

    /// Pure derivation, kept out of `GatewayModel` so tests can reach it without
    /// a live gateway or the main actor.
    ///
    /// The gateway owns the threshold via `soft_threshold_pct`, so this reads it
    /// rather than hardcoding 80 — and honours the `soft` flag too, since the
    /// gateway can set it for reasons of its own.
    static func resolve(status: GatewayStatus?, budget: Budget?) -> BudgetHeat {
        guard let status, let budget else { return .normal }
        if budget.exhausted { return .exhausted }
        if budget.soft || budget.pct >= status.softThresholdPct { return .soft }
        return .normal
    }
}

/// Pure helpers for values that used to live inside `GatewayModel` and were
/// therefore unreachable from tests. The model delegates to these.
enum Derive {
    /// How quickly to retry while the gateway is unreachable.
    ///
    /// Deliberately short and independent of the panel: while the gateway is
    /// down, Claude Code is failing every request, so the single most useful
    /// thing this app can do is notice the moment it comes back. A refused
    /// connection fails in milliseconds, so retrying often costs nothing.
    static let downRetrySeconds: Double = 5

    /// Poll cadence. An open panel refreshes briskly; a closed one stays cheap;
    /// a down gateway is retried fast regardless. Zero or missing values fall
    /// back rather than producing a hot loop.
    static func pollInterval(
        open: Bool, openValue: Double, closedValue: Double, down: Bool = false
    ) -> Double {
        if down { return downRetrySeconds }
        let value = open ? openValue : closedValue
        return value > 0 ? value : (open ? 5 : 30)
    }

    /// Dashboard URL. Always loopback by literal IP: the gateway validates the
    /// Host header against loopback names, and `localhost` can resolve to an
    /// IPv6 literal it rejects.
    static func dashboardURL(host: String, port: Int) -> URL? {
        let h = host.trimmingCharacters(in: .whitespaces)
        let safeHost = h.isEmpty ? "127.0.0.1" : h
        let safePort = port > 0 ? port : 8484
        return URL(string: "http://\(safeHost):\(safePort)/dash")
    }

    /// Budgets a bumper can be applied to — everything except the overall
    /// ceiling, which the gateway rejects with a 400.
    static func bumpableBudgets(_ all: [Budget]) -> [Budget] {
        all.filter { !$0.isCeiling(among: all) }
    }

    /// The cap a bumper produces: the budget's own limit with the bumper on top.
    ///
    /// The panel shows this beside both amount fields because it is the number
    /// the user is reasoning about, while the field they type into is a delta.
    /// Typing 2210 and being surprised by a $2285 cap is exactly the gap this
    /// closes. A negative bump is treated as none rather than subtracting: the
    /// gateway has no such thing, so rendering one would be a lie.
    static func resultingCap(base: Double, bump: Double) -> Double {
        base + max(0, bump)
    }

    /// Why a proposed cap is dangerous, or nil when it is not.
    ///
    /// A cap at or below what the window has already spent leaves no headroom,
    /// so the gateway starts blocking the instant it is applied. That is a
    /// legitimate thing to want — it is the fastest "stop me now" this app has —
    /// so this warns and lets it through rather than forbidding it.
    static func bumpWarning(cap: Double, spent: Double) -> String? {
        guard cap <= spent else { return nil }
        return "below the \(Fmt.usd(spent)) already spent — requests block immediately"
    }

    /// Whole minutes left on a bumper, for re-issuing it without moving its
    /// expiry.
    ///
    /// Reducing a bumper means clearing it and bumping again, and a plain
    /// re-bump restarts the clock — so changing the *amount* would silently
    /// extend the *duration*. Returns nil when no bumper is live, which makes
    /// the caller omit `minutes` and get the budget's own window, the gateway's
    /// documented default.
    ///
    /// Truncates rather than rounds, so re-issuing can only ever shorten a
    /// bumper by under a minute, never extend it. The bounds mirror the
    /// gateway's own 5…10080 clamp: a value outside them would come back
    /// silently changed, which is worse than clamping here where it is visible.
    static func remainingBumpMinutes(expiresAt: Date?, now: Date = Date()) -> Int? {
        guard let expiresAt else { return nil }
        let seconds = expiresAt.timeIntervalSince(now)
        guard seconds > 0 else { return nil }
        return min(10_080, max(5, Int(seconds / 60)))
    }

    /// The launchd service target for the gateway agent. A typo here means Stop
    /// and Start silently do nothing, so it is asserted rather than trusted.
    static func serviceTarget(uid: UInt32, label: String) -> String {
        "gui/\(uid)/\(label)"
    }

    static func domainTarget(uid: UInt32) -> String {
        "gui/\(uid)"
    }
}
