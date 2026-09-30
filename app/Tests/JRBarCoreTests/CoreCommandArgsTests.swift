import Foundation
import Testing
@testable import JRBarCore

/// The args the app's newer command helpers put on the wire, pinned to the
/// fields docs/CORE-PROTOCOL.md documents for them.
@Suite("Core command args")
struct CoreCommandArgsTests {
    @Test("Quiet this run is a run-scoped snooze on one row")
    func quietRun() {
        let args = CoreModel.quietRunArgs(session: "claude:agent:w1", seconds: 900)
        #expect(args == [
            "session": .string("claude:agent:w1"),
            "seconds": .number(900),
            "scope": .string("run"),
        ])
        #expect(CoreModel.quietRunArgs(session: "claude:agent:w1", seconds: -5)["seconds"] == .number(0),
                "a negative length lifts it rather than meaning anything else")
    }

    @Test("an ask's explicit answer names its verb, and a choice its picks")
    func answerAsk() {
        #expect(CoreModel.answerAskArgs(session: "claude:agent:w1", decision: "deny") == [
            "session": .string("claude:agent:w1"), "decision": .string("deny"),
            "only_if_frontmost": .bool(false),
        ])
        let picked = CoreModel.answerAskArgs(session: "claude:agent:w1", decision: "answer",
                                             answers: ["Which branch?": .string("main")],
                                             request: "request:v1:{}")
        #expect(picked == [
            "session": .string("claude:agent:w1"), "decision": .string("answer"),
            "only_if_frontmost": .bool(false),
            "answers": .object(["Which branch?": .string("main")]),
            "request": .string("request:v1:{}"),
        ])
    }
}
