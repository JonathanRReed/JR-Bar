import Foundation

// Codable models for protocol 1 (docs/CORE-PROTOCOL.md). Every field the
// document shows is here; everything is optional unless the protocol makes
// it load-bearing, and unknown keys are ignored by construction (Codable
// synthesised decoders never reject extra members). Timestamps are Unix
// epoch seconds, as on the wire.

public enum CoreProtocol {
    public static let version = 1
    /// The newest `settings.schema` this build's controls were written
    /// against; a daemon above it gets a banner in the Settings window
    /// rather than silent blind writes.
    public static let knownSettingsSchema = 3
}

/// Decodes a structured row tolerantly: one malformed row drops out of the
/// list instead of failing the whole document. The daemon's schema moves
/// faster than a pinned decoder, and a version-skew row must not blank the
/// panel — or take the strip's program with it.
private func tolerantRows<T: Decodable>(_ type: T.Type, _ raw: [JSONValue]?) -> [T] {
    (raw ?? []).compactMap { try? ReplyDecoding.decode(T.self, from: $0) }
}

// MARK: - hello

public struct CoreHello: Codable, Hashable, Sendable {
    public var coreVersion: String?
    public var pid: Int?
    public var capabilities: [String]
    /// The daemon incarnation's event stream and its journal's tail
    /// cursor. A reconnect that sees the SAME stream can ask
    /// `replay_events` for the frames the drop ate; a different stream
    /// is a restarted journal — anchor, never replay.
    public var stream: String?
    public var cursor: String?

    public init(coreVersion: String? = nil, pid: Int? = nil, capabilities: [String] = [],
                stream: String? = nil, cursor: String? = nil) {
        self.coreVersion = coreVersion
        self.pid = pid
        self.capabilities = capabilities
        self.stream = stream
        self.cursor = cursor
    }

    enum CodingKeys: String, CodingKey {
        case coreVersion = "core_version"
        case pid
        case capabilities
        case stream
        case cursor
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        coreVersion = try c.decodeIfPresent(String.self, forKey: .coreVersion)
        pid = try c.decodeIfPresent(Int.self, forKey: .pid)
        capabilities = try c.decodeIfPresent([String].self, forKey: .capabilities) ?? []
        stream = try c.decodeIfPresent(String.self, forKey: .stream)
        cursor = try c.decodeIfPresent(String.self, forKey: .cursor)
    }
}

// MARK: - state

public struct CoreAggregate: Codable, Hashable, Sendable {
    public var mode: String
    public var needsYou: Int
    public var active: Int
    public var ready: Int
    /// Sessions in a failed/blocked state — the daemon has always sent it;
    /// the header just never decoded it.
    public var failed: Int

    public init(mode: String = "idle", needsYou: Int = 0, active: Int = 0, ready: Int = 0, failed: Int = 0) {
        self.mode = mode
        self.needsYou = needsYou
        self.active = active
        self.ready = ready
        self.failed = failed
    }

    enum CodingKeys: String, CodingKey {
        case mode
        case needsYou = "needs_you"
        case active
        case ready
        case failed
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        mode = try c.decodeIfPresent(String.self, forKey: .mode) ?? "idle"
        needsYou = try c.decodeIfPresent(Int.self, forKey: .needsYou) ?? 0
        active = try c.decodeIfPresent(Int.self, forKey: .active) ?? 0
        ready = try c.decodeIfPresent(Int.self, forKey: .ready) ?? 0
        failed = try c.decodeIfPresent(Int.self, forKey: .failed) ?? 0
    }
}

public struct CoreOrigin: Codable, Hashable, Sendable {
    public var kind: String?
    public var label: String?
    public var bundleId: String?

    enum CodingKeys: String, CodingKey {
        case kind, label
        case bundleId = "bundle_id"
    }
}

public struct CoreTerminal: Codable, Hashable, Sendable {
    public var app: String?
    public var bundleId: String?
    /// Decoded for forward headroom; nothing displays the tty — the row's
    /// "Open in …" action names `app` only.
    public var tty: String?

    enum CodingKeys: String, CodingKey {
        case app, tty
        case bundleId = "bundle_id"
    }
}

/// A pending question, either pinned in `state.asks` (with `session`) or
/// embedded in the session it belongs to (without).
public struct CoreAsk: Codable, Hashable, Sendable, Identifiable {
    public var session: String?
    public var kind: String?
    public var openedAt: Double?
    public var summary: String?
    /// The daemon's verdict on whether the answer chain can type a reply
    /// into this session (provider capability + a live target). nil on
    /// older daemons — treat as answerable to preserve old behaviour.
    public var answerable: Bool?
    /// Whether this ask accepts free text (a reply field instead of
    /// Approve/Deny).
    public var replyable: Bool?
    /// The exact episode this card answers (`request:v1:{…}`): a card
    /// that pins it has the daemon refuse the answer when the live
    /// request has moved on. nil on older daemons or unmodelled asks.
    public var request: String?
    /// The decide lane's hold: non-nil while the agent's own
    /// PermissionRequest hook is waiting on JR-Bar for a verdict. Such an
    /// ask is answerable from any terminal, and nothing is typed. nil on
    /// older daemons and for asks the lane does not hold.
    public var decision: CoreAskDecision?
    /// One bounded line of what the agent wants to run (the command, the
    /// file, the URL), for a held ask.
    public var preview: String?
    /// `"destructive"` when the command is the kind that loses work if it
    /// runs by mistake; a mark for the card, never a block.
    public var risk: String?

    public var id: String { request ?? ((session ?? "") + "|" + (summary ?? "") + "|" + String(openedAt ?? 0)) }

    /// The agent's hook is holding this ask for JR-Bar's Approve/Deny.
    public var isHeldForDecision: Bool { decision.map { !$0.decided } ?? false }
    /// Still held at `now`: false once `hold_until` has come, when the
    /// agent's own prompt carries on and Always and the choices lapse
    /// with the hold. A hold with no deadline lasts until the daemon
    /// says it was decided.
    public func isHeld(at now: Date) -> Bool {
        guard isHeldForDecision else { return false }
        guard let holdUntil = decision?.holdUntil else { return true }
        return holdUntil > now.timeIntervalSince1970
    }
    /// Whether an "Always allow" (`answer_ask` decision `always`) can be sent.
    public var canAlwaysAllow: Bool { isHeldForDecision && (decision?.always ?? false) }
    /// A held multiple-choice ask: its options can be picked from any
    /// terminal (`answer_ask` decision `answer` with `answers`). Approve
    /// and Deny keep following `canAnswer`.
    public var canChoose: Bool { isHeldForDecision && !(decision?.choices.isEmpty ?? true) }
    public var isDestructive: Bool { risk == "destructive" }

    /// What the buttons may claim: assume yes when the daemon is too old
    /// to say, so nothing regresses against pre-0.8.2 cores.
    public var canAnswer: Bool { answerable ?? true }
    public var wantsTextReply: Bool { replyable ?? false }

    public init(session: String? = nil, kind: String? = nil, openedAt: Double? = nil, summary: String? = nil,
                answerable: Bool? = nil, replyable: Bool? = nil, request: String? = nil,
                decision: CoreAskDecision? = nil, preview: String? = nil, risk: String? = nil) {
        self.session = session
        self.kind = kind
        self.openedAt = openedAt
        self.summary = summary
        self.answerable = answerable
        self.replyable = replyable
        self.request = request
        self.decision = decision
        self.preview = preview
        self.risk = risk
    }

    enum CodingKeys: String, CodingKey {
        case session, kind, summary, answerable, replyable, request
        case decision, preview, risk
        case openedAt = "opened_at"
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        session = try c.decodeIfPresent(String.self, forKey: .session)
        kind = try c.decodeIfPresent(String.self, forKey: .kind)
        openedAt = try c.decodeIfPresent(Double.self, forKey: .openedAt)
        summary = try c.decodeIfPresent(String.self, forKey: .summary)
        answerable = try c.decodeIfPresent(Bool.self, forKey: .answerable)
        replyable = try c.decodeIfPresent(Bool.self, forKey: .replyable)
        request = try c.decodeIfPresent(String.self, forKey: .request)
        decision = try? c.decodeIfPresent(CoreAskDecision.self, forKey: .decision)
        preview = try? c.decodeIfPresent(String.self, forKey: .preview)
        risk = try? c.decodeIfPresent(String.self, forKey: .risk)
    }
}

/// `ask.decision` (docs/CORE-PROTOCOL.md, "The decide lane").
public struct CoreAskDecision: Codable, Hashable, Sendable {
    /// Epoch at which the hold lapses and the agent's own prompt carries on.
    public var holdUntil: Double?
    /// An "Always allow" can be sent (Claude, with an allow rule offered).
    public var always: Bool
    /// Answered a moment ago; the provider's events have not caught up.
    public var decided: Bool
    /// The questions of a held multiple-choice ask (Claude's
    /// AskUserQuestion), in the agent's order. Empty for a yes/no ask.
    public var choices: [CoreAskChoice]

    public init(holdUntil: Double? = nil, always: Bool = false, decided: Bool = false,
                choices: [CoreAskChoice] = []) {
        self.holdUntil = holdUntil
        self.always = always
        self.decided = decided
        self.choices = choices
    }

    enum CodingKeys: String, CodingKey {
        case always, decided, choices
        case holdUntil = "hold_until"
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        holdUntil = try? c.decodeIfPresent(Double.self, forKey: .holdUntil)
        always = (try? c.decodeIfPresent(Bool.self, forKey: .always)) ?? false
        decided = (try? c.decodeIfPresent(Bool.self, forKey: .decided)) ?? false
        choices = (try? c.decodeIfPresent([CoreAskChoice].self, forKey: .choices)) ?? []
    }
}

/// One question of a held multiple-choice ask (`ask.decision.choices[]`).
/// The answer names `question` exactly and picks from `options` exactly:
/// `answers: {question: label}`, or a list of labels when `multi`.
public struct CoreAskChoice: Codable, Hashable, Sendable {
    public var question: String
    /// The agent's short chip for the question ("Framework"), when given.
    public var header: String?
    public var options: [String]
    public var multi: Bool

    public init(question: String, header: String? = nil, options: [String], multi: Bool = false) {
        self.question = question
        self.header = header
        self.options = options
        self.multi = multi
    }
}

public struct CoreSession: Codable, Hashable, Sendable, Identifiable {
    public var id: String
    public var provider: String
    public var kind: String
    public var parent: String?
    public var label: String?
    /// The daemon's 8-character handle for the session (`short_id`), shown
    /// when the label is missing or is itself a UUID.
    public var shortId: String?
    public var cwd: String?
    /// Decoded for `SessionActivity.reduce` and the light explainer; the
    /// raw word is never displayed.
    public var mode: String?
    /// Decoded for `SessionActivity.reduce` and the light explainer; the
    /// raw word is never displayed.
    public var lifecycle: String?
    /// Decoded for `SessionActivity.reduce` (`user` counts as waiting);
    /// never displayed verbatim.
    public var nextActor: String?
    public var since: Double?
    /// Decoded for the light explainer's ordering and "… ago" phrasing;
    /// not itself displayed.
    public var updatedAt: Double?
    public var stale: Bool
    public var pid: Int?
    public var origin: CoreOrigin?
    public var ask: CoreAsk?
    public var terminal: CoreTerminal?
    public var workers: Int
    /// The family mailbox's active snooze (`snoozed_until`), when one
    /// covers this session.
    public var snoozedUntil: Double?
    /// A peer Mac's row (`remote:<machine>:` id namespace): not locally
    /// actionable — nothing here can raise its window or type its answer.
    public var remote: Bool
    /// The hook's last word for the session: the canonical event name
    /// (`PreToolUse`, `PostToolUse`, …), the tool it was about when one
    /// applied, and the message it carried. Facts, not state — a finished
    /// row's `event` is history rather than something happening now, and
    /// `message` can carry agent prose, so it needs bounding before it
    /// renders anywhere.
    public var event: String?
    public var tool: String?
    public var message: String?
    /// The separated record axes on the live session row — the same
    /// `session_axes` the roster carries, so a surface reading
    /// `state.sessions` (the tank) sees review/freshness without a
    /// roster fetch. nil on older daemons.
    public var axes: CoreSessionAxes?

