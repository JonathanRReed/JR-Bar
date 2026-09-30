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
}
