import AppKit
import Foundation
import SwiftUI

/// Renders the panel, settings and help views in the states a user can actually
/// reach, and asserts each one produces something.
///
/// `RenderTests` measures the menu bar label's geometry, because a few points of
/// width there is a real constraint. This file has a different purpose: the panel
/// and settings views were the two largest files in the repo and neither had a
/// single test, so nothing caught a state that crashed, laid out to nothing, or
/// silently dropped a section. Rendering is the cheapest assertion that covers
/// those, and it works for the same surprising reason `RenderTests` does —
/// SwiftUI hosts inside this plain `swiftc` binary with no bundle and no app.
///
/// What rendering cannot reach is anything behind `@State`: the confirmation
/// dialogs, the bump form, and the joke line only appear once the user has
/// clicked something, and a test outside the view cannot set that. Those paths
/// are covered by testing the decisions they depend on directly — see
/// `PanelDerive` in `DeriveTests`.
@MainActor
func runViewTests() async {
    func size<V: View>(_ view: V) -> CGSize {
        let host = NSHostingView(rootView: view)
        host.layout()
        return host.fittingSize
    }

    /// Renders and asserts the result has real area. A mistyped symbol or a
    /// collapsed stack renders as a zero-size view rather than failing, so size
    /// is the signal that anything happened at all.
    ///
    /// `minimum` defaults to a panel-sized floor. The menu bar title needs its
    /// own, much smaller one: it is ~16pt tall on purpose, since occupying as
    /// little of the menu bar as possible is the whole design goal there.
    func expectRenders<V: View>(_ view: V, _ label: String, minimum: CGFloat = 20) {
        let s = size(view)
        T.expect(s.width > minimum && s.height > minimum,
                 "\(label) renders (\(Int(s.width))x\(Int(s.height)))")
    }

    /// A model driven to a real state through the transport, since `snapshot` is
    /// `private(set)` — the only way in is a refresh, which is also the path the
    /// app takes.
    func model(status: String? = statusFixture,
               health: String? = healthFixture,
               spend: String? = spendFixture) async -> GatewayModel {
        let t = MockTransport()
        if let status { t.stub("/api/status", json: status) } else { t.fail("/api/status") }
        if let health { t.stub("/api/health", json: health) } else { t.fail("/api/health") }
        if let spend { t.stub("/api/spend", json: spend) } else { t.fail("/api/spend") }
        let m = GatewayModel(client: GatewayClient(transport: t))
        await m.refresh()
        return m
    }

    await T.suite("the panel renders in every reachability state") {
        let live = await model()
        T.equal(live.reachability, .live, "the healthy fixture reaches .live")
        expectRenders(PanelView(model: live), "panel when live")

        let paused = await model(status: statusFixturePaused)
        T.equal(paused.reachability, .paused, "the paused fixture reaches .paused")
        expectRenders(PanelView(model: paused), "panel when paused")

        // Every read failing is the state the whole recover/bypass row exists
        // for, and it renders a different tree — the down notice replaces the
        // budget list entirely.
        let down = await model(status: nil, health: nil, spend: nil)
        T.expect(down.isDown, "a failing transport reaches .down")
        expectRenders(PanelView(model: down), "panel when down")
    }

    await T.suite("the panel renders each budget shape") {
        // No primary: the gateway omits it when nothing has traffic, and the
        // panel has to fall back rather than blank.
        let noPrimary = await model(status: statusFixtureNoPrimary)
        expectRenders(PanelView(model: noPrimary), "panel without a primary budget")

        // An empty budget list is reachable on a fresh install, before any
        // budget is configured.
        let noBudgets = await model(status: statusFixtureEmptyBudgets)
        expectRenders(PanelView(model: noBudgets), "panel with no budgets")

        // Exhausted and soft drive the two colour branches in `color(for:)`,
        // and exhausted is the one that matters most to get on screen.
        let hot = await model(status: statusFixtureExhausted)
        expectRenders(PanelView(model: hot), "panel with an exhausted budget")

        // A live bumper renders an extra row with its expiry.
        let bumped = await model(status: statusFixtureBumped)
        expectRenders(PanelView(model: bumped), "panel with an active bumper")

        // Degraded, plus a pace over 1.5 and a window that does not fit — the
        // pessimistic end of the burn section.
        let degraded = await model(status: statusFixtureDegraded)
        expectRenders(PanelView(model: degraded), "panel when degraded")

        // No spend rows: the models section must disappear, not render an empty
        // header with nothing under it.
        let noSpend = await model(spend: spendFixtureEmpty)
        expectRenders(PanelView(model: noSpend), "panel with no spend rows")
    }

    await T.suite("the panel renders with every section toggled off") {
        // Each section is @AppStorage-backed, so the panel has a collapsed form
        // the tests had never built. All three off is the smallest it can get.
        let m = await model()
        for section in PanelSection.allCases {
            UserDefaults.standard.set(false, forKey: section.defaultsKey)
        }
        expectRenders(PanelView(model: m), "panel with all sections hidden")

        for section in PanelSection.allCases {
            UserDefaults.standard.set(true, forKey: section.defaultsKey)
        }
        expectRenders(PanelView(model: m), "panel with all sections shown")
    }

    await T.suite("the panel renders an error without hiding the controls") {
        // A failed action leaves lastError set while the gateway is still up.
        // That combination is its own branch: the error shows in the footer
        // rather than the down notice.
        let m = await model()
        await m.bump(budgetId: "monthly", amountUsd: 1, minutes: nil)
        expectRenders(PanelView(model: m), "panel with a live error")
    }

    await T.suite("settings renders every pane") {
        let m = await model()
        expectRenders(SettingsView(model: m), "settings")

        // The display pane's preview switches between live and sample data on
        // reachability, so render it against a down model too.
        let down = await model(status: nil, health: nil, spend: nil)
        expectRenders(SettingsView(model: down), "settings with the gateway down")

        // Every title mode changes the preview row.
        for mode in TitleMode.allCases {
            UserDefaults.standard.set(mode.rawValue, forKey: DefaultsKey.titleMode)
            expectRenders(SettingsView(model: m), "settings previewing \(mode.rawValue)")
        }
        UserDefaults.standard.set(TitleMode.spendOfLimit.rawValue, forKey: DefaultsKey.titleMode)
    }

    T.suite("help renders and covers every control the panel has") {
        expectRenders(HelpView(), "help")

        // The help window is static prose, so the failure mode is not a crash —
        // it is drifting out of step with the panel it documents. Assert it
        // names every control, which is the one claim worth pinning.
        let help = HelpView.controlNames
        for expected in ["Restart", "Pause", "Stop", "Bypass", "Reconnect",
                         "Dashboard", "Settings", "Quit"] {
            T.expect(help.contains { $0.localizedCaseInsensitiveContains(expected) },
                     "help documents \(expected)")
        }
    }

    await T.suite("the menu bar title renders from a live model") {
        // MenuBarTitle had no test at all, while its own comment documents a
        // shipped bug: a MenuBarLabel.init(model:) convenience that read the
        // model outside a view body and so never updated. Rendering it through
        // the real type is what would have caught that.
        //
        // Both states matter. Before a refresh the title renders the no-data
        // case, which is what a user sees for the first second of every launch
        // and whenever the gateway is unreachable.
        let empty = GatewayModel(client: GatewayClient(transport: MockTransport.healthy()))
        for mode in TitleMode.allCases {
            expectRenders(MenuBarTitle(model: empty, mode: mode),
                          "title in \(mode.rawValue) before any data", minimum: 12)
        }

        let live = await model()
        for mode in TitleMode.allCases {
            expectRenders(MenuBarTitle(model: live, mode: mode),
                          "title in \(mode.rawValue) with data", minimum: 12)
        }
    }
}
