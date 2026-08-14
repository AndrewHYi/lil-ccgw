import AppKit
import Foundation
import Observation

/// Advances the menu bar glyph's animation frames.
///
/// A plain timer feeding an `@Observable` counter, deliberately: `TimelineView`
/// does **not** re-render a `MenuBarExtra` label. Measured with a probe app that
/// logged every body evaluation — `TimelineView(.periodic(by: 0.32))` produced 1
/// tick in 6 seconds, this produced 17. Reading `frame` inside the label's body
/// is what registers the dependency, the same mechanism that fixed the frozen
/// title.
@MainActor
@Observable
final class FrameAnimator {
    private(set) var frame = 0
    private var task: Task<Void, Never>?
    private var currentInterval: Double = 0

    /// Idempotent for an unchanged interval, so the ~5s refresh cycle doesn't
    /// restart the animation and make it stutter.
    func run(interval: Double) {
        guard interval > 0 else { return stop() }
        guard interval != currentInterval || task == nil else { return }
        currentInterval = interval
        task?.cancel()
        task = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(interval))
                guard let self else { return }
                self.frame &+= 1
            }
        }
    }

    /// No animated tier means no timer at all — the point of keeping `ok` static.
    func stop() {
        task?.cancel()
        task = nil
        currentInterval = 0
        frame = 0
    }
}

@MainActor
@Observable
final class GatewayModel {
    private(set) var snapshot = GatewaySnapshot()
    private(set) var lastError: String?
    private(set) var lastUpdated: Date?
    private(set) var isBusy = false
    private(set) var agentLoaded = true

    /// Window the current model breakdown covers, so the panel can label it
    /// honestly instead of asserting a fixed range.
    private(set) var spendWindowSeconds: TimeInterval = 86_400

    var spendWindowLabel: String {
        trackedBudget?.window ?? "24h"
    }

    /// Set by the panel appearing/disappearing so an open panel refreshes
    /// briskly while a closed one stays cheap.
    var panelIsOpen = false {
        didSet { if panelIsOpen != oldValue { restartPolling() } }
    }

    let animator = FrameAnimator()

    private let client: GatewayClient
    private var pollTask: Task<Void, Never>?
    private var notifier = ThresholdNotifier()

    /// `client` is injectable for tests; production uses the default, which
    /// talks to loopback over URLSession.
    ///
    /// `settle` is the pause after a lifecycle action, before the first poll that
    /// checks whether it worked — the gateway drains in-flight requests on the way
    /// out and launchd takes a moment to bring it back. It is injectable purely
    /// for test speed: `recover()` alone waits five seconds, and honouring that
    /// would make it slower than the rest of the suite together.
    init(
        client: GatewayClient = GatewayClient(),
        settle: @escaping @Sendable (Duration) async -> Void = {
            try? await Task.sleep(for: $0)
        }
    ) {
        self.client = client
        self.settle = settle
    }

    private let settle: @Sendable (Duration) async -> Void

    // MARK: - Derived state

    /// Axis one: can the gateway be read, and is it enforcing. Drives which
    /// glyph wins outright and which controls make sense.
    var reachability: Reachability {
        guard let status = snapshot.status else {
            return snapshot.health == nil && lastUpdated != nil ? .down : .unknown
        }
        return status.isPaused ? .paused : .live
    }

    /// Axis two: how much of the tracked budget is gone. Drives colour only, so
    /// the gateway's own soft threshold keeps its meaning even while the glyph
    /// is busy reporting burn rate.
    var budgetHeat: BudgetHeat {
        BudgetHeat.resolve(status: snapshot.status, budget: trackedBudget)
    }

    var isDown: Bool { reachability == .down }

    /// The current burn-rate scene. `forcedTier` exists for walking all eight
    /// states without waiting for a meltdown on the first of the month — the
    /// dashboard has the same escape hatch behind its `#skit=1..8` hash.
    var scene: SkitScene {
        SkitScene.resolve(
            snapshot: snapshot,
            reachability: reachability,
            now: Date(),
            meltSince: meltSince,
            forced: forcedTier
        ).scene
    }

    var forcedTier: SkitTier? {
        guard let raw = UserDefaults.standard.string(forKey: DefaultsKey.forcedTier),
              !raw.isEmpty else { return nil }
        return SkitTier(rawValue: raw)
    }

    /// Persisted so a meltdown that started before the last relaunch still
    /// reaches acceptance on schedule, mirroring the dashboard's
    /// `ccgw-melt-since` localStorage key.
    private var meltSince: Date? {
        get {
            let stamp = UserDefaults.standard.double(forKey: DefaultsKey.meltSince)
            return stamp > 0 ? Date(timeIntervalSince1970: stamp) : nil
        }
        set {
            if let newValue {
                UserDefaults.standard.set(newValue.timeIntervalSince1970, forKey: DefaultsKey.meltSince)
            } else {
                UserDefaults.standard.removeObject(forKey: DefaultsKey.meltSince)
            }
        }
    }

