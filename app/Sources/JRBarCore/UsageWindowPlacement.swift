import Foundation

/// Placement uses the stated cadence, never the time remaining until reset.
public enum UsageWindowPlacement: String, Codable, Sendable {
    case fiveHour = "5h"
    case weekly = "7d"
    case labelled

    public static func of(_ window: CoreUsageWindow) -> Self {
        for raw in [window.key, window.name].compactMap({ $0 }) {
            let span = UsageWindowLabel.windowSpan(id: raw, name: nil)
            if span == 5 * 3600 { return .fiveHour }
            if span == 7 * 86400 { return .weekly }
            let words = raw.lowercased().split { !$0.isLetter && !$0.isNumber }.map(String.init)
            let pairs = zip(words, words.dropFirst()).map { $0 + "-" + $1 }
            if words.contains("weekly") || words.contains("7d") || pairs.contains("7-day")
                || pairs.contains("seven-day") { return .weekly }
            if words.contains("5h") || pairs.contains("5-hour") || pairs.contains("five-hour") {
                return .fiveHour
            }
        }
        return .labelled
    }
}

extension CoreUsageWindow {
    public var placement: UsageWindowPlacement { UsageWindowPlacement.of(self) }

    /// Alias windows share a heading; named pools retain their own heading.
    public var overviewColumn: String {
        if placement != .labelled,
           UsageWindowLabel.short(id: nil, name: name) == placement.rawValue {
            return placement.rawValue
        }
        return name
    }

    public var placementLabel: String {
        overviewColumn
    }
}
