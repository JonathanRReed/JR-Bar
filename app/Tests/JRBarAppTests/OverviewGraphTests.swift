import CoreGraphics
import Foundation
import Testing
import JRBarCore
@testable import JRBarApp

/// The Overview's Graph: what it draws, and where. The layout and the
/// camera are pure, so their promises — workers branching off their
/// session, a hub per provider level with its work, nothing overlapping,
/// the same picture twice, a state change that never moves a node — are
/// checked directly.
@MainActor
@Suite struct OverviewGraphTests {
    private typealias Layout = OverviewGraphLayout

    private static func node(_ id: String, parent: String? = nil, project: String? = "app",
                             _ activity: SessionActivity = .working, provider: String = "claude",
                             last: Double = 0) -> OverviewGraphNode {
        OverviewGraphNode(id: id, parentID: parent, project: project, provider: provider,
                          activity: activity, label: id, lastActive: last)
    }

    /// No two frames in the list overlap.
    private static func disjoint(_ frames: [CGRect]) -> Bool {
        for (index, a) in frames.enumerated() {
            for b in frames.dropFirst(index + 1) where a.insetBy(dx: 0.5, dy: 0.5).intersects(b) { return false }
        }
        return true
    }

    @Test("workers branch outward from their session, one edge each, in columns of six")
    func familiesAndEdges() throws {
        let nodes = [Self.node("main")] + (1...8).map { Self.node("w\($0)", parent: "main") }
        let layout = Layout.make(nodes)
        let main = try #require(layout.nodes["main"])
        #expect(!main.isWorker && main.depth == 0)
        #expect(Set(layout.edges) == Set((1...8).map { Layout.Edge(from: "main", to: "w\($0)") }))
        let workers = try (1...8).map { try #require(layout.nodes["w\($0)"]) }
        #expect(workers.allSatisfy { $0.isWorker && $0.side == main.side })
        // Outward: past the session's far end, facing it.
        #expect(workers.allSatisfy { $0.frame.minX >= main.frame.maxX + Layout.Metrics.branch - 0.5 })
        // Eight make a column of six and one of two, centred on the session.
        let columns = Dictionary(grouping: workers, by: { $0.frame.minX })
        #expect(columns.count == 2)
        #expect(columns.values.map(\.count).sorted() == [2, 6])
        let ys = workers.map(\.center.y)
        #expect(abs(((ys.min() ?? 0) + (ys.max() ?? 0)) / 2 - main.center.y) < 0.5)
        #expect(Self.disjoint(workers.map(\.frame)))
    }

    @Test("a worker's own workers branch off it in turn")
    func nestedFamilies() throws {
        let nodes = [Self.node("main"), Self.node("lead", parent: "main"), Self.node("helper", parent: "lead"),
                     Self.node("solo", parent: "main")]
        let layout = Layout.make(nodes)
        let lead = try #require(layout.nodes["lead"])
        let helper = try #require(layout.nodes["helper"])
        #expect(lead.depth == 1 && helper.depth == 2)
        #expect(helper.parentID == "lead")
        #expect(helper.frame.minX > lead.frame.maxX)
        #expect(Set(layout.edges) == [.init(from: "lead", to: "helper"), .init(from: "main", to: "lead"),
                                      .init(from: "main", to: "solo")])
        #expect(Self.disjoint(layout.nodes.values.map(\.frame)))
    }

    @Test("clusters go in name order, alternate sides of the hubs, and never overlap")
    func clusterOrderAndSpacing() {
        let nodes = [
            Self.node("quiet", project: "docs", .idle, last: 900),
            Self.node("busy", project: "api", .working, last: 800),
            Self.node("ask", project: "site", .waiting, provider: "codex", last: 100),
            Self.node("gone", project: nil, .done, last: 50),
            Self.node("more", project: "api", .failed, provider: "gemini"),
        ]
        let layout = Layout.make(nodes)
        #expect(layout.clusters.map(\.id) == ["api", "docs", "site", ""])
        #expect(layout.clusters.map(\.side) == [.right, .left, .right, .left])
        #expect(layout.clusters.first { $0.id.isEmpty }?.title == "No folder")
        #expect(Self.disjoint(layout.clusters.map(\.frame)))
        for cluster in layout.clusters {
            // Clear of the hubs' axis, with the spokes' run to spare.
            #expect(cluster.side == .right ? cluster.frame.minX >= Layout.Metrics.spoke
                                           : cluster.frame.maxX <= -Layout.Metrics.spoke)
            for id in cluster.nodeIDs {
                #expect(cluster.frame.contains(layout.nodes[id]?.frame ?? .null))
            }
            #expect(layout.bounds.contains(cluster.frame))
        }
        #expect(layout.clusters.first { $0.id == "site" }?.counts == [.waiting: 1])
        #expect(layout.clusters.first { $0.id == "api" }?.counts == [.working: 1, .failed: 1])
    }

    @Test("a hub per provider on the axis, level with its sessions, spaced so none touch")
    func hubs() throws {
        let nodes = [
            Self.node("a", project: "api"), Self.node("b", project: "api", provider: "codex"),
            Self.node("c", project: "docs", provider: "codex"), Self.node("d", project: "site", provider: "gemini"),
            Self.node("w", parent: "a", provider: "gemini"),
        ]
        let layout = Layout.make(nodes)
        // Workers join their session, not a hub: Gemini's hub serves "d" only.
        #expect(layout.hubs.map(\.id).sorted() == ["claude", "codex", "gemini"])
        #expect(layout.hubs.first { $0.id == "gemini" }?.sessionIDs == ["d"])
        #expect(Set(layout.hubs.flatMap(\.sessionIDs)) == ["a", "b", "c", "d"])
        #expect(layout.hubs.allSatisfy { $0.center.x == 0 })
        let ys = layout.hubs.map(\.center.y).sorted()
        for (upper, lower) in zip(ys, ys.dropFirst()) { #expect(lower - upper >= Layout.Metrics.hubPitch - 0.5) }
        for hub in layout.hubs { #expect(layout.bounds.contains(hub.frame)) }
        // Within its sessions' span, so the spokes run short.
        let codex = try #require(layout.hubs.first { $0.id == "codex" })
        let spans = codex.sessionIDs.compactMap { layout.nodes[$0]?.center.y }
        #expect(codex.center.y >= (spans.min() ?? 0) - Layout.Metrics.hubPitch)
        #expect(codex.center.y <= (spans.max() ?? 0) + Layout.Metrics.hubPitch)
    }

    @Test("the same sessions land in the same places, in any order, and a state change never moves one")
    func deterministic() {
        let nodes = [Self.node("a", last: 3), Self.node("b", .waiting, last: 2), Self.node("c", parent: "a"),
                     Self.node("d", project: "other", .failed)]
        let once = Layout.make(nodes)
        #expect(once == Layout.make(nodes.reversed()))
        // Every state and clock changed: nothing moves.
        let restated = nodes.map { node in
            OverviewGraphNode(id: node.id, parentID: node.parentID, project: node.project, provider: node.provider,
                              activity: node.activity == .waiting ? .working : .waiting, label: node.label,
                              lastActive: node.lastActive + 500)
        }
        let again = Layout.make(restated)
        #expect(again.nodes == once.nodes)
        #expect(again.hubs == once.hubs)
        #expect(again.order == once.order)
    }

    @Test("a worker whose session is off the graph stands alone, and a parent loop ends")
    func orphansAndLoops() {
        let orphan = Layout.make([Self.node("w", parent: "missing")])
        #expect(orphan.nodes["w"]?.isWorker == false)
        #expect(orphan.edges.isEmpty)
        let loop = Layout.make([Self.node("x", parent: "y"), Self.node("y", parent: "x"),
                                Self.node("z", parent: "x")])
        #expect(loop.nodes.count == 3)
        #expect(loop.nodes["x"]?.isWorker == false, "the loop roots at its smallest id")
        #expect(Set(loop.edges) == [.init(from: "x", to: "y"), .init(from: "x", to: "z")])
        #expect(Layout.make([]) == Layout())
    }

    @Test("a session in a worktree sits in its repository's cluster")
    func worktreesJoinTheirRepository() {
        let main = CoreRosterEntry(session: CoreSession(id: "m", provider: "claude", cwd: "/Users/jr/Code/jr-bar"))
        let lane = CoreRosterEntry(session: CoreSession(id: "l", provider: "claude",
                                                        cwd: "/Users/jr/Code/jr-bar/.claude/worktrees/q-graph"))
        #expect(OverviewGraphNode(main).project == "jr-bar")
        #expect(OverviewGraphNode(lane).project == "jr-bar")
        #expect(Layout.make([OverviewGraphNode(main), OverviewGraphNode(lane)]).clusters.count == 1)
    }

    // MARK: Reading the map

    @Test("a point finds the node over the hub over the cluster")
    func hitTesting() throws {
        let layout = Layout.make([Self.node("a"), Self.node("w", parent: "a")])
        let a = try #require(layout.nodes["a"])
        let hub = try #require(layout.hubs.first)
        let cluster = try #require(layout.clusters.first)
        #expect(layout.hit(a.center) == .node("a"))
        #expect(layout.hit(hub.center) == .hub("claude"))
        #expect(layout.hit(CGPoint(x: cluster.frame.minX + 4, y: cluster.frame.minY + 4)) == .cluster("app"))
        #expect(layout.hit(CGPoint(x: -5_000, y: 0)) == nil)
    }

    @Test("a hover lights a node's hub, parents and workers, or a hub's whole fleet")
    func neighbourhoods() {
        let nodes = [Self.node("a"), Self.node("w", parent: "a"), Self.node("ww", parent: "w"),
                     Self.node("b", provider: "codex")]
        let layout = Layout.make(nodes)
        let providers = Dictionary(uniqueKeysWithValues: nodes.map { ($0.id, $0.provider) })
        #expect(layout.neighbourhood(of: .node("w"), providers: providers) == ["w", "a", "ww", "hub:claude"])
        #expect(layout.neighbourhood(of: .node("b"), providers: providers) == ["b", "hub:codex"])
        #expect(layout.neighbourhood(of: .hub("claude"), providers: providers) == ["hub:claude", "a", "w", "ww"])
    }

    @Test("the arrows walk to the nearest node that way, and start at the first")
    func arrowWalk() throws {
        let nodes = [Self.node("a"), Self.node("b"), Self.node("w", parent: "a"), Self.node("l", project: "left")]
        let layout = Layout.make(nodes)
        let first = try #require(layout.order.first)
        #expect(layout.neighbour(of: nil, toward: .down) == first)
        // "a" and "b" share the right-hand cluster, "a" above "b".
        #expect(layout.neighbour(of: "a", toward: .down) == "b")
        #expect(layout.neighbour(of: "b", toward: .up) == "a")
        #expect(layout.neighbour(of: "a", toward: .right) == "w")
        #expect(layout.neighbour(of: "w", toward: .left) == "a")
        #expect(layout.neighbour(of: "a", toward: .left) == "l", "across the hubs to the other side")
        #expect(layout.neighbour(of: "w", toward: .right) == nil)
    }

    @Test("the camera fits the map, zooms about the pointer and pans only as far as it must")
    func camera() {
        let bounds = CGRect(x: -400, y: -200, width: 800, height: 400)
        let whole = GraphCamera.fit(bounds, in: CGSize(width: 1_000, height: 400), inset: 0)
        #expect(abs(whole.scale - 1) < 0.001)
        #expect(whole.screen(CGPoint(x: bounds.midX, y: bounds.midY)) == CGPoint(x: 500, y: 200))
        let tiny = GraphCamera.fit(CGRect(x: 0, y: 0, width: 10, height: 10), in: CGSize(width: 800, height: 600))
        #expect(tiny.scale == GraphCamera.maxFitScale, "a small map is never blown up past the cap")

        let anchor = CGPoint(x: 120, y: 80)
        let pinned = whole.world(anchor)
        let closer = whole.zoomed(by: 2, about: anchor)
        #expect(closer.scale == 2)
        #expect(abs(closer.screen(pinned).x - anchor.x) < 0.001 && abs(closer.screen(pinned).y - anchor.y) < 0.001)
        #expect(whole.zoomed(by: 100, about: anchor).scale == GraphCamera.maxScale)
        #expect(whole.zoomed(by: 0.001, about: anchor).scale == GraphCamera.minScale)

        let size = CGSize(width: 1_000, height: 400)
        #expect(whole.revealing(CGRect(x: 0, y: 0, width: 50, height: 50), in: size) == nil)
        let moved = whole.revealing(CGRect(x: 600, y: 0, width: 50, height: 50), in: size, margin: 20)
        #expect(moved?.scale == whole.scale)
        #expect(moved.map { $0.screen(CGRect(x: 600, y: 0, width: 50, height: 50)).maxX } == 980)
    }

    @Test("the Graph opens whole when it reads, else readable on its middle with the first ask in sight")
    func opening() {
        let size = CGSize(width: 600, height: 400)
        let small = CGRect(x: -300, y: -200, width: 600, height: 400)
        #expect(GraphCamera.opening(small, in: size, focus: nil, inset: 0) == GraphCamera.fit(small, in: size, inset: 0))

        let big = CGRect(x: -1_500, y: -1_000, width: 3_000, height: 2_000)
        let middle = GraphCamera.opening(big, in: size, focus: nil)
        #expect(middle.scale == GraphCamera.readableScale)
        #expect(middle.screen(CGPoint.zero) == CGPoint(x: 300, y: 200))
        let ask = CGRect(x: 1_000, y: 800, width: 200, height: 50)
        let found = GraphCamera.opening(big, in: size, focus: ask)
        #expect(found.scale == GraphCamera.readableScale)
        let shown = found.screen(ask)
        #expect(shown.minX >= 0 && shown.maxX <= size.width && shown.minY >= 0 && shown.maxY <= size.height)
    }

    @Test("a hub's caption counts its sessions and names the loudest state among them")
    func hubCaptions() {
        #expect(OverviewGraphCanvas.hubCaption([.working]) == "1 session · 1 working")
        #expect(OverviewGraphCanvas.hubCaption([.working, .failed, .done]) == "3 sessions · 1 failed")
        #expect(OverviewGraphCanvas.hubCaption([.working, .waiting, .waiting]) == "3 sessions · 2 waiting")
        #expect(OverviewGraphCanvas.hubCaption([.done, .idle]) == "2 sessions")
    }

    @Test("two fingers pan, a wheel pans in bigger steps, and ⌘ turns either into a zoom")
    func pointerIntents() {
        let at = CGPoint(x: 10, y: 20)
        #expect(GraphPointerIntent.from(scrollX: 3, scrollY: -4, precise: true, command: false, at: at)
                == .pan(CGSize(width: 3, height: -4)))
        #expect(GraphPointerIntent.from(scrollX: 0, scrollY: 1, precise: false, command: false, at: at)
                == .pan(CGSize(width: 0, height: 12)))
        guard case .zoom(let factor, let point)? = GraphPointerIntent.from(scrollX: 0, scrollY: 10, precise: true,
                                                                           command: true, at: at) else {
            Issue.record("⌘-scroll should zoom")
            return
        }
        #expect(factor > 1 && point == at)
        #expect(GraphPointerIntent.from(scrollX: 0, scrollY: 0, precise: true, command: false, at: at) == nil)
    }

    // MARK: What the Graph draws

    private static func entry(_ id: String, mode: String, lifecycle: String = "active", parent: String? = nil,
                              updated: Double, hidden: Bool = false, label: String? = nil) -> CoreRosterEntry {
        CoreRosterEntry(session: CoreSession(id: id, provider: "claude", parent: parent, label: label ?? id,
                                             cwd: "/r/app", mode: mode, lifecycle: lifecycle,
                                             since: updated, updatedAt: updated),
                        visibility: hidden ? "hidden" : nil)
    }

    @Test("Active keeps live work and the last hour's finishes, with each kept worker's session")
    func activeScope() {
        let now = Date(timeIntervalSince1970: 100_000)
        let old = now.timeIntervalSince1970 - 2 * 3_600
        let recent = now.timeIntervalSince1970 - 600
        let roster = [
            Self.entry("working", mode: "working", updated: old),
            Self.entry("done-recent", mode: "completed", lifecycle: "completed", updated: recent),
            Self.entry("done-old", mode: "completed", lifecycle: "completed", updated: old),
            Self.entry("parent-old", mode: "completed", lifecycle: "completed", updated: old),
            Self.entry("child", mode: "working", parent: "parent-old", updated: recent),
            Self.entry("hidden", mode: "working", updated: recent, hidden: true),
        ]
        let active = OverviewStore.graphEntries(roster, scope: .active, search: "", now: now).map(\.id)
        #expect(active == ["working", "done-recent", "parent-old", "child"])
        let everything = OverviewStore.graphEntries(roster, scope: .everything, search: "", now: now)
        #expect(everything.count == roster.count)
        let searched = OverviewStore.graphEntries(roster, scope: .everything, search: "done-", now: now).map(\.id)
        #expect(searched == ["done-recent", "done-old"])
    }

    @Test("a node picked on the Graph is the inspector's, and Show in Roster finds its row")
    func selection() {
        let store = OverviewStore(core: CoreModel())
        store.roster = [Self.entry("old", mode: "completed", lifecycle: "completed", updated: 1)]
        store.filter = OverviewFilter(preset: .needsMe)
        store.showGraph()
        store.selectInGraph("old")
        #expect(store.selected?.id == "old", "the Graph resolves against the whole roster")
        store.showInRoster("old")
        #expect(store.pane == .roster)
        #expect(store.filter.preset == .all)
        #expect(store.selected?.id == "old")
        store.selectInGraph(nil)
        #expect(store.selectedIDs.isEmpty)
    }

    final class Tripped: @unchecked Sendable { var fired = false }

    @Test("Everything's nodes ignore the one-second clock; Active's follow it")
    func everythingIgnoresTheClock() {
        let store = OverviewStore(core: CoreModel())
        store.roster = [Self.entry("done", mode: "completed", lifecycle: "completed", updated: 1)]
        store.graphScope = .everything
        let everything = Tripped()
        withObservationTracking { _ = store.graphNodes } onChange: { everything.fired = true }
        store.now = store.now.addingTimeInterval(1)
        #expect(!everything.fired, "a tick must not lay the whole record out again")

        store.graphScope = .active
        let active = Tripped()
        withObservationTracking { _ = store.graphNodes } onChange: { active.fired = true }
        store.now = store.now.addingTimeInterval(1)
        #expect(active.fired, "Active's one-hour horizon moves with the clock")
    }

    @Test("only working and waiting marks sit under the timeline")
    func movingMarks() {
        let moving: [SessionActivity] = [.working, .waiting]
        for activity in SessionActivity.allCases {
            #expect(GraphSceneModel.moves(activity) == moving.contains(activity))
        }
    }
}
