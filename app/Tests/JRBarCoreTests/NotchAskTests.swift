import Foundation
import Testing
@testable import JRBarCore

/// Asks you can act on at the notch: the latched ask capsule, its
/// request pin, the verbs a surface may offer, the refusal line, the
/// takeover jump, the feedback overlay and the queue's stale-news rule.
/// Pure — no notch, no daemon.
@Suite("Notch asks")
struct NotchAskTests {
    private let t0 = Date(timeIntervalSince1970: 1_000)

    private func notice(_ kind: AlcoveNoticeKind, key: String, id: String,
                        session: String? = nil, request: String? = nil) -> AlcoveNotice {
        AlcoveNotice(id: id, kind: kind, title: "Claude · t-\(id)", subtitle: kind.verb,
                     session: session, key: key,
                     ask: kind == .ask ? CoreAsk(session: session, summary: "Run: make test",
                                                 request: request) : nil)
    }

    // MARK: Kinds

    @Test("an ask is latched; news keeps its beat; key feedback overlays")
    func kindLives() {
        #expect(AlcoveNoticeKind.ask.life == nil)
        #expect(AlcoveNoticeKind.completed.life == AlcoveCapsuleQueue.life)
        #expect(AlcoveNoticeKind.focus.life == AlcoveCapsuleQueue.life)
        #expect(AlcoveNoticeKind.timer.life == AlcoveCapsuleQueue.timerLife)
        #expect(AlcoveNoticeKind.level.life == AlcoveCapsuleQueue.feedbackLife)
        #expect(AlcoveNoticeKind.level.isFeedback)
        #expect(AlcoveNoticeKind.capsLock.isFeedback)
        #expect(!AlcoveNoticeKind.device.isFeedback)
        #expect(!AlcoveNoticeKind.ask.isFeedback)
    }

    @Test("every kind has a glyph and a rank; a notice's own glyph wins")
    func kindGlyphs() {
        for kind in AlcoveNoticeKind.allCases {
            #expect(!kind.symbol.isEmpty)
            #expect(!kind.verb.isEmpty)
            #expect(AlcoveCapsuleKinds().isOn(kind))
        }
        #expect(AlcoveNoticeKind.timer.queueRank < AlcoveNoticeKind.completed.queueRank)
        #expect(AlcoveNoticeKind.failed.queueRank < AlcoveNoticeKind.timer.queueRank)
        var focus = notice(.focus, key: "focus", id: "f")
        #expect(focus.symbol == AlcoveNoticeKind.focus.symbol)
        focus.glyph = "briefcase.fill"
        #expect(focus.symbol == "briefcase.fill")
    }

    // MARK: Shaping

    @Test("an ask notice carries its request pin, and the pin joins the key")
    func askPin() {
        let session = CoreSession(id: "claude:s1", provider: "claude", label: "rename-the-fish",
                                  ask: CoreAsk(kind: "permission", summary: "Edit main.swift",
                                               answerable: true))
        let event = CoreEvent(id: "e1", kind: "ask_opened", session: "claude:s1",
                              request: "request:v1:abc")
        let ask = AlcoveEventPolicy.notice(for: event, session: session, kinds: AlcoveCapsuleKinds())
        #expect(ask?.ask?.request == "request:v1:abc")
        #expect(ask?.ask?.session == "claude:s1")
        #expect(ask?.ask?.summary == "Edit main.swift")
        #expect(ask?.key == "ask:claude:s1|request:v1:abc")
        // A new episode for the same session is a new key — answered
        // asks never silence the next one through the cooldown.
        var q = AlcoveCapsuleQueue()
        let first = q.offer(ask!, at: t0)
        #expect(first == .now)
        let closed = q.resolveAsk(session: "claude:s1", request: "request:v1:abc")
        #expect(closed)
        _ = q.finish(at: t0.addingTimeInterval(5))
        let next = AlcoveEventPolicy.notice(
            for: CoreEvent(id: "e2", kind: "ask_opened", session: "claude:s1", request: "request:v1:def"),
            session: session, kinds: AlcoveCapsuleKinds())!
        let second = q.offer(next, at: t0.addingTimeInterval(6))
        #expect(second == .now)
    }

    @Test("an ask the state has not caught up with still shapes from the event")
    func askFromEventOnly() {
        let event = CoreEvent(id: "e1", kind: "ask_opened", session: "codex:s2", provider: "codex",
                              detail: "Approve network access", request: "r1")
        let ask = AlcoveEventPolicy.notice(for: event, session: nil, kinds: AlcoveCapsuleKinds())
        #expect(ask?.ask?.summary == "Approve network access")
        #expect(ask?.ask?.request == "r1")
        #expect(ask?.ask?.answerable == nil, "the snapshot never claims answerability")
    }

