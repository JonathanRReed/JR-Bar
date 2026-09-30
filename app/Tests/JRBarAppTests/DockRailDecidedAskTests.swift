import Foundation
import Testing
import JRBarCore
@testable import JRBarApp

/// The Dock's ask row and the Rail's ask pill for an ask JR-Bar already
/// answered: no verb, not even a disabled one, and the panel's own line
/// where the verbs were. Pure: nothing is drawn, nothing is sent.
@Suite("Dock and Rail decided asks")
@MainActor
struct DockRailDecidedAskTests {
    private typealias Fixture = DecidedAskFixture

    // MARK: Dock

    @Test("the Dock row draws the decided line and no disabled verb for a decided ask")
    func dockRowForADecidedAsk() {
        for stale in [Fixture.decidedAsk(), Fixture.olderDaemonDecidedAsk()] {
            let plan = DockAskVerbSet.resolve(ask: stale, hasDesk: true, note: nil)
            #expect(plan == .decided(line: Fixture.words))
            let noDesk = DockAskVerbSet.resolve(ask: stale, hasDesk: false, note: nil)
            #expect(noDesk == .decided(line: Fixture.words), "a fact about the ask, whatever the desk")
        }
    }

    @Test("the Dock row is unchanged for an open ask, a held question and an ask it cannot type into")
    func dockRowIsUnchangedOtherwise() {
        let open = Fixture.openAsk()
        #expect(DockAskVerbSet.resolve(ask: open, hasDesk: true, note: nil) == .verdicts(answerable: true))
        let question = Fixture.heldQuestion()
        #expect(DockAskVerbSet.resolve(ask: question, hasDesk: true, note: nil) == .choices)
        let sealed = CoreAsk(session: Fixture.session, summary: "Bash", answerable: false)
        #expect(DockAskVerbSet.resolve(ask: sealed, hasDesk: true, note: nil) == .verdicts(answerable: false),
                "an undecided ask that cannot be typed into keeps its disabled verbs")
        let typed = CoreAsk(session: Fixture.session, summary: "Reply", answerable: true, replyable: true)
        #expect(DockAskVerbSet.resolve(ask: typed, hasDesk: true, note: nil) == .verdicts(answerable: false))
        #expect(DockAskVerbSet.resolve(ask: open, hasDesk: false, note: nil) == .none, "no desk, no verbs")
        #expect(DockAskVerbSet.resolve(ask: nil, hasDesk: true, note: nil) == .none)
    }

    @Test("the desk's own line about the last answer still comes first")
    func dockRowKeepsTheDeskNote() {
        let line = "Sent through the agent's own permission hook"
        #expect(DockAskVerbSet.resolve(ask: Fixture.openAsk(), hasDesk: true, note: line) == .note(line))
        #expect(DockAskVerbSet.resolve(ask: Fixture.decidedAsk(), hasDesk: true, note: line) == .note(line))
    }

    // MARK: Rail

    @Test("the Rail's pill draws no verb for a decided ask and carries the decided line instead")
    func railPillForADecidedAsk() {
        let log = Fixture.SentLog()
        let desk = Fixture.loggingDesk(log)
        let answered = Fixture.decidedAsk()
        #expect(!DeckStore.pillAnswers(answered))
        let pill = RailLabelView(title: "Key 1", subtitle: "Needs you", provider: "claude", number: "1",
                                 ask: answered, desk: desk)
        #expect(!pill.isInteractive, "no verbs to click, so the pill goes when the pointer leaves")
        #expect(pill.decidedLine == Fixture.words)
        #expect(pill.decidedLine == answered.decidedLine)
        let stale = Fixture.olderDaemonDecidedAsk()
        #expect(RailLabelView.decidedLine(stale) == Fixture.words, "whatever the older daemon says of it")
        #expect(log.answers.isEmpty)
    }

    @Test("the Rail's pill is unchanged for an open ask, a held question, a peer's ask and none at all")
    func railPillIsUnchangedOtherwise() {
        let desk = Fixture.loggingDesk(Fixture.SentLog())
        let open = Fixture.openAsk()
        #expect(DeckStore.pillAnswers(open))
        #expect(RailLabelView.decidedLine(open) == nil)
        let pill = RailLabelView(title: "Key 1", subtitle: "Needs you", provider: "claude", number: "1",
                                 ask: open, desk: desk)
        #expect(pill.isInteractive)
        #expect(pill.decidedLine == nil)
        #expect(DeckStore.pillAnswers(Fixture.heldQuestion()))
        #expect(RailLabelView.decidedLine(Fixture.heldQuestion()) == nil)
        var peer = Fixture.decidedAsk()
        peer.session = "remote:studio:claude:s1"
        #expect(!DeckStore.pillAnswers(peer))
        #expect(RailLabelView.decidedLine(peer) == nil, "a peer's ask is the peer's to describe")
        #expect(RailLabelView.decidedLine(nil) == nil)
        var unnamed = Fixture.decidedAsk()
        unnamed.session = nil
        #expect(RailLabelView.decidedLine(unnamed) == nil)
    }
}
