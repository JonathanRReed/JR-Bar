import Foundation
import Testing
import JRBarCore
@testable import JRBarApp

/// Answering an ask from any surface: which verbs an ask can take, what
/// a pick puts on the wire, what the line after it says, and the shared
/// desk that sends Always allow and a held question's answers.
@Suite("Ask answers")
@MainActor
struct AskAnswersTests {
    static let session = "claude:session:s1"

    static let single = CoreAskChoice(question: "Which database?", header: "Database",
                                      options: ["Postgres", "SQLite"])
    static let multi = CoreAskChoice(question: "Which checks?", options: ["Lint", "Tests", "Types"], multi: true)

    static func held(always: Bool = false, choices: [CoreAskChoice] = [], answerable: Bool? = true,
                     decided: Bool = false, request: String? = "r1", preview: String? = nil,
                     risk: String? = nil) -> CoreAsk {
        CoreAsk(session: session, kind: "permission", summary: "Bash", answerable: answerable,
                request: request,
                decision: CoreAskDecision(holdUntil: 2e9, always: always, decided: decided, choices: choices),
                preview: preview, risk: risk)
    }

    // MARK: Verbs

    @Test("a held ask offers Always only when the agent offered a rule, and never on a question")
    func alwaysGate() {
        #expect(AskVerbs.alwaysAllows(Self.held(always: true)))
        #expect(!AskVerbs.alwaysAllows(Self.held(always: false)))
        #expect(!AskVerbs.alwaysAllows(Self.held(always: true, decided: true)), "answered a moment ago")
        #expect(!AskVerbs.alwaysAllows(CoreAsk(session: Self.session, summary: "Bash", answerable: true)),
                "an ask the hook does not hold has nothing to remember")
        #expect(!AskVerbs.alwaysAllows(Self.held(always: true, choices: [Self.single])))
    }

    @Test("a held question trades Approve for its options and keeps Deny whatever hosts it")
    func questionVerbs() {
        let question = Self.held(choices: [Self.single], answerable: false)
        #expect(AskVerbs.chooses(question))
        #expect(!AskVerbs.approves(question), "a bare yes answers nothing")
        #expect(AskVerbs.denies(question), "the hook declines it like Esc, even from Ghostty")
        let plain = CoreAsk(session: Self.session, summary: "Bash", answerable: false)
        #expect(!AskVerbs.denies(plain) && !AskVerbs.approves(plain) && !AskVerbs.any(plain))
        let reply = CoreAsk(session: Self.session, summary: "?", answerable: true, replyable: true)
        #expect(!AskVerbs.approves(reply) && !AskVerbs.denies(reply), "a reply ask wants words")
    }

    @Test("a pick is allowed only when it names every question with offered labels")
    func pickGate() {
        let ask = Self.held(choices: [Self.single, Self.multi])
        #expect(!AskVerbs.allows(.choose(["Which database?": .string("Postgres")]), on: ask))
        #expect(AskVerbs.allows(.choose(["Which database?": .string("Postgres"),
                                         "Which checks?": .array([.string("Lint")])]), on: ask))
        #expect(!AskVerbs.allows(.choose(["Which database?": .string("MySQL"),
                                          "Which checks?": .array([.string("Lint")])]), on: ask))
        #expect(!AskVerbs.allows(.choose(["Which database?": .array([.string("Postgres"), .string("SQLite")]),
                                          "Which checks?": .array([.string("Lint")])]), on: ask),
                "two labels for a single-pick question")
    }

    // MARK: Picks

    @Test("a single-pick question holds one label; a multi-select toggles, in the agent's order on the wire")
    func picks() {
        var picks = AskChoicePicks()
        picks.toggle("Postgres", in: Self.single)
        picks.toggle("SQLite", in: Self.single)
        #expect(picks.labels(for: Self.single) == ["SQLite"])
        picks.toggle("Types", in: Self.multi)
        picks.toggle("Lint", in: Self.multi)
        picks.toggle("MySQL", in: Self.single)
        #expect(picks.labels(for: Self.single) == ["SQLite"], "an unoffered label is ignored")
        #expect(picks.isComplete([Self.single, Self.multi]))
        #expect(picks.answers([Self.single, Self.multi]) == [
            "Which database?": .string("SQLite"),
            "Which checks?": .array([.string("Lint"), .string("Types")]),
        ])
        picks.toggle("Lint", in: Self.multi)
        picks.toggle("Types", in: Self.multi)
        #expect(!picks.isComplete([Self.single, Self.multi]))
        #expect(picks.answers([Self.single, Self.multi]) == nil)
        #expect(picks.answered([Self.single, Self.multi]) == 1)
    }

    @Test("one click answers a single single-pick question; anything more only picks")
    func oneClick() {
        #expect(AskChoicePicks.oneClick("Postgres", choices: [Self.single])
                == .choose(["Which database?": .string("Postgres")]))
        #expect(AskChoicePicks.oneClick("Lint", choices: [Self.multi]) == nil)
        #expect(AskChoicePicks.oneClick("Postgres", choices: [Self.single, Self.multi]) == nil)
        #expect(AskChoicePicks.oneClick("MySQL", choices: [Self.single]) == nil)
    }

    @Test("short single-pick options are buttons; many, long or several questions are a menu")
    func layout() {
        #expect(AskChoiceLayout.layout([Self.single]) == .buttons(["Postgres", "SQLite"]))
        #expect(AskChoiceLayout.layout([Self.multi]) == .menu)
        #expect(AskChoiceLayout.layout([Self.single, Self.multi]) == .menu)
        let many = CoreAskChoice(question: "Q", options: ["a", "b", "c", "d"])
        #expect(AskChoiceLayout.layout([many]) == .menu)
        let long = CoreAskChoice(question: "Q", options: ["A very long first option", "And another long one"])
        #expect(AskChoiceLayout.layout([long]) == .menu)
        var picks = AskChoicePicks()
        #expect(AskChoiceLayout.menuTitle([Self.single], picks: picks) == "Choose…")
        #expect(AskChoiceLayout.menuTitle([Self.single, Self.multi], picks: picks) == "Answer…")
        picks.toggle("Lint", in: Self.multi)
        #expect(AskChoiceLayout.menuTitle([Self.single, Self.multi], picks: picks) == "Answer (1/2)")
    }

    // MARK: The line after

    static func reply(mechanism: String?) -> CoreReply {
        CoreReply(id: "c1", ok: true, result: .object(mechanism.map { ["mechanism": .string($0)] } ?? [:]))
    }

    @Test("Always and a pick put their own decision word on the wire, pinned; answers ride only with answer")
    func wireArgs() {
        let always = CoreModel.answerAskArgs(session: Self.session, decision: "always", request: "r1")
        #expect(always["decision"] == .string("always"))
        #expect(always["request"] == .string("r1"))
        #expect(always["answers"] == nil)
        #expect(always["only_if_frontmost"] == .bool(false))
        let answer = CoreModel.answerAskArgs(session: Self.session, decision: "answer",
                                             answers: ["Q": .string("A")], request: nil)
        #expect(answer["answers"] == .object(["Q": .string("A")]))
        #expect(answer["request"] == nil)
        let stray = CoreModel.answerAskArgs(session: Self.session, decision: "approve", answers: ["Q": .string("A")])
        #expect(stray["answers"] == nil, "a bare verdict never carries picks")
    }

    // MARK: The desk

    final class Sent {
        var calls: [(session: String, verdict: AskVerdict, request: String?)] = []
    }

    func desk(_ sent: Sent, reply: @escaping @MainActor () throws -> CoreReply) -> AskAnswerDesk {
        AskAnswerDesk(send: { session, verdict, request in
            sent.calls.append((session, verdict, request))
            return try reply()
        })
    }

    @Test("Always allow goes out once, pinned to its request, and its line names the hook")
    func deskAlways() async {
        let sent = Sent()
        var answered: [String] = []
        let desk = desk(sent) { Self.reply(mechanism: "permission_hook") }
        desk.onAnswered = { session, _ in answered.append(session) }
        let outcome = await desk.answer(Self.held(always: true), .always)
        #expect(outcome.ok)
        #expect(outcome.line == "Always allowed · sent through the agent's permission hook")
        #expect(sent.calls.count == 1)
        #expect(sent.calls.first?.verdict == .always && sent.calls.first?.request == "r1")
        #expect(answered == [Self.session], "the notch hears the answer landed")
        #expect(desk.note(for: Self.session)?.refused == false)
    }

    @Test("nothing is sent for a verb the ask cannot take, a peer's ask, or a second click")
    func deskRefusesBeforeSending() async {
        let sent = Sent()
        let desk = desk(sent) { Self.reply(mechanism: "permission_hook") }
        #expect(await desk.answer(Self.held(always: false), .always).ok == false)
        var remote = Self.held(always: true)
        remote.session = "remote:studio:claude:session:x"
        let refused = await desk.answer(remote, .always)
        #expect(!refused.ok && refused.line.contains("studio"))
        #expect(await desk.answer(Self.held(choices: [Self.single]), .choose(["Which database?": .string("MySQL")])).ok == false)
        #expect(sent.calls.isEmpty)
    }

    @Test("a refusal is the daemon's, the ask stays open, and the picks survive it")
    func deskRefusal() async {
        let sent = Sent()
        let desk = desk(sent) {
            CoreReply(id: "c", ok: false, error: CoreReplyError(code: "stale_request", message: "replaced"))
        }
        let ask = Self.held(choices: [Self.single, Self.multi])
        desk.toggle("Postgres", in: Self.single, of: ask)
        desk.toggle("Lint", in: Self.multi, of: ask)
        let outcome = await desk.sendPicks(for: ask)
        #expect(!outcome.ok)
        #expect(outcome.line == NotchAskRefusal.line(for: CoreReplyError(code: "stale_request", message: "replaced")))
        #expect(desk.note(for: Self.session)?.refused == true)
        #expect(desk.picks(for: ask).isComplete([Self.single, Self.multi]), "a refused send keeps the picks")
        #expect(sent.calls.first?.verdict == .choose(["Which database?": .string("Postgres"),
                                                      "Which checks?": .array([.string("Lint")])]))
    }

    @Test("Send Answers with a question still open sends nothing")
    func deskIncomplete() async {
        let sent = Sent()
        let desk = desk(sent) { Self.reply(mechanism: "permission_hook") }
        let ask = Self.held(choices: [Self.single, Self.multi])
        desk.toggle("Postgres", in: Self.single, of: ask)
        #expect(await desk.sendPicks(for: ask).ok == false)
        #expect(sent.calls.isEmpty)
    }

    @Test("a landed answer clears its picks; a thrown send says the monitor is away")
    func deskClearsAndUnreachable() async {
        let sent = Sent()
        let ok = desk(sent) { Self.reply(mechanism: "permission_hook") }
        let ask = Self.held(choices: [Self.multi])
        ok.toggle("Tests", in: Self.multi, of: ask)
        #expect(await ok.sendPicks(for: ask).ok)
        #expect(ok.picks(for: ask).answered([Self.multi]) == 0)
        let away = desk(sent) { throw CoreClientError.notConnected }
        let outcome = await away.answer(Self.held(always: true), .always)
        #expect(!outcome.ok && outcome.line == NotchAskRefusal.unreachable)
    }

    // MARK: The row's copy

    @Test("the preview line is dropped when it only repeats the summary")
    func previewLine() {
        #expect(Self.held(preview: "rm -rf build").previewLine == "rm -rf build")
        #expect(Self.held(preview: "  ").previewLine == nil)
        #expect(Self.held(preview: "Bash").previewLine == nil, "the summary already says it")
        #expect(Self.held(risk: "destructive").isDestructive)
    }
}
