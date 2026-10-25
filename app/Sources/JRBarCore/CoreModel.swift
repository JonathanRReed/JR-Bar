import Foundation
import Observation

public struct CoreSettingsFrame: Hashable, Sendable {
    public let settings: CoreSettings
    public let stream: String?
    public let connectionRevision: UInt64
}

/// The app's view of the daemon: the latest full documents, the connection
/// status, and a way to send commands. Main-actor and `@Observable`, so
/// SwiftUI and AppKit observers both see every change.
@MainActor
@Observable
public final class CoreModel {
    public enum Connection: Equatable, Sendable {
        case idle
        case connecting(attempt: Int)
        case connected
        case disconnected(reason: String)

        public var isConnected: Bool { self == .connected }
    }

    /// Whether the daemon on the socket takes this app's privileged commands.
    public enum AuthState: Equatable, Sendable {
        /// No secret is held (no daemon of ours is supervised), or the exchange
        /// has not finished on this connection.
        case unproven
        /// The daemon accepted the proof for this connection.
        case authenticated
        /// It did not, or could not be asked; the sentence says why.
        case refused(String)
    }

    public let socketPath: String
    /// The secret of the daemon the supervisor started, and that daemon's pid,
    /// in memory only. The supervisor writes them; the client proves it.
    public let authSecret = CoreAuthSecret()
    public private(set) var authState: AuthState = .unproven
    /// Called when a connection could not be authenticated, so the app can
    /// restart the daemon it supervises (once) or say what is wrong.
    @ObservationIgnored public var onAuthRefused: (@MainActor (CoreAuthRefusal) -> Void)?
    /// Called when a connection has been authenticated.
    @ObservationIgnored public var onAuthenticated: (@MainActor () -> Void)?
    /// Called with every `settings` frame, after the model has taken it.
    @ObservationIgnored public var onSettingsFrame: (@MainActor (CoreSettings) -> Void)?
    public private(set) var connection: Connection = .idle
    public private(set) var hello: CoreHello?
    public private(set) var state: CoreState?
    public private(set) var lights: CoreLights?
    public private(set) var settingsFrame: CoreSettingsFrame?
    /// A reconnect can deliver unchanged settings from the same daemon stream.
    public private(set) var settingsConnectionRevision: UInt64 = 0
    public var settings: CoreSettings? { settingsFrame?.settings }
    /// The newest event for display. Consumers drain by sequence.
    public private(set) var lastEvent: CoreEvent?
    /// How many events the model keeps for a reader that was busy when a
    /// burst arrived.
    public static let recentEventLimit = 32
    /// The newest events in arrival order, past dedup. `lastEvent` is only
    /// the newest of them: two events in one turn of the run loop would
    /// show a watcher of it just the second.
    public private(set) var recentEvents: [CoreEvent] = []
    /// How many events have been applied; the event at the end of
    /// `recentEvents` is number `eventSequence`.
    public private(set) var eventSequence = 0

    /// The retained events numbered after `sequence`, oldest first: what a
    /// reader that last looked at `sequence` has not seen.
    public func events(after sequence: Int) -> [CoreEvent] {
        readEvents(after: sequence).events
    }

    public struct EventRead: Sendable {
        public let events: [CoreEvent]
        public let hasGap: Bool
    }

    public func readEvents(after sequence: Int) -> EventRead {
        let firstKept = eventSequence - recentEvents.count
        let start = max(0, sequence - firstKept)
        let events = start < recentEvents.count ? Array(recentEvents[start...]) : []
        return EventRead(events: events, hasGap: sequence < firstKept)
    }
    public private(set) var lastLog: CoreLog?
    /// The daemon's recent `log` messages, oldest first, bounded.
    public private(set) var logTail: [CoreLog] = []
    public static let logTailLimit = 200
    public private(set) var lastDecodeFailure: String?
    /// Why the newest `state` frame was refused (too big, unreadable, or of
    /// a protocol this app does not speak), or nil while the newest one was
    /// taken. While it is set the model is not live: what is on screen is
    /// the frame before the bad one, and nothing says it is current.
    public private(set) var stateRejected: String?
    public private(set) var unknownMessageCount = 0
    public private(set) var connectedAt: Date?
    /// Wall-clock arrival of the most recent `state` frame. The daemon
    /// builds a state document every 15 s refresh but broadcasts only when
    /// the projection changed (`doc_significant_equal` ignores the doc's
    /// own `now`/`generation`), so a quiet daemon legitimately sends
    /// nothing — this stamps the frame's age, not the daemon's heartbeat.
    public private(set) var lastStateAt: Date?
    /// Commands the app sent that the daemon has not answered yet. Not
    /// observed: every command moves it twice, and a view that re-rendered
    /// on each would re-render per command. A reader sees the count as of
    /// its own next render.
    @ObservationIgnored public private(set) var inFlightCommands = 0
    /// Every `state`'s usage windows, kept so the Usage Center can
    /// extrapolate a pace when the daemon sends no `forecast`.
    public private(set) var usageSamples = UsageSampleLog()

    /// Called for every event before the model applies it.
    public var onEvent: (@MainActor (CoreEvent) -> Void)?
    /// A repeated durable reset reaches only its receipt-aware consumer.
    public var onResetReplay: (@MainActor (CoreEvent) -> Void)?

    @ObservationIgnored private var client: CoreClient?
    /// Queued events from retired clients cannot change the current model.
    @ObservationIgnored private var clientGeneration: UInt64 = 0
    var eventGeneration: UInt64 { clientGeneration }
    @ObservationIgnored private var seenEventKeys: [String] = []
    /// Cached facts may outlive a stopped client, but cannot prove a new
    /// connection has delivered its own state.
    @ObservationIgnored private var hasStateForConnection = false

    public init(socketPath: String = CoreSocketPath.resolve()) {
        self.socketPath = socketPath
    }

    /// Facts and lights are only trusted once this connection has sent an
    /// accepted state; until then the file feeds keep running.
    ///
    /// Stored, and written only when it flips: a view that asks whether
    /// the monitor is live is not re-rendered by every `state` push, only
    /// by a connect, a first state or a disconnect.
    public private(set) var isLive = false

    /// Recomputes `isLive` from this connection's accepted state, assigning
    /// only a change so its readers are not woken for nothing.
    private func refreshLive() {
        let live = connection.isConnected && hasStateForConnection && state != nil && stateRejected == nil
        if isLive != live { isLive = live }
    }

    /// A `state` frame older than this stops counting as "current": six
    /// 15 s refresh ticks. Because the daemon dedupes unchanged frames this
    /// is an age bound, not a heartbeat check — a merely quiet daemon
    /// crosses it honestly, and the UI's job is to disclose the frame's age
    /// rather than claim a disconnect (the socket is still open).
    public static let stateStaleAfter: TimeInterval = 90

    /// How old the frame on screen is: the older of its wall-clock arrival
    /// and the daemon's own `state.now` stamp, so a replayed or
    /// clock-skewed frame cannot look fresher than it is. Nil before the
    /// first state.
    public func stateAge(at now: Date = Date()) -> TimeInterval? {
        guard let lastStateAt else { return nil }
        var age = now.timeIntervalSince(lastStateAt)
        if let built = state?.now { age = max(age, now.timeIntervalSince1970 - built) }
        return max(0, age)
    }

    /// Connected but the last frame is older than `stateStaleAfter`.
    /// `isLive` deliberately stays true — the socket is open and the
    /// monitor may simply have had nothing new to send.
    public func stateIsStale(at now: Date = Date()) -> Bool {
        (stateAge(at: now) ?? 0) > Self.stateStaleAfter
    }

