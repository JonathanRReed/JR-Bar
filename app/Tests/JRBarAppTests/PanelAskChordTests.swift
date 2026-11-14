import Foundation
import Testing
@testable import JRBarApp
@testable import JRBarCore

/// ⌘↩ and ⌘D in the panel: which ask a chord answers, if any. Every input
/// is passed in, so nothing here waits on a clock, opens a window or
/// reaches a daemon.
@Suite("Panel ask chords")
@MainActor
struct PanelAskChordTests {
    private static let permission = "claude:session:perm"
    private static let second = "claude:session:next"
    private static let reply = "claude:session:reply"
    private static let choices = [CoreAskChoice(question: "Which database?", options: ["Postgres", "SQLite"])]

    private func permissionAsk(_ session: String, answerable: Bool = true) -> CoreAsk {
        CoreAsk(session: session, kind: "permission", summary: "Run a command", answerable: answerable)
    }

    private func replyAsk(_ session: String) -> CoreAsk {
        CoreAsk(session: session, kind: "input", summary: "What next?", answerable: true, replyable: true)
    }

    private func heldQuestion(_ session: String) -> CoreAsk {
        CoreAsk(session: session, kind: "permission", summary: "Which one?", answerable: true,
                decision: CoreAskDecision(always: false, decided: false, choices: Self.choices))
    }

    private func row(_ id: String, ask: CoreAsk?) -> SessionRow {
        SessionRow(session: CoreSession(id: id, provider: "claude", mode: "waiting", lifecycle: "active", ask: ask),
                   pinnedAsk: nil)
    }

    private func target(_ chord: PanelStore.AskChord, typing: Bool = false, selected: String? = nil,
                        rows: [SessionRow]) -> PanelStore.AskChordTarget {
        PanelStore.chordTarget(chord, typingInField: typing, selectedID: selected, askRows: rows)
    }

    @Test("typing in a field leaves both chords alone, whatever is open or selected")
    func typingPassesThrough() {
        let two = [row(Self.permission, ask: permissionAsk(Self.permission)),
                   row(Self.second, ask: permissionAsk(Self.second))]
        let lone = [row(Self.permission, ask: permissionAsk(Self.permission))]
        for chord in [PanelStore.AskChord.approve, .deny] {
            #expect(target(chord, typing: true, rows: two) == .none)
            #expect(target(chord, typing: true, selected: Self.second, rows: two) == .none)
            #expect(target(chord, typing: true, rows: lone) == .none)
        }
    }

    @Test("a lone approvable ask is the default for both chords")
    func loneAskIsTheDefault() {
        let lone = [row(Self.permission, ask: permissionAsk(Self.permission))]
        #expect(target(.approve, rows: lone) == .ask(id: Self.permission))
        #expect(target(.deny, rows: lone) == .ask(id: Self.permission))
    }

    @Test("two asks and nothing selected answers neither; the selected one is the only target")
    func severalNeedASelection() {
        let two = [row(Self.permission, ask: permissionAsk(Self.permission)),
                   row(Self.second, ask: permissionAsk(Self.second))]
        #expect(target(.approve, rows: two) == .ambiguous)
        #expect(target(.deny, rows: two) == .ambiguous)
        #expect(target(.approve, selected: Self.second, rows: two) == .ask(id: Self.second))
        #expect(target(.deny, selected: Self.second, rows: two) == .ask(id: Self.second))
    }

    @Test("an older permission ask is approved only when nothing else could take it, never from a reply field")
    func olderPermissionNewerReply() {
        let rows = [row(Self.permission, ask: permissionAsk(Self.permission)),
                    row(Self.reply, ask: replyAsk(Self.reply))]
        #expect(target(.approve, rows: rows) == .ask(id: Self.permission), "the reply ask is not an approver")
        #expect(target(.approve, typing: true, rows: rows) == .none, "typing in the reply field leaves the key alone")
        #expect(target(.deny, typing: true, rows: rows) == .none)
    }

    @Test("a peer's ask and one that cannot be answered from here are never candidates")
    func remoteAndUnansweredAreSkipped() {
        let remoteID = "remote:studio:claude:session:x"
        let remote = SessionRow(session: CoreSession(id: remoteID, provider: "claude", mode: "waiting",
                                                     ask: permissionAsk(remoteID), remote: true),
                                pinnedAsk: nil)
        let blocked = row(Self.second, ask: permissionAsk(Self.second, answerable: false))
        let mine = row(Self.permission, ask: permissionAsk(Self.permission))
        #expect(target(.approve, rows: [remote, blocked]) == .none)
        #expect(target(.deny, rows: [remote, blocked]) == .none)
        #expect(target(.approve, rows: [remote, blocked, mine]) == .ask(id: Self.permission))
        #expect(target(.deny, rows: [remote, blocked, mine]) == .ask(id: Self.permission))
    }

