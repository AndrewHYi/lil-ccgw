import Foundation

/// Tests for logic that used to be trapped inside `@MainActor` classes.
///
/// These were extracted to `Derive` and `BudgetHeat.resolve` precisely so they
/// could be asserted: each one is a decision the UI makes silently, where being
/// wrong produces a plausible-looking result rather than a crash. The model
/// delegates to these functions, so a passing test here covers the real path
/// rather than a copy of it.
func runDeriveTests() {
    T.suite("budget heat — the colour axis") {
        let status = try decodeFixture(GatewayStatus.self, statusFixture)

        // Normal: well under the gateway's threshold.
        T.equal(BudgetHeat.resolve(status: status, budget: makeBudget(pct: 26.2)), .normal,
                "26% is normal")

        // The gateway owns the threshold (80 in the fixture); this must read it
        // rather than hardcode a number.
        T.equal(BudgetHeat.resolve(status: status, budget: makeBudget(pct: 79.9)), .normal,
                "just under threshold is normal")
        T.equal(BudgetHeat.resolve(status: status, budget: makeBudget(pct: 80)), .soft,
                "exactly at threshold is soft")
        T.equal(BudgetHeat.resolve(status: status, budget: makeBudget(pct: 95)), .soft,
                "over threshold is soft")

        // Exhausted outranks soft even though both are true at that point.
        let dead = makeBudget(pct: 100, id: "x", window: "5h", action: "block")
        let deadJSON = """
        {
          "id": "x", "scope": "global", "window": "5h",
          "effective_limit_usd": 75, "spent_usd": 75, "remaining_usd": 0,
          "pct": 100, "action": "block", "exhausted": true, "soft": true,
          "burn_rate_hr": null, "sustainable_hr": null, "pace": null,
          "bump_usd": null, "bump_expires_at": null
        }
        """
        T.equal(BudgetHeat.resolve(status: status, budget: try decodeFixture(Budget.self, deadJSON)),
                .exhausted, "exhausted outranks soft")
        _ = dead

        // The gateway can set `soft` for its own reasons; honour it even when the
        // percentage alone wouldn't trigger.
        let flagged = """
        {
          "id": "y", "scope": "global", "window": "5h",
          "effective_limit_usd": 75, "spent_usd": 10, "remaining_usd": 65,
          "pct": 13, "action": "block", "exhausted": false, "soft": true,
          "burn_rate_hr": null, "sustainable_hr": null, "pace": null,
          "bump_usd": null, "bump_expires_at": null
        }
        """
        T.equal(BudgetHeat.resolve(status: status, budget: try decodeFixture(Budget.self, flagged)),
                .soft, "the soft flag alone is enough")

        // Missing data must not invent a warning.
        T.equal(BudgetHeat.resolve(status: nil, budget: makeBudget(pct: 99)), .normal,
                "no status yields normal")
        T.equal(BudgetHeat.resolve(status: status, budget: nil), .normal,
                "no budget yields normal")
    }

    T.suite("poll interval") {
        T.close(Derive.pollInterval(open: true, openValue: 5, closedValue: 30), 5, "open uses open value")
        T.close(Derive.pollInterval(open: false, openValue: 5, closedValue: 30), 30, "closed uses closed value")
        T.close(Derive.pollInterval(open: true, openValue: 1, closedValue: 30), 1, "custom open honoured")

        // A zero from unset defaults must never become a zero-delay poll loop,
        // which would hammer the gateway continuously.
        T.close(Derive.pollInterval(open: true, openValue: 0, closedValue: 0), 5, "zero open falls back to 5")
        T.close(Derive.pollInterval(open: false, openValue: 0, closedValue: 0), 30, "zero closed falls back to 30")
        T.close(Derive.pollInterval(open: true, openValue: -3, closedValue: 30), 5, "negative falls back")
    }

    T.suite("dashboard URL") {
        T.equal(Derive.dashboardURL(host: "127.0.0.1", port: 8484)?.absoluteString,
                "http://127.0.0.1:8484/dash", "default")
        T.equal(Derive.dashboardURL(host: "127.0.0.1", port: 9000)?.absoluteString,
                "http://127.0.0.1:9000/dash", "custom port")

        // Unset defaults read as 0 / empty; both must fall back rather than
        // producing http://:0/dash.
        T.equal(Derive.dashboardURL(host: "127.0.0.1", port: 0)?.absoluteString,
                "http://127.0.0.1:8484/dash", "zero port falls back")
        T.equal(Derive.dashboardURL(host: "", port: 8484)?.absoluteString,
                "http://127.0.0.1:8484/dash", "empty host falls back")
        T.equal(Derive.dashboardURL(host: "  ", port: 8484)?.absoluteString,
                "http://127.0.0.1:8484/dash", "whitespace host falls back")
    }

    T.suite("bumpable budgets") {
        let status = try decodeFixture(GatewayStatus.self, statusFixture)
        let bumpable = Derive.bumpableBudgets(status.budgets).map(\.id)

        // monthly (30d block) is the ceiling and must be excluded, or the UI
        // offers a button the gateway answers with 400.
        T.expect(!bumpable.contains("monthly"), "the ceiling is excluded")
        T.expect(bumpable.contains("session"), "session is bumpable")
        T.expect(bumpable.contains("weekly"), "a warn budget is bumpable")
        T.expect(bumpable.contains("monthly-degrade"), "a degrade budget is bumpable")
        T.equal(bumpable.count, 3, "3 of 4 budgets are bumpable")

        T.equal(Derive.bumpableBudgets([]).count, 0, "empty list stays empty")
    }

    T.suite("launchd targets") {
        // A typo here means Stop and Start silently do nothing — launchctl exits
        // non-zero on an unknown target, and the error surfaces far from the
        // cause. Worth pinning the exact string shape.
        T.equal(Derive.serviceTarget(uid: 501, label: "io.ccgw.gateway"),
                "gui/501/io.ccgw.gateway", "service target")
        T.equal(Derive.domainTarget(uid: 501), "gui/501", "domain target")
        T.equal(Derive.serviceTarget(uid: 0, label: "io.ccgw.gateway"),
                "gui/0/io.ccgw.gateway", "root uid")
        T.expect(Derive.serviceTarget(uid: 501, label: "io.ccgw.gateway")
                    .hasPrefix(Derive.domainTarget(uid: 501)),
                 "service target extends the domain target")
        T.equal(ServiceControl.label, "io.ccgw.gateway", "agent label matches the installed plist")
    }

    T.suite("gateway error messages") {
        // These reach the panel, so they must read as sentences rather than
        // enum cases.
        T.equal(GatewayError.unreachable.errorDescription, "Gateway not responding", "unreachable")
        T.equal(GatewayError.http(403, "budget exceeded").errorDescription,
                "HTTP 403: budget exceeded", "http with body")
        T.equal(GatewayError.http(500, nil).errorDescription, "HTTP 500", "http without body")
        T.equal(GatewayError.http(500, "").errorDescription, "HTTP 500", "http with empty body")
    }

    T.suite("accessibility label") {
        // In icon-only mode the glyph is the entire signal, and a template image
        // says nothing to a screen reader — so the label has to carry both the
        // spend and the scene.
        let (snapshot, budget) = MenuBarLabel.sampleSnapshot()
        let label = MenuBarLabel(
            snapshot: snapshot, scene: SkitScene.scene(for: .hot), heat: .normal,
            frame: 0, mode: .iconOnly, trackedBudget: budget
        )
        let text = label.accessibilityText
        T.expect(text.contains("session"), "names the budget")
        T.expect(text.contains("$9.34"), "carries the spend")
        T.expect(text.contains("$75"), "carries the limit")
        T.expect(text.contains("over sustainable"), "carries the scene caption")

        // With no budget it must still say something useful rather than an
        // empty string.
        let empty = MenuBarLabel(
            snapshot: GatewaySnapshot(), scene: SkitScene.scene(for: nil), heat: .normal,
            frame: 0, mode: .iconOnly, trackedBudget: nil
        )
        T.expect(!empty.accessibilityText.isEmpty, "no-data label is not empty")
        T.expect(empty.accessibilityText.contains("ccgw"), "no-data label still identifies the app")
    }

    T.suite("registered defaults are complete") {
        // A key read with @AppStorage but never registered silently reads as
        // zero/false/empty, which is how a 0-second poll interval or a blank
        // title mode would ship.
        let defaults = UserDefaults.standard
        for key in [DefaultsKey.titleMode, DefaultsKey.gatewayHost] {
            T.expect(defaults.string(forKey: key)?.isEmpty == false, "\(key) has a non-empty default")
        }
        T.expect(defaults.integer(forKey: DefaultsKey.gatewayPort) > 0, "port default is positive")
        T.expect(defaults.double(forKey: DefaultsKey.pollOpen) > 0, "open interval default is positive")
        T.expect(defaults.double(forKey: DefaultsKey.pollClosed) > 0, "closed interval default is positive")
        T.expect(defaults.integer(forKey: DefaultsKey.pauseMinutes) > 0, "pause default is positive")
        T.expect(defaults.bool(forKey: DefaultsKey.animateIcon), "animation defaults on")
        T.equal(defaults.string(forKey: DefaultsKey.forcedTier), "", "no tier is forced by default")
        T.equal(defaults.string(forKey: DefaultsKey.trackedBudgetId), "",
                "budget tracking defaults to automatic")
        for section in PanelSection.allCases {
            T.expect(defaults.bool(forKey: section.defaultsKey), "\(section.rawValue) visible by default")
        }

        // Every key must be distinct — a collision would make two settings
        // silently share one value.
        let keys = [DefaultsKey.titleMode, DefaultsKey.trackedBudgetId, DefaultsKey.gatewayHost,
                    DefaultsKey.gatewayPort, DefaultsKey.pollOpen, DefaultsKey.pollClosed,
                    DefaultsKey.notifySoft, DefaultsKey.notifyDown, DefaultsKey.pauseMinutes,
                    DefaultsKey.animateIcon, DefaultsKey.forcedTier, DefaultsKey.meltSince]
            + PanelSection.allCases.map(\.defaultsKey)
        T.equal(Set(keys).count, keys.count, "all defaults keys are unique")
    }

    T.suite("notifier availability gating") {
        // UNUserNotificationCenter.current() traps outright when the process has
        // no bundle identifier, which is the case for the test binary and for
        // running the bare executable. isAvailable is the guard that keeps that
        // from crashing.
        T.equal(Notifier.isAvailable, Bundle.main.bundleIdentifier != nil,
                "availability tracks the bundle identifier")
        if !Notifier.isAvailable {
            T.expect(Notifier.explanation != nil, "unbundled explains itself in Settings")
        }
        // Must be safe to call regardless — a no-op rather than a trap.
        Notifier.post(title: "test", body: "must not trap")
        T.expect(true, "post is safe when unavailable")
    }

    T.suite("spend window label") {
        // The breakdown header claims a window; it has to match the budget the
        // breakdown was actually fetched for.
        let status = try decodeFixture(GatewayStatus.self, statusFixture)
        var snap = GatewaySnapshot()
        snap.status = status
        let tracked = snap.titleBudget(preferredId: nil)
        T.equal(tracked?.window, "5h", "tracked budget window")
        T.close(tracked?.windowSeconds ?? -1, 18_000, "and its seconds")

        let monthly = snap.titleBudget(preferredId: "monthly")
        T.equal(monthly?.window, "30d", "an explicit choice changes the window")
        T.close(monthly?.windowSeconds ?? -1, 2_592_000, "30d in seconds")
    }
}
