import Foundation
import Testing
@testable import JRBarCore

/// W13/T54: every AQ rule maps to a distinguishable plan, and the plan
/// cites the wire facts that drove it. Sessions are the wire's own
/// shape — a fixture and the live tank make the same decision.
@Suite struct AquariumPlannerTests {
    private let now = Date(timeIntervalSince1970: 1_700_000_000)

    private func session(mode: String? = nil, lifecycle: String? = nil,
                         tool: String? = nil, event: String? = nil,
                         ask: CoreAsk? = nil, stale: Bool = false,
                         workers: Int = 0, kind: String = "main",
                         nextActor: String? = nil,
                         updatedAt: Double? = nil) -> CoreSession {
        CoreSession(id: "s1", provider: "claude", kind: kind,
                    mode: mode, lifecycle: lifecycle, nextActor: nextActor,
                    updatedAt: updatedAt, stale: stale, ask: ask,
                    workers: workers, event: event, tool: tool)
    }

    // MARK: - Base activity (AQ01–AQ04)

    @Test func aq02_idleRest() {
        let plan = AquariumPlanner.plan(for: session(mode: "idle_ready"), now: now)
        #expect(plan.action == .idleRest)
        #expect(plan.state == .idling)
    }

    @Test func aq03_patrolWhenWorkingWithoutDetail() {
        let plan = AquariumPlanner.plan(for: session(mode: "working"), now: now)
        #expect(plan.action == .patrol)
        #expect(plan.state == .swimming)
    }

    @Test func aq04_attentiveHoverOnProcessingBoundary() {
        let plan = AquariumPlanner.plan(for: session(mode: "long_task_progress"), now: now)
        #expect(plan.action == .attentiveHover)
        #expect(plan.state == .swimming)
        let thinking = AquariumPlanner.plan(for: session(mode: "thinking"), now: now)
        #expect(thinking.action == .attentiveHover)
    }

    // MARK: - Tool stations (AQ05–AQ12)

    private func toolSession(_ tool: String) -> CoreSession {
        session(mode: "tool_running", tool: tool,
                event: "PostToolUse", updatedAt: now.timeIntervalSince1970 - 5)
    }

    @Test func aq05_genericToolFeeds() {
        #expect(AquariumPlanner.plan(for: toolSession("TodoWrite"), now: now).action == .feedStation)
    }

    @Test func aq06_readForages() {
        #expect(AquariumPlanner.plan(for: toolSession("Read"), now: now).action == .forage)
        #expect(AquariumPlanner.plan(for: toolSession("Glob"), now: now).action == .forage)
    }

    @Test func aq07_searchExplores() {
        #expect(AquariumPlanner.plan(for: toolSession("WebSearch"), now: now).action == .explore)
        #expect(AquariumPlanner.plan(for: toolSession("Grep"), now: now).action == .explore)
    }

    @Test func aq08_editTendsStones() {
        #expect(AquariumPlanner.plan(for: toolSession("Edit"), now: now).action == .tendStones)
        #expect(AquariumPlanner.plan(for: toolSession("Write"), now: now).action == .tendStones)
    }

    @Test func aq09_shellCurrentWork() {
        #expect(AquariumPlanner.plan(for: toolSession("Bash"), now: now).action == .currentWork)
    }

    @Test func aq10_testInspectsStructure() {
        #expect(AquariumPlanner.plan(for: toolSession("pytest"), now: now).action == .inspectStructure)
        #expect(AquariumPlanner.plan(for: toolSession("swiftbuild"), now: now).action == .inspectStructure)
    }

    @Test func aq12_mcpVisitsServiceStation() {
        #expect(AquariumPlanner.plan(for: toolSession("mcp__github__create_issue"), now: now).action == .serviceVisit)
        #expect(AquariumPlanner.plan(for: toolSession("mcp_call_tool"), now: now).action == .serviceVisit)
    }

    @Test func aq11_testResultBubbleOnPostToolUse() {
        // A test tool that just finished: PostToolUse, not still running.
        let done = session(mode: "working", tool: "pytest",
                           event: "PostToolUse",
                           updatedAt: now.timeIntervalSince1970 - 3)
        #expect(AquariumPlanner.plan(for: done, now: now).action == .resultBubble)
        // A stale PostToolUse is history, not a result arriving.
        let old = session(mode: "working", tool: "pytest", event: "PostToolUse",
                          updatedAt: now.timeIntervalSince1970 - 600)
        #expect(AquariumPlanner.plan(for: old, now: now).action != .resultBubble)
        // A non-test PostToolUse isn't a result marker.
        let bash = session(mode: "working", tool: "Bash", event: "PostToolUse",
                           updatedAt: now.timeIntervalSince1970 - 3)
        #expect(AquariumPlanner.plan(for: bash, now: now).action != .resultBubble)
    }

    @Test func staleToolEventIsHistoryNotStation() {
        // A tool_running row whose last update is old: the event is a
        // fact about the past, not something the fish is doing now.
        let old = session(mode: "tool_running", tool: "Read",
                          event: "PostToolUse",
                          updatedAt: now.timeIntervalSince1970 - 600)
        let plan = AquariumPlanner.plan(for: old, now: now)
        #expect(plan.action != .forage)
    }

    // MARK: - Parallel + delegation (AQ13, AQ15)

    @Test func aq13_parallelMarkersNeedWorkingMainWithWorkers() {
        let working = session(mode: "working", workers: 3)
        #expect(AquariumPlanner.plan(for: working, now: now).parallelMarkers == 3)
        // Idle or done workers don't draw markers.
        #expect(AquariumPlanner.plan(for: session(mode: "idle_ready", workers: 3), now: now).parallelMarkers == 0)
        // Non-main rows never own a school.
        #expect(AquariumPlanner.plan(for: session(mode: "working", workers: 3, kind: "worker"), now: now).parallelMarkers == 0)
    }

