import Foundation

/// One session's part in a quota window: "the JR-Bar refactor used 60 % of
/// what this Mac spent since the 5h window opened". Only an app that sees
/// both the sessions and the quota can say it; the share is of the tokens
/// the listed sessions spent — the part of the window this Mac can see —
/// never a claim about the provider's own percentage.
public struct WindowBurner: Hashable, Sendable, Identifiable {
    public var id: String
    public var label: String
    public var tokens: Int
    /// 0...1 of the listed sessions' tokens.
    public var share: Double

    public init(id: String, label: String, tokens: Int, share: Double) {
        self.id = id
        self.label = label
        self.tokens = tokens
        self.share = share
    }

    /// Sessions that spent nothing in the window drop out; the rest rank
    /// by tokens (ties by label, so the order never jitters), at most
    /// `limit` of them, each with its share of the listed total.
    public static func rank(_ sessions: [(id: String, label: String, tokens: Int)], limit: Int = 5) -> [WindowBurner] {
        let spending = sessions.filter { $0.tokens > 0 }
        let total = spending.reduce(0) { $0 + $1.tokens }
        guard total > 0 else { return [] }
        return spending
            .sorted { $0.tokens != $1.tokens ? $0.tokens > $1.tokens : $0.label < $1.label }
            .prefix(limit)
            .map { WindowBurner(id: $0.id, label: $0.label, tokens: $0.tokens, share: Double($0.tokens) / Double(total)) }
    }
}
