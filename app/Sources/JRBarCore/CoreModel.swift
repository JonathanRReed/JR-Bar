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
    }

    public func retryNow() { client?.retryNow() }

    // MARK: Commands

    @discardableResult
    public func send(_ name: String, args: [String: JSONValue] = [:]) async throws -> CoreReply {
        guard let client else { throw CoreClientError.notConnected }
        inFlightCommands += 1
        defer { inFlightCommands -= 1 }
        return try await client.send(name: name, args: args)
    }

    /// Sends and forgets; failures land in `lastDecodeFailure` for the log view.
    public func post(_ name: String, args: [String: JSONValue] = [:]) {
        Task { [weak self] in
            do { _ = try await self?.send(name, args: args) }
            catch { await MainActor.run { self?.lastDecodeFailure = "\(name): \(error)" } }
        }
    }

    public func openSession(_ id: String) { post("open_session", args: ["session": .string(id)]) }

    public func answerAsk(session: String, approve: Bool, onlyIfFrontmost: Bool = false) {
        post("answer_ask", args: [
            "session": .string(session),
            "decision": .string(approve ? "approve" : "deny"),
            "only_if_frontmost": .bool(onlyIfFrontmost),
        ])
    }

    /// Acknowledges completions; the reply's `batch` is kept so `undoClear`
    /// can put them back within `EventPolicy.undoWindow`.
    public func clearCompleted(sessions: [String]? = nil) {
        let scope: JSONValue = sessions.map { .array($0.map(JSONValue.string)) } ?? .string("all")
        Task { [weak self] in
            guard let self else { return }
            do {
                let reply = try await self.send("clear_completed", args: ["sessions": scope])
                if reply.ok, let batch = reply.result?["batch"]?.stringValue {
                    self.lastClear = (batch, Date())
                }
            } catch {
                self.lastDecodeFailure = "clear_completed: \(error)"
            }
        }
    }

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

    /// Shows `program` on `surface` for `seconds`, then the daemon reverts.
    public func previewProgram(surface: String, program: String, seconds: Double) {
        post("preview_program", args: ["surface": .string(surface), "program": .string(program), "seconds": .number(seconds)])
    }

    public func applyCalibration(device: String, profile: [String: JSONValue]) {
        post("apply_calibration", args: ["device": .string(device), "profile": .object(profile)])
    }

    public func doctor() async throws -> CoreReply { try await send("doctor") }

    /// Puts every listed path back to the daemon's default.
    @discardableResult
    public func resetSettings(paths: [String]) async throws -> CoreReply {
        try await send("reset_settings", args: ["paths": .array(paths.map(JSONValue.string))])
    }

    /// Sends and decodes; a `not ok` reply becomes its `CoreReplyError`.
    public func request<T: Decodable>(_ name: String, args: [String: JSONValue] = [:], as type: T.Type) async throws -> T {
        let reply = try await send(name, args: args)
        guard reply.ok else { throw reply.error ?? CoreReplyError(code: "error", message: "\(name) failed") }
        return try ReplyDecoding.decode(type, from: reply.result)
    }

    // MARK: Usage Center (app-proposed extensions, see app/README.md)

    /// `usage_history {provider, range}` → daily and hourly token/cost rows.
    public func usageHistory(provider: String, range: UsageHistoryRange) async throws -> UsageHistory {
        try await request("usage_history", args: ["provider": .string(provider), "range": .string(range.rawValue)], as: UsageHistory.self)
    }

    /// `refresh_usage {providers[]}`; an empty list means every provider.
    @discardableResult
    public func refreshUsage(providers: [String] = []) async throws -> CoreReply {
        try await send("refresh_usage", args: ["providers": .array(providers.map(JSONValue.string))])
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

    @discardableResult
    public func setAssignment(_ assignment: EffectAssignment) async throws -> EffectAssignmentDocument {
        var args: [String: JSONValue] = [
            "effect_id": .string(assignment.effectID),
            "scope": .string(assignment.scope.rawValue),
            "parameters": .object(assignment.parameters),
        ]
        if let target = assignment.targetID { args["target_id"] = .string(target) }
        return try await request("set_assignment", args: args, as: EffectAssignmentDocument.self)
    }

    @discardableResult
    public func clearAssignment(scope: EffectScope, targetID: String?) async throws -> EffectAssignmentDocument {
        var args: [String: JSONValue] = ["scope": .string(scope.rawValue)]
        if let targetID { args["target_id"] = .string(targetID) }
        return try await request("clear_assignment", args: args, as: EffectAssignmentDocument.self)
    }

    /// `import_effect_pack {path}`: the daemon reads and validates the JSON
    /// itself (the app never parses a pack) and replies with the new catalog.
    public func importEffectPack(path: String) async throws -> EffectCatalog {
        try await request("import_effect_pack", args: ["path": .string(path)], as: EffectCatalog.self)
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
