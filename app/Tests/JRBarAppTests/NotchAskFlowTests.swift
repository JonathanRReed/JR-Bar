import Foundation
import Testing
import JRBarCore
@testable import JRBarApp

/// The ask at the notch, end to end against the toy: the capsule that
/// holds until the ask is acted on, the answer path with its request
/// pin, the tap that opens, the band click that yields, the takeover,
/// and key feedback that never covers an ask's buttons. The daemon is a
/// staged `send`; `islandVisible` stands in for a notched screen.
@Suite("Notch ask flow")
@MainActor
struct NotchAskFlowTests {
    private static let session = "claude:s1"

    private func makeToy(state: CoreState? = nil) -> (NotchToy, ToysStore, CoreModel) {
        var toys = ToysState()
        toys.notch = NotchSettings(enabled: true, provider: .jrbar, islandEnabled: true)
        let core = CoreModel()
        if let state { core.apply(.state(state)) }
        let store = ToysStore(core: core, settings: SettingsStore(core: core),
                              state: toys, cardModel: makeTestCardModel(),
                              notchRuntimeEnabled: false)
        let toy: NotchToy = store.notch
        toy.islandVisible = true
        return (toy, store, core)
    }

    private func liveState(answerable: Bool = true, request: String = "r1") -> CoreState {
        CoreState(sessions: [CoreSession(id: Self.session, provider: "claude", label: "rename-the-fish",
                                         ask: CoreAsk(summary: "Run tests"))],
                  asks: [CoreAsk(session: Self.session, openedAt: 1, summary: "Run tests",
                                 answerable: answerable, request: request)])
    }

    private func askNotice(id: String = "a", session: String = NotchAskFlowTests.session,
                           request: String? = "r1") -> AlcoveNotice {
        AlcoveNotice(id: id, kind: .ask, title: "Claude · rename-the-fish", subtitle: "Run tests",
                     session: session, key: "ask:\(session)|\(request ?? "")",
                     ask: CoreAsk(session: session, summary: "Run tests", request: request))
    }

    private func news(_ kind: AlcoveNoticeKind, id: String) -> AlcoveNotice {
        AlcoveNotice(id: id, kind: kind, title: "Claude · t-\(id)", subtitle: kind.verb,
                     key: "\(kind.rawValue):\(id)")
    }

    @Test("an ask capsule holds past a capsule's life — nothing times it out")
    func askLatches() async throws {
        let (toy, store, _) = makeToy(state: liveState())
        defer { withExtendedLifetime(store) {} }
        toy.offer(askNotice())
        #expect(toy.activeCapsule?.id == "a")
        try await Task.sleep(for: .seconds(AlcoveCapsuleQueue.life + 0.4))
        #expect(toy.activeCapsule?.id == "a", "an ask waits for its answer")
    }

    @Test("ask_resolved steps the ask down and the next capsule takes its turn")
    func resolvedStepsDown() {
        let (toy, store, _) = makeToy(state: liveState())
        defer { withExtendedLifetime(store) {} }
        toy.offer(askNotice())
        toy.offer(news(.failed, id: "f"))
        #expect(toy.capsuleQueue.pending?.id == "f")
        toy.noteEvent(CoreEvent(id: "x", kind: "ask_resolved", session: Self.session, request: "r1"))
        #expect(toy.activeCapsule?.id != "a")
        #expect(toy.capsuleQueue.current?.id == "f", "the waiting failure is next")
    }

    @Test("a resolution for another episode leaves the ask up")
    func otherEpisodeKeepsAsk() {
        let (toy, store, _) = makeToy(state: liveState())
        defer { withExtendedLifetime(store) {} }
        toy.offer(askNotice())
        toy.noteEvent(CoreEvent(id: "x", kind: "ask_resolved", session: Self.session, request: "r0"))
        #expect(toy.activeCapsule?.id == "a")
    }

    @Test("the state dropping the ask steps the capsule down once it was seen live")
    func stateResolution() {
        let (toy, store, core) = makeToy(state: liveState())
        defer { withExtendedLifetime(store) {} }
        toy.offer(askNotice())
        toy.noteAskState()
        #expect(toy.activeCapsule?.id == "a", "live in the state: holds")
        core.apply(.state(CoreState(sessions: [CoreSession(id: Self.session, provider: "claude",
                                                           mode: "working")])))
        toy.noteAskState()
        #expect(toy.activeCapsule == nil, "answered in the terminal: steps down")
    }

