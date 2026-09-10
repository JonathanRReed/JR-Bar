import Foundation

/// The panel's short names for usage windows. The daemon's window `id`
/// (`five-hour`, `weekly`, `daily`, `credits`) or `name` (`5h`, `7d`,
/// `Daily`, `Weekly`, `Monthly`, `Credits`, or an older long name such as
/// `Antigravity CLI`) becomes a label that never wraps a 42 pt column.
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

    static func known(_ raw: String) -> String? {
        let key = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            .replacingOccurrences(of: "-", with: "_").replacingOccurrences(of: " ", with: "_")
        switch key {
        case "5h", "five_hour", "5_hour", "fivehour", "five_hours", "5_hours", "5hr", "5hrs": return "5h"
        case "7d", "seven_day", "7_day", "sevenday", "seven_days", "7_days", "weekly", "week": return "7d"
        case "daily", "day", "24h", "1d", "one_day": return "Daily"
        case "monthly", "month", "30d": return "Monthly"
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
}