    var trackedBudget: Budget? {
        let preferred = UserDefaults.standard.string(forKey: DefaultsKey.trackedBudgetId)
        return snapshot.titleBudget(preferredId: (preferred?.isEmpty == false) ? preferred : nil)
    }

    /// `host:port` as configured — named in the down message so the user can see
    /// at a glance whether the app is even pointed at the right place.
    var gatewayAddress: String {
        let host = UserDefaults.standard.string(forKey: DefaultsKey.gatewayHost) ?? "127.0.0.1"
        let port = UserDefaults.standard.integer(forKey: DefaultsKey.gatewayPort)
        return "\(host.isEmpty ? "127.0.0.1" : host):\(port > 0 ? port : 8484)"
    }

    var dashboardURL: URL? {
        Derive.dashboardURL(
            host: UserDefaults.standard.string(forKey: DefaultsKey.gatewayHost) ?? "127.0.0.1",
            port: UserDefaults.standard.integer(forKey: DefaultsKey.gatewayPort)
        )
    }

    // MARK: - Lifecycle

    func start() {
        restartPolling()
    }

    private func restartPolling() {
        pollTask?.cancel()
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                await self?.refresh()
                guard let interval = self?.currentInterval else { return }
                try? await Task.sleep(for: .seconds(interval))
            }
        }
    }

    private var currentInterval: Double {
        Derive.pollInterval(
            open: panelIsOpen,
            openValue: UserDefaults.standard.double(forKey: DefaultsKey.pollOpen),
            closedValue: UserDefaults.standard.double(forKey: DefaultsKey.pollClosed),
            down: isDown
        )
    }

    /// Applies host/port changes made in Settings without a relaunch.
    func applyConnectionSettings() async {
        let host = UserDefaults.standard.string(forKey: DefaultsKey.gatewayHost) ?? "127.0.0.1"
        let port = UserDefaults.standard.integer(forKey: DefaultsKey.gatewayPort)
        await client.configure(host: host, port: port == 0 ? 8484 : port)
        await refresh()
    }

    // MARK: - Reads

    func refresh() async {
        // Status and health are fetched concurrently so one failing endpoint
        // degrades a single section rather than blanking the whole panel.
        async let statusResult = try? client.status()
        async let healthResult = try? client.health()
        let (status, health) = await (statusResult, healthResult)

        snapshot.status = status
        snapshot.health = health

        // Spend follows, because its window comes from the budget the title
        // tracks — scoping the breakdown to the same window as the budget above
        // it is what keeps the two from disagreeing. On loopback the extra
        // round trip costs microseconds.
        let window = trackedBudget?.windowSeconds ?? 86_400
        spendWindowSeconds = window
        if let spend = try? await client.spendByModel(windowSeconds: window) {
            snapshot.spend = spend
        }

        lastUpdated = Date()
        lastError = (status == nil && health == nil) ? "Gateway not responding" : nil

        if status == nil && health == nil {
            agentLoaded = await ServiceControl.isAgentLoaded()
        } else {
            agentLoaded = true
        }

        notifier.evaluate(reachability: reachability, heat: budgetHeat, budget: trackedBudget)
        advanceScene()
    }

    /// Persists the meltdown clock and starts or stops the frame timer.
    ///
    /// Called from the poll cycle rather than computed in `scene`, because
    /// resolution has to stay pure — the clock is the one piece of state the
    /// ladder carries between ticks.
    private func advanceScene() {
        let resolved = SkitScene.resolve(
            snapshot: snapshot,
            reachability: reachability,
            now: Date(),
            meltSince: meltSince,
            forced: forcedTier
        )
        meltSince = resolved.meltSince

        let animate = UserDefaults.standard.bool(forKey: DefaultsKey.animateIcon)
        if animate && resolved.scene.isAnimated {
            animator.run(interval: resolved.scene.interval)
        } else {
            animator.stop()
        }
    }

    // MARK: - Controls

    /// Graceful restart through the API when reachable; the launchd kickstart is
    /// the fallback for when it isn't (the API can't restart a dead process).
    func restart() async {
        await perform {
            if self.isDown {
                try await ServiceControl.kickstartRestart()
            } else {
                try await self.client.restart()
            }
            // The gateway drains in-flight requests before exiting, so give the
            // supervisor a moment before the first health poll.
            await self.settle(.seconds(2))
        }
    }

    func pauseEnforcement(minutes: Int) async {
        await perform { try await self.client.pauseEnforcement(minutes: minutes) }
    }

    func resumeEnforcement() async {
        await perform { try await self.client.resumeEnforcement() }
    }

    /// `minutes` nil means the budget's own window.
    func bump(budgetId: String, amountUsd: Double, minutes: Int?) async {
        await perform {
            try await self.client.bump(budgetId: budgetId, amountUsd: amountUsd, minutes: minutes)
        }
    }

    func clearBump(budgetId: String) async {
        await perform { try await self.client.clearBump(budgetId: budgetId) }
    }

    /// Budgets a bumper can actually be applied to. Excludes the overall ceiling,
    /// which the gateway rejects.
    var bumpableBudgets: [Budget] {
        Derive.bumpableBudgets(snapshot.status?.budgets ?? [])
    }

    /// One action that gets the gateway back, whatever is actually wrong.
    ///
    /// While the gateway is down Claude Code fails every request, so this is the
    /// most important button in the app — and the user shouldn't have to know
    /// whether the agent is loaded-but-wedged (needs `kickstart`) or booted out
    /// (needs `bootstrap`). It escalates, and reports what it tried if both fail.
    func recover() async {
        isBusy = true
        defer { isBusy = false }

        var attempts: [String] = []
        let loaded = await ServiceControl.isAgentLoaded()

        if loaded {
            attempts.append("kickstart")
            try? await ServiceControl.kickstartRestart()
            await settle(.seconds(2))
            await refresh()
            if !isDown { lastError = nil; return }
        }

        // Either the agent was never loaded, or kickstarting a loaded-but-broken
        // agent didn't take.
        attempts.append("bootstrap")
        do {
            try await ServiceControl.start()
        } catch {
            await refresh()
            lastError = "Recovery failed (\(attempts.joined(separator: " → "))): \(error.localizedDescription)"
            return
        }
        await settle(.seconds(3))
        await refresh()

        if isDown {
            lastError = "Tried \(attempts.joined(separator: " → ")) — still not answering. Check ~/.ccgw/logs/launchd.err.log."
        } else {
            lastError = nil
        }
    }

    /// Real stop: boots the agent out of launchd so KeepAlive cannot respawn it.
    func stopGateway() async {
        isBusy = true
        defer { isBusy = false }
        var note: String?
        var failure: String?
        do {
            note = try await ServiceControl.stop()
            await settle(.seconds(1))
        } catch {
            failure = error.localizedDescription
        }
        await refresh()
        // Surfaced after the refresh for the same reason control errors are: the
        // refresh clears lastError whenever the gateway answers.
        lastError = failure ?? note
    }

    func startGateway() async {
        await perform {
            try await ServiceControl.start()
            await self.settle(.seconds(2))
        }
    }

    func bypass() async {
        await perform { try await ServiceControl.bypass() }
    }

    func wire() async {
        await perform { try await ServiceControl.wire() }
    }

    func openDashboard() {
        guard let url = dashboardURL else { return }
        NSWorkspace.shared.open(url)
    }

    private func perform(_ work: @escaping () async throws -> Void) async {
        isBusy = true
        defer { isBusy = false }

        var actionError: String?
        do {
            try await work()
        } catch {
            actionError = error.localizedDescription
        }

        await refresh()

        // Re-assert after the refresh, which clears `lastError` whenever the
        // gateway answers. Without this the failure is wiped milliseconds after
        // it happens and the panel shows nothing — so a rejected bumper, whose
        // 400 carries the gateway's actual reason, looked like a button that
        // simply did nothing.
        if let actionError { lastError = actionError }
    }
}

