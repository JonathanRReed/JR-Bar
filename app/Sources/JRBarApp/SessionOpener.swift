import JRBarCore

/// Opening a session, from wherever JR-Bar shows one: the daemon's
/// `open_session`, awaited so its refusal is heard, and — when the
/// daemon answers `not_found` for a session still running on this Mac —
/// the Dock's window locator (`UtilitiesStore.raiseSessionWindow`),
/// which finds and raises the window it runs in off the main thread.
/// One path, so a click never dead-ends on one surface where another's
/// would have landed.
///
/// nil means the session is in front; a line is the refusal to show.
/// A surface that collapses itself waits for nil before it goes.
@MainActor
enum SessionOpener {
    /// The daemon and the Dock, as opening needs them.
    struct Wiring {
        /// `open_session {session}`, awaited — `CoreModel.send` in
        /// production; tests stage the reply.
        var send: @MainActor (_ session: String) async throws -> CoreReply
        /// The daemon's live sessions: which refused opens are worth the
        /// window locator's try.
        var sessions: @MainActor () -> [CoreSession]
        /// The Dock's window locator — true when the session's own window
        /// is now in front.
        var raise: @MainActor (_ session: String) async -> Bool
    }

    /// Published by the app delegate. nil — no daemon hands yet, or a
    /// test — refuses every open.
    static var wiring: Wiring?

    static let notAnswering = "The monitor is not answering"

    /// Open `id` through the published wiring.
    static func open(_ id: String) async -> String? {
        await open(id, via: wiring)
    }

    static func open(_ id: String, via wiring: Wiring?) async -> String? {
        // A mirrored peer session has no local window to raise.
        if CoreSession.isRemoteID(id) {
            return CoreSession.remoteMachine(inID: id).map { "Running on \($0) — open it there" }
                ?? "A remote session — open it on the machine it runs on"
        }
        guard let wiring else { return notAnswering }
        let reply: CoreReply
        do {
            reply = try await wiring.send(id)
        } catch {
            return notAnswering
        }
        if reply.ok { return nil }
        let session = wiring.sessions().first { $0.id == id }
        // The daemon could not find the window of a session that is
        // still running; the Dock's window locator may.
        if raisesWindowInstead(reply.error, session: session), await wiring.raise(id) { return nil }
        return reply.error?.message ?? "Could not open \(session?.displayLabel ?? "that session")"
    }

    /// Whether a refused open is worth the window locator's try: the
    /// daemon's `not_found` for a local session that is still live. An
    /// ended row has no window left to find — its refusal stands.
    nonisolated static func raisesWindowInstead(_ error: CoreReplyError?, session: CoreSession?) -> Bool {
        guard error?.code == "not_found", let session, !session.isRemote, !session.remote else { return false }
        let activity = SessionActivity.reduce(session)
        return !activity.isClearable && activity != .failed
    }
}

extension SessionOpener.Wiring {
    /// The app's hands: the core's `send` and live state, and the
    /// utilities store's worker-backed raise.
    init(core: CoreModel, utilities: UtilitiesStore) {
        self.init(
            send: { [weak core] id in
                guard let core else { throw CoreClientError.notConnected }
                return try await core.send("open_session", args: ["session": .string(id)])
            },
            sessions: { [weak core] in core?.state?.sessions ?? [] },
            raise: { [weak utilities] id in
                guard let utilities else { return false }
                return await utilities.raiseSessionWindow(id)
            })
    }
}
