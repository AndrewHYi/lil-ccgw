import SwiftUI

/// The dropdown. Section order follows the dashboard's own information
/// hierarchy (health → budgets → burn → breakdown) so the two surfaces agree
/// about what matters most.
struct PanelView: View {
    @Bindable var model: GatewayModel
    @Environment(\.openSettings) private var openSettings
    @Environment(\.openWindow) private var openWindow

    @AppStorage(PanelSection.budgets.defaultsKey) private var showBudgets = true
    @AppStorage(PanelSection.burn.defaultsKey) private var showBurn = true
    @AppStorage(PanelSection.models.defaultsKey) private var showModels = true
    @AppStorage(DefaultsKey.pauseMinutes) private var pauseMinutes = 60

    @State private var confirming: Confirmation?

    /// Re-rolled each time the panel opens, which is this app's analogue of the
    /// dashboard re-rolling its tooltip on every hover.
    @State private var joke: String?

    /// Budget id whose bumper form is open, if any.
    @State private var bumping: String?
    @State private var bumpAmount = "25"
    @State private var bumpMinutes = 0

    /// The "set the bumper to" field, which replaces an active bumper instead of
    /// adding to it. Prefilled with the current amount when the form opens, so
    /// correcting a mistyped bumper is an edit rather than a fresh calculation.
    @State private var bumpTarget = ""

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

    /// The down state, written consequence-first.
    ///
    /// "Gateway not responding" is the technical fact; "Claude Code is failing"
    /// is what the user is actually experiencing, and it's the reason they came
    /// looking. Lead with that, then offer the two ways out: bring the gateway
    /// back, or take Claude Code out from behind it.
    private var downNotice: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 4) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.red)
                Text("Claude Code requests are failing")
                    .font(.system(size: 12, weight: .semibold))
            }

            Text("Claude Code is wired to send every request through this gateway, and it isn't answering on \(model.gatewayAddress). Requests will fail with connection refused until it's back.")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Text(model.agentLoaded
                 ? "The launchd agent is loaded, so something is wedged rather than missing."
                 : "The launchd agent isn't loaded — most likely it was stopped deliberately.")
                .font(.system(size: 10))
                .foregroundStyle(.tertiary)
                .fixedSize(horizontal: false, vertical: true)

            HStack(spacing: 6) {
                Button("Recover gateway") { Task { await model.recover() } }
                    .buttonStyle(.borderedProminent)
                Button("Bypass…") { confirming = .bypass }
            }
            .controlSize(.small)
            .disabled(model.isBusy)

            Text("Bypass unwires Claude Code from the gateway so it talks to the API directly — it works even while the gateway is down, but budgets stop being enforced and it needs a Claude Code restart.")
                .font(.system(size: 9))
                .foregroundStyle(.tertiary)
                .fixedSize(horizontal: false, vertical: true)

            if let error = model.lastError {
                Text(error)
                    .font(.system(size: 10))
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }
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

                    bumpRow(budget, all: status.budgets)
                }
            }
        }
        .font(.system(size: 11))
    }

    /// The bumper affordance: an active bumper's state, and a way to add one.
    ///
    /// Hidden entirely on the overall ceiling — the gateway rejects a bump there
    /// with a 400, since raising the widest block budget would increase total
    /// spend rather than redistribute it.
    @ViewBuilder
    private func bumpRow(_ budget: Budget, all: [Budget]) -> some View {
        if budget.isCeiling(among: all) {
            EmptyView()
        } else {
            HStack(spacing: 6) {
                if budget.hasActiveBump() {
                    HStack(spacing: 3) {
                        Image(systemName: "arrow.up.circle.fill")
                        Text("+\(Fmt.usd(budget.bumpUsd ?? 0))")
                            .monospacedDigit()
                        if let expiry = budget.bumpExpiryDate {
                            Text("until \(Fmt.clockTime(expiry))")
                        }
                        Button {
                            Task { await model.clearBump(budgetId: budget.id) }
                        } label: {
                            Image(systemName: "xmark")
                        }
                        .buttonStyle(.borderless)
                        .help("Remove this bumper")
                    }
                    .font(.system(size: 10))
                    .foregroundStyle(.blue)
                    // The base limit matters once a bumper is active: the
                    // headline figure already includes it, so without this the
                    // budget looks larger than it was configured to be.
                    Text("(base \(Fmt.limit(budget.baseLimitUsd())))")
                        .font(.system(size: 10))
                        .foregroundStyle(.tertiary)
                }
                Spacer()
                Button(budget.hasActiveBump() ? "+ more" : "+ bumper") {
                    bumping = (bumping == budget.id) ? nil : budget.id
                    bumpAmount = "25"
                    bumpMinutes = 0
                    bumpTarget = BumpForm.fieldText(budget.bumpUsd ?? 0)
                }
                .buttonStyle(.borderless)
                .font(.system(size: 10))
            }

            // A lapsing bumper that reverts below current spend exhausts the
            // budget the moment it expires. The expiry time alone does not say
            // that, and the failure is total — every request refused.
            if let warning = Derive.bumpExpiryWarning(
                baseLimit: budget.baseLimitUsd(),
                spent: budget.spentUsd,
                expiresAt: budget.bumpExpiryDate
            ) {
                HStack(alignment: .top, spacing: 3) {
                    Image(systemName: "exclamationmark.triangle.fill")
                    Text(warning).fixedSize(horizontal: false, vertical: true)
                }
                .font(.system(size: 9))
                .foregroundStyle(.orange)
            }

            if bumping == budget.id {
                bumpForm(budget)
            }
        }
    }

    private func bumpForm(_ budget: Budget) -> some View {
        BumpForm(
            budget: budget,
            amount: $bumpAmount,
            minutes: $bumpMinutes,
            target: $bumpTarget,
            onAdd: { amount, minutes in
                Task {
                    await model.bump(budgetId: budget.id, amountUsd: amount, minutes: minutes)
                    bumping = nil
                }
            },
            onReplace: { amount, minutes in
                Task {
                    await model.setBump(budgetId: budget.id, amountUsd: amount, minutes: minutes)
                    bumping = nil
                }
            },
            onCancel: { bumping = nil }
        )
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
                if model.isDown {
                    // Recovery already has a prominent button in the down notice;
                    // this row keeps only what still makes sense with no gateway
                    // to talk to.
                    Button("Recover") { Task { await model.recover() } }
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
                Button("Reconnect") { Task { await model.wire() } }
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
            Button("Help…") { HelpWindow.present { openWindow(id: "help") } }
                .keyboardShortcut("?")
            Spacer()
            Button("Quit") { NSApplication.shared.terminate(nil) }
                .keyboardShortcut("q")
        }
        .buttonStyle(.borderless)
        .font(.system(size: 11))
    }

    // MARK: - Helpers

    private var topModels: [SpendRow]? { PanelDerive.topModels(model.snapshot.spend) }

    private func color(for budget: Budget, softThreshold: Double) -> Color {
        PanelDerive.budgetColor(budget, softThreshold: softThreshold)
    }

    private func paceColor(_ pace: Double?) -> Color { PanelDerive.paceColor(pace) }
}