    public func start() {
        guard client == nil else { return }
        clientGeneration &+= 1
        let generation = clientGeneration
        let client = CoreClient(socketPath: socketPath, auth: authSecret) { [weak self] event in
            Task { @MainActor [weak self] in
                self?.handle(event, generation: generation)
            }
        }
        self.client = client
        client.start()
    }

    public func stop() {
        clientGeneration &+= 1
        client?.stop()
        client = nil
        hasStateForConnection = false
        connection = .idle
        connectedAt = nil
        lastStateAt = nil
        refreshLive()
    }

    public func retryNow() { client?.retryNow() }

    func handle(_ event: CoreClient.Event, generation: UInt64) {
        guard clientGeneration == generation else { return }
        handle(event)
    }

    // MARK: Commands

    @discardableResult
    public func send(_ name: String, args: [String: JSONValue] = [:], timeout: TimeInterval? = nil) async throws -> CoreReply {
        guard let client else { throw CoreClientError.notConnected }
        inFlightCommands += 1
        defer { inFlightCommands -= 1 }
        let reply = try await client.send(name: name, args: args, timeout: timeout ?? Self.deckReplyTimeout(for: name))
        return explaining(reply)
    }

    /// The Deck worker admits one operation without a queue. Apply can
    /// inspect and write, each with a 60-second daemon budget.
    nonisolated static func deckReplyTimeout(for command: String) -> TimeInterval? {
        switch command {
        case "deck_plan_keymap", "deck_restore_keymap": return 65
        case "deck_apply_keymap": return 125
        case "deck_approve_device": return 22
        case "deck_disable": return 20
        default: return nil
        }
    }

    /// A daemon's `unauthenticated` refusal tells a terminal to use the app.
    /// Said to the app itself that would be a riddle, so it gets the reason
    /// this connection is not trusted instead.
    func explaining(_ reply: CoreReply) -> CoreReply {
        guard !reply.ok, reply.error?.code == "unauthenticated" else { return reply }
        var explained = reply
        if case .refused(let sentence) = authState {
            explained.error = CoreReplyError(code: "unauthenticated", message: sentence)
        } else {
            explained.error = CoreReplyError(
                code: "unauthenticated",
                message: "The daemon did not take this change from JR-Bar. Restart JR-Bar if this keeps happening.")
        }
        return explained
    }

    /// Sends and forgets; failures land in `lastDecodeFailure` for the log
    /// view, and a refusal (`ok: false`) in the log tail as well — a
    /// forgotten send the daemon turned down is still worth a line.
    public func post(_ name: String, args: [String: JSONValue] = [:]) {
        Task { [weak self] in
            do {
                guard let reply = try await self?.send(name, args: args), !reply.ok else { return }
                let why = reply.error?.message ?? reply.error?.code ?? "refused"
                self?.lastDecodeFailure = "\(name): \(why)"
                self?.appendLocalLog(level: "warn", "\(name) refused: \(why)")
            } catch {
                self?.lastDecodeFailure = "\(name): \(error)"
            }
        }
    }

    public func openSession(_ id: String) { post("open_session", args: ["session": .string(id)]) }

    /// `answer_ask` awaited: the reply carries the daemon's verdict —
    /// `ok: false` with `error.message` naming the refusal
    /// (`not_frontmost`, `accessibility_required`, `unsupported`, …).
    /// Callers that show a toast must show this, not a guessed success.
    /// `request` pins the answer to the ask's episode identity: a daemon
    /// that finds a DIFFERENT live request refuses `stale_request` rather
    /// than approving whatever replaced the card.
    @discardableResult
    public func answerAskNow(session: String, approve: Bool, onlyIfFrontmost: Bool = false,
                             replyText: String? = nil, request: String? = nil) async throws -> CoreReply {
        // The Try it ask has no agent: a second guard behind the desk's.
        if DemoAsk.isDemo(session: session) { return Self.demoRefusal }
        var args: [String: JSONValue] = [
            "session": .string(session),
            "decision": .string(approve ? "approve" : "deny"),
            "only_if_frontmost": .bool(onlyIfFrontmost),
        ]
        if let replyText { args["reply_text"] = .string(replyText) }
        if let request { args["request"] = .string(request) }
        return try await send("answer_ask", args: args, timeout: 8)
    }

    /// `answer_ask` with the decision as its word, awaited — the decide
    /// lane's own verbs: `always` for a held ask that offers it
    /// (`CoreAsk.canAlwaysAllow`), `answer` with `answers` for a held
    /// question (`CoreAsk.canChoose`), and `approve` / `deny` for a
    /// caller that holds its verdict as a word. Same pin, same 8 s wait,
    /// same verdict-in-the-reply as `answerAskNow(approve:)`.
    @discardableResult
    public func answerAskNow(session: String, decision: String, answers: [String: JSONValue]? = nil,
                             request: String? = nil) async throws -> CoreReply {
        if DemoAsk.isDemo(session: session) { return Self.demoRefusal }
        return try await send("answer_ask", args: Self.answerAskArgs(session: session, decision: decision,
                                                                     answers: answers, request: request),
                              timeout: 8)
    }

    /// What a caller gets for the Try it ask: a refusal made here, with
    /// nothing put on the socket.
    nonisolated static let demoRefusal = CoreReply(
        id: "", ok: false,
        error: CoreReplyError(code: "demo", message: "That is the demo ask — nothing was sent to any agent"))

    /// The `answer_ask` arguments for a decision word — pure, so what an
    /// Always allow or a picked option puts on the wire is a test.
    /// `answers` rides only with `answer`: a question's picks are never
    /// sent with a bare verdict.
    public nonisolated static func answerAskArgs(session: String, decision: String,
                                                 answers: [String: JSONValue]? = nil,
                                                 request: String? = nil) -> [String: JSONValue] {
        var args: [String: JSONValue] = [
            "session": .string(session),
            "decision": .string(decision),
            "only_if_frontmost": .bool(false),
        ]
        if decision == "answer", let answers { args["answers"] = .object(answers) }
        if let request { args["request"] = .string(request) }
        return args
    }

    /// `clear_completed` and its reply: `ok` with `{batch, cleared[]}`, the
    /// batch remembered for `undoClear`. Throws when the socket is down.
    @discardableResult
    public func clearCompletedNow(sessions: [String]? = nil) async throws -> CoreReply {
        clearRequestGeneration &+= 1
        let generation = clearRequestGeneration
        let scope: JSONValue = sessions.map { .array($0.map(JSONValue.string)) } ?? .string("all")
        let reply = try await send("clear_completed", args: ["sessions": scope])
        if reply.ok, let batch = reply.result?["batch"]?.stringValue,
           generation > acceptedClearGeneration {
            acceptedClearGeneration = generation
            lastClear = (batch, Date())
        }
        return reply
    }

    /// The daemon's count of sessions it keeps out of `state.sessions`
    /// (acknowledged, older); `list_history` still has them.
    public var hiddenSessionCount: Int { state?.hiddenCount ?? 0 }

    /// The last `clear_completed` batch and when it happened.
    public private(set) var lastClear: (batch: String, at: Date)?
    @ObservationIgnored private var clearRequestGeneration: UInt64 = 0
    @ObservationIgnored private var acceptedClearGeneration: UInt64 = 0

    /// True while the last clear is still inside the undo window.
    public var canUndoClear: Bool {
        guard let lastClear else { return false }
        return Date().timeIntervalSince(lastClear.at) < EventPolicy.undoWindow
    }

    /// Sends `undo_clear` for the last batch; returns the reply, or nil
    /// when there is nothing to undo.
    @discardableResult
    public func undoClear() async throws -> CoreReply? {
        guard let lastClear, canUndoClear else { return nil }
        let generation = acceptedClearGeneration
        let reply = try await send("undo_clear", args: ["batch": .string(lastClear.batch)])
        let terminal = reply.ok || reply.error?.code == "expired" || reply.error?.code == "not_found"
        if terminal, acceptedClearGeneration == generation, self.lastClear?.batch == lastClear.batch {
            self.lastClear = nil
        }
        return reply
    }