    // MARK: Verbs

    @Test("Approve and Deny exist only where the daemon can deliver")
    func verbs() {
        let ok = CoreAsk(session: "claude:s1", answerable: true)
        #expect(NotchAskVerbs.resolve(live: ok, session: "claude:s1") == .answer)
        #expect(NotchAskVerbs.resolve(live: ok, session: "claude:s1").answers)
        #expect(NotchAskVerbs.resolve(live: ok, session: "claude:s1").opens)

        let ghostty = CoreAsk(session: "claude:s1", answerable: false)
        let refused = NotchAskVerbs.resolve(live: ghostty, session: "claude:s1")
        #expect(!refused.answers)
        #expect(refused.opens)
        #expect(refused.note == "Answer it in its window")

        let text = CoreAsk(session: "claude:s1", answerable: true, replyable: true)
        #expect(!NotchAskVerbs.resolve(live: text, session: "claude:s1").answers)

        let unseen = NotchAskVerbs.resolve(live: nil, session: "claude:s1")
        #expect(unseen == .openOnly(reason: nil))
        #expect(unseen.note == nil)

        let remote = NotchAskVerbs.resolve(live: ok, session: "remote:studio:claude:s1")
        #expect(remote == .remote(machine: "studio"))
        #expect(!remote.answers && !remote.opens)
        #expect(remote.note == "Runs on studio — answer it there")

        #expect(NotchAskVerbs.resolve(live: ok, session: nil) == .none)
        #expect(NotchAskVerbs.resolve(live: ok, session: "") == .none)
    }

