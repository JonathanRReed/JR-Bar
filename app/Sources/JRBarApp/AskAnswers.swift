import Foundation
import JRBarCore
import Observation

/// Answering an ask, the same everywhere it can be answered — the
/// panel's ask rows, the notch's capsule and card rows, the palette,
/// the Dock preview, the Rail's pill and a banner's Approve or Deny.
/// What each surface may offer
/// is read off the ask alone (`AskVerbs`), what a click sends is one
/// `AskVerdict`, and what the person is told afterwards is one line
/// (`AskAnswerLine`) that says how the answer went: through the agent's
/// own permission hook, or typed into its terminal.
///
/// Nothing here answers on its own. Every verdict starts from an
/// explicit click, and Always allow only ever from its own button.

/// One explicit answer to an ask.
enum AskVerdict: Equatable, Sendable {
    case approve
    case deny
    /// The decide lane's Always allow: the agent's own offered allow
    /// rule, remembered by the agent. Only while `canAlwaysAllow`.
    case always
    /// A held question's picks, as `answer_ask` takes them: the question
    /// text → one label, or a list of labels for a multi-select.
    case choose([String: JSONValue])
    /// Words for an ask that wants them (`wantsTextReply`), typed into
    /// the session as `reply_text` on an approving `answer_ask`.
    case reply(String)

    /// The `answer_ask` decision word.
    var decision: String {
        switch self {
        case .approve, .reply: return "approve"
        case .deny: return "deny"
        case .always: return "always"
        case .choose: return "answer"
        }
    }

    /// The `answers` a pick carries; nil for the bare verdicts.
    var answers: [String: JSONValue]? {
        if case .choose(let answers) = self { return answers }
        return nil
    }
}

/// Which verbs an ask can take from outside its own window — read off
/// the daemon's flags, never guessed. A peer's ask takes none of them;
/// callers check `CoreSession.isRemoteID` before this.
enum AskVerbs {
    /// Approve where the daemon can deliver a yes. Never on a held
    /// question: a bare allow answers nothing there — its options do.
    static func approves(_ ask: CoreAsk) -> Bool {
        ask.canAnswer && !ask.wantsTextReply && !ask.canChoose
    }

    /// Deny wherever Approve is, and on a held question too: the hook
    /// declines it the way Esc does, whatever hosts the session.
    static func denies(_ ask: CoreAsk) -> Bool {
        (ask.canAnswer && !ask.wantsTextReply) || ask.canChoose
    }

    /// Always allow, only while the hook holds an ask that offers it.
    static func alwaysAllows(_ ask: CoreAsk) -> Bool {
        ask.canAlwaysAllow && !ask.canChoose
    }

    /// A held question's options can be picked.
    static func chooses(_ ask: CoreAsk) -> Bool { ask.canChoose }

    /// A typed reply, where the ask wants words and the daemon can take
    /// them.
    static func replies(_ ask: CoreAsk) -> Bool { ask.canAnswer && ask.wantsTextReply }

    /// Whether `verdict` may be sent for `ask` at all — the desk's gate,
    /// the same one the buttons are drawn behind. A pick must name every
    /// question with labels the agent offered; a reply must say something.
    static func allows(_ verdict: AskVerdict, on ask: CoreAsk) -> Bool {
        switch verdict {
        case .approve: return approves(ask)
        case .deny: return denies(ask)
        case .always: return alwaysAllows(ask)
        case .choose(let answers):
            guard chooses(ask), let choices = ask.decision?.choices else { return false }
            return AskChoicePicks(answers: answers, choices: choices)?.isComplete(choices) ?? false
        case .reply(let text):
            return replies(ask) && !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
    }

    /// Why `allows` said no, in the words of the button that was clicked:
    /// a held question wants one of its options, an Always allow needs a
    /// rule the agent offered, a reply needs words. Anything else is the
    /// session's own window.
    static func refusal(_ verdict: AskVerdict, on ask: CoreAsk) -> String {
        switch verdict {
        case .approve, .always:
            if chooses(ask) { return "Pick one of its options" }
            if case .always = verdict, approves(ask) {
                return "This one has no rule to remember — approve it once instead"
            }
        case .choose:
            if chooses(ask) { return "Pick an answer for every question first" }
        case .reply:
            if replies(ask) { return "Type a reply first" }
        case .deny:
            break
        }
        return "Answer this one in the session's window"
    }

    /// Any verb at all to draw beside the ask.
    static func any(_ ask: CoreAsk) -> Bool {
        approves(ask) || denies(ask) || alwaysAllows(ask) || chooses(ask)
    }
}

/// A held question's picks so far: question text → the labels picked.
/// A single-pick question holds one label (a second pick replaces it),
/// a multi-select any number (a second pick of the same label takes it
/// back). What goes on the wire keeps the agent's own option order.
struct AskChoicePicks: Equatable, Sendable {
    private(set) var picked: [String: [String]] = [:]

