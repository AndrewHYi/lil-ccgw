import SwiftUI

/// The dropdown. Section order follows the dashboard's own information
/// hierarchy (health → budgets → burn → breakdown) so the two surfaces agree
/// about what matters most.
struct PanelView: View {
    @Bindable var model: GatewayModel
    @Environment(\.openSettings) private var openSettings

    @AppStorage(PanelSection.budgets.defaultsKey) private var showBudgets = true
    @AppStorage(PanelSection.burn.defaultsKey) private var showBurn = true
    @AppStorage(PanelSection.models.defaultsKey) private var showModels = true
    @AppStorage(DefaultsKey.pauseMinutes) private var pauseMinutes = 60

    @State private var confirming: Confirmation?

    /// Re-rolled each time the panel opens, which is this app's analogue of the
    /// dashboard re-rolling its tooltip on every hover.
    @State private var joke: String?

    private enum Confirmation: Identifiable {
        case stop, bypass
        var id: String {
            switch self { case .stop: return "stop"; case .bypass: return "bypass" }
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            header
            if model.isDown {
                downNotice
            } else {
                if showBudgets, let status = model.snapshot.status, !status.budgets.isEmpty {
                    Divider()
                    budgets(status)
                }
                if showBurn, let primary = model.snapshot.status?.primary {
                    Divider()
                    burn(primary)
                }
                if showModels, let rows = topModels, !rows.isEmpty {
                    Divider()
                    models(rows)
                }
                Divider()
                enforcementRow
            }
            Divider()
            controls
            Divider()
            footer
        }
        .padding(12)
        .frame(width: 320)
        .onAppear {
            model.panelIsOpen = true
            joke = model.scene.jokes.randomElement()
        }
        .onDisappear { model.panelIsOpen = false }
        // Opening the panel forces a fresh read rather than showing whatever the
        // closed-panel cadence last fetched — up to 30s stale, which at a
        // typical burn is enough to disagree visibly with /dash (which polls
        // status every 4s).
        .task { await model.refresh() }
        .alert(item: $confirming) { which in
            switch which {
            case .stop:
                return Alert(
                    title: Text("Stop the gateway?"),
                    message: Text(
                        """
                        Claude Code points at this gateway, so every request will \
                        fail with connection refused until it is started again.

                        Stopping also unloads the launchd agent, so it will not \
                        come back at login until you press Start.
                        """
                    ),
                    primaryButton: .destructive(Text("Stop")) {
                        Task { await model.stopGateway() }
                    },
                    secondaryButton: .cancel()
                )
            case .bypass:
                return Alert(
                    title: Text("Bypass the gateway?"),
                    message: Text(
                        """
                        This unwires ANTHROPIC_BASE_URL from settings.json so \
                        Claude Code talks to the API directly — budgets stop \
                        being enforced and spend stops being recorded.

                        It takes effect the next time Claude Code starts, not \
                        immediately.
                        """
                    ),
                    primaryButton: .destructive(Text("Bypass")) {
                        Task { await model.bypass() }
                    },
                    secondaryButton: .cancel()
                )
            }
        }
    }

    // MARK: - Sections

