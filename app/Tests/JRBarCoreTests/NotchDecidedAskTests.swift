import Foundation
import Testing
@testable import JRBarCore

/// What the notch offers for an ask JR-Bar already answered. The agent's
/// own events have not closed the request yet, so nothing is being asked:
/// the notch draws no verb and says what the panel says
/// (`CoreAsk.decidedLine`), never "answer it in its window". Pure: no
/// notch, no daemon, nothing sent.
@Suite("Notch decided asks")
struct NotchDecidedAskTests {
    private static let session = "claude:s1"

    /// The ask as the daemon publishes it once the answer went out.
    private static func decided(answerable: Bool? = false, replyable: Bool? = false,
                                choices: [CoreAskChoice] = []) -> CoreAsk {
        CoreAsk(session: session, kind: "permission", summary: "Run the cleanup",
                answerable: answerable, replyable: replyable, request: "r-decided",
                decision: CoreAskDecision(holdUntil: 2e9, always: false, decided: true, choices: choices),
                preview: "rm -rf build", risk: "destructive")
    }

    @Test("a decided ask resolves to no verb and the panel's own line")
    func decidedResolvesToTheLine() {
        let ask = Self.decided()
        let verbs = NotchAskVerbs.resolve(live: ask, session: Self.session)
        #expect(verbs == .decided(line: "Answered, waiting for the agent"))
        #expect(verbs.note == ask.decidedLine, "the same words the panel draws, from one place")
        #expect(!verbs.answers)
        #expect(!verbs.opens, "nothing is asked, so there is no Open beside a line that says wait")
    }

    @Test("it never says to answer it in its window")
    func neverSendsThePersonElsewhere() {
        let verbs = NotchAskVerbs.resolve(live: Self.decided(), session: Self.session)
        #expect(verbs.note != "Answer it in its window")
        #expect(verbs != .openOnly(reason: "Answer it in its window"))
    }

    @Test("a decided ask from an older daemon that still says answerable draws no verb either")
    func olderDaemonDecidedAsk() {
        let answerable = Self.decided(answerable: true, replyable: nil)
        let verbs = NotchAskVerbs.resolve(live: answerable, session: Self.session)
        #expect(verbs == .decided(line: "Answered, waiting for the agent"))
        #expect(!verbs.answers)
        let replyable = Self.decided(answerable: true, replyable: true)
        let typed = NotchAskVerbs.resolve(live: replyable, session: Self.session)
        #expect(typed == .decided(line: "Answered, waiting for the agent"), "not a typed-reply ask any more")
        #expect(typed.note == replyable.decidedLine)
    }

    @Test("a decided question that still lists its choices draws none of them")
    func decidedQuestion() {
        let choice = CoreAskChoice(question: "Which?", options: ["A", "B"])
        let ask = Self.decided(answerable: true, choices: [choice])
        let verbs = NotchAskVerbs.resolve(live: ask, session: Self.session)
        #expect(verbs == .decided(line: "Answered, waiting for the agent"))
        #expect(!verbs.answers)
    }

    @Test("an ask still waiting on a person is unchanged")
    func undecidedIsUnchanged() {
        let plain = CoreAsk(session: Self.session, answerable: true)
        #expect(NotchAskVerbs.resolve(live: plain, session: Self.session) == .answer)
        var held = CoreAsk(session: Self.session, openedAt: 985, answerable: true)
        held.decision = CoreAskDecision(holdUntil: 2e9, always: true, decided: false)
        let holding = NotchAskVerbs.resolve(live: held, session: Self.session)
        #expect(holding == .answer)
        #expect(holding.answers && holding.opens)
        #expect(holding.note == nil)
        let stuck = CoreAsk(session: Self.session, answerable: false)
        let refused = NotchAskVerbs.resolve(live: stuck, session: Self.session)
        #expect(refused == .openOnly(reason: "Answer it in its window"), "an undecided ask that cannot be typed into")
        #expect(refused.opens)
        let typing = CoreAsk(session: Self.session, answerable: true, replyable: true)
        #expect(NotchAskVerbs.resolve(live: typing, session: Self.session) == .openOnly(reason: "Wants a typed reply"))
    }

    @Test("a held question with choices is unchanged")
    func heldQuestionIsUnchanged() {
        let choice = CoreAskChoice(question: "Which?", options: ["A", "B"])
        var question = CoreAsk(session: Self.session, answerable: false)
        question.decision = CoreAskDecision(holdUntil: 2e9, always: false, decided: false, choices: [choice])
        let verbs = NotchAskVerbs.resolve(live: question, session: Self.session)
        #expect(verbs == .openOnly(reason: "Answer it in its window"), "the island hides that note for a question")
        #expect(question.decidedLine == nil)
        var answerable = question
        answerable.answerable = true
        #expect(NotchAskVerbs.resolve(live: answerable, session: Self.session) == .answer)
    }

    @Test("the session and remote rules still come first")
    func sessionRulesComeFirst() {
        let ask = Self.decided()
        #expect(NotchAskVerbs.resolve(live: ask, session: nil) == .none)
        #expect(NotchAskVerbs.resolve(live: ask, session: "") == .none)
        let remote = NotchAskVerbs.resolve(live: ask, session: "remote:studio:claude:s1")
        #expect(remote == .remote(machine: "studio"))
        #expect(NotchAskVerbs.resolve(live: nil, session: Self.session) == .openOnly(reason: nil),
                "an ask the state has not carried yet")
    }
}
