import Foundation

/// Formatting and label-state tests.
///
/// The menu bar is a few characters wide and read at a glance, so formatting
/// bugs are user-visible in a way that unit tests catch cheaply: a jittering
/// width, a missing dash where data is absent, or a state whose glyph does not
/// match its severity.
func runPresentationTests() {
    T.suite("currency formatting") {
        T.equal(Fmt.usd(19.62), "$19.62", "cents below 1000")
        T.equal(Fmt.usd(0), "$0.00", "zero")
        T.equal(Fmt.usd(0.07), "$0.07", "sub-cent rounding")
        T.equal(Fmt.usd(999.99), "$999.99", "just below the cents cutoff")
        T.equal(Fmt.usd(1200), "$1200", "drops cents at 1000 to save menu width")
        T.equal(Fmt.usd(33.39, cents: false), "$33", "explicit no-cents")
        T.equal(Fmt.limit(75), "$75", "limits never show cents")
        T.equal(Fmt.limit(1200), "$1200", "large limit")
    }

    T.suite("rate and pace formatting") {
        T.equal(Fmt.pace(0.91), "0.91×", "pace")
        T.equal(Fmt.pace(1.0), "1.00×", "pace at parity")
        T.equal(Fmt.pace(nil), "—", "nil pace renders a dash, not 0")
        T.equal(Fmt.rate(13.58), "$13.58/hr", "burn rate")
        T.equal(Fmt.rate(nil), "—", "nil rate renders a dash")
    }

    T.suite("duration formatting") {
        T.equal(Fmt.hours(4.1), "4.1h", "hours with decimal")
        T.equal(Fmt.hours(1), "1.0h", "exactly one hour")
        T.equal(Fmt.hours(0.5), "30m", "sub-hour becomes minutes")
        T.equal(Fmt.hours(96), "4d", "multi-day collapses to days")
        T.equal(Fmt.hours(nil), "—", "nil")
        T.equal(Fmt.hours(.infinity), "—", "infinite ETA renders a dash")

        T.equal(Fmt.uptime(11_640), "3h 14m", "hours and minutes")
        T.equal(Fmt.uptime(90), "1m", "under an hour")
        T.equal(Fmt.uptime(180_000), "2d 2h", "days and hours")
        T.equal(Fmt.uptime(nil), "—", "nil")
        T.equal(Fmt.uptime(0), "—", "zero uptime is not yet running")
    }

    T.suite("title modes") {
        let (snapshot, budget) = MenuBarLabel.sampleSnapshot()

        // Icon-only must not render text at any width.
        let iconOnly = MenuBarLabel(
            snapshot: snapshot, scene: SkitScene.scene(for: .ok), heat: .normal,
            frame: 0, mode: .iconOnly, trackedBudget: budget
        )
        T.expect(iconOnly.renderedText == nil, "icon-only renders no text")

        // The default mode: spend, ceiling, and window together.
        let full = MenuBarLabel(
            snapshot: snapshot, scene: SkitScene.scene(for: .ok), heat: .normal,
            frame: 0, mode: .spendOfLimit, trackedBudget: budget
        )
        T.equal(full.renderedText, "$9.34/$75 5h", "default shows spend, limit and window")

        let spend = MenuBarLabel(
            snapshot: snapshot, scene: SkitScene.scene(for: .ok), heat: .normal,
            frame: 0, mode: .iconAndSpend, trackedBudget: budget
        )
        T.equal(spend.renderedText, "$9.34", "spend-only shows tracked spend")

        let pace = MenuBarLabel(
            snapshot: snapshot, scene: SkitScene.scene(for: .ok), heat: .normal,
            frame: 0, mode: .iconAndPace, trackedBudget: budget
        )
        T.equal(pace.renderedText, "0.32×", "icon+pace shows pace")

        // Statusline pairs the tracked budget with the widest *other* block
        // budget as the ceiling — the degrade and warn budgets must not be
        // mistaken for it.
        let statusline = MenuBarLabel(
            snapshot: snapshot, scene: SkitScene.scene(for: .ok), heat: .normal,
            frame: 0, mode: .statusline, trackedBudget: budget
        )
        T.equal(
            statusline.renderedText, "$9.34/$75 5h │ $23/$1200 30d",
            "statusline pairs tracked budget with the block ceiling"
        )
    }

    T.suite("title with no data") {
        // When the gateway is unreachable the title must show a dash rather
        // than a stale or invented number.
        let empty = GatewaySnapshot()
        for mode in TitleMode.allCases where mode != .iconOnly {
            let label = MenuBarLabel(snapshot: empty, scene: SkitScene.scene(for: nil), heat: .normal,
                                     frame: 0, mode: mode, trackedBudget: nil)
            T.equal(label.renderedText, "—", "\(mode.rawValue) shows a dash when down")
        }
        let iconOnly = MenuBarLabel(snapshot: empty, scene: SkitScene.scene(for: nil), heat: .normal,
                                        frame: 0, mode: .iconOnly, trackedBudget: nil)
        T.expect(iconOnly.renderedText == nil, "icon-only stays textless when down")
    }

    T.suite("sample snapshot is usable for the preview") {
        // The settings preview falls back to this when the gateway is
        // unreachable; if it stopped decoding, the preview would silently show
        // dashes and misrepresent every mode.
        let (snapshot, budget) = MenuBarLabel.sampleSnapshot()
        T.expect(snapshot.status != nil, "sample decodes")
        T.equal(budget.id, "session", "sample tracks the session budget")
        T.close(budget.spentUsd, 9.34, "sample spend")
        T.equal(snapshot.status?.budgets.count, 2, "sample has a ceiling budget too")
    }

    T.suite("title modes are all selectable") {
        // A mode absent from allCases would be unreachable in Settings.
        T.equal(TitleMode.allCases.count, 5, "five title modes")

        // The default has to carry the denominator and window, not spend alone:
        // "$19.62" answers how much, but not out of what or over how long.
        T.equal(
            UserDefaults.standard.string(forKey: DefaultsKey.titleMode),
            TitleMode.spendOfLimit.rawValue,
            "registered default is spend/limit + window"
        )
        for mode in TitleMode.allCases {
            T.expect(!mode.label.isEmpty, "\(mode.rawValue) has a label")
            T.expect(!mode.detail.isEmpty, "\(mode.rawValue) has a description")
            T.equal(TitleMode(rawValue: mode.rawValue), mode, "\(mode.rawValue) round-trips")
        }
        for section in PanelSection.allCases {
            T.expect(!section.label.isEmpty, "\(section.rawValue) has a label")
            T.expect(section.defaultsKey.hasPrefix("show."), "\(section.rawValue) key namespaced")
        }
    }
}

