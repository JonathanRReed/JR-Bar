import Foundation
import Testing
import JRBarCore
@testable import JRBarApp

/// The Rail's pill and key say "Answered" where they said "Needs you" for an
/// ask JR-Bar already answered, so the line above it and "Answered, waiting
/// for the agent" below it do not contradict. What counts as needing the
/// person is not touched: the key is the same state, lit the same, and the
/// header count reads the same. Nothing here answers anything.
@Suite("Rail subtitle for a decided ask")
@MainActor
struct RailDecidedSubtitleTests {
    private typealias Fixture = DecidedAskFixture

    private func makeStore(holding ask: CoreAsk) -> DeckStore {
        let core = CoreModel()
        core.apply(.state(Fixture.state(holding: ask)))
        return DeckStore(core: core)
    }

    private let asking = DeckSlot(index: 0, identity: "key-0", session: Fixture.session, state: .inputRequired)

    @Test("a decided ask's key reads Answered, from the daemon or from an older one")
    func decidedKeyReadsAnswered() {
        for ask in [Fixture.decidedAsk(), Fixture.olderDaemonDecidedAsk()] {
            let store = makeStore(holding: ask)
            #expect(store.ask(for: asking)?.isDecided == true)
            #expect(store.railSubtitle(for: asking) == "Answered")
        }
    }

    @Test("an open ask, a held question and every other key read as they always did")
    func otherKeysAreUnchanged() {
        let open = makeStore(holding: Fixture.openAsk())
        #expect(open.railSubtitle(for: asking) == "Needs you")
        #expect(asking.subtitle == "Needs you")
        let question = makeStore(holding: Fixture.heldQuestion())
        #expect(question.railSubtitle(for: asking) == "Needs you")
        let decided = makeStore(holding: Fixture.decidedAsk())
        let working = DeckSlot(index: 1, identity: "key-1", session: Fixture.session, state: .active)
        #expect(decided.railSubtitle(for: working) == "Working", "only the asking key has an ask to answer")
        #expect(decided.railSubtitle(for: DeckSlot(index: 2)) == "No session assigned")
        let reserved = DeckSlot(index: 3, identity: "abc")
        #expect(decided.railSubtitle(for: reserved) == "Session not observed")
    }

    @Test("a key with no live ask left says Needs you until the state catches up")
    func noLiveAskKeepsTheStateWord() {
        let store = makeStore(holding: Fixture.decidedAsk())
        let gone = DeckSlot(index: 4, identity: "key-4", session: "claude:session:gone", state: .inputRequired)
        #expect(store.ask(for: gone) == nil)
        #expect(store.railSubtitle(for: gone) == "Needs you")
    }

    @Test("a peer's decided ask is the peer's to describe: its key keeps the state word")
    func peerAskKeepsTheStateWord() {
        var peer = Fixture.decidedAsk()
        peer.session = "remote:studio:claude:s1"
        let slot = DeckSlot(index: 5, identity: "key-5", session: peer.session, state: .inputRequired)
        #expect(DeckStore.railSubtitle(slot, ask: peer) == "Needs you")
        var unnamed = Fixture.decidedAsk()
        unnamed.session = nil
        #expect(DeckStore.railSubtitle(asking, ask: unnamed) == "Needs you")
        #expect(DeckStore.railSubtitle(asking, ask: nil) == "Needs you")
    }

    @Test("the pill carries the Answered subtitle above the decided line, and the key's state is unchanged")
    func pillAndStateAgree() {
        let ask = Fixture.decidedAsk()
        let store = makeStore(holding: ask)
        let subtitle = store.railSubtitle(for: asking)
        let pill = RailLabelView(title: "release cleanup", subtitle: subtitle, provider: "claude", number: "1",
                                 ask: store.ask(for: asking), desk: Fixture.loggingDesk(Fixture.SentLog()))
        #expect(pill.subtitle == "Answered")
        #expect(pill.decidedLine == Fixture.words)
        #expect(!pill.isInteractive)
        // What counts as needing the person is the key's state, not its label.
        #expect(asking.state == .inputRequired)
        #expect(asking.state.needsAttention)
        #expect(asking.state.railMark == "!")
        #expect(asking.state.lightingHex == DeckLighting.askHex)
    }
}
