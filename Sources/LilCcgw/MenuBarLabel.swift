import SwiftUI

/// The menu bar title.
///
/// This one view renders both the live status item and the preview strip in
/// Settings → Display. That sharing is the entire mechanism behind the WYSIWYG
/// requirement: there is no second code path that could drift from what the
/// menu bar actually shows. Do not fork it for the preview.
///
/// Two independent axes, deliberately:
///
/// - **Glyph** carries burn rate, via the `SkitScene` ladder ported from the
///   dashboard. Frames are shape-distinct rather than colour-distinct, because
///   SwiftUI renders `MenuBarExtra` labels as template images in most
///   configurations and flattens colour.
/// - **Colour** carries budget consumption — normal, amber at the gateway's soft
///   threshold, red when exhausted.
///
/// So a thriving leaf in amber is a real and useful state: calm burn rate, but
/// most of the window already spent.
struct MenuBarLabel: View {
    let snapshot: GatewaySnapshot
    let scene: SkitScene
    let heat: BudgetHeat
    let frame: Int
    let mode: TitleMode
    let trackedBudget: Budget?

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: glyph).foregroundStyle(tint)
            if let text = renderedText {
                Text(text)
                    .monospacedDigit()
                    .foregroundStyle(tint)
            }
        }
        .accessibilityLabel(accessibilityText)
    }

    // MARK: - Glyph and colour

    var glyph: String { scene.frame(frame) }

    var tint: Color {
        switch heat {
        case .exhausted: return .red
        case .soft: return .orange
        case .normal: return scene.tier == nil ? .secondary : .primary
        }
    }

    // MARK: - Text

    /// The text beside the glyph, or nil for icon-only. Internal rather than
    /// private so the test suite can assert every mode's output directly —
    /// rendering a SwiftUI view in a test would need a host app.
    var renderedText: String? {
        switch mode {
        case .iconOnly:
            return nil
        case .spendOfLimit:
            guard let budget = trackedBudget else { return placeholder }
            return "\(Fmt.usd(budget.spentUsd))/\(Fmt.limit(budget.effectiveLimitUsd)) \(budget.window)"
        case .iconAndSpend:
            guard let budget = trackedBudget else { return placeholder }
            return Fmt.usd(budget.spentUsd)
        case .iconAndPace:
            guard let budget = trackedBudget else { return placeholder }
            return Fmt.pace(budget.pace ?? snapshot.status?.primary?.pace)
        case .statusline:
            return statuslineText
        }
    }

    /// Mirrors the ccgw statusline segment: primary window, then the widest
    /// block budget as the overall ceiling.
    private var statuslineText: String? {
        guard let status = snapshot.status else { return placeholder }
        guard let primary = trackedBudget ?? status.budgets.first else { return placeholder }
        var parts = ["\(Fmt.usd(primary.spentUsd))/\(Fmt.limit(primary.effectiveLimitUsd)) \(primary.window)"]
        let ceiling = status.budgets
            .filter { $0.action == "block" && $0.id != primary.id }
            .max(by: { $0.effectiveLimitUsd < $1.effectiveLimitUsd })
        if let ceiling {
            parts.append("\(Fmt.usd(ceiling.spentUsd, cents: false))/\(Fmt.limit(ceiling.effectiveLimitUsd)) \(ceiling.window)")
        }
        return parts.joined(separator: " │ ")
    }

    /// A dash rather than a stale or invented number when there is nothing to
    /// report. `scene.tier == nil` is exactly the unreachable/paused/unknown set.
    private var placeholder: String? {
        scene.tier == nil ? "—" : nil
    }

    /// Spoken form carries the scene too — the glyph is the whole signal in
    /// icon-only mode, and a template image says nothing to a screen reader.
    ///
    /// Internal rather than private so tests can assert it; there is no way to
    /// read a rendered view's accessibility label without a host app.
    var accessibilityText: String {
        guard let budget = trackedBudget else {
            return scene.caption.isEmpty ? "ccgw: no data" : "ccgw: \(scene.caption)"
        }
        let spend = "\(budget.id) \(budget.window): \(Fmt.usd(budget.spentUsd)) of \(Fmt.limit(budget.effectiveLimitUsd))"
        return scene.caption.isEmpty ? "ccgw \(spend)" : "ccgw \(spend). \(scene.caption)"
    }
}

/// Live wrapper around `MenuBarLabel` for the status item and the panel header.
///
/// This indirection is load-bearing, not ceremony. `MenuBarLabel` stores plain
/// values, so handing it `model.snapshot` from an initialiser would read the
/// `@Observable` model *outside* body evaluation — and SwiftUI only registers a
/// dependency on properties read *during* body. The label would then render once
/// and freeze, updating only when something else forced a redraw (opening the
/// panel). Reading the model here, inside `body`, is what makes the menu bar
/// title actually track the gateway.
///
/// Do not add a `MenuBarLabel.init(model:)` convenience back. That was the bug.
struct MenuBarTitle: View {
    let model: GatewayModel
    let mode: TitleMode

    var body: some View {
        // Every one of these is read here, inside body, on purpose — including
        // `animator.frame`, which is what advances the animation. Hoisting any
        // into an initialiser silently freezes the title.
        //
        // Each tick costs a hosted-view invalidation, measured at roughly 6% of
        // a core at 0.26s and 10% at 0.18s. Isolating the icon into its own
        // nested view was tried and made no difference, so the cost is macOS
        // re-hosting the status item rather than anything in this body. The
        // lever is tick rate, or the animate toggle.
        MenuBarLabel(
            snapshot: model.snapshot,
            scene: model.scene,
            heat: model.budgetHeat,
            frame: model.animator.frame,
            mode: mode,
            trackedBudget: model.trackedBudget
        )
    }
}

extension MenuBarLabel {
    /// Sample data for the Settings preview when the gateway is unreachable.
    /// Labelled as sample in the UI rather than passed off as live, so the
    /// preview never quietly shows zeros as if they were real.
    static func sampleSnapshot() -> (GatewaySnapshot, Budget) {
        let json = """
        {
          "enforcement": "on",
          "enforcement_resume_at": null,
          "degraded": false,
          "soft_threshold_pct": 80,
          "primary": {
            "id": "session", "window": "5h", "pace": 0.32,
            "burn_rate_hr": 4.73, "sustainable_hr": 15,
            "eta_hours": 13.9, "fits_window": true
          },
          "budgets": [
            {
              "id": "session", "scope": "global", "window": "5h",
              "effective_limit_usd": 75, "spent_usd": 9.34,
              "remaining_usd": 65.66, "pct": 12.5, "action": "block",
              "exhausted": false, "soft": false, "burn_rate_hr": 4.73,
              "sustainable_hr": 15, "pace": 0.32,
              "bump_usd": 0, "bump_expires_at": null
            },
            {
              "id": "monthly", "scope": "global", "window": "30d",
              "effective_limit_usd": 1200, "spent_usd": 23.11,
              "remaining_usd": 1176.89, "pct": 1.9, "action": "block",
              "exhausted": false, "soft": false, "burn_rate_hr": null,
              "sustainable_hr": null, "pace": null,
              "bump_usd": 0, "bump_expires_at": null
            }
          ]
        }
        """
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        let status = try! decoder.decode(GatewayStatus.self, from: Data(json.utf8))
        var snapshot = GatewaySnapshot()
        snapshot.status = status
        return (snapshot, status.budgets[0])
    }
}