    @Test("an ask the state has not carried yet holds through its grace")
    func graceBeforeState() {
        let (toy, store, _) = makeToy()
        defer { withExtendedLifetime(store) {} }
        toy.offer(askNotice())
        toy.noteAskState()
        #expect(toy.activeCapsule?.id == "a")
        #expect(toy.askVerbs(for: toy.activeCapsule!) == .openOnly(reason: nil),
                "no live ask yet: Open only, never a guessed Approve")
    }

    @Test("Approve sends the pinned request and steps the ask down on ok")
    func approveSendsPin() async throws {
        let (toy, store, _) = makeToy(state: liveState())
        defer { withExtendedLifetime(store) {} }
        var sent: [(String, Bool, String?)] = []
        toy.answerer.send = { session, approve, request in
            sent.append((session, approve, request))
            return CoreReply(id: "1", ok: true)
        }
        toy.offer(askNotice())
        #expect(toy.askVerbs(for: toy.activeCapsule!) == .answer)
        // The answer is awaited, not polled: a congested main queue in
        // the parallel suite can outlast any fixed wait.
        await toy.answerCapsule(approve: true)?.value
        #expect(toy.activeCapsule == nil)
        #expect(sent.count == 1)
        #expect(sent.first?.0 == Self.session)
        #expect(sent.first?.1 == true)
        #expect(sent.first?.2 == "r1")
    }

    @Test("a refused answer keeps the ask up and says why")
    func refusalKeepsAsk() async throws {
        let (toy, store, _) = makeToy(state: liveState())
        defer { withExtendedLifetime(store) {} }
        toy.answerer.send = { _, _, _ in
            CoreReply(id: "1", ok: false, error: CoreReplyError(code: "stale_request"))
        }
        toy.offer(askNotice())
        await toy.answerCapsule(approve: false)?.value
        #expect(toy.activeCapsule?.id == "a")
        #expect(toy.answerer.note(for: Self.session) == "That request changed — nothing was sent")
    }

    @Test("an ask the daemon can't type into never sends")
    func unanswerableNeverSends() async throws {
        let (toy, store, _) = makeToy(state: liveState(answerable: false))
        defer { withExtendedLifetime(store) {} }
        var sends = 0
        toy.answerer.send = { _, _, _ in
            sends += 1
            return CoreReply(id: "1", ok: true)
        }
        toy.offer(askNotice())
        #expect(!toy.askVerbs(for: toy.activeCapsule!).answers)
        let took = await toy.answerer.answer(session: Self.session,
                                             ask: toy.liveAsk(for: toy.activeCapsule!),
                                             approve: true)
        #expect(!took)
        #expect(sends == 0)
    }

    @Test("a tap on an ask opens its session and puts the capsule away")
    func tapOpens() {
        let (toy, store, _) = makeToy(state: liveState())
        defer { withExtendedLifetime(store) {} }
        var opened: [String] = []
        toy.answerer.openSession = { opened.append($0) }
        toy.offer(askNotice())
        toy.islandTapped()
        #expect(opened == [Self.session])
        #expect(toy.activeCapsule == nil)
        #expect(!toy.islandExpanded)
    }

    @Test("a tap on news about a session opens it; news about nothing just goes")
    func tapOnNews() {
        let (toy, store, _) = makeToy()
        defer { withExtendedLifetime(store) {} }
        var opened: [String] = []
        toy.answerer.openSession = { opened.append($0) }
        var failed = news(.failed, id: "f")
        failed.session = "codex:s9"
        toy.offer(failed)
        toy.islandTapped()
        #expect(opened == ["codex:s9"])
        #expect(toy.activeCapsule == nil)
    }

    @Test("a band click grows the card over a latched ask; the fold brings the ask back")
    func bandClickYields() {
        let (toy, store, _) = makeToy(state: liveState())
        defer { withExtendedLifetime(store) {} }
        toy.offer(askNotice())
        toy.expandFromBand()
        #expect(toy.islandExpanded, "the card carries the same ask with its verbs")
        #expect(toy.activeCapsule == nil)
        #expect(toy.shelvedCapsule?.notice.id == "a")
        toy.collapseFromBand()
        #expect(toy.activeCapsule?.id == "a", "still open: the ask comes back")
    }

    @Test("an ask answered while the card was up does not come back on the fold")
    func answeredUnderCard() {
        let (toy, store, _) = makeToy(state: liveState())
        defer { withExtendedLifetime(store) {} }
        toy.offer(askNotice())
        toy.expandFromBand()
        toy.noteEvent(CoreEvent(id: "x", kind: "ask_resolved", session: Self.session))
        toy.collapseFromBand()
        #expect(toy.activeCapsule == nil)
        #expect(toy.capsuleQueue.current == nil)
    }

    @Test("the takeover grows the live ask into the card and holds it")
    func takeover() {
        let (toy, store, _) = makeToy(state: liveState())
        defer { withExtendedLifetime(store) {} }
        toy.offer(news(.completed, id: "c"))
        toy.noteTakeover(CoreEvent(id: "e", kind: "escalation_stage", session: Self.session, stage: 3))
        #expect(toy.activeCapsule?.kind == .ask)
        #expect(toy.activeCapsule?.takeover == true)
        #expect(toy.activeCapsule?.ask?.request == "r1", "pinned to the live episode")
        toy.releaseTakeover()
        #expect(toy.activeCapsule?.takeover == false)
        #expect(toy.activeCapsule?.kind == .ask, "the capsule keeps holding")
    }

    @Test("no open ask, no takeover; a grown card is left alone")
    func takeoverGates() {
        let (idle, store, _) = makeToy()
        defer { withExtendedLifetime(store) {} }
        idle.noteTakeover(CoreEvent(id: "e", kind: "escalation_stage", session: Self.session, stage: 3))
        #expect(idle.activeCapsule == nil)

        let (toy, store2, _) = makeToy(state: liveState())
        defer { withExtendedLifetime(store2) {} }
        toy.expandFromBand()
        toy.noteTakeover(CoreEvent(id: "e", kind: "escalation_stage", session: Self.session, stage: 3))
        #expect(toy.activeCapsule == nil)
        #expect(toy.islandExpanded)
    }

    @Test("level feedback overlays the island at once and never queues")
    func levelOverlay() {
        let (toy, store, _) = makeToy()
        defer { withExtendedLifetime(store) {} }
        let level = AlcoveNotice(id: "l", kind: .level, title: "Volume", subtitle: "",
                                 key: "level", fraction: 0.3)
        #expect(toy.presentSystemNotice(level))
        #expect(toy.activeOverlay?.fraction == 0.3)
        #expect(toy.capsuleQueue.current == nil)
        toy.islandTapped()
        #expect(toy.activeOverlay == nil, "a tap puts feedback away")
        #expect(!toy.islandExpanded)
    }

    @Test("feedback yields to a latched ask — the pill takes it instead")
    func levelYieldsToAsk() {
        let (toy, store, _) = makeToy(state: liveState())
        defer { withExtendedLifetime(store) {} }
        toy.offer(askNotice())
        let level = AlcoveNotice(id: "l", kind: .level, title: "Volume", subtitle: "",
                                 key: "level", fraction: 0.3)
        #expect(!toy.presentSystemNotice(level))
        #expect(toy.activeOverlay == nil)
        #expect(toy.activeCapsule?.id == "a")
    }

    @Test("announcements join the capsule line; a grown or parked island refuses them")
    func announcementsQueue() {
        let (toy, store, _) = makeToy()
        defer { withExtendedLifetime(store) {} }
        #expect(toy.presentSystemNotice(news(.focus, id: "f")))
        #expect(toy.activeCapsule?.kind == .focus)
        toy.finishCapsule()
        toy.expandFromBand()
        #expect(!toy.presentSystemNotice(news(.device, id: "d")))
        toy.collapseFromBand()
        toy.islandVisible = false
        #expect(!toy.presentSystemNotice(news(.display, id: "x")))
    }

    @Test("a toast the island would never say goes to the pill")
    func announcementsNeverVanish() {
        // A latched ask holds the line: a device notice queued behind it
        // would sit there until it went stale.
        let (toy, store, _) = makeToy(state: liveState())
        defer { withExtendedLifetime(store) {} }
        toy.offer(askNotice())
        #expect(!toy.presentSystemNotice(news(.device, id: "d")))
        #expect(toy.capsuleQueue.pending == nil, "nothing parked behind the ask")
        #expect(toy.activeCapsule?.id == "a")

        // News up, an ask waiting behind it: the device notice is
        // outranked at the door, so the island will not say it.
        let (other, store2, _) = makeToy(state: liveState())
        defer { withExtendedLifetime(store2) {} }
        other.offer(news(.completed, id: "c"))
        other.offer(askNotice())
        #expect(other.capsuleQueue.pending?.kind == .ask)
        #expect(!other.presentSystemNotice(news(.device, id: "d")))
        #expect(other.capsuleQueue.pending?.kind == .ask)

        // A repeat inside the cooldown is not the island's to say again —
        // the pill carries it.
        other.finishCapsule()
        other.finishCapsule()
        #expect(other.presentSystemNotice(news(.display, id: "x")))
        other.finishCapsule()
        #expect(!other.presentSystemNotice(news(.display, id: "x")))
    }

    @Test("the amber count opens the longest-waiting session")
    func oldestAsk() {
        let older = CoreSession(id: "claude:old", provider: "claude", since: 1,
                                ask: CoreAsk(openedAt: 10))
        let newer = CoreSession(id: "claude:new", provider: "claude", since: 2,
                                ask: CoreAsk(openedAt: 20))
        let (toy, store, _) = makeToy(state: CoreState(sessions: [newer, older]))
        defer { withExtendedLifetime(store) {} }
        var opened: [String] = []
        toy.answerer.openSession = { opened.append($0) }
        toy.openOldestAsk()
        #expect(opened == ["claude:old"])
    }
}
