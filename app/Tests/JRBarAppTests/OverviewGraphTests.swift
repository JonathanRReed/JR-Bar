import CoreGraphics
import Foundation
import Testing
import JRBarCore
@testable import JRBarApp

/// The Overview's Graph: what it draws, and where. The layout is pure, so
/// its promises — workers under their session, the urgent card first,
/// nothing overlapping, the same picture twice — are checked directly.
@MainActor
@Suite struct OverviewGraphTests {
    private static func node(_ id: String, parent: String? = nil, project: String? = "app",
                             _ activity: SessionActivity = .working, last: Double = 0) -> OverviewGraphNode {
        OverviewGraphNode(id: id, parentID: parent, project: project, provider: "claude",
                          activity: activity, label: id, lastActive: last)
    }

    @Test("workers hang in rows under their session, joined by an edge each")
    func familiesAndEdges() throws {
        let nodes = [Self.node("main")] + (1...6).map { Self.node("w\($0)", parent: "main") }
        let layout = OverviewGraphLayout.make(nodes, width: 1_000)
        let main = try #require(layout.nodes["main"])
        #expect(!main.isWorker)
        #expect(Set(layout.edges) == Set((1...6).map { OverviewGraphLayout.Edge(from: "main", to: "w\($0)") }))
        let workers = try (1...6).map { try #require(layout.nodes["w\($0)"]) }
        #expect(workers.allSatisfy { $0.isWorker && $0.center.y > main.stem.y })
        // Six workers make two rows; the second sits half a slot over, so
        // its drops pass between the first row's nodes.
        let rows = Dictionary(grouping: workers, by: { $0.center.y })
        #expect(rows.count == 2)
        let first = try #require(rows.keys.min().flatMap { rows[$0] }).map(\.center.x).sorted()
        let second = try #require(rows.keys.max().flatMap { rows[$0] }).map(\.center.x).sorted()
        #expect(first.count == 4 && second.count == 2)
        for x in second { #expect(first.allSatisfy { abs($0 - x) > 20 }) }
        // The edges leave from under the caption, never through it.
        #expect(main.stem.y >= main.center.y + main.diameter / 2 + OverviewGraphLayout.Metrics.rootCaption)
    }

    @Test("the card with someone waiting comes first, and cards never overlap")
    func clusterOrderAndSpacing() {
        let nodes = [
            Self.node("quiet", project: "docs", .idle, last: 900),
            Self.node("busy", project: "api", .working, last: 800),
            Self.node("ask", project: "site", .waiting, last: 100),
            Self.node("gone", project: nil, .done, last: 50),
        ]
        let layout = OverviewGraphLayout.make(nodes, width: 600)
        // The panel's order: waiting, failed, working, done, ended, idle.
        #expect(layout.clusters.map(\.id) == ["site", "api", "", "docs"])
        #expect(layout.clusters.first { $0.id.isEmpty }?.title == "No folder")
        for (index, a) in layout.clusters.enumerated() {
            #expect(a.frame.maxX <= 600 - OverviewGraphLayout.Metrics.margin + 0.5)
            for b in layout.clusters.dropFirst(index + 1) { #expect(!a.frame.intersects(b.frame)) }
            for id in a.nodeIDs {
                #expect(a.frame.contains(layout.nodes[id]?.center ?? .zero))
            }
        }
        #expect(layout.size.height >= (layout.clusters.map(\.frame.maxY).max() ?? 0))
        #expect(layout.clusters.first?.counts == [.waiting: 1])
    }

    @Test("the same sessions at the same width land in the same places, in any order")
    func deterministic() {
        let nodes = [Self.node("a", last: 3), Self.node("b", .waiting, last: 2), Self.node("c", parent: "a"),
                     Self.node("d", project: "other", .failed)]
        let once = OverviewGraphLayout.make(nodes, width: 800)
        let again = OverviewGraphLayout.make(nodes.reversed(), width: 800)
        #expect(once == again)
        #expect(once.order.first == "b", "the waiting session leads its card")
    }

    @Test("a worker whose session is off the graph stands alone, and a parent loop ends")
    func orphansAndLoops() {
        let orphan = OverviewGraphLayout.make([Self.node("w", parent: "missing")], width: 500)
        #expect(orphan.nodes["w"]?.isWorker == false)
        #expect(orphan.edges.isEmpty)
        let loop = OverviewGraphLayout.make([Self.node("x", parent: "y"), Self.node("y", parent: "x"),
                                             Self.node("z", parent: "x")], width: 500)
        #expect(loop.nodes.count == 3)
        #expect(loop.nodes["x"]?.isWorker == false, "the loop roots at its smallest id")
        #expect(Set(loop.edges) == [.init(from: "x", to: "y"), .init(from: "x", to: "z")])
        #expect(OverviewGraphLayout.make([], width: 500) == OverviewGraphLayout())
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
    func inkLayers() {
        let moving: [SessionActivity] = [.working, .waiting]
        for activity in [SessionActivity.working, .waiting, .failed, .done, .idle, .ended] {
            #expect(GraphInkLayer.ring(activity) == (moving.contains(activity) ? .moving : .still))
            #expect(GraphInkLayer.drop(activity) == (activity == .working ? .moving : .still))
        }
    }
}