    @Test("Deny counts a held question; Approve does not")
    func heldQuestionTakesOnlyDeny() {
        let question = row(Self.second, ask: heldQuestion(Self.second))
        let plain = row(Self.permission, ask: permissionAsk(Self.permission))
        #expect(target(.deny, rows: [question]) == .ask(id: Self.second))
        #expect(target(.approve, rows: [question]) == .none)
        #expect(target(.deny, rows: [plain, question]) == .ambiguous)
        #expect(target(.approve, rows: [plain, question]) == .ask(id: Self.permission))
    }

    @Test("⌘1 and up pick a held question's option buttons, and nothing else")
    func optionKeysPickVisibleButtons() {
        let question = row(Self.second, ask: heldQuestion(Self.second))
        let plain = row(Self.permission, ask: permissionAsk(Self.permission))
        #expect(PanelStore.optionLabel(heldQuestion(Self.second), index: 0) == "Postgres")
        #expect(PanelStore.optionLabel(heldQuestion(Self.second), index: 1) == "SQLite")
        #expect(PanelStore.optionLabel(heldQuestion(Self.second), index: 2) == nil)
        #expect(PanelStore.optionLabel(permissionAsk(Self.permission), index: 0) == nil)
        #expect(target(.option(0), rows: [plain, question]) == .ask(id: Self.second), "a plain ask is no candidate")
        #expect(target(.option(2), rows: [question]) == .none, "no third button")
        #expect(target(.option(0), typing: true, rows: [question]) == .none)
        let other = row(Self.reply, ask: heldQuestion(Self.reply))
        #expect(target(.option(0), rows: [question, other]) == .ambiguous)
        #expect(target(.option(0), selected: Self.reply, rows: [question, other]) == .ask(id: Self.reply))

        // Options folded into a menu are not on screen, so no key picks them.
        let long = CoreAskChoice(question: "Which?", options: ["One", "Two", "Three", "Four"])
        let many = CoreAsk(session: Self.second, kind: "permission", summary: "Which?", answerable: true,
                           decision: CoreAskDecision(always: false, decided: false, choices: [long]))
        #expect(PanelStore.optionLabel(many, index: 0) == nil)
        let multi = CoreAskChoice(question: "Which?", options: ["One", "Two"], multi: true)
        let several = CoreAsk(session: Self.second, kind: "permission", summary: "Which?", answerable: true,
                              decision: CoreAskDecision(always: false, decided: false, choices: [multi]))
        #expect(PanelStore.optionLabel(several, index: 0) == nil)

        // A hold that has ended takes no key: the agent's own prompt carries on.
        let lapsed = CoreAsk(session: Self.second, kind: "permission", summary: "Which?", answerable: true,
                             decision: CoreAskDecision(holdUntil: 100, choices: Self.choices))
        #expect(PanelStore.optionLabel(lapsed, index: 0, now: Date(timeIntervalSince1970: 101)) == nil)
        #expect(PanelStore.optionLabel(lapsed, index: 0, now: Date(timeIntervalSince1970: 99)) == "Postgres")
    }