    @Test("a refusal is one short line naming why")
    func refusalLines() {
        #expect(NotchAskRefusal.line(for: CoreReplyError(code: "stale_request"))
                == "That request changed — nothing was sent")
        #expect(NotchAskRefusal.line(for: CoreReplyError(code: "accessibility_required"))
                == "Needs Accessibility for JR-Bar's helper")
        #expect(NotchAskRefusal.line(for: CoreReplyError(code: "unsupported", message: "no route"))
                == "Couldn't answer: no route")
        #expect(NotchAskRefusal.line(for: nil) == "Couldn't answer: refused")
    }

    // MARK: Latch

    @Test("a latched ask holds while live, waits out its grace, and lets go on a new episode")
    func askStillOpen() {
        let ask = notice(.ask, key: "ask:s1", id: "a", session: "claude:s1", request: "r1")
        let live = CoreAsk(session: "claude:s1", request: "r1")
        #expect(NotchIsland.askStillOpen(ask, live: live, seenLive: true, age: 999))
        // Not in the state yet: the event beat the document.
        #expect(NotchIsland.askStillOpen(ask, live: nil, seenLive: false, age: 1))
        #expect(!NotchIsland.askStillOpen(ask, live: nil, seenLive: false,
                                          age: NotchIsland.askGrace + 1))
        // Seen, then gone: resolved.
        #expect(!NotchIsland.askStillOpen(ask, live: nil, seenLive: true, age: 1))
        // The session moved to a different request: this capsule's
        // episode is over.
        #expect(!NotchIsland.askStillOpen(ask, live: CoreAsk(session: "claude:s1", request: "r2"),
                                          seenLive: true, age: 1))
        // Either side unpinned: the live ask is enough.
        #expect(NotchIsland.askStillOpen(ask, live: CoreAsk(session: "claude:s1"),
                                         seenLive: true, age: 1))
        #expect(!NotchIsland.askStillOpen(notice(.failed, key: "f", id: "f"), live: live,
                                          seenLive: true, age: 0))
    }

    @Test("the live ask prefers the pinned one and fills in the session")
    func liveAsk() {
        let embedded = CoreAsk(summary: "embedded")
        let pinned = CoreAsk(session: "claude:s1", summary: "pinned", answerable: true)
        let session = CoreSession(id: "claude:s1", provider: "claude", ask: embedded)
        #expect(NotchIsland.liveAsk(for: session, asks: [pinned])?.summary == "pinned")
        let fallback = NotchIsland.liveAsk(for: session, asks: [])
        #expect(fallback?.summary == "embedded")
        #expect(fallback?.session == "claude:s1")
        let state = CoreState(sessions: [session], asks: [CoreAsk(session: "gone:s9", summary: "orphan")])
        #expect(NotchIsland.liveAsk(session: "gone:s9", state: state)?.summary == "orphan")
        #expect(NotchIsland.liveAsk(session: "claude:s1", state: state)?.summary == "embedded")
        #expect(NotchIsland.liveAsk(session: "nobody", state: state) == nil)
        #expect(NotchIsland.liveAsk(session: "claude:s1", state: nil) == nil)
    }

    @Test("waiting rows carry their ask and the oldest waiter is named")
    func summaryAsks() {
        let older = CoreSession(id: "claude:old", provider: "claude", label: "old",
                                since: 50, ask: CoreAsk(openedAt: 100, summary: "a"))
        let newer = CoreSession(id: "codex:new", provider: "codex", label: "new",
                                since: 10, ask: CoreAsk(openedAt: 200, summary: "b"))
        let working = CoreSession(id: "claude:w", provider: "claude", label: "w", mode: "working")
        let summary = NotchIsland.summarize([newer, working, older],
                                            asks: [CoreAsk(session: "codex:new", summary: "pinned b",
                                                           answerable: false)])
        #expect(summary.oldestWaiting == "claude:old")
        let rows = Dictionary(uniqueKeysWithValues: summary.rows.map { ($0.id, $0) })
        #expect(rows["codex:new"]?.ask?.summary == "pinned b")
        #expect(rows["claude:old"]?.ask?.session == "claude:old")
        #expect(rows["claude:w"]?.ask == nil)
        #expect(NotchIsland.summarize([working]).oldestWaiting == nil)
    }

    // MARK: Queue

    @Test("resolving an ask drops it from the waiting slot and names the shown one")
    func resolve() {
        var q = AlcoveCapsuleQueue()
        q.offer(notice(.ask, key: "ask:a", id: "a", session: "s-a", request: "ra"), at: t0)
        q.offer(notice(.ask, key: "ask:b", id: "b", session: "s-b", request: "rb"), at: t0)
        #expect(q.pending?.id == "b")
        let waiting = q.resolveAsk(session: "s-b", request: "rb")
        #expect(!waiting, "the waiting one is not shown")
        #expect(q.pending == nil)
        let other = q.resolveAsk(session: "s-a", request: "other")
        #expect(!other, "another episode is not this ask")
        let unpinned = q.resolveAsk(session: "s-a", request: nil)
        #expect(unpinned)
        let pinned = q.resolveAsk(session: "s-a", request: "ra")
        #expect(pinned)
    }

    @Test("news left waiting behind a latched ask goes stale; a waiting ask never does")
    func staleNews() {
        var q = AlcoveCapsuleQueue()
        q.offer(notice(.ask, key: "ask:a", id: "a", session: "s-a"), at: t0)
        q.offer(notice(.completed, key: "done:b", id: "b"), at: t0)
        let late = t0.addingTimeInterval(AlcoveCapsuleQueue.pendingStaleAfter + 1)
        let stale = q.finish(at: late)
        #expect(stale == .idle)
        #expect(q.current == nil)

        var asks = AlcoveCapsuleQueue()
        asks.offer(notice(.ask, key: "ask:a", id: "a", session: "s-a"), at: t0)
        asks.offer(notice(.ask, key: "ask:b", id: "b", session: "s-b"), at: t0)
        let promoted = asks.finish(at: late)
        #expect(promoted == .now(asks.current!))
        #expect(asks.current?.id == "b")

        // Fresh news still promotes on its turn.
        var fresh = AlcoveCapsuleQueue()
        fresh.offer(notice(.ask, key: "ask:a", id: "a", session: "s-a"), at: t0)
        fresh.offer(notice(.completed, key: "done:b", id: "b"), at: t0.addingTimeInterval(1))
        if case .idle = fresh.finish(at: t0.addingTimeInterval(5)) {
            Issue.record("fresh news must still show")
        }
    }

    @Test("key feedback overlays idle and news, never a latched ask")
    func overlay() {
        var q = AlcoveCapsuleQueue()
        let level = AlcoveNotice(id: "l", kind: .level, title: "Volume", subtitle: "",
                                 key: "level", fraction: 0.4)
        #expect(q.acceptsOverlay)
        let shown = q.present(level)
        #expect(shown)
        #expect(q.overlay?.fraction == 0.4)
        var louder = level
        louder.fraction = 0.5
        let updated = q.present(louder)
        #expect(updated, "a held key updates in place")
        #expect(q.overlay?.fraction == 0.5)
        #expect(q.current == nil, "feedback never enters the line")
        #expect(q.recent.isEmpty, "feedback spends no cooldown")
        q.endOverlay()
        #expect(q.overlay == nil)

        let device = q.present(notice(.device, key: "dev", id: "d"))
        #expect(!device, "news is not feedback")

        q.offer(notice(.completed, key: "done", id: "c"), at: t0)
        let overNews = q.present(level)
        #expect(overNews, "news is transient — feedback may cover it")
        q.clear()
        #expect(q.overlay == nil)

        q.offer(notice(.ask, key: "ask", id: "a", session: "s"), at: t0.addingTimeInterval(100))
        #expect(!q.acceptsOverlay)
        let overAsk = q.present(level)
        #expect(!overAsk, "the ask's buttons keep the island")
    }

    @Test("a takeover grows the shown ask in place")
    func takeoverInPlace() {
        var q = AlcoveCapsuleQueue()
        let ask = notice(.ask, key: "ask:a", id: "a", session: "s-a")
        q.offer(ask, at: t0)
        q.takeOver(notice(.ask, key: "ask:a2", id: "a2", session: "s-a"), at: t0.addingTimeInterval(1))
        #expect(q.current?.id == "a", "the same capsule, not a new one")
        #expect(q.current?.takeover == true)
        q.releaseTakeover()
        #expect(q.current?.takeover == false)
        #expect(q.current?.id == "a")
    }

    @Test("a takeover jumps the line: news steps aside, another ask waits behind it")
    func takeoverPreempts() {
        var q = AlcoveCapsuleQueue()
        q.offer(notice(.completed, key: "done", id: "c"), at: t0)
        let level = AlcoveNotice(id: "l", kind: .level, title: "Volume", subtitle: "", key: "level")
        q.present(level)
        q.takeOver(notice(.ask, key: "ask:x", id: "x", session: "s-x"), at: t0.addingTimeInterval(0.1))
        #expect(q.current?.id == "x")
        #expect(q.current?.takeover == true)
        #expect(q.pending == nil, "ambient news is dropped")
        #expect(q.overlay == nil, "feedback yields to the takeover")

        var asks = AlcoveCapsuleQueue()
        asks.offer(notice(.ask, key: "ask:a", id: "a", session: "s-a"), at: t0)
        asks.takeOver(notice(.ask, key: "ask:b", id: "b", session: "s-b"), at: t0.addingTimeInterval(0.1))
        #expect(asks.current?.id == "b")
        #expect(asks.pending?.id == "a", "the ask that was up keeps its place")
    }

    // MARK: Layout

    @Test("the ask face grows with its summary and the takeover is the card's width")
    func askSize() {
        let compact = NotchIslandLayout.askSize(slotWidth: 200, notchDepth: 32, summaryLines: 1,
                                                takeover: false)
        #expect(compact.width == 300)
        let tall = NotchIslandLayout.askSize(slotWidth: 200, notchDepth: 32, summaryLines: 3,
                                             takeover: true)
        #expect(tall.width == NotchIslandLayout.expandedWidth(slotWidth: 200))
        #expect(tall.height - compact.height == 2 * NotchIslandLayout.askSummaryLine)
        // Under a housing the content box stands clear of the climb.
        let housed = NotchIslandLayout.askSize(slotWidth: 200, notchDepth: 32, summaryLines: 1,
                                               takeover: false, underHousing: 8)
        let climb = NotchIslandLayout.housingClimb(size: housed, notchDepth: 32, restingRadius: 8)
        #expect(housed.height - climb >= compact.height)
        // Notch-less: no notch depth over the copy.
        let floating = NotchIslandLayout.askSize(slotWidth: 0, notchDepth: 0, summaryLines: 1,
                                                 takeover: false)
        #expect(floating.height < compact.height)
    }

    @Test("the summary's line count is estimated and capped")
    func summaryLines() {
        #expect(NotchIslandLayout.askSummaryLines("", width: 340, maxLines: 3) == 1)
        #expect(NotchIslandLayout.askSummaryLines("short", width: 340, maxLines: 3) == 1)
        let long = String(repeating: "word ", count: 60)
        #expect(NotchIslandLayout.askSummaryLines(long, width: 340, maxLines: 3) == 3)
        #expect(NotchIslandLayout.askSummaryLines(long, width: 340, maxLines: 1) == 1)
    }
}
