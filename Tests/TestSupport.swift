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
