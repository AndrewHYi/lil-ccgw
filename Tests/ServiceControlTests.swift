import Foundation

/// Tests for the process-control layer, driven through `ServiceControl.environment`.
///
/// These deliberately do *not* spawn `launchctl`, `lsof` or `/bin/kill`. The
/// `testing-lil-ccgw` skill's rule stands: the suite must stay runnable with the
/// gateway stopped, and a test that boots the agent out of launchd would break
/// the machine it runs on.
///
/// What is asserted is the logic that used to be unreachable behind a
/// `private static` wrapping `Process`, all of which has bug history:
///
/// * `bootout` exits 3 when the agent was not loaded, which is a fine starting
///   point rather than a failure. Treating it as an error made Stop look broken.
/// * A gateway process can outlive its agent, so stop unloads *then* kills, in
///   that order — killing first just invites KeepAlive to respawn it.
/// * `lsof -t` output has to be parsed to a pid.
/// * Every command that fails has to produce a message a user can act on.
///
/// It also asserts the commands themselves, not just the outcomes. A stop that
/// silently ran the wrong launchctl subcommand would pass an outcome-only test.
func runServiceControlTests() async {
    /// Records every spawn and answers from a script keyed by the first argument.
    final class FakeProcesses: @unchecked Sendable {
        private let lock = NSLock()
        private var _calls: [(path: String, args: [String])] = []
        private var results: [String: ServiceControl.Result] = [:]
        private var fallback = ServiceControl.Result(exitCode: 0, stdout: "", stderr: "")

        var calls: [(path: String, args: [String])] {
            lock.lock(); defer { lock.unlock() }
            return _calls
        }

        var commands: [String] { calls.map { ([$0.path] + $0.args).joined(separator: " ") } }

        func on(_ subcommand: String, exit code: Int32, stdout: String = "", stderr: String = "") {
            lock.lock(); defer { lock.unlock() }
            results[subcommand] = ServiceControl.Result(
                exitCode: code, stdout: stdout, stderr: stderr)
        }

        func setFallback(exit code: Int32, stdout: String = "", stderr: String = "") {
            lock.lock(); defer { lock.unlock() }
            fallback = ServiceControl.Result(exitCode: code, stdout: stdout, stderr: stderr)
        }

        func run(_ path: String, _ args: [String]) -> ServiceControl.Result {
            lock.lock(); defer { lock.unlock() }
            _calls.append((path, args))
            // Keyed on the subcommand (`bootout`, `bootstrap`, …) or the binary's
            // own name for the ccgw CLI, so a test can script one step at a time.
            for (key, result) in results {
                if args.contains(key) || path.hasSuffix(key) { return result }
            }
            return fallback
        }
    }

    /// Installs a fake environment, runs the body, and always restores the live
    /// one — a leaked fake would make later suites spawn nothing, or worse, make
    /// a real one spawn launchctl.
    func withFake(
        agentInstalled: Bool = true,
        cliInstalled: Bool = true,
        _ body: (FakeProcesses) async throws -> Void
    ) async {
        let fake = FakeProcesses()
        let previous = ServiceControl.environment
        ServiceControl.environment = ServiceControl.Environment(
            run: { path, args in fake.run(path, args) },
            agentInstalled: { agentInstalled },
            cliInstalled: { cliInstalled },
            sleep: { _ in }
        )
        defer { ServiceControl.environment = previous }
        do {
            try await body(fake)
        } catch {
            T.fail("threw \(error)")
        }
    }

    T.suite("paths and launchd targets") {
        T.equal(ServiceControl.label, "io.ccgw.gateway", "agent label matches the installed plist")
        T.expect(ServiceControl.ccgwBinary.path.hasSuffix("/.ccgw/bin/ccgw"),
                 "the CLI is addressed by absolute path under ~/.ccgw, not via PATH")
        T.expect(ServiceControl.plistPath.path.hasSuffix("Library/LaunchAgents/io.ccgw.gateway.plist"),
                 "the agent plist is in the user's LaunchAgents")
        T.expect(ServiceControl.serviceTarget.hasSuffix("/io.ccgw.gateway"),
                 "the service target names the label")
        T.expect(ServiceControl.domainTarget.hasPrefix("gui/"),
                 "the domain target is the per-user GUI domain")
    }

    await T.suite("a loaded agent is detected by launchctl print") {
        await withFake { fake in
            fake.on("print", exit: 0)
            let loaded = await ServiceControl.isAgentLoaded()
            T.expect(loaded, "exit 0 from launchctl print means loaded")
            T.expect(fake.commands.first?.contains("launchctl print") == true,
                     "asks launchctl to print the service target")
        }
        await withFake { fake in
            fake.on("print", exit: 113)
            let loaded = await ServiceControl.isAgentLoaded()
            T.expect(!loaded, "a non-zero exit means not loaded")
        }
    }

    await T.suite("the listening pid is parsed out of lsof") {
        await withFake { fake in
            // lsof -t prints one pid per line, and can print several.
            fake.on("-t", exit: 0, stdout: "4821\n4822\n")
            let pid = await ServiceControl.listeningPID(port: 8484)
            T.equal(pid, 4821, "the first pid is taken")
            T.expect(fake.commands.first?.contains("-iTCP:8484") == true,
                     "asks about the configured port")
        }
        await withFake { fake in
            fake.on("-t", exit: 1, stdout: "")
            let pid = await ServiceControl.listeningPID(port: 8484)
            T.equal(pid, nil, "a non-zero lsof exit means nothing is listening")
        }
        await withFake { fake in
            // Whitespace and blank lines are real: lsof pads its output.
            fake.on("-t", exit: 0, stdout: "\n  4823  \n")
            let pid = await ServiceControl.listeningPID(port: 8484)
            T.equal(pid, 4823, "surrounding whitespace is trimmed")
        }
    }

    await T.suite("stop unloads the agent before killing anything") {
        await withFake { fake in
            fake.on("bootout", exit: 0)
            fake.on("-t", exit: 1)  // nothing left listening
            let note = try await ServiceControl.stop()
            T.equal(note, nil, "a clean unload needs no explanation")
            let commands = fake.commands
            T.expect(commands.first?.contains("bootout") == true,
                     "bootout comes first — killing before unloading invites a respawn")
            T.expect(!commands.contains { $0.contains("/bin/kill") },
                     "nothing is killed when nothing survived the unload")
        }
    }

    await T.suite("bootout exiting 3 is not a failure") {
        // THE REGRESSION. `launchctl bootout` exits 3 and does nothing when the
        // agent was never loaded. Treating that as an error made Stop report a
        // failure in the one case where there was nothing to do.
        await withFake { fake in
            fake.on("bootout", exit: 3, stderr: "Boot-out failed: 3: No such process")
            fake.on("-t", exit: 1)
            let note = try await ServiceControl.stop()
            T.equal(note, nil, "exit 3 with nothing listening is a successful stop")
        }
    }

    await T.suite("an orphaned listener is terminated after the unload") {
        // A gateway process can outlive its agent — started by hand, or orphaned
        // by an earlier bootout. Nothing can respawn it once the agent is gone,
        // so terminating is safe and is what the user asked for.
        final class Box: @unchecked Sendable { var killed = false }
        let box = Box()
        await withFake { fake in
            fake.on("bootout", exit: 3)
            fake.setFallback(exit: 0, stdout: "")
            // Listening before the kill, gone after it.
            fake.on("-t", exit: 0, stdout: "9001\n")
            _ = try? await ServiceControl.stop()
            box.killed = fake.commands.contains { $0.contains("/bin/kill 9001") }
        }
        T.expect(box.killed, "the surviving pid is terminated by number")
    }

    await T.suite("a listener that will not die is reported, not swallowed") {
        await withFake { fake in
            fake.on("bootout", exit: 0)
            // Still listening even after the kill.
            fake.on("-t", exit: 0, stdout: "9002\n")
            await T.expectThrows("stop throws when the port keeps answering") {
                try await ServiceControl.stop()
            }
        }
    }

    await T.suite("a genuine bootout failure throws with launchctl's own words") {
        await withFake { fake in
            fake.on("bootout", exit: 5, stderr: "Boot-out failed: 5: Input/output error")
            do {
                _ = try await ServiceControl.stop()
                T.fail("expected a throw on a real bootout failure")
            } catch {
                let message = (error as? ServiceControl.ServiceError)?.errorDescription ?? "\(error)"
                T.expect(message.contains("Input/output error"),
                         "the error carries launchctl's stderr, not a generic code")
            }
        }
        await withFake { fake in
            // Nothing on either stream — the message has to fall back to the code
            // rather than being empty.
            fake.on("bootout", exit: 5)
            do {
                _ = try await ServiceControl.stop()
                T.fail("expected a throw")
            } catch {
                let message = (error as? ServiceControl.ServiceError)?.errorDescription ?? "\(error)"
                T.expect(message.contains("5"), "a silent failure still names the exit code")
            }
        }
    }

    await T.suite("start bootstraps the agent, and says so when it is missing") {
        await withFake { fake in
            try await ServiceControl.start()
            T.expect(fake.commands.first?.contains("bootstrap") == true,
                     "start bootstraps rather than kickstarting")
            T.expect(fake.commands.first?.contains("io.ccgw.gateway.plist") == true,
                     "bootstrap is given the plist path")
        }
        await withFake(agentInstalled: false) { fake in
            await T.expectThrows("start throws when no agent is installed") {
                try await ServiceControl.start()
            }
            T.expect(fake.calls.isEmpty, "it fails before spawning anything")
        }
    }

    await T.suite("kickstart is the abrupt restart") {
        await withFake { fake in
            try await ServiceControl.kickstartRestart()
            T.expect(fake.commands.first?.contains("kickstart -k") == true,
                     "kickstart -k is the fallback when the HTTP API cannot answer")
        }
    }

    await T.suite("bypass and wire go through the ccgw CLI") {
        await withFake { fake in
            try await ServiceControl.bypass()
            T.expect(fake.commands.first?.contains("/.ccgw/bin/ccgw bypass") == true,
                     "bypass shells out to the CLI by absolute path")
        }
        await withFake { fake in
            try await ServiceControl.wire()
            T.expect(fake.commands.first?.contains("/.ccgw/bin/ccgw wire") == true,
                     "wire is the exact inverse command")
        }
        await withFake(cliInstalled: false) { fake in
            await T.expectThrows("bypass throws when the CLI is absent") {
                try await ServiceControl.bypass()
            }
            T.expect(fake.calls.isEmpty, "it fails before spawning anything")
        }
        await withFake { fake in
            fake.setFallback(exit: 1, stderr: "no settings.json found")
            do {
                try await ServiceControl.wire()
                T.fail("expected a throw when the CLI fails")
            } catch {
                let message = (error as? ServiceControl.ServiceError)?.errorDescription ?? "\(error)"
                T.expect(message.contains("settings.json"),
                         "the CLI's own message reaches the UI")
            }
        }
    }
}
