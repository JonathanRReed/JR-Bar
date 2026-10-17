import Foundation
import Testing
import JRBarCore
@testable import JRBarApp

/// The ask face for the keyboard and VoiceOver. The rule every test here
/// guards: no key answers an ask by itself. Engaging focuses nothing,
/// Return does nothing until a person has moved onto a verb, Esc only
/// lets go, and an ask that goes away takes the keyboard with it.
@Suite("Notch ask keyboard")
@MainActor
struct NotchAskKeyboardTests {
    private static let session = "claude:s1"

    // MARK: The pure focus

    private let order: [NotchAskVerbKey] = [.deny, .approve, .open]

    @Test("a fresh focus rests on nothing, and Return and Space press nothing")
    func freshFocusPressesNothing() {
        var focus = NotchAskFocus()
        #expect(focus.focused == nil)
        #expect(focus.handle(.activate, order: order) == .ignored)
        #expect(focus.focused == nil)
    }

    @Test("forward lands on the first verb, back on the last, and both wrap")
    func movesAndWraps() {
        var forward = NotchAskFocus()
        #expect(forward.handle(.tab, order: order) == .moved)
        #expect(forward.focused == .deny)
        _ = forward.handle(.right, order: order)
        #expect(forward.focused == .approve)
        _ = forward.handle(.down, order: order)
        #expect(forward.focused == .open)
        _ = forward.handle(.tab, order: order)
        #expect(forward.focused == .deny, "the ring wraps from the last verb to the first")

        var back = NotchAskFocus()
        _ = back.handle(.backTab, order: order)
        #expect(back.focused == .open)
        _ = back.handle(.left, order: order)
        #expect(back.focused == .approve)
        _ = back.handle(.up, order: order)
        #expect(back.focused == .deny)
        _ = back.handle(.up, order: order)
        #expect(back.focused == .open)
    }

    @Test("Return presses only the verb the ring is on")
    func pressesTheFocusedVerb() {
        var focus = NotchAskFocus()
        _ = focus.handle(.tab, order: order)
        _ = focus.handle(.tab, order: order)
        #expect(focus.handle(.activate, order: order) == .press(.approve))
    }

    @Test("Esc lets go and never presses, whatever the ring is on")
    func escapeNeverPresses() {
        var focus = NotchAskFocus()
        _ = focus.handle(.tab, order: order)
        #expect(focus.handle(.escape, order: order) == .release)
        #expect(focus.focused == nil)
        #expect(focus.handle(.activate, order: order) == .ignored)
    }

    @Test("a verb that goes away takes its focus with it")
    func vanishedVerbDropsFocus() {
        var focus = NotchAskFocus()
        _ = focus.handle(.backTab, order: order)
        #expect(focus.focused == .open)
        // Return after the verb is gone must press nothing.
        #expect(focus.handle(.activate, order: [.deny, .approve]) == .ignored)
        #expect(focus.focused == nil)
    }

    @Test("other keys and an empty face do nothing")
    func otherKeysAreSpent() {
        var focus = NotchAskFocus()
        #expect(focus.handle(.other, order: order) == .ignored)
        #expect(focus.handle(.tab, order: []) == .ignored)
        #expect(focus.focused == nil)
    }

    @Test("Mac key codes map onto the keys the face listens for")
    func keyCodes() {
        #expect(NotchAskFocus.key(forKeyCode: 48, shift: false) == .tab)
        #expect(NotchAskFocus.key(forKeyCode: 48, shift: true) == .backTab)
        #expect(NotchAskFocus.key(forKeyCode: 123, shift: false) == .left)
        #expect(NotchAskFocus.key(forKeyCode: 124, shift: false) == .right)
        #expect(NotchAskFocus.key(forKeyCode: 125, shift: false) == .down)
        #expect(NotchAskFocus.key(forKeyCode: 126, shift: false) == .up)
        for code: UInt16 in [36, 76, 49] {
            #expect(NotchAskFocus.key(forKeyCode: code, shift: false) == .activate)
        }
        #expect(NotchAskFocus.key(forKeyCode: 53, shift: false) == .escape)
        #expect(NotchAskFocus.key(forKeyCode: 0, shift: false) == .other)
    }

    @Test("every verb has a name and a hint for VoiceOver")
    func verbsAreSpoken() {
        let verbs: [NotchAskVerbKey] = [.deny, .always, .approve, .open, .choice("Yes")]
        for verb in verbs {
            #expect(!verb.title.isEmpty)
            #expect(!NotchIslandView.askHint(verb).isEmpty, "\(verb) has no hint")
        }
        #expect(Set(verbs.map(\.title)).count == verbs.count, "no two verbs sound alike")
        #expect(NotchAskVerbKey.choice("Use Postgres").title == "Use Postgres")
    }