    /// `list_history`: rows newest first.
    public func listHistory(since: Double? = nil, limit: Int = 500) async throws -> [CoreHistoryRow] {
        var args: [String: JSONValue] = ["limit": .number(Double(limit))]
        if let since { args["since"] = .number(since) }
        let reply = try await send("list_history", args: args)
        guard reply.ok else { throw reply.error ?? CoreReplyError(code: "error", message: "list_history failed") }
        let rows = reply.result?["rows"]?.arrayValue ?? reply.result?.arrayValue ?? []
        let decoder = JSONDecoder()
        return try rows.compactMap { value -> CoreHistoryRow? in
            let data = try JSONEncoder().encode(value)
            return try decoder.decode(CoreHistoryRow.self, from: data)
        }.sorted { $0.at > $1.at }
    }

    /// `list_roster`: the daemon's whole retained session set — the rows
    /// `state.sessions` filters plus everything panel aging would hide —
    /// with `counts` over the retained set and the `coverage` bound.
    public func listRoster(scope: String = "all", provider: String? = nil, parent: String? = nil,
                           since: Double? = nil, limit: Int = 500) async throws -> CoreRoster {
        var args: [String: JSONValue] = ["scope": .string(scope), "limit": .number(Double(limit))]
        if let provider { args["provider"] = .string(provider) }
        if let parent { args["parent"] = .string(parent) }
        if let since { args["since"] = .number(since) }
        let reply = try await send("list_roster", args: args)
        guard reply.ok else { throw reply.error ?? CoreReplyError(code: "error", message: "list_roster failed") }
        guard let result = reply.result else {
            throw CoreReplyError(code: "bad_reply", message: "list_roster: missing result")
        }
        return try await ReplyDecoding.decodeOffMain(CoreRoster.self, from: result)
    }

    /// `session_timeline`: the session's provider transcript as bounded
    /// items — messages, tool_use/tool_result pairs, turn ends — newest
    /// page first. `before` pages older items; ended sessions keep
    /// working through `session`+`provider` once the roster row is gone —
    /// pass them so a row that aged out mid-browse still resolves.
    public func sessionTimeline(id: String, limit: Int = 100,
                                before: Int? = nil, provider: String? = nil,
                                session: String? = nil, cwd: String? = nil) async throws -> CoreTimelinePage {
        var args: [String: JSONValue] = ["id": .string(id), "limit": .number(Double(limit))]
        if let before { args["before"] = .number(Double(before)) }
        if let provider { args["provider"] = .string(provider) }
        if let session { args["session"] = .string(session) }
        if let cwd { args["cwd"] = .string(cwd) }
        let reply = try await send("session_timeline", args: args)
        guard reply.ok else { throw reply.error ?? CoreReplyError(code: "error", message: "session_timeline failed") }
        guard let result = reply.result else {
            throw CoreReplyError(code: "bad_reply", message: "session_timeline: missing result")
        }
        return try await ReplyDecoding.decodeOffMain(CoreTimelinePage.self, from: result)
    }

    /// `compare_sessions`: two runs side by side on retained facts —
    /// transcript aggregates, ledger interruptions, roster axes — with
    /// `warnings`/`gaps` naming what the comparison cannot claim.
    public func compareRuns(_ a: String, _ b: String) async throws -> CoreRunComparison {
        let reply = try await send("compare_sessions", args: [
            "a": .string(a), "b": .string(b)])
        guard reply.ok else { throw reply.error ?? CoreReplyError(code: "error", message: "compare_sessions failed") }
        guard let result = reply.result else {
            throw CoreReplyError(code: "bad_reply", message: "compare_sessions: missing result")
        }
        return try ReplyDecoding.decode(CoreRunComparison.self, from: result)
    }

    /// `usage_graph`: the shared-axis chart — per-provider series over
    /// the range on one scale, the day-grid heatmap, and the scan's own
    /// summary/disclosures. `days`, `metric`, `providers` are
    /// per-request overrides — the daemon does not rewrite settings.
    /// Transcript scans use a longer request timeout.
    public func usageGraph(days: Int? = nil, metric: String? = nil,
                           providers: [String]? = nil) async throws -> CoreUsageGraphDocument {
        var args: [String: JSONValue] = [:]
        if let days { args["days"] = .number(Double(days)) }
        if let metric { args["metric"] = .string(metric) }
        if let providers { args["providers"] = .array(providers.map(JSONValue.string)) }
        let reply = try await send("usage_graph", args: args, timeout: 150)
        guard reply.ok else { throw reply.error ?? CoreReplyError(code: "error", message: "usage_graph failed") }
        guard let result = reply.result else {
            throw CoreReplyError(code: "bad_reply", message: "usage_graph: missing result")
        }
        return try await ReplyDecoding.decodeOffMain(CoreUsageGraphDocument.self, from: result)
    }

    /// `replay_events`: the retained event journal for the Replay
    /// surface — read-only history with its coverage bounds (`retained`,
    /// `dropped`, `stream`) so the view can say exactly what it shows.
    public func replayEvents(limit: Int = 512) async throws -> CoreReplayPage {
        let reply = try await send("replay_events", args: ["limit": .number(Double(limit))])
        guard reply.ok else { throw reply.error ?? CoreReplyError(code: "error", message: "replay_events failed") }
        guard let result = reply.result else {
            throw CoreReplyError(code: "bad_reply", message: "replay_events: missing result")
        }
        let events = result["events"]?.arrayValue ?? []
        let decoder = JSONDecoder()
        let decoded = events.compactMap { value -> CoreEvent? in
            guard let data = try? JSONEncoder().encode(value) else { return nil }
            return try? decoder.decode(CoreEvent.self, from: data)
        }
        return CoreReplayPage(
            events: decoded,
            stream: result["stream"]?.stringValue,
            retained: result["retained"]?.intValue ?? decoded.count,
            dropped: result["dropped"]?.intValue ?? 0,
            resyncRequired: result["resync_required"]?.boolValue ?? false,
            reason: result["reason"]?.stringValue,
            cursor: result["cursor"]?.stringValue)
    }

    /// A line from the app itself (the supervisor, a delivery failure) in
    /// the same tail as the daemon's `log` messages.
    public func appendLocalLog(level: String = "info", _ message: String) {
        let entry = CoreLog(level: level, message: message, at: Date().timeIntervalSince1970)
        lastLog = entry
        logTail.append(entry)
        if logTail.count > Self.logTailLimit { logTail.removeFirst(logTail.count - Self.logTailLimit) }
    }

    public func setBrightness(device: String = "all", value: Double) {
        post("set_brightness", args: ["device": .string(device), "value": .number(min(1, max(0, value)))])
    }

    public func quiet(mode: String = "dnd", seconds: Int) async throws -> CoreReply {
        try await send("quiet", args: ["mode": .string(mode), "seconds": .number(Double(seconds))])
    }

    public func snooze(session: String? = nil, seconds: Int) {
        post("snooze", args: ["session": .string(session ?? "all"), "seconds": .number(Double(seconds))])
    }

    /// "Quiet this run": `snooze {session, seconds, scope: "run"}` quiets
    /// that one row — a main session or a single worker — for exactly
    /// `seconds` (a live ask still gets through), never its whole family
    /// the way `snooze` does. `seconds: 0` lifts it.
    public func quietRun(session: String, seconds: Int) {
        post("snooze", args: Self.quietRunArgs(session: session, seconds: seconds))
    }

