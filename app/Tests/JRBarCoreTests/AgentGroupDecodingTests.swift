import Foundation
import Testing
@testable import JRBarCore

@Suite("Agent group decoding")
struct AgentGroupDecodingTests {
    @Test("Python's seven members decode as one Claude group")
    func pythonGroup() throws {
        guard case .state(let state) = try CoreFixtures.message("python-agent-groups.json") else {
            Issue.record("Expected the daemon's state frame")
            return
        }
        let group = try #require(state.agentGroups.first)
        #expect(state.agentGroups.count == 1)
        #expect(group.rootWorkKey == "claude:session:native-root")
        #expect(group.rootProvider == "claude")
        #expect(group.members.count == 7)
        #expect(group.workerCount == 6)
        #expect(group.lineageEvidence.count == 6)
        #expect(state.mainSessions.map(\.id) == [group.rootWorkKey])
        #expect(state.sessions.allSatisfy { $0.groupId == group.id && !$0.unlinkedWorker })
        #expect(state.session(withID: group.rootWorkKey)?.workers == 6)
    }

    @Test("Older daemons and malformed groups keep the state readable")
    func additiveFields() throws {
        let old = Data(#"{"generation":1,"sessions":[{"id":"claude:agent:worker"}]}"#.utf8)
        let state = try JSONDecoder().decode(CoreState.self, from: old)
        #expect(state.agentGroups.isEmpty)
        #expect(state.sessions.first?.unlinkedWorker == false)
        let malformed = Data(#"{"generation":1,"agent_groups":[{}],"sessions":[{"id":"claude:agent:worker","unlinked_worker":true}]}"#.utf8)
        let decoded = try JSONDecoder().decode(CoreState.self, from: malformed)
        #expect(decoded.agentGroups.isEmpty)
        #expect(decoded.sessions.first?.unlinkedWorker == true)
    }
}
