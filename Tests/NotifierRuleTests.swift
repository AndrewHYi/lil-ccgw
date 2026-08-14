import Foundation

/// Tests for the threshold notifier's fire-once-and-re-arm rule.
///
/// `ModelTests` claimed to cover this. It did not — there was no assertion about
/// the notifier anywhere in the suite. The state machine ran on every refresh and
/// its decisions went unobserved, because `Notifier.post` is a no-op in this
/// binary (no bundle identifier), so a version that notified on every single poll
/// would have looked identical from outside.
///
/// That is the bug worth guarding: a sustained overspend polls every few seconds,
/// and notifying each time would make the app unusable.
@MainActor
func runNotifierRuleTests() {
    func budget(soft: Bool, exhausted: Bool = false) -> Budget {
        let json = """
        {"id":"session","scope":"global","window":"5h",
         "effective_limit_usd":75,"spent_usd":70,"remaining_usd":5,
         "pct":93,"action":"block","exhausted":\(exhausted),"soft":\(soft),
         "burn_rate_hr":null,"sustainable_hr":null,"pace":null,
         "bump_usd":null,"bump_expires_at":null}
        """
        return try! decodeFixture(Budget.self, json)
    }

    /// Both notification preferences on, which is the registered default.
    func enableNotifications() {
        UserDefaults.standard.set(true, forKey: DefaultsKey.notifyDown)
        UserDefaults.standard.set(true, forKey: DefaultsKey.notifySoft)
    }

    T.suite("a sustained outage notifies once, not once per poll") {
        enableNotifications()
        var notifier = ThresholdNotifier()
        let first = notifier.evaluate(reachability: .down, heat: .normal, budget: nil)
        T.equal(first.count, 1, "the first poll after going down notifies")
        T.expect(first.first?.title.contains("Claude Code") == true,
                 "it leads with the consequence, not with the gateway")

        for poll in 2...10 {
            let again = notifier.evaluate(reachability: .down, heat: .normal, budget: nil)
            T.equal(again.count, 0, "poll \(poll) of the same outage stays quiet")
        }
    }

    T.suite("recovery re-arms the outage notification") {
        enableNotifications()
        var notifier = ThresholdNotifier()
        _ = notifier.evaluate(reachability: .down, heat: .normal, budget: nil)
        _ = notifier.evaluate(reachability: .live, heat: .normal, budget: nil)
        let second = notifier.evaluate(reachability: .down, heat: .normal, budget: nil)
        T.equal(second.count, 1, "a second, separate outage notifies again")
    }

    T.suite("crossing the soft threshold notifies once") {
        enableNotifications()
        var notifier = ThresholdNotifier()
        let crossed = notifier.evaluate(
            reachability: .live, heat: .soft, budget: budget(soft: true))
        T.equal(crossed.count, 1, "the crossing notifies")
        T.expect(crossed.first?.title.contains("threshold") == true,
                 "and says it is a threshold, not an exhaustion")
        T.expect(crossed.first?.body.contains("session") == true,
                 "naming the budget, so a multi-budget setup is diagnosable")

        let held = notifier.evaluate(
            reachability: .live, heat: .soft, budget: budget(soft: true))
        T.equal(held.count, 0, "staying over the threshold does not notify again")
    }

    T.suite("exhaustion is titled differently from a soft crossing") {
        enableNotifications()
        var notifier = ThresholdNotifier()
        let posts = notifier.evaluate(
            reachability: .live, heat: .exhausted, budget: budget(soft: true, exhausted: true))
        T.equal(posts.count, 1, "exhaustion notifies")
        T.expect(posts.first?.title.contains("exhausted") == true,
                 "exhausted is a different message from over-threshold")
    }

    T.suite("dropping back under the threshold re-arms it") {
        enableNotifications()
        var notifier = ThresholdNotifier()
        _ = notifier.evaluate(reachability: .live, heat: .soft, budget: budget(soft: true))
        // A rolling window can genuinely fall back under as old spend ages out.
        _ = notifier.evaluate(reachability: .live, heat: .normal, budget: budget(soft: false))
        let again = notifier.evaluate(
            reachability: .live, heat: .soft, budget: budget(soft: true))
        T.equal(again.count, 1, "crossing again after recovering notifies again")
    }

    T.suite("both conditions at once produce both notifications") {
        enableNotifications()
        var notifier = ThresholdNotifier()
        let posts = notifier.evaluate(
            reachability: .down, heat: .exhausted, budget: budget(soft: true, exhausted: true))
        T.equal(posts.count, 2, "a down gateway with an exhausted budget notifies about both")
    }

    T.suite("the preferences actually suppress") {
        UserDefaults.standard.set(false, forKey: DefaultsKey.notifyDown)
        UserDefaults.standard.set(false, forKey: DefaultsKey.notifySoft)
        var notifier = ThresholdNotifier()
        let posts = notifier.evaluate(
            reachability: .down, heat: .exhausted, budget: budget(soft: true, exhausted: true))
        T.equal(posts.count, 0, "both toggles off means silence")

        // The flag must gate the notification without breaking the re-arm state,
        // or turning alerts back on would stay silent until the next recovery.
        UserDefaults.standard.set(true, forKey: DefaultsKey.notifyDown)
        let afterEnabling = notifier.evaluate(reachability: .down, heat: .normal, budget: nil)
        T.equal(afterEnabling.count, 0,
                "still quiet while the same outage continues — the condition already fired")
        enableNotifications()
    }

    T.suite("a soft crossing with no tracked budget stays quiet") {
        // The body names the budget, so there is nothing to say without one.
        enableNotifications()
        var notifier = ThresholdNotifier()
        let posts = notifier.evaluate(reachability: .live, heat: .soft, budget: nil)
        T.equal(posts.count, 0, "no budget means no message")
    }
}
