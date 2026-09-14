import Foundation

/// The redacted desktop-glance file the daemon writes next to its other
/// state (`widget-snapshot.json` in the state dir). A WidgetKit
/// extension reads this — never the socket — so the shape is its own
/// small contract: counts, provider names and flags, no transcript text.
public struct WidgetSnapshot: Codable, Equatable, Sendable {
    public struct Counts: Codable, Equatable, Sendable {
        public var sessions: Int
        public var working: Int
        public var waiting: Int
        public var stale: Int
        /// Entries actually listed; `sessions - shown` are elided by the cap.
        public var shown: Int
    }

    /// One tile's facts: who, what mode, whether it waits, whether it's stale.
    public struct Entry: Codable, Equatable, Sendable {
        public var provider: String
        public var mode: String
        public var waiting: Bool
        public var stale: Bool
    }

    public var schema: Int
    /// Wall-clock when the daemon wrote it — the widget's "as of" line.
    public var generatedAt: TimeInterval
    public var counts: Counts
    public var entries: [Entry]

    public init(schema: Int, generatedAt: TimeInterval, counts: Counts, entries: [Entry]) {
        self.schema = schema
        self.generatedAt = generatedAt
        self.counts = counts
        self.entries = entries
    }

    private enum CodingKeys: String, CodingKey {
        case schema, counts, entries
        case generatedAt = "generated_at"
    }

    /// A snapshot older than this is wallpaper, not a glance — the widget
    /// dims rather than shows a stale count as current.
    public static let freshnessWindow: TimeInterval = 90

    /// Whether the file is fresh enough to present as live; `now` is
    /// injectable so the check is a pure function of the file's stamp.
    public func isFresh(at now: Date = Date()) -> Bool {
        now.timeIntervalSince1970 - generatedAt <= Self.freshnessWindow
    }

    /// Reads the snapshot file if it exists and parses; absent, corrupt
    /// or wrong-schema files all read as nil — the widget then shows its
    /// "open JR-Bar" placeholder instead of a fabricated count.
    public static func load(from url: URL, schema: Int = 1) -> WidgetSnapshot? {
        guard let data = try? Data(contentsOf: url),
              let snapshot = try? JSONDecoder().decode(WidgetSnapshot.self, from: data),
              snapshot.schema == schema else { return nil }
        return snapshot
    }
}
