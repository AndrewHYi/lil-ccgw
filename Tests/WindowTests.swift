import AppKit
import Foundation

/// Tests for the two window-opening helpers.
///
/// Both already had the seam — `present` takes the open action as a closure —
/// and neither used it. What is asserted is the part that can actually regress
/// silently: that `present` calls the action exactly once, on the calling turn.
///
/// The `NSApp.windows` raise loop is not asserted and is exempt in
/// `coverage-floors.txt`. It runs inside `DispatchQueue.main.async` against a
/// real window list, and this binary is not an `NSApplication` with scenes, so
/// there is nothing to raise. Its failure mode is visual — a window opening
/// behind the user's frontmost app — which no unit test would catch anyway.
@MainActor
func runWindowTests() {
    T.suite("presenting settings triggers the open action exactly once") {
        var opens = 0
        SettingsWindow.present { opens += 1 }
        T.equal(opens, 1, "the injected open action runs once, synchronously")
    }

    T.suite("presenting help triggers the open action exactly once") {
        var opens = 0
        HelpWindow.present { opens += 1 }
        T.equal(opens, 1, "the injected open action runs once, synchronously")
    }

    T.suite("each present call opens again") {
        // Clicking Help twice has to open it twice — a guard that suppressed the
        // second call would make a closed window unreopenable until relaunch.
        var opens = 0
        HelpWindow.present { opens += 1 }
        HelpWindow.present { opens += 1 }
        HelpWindow.present { opens += 1 }
        T.equal(opens, 3, "presenting is not deduplicated")
    }
}
