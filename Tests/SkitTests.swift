import Foundation

/// Tests for the burn-rate escalation ladder ported from the dashboard's `#skit`.
///
/// These matter more than they look. The thresholds are copied constants from
/// another repo, the precedence rules interact (`payday` only replaces `ok`,
/// `zen` only replaces `melt`), and the whole thing is invisible in normal use —
/// most tiers only appear during an incident or on one day of the month. Boundary
/// values are asserted from both sides because an off-by-epsilon here shows a
/// thriving plant during a runaway.
func runSkitTests() {
    T.suite("pace boundaries") {
        // dashboard.html:1123-1126 — the comparisons are <=, so each boundary
        // value belongs to the *lower* tier.
        T.equal(tier(pace: 0.0), .ok, "zero pace")
        T.equal(tier(pace: 0.85), .ok, "0.85 is still ok")
        T.equal(tier(pace: 0.851), .warm, "just past 0.85 is warm")
        T.equal(tier(pace: 1.2), .warm, "1.2 is still warm")
        T.equal(tier(pace: 1.201), .hot, "just past 1.2 is hot")
        T.equal(tier(pace: 1.6), .hot, "1.6 is still hot")
        T.equal(tier(pace: 1.601), .crit, "just past 1.6 is crit")
        T.equal(tier(pace: 2.0), .crit, "2.0 is still crit")
        T.equal(tier(pace: 2.001), .melt, "just past 2.0 is melt")
        T.equal(tier(pace: 12.0), .melt, "far past 2.0 stays melt")
    }

    T.suite("idle overrides pace") {
        // The dashboard passes `burnHr <= 0` as its idle flag, which wins over
        // whatever stale ratio the last window produced. Without this a gateway
        // that just went quiet would keep showing flames.
        T.equal(tier(pace: 5.0, burn: 0), .ok, "no burn is ok even at pace 5")
        T.equal(tier(pace: 5.0, burn: -1), .ok, "negative burn is ok")
        T.equal(tier(pace: 5.0, burn: 0.01), .melt, "any positive burn respects pace")
    }

    T.suite("rip needs a global block budget") {
        // dashboard.html:1119 — all three conditions, or it isn't a funeral.
        T.equal(
            tier(pace: 0.1, budgets: [budget(id: "session", exhausted: true, action: "block", scope: "global")]),
            .rip, "exhausted global block budget")

        // A warn budget over its limit still admits requests.
        T.equal(
            tier(pace: 0.1, budgets: [budget(id: "weekly", exhausted: true, action: "warn", scope: "global")]),
            .ok, "exhausted warn budget is not rip")

        // A project-scoped budget doesn't stop the machine.
        T.equal(
            tier(pace: 0.1, budgets: [budget(id: "kith", exhausted: true, action: "block", scope: "project")]),
            .ok, "exhausted project budget is not rip")

        // Not exhausted is not dead, however close it is.
        T.equal(
            tier(pace: 0.1, budgets: [budget(id: "session", exhausted: false, action: "block", scope: "global", pct: 99.9)]),
            .ok, "99.9% is not exhausted")

        // rip outranks the pace ladder entirely.
        T.equal(
            tier(pace: 9.0, budgets: [budget(id: "session", exhausted: true, action: "block", scope: "global")]),
            .rip, "rip beats melt")
    }

    T.suite("payday only replaces ok") {
        let firstOfMonth = date("2026-09-01T12:00:00Z")
        let midMonth = date("2026-09-12T12:00:00Z")

        T.equal(tier(pace: 0.1, now: firstOfMonth), .payday, "calm on the 1st is payday")
        T.equal(tier(pace: 0.1, now: midMonth), .ok, "calm mid-month is ok")

        // A runaway on payday is still a runaway.
        T.equal(tier(pace: 1.4, now: firstOfMonth), .hot, "hot on the 1st stays hot")
        T.equal(tier(pace: 3.0, now: firstOfMonth), .melt, "melt on the 1st stays melt")

        // And a dead budget outranks the party.
        T.equal(
            tier(pace: 0.1, now: firstOfMonth,
                 budgets: [budget(id: "session", exhausted: true, action: "block", scope: "global")]),
            .rip, "rip beats payday")
    }

    T.suite("zen after a sustained meltdown") {
        let start = date("2026-09-12T12:00:00Z")

        // First tick of a meltdown starts the clock and stays melt.
        let first = resolve(pace: 3.0, now: start, meltSince: nil)
        T.equal(first.scene.tier, .melt, "meltdown begins as melt")
        T.expect(first.meltSince != nil, "clock starts")

        // Still melt at 9 minutes.
        let nine = resolve(pace: 3.0, now: start.addingTimeInterval(9 * 60), meltSince: start)
        T.equal(nine.scene.tier, .melt, "9 minutes is still melt")

        // Past 10 minutes it becomes acceptance.
        let eleven = resolve(pace: 3.0, now: start.addingTimeInterval(11 * 60), meltSince: start)
        T.equal(eleven.scene.tier, .zen, "past 10 minutes is zen")
        T.expect(eleven.meltSince != nil, "clock survives into zen")

        // Pace dropping clears the clock, so the next meltdown starts fresh
        // rather than arriving instantly at zen.
        let cooled = resolve(pace: 0.5, now: start.addingTimeInterval(12 * 60), meltSince: start)
        T.equal(cooled.scene.tier, .ok, "cooling off leaves zen")
        T.expect(cooled.meltSince == nil, "clock resets when pace drops")

        let again = resolve(pace: 3.0, now: start.addingTimeInterval(13 * 60), meltSince: nil)
        T.equal(again.scene.tier, .melt, "a fresh meltdown starts at melt, not zen")
    }

    T.suite("app states outrank the ladder") {
        // A scene about burn rate is meaningless when the gateway can't be read.
        for reach in [Reachability.down, .paused, .unknown] {
            let r = SkitScene.resolve(
                snapshot: snapshot(pace: 9.0, burn: 50),
                reachability: reach, now: Date(), meltSince: nil)
            T.expect(r.scene.tier == nil, "\(reach) has no tier even at pace 9")
        }

        let down = SkitScene.resolve(
            snapshot: snapshot(pace: 9.0, burn: 50),
            reachability: .down, now: Date(), meltSince: nil)
        T.equal(down.scene.frames.first, "wifi.slash", "down glyph")
        T.expect(!down.scene.isAnimated, "down does not animate")

        let paused = SkitScene.resolve(
            snapshot: snapshot(pace: 9.0, burn: 50),
            reachability: .paused, now: Date(), meltSince: nil)
        T.equal(paused.scene.frames.first, "pause.circle.fill", "paused glyph")
    }

    T.suite("forced tier bypasses everything") {
        // The debug override has to reach every tier regardless of live state,
        // or there is no way to check the eight scenes without an incident.
        for want in SkitTier.allCases {
            let r = SkitScene.resolve(
                snapshot: snapshot(pace: 0.1, burn: 1),
                reachability: .live, now: Date(), meltSince: nil, forced: want)
            T.equal(r.scene.tier, want, "forced \(want.rawValue)")
        }

        // Forcing must not corrupt the persisted meltdown clock.
        let r = SkitScene.resolve(
            snapshot: snapshot(pace: 0.1, burn: 1),
            reachability: .live, now: Date(), meltSince: nil, forced: .melt)
        T.expect(r.meltSince == nil, "forcing melt does not start the clock")

        // A forced tier also wins over an unreachable gateway, so the override
        // works while the gateway is down.
        let forcedWhileDown = SkitScene.resolve(
            snapshot: GatewaySnapshot(), reachability: .down,
            now: Date(), meltSince: nil, forced: .hot)
        T.equal(forcedWhileDown.scene.tier, .hot, "forced tier beats down state")
    }

    T.suite("every tier is shape-distinct") {
        // Colour is committed to budget consumption, so the pace ladder can only
        // escalate by silhouette. Two tiers sharing a first frame would be
        // indistinguishable in the menu bar.
        var firstFrames: [String: SkitTier] = [:]
        for t in SkitTier.allCases {
            let frame = SkitScene.scene(for: t).frames[0]
            if let clash = firstFrames[frame] {
                T.expect(false, "\(t.rawValue) shares its first frame with \(clash.rawValue): \(frame)")
            }
            firstFrames[frame] = t
        }
        T.equal(firstFrames.count, SkitTier.allCases.count, "8 tiers, 8 distinct first frames")

        // App states must not collide with the ladder either — `crit` uses the
        // warning triangle the down state used to own.
        let appGlyphs = ["wifi.slash", "pause.circle.fill", "circle.dotted"]
        for glyph in appGlyphs {
            T.expect(firstFrames[glyph] == nil, "\(glyph) is not also a tier's first frame")
        }
    }

    T.suite("animation shape") {
        // ok stays static so the common case runs no timer at all.
        let ok = SkitScene.scene(for: .ok)
        T.equal(ok.frames.count, 1, "ok has one frame")
        T.expect(!ok.isAnimated, "ok does not animate")
        T.equal(ok.frame(0), ok.frame(7), "a static scene ignores the frame counter")

        for t in SkitTier.allCases where t != .ok {
            let s = SkitScene.scene(for: t)
            T.equal(s.frames.count, 2, "\(t.rawValue) has two frames")
            T.expect(s.interval > 0, "\(t.rawValue) has a positive interval")
            T.expect(s.isAnimated, "\(t.rawValue) animates")
            T.equal(s.frame(0), s.frames[0], "\(t.rawValue) frame 0")
            T.equal(s.frame(1), s.frames[1], "\(t.rawValue) frame 1")
            T.equal(s.frame(2), s.frames[0], "\(t.rawValue) wraps")
            // The counter is unbounded and could in principle go negative on
            // overflow; indexing must never trap.
            T.equal(s.frame(-1), s.frames[1], "\(t.rawValue) tolerates negative")
            T.equal(s.frame(Int.max), s.frames[Int.max % 2], "\(t.rawValue) tolerates Int.max")
        }
    }

    T.suite("captions and jokes") {
        for t in SkitTier.allCases {
            let s = SkitScene.scene(for: t)
            T.expect(!s.caption.isEmpty, "\(t.rawValue) has a caption")
            T.expect(s.jokes.count >= 3, "\(t.rawValue) has at least 3 jokes")
        }

        // rip names the budget that died, since "budget exhausted" alone doesn't
        // say which one is blocking.
        let dead = budget(id: "session", exhausted: true, action: "block", scope: "global")
        let rip = SkitScene.scene(for: .rip, dead: dead)
        T.expect(rip.caption.contains("session"), "rip caption names the budget")
        T.expect(rip.caption.contains("$75"), "rip caption carries the limit")

        // And degrades sensibly when the budget isn't available.
        T.equal(SkitScene.scene(for: .rip).caption, "budget exhausted", "rip caption without a budget")
    }

    T.suite("thresholds match the dashboard") {
        // Guards against a well-meaning tidy-up drifting these away from the
        // upstream constants they were copied from.
        T.close(SkitScene.okCeiling, 0.85, "ok ceiling")
        T.close(SkitScene.warmCeiling, 1.2, "warm ceiling")
        T.close(SkitScene.hotCeiling, 1.6, "hot ceiling")
        T.close(SkitScene.critCeiling, 2.0, "crit ceiling")
        T.close(SkitScene.zenAfter, 600, "zen delay is 10 minutes")
        T.equal(SkitTier.ordered.map(\.rawValue),
                ["ok", "warm", "hot", "crit", "melt", "rip", "payday", "zen"],
                "order matches the dashboard's SKIT_ORDER")
    }
}

