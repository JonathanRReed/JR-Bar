import Foundation
import Testing
import JRBarCore
@testable import JRBarApp

/// The footer's hold mark: why the Mac is awake, from `state.power`.
@Suite("Awake hold mark")
struct AwakeHoldTests {
    private func power(_ json: String) throws -> CorePower {
        try JSONDecoder().decode(CorePower.self, from: Data(json.utf8))
    }

    @Test("no hold, no mark")
    func none() throws {
        #expect(PanelStore.awakeHold(power: nil, working: 2) == nil)
        #expect(PanelStore.awakeHold(power: try power(#"{"keep_awake":false}"#), working: 2) == nil)
    }

    @Test("keep-awake names the agents and when it lets go")
    func keepAwake() throws {
        let hold = try #require(PanelStore.awakeHold(power: try power(#"{"keep_awake":true}"#), working: 2))
        #expect(hold.symbol == "cup.and.saucer.fill")
        #expect(hold.text == "Keeping this Mac awake while 2 agents work; it lets go a few minutes after they stop")
        #expect(PanelStore.awakeHold(power: try power(#"{"keep_awake":true}"#), working: 1)?.text.contains("1 agent works") == true)
    }

    @Test("a closed lid held open outranks the plain hold")
    func closedLid() throws {
        let hold = try #require(PanelStore.awakeHold(
            power: try power(#"{"keep_awake":true,"closed_lid":{"policy":"agents","holding":true}}"#), working: 0))
        #expect(hold.symbol == "laptopcomputer")
        #expect(hold.text.hasPrefix("Running with the lid closed"))
    }
}