    /// The `snooze` args `quietRun` sends — the protocol's `scope` field.
    public nonisolated static func quietRunArgs(session: String, seconds: Int) -> [String: JSONValue] {
        ["session": .string(session), "seconds": .number(Double(max(0, seconds))), "scope": .string("run")]
    }

    /// Returns the daemon's reply, including refusals. On success the
    /// daemon separately echoes settings and replies with its generation.
    @discardableResult
    public func setSetting(_ path: SettingsPath, value: JSONValue) async throws -> CoreReply {
        try await send("set_setting", args: ["path": .string(path.description), "value": value])
    }

    public func installHooks(providers: [String]) { post("install_hooks", args: ["providers": .array(providers.map(JSONValue.string))]) }

    /// `install_hooks` awaited: the reply's `results` maps each provider to
    /// its outcome so the row can show "Installed" or the error string.
    @discardableResult
    public func installHooksNow(providers: [String]) async throws -> CoreReply {
        try await send("install_hooks", args: ["providers": .array(providers.map(JSONValue.string))])
    }

    @discardableResult
    public func uninstallHooksNow(providers: [String]) async throws -> CoreReply {
        try await send("uninstall_hooks", args: ["providers": .array(providers.map(JSONValue.string))])
    }

    @discardableResult
    public func refreshHooksNow() async throws -> CoreReply {
        try await send("refresh_hooks", args: [:], timeout: 120)
    }

    /// Shows `program` on `surface` for `seconds`, then the daemon reverts.
    public func previewProgram(surface: String, program: String, seconds: Double) {
        post("preview_program", args: ["surface": .string(surface), "program": .string(program), "seconds": .number(seconds)])
    }

    /// Awaited `preview_program`: `ok: false` (e.g. `not_found` when no
    /// device of that surface is connected) must reach the caller.
    @discardableResult
    public func previewProgramNow(surface: String, program: String, seconds: Double) async throws -> CoreReply {
        try await send("preview_program", args: ["surface": .string(surface), "program": .string(program), "seconds": .number(seconds)])
    }

    /// Awaited `apply_calibration`: the reply says whether the profile
    /// persisted (`not_found` when the device was never seen).
    @discardableResult
    public func applyCalibrationNow(device: String, profile: [String: JSONValue]) async throws -> CoreReply {
        try await send("apply_calibration", args: ["device": .string(device), "profile": .object(profile)])
    }

    /// A held calibration preview: the daemon keeps the patch lit on the
    /// device until `endCalibrationPreview` (or its ten-minute backstop),
    /// so the sheet re-sends only when the working values change.
    /// Awaited: `not_found` when the device is not connected — the sheet
    /// must know rather than claim a lit patch.
    @discardableResult
    public func previewCalibrationNow(args: [String: JSONValue]) async throws -> CoreReply {
        try await send("preview_calibration", args: args)
    }

    public func endCalibrationPreview(device: String) {
        post("end_calibration_preview", args: ["device": .string(device)])
    }

    public func doctor() async throws -> CoreReply { try await send("doctor") }

    /// `mark_history_seen`: the user just looked at History — the daemon
    /// advances its `last_seen` watermark so `unseen` rows and the "while
    /// you were away" banner reflect looking, not app restarts.
    @discardableResult
    public func markHistorySeen() async throws -> CoreReply {
        try await send("mark_history_seen")
    }

    /// `dismiss_session {session}`: acknowledge a live or stuck row until
    /// it next speaks — the "hide this" affordance for a session whose
    /// process is alive but isn't going anywhere.
    @discardableResult
    public func dismissSession(_ session: String) async throws -> CoreReply {
        try await send("dismiss_session", args: ["session": .string(session)])
    }

    /// `dismiss_ask {session, request?}`: take one ask that may be stale
    /// off this Mac's surfaces. The daemon accepts it only for an ask it
    /// calls stale (`ask.isDismissible`), and it sends nothing to the
    /// agent: it is never an answer. `request` pins the ask the card shows,
    /// so a replaced one is refused (`stale_request`).
    @discardableResult
    public func dismissAsk(session: String, request: String? = nil) async throws -> CoreReply {
        var args: [String: JSONValue] = ["session": .string(session)]
        if let request { args["request"] = .string(request) }
        return try await send("dismiss_ask", args: args)
    }

    /// `list_scene_packs`: the installed scene packs (id, name, effect ids).
    public func listScenePacks() async throws -> [ScenePackSummary] {
        let reply = try await send("list_scene_packs")
        guard reply.ok else { throw reply.error ?? CoreReplyError(code: "error", message: "list_scene_packs failed") }
        let packs = reply.result?["packs"]?.arrayValue ?? []
        let decoder = JSONDecoder()
        return try packs.compactMap { value in
            let data = try JSONEncoder().encode(value)
            return try decoder.decode(ScenePackSummary.self, from: data)
        }
    }

    /// `import_scene_pack {path}`: the daemon validates and installs the
    /// pack file itself. Replies `{ok, pack_id, ...}` or an error.
    @discardableResult
    public func importScenePack(path: String) async throws -> CoreReply {
        try await send("import_scene_pack", args: ["path": .string(path)])
    }

    /// `preview_scene_pack {pack_id}`: renders the pack's program so the
    /// Studio can preview it before installing or assigning.
    public func previewScenePack(packID: String, ledCount: Int = 8) async throws -> EffectPreview {
        try await request("preview_scene_pack", args: [
            "pack_id": .string(packID),
            "led_count": .number(Double(ledCount)),
        ], as: EffectPreview.self)
    }

    /// `serve_token`: the loopback status endpoint's bearer token, for the
    /// Settings › Remote reveal row. Local socket, so plain text is fine.
    public func serveToken() async throws -> String? {
        let reply = try await send("serve_token")
        guard reply.ok else { return nil }
        return reply.result?["token"]?.stringValue
    }

    /// `ntfy_test`: Settings › Remote's Test button. One fixed line to the
    /// saved ntfy topic, sent only because the person clicked. The reply's
    /// `message` is the sentence to show, verbatim.
    public func testPhoneAlert() async throws -> (sent: Bool, message: String) {
        let reply = try await send("ntfy_test", timeout: 15)
        guard reply.ok else {
            throw reply.error ?? CoreReplyError(code: "error", message: "ntfy_test failed")
        }
        let sent = reply.result?["sent"]?.boolValue ?? false
        let message = reply.result?["message"]?.stringValue ?? (sent ? "Sent." : "Nothing was sent.")
        return (sent, message)
    }

    /// Puts every listed path back to the daemon's default.
    @discardableResult
    public func resetSettings(paths: [String]) async throws -> CoreReply {
        try await send("reset_settings", args: ["paths": .array(paths.map(JSONValue.string))])
    }

    /// Sends and decodes; a `not ok` reply becomes its `CoreReplyError`.
    public func request<T: Decodable>(_ name: String, args: [String: JSONValue] = [:], as type: T.Type, timeout: TimeInterval? = nil) async throws -> T {
        let reply = try await send(name, args: args, timeout: timeout)
        guard reply.ok else { throw reply.error ?? CoreReplyError(code: "error", message: "\(name) failed") }
        return try ReplyDecoding.decode(type, from: reply.result)
    }

    // MARK: Usage Center (app-proposed extensions, see app/README.md)

    /// Includes time queued behind other scan-lane commands.
    public static let usageHistoryTimeout: TimeInterval = 30

    /// Observation reports current memory without starting or retrying a scan.
    public func usageHistory(provider: String, range: UsageHistoryRange,
                             observe: Bool = false) async throws -> UsageHistory {
        var args: [String: JSONValue] = ["provider": .string(provider), "range": .string(range.rawValue)]
        if observe { args["observe"] = .bool(true) }
        return try await request("usage_history", args: args, as: UsageHistory.self,
                                 timeout: Self.usageHistoryTimeout)
    }

