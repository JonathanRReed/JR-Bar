import Foundation
import Observation

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

    public let socketPath: String
    public private(set) var connection: Connection = .idle
    public private(set) var hello: CoreHello?
    public private(set) var state: CoreState?
    public private(set) var lights: CoreLights?
    public private(set) var settings: CoreSettings?
    /// The most recent transient event; consumers compare ids.
    public private(set) var lastEvent: CoreEvent?
    public private(set) var lastLog: CoreLog?
    /// The daemon's recent `log` messages, oldest first, bounded.
    public private(set) var logTail: [CoreLog] = []
    public static let logTailLimit = 200
    public private(set) var lastDecodeFailure: String?
    public private(set) var unknownMessageCount = 0
    public private(set) var connectedAt: Date?
    /// Wall-clock arrival of the most recent `state` frame. The daemon
    /// builds a state document every 15 s refresh but broadcasts only when
    /// the projection changed (`doc_significant_equal` ignores the doc's
    /// own `now`/`generation`), so a quiet daemon legitimately sends
    /// nothing — this stamps the frame's age, not the daemon's heartbeat.
    public private(set) var lastStateAt: Date?
    /// Commands the app sent that the daemon has not answered yet.
    public private(set) var inFlightCommands = 0
    /// Every `state`'s usage windows, kept so the Usage Center can
    /// extrapolate a pace when the daemon sends no `forecast`.
    public private(set) var usageSamples = UsageSampleLog()

    /// Called for every event before the model applies it.
    public var onEvent: (@MainActor (CoreEvent) -> Void)?

    @ObservationIgnored private var client: CoreClient?
    @ObservationIgnored private var seenEventIDs: [String] = []

    public init(socketPath: String = CoreSocketPath.resolve()) {
        self.socketPath = socketPath
    }

    /// Facts and lights are only trusted once the daemon has said hello and
    /// sent a state; until then the file feeds keep running.
    public var isLive: Bool { connection.isConnected && state != nil }

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
        let client = CoreClient(socketPath: socketPath) { [weak self] event in
            Task { @MainActor [weak self] in self?.handle(event) }
        }
        self.client = client
        client.start()
    }

    public func stop() {
        client?.stop()
        client = nil
        connection = .idle
        connectedAt = nil
        lastStateAt = nil
    }

    public func retryNow() { client?.retryNow() }

    // MARK: Commands

    @discardableResult
    public func send(_ name: String, args: [String: JSONValue] = [:], timeout: TimeInterval? = nil) async throws -> CoreReply {
        guard let client else { throw CoreClientError.notConnected }
        inFlightCommands += 1
        defer { inFlightCommands -= 1 }
        return try await client.send(name: name, args: args, timeout: timeout)
    }

    /// Sends and forgets; failures land in `lastDecodeFailure` for the log view.
    public func post(_ name: String, args: [String: JSONValue] = [:]) {
        Task { [weak self] in
            do { _ = try await self?.send(name, args: args) }
            catch { await MainActor.run { self?.lastDecodeFailure = "\(name): \(error)" } }
        }
    }

    public func openSession(_ id: String) { post("open_session", args: ["session": .string(id)]) }

    public func answerAsk(session: String, approve: Bool, onlyIfFrontmost: Bool = false,
                          request: String? = nil) {
        var args: [String: JSONValue] = [
            "session": .string(session),
            "decision": .string(approve ? "approve" : "deny"),
            "only_if_frontmost": .bool(onlyIfFrontmost),
        ]
        if let request { args["request"] = .string(request) }
        post("answer_ask", args: args)
    }

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
        var args: [String: JSONValue] = [
            "session": .string(session),
            "decision": .string(approve ? "approve" : "deny"),
            "only_if_frontmost": .bool(onlyIfFrontmost),
        ]
        if let replyText { args["reply_text"] = .string(replyText) }
        if let request { args["request"] = .string(request) }
        return try await send("answer_ask", args: args, timeout: 8)
    }

    /// Acknowledges completions; the reply's `batch` is kept so `undoClear`
    /// can put them back within `EventPolicy.undoWindow`.
    public func clearCompleted(sessions: [String]? = nil) {
        Task { [weak self] in
            guard let self else { return }
            do { _ = try await self.clearCompletedNow(sessions: sessions) }
            catch { self.lastDecodeFailure = "clear_completed: \(error)" }
        }
    }

    /// `clear_completed` and its reply: `ok` with `{batch, cleared[]}`, the
    /// batch remembered for `undoClear`. Throws when the socket is down.
    @discardableResult
    public func clearCompletedNow(sessions: [String]? = nil) async throws -> CoreReply {
        let scope: JSONValue = sessions.map { .array($0.map(JSONValue.string)) } ?? .string("all")
        let reply = try await send("clear_completed", args: ["sessions": scope])
        if reply.ok, let batch = reply.result?["batch"]?.stringValue {
            lastClear = (batch, Date())
        }
        return reply
    }

    /// The daemon's count of sessions it keeps out of `state.sessions`
    /// (acknowledged, older); `list_history` still has them.
    public var hiddenSessionCount: Int { state?.hiddenCount ?? 0 }

    /// The last `clear_completed` batch and when it happened.
    public private(set) var lastClear: (batch: String, at: Date)?

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
        let reply = try await send("undo_clear", args: ["batch": .string(lastClear.batch)])
        if reply.ok { self.lastClear = nil }
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
        return try ReplyDecoding.decode(CoreRoster.self, from: result)
    }

    /// `audit_export`: the redacted audit bundle — projected roster rows,
    /// activity rows, the named gaps, and pricing coverage. `format` is
    /// `"json"` or `"markdown"`; the markdown reply also carries `text`.
    /// The document is returned for preview; the app writes the bytes the
    /// user previews to the destination they pick.
    public func exportAudit(scope: String = "all", since: Double? = nil,
                            format: String = "json") async throws -> (document: JSONValue, text: String?) {
        var args: [String: JSONValue] = ["scope": .string(scope), "format": .string(format)]
        if let since { args["since"] = .number(since) }
        let reply = try await send("audit_export", args: args)
        guard reply.ok else { throw reply.error ?? CoreReplyError(code: "error", message: "audit_export failed") }
        guard let result = reply.result else {
            throw CoreReplyError(code: "bad_reply", message: "audit_export: missing result")
        }
        return (result["document"] ?? .object([:]), result["text"]?.stringValue)
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
        return try ReplyDecoding.decode(CoreTimelinePage.self, from: result)
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
    /// The scan is heavy on a cold cache (~30s), so the timeout runs
    /// long and the view shows its scanning state meanwhile.
    public func usageGraph(days: Int? = nil, metric: String? = nil,
                           providers: [String]? = nil) async throws -> CoreUsageGraphDocument {
        var args: [String: JSONValue] = [:]
        if let days { args["days"] = .number(Double(days)) }
        if let metric { args["metric"] = .string(metric) }
        if let providers { args["providers"] = .array(providers.map(JSONValue.string)) }
        // Commands dispatch serially per socket: a pick made mid-scan
        // queues behind the in-flight cold scan (~60s measured) before
        // running its own — warm, ~2s — so the budget covers one cold
        // wait plus its own scan, with margin for a concurrent client.
        let reply = try await send("usage_graph", args: args, timeout: 150)
        guard reply.ok else { throw reply.error ?? CoreReplyError(code: "error", message: "usage_graph failed") }
        guard let result = reply.result else {
            throw CoreReplyError(code: "bad_reply", message: "usage_graph: missing result")
        }
        return try ReplyDecoding.decode(CoreUsageGraphDocument.self, from: result)
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

    /// `list_radar_reports`: summaries of the bounded static-topology
    /// reports imported so far (S7.5).
    public func listRadarReports() async throws -> [CoreRadarSummary] {
        let reply = try await send("list_radar_reports")
        guard reply.ok else { throw reply.error ?? CoreReplyError(code: "error", message: "list_radar_reports failed") }
        let rows = reply.result?["reports"]?.arrayValue ?? []
        let decoder = JSONDecoder()
        return rows.compactMap { value -> CoreRadarSummary? in
            guard let data = try? JSONEncoder().encode(value) else { return nil }
            return try? decoder.decode(CoreRadarSummary.self, from: data)
        }
    }

    /// `radar_report`: one stored report's normalized graph.
    public func radarReport(id: String) async throws -> CoreRadarReport {
        let reply = try await send("radar_report", args: ["id": .string(id)])
        guard reply.ok else { throw reply.error ?? CoreReplyError(code: "error", message: "radar_report failed") }
        guard let result = reply.result?["report"] else {
            throw CoreReplyError(code: "bad_reply", message: "radar_report: missing report")
        }
        return try ReplyDecoding.decode(CoreRadarReport.self, from: result)
    }

    /// `import_radar_report`: bounded, data-only import — the file is
    /// parsed and stored, never executed (S7.5).
    public func importRadarReport(path: String) async throws -> CoreRadarSummary {
        let reply = try await send("import_radar_report", args: ["path": .string(path)])
        guard reply.ok else { throw reply.error ?? CoreReplyError(code: "error", message: "import_radar_report failed") }
        guard let result = reply.result?["imported"] else {
            throw CoreReplyError(code: "bad_reply", message: "import_radar_report: missing summary")
        }
        return try ReplyDecoding.decode(CoreRadarSummary.self, from: result)
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

    public func quiet(mode: String = "dnd", seconds: Int) {
        post("quiet", args: ["mode": .string(mode), "seconds": .number(Double(seconds))])
    }

    public func snooze(session: String? = nil, seconds: Int) {
        post("snooze", args: ["session": .string(session ?? "all"), "seconds": .number(Double(seconds))])
    }

    /// A validated settings write; the daemon echoes a new `settings`
    /// document and replies with its generation.
    @discardableResult
    public func setSetting(_ path: SettingsPath, value: JSONValue) async throws -> CoreReply {
        try await send("set_setting", args: ["path": .string(path.description), "value": value])
    }

    public func installHooks(providers: [String]) { post("install_hooks", args: ["providers": .array(providers.map(JSONValue.string))]) }

    public func uninstallHooks(providers: [String]) { post("uninstall_hooks", args: ["providers": .array(providers.map(JSONValue.string))]) }

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

    /// How long a `usage_history` request may take: a cold transcript scan
    /// runs tens of seconds on the daemon's socket thread.
    public static let usageHistoryTimeout: TimeInterval = 30

    /// `usage_history {provider, range}` → daily and hourly token/cost rows.
    /// Waits `usageHistoryTimeout` rather than the default 10 s.
    public func usageHistory(provider: String, range: UsageHistoryRange) async throws -> UsageHistory {
        try await request("usage_history", args: ["provider": .string(provider), "range": .string(range.rawValue)],
                          as: UsageHistory.self, timeout: Self.usageHistoryTimeout)
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

    /// `provider_action` runs the staged flow behind the provider's
    /// current action label (clipboard import, reconnect, repair). The
    /// reply carries the message the daemon surfaced; `unsupported`
    /// means no staged action matches the live state.
    public func providerAction(_ provider: String, instance: String? = nil) async throws -> String {
        var args: [String: JSONValue] = ["provider": .string(provider)]
        if let instance { args["instance"] = .string(instance) }
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

    public var deck: DeckState? { state?.deck }

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

    private func handle(_ event: CoreClient.Event) {
        switch event {
        case .connecting(let attempt):
            connection = .connecting(attempt: attempt)
        case .connected:
            connection = .connected
            connectedAt = Date()
        case .disconnected(let reason):
            connection = .disconnected(reason: reason)
            connectedAt = nil
        case .decodeFailure(let why):
            lastDecodeFailure = why
        case .message(let message):
            apply(message)
        }
    }

    public func apply(_ message: CoreMessage) {
        switch message {
        case .hello(let hello):
            self.hello = hello
        case .state(let state):
            self.state = state
            lastStateAt = Date()
            usageSamples.record(state.usage, now: state.now ?? Date().timeIntervalSince1970)
        case .lights(let lights):
            self.lights = lights
        case .settings(let settings):
            self.settings = settings
        case .event(let event):
            guard !seenEventIDs.contains(event.id) else { return }
            seenEventIDs.append(event.id)
            if seenEventIDs.count > 64 { seenEventIDs.removeFirst(seenEventIDs.count - 64) }
            onEvent?(event)
            lastEvent = event
        case .reply:
            break
        case .log(let log):
            lastLog = log
            logTail.append(log)
            if logTail.count > Self.logTailLimit { logTail.removeFirst(logTail.count - Self.logTailLimit) }
        case .unknown:
            unknownMessageCount += 1
        }
    }

    // MARK: Derived

    public var sessions: [CoreSession] { state?.mainSessions ?? [] }
    public var asks: [CoreAsk] { state?.asks ?? [] }
    public var devices: [CoreDevice] { state?.devices ?? [] }
    public var usage: [CoreProviderUsage] { state?.usage?.providers ?? [] }

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
