import Foundation

/// Tests for the model's machine-control actions.
///
/// `recover()` had no coverage at all, while its own doc comment calls it "the
/// most important button in the app" — while the gateway is down Claude Code
/// fails every request, and this is the only surface that can fix it. Its whole
/// value is the escalation: kickstart a loaded-but-wedged agent, bootstrap one
/// that was booted out, and say what it tried when neither works. None of that
/// was asserted.
///
/// Everything here runs against a fake `ServiceControl.environment` and a zeroed
/// settle, so nothing spawns launchctl and the five seconds `recover()` really
/// waits cost nothing.
@MainActor
func runRecoveryTests() async {
    final class Spy: @unchecked Sendable {
        private let lock = NSLock()
        private var _commands: [String] = []
        var loaded = true
        var startFails = false

        var commands: [String] {
            lock.lock(); defer { lock.unlock() }
            return _commands
        }

        func run(_ path: String, _ args: [String]) -> ServiceControl.Result {
            lock.lock()
            _commands.append(([path] + args).joined(separator: " "))
            lock.unlock()
            if args.contains("print") {
                return ServiceControl.Result(exitCode: loaded ? 0 : 113, stdout: "", stderr: "")
            }
            if args.contains("bootstrap") && startFails {
                return ServiceControl.Result(
                    exitCode: 5, stdout: "", stderr: "Load failed: 5: Input/output error")
            }
            if args.contains("-t") {
                return ServiceControl.Result(exitCode: 1, stdout: "", stderr: "")
            }
            return ServiceControl.Result(exitCode: 0, stdout: "", stderr: "")
        }
    }

    /// A model whose reads either work or fail, with process control faked.
    func harness(
        reachable: Bool,
        loaded: Bool = true,
        startFails: Bool = false,
        _ body: (GatewayModel, Spy) async throws -> Void
    ) async {
        let spy = Spy()
        spy.loaded = loaded
        spy.startFails = startFails

        let transport = MockTransport()
        if reachable {
            transport.stub("/api/status", json: statusFixture)
            transport.stub("/api/health", json: healthFixture)
            transport.stub("/api/spend", json: spendFixture)
        } else {
            transport.fail("/api/status")
            transport.fail("/api/health")
            transport.fail("/api/spend")
        }

        let previous = ServiceControl.environment
        ServiceControl.environment = ServiceControl.Environment(
            run: { path, args in spy.run(path, args) },
            agentInstalled: { true },
            cliInstalled: { true },
            sleep: { _ in }
        )
        defer { ServiceControl.environment = previous }

        let model = GatewayModel(
            client: GatewayClient(transport: transport),
            settle: { _ in }
        )
        do {
            try await body(model, spy)
        } catch {
            T.fail("threw \(error)")
        }
    }

    await T.suite("a wedged but loaded agent is kickstarted first") {
        await harness(reachable: true, loaded: true) { model, spy in
            await model.recover()
            T.expect(spy.commands.contains { $0.contains("launchctl print") },
                     "it asks launchd whether the agent is loaded before deciding")
            T.expect(spy.commands.contains { $0.contains("kickstart -k") },
                     "a loaded agent is kickstarted")
            T.expect(!spy.commands.contains { $0.contains("bootstrap") },
                     "and not bootstrapped, because the kickstart worked")
            T.equal(model.lastError, nil, "a successful recovery clears the error")
        }
    }

    await T.suite("an unloaded agent skips straight to bootstrap") {
        await harness(reachable: true, loaded: false) { model, spy in
            await model.recover()
            T.expect(!spy.commands.contains { $0.contains("kickstart") },
                     "there is nothing to kickstart when the agent is not loaded")
            T.expect(spy.commands.contains { $0.contains("bootstrap") },
                     "it bootstraps instead")
            T.equal(model.lastError, nil, "and reports success")
        }
    }

    await T.suite("a kickstart that does not take escalates to bootstrap") {
        // The agent is loaded, so kickstart is tried — but the gateway still is
        // not answering afterwards, which is exactly the case the escalation
        // exists for.
        await harness(reachable: false, loaded: true) { model, spy in
            await model.recover()
            let commands = spy.commands
            guard let kick = commands.firstIndex(where: { $0.contains("kickstart") }),
                  let boot = commands.firstIndex(where: { $0.contains("bootstrap") }) else {
                T.fail("expected both a kickstart and a bootstrap, got \(commands)")
                return
            }
            T.expect(kick < boot, "kickstart is tried before bootstrap, not after")
        }
    }

    await T.suite("when everything fails, it says what it tried") {
        // The user cannot act on "recovery failed". They can act on knowing both
        // paths were attempted and where the log is.
        await harness(reachable: false, loaded: true) { model, _ in
            await model.recover()
            let message = model.lastError ?? ""
            T.expect(message.contains("kickstart"), "the message names the kickstart attempt")
            T.expect(message.contains("bootstrap"), "and the bootstrap attempt")
            T.expect(message.contains("launchd.err.log"),
                     "and points at the log that would explain why")
        }
    }

    await T.suite("a bootstrap that errors reports launchd's own reason") {
        await harness(reachable: false, loaded: false, startFails: true) { model, _ in
            await model.recover()
            let message = model.lastError ?? ""
            T.expect(message.contains("Recovery failed"), "it is reported as a failure")
            T.expect(message.contains("Input/output error"),
                     "carrying launchd's stderr rather than a bare exit code")
        }
    }

    await T.suite("stop surfaces its note after the refresh, not before") {
        // THE REGRESSION this ordering exists for: refresh() clears lastError
        // whenever the gateway answers, so a note set before the refresh vanished
        // milliseconds after appearing.
        await harness(reachable: false) { model, spy in
            await model.stopGateway()
            T.expect(spy.commands.contains { $0.contains("bootout") },
                     "stopping boots the agent out of launchd")
            T.expect(!model.isBusy, "the busy flag is cleared afterwards")
        }
    }

    await T.suite("a failed stop leaves its error visible") {
        let spy = Spy()
        let transport = MockTransport()
        transport.stub("/api/status", json: statusFixture)
        transport.stub("/api/health", json: healthFixture)
        transport.stub("/api/spend", json: spendFixture)

        let previous = ServiceControl.environment
        ServiceControl.environment = ServiceControl.Environment(
            run: { path, args in
                _ = spy.run(path, args)
                if args.contains("bootout") {
                    return ServiceControl.Result(
                        exitCode: 5, stdout: "", stderr: "Boot-out failed: 5: Input/output error")
                }
                return ServiceControl.Result(exitCode: 0, stdout: "", stderr: "")
            },
            agentInstalled: { true }, cliInstalled: { true }, sleep: { _ in }
        )
        defer { ServiceControl.environment = previous }

        let model = GatewayModel(client: GatewayClient(transport: transport), settle: { _ in })
        await model.stopGateway()
        // The gateway still answers here, so refresh() clears errors — the note
        // has to be reapplied after it or this is nil.
        T.expect(model.lastError?.contains("Input/output error") == true,
                 "the failure survives the refresh that follows it")
    }

    await T.suite("start, bypass and wire each run their one command") {
        await harness(reachable: true) { model, spy in
            await model.startGateway()
            T.expect(spy.commands.contains { $0.contains("bootstrap") }, "start bootstraps")
        }
        await harness(reachable: true) { model, spy in
            await model.bypass()
            T.expect(spy.commands.contains { $0.contains("ccgw bypass") },
                     "bypass shells out to the CLI")
        }
        await harness(reachable: true) { model, spy in
            await model.wire()
            T.expect(spy.commands.contains { $0.contains("ccgw wire") },
                     "wire is the exact inverse")
        }
    }

    await T.suite("restart takes the API path when up and launchctl when down") {
        await harness(reachable: true) { model, spy in
            await model.restart()
            T.expect(!spy.commands.contains { $0.contains("kickstart") },
                     "a reachable gateway is restarted over HTTP, which drains in flight requests")
        }
        await harness(reachable: false) { model, spy in
            // A refresh has to have happened first. `reachability` reports
            // .unknown rather than .down until lastUpdated is set, precisely so
            // the panel does not accuse the gateway of being dead before it has
            // ever been asked — which also means restart() would take the API
            // path on a model that has never polled.
            await model.refresh()
            T.expect(model.isDown, "the model is genuinely down before restarting")
            await model.restart()
            T.expect(spy.commands.contains { $0.contains("kickstart -k") },
                     "a dead gateway cannot answer an HTTP restart, so launchctl does it")
        }
    }
}
