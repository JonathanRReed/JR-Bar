import Foundation
import Testing
import JRBarCore
@testable import JRBarApp

/// `AskVerbs` is the one rule every surface reads: an ask JR-Bar already
/// answered offers no verb, whatever the daemon still says about it. A
/// newer app talking to an older daemon that calls a decided ask
/// answerable must not draw Approve, Deny or Always on the notch, the
/// Dock or the Rail, and the shared desk must not send a second verdict.
/// Nothing here answers anything.
@Suite("Ask verbs for a decided ask")
@MainActor
struct AskVerbsDecidedTests {
    private typealias Fixture = DecidedAskFixture

    @Test("a decided ask from an older daemon that says answerable offers no verb at all")
    func olderDaemonDecidedOffersNothing() {
        let stale = Fixture.olderDaemonDecidedAsk()
        #expect(stale.canAnswer && stale.isDecided, "what the older daemon claims")
        #expect(!AskVerbs.approves(stale))
        #expect(!AskVerbs.denies(stale))
        #expect(!AskVerbs.denies(stale, at: Date(timeIntervalSince1970: 1)))
        #expect(!AskVerbs.alwaysAllows(stale))
        #expect(!AskVerbs.chooses(stale))
        #expect(!AskVerbs.replies(stale))
        #expect(!AskVerbs.any(stale))
        for verdict in [AskVerdict.approve, .deny, .always, .reply("yes"),
                        .choose(["Which database?": .string("Postgres")])] {
            #expect(!AskVerbs.allows(verdict, on: stale))
        }
    }

    @Test("an older daemon's decided question or reply ask offers no verb either")
    func olderDaemonDecidedQuestionAndReply() {
        let question = Fixture.decidedAsk(answerable: true, replyable: nil, choices: [Fixture.pick])
        #expect(!AskVerbs.chooses(question))
        #expect(!AskVerbs.denies(question))
        #expect(!AskVerbs.any(question))
        #expect(!AskVerbs.allows(.choose(["Which database?": .string("SQLite")]), on: question))
        let reply = Fixture.decidedAsk(answerable: true, replyable: true)
        #expect(!AskVerbs.replies(reply))
        #expect(!AskVerbs.allows(.reply("main"), on: reply))
        #expect(!AskVerbs.any(reply))
    }

    @Test("the daemon's own decided ask, answerable false, offers no verb")
    func daemonDecidedOffersNothing() {
        let answered = Fixture.decidedAsk()
        #expect(!AskVerbs.approves(answered) && !AskVerbs.denies(answered))
        #expect(!AskVerbs.alwaysAllows(answered) && !AskVerbs.any(answered))
    }

    @Test("an undecided answerable ask is unchanged: Approve, Deny, and Always where offered")
    func undecidedIsUnchanged() {
        let offered = Fixture.openAsk()
        #expect(AskVerbs.approves(offered) && AskVerbs.denies(offered) && AskVerbs.alwaysAllows(offered))
        #expect(AskVerbs.any(offered))
        for verdict in [AskVerdict.approve, .deny, .always] {
            #expect(AskVerbs.allows(verdict, on: offered))
        }
        let plain = Fixture.openAsk(always: false)
        #expect(AskVerbs.approves(plain) && AskVerbs.denies(plain))
        #expect(!AskVerbs.alwaysAllows(plain), "the agent offered no rule to remember")
        let typed = CoreAsk(session: Fixture.session, summary: "Reply", answerable: true, replyable: true)
        #expect(AskVerbs.replies(typed))
        #expect(AskVerbs.allows(.reply("main"), on: typed))
        #expect(!AskVerbs.approves(typed) && !AskVerbs.denies(typed), "a reply ask wants words")
    }

    @Test("a held question with choices is unchanged: its options and Deny, never a bare yes")
    func heldQuestionIsUnchanged() {
        let question = Fixture.heldQuestion()
        #expect(AskVerbs.chooses(question))
        #expect(AskVerbs.denies(question))
        #expect(!AskVerbs.approves(question))
        #expect(AskVerbs.any(question))
        #expect(AskVerbs.allows(.choose(["Which database?": .string("Postgres")]), on: question))
        #expect(question.decidedLine == nil)
    }

    @Test("a refusal for a decided ask is the decided line, not a way to another window")
    func refusalSaysTheAskIsDecided() {
        for stale in [Fixture.decidedAsk(), Fixture.olderDaemonDecidedAsk()] {
            for verdict in [AskVerdict.approve, .deny, .always, .reply("yes"), .choose([:])] {
                #expect(AskVerbs.refusal(verdict, on: stale) == stale.decidedLine)
            }
        }
        let refused = AskVerbs.refusal(.approve, on: Fixture.heldQuestion())
        #expect(refused == "Pick one of its options", "an undecided ask keeps its own refusals")
        let sealed = CoreAsk(session: Fixture.session, summary: "Bash", answerable: false)
        #expect(AskVerbs.refusal(.deny, on: sealed) == "Answer this one in the session's window")
    }

    @Test("the desk refuses every verdict for a decided ask and sends nothing")
    func deskSendsNothingForADecidedAsk() async {
        let log = Fixture.SentLog()
        let desk = Fixture.desk(logging: log)
        let stale = Fixture.olderDaemonDecidedAsk()
        for verdict in [AskVerdict.approve, .deny, .always] {
            let outcome = await desk.answer(stale, verdict)
            #expect(!outcome.ok)
            #expect(outcome.line == stale.decidedLine)
        }
        #expect(desk.refusal(stale, .approve) == stale.decidedLine)
        #expect(log.answers.isEmpty, "no second verdict left the desk")
        #expect(!desk.isPending(Fixture.session))
        #expect(desk.note(for: Fixture.session) == nil)
        // The ask beside it still goes through the same desk.
        let outcome = await desk.answer(Fixture.openAsk(), .approve)
        #expect(outcome.ok)
        #expect(log.answers.count == 1)
        #expect(log.answers.first?.1 == .approve)
    }

    @Test("the Rail's pill offers nothing to click for a decided ask from an older daemon")
    func railPillForAnOlderDaemonsDecidedAsk() {
        let stale = Fixture.olderDaemonDecidedAsk()
        #expect(!DeckStore.pillAnswers(stale))
        let desk = Fixture.desk(logging: Fixture.SentLog())
        let pill = RailLabelView(title: "Key 1", subtitle: "Needs you", provider: "claude", number: "1",
                                 ask: stale, desk: desk)
        #expect(!pill.isInteractive)
        #expect(pill.decidedLine == Fixture.words)
    }

    @Test("a click path that reaches a decided ask from an older daemon still sends nothing")
    func capsuleAnswerSendsNothing() async {
        let stale = Fixture.olderDaemonDecidedAsk()
        let (toy, store, desk, log) = Fixture.makeToy(state: Fixture.state(holding: stale))
        defer { withExtendedLifetime(store) {} }
        toy.offer(Fixture.capsule(stale))
        await toy.answerCapsule(approve: true)?.value
        await toy.answerCapsule(approve: false)?.value
        #expect(log.answers.isEmpty, "the desk refuses what the buttons would not draw")
        #expect(toy.activeCapsule?.id == "a", "nothing was answered, so the capsule stays")
        #expect(!desk.isPending(Fixture.session))
    }
}