    /// `refresh_usage {providers[]}`; an empty list means every provider.
    @discardableResult
    public func refreshUsage(providers: [String] = []) async throws -> CoreReply {
        try await send("refresh_usage", args: ["providers": .array(providers.map(JSONValue.string))])
    }

    // MARK: Provider connections (W06)

    /// `list_providers` → one inspection row per configured provider
    /// instance (enabled flag, live state, consents, credential
    /// availability — never secrets).
    public func listProviders(
        provider: String? = nil,
        instance: String? = nil
    ) async throws -> [ProviderRow] {
        var args: [String: JSONValue] = [:]
        if let provider { args["provider"] = .string(provider) }
        if let instance { args["instance"] = .string(instance) }
        let reply = try await send("list_providers", args: args)
        guard reply.ok else {
            throw reply.error ?? CoreReplyError(code: "error", message: "list_providers failed")
        }
        return try ReplyDecoding.decode([ProviderRow].self, from: reply.result?["providers"])
    }

    /// Store a key without changing consent or requesting usage.
    @discardableResult
    public func setProviderCredential(
        _ provider: String, account: String, secret: String, instance: String = "default"
    ) async throws -> ProviderCredentialReceipt {
        let normalized = try Self.normalizedProviderSecret(secret)
        return try await providerCredentialCommand("set_provider_credential", provider: provider,
            account: account, instance: instance, secret: normalized, available: true)
    }

    @discardableResult
    public func deleteProviderCredential(
        _ provider: String, account: String, instance: String = "default"
    ) async throws -> ProviderCredentialReceipt {
        try await providerCredentialCommand("delete_provider_credential", provider: provider,
            account: account, instance: instance, secret: nil, available: false)
    }

    public nonisolated static func normalizedProviderSecret(_ secret: String) throws -> String {
        let value = secret.trimmingCharacters(in: .whitespacesAndNewlines)
        let hasControls = value.unicodeScalars.contains { scalar in
            switch scalar.properties.generalCategory {
            case .control, .format, .lineSeparator, .paragraphSeparator: return true
            default: return false
            }
        }
        guard !value.isEmpty, value.utf8.count <= 64 * 1024, !hasControls else {
            throw CoreReplyError(code: "invalid_args", message: "Enter a single-line API key of at most 64 KiB.")
        }
        return value
    }

    private func providerCredentialCommand(
        _ command: String, provider: String, account: String, instance: String,
        secret: String?, available: Bool
    ) async throws -> ProviderCredentialReceipt {
        var args: [String: JSONValue] = [
            "provider": .string(provider), "account": .string(account), "instance": .string(instance),
        ]
        if let secret { args["secret"] = .string(secret) }
        let reply = try await send(command, args: args)
        guard reply.ok else {
            throw CoreReplyError(code: reply.error?.code ?? "credential_unavailable")
        }
        let receipt: ProviderCredentialReceipt
        do { receipt = try ReplyDecoding.decode(ProviderCredentialReceipt.self, from: reply.result) }
        catch { throw CoreReplyError(code: "bad_reply") }
        guard receipt.matches(provider: provider, instance: instance, account: account, available: available) else {
            throw CoreReplyError(code: "bad_reply")
        }
        return receipt
    }

    /// `set_provider_enabled {provider, enabled, instance}` → the row as
    /// persisted. `settings_changed` means a concurrent edit won; reload
    /// and retry.
    @discardableResult
    public func setProviderEnabled(
        _ provider: String,
        enabled: Bool,
        instance: String? = nil
    ) async throws -> ProviderRow {
        var args: [String: JSONValue] = [
            "provider": .string(provider),
            "enabled": .bool(enabled),
        ]
        if let instance { args["instance"] = .string(instance) }
        let reply = try await send("set_provider_enabled", args: args)
        guard reply.ok else {
            throw reply.error ?? CoreReplyError(code: "error", message: "set_provider_enabled failed")
        }
        return try ReplyDecoding.decode(ProviderRow.self, from: reply.result?["provider"])
    }

    /// `set_provider_usage_consent {provider, enabled, instance, source}` →
    /// the row as persisted. Turning it on is the person's own act: the
    /// caller shows the row's `usage_consent.summary` first. `source` is
    /// `setup`, `settings` or `usage_center`.
    @discardableResult
    public func setProviderUsageConsent(
        _ provider: String,
        enabled: Bool,
        source: String,
        instance: String? = nil
    ) async throws -> ProviderRow {
        var args: [String: JSONValue] = [
            "provider": .string(provider),
            "enabled": .bool(enabled),
            "source": .string(source),
        ]
        if let instance { args["instance"] = .string(instance) }
        let reply = try await send("set_provider_usage_consent", args: args)
        guard reply.ok else {
            throw reply.error ?? CoreReplyError(code: "error", message: "set_provider_usage_consent failed")
        }
        return try ReplyDecoding.decode(ProviderRow.self, from: reply.result?["provider"])
    }

    /// Save source choices without changing usage consent.
    @discardableResult
    public func setProviderOptions(
        _ provider: String,
        options: [String: String],
        instance: String? = nil
    ) async throws -> ProviderRow {
        let args = Self.providerOptionsArguments(provider, options: options, instance: instance)
        let reply = try await send("set_provider_options", args: args)
        guard reply.ok else {
            throw reply.error ?? CoreReplyError(code: "error", message: "set_provider_options failed")
        }
        return try ReplyDecoding.decode(ProviderRow.self, from: reply.result?["provider"])
    }

    nonisolated static func providerOptionsArguments(
        _ provider: String, options: [String: String], instance: String?
    ) -> [String: JSONValue] {
        var args: [String: JSONValue] = ["provider": .string(provider),
                                        "options": .object(options.mapValues { .string($0) })]
        if let instance { args["instance"] = .string(instance) }
        return args
    }

    /// `provider_add_instance {provider, instance, label}` → the new
    /// row. Only providers with a per-instance source accept it — the
    /// daemon answers `unsupported` where a second account would just
    /// mirror this Mac's own sign-in.
    @discardableResult
    public func addProviderInstance(
        _ provider: String,
        instance: String,
        label: String? = nil
    ) async throws -> ProviderRow {
        var args: [String: JSONValue] = [
            "provider": .string(provider),
            "instance": .string(instance),
        ]
        if let label { args["label"] = .string(label) }
        let reply = try await send("provider_add_instance", args: args)
        guard reply.ok else {
            throw reply.error ?? CoreReplyError(code: "error", message: "provider_add_instance failed")
        }
        return try ReplyDecoding.decode(ProviderRow.self, from: reply.result?["provider"])
    }

    /// `provider_consent` — list, or grant/revoke one exact
    /// provider+browser+profile scope. Grant imports nothing.
    @discardableResult
    public func providerConsent(
        action: String,
        provider: String? = nil,
        browser: String? = nil,
        profile: String? = nil,
        backgroundRepair: Bool = false,
        instance: String? = nil
    ) async throws -> CoreReply {
        var args: [String: JSONValue] = ["action": .string(action)]
        if let provider { args["provider"] = .string(provider) }
        if let browser { args["browser"] = .string(browser) }
        if let profile { args["profile"] = .string(profile) }
        if let instance { args["instance"] = .string(instance) }
        if action == "grant" { args["background_repair"] = .bool(backgroundRepair) }
        return try await send("provider_consent", args: args)
    }

