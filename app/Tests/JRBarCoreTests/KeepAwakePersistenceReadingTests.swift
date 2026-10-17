import Foundation
import Testing
@testable import JRBarCore

@Suite("Keep Awake saved state warnings")
struct KeepAwakePersistenceReadingTests {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    private func reading(state: String, failure: String?) throws -> KeepAwakeReading {
        var fields: [String: Any] = ["state": state, "active": state != "off", "agents": 2]
        if state == "manual" { fields["lease"] = ["kind": "indefinite"] }
        if let failure { fields["persistence_error"] = failure }
        let data = try JSONSerialization.data(withJSONObject: fields)
        let hold = try JSONDecoder().decode(CoreAwakeHold.self, from: data)
        return KeepAwakeReading(hold: hold)
    }

    @Test("off holds expose saved-state failures without claiming an active hold",
           arguments: ["save_failed", "clear_failed"])
    func warningWhileOff(failure: String) throws {
        let value = try reading(state: "off", failure: failure)
        #expect(value.state == .off && !value.leaseInForce)
        #expect(value.footerLine(now: now)?.short == "Not saved")
        #expect(value.chipHelp(now: now).contains("could not"))
        #expect(!value.facts().isEmpty)
    }

    @Test("warnings retain manual and agent ownership", arguments: ["manual", "agents"])
    func warningKeepsOwnership(state: String) throws {
        let value = try reading(state: state, failure: "save_failed")
        #expect(value.leaseInForce == (state == "manual"))
        #expect(value.state != .off)
        #expect(value.footerLine(now: now)?.short == "Not saved")
        #expect(value.facts().contains { $0.contains("could not") })
    }

    @Test("old and unknown warning fields preserve the existing reading")
    func compatibility() throws {
        for failure in [nil, "future_failure"] as [String?] {
            let value = try reading(state: "off", failure: failure)
            #expect(value.footerLine(now: now) == nil)
            #expect(value.facts().isEmpty)
        }
    }
}