    public init(id: String, provider: String, kind: String = "main", parent: String? = nil, label: String? = nil,
                shortId: String? = nil, cwd: String? = nil, mode: String? = nil, lifecycle: String? = nil, nextActor: String? = nil,
                since: Double? = nil, updatedAt: Double? = nil, stale: Bool = false, pid: Int? = nil,
                origin: CoreOrigin? = nil, ask: CoreAsk? = nil, terminal: CoreTerminal? = nil, workers: Int = 0,
                snoozedUntil: Double? = nil, remote: Bool = false,
                event: String? = nil, tool: String? = nil, message: String? = nil,
                axes: CoreSessionAxes? = nil) {
        self.id = id
        self.provider = provider
        self.kind = kind
        self.parent = parent
        self.label = label
        self.shortId = shortId
        self.cwd = cwd
        self.mode = mode
        self.lifecycle = lifecycle
        self.nextActor = nextActor
        self.since = since
        self.updatedAt = updatedAt
        self.stale = stale
        self.pid = pid
        self.origin = origin
        self.ask = ask
        self.terminal = terminal
        self.workers = workers
        self.snoozedUntil = snoozedUntil
        self.remote = remote
        self.event = event
        self.tool = tool
        self.message = message
        self.axes = axes
    }

    enum CodingKeys: String, CodingKey {
        case id, provider, kind, parent, label, cwd, mode, lifecycle, since, stale, pid, origin, ask, terminal, workers, remote
        case event, tool, message, axes
        case shortId = "short_id"
        case nextActor = "next_actor"
        case updatedAt = "updated_at"
        case snoozedUntil = "snoozed_until"
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        provider = try c.decodeIfPresent(String.self, forKey: .provider) ?? "unknown"
        kind = try c.decodeIfPresent(String.self, forKey: .kind) ?? "main"
        parent = try c.decodeIfPresent(String.self, forKey: .parent)
        label = try c.decodeIfPresent(String.self, forKey: .label)
        shortId = try c.decodeIfPresent(String.self, forKey: .shortId)
        cwd = try c.decodeIfPresent(String.self, forKey: .cwd)
        mode = try c.decodeIfPresent(String.self, forKey: .mode)
        lifecycle = try c.decodeIfPresent(String.self, forKey: .lifecycle)
        nextActor = try c.decodeIfPresent(String.self, forKey: .nextActor)
        since = try c.decodeIfPresent(Double.self, forKey: .since)
        updatedAt = try c.decodeIfPresent(Double.self, forKey: .updatedAt)
        stale = try c.decodeIfPresent(Bool.self, forKey: .stale) ?? false
        pid = try c.decodeIfPresent(Int.self, forKey: .pid)
        origin = try c.decodeIfPresent(CoreOrigin.self, forKey: .origin)
        ask = try c.decodeIfPresent(CoreAsk.self, forKey: .ask)
        terminal = try c.decodeIfPresent(CoreTerminal.self, forKey: .terminal)
        workers = try c.decodeIfPresent(Int.self, forKey: .workers) ?? 0
        snoozedUntil = try c.decodeIfPresent(Double.self, forKey: .snoozedUntil)
        remote = (try? c.decodeIfPresent(Bool.self, forKey: .remote)) ?? false
        event = try c.decodeIfPresent(String.self, forKey: .event)
        tool = try c.decodeIfPresent(String.self, forKey: .tool)
        message = try c.decodeIfPresent(String.self, forKey: .message)
        axes = try? c.decodeIfPresent(CoreSessionAxes.self, forKey: .axes)
    }
}

// MARK: Roster (W02/W08)

/// `list_roster`'s separated record axes (S7.3): execution outcome,
/// review state and freshness are three facts, never one colour.
public struct CoreSessionAxes: Codable, Hashable, Sendable {
    /// `succeeded` / `failed` / `unreported` (ended with no terminal
    /// word) / `none` (still running) / `unknown`.
    public var outcome: String?
    /// `pending` (still running) / `unreviewed` / `reviewed`.
    public var review: String?
    /// `live` / `delayed` / `unknown` — how fresh the row's own clock is,
    /// independent of outcome.
    public var freshness: String?

    public init(outcome: String? = nil, review: String? = nil, freshness: String? = nil) {
        self.outcome = outcome
        self.review = review
        self.freshness = freshness
    }
}

/// One `list_roster` row: the same `session_document` the panel shows,
/// plus the roster-only facts the panel's filter would have hidden.
public struct CoreRosterEntry: Codable, Hashable, Sendable, Identifiable {
    public var session: CoreSession
    /// `activity_model.RECORD_SCHEMA_VERSION` the daemon wrote.
    public var schema: Int
    /// A live ask pins the row against panel aging.
    public var pinned: Bool
    /// What the panel's aging filter would do with this row
    /// (`live` / `completion` / `hidden`) — a fact about the row, never a
    /// removal of it.
    public var visibility: String?
    public var axes: CoreSessionAxes?

    public var id: String { session.id }

    public init(session: CoreSession, schema: Int = 0, pinned: Bool = false,
                visibility: String? = nil, axes: CoreSessionAxes? = nil) {
        self.session = session
        self.schema = schema
        self.pinned = pinned
        self.visibility = visibility
        self.axes = axes
    }

    enum CodingKeys: String, CodingKey { case schema, pinned, visibility, axes }

    public init(from decoder: Decoder) throws {
        session = try CoreSession(from: decoder)
        let c = try decoder.container(keyedBy: CodingKeys.self)
        schema = (try? c.decodeIfPresent(Int.self, forKey: .schema)) ?? 0
        pinned = (try? c.decodeIfPresent(Bool.self, forKey: .pinned)) ?? false
        visibility = try? c.decodeIfPresent(String.self, forKey: .visibility)
        axes = try? c.decodeIfPresent(CoreSessionAxes.self, forKey: .axes)
    }
}

/// `list_roster`'s totals over the FULL retained set — computed before
/// scoping, so a scoped answer still reports what exists.
public struct CoreRosterCounts: Codable, Hashable, Sendable {
    public var total: Int
    public var workers: Int
    /// Rows carrying a live ask.
    public var attention: Int
    public var live: Int
    public var finished: Int
    /// Rows the panel's aging would hide — the roster's independence
    /// made visible.
    public var hiddenFromPanel: Int
    /// How many rows this scoped answer carried — `total` minus the
    /// scope cut.
    public var listed: Int

    enum CodingKeys: String, CodingKey {
        case total, workers, attention, live, finished, listed
        case hiddenFromPanel = "hidden_from_panel"
    }

    public init(total: Int = 0, workers: Int = 0, attention: Int = 0, live: Int = 0,
                finished: Int = 0, hiddenFromPanel: Int = 0, listed: Int = 0) {
        self.total = total
        self.workers = workers
        self.attention = attention
        self.live = live
        self.finished = finished
        self.hiddenFromPanel = hiddenFromPanel
        self.listed = listed
    }
}

/// The `list_roster` answer: the scoped cut plus the honest bounds.
public struct CoreRoster: Codable, Hashable, Sendable {
    public var sessions: [CoreRosterEntry]
    public var counts: CoreRosterCounts
    /// What the roster covers (the collector's retention); deeper
    /// history is `list_history`'s job — the document says so.
    public var coverage: JSONValue?

    public init(sessions: [CoreRosterEntry] = [], counts: CoreRosterCounts = CoreRosterCounts(),
                coverage: JSONValue? = nil) {
        self.sessions = sessions
        self.counts = counts
        self.coverage = coverage
    }

    enum CodingKeys: String, CodingKey { case sessions, counts, coverage }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        sessions = tolerantRows(
            CoreRosterEntry.self,
            try c.decodeIfPresent([JSONValue].self, forKey: .sessions)
        )
        counts = (try? c.decodeIfPresent(CoreRosterCounts.self, forKey: .counts)) ?? CoreRosterCounts()
        coverage = try? c.decodeIfPresent(JSONValue.self, forKey: .coverage)
    }
}

/// One `session_timeline` item — a transcript row projected for the
/// inspector: message, tool_use/tool_result (paired by `toolUseId`),
/// turn_end. `at` is the row's own stamp (occurrence); `recordedAt`
/// stays nil — per-row ingestion time was never kept (S7.2).
public struct CoreTimelineItem: Codable, Hashable, Sendable, Identifiable {
    public var id: Int { seq }
    public var seq: Int
    public var at: Double?
    /// Always nil on transcript rows — ingestion time is not recorded.
    public var recordedAt: Double?
    public var kind: String
    public var role: String?
    public var name: String?
    public var text: String?
    public var toolUseId: String?
    public var isError: Bool?
    public var sidechain: Bool?
    public var model: String?
    public var uuid: String?
    public var parentUuid: String?
    public var origin: String?
    /// Tool output and assistant text are untrusted content — never
    /// rendered as a command or an approval (T44).
    public var untrusted: Bool?

    enum CodingKeys: String, CodingKey {
        case seq, at, kind, role, name, text, model, uuid, origin, untrusted
        case recordedAt = "recorded_at"
        case toolUseId = "tool_use_id"
        case isError = "is_error"
        case sidechain
        case parentUuid = "parent_uuid"
    }

    public init(seq: Int, at: Double? = nil, kind: String, role: String? = nil,
                name: String? = nil, text: String? = nil, toolUseId: String? = nil,
                isError: Bool? = nil, sidechain: Bool? = nil, model: String? = nil,
                uuid: String? = nil, parentUuid: String? = nil,
                origin: String? = nil, untrusted: Bool? = nil,
                recordedAt: Double? = nil) {
        self.seq = seq
        self.at = at
        self.recordedAt = recordedAt
        self.kind = kind
        self.role = role
        self.name = name
        self.text = text
        self.toolUseId = toolUseId
        self.isError = isError
        self.sidechain = sidechain
        self.model = model
        self.uuid = uuid
        self.parentUuid = parentUuid
        self.origin = origin
        self.untrusted = untrusted
    }
}

/// A `session_timeline` page: the newest `limit` items before the
/// caller's `before` cursor, the next cursor for an older page, and the
/// named gaps (`transcript_not_found`, `unsupported_provider`,
/// `timeline_item_cap:N`).
public struct CoreTimelinePage: Codable, Hashable, Sendable {
    public var events: [CoreTimelineItem]
    public var hasMore: Bool
    public var nextBefore: Int?
    public var total: Int
    public var provider: String?
    public var file: String?
    public var gaps: [String]

    public init(events: [CoreTimelineItem] = [], hasMore: Bool = false,
                nextBefore: Int? = nil, total: Int = 0,
                provider: String? = nil, file: String? = nil,
                gaps: [String] = []) {
        self.events = events
        self.hasMore = hasMore
        self.nextBefore = nextBefore
        self.total = total
        self.provider = provider
        self.file = file
        self.gaps = gaps
    }

    enum CodingKeys: String, CodingKey {
        case events, gaps, total, source
        case hasMore = "has_more"
        case nextBefore = "next_before"
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        events = tolerantRows(
            CoreTimelineItem.self,
            try c.decodeIfPresent([JSONValue].self, forKey: .events)
        )
        hasMore = (try? c.decodeIfPresent(Bool.self, forKey: .hasMore)) ?? false
        nextBefore = try? c.decodeIfPresent(Int.self, forKey: .nextBefore)
        total = (try? c.decodeIfPresent(Int.self, forKey: .total)) ?? events.count
        gaps = (try? c.decodeIfPresent([String].self, forKey: .gaps)) ?? []
        let source = try? c.decodeIfPresent(JSONValue.self, forKey: .source)
        provider = source?["provider"]?.stringValue
        file = source?["file"]?.stringValue
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(events, forKey: .events)
        try c.encode(hasMore, forKey: .hasMore)
        try c.encodeIfPresent(nextBefore, forKey: .nextBefore)
        try c.encode(total, forKey: .total)
        try c.encode(gaps, forKey: .gaps)
        var source: [String: JSONValue] = [:]
        if let provider { source["provider"] = .string(provider) }
        if let file { source["file"] = .string(file) }
        try c.encode(JSONValue.object(source), forKey: .source)
    }
}

/// One side of a `compare_sessions` document: the roster row's axes,
/// the transcript aggregate, and the ledger's interruption counts.
/// `activity` is nil with a named gap when no transcript exists;
/// `artifacts` is the files the run's edit tools named once its
/// transcript was read (nil otherwise); `model` is always nil.
public struct CoreRunSide: Codable, Hashable, Sendable {
    public var id: String
    public var label: String?
    public var provider: String?
    public var cwd: String?
    public var lifecycle: String?
    public var mode: String?
    public var axes: CoreSessionAxes?
    public var remote: Bool
    public var activity: CoreRunActivity?
    public var interruptions: CoreRunInterruptions
    public var artifacts: CoreRunArtifacts?
    public var gaps: [String]