    /// `provider_action` with `action:"resign_in"`: the per-provider
    /// "Re-sign in" / "Update provider" click. The daemon re-pulls
    /// whatever sign-in the provider's own tooling holds and forces a
    /// refresh, even when no staged action label is on the card. The
    /// reply's `message` is the daemon's honest account — including the
    /// provider's own remedy when only its CLI/app can sign in — and
    /// `signInURL` is set when the remedy is a page to open.
    public func resignInProvider(_ provider: String, instance: String? = nil) async throws -> ProviderResignInResult {
        var args: [String: JSONValue] = [
            "provider": .string(provider),
            "action": .string("resign_in"),
        ]
        if let instance { args["instance"] = .string(instance) }
        let reply = try await send("provider_action", args: args)
        guard reply.ok else {
            throw reply.error ?? CoreReplyError(code: "error", message: "re-sign-in failed")
        }
        return ProviderResignInResult(
            message: reply.result?["message"]?.stringValue ?? "",
            signInURL: reply.result?["sign_in_url"]?.stringValue
        )
    }

    /// How long a `provider_sign_in` reply may take: a Claude renewal is a
    /// real call the daemon allows 90 s, and the command waits on the
    /// daemon's slow lane so nothing else the app sends waits with it.
    public nonisolated static let signInReplyTimeout: TimeInterval = 120

    /// The args `provider_sign_in` takes: a provider, its instance and the
    /// terminal when one is named. Never a command: the daemon's own table
    /// says what a provider signs in with.
    public nonisolated static func signInArgs(provider: String, instance: String? = nil,
                                              terminal: String? = nil) -> [String: JSONValue] {
        var args: [String: JSONValue] = ["provider": .string(provider)]
        if let instance, !instance.isEmpty, instance != "default" { args["instance"] = .string(instance) }
        if let terminal, !terminal.isEmpty { args["terminal"] = .string(terminal) }
        return args
    }

    /// `provider_sign_in`: "Fix sign-in". The daemon does the best
    /// automatic thing (re-read, ask Claude Code to renew its own sign-in,
    /// or open the owner's terminal on the provider's own login) and answers
    /// with one sentence to show as it is. Explicit only: a click.
    public func signInProvider(_ provider: String, instance: String? = nil,
                               terminal: String? = nil) async throws -> ProviderSignInResult {
        let reply = try await send(
            "provider_sign_in",
            args: Self.signInArgs(provider: provider, instance: instance, terminal: terminal),
            timeout: Self.signInReplyTimeout
        )
        guard reply.ok else {
            throw reply.error ?? CoreReplyError(code: "error", message: "provider_sign_in failed")
        }
        return ProviderSignInResult(reply.result, provider: provider)
    }

    /// `provider_update`: runs the provider's own updater on a daemon
    /// thread and answers at once. Only a provider id goes on the wire; the
    /// result arrives in `providerUpdates`. A plain refusal (no updater,
    /// not installed, busy) is a result to show, not a thrown error.
    public func updateProvider(_ provider: String) async throws -> ProviderUpdateStart {
        let reply = try await send("provider_update", args: ["provider": .string(provider)], timeout: 10)
        guard reply.ok else {
            throw reply.error ?? CoreReplyError(code: "error", message: "provider_update failed")
        }
        return ProviderUpdateStart(reply.result, provider: provider)
    }

    /// `provider_update_check`: asks for a fresh "update available" look.
    /// The daemon does nothing at all unless the person turned update
    /// checks on, so this is safe to send whenever Agents is refreshed.
    public func checkProviderUpdates() {
        post("provider_update_check")
    }

    /// `provider_action` runs the staged flow behind the provider's
    /// current action label (clipboard import, reconnect, repair). The
    /// reply carries the message the daemon surfaced; `unsupported`
    /// means no staged action matches the live state.
    public func providerAction(_ provider: String, instance: String? = nil, action: String? = nil) async throws -> String {
        var args: [String: JSONValue] = ["provider": .string(provider)]
        if let instance { args["instance"] = .string(instance) }
        if let action { args["action"] = .string(action) }
        let reply = try await send("provider_action", args: args)
        guard reply.ok else {
            throw reply.error ?? CoreReplyError(code: "error", message: "provider_action failed")
        }
        return reply.result?["message"]?.stringValue ?? ""
    }

    // MARK: Effect Studio (app-proposed extensions, see app/README.md)

    public func listEffects() async throws -> EffectCatalog {
        try await request("list_effects", as: EffectCatalog.self)
    }

    public func listAssignments() async throws -> EffectAssignmentDocument {
        try await request("list_assignments", as: EffectAssignmentDocument.self)
    }

    /// `render_effect {effect_id, parameters, led_count}` → the LEDS program
    /// the daemon would play for those parameters.
    public func renderEffect(_ effectID: String, parameters: [String: JSONValue], ledCount: Int = 8) async throws -> EffectPreview {
        try await request("render_effect", args: [
            "effect_id": .string(effectID),
            "parameters": .object(parameters),
            "led_count": .number(Double(ledCount)),
        ], as: EffectPreview.self)
    }

    /// `render_effect` drawn in `color` (`#RRGGBB`) instead of the working
    /// cyan: how the effect looks on one provider, in its own colour.
    public func renderEffect(_ effectID: String, parameters: [String: JSONValue], ledCount: Int = 8,
                             color: String?) async throws -> EffectPreview {
        guard let color else { return try await renderEffect(effectID, parameters: parameters, ledCount: ledCount) }
        return try await request("render_effect", args: [
            "effect_id": .string(effectID),
            "parameters": .object(parameters),
            "led_count": .number(Double(ledCount)),
            "color": .string(color),
        ], as: EffectPreview.self)
    }

    /// `set_assignment {effect_id, scope, target_id, parameters}`: the
    /// Effect Studio assignment for that scope and target. Unlike
    /// `apply_effect` this command persists tuned `parameters` to the
    /// sidecar and returns the full document (assignments, `active_scene`,
    /// `generation`).
    @discardableResult
    public func setAssignment(_ assignment: EffectAssignment) async throws -> EffectAssignmentDocument {
        var args: [String: JSONValue] = [
            "effect_id": .string(assignment.effectID),
            "scope": .string(assignment.scope.rawValue),
            "target_id": assignment.targetID.map(JSONValue.string) ?? .null,
            "parameters": .object(assignment.parameters),
        ]
        if assignment.parameters.isEmpty { args["parameters"] = nil }
        return try await request("set_assignment", args: args, as: EffectAssignmentDocument.self)
    }

    /// `clear_assignment {scope, target_id}` removes the assignment.
    @discardableResult
    public func clearAssignment(scope: EffectScope, targetID: String?) async throws -> EffectAssignmentDocument {
        let args: [String: JSONValue] = [
            "scope": .string(scope.rawValue),
            "target_id": targetID.map(JSONValue.string) ?? .null,
        ]
        return try await request("clear_assignment", args: args, as: EffectAssignmentDocument.self)
    }

    /// `import_effect_pack {path, update?}`: the daemon reads and validates
    /// the JSON itself (the app never parses a pack) and replies with the
    /// new catalog. `update: true` is the explicit replace a Studio offers
    /// after an `already_installed` conflict.
    public func importEffectPack(path: String, update: Bool = false) async throws -> EffectCatalog {
        var args: [String: JSONValue] = ["path": .string(path)]
        if update { args["update"] = .bool(true) }
        return try await request("import_effect_pack", args: args, as: EffectCatalog.self)
    }

    /// `remove_effect_pack {pack_id}`: uninstalls a pack and replies with
    /// the new catalog. (App-proposed; a core without it answers
    /// `unknown_command`, which the Studio shows as the refusal.)
    public func removeEffectPack(packID: String) async throws -> EffectCatalog {
        try await request("remove_effect_pack", args: ["pack_id": .string(packID)], as: EffectCatalog.self)
    }

