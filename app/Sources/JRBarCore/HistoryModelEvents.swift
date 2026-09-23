import Foundation

// History's two newer halves: the daemon's event journal (what the Event
// Replay window used to show on its own) as a filterable log, the light log
// the "Why this light" popover draws from it, and which History rows can
// open their session's timeline.

/// The daemon's event journal, sorted into the handful of things a person
/// asks it about. History's Events view filters by these, and the "Why
/// this light" popover's light log keeps only the ones that move a light.
public enum EventLogCategory: String, CaseIterable, Sendable, Identifiable {
    case asks
    case runs
    case failures
    case escalation
    case quota
    case devices
    case other

    public var id: String { rawValue }

    public static func of(_ kind: String) -> EventLogCategory {
        switch kind {
        case "ask_opened", "ask_resolved": return .asks
        case "failed", "session_failed": return .failures
        case "completed", "started", "ended": return .runs
        case "escalation_stage": return .escalation
        case "quota_crossed", "quota_reset", "quota_pace": return .quota
        case "device_connected", "device_disconnected", "peer_arrived", "peer_departed",
             "deck_receipt", "deck_input", "deck_device":
            return .devices
        default:
            if kind.hasPrefix("quota") { return .quota }
            if kind.hasPrefix("device") || kind.hasPrefix("deck") || kind.hasPrefix("peer") { return .devices }
            if kind.contains("fail") || kind.contains("error") { return .failures }
            return .other
        }
    }

    /// The chip's word.
    public var word: String {
        switch self {
        case .asks: return "Asks"
        case .runs: return "Runs"
        case .failures: return "Failures"
        case .escalation: return "Escalation"
        case .quota: return "Quota"
        case .devices: return "Devices"
        case .other: return "Other"
        }
    }

    /// The categories that change what a light is doing — the light log
    /// keeps these and drops device chatter and bookkeeping.
    public var movesALight: Bool {
        switch self {
        case .asks, .runs, .failures, .escalation, .quota: return true
        case .devices, .other: return false
        }
    }
}

/// History's Events filter: category chips and free text. Empty means
/// everything. Bookkeeping events no person reads (`usage_history_ready`)
/// never show.
public struct EventLogFilter: Equatable, Sendable {
    public var categories: Set<EventLogCategory> = []
    public var text: String = ""

    public init(categories: Set<EventLogCategory> = [], text: String = "") {
        self.categories = categories
        self.text = text
    }

    public static let hiddenKinds: Set<String> = [CoreEvent.usageHistoryReadyKind]

    public var isEmpty: Bool { categories.isEmpty && text.trimmingCharacters(in: .whitespaces).isEmpty }

    public func matches(_ event: CoreEvent) -> Bool {
        if Self.hiddenKinds.contains(event.kind) { return false }
        if !categories.isEmpty, !categories.contains(EventLogCategory.of(event.kind)) { return false }
        let needle = text.trimmingCharacters(in: .whitespaces).lowercased()
        if !needle.isEmpty {
            let haystack = [event.kind, event.label, event.detail, event.message, event.provider, event.session]
                .compactMap { $0?.lowercased() }
            if !haystack.contains(where: { $0.contains(needle) }) { return false }
        }
        return true
    }

    /// Newest first — the journal arrives oldest first.
    public func apply(_ events: [CoreEvent]) -> [CoreEvent] {
        events.filter(matches).reversed()
    }
}

/// One line of the light log: "Codex asked · sidepulse-core" at a time.
public struct LightLogEntry: Hashable, Sendable, Identifiable {
    public var id: String
    public var at: Double
    public var category: EventLogCategory
    public var text: String

    public init(id: String, at: Double, category: EventLogCategory, text: String) {
        self.id = id
        self.at = at
        self.category = category
        self.text = text
    }
}

/// The recent events that moved a light, newest first, for the "Why this
/// light" popover: the reason says what the light is doing now, the log
/// says how it got there.
public enum LightLog {
    public static func entries(from events: [CoreEvent], limit: Int = 5) -> [LightLogEntry] {
        var out: [LightLogEntry] = []
        for event in events.reversed() {
            let category = EventLogCategory.of(event.kind)
            guard category.movesALight, !EventLogFilter.hiddenKinds.contains(event.kind), let at = event.at else { continue }
            out.append(LightLogEntry(id: event.id, at: at, category: category, text: text(for: event)))
            if out.count >= limit { break }
        }
        return out
    }

