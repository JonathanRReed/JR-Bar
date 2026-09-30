import Foundation
import Testing
import JRBarCore
@testable import JRBarApp

/// The Overview reads the same rule every other surface does for an ask
/// JR-Bar already answered (`CoreAsk.isDecided`): its inspector and context
/// menu draw no verb, not even a disabled one behind "cannot be answered
/// from here", and say the decided line. An undecided answerable ask, a held
/// question and an ask that really cannot be answered from here are as they
/// were. Nothing here answers anything.
@Suite("Overview and a decided ask")
@MainActor
struct OverviewDecidedAskTests {
    private typealias Fixture = DecidedAskFixture

    private func entry(_ ask: CoreAsk, remote: Bool = false) -> CoreRosterEntry {
        CoreRosterEntry(session: CoreSession(id: Fixture.session, provider: "claude", label: "release cleanup",
                                             mode: "waiting", lifecycle: "active", ask: ask, remote: remote),
                        schema: 1, visibility: "live")
    }

    private func makeStore(desk: AskAnswerDesk? = nil) -> OverviewStore {
        OverviewStore(core: CoreModel(), desk: desk)
    }

    @Test("a decided ask is neither actionable nor 'cannot be answered': it says it was answered")
    func decidedAskSaysSo() {
        let store = makeStore()
        for ask in [Fixture.decidedAsk(), Fixture.olderDaemonDecidedAsk()] {
            let row = entry(ask)
            #expect(store.askAction(for: row) == .decided)
            #expect(store.askDisabledReason(for: row) == Fixture.words)
            #expect(!store.canReply(row))
        }
    }

    @Test("a decided reply ask from an older daemon offers no Reply either")
    func decidedReplyAsk() {
        let store = makeStore()
        let row = entry(Fixture.decidedAsk(answerable: true, replyable: true))
        #expect(store.askAction(for: row) == .decided)
        #expect(!store.canReply(row))
    }

    @Test("the inspector's plan for a decided ask draws no verb at all, and carries the decided line")
    func decidedPlanDrawsNothing() {
        let store = makeStore()
        for ask in [Fixture.decidedAsk(), Fixture.olderDaemonDecidedAsk(),
                    Fixture.decidedAsk(answerable: true, replyable: true),
                    Fixture.decidedAsk(answerable: true, replyable: nil, choices: [Fixture.pick])] {
            let plan = store.askVerbPlan(for: entry(ask))
            #expect(plan == OverviewStore.AskVerbPlan(decidedLine: Fixture.words))
            #expect(plan.disabledReason == nil, "not a disabled button with an excuse")
        }
    }

    @Test("an undecided answerable ask is unchanged: Approve, Deny and Always where offered")
    func undecidedIsUnchanged() {
        let store = makeStore()
        let offered = entry(Fixture.openAsk())
        #expect(store.askAction(for: offered) == .actionable)
        #expect(store.askDisabledReason(for: offered) == nil)
        #expect(store.askVerbPlan(for: offered)
                == OverviewStore.AskVerbPlan(approve: true, alwaysAllow: true, deny: true))
        let plain = entry(Fixture.openAsk(always: false))
        #expect(store.askVerbPlan(for: plain) == OverviewStore.AskVerbPlan(approve: true, deny: true))
        let typed = entry(CoreAsk(session: Fixture.session, summary: "Which branch?", answerable: true, replyable: true))
        #expect(store.canReply(typed))
        #expect(store.askVerbPlan(for: typed) == OverviewStore.AskVerbPlan(reply: true))
    }

    @Test("an ask that cannot be answered from here keeps its words and its disabled verbs")
    func notAnswerableKeepsItsWords() {
        let store = makeStore()
        let sealed = entry(CoreAsk(session: Fixture.session, summary: "Edit a file", answerable: false))
        let reason = "The monitor reports this ask cannot be answered from here"
        #expect(store.askAction(for: sealed) == .notAnswerable)
        #expect(store.askDisabledReason(for: sealed) == reason)
        #expect(store.askVerbPlan(for: sealed)
                == OverviewStore.AskVerbPlan(approve: true, deny: true, disabledReason: reason))
        let peer = entry(CoreAsk(session: Fixture.session, summary: "Run", answerable: true), remote: true)
        #expect(store.askAction(for: peer) == .remote)
        #expect(store.askDisabledReason(for: peer) == "A remote session — answer it on the machine it runs on")
        #expect(store.askVerbPlan(for: peer).disabledReason == store.askDisabledReason(for: peer))
        #expect(store.askAction(for: entry(CoreAsk(session: Fixture.session))) == .actionable)
    }

    @Test("a peer's ask keeps the peer's words, whatever its decision says")
    func peerAskIsThePeersToDescribe() {
        let store = makeStore()
        let peer = entry(Fixture.decidedAsk(), remote: true)
        #expect(store.askAction(for: peer) == .remote)
        #expect(store.askVerbPlan(for: peer).decidedLine == nil)
    }

    @Test("a held question with choices is unchanged: its options stay and Deny declines it")
    func heldQuestionIsUnchanged() {
        let store = makeStore()
        let question = Fixture.heldQuestion()
        let row = entry(question)
        #expect(AskVerbs.chooses(question), "the inspector and the menu route it to its options first")
        #expect(question.decidedLine == nil)
        #expect(store.askAction(for: row) == .notAnswerable, "as it was: only its options and Deny apply")
        #expect(OverviewSessionInspector.askHeading(question) == "Waiting on you")
    }

    @Test("the inspector's heading is the decided line where the loud 'Waiting on you' was")
    func headingForADecidedAsk() {
        #expect(OverviewSessionInspector.askHeading(Fixture.decidedAsk()) == Fixture.words)
        #expect(OverviewSessionInspector.askHeading(Fixture.olderDaemonDecidedAsk()) == Fixture.words)
        #expect(OverviewSessionInspector.askHeading(Fixture.openAsk()) == "Waiting on you")
    }

    @Test("Approve on a decided ask sends nothing and the status line says it was answered")
    func answerOnADecidedAskIsRefused() async {
        let log = Fixture.SentLog()
        let store = makeStore(desk: Fixture.loggingDesk(log))
        for ask in [Fixture.decidedAsk(), Fixture.olderDaemonDecidedAsk()] {
            store.actionStatus = nil
            await store.answerAsk(entry: entry(ask), approve: true)
            #expect(store.actionStatus == Fixture.words)
            #expect(store.actionIsError)
            await store.answerAsk(entry: entry(ask), approve: false)
            await store.alwaysAllow(entry: entry(ask))
            #expect(store.actionStatus == Fixture.words)
        }
        #expect(log.answers.isEmpty, "no verdict left the desk")
    }
}
