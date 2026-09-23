import Foundation
import Testing
@testable import JRBarApp
@testable import JRBarCore

/// Opening a session: the daemon first, the Dock's window locator only
/// for a running local session the daemon could not find, and a
/// refusal line whenever nothing came to the front. Every reply is
/// staged; nothing here reaches a daemon or raises a window.
@Suite("Session opener")
@MainActor
struct SessionOpenerTests {
    @MainActor
    final class Log {
        var calls: [String] = []
    }

    private func session(_ id: String, mode: String = "working", lifecycle: String? = nil,
                         remote: Bool = false) -> CoreSession {
        CoreSession(id: id, provider: "claude", label: "Ship the opener", mode: mode, lifecycle: lifecycle,
                    remote: remote)
    }

    private func wiring(_ log: Log, reply: CoreReply? = nil, raises: Bool = true,
                        sessions: [CoreSession] = []) -> SessionOpener.Wiring {
        SessionOpener.Wiring(
            send: { id in
                log.calls.append("open:\(id)")
                guard let reply else { throw CoreClientError.notConnected }
                return reply
            },
            sessions: { sessions },
            raise: { id in
                log.calls.append("raise:\(id)")
                return raises
            })
    }

    private static let notFound = CoreReply(id: "1", ok: false,
                                            error: CoreReplyError(code: "not_found", message: "can't find its window"))

    @Test("an open the daemon takes lands without the locator")
    func daemonOpens() async {
        let log = Log()
        let line = await SessionOpener.open("claude:w", via: wiring(log, reply: CoreReply(id: "1", ok: true),
                                                                     sessions: [session("claude:w")]))
        #expect(line == nil)
        #expect(log.calls == ["open:claude:w"])
    }

    @Test("a running session the daemon cannot find is raised by the locator")
    func locatorRaises() async {
        let log = Log()
        let raised = await SessionOpener.open("claude:w", via: wiring(log, reply: Self.notFound,
                                                                       sessions: [session("claude:w")]))
        #expect(raised == nil)
        #expect(log.calls == ["open:claude:w", "raise:claude:w"])

        let missed = Log()
        let refusal = await SessionOpener.open("claude:w", via: wiring(missed, reply: Self.notFound, raises: false,
                                                                        sessions: [session("claude:w")]))
        #expect(refusal == "can't find its window", "the locator found nothing: the daemon's words stand")
        #expect(missed.calls == ["open:claude:w", "raise:claude:w"])
    }

    @Test("an ended, failed, unknown or other refusal never tries the locator")
    func refusalsStand() async {
        let ended = Log()
        let endedLine = await SessionOpener.open("claude:e", via: wiring(
            ended, reply: Self.notFound, sessions: [session("claude:e", mode: "completed", lifecycle: "completed")]))
        #expect(endedLine == "can't find its window")
        #expect(ended.calls == ["open:claude:e"])

        let unknown = Log()
        let unknownLine = await SessionOpener.open("claude:gone", via: wiring(unknown, reply: Self.notFound))
        #expect(unknownLine == "can't find its window")
        #expect(unknown.calls == ["open:claude:gone"])

        let other = Log()
        let unsupported = CoreReply(id: "1", ok: false, error: CoreReplyError(code: "unsupported"))
        let otherLine = await SessionOpener.open("claude:w", via: wiring(other, reply: unsupported,
                                                                          sessions: [session("claude:w")]))
        #expect(otherLine == "Could not open Ship the opener", "no message: the row's own name")
        #expect(other.calls == ["open:claude:w"])
    }

    @Test("a remote session, a silent daemon or no wiring each refuse out loud")
    func refusedBeforeTheLocator() async {
        let remote = Log()
        let remoteLine = await SessionOpener.open("remote:studio:claude:x", via: wiring(remote, reply: Self.notFound))
        #expect(remoteLine == "Running on studio — open it there")
        #expect(remote.calls.isEmpty, "nothing is sent for a peer's session")

        let silent = Log()
        let silentLine = await SessionOpener.open("claude:w", via: wiring(silent, sessions: [session("claude:w")]))
        #expect(silentLine == SessionOpener.notAnswering)
        #expect(silent.calls == ["open:claude:w"], "a thrown send is not a not_found")

        let unwired = await SessionOpener.open("claude:w", via: nil)
        #expect(unwired == SessionOpener.notAnswering)
    }

    @Test("the locator's gate: a live local session the daemon answered not_found")
    func locatorGate() {
        let live = session("claude:w")
        #expect(SessionOpener.raisesWindowInstead(Self.notFound.error, session: live))
        #expect(!SessionOpener.raisesWindowInstead(CoreReplyError(code: "unsupported"), session: live))
        #expect(!SessionOpener.raisesWindowInstead(nil, session: live))
        #expect(!SessionOpener.raisesWindowInstead(Self.notFound.error, session: nil))
        #expect(!SessionOpener.raisesWindowInstead(Self.notFound.error,
                                                   session: session("claude:e", mode: "completed",
                                                                    lifecycle: "completed")))
        #expect(!SessionOpener.raisesWindowInstead(Self.notFound.error,
                                                   session: session("claude:f", mode: "failed")))
        #expect(!SessionOpener.raisesWindowInstead(Self.notFound.error,
                                                   session: session("remote:studio:claude:x", remote: true)))
    }
}
