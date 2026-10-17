import Foundation

/// How loud JR-Bar is about the moments that matter, as one choice.
///
/// A profile sets a few local switches together: whether a finished session
/// posts a banner, whether a quota crossing, pace warning or reset posts one,
/// how far an ignored ask may escalate, and whether a session that has gone
/// quiet gets one banner. It writes nothing else. None of
/// the keys it touches sends anything off this Mac, and none of them is on
/// the settings seal's list, so choosing a profile never needs the seal and
/// never turns on a webhook, a provider request or an answer path. A test
/// holds that line.
///
/// The individual switches stay on the page. When they differ from every
/// profile the picker reads "Custom"; `current(in:)` returns nil for that.
public enum AlertsProfile: String, CaseIterable, Sendable {
    case quiet
    case balanced
    case loud

    /// The settings keys a profile writes, in the order they are sent.
    /// Nothing outside this list is ever written by a profile.
    public static let keys: [String] = [
        "completion_notification_enabled",
        "quota_alerts_enabled",
        "escalation_tier",
        "silent_session_banner_enabled",
    ]

    public var title: String {
        switch self {
        case .quiet: return "Quiet"
        case .balanced: return "Balanced"
        case .loud: return "Loud"
        }
    }

    /// One plain sentence about what the profile does for the person.
    public var summary: String {
        switch self {
        case .quiet:
            return "Only asks reach you. No finish banner, no quota alerts, and an ignored ask stays on the light."
        case .balanced:
            return "A banner when a session finishes and when a quota runs low. An ignored ask reaches the menu bar."
        case .loud:
            return "Every banner, one for a session that has gone quiet, and an ignored ask chimes."
        }
    }

    /// The value each key takes under this profile.
    public var values: [String: JSONValue] {
        switch self {
        case .quiet:
            return ["completion_notification_enabled": .bool(false),
                    "quota_alerts_enabled": .bool(false),
                    "escalation_tier": .string("light"),
                    "silent_session_banner_enabled": .bool(false)]
        case .balanced:
            return ["completion_notification_enabled": .bool(true),
                    "quota_alerts_enabled": .bool(true),
                    "escalation_tier": .string("menu_bar"),
                    "silent_session_banner_enabled": .bool(false)]
        case .loud:
            return ["completion_notification_enabled": .bool(true),
                    "quota_alerts_enabled": .bool(true),
                    "escalation_tier": .string("chime"),
                    "silent_session_banner_enabled": .bool(true)]
        }
    }

    /// The writes that select this profile, in the order they are sent.
    public var writes: [(key: String, value: JSONValue)] {
        let table = values
        return Self.keys.compactMap { key in table[key].map { (key: key, value: $0) } }
    }

    /// The profile the document's switches add up to, or nil for Custom.
    /// A key the document does not carry reads as Balanced's value, because
    /// that is what the daemon uses for a key nobody has written.
    public static func current(in document: SettingsDocument) -> AlertsProfile? {
        current(reading: { document.value(at: SettingsPath($0)) })
    }

    /// `current(in:)` over any reader of settings, so a view can pass its
    /// overlaid values.
    public static func current(reading lookup: (String) -> JSONValue?) -> AlertsProfile? {
        let balanced = AlertsProfile.balanced.values
        var seen: [String: JSONValue] = [:]
        for key in keys {
            var value = lookup(key) ?? balanced[key] ?? .null
            if key == "escalation_tier", let tier = value.stringValue {
                value = .string(canonicalTier(tier))
            }
            seen[key] = value
        }
        return allCases.first { $0.values == seen }
    }

    /// The spellings of a tier the daemon and the app both accept, folded to
    /// the one a profile writes.
    static func canonicalTier(_ tier: String) -> String {
        switch tier.lowercased() {
        case "light", "ramp": return "light"
        case "menu_bar", "menubar": return "menu_bar"
        case "chime", "final": return "chime"
        default: return tier.lowercased()
        }
    }
}
