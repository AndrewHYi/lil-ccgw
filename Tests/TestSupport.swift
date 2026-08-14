import Foundation

/// A minimal assertion harness.
///
/// Not XCTest and not swift-testing, for the same reason there is no
/// Package.swift: SwiftPM cannot run on a Command Line Tools-only host (see
/// CLAUDE.md), and both test frameworks reach for it or for xcodebuild. This is
/// ~40 lines, runs under plain `swiftc`, and reports failures with file and line
/// like a real framework would.
enum T {
    nonisolated(unsafe) static var passed = 0
    nonisolated(unsafe) static var failures: [String] = []
    nonisolated(unsafe) static var currentSuite = ""

    static func suite(_ name: String, _ body: () throws -> Void) {
        currentSuite = name
        do {
            try body()
        } catch {
            failures.append("\(name): threw \(error)")
        }
    }

    static func expect(
        _ condition: Bool,
        _ message: String,
        file: StaticString = #file,
        line: UInt = #line
    ) {
        if condition {
            passed += 1
        } else {
            failures.append("\(currentSuite): \(message)  (\(shortFile(file)):\(line))")
        }
    }

    static func equal<V: Equatable>(
        _ actual: V,
        _ expected: V,
        _ label: String,
        file: StaticString = #file,
        line: UInt = #line
    ) {
        if actual == expected {
            passed += 1
        } else {
            failures.append(
                "\(currentSuite): \(label) — expected \(expected), got \(actual)  (\(shortFile(file)):\(line))"
            )
        }
    }

    static func close(
        _ actual: Double,
        _ expected: Double,
        _ label: String,
        tolerance: Double = 0.0001,
        file: StaticString = #file,
        line: UInt = #line
    ) {
        if abs(actual - expected) <= tolerance {
            passed += 1
        } else {
            failures.append(
                "\(currentSuite): \(label) — expected \(expected), got \(actual)  (\(shortFile(file)):\(line))"
            )
        }
    }

    /// Async counterpart to `suite`. The sync one takes `() throws -> Void`, so
    /// async suites used to set `currentSuite` by hand and lost the
    /// throw-is-reported-not-fatal behaviour with it.
    static func suite(_ name: String, _ body: () async throws -> Void) async {
        currentSuite = name
        do {
            try await body()
        } catch {
            failures.append("\(name): threw \(error)")
        }
    }

    /// Asserts that `body` throws, and optionally that it throws a particular
    /// error. Without this the only way to test a throwing path was a hand-rolled
    /// do/catch plus `expect(false, …)` in the success branch, which is easy to
    /// write in a way that passes when nothing throws at all.
    static func expectThrows<V>(
        _ label: String,
        _ expected: (any Error)? = nil,
        file: StaticString = #file,
        line: UInt = #line,
        _ body: () throws -> V
    ) {
        do {
            _ = try body()
            failures.append(
                "\(currentSuite): \(label) — expected a throw, returned normally  (\(shortFile(file)):\(line))"
            )
        } catch {
            guard let expected else { passed += 1; return }
            if "\(error)" == "\(expected)" {
                passed += 1
            } else {
                failures.append(
                    "\(currentSuite): \(label) — expected \(expected), threw \(error)  (\(shortFile(file)):\(line))"
                )
            }
        }
    }

    /// Async form of `expectThrows`.
    static func expectThrows<V>(
        _ label: String,
        _ expected: (any Error)? = nil,
        file: StaticString = #file,
        line: UInt = #line,
        _ body: () async throws -> V
    ) async {
        do {
            _ = try await body()
            failures.append(
                "\(currentSuite): \(label) — expected a throw, returned normally  (\(shortFile(file)):\(line))"
            )
        } catch {
            guard let expected else { passed += 1; return }
            if "\(error)" == "\(expected)" {
                passed += 1
            } else {
                failures.append(
                    "\(currentSuite): \(label) — expected \(expected), threw \(error)  (\(shortFile(file)):\(line))"
                )
            }
        }
    }