    // MARK: The plan

    private func ask(answerable: Bool = true, decision: CoreAskDecision? = nil,
                     replyable: Bool? = nil) -> CoreAsk {
        CoreAsk(session: Self.session, openedAt: 1, summary: "Run tests", answerable: answerable,
                replyable: replyable, request: "r1", decision: decision)
    }

    private func plan(_ live: CoreAsk?, session: String? = NotchAskKeyboardTests.session,
                      hasDesk: Bool = true) -> [NotchAskVerbKey] {
        NotchAskVerbPlan.verbs(live: live, verbs: NotchAskVerbs.resolve(live: live, session: session),
                               session: session, hasDesk: hasDesk)
    }

    @Test("an answerable ask offers Deny, Approve and Open in the order they stand")
    func plainPlan() {
        #expect(plan(ask()) == [.deny, .approve, .open])
    }

    @Test("Always allow stands between Deny and Approve while the hook holds one")
    func alwaysPlan() {
        #expect(plan(ask(decision: CoreAskDecision(always: true))) == [.deny, .always, .approve, .open])
    }

    @Test("a held question lists Deny and its options, a folded menu is not a button")
    func questionPlan() {
        let two = CoreAskChoice(question: "Which?", options: ["A", "B"])
        #expect(plan(ask(decision: CoreAskDecision(choices: [two]))) == [.deny, .choice("A"), .choice("B"), .open])
        let many = CoreAskChoice(question: "Which?", options: ["One", "Two", "Three", "Four"])
        #expect(plan(ask(decision: CoreAskDecision(choices: [many]))) == [.deny, .open])
    }

    @Test("what the daemon cannot deliver is never on the plan")
    func refusedPlans() {
        #expect(plan(ask(answerable: false)) == [.open], "Open only")
        #expect(plan(ask(replyable: true)) == [.open], "a typed reply is for the terminal")
        #expect(plan(ask(), hasDesk: false) == [.open], "no desk, no answer")
        #expect(plan(ask(decision: CoreAskDecision(decided: true))).isEmpty, "answered: nothing is asked")
        #expect(plan(ask(), session: "remote:studio-mac:s1").isEmpty, "a peer's ask can be neither answered nor raised")
        #expect(plan(nil) == [.open], "not in the state yet: Open only, never a guessed Approve")
    }

    // MARK: The toy

    private final class Sent {
        var answers: [(String, AskVerdict, String?)] = []
    }

    private func makeToy(state: CoreState? = nil) -> (NotchToy, ToysStore, Sent, ManualTimers) {
        var toys = ToysState()
        toys.notch = NotchSettings(enabled: true, provider: .jrbar, islandEnabled: true)
        let core = CoreModel()
        if let state { core.apply(.state(state)) }
        let store = ToysStore(core: core, settings: SettingsStore(core: core),
                              state: toys, cardModel: makeTestCardModel(),
                              notchRuntimeEnabled: false)
        let toy: NotchToy = store.notch
        toy.islandVisible = true
        let sent = Sent()
        let desk = AskAnswerDesk(send: { session, verdict, request in
            sent.answers.append((session, verdict, request))
            return CoreReply(id: "1", ok: true)
        })
        let timers = ManualTimers.driving(toy)
        desk.noteTimer = { delay, work in timers.arm(delay, work) }
        desk.onAnswered = { [weak toy] session, request in toy?.resolveAsk(session: session, request: request) }
        toy.cardModel.askDesk = { desk }
        return (toy, store, sent, timers)
    }

    private func state(decision: CoreAskDecision? = nil) -> CoreState {
        var live = CoreAsk(session: Self.session, openedAt: 1, summary: "Run tests",
                           answerable: true, request: "r1")
        live.decision = decision
        return CoreState(sessions: [CoreSession(id: Self.session, provider: "claude", label: "rename-the-fish",
                                                ask: CoreAsk(summary: "Run tests"))],
                         asks: [live])
    }

    private func notice() -> AlcoveNotice {
        AlcoveNotice(id: "a", kind: .ask, title: "Claude · rename-the-fish", subtitle: "Run tests",
                     session: Self.session, key: "ask:\(Self.session)|r1",
                     ask: CoreAsk(session: Self.session, summary: "Run tests", request: "r1"))
    }

    @Test("engaging takes the keyboard and focuses nothing")
    func engageFocusesNothing() {
        let (toy, store, sent, _) = makeToy(state: state())
        defer { withExtendedLifetime(store) {} }
        toy.offer(notice())
        #expect(toy.engageAskKeyboard())
        #expect(toy.askKeyboardEngaged)
        #expect(toy.askFocus.focused == nil)
        toy.askKey(.activate)
        toy.askKey(.activate)
        #expect(sent.answers.isEmpty, "Return with the ring nowhere answers nothing")
        #expect(toy.activeCapsule?.id == "a")
    }

