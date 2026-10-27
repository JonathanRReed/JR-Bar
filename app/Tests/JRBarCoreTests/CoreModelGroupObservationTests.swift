import Foundation
import Observation
import Testing
@testable import JRBarCore

@Suite("CoreModel group observation")
@MainActor
struct CoreModelGroupObservationTests {
    final class Changed: @unchecked Sendable { var value = false }

    @Test("groups ignore clock and health changes and take a delta immediately")
    func groupSlice() throws {
        let core = CoreModel(socketPath: "/tmp/jrbar-groups-unused.sock")
        core.handle(.connected)
        let group = CoreAgentGroup(id: "group", rootWorkKey: "main", rootProvider: "claude",
                                   members: ["main", "worker"], lineageEvidence: [])
        core.apply(.state(CoreState(generation: 1, agentGroups: [group])))
        let changed = Changed()
        withObservationTracking { _ = core.agentGroups } onChange: { changed.value = true }
        core.apply(.state(CoreState(generation: 2, now: 2, health: .object(["age": .number(2)]),
                                   agentGroups: [group])))
        #expect(!changed.value)
        #expect(core.agentGroups == [group])

        let data = Data(#"{"generation":3,"base_generation":2,"slices":{"agent_groups":{"generation":1,"value":[]}}}"#.utf8)
        let delta = try JSONDecoder().decode(CoreStateDelta.self, from: data)
        core.apply(.stateDelta(delta))
        #expect(changed.value)
        #expect(core.agentGroups.isEmpty)
        #expect(core.state?.agentGroups.isEmpty == true)
    }

    @Test("disconnect clears the group slice with the other session facts")
    func disconnectClearsGroups() {
        let core = CoreModel(socketPath: "/tmp/jrbar-groups-unused.sock")
        core.handle(.connected)
        let group = CoreAgentGroup(id: "group", rootWorkKey: "main", rootProvider: "claude",
                                   members: ["main"], lineageEvidence: [])
        core.apply(.state(CoreState(generation: 1, agentGroups: [group])))
        core.handle(.disconnected(reason: "synthetic disconnect"))
        #expect(core.agentGroups.isEmpty)
        #expect(core.state == nil)
    }
}