/// Fires a notification the first time the tracked budget crosses its soft
/// threshold or the gateway drops, and re-arms once the condition clears — so a
/// sustained overspend notifies once rather than every poll.
@MainActor
private struct ThresholdNotifier {
    private var softFired = false
    private var downFired = false

    mutating func evaluate(reachability: Reachability, heat: BudgetHeat, budget: Budget?) {
        let defaults = UserDefaults.standard

        if reachability == .down {
            if !downFired && defaults.bool(forKey: DefaultsKey.notifyDown) {
                // Lead with the consequence: the user cares that Claude Code is
                // broken, and the gateway is only the reason why.
                Notifier.post(
                    title: "Claude Code requests are failing",
                    body: "The ccgw gateway stopped answering. Open the menu bar item to recover it, or bypass it to keep working."
                )
            }
            downFired = true
        } else {
            downFired = false
        }

        let overThreshold = heat == .soft || heat == .exhausted
        if overThreshold {
            if !softFired && defaults.bool(forKey: DefaultsKey.notifySoft), let budget {
                let title = heat == .exhausted ? "Budget exhausted" : "Budget over threshold"
                Notifier.post(
                    title: title,
                    body: "\(budget.id) \(budget.window): \(Fmt.usd(budget.spentUsd)) of \(Fmt.limit(budget.effectiveLimitUsd))"
                )
            }
            softFired = true
        } else {
            softFired = false
        }
    }
}