    /// Fails unconditionally. `expect(false, …)` reads as a double negative at
    /// the bottom of a `guard`, which is where it is almost always used.
    static func fail(
        _ message: String,
        file: StaticString = #file,
        line: UInt = #line
    ) {
        failures.append("\(currentSuite): \(message)  (\(shortFile(file)):\(line))")
    }

    static func report() -> Int32 {
        if failures.isEmpty {
            print("✓ \(passed) assertions passed")
            return 0
        }
        print("✗ \(failures.count) failure(s), \(passed) passed\n")
        for failure in failures {
            print("  \(failure)")
        }
        return 1
    }

    private static func shortFile(_ file: StaticString) -> String {
        URL(fileURLWithPath: "\(file)").lastPathComponent
    }
}

/// Clears whatever `UserDefaults.standard` means inside the test binary, so a
/// run cannot pass because an earlier run left a value behind.
///
/// This binary has no bundle identifier, so `UserDefaults.standard` resolves to
/// a domain named after the executable — `lil-ccgw-tests` — and *not* to
/// `com.andrewhyi.lil-ccgw`. The app's real preferences are therefore already
/// safe from the suite, which is worth stating because the opposite is the
/// natural assumption. What was not safe is determinism: that plist persisted
/// between runs, so `@AppStorage`-backed state and `meltSince` carried over.
///
/// The guard is the load-bearing part. If this binary ever acquires the app's
/// bundle identifier, wiping the domain would delete the user's real settings,
/// so it refuses rather than trusting that never to happen.
func resetTestDefaults() {
    let domain = Bundle.main.bundleIdentifier ?? ProcessInfo.processInfo.processName
    guard domain != "com.andrewhyi.lil-ccgw" else {
        print("""
        ✗ refusing to reset defaults: this binary claims the app's bundle \
        identifier, so the domain holds real user settings
        """)
        exit(2)
    }
    UserDefaults.standard.removePersistentDomain(forName: domain)
}

/// Decodes with the same strategy `GatewayClient` uses, so a decoding bug
/// cannot pass here and fail in the app.
func decodeFixture<V: Decodable>(_ type: V.Type, _ json: String) throws -> V {
    let decoder = JSONDecoder()
    decoder.keyDecodingStrategy = .convertFromSnakeCase
    return try decoder.decode(type, from: Data(json.utf8))
}

/// Captured verbatim from a live gateway (`curl 127.0.0.1:8484/api/status`,
/// ccgw v0.1.52) with the numbers pinned so assertions stay deterministic.
///
/// It deliberately keeps the parts that break naive decoders: `null` rates on a
/// budget with no traffic in its window, a `monthly-degrade` budget whose action
/// is neither block nor warn, and the `effort` / `model` / `tool_search` objects
/// this app does not model at all.
let statusFixture = """
{
  "enforcement": "on",
  "enforcement_resume_at": null,
  "degraded": false,
  "soft_threshold_pct": 80,
  "effort": { "manual_cap": null, "dynamic_cap": null, "effective_cap": null },
  "model": { "manual_cap": null, "routes": {} },
  "tool_search": { "state": "set", "value": "true" },
  "primary": {
    "id": "session",
    "window": "5h",
    "pace": 0.91,
    "burn_rate_hr": 13.58,
    "sustainable_hr": 15,
    "eta_hours": 4.1,
    "fits_window": true
  },
  "budgets": [
    {
      "id": "session", "scope": "global", "window": "5h",
      "limit_usd": 75, "bump_usd": 0, "bump_expires_at": null,
      "effective_limit_usd": 75, "spent_usd": 19.62,
      "remaining_usd": 55.38, "pct": 26.2, "action": "block",
      "exhausted": false, "soft": false,
      "burn_rate_hr": 13.58, "sustainable_hr": 15, "pace": 0.91
    },
    {
      "id": "weekly", "scope": "global", "window": "7d",
      "limit_usd": 300, "bump_usd": 0, "bump_expires_at": null,
      "effective_limit_usd": 300, "spent_usd": 33.39,
      "remaining_usd": 266.61, "pct": 11.1, "action": "warn",
      "exhausted": false, "soft": false,
      "burn_rate_hr": null, "sustainable_hr": null, "pace": null
    },
    {
      "id": "monthly", "scope": "global", "window": "30d",
      "limit_usd": 1200, "bump_usd": 0, "bump_expires_at": null,
      "effective_limit_usd": 1200, "spent_usd": 33.39,
      "remaining_usd": 1166.61, "pct": 2.8, "action": "block",
      "exhausted": false, "soft": false,
      "burn_rate_hr": null, "sustainable_hr": null, "pace": null
    },
    {
      "id": "monthly-degrade", "scope": "global", "window": "30d",
      "limit_usd": 1000, "bump_usd": 0, "bump_expires_at": null,
      "effective_limit_usd": 1000, "spent_usd": 33.39,
      "remaining_usd": 966.61, "pct": 3.3, "action": "degrade",
      "exhausted": false, "soft": false,
      "burn_rate_hr": null, "sustainable_hr": null, "pace": null
    }
  ]
}
"""