    /// "Codex asked · sidepulse-core" — who, then what, in the log's words.
    public static func text(for event: CoreEvent) -> String {
        let who = event.provider.map { SessionLabel.providerName($0) }
        let subject = event.label?.trimmingCharacters(in: .whitespacesAndNewlines)
        let verb: String
        switch event.kind {
        case "ask_opened": verb = "asked"
        case "ask_resolved": verb = "was answered"
        case "completed": verb = "finished"
        case "failed", "session_failed": verb = "failed"
        case "started": verb = "started"
        case "ended": verb = "ended"
        case "escalation_stage": verb = "escalated to stage \(event.stage ?? 0)"
        case "quota_crossed": verb = "crossed a quota threshold"
        case "quota_reset": verb = "quota reset"
        default: verb = event.kind.replacingOccurrences(of: "_", with: " ")
        }
        let head = [who, verb].compactMap { $0 }.joined(separator: " ")
        if let subject, !subject.isEmpty, subject != who { return head + " · " + subject }
        if let detail = event.detail, !detail.isEmpty { return head + " · " + detail }
        return head
    }
}

// MARK: - Transcript hits

public enum TranscriptSnippet {
    /// A full-text snippet cut from a stored JSONL line, made readable:
    /// escapes undone, JSON keys, brackets and quotes dropped, runs of
    /// space collapsed. The « » the index puts around matched terms stay,
    /// so the view can mark them.
    public static func readable(_ raw: String) -> String {
        raw.replacingOccurrences(of: "\\n", with: " ")
            .replacingOccurrences(of: "\\t", with: " ")
            .replacingOccurrences(of: "\"[A-Za-z_]+\"\\s*:", with: " ", options: .regularExpression)
            .replacingOccurrences(of: "[{}\\[\\]\"\\\\]", with: " ", options: .regularExpression)
            .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .replacingOccurrences(of: " ,", with: ",")
            .trimmingCharacters(in: CharacterSet(charactersIn: ", ").union(.whitespacesAndNewlines))
    }
}

// MARK: - Days

public enum HistoryDayParse {
    /// `2026-09-16` (the heatmap's day key) → local midnight; nil for
    /// anything else.
    public static func date(_ iso: String, calendar: Calendar = .current) -> Date? {
        let parts = iso.split(separator: "-").compactMap { Int($0) }
        guard parts.count == 3 else { return nil }
        return calendar.date(from: DateComponents(year: parts[0], month: parts[1], day: parts[2]))
    }

    /// "Tue 16 Sep" — a day as the filter banners name it.
    public static func title(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.setLocalizedDateFormatFromTemplate("EEE d MMM")
        return formatter.string(from: date)
    }
}

// MARK: - History row timelines

public enum HistoryTimelineRequest {
    /// Transcript readers exist for these providers.
    public static let readableProviders: Set<String> = ["claude", "codex"]

    /// The provider uuid an agent id carries as its last `:` segment
    /// (`claude:session:8870963f-…`) — the same convention the Overview's
    /// timeline fallback uses once a row has aged out of the roster.
    public static func sessionUUID(from agentID: String?) -> String? {
        guard let agentID else { return nil }
        let parts = agentID.split(separator: ":")
        guard parts.count >= 2, let last = parts.last else { return nil }
        let text = String(last)
        return SessionLabel.looksLikeUUID(text) ? text : nil
    }

    /// The provider a row names, or the agent id's leading segment.
    public static func provider(of row: CoreHistoryRow) -> String? {
        if let provider = row.provider, !provider.isEmpty { return provider }
        return row.session?.split(separator: ":").first.map(String.init)
    }

    /// A row can open its timeline when it names a local session of a
    /// provider whose transcripts are read.
    public static func canExpand(_ row: CoreHistoryRow) -> Bool {
        guard let session = row.session, !session.isEmpty, !CoreSession.isRemoteID(session) else { return false }
        return provider(of: row).map(readableProviders.contains) ?? false
    }
}