    private var header: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 6) {
                MenuBarTitle(model: model, mode: .iconOnly)
                if let health = model.snapshot.health {
                    Text("ccgw \(health.version)")
                        .fontWeight(.semibold)
                    Text("· up \(Fmt.uptime(health.uptimeS))")
                        .foregroundStyle(.secondary)
                } else {
                    Text("ccgw").fontWeight(.semibold)
                    Text("· unreachable").foregroundStyle(.secondary)
                }
                Spacer()
                if model.isBusy {
                    ProgressView().controlSize(.small)
                }
            }
            .font(.system(size: 12))

            // The dashboard puts its caption and a random joke behind a hover
            // tooltip. A MenuBarExtra label can't show one, so the panel is the
            // natural home — and opening it is the closest equivalent gesture.
            if !model.scene.caption.isEmpty {
                Text(model.scene.caption)
                    .font(.system(size: 11))
                    .foregroundStyle(captionColor)
            }
            if let joke {
                Text(joke)
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var captionColor: Color {
        switch model.scene.tier {
        case .crit, .melt, .rip: return .red
        case .warm, .hot, .zen: return .orange
        case .payday: return .green
        case .ok, .none: return .secondary
        }
    }

    private var downNotice: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Gateway is not responding")
                .font(.system(size: 12, weight: .semibold))
            Text(model.agentLoaded
                 ? "The launchd agent is loaded but nothing is answering on the port."
                 : "The launchd agent is not loaded. Start it to restore Claude Code.")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func budgets(_ status: GatewayStatus) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(status.budgets) { budget in
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(budget.id)
                            .fontWeight(budget.id == model.trackedBudget?.id ? .semibold : .regular)
                        Text(budget.window).foregroundStyle(.secondary)
                        Spacer()
                        Text("\(Fmt.usd(budget.spentUsd)) / \(Fmt.limit(budget.effectiveLimitUsd))")
                            .monospacedDigit()
                        Text(String(format: "%.1f%%", budget.pct))
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                            .frame(width: 44, alignment: .trailing)
                    }
                    ProgressView(value: budget.fraction)
                        .tint(color(for: budget, softThreshold: status.softThresholdPct))
                }
            }
        }
        .font(.system(size: 11))
    }

    private func burn(_ primary: PrimaryBudget) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack {
                Text("burn").foregroundStyle(.secondary)
                Text(Fmt.rate(primary.burnRateHr)).monospacedDigit()
                Text("vs \(Fmt.rate(primary.sustainableHr)) sustainable")
                    .foregroundStyle(.secondary)
            }
            HStack {
                Text("pace").foregroundStyle(.secondary)
                Text(Fmt.pace(primary.pace))
                    .monospacedDigit()
                    .foregroundStyle(paceColor(primary.pace))
                if primary.fitsWindow == false {
                    Text("exceeds window").foregroundStyle(.orange)
                } else {
                    Text("· \(Fmt.hours(primary.etaHours)) to limit")
                        .foregroundStyle(.secondary)
                }
            }
        }
        .font(.system(size: 11))
    }

    private func models(_ rows: [SpendRow]) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack {
                Text("top models").foregroundStyle(.secondary)
                Spacer()
                Text(model.spendWindowLabel).foregroundStyle(.secondary)
            }
            ForEach(rows) { row in
                HStack {
                    Text(row.shortName)
                    Spacer()
                    Text(Fmt.usd(row.costUsd)).monospacedDigit()
                }
            }
        }
        .font(.system(size: 11))
    }

    private var enforcementRow: some View {
        HStack(spacing: 4) {
            Text("enforcement").foregroundStyle(.secondary)
            if let status = model.snapshot.status {
                if status.isPaused {
                    Text("paused").foregroundStyle(.orange)
                    if let resume = status.resumeDate {
                        Text("· resumes \(Fmt.clockTime(resume))").foregroundStyle(.secondary)
                    }
                } else {
                    Text(status.enforcement)
                    if status.degraded {
                        Text("· degraded").foregroundStyle(.orange)
                    }
                }
            } else {
                Text("—").foregroundStyle(.secondary)
            }
        }
        .font(.system(size: 11))
    }

    // MARK: - Controls

    private var controls: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                if model.isDown && !model.agentLoaded {
                    Button("Start") { Task { await model.startGateway() } }
                } else {
                    Button("Restart") { Task { await model.restart() } }
                }

                if let status = model.snapshot.status, status.isPaused {
                    Button("Resume") { Task { await model.resumeEnforcement() } }
                } else {
                    Button("Pause \(pauseMinutes)m") {
                        Task { await model.pauseEnforcement(minutes: pauseMinutes) }
                    }
                    .disabled(model.isDown)
                }
            }
            HStack(spacing: 6) {
                Button("Stop…") { confirming = .stop }
                    .disabled(model.isDown && !model.agentLoaded)
                Button("Bypass…") { confirming = .bypass }
                Button("Re-wire") { Task { await model.wire() } }
            }
            if let error = model.lastError, !model.isDown {
                Text(error)
                    .font(.system(size: 10))
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .buttonStyle(.bordered)
        .controlSize(.small)
        .disabled(model.isBusy)
    }

    private var footer: some View {
        HStack {
            Button("Dashboard") { model.openDashboard() }
                .keyboardShortcut("d")
            Button("Settings…") { SettingsWindow.present { openSettings() } }
                .keyboardShortcut(",")
            Spacer()
            Button("Quit") { NSApplication.shared.terminate(nil) }
                .keyboardShortcut("q")
        }
        .buttonStyle(.borderless)
        .font(.system(size: 11))
    }

    // MARK: - Helpers

    private var topModels: [SpendRow]? {
        model.snapshot.spend?.rows
            .sorted { $0.costUsd > $1.costUsd }
            .prefix(3)
            .map { $0 }
    }

    private func color(for budget: Budget, softThreshold: Double) -> Color {
        if budget.exhausted { return .red }
        if budget.soft || budget.pct >= softThreshold { return .orange }
        return .accentColor
    }

    /// Matches the dashboard's green/amber/red pace treatment so the two
    /// surfaces never disagree about whether the current burn is a problem.
    private func paceColor(_ pace: Double?) -> Color {
        guard let pace else { return .secondary }
        if pace >= 1.5 { return .red }
        if pace >= 1.0 { return .orange }
        return .green
    }
}

/// `alert(item:)` shim — SwiftUI dropped the Identifiable-item overload for
/// `Alert`, but it keeps the two confirmations declarative here.
private extension View {
    func alert<Item: Identifiable>(
        item: Binding<Item?>,
        content: @escaping (Item) -> Alert
    ) -> some View {
        let isPresented = Binding(
            get: { item.wrappedValue != nil },
            set: { if !$0 { item.wrappedValue = nil } }
        )
        return background(
            EmptyView().alert(isPresented: isPresented) {
                content(item.wrappedValue!)
            }
        )
    }
}