    enum CodingKeys: String, CodingKey {
        case id, label, provider, cwd, lifecycle, mode, axes, remote
        case activity, interruptions, artifacts, gaps
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        label = try? c.decodeIfPresent(String.self, forKey: .label)
        provider = try? c.decodeIfPresent(String.self, forKey: .provider)
        cwd = try? c.decodeIfPresent(String.self, forKey: .cwd)
        lifecycle = try? c.decodeIfPresent(String.self, forKey: .lifecycle)
        mode = try? c.decodeIfPresent(String.self, forKey: .mode)
        axes = try? c.decodeIfPresent(CoreSessionAxes.self, forKey: .axes)
        remote = (try? c.decodeIfPresent(Bool.self, forKey: .remote)) ?? false
        activity = try? c.decodeIfPresent(CoreRunActivity.self, forKey: .activity)
        interruptions = (try? c.decodeIfPresent(CoreRunInterruptions.self, forKey: .interruptions))
            ?? CoreRunInterruptions()
        artifacts = try? c.decodeIfPresent(CoreRunArtifacts.self, forKey: .artifacts)
        gaps = (try? c.decodeIfPresent([String].self, forKey: .gaps)) ?? []
    }
}

/// The transcript aggregate for one side: message/tool counts, tool
/// failures and retried calls, the tool histogram, and the run's span.
public struct CoreRunActivity: Codable, Hashable, Sendable {
    public var userMessages: Int
    public var assistantMessages: Int
    public var toolUses: Int
    public var toolFailures: Int
    public var retriedTools: Int
    public var turnEnds: Int
    public var sidechainRows: Int
    public var tools: [String: Int]
    public var span: CoreRunSpan?
    public var file: String?

    enum CodingKeys: String, CodingKey {
        case counts, tools, span, file
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let counts = try? c.decodeIfPresent(JSONValue.self, forKey: .counts)
        userMessages = counts?["user_messages"]?.intValue ?? 0
        assistantMessages = counts?["assistant_messages"]?.intValue ?? 0
        toolUses = counts?["tool_uses"]?.intValue ?? 0
        toolFailures = counts?["tool_failures"]?.intValue ?? 0
        retriedTools = counts?["retried_tools"]?.intValue ?? 0
        turnEnds = counts?["turn_ends"]?.intValue ?? 0
        sidechainRows = counts?["sidechain_rows"]?.intValue ?? 0
        tools = (try? c.decodeIfPresent([String: Int].self, forKey: .tools)) ?? [:]
        span = try? c.decodeIfPresent(CoreRunSpan.self, forKey: .span)
        file = try? c.decodeIfPresent(String.self, forKey: .file)
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(JSONValue.object([
            "user_messages": .number(Double(userMessages)),
            "assistant_messages": .number(Double(assistantMessages)),
            "tool_uses": .number(Double(toolUses)),
            "tool_failures": .number(Double(toolFailures)),
            "retried_tools": .number(Double(retriedTools)),
            "turn_ends": .number(Double(turnEnds)),
            "sidechain_rows": .number(Double(sidechainRows)),
        ]), forKey: .counts)
        try c.encode(tools, forKey: .tools)
        try c.encodeIfPresent(span, forKey: .span)
        try c.encodeIfPresent(file, forKey: .file)
    }
}

/// `span{first_at,last_at,duration_s}` — the transcript's own bounds.
public struct CoreRunSpan: Codable, Hashable, Sendable {
    public var firstAt: Double?
    public var lastAt: Double?
    public var durationS: Double?

    enum CodingKeys: String, CodingKey {
        case firstAt = "first_at", lastAt = "last_at", durationS = "duration_s"
    }

    public init(firstAt: Double? = nil, lastAt: Double? = nil, durationS: Double? = nil) {
        self.firstAt = firstAt
        self.lastAt = lastAt
        self.durationS = durationS
    }
}

/// Ledger-derived interruption counts for the run's agent id.
public struct CoreRunInterruptions: Codable, Hashable, Sendable {
    public var asked: Int
    public var blocked: Int
    public var completed: Int

    public init(asked: Int = 0, blocked: Int = 0, completed: Int = 0) {
        self.asked = asked
        self.blocked = blocked
        self.completed = completed
    }
}

/// `compare_sessions`: two sides plus `shared` facts and `warnings` —
/// `not_a_controlled_benchmark` is always present (S7.4: uncontrolled
/// runs are not a fair model comparison).
public struct CoreRunComparison: Codable, Hashable, Sendable {
    public var a: CoreRunSide
    public var b: CoreRunSide
    public var sharedProvider: Bool
    public var sharedWorkspace: Bool
    /// Always nil — the roster tracks no per-session model.
    public var sharedModel: Bool?
    public var warnings: [String]
    public var gaps: [String]
    public var generatedAt: Double?

    enum CodingKeys: String, CodingKey {
        case a, b, warnings, gaps, shared
        case generatedAt = "generated_at"
    }

    private enum SharedKeys: String, CodingKey { case provider, workspace, model }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        a = try c.decode(CoreRunSide.self, forKey: .a)
        b = try c.decode(CoreRunSide.self, forKey: .b)
        warnings = (try? c.decodeIfPresent([String].self, forKey: .warnings)) ?? []
        gaps = (try? c.decodeIfPresent([String].self, forKey: .gaps)) ?? []
        generatedAt = try? c.decodeIfPresent(Double.self, forKey: .generatedAt)
        let shared = try? c.nestedContainer(keyedBy: SharedKeys.self, forKey: .shared)
        sharedProvider = (try? shared?.decodeIfPresent(Bool.self, forKey: .provider)) ?? false
        sharedWorkspace = (try? shared?.decodeIfPresent(Bool.self, forKey: .workspace)) ?? false
        sharedModel = try? shared?.decodeIfPresent(Bool.self, forKey: .model)
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(a, forKey: .a)
        try c.encode(b, forKey: .b)
        try c.encode(warnings, forKey: .warnings)
        try c.encode(gaps, forKey: .gaps)
        try c.encodeIfPresent(generatedAt, forKey: .generatedAt)
        var shared = c.nestedContainer(keyedBy: SharedKeys.self, forKey: .shared)
        try shared.encode(sharedProvider, forKey: .provider)
        try shared.encode(sharedWorkspace, forKey: .workspace)
        try shared.encodeIfPresent(sharedModel, forKey: .model)
    }
}

/// The `replay_events` reply for the Replay surface: journaled event
/// frames plus the coverage the view must state — `retained`/`dropped`
/// are the journal's bounds, `resyncRequired`+`reason` the honest
/// refusal a foreign/expired cursor gets.
public struct CoreReplayPage: Hashable, Sendable {
    public var events: [CoreEvent]
    public var stream: String?
    public var retained: Int
    public var dropped: Int
    public var resyncRequired: Bool
    public var reason: String?
    public var cursor: String?

    public init(events: [CoreEvent] = [], stream: String? = nil,
                retained: Int = 0, dropped: Int = 0,
                resyncRequired: Bool = false, reason: String? = nil,
                cursor: String? = nil) {
        self.events = events
        self.stream = stream
        self.retained = retained
        self.dropped = dropped
        self.resyncRequired = resyncRequired
        self.reason = reason
        self.cursor = cursor
    }
}

public struct CoreDevice: Codable, Hashable, Sendable, Identifiable {
    public var id: String
    public var kind: String
    public var name: String?
    public var path: String?
    public var leds: Int?
    public var connected: Bool?
    public var enabled: Bool?
    /// As sent: the Pro reports a percent (79), the lights document a
    /// fraction (0.79). `brightnessFraction` normalises.
    public var brightness: Double?
    public var linked: Bool?
    /// Decoded for forward headroom; nothing displays the device's last
    /// write time.
    public var lastWrite: Double?
    public var error: String?
    /// How the writes are going (`state.devices[].write_health`), nil
    /// before the first one: the card can say why the strip looks wrong.
    public var writeHealth: CoreWriteHealth?

    public init(id: String, kind: String, name: String? = nil, path: String? = nil, leds: Int? = nil,
                connected: Bool? = nil, enabled: Bool? = nil, brightness: Double? = nil, linked: Bool? = nil,
                lastWrite: Double? = nil, error: String? = nil, writeHealth: CoreWriteHealth? = nil) {
        self.id = id
        self.kind = kind
        self.name = name
        self.path = path
        self.leds = leds
        self.connected = connected
        self.enabled = enabled
        self.brightness = brightness
        self.linked = linked
        self.lastWrite = lastWrite
        self.error = error
        self.writeHealth = writeHealth
    }

    public var brightnessFraction: Double? {
        guard let brightness else { return nil }
        return brightness > 1.0 ? min(1, brightness / 100.0) : max(0, brightness)
    }

    /// Screen Bar rows say `enabled`, hardware rows say `connected`.
    public var isPresent: Bool { connected ?? enabled ?? false }

    enum CodingKeys: String, CodingKey {
        case id, kind, name, path, leds, connected, enabled, brightness, linked, error
        case lastWrite = "last_write"
        case writeHealth = "write_health"
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        kind = try c.decodeIfPresent(String.self, forKey: .kind) ?? "unknown"
        name = try c.decodeIfPresent(String.self, forKey: .name)
        path = try c.decodeIfPresent(String.self, forKey: .path)
        leds = try c.decodeIfPresent(Int.self, forKey: .leds)
        connected = try c.decodeIfPresent(Bool.self, forKey: .connected)
        enabled = try c.decodeIfPresent(Bool.self, forKey: .enabled)
        brightness = try c.decodeIfPresent(Double.self, forKey: .brightness)
        linked = try c.decodeIfPresent(Bool.self, forKey: .linked)
        lastWrite = try c.decodeIfPresent(Double.self, forKey: .lastWrite)
        error = try c.decodeIfPresent(String.self, forKey: .error)
        // Tolerant: a malformed health line must never cost the device row.
        writeHealth = try? c.decodeIfPresent(CoreWriteHealth.self, forKey: .writeHealth)
    }
}

/// `state.devices[].write_health`: the last write's latency, how many
/// programs the safety compiler had to change, and how many never reached
/// the device -- with the last refusal's reason. Counts since the daemon
/// started.
public struct CoreWriteHealth: Codable, Hashable, Sendable {
    public var latencyMs: Int?
    public var writes: Int?
    public var transformed: Int?
    public var refused: Int?
    public var lastRefusal: String?
    public var lastRefusalAt: Double?
    /// The latest attempt never reached the device: failing now, not once.
    public var failing: Bool?

    enum CodingKeys: String, CodingKey {
        case writes, transformed, refused, failing
        case latencyMs = "latency_ms"
        case lastRefusal = "last_refusal"
        case lastRefusalAt = "last_refusal_at"
    }
}

/// One usage window of one provider.
///
/// A window the account does not have is **absent** — no entry at all. A
/// window that exists but whose provider stated no number is **unknown**:
/// it arrives with `used_pct: null`, and `usedPct` is nil. Reading that as
/// zero drew a full green bar and said "plenty left" about a window nobody
/// had measured, which is a confident lie; every consumer has to render it
/// as unknown (CORE-PROTOCOL, "Three states, never two").
public struct CoreUsageWindow: Codable, Hashable, Sendable, Identifiable {
    /// The daemon's window key (`five-hour`, `weekly`, `daily`, `credits`, …) when it sends one.
    public var key: String?
    public var name: String
    /// How much of the window is spent, 0…100 — nil when the provider
    /// stated no number. Never substitute a number for nil.
    public var usedPct: Double?
    public var resetsAt: Double?
    /// Per-window pace projection; the daemon emits it for every measured
    /// window, not only the primary one.
    public var forecast: CoreUsageForecast?
    /// False when the provider's own catalog does not know this lane:
    /// evidence, never an applicable constraint (it must not drive the
    /// featured-window pick or an interruption).
    public var bindable: Bool

    public var id: String { key ?? name }

    /// The panel's short label for the window: `5h`, `7d`, `Daily`, `Monthly`, `Credits`.
    public var shortName: String { UsageWindowLabel.short(id: key, name: name) }

    /// The expanded label for captions and tooltips: `5-hour`, `7-day`, or
    /// the daemon's own name when it is already a word.
    public var longName: String { UsageWindowLabel.long(id: key, name: name) }

    /// The window exists and nobody said how full it is.
    public var isUnknown: Bool { usedPct == nil }

    /// The percent column: `42%`, or an em dash when there is no reading.
    /// Every surface uses the same two characters for "unknown".
    public var percentText: String { UsageWindowLabel.percent(usedPct) }

    /// What VoiceOver and the tooltips say: "42 percent used", or
    /// "no reading" — never "0 percent used".
    public var spokenPercent: String { UsageWindowLabel.spoken(usedPct) }

    public init(key: String? = nil, name: String, usedPct: Double?, resetsAt: Double? = nil,
                forecast: CoreUsageForecast? = nil, bindable: Bool = true) {
        self.key = key
        self.name = name
        self.usedPct = usedPct
        self.resetsAt = resetsAt
        self.forecast = forecast
        self.bindable = bindable
    }

