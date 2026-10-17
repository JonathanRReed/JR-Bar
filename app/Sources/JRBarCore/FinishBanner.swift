import Foundation

/// The words of a finish banner: what finished, how long it took, and the
/// first line of what the agent said last. Pure, so it is tested without
/// AppKit. The daemon has already stripped the summary's markdown and
/// scrubbed anything token-shaped out of it; this only keeps the banner
/// honest if a daemon sent something longer.
public enum FinishBanner {
    /// The most characters of the agent's own words a banner carries.
    public static let summaryLimit = 140

    /// `4m 12s`, `1h 5m`, `45s`: the run's length in the units a person
    /// says it in. nil when the span is unknown, not a number, or under a
    /// second, because "finished in 0s" says nothing.
    public static func durationWords(_ seconds: Double?) -> String? {
        guard let seconds, seconds.isFinite, seconds >= 1, seconds < 400 * 24 * 3600 else { return nil }
        let whole = Int(seconds.rounded())
        if whole < 60 { return "\(whole)s" }
        let minutes = whole / 60
        if minutes < 60 {
            let rest = whole % 60
            return rest == 0 ? "\(minutes)m" : "\(minutes)m \(rest)s"
        }
        let hours = minutes / 60
        if hours < 24 {
            let rest = minutes % 60
            return rest == 0 ? "\(hours)h" : "\(hours)h \(rest)m"
        }
        let days = hours / 24
        return hours % 24 == 0 ? "\(days)d" : "\(days)d \(hours % 24)h"
    }

    /// "sidepulse-core finished in 4m 12s", or "sidepulse-core finished"
    /// when the run's length is not known.
    public static func title(label: String, duration: Double?) -> String {
        guard let words = durationWords(duration) else { return "\(label) finished" }
        return "\(label) finished in \(words)"
    }

    /// The first line of the agent's last message, capped, or nil when
    /// there is nothing to say.
    public static func summary(_ text: String?) -> String? {
        guard let text else { return nil }
        let line = text.split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .first { !$0.isEmpty }
        guard let line else { return nil }
        guard line.count > summaryLimit else { return line }
        let cut = String(line.prefix(summaryLimit - 1))
        let trimmed = cut.lastIndex(of: " ").map { String(cut[..<$0]) } ?? cut
        return trimmed.trimmingCharacters(in: CharacterSet(charactersIn: " .,;:-")) + "…"
    }
}
