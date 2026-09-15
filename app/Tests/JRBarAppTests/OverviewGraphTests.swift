import Foundation
import simd
import Testing
import JRBarCore
@testable import JRBarApp

/// The session graph's pure half: the node/edge document the canvas
/// draws (parent→worker mapping, state → card style), the filter that
/// feeds it, and the force layout's convergence and sleep. The canvas
/// itself is AppKit and stays untested here by design.
@Suite struct OverviewGraphModelTests {

    private static func entry(
        _ id: String,
        provider: String = "codex",
        kind: String = "main",
        parent: String? = nil,
        label: String? = nil,
        cwd: String? = nil,
        mode: String? = "working",
        lifecycle: String? = "active",
        remote: Bool = false,
        ask: CoreAsk? = nil,
        pinned: Bool = false,
        outcome: String? = "none",
        review: String? = "pending",
        message: String? = nil,
        tool: String? = nil
    ) -> CoreRosterEntry {
        CoreRosterEntry(
            session: CoreSession(
                id: id, provider: provider, kind: kind, parent: parent,
                label: label, cwd: cwd, mode: mode, lifecycle: lifecycle,
                ask: ask, remote: remote, tool: tool, message: message
            ),
            schema: 1, pinned: pinned, visibility: "live",
            axes: CoreSessionAxes(outcome: outcome, review: review, freshness: "live")
        )
    }

    // MARK: Node/edge model

    @Test func workerRowsBecomeSatellitesOfTheirParent() {
        let graph = OverviewGraph.build(from: [
            Self.entry("main-1", label: "Fix the flap"),
            Self.entry("w-1", kind: "worker", parent: "main-1", label: "scout"),
            Self.entry("w-2", kind: "worker", parent: "main-1"),
        ])
        #expect(graph.nodes.count == 3)
        #expect(graph.edges.count == 2)
        #expect(graph.edges.allSatisfy { $0.source == "main-1" && $0.kind == .subagent })
        #expect(Set(graph.edges.map(\.target)) == ["w-1", "w-2"])
        #expect(graph.node("w-1")?.isWorker == true)
        #expect(graph.node("w-1")?.parentID == "main-1")
        #expect(graph.node("main-1")?.isWorker == false)
    }

    @Test func workerWhoseParentIsFilteredOutStandsAlone() {
        // The cut hid the parent: the worker is still a node, but no
        // edge may point at a card that is not drawn.
        let graph = OverviewGraph.build(from: [
            Self.entry("orphan", kind: "worker", parent: "absent"),
        ])
        #expect(graph.nodes.count == 1)
        #expect(graph.edges.isEmpty)
        #expect(graph.node("orphan")?.parentID == nil)
        #expect(graph.node("orphan")?.isWorker == true)
    }

    @Test func activityMapsToCardStyle() {
        let graph = OverviewGraph.build(from: [
            Self.entry("run", mode: "tool_running"),
            Self.entry("ask", ask: CoreAsk(session: "ask", summary: "?")),
            Self.entry("bad", mode: "failed", lifecycle: "failed", outcome: "failed"),
            Self.entry("ok", mode: "completed", lifecycle: "completed", outcome: "succeeded"),
            Self.entry("gone", mode: "ended_unconfirmed", lifecycle: "ended", outcome: "unreported"),
            Self.entry("still", mode: "idle_ready"),
        ])
        #expect(graph.node("run")?.style == .working)
        #expect(graph.node("ask")?.style == .waiting)
        #expect(graph.node("bad")?.style == .failed)
        #expect(graph.node("ok")?.style == .done)
        #expect(graph.node("gone")?.style == .quiet)
        #expect(graph.node("still")?.style == .quiet)
    }

    @Test func nodeCaptionsReuseTheActivityColumnWording() {
        let graph = OverviewGraph.build(from: [
            Self.entry("m", message: "rebased the branch"),
            Self.entry("t", tool: "Read"),
            Self.entry("q", ask: CoreAsk(session: "q", summary: "Ship it?")),
        ])
        #expect(graph.node("m")?.caption == "rebased the branch")
        #expect(graph.node("t")?.caption == "Read")
        #expect(graph.node("q")?.caption == "Ship it?")
    }

    @Test func attentionFollowsThePinnedAndAskedRows() {
        let graph = OverviewGraph.build(from: [
            Self.entry("pin", mode: "completed", lifecycle: "completed",
                       pinned: true, outcome: "succeeded"),
            Self.entry("plain"),
        ])
        #expect(graph.node("pin")?.attention == true)
        #expect(graph.node("plain")?.attention == false)
    }

    // MARK: The filter applies identically

    @MainActor
    @Test func graphSeesTheSameFilteredRowsAsTheTable() {
        let store = OverviewStore(core: CoreModel())
        store.roster = [
            Self.entry("ask", ask: CoreAsk(session: "ask", summary: "?")),
            Self.entry("kid", kind: "worker", parent: "ask",
                       ask: CoreAsk(session: "kid", summary: "?")),
            Self.entry("quiet"),
        ]
        store.filter = OverviewFilter(preset: .needsMe)
        let graph = store.graph
        #expect(Set(graph.nodes.map(\.id)) == Set(store.rows.map(\.id)))
        // The parent's edge survives because both rows pass the cut.
        #expect(graph.edges == [OverviewGraphEdge(source: "ask", target: "kid", kind: .subagent)])
        store.search = "kid"
        #expect(store.graph.nodes.map(\.id) == ["kid"])
        #expect(store.graph.edges.isEmpty) // parent filtered out → no edge
    }

