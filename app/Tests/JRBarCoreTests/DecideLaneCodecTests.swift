import Foundation
import Testing
@testable import JRBarCore

/// `ask.decision`, `ask.preview` and `ask.risk`: the decide lane's facts on
/// an ask the agent's own PermissionRequest hook is holding for JR-Bar
/// (docs/CORE-PROTOCOL.md, "The decide lane").
@Suite("Decide lane ask fields")
struct DecideLaneCodecTests {
    private func ask(_ json: String) throws -> CoreAsk {
        try JSONDecoder().decode(CoreAsk.self, from: Data(json.utf8))
    }

    @Test("a held ask decodes its hold, preview and risk mark")
    func heldAsk() throws {
        let held = try ask("""
        {"session":"claude:session:a","kind":"permission","opened_at":1788982800.0,
         "summary":"Bash","answerable":true,"replyable":false,"request":"request:v1:x",
         "decision":{"hold_until":1788982845.5,"always":true,"decided":false},
         "preview":"rm -rf build","risk":"destructive"}
        """)
        #expect(held.canAnswer)
        #expect(held.isHeldForDecision)
        #expect(held.canAlwaysAllow)
        #expect(held.isDestructive)
        #expect(held.preview == "rm -rf build")
        #expect(held.decision?.holdUntil == 1788982845.5)
    }

    @Test("an answered hold no longer offers anything")
    func decidedAsk() throws {
        let answered = try ask("""
        {"session":"s","answerable":true,"decision":{"hold_until":1.0,"always":true,"decided":true},
         "preview":null,"risk":null}
        """)
        #expect(!answered.isHeldForDecision)
        #expect(!answered.canAlwaysAllow)
        #expect(!answered.isDestructive)
    }

    @Test("a hold lapses at hold_until; one with no deadline, or none at all, reads as before")
    func holdLapses() throws {
        let held = try ask("""
        {"session":"s","answerable":true,"decision":{"hold_until":1788982845.5,"always":true,"decided":false}}
        """)
        let deadline = Date(timeIntervalSince1970: 1788982845.5)
        #expect(held.isHeld(at: deadline.addingTimeInterval(-44.5)))
        #expect(held.isHeld(at: deadline.addingTimeInterval(-0.001)))
        #expect(!held.isHeld(at: deadline), "the hold is over the moment hold_until comes")
        #expect(!held.isHeld(at: deadline.addingTimeInterval(60)))
        #expect(held.isHeldForDecision, "the daemon's word is unchanged; only the clock says it lapsed")

        let open = try ask(#"{"session":"s","decision":{"always":false,"decided":false}}"#)
        #expect(open.isHeld(at: deadline.addingTimeInterval(86_400)), "no deadline: held until decided")
        let decided = try ask(#"{"session":"s","decision":{"hold_until":1788982845.5,"decided":true}}"#)
        #expect(!decided.isHeld(at: deadline.addingTimeInterval(-10)))
        let plain = try ask(#"{"session":"s","answerable":true}"#)
        #expect(!plain.isHeld(at: deadline))
    }

    @Test("an older daemon, or an ask the lane does not hold, reads as before")
    func unheldAsk() throws {
        let plain = try ask(#"{"session":"s","kind":"input","answerable":false,"replyable":true}"#)
        #expect(plain.decision == nil)
        #expect(!plain.isHeldForDecision)
        #expect(!plain.canAlwaysAllow)
        #expect(plain.preview == nil)
        let nulls = try ask(#"{"session":"s","decision":null,"preview":null,"risk":null}"#)
        #expect(nulls.decision == nil && nulls.risk == nil)
        // A malformed hold never takes the ask down with it.
        let odd = try ask(#"{"session":"s","answerable":true,"decision":"soon"}"#)
        #expect(odd.decision == nil)
        #expect(odd.canAnswer)
    }

    @Test("a held question decodes its choices, and only a held one offers them")
    func heldChoices() throws {
        let question = try ask("""
        {"session":"claude:session:a","kind":"input","answerable":false,"replyable":false,
         "decision":{"hold_until":1788982845.0,"always":false,"decided":false,
                     "choices":[{"question":"Which framework?","header":"Framework",
                                 "options":["React","Vue"],"multi":false},
                                {"question":"Which extras?","header":null,
                                 "options":["Tests","Docs"],"multi":true}]},
         "preview":"Which framework? +1","risk":null}
        """)
        #expect(question.canChoose)
        #expect(!question.canAnswer)
        #expect(question.decision?.choices.count == 2)
        #expect(question.decision?.choices.first == CoreAskChoice(question: "Which framework?", header: "Framework",
                                                                   options: ["React", "Vue"]))
        #expect(question.decision?.choices.last?.multi == true)
        #expect(question.decision?.choices.last?.header == nil)

        let answered = try ask("""
        {"session":"s","decision":{"hold_until":1.0,"decided":true,
         "choices":[{"question":"q","options":["a"],"multi":false}]}}
        """)
        #expect(!answered.canChoose)
        // A yes/no hold, an older daemon, or a malformed list offers no choices.
        let yesNo = try ask(#"{"session":"s","decision":{"hold_until":1.0,"always":false,"decided":false}}"#)
        #expect(yesNo.decision?.choices == [])
        #expect(!yesNo.canChoose)
        let odd = try ask(#"{"session":"s","decision":{"hold_until":1.0,"choices":"React"}}"#)
        #expect(odd.isHeldForDecision)
        #expect(!odd.canChoose)
    }

    @Test("the fields survive a round trip")
    func roundTrip() throws {
        let original = CoreAsk(session: "s", kind: "permission", answerable: true, request: "r",
                               decision: CoreAskDecision(holdUntil: 12.5, always: false, decided: false),
                               preview: "npm test", risk: nil)
        let decoded = try JSONDecoder().decode(CoreAsk.self, from: JSONEncoder().encode(original))
        #expect(decoded == original)
        let choosing = CoreAsk(session: "s", kind: "input", answerable: false,
                               decision: CoreAskDecision(holdUntil: 3, choices: [
                                   CoreAskChoice(question: "Which?", header: "Pick", options: ["A", "B"], multi: true),
                               ]))
        let back = try JSONDecoder().decode(CoreAsk.self, from: JSONEncoder().encode(choosing))
        #expect(back == choosing)
        #expect(back.canChoose)
    }
}
