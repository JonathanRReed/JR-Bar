import AppKit
import JRBarCore

/// The ask face for a person who does not use a pointer: the keyboard and
/// VoiceOver reach the same verbs the buttons are, through one door
/// (`performAskVerb`).
///
/// Hover never takes typing from the terminal. A person asks for the keyboard (the "Show the waiting ask"
/// shortcut, `engageAskKeyboard`), and only then does the island take
/// keys: Tab and the arrows move a ring over the verbs, Return
/// presses the one the ring is on, Esc lets go. No key answers an ask by
/// itself: engaging focuses nothing, Esc never denies, and an ask that
/// goes away takes the keyboard with it (`NotchAskFocus`).
extension NotchToy {
    /// How long an engaged keyboard waits for a key before it lets go, so
    /// a person who walked away never leaves the island holding typing.
    nonisolated static let askKeyIdle: TimeInterval = 15

    /// The verbs the ask face stands right now, in order.
    func askKeyVerbs(for notice: AlcoveNotice) -> [NotchAskVerbKey] {
        NotchAskVerbPlan.verbs(live: liveAsk(for: notice), verbs: askVerbs(for: notice),
                               session: notice.session, hasDesk: cardModel.askDesk() != nil)
    }

    /// The ask capsule on screen, if the face is one.
    private var askCapsule: AlcoveNotice? {
        guard let capsule = activeCapsule, capsule.kind == .ask else { return nil }
        return capsule
    }

    /// Whether an ask face is up with a verb to reach: what the shortcut
    /// asks before it takes the keyboard rather than opening the card.
    var askKeyboardAvailable: Bool {
        guard isDrawingIsland, !foldEngaged, !islandExpanded, let capsule = askCapsule else { return false }
        return !askKeyVerbs(for: capsule).isEmpty
    }

    /// Hand the ask face the keyboard, because a person asked. Nothing is
    /// focused: they must move onto a verb before Return does anything.
    @discardableResult
    func engageAskKeyboard() -> Bool {
        guard askKeyboardAvailable else { return false }
        releaseShelfKeyboard()
        releaseGlassShelfKeyboard()
        askFocus.clear()
        askKeyboardEngaged = true
        armAskKeyIdle()
        island?.takeKeyboard()
        return true
    }

    /// Let the keyboard go back to whoever had it.
    func releaseAskKeyboard() {
        askKeyIdleWork?.cancel()
        askKeyIdleWork = nil
        askFocus.clear()
        guard askKeyboardEngaged else { return }
        askKeyboardEngaged = false
        island?.returnKeyboard()
    }

    private func armAskKeyIdle() {
        askKeyIdleWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated { self?.releaseAskKeyboard() }
        }
        askKeyIdleWork = work
        capsuleTimer(Self.askKeyIdle, work)
    }

    /// A key the island's window received while the keyboard is engaged.
    /// Every key is spent here (the window is key only because a person
    /// asked); none but a press on a focused verb does anything to the ask.
    /// The press, if one happened, is returned for tests to await.
    @discardableResult
    func askKey(_ key: NotchAskFocus.Key) -> Task<Void, Never>? {
        guard askKeyboardEngaged, let capsule = askCapsule else {
            releaseAskKeyboard()
            return nil
        }
        let order = askKeyVerbs(for: capsule)
        guard !order.isEmpty else {
            releaseAskKeyboard()
            return nil
        }
        armAskKeyIdle()
        switch askFocus.handle(key, order: order) {
        case .moved, .ignored:
            return nil
        case .release:
            releaseAskKeyboard()
            return nil
        case .press(let verb):
            return performAskVerb(verb)
        }
    }

    /// The one door every way of pressing a verb goes through: the
    /// button's click, the keyboard's Return, VoiceOver's action. It
    /// checks the verb is still on the face (a lapsed hold, an answer in
    /// flight and an ask already decided all take verbs away) and then
    /// does what the button always did.
    @discardableResult
    func performAskVerb(_ verb: NotchAskVerbKey) -> Task<Void, Never>? {
        guard let capsule = askCapsule, let session = capsule.session,
              askKeyVerbs(for: capsule).contains(verb) else { return nil }
        if verb != .open, cardModel.askDesk()?.isPending(session) == true { return nil }
        let live = liveAsk(for: capsule)
        let desk = cardModel.askDesk()
        switch verb {
        case .open:
            return openCapsuleSession()
        case .approve:
            return answerCapsule(approve: true)
        case .deny:
            if let live, let desk, AskVerbs.chooses(live) {
                return Task { _ = await desk.answer(live, .deny) }
            }
            return answerCapsule(approve: false)
        case .always:
            guard let live, let desk else { return nil }
            return Task { _ = await desk.answer(live, .always) }
        case .choice(let label):
            guard let live, let desk, let choice = live.decision?.choices.first else { return nil }
            desk.pick(label, in: choice, of: live)
            return nil
        }
    }
}