    enum CodingKeys: String, CodingKey {
        case name, bindable
        case key = "id"
        case usedPct = "used_pct"
        case resetsAt = "resets_at"
        case forecast
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        key = try c.decodeIfPresent(String.self, forKey: .key)
        name = try c.decodeIfPresent(String.self, forKey: .name) ?? key ?? "?"
        // `null` is the daemon saying "the window exists, nobody measured
        // it". A malformed value is no better a reading than a missing one,
        // and neither may become a number.
        let raw = (try? c.decodeIfPresent(Double.self, forKey: .usedPct)) ?? nil
        usedPct = raw.flatMap { $0.isFinite ? $0 : nil }
        resetsAt = try c.decodeIfPresent(Double.self, forKey: .resetsAt)
        forecast = try? c.decodeIfPresent(CoreUsageForecast.self, forKey: .forecast)
        bindable = (try? c.decodeIfPresent(Bool.self, forKey: .bindable)) ?? true
    }
}

public struct CoreUsageForecast: Codable, Hashable, Sendable {
    public var exhaustsAt: Double?
    public var pace: String?
    /// Why a `guarded` pace has no date (T28): `insufficient_samples`,
    /// `insufficient_span`, `reset_boundary`, `stale_samples`,
    /// `clock_regressed`. Nil on a real pace.
    public var reason: String?
    public var samples: Int?
    public var ratePctPerHour: Double?

    public init(exhaustsAt: Double? = nil, pace: String? = nil, reason: String? = nil,
                samples: Int? = nil, ratePctPerHour: Double? = nil) {
        self.exhaustsAt = exhaustsAt
        self.pace = pace
        self.reason = reason
        self.samples = samples
        self.ratePctPerHour = ratePctPerHour
    }

    enum CodingKeys: String, CodingKey {
        case pace, reason, samples
        case exhaustsAt = "exhausts_at"
        case ratePctPerHour = "rate_pct_per_hour"
    }
}

/// `usage.providers[].tokens`: the provider's own counters at
/// `observed_at` — input, cached-input and output tokens for whatever
/// period the provider reports on. They ride the provider's `fidelity`:
/// a stale or derived snapshot's counts are stale or derived counts, and
/// a snapshot that counted nothing sends zeroes rather than omitting the
/// block.
public struct CoreUsageTokens: Codable, Hashable, Sendable {
    public var input: Int
    public var cachedInput: Int
    public var output: Int

    /// Everything the provider counted, cache reads included.
    public var total: Int { input + cachedInput + output }

    public init(input: Int = 0, cachedInput: Int = 0, output: Int = 0) {
        self.input = input
        self.cachedInput = cachedInput
        self.output = output
    }

    enum CodingKeys: String, CodingKey {
        case input, output
        case cachedInput = "cached_input"
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        // Counters are integers on the wire; a daemon that sends a float
        // loses nothing by having it truncated.
        func counter(_ key: CodingKeys) -> Int {
            if let value = try? c.decodeIfPresent(Int.self, forKey: key) { return max(0, value) }
            if let value = try? c.decodeIfPresent(Double.self, forKey: key), value.isFinite { return max(0, Int(value)) }
            return 0
        }
        input = counter(.input)
        cachedInput = counter(.cachedInput)
        output = counter(.output)
    }
}

/// The daemon's pick for "the lane worth watching" (S6.4): the least
/// headroom among windows the provider's own catalog knows (`bindable`)
/// and actually measured. `reason` is `only_measured` or
/// `least_headroom`; `candidates` is how many windows were eligible.
public struct CoreConstrainedLane: Codable, Hashable, Sendable {
    public var id: String?
    public var name: String
    public var usedPct: Double?
    public var resetsAt: Double?
    public var reason: String?
    public var candidates: Int

    public init(id: String? = nil, name: String, usedPct: Double? = nil, resetsAt: Double? = nil,
                reason: String? = nil, candidates: Int = 0) {
        self.id = id
        self.name = name
        self.usedPct = usedPct
        self.resetsAt = resetsAt
        self.reason = reason
        self.candidates = candidates
    }

    enum CodingKeys: String, CodingKey {
        case id, name, reason, candidates
        case usedPct = "used_pct"
        case resetsAt = "resets_at"
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try? c.decodeIfPresent(String.self, forKey: .id)
        name = (try? c.decodeIfPresent(String.self, forKey: .name)) ?? "?"
        usedPct = try? c.decodeIfPresent(Double.self, forKey: .usedPct)
        resetsAt = try? c.decodeIfPresent(Double.self, forKey: .resetsAt)
        reason = try? c.decodeIfPresent(String.self, forKey: .reason)
        candidates = (try? c.decodeIfPresent(Int.self, forKey: .candidates)) ?? 0
    }

    /// One clause explaining the pick — never a bare enum word.
    public var explanation: String {
        switch reason {
        case "only_measured": return "the only measured window"
        case "least_headroom":
            return candidates > 1 ? "least headroom of \(candidates) measured windows" : "least headroom"
        default: return "most constrained window"
        }
    }
}

public struct CoreProviderUsage: Codable, Hashable, Sendable, Identifiable {
    public var id: String
    public var windows: [CoreUsageWindow]
    public var fidelity: String?
    public var state: String?
    public var forecast: CoreUsageForecast?
    /// Plan, account label and fidelity when the daemon knows them
    /// (app-proposed; `usage_history` carries the same block).
    public var account: UsageAccount?
    /// The daemon's fix-it hint when the source is not `ready` ("Reconnect
    /// Claude", "Run grok login") and the reason word behind it
    /// (`authentication_required`, `browser_session_not_imported`).
    public var action: String?
    public var reason: String?
    /// Which configured account this reading belongs to — two accounts of
    /// one provider arrive as two rows sharing `id`, distinguished here.
    public var instance: String?
    /// False when the provider has no quota source at all (Pi, Kiro, …):
    /// a "meters" checkbox for it would be a dead control.
    public var quotaSource: Bool
    /// The provider's token counters at `observed_at`; absent when the
    /// daemon predates the field, present (possibly all-zero) otherwise.
    public var tokens: CoreUsageTokens?
    /// The daemon's own cost estimate for the snapshot's period — an
    /// estimate from list prices, never an invoice.
    public var estimatedCostUSD: Double?
    /// A credit balance, for providers that bill in credits rather than
    /// percent-of-window.
    public var creditsRemaining: Double?
    /// When the snapshot was taken (epoch seconds): the age a stale lane
    /// should name instead of posing as current.
    public var observedAt: Double?
    /// The window the daemon says is worth watching — least headroom of
    /// the applicable measured lanes, with its reason — so the card can
    /// lead with it and say why (S6.4). Nil when nothing applicable was
    /// measured.
    public var constrained: CoreConstrainedLane?
    /// The provider status feed's live incident ("Anthropic: Elevated
    /// errors") — the daemon already stamps it on the snapshot and drops
    /// it the moment the feed goes quiet or stale, so a non-nil value
    /// here is current by construction. An outage on the vendor's side,
    /// never a quota verdict.
    public var incident: String?

    public init(id: String, windows: [CoreUsageWindow] = [], fidelity: String? = nil, state: String? = nil, forecast: CoreUsageForecast? = nil,
                account: UsageAccount? = nil, action: String? = nil, reason: String? = nil,
                instance: String? = nil, quotaSource: Bool = true, tokens: CoreUsageTokens? = nil,
                estimatedCostUSD: Double? = nil, creditsRemaining: Double? = nil, observedAt: Double? = nil,
                constrained: CoreConstrainedLane? = nil, incident: String? = nil) {
        self.id = id
        self.windows = windows
        self.fidelity = fidelity
        self.state = state
        self.forecast = forecast
        self.account = account
        self.action = action
        self.reason = reason
        self.instance = instance
        self.quotaSource = quotaSource
        self.tokens = tokens
        self.estimatedCostUSD = estimatedCostUSD
        self.creditsRemaining = creditsRemaining
        self.observedAt = observedAt
        self.constrained = constrained
        self.incident = incident
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        windows = tolerantRows(
            CoreUsageWindow.self,
            try c.decodeIfPresent([JSONValue].self, forKey: .windows)
        )
        fidelity = try c.decodeIfPresent(String.self, forKey: .fidelity)
        state = try c.decodeIfPresent(String.self, forKey: .state)
        forecast = try c.decodeIfPresent(CoreUsageForecast.self, forKey: .forecast)
        account = try c.decodeIfPresent(UsageAccount.self, forKey: .account)
        action = try? c.decodeIfPresent(String.self, forKey: .action)
        reason = try? c.decodeIfPresent(String.self, forKey: .reason)
        instance = try? c.decodeIfPresent(String.self, forKey: .instance)
        quotaSource = (try? c.decodeIfPresent(Bool.self, forKey: .quotaSource)) ?? true
        tokens = try? c.decodeIfPresent(CoreUsageTokens.self, forKey: .tokens)
        estimatedCostUSD = try? c.decodeIfPresent(Double.self, forKey: .estimatedCostUSD)
        creditsRemaining = try? c.decodeIfPresent(Double.self, forKey: .creditsRemaining)
        observedAt = try? c.decodeIfPresent(Double.self, forKey: .observedAt)
        constrained = try? c.decodeIfPresent(CoreConstrainedLane.self, forKey: .constrained)
        incident = try? c.decodeIfPresent(String.self, forKey: .incident)
    }

    /// Stable identity across multi-account rows of the same provider;
    /// the default instance collapses to the bare id.
    public var identity: String {
        guard let instance, !instance.isEmpty, instance != "default" else { return id }
        return "\(id)|\(instance)"
    }

    enum CodingKeys: String, CodingKey {
        case id, windows, fidelity, state, forecast, account, action, reason, instance, tokens, constrained, incident
        case quotaSource = "quota_source"
        case estimatedCostUSD = "estimated_cost_usd"
        case creditsRemaining = "credits_remaining"
        case observedAt = "observed_at"
    }

    /// `not_signed_in`, `signed_out`, `unauthenticated`, `no_auth`: the CLI
    /// has to log in before the daemon can read anything.
    public var isSignedOut: Bool {
        guard let state = state?.lowercased() else { return false }
        return state.contains("sign") || state.contains("auth") || state.contains("login")
    }

    /// Anything the daemon did not measure directly (`derived`, `estimated`, …).
    public var isDerived: Bool {
        guard let fidelity else { return false }
        return fidelity != "official"
    }

    /// The daemon marks the reading stale, by state or by fidelity: the
    /// last refresh did not land, so the figures are the last ones that
    /// did.
    public var isStale: Bool {
        state?.lowercased() == "stale" || fidelity?.lowercased() == "stale"
    }

    /// A broken source's fix: the daemon's fix-it ("Reconnect Claude",
    /// "Run grok login") on a stale reading, trimmed. Nil for a healthy
    /// source, and for a stale one with nothing to do about it. A
    /// window past its reset names this instead of waiting for a new
    /// reading, since none comes until the person acts.
    public var staleFix: String? {
        guard isStale, let action = action?.trimmingCharacters(in: .whitespaces), !action.isEmpty else { return nil }
        return action
    }

    /// The window every surface leads with — the Usage Center's
    /// headline, the menu-bar meter, the notch card's meter, the Screen
    /// Bar's ear ring: the daemon's `constrained` pick when it names a
    /// real window (least headroom of the applicable measured lanes),
    /// the same least-headroom rule computed locally when it does not,
    /// else the 5h convention. A weekly lane at 100 % outranks a 5h
    /// lane with headroom: the tighter constraint is always the story,
    /// never the shorter clock. One rule, one place — a provider can
    /// never read 17 % in the notch and 100 % in the menu bar.
    public var headlineWindow: CoreUsageWindow? {
        if let constrained,
           let match = windows.first(where: { $0.id == constrained.id || $0.name == constrained.name }) {
            return match
        }
        let measured = windows.filter { $0.bindable && $0.usedPct != nil }
        if let worst = measured.max(by: { ($0.usedPct ?? 0) < ($1.usedPct ?? 0) }) {
            return worst
        }
        return conventionalWindow
    }

    /// The 5h convention: what the pick would be before exhaustion is
    /// consulted — the baseline a "Watching it" note compares against
    /// when the constrained pick differs.
    public var conventionalWindow: CoreUsageWindow? {
        windows.first { $0.name.lowercased() == "5h" } ?? windows.first
    }
}

public struct CoreUsage: Codable, Hashable, Sendable {
    public var refreshedAt: Double?
    public var providers: [CoreProviderUsage]

    public init(refreshedAt: Double? = nil, providers: [CoreProviderUsage] = []) {
        self.refreshedAt = refreshedAt
        self.providers = providers
    }