    @Test("a selection that is not among the shown asks is ignored")
    func straySelectionFallsToTheRule() {
        let rows = [row(Self.permission, ask: permissionAsk(Self.permission))]
        #expect(target(.approve, selected: "claude:session:plain", rows: rows) == .ask(id: Self.permission),
                "a plain row, or an ask a query filtered out, is not the target")
        let two = [row(Self.permission, ask: permissionAsk(Self.permission)),
                   row(Self.second, ask: permissionAsk(Self.second))]
        #expect(target(.approve, selected: "claude:session:plain", rows: two) == .ambiguous)
    }

    // MARK: The store's entry points

    private func liveStore(_ asks: [(String, CoreAsk)]) -> PanelStore {
        let sessions = asks.map { id, ask in
            CoreSession(id: id, provider: "claude", mode: "waiting", lifecycle: "active", ask: ask)
        }
        let (_, store) = PanelRowsMemoTests.liveStore(sessions)
        return store
    }

    @Test("with several asks and no selection, the chord says so and sends nothing")
    func storeExplainsAnAmbiguousChord() {
        let store = liveStore([(Self.permission, permissionAsk(Self.permission)),
                               (Self.second, permissionAsk(Self.second))])
        #expect(store.visibleAskRows.count == 2)
        let approved = store.approveSelectedAsk()
        #expect(approved, "the key is handled, so it is swallowed and explained")
        #expect(store.toast == PanelStore.chordAmbiguousLine)
        #expect(!store.isAnswerPending(permissionAsk(Self.permission)))
        #expect(!store.isAnswerPending(permissionAsk(Self.second)))
        store.show(toast: "cleared")
        let denied = store.denySelectedAsk()
        #expect(denied)
        #expect(store.toast == PanelStore.chordAmbiguousLine)
    }

    @Test("typing, or no ask at all, hands the key back")
    func storeLeavesTheKeyAlone() {
        let store = liveStore([(Self.permission, permissionAsk(Self.permission)),
                               (Self.second, permissionAsk(Self.second))])
        let typed = store.approveSelectedAsk(typingInField: true)
        #expect(!typed)
        #expect(store.toast == nil)
        let bare = liveStore([])
        let none = bare.denySelectedAsk()
        #expect(!none)
    }

    @Test("a selected card is the target, and the desk refuses a verdict it cannot take")
    func storeFollowsTheSelection() {
        let store = liveStore([(Self.permission, permissionAsk(Self.permission)),
                               (Self.reply, replyAsk(Self.reply))])
        for _ in 0..<3 where store.selectedID != Self.reply { store.moveSelection(by: 1) }
        #expect(store.selectedID == Self.reply)
        let resolved = PanelStore.chordTarget(.approve, typingInField: false, selectedID: store.selectedID,
                                              askRows: store.visibleAskRows)
        #expect(resolved == .ask(id: Self.reply), "the selected card wins, even one that cannot approve")
        let handled = store.approveSelectedAsk()
        #expect(handled)
        #expect(store.toast != nil, "the desk's refusal is said, and nothing is approved")
        #expect(store.toast != PanelStore.chordAmbiguousLine)
    }

    @Test("⌘2 on a lone held question answers with its second option; other numbers are handed back")
    func storeAnswersAnOptionKey() {
        let ask = heldQuestion(Self.second)
        let store = liveStore([(Self.second, ask)])
        let beyond = store.chooseSelectedAsk(option: 5)
        #expect(!beyond, "no sixth button: the key is left alone")
        let unarmed = store.chooseSelectedAsk(option: 1, armed: false)
        #expect(unarmed, "an unarmed key is swallowed")
        #expect(!store.isAnswerPending(ask))
        let typed = store.chooseSelectedAsk(option: 1, typingInField: true)
        #expect(!typed)
        let answered = store.chooseSelectedAsk(option: 1)
        #expect(answered)
        #expect(store.toast == nil, "the desk took the pick: no refusal is said")

        let plain = liveStore([(Self.permission, permissionAsk(Self.permission))])
        let nothing = plain.chooseSelectedAsk(option: 0)
        #expect(!nothing, "a yes/no ask has no numbered option")
        #expect(!plain.isAnswerPending(permissionAsk(Self.permission)))
    }

    @Test("a held key or a panel that just arrived answers nothing")
    func repeatsAndArrivalsAreNotAnswers() {
        let opened = Date(timeIntervalSince1970: 1_000)
        let later = opened.addingTimeInterval(PanelStore.chordSettle + 0.1)
        #expect(!PanelStore.chordsArmed(isRepeat: false, openedAt: opened, now: opened.addingTimeInterval(0.1)))
        #expect(PanelStore.chordsArmed(isRepeat: false, openedAt: opened, now: later))
        #expect(!PanelStore.chordsArmed(isRepeat: true, openedAt: opened, now: later.addingTimeInterval(5)),
                "a held ⌘↩ is one answer, not one per ask")
    }

    @Test("an unarmed chord is swallowed with nothing answered and nothing said; with no ask it is handed back")
    func unarmedChordAnswersNothing() {
        let store = liveStore([(Self.permission, permissionAsk(Self.permission))])
        let swallowed = store.approveSelectedAsk(armed: false)
        #expect(swallowed)
        #expect(store.toast == nil)
        #expect(!store.isAnswerPending(permissionAsk(Self.permission)))
        let bare = liveStore([])
        #expect(!bare.approveSelectedAsk(armed: false), "no ask: the key is not ours")
    }
}
