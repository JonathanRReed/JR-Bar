import Foundation
import Testing
@testable import JRBarCore

@Suite("Failure signals")
struct FailureSignalTests {
    @Test("A top-level failure expires after five seconds and keeps its panel mark")
    func topLevel() {
        let row = CoreSession(id: "codex:session:root", provider: "codex", cwd: "/repo/synthetic",
                              mode: "blocked_error", lifecycle: "failed", updatedAt: 100, failureSignalUntil: 105)
        for now in [100.0, 104.999, 105, 200] {
            #expect(row.signalsFailure(at: now) == (now < 105))
            #expect(SessionActivity.reduce(row) == .failed)
            #expect(NotchIsland.summarize([row], now: now).failed == (now < 105 ? 1 : 0))
        }
        let event = CoreEvent(id: "failure-1", kind: "failed", session: row.id, at: 100, notify: true, provider: "codex")
        let notice = AlcoveEventPolicy.notice(for: event, session: row, kinds: .init(), now: 100)
        #expect(notice?.title == "Codex · synthetic")
        #expect(notice?.subtitle == "failed")
        var anotherFailure = event
        anotherFailure.id = "failure-2"
        let anotherNotice = AlcoveEventPolicy.notice(for: anotherFailure, session: row, kinds: .init(), now: 100)
        #expect(anotherNotice?.key != notice?.key)
        #expect(notice?.kind.life == 5)
        #expect(notice?.remainingLife(at: 104) == 1)
        #expect(notice?.remainingLife(at: 105) == 0)
        let state = CoreState(sessions: [row])
        #expect(EventPolicy.delivery(for: event, state: state, settings: nil, now: 104.999).notification?.title == "Codex · synthetic failed")
        #expect(EventPolicy.delivery(for: event, state: state, settings: nil, now: 105) == .nothing)
        #expect(AlcoveEventPolicy.notice(for: event, session: row, kinds: .init(), now: 105) == nil)
    }

    @Test("Linked and unlinked workers keep only the failed panel mark")
    func workers() {
        for linked in [false, true] {
            let row = CoreSession(id: "codex:agent:worker", provider: "codex", kind: "worker",
                                  parent: linked ? "codex:session:root" : nil, mode: "blocked_error",
                                  lifecycle: "failed", updatedAt: 100, unlinkedWorker: !linked, failureSignalUntil: 105)
            #expect(!row.signalsFailure(at: 100))
            #expect(NotchIsland.summarize([row], now: 100).failed == 0)
            #expect(SessionActivity.reduce(row) == .failed)
            let event = CoreEvent(id: "failure-1", kind: "failed", session: row.id, at: 100, notify: true)
            #expect(AlcoveEventPolicy.notice(for: event, session: row, kinds: .init(), now: 100) == nil)
            let state = CoreState(generation: 1, now: 100, sessions: [row])
            #expect(EventPolicy.delivery(for: event, state: state, settings: nil) == .nothing)
        }
    }
    @Test("Failure notices interrupt ordinary news, yield to asks, and expire while queued")
    func queue() {
        let at = Date(timeIntervalSince1970: 100)
        let news = AlcoveNotice(id: "news", kind: .completed, title: "Codex", subtitle: "finished", key: "news")
        let failure = AlcoveNotice(id: "failure", kind: .failed, title: "Codex · synthetic", subtitle: "failed", key: "failure", expiresAt: 105)
        let ask = AlcoveNotice(id: "ask", kind: .ask, title: "Claude", subtitle: "needs you", key: "ask")
        var queue = AlcoveCapsuleQueue()
        #expect(queue.offer(news, at: at) == .now)
        #expect(queue.offer(failure, at: at) == .now)
        #expect(queue.current?.id == "failure")
        #expect(queue.offer(ask, at: at) == .now)
        #expect(queue.current?.id == "ask")
        var waiting = AlcoveCapsuleQueue()
        #expect(waiting.offer(ask, at: at) == .now)
        #expect(waiting.offer(failure, at: at) == .queued)
        #expect(waiting.finish(at: Date(timeIntervalSince1970: 105)) == .idle)
    }

}