    enum CodingKeys: String, CodingKey {
        case providers
        case refreshedAt = "refreshed_at"
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        refreshedAt = try c.decodeIfPresent(Double.self, forKey: .refreshedAt)
        providers = tolerantRows(
            CoreProviderUsage.self,
            try c.decodeIfPresent([JSONValue].self, forKey: .providers)
        )
    }
}

public struct CoreClosedLid: Codable, Hashable, Sendable {
    public var policy: String?
    public var holding: Bool?
    public var helperInstalled: Bool?
    /// The lid as the daemon last read it; nil while it has no reading.
    public var lidClosed: Bool?
    /// The daemon asks for sleep when the hold drops with the lid shut.
    public var sleepsOnRelease: Bool?
    public var lastSleepAt: Double?
    public var sleepError: String?

    enum CodingKeys: String, CodingKey {
        case policy, holding
        case helperInstalled = "helper_installed"
        case lidClosed = "lid_closed"
        case sleepsOnRelease = "sleeps_on_release"
        case lastSleepAt = "last_sleep_at"
        case sleepError = "sleep_error"
    }
}

/// The person's own keep-awake request (`state.power.hold.lease`): for a
/// duration (`until` is its end), until the named sessions finish
/// (`kind == "agents"`, `until` is the backstop), or until turned off
/// (`kind == "indefinite"`, no `until`).
public struct CoreAwakeLease: Codable, Hashable, Sendable {
    public var kind: String?
    public var startedAt: Double?
    public var until: Double?
    public var sessions: [String]?
    public var display: Bool?
    public var source: String?

    enum CodingKeys: String, CodingKey {
        case kind, until, sessions, display, source
        case startedAt = "started_at"
    }

    public var waitsOnAgents: Bool { kind == "agents" }

    /// Seconds left on a duration lease; nil for the other two shapes,
    /// whose end is not a countdown.
    public func remaining(now: Double) -> Double? {
        guard kind == "duration", let until else { return nil }
        return max(0, until - now)
    }
}

/// `state.power.hold`: why the Mac is (or is not) held awake. `state` is
/// the chip's three words -- `off`, `agents` (the agents hold it; `agents`
/// counts them), `manual` (a lease is in force). `suspended` names a yield
/// that took the hold away (`thermal`, `battery`) while the demand stands.
public struct CoreAwakeHold: Codable, Hashable, Sendable {
    public var state: String?
    public var agents: Int?
    public var active: Bool?
    public var display: Bool?
    public var graceUntil: Double?
    public var lease: CoreAwakeLease?
    public var suspended: String?
    public var thermal: String?

    enum CodingKeys: String, CodingKey {
        case state, agents, active, display, lease, suspended, thermal
        case graceUntil = "grace_until"
    }

    public var isManual: Bool { state == "manual" }
    public var isHeldByAgents: Bool { state == "agents" }
    public var isOff: Bool { state == nil || state == "off" }
}

/// The last time a hold let go for a reason worth reading
/// (`state.power.last_release`): a lease ending on time or when its agents
/// finished, a yield to heat or the battery floor, a closed-lid stretch,
/// or a sleep the daemon asked for.
public struct CorePowerRelease: Codable, Hashable, Sendable {
    public var kind: String?
    public var reason: String?
    public var at: Double?
    public var duration: Double?
    /// Runs the activity ledger saw finish during a closed-lid stretch.
    public var finished: Int?
    /// When the daemon's sleep landed, on a `slept` release.
    public var sleptAt: Double?

    public init(kind: String? = nil, reason: String? = nil, at: Double? = nil, duration: Double? = nil,
                finished: Int? = nil, sleptAt: Double? = nil) {
        self.kind = kind
        self.reason = reason
        self.at = at
        self.duration = duration
        self.finished = finished
        self.sleptAt = sleptAt
    }

    enum CodingKeys: String, CodingKey {
        case kind, reason, at, duration, finished
        case sleptAt = "slept_at"
    }
}

/// `state.power.battery.runway`: will the run holding the Mac awake
/// outlast the battery. `short` only on battery, with agents working and a
/// hold up, under half an hour left. `adapterShort` while the charger is in
/// and the battery still falls under the agents' load, with
/// `fullSpeedWatts` the adapter this Mac charges at full speed on.
public struct CoreBatteryRunway: Codable, Hashable, Sendable {
    public var agents: Int?
    public var minutesLeft: Int?
    public var short: Bool?
    public var adapterShort: Bool?
    public var fullSpeedWatts: Double?

    enum CodingKeys: String, CodingKey {
        case agents, short
        case minutesLeft = "minutes_left"
        case adapterShort = "adapter_short"
        case fullSpeedWatts = "full_speed_watts"
    }
}

/// `state.power.battery`: the daemon's battery reading (nil on a Mac with
/// no battery). Estimates are nil while macOS is still estimating.
public struct CoreBattery: Codable, Hashable, Sendable {
    public var percent: Int?
    public var charging: Bool?
    public var plugged: Bool?
    public var minutesLeft: Int?
    public var minutesToFull: Int?
    public var healthPercent: Int?
    public var cycleCount: Int?
    public var temperatureC: Double?
    public var condition: String?
    public var drawWatts: Double?
    public var adapterWatts: Double?
    public var runway: CoreBatteryRunway?

    enum CodingKeys: String, CodingKey {
        case percent, charging, plugged, condition, runway
        case minutesLeft = "minutes_left"
        case minutesToFull = "minutes_to_full"
        case healthPercent = "health_percent"
        case cycleCount = "cycle_count"
        case temperatureC = "temperature_c"
        case drawWatts = "draw_watts"
        case adapterWatts = "adapter_watts"
    }
}

public struct CorePower: Codable, Hashable, Sendable {
    public var keepAwake: Bool?
    public var closedLid: CoreClosedLid?
    public var hold: CoreAwakeHold?
    public var lastRelease: CorePowerRelease?
    public var battery: CoreBattery?

    enum CodingKeys: String, CodingKey {
        case keepAwake = "keep_awake"
        case closedLid = "closed_lid"
        case hold
        case lastRelease = "last_release"
        case battery
    }
}

/// The `hold_awake` command's arguments: exactly one shape -- a duration,
/// until a time, until the agents finish, or until turned off -- plus
/// whether the screen is held too and which surface asked.
public struct CoreAwakeRequest: Hashable, Sendable {
    public enum Shape: Hashable, Sendable {
        case seconds(Double)
        case until(Double)
        /// A local `HH:MM` ("08:00"): the daemon resolves the next one in
        /// the Mac's own zone.
        case untilTime(String)
        /// Every main session running now, or the named ones.
        case untilAgentsFinish(sessions: [String]?)
        case indefinite
    }

    public var shape: Shape
    public var display: Bool
    public var source: String

    public init(_ shape: Shape, display: Bool = false, source: String = "app") {
        self.shape = shape
        self.display = display
        self.source = source
    }

    public var arguments: [String: JSONValue] {
        var args: [String: JSONValue] = ["display": .bool(display), "source": .string(source)]
        switch shape {
        case .seconds(let seconds): args["seconds"] = .number(seconds)
        case .until(let epoch): args["until"] = .number(epoch)
        case .untilTime(let clock): args["until_time"] = .string(clock)
        case .untilAgentsFinish(let sessions):
            args["until_agents_idle"] = .bool(true)
            if let sessions { args["sessions"] = .array(sessions.map(JSONValue.string)) }
        case .indefinite: args["indefinite"] = .bool(true)
        }
        return args
    }
}

/// The `presence` command's arguments: what the app senses right now. The
/// daemon treats a report as current for three minutes, so a sender renews
/// it at least every minute while a sensor is live.
public struct CorePresenceReport: Hashable, Sendable {
    public var mic: Bool
    public var camera: Bool
    public var screenShared: Bool
    public var locked: Bool?
    public var idleSeconds: Double?
    /// INFocusStatusCenter's `isFocused`, from the app's own grant.
    public var focus: Bool?
    /// When a calendar meeting in progress ends.
    public var meetingUntil: Double?
    /// The app's own Calendar reading for the "glow before events" signal:
    /// `.some(nil)` says "nothing coming", `nil` sends nothing and leaves
    /// the daemon on its own EventKit read.
    public var nextEventStart: Double??
    /// Identifiers of the reminders due now, from the app's own read.
    public var remindersDue: [String]?

    public init(mic: Bool = false, camera: Bool = false, screenShared: Bool = false,
                locked: Bool? = nil, idleSeconds: Double? = nil, focus: Bool? = nil, meetingUntil: Double? = nil,
                nextEventStart: Double?? = nil, remindersDue: [String]? = nil) {
        self.mic = mic
        self.camera = camera
        self.screenShared = screenShared
        self.locked = locked
        self.idleSeconds = idleSeconds
        self.focus = focus
        self.meetingUntil = meetingUntil
        self.nextEventStart = nextEventStart
        self.remindersDue = remindersDue
    }

    public var sensingCall: Bool { mic || camera || screenShared }

    public var arguments: [String: JSONValue] {
        var args: [String: JSONValue] = [
            "mic": .bool(mic), "camera": .bool(camera), "screen_shared": .bool(screenShared),
        ]
        if let locked { args["locked"] = .bool(locked) }
        if let idleSeconds { args["idle_seconds"] = .number(max(0, idleSeconds)) }
        if let focus { args["focus"] = .bool(focus) }
        if let meetingUntil { args["meeting_until"] = .number(meetingUntil) }
        if let nextEventStart { args["next_event_start"] = nextEventStart.map(JSONValue.number) ?? .null }
        if let remindersDue { args["reminders_due"] = .array(remindersDue.prefix(32).map(JSONValue.string)) }
        return args
    }
}

/// `state.presence`: the one presence fact every surface reads the same
/// way. `onCall` is a live microphone, camera or screen share the app
/// reported (and renewed); `quiet` is what the daemon did about it
/// (`sounds`, a quiet mode word, or `off`); `escalationCeiling` is the
/// stage the ladder holds at (1 on a call); `celebrationsHeld` asks
/// Confetti and every other celebration to hold its burst.
public struct CorePresence: Codable, Hashable, Sendable {
    public var onCall: Bool?
    public var mic: Bool?
    public var camera: Bool?
    public var screenShared: Bool?
    public var since: Double?
    public var inMeeting: Bool?
    public var meetingUntil: Double?
    public var away: Bool?
    public var fresh: Bool?
    public var quiet: String?
    public var escalationCeiling: Int?
    public var celebrationsHeld: Bool?

    enum CodingKeys: String, CodingKey {
        case mic, camera, since, away, fresh, quiet
        case onCall = "on_call"
        case screenShared = "screen_shared"
        case inMeeting = "in_meeting"
        case meetingUntil = "meeting_until"
        case escalationCeiling = "escalation_ceiling"
        case celebrationsHeld = "celebrations_held"
    }

    public var isOnCall: Bool { onCall == true }
    public var holdsCelebrations: Bool { celebrationsHeld == true }
}

public struct CoreFocus: Codable, Hashable, Sendable {
    public var mode: String?
    public var source: String?
    public var until: Double?
    /// The quiet policy's own effect axes. A call's default quiet
    /// (`source == "call"`) leaves `mode` at `off` and takes only the
    /// sounds, so `audibleAllowed == false` is how a reader learns it.
    public var bannerAllowed: Bool?
    public var audibleAllowed: Bool?
    public var summary: String?
    /// Whether the daemon's helper can read which Focus is on (it needs
    /// Full Disk Access of its own); nil until it has tried.
    public var namedReadable: Bool?

    enum CodingKeys: String, CodingKey {
        case mode, source, until, summary
        case bannerAllowed = "banner_allowed"
        case audibleAllowed = "audible_allowed"
        case namedReadable = "named_readable"
    }

    /// False only when the daemon says sounds are off right now.
    public var soundsAllowed: Bool { audibleAllowed != false }
}

public struct CoreEscalation: Codable, Hashable, Sendable {
    public var stage: String?
    public var since: Double?

    public init(stage: String? = nil, since: Double? = nil) {
        self.stage = stage
        self.since = since
    }

    /// `"none"` 0, `"ramp"`/`"light"` 1, `"menu_bar"` 2, `"final"`/`"chime"`/
    /// `"takeover"` 3; digits as themselves. Unknown words are 0.
    public static func stageNumber(_ text: String?) -> Int {
        guard let text = text?.trimmingCharacters(in: .whitespaces).lowercased(), !text.isEmpty else { return 0 }
        if let number = Int(text) { return max(0, min(3, number)) }
        switch text {
        case "none", "off", "fresh": return 0
        case "ramp", "light", "1": return 1
        case "menu_bar", "menubar", "menu-bar", "flash": return 2
        case "final", "chime", "takeover", "loud": return 3
        default: return 0
        }
    }

    public var stageNumber: Int { Self.stageNumber(stage) }
}