    /// `export_effect_pack {ids[], path}` writes a data-only JSON v2 pack.
    @discardableResult
    public func exportEffectPack(ids: [String], path: String, name: String? = nil) async throws -> CoreReply {
        var args: [String: JSONValue] = ["ids": .array(ids.map(JSONValue.string)), "path": .string(path)]
        if let name { args["name"] = .string(name) }
        let reply = try await send("export_effect_pack", args: args)
        guard reply.ok else { throw reply.error ?? CoreReplyError(code: "error", message: "export failed") }
        return reply
    }

    // MARK: Control Center (app-proposed extensions, see app/README.md)

    // `deck` is a slice of `state` (see Slices).

    /// `deck_press {index}`: what a physical press of that control does,
    /// from the screen (a session key reveals its session; an auxiliary
    /// control runs its explicit mapping). Indices 0..23.
    @discardableResult
    public func deckPress(index: Int) async throws -> CoreReply {
        try await send("deck_press", args: ["index": .number(Double(index))])
    }

    /// `deck_pin {index}`: toggles the pin on the identity at that key. Pins
    /// are per identity, so they survive Clear absent and bank changes.
    @discardableResult
    public func deckPin(index: Int) async throws -> CoreReply {
        try await send("deck_pin", args: ["index": .number(Double(index))])
    }

    /// `deck_bank {delta}`: ±1, wrapping.
    @discardableResult
    public func deckBank(delta: Int) async throws -> CoreReply {
        try await send("deck_bank", args: ["delta": .number(Double(delta))])
    }

    /// `deck_scope {delta}`: ±1, stepping the board scope through
    /// `automatic` plus the configured provider scopes, wrapping.
    /// `{scope, scopes}`.
    @discardableResult
    public func deckScope(delta: Int) async throws -> CoreReply {
        try await send("deck_scope", args: ["delta": .number(Double(delta))])
    }

    /// `deck_rail {edge}`: off, left, right, top or bottom.
    @discardableResult
    public func deckRail(edge: DeckRailEdge) async throws -> CoreReply {
        try await send("deck_rail", args: ["edge": .string(edge.rawValue)])
    }

    /// `deck_clear_absent`: unpinned identities with no observed session leave the board.
    @discardableResult
    public func deckClearAbsent() async throws -> CoreReply { try await send("deck_clear_absent") }

    /// `deck_plan_keymap {profile, layer, include_auxiliary}`: the review
    /// text and change list Apply would write, without writing.
    public func deckPlanKeymap(profile: Int, layer: Int, includeAuxiliary: Bool) async throws -> CoreReply {
        try await send("deck_plan_keymap", args: [
            "profile": .number(Double(profile)), "layer": .number(Double(layer)), "include_auxiliary": .bool(includeAuxiliary),
        ])
    }

    /// `deck_plan_keymap {profile, layers, include_auxiliary}`: the review
    /// for the multi-layer write `deckApplyKeymap(profile:layers:)` runs.
    /// A daemon that predates `layers` answers the `layer` plan instead.
    public func deckPlanKeymap(profile: Int, layer: Int, layers: [(layer: Int, name: String)],
                               includeAuxiliary: Bool) async throws -> CoreReply {
        try await send("deck_plan_keymap", args: [
            "profile": .number(Double(profile)), "layer": .number(Double(layer)),
            "layers": .array(layers.map { .object(["layer": .number(Double($0.layer)), "name": .string($0.name)]) }),
            "include_auxiliary": .bool(includeAuxiliary),
        ])
    }

    /// `deck_apply_keymap {profile, layer, include_auxiliary}`: backs the
    /// original up, writes the vendor keycodes to that layer and verifies
    /// the readback. The reply carries the receipt `{code, message}`.
    @discardableResult
    public func deckApplyKeymap(profile: Int, layer: Int, includeAuxiliary: Bool) async throws -> CoreReply {
        try await send("deck_apply_keymap", args: [
            "profile": .number(Double(profile)), "layer": .number(Double(layer)), "include_auxiliary": .bool(includeAuxiliary),
        ])
    }

    /// `deck_apply_keymap {profile, layers, include_auxiliary}`: one write
    /// claiming and naming every listed layer at once.
    @discardableResult
    public func deckApplyKeymap(profile: Int, layers: [(layer: Int, name: String)],
                                includeAuxiliary: Bool) async throws -> CoreReply {
        try await send("deck_apply_keymap", args: [
            "profile": .number(Double(profile)),
            "layers": .array(layers.map { .object(["layer": .number(Double($0.layer)), "name": .string($0.name)]) }),
            "include_auxiliary": .bool(includeAuxiliary),
        ])
    }

    /// `deck_restore_keymap`: the first private backup goes back, verified.
    @discardableResult
    public func deckRestoreKeymap() async throws -> CoreReply { try await send("deck_restore_keymap") }

    /// `deck_approve_device`: binds JR-Bar to the connected pad's serial.
    @discardableResult
    public func deckApproveDevice() async throws -> CoreReply { try await send("deck_approve_device") }

    /// `deck_disable`: writes `creator_micro_enabled = false` — the output
    /// service is torn down; the approved serial survives the off switch.
    public func deckDisable() async throws -> CoreReply { try await send("deck_disable") }

    /// `deck_check_input {enabled}`: inputs are shown, actions are paused.
    @discardableResult
    public func deckCheckInput(enabled: Bool) async throws -> CoreReply {
        try await send("deck_check_input", args: ["enabled": .bool(enabled)])
    }

    /// `deck_set_settings {enabled, session_mode, analog_enabled, bindings,
    /// layer_map, layer_owners, scopes}` (any subset). `bindings` replaces
    /// every auxiliary binding; `layer_map` maps hardware layers to board
    /// scopes; `layer_owners` hands hardware layers past layer 1 to an
    /// external writer (a provider id or "everything"); `scopes` adds
    /// provider scopes past the mapped ones.
    @discardableResult
    public func deckSetSettings(enabled: Bool? = nil, sessionMode: Bool? = nil, analogEnabled: Bool? = nil,
                                bindings: [(index: Int, action: String?)]? = nil,
                                layerMap: [(layer: Int, scope: String)]? = nil,
                                layerOwners: [(layer: Int, owner: String)]? = nil,
                                scopes: [String]? = nil) async throws -> CoreReply {
        var args: [String: JSONValue] = [:]
        if let enabled { args["enabled"] = .bool(enabled) }
        if let sessionMode { args["session_mode"] = .bool(sessionMode) }
        if let analogEnabled { args["analog_enabled"] = .bool(analogEnabled) }
        if let bindings {
            args["bindings"] = .array(bindings.map {
                .object(["index": .number(Double($0.index)),
                         "action": $0.action.map(JSONValue.string) ?? .null])
            })
        }
        if let layerMap {
            args["layer_map"] = .array(layerMap.map {
                .object(["layer": .number(Double($0.layer)), "scope": .string($0.scope)])
            })
        }
        if let layerOwners {
            args["layer_owners"] = .array(layerOwners.map {
                .object(["layer": .number(Double($0.layer)), "owner": .string($0.owner)])
            })
        }
        if let scopes { args["scopes"] = .array(scopes.map(JSONValue.string)) }
        return try await send("deck_set_settings", args: args)
    }

    // MARK: Inbound

    /// A dropped socket takes the daemon's facts with it: the next daemon
    /// may be a restart that has not refreshed yet, and its asks, rows and
    /// lights are not the dead one's. `settings` and `usageSamples` stay —
    /// the document is re-sent on connect and the samples are history.
    /// `hello` clears on connect, so a new socket says who it is afresh.
    func handle(_ event: CoreClient.Event) {
        switch event {
        case .connecting(let attempt):
            hasStateForConnection = false
            connection = .connecting(attempt: attempt)
        case .connected:
            hasStateForConnection = false
            connection = .connected
            connectedAt = Date()
            hello = nil
            authState = .unproven
        case .authenticated:
            authState = .authenticated
            onAuthenticated?()
        case .authRefused(let reason):
            authState = .refused(reason.sentence)
            appendLocalLog(level: "warn", reason.sentence)
            onAuthRefused?(reason)
        case .disconnected(let reason):
            hasStateForConnection = false
            authState = .unproven
            connection = .disconnected(reason: reason)
            connectedAt = nil
            state = nil
            stateRejected = nil
            applySlices(nil)
            lights = nil
            lastStateAt = nil
        case .decodeFailure(let why):
            lastDecodeFailure = why
        case .stateRejected(let why):
            stateRejected = why
        case .message(let message):
            apply(message)
        }
        refreshLive()
    }

