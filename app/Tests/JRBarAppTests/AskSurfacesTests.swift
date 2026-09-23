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

    private func verbs(_ log: Log, picks: AskChoicePicks = AskChoicePicks()) -> AgentPaletteVerbs {
        var verbs = AgentPaletteVerbs(
            open: { log.calls.append("open:\($0.id)") },
            approve: { log.calls.append("approve:\($0.request ?? "")") },
            deny: { log.calls.append("deny:\($0.request ?? "")") },
            snooze: { _, _ in }, copyPath: { _ in }, reveal: { _ in }, dismiss: { _ in }, clear: { _ in })
        verbs.alwaysAllow = { log.calls.append("always:\($0.request ?? "")") }
        verbs.pick = { label, choice, _ in log.calls.append("pick:\(choice.question):\(label)") }
        verbs.picks = { _ in picks }
        verbs.sendPicks = { log.calls.append("send:\($0.request ?? "")") }
        return verbs
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

    // MARK: Palette

    @Test("Always Allow is its own verb in the action panel, on no chord, beside Approve and Deny")
    func paletteAlways() {
        let log = Log()
        let ask = held(always: true)
        let item = AgentPaletteRows.askItem(row: row("claude:s1", ask: ask), ask: ask, now: now, verbs: verbs(log))
        let always = item.actions.first { $0.id == "always" }
        #expect(always?.title == "Always Allow")
        #expect(always.map { item.shortcut(for: $0) } == .some(nil), "remembering a rule is never a keystroke")
        #expect(item.action(for: .secondary)?.id == "approve")
        _ = always?.run()
        #expect(log.calls == ["always:r1"])
        let once = held(always: false)
        #expect(!AgentPaletteRows.askItem(row: row("claude:s1", ask: once), ask: once, now: now, verbs: verbs(log))
            .actions.contains { $0.id == "always" })
    }

    @Test("a held question lists its options by name: no Approve, Deny on ⌘D, and ⌘↩ lands on no option")
    func paletteQuestion() {
        let log = Log()
        let ask = held(choices: [Self.single], answerable: false)
        let item = AgentPaletteRows.askItem(row: row("claude:s1", ask: ask), ask: ask, now: now, verbs: verbs(log))
        #expect(!item.actions.contains { $0.id == "approve" })
        #expect(item.action(for: .command("d"))?.id == "deny")
        #expect(item.action(for: .secondary) == nil, "an answer is always picked by name")
        #expect(item.actions.filter { $0.id.hasPrefix("answer.") }.map(\.title)
                == ["Answer “Postgres”", "Answer “SQLite”"])
        #expect(item.accessibilityNote == nil, "a question answers here whatever hosts it")
        _ = item.actions.first { $0.id == "answer.1" }?.run()
        #expect(log.calls == ["pick:Which database?:SQLite"])
    }

    @Test("several parts pick with the palette up, and Send Answers appears once each has one")
    func paletteMultiPart() {
        let log = Log()
        let ask = held(choices: [Self.single, Self.multi])
        let open = AgentPaletteRows.askItem(row: row("claude:s1", ask: ask), ask: ask, now: now, verbs: verbs(log))
        let picks = open.actions.filter { $0.id.hasPrefix("pick.") }
        #expect(picks.count == 4)
        let pickingKeepsOpen = picks.allSatisfy { $0.keepsOpen }
        #expect(pickingKeepsOpen, "a pick runs with the palette up")
        #expect(!open.actions.contains { $0.id == "sendAnswers" })
        var chosen = AskChoicePicks()
        chosen.toggle("SQLite", in: Self.single)
        chosen.toggle("Tests", in: Self.multi)
        let ready = AgentPaletteRows.askItem(row: row("claude:s1", ask: ask), ask: ask, now: now,
                                             verbs: verbs(log, picks: chosen))
        #expect(ready.actions.first { $0.id == "pick.1.1" }?.title == "Unpick “Tests” · Checks")
        let send = ready.actions.first { $0.id == "sendAnswers" }
        #expect(send?.keepsOpen == false)
        _ = send?.run()
        #expect(log.calls == ["send:r1"])
    }

    @Test("the row says what would run, is found by it, and marks a destructive command")
    func paletteRisk() {
        let log = Log()
        let ask = held(preview: "rm -rf build", risk: "destructive")
        let item = AgentPaletteRows.askItem(row: row("claude:s1", ask: ask), ask: ask, now: now, verbs: verbs(log))
        #expect(item.subtitle == "Bash — rm -rf build")
        #expect(item.tags.contains(PaletteTag(text: "Destructive", tone: .alert)))
        #expect(item.accessibilityNote == AskRiskMark.help)
        #expect(PaletteRanking.rank([item], query: "rm -rf", usage: PaletteUsage(), now: now).count == 1)
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
