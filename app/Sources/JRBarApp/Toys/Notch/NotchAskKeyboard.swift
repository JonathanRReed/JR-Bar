import Foundation
import JRBarCore

/// One verb on the island's ask face, named the same way by the buttons
/// the face draws, the keyboard's focus ring and VoiceOver's actions.
enum NotchAskVerbKey: Hashable, Sendable {
    case deny
    case always
    case approve
    case open
    /// One of a held question's options, by its label.
    case choice(String)

    /// What a person hears and reads for it.
    var title: String {
        switch self {
        case .deny: return "Deny"
        case .always: return "Always allow"
        case .approve: return "Approve"
        case .open: return "Open session"
        case .choice(let label): return label
        }
    }
}

/// The verbs the ask face offers right now, left to right in the order
/// the buttons stand. Read off the same rules the face draws behind
/// (`AskVerbs`, `NotchAskVerbs`), so the keyboard and VoiceOver can reach
/// exactly the buttons a pointer can and no more. A held question's
/// options past two (the face folds them into a menu) are not listed: a
/// menu is not a button the keyboard can press.
enum NotchAskVerbPlan {
    static func verbs(live: CoreAsk?, verbs: NotchAskVerbs, session: String?,
                      hasDesk: Bool, now: Date = Date()) -> [NotchAskVerbKey] {
        var plan: [NotchAskVerbKey] = []
        if let live, hasDesk, let session, !CoreSession.isRemoteID(session) {
            if AskVerbs.chooses(live, at: now) {
                plan.append(.deny)
                if let choices = live.decision?.choices,
                   case .buttons(let labels) = AskChoiceLayout.layout(choices, maxButtons: 2,
                                                                     maxCharacters: 18) {
                    plan.append(contentsOf: labels.map(NotchAskVerbKey.choice))
                }
            } else if verbs.answers, AskVerbs.approves(live) {
                plan.append(.deny)
                if AskVerbs.alwaysAllows(live, at: now) { plan.append(.always) }
                plan.append(.approve)
            }
        }
        if verbs.opens { plan.append(.open) }
        return plan
    }
}

/// Where the keyboard stands on the ask face. A pure value, so the rules
/// are proved without a window.
///
/// The one rule that matters: nothing here answers an ask by itself.
/// Space requires a focused verb. Return may approve a non-destructive ask
/// without focus. Arrows choose a verb, Tab changes asks, and Esc
/// only lets the keyboard go: it never denies, dismisses or approves.
struct NotchAskFocus: Equatable, Sendable {
    /// The keys the ask face listens for.
    enum Key: Equatable, Sendable {
        case tab, backTab, left, right, up, down
        case activate   // Return, Enter
        case space
        case escape
        case other
    }

    /// What a key did.
    enum Result: Equatable, Sendable {
        /// The focus moved (or stayed on a single verb).
        case moved
        /// The person pressed the focused verb.
        case press(NotchAskVerbKey)
        /// The keyboard lets go; nothing is answered.
        case release
        /// Not ours, or nothing to do: the key is spent, nothing happens.
        case ignored
    }

    /// The verb wearing the focus ring, nil until a person moves there.
    private(set) var focused: NotchAskVerbKey?

    /// Focus the person moved to, kept only while its verb still stands.
    mutating func reconcile(with order: [NotchAskVerbKey]) {
        if let focused, !order.contains(focused) { self.focused = nil }
    }

    mutating func handle(_ key: Key, order: [NotchAskVerbKey]) -> Result {
        reconcile(with: order)
        switch key {
        case .escape:
            focused = nil
            return .release
        case .tab, .right, .down:
            return move(by: 1, in: order)
        case .backTab, .left, .up:
            return move(by: -1, in: order)
        case .activate, .space:
            // A press needs a focus a person put there.
            guard let focused, order.contains(focused) else { return .ignored }
            return .press(focused)
        case .other:
            return .ignored
        }
    }

    private mutating func move(by step: Int, in order: [NotchAskVerbKey]) -> Result {
        guard !order.isEmpty else { return .ignored }
        guard let current = focused, let index = order.firstIndex(of: current) else {
            // From nowhere: forward lands on the first verb, back on the last.
            focused = step > 0 ? order.first : order.last
            return .moved
        }
        focused = order[(index + step + order.count) % order.count]
        return .moved
    }

    /// Forget the focus (the keyboard let go, or the ask went away).
    mutating func clear() { focused = nil }

    /// The Mac key codes the window maps onto `Key`.
    static func key(forKeyCode code: UInt16, shift: Bool) -> Key {
        switch code {
        case 48: return shift ? .backTab : .tab
        case 123: return .left
        case 124: return .right
        case 125: return .down
        case 126: return .up
        case 36, 76: return .activate
        case 49: return .space
        case 53: return .escape
        default: return .other
        }
    }
}
