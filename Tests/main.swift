import Foundation

// Entry point for the test binary. scripts/test.sh compiles the app sources
// minus LilCcgwApp.swift (whose @main would collide with this top-level code)
// together with Tests/, then runs the result.

// Clear anything a previous run left in this binary's own defaults domain
// before registering, or @AppStorage-backed state carries between runs.
resetTestDefaults()

// Mirrors what LilCcgwApp.init does at launch, so assertions about registered
// defaults exercise the real registration rather than a test-local copy.
UserDefaults.registerLilCcgwDefaults()

runModelsTests()
runPresentationTests()
runSkitTests()
runDeriveTests()
runTransportTests()
runPanelDeriveTests()

// Render tests host real SwiftUI views, so they need the main actor.
await MainActor.run { runRenderTests() }

// Window helpers touch NSApp, so main actor as well.
await MainActor.run { runWindowTests() }

// The notifier's fire-once rule is main-actor isolated.
await MainActor.run { runNotifierRuleTests() }

// View tests render the panel, settings and help views. Async as well as
// main-actor isolated, because each state is reached through a real refresh.
await runViewTests()

// Process control, driven through a fake environment — nothing here spawns
// launchctl, so the suite still runs with the gateway stopped.
await runServiceControlTests()

// The model's lifecycle actions, on the same fake environment.
await runRecoveryTests()

// Odds and ends that coverage measurement showed nothing had ever executed.
await runGapTests()

// Model tests are async and main-actor isolated. Top-level `await` in main.swift
// is the pattern that works here — a DispatchSemaphore around a @MainActor task
// deadlocks, because blocking the main thread starves the actor it's waiting on.
await runModelTests()

exit(T.report())