    init() {}

    /// Picks read back from a verdict's `answers` — nil when a label is
    /// not one the question offers or a question is not the agent's.
    init?(answers: [String: JSONValue], choices: [CoreAskChoice]) {
        for (question, value) in answers {
            guard let choice = choices.first(where: { $0.question == question }) else { return nil }
            let labels: [String]
            if let one = value.stringValue {
                labels = [one]
            } else if let many = value.arrayValue?.compactMap(\.stringValue), choice.multi {
                labels = many
            } else {
                return nil
            }
            guard !labels.isEmpty, labels.allSatisfy(choice.options.contains) else { return nil }
            picked[question] = labels
        }
    }

    func labels(for choice: CoreAskChoice) -> [String] { picked[choice.question] ?? [] }

    func isPicked(_ label: String, in choice: CoreAskChoice) -> Bool {
        labels(for: choice).contains(label)
    }

    /// A label only the question offers counts; anything else is ignored.
    mutating func toggle(_ label: String, in choice: CoreAskChoice) {
        guard choice.options.contains(label) else { return }
        var labels = picked[choice.question] ?? []
        if choice.multi {
            if let index = labels.firstIndex(of: label) { labels.remove(at: index) } else { labels.append(label) }
        } else {
            labels = labels == [label] ? [] : [label]
        }
        picked[choice.question] = labels.isEmpty ? nil : labels
    }

    /// How many of `choices` have a pick.
    func answered(_ choices: [CoreAskChoice]) -> Int {
        choices.filter { !labels(for: $0).isEmpty }.count
    }

    /// Every question has a pick — the daemon refuses anything less.
    func isComplete(_ choices: [CoreAskChoice]) -> Bool {
        !choices.isEmpty && answered(choices) == choices.count
    }

    /// `answer_ask`'s `answers`: a label for a single pick, the labels in
    /// the agent's option order for a multi-select. nil until complete.
    func answers(_ choices: [CoreAskChoice]) -> [String: JSONValue]? {
        guard isComplete(choices) else { return nil }
        var out: [String: JSONValue] = [:]
        for choice in choices {
            let labels = labels(for: choice)
            if choice.multi {
                out[choice.question] = .array(choice.options.filter(labels.contains).map(JSONValue.string))
            } else if let label = labels.first {
                out[choice.question] = .string(label)
            }
        }
        return out
    }

    /// The verdict a single click on `label` is, when that click is the
    /// whole answer: one single-pick question. nil when it only adds to
    /// the picks (several questions, a multi-select).
    static func oneClick(_ label: String, choices: [CoreAskChoice]) -> AskVerdict? {
        guard choices.count == 1, let choice = choices.first, !choice.multi,
              choice.options.contains(label) else { return nil }
        return .choose([choice.question: .string(label)])
    }
}

/// How a held question's options fit a row.
enum AskChoiceLayout: Equatable {
    /// One single-pick question with a few short labels: a button each,
    /// and a click is the answer.
    case buttons([String])
    /// Anything more — several questions, a multi-select, many or long
    /// labels: one menu that holds them.
    case menu

    static func layout(_ choices: [CoreAskChoice], maxButtons: Int = 3,
                       maxCharacters: Int = 30) -> AskChoiceLayout {
        guard choices.count == 1, let choice = choices.first, !choice.multi,
              (1...maxButtons).contains(choice.options.count),
              choice.options.reduce(0, { $0 + $1.count }) <= maxCharacters else { return .menu }
        return .buttons(choice.options)
    }

