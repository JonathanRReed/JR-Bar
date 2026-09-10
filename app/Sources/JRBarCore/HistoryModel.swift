import Foundation

/// One `list_history` row: something that happened to a session.
public struct CoreHistoryRow: Codable, Hashable, Sendable, Identifiable {
    public var at: Double
    /// `started`, `completed`, `asked`, `answered`, `failed`, `ended`.
    public var kind: String
    public var provider: String?
    public var session: String?
    public var label: String?
    public var detail: String?
    /// Seconds the thing took, when the daemon knows (a completed run, an answered ask).
    public var duration: Double?
    /// True when it happened while the Mac was asleep or locked.
    public var unseen: Bool

    public var id: String { "\(at)|\(kind)|\(session ?? "")|\(label ?? "")" }

    /// The label as the panel shows sessions (`SessionLabel`): the daemon's
    /// "Claude 8870963f-850a-…" row reads "8870963f", never the provider
    /// twice; with no label at all, the provider's name.
    public var displayLabel: String {
        let providerID = provider ?? session?.split(separator: ":").first.map(String.init) ?? ""
        let text = SessionLabel.display(label: label, shortId: nil, id: session ?? "", provider: providerID)
        if text.isEmpty { return SessionLabel.providerName(providerID) }
        return text
    }

    public init(at: Double, kind: String, provider: String? = nil, session: String? = nil, label: String? = nil,
                detail: String? = nil, duration: Double? = nil, unseen: Bool = false) {
        self.at = at
        self.kind = kind
        self.provider = provider
        self.session = session
        self.label = label
        self.detail = detail
        self.duration = duration
        self.unseen = unseen
    }

    enum CodingKeys: String, CodingKey { case at, kind, provider, session, label, detail, duration, unseen }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        at = try c.decodeIfPresent(Double.self, forKey: .at) ?? 0
        kind = try c.decodeIfPresent(String.self, forKey: .kind) ?? "event"
        provider = try c.decodeIfPresent(String.self, forKey: .provider)
        session = try c.decodeIfPresent(String.self, forKey: .session)
        label = try c.decodeIfPresent(String.self, forKey: .label)
        detail = try c.decodeIfPresent(String.self, forKey: .detail)
        duration = try c.decodeIfPresent(Double.self, forKey: .duration)
        unseen = try c.decodeIfPresent(Bool.self, forKey: .unseen) ?? false
    }

    public var date: Date { Date(timeIntervalSince1970: at) }

    public static let kinds = ["started", "completed", "asked", "answered", "failed", "ended"]

    /// "Started", "Needed you", "Answered", "Finished", "Failed", "Ended".
    public var kindWord: String {
        switch kind {
        case "started": return "Started"
        case "completed": return "Finished"
        case "asked": return "Needed you"
        case "answered": return "Answered"
        case "failed": return "Failed"
        case "ended": return "Ended"
        default: return kind.prefix(1).uppercased() + kind.dropFirst()
        }
    }
}

/// The History window's filter: provider chips, kind chips and free text.
/// Empty sets mean "everything".
public struct HistoryFilter: Equatable, Sendable {
    public var providers: Set<String> = []
    public var kinds: Set<String> = []
    public var text: String = ""

    public init(providers: Set<String> = [], kinds: Set<String> = [], text: String = "") {
        self.providers = providers
        self.kinds = kinds
        self.text = text
    }

    public var isEmpty: Bool { providers.isEmpty && kinds.isEmpty && text.trimmingCharacters(in: .whitespaces).isEmpty }

    public func matches(_ row: CoreHistoryRow) -> Bool {
        if !providers.isEmpty, !providers.contains(row.provider ?? "") { return false }
        if !kinds.isEmpty, !kinds.contains(row.kind) { return false }
        let needle = text.trimmingCharacters(in: .whitespaces).lowercased()
        if !needle.isEmpty {
            let haystack = [row.label, row.detail, row.provider, row.session, row.kindWord].compactMap { $0?.lowercased() }
            if !haystack.contains(where: { $0.contains(needle) }) { return false }
        }
        return true
    }

    public func apply(_ rows: [CoreHistoryRow]) -> [CoreHistoryRow] { rows.filter(matches) }
}

/// Rows for one calendar day, newest first.
public struct HistoryDay: Identifiable, Equatable, Sendable {
    public var date: Date
    public var title: String
    public var rows: [CoreHistoryRow]
    public var id: Date { date }
}

public enum HistoryGrouping {
    /// Groups newest first; titles are Today, Yesterday, then a weekday
    /// and date. `now` and `calendar` are injectable for tests.
    public static func days(_ rows: [CoreHistoryRow], now: Date = Date(), calendar: Calendar = .current) -> [HistoryDay] {
        var buckets: [Date: [CoreHistoryRow]] = [:]
        for row in rows {
            buckets[calendar.startOfDay(for: row.date), default: []].append(row)
        }
        let today = calendar.startOfDay(for: now)
        let formatter = DateFormatter()
        formatter.calendar = calendar
        formatter.setLocalizedDateFormatFromTemplate("EEEE d MMMM")
        return buckets.keys.sorted(by: >).map { day in
            let title: String
            if day == today { title = "Today" }
            else if let yesterday = calendar.date(byAdding: .day, value: -1, to: today), day == yesterday { title = "Yesterday" }
            else { title = formatter.string(from: day) }
            return HistoryDay(date: day, title: title, rows: buckets[day]!.sorted { $0.at > $1.at })
        }
    }
}

/// "While you were away: 2 finished, 1 needed you" — built from the unseen
/// rows at the top of the history. Nil when the newest row was seen.
public struct AwaySummary: Equatable, Sendable {
    public var rows: [CoreHistoryRow]
    public var since: Date
    public var counts: [String: Int]

    public var text: String {
        let order = ["completed", "asked", "failed", "answered", "started", "ended"]
        let parts = order.compactMap { kind -> String? in
            guard let count = counts[kind], count > 0 else { return nil }
            switch kind {
            case "completed": return "\(count) finished"
            case "asked": return count == 1 ? "1 needed you" : "\(count) needed you"
            case "failed": return "\(count) failed"
            case "answered": return "\(count) answered"
            case "started": return "\(count) started"
            default: return "\(count) ended"
            }
        }
        return "While you were away: " + (parts.isEmpty ? "\(rows.count) events" : parts.joined(separator: ", "))
    }

    /// Only a run of unseen rows at the newest end counts as "away"; older
    /// unseen rows have been scrolled past already.
    public static func make(from rows: [CoreHistoryRow]) -> AwaySummary? {
        let newestFirst = rows.sorted { $0.at > $1.at }
        var run: [CoreHistoryRow] = []
        for row in newestFirst {
            guard row.unseen else { break }
            run.append(row)
        }
        guard !run.isEmpty else { return nil }
        var counts: [String: Int] = [:]
        for row in run { counts[row.kind, default: 0] += 1 }
        return AwaySummary(rows: run, since: run.last!.date, counts: counts)
    }
}
