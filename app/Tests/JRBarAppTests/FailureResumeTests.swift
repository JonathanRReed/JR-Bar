import Foundation
import Testing
@testable import JRBarApp
@testable import JRBarCore
@testable import JRBarUI

@Suite("Failure resumes", .serialized)
@MainActor
struct FailureResumeTests {
    @Test func menuBarAndSessionDotsUseTheSameBriefTopLevelSignal() {
        let root = CoreSession(id: "claude:session:root", provider: "claudeAgent", mode: "blocked_error",
                               lifecycle: "failed", updatedAt: 100, failureSignalUntil: 105)
        let worker = CoreSession(id: "claude:session:child", provider: "claude", kind: "worker",
                                 parent: root.id, mode: "blocked_error", lifecycle: "failed", updatedAt: 100,
                                 failureSignalUntil: 105)
        for now in [100.0, 104.999, 105, 200] {
            let expected = now < 105 ? StatusDotState.error : .idle
            #expect(AppDelegate.meterDotState(state: CoreState(sessions: [root]), now: now) == expected)
            let state = CoreState(aggregate: CoreAggregate(mode: "failed", failed: 1), sessions: [root])
            #expect(AgentAggregateState.from(state: state, now: now) == (now < 105 ? .failed : .idle))
            #expect(AppDelegate.sessionDotState(for: SessionRow(session: root, pinnedAsk: nil),
                                               now: Date(timeIntervalSince1970: now)) == expected)
            #expect(AppDelegate.meterDotState(state: CoreState(sessions: [worker]), now: now) == .idle)
            #expect(AppDelegate.sessionDotState(for: SessionRow(session: worker, pinnedAsk: nil),
                                               now: Date(timeIntervalSince1970: now)) == .idle)
        }
        let resumed = CoreSession(id: root.id, provider: "claude", mode: "tool_running", lifecycle: "active", updatedAt: 101)
        #expect(AppDelegate.meterDotState(state: CoreState(sessions: [resumed, worker]), now: 102) == .working)
        let ended = CoreSession(id: root.id, provider: "claude", mode: "ended_unconfirmed", lifecycle: "ended", updatedAt: 101)
        #expect(AppDelegate.meterDotState(state: CoreState(sessions: [ended, worker]), now: 102) == .idle)
    }
}
