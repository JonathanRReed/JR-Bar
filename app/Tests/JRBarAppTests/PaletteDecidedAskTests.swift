import Foundation
import Testing
@testable import JRBarApp
@testable import JRBarCore

/// The palette reads the same rule every other surface does for an ask
/// JR-Bar already answered: its row draws no Approve, Deny, Always Allow or
/// Reply, and says the decided line instead of sending the person to the
/// session's window. An undecided ask keeps its verbs, a held question its
/// options, and an ask that really cannot be answered from here its words.
/// Nothing here answers anything.
@Suite("Palette and a decided ask")
@MainActor
struct PaletteDecidedAskTests {
    private typealias Fixture = DecidedAskFixture
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    private func row(_ ask: CoreAsk, id: String) -> SessionRow {
        SessionRow(session: CoreSession(id: id, provider: "claude", label: "release cleanup",
                                        cwd: "/Users/me/src/site", mode: "waiting",
                                        since: now.timeIntervalSince1970 - 300, ask: ask,
                                        remote: CoreSession.isRemoteID(id)),
                   pinnedAsk: nil)
    }

    private func item(_ ask: CoreAsk, id: String = Fixture.session) -> PaletteItem {
        var verbs = AgentPaletteVerbs(open: { _ in }, approve: { _ in }, deny: { _ in }, snooze: { _, _ in },
                                      copyPath: { _ in }, reveal: { _ in }, dismiss: { _ in }, clear: { _ in })
        verbs.alwaysAllow = { _ in }
        verbs.reply = { _, _ in }
        return AgentPaletteRows.askItem(row: row(ask, id: id), ask: ask, now: now, verbs: verbs)
    }

    private static let answerIDs: Set<String> = ["approve", "deny", "always", "reply"]

    private func answerVerbs(_ item: PaletteItem) -> [String] {
        item.actions.map(\.id).filter { Self.answerIDs.contains($0) || $0.hasPrefix("answer.") || $0.hasPrefix("pick.") }
    }

    @Test("a decided ask draws no verb and says the decided line, whatever the daemon still calls it")
    func decidedDrawsNoVerb() {
        let asks = [
            Fixture.decidedAsk(),
            Fixture.olderDaemonDecidedAsk(),
            Fixture.decidedAsk(answerable: true, replyable: true),
            Fixture.decidedAsk(answerable: true, replyable: nil, choices: [Fixture.pick]),
        ]
        for ask in asks {
            let shown = item(ask)
            #expect(answerVerbs(shown).isEmpty, "no answer verb for \(ask.summary ?? "")")
            #expect(shown.accessibilityNote == Fixture.words)
            #expect(shown.action(for: .secondary) == nil, "⌘↩ answers nothing")
            #expect(shown.primary?.title == "Open Session", "Return still only opens")
        }
    }

    @Test("a decided row's tag says it was answered, not that it needs you")
    func decidedTag() {
        let shown = item(Fixture.decidedAsk())
        #expect(shown.tags.first == PaletteTag(text: "Answered"))
        #expect(!shown.tags.contains { $0.text == "Needs You" })
        #expect(shown.tags.contains(PaletteTag(text: "Destructive", tone: .alert)), "the risk mark stays")
        #expect(shown.section == .needsYou, "what counts as waiting on the person is not changed here")
        #expect(shown.urgent)
    }

    @Test("an undecided answerable ask keeps Approve, Deny and Always Allow, and its Needs You tag")
    func undecidedIsUnchanged() {
        let shown = item(Fixture.openAsk())
        #expect(shown.action(for: .secondary)?.id == "approve")
        #expect(shown.action(for: .command("d"))?.id == "deny")
        #expect(shown.actions.contains { $0.id == "always" })
        #expect(shown.tags.first == PaletteTag(text: "Needs You", tone: .attention))
        #expect(shown.accessibilityNote == nil)
        let plain = item(Fixture.openAsk(always: false))
        #expect(!plain.actions.contains { $0.id == "always" })
        let typed = item(CoreAsk(session: Fixture.session, summary: "Which branch?", answerable: true, replyable: true))
        #expect(typed.action(for: .secondary)?.id == "reply")
        #expect(!typed.actions.contains { $0.id == "approve" || $0.id == "deny" })
    }

    @Test("a held question keeps its options and Deny, and says nothing of being answered")
    func heldQuestionIsUnchanged() {
        let shown = item(Fixture.heldQuestion())
        #expect(shown.actions.filter { $0.id.hasPrefix("answer.") }.map(\.title) == ["Answer “Postgres”", "Answer “SQLite”"])
        #expect(shown.action(for: .command("d"))?.id == "deny")
        #expect(shown.accessibilityNote == nil)
        #expect(shown.tags.first == PaletteTag(text: "Needs You", tone: .attention))
    }

    @Test("an ask that cannot be answered from here keeps its words and offers no verb")
    func notAnswerableKeepsItsWords() {
        let sealed = CoreAsk(session: Fixture.session, summary: "Edit a file", answerable: false)
        let shown = item(sealed)
        #expect(answerVerbs(shown).isEmpty)
        #expect(shown.accessibilityNote == "Answer it in the session's own window")
        #expect(shown.tags.first == PaletteTag(text: "Needs You", tone: .attention))
    }

    @Test("a peer's ask says it runs elsewhere, whatever its decision says")
    func peerAskKeepsItsWords() {
        let peerID = "remote:studio:claude:s1"
        var peer = Fixture.decidedAsk()
        peer.session = peerID
        let shown = item(peer, id: peerID)
        #expect(shown.accessibilityNote == "Runs on studio — answer it there")
        #expect(answerVerbs(shown).isEmpty)
    }

    @Test("the decided row is found by what it would run, as an open one is")
    func decidedRowIsStillFound() {
        let shown = item(Fixture.decidedAsk())
        let hits = PaletteRanking.rank([shown], query: "rm -rf", usage: PaletteUsage(), now: now)
        #expect(hits.count == 1)
        #expect(hits.first?.primary?.id == "open")
        #expect(hits.first?.actions.contains { $0.id == "approve" } == false, "nothing is left to approve")
    }
}
