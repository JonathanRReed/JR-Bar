import Foundation
import Testing
import JRBarCore
@testable import JRBarApp

/// The ask at the notch, end to end against the toy: the capsule that
/// holds until the ask is acted on, the answer path through the shared
/// desk with its request pin, the tap that opens through the one opener,
/// the band click that yields, the takeover, and key feedback that never
/// covers an ask's buttons. The daemon is a staged `send` on the toy's
/// own desk, wired the way the app delegate wires the shared one;
/// `islandVisible` stands in for a notched screen.
@Suite("Notch ask flow")
@MainActor
struct NotchAskFlowTests {
    private static let session = "claude:s1"

    /// What the staged daemon was asked: session, verdict, request pin.
    private final class Sent {
        var answers: [(String, AskVerdict, String?)] = []
        var reply = CoreReply(id: "1", ok: true)
    }

    private func makeToy(state: CoreState? = nil) -> (NotchToy, ToysStore, CoreModel) {
        let (toy, store, core, _, _) = makeToyWithDesk(state: state)
        return (toy, store, core)
    }

    private func makeToyWithDesk(state: CoreState? = nil)
        -> (NotchToy, ToysStore, CoreModel, AskAnswerDesk, Sent) {
        var toys = ToysState()
        toys.notch = NotchSettings(enabled: true, provider: .jrbar, islandEnabled: true)
        let core = CoreModel()
        if let state { core.apply(.state(state)) }
        let store = ToysStore(core: core, settings: SettingsStore(core: core),
                              state: toys, cardModel: makeTestCardModel(),
                              notchRuntimeEnabled: false)
        let toy: NotchToy = store.notch
        toy.islandVisible = true
        let sent = Sent()
        let desk = AskAnswerDesk(send: { session, verdict, request in
            sent.answers.append((session, verdict, request))
            return sent.reply
        })
        // As the app delegate wires the shared desk: an answer it lands
        // steps the capsule down.
        desk.onAnswered = { [weak toy] session, request in toy?.resolveAsk(session: session, request: request) }
        toy.cardModel.askDesk = { desk }
        return (toy, store, core, desk, sent)
    }