/// One remote peer as of the daemon's last refresh (`state.peers`).
/// Facts only: reachable or not, how many rows it published, and the
/// failure word when it did not answer.
public struct CorePeer: Codable, Hashable, Sendable, Identifiable {
    public var machine: String
    public var host: String?
    public var reachable: Bool
    public var rows: Int
    public var failure: String?

    public var id: String { machine }

    public init(machine: String, host: String? = nil, reachable: Bool = false, rows: Int = 0, failure: String? = nil) {
        self.machine = machine
        self.host = host
        self.reachable = reachable
        self.rows = rows
        self.failure = failure
    }

    enum CodingKeys: String, CodingKey {
        case machine, host, reachable, rows, failure
    }
}

public struct CoreState: Codable, Hashable, Sendable {
    public var generation: Int
    public var now: Double?
    public var aggregate: CoreAggregate
    public var sessions: [CoreSession]
    public var asks: [CoreAsk]
    public var devices: [CoreDevice]
    public var usage: CoreUsage?
    public var power: CorePower?
    public var focus: CoreFocus?
    public var escalation: CoreEscalation?
    public var health: JSONValue?
    public var settingsGeneration: Int?
    /// The Creator Micro 2 deck (app-proposed extension, see app/README.md).
    public var deck: DeckState?
    /// Sessions the daemon keeps out of `sessions` (acknowledged
    /// completions, older ended runs) that `list_history` still has; nil
    /// from a daemon that does not count them.
    public var hiddenCount: Int?
    /// Moves when the effect registry, packs or assignments change, so the
    /// Effect Studio can reload its catalog without reconnecting.
    public var catalogGeneration: Int?
    /// `unseen_completions`: ids of listed sessions that finished since
    /// the user last looked — the daemon intersects it with the rows it
    /// still lists, so membership is all a "new" marker has to check.
    public var unseenCompletions: [String]
    /// `peers`: the remote-peers fleet as of the last refresh — absent
    /// while the feature is off, one row per discovered peer otherwise.
    public var peers: [CorePeer]?
    /// `presence`: on a call, in a meeting, away; nil from an older daemon.
    public var presence: CorePresence?

    public init(generation: Int = 0, now: Double? = nil, aggregate: CoreAggregate = CoreAggregate(),
                sessions: [CoreSession] = [], asks: [CoreAsk] = [], devices: [CoreDevice] = [], usage: CoreUsage? = nil,
                power: CorePower? = nil, focus: CoreFocus? = nil, escalation: CoreEscalation? = nil,
                health: JSONValue? = nil, settingsGeneration: Int? = nil, deck: DeckState? = nil, hiddenCount: Int? = nil,
                catalogGeneration: Int? = nil, unseenCompletions: [String] = [], peers: [CorePeer]? = nil,
                presence: CorePresence? = nil) {
        self.generation = generation
        self.now = now
        self.aggregate = aggregate
        self.sessions = sessions
        self.asks = asks
        self.devices = devices
        self.usage = usage
        self.power = power
        self.focus = focus
        self.escalation = escalation
        self.health = health
        self.settingsGeneration = settingsGeneration
        self.deck = deck
        self.hiddenCount = hiddenCount
        self.catalogGeneration = catalogGeneration
        self.unseenCompletions = unseenCompletions
        self.peers = peers
        self.presence = presence
    }

    enum CodingKeys: String, CodingKey {
        case generation, now, aggregate, sessions, asks, devices, usage, power, focus, escalation, health, deck
        case settingsGeneration = "settings_generation"
        case hiddenCount = "hidden_count"
        case catalogGeneration = "catalog_generation"
        case unseenCompletions = "unseen_completions"
        case peers
        case presence
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        generation = try c.decodeIfPresent(Int.self, forKey: .generation) ?? 0
        now = try c.decodeIfPresent(Double.self, forKey: .now)
        aggregate = try c.decodeIfPresent(CoreAggregate.self, forKey: .aggregate) ?? CoreAggregate()
        sessions = tolerantRows(
            CoreSession.self,
            try c.decodeIfPresent([JSONValue].self, forKey: .sessions)
        )
        asks = tolerantRows(
            CoreAsk.self,
            try c.decodeIfPresent([JSONValue].self, forKey: .asks)
        )
        devices = tolerantRows(
            CoreDevice.self,
            try c.decodeIfPresent([JSONValue].self, forKey: .devices)
        )
        usage = try c.decodeIfPresent(CoreUsage.self, forKey: .usage)
        power = try c.decodeIfPresent(CorePower.self, forKey: .power)
        focus = try c.decodeIfPresent(CoreFocus.self, forKey: .focus)
        escalation = try c.decodeIfPresent(CoreEscalation.self, forKey: .escalation)
        health = try c.decodeIfPresent(JSONValue.self, forKey: .health)
        settingsGeneration = try c.decodeIfPresent(Int.self, forKey: .settingsGeneration)
        // A malformed deck must not take the whole state down with it.
        deck = try? c.decodeIfPresent(DeckState.self, forKey: .deck)
        if let count = try? c.decodeIfPresent(Int.self, forKey: .hiddenCount) {
            hiddenCount = max(0, count)
        } else if let count = try? c.decodeIfPresent(Double.self, forKey: .hiddenCount) {
            hiddenCount = max(0, Int(count))
        } else {
            hiddenCount = nil
        }
        catalogGeneration = try? c.decodeIfPresent(Int.self, forKey: .catalogGeneration)
        unseenCompletions = (try? c.decodeIfPresent([String].self, forKey: .unseenCompletions)) ?? []
        peers = tolerantRows(CorePeer.self, try c.decodeIfPresent([JSONValue].self, forKey: .peers))
        // A malformed presence reads as "no report", never a lost state.
        presence = try? c.decodeIfPresent(CorePresence.self, forKey: .presence)
    }

    /// Sessions the panel lists: `kind == "main"`. Workers roll up into their parent's badge.
    public var mainSessions: [CoreSession] { sessions.filter { $0.kind == "main" || $0.parent == nil } }

    public func session(withID id: String) -> CoreSession? { sessions.first { $0.id == id } }

    /// Asks whose session the daemon no longer lists — cleared, or
    /// acknowledged out from under a request that is still open. The
    /// aggregate counts them and the light is about them, so the panel
    /// gives them a row of their own rather than dropping them.
    public var orphanAsks: [CoreAsk] {
        guard !asks.isEmpty else { return [] }
        let known = Set(sessions.map(\.id))
        return asks.filter { ask in
            guard let session = ask.session, !session.isEmpty else { return true }
            return !known.contains(session)
        }
    }

    /// `health.sources[provider]` decoded: whether the provider's hook
    /// feed is still delivering (`fresh`) and how many seconds since the
    /// last event it accepted (`heard_age_seconds`, nil when it never
    /// has). `health` stays a reserved JSONValue subtree — this and
    /// `intakeHealth` are the parts of it consumers need typed.
    public func sourceHealth(for provider: String) -> (fresh: Bool, heardAgeSeconds: Double?)? {
        guard let source = health?["sources"]?[provider]?.objectValue else { return nil }
        return (source["fresh"]?.boolValue ?? false, source["heard_age_seconds"]?.doubleValue)
    }

    /// `health.intake`: the intake report's verdict codes (`hook_state`,
    /// `source_health`) and the `silence_seconds` bound it judges
    /// quiet by; nil from a daemon that reports no intake at all.
    public var intakeHealth: (hookState: String?, sourceHealth: String?, silenceSeconds: Double?)? {
        guard let intake = health?["intake"], !intake.isNull else { return nil }
        return (intake["hook_state"]?.stringValue,
                intake["source_health"]?.stringValue,
                intake["silence_seconds"]?.doubleValue)
    }
}

// MARK: - lights

/// What the daemon says about the `why` it chose: the session the light
/// is about, its label and provider, how long it has been in that state,
/// and the dimming applied on top (`why_detail`, every field optional).
public struct CoreWhyDetail: Codable, Hashable, Sendable {
    public var session: String?
    public var label: String?
    public var provider: String?
    public var secondsInState: Double?
    public var brightnessFactor: Double?
    /// Names of the dimming sources in effect (`idle_dim`, `battery`, …).
    public var dimming: [String]

    public init(session: String? = nil, label: String? = nil, provider: String? = nil, secondsInState: Double? = nil,
                brightnessFactor: Double? = nil, dimming: [String] = []) {
        self.session = session
        self.label = label
        self.provider = provider
        self.secondsInState = secondsInState
        self.brightnessFactor = brightnessFactor
        self.dimming = dimming
    }

    enum CodingKeys: String, CodingKey {
        case session, label, provider, dimming
        case secondsInState = "seconds_in_state"
        case brightnessFactor = "brightness_factor"
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        session = try c.decodeIfPresent(String.self, forKey: .session)
        label = try c.decodeIfPresent(String.self, forKey: .label)
        provider = try c.decodeIfPresent(String.self, forKey: .provider)
        secondsInState = try c.decodeIfPresent(Double.self, forKey: .secondsInState)
        brightnessFactor = try c.decodeIfPresent(Double.self, forKey: .brightnessFactor)
        // Strings today; objects with a name/kind/reason are read for their word.
        let raw = (try? c.decodeIfPresent([JSONValue].self, forKey: .dimming)) ?? []
        dimming = raw.compactMap { value -> String? in
            switch value {
            case .string(let text): return text
            case .object(let object):
                for key in ["name", "kind", "reason", "id"] {
                    if case .string(let text)? = object[key] { return text }
                }
                return nil
            default: return nil
            }
        }
    }
}

public struct CoreLightSurface: Codable, Hashable, Sendable {
    public var program: String
    public var ledCount: Int?
    /// Epoch seconds at which the program's t=0 happened on the strip.
    public var anchor: Double?
    public var motion: String?
    public var staticFallback: String?
    public var brightness: Double?
    public var why: String?
    public var whyDetail: CoreWhyDetail?
    /// `dot` only, and only while a role is actually driving the Dot
    /// (`docs/CORE-PROTOCOL.md`, "The Dot's role"): `extend` or `asks`.
    /// Absent when the Dot renders its own display, and never on a preview.
    public var role: String?
    /// Additive: the ambient cue staged on this surface right now
    /// (`{id, name}`, "Handoff baton"), so a sweep has a name; nil when
    /// none plays, and on daemons that predate it.
    public var cue: CoreLightCue?

    public init(program: String, ledCount: Int? = nil, anchor: Double? = nil, motion: String? = nil,
                staticFallback: String? = nil, brightness: Double? = nil, why: String? = nil,
                whyDetail: CoreWhyDetail? = nil, role: String? = nil, cue: CoreLightCue? = nil) {
        self.program = program
        self.ledCount = ledCount
        self.anchor = anchor
        self.motion = motion
        self.staticFallback = staticFallback
        self.brightness = brightness
        self.why = why
        self.whyDetail = whyDetail
        self.role = role
        self.cue = cue
    }

    enum CodingKeys: String, CodingKey {
        case program, anchor, motion, brightness, why, role, cue
        case ledCount = "led_count"
        case staticFallback = "static_fallback"
        case whyDetail = "why_detail"
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        program = try c.decodeIfPresent(String.self, forKey: .program) ?? ""
        ledCount = try c.decodeIfPresent(Int.self, forKey: .ledCount)
        anchor = try c.decodeIfPresent(Double.self, forKey: .anchor)
        motion = try c.decodeIfPresent(String.self, forKey: .motion)
        staticFallback = try c.decodeIfPresent(String.self, forKey: .staticFallback)
        brightness = try c.decodeIfPresent(Double.self, forKey: .brightness)
        why = try c.decodeIfPresent(String.self, forKey: .why)
        whyDetail = try? c.decodeIfPresent(CoreWhyDetail.self, forKey: .whyDetail)
        role = try c.decodeIfPresent(String.self, forKey: .role)
        cue = try? c.decodeIfPresent(CoreLightCue.self, forKey: .cue)
    }
}

/// `lights.surfaces.<name>.cue`: the ambient cue a surface is playing.
public struct CoreLightCue: Codable, Hashable, Sendable {
    public var id: String
    public var name: String

    public init(id: String, name: String) {
        self.id = id
        self.name = name
    }
}

/// `lights.auto_dim`: the decision behind the `auto_dim` dimming word.
/// `mode` is the setting, `source` the reader that produced `factor`
/// (ambient without a sensor falls back to `display`), `available` false
/// when the mode's own source could not be read, `reading` the raw value
/// (lux, the display fraction, or minutes since midnight).
public struct CoreAutoDim: Codable, Hashable, Sendable {
    public var mode: String
    public var source: String
    public var factor: Double?
    public var available: Bool
    public var reading: Double?
    /// Additive: the sensor's unsmoothed value behind an ambient `reading`
    /// (the daemon smooths shadows out of it); nil on daemons without it.
    public var raw: Double?

