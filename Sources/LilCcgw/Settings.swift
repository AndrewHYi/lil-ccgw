import Foundation
import SwiftUI

/// What the menu bar shows. The whole point of making this configurable is that
/// menu bar width is contested real estate and the right trade differs per
/// person, so every mode is a first-class option rather than a hidden default.
enum TitleMode: String, CaseIterable, Identifiable {
    case spendOfLimit
    case iconAndSpend
    case iconOnly
    case iconAndPace
    case statusline

    var id: String { rawValue }

    /// The mode a stored raw value means, with one fallback for the whole app.
    ///
    /// There used to be two. The menu bar fell back to `.spendOfLimit` and the
    /// Settings preview to `.iconAndSpend`, so an unrecognised stored value made
    /// the preview show a different mode than the menu bar it claims to preview —
    /// the one thing a preview must never do. `.spendOfLimit` wins because it is
    /// also the registered default.
    static func resolve(_ raw: String?) -> TitleMode {
        TitleMode(rawValue: raw ?? "") ?? .spendOfLimit
    }

    var label: String {
        switch self {
        case .spendOfLimit: return "Spend / limit + window"
        case .iconAndSpend: return "Spend only"
        case .iconOnly: return "Icon only"
        case .iconAndPace: return "Pace"
        case .statusline: return "Statusline"
        }
    }

    var detail: String {
        switch self {
        case .spendOfLimit: return "$20.59/$75 5h — spend, ceiling, and window"
        case .iconAndSpend: return "$20.59 — spend alone, no context"
        case .iconOnly: return "Narrowest — colour and glyph only"
        case .iconAndPace: return "0.91× — burn ÷ sustainable rate"
        case .statusline: return "Adds a second budget as the overall ceiling"
        }
    }
}

/// Which dropdown sections are visible.
enum PanelSection: String, CaseIterable, Identifiable {
    case budgets
    case burn
    case models

    var id: String { rawValue }

    var label: String {
        switch self {
        case .budgets: return "Budgets"
        case .burn: return "Burn and pace"
        case .models: return "Top models"
        }
    }

    var defaultsKey: String { "show.\(rawValue)" }
}

enum DefaultsKey {
    static let titleMode = "titleMode"
    static let trackedBudgetId = "trackedBudgetId"
    static let gatewayHost = "gatewayHost"
    static let gatewayPort = "gatewayPort"
    static let pollOpen = "pollOpenSeconds"
    static let pollClosed = "pollClosedSeconds"
    static let notifySoft = "notifySoftThreshold"
    static let notifyDown = "notifyGatewayDown"
    static let pauseMinutes = "pauseMinutes"
    static let animateIcon = "animateIcon"
    static let forcedTier = "forcedTier"
    static let meltSince = "meltSince"
}

extension UserDefaults {
    /// Registered rather than sprinkled as `?? default` at each read site, so
    /// the settings panes and the label view cannot disagree about a default.
    static func registerLilCcgwDefaults() {
        standard.register(defaults: [
            // Spend alone answers "how much" but not "out of what, over how
            // long" — the two facts that make the number actionable at a glance.
            DefaultsKey.titleMode: TitleMode.spendOfLimit.rawValue,
            DefaultsKey.trackedBudgetId: "",
            DefaultsKey.gatewayHost: "127.0.0.1",
            DefaultsKey.gatewayPort: GatewayClient.configuredPort() ?? 8484,
            DefaultsKey.pollOpen: 5.0,
            DefaultsKey.pollClosed: 30.0,
            DefaultsKey.notifySoft: true,
            DefaultsKey.notifyDown: true,
            DefaultsKey.pauseMinutes: 60,
            DefaultsKey.animateIcon: true,
            DefaultsKey.forcedTier: "",
            PanelSection.budgets.defaultsKey: true,
            PanelSection.burn.defaultsKey: true,
            PanelSection.models.defaultsKey: true,
        ])
    }
}

/// Formatting shared by the label, the panel, and the settings preview. Keeping
/// it in one place is what stops the preview from drifting from what actually
/// lands in the menu bar.
enum Fmt {
    static func usd(_ value: Double, cents: Bool = true) -> String {
        if cents && value < 1000 {
            return String(format: "$%.2f", value)
        }
        return String(format: "$%.0f", value)
    }

    static func limit(_ value: Double) -> String {
        String(format: "$%.0f", value)
    }

    static func pace(_ value: Double?) -> String {
        guard let value else { return "—" }
        return String(format: "%.2f×", value)
    }

    static func rate(_ value: Double?) -> String {
        guard let value else { return "—" }
        return String(format: "$%.2f/hr", value)
    }

    static func hours(_ value: Double?) -> String {
        guard let value, value.isFinite else { return "—" }
        if value >= 48 { return String(format: "%.0fd", value / 24) }
        if value >= 1 { return String(format: "%.1fh", value) }
        return String(format: "%.0fm", value * 60)
    }

    static func uptime(_ seconds: Double?) -> String {
        guard let seconds, seconds > 0 else { return "—" }
        let total = Int(seconds)
        let days = total / 86_400
        let hours = (total % 86_400) / 3600
        let minutes = (total % 3600) / 60
        if days > 0 { return "\(days)d \(hours)h" }
        if hours > 0 { return "\(hours)h \(minutes)m" }
        return "\(minutes)m"
    }

    static func clockTime(_ date: Date?) -> String {
        guard let date else { return "—" }
        let formatter = DateFormatter()
        formatter.timeStyle = .short
        return formatter.string(from: date)
    }
}
