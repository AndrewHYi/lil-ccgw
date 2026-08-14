import SwiftUI

/// A plain-language reference for what each panel control does, opened from
/// the footer's Help button.
///
/// Static content — nothing here reads live state, so unlike the panel it
/// can never disagree with the gateway. The trade is that it can drift from
/// the panel's actual controls if one changes without the other; there is no
/// test for that, the same way there is none for `SettingsView`'s prose.
struct HelpView: View {
    var body: some View {
        Form {
            Section("While the gateway is reachable") {
                HelpRow("Restart", "Gracefully restarts the gateway process: drains in-flight requests, then it respawns. Doesn't change any settings.")
                HelpRow("Pause / Resume", "Turns budget enforcement off for a set number of minutes, then resumes on its own — it auto-reverts, so it can't be forgotten. Spend still gets recorded; only blocking and effort-throttling stop.")
                HelpRow("+ bumper", "Adds temporary extra allowance to one budget. The overall ceiling never offers this — a bump reshapes when you can spend, not how much.")
            }

            Section("Always available, even if the gateway is down") {
                HelpRow("Stop…", "Actually stops the gateway and unloads its login agent, so it won't silently come back. Claude Code still points at it, so requests fail with connection refused until it's started again. Confirms first.")
                HelpRow("Bypass…", "Unwires Claude Code from the gateway by editing its settings directly, so requests go straight to the API. Works even while the gateway is down. Budgets stop being enforced and spend stops being recorded. Takes effect on Claude Code's next restart, not immediately. Confirms first.")
                HelpRow("Reconnect", "The undo for Bypass — wires Claude Code back to the gateway. The two are a pair: Bypass takes Claude Code off the gateway, Reconnect puts it back on. Also takes effect on the next restart, not immediately. (Named “Re-wire” in older versions.)")
            }

            Section("Windows") {
                HelpRow("Dashboard", "Opens the full web dashboard in your browser — the same numbers, plus history and charts.")
                HelpRow("Settings…", "This app's own preferences: gateway address, refresh cadence, default pause length, what the menu bar shows, notifications.")
                HelpRow("Quit", "Quits this menu bar app only. The gateway runs as its own background service and keeps running — Quit doesn't stop it, and Claude Code is unaffected.")
            }

            Section("Reading the panel") {
                HelpRow("enforcement", "on, paused (with a resume time), or degraded — degraded means a budget crossed its soft threshold and requests are being capped to a cheaper effort level rather than blocked outright.")
                HelpRow("Budget rows", "Spend vs. limit for one configured window, each on its own rolling clock. The bar ambers near the soft threshold and reds out when exhausted.")
                HelpRow("burn / pace", "Burn is the current spend rate; pace is that rate divided by what's sustainable for the window. Below 1.0× you'll make it to the reset at this rate; above, you won't.")
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