    public init(mode: String = "off", source: String = "off", factor: Double? = nil, available: Bool = true,
                reading: Double? = nil, raw: Double? = nil) {
        self.mode = mode
        self.source = source
        self.factor = factor
        self.available = available
        self.reading = reading
        self.raw = raw
    }

    enum CodingKeys: String, CodingKey { case mode, source, factor, available, reading, raw }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        mode = try c.decodeIfPresent(String.self, forKey: .mode) ?? "off"
        source = try c.decodeIfPresent(String.self, forKey: .source) ?? mode
        factor = try? c.decodeIfPresent(Double.self, forKey: .factor)
        available = try c.decodeIfPresent(Bool.self, forKey: .available) ?? true
        reading = try? c.decodeIfPresent(Double.self, forKey: .reading)
        raw = try? c.decodeIfPresent(Double.self, forKey: .raw)
    }

    /// The setting is doing something.
    public var isActive: Bool { mode != "off" }
}

/// `lights.dot_link`: the daemon's own word for the Pro + Dot link —
/// which of `off`, `no_dot`, `no_strip`, `beacon`, `solo`, `linked` or
/// `failed` applies right now, the `dot_role` behind it, and the linked
/// write's error class when the last one failed. The states a settings
/// toggle cannot express (`no_strip`, `failed`) are why this exists; it
/// is nil on daemons that predate it, and the app falls back to the
/// `devices_linked` setting then.
public struct CoreDotLink: Codable, Hashable, Sendable {
    public var state: String
    public var role: String?
    public var error: String?

    public init(state: String, role: String? = nil, error: String? = nil) {
        self.state = state
        self.role = role
        self.error = error
    }

    enum CodingKeys: String, CodingKey { case state, role, error }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        state = try c.decodeIfPresent(String.self, forKey: .state) ?? "off"
        role = try c.decodeIfPresent(String.self, forKey: .role)
        error = try c.decodeIfPresent(String.self, forKey: .error)
    }
}

public struct CoreLights: Codable, Hashable, Sendable {
    public var surfaces: [String: CoreLightSurface]
    public var linked: Bool?
    /// Additive (protocol 1, schema 3): the `devices_linked` setting in
    /// effect with both a Pro and a Dot connected, the measured gap between
    /// their write completions, and the auto-dim decision.
    public var devicesLinked: Bool?
    public var linkedSkewMs: Double?
    /// When `linkedSkewMs` was measured (epoch seconds); the two travel
    /// together or not at all.
    public var linkedSkewAt: Double?
    /// The skew the last coupled write baked into the Dot's program so it
    /// restarts in phase; absent when no correction was applied. Shares
    /// `linkedSkewAt`'s freshness.
    public var linkedSkewCorrectedMs: Double?
    public var dotLink: CoreDotLink?
    public var autoDim: CoreAutoDim?

    public init(surfaces: [String: CoreLightSurface] = [:], linked: Bool? = nil, devicesLinked: Bool? = nil,
                linkedSkewMs: Double? = nil, linkedSkewAt: Double? = nil,
                linkedSkewCorrectedMs: Double? = nil,
                dotLink: CoreDotLink? = nil, autoDim: CoreAutoDim? = nil) {
        self.surfaces = surfaces
        self.linked = linked
        self.devicesLinked = devicesLinked
        self.linkedSkewMs = linkedSkewMs
        self.linkedSkewAt = linkedSkewAt
        self.linkedSkewCorrectedMs = linkedSkewCorrectedMs
        self.dotLink = dotLink
        self.autoDim = autoDim
    }

    enum CodingKeys: String, CodingKey {
        case surfaces, linked
        case devicesLinked = "devices_linked"
        case linkedSkewMs = "linked_skew_ms"
        case linkedSkewAt = "linked_skew_at"
        case linkedSkewCorrectedMs = "linked_skew_corrected_ms"
        case dotLink = "dot_link"
        case autoDim = "auto_dim"
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let rawSurfaces = try c.decodeIfPresent([String: JSONValue].self, forKey: .surfaces) ?? [:]
        surfaces = rawSurfaces.compactMapValues {
            try? ReplyDecoding.decode(CoreLightSurface.self, from: $0)
        }
        linked = try c.decodeIfPresent(Bool.self, forKey: .linked)
        devicesLinked = try? c.decodeIfPresent(Bool.self, forKey: .devicesLinked)
        linkedSkewMs = try? c.decodeIfPresent(Double.self, forKey: .linkedSkewMs)
        linkedSkewAt = try? c.decodeIfPresent(Double.self, forKey: .linkedSkewAt)
        linkedSkewCorrectedMs = try? c.decodeIfPresent(Double.self, forKey: .linkedSkewCorrectedMs)
        dotLink = try? c.decodeIfPresent(CoreDotLink.self, forKey: .dotLink)
        autoDim = try? c.decodeIfPresent(CoreAutoDim.self, forKey: .autoDim)
    }

    public var screenBar: CoreLightSurface? { surfaces["screen_bar"] }
    public var hardware: CoreLightSurface? { surfaces["hardware"] }
    public var dot: CoreLightSurface? { surfaces["dot"] }

    /// The skew is a measurement, not a state: past half an hour it is
    /// old news and says nothing about whether the pair is in step now.
    public static let linkedSkewFreshSeconds: TimeInterval = 30 * 60
    public var isLinkedSkewFresh: Bool {
        guard let linkedSkewAt, linkedSkewMs != nil else { return false }
        return linkedSkewAt >= Date().timeIntervalSince1970 - Self.linkedSkewFreshSeconds
    }
}

// MARK: - event

public struct CoreEvent: Codable, Hashable, Sendable, Identifiable {
    public var id: String
    public var kind: String
    public var session: String?
    public var label: String?
    public var at: Double?
    public var sound: String?
    public var notify: Bool?
    /// Additive fields: the provider behind the event, a one-line detail
    /// (the ask summary, the quota window), and the escalation stage
    /// (`escalation_stage` events; 0...3, or a stage name).
    public var provider: String?
    public var detail: String?
    public var stage: Int?
    /// `deck_input`: the observed control (`{index, kind, at}`, nested
    /// because the envelope's `kind` is the event kind). `deck_receipt`:
    /// the receipt `code` and its `message`.
    public var input: DeckInput?
    public var code: String?
    public var message: String?
    /// `usage_history_ready`: the range (`7d`, `30d`, …) whose scan finished
    /// for `provider`; nil means every range.
    public var range: String?

    /// `usage_history_ready {provider, range?}`: the daemon's background
    /// scan for `usage_history` has fresh rows; a client that asked earlier
    /// and got a partial or slow answer should ask again. `notify: false`;
    /// a daemon that never sends it costs nothing.
    public static let usageHistoryReadyKind = "usage_history_ready"

    /// `quota_reset`'s lane (`"weekly"`, `"5h-weekly"`, …): the quota
    /// window that reset. Confetti fires only on the weekly ones.
    public var lane: String?

    /// `list_history` rows: seconds the session ran when the daemon knows
    /// both ends of it. nil for events without a measured span.
    public var duration: Double?

    /// The resume point this frame carries: `<stream>:<event id>`. The
    /// last cursor a client saw is what it replays from after a drop.
    public var cursor: String?

    /// `ask_opened` / `ask_resolved`: the episode's canonical request
    /// identity — every surface keys the same request to the same
    /// interruption episode, and a resolution only closes its own ask.
    public var request: String?

    /// `milestone`: the completion count the odometer just crossed (the
    /// latest, when one batch crossed several). The lights, Confetti and
    /// the Aquarium celebrate the same number.
    public var count: Int?
    public static let milestoneKind = "milestone"

    /// `open_window`: the app window a deck key asked for, by its link
    /// name (`overview`, `usage`, `control-center`).
    public var window: String?
    /// `open_window {window}` and `reveal_ask`: a Creator Micro key asked
    /// the app for one of its windows or for the waiting ask. The app runs
    /// them the way it runs a `jrbar://` link; revealing an ask never
    /// answers it.
    public static let openWindowKind = "open_window"
    public static let revealAskKind = "reveal_ask"

    public init(id: String, kind: String, session: String? = nil, label: String? = nil, at: Double? = nil, sound: String? = nil,
                notify: Bool? = nil, provider: String? = nil, detail: String? = nil, stage: Int? = nil,
                input: DeckInput? = nil, code: String? = nil, message: String? = nil, range: String? = nil,
                lane: String? = nil, duration: Double? = nil, cursor: String? = nil, request: String? = nil,
                count: Int? = nil, window: String? = nil) {
        self.id = id
        self.kind = kind
        self.session = session
        self.label = label
        self.at = at
        self.sound = sound
        self.notify = notify
        self.provider = provider
        self.detail = detail
        self.stage = stage
        self.input = input
        self.code = code
        self.message = message
        self.range = range
        self.lane = lane
        self.duration = duration
        self.cursor = cursor
        self.request = request
        self.count = count
        self.window = window
    }

    enum CodingKeys: String, CodingKey {
        case id, kind, session, label, at, sound, notify, provider, detail, stage, input, code, message, range, lane, duration, cursor, request
        case count
        case window
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(String.self, forKey: .id) ?? UUID().uuidString
        kind = try c.decodeIfPresent(String.self, forKey: .kind) ?? "unknown"
        session = try c.decodeIfPresent(String.self, forKey: .session)
        label = try c.decodeIfPresent(String.self, forKey: .label)
        at = try c.decodeIfPresent(Double.self, forKey: .at)
        sound = try c.decodeIfPresent(String.self, forKey: .sound)
        notify = try c.decodeIfPresent(Bool.self, forKey: .notify)
        provider = try c.decodeIfPresent(String.self, forKey: .provider)
        detail = try c.decodeIfPresent(String.self, forKey: .detail)
        if let number = try? c.decodeIfPresent(Int.self, forKey: .stage) {
            stage = number
        } else if let text = try? c.decodeIfPresent(String.self, forKey: .stage) {
            stage = CoreEscalation.stageNumber(text)
        } else {
            stage = nil
        }
        input = try? c.decodeIfPresent(DeckInput.self, forKey: .input)
        code = try? c.decodeIfPresent(String.self, forKey: .code)
        message = try? c.decodeIfPresent(String.self, forKey: .message)
        range = try? c.decodeIfPresent(String.self, forKey: .range)
        lane = try? c.decodeIfPresent(String.self, forKey: .lane)
        duration = try? c.decodeIfPresent(Double.self, forKey: .duration)
        cursor = try? c.decodeIfPresent(String.self, forKey: .cursor)
        request = try? c.decodeIfPresent(String.self, forKey: .request)
        count = try? c.decodeIfPresent(Int.self, forKey: .count)
        window = try? c.decodeIfPresent(String.self, forKey: .window)
    }

    /// `deck_receipt` as a receipt value.
    public var receipt: DeckReceipt? {
        guard kind == "deck_receipt", let code else { return nil }
        return DeckReceipt(code: code, message: message, at: at)
    }
}

// MARK: - settings

public struct CoreSettings: Codable, Hashable, Sendable {
    public var generation: Int
    public var schema: Int?
    public var document: JSONValue

    public init(generation: Int = 0, schema: Int? = nil, document: JSONValue = .object([:])) {
        self.generation = generation
        self.schema = schema
        self.document = document
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        generation = try c.decodeIfPresent(Int.self, forKey: .generation) ?? 0
        schema = try c.decodeIfPresent(Int.self, forKey: .schema)
        document = try c.decodeIfPresent(JSONValue.self, forKey: .document) ?? .object([:])
    }
}

// MARK: - reply

public struct CoreReplyError: Codable, Hashable, Sendable, Error {
    public var code: String
    public var message: String?

    public init(code: String, message: String? = nil) {
        self.code = code
        self.message = message
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        code = try c.decodeIfPresent(String.self, forKey: .code) ?? "error"
        message = try c.decodeIfPresent(String.self, forKey: .message)
    }
}

public struct CoreReply: Codable, Hashable, Sendable {
    public var id: String
    public var ok: Bool
    public var result: JSONValue?
    public var error: CoreReplyError?

    public init(id: String, ok: Bool, result: JSONValue? = nil, error: CoreReplyError? = nil) {
        self.id = id
        self.ok = ok
        self.result = result
        self.error = error
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(String.self, forKey: .id) ?? ""
        ok = try c.decodeIfPresent(Bool.self, forKey: .ok) ?? false
        result = try c.decodeIfPresent(JSONValue.self, forKey: .result)
        error = try c.decodeIfPresent(CoreReplyError.self, forKey: .error)
    }
}

// MARK: - log