/// A status payload with `primary` absent entirely — the gateway omits it when
/// no budget has traffic. The app must fall back to the first budget rather than
/// blanking the title.
let statusFixtureNoPrimary = """
{
  "enforcement": "on",
  "enforcement_resume_at": null,
  "degraded": false,
  "soft_threshold_pct": 80,
  "budgets": [
    {
      "id": "weekly", "scope": "global", "window": "7d",
      "effective_limit_usd": 300, "spent_usd": 0, "remaining_usd": 300,
      "pct": 0, "action": "warn", "exhausted": false, "soft": false,
      "burn_rate_hr": null, "sustainable_hr": null, "pace": null,
      "bump_usd": null, "bump_expires_at": null
    },
    {
      "id": "monthly", "scope": "global", "window": "30d",
      "effective_limit_usd": 1200, "spent_usd": 0, "remaining_usd": 1200,
      "pct": 0, "action": "block", "exhausted": false, "soft": false,
      "burn_rate_hr": null, "sustainable_hr": null, "pace": null,
      "bump_usd": null, "bump_expires_at": null
    }
  ]
}
"""

/// A paused-enforcement payload: `enforcement_resume_at` carries the epoch-ms
/// instant the gateway auto-resumes, which the panel converts to a local time.
let statusFixturePaused = """
{
  "enforcement": "off",
  "enforcement_resume_at": 1786550000000,
  "degraded": false,
  "soft_threshold_pct": 80,
  "primary": {
    "id": "session", "window": "5h", "pace": 0.1,
    "burn_rate_hr": 1.5, "sustainable_hr": 15,
    "eta_hours": 40, "fits_window": true
  },
  "budgets": [
    {
      "id": "session", "scope": "global", "window": "5h",
      "effective_limit_usd": 75, "spent_usd": 5, "remaining_usd": 70,
      "pct": 6.7, "action": "block", "exhausted": false, "soft": false,
      "burn_rate_hr": 1.5, "sustainable_hr": 15, "pace": 0.1,
      "bump_usd": null, "bump_expires_at": null
    }
  ]
}
"""

/// No budgets configured yet — reachable on a fresh gateway install, and the
/// state where the panel must show something other than an empty list.
let statusFixtureEmptyBudgets = """
{
  "enforcement": "on",
  "enforcement_resume_at": null,
  "degraded": false,
  "soft_threshold_pct": 80,
  "budgets": []
}
"""

