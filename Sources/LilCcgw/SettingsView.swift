import ServiceManagement
import SwiftUI

struct SettingsView: View {
    @Bindable var model: GatewayModel

    var body: some View {
        TabView {
            GeneralPane(model: model)
                .tabItem { Label("General", systemImage: "gearshape") }
            DisplayPane(model: model)
                .tabItem { Label("Display", systemImage: "menubar.rectangle") }
            AlertsPane()
                .tabItem { Label("Alerts", systemImage: "bell") }
        }
        .frame(width: 440)
    }
}

// MARK: - General

private struct GeneralPane: View {
    @Bindable var model: GatewayModel

    @AppStorage(DefaultsKey.gatewayHost) private var host = "127.0.0.1"
    @AppStorage(DefaultsKey.gatewayPort) private var port = 8484
    @AppStorage(DefaultsKey.pollOpen) private var pollOpen = 5.0
    @AppStorage(DefaultsKey.pollClosed) private var pollClosed = 30.0
    @AppStorage(DefaultsKey.pauseMinutes) private var pauseMinutes = 60

    @State private var launchAtLogin = LoginItem.isEnabled
    @State private var loginError: String?

    var body: some View {
        Form {
            Section {
                Toggle("Launch at login", isOn: $launchAtLogin)
                    .onChange(of: launchAtLogin) { _, enabled in
                        do {
                            try LoginItem.set(enabled)
                            loginError = nil
                        } catch {
                            loginError = error.localizedDescription
                            launchAtLogin = LoginItem.isEnabled
                        }
                    }
                if let loginError {
                    Text(loginError)
                        .font(.caption)
                        .foregroundStyle(.red)
                }
                if let note = LoginItem.note {
                    Text(note)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Section("Gateway") {
                TextField("Host", text: $host)
                TextField("Port", value: $port, format: .number)
                Text("Address the gateway as 127.0.0.1 — it validates the Host header against loopback names, so `localhost` can be rejected.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Button("Apply and reconnect") {
                    Task { await model.applyConnectionSettings() }
                }
            }

            Section("Refresh") {
                LabeledContent("Panel open") {
                    Stepper("\(Int(pollOpen))s", value: $pollOpen, in: 1...60, step: 1)
                }
                LabeledContent("Panel closed") {
                    Stepper("\(Int(pollClosed))s", value: $pollClosed, in: 5...300, step: 5)
                }
            }

            Section("Pause duration") {
                LabeledContent("Default pause") {
                    Stepper("\(pauseMinutes) min", value: $pauseMinutes, in: 1...1440, step: 15)
                }
                Text("The gateway clamps this to 1–1440 minutes and auto-resumes, so a pause cannot be forgotten.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }
}

// MARK: - Display

private struct DisplayPane: View {
    @Bindable var model: GatewayModel

    @AppStorage(DefaultsKey.titleMode) private var titleModeRaw = TitleMode.spendOfLimit.rawValue
    @AppStorage(DefaultsKey.trackedBudgetId) private var trackedBudgetId = ""
    @AppStorage(DefaultsKey.animateIcon) private var animateIcon = true
    @AppStorage(DefaultsKey.forcedTier) private var forcedTier = ""

    private var titleMode: TitleMode {
        TitleMode(rawValue: titleModeRaw) ?? .iconAndSpend
    }

    /// Live data when the gateway is reachable, clearly-labelled sample data
    /// when it is not — never zeros dressed up as real numbers.
    private var previewData: (snapshot: GatewaySnapshot, budget: Budget?, isLive: Bool) {
        if model.snapshot.status != nil {
            return (model.snapshot, model.trackedBudget, true)
        }
        let (sample, budget) = MenuBarLabel.sampleSnapshot()
        return (sample, budget, false)
    }

    var body: some View {
        Form {
            Section("Menu bar shows") {
                Picker("", selection: $titleModeRaw) {
                    ForEach(TitleMode.allCases) { mode in
                        Text(mode.label).tag(mode.rawValue)
                    }
                }
                .pickerStyle(.radioGroup)
                .labelsHidden()
                Text(titleMode.detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Track budget") {
                Picker("Budget", selection: $trackedBudgetId) {
                    Text("Automatic (gateway's primary)").tag("")
                    ForEach(model.snapshot.status?.budgets ?? []) { budget in
                        Text("\(budget.id) · \(budget.window)").tag(budget.id)
                    }
                }
                Text("Automatic follows whichever budget the gateway nominates as primary — currently \(model.snapshot.status?.primary.map { "\($0.id) · \($0.window)" } ?? "unknown").")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Icon") {
                Toggle("Animate the icon", isOn: $animateIcon)
                Text("The icon reports burn rate — a leaf under the sustainable rate, escalating through flames to a running figure past 2×. Colour reports budget spent, so a calm leaf can still turn amber. Below 0.85× nothing animates and no timer runs.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                Picker("Force scene", selection: $forcedTier) {
                    Text("Automatic").tag("")
                    ForEach(SkitTier.ordered) { tier in
                        Text(tier.rawValue).tag(tier.rawValue)
                    }
                }
                Text("For seeing every stage without waiting for a runaway — or for the first of the month. Leave on Automatic in normal use.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Preview") {
                MenuBarPreview(
                    snapshot: previewData.snapshot,
                    scene: previewScene,
                    heat: previewData.isLive ? model.budgetHeat : .normal,
                    frame: model.animator.frame,
                    mode: titleMode,
                    budget: previewData.budget
                )
                if !previewScene.caption.isEmpty {
                    Text(previewScene.caption)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Text(previewData.isLive
                     ? "Live data — this is exactly what the menu bar renders."
                     : "Sample data (gateway unreachable) — layout is exact, numbers are not.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }

    /// Live scene when the gateway is up; a calm one for the sample, so the
    /// preview never implies a meltdown that isn't happening.
    private var previewScene: SkitScene {
        previewData.isLive ? model.scene : SkitScene.scene(for: .ok)
    }
}

/// A mock menu bar strip so the choice can be judged in context rather than in
/// the abstract. Renders the real `MenuBarLabel`, never a copy of it.
private struct MenuBarPreview: View {
    let snapshot: GatewaySnapshot
    let scene: SkitScene
    let heat: BudgetHeat
    let frame: Int
    let mode: TitleMode
    let budget: Budget?

    var body: some View {
        HStack(spacing: 12) {
            Spacer()
            MenuBarLabel(snapshot: snapshot, scene: scene, heat: heat,
                         frame: frame, mode: mode, trackedBudget: budget)
            Image(systemName: "wifi")
            Image(systemName: "battery.75percent")
            Text(Fmt.clockTime(Date()))
        }
        .font(.system(size: 12))
        .foregroundStyle(.primary)
        .padding(.horizontal, 10)
        .frame(height: 26)
        .background(.quaternary, in: RoundedRectangle(cornerRadius: 6))
    }
}

// MARK: - Alerts

private struct AlertsPane: View {
    @AppStorage(DefaultsKey.notifySoft) private var notifySoft = true
    @AppStorage(DefaultsKey.notifyDown) private var notifyDown = true
    @AppStorage(PanelSection.budgets.defaultsKey) private var showBudgets = true
    @AppStorage(PanelSection.burn.defaultsKey) private var showBurn = true
    @AppStorage(PanelSection.models.defaultsKey) private var showModels = true

    var body: some View {
        Form {
            Section("Notify me when") {
                Toggle("The tracked budget crosses its soft threshold", isOn: $notifySoft)
                Toggle("The gateway stops responding", isOn: $notifyDown)
                if let explanation = Notifier.explanation {
                    Text(explanation)
                        .font(.caption)
                        .foregroundStyle(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            Section("Show in dropdown") {
                Toggle(PanelSection.budgets.label, isOn: $showBudgets)
                Toggle(PanelSection.burn.label, isOn: $showBurn)
                Toggle(PanelSection.models.label, isOn: $showModels)
            }
        }
        .formStyle(.grouped)
    }
}

// MARK: - Login item

/// Launch at login.
///
/// `SMAppService.mainApp` is the supported API, but it needs a real bundle and
/// is the feature most likely to misbehave on an ad-hoc-signed app. Rather than
/// showing a toggle that silently fails, unavailability and errors are surfaced
/// to the pane.
enum LoginItem {
    static var isAvailable: Bool { Bundle.main.bundleIdentifier != nil }

    static var isEnabled: Bool {
        guard isAvailable else { return false }
        return SMAppService.mainApp.status == .enabled
    }

    static func set(_ enabled: Bool) throws {
        guard isAvailable else {
            throw NSError(
                domain: "lil-ccgw", code: 1,
                userInfo: [NSLocalizedDescriptionKey:
                    "Launch at login needs the assembled .app — the bare binary has no bundle identifier."]
            )
        }
        if enabled {
            try SMAppService.mainApp.register()
        } else {
            try SMAppService.mainApp.unregister()
        }
    }

    static var note: String? {
        guard isAvailable else {
            return "Running unbundled — launch at login is unavailable until installed as lil-ccgw.app."
        }
        if SMAppService.mainApp.status == .requiresApproval {
            return "Approval needed in System Settings → General → Login Items."
        }
        return nil
    }
}
