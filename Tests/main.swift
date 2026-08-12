import Foundation

// Entry point for the test binary. scripts/test.sh compiles the app sources
// minus LilCcgwApp.swift (whose @main would collide with this top-level code)
// together with Tests/, then runs the result.

// Mirrors what LilCcgwApp.init does at launch, so assertions about registered
// defaults exercise the real registration rather than a test-local copy.
UserDefaults.registerLilCcgwDefaults()

runModelsTests()
runPresentationTests()
runSkitTests()

exit(T.report())