    /// The menu's own title — what it will do.
    static func menuTitle(_ choices: [CoreAskChoice], picks: AskChoicePicks) -> String {
        if choices.count == 1, choices.first?.multi == false { return "Choose…" }
        let done = picks.answered(choices)
        return done == 0 ? "Answer…" : "Answer (\(done)/\(choices.count))"
    }
}

/// The line an answer earns, where the click happened.
enum AskAnswerLine {
    /// `mechanism: "permission_hook"` — the agent's own hook took it.
    static let hookPhrase = "sent through the agent's permission hook"
    /// `synthetic_keystroke` / `synthetic_text` — typed into the session.
    static let terminalPhrase = "typed into the terminal"

    /// How the reply says the answer went; nil for a daemon that does
    /// not say (the line then claims nothing about the route).
    static func how(_ reply: CoreReply) -> String? {
        switch reply.result?["mechanism"]?.stringValue {
        case "permission_hook": return hookPhrase
        case "synthetic_keystroke", "synthetic_text": return terminalPhrase
        default: return nil
        }
    }

    /// "Approved · sent through the agent's permission hook".
    static func sent(_ verdict: AskVerdict, reply: CoreReply) -> String {
        let what: String
        switch verdict {
        case .approve: what = "Approved"
        case .deny: what = "Denied"
        case .always: what = "Always allowed"
        case .choose(let answers):
            if answers.count == 1, let label = answers.values.first?.stringValue {
                what = "Answered “\(label)”"
            } else {
                what = "Answered"
            }
        case .reply: return replied(reply)
        }
        return how(reply).map { "\(what) · \($0)" } ?? what
    }

    /// A typed reply that went out.
    static func replied(_ reply: CoreReply) -> String {
        "Reply sent · \(how(reply) ?? terminalPhrase)"
    }
}

/// The answer desk every surface shares — the panel's verbs and its
/// reply field and a banner's Approve and Deny send here, and so do the
/// notch, the Dock preview and the Rail's Always allow and picks — so
/// one pending set dims every copy of an ask's buttons while its answer
/// is on the wire and a multi-question pick started in one place
/// finishes in another. The panel owns it; the app delegate publishes
/// it as `shared`.
@MainActor
@Observable
final class AskAnswerDesk {
    /// The panel's desk, published by the app delegate. nil draws none
    /// of the desk's verbs — a surface without it offers what it always
    /// did.
    static var shared: AskAnswerDesk?

    /// How long a line stays under its ask.
    static let noteLife: TimeInterval = 4

    struct Note: Equatable {
        let text: String
        /// A refusal: the ask is still open.
        let refused: Bool
    }

    struct Outcome: Equatable {
        let ok: Bool
        let line: String
        /// The daemon's refusal code, for a surface that can offer the
        /// fix (the panel's "Open Settings" on `accessibility_required`).
        var code: String? = nil
    }

    /// The daemon call — `CoreModel.answerAskNow(session:decision:…)` in
    /// production; tests stage the reply.
    @ObservationIgnored var send: @MainActor (_ session: String, _ verdict: AskVerdict,
                                              _ request: String?) async throws -> CoreReply
    /// A verdict the daemon took — the notch steps its capsule down now
    /// rather than waiting for `ask_resolved`.
    @ObservationIgnored var onAnswered: @MainActor (_ session: String, _ request: String?) -> Void = { _, _ in }

    /// Sessions with an answer in flight.
    private(set) var pending: Set<String> = []
    /// Session → the last answer's line.
    private(set) var notes: [String: Note] = [:]
    /// Ask (by its request pin) → the picks so far.
    private(set) var picks: [String: AskChoicePicks] = [:]
    @ObservationIgnored private var noteTokens: [String: UUID] = [:]

    init(send: @escaping @MainActor (String, AskVerdict, String?) async throws -> CoreReply) {
        self.send = send
    }

