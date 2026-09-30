import Foundation
import Testing
import JRBarCore
@testable import JRBarApp

/// The ask capsule at the notch for an ask JR-Bar already answered: it
/// draws no verb and says what the panel says, even when a daemon that
/// predates the decided flag still calls the ask answerable. Nothing here
/// answers anything.
@Suite("Notch decided ask flow")
@MainActor
struct NotchDecidedAskFlowTests {
    private typealias Fixture = DecidedAskFixture

    @Test("the capsule for a decided ask draws no verb and says what the panel says, even from an older daemon")
    func capsuleForADecidedAsk() {
        for stale in [Fixture.decidedAsk(), Fixture.olderDaemonDecidedAsk()] {
            let (toy, store, _, _) = Fixture.makeToy(state: Fixture.state(holding: stale))
            defer { withExtendedLifetime(store) {} }
            toy.offer(Fixture.capsule(stale))
            let shown = toy.activeCapsule
            #expect(shown?.id == "a")
            let verbs = shown.map { toy.askVerbs(for: $0) }
            #expect(verbs == .decided(line: Fixture.words))
            #expect(verbs?.answers == false)
            #expect(verbs?.opens == false)
            #expect(verbs?.note == stale.decidedLine)
        }
    }

    @Test("the capsule for an undecided ask is unchanged")
    func capsuleForAnOpenAsk() async {
        let open = Fixture.openAsk()
        let (toy, store, _, log) = Fixture.makeToy(state: Fixture.state(holding: open))
        defer { withExtendedLifetime(store) {} }
        toy.offer(Fixture.capsule(open))
        let verbs = toy.activeCapsule.map { toy.askVerbs(for: $0) }
        #expect(verbs == .answer)
        #expect(verbs?.answers == true && verbs?.opens == true)
        await toy.answerCapsule(approve: true)?.value
        #expect(log.answers.count == 1)
        #expect(log.answers.first?.1 == .approve)
    }

    @Test("the capsule for a held question is unchanged: it still offers its options")
    func capsuleForAHeldQuestion() {
        let question = Fixture.heldQuestion()
        let (toy, store, _, _) = Fixture.makeToy(state: Fixture.state(holding: question))
        defer { withExtendedLifetime(store) {} }
        toy.offer(Fixture.capsule(question))
        let live = toy.activeCapsule.flatMap { toy.liveAsk(for: $0) }
        #expect(live.map(AskVerbs.chooses) == true)
        #expect(live?.decidedLine == nil)
        let verbs = toy.activeCapsule.map { toy.askVerbs(for: $0) }
        #expect(verbs == .openOnly(reason: "Answer it in its window"), "the island hides that note for a question")
    }
}
