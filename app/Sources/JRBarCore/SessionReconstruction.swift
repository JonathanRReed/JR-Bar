import Foundation

/// One rebuilt timeline row — the archived-session twin of the live
/// `session_timeline` items the Python side projects from Claude Code and
/// Codex transcripts. `at` is the row's own stamp (epoch seconds);
/// `untrusted` marks content that must never render as a command or an
/// approval (T44); `redacted` marks a text payload withheld by the
/// metadata-only consent mode.
public struct ReconstructedItem: Sendable, Equatable {
    public enum Kind: String, Sendable, Equatable, CaseIterable {
        case message
        case toolUse
        case toolResult
        case turnEnd
    }

    public let seq: Int
    public let at: Double?            // epoch seconds
    public let kind: Kind
    public let uuid: String?
    public let parentUUID: String?
    public let role: String?          // "user"/"assistant"
    public let name: String?          // tool name, or turn-end reason
    public let toolUseID: String?
    public let isError: Bool
    public let sidechain: Bool
    public let untrusted: Bool
    public let redacted: Bool         // text was redacted/missing due to consent mode
    public let text: String?
    public let model: String?

    public init(seq: Int, at: Double? = nil, kind: Kind,
                uuid: String? = nil, parentUUID: String? = nil,
                role: String? = nil, name: String? = nil,
                toolUseID: String? = nil, isError: Bool = false,
                sidechain: Bool = false, untrusted: Bool = false,
                redacted: Bool = false, text: String? = nil,
                model: String? = nil) {
        self.seq = seq
        self.at = at
        self.kind = kind
        self.uuid = uuid
        self.parentUUID = parentUUID
        self.role = role
        self.name = name
        self.toolUseID = toolUseID
        self.isError = isError
        self.sidechain = sidechain
        self.untrusted = untrusted
        self.redacted = redacted
        self.text = text
        self.model = model
    }
}

/// What went wrong in the session, derived from the reconstructed items.
/// Nothing here is guessed: a clean ending reports `failed == false`, a
/// transcript that stops mid-work reports `diedMidTurn`, and error counts
/// only ever count `isError` items.
public struct FailureStory: Sendable, Equatable {
    public let failed: Bool
    public let errorCount: Int
    public let lastErrorSummary: String?
    public let diedMidTurn: Bool      // last activity has no closing turn_end
    public let lastUserIntent: String?// bounded last user message
    public let failedToolNames: [String]
    /// How long the turn that first failed had run when it failed: from
    /// the last thing you said before the first error to that error. Nil
    /// without a dated error, or with no message of yours before it.
    public let failingTurnSeconds: Double?

    public init(failed: Bool, errorCount: Int, lastErrorSummary: String?,
                diedMidTurn: Bool, lastUserIntent: String?,
                failedToolNames: [String], failingTurnSeconds: Double? = nil) {
        self.failed = failed
        self.errorCount = errorCount
        self.lastErrorSummary = lastErrorSummary
        self.diedMidTurn = diedMidTurn
        self.lastUserIntent = lastUserIntent
        self.failedToolNames = failedToolNames
        self.failingTurnSeconds = failingTurnSeconds
    }
}

/// The reconstruction result: ordered items, the failure story, and the
/// honest gaps — named, never hidden (`malformed_lines:3`,
/// `item_cap:5000`, `unsupported_provider`, `transcript_too_large:N`).
public struct SessionReconstruction: Sendable, Equatable {
    public let items: [ReconstructedItem]
    public let story: FailureStory
    public let gaps: [String]
    public let totalLines: Int

    public init(items: [ReconstructedItem], story: FailureStory,
                gaps: [String], totalLines: Int) {
        self.items = items
        self.story = story
        self.gaps = gaps
        self.totalLines = totalLines
    }
}

/// Rebuilds a timeline from the daemon's `session_timeline` rows and tells
/// the story of how it failed, if it did.
public enum SessionReconstructor {
    private static let intentLimit = 200

    // MARK: Live timelines

