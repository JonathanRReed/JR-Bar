import Darwin
import Foundation
import Testing
@testable import JRBarApp
@testable import JRBarCore

/// Asks answered from every surface: the palette's ask rows, the panel's
/// guards and its Open fallback, the Rail's pill, History's Resume, the
/// Overview's New Session Here, the hook doctor's line, and "quiet while
/// watching" taking the daemon's tab-level word. Nothing here opens a
/// window, plays a sound or reaches a daemon.
@Suite("Ask surfaces")
@MainActor
struct AskSurfacesTests {
    @MainActor
    final class Log {
        var calls: [String] = []
    }

    private let now = Date(timeIntervalSince1970: 1_800_000_000)
    static let single = CoreAskChoice(question: "Which database?", options: ["Postgres", "SQLite"])
    static let multi = CoreAskChoice(question: "Which checks?", header: "Checks", options: ["Lint", "Tests"], multi: true)

    private func row(_ id: String, ask: CoreAsk?, remote: Bool = false, mode: String = "waiting") -> SessionRow {
        SessionRow(session: CoreSession(id: id, provider: "claude", label: id, cwd: "/Users/me/src/\(id)",
                                        mode: mode, since: now.timeIntervalSince1970 - 60, ask: ask,
                                        remote: remote),
                   pinnedAsk: nil)
    }

    private func held(always: Bool = false, choices: [CoreAskChoice] = [], answerable: Bool = true,
                      preview: String? = nil, risk: String? = nil) -> CoreAsk {
        CoreAsk(session: "claude:s1", summary: "Bash", answerable: answerable, request: "r1",
                decision: CoreAskDecision(holdUntil: 2e9, always: always, choices: choices),
                preview: preview, risk: risk)
    }

    /// Polls until `done` or ten seconds pass — generous, because the
    /// whole suite shares one main actor, and each hop lands in a blink.
    static func waitFor(_ done: () -> Bool) async {
        let deadline = Date().addingTimeInterval(10)
        while !done(), Date() < deadline { try? await Task.sleep(for: .milliseconds(10)) }
    }

    // MARK: Panel

    @Test("⌘↩ on a held question sends nothing and says to pick an option")
    func panelApproveOnQuestion() {
        let store = PanelStore(core: CoreModel(), draftsDefaults: UserDefaults(suiteName: "jrbar.tests.\(UUID())")!,
                               screenBarShown: false)
        store.approve(held(choices: [Self.single]))
        #expect(store.toast == "Pick one of its options")
        #expect(!store.isAnswerPending(held(choices: [Self.single])))
        store.alwaysAllow(held(always: false))
        #expect(store.toast == "This one has no rule to remember — approve it once instead")
    }

    // MARK: Rail

    @Test("the Rail's ask pill holds across the gap and while pointed at, and a plain label never does")
    func railPillHold() {
        #expect(DeckRailPillHold.cell(hovered: 3, pillCell: 1, pillHovered: true, interactive: true, inGrace: false) == 3)
        #expect(DeckRailPillHold.cell(hovered: nil, pillCell: 1, pillHovered: false, interactive: true, inGrace: true) == 1)
        #expect(DeckRailPillHold.cell(hovered: nil, pillCell: 1, pillHovered: true, interactive: true, inGrace: false) == 1)
        #expect(DeckRailPillHold.cell(hovered: nil, pillCell: 1, pillHovered: false, interactive: true, inGrace: false) == nil)
        #expect(DeckRailPillHold.cell(hovered: nil, pillCell: 1, pillHovered: true, interactive: false, inGrace: true) == nil)
    }

    @Test("an asking key's pill carries its live ask; a peer's or an unanswerable one draws no verbs")
    func railPillAsk() {
        let core = CoreModel()
        let ask = CoreAsk(session: "claude:session:r", kind: "permission", summary: "Run", answerable: true,
                          decision: CoreAskDecision(always: true))
        core.apply(.state(CoreState(
            sessions: [CoreSession(id: "claude:session:r", provider: "claude", mode: "waiting")], asks: [ask])))
        let store = DeckStore(core: core)
        let asking = DeckSlot(index: 0, session: "claude:session:r", state: .inputRequired)
        #expect(store.ask(for: asking)?.canAlwaysAllow == true)
        #expect(store.ask(for: DeckSlot(index: 1, session: "claude:session:r", state: .active)) == nil)
        #expect(DeckStore.pillAnswers(store.ask(for: asking)))
        #expect(!DeckStore.pillAnswers(CoreAsk(session: "claude:x", summary: "Run", answerable: false)))
        #expect(!DeckStore.pillAnswers(CoreAsk(session: "remote:studio:claude:x", summary: "Run", answerable: true)))
        #expect(!DeckStore.pillAnswers(nil))
    }

}
