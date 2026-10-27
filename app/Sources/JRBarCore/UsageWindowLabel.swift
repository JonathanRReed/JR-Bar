import Foundation

/// The panel's short names for usage windows. The daemon's window `id`
/// (`five-hour`, `weekly`, `daily`, `credits`) or `name` (`5h`, `7d`,
/// `Daily`, `Weekly`, `Monthly`, `Credits`, or an older long name such as
/// `Antigravity CLI`) becomes a compact window or model-pool label.
public enum UsageWindowLabel {
    /// `5h`, `7d`, `Daily`, `Monthly`, `Credits`; a few daemon keys the
    /// table also knows (`cli` → `CLI`, `free-tier` → `Free`, `<model>-only`
    /// → `Model`); anything else is the first six characters of the name.
    public static func short(id: String?, name: String?) -> String {
        if let id, let known = known(id) { return known }
        if let name, let known = known(name) { return known }
        let fallback = (name?.isEmpty == false ? name : id) ?? "?"
        let trimmed = fallback.trimmingCharacters(in: .whitespacesAndNewlines)
        return String(trimmed.prefix(6)).trimmingCharacters(in: .whitespaces)
    }

    /// Table headings keep the cadence beside a short model-pool name.
    public static func column(_ name: String) -> String {
        let label = short(id: nil, name: name)
        if let cadence = cadence(id: nil, name: name) { return "\(label) \(cadence)" }
        let parts = name.split(separator: " ", maxSplits: 1)
        if parts.count == 2, ["5h", "7d"].contains(String(parts[0])) {
            return "\(short(id: nil, name: String(parts[1]))) \(parts[0])"
        }
        return label
    }

    private static func pool(_ raw: String) -> (label: String, cadence: String)? {
        let key = raw.lowercased().filter { $0.isLetter || $0.isNumber || $0 == "+" }
        let families = [("gemini4argon", "Argon"), ("geminiargon", "Argon"),
                        ("gemini", "Gemini"), ("claude+gpt", "Claude+GPT"), ("claudegpt", "Claude+GPT")]
        for (prefix, label) in families where key.hasPrefix(prefix) {
            let suffix = String(key.dropFirst(prefix.count))
            switch suffix {
            case "weekly", "7d": return (label, "7d")
            case "fivehour", "5hour", "5h": return (label, "5h")
            default: continue
            }
        }
        return nil
    }

    private static func factoryPool(_ raw: String) -> (label: String, cadence: String)? {
        let key = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            .replacingOccurrences(of: "-", with: "_")
        switch key {
        case "standard_5h": return ("Standard", "5h")
        case "standard_7d": return ("Standard", "7d")
        case "standard_30d": return ("Standard", "Monthly")
        case "core_5h": return ("Core", "5h")
        case "core_7d": return ("Core", "7d")
        case "core_30d": return ("Core", "Monthly")
        default: return nil
        }
    }

    /// The ring's pool name. Compact labels used by quota logic stay unchanged.
    public static func ringTitle(id: String?, name: String?) -> String {
        if let id, let pool = factoryPool(id) { return pool.label }
        return short(id: id, name: name)
    }

    /// A model pool's cadence, shown separately from its short name.
    public static func cadence(id: String?, name: String?) -> String? {
        if let id, let pool = factoryPool(id) { return pool.cadence }
        for raw in [id, name].compactMap({ $0 }) {
            if let pool = pool(raw) { return pool.cadence }
        }
        return nil
    }

    static func known(_ raw: String) -> String? {
        if let pool = pool(raw) { return pool.label }
        let key = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            .replacingOccurrences(of: "-", with: "_").replacingOccurrences(of: " ", with: "_")
        switch key {
        case "standard_5h", "core_5h", "5h", "five_hour", "5_hour", "fivehour", "five_hours", "5_hours", "5hr", "5hrs": return "5h"
        case "standard_7d", "core_7d", "7d", "seven_day", "7_day", "sevenday", "seven_days", "7_days", "weekly", "week": return "7d"
        case "daily", "day", "24h", "1d", "one_day": return "Daily"
        case "standard_30d", "core_30d", "monthly", "month", "30d": return "Monthly"
        case "credits", "credit", "balance": return "Credits"
        case "cli": return "CLI"
        case "free_tier", "free": return "Free"
        default:
            if key.hasSuffix("_only"), key.count > 5 {
                let model = key.dropLast(5)
                if !model.isEmpty { return String(model.prefix(1).uppercased() + model.dropFirst().prefix(5)) }
            }
            return nil
        }
    }

    /// The spoken-length name: the daemon's own name when it is already a
    /// word ("Weekly", "Daily"), else the short codes expanded ("5-hour",
    /// "7-day"). For captions and tooltips where `5h` alone is cryptic.
    public static func long(id: String?, name: String?) -> String {
        let short = short(id: id, name: name)
        if let name, !name.isEmpty, name != short { return name }
        switch short {
        case "5h": return "5-hour"
        case "7d": return "7-day"
        default: return short
        }
    }

    /// The two characters every surface uses for a window nobody measured.
    /// It is not "0", and it is not blank: a blank column reads as calm.
    public static let unknownPercent = "—"

    /// `42%`, or `—` when the provider stated no number.
    public static func percent(_ usedPct: Double?) -> String {
        UsageNumber.percent(usedPct)
    }

    /// "42 percent used" / "no reading", for VoiceOver and tooltips.
    public static func spoken(_ usedPct: Double?) -> String {
        guard let usedPct else { return "no reading" }
        return "\(wholeUsed(usedPct)) percent used"
    }

    /// A used percent as a whole number that never overstates: 100 only
    /// for a window the forecast also calls spent (99.95 and up), so 99.6
    /// reads 99 rather than "100% used" beside a run-out forecast. Clamped
    /// to 0...100, and a value that is not a number or is out of range
    /// cannot trap the conversion.
    public static func wholeUsed(_ pct: Double) -> Int {
        guard !pct.isNaN else { return 0 }
        let clamped = min(100, max(0, pct))
        if clamped >= 99.95 { return 100 }
        return min(99, Int(clamped.rounded()))
    }

    /// What is left of a window as a whole number, the complement of
    /// `wholeUsed`: 0 only for a spent window, so 99.6 used is "1% left".
    public static func wholeLeft(usedPct: Double) -> Int {
        100 - wholeUsed(usedPct)
    }

    /// The lane's own length in seconds — a reset countdown drawn as a
    /// draining arc needs the window's full span for its denominator.
    /// Only the horizons the daemon's lane ids actually name; a
    /// `credits` balance or an unclassified lane has no clock to drain
    /// and returns nil.
    public static func windowSpan(id: String?, name: String?) -> TimeInterval? {
        let candidates = [id, name].compactMap { $0 }
        for raw in candidates {
            let key = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
                .replacingOccurrences(of: "-", with: "_").replacingOccurrences(of: " ", with: "_")
            switch key {
            case "standard_5h", "core_5h", "5h", "five_hour", "5_hour", "fivehour", "five_hours", "5_hours", "5hr", "5hrs":
                return 5 * 3600
            case "standard_7d", "core_7d", "7d", "seven_day", "7_day", "sevenday", "seven_days", "7_days", "weekly", "week":
                return 7 * 86400
            case "daily", "day", "24h", "1d", "one_day":
                return 86400
            case "standard_30d", "core_30d", "monthly", "month", "30d":
                return 30 * 86400
            default: continue
            }
        }
        return nil
    }
}