public struct CoreLog: Codable, Hashable, Sendable {
    public var level: String?
    public var message: String?
    public var at: Double?
}

// MARK: - command (app → daemon)

public struct CoreCommand: Codable, Hashable, Sendable {
    public var id: String
    public var name: String
    public var args: [String: JSONValue]

    public init(id: String, name: String, args: [String: JSONValue] = [:]) {
        self.id = id
        self.name = name
        self.args = args
    }

    enum CodingKeys: String, CodingKey { case t, v, id, name, args }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        name = try c.decode(String.self, forKey: .name)
        args = try c.decodeIfPresent([String: JSONValue].self, forKey: .args) ?? [:]
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode("command", forKey: .t)
        try c.encode(CoreProtocol.version, forKey: .v)
        try c.encode(id, forKey: .id)
        try c.encode(name, forKey: .name)
        try c.encode(args, forKey: .args)
    }
}

// MARK: - envelope

/// One decoded daemon → app frame.
public enum CoreMessage: Hashable, Sendable {
    case hello(CoreHello)
    case state(CoreState)
    case lights(CoreLights)
    case event(CoreEvent)
    case settings(CoreSettings)
    case reply(CoreReply)
    case log(CoreLog)
    /// A type this build does not know (or a protocol version it does not
    /// speak). Kept so callers can count or log it; never an error.
    case unknown(type: String, version: Int?)

    public var typeName: String {
        switch self {
        case .hello: return "hello"
        case .state: return "state"
        case .lights: return "lights"
        case .event: return "event"
        case .settings: return "settings"
        case .reply: return "reply"
        case .log: return "log"
        case .unknown(let type, _): return type
        }
    }
}

// MARK: - Provider management (W06: `list_providers`, `provider_consent`)

/// One granted browser consent as `list_providers`/`provider_consent`
/// report it: the exact provider + browser + profile + field scope.
public struct ProviderConsentRow: Codable, Hashable, Sendable {
    public var browser: String
    public var profile: String
    public var domains: [String]
    public var fields: [String]
    public var backgroundRepair: Bool
    public var grantedAt: Double
    public var sourceInstanceID: String

    public init(browser: String, profile: String, domains: [String], fields: [String],
                backgroundRepair: Bool = false, grantedAt: Double = 0, sourceInstanceID: String = "default") {
        self.browser = browser
        self.profile = profile
        self.domains = domains
        self.fields = fields
        self.backgroundRepair = backgroundRepair
        self.grantedAt = grantedAt
        self.sourceInstanceID = sourceInstanceID
    }

    enum CodingKeys: String, CodingKey {
        case browser, profile, domains, fields
        case backgroundRepair = "background_repair"
        case grantedAt = "granted_at"
        case sourceInstanceID = "source_instance_id"
    }
}

/// The reply to `provider_action action="resign_in"`: the daemon's own
/// account of what the re-pull did, plus a sign-in page when the remedy
/// is one only the user can complete.
public struct ProviderResignInResult: Hashable, Sendable {
    public var message: String
    public var signInURL: String?

    public init(message: String, signInURL: String? = nil) {
        self.message = message
        self.signInURL = signInURL
    }
}

/// Whether a credential account exists — never the secret itself.
public struct ProviderCredentialRow: Codable, Hashable, Sendable {
    public var account: String
    public var available: Bool
}

/// `list_providers` row: what the daemon knows and can do for one
/// provider — enabled flag, live source state, the source ladder,
/// consents, credential availability. Secrets never cross the socket.
public struct ProviderRow: Codable, Hashable, Sendable {
    public var id: String
    /// The configured source instance this row inspects ("default" for
    /// the single-account case).
    public var instance: String
    public var label: String
    public var enabled: Bool
    public var menuVisible: Bool
    public var browserSourcesEnabled: Bool
    public var supportsBrowserSources: Bool
    public var supportsLocalTokens: Bool
    public var supportsQuota: Bool
    /// The daemon's word on whether a second configured account could
    /// read a *different* account — only where a source is per-instance
    /// (stored credential or consented browser session). Governs the
    /// "Add account" affordance.
    public var supportsInstances: Bool
    public var sourceOrder: [String]
    public var options: [String: String]
    public var consents: [ProviderConsentRow]
    public var credentials: [ProviderCredentialRow]
    /// A stored credential whose provenance says "browser import" — the
    /// only credential a consent revoke may remove (T26).
    public var importedCredential: Bool
    public var state: String?
    public var reason: String?
    public var action: String?
    public var accountLabel: String?
    public var observedAt: Double?

    /// `id|instance` for non-default instances — the same composite the
    /// usage rows use, so a card can find its manage row directly.
    public var identity: String {
        instance.isEmpty || instance == "default" ? id : "\(id)|\(instance)"
    }

    enum CodingKeys: String, CodingKey {
        case id, instance, label, enabled, options, consents, credentials, state, reason, action
        case menuVisible = "menu_visible"
        case browserSourcesEnabled = "browser_sources_enabled"
        case supportsBrowserSources = "supports_browser_sources"
        case supportsLocalTokens = "supports_local_tokens"
        case supportsQuota = "supports_quota"
        case supportsInstances = "supports_instances"
        case sourceOrder = "source_order"
        case importedCredential = "imported_credential"
        case accountLabel = "account_label"
        case observedAt = "observed_at"
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        instance = (try? c.decodeIfPresent(String.self, forKey: .instance)) ?? "default"
        label = (try? c.decodeIfPresent(String.self, forKey: .label)) ?? id
        enabled = (try? c.decodeIfPresent(Bool.self, forKey: .enabled)) ?? false
        menuVisible = (try? c.decodeIfPresent(Bool.self, forKey: .menuVisible)) ?? true
        browserSourcesEnabled = (try? c.decodeIfPresent(Bool.self, forKey: .browserSourcesEnabled)) ?? false
        supportsBrowserSources = (try? c.decodeIfPresent(Bool.self, forKey: .supportsBrowserSources)) ?? false
        supportsLocalTokens = (try? c.decodeIfPresent(Bool.self, forKey: .supportsLocalTokens)) ?? false
        supportsQuota = (try? c.decodeIfPresent(Bool.self, forKey: .supportsQuota)) ?? false
        supportsInstances = (try? c.decodeIfPresent(Bool.self, forKey: .supportsInstances)) ?? false
        sourceOrder = (try? c.decodeIfPresent([String].self, forKey: .sourceOrder)) ?? []
        options = (try? c.decodeIfPresent([String: String].self, forKey: .options)) ?? [:]
        consents = tolerantRows(
            ProviderConsentRow.self,
            try c.decodeIfPresent([JSONValue].self, forKey: .consents)
        )
        credentials = tolerantRows(
            ProviderCredentialRow.self,
            try c.decodeIfPresent([JSONValue].self, forKey: .credentials)
        )
        importedCredential = (try? c.decodeIfPresent(Bool.self, forKey: .importedCredential)) ?? false
        state = try? c.decodeIfPresent(String.self, forKey: .state)
        reason = try? c.decodeIfPresent(String.self, forKey: .reason)
        action = try? c.decodeIfPresent(String.self, forKey: .action)
        accountLabel = try? c.decodeIfPresent(String.self, forKey: .accountLabel)
        observedAt = try? c.decodeIfPresent(Double.self, forKey: .observedAt)
    }
}

// MARK: - usage_graph

/// The `usage_graph` reply: one shared-axis chart model — strided day
/// labels, per-provider series on a single `scaleMax`, the day-grid
/// heatmap, and the disclosures the scan names for itself — plus the
/// summary line (`"Last 30 days: Claude 12.3M · 45 sessions"`).
public struct CoreUsageGraphDocument: Codable, Hashable, Sendable {
    public var graph: CoreUsageGraph
    public var summary: String

    public init(graph: CoreUsageGraph = CoreUsageGraph(), summary: String = "") {
        self.graph = graph
        self.summary = summary
    }
}

/// The chart model: `labels`/`values` are index-aligned, one slot per
/// calendar day oldest→newest. A series value `< 0` is a gap day —
/// before the provider had any samples — and the line must break
/// there rather than pretend a flat zero.
public struct CoreUsageGraph: Codable, Hashable, Sendable {
    public var days: Int
    public var periodLabel: String
    /// `tokens` | `cost` | `sessions` | `percent`.
    public var metric: String
    public var labels: [String]
    public var series: [Series]
    public var scaleMax: Double
    public var heatmap: CoreUsageHeatmap?
    /// The resolved request set — the providers the daemon charted.
    /// Series omits a checked-but-empty provider; this echo is what
    /// the picker's checkmarks key on.
    public var providers: [String]
    /// Providers whose local history is incomplete for this range —
    /// the pane names them rather than imply full coverage.
    public var partialProviderIds: [String]
    /// `api_equivalent_estimate` when `metric == cost`: the chart is
    /// pricing the transcripts, not billing the subscription.
    public var costSemantics: String?

    public struct Series: Codable, Hashable, Sendable {
        public var providerId: String
        /// Percent mode charts one series per (provider, instance): two
        /// rows can share `providerId`, so anything keying on it alone
        /// would merge them into one fabricated line. Non-percent
        /// series omit it entirely.
        public var sourceInstanceId: String?
        /// The daemon's display name — `provider · instance` for a
        /// non-default instance, the bare provider otherwise.
        public var label: String?
        public var values: [Double]

        /// The chart's identity for this row: `provider` when no
        /// instance was sent, `provider·instance` when it was — unique
        /// across the multi-instance rows percent mode emits.
        public var seriesKey: String {
            guard let instance = sourceInstanceId else { return providerId }
            return "\(providerId)·\(instance)"
        }

        public init(providerId: String, sourceInstanceId: String? = nil,
                    label: String? = nil, values: [Double]) {
            self.providerId = providerId
            self.sourceInstanceId = sourceInstanceId
            self.label = label
            self.values = values
        }
    }

    public init() {
        days = 7; periodLabel = ""; metric = "tokens"
        labels = []; series = []; scaleMax = 1
        heatmap = nil; providers = []; partialProviderIds = []; costSemantics = nil
    }

    enum CodingKeys: String, CodingKey {
        case days, metric, labels, series, heatmap, providers
        case periodLabel = "period_label"
        case scaleMax = "scale_max"
        case partialProviderIds = "partial_provider_ids"
        case costSemantics = "cost_semantics"
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        days = (try? c.decodeIfPresent(Int.self, forKey: .days)) ?? 7
        periodLabel = (try? c.decodeIfPresent(String.self, forKey: .periodLabel)) ?? ""
        metric = (try? c.decodeIfPresent(String.self, forKey: .metric)) ?? "tokens"
        labels = (try? c.decodeIfPresent([String].self, forKey: .labels)) ?? []
        scaleMax = (try? c.decodeIfPresent(Double.self, forKey: .scaleMax)) ?? 1
        heatmap = try? c.decodeIfPresent(CoreUsageHeatmap.self, forKey: .heatmap)
        providers = (try? c.decodeIfPresent([String].self, forKey: .providers)) ?? []
        partialProviderIds = (try? c.decodeIfPresent([String].self, forKey: .partialProviderIds)) ?? []
        costSemantics = try? c.decodeIfPresent(String.self, forKey: .costSemantics)
        series = ((try? c.decodeIfPresent([Series].self, forKey: .series)) ?? [])
            .filter { !$0.providerId.isEmpty }
    }
}

extension CoreUsageGraph.Series {
    enum CodingKeys: String, CodingKey {
        case values, label
        case providerId = "provider_id"
        case sourceInstanceId = "source_instance_id"
    }
}

/// The GitHub-style day grid beside the chart: one cell per calendar
/// day per provider plus an `aggregate` row, `intensity` 0–4.
public struct CoreUsageHeatmap: Codable, Hashable, Sendable {
    /// ISO `YYYY-MM-DD`, oldest→newest, local calendar days.
    public var days: [String]
    public var providers: [String: Provider]
    public var aggregate: Provider
    public var timezone: String

    public struct Provider: Codable, Hashable, Sendable {
        public var providerId: String
        public var cells: [Cell]
        public var totals: Totals
        /// `available` | `unavailable` — no records observed at all.
        public var dataStatus: String

        public struct Totals: Codable, Hashable, Sendable {
            public var tokens: Int
            public var sessions: Int
        }

        public struct Cell: Codable, Hashable, Sendable {
            public var day: String
            public var tokens: Int
            public var sessions: Int
            public var intensity: Int
            public var color: String
            public var accessibilityLabel: String

            enum CodingKeys: String, CodingKey {
                case day, tokens, sessions, intensity, color
                case accessibilityLabel = "accessibility_label"
            }
        }

        enum CodingKeys: String, CodingKey {
            case cells, totals
            case providerId = "provider_id"
            case dataStatus = "data_status"
        }
    }
}