/// One exhausted budget and one over the soft threshold, which are the two
/// colour branches in the panel's `color(for:)` and the only states where the
/// bar stops being informational and starts being a warning.
let statusFixtureExhausted = """
{
  "enforcement": "on",
  "enforcement_resume_at": null,
  "degraded": false,
  "soft_threshold_pct": 80,
  "primary": {
    "id": "session", "window": "5h", "pace": 2.4,
    "burn_rate_hr": 36, "sustainable_hr": 15,
    "eta_hours": 0.2, "fits_window": false
  },
  "budgets": [
    {
      "id": "session", "scope": "global", "window": "5h",
      "effective_limit_usd": 75, "spent_usd": 75, "remaining_usd": 0,
      "pct": 100, "action": "block", "exhausted": true, "soft": true,
      "burn_rate_hr": 36, "sustainable_hr": 15, "pace": 2.4,
      "bump_usd": null, "bump_expires_at": null
    },
    {
      "id": "weekly", "scope": "global", "window": "7d",
      "effective_limit_usd": 300, "spent_usd": 258, "remaining_usd": 42,
      "pct": 86, "action": "warn", "exhausted": false, "soft": true,
      "burn_rate_hr": 12, "sustainable_hr": 10, "pace": 1.2,
      "bump_usd": null, "bump_expires_at": null
    }
  ]
}
"""

/// A budget with a live bumper. The expiry is deliberately far future rather
/// than `now + something`: `hasActiveBump()` compares against the clock, so a
/// relative expiry would make this fixture's rendering depend on when it ran.
let statusFixtureBumped = """
{
  "enforcement": "on",
  "enforcement_resume_at": null,
  "degraded": false,
  "soft_threshold_pct": 80,
  "primary": {
    "id": "session", "window": "5h", "pace": 0.5,
    "burn_rate_hr": 8, "sustainable_hr": 16,
    "eta_hours": 9, "fits_window": true
  },
  "budgets": [
    {
      "id": "session", "scope": "global", "window": "5h",
      "effective_limit_usd": 100, "spent_usd": 20, "remaining_usd": 80,
      "pct": 20, "action": "block", "exhausted": false, "soft": false,
      "burn_rate_hr": 8, "sustainable_hr": 16, "pace": 0.5,
      "bump_usd": 25, "bump_expires_at": 4102444800000
    }
  ]
}
"""

/// Degraded enforcement, a pace past the red threshold, and a window the spend
/// does not fit — the pessimistic end of the burn section.
let statusFixtureDegraded = """
{
  "enforcement": "on",
  "enforcement_resume_at": null,
  "degraded": true,
  "soft_threshold_pct": 80,
  "primary": {
    "id": "session", "window": "5h", "pace": 1.7,
    "burn_rate_hr": 25.5, "sustainable_hr": 15,
    "eta_hours": 1.1, "fits_window": false
  },
  "budgets": [
    {
      "id": "session", "scope": "global", "window": "5h",
      "effective_limit_usd": 75, "spent_usd": 60, "remaining_usd": 15,
      "pct": 80, "action": "degrade", "exhausted": false, "soft": true,
      "burn_rate_hr": 25.5, "sustainable_hr": 15, "pace": 1.7,
      "bump_usd": null, "bump_expires_at": null
    }
  ]
}
"""

/// No traffic in the window, so the models section must vanish rather than
/// render a header over nothing.
let spendFixtureEmpty = """
{
  "from": 1785942318163,
  "to": 1786547118163,
  "group_by": "model",
  "rows": []
}
"""

let healthFixture = """
{
  "ok": true,
  "version": "0.1.52",
  "uptime_s": 11640,
  "upstream": "https://api.anthropic.com",
  "ledger_rows": 233,
  "sessions_tracked": 7,
  "passthrough_requests": 0,
  "telemetry_degraded": false,
  "enforcement": "on"
}
"""

let spendFixture = """
{
  "from": 1785942318163,
  "to": 1786547118163,
  "group_by": "model",
  "rows": [
    { "key": "claude-opus-5", "requests": 55, "input_tokens": 1078,
      "output_tokens": 26944, "cache_read_tokens": 6441305,
      "cache_write_tokens": 422567, "cost_usd": 18.16 },
    { "key": "claude-sonnet-5", "requests": 176, "input_tokens": 15047,
      "output_tokens": 379303, "cache_read_tokens": 12872817,
      "cache_write_tokens": 1458090, "cost_usd": 15.17 },
    { "key": "claude-haiku-4-5-20251001", "requests": 2, "input_tokens": 20,
      "output_tokens": 550, "cache_read_tokens": 16054,
      "cache_write_tokens": 48998, "cost_usd": 0.07 }
  ]
}
"""