/// The bumper form, lifted out of `PanelView` so its layout can be asserted.
///
/// `PanelView` opens it from a private `@State`, so nothing outside could render
/// it open — and this is the part that just grew a second field and two live cap
/// previews inside a fixed 320pt panel, which is precisely the shape of change
/// `RenderTests` exists to catch. Actions are handed out as closures so the view
/// itself stays free of the model.
struct BumpForm: View {
    let budget: Budget
    @Binding var amount: String
    @Binding var minutes: Int
    @Binding var target: String
    var onAdd: (Double, Int?) -> Void
    var onReplace: (Double, Int?) -> Void
    var onCancel: () -> Void

    var body: some View {
        let addend = Double(amount) ?? 0
        let replacement = Double(target) ?? 0
        return VStack(alignment: .leading, spacing: 6) {
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 4) {
                    Text("Allow an extra")
                    TextField("", text: $amount)
                        .frame(width: 46)
                        .monospacedDigit()
                        .multilineTextAlignment(.trailing)
                    Text("USD for")
                    Picker("", selection: $minutes) {
                        // 0 stands for "omit minutes", which makes the gateway use
                        // the budget's own window — its documented default.
                        Text("this window (\(budget.window))").tag(0)
                        Text("1 hour").tag(60)
                        Text("12 hours").tag(720)
                        Text("24 hours").tag(1440)
                    }
                    .labelsHidden()
                    .frame(width: 130)
                }
                // Adding stacks on whatever is already in force, so the cap this
                // produces starts from the effective limit rather than the base.
                capPreview(
                    cap: BumpForm.addedCap(budget, extra: addend),
                    spent: budget.spentUsd,
                    action: "Add",
                    enabled: addend > 0
                ) {
                    // 0 is the picker's "omit minutes", not a zero-length bump.
                    onAdd(addend, minutes == 0 ? nil : minutes)
                }
            }

