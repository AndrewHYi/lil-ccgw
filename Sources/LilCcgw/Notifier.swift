import Foundation
import UserNotifications

/// System notifications, with a hard guard.
///
/// `UNUserNotificationCenter.current()` traps when the process has no bundle
/// identifier — which is exactly the case when the binary is run straight out of
/// the build directory rather than from the assembled .app. Every entry point
/// therefore checks `isAvailable` first, so `swiftc … && ./lil-ccgw` stays a
/// usable dev loop instead of crashing on the first threshold crossing.
///
/// Authorization can also legitimately be refused: the app is ad-hoc signed
/// (no Developer ID is available), and macOS is stricter about notifications
/// from unsigned apps. Denial is treated as an expected outcome, recorded in
/// `status` so Settings can tell the truth rather than showing a toggle that
/// silently does nothing.
enum Notifier {
    enum Status: Equatable {
        case unavailable
        case notRequested
        case authorized
        case denied
    }

    private(set) nonisolated(unsafe) static var status: Status = .notRequested

    static var isAvailable: Bool {
        Bundle.main.bundleIdentifier != nil
    }

    static func requestAuthorizationIfNeeded() {
        guard isAvailable else {
            status = .unavailable
            return
        }
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert]) { granted, _ in
            status = granted ? .authorized : .denied
        }
    }

    static func post(title: String, body: String) {
        guard isAvailable, status != .denied else { return }
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        let request = UNNotificationRequest(
            identifier: UUID().uuidString,
            content: content,
            trigger: nil
        )
        UNUserNotificationCenter.current().add(request)
    }

    /// Human-readable explanation for the Alerts pane.
    ///
    /// Checks `isAvailable` first rather than trusting `status`. `status` only
    /// becomes `.unavailable` once `requestAuthorizationIfNeeded()` has run, so
    /// keying off it alone meant the pane could render toggles with no warning
    /// attached while notifications were in fact impossible.
    static var explanation: String? {
        explanation(available: isAvailable, status: status)
    }

    /// The decision behind `explanation`, taking its inputs rather than reading
    /// them.
    ///
    /// Split out because the test binary has no bundle identifier, so
    /// `isAvailable` is always false there and the early return swallowed every
    /// other branch — the denied case, the one users are most likely to hit on
    /// an ad-hoc signed build, could not be reached by a test at all.
    static func explanation(available: Bool, status: Status) -> String? {
        if !available {
            return unbundledExplanation
        }
        switch status {
        case .unavailable:
            return unbundledExplanation
        case .denied:
            return "macOS denied notifications for this app. Alerts still show in the menu."
        case .authorized, .notRequested:
            return nil
        }
    }

    static let unbundledExplanation =
        "Running unbundled — notifications need the assembled .app."
}
