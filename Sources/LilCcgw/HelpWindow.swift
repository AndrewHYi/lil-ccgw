import AppKit

/// Opens the Help window and brings it to the front.
///
/// Same problem `SettingsWindow` solves, for the same reason: this is an
/// `LSUIElement` accessory with no Dock presence, so a freshly-opened window
/// can land behind whatever the user was working in — which reads as
/// "clicking Help does nothing". Activating explicitly is the fix; per
/// `menubar-ergonomics`, any future window needs the same treatment.
///
/// This lives outside `LilCcgwApp.swift` on purpose: that file carries `@main`
/// and is excluded from the test build, so anything the rest of the app calls
/// has to sit elsewhere or the tests will not compile.
@MainActor
enum HelpWindow {
    static func present(_ openWindow: @escaping () -> Void) {
        NSApp.activate(ignoringOtherApps: true)
        openWindow()
        // The scene can take a tick to materialise, so raise it once it has.
        DispatchQueue.main.async {
            NSApp.activate(ignoringOtherApps: true)
            for window in NSApp.windows
            where window.title.localizedCaseInsensitiveContains("help") {
                window.makeKeyAndOrderFront(nil)
            }
        }
    }
}
