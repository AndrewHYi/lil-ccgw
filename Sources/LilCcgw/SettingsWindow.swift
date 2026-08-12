import AppKit

/// Opens the Settings scene and brings it to the front.
///
/// `openSettings()` alone is not enough here. The app sets `LSUIElement`, so it
/// is an accessory with no Dock presence and never becomes active on its own —
/// the window opens behind whatever the user was working in, which reads as
/// "clicking Settings does nothing". Activating explicitly is the fix.
///
/// This lives outside `LilCcgwApp.swift` on purpose: that file carries `@main`
/// and is excluded from the test build, so anything the rest of the app calls
/// has to sit elsewhere or the tests will not compile.
@MainActor
enum SettingsWindow {
    static func present(_ openSettings: @escaping () -> Void) {
        NSApp.activate(ignoringOtherApps: true)
        openSettings()
        // The scene can take a tick to materialise, so raise it once it has.
        DispatchQueue.main.async {
            NSApp.activate(ignoringOtherApps: true)
            for window in NSApp.windows
            where window.title.localizedCaseInsensitiveContains("settings")
                || window.title.localizedCaseInsensitiveContains("preferences") {
                window.makeKeyAndOrderFront(nil)
            }
        }
    }
}