// MARK: - Helpers

private func date(_ iso: String) -> Date {
    let f = ISO8601DateFormatter()
    return f.date(from: iso)!
}

private func budget(
    id: String, exhausted: Bool = false, action: String = "block",
    scope: String = "global", pct: Double = 10, window: String = "5h"
) -> Budget {
    let json = """
    {
      "id": "\(id)", "scope": "\(scope)", "window": "\(window)",
      "effective_limit_usd": 75, "spent_usd": 10, "remaining_usd": 65,
      "pct": \(pct), "action": "\(action)", "exhausted": \(exhausted),
      "soft": false, "burn_rate_hr": null, "sustainable_hr": null,
      "pace": null, "bump_usd": null, "bump_expires_at": null
    }
    """
    return try! decodeFixture(Budget.self, json)
}

private func snapshot(pace: Double, burn: Double, budgets: [Budget] = []) -> GatewaySnapshot {
    let budgetJSON = budgets.isEmpty
        ? ""
        : budgets.map { b in
            """
            {
              "id": "\(b.id)", "scope": "\(b.scope)", "window": "\(b.window)",
              "effective_limit_usd": \(b.effectiveLimitUsd), "spent_usd": \(b.spentUsd),
              "remaining_usd": \(b.remainingUsd), "pct": \(b.pct),
              "action": "\(b.action)", "exhausted": \(b.exhausted), "soft": \(b.soft),
              "burn_rate_hr": null, "sustainable_hr": null, "pace": null,
              "bump_usd": null, "bump_expires_at": null
            }
            """
        }.joined(separator: ",")

    let json = """
    {
      "enforcement": "on", "enforcement_resume_at": null, "degraded": false,
      "soft_threshold_pct": 80,
      "primary": {
        "id": "session", "window": "5h", "pace": \(pace),
        "burn_rate_hr": \(burn), "sustainable_hr": 15,
        "eta_hours": 4.0, "fits_window": true
      },
      "budgets": [\(budgetJSON)]
    }
    """
    var snap = GatewaySnapshot()
    snap.status = try! decodeFixture(GatewayStatus.self, json)
    return snap
}

private func resolve(
    pace: Double, burn: Double = 10, now: Date = Date(),
    meltSince: Date? = nil, budgets: [Budget] = []
) -> (scene: SkitScene, meltSince: Date?) {
    SkitScene.resolve(
        snapshot: snapshot(pace: pace, burn: burn, budgets: budgets),
        reachability: .live, now: now, meltSince: meltSince)
}

private func tier(
    pace: Double, burn: Double = 10, now: Date = date("2026-09-12T12:00:00Z"),
    budgets: [Budget] = []
) -> SkitTier? {
    resolve(pace: pace, burn: burn, now: now, budgets: budgets).scene.tier
}
