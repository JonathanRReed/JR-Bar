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

    @Test("the fields survive a round trip")
    func roundTrip() throws {
        let original = CoreAsk(session: "s", kind: "permission", answerable: true, request: "r",
                               decision: CoreAskDecision(holdUntil: 12.5, always: false, decided: false),
                               preview: "npm test", risk: nil)
        let decoded = try JSONDecoder().decode(CoreAsk.self, from: JSONEncoder().encode(original))
        #expect(decoded == original)
    }
}
