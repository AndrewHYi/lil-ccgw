import SwiftUI

/// A plain-language reference for what each panel control does, opened from
/// the footer's Help button.
///
/// Static content — nothing here reads live state, so unlike the panel it can
/// never disagree with the gateway. What it *can* do is drift from the panel's
/// actual controls when one changes without the other, and prose in a view body
/// is not checkable. So the content is data rather than inline literals, and
/// `controlNames` lets a test assert every control is still documented.
struct HelpView: View {
    struct Entry: Identifiable {
        let title: String
        let detail: String
        var id: String { title }
    }

    struct Section: Identifiable {
        let heading: String
        let entries: [Entry]
        var id: String { heading }
    }

    static let sections: [Section] = [
        Section(heading: "While the gateway is reachable", entries: [
            Entry(title: "Restart",
                  detail: "Gracefully restarts the gateway process: drains in-flight requests, then it respawns. Doesn't change any settings."),
            Entry(title: "Pause / Resume",
                  detail: "Turns budget enforcement off for a set number of minutes, then resumes on its own — it auto-reverts, so it can't be forgotten. Spend still gets recorded; only blocking and effort-throttling stop."),
            Entry(title: "+ bumper",
                  detail: "Adds temporary extra allowance to one budget. The overall ceiling never offers this — a bump reshapes when you can spend, not how much."),
        ]),
        Section(heading: "Always available, even if the gateway is down", entries: [
            Entry(title: "Stop…",
                  detail: "Actually stops the gateway and unloads its login agent, so it won't silently come back. Claude Code still points at it, so requests fail with connection refused until it's started again. Confirms first."),
            Entry(title: "Bypass…",
                  detail: "Unwires Claude Code from the gateway by editing its settings directly, so requests go straight to the API. Works even while the gateway is down. Budgets stop being enforced and spend stops being recorded. Takes effect on Claude Code's next restart, not immediately. Confirms first."),
            Entry(title: "Reconnect",
                  detail: "The undo for Bypass — wires Claude Code back to the gateway. The two are a pair: Bypass takes Claude Code off the gateway, Reconnect puts it back on. Also takes effect on the next restart, not immediately. (Named “Re-wire” in older versions.)"),
        ]),
        Section(heading: "Windows", entries: [
            Entry(title: "Dashboard",
                  detail: "Opens the full web dashboard in your browser — the same numbers, plus history and charts."),
            Entry(title: "Settings…",
                  detail: "This app's own preferences: gateway address, refresh cadence, default pause length, what the menu bar shows, notifications."),
            Entry(title: "Quit",
                  detail: "Quits this menu bar app only. The gateway runs as its own background service and keeps running — Quit doesn't stop it, and Claude Code is unaffected."),
        ]),
        Section(heading: "Reading the panel", entries: [
            Entry(title: "enforcement",
                  detail: "on, paused (with a resume time), or degraded — degraded means a budget crossed its soft threshold and requests are being capped to a cheaper effort level rather than blocked outright."),
            Entry(title: "Budget rows",
                  detail: "Spend vs. limit for one configured window, each on its own rolling clock. The bar ambers near the soft threshold and reds out when exhausted."),
            Entry(title: "burn / pace",
                  detail: "Burn is the current spend rate; pace is that rate divided by what's sustainable for the window. Below 1.0× you'll make it to the reset at this rate; above, you won't."),
        ]),
    ]

    /// Every control this window documents, for the drift check in `ViewTests`.
    static var controlNames: [String] {
        sections.flatMap { $0.entries.map(\.title) }
    }

    var body: some View {
        Form {
            ForEach(Self.sections) { section in
                SwiftUI.Section(section.heading) {
                    ForEach(section.entries) { entry in
                        HelpRow(entry.title, entry.detail)
                    }
                }
            }
        }
        .formStyle(.grouped)
        .frame(width: 420)
    }
}

private struct HelpRow: View {
    let title: String
    let detail: String

    init(_ title: String, _ detail: String) {
        self.title = title
        self.detail = detail
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).fontWeight(.semibold)
            Text(detail)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.vertical, 2)
    }
}