    private func liveState(answerable: Bool = true, request: String = "r1",
                           choices: [CoreAskChoice]? = nil) -> CoreState {
        var ask = CoreAsk(session: Self.session, openedAt: 1, summary: "Run tests",
                          answerable: answerable, request: request)
        if let choices { ask.decision = CoreAskDecision(choices: choices) }
        return CoreState(sessions: [CoreSession(id: Self.session, provider: "claude", label: "rename-the-fish",
                                                ask: CoreAsk(summary: "Run tests"))],
                         asks: [ask])
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
    func askLatches() {
        let (toy, store, _) = makeToy(state: liveState())
        defer { withExtendedLifetime(store) {} }
        let timers = ManualTimers.driving(toy)
        toy.offer(askNotice())
        #expect(toy.activeCapsule?.id == "a")
        #expect(timers.live == 0, "a latched ask arms no life to time it out")
        timers.advance(by: AlcoveCapsuleQueue.life + 0.4)
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

    @Test("Approve goes through the desk with the pinned request and steps the ask down on ok")
    func approveSendsPin() async throws {
        let (toy, store, _, desk, sent) = makeToyWithDesk(state: liveState())
        defer { withExtendedLifetime(store) {} }
        toy.offer(askNotice())
        #expect(toy.askVerbs(for: toy.activeCapsule!) == .answer)
        // The answer is awaited, not polled: a congested main queue in
        // the parallel suite can outlast any fixed wait.
        await toy.answerCapsule(approve: true)?.value
        #expect(toy.activeCapsule == nil)
        #expect(sent.answers.count == 1)
        #expect(sent.answers.first?.0 == Self.session)
        #expect(sent.answers.first?.1 == .approve)
        #expect(sent.answers.first?.2 == "r1")
        #expect(!desk.isPending(Self.session))
    }

    @Test("the capsule answers the episode it shows, never the live ask that replaced it")
    func pinOutlivesAReplacement() async throws {
        let (toy, store, core, _, sent) = makeToyWithDesk(state: liveState(request: "r1"))
        defer { withExtendedLifetime(store) {} }
        toy.offer(askNotice(request: "r1"))
        // A replacement lands before the capsule's next state pass.
        core.apply(.state(liveState(request: "r2")))
        #expect(toy.activeCapsule?.id == "a")
        await toy.answerCapsule(approve: false)?.value
        #expect(sent.answers.first?.1 == .deny)
        #expect(sent.answers.first?.2 == "r1", "the daemon refuses a stale pin rather than deny r2")
    }

    @Test("a refused answer keeps the ask up and says why")
    func refusalKeepsAsk() async throws {
        let (toy, store, _, desk, sent) = makeToyWithDesk(state: liveState())
        defer { withExtendedLifetime(store) {} }
        sent.reply = CoreReply(id: "1", ok: false, error: CoreReplyError(code: "stale_request"))
        toy.offer(askNotice())
        await toy.answerCapsule(approve: false)?.value
        #expect(toy.activeCapsule?.id == "a")
        #expect(desk.note(for: Self.session)?.text == "That request changed — nothing was sent")
        #expect(desk.note(for: Self.session)?.refused == true)
    }

    @Test("an ask the daemon can't type into never sends")
    func unanswerableNeverSends() async throws {
        let (toy, store, _, desk, sent) = makeToyWithDesk(state: liveState(answerable: false))
        defer { withExtendedLifetime(store) {} }
        toy.offer(askNotice())
        #expect(!toy.askVerbs(for: toy.activeCapsule!).answers)
        await toy.answerCapsule(approve: true)?.value
        let live = try #require(toy.liveAsk(for: toy.activeCapsule!))
        let outcome = await desk.answer(live, .approve)
        #expect(!outcome.ok)
        #expect(sent.answers.isEmpty)
    }

    @Test("a held question takes no bare Approve from the capsule — its options answer it")
    func heldQuestionRefusesApprove() async throws {
        let choice = CoreAskChoice(question: "Which?", options: ["A", "B"])
        let (toy, store, _, _, sent) = makeToyWithDesk(state: liveState(choices: [choice]))
        defer { withExtendedLifetime(store) {} }
        toy.offer(askNotice())
        let live = try #require(toy.liveAsk(for: toy.activeCapsule!))
        #expect(!AskVerbs.approves(live), "no Approve button is drawn")
        #expect(AskVerbs.denies(live) && AskVerbs.chooses(live))
        await toy.answerCapsule(approve: true)?.value
        #expect(sent.answers.isEmpty, "the desk refuses what the buttons would not offer")
        #expect(toy.activeCapsule?.id == "a")
    }

    @Test("with no desk the capsule sends nothing")
    func noDeskNoAnswer() {
        let (toy, store, _) = makeToy(state: liveState())
        defer { withExtendedLifetime(store) {} }
        toy.cardModel.askDesk = { nil }
        toy.offer(askNotice())
        #expect(toy.answerCapsule(approve: true) == nil)
    }

    @Test("a tap on an ask opens its session and puts the capsule away")
    func tapOpens() async {
        let (toy, store, _) = makeToy(state: liveState())
        defer { withExtendedLifetime(store) {} }
        var opened: [String] = []
        toy.openSession = { opened.append($0); return nil }
        toy.offer(askNotice())
        toy.islandTapped()
        await toy.openInFlight?.value
        #expect(opened == [Self.session])
        #expect(toy.activeCapsule == nil)
        #expect(!toy.islandExpanded)
    }

    @Test("an open that did not land keeps the capsule and says why")
    func refusedOpenStays() async {
        let (toy, store, _) = makeToy(state: liveState())
        defer { withExtendedLifetime(store) {} }
        toy.openSession = { _ in "That session is gone" }
        toy.offer(askNotice())
        await toy.openCapsuleSession()?.value
        #expect(toy.activeCapsule?.id == "a", "nothing opened: the ask is still the person's to act on")
        #expect(toy.cardModel.openRefusals[Self.session] == "That session is gone")
    }

    @Test("a card row folds the card only once its session is in front")
    func rowOpenWaitsForTheWindow() async {
        let (toy, store, _) = makeToy(state: liveState())
        defer { withExtendedLifetime(store) {} }
        toy.expandFromBand()
        toy.openSession = { _ in "Could not open rename-the-fish" }
        toy.cardModel.onOpenRow?(Self.session)
        await toy.openInFlight?.value
        #expect(toy.islandExpanded, "a refusal leaves the card up with its line")
        #expect(toy.cardModel.openRefusals[Self.session] == "Could not open rename-the-fish")

        var opened: [String] = []
        toy.openSession = { opened.append($0); return nil }
        toy.cardModel.onOpenRow?(Self.session)
        await toy.openInFlight?.value
        #expect(opened == [Self.session])
        #expect(!toy.islandExpanded)
    }

    @Test("a tap on news about a session opens it; news about nothing just goes")
    func tapOnNews() async {
        let (toy, store, _) = makeToy()
        defer { withExtendedLifetime(store) {} }
        var opened: [String] = []
        toy.openSession = { opened.append($0); return nil }
        var failed = news(.failed, id: "f")
        failed.session = "codex:s9"
        toy.offer(failed)
        toy.islandTapped()
        await toy.openInFlight?.value
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

    @Test("an announcement the island queued, then gave up to newer news, is handed back")
    func displacedAnnouncementIsReported() {
        let (toy, store, _) = makeToy(state: liveState())
        defer { withExtendedLifetime(store) {} }
        var evicted: [String] = []
        toy.onCapsuleEvicted = { evicted.append($0.id) }
        toy.offer(news(.failed, id: "f"))
        #expect(toy.presentSystemNotice(news(.device, id: "d")),
                "the island takes it — it waits behind the failure, and the pill stays down")
        #expect(toy.capsuleQueue.pending?.id == "d")
        // An agent's finish outranks a device and takes the one slot:
        // the island's yes has lapsed, and the toy says so.
        #expect(toy.offer(news(.completed, id: "c")))
        #expect(toy.capsuleQueue.pending?.id == "c")
        #expect(evicted == ["d"])
        // Turned away at the door, a notice displaces nothing.
        #expect(!toy.offer(news(.charging, id: "p")))
        #expect(evicted == ["d"])
        #expect(AlcoveNoticeKind.device.isMacAnnouncement, "the HUD's pill is the one to say it")
    }

    @Test("the amber count opens the longest-waiting session")
    func oldestAsk() async {
        let older = CoreSession(id: "claude:old", provider: "claude", since: 1,
                                ask: CoreAsk(openedAt: 10))
        let newer = CoreSession(id: "claude:new", provider: "claude", since: 2,
                                ask: CoreAsk(openedAt: 20))
        let (toy, store, _) = makeToy(state: CoreState(sessions: [newer, older]))
        defer { withExtendedLifetime(store) {} }
        var opened: [String] = []
        toy.openSession = { opened.append($0); return nil }
        toy.openOldestAsk()
        await toy.openInFlight?.value
        #expect(opened == ["claude:old"])
    }
}