    @Test("there is nothing to engage without an ask on the face")
    func nothingToEngage() {
        let (toy, store, _, _) = makeToy(state: state())
        defer { withExtendedLifetime(store) {} }
        #expect(!toy.engageAskKeyboard(), "no capsule")
        toy.offer(AlcoveNotice(id: "n", kind: .completed, title: "Claude · t", subtitle: "finished",
                               key: "completed:n"))
        #expect(!toy.engageAskKeyboard(), "news is not an ask")
        #expect(!toy.askKeyboardEngaged)
    }

    @Test("Tab then Return presses the focused verb through the desk with the request pin")
    func keyboardAnswersOnPurpose() async {
        let (toy, store, sent, _) = makeToy(state: state())
        defer { withExtendedLifetime(store) {} }
        toy.offer(notice())
        toy.engageAskKeyboard()
        toy.askKey(.tab)
        #expect(toy.askFocus.focused == .deny)
        toy.askKey(.right)
        #expect(toy.askFocus.focused == .approve)
        // The answer is in flight on a task; the key returns it.
        await toy.askKey(.activate)?.value
        #expect(sent.answers.first?.1 == .approve)
        #expect(sent.answers.first?.2 == "r1")
    }

    @Test("Esc lets the keyboard go and denies nothing")
    func escapeLeavesTheAskAlone() {
        let (toy, store, sent, _) = makeToy(state: state())
        defer { withExtendedLifetime(store) {} }
        toy.offer(notice())
        toy.engageAskKeyboard()
        toy.askKey(.tab)
        toy.askKey(.escape)
        #expect(!toy.askKeyboardEngaged)
        #expect(toy.askFocus.focused == nil)
        #expect(sent.answers.isEmpty)
        #expect(toy.activeCapsule?.id == "a", "the ask is still up, still waiting for a person")
        toy.askKey(.activate)
        #expect(sent.answers.isEmpty, "a key after the keyboard went is not an answer")
    }

    @Test("an ask answered elsewhere takes the keyboard with it")
    func resolvedReleases() {
        let (toy, store, sent, _) = makeToy(state: state())
        defer { withExtendedLifetime(store) {} }
        toy.offer(notice())
        toy.engageAskKeyboard()
        toy.askKey(.tab)
        toy.resolveAsk(session: Self.session, request: "r1")
        #expect(toy.activeCapsule == nil)
        #expect(!toy.askKeyboardEngaged)
        #expect(toy.askFocus.focused == nil)
        toy.askKey(.activate)
        #expect(sent.answers.isEmpty)
    }

    @Test("a keyboard nobody uses lets go by itself")
    func idleReleases() {
        let (toy, store, sent, timers) = makeToy(state: state())
        defer { withExtendedLifetime(store) {} }
        toy.offer(notice())
        toy.engageAskKeyboard()
        timers.advance(by: NotchToy.askKeyIdle - 1)
        #expect(toy.askKeyboardEngaged)
        toy.askKey(.tab)
        timers.advance(by: NotchToy.askKeyIdle - 1)
        #expect(toy.askKeyboardEngaged, "a key keeps it for another stretch")
        timers.advance(by: 2)
        #expect(!toy.askKeyboardEngaged)
        #expect(sent.answers.isEmpty)
    }

    @Test("a verb no longer on the face cannot be pressed from any door")
    func staleVerbRefused() {
        let (toy, store, sent, _) = makeToy(state: state())
        defer { withExtendedLifetime(store) {} }
        toy.offer(notice())
        #expect(toy.performAskVerb(.always) == nil, "the ask offered no rule")
        #expect(toy.performAskVerb(.choice("A")) == nil)
        #expect(sent.answers.isEmpty)
    }

    @Test("a held question's option is picked through the same door")
    func optionThroughTheDoor() async {
        let choice = CoreAskChoice(question: "Which?", options: ["A", "B"])
        let (toy, store, sent, _) = makeToy(state: state(decision: CoreAskDecision(choices: [choice])))
        defer { withExtendedLifetime(store) {} }
        toy.offer(notice())
        let order = toy.askKeyVerbs(for: toy.activeCapsule!)
        #expect(order == [.deny, .choice("A"), .choice("B"), .open])
        _ = toy.performAskVerb(.choice("B"))
        // `pick` records the choice and sends it; give the desk its task.
        for _ in 0..<50 where sent.answers.isEmpty { await Task.yield() }
        #expect(sent.answers.first?.0 == Self.session)
    }
}
