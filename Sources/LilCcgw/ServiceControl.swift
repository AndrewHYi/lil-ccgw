import Foundation

/// Process-level control of the gateway: launchd for lifecycle, the ccgw CLI
/// for wiring.
///
/// The important thing this type exists to get right: **`ccgw stop` does not
/// stop the gateway on a managed install.** It sends SIGTERM to the pid, and
/// the LaunchAgent sets `KeepAlive=true`, so launchd respawns within about a
/// second — a Stop button wired to the CLI looks broken. A real stop has to
/// `bootout` the agent, which unloads it as well as killing it. The cost is
/// that the gateway then stays down across login until `start()` bootstraps it
/// again, which is why the UI confirms first.
enum ServiceControl {
    static let label = "io.ccgw.gateway"

    /// Not on PATH — the setup skill installs it under ~/.ccgw, so every
    /// invocation uses the absolute path.
    static var ccgwBinary: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".ccgw/bin/ccgw")
    }

    static var plistPath: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/LaunchAgents/\(label).plist")
    }

    static var domainTarget: String { Derive.domainTarget(uid: getuid()) }
    static var serviceTarget: String { Derive.serviceTarget(uid: getuid(), label: label) }

    static var isAgentInstalled: Bool {
        FileManager.default.fileExists(atPath: plistPath.path)
    }

    static var isCLIInstalled: Bool {
        FileManager.default.isExecutableFile(atPath: ccgwBinary.path)
    }

    /// Whether launchd currently has the agent loaded. Distinct from "the HTTP
    /// port answers" — the agent can be loaded while the process is still
    /// starting up.
    static func isAgentLoaded() async -> Bool {
        let result = await run("/bin/launchctl", ["print", serviceTarget])
        return result.exitCode == 0
    }

    /// Real stop, in two steps because one is not enough.
    ///
    /// `launchctl bootout` unloads the agent so `KeepAlive` can't respawn, but it
    /// **exits 3 and does nothing** when the agent isn't loaded — and a gateway
    /// process can outlive its agent (started by hand, or orphaned by an earlier
    /// bootout). Verified: with the agent unloaded and a process still serving,
    /// `bootout` reports "No such process" while the port keeps answering, and
    /// `ccgw stop` can't help either because its pidfile is gone.
    ///
    /// So: unload first, then terminate whatever is still listening. Order
    /// matters — killing before unloading just invites KeepAlive to respawn it.
    ///
    /// Returns a note when it had to fall back to killing the listener, so the
    /// UI can say what actually happened.
    @discardableResult
    static func stop() async throws -> String? {
        let bootout = await run("/bin/launchctl", ["bootout", serviceTarget])
        // Exit 3 is "no such process" — the agent simply wasn't loaded, which is
        // a fine starting point, not a failure.
        if bootout.exitCode != 0 && bootout.exitCode != 3 {
            let detail = bootout.stderr.isEmpty ? bootout.stdout : bootout.stderr
            throw ServiceError.message(
                detail.isEmpty ? "launchctl bootout exited \(bootout.exitCode)"
                               : detail.trimmingCharacters(in: .whitespacesAndNewlines))
        }

        try? await Task.sleep(for: .milliseconds(700))
        guard let pid = await listeningPID() else { return nil }

        // Something is still serving with no agent behind it. Nothing can respawn
        // it now, so terminating is safe and is what the user asked for.
        _ = await run("/bin/kill", [String(pid)])
        try? await Task.sleep(for: .milliseconds(700))
        if let survivor = await listeningPID() {
            throw ServiceError.message(
                "Agent unloaded, but pid \(survivor) is still serving the port and would not terminate.")
        }
        return "The agent was unloaded and an unmanaged process (pid \(pid)) was terminated."
    }

    /// PID listening on the configured gateway port, if any.
    ///
    /// Used to tell "the gateway is stopped" apart from "the agent is gone but
    /// something is still answering", which are different problems with different
    /// fixes.
    static func listeningPID(port: Int? = nil) async -> Int32? {
        let resolved = port ?? {
            let p = UserDefaults.standard.integer(forKey: DefaultsKey.gatewayPort)
            return p > 0 ? p : 8484
        }()
        let result = await run("/usr/sbin/lsof",
                              ["-nP", "-iTCP:\(resolved)", "-sTCP:LISTEN", "-t"])
        guard result.exitCode == 0 else { return nil }
        return result.stdout
            .split(whereSeparator: \.isNewline)
            .compactMap { Int32($0.trimmingCharacters(in: .whitespaces)) }
            .first
    }

    static func start() async throws {
        guard isAgentInstalled else {
            throw ServiceError.message("No LaunchAgent at \(plistPath.path). Run `ccgw service install` first.")
        }
        try await runOrThrow("/bin/launchctl", ["bootstrap", domainTarget, plistPath.path])
    }

    /// Fallback restart for when the HTTP API is unreachable. The graceful path
    /// is POST /api/restart, which drains in-flight requests first; this one is
    /// abrupt.
    static func kickstartRestart() async throws {
        try await runOrThrow("/bin/launchctl", ["kickstart", "-k", serviceTarget])
    }

    /// Unwire ANTHROPIC_BASE_URL from Claude Code's settings.json so sessions
    /// go direct to the API. Takes effect on the next Claude Code start, not
    /// immediately — the UI says so before running it.
    static func bypass() async throws {
        try await runCcgw(["bypass"])
    }

    static func wire() async throws {
        try await runCcgw(["wire"])
    }

    private static func runCcgw(_ args: [String]) async throws {
        guard isCLIInstalled else {
            throw ServiceError.message("ccgw CLI not found at \(ccgwBinary.path)")
        }
        try await runOrThrow(ccgwBinary.path, args)
    }

    // MARK: - Process plumbing

    struct Result {
        let exitCode: Int32
        let stdout: String
        let stderr: String
    }

    enum ServiceError: LocalizedError {
        case message(String)
        var errorDescription: String? {
            switch self { case let .message(text): return text }
        }
    }

    @discardableResult
    private static func runOrThrow(_ launchPath: String, _ args: [String]) async throws -> Result {
        let result = await run(launchPath, args)
        guard result.exitCode == 0 else {
            let detail = result.stderr.isEmpty ? result.stdout : result.stderr
            let command = ([launchPath] + args).joined(separator: " ")
            throw ServiceError.message(
                detail.isEmpty
                    ? "`\(command)` exited \(result.exitCode)"
                    : detail.trimmingCharacters(in: .whitespacesAndNewlines)
            )
        }
        return result
    }

    /// Runs off the main actor so a hung launchctl can never freeze the menu.
    private static func run(_ launchPath: String, _ args: [String]) async -> Result {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let process = Process()
                process.executableURL = URL(fileURLWithPath: launchPath)
                process.arguments = args
                let out = Pipe()
                let err = Pipe()
                process.standardOutput = out
                process.standardError = err
                do {
                    try process.run()
                } catch {
                    continuation.resume(returning: Result(
                        exitCode: -1, stdout: "", stderr: error.localizedDescription
                    ))
                    return
                }
                let outData = out.fileHandleForReading.readDataToEndOfFile()
                let errData = err.fileHandleForReading.readDataToEndOfFile()
                process.waitUntilExit()
                continuation.resume(returning: Result(
                    exitCode: process.terminationStatus,
                    stdout: String(data: outData, encoding: .utf8) ?? "",
                    stderr: String(data: errData, encoding: .utf8) ?? ""
                ))
            }
        }
    }
}