            // Replacing only means anything while a bumper is in force; with none
            // active, setting it to N and adding N are the same request, and a
            // second field for the same outcome is just another thing to misread.
            if budget.hasActiveBump() {
                Divider()
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 4) {
                        Text("Set the bumper to")
                        TextField("", text: $target)
                            .frame(width: 52)
                            .monospacedDigit()
                            .multilineTextAlignment(.trailing)
                        Text("USD")
                    }
                    capPreview(
                        cap: BumpForm.replacedCap(budget, amount: replacement),
                        spent: budget.spentUsd,
                        action: "Replace",
                        enabled: replacement > 0
                    ) {
                        // Carry what is left of the current bumper so changing the
                        // amount does not silently restart its clock.
                        onReplace(
                            replacement,
                            Derive.remainingBumpMinutes(expiresAt: budget.bumpExpiryDate)
                        )
                    }
                }
            }

            HStack {
                Text(budget.hasActiveBump()
                     ? "Adding stacks on the active bumper and the later expiry wins; replacing swaps it outright and keeps the expiry it already had."
                     : "The overall ceiling is never raised, so total spend stays capped — the bump comes out of remaining headroom, and the sustainable pace for the rest of the window drops to match.")
                    .font(.system(size: 9))
                    .foregroundStyle(.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer()
                Button("Cancel", action: onCancel)
                    .buttonStyle(.bordered)
                    .controlSize(.small)
            }
        }
        .font(.system(size: 10))
        .padding(6)
        .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 4))
    }

    /// The cap a typed number would actually produce, beside the button that
    /// commits it.
    ///
    /// Both fields take a delta while the number anyone reasons about is the cap,
    /// and nothing on screen used to bridge the two — which is how a $75 budget
    /// acquires a $2285 ceiling without anyone intending it. Showing the outcome
    /// next to the input is the whole point of this row.
    private func capPreview(
        cap: Double,
        spent: Double,
        action: String,
        enabled: Bool,
        apply: @escaping () -> Void
    ) -> some View {
        let warning = Derive.bumpWarning(cap: cap, spent: spent)
        return VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 6) {
                Text("→ cap \(Fmt.limit(cap))")
                    .monospacedDigit()
                    .foregroundStyle(warning == nil ? Color.secondary : Color.red)
                Spacer()
                Button(action, action: apply)
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .disabled(!enabled)
            }
            if let warning {
                // Deliberately not disabling the button. Capping yourself at what
                // you have already spent is the fastest stop this app offers, so
                // it states the consequence and lets it through.
                Text(warning)
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .font(.system(size: 9))
    }

    /// The cap the "allow an extra" field would produce.
    ///
    /// Adding stacks on whatever is already in force, so it starts from the
    /// effective limit. Starting from the base instead would under-report the cap
    /// by the size of the active bumper — a wrong number rendered confidently,
    /// which is the exact failure this preview exists to prevent.
    static func addedCap(_ budget: Budget, extra: Double) -> Double {
        Derive.resultingCap(base: budget.effectiveLimitUsd, bump: extra)
    }

    /// The cap the "set the bumper to" field would produce.
    ///
    /// Replacing discards the active bumper, so this starts from the base limit.
    /// Starting from the effective limit would double-count the bumper being
    /// replaced.
    static func replacedCap(_ budget: Budget, amount: Double) -> Double {
        Derive.resultingCap(base: budget.baseLimitUsd(), bump: amount)
    }

    /// A bumper amount as editable text — whole dollars stay whole, so a $2210
    /// bumper prefills as "2210" rather than "2210.00".
    static func fieldText(_ value: Double) -> String {
        value == value.rounded() ? String(Int(value)) : String(format: "%.2f", value)
    }
}

/// The panel's decisions, kept out of the view so tests can reach them.
///
/// Same move `Derive` made for `GatewayModel`, and for the same reason: these
/// were `private` members of a `View`, so nothing could assert them even from
/// inside the module. Rendering the panel exercises them, but only for whatever
/// state the fixture happens to hold — it cannot pin a threshold. The pace
/// thresholds in particular are copied from the dashboard, and nothing else in
/// the repo would notice if they drifted apart.
enum PanelDerive {
    /// The three costliest models, or nil when there is no breakdown at all.
    ///
    /// Nil and empty mean different things to the panel: nil is "not fetched",
    /// empty is "no traffic in the window", and both must hide the section rather
    /// than render a header over nothing.
    static func topModels(_ spend: SpendReport?) -> [SpendRow]? {
        spend?.rows
            .sorted { $0.costUsd > $1.costUsd }
            .prefix(3)
            .map { $0 }
    }

    /// Bar colour for one budget. The gateway owns the soft threshold, so it is
    /// passed in rather than assumed to be 80.
    static func budgetColor(_ budget: Budget, softThreshold: Double) -> Color {
        if budget.exhausted { return .red }
        if budget.soft || budget.pct >= softThreshold { return .orange }
        return .accentColor
    }

    /// Matches the dashboard's green/amber/red pace treatment so the two
    /// surfaces never disagree about whether the current burn is a problem.
    static func paceColor(_ pace: Double?) -> Color {
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