    // MARK: View-mode default and persistence

    @MainActor
    @Test func graphIsTheDefaultOnlyWhileASessionIsLive() {
        let store = OverviewStore(core: CoreModel())
        store.viewModeChoice = nil // ignore whatever the host defaults hold
        store.roster = []
        #expect(store.viewMode == .list)
        store.roster = [Self.entry("done", mode: "completed", lifecycle: "completed",
                                 outcome: "succeeded", review: "reviewed")]
        #expect(store.viewMode == .list)
        store.roster.append(Self.entry("live"))
        #expect(store.viewMode == .graph)
        // An explicit pick wins over the liveness default.
        store.viewModeChoice = .list
        #expect(store.viewMode == .list)
    }

    @Test func viewModePreferenceRoundTrips() {
        let defaults = UserDefaults(suiteName: "OverviewGraphTests.\(UUID().uuidString)")!
        #expect(OverviewViewModePreference.load(defaults: defaults) == nil)
        OverviewViewModePreference.save(.graph, defaults: defaults)
        #expect(OverviewViewModePreference.load(defaults: defaults) == .graph)
        OverviewViewModePreference.save(nil, defaults: defaults)
        #expect(OverviewViewModePreference.load(defaults: defaults) == nil)
    }
}

/// The force layout: deterministic seeding, convergence inside a tick
/// budget, springs holding near their rest length, and a settled engine
/// that stays asleep.
@Suite struct OverviewForceLayoutTests {

    private static func graph(
        mains: Int, workersPerMain: Int = 0
    ) -> OverviewGraph {
        var rows: [CoreRosterEntry] = []
        for m in 0..<mains {
            rows.append(CoreRosterEntry(
                session: CoreSession(id: "m\(m)", provider: "codex", mode: "working"),
                schema: 1))
            for w in 0..<workersPerMain {
                rows.append(CoreRosterEntry(
                    session: CoreSession(id: "m\(m)w\(w)", provider: "codex",
                                         kind: "worker", parent: "m\(m)", mode: "working"),
                    schema: 1))
            }
        }
        return OverviewGraph.build(from: rows)
    }

    @Test func layoutConvergesAndTerminates() {
        var layout = OverviewForceLayout(graph: Self.graph(mains: 6, workersPerMain: 2))
        let spent = layout.runUntilSettled(maxTicks: 1200)
        #expect(layout.settled)
        #expect(spent < 1200)
        // Every position is finite once the dust clears.
        for body in layout.bodies {
            #expect(body.position.x.isFinite && body.position.y.isFinite)
        }
    }

    @Test func springsHoldNearTheirRestLength() {
        let graph = Self.graph(mains: 2, workersPerMain: 2)
        var layout = OverviewForceLayout(graph: graph)
        layout.runUntilSettled()
        for spring in layout.springs {
            let a = layout.bodies[spring.a].position
            let b = layout.bodies[spring.b].position
            let dist = simd_distance(a, b)
            // Within a third of the satellite rest — repulsion keeps a
            // little extra room, so this is a band, not a point.
            #expect(dist > 60 && dist < 320)
        }
    }

    @Test func aSettledLayoutStaysAsleep() {
        var layout = OverviewForceLayout(graph: Self.graph(mains: 4, workersPerMain: 1))
        layout.runUntilSettled()
        #expect(layout.settled)
        let delta = layout.tick()
        #expect(delta < layout.parameters.epsilon || layout.settled)
    }

    @Test func draggingWakesAndReleases() {
        var layout = OverviewForceLayout(graph: Self.graph(mains: 3))
        layout.runUntilSettled()
        #expect(layout.settled)
        layout.pin("m1", at: SIMD2(400, 0))
        #expect(!layout.settled)
        layout.movePinned("m1", to: SIMD2(500, 50))
        #expect(layout.position(of: "m1") == SIMD2(500, 50))
        layout.unpin("m1")
        layout.runUntilSettled()
        #expect(layout.settled)
    }

    @Test func syncKeepsSurvivingNodesInPlace() {
        var layout = OverviewForceLayout(graph: Self.graph(mains: 4))
        layout.runUntilSettled()
        let before = layout.position(of: "m0")!
        // A refreshed graph drops one node; the survivors keep their
        // settled spots instead of re-scattering.
        var smaller = Self.graph(mains: 4)
        smaller.nodes.removeAll { $0.id == "m3" }
        layout.sync(with: smaller)
        #expect(layout.position(of: "m0") == before)
        #expect(!layout.settled) // a changed graph re-wakes
    }

    @Test func aSingleNodeDriftsToTheCentreAndSleeps() {
        var layout = OverviewForceLayout(graph: Self.graph(mains: 1))
        layout.runUntilSettled()
        #expect(layout.settled)
        let p = layout.bodies[0].position
        #expect(simd_length(p) < 80) // weak gravity pulls the seed home
    }
}