    /// A reply rides `reply_text` on an approving `answer_ask`; every
    /// other verdict is its decision word.
    convenience init(core: CoreModel) {
        self.init(send: { [weak core] session, verdict, request in
            guard let core else { throw CoreClientError.notConnected }
            if case .reply(let text) = verdict {
                return try await core.answerAskNow(session: session, approve: true, replyText: text,
                                                   request: request)
            }
            return try await core.answerAskNow(session: session, decision: verdict.decision,
                                               answers: verdict.answers, request: request)
        })
    }

    func isPending(_ session: String?) -> Bool { session.map(pending.contains) ?? false }
    func note(for session: String?) -> Note? { session.flatMap { notes[$0] } }

    private static func pickKey(_ ask: CoreAsk) -> String { ask.request ?? ask.id }

    func picks(for ask: CoreAsk) -> AskChoicePicks { picks[Self.pickKey(ask)] ?? AskChoicePicks() }

    /// Adds or takes back one label — nothing is sent.
    func toggle(_ label: String, in choice: CoreAskChoice, of ask: CoreAsk) {
        var current = picks(for: ask)
        current.toggle(label, in: choice)
        picks[Self.pickKey(ask)] = current
        // A pick for an ask that has since gone is clutter.
        if picks.count > 16 { picks = picks.filter { $0.key == Self.pickKey(ask) } }
    }

    /// The collected picks, sent — refused here when a question has none.
    @discardableResult
    func sendPicks(for ask: CoreAsk) async -> Outcome {
        guard let choices = ask.decision?.choices, let answers = picks(for: ask).answers(choices) else {
            let line = "Pick an answer for every question first"
            return Outcome(ok: false, line: line)
        }
        return await answer(ask, .choose(answers))
    }

    /// Why `verdict` would be refused before anything is sent — no
    /// session, a peer's ask, a verb the ask cannot take here, or an
    /// answer for the session already on its way; nil when it may go.
    /// A surface can say it at once, without waiting on a send.
    func refusal(_ ask: CoreAsk, _ verdict: AskVerdict) -> String? {
        guard let session = ask.session, !session.isEmpty else { return Self.noSession }
        if CoreSession.isRemoteID(session) {
            return "Runs on \(CoreSession.remoteMachine(inID: session) ?? "another Mac") — answer it there"
        }
        guard AskVerbs.allows(verdict, on: ask) else { return AskVerbs.refusal(verdict, on: ask) }
        return pending.contains(session) ? "An answer is already on its way" : nil
    }

    static let noSession = "This ask has no session left to answer"

    /// One verdict, from a click. Refused before any send when the ask
    /// cannot take it here or an answer for the session is already on
    /// its way; the daemon's refusal otherwise, never a guessed success.
    @discardableResult
    func answer(_ ask: CoreAsk, _ verdict: AskVerdict) async -> Outcome {
        if let line = refusal(ask, verdict) { return Outcome(ok: false, line: line) }
        guard let session = ask.session else { return Outcome(ok: false, line: Self.noSession) }
        pending.insert(session)
        defer { pending.remove(session) }
        clearNote(for: session)
        do {
            let reply = try await send(session, verdict, ask.request)
            if reply.ok {
                let line = AskAnswerLine.sent(verdict, reply: reply)
                picks[Self.pickKey(ask)] = nil
                setNote(Note(text: line, refused: false), for: session)
                onAnswered(session, ask.request)
                return Outcome(ok: true, line: line)
            }
            let line = NotchAskRefusal.line(for: reply.error)
            setNote(Note(text: line, refused: true), for: session)
            return Outcome(ok: false, line: line, code: reply.error?.code)
        } catch {
            setNote(Note(text: NotchAskRefusal.unreachable, refused: true), for: session)
            return Outcome(ok: false, line: NotchAskRefusal.unreachable)
        }
    }

    private func setNote(_ note: Note, for session: String) {
        notes[session] = note
        let token = UUID()
        noteTokens[session] = token
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.noteLife) { [weak self] in
            MainActor.assumeIsolated {
                guard let self, self.noteTokens[session] == token else { return }
                self.clearNote(for: session)
            }
        }
    }

    private func clearNote(for session: String) {
        notes[session] = nil
        noteTokens[session] = nil
    }
}
