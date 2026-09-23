import Foundation
import JRBarCore
import Observation

/// The notch's answer path — the ask capsule's, the takeover card's and
/// the card rows' Approve / Deny / Open. `answer_ask` is awaited so a
/// refusal is heard where the click happened: the line lands under the
/// ask itself (the panel's toast has no place at the notch), and the
/// ask stays open. The pin is always the episode the surface showed
/// (`CoreAsk.request`): a session that moved on to a different request
/// refuses `stale_request` rather than approve whatever replaced it.
///
/// Nothing here decides on its own. An answer only ever starts from a
/// click, and only for an ask `NotchAskVerbs` says the daemon can
/// deliver; everything else offers Open.
@MainActor
@Observable
final class NotchAskAnswerer {
    /// How long a refusal line stays under its ask.
    static let noteLife: TimeInterval = 4

    /// Sessions with an answer in flight — their buttons dim and a
    /// second click is ignored rather than sent twice.
    private(set) var pending: Set<String> = []
    /// Session → the line the last refused answer earned.
    private(set) var notes: [String: String] = [:]

    /// The daemon call — `CoreModel.answerAskNow` in production; tests
    /// stage the reply.
    @ObservationIgnored var send: @MainActor (_ session: String, _ approve: Bool,
                                              _ request: String?) async throws -> CoreReply
    /// `open_session` — raising the session's own window.
    @ObservationIgnored var openSession: @MainActor (_ session: String) -> Void
    /// An answer the daemon accepted: the owner steps the capsule down
    /// now instead of waiting for `ask_resolved` to round-trip.
    @ObservationIgnored var onAnswered: @MainActor (_ session: String, _ request: String?) -> Void = { _, _ in }
    /// Each note's own expiry, so an older timer never clears a newer
    /// line for the same session.
    @ObservationIgnored private var noteTokens: [String: UUID] = [:]

    init(core: CoreModel) {
        send = { [weak core] session, approve, request in
            guard let core else { throw CoreClientError.notConnected }
            return try await core.answerAskNow(session: session, approve: approve, request: request)
        }
        openSession = { [weak core] session in core?.openSession(session) }
    }

    func isPending(_ session: String) -> Bool { pending.contains(session) }
    func note(for session: String) -> String? { notes[session] }

    /// Approve or Deny, from a click. Refused before any send when the
    /// verbs say this ask cannot be answered here, or an answer for the
    /// session is already on its way. True when the daemon took it.
    @discardableResult
    func answer(session: String, ask: CoreAsk?, approve: Bool) async -> Bool {
        guard !pending.contains(session),
              NotchAskVerbs.resolve(live: ask, session: session).answers else { return false }
        pending.insert(session)
        defer { pending.remove(session) }
        clearNote(for: session)
        do {
            let reply = try await send(session, approve, ask?.request)
            if reply.ok {
                onAnswered(session, ask?.request)
                return true
            }
            setNote(NotchAskRefusal.line(for: reply.error), for: session)
        } catch {
            setNote(NotchAskRefusal.unreachable, for: session)
        }
        return false
    }

    /// Open the session's own window. A remote row has no window here —
    /// the verbs never offer it, and this refuses it too.
    func open(session: String) {
        guard !CoreSession.isRemoteID(session) else { return }
        openSession(session)
    }

    private func setNote(_ line: String, for session: String) {
        notes[session] = line
        let token = UUID()
        noteTokens[session] = token
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.noteLife) { [weak self] in
            MainActor.assumeIsolated {
                guard let self, self.noteTokens[session] == token else { return }
                self.clearNote(for: session)
            }
        }
    }

    private func clearNote(for session: String) {
        notes[session] = nil
        noteTokens[session] = nil
    }
}
