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

    private let client = GatewayClient()
    private var pollTask: Task<Void, Never>?
    private var notifier = ThresholdNotifier()

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
        guard let status = snapshot.status, let budget = trackedBudget else { return .normal }
        if budget.exhausted { return .exhausted }
        if budget.soft || budget.pct >= status.softThresholdPct { return .soft }
        return .normal
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

    var dashboardURL: URL? {
        let host = UserDefaults.standard.string(forKey: DefaultsKey.gatewayHost) ?? "127.0.0.1"
        let port = UserDefaults.standard.integer(forKey: DefaultsKey.gatewayPort)
        return URL(string: "http://\(host):\(port == 0 ? 8484 : port)/dash")
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
        let key = panelIsOpen ? DefaultsKey.pollOpen : DefaultsKey.pollClosed
        let value = UserDefaults.standard.double(forKey: key)
        return value > 0 ? value : (panelIsOpen ? 5 : 30)
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
            try? await Task.sleep(for: .seconds(2))
        }
    }

    func pauseEnforcement(minutes: Int) async {
        await perform { try await self.client.pauseEnforcement(minutes: minutes) }
    }

    func resumeEnforcement() async {
        await perform { try await self.client.resumeEnforcement() }
    }

    /// Real stop: boots the agent out of launchd so KeepAlive cannot respawn it.
    func stopGateway() async {
        await perform {
            try await ServiceControl.stop()
            try? await Task.sleep(for: .seconds(1))
        }
    }

    func startGateway() async {
        await perform {
            try await ServiceControl.start()
            try? await Task.sleep(for: .seconds(2))
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
        do {
            try await work()
            lastError = nil
        } catch {
            lastError = error.localizedDescription
        }
        await refresh()
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
                Notifier.post(title: "ccgw is not responding",
                              body: "Claude Code requests will fail until it is back.")
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
