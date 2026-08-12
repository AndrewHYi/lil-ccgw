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

    /// Real stop: kills the process *and* unloads the agent so KeepAlive can't
    /// resurrect it.
    static func stop() async throws {
        try await runOrThrow("/bin/launchctl", ["bootout", serviceTarget])
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