    /// The daemon's `session_timeline` items as a reconstruction, so the
    /// Overview inspector and History's expanded rows render one timeline
    /// through one view.
    /// `running` withholds the mid-turn verdict: a session that is still
    /// working ends mid-turn by definition, and calling that a death would
    /// paint every live run as a failure. Unknown kinds are skipped, the
    /// way the transcript projection skips unknown rows.
    public static func reconstruction(from timeline: [CoreTimelineItem], gaps: [String] = [],
                                      running: Bool) -> SessionReconstruction {
        let items: [ReconstructedItem] = timeline.compactMap { item in
            let kind: ReconstructedItem.Kind
            switch item.kind {
            case "message": kind = .message
            case "tool_use": kind = .toolUse
            case "tool_result": kind = .toolResult
            case "turn_end": kind = .turnEnd
            default: return nil
            }
            return ReconstructedItem(
                seq: item.seq, at: item.at, kind: kind, uuid: item.uuid,
                parentUUID: item.parentUuid, role: item.role, name: item.name,
                toolUseID: item.toolUseId, isError: item.isError ?? false,
                sidechain: item.sidechain ?? false, untrusted: item.untrusted ?? false,
                text: item.text, model: item.model)
        }
        return SessionReconstruction(
            items: items, story: story(for: items, running: running), gaps: gaps,
            totalLines: timeline.count)
    }

    // MARK: Failure story

    static func story(for items: [ReconstructedItem], running: Bool = false) -> FailureStory {
        var toolNames: [String: String?] = [:]
        for item in items where item.kind == .toolUse {
            if let id = item.toolUseID, toolNames[id] == nil {
                toolNames.updateValue(item.name, forKey: id)
            }
        }
        let errorItems = items.filter(\.isError)
        let diedMidTurn = !running && !items.isEmpty && items.last?.kind != .turnEnd
        var lastErrorSummary: String? = nil
        if let last = errorItems.last {
            switch last.kind {
            case .turnEnd:
                lastErrorSummary = last.name == "turn_aborted"
                    ? "turn aborted"
                    : bounded(last.name.map { "turn end: \($0)" } ?? last.text)
            case .toolUse, .toolResult:
                let name = last.name ?? last.toolUseID.flatMap { toolNames[$0] ?? nil }
                lastErrorSummary = name.map { "tool `\($0)` failed" }
                    ?? "tool call failed"
            case .message:
                lastErrorSummary = bounded(last.text) ?? "error"
            }
        }
        let lastUserIntent = items.last {
            $0.kind == .message && $0.role == "user"
        }.flatMap { $0.text }.map { String($0.prefix(intentLimit)) }
        var failedToolNames: [String] = []
        var seenNames: Set<String> = []
        for item in errorItems where item.kind == .toolUse || item.kind == .toolResult {
            if let name = item.name ?? item.toolUseID.flatMap({ toolNames[$0] ?? nil }),
               seenNames.insert(name).inserted {
                failedToolNames.append(name)
            }
        }
        return FailureStory(
            failed: !errorItems.isEmpty || diedMidTurn,
            errorCount: errorItems.count,
            lastErrorSummary: lastErrorSummary,
            diedMidTurn: diedMidTurn,
            lastUserIntent: lastUserIntent,
            failedToolNames: failedToolNames,
            failingTurnSeconds: failingTurnSeconds(items))
    }

    /// The first dated error's distance from the last user message before
    /// it — the failing turn's running time when it failed.
    static func failingTurnSeconds(_ items: [ReconstructedItem]) -> Double? {
        guard let index = items.firstIndex(where: { $0.isError && $0.at != nil }),
              let failedAt = items[index].at,
              let asked = items[..<index].last(where: { $0.kind == .message && $0.role == "user" && $0.at != nil })?.at,
              failedAt >= asked else { return nil }
        return failedAt - asked
    }

    private static func bounded(_ text: String?) -> String? {
        text.map { String($0.prefix(intentLimit)) }
    }
}
