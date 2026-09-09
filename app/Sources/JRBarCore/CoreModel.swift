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
    public private(set) var lastDecodeFailure: String?
    public private(set) var unknownMessageCount = 0
    public private(set) var connectedAt: Date?
    /// Commands the app sent that the daemon has not answered yet.
    public private(set) var inFlightCommands = 0

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

    public func clearCompleted(sessions: [String]? = nil) {
        let scope: JSONValue = sessions.map { .array($0.map(JSONValue.string)) } ?? .string("all")
        post("clear_completed", args: ["sessions": scope])
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
