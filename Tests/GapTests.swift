import Foundation

/// The last reachable gaps, gathered once coverage measurement made them visible.
///
/// None of these is interesting on its own. They are here because a per-file
/// coverage floor only protects what has been reached at least once, and each of
/// these was a line nothing executed — which is exactly how a typo in a rarely-hit
/// branch ships.
@MainActor
func runGapTests() async {
    T.suite("panel sections are identifiable by their own raw value") {
        // Used as ForEach identity in Settings; a collision would silently make
        // two toggles share state.
        let ids = PanelSection.allCases.map(\.id)
        T.equal(Set(ids).count, PanelSection.allCases.count, "every section id is distinct")
        for section in PanelSection.allCases {
            T.equal(section.id, section.rawValue, "\(section.rawValue) is identified by its raw value")
        }
    }

    await T.suite("reconfiguring the client changes where requests go") {
        // applyConnectionSettings exists so a host/port change in Settings takes
        // effect without a relaunch. Nothing exercised the configure call itself.
        let transport = MockTransport.healthy()
        let client = GatewayClient(transport: transport, token: { nil })
        await client.configure(host: "127.0.0.1", port: 9999)
        let model = GatewayModel(client: client, settle: { _ in })
        await model.refresh()
        T.expect(transport.urls.allSatisfy { $0.contains(":9999") },
                 "requests follow the reconfigured port")
        T.expect(transport.urls.allSatisfy { $0.contains("127.0.0.1") },
                 "and stay on the loopback literal, never localhost")
    }

    T.suite("the dashboard URL follows the configured address") {
        UserDefaults.standard.set("127.0.0.1", forKey: DefaultsKey.gatewayHost)
        UserDefaults.standard.set(8484, forKey: DefaultsKey.gatewayPort)
        let model = GatewayModel(client: GatewayClient(transport: MockTransport.healthy()))
        T.equal(model.dashboardURL?.absoluteString, "http://127.0.0.1:8484/dash",
                "the dashboard is the configured address plus /dash")

        UserDefaults.standard.set(9100, forKey: DefaultsKey.gatewayPort)
        T.equal(model.dashboardURL?.absoluteString, "http://127.0.0.1:9100/dash",
                "a moved gateway moves its dashboard")
        UserDefaults.standard.set(8484, forKey: DefaultsKey.gatewayPort)
    }

    await T.suite("polling starts on demand and refreshes at least once") {
        let transport = MockTransport.healthy()
        let model = GatewayModel(client: GatewayClient(transport: transport, token: { nil }),
                                 settle: { _ in })
        model.start()
        // start() spawns the poll loop; give it one turn to issue its first read.
        for _ in 0..<50 where transport.callCount("/api/status") == 0 {
            await Task.yield()
        }
        T.expect(transport.callCount("/api/status") >= 1,
                 "start() polls rather than waiting for the first interval to elapse")
    }

    T.suite("the live process environment is wired to the real system") {
        // The default Environment's closures had never been evaluated, so a typo
        // in one would only have surfaced in the shipped app.
        let live = ServiceControl.Environment.live
        _ = live.agentInstalled()
        _ = live.cliInstalled()
        T.expect(true, "the live environment's probes evaluate without trapping")
    }

    T.suite("the real transport can be constructed") {
        // Its init configures an ephemeral session with a short timeout. Nothing
        // built one, because every test injects a mock.
        _ = URLSessionTransport()
        _ = URLSessionTransport(timeout: 1)
        T.expect(true, "URLSessionTransport initialises with and without a timeout")
    }

    await T.suite("stop explains itself when it had to kill an orphan") {
        // The success path that returns a note, as opposed to the nil-note clean
        // unload already covered. The distinction matters: this note is the only
        // way the user learns an unmanaged process was terminated.
        final class Fake: @unchecked Sendable {
            let lock = NSLock()
            var lsofCalls = 0
            func run(_ path: String, _ args: [String]) -> ServiceControl.Result {
                if args.contains("bootout") {
                    return ServiceControl.Result(exitCode: 0, stdout: "", stderr: "")
                }
                if args.contains("-t") {
                    lock.lock(); lsofCalls += 1; let n = lsofCalls; lock.unlock()
                    // Listening on the first check, gone after the kill.
                    return n == 1
                        ? ServiceControl.Result(exitCode: 0, stdout: "7777\n", stderr: "")
                        : ServiceControl.Result(exitCode: 1, stdout: "", stderr: "")
                }
                return ServiceControl.Result(exitCode: 0, stdout: "", stderr: "")
            }
        }
        let fake = Fake()
        let previous = ServiceControl.environment
        ServiceControl.environment = ServiceControl.Environment(
            run: { path, args in fake.run(path, args) },
            agentInstalled: { true }, cliInstalled: { true }, sleep: { _ in })
        defer { ServiceControl.environment = previous }

        let note = try? await ServiceControl.stop()
        T.expect(note?.contains("7777") == true, "the note names the pid it terminated")
        T.expect(note?.contains("unmanaged") == true,
                 "and says it was unmanaged, which is why killing it was safe")
    }

    await T.suite("an unusable host is a throw, not a crash") {
        // url(_:) throws when the interpolation cannot make a URL. Unreachable in
        // practice, but it is the guard standing between a bad stored host and a
        // force-unwrap.
        let transport = MockTransport.healthy()
        let client = GatewayClient(transport: transport, token: { nil })
        await client.configure(host: "a b\u{7F}c", port: -1)
        let model = GatewayModel(client: client, settle: { _ in })
        await model.refresh()
        T.expect(model.lastError != nil || transport.requests.isEmpty,
                 "a host that cannot form a URL surfaces an error instead of trapping")
    }
}