    public func apply(_ message: CoreMessage) {
        switch message {
        case .hello(let hello):
            settingsConnectionRevision &+= 1
            self.hello = hello
        case .state(let state):
            stateRejected = nil
            self.state = state
            applySlices(state)
            hasStateForConnection = connection.isConnected
            refreshLive()
            lastStateAt = Date()
            usageSamples.record(state.usage, now: state.now ?? Date().timeIntervalSince1970)
        case .lights(let lights):
            self.lights = lights
        case .settings(let settings):
            self.settingsFrame = CoreSettingsFrame(settings: settings, stream: hello?.stream,
                                                  connectionRevision: settingsConnectionRevision)
            onSettingsFrame?(settings)
        case .event(let event):
            let key = event.cursor ?? hello?.stream.map { "\($0):\(event.id)" } ?? event.id
            if seenEventKeys.contains(key) {
                if event.isDurableResetReplay { onResetReplay?(event) }
                return
            }
            seenEventKeys.append(key)
            if seenEventKeys.count > 64 { seenEventKeys.removeFirst(seenEventKeys.count - 64) }
            onEvent?(event)
            eventSequence += 1
            recentEvents.append(event)
            if recentEvents.count > Self.recentEventLimit {
                recentEvents.removeFirst(recentEvents.count - Self.recentEventLimit)
            }
            lastEvent = event
        case .reply:
            break
        case .log(let log):
            lastLog = log
            logTail.append(log)
            if logTail.count > Self.logTailLimit { logTail.removeFirst(logTail.count - Self.logTailLimit) }
        case .unknown(let type, let version):
            unknownMessageCount += 1
            // A `state` from another protocol version is not this app's to
            // read: the old model must not stand as current beside it.
            if type == "state" {
                let theirs = version.map(String.init) ?? "unknown"
                stateRejected = "its protocol version is \(theirs), this app speaks \(CoreProtocol.version)"
                refreshLive()
            }
        }
    }

    // MARK: Slices

    // Each part of the latest `state` on its own, assigned only when it
    // differs from what is there. The daemon sends the whole document on
    // every change, so a reader of `state` is woken by every frame; a
    // reader of a slice only by a frame that changed that slice. `state`
    // stays for the readers that want the whole document.

    /// The sessions the panel lists (`CoreState.mainSessions`), filtered
    /// once per frame rather than on every read.
    public private(set) var sessions: [CoreSession] = []
    /// Every session in the frame, workers included (`state.sessions`).
    public private(set) var allSessions: [CoreSession] = []
    public private(set) var asks: [CoreAsk] = []
    public private(set) var devices: [CoreDevice] = []
    /// `state.usage.providers`.
    public private(set) var usage: [CoreProviderUsage] = []
    public private(set) var aggregate: CoreAggregate?
    public private(set) var power: CorePower?
    public private(set) var focus: CoreFocus?
    public private(set) var presence: CorePresence?
    public private(set) var deck: DeckState?
    public private(set) var health: JSONValue?
    /// `state.provider_updates`: what each agent CLI's updater last did,
    /// keyed by provider id; empty from an older daemon.
    public private(set) var providerUpdates: [String: ProviderUpdateStatus] = [:]
    /// `state.firmware`: the firmware update job, nil while there is none.
    public private(set) var firmware: FirmwareJob?
    /// `state.catalog_generation` and `state.settings_generation`: what
    /// the Effect Studio reloads on.
    public private(set) var catalogGeneration: Int?
    public private(set) var stateSettingsGeneration: Int?

    /// Brings every slice in line with `state`, touching only those that
    /// changed. A disconnect clears them with the document.
    private func applySlices(_ state: CoreState?) {
        // `mainSessions` is a pure filter of `sessions` — when the roster
        // compares unchanged, the mains provably did too, so the second
        // deep compare is skipped. One session walk per state frame, not two.
        let all = state?.sessions ?? []
        if all != allSessions {
            allSessions = all
            assign(\.sessions, state?.mainSessions ?? [])
        }
        assign(\.asks, state?.asks ?? [])
        assign(\.devices, state?.devices ?? [])
        assign(\.usage, state?.usage?.providers ?? [])
        assign(\.aggregate, state?.aggregate)
        assign(\.power, state?.power)
        assign(\.focus, state?.focus)
        assign(\.presence, state?.presence)
        assign(\.deck, state?.deck)
        assign(\.health, state?.health)
        assign(\.providerUpdates, state?.providerUpdates ?? [:])
        assign(\.firmware, state?.firmware)
        assign(\.catalogGeneration, state?.catalogGeneration)
        assign(\.stateSettingsGeneration, state?.settingsGeneration)
    }

    private func assign<Value: Equatable>(_ slice: ReferenceWritableKeyPath<CoreModel, Value>, _ value: Value) {
        if self[keyPath: slice] != value { self[keyPath: slice] = value }
    }

    // MARK: Derived

    /// Open asks, with the session's own record where the pinned list lacks one.
    public var openAsks: [CoreAsk] {
        var result = asks
        let pinned = Set(result.compactMap(\.session))
        for session in sessions where !pinned.contains(session.id) {
            if var ask = session.ask {
                ask.session = session.id
                result.append(ask)
            }
        }
        return result
    }
}

// MARK: - Startup program (lights lane)

extension CoreModel {
    /// `burn_init {program, device?}`: writes `program` to a SidePulse
    /// device's INIT.LED — what it plays at power-up, with no monitor
    /// running — and the firmware applies it at once as confirmation.
    /// `device` is a device id; nil lets the daemon pick the strip. The
    /// caller sends only a program the presentation compiler accepted.
    /// The command belongs to the daemon's hardware work; a daemon
    /// without it answers `unknown_command`, which the LEDS Studio
    /// reports as nothing written rather than claiming a burn.
    /// Sent with `confirm: true`: the caller has already asked the person,
    /// and without it the daemon only answers with the plan it would write.
    @discardableResult
    public func burnInitProgramNow(_ program: String, device: String? = nil) async throws -> CoreReply {
        var args: [String: JSONValue] = ["program": .string(program), "confirm": .bool(true)]
        if let device { args["device"] = .string(device) }
        return try await send("burn_init", args: args)
    }
}

// MARK: - Presence and the keep-awake lease (presence lane)

extension CoreModel {
    /// `presence`: what the app's sensors see — a live microphone or
    /// camera is a call (`CorePresenceReport`). The daemon holds a report
    /// for 180 s; `PresenceReporting` decides when one is owed.
    @discardableResult
    public func reportPresence(_ report: CorePresenceReport) async throws -> CoreReply {
        try await send("presence", args: report.arguments)
    }

    /// `hold_awake`: the person's keep-awake lease, the one hold every
    /// surface shares (it replaces any earlier lease).
    @discardableResult
    public func holdAwake(_ request: CoreAwakeRequest) async throws -> CoreReply {
        try await send("hold_awake", args: request.arguments)
    }

    /// `release_awake`: ends the person's lease; the agents' own hold
    /// keeps its switch.
    @discardableResult
    public func releaseAwake() async throws -> CoreReply {
        try await send("release_awake")
    }
}
