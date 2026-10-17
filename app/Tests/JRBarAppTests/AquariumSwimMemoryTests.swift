import Foundation
import Testing
@testable import JRBarApp

/// The tank's memory of where each fish was drawn: a fry's orbit must
/// keep circling when the wall clock that times the frames is set back.
@Suite("Aquarium swim memory")
@MainActor
struct AquariumSwimMemoryTests {
    @Test("same-size roster replacements retire old orbit and pose memory")
    func pruneReplacedRoster() {
        let memory = TankSwimMemory()
        _ = memory.orbit("old", t: 100, rate: 2, start: { 0 })
        memory.rolls["old"] = .init(start: 100, go: true)
        memory.prune(keeping: ["new"])
        #expect(memory.orbits.isEmpty)
        #expect(memory.rolls.isEmpty)
        _ = memory.orbit("new", t: 100, rate: 2, start: { 0 })
        memory.prune(keeping: ["new"])
        #expect(memory.orbits["new"] != nil)
        memory.prune(keeping: [])
        #expect(memory.orbits.isEmpty)
    }

    @Test("a fry's orbit keeps circling after the frame clock is set back")
    func orbitSurvivesAClockStepBack() {
        let memory = TankSwimMemory()
        let first = memory.orbit("fry", t: 1_000, rate: 2, start: { 0 })
        #expect(first == 0)
        let second = memory.orbit("fry", t: 1_000.1, rate: 2, start: { 0 })
        #expect(abs(second - 0.2) < 1e-9)
        // The clock is set back an hour: the orbit holds its angle for the
        // frame that sees it, then carries on from the new time at once.
        let stepped = memory.orbit("fry", t: 1_000.1 - 3_600, rate: 2, start: { 0 })
        #expect(stepped == second)
        let after = memory.orbit("fry", t: 1_000.1 - 3_600 + 0.1, rate: 2, start: { 0 })
        #expect(abs(after - (second + 0.2)) < 1e-9, "no hour of frozen orbit")
    }
}
