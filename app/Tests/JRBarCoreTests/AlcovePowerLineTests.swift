import Foundation
import Testing
@testable import JRBarCore

/// The battery, agent-aware: the glyph holds the charge it reads, the
/// card's line says whether a run survives unplugged, and the one
/// power word only JR-Bar can give — low battery with agents working.
@Suite("Power line")
struct AlcovePowerLineTests {
    private func state(percent: Int?, onAC: Bool = false, charging: Bool = false,
                       full: Bool = false, minutes: Int? = nil) -> AlcovePowerState {
        AlcovePowerState(hasBattery: true, onAC: onAC, charging: charging, percent: percent,
                         fullyCharged: full, minutesRemaining: minutes)
    }

    @Test("the glyph is the charge, never a fixed half battery")
    func glyph() {
        #expect(state(percent: 5).symbol == "battery.0percent")
        #expect(state(percent: 30).symbol == "battery.25percent")
        #expect(state(percent: 50).symbol == "battery.50percent")
        #expect(state(percent: 80).symbol == "battery.75percent")
        #expect(state(percent: 95).symbol == "battery.100percent")
        #expect(state(percent: 40, onAC: true, charging: true).symbol == "battery.100percent.bolt")
    }

    @Test("the line reads time left and the runs riding on it")
    func line() {
        #expect(AlcovePower.batteryLine(state(percent: 41, minutes: 110), working: 3, heldAwake: true)
                == "41% · ~1h 50m left · 3 agents working · held awake")
        #expect(AlcovePower.batteryLine(state(percent: 41), working: 0, heldAwake: false)
                == "41% · On battery")
        #expect(AlcovePower.batteryLine(state(percent: 84, onAC: true, charging: true, minutes: 35),
                                        working: 1, heldAwake: false)
                == "84% · Charging · full in 35m · 1 agent working")
        #expect(AlcovePower.batteryLine(state(percent: 100, onAC: true, full: true), working: 0,
                                        heldAwake: false) == "100% · Charged")
        #expect(AlcovePower.batteryLine(state(percent: 80, onAC: true), working: 0, heldAwake: false)
                == "80% · On AC")
    }

    @Test("low battery speaks once, on the crossing, only with agents working on battery")
    func lowBattery() {
        let crossing = AlcovePower.lowBatteryNotice(from: state(percent: 20), to: state(percent: 19, minutes: 25),
                                                    working: 2, id: "x")
        #expect(crossing?.title == "Battery low")
        #expect(crossing?.subtitle == "19% · ~25m left · 2 agents working")
        #expect(crossing?.key == AlcovePower.lowKey)
        #expect(AlcovePower.lowBatteryNotice(from: state(percent: 20), to: state(percent: 19),
                                             working: 0, id: "x") == nil, "nothing running: not news")
        #expect(AlcovePower.lowBatteryNotice(from: state(percent: 19), to: state(percent: 18),
                                             working: 2, id: "x") == nil, "already under: said once")
        #expect(AlcovePower.lowBatteryNotice(from: state(percent: 20, onAC: true),
                                             to: state(percent: 19, onAC: true),
                                             working: 2, id: "x") == nil, "plugged in")
    }

    @Test("an estimate moving is never a transition")
    func estimateDrift() {
        let a = state(percent: 50, minutes: 100)
        let b = state(percent: 50, minutes: 97)
        #expect(a != b)
        #expect(a.withoutEstimate == b.withoutEstimate)
        #expect(AlcovePower.notice(from: a, to: b, id: "x", kinds: AlcoveCapsuleKinds()) == nil)
    }
}