    @Test func aq15_delegationEventPassesAToken() {
        let delegation = session(mode: "working", event: "delegation")
        #expect(AquariumPlanner.plan(for: delegation, now: now).action == .tokenPass)
    }

    // MARK: - Attention (AQ16–AQ17)

    @Test func aq16_questionBubbleForPlainAsk() {
        let ask = CoreAsk(kind: "question", summary: "Which file?")
        let plan = AquariumPlanner.plan(for: session(ask: ask), now: now)
        #expect(plan.action == .surfaceQuestion)
        #expect(plan.overlay == .questionBubble)
        #expect(plan.state == .surfacing)
    }

    @Test func aq17_attentionBuoyForPermissionAsk() {
        let ask = CoreAsk(kind: "permission", summary: "Run rm -rf?")
        let plan = AquariumPlanner.plan(for: session(ask: ask), now: now)
        #expect(plan.action == .attentionBuoy)
        #expect(plan.overlay == .attentionBuoy)
    }

    // MARK: - Outcomes (AQ20–AQ24)

    @Test func aq20_failedHoldsAtWarningBuoy() {
        let plan = AquariumPlanner.plan(for: session(lifecycle: "failed"), now: now)
        #expect(plan.action == .warningBuoy)
        #expect(plan.overlay == .warningBuoy)
        #expect(plan.state == .sinking)
    }

    @Test func aq21_doneUnreviewedDepositsPearl() {
        let plan = AquariumPlanner.plan(for: session(lifecycle: "completed"),
                                        axes: CoreSessionAxes(review: "unreviewed"),
                                        now: now)
        #expect(plan.action == .pearlDeposit)
        #expect(plan.overlay == .pearl)
        #expect(plan.state == .leaving)
    }

    @Test func aq22_reviewedClearsPearl() {
        let plan = AquariumPlanner.plan(for: session(lifecycle: "completed"),
                                        axes: CoreSessionAxes(review: "reviewed"),
                                        now: now)
        #expect(plan.action == .returnNormal)
        #expect(plan.overlay == nil)
    }

    @Test func aq23_staleClaimsNoPreciseActivity() {
        let stale = session(mode: "working", tool: "Read", stale: true)
        let plan = AquariumPlanner.plan(for: stale, now: now)
        #expect(plan.action == .uncertainDrift)
        #expect(plan.overlay == .staleMarker)
        // Freshness axis that isn't "live" degrades the same way.
        let delayed = session(mode: "working")
        let delayedPlan = AquariumPlanner.plan(for: delayed,
                                               axes: CoreSessionAxes(freshness: "delayed"),
                                               now: now)
        #expect(delayedPlan.action == .uncertainDrift)
    }

    @Test func aq24_unconfirmedEndIsInactiveNotFailed() {
        let plan = AquariumPlanner.plan(for: session(mode: "ended_unconfirmed"), now: now)
        #expect(plan.action == .inactiveDrift)
        #expect(plan.state == .sinking)
        // Distinct from failure — no warning buoy, no injury.
        #expect(plan.overlay == nil)
        let failed = AquariumPlanner.plan(for: session(lifecycle: "failed"), now: now)
        #expect(failed.action != plan.action)
    }

    // MARK: - Evidence citation

    @Test func evidenceNamesTheFacts() {
        let plan = AquariumPlanner.plan(for: toolSession("Bash"), now: now)
        #expect(plan.evidence.contains("tool=Bash"))
        #expect(plan.evidence.contains("currentWork"))
        #expect(plan.evidence.contains("mode=tool_running"))
    }

    @Test func everyActionIsReachable() {
        // The contract: no case exists that no wire fact can produce.
        // `.enter` is set by enteredAt in the model, not the planner —
        // the rest must each appear under some fixture.
        var seen = Set<FishAction>()
        let fixtures: [CoreSession] = [
            session(mode: "idle_ready"),
            session(mode: "working"),
            session(mode: "long_task_progress"),
            toolSession("TodoWrite"), toolSession("Read"), toolSession("Grep"),
            toolSession("Edit"), toolSession("Bash"), toolSession("pytest"),
            toolSession("mcp__x__y"),
            session(mode: "working", event: "delegation"),
            session(ask: CoreAsk(kind: "question")),
            session(ask: CoreAsk(kind: "permission")),
            session(lifecycle: "failed"),
            session(lifecycle: "completed"),
            session(mode: "working", stale: true),
            session(mode: "ended_unconfirmed"),
        ]
        for s in fixtures {
            seen.insert(AquariumPlanner.plan(for: s, now: now).action)
        }
        // The axis-dependent cases need explicit axes:
        seen.insert(AquariumPlanner.plan(
            for: session(lifecycle: "completed"),
            axes: CoreSessionAxes(review: "unreviewed"), now: now).action)
        seen.insert(AquariumPlanner.plan(
            for: session(lifecycle: "completed"),
            axes: CoreSessionAxes(review: "reviewed"), now: now).action)
        // And AQ11 needs a fresh PostToolUse on a test tool:
        seen.insert(AquariumPlanner.plan(
            for: session(mode: "working", tool: "pytest", event: "PostToolUse",
                         updatedAt: now.timeIntervalSince1970 - 3), now: now).action)
        let reachable = Set(FishAction.allCases).subtracting([.enter])
        #expect(seen == reachable,
                "Unreachable actions: \(reachable.subtracting(seen))")
    }
}
