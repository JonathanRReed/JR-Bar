import Foundation
import Testing
@testable import JRBarCore
@testable import JRBarApp

/// Every moment gets a switch: the monitor's `list_cues` / `set_cue`
/// when it has them, the older opt-in settings when it does not.
@Suite("Moments · cue switches")
@MainActor
struct LightMomentCueTests {
    /// A `list_cues` reply in the protocol's shape.
    private static let reply = Data("""
    {"cues": [
      {"id": "ask_heartbeat", "name": "Ask heartbeat", "meaning": "…", "enabled": true, "default_enabled": true, "setting": "ambient_cues_disabled", "priority": 1000},
      {"id": "handoff_baton", "name": "Handoff baton", "meaning": "…", "enabled": false, "default_enabled": true, "setting": "ambient_cues_disabled", "priority": 780},
      {"id": "milestone_odometer", "name": "Milestone odometer", "meaning": "…", "enabled": true, "default_enabled": false,
       "setting": "milestone_odometer_enabled", "priority": 720, "count": 37, "next_step": 50},
      {"id": "some_future_cue", "enabled": true}
    ]}
    """.utf8)

    private static func moment(_ id: String) -> LightMoment {
        LightMoment.all.first { $0.id == id }!
    }

    @Test func theRepliesShapeDecodes() throws {
        let list = try JSONDecoder().decode(LightCueList.self, from: Self.reply)
        #expect(list.cues.count == 4)
        let milestone = try #require(list.cues.first { $0.id == "milestone_odometer" })
        #expect(milestone.count == 37 && milestone.nextStep == 50)
        #expect(list.cues.first { $0.id == "handoff_baton" }?.enabled == false)
    }

    @Test func aListedCueTakesTheMonitorsSwitch() throws {
        let list = try JSONDecoder().decode(LightCueList.self, from: Self.reply)
        let cues = Dictionary(uniqueKeysWithValues: list.cues.map { ($0.id, $0) })
        guard case .cue(let baton) = MomentSwitch.of(Self.moment("handoff_baton"), cues: cues) else {
            Issue.record("the baton should switch through set_cue")
            return
        }
        #expect(!baton.enabled)
        // A cue the monitor does not list keeps what it had: the Dot's
        // heartbeat is a display, and without the command the opt-in
        // cues keep their settings.
        #expect(MomentSwitch.of(Self.moment("dot_binary_heartbeat"), cues: cues) == .always)
        #expect(MomentSwitch.of(Self.moment("rainstick_idle"), cues: nil) == .setting("rainstick_idle_enabled"))
        #expect(MomentSwitch.of(Self.moment("glance_light"), cues: nil) == .always)
    }

    @Test func theMilestoneSaysWhereItStands() {
        #expect(MomentSwitch.milestoneLine(LightCueState(id: "milestone_odometer", enabled: true, count: 37, nextStep: 50))
                == "37 finished since the monitor started · next at 50")
        #expect(MomentSwitch.milestoneLine(LightCueState(id: "milestone_odometer", enabled: true, count: 140, nextStep: nil))
                == "140 finished since the monitor started · past the last step")
        #expect(MomentSwitch.milestoneLine(LightCueState(id: "glance_light", enabled: true)) == nil)
    }

    @Test func everyCueTheMonitorNamesHasAMoment() {
        // `list_cues`' ids (docs/CORE-PROTOCOL.md): the eleven ambient
        // families. The Dot's heartbeat is the one moment that is not a cue.
        let cueIDs: Set = ["firefly_completion", "completion_meniscus", "handoff_baton", "recovery_grace",
                           "ask_heartbeat", "turn_length_ember", "fleet_arrival_departure", "courtesy_signature",
                           "glance_light", "rainstick_idle", "milestone_odometer"]
        #expect(Set(LightMoment.all.map(\.id)).subtracting(["dot_binary_heartbeat"]) == cueIDs)
    }
}
