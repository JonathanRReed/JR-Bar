import CoreGraphics
import Testing
import JRBarCore
@testable import JRBarApp

@MainActor
@Suite struct OverviewGraphNetworkTests {
    private func nodes(_ count: Int) -> [OverviewGraphNode] {
        (0..<count).map { index in
            OverviewGraphNode(id: "n\(index)", parentID: index % 4 == 1 ? "n\(index - 1)" : nil,
                              project: "project\(index / 8)", provider: index % 2 == 0 ? "claude" : "codex",
                              activity: .working, label: "Session \(index)")
        }
    }

    @Test func denseAndSparseFleetsHaveOneHitTargetPerSession() {
        for count in [1, 16, 64] {
            let source = nodes(count)
            let layout = OverviewGraphLayout.make(source, presentation: .network)
            #expect(layout.presentation == .network)
            #expect(layout.nodes.count == count)
            #expect(Set(layout.order).count == count)
            #expect(layout.bounds.width.isFinite && layout.bounds.height.isFinite)
            let frames = Array(layout.nodes.values.map(\.frame))
            for (index, frame) in frames.enumerated() {
                #expect(!frames.dropFirst(index + 1).contains { frame.intersects($0) })
                #expect(layout.bounds.contains(frame))
            }
            for id in layout.order {
                if let placed = layout.nodes[id] { #expect(layout.hit(placed.center) == .node(id)) }
            }
            let map = OverviewGraphLayout.make(source)
            #expect(Set(layout.edges) == Set(map.edges))
            #expect(Set(layout.hubs.flatMap(\.sessionIDs)) == Set(map.hubs.flatMap(\.sessionIDs)))
        }
    }

    @Test func stateChangesNeverMoveNetworkNodes() {
        let source = nodes(16)
        let changed = source.map { node in
            OverviewGraphNode(id: node.id, parentID: node.parentID, project: node.project,
                              provider: node.provider, activity: .waiting, label: node.label)
        }
        let first = OverviewGraphLayout.make(source, presentation: .network)
        let second = OverviewGraphLayout.make(changed, presentation: .network)
        #expect(first.placesMatch(second))
    }

    @Test func cyclesAndMissingParentsReuseTheMapsActualEdges() {
        let source = [
            OverviewGraphNode(id: "a", parentID: "b", project: "one", provider: "claude", activity: .working, label: "A"),
            OverviewGraphNode(id: "b", parentID: "a", project: "two", provider: "codex", activity: .working, label: "B"),
            OverviewGraphNode(id: "c", parentID: "missing", provider: "claude", activity: .working, label: "C"),
            OverviewGraphNode(id: "d", parentID: "d", provider: "codex", activity: .working, label: "D"),
            OverviewGraphNode(id: "e", parentID: "b", project: "three", provider: "gemini", activity: .working, label: "E"),
        ]
        let map = OverviewGraphLayout.make(source)
        let layout = OverviewGraphLayout.make(source, presentation: .network)
        #expect(Set(layout.order) == Set(source.map(\.id)))
        #expect(Set(layout.edges) == Set(map.edges))
        #expect(layout.nodes["c"]?.parentID == nil)
        #expect(layout.nodes["d"]?.parentID == nil)
        #expect(layout.nodes["e"]?.parentID == "b")
        #expect(layout.nodes["e"]?.depth == 2)
        #expect(layout.neighbour(of: nil, toward: .right) != nil)
    }

    @Test func directionalNavigationCanReachEveryRadialNode() {
        let layout = OverviewGraphLayout.make(nodes(16), presentation: .network)
        var reached: Set<String> = [layout.order[0]]
        var queue = [layout.order[0]]
        while !queue.isEmpty {
            let id = queue.removeFirst()
            for direction in [OverviewGraphLayout.Direction.up, .down, .left, .right] {
                if let next = layout.neighbour(of: id, toward: direction), reached.insert(next).inserted {
                    queue.append(next)
                }
            }
        }
        #expect(reached == Set(layout.order))
    }
    @Test func provenCompatibilityProvenanceNeverChangesTheProviderHub() {
        let session = CoreSession(id: "imported", provider: "codex", label: "Synthetic task",
                                  sourceIntegration: "t3code")
        let node = OverviewGraphNode(CoreRosterEntry(session: session))
        #expect(node.provider == "codex")
        #expect(node.provenance == "from T3 Code")
        let layout = OverviewGraphLayout.make([node], presentation: .network)
        #expect(layout.hubs.map(\.id) == ["codex"])
        let titleOnly = CoreSession(id: "native", provider: "claude", label: "T3 Code in a title")
        #expect(OverviewGraphNode(CoreRosterEntry(session: titleOnly)).provenance == nil)
        let legacy = OverviewGraphNode(id: "old", provider: "t3code", activity: .idle, label: "Imported")
        #expect(legacy.provider == "unknown")
        #expect(OverviewGraphLayout.make([legacy]).hubs.map(\.id) == ["unknown"])
        #expect(legacy.provenance == "Legacy T3 Code import · provider unknown")
    }

    @Test func denseNetworkFitsTheViewportAndSelectionBecomesReadable() throws {
        let layout = OverviewGraphLayout.make(nodes(64), presentation: .network)
        for size in [CGSize(width: 400, height: 600), CGSize(width: 1000, height: 720)] {
            let camera = GraphCamera.fit(layout.bounds, in: size, inset: 16, minimumScale: 0.01)
            let shown = camera.screen(layout.bounds)
            #expect(shown.minX >= 15.9 && shown.minY >= 15.9)
            #expect(shown.maxX <= size.width - 15.9 && shown.maxY <= size.height - 15.9)
            let id = layout.order[0]
            let readable = try #require(OverviewGraphCanvas.selectionCamera(camera, layout: layout, id: id, size: size))
            #expect(readable.scale >= GraphCamera.readableScale)
            let frame = try #require(layout.nodes[id]?.frame)
            #expect(CGRect(origin: .zero, size: size).contains(readable.screen(frame)))
        }
    }

    @Test func freshOverviewUsesRadialNetworkAndMapRemainsAvailable() {
        let store = OverviewStore(core: CoreModel())
        #expect(store.graphPresentation == .network)
        store.graphPresentation = .map
        #expect(store.graphPresentation == .map)
    }

}

@Suite struct GraphFramingTests {
    private func fleet(_ count: Int = 64, providers: [String] = ["claude", "codex"]) -> [OverviewGraphNode] {
        (0..<count).map { index in
            OverviewGraphNode(id: "camera\(index)", parentID: index % 4 == 1 ? "camera\(index - 1)" : nil,
                              project: "project\(index / 8)", provider: providers[index % providers.count],
                              activity: .working, label: "Session \(index)")
        }
    }

    @Test func denseOpeningShowsTheFocusAndItsOwningHubWhenReadable() throws {
        let layout = OverviewGraphLayout.make(fleet(), presentation: .network)
        for size in [CGSize(width: 400, height: 600), CGSize(width: 1000, height: 650)] {
            let viewport = CGRect(origin: .zero, size: size)
            for id in layout.order {
                let frame = try #require(layout.nodes[id]?.frame)
                let hub = try #require(layout.hubs.first { hub in
                    hub.sessionIDs.contains { $0 == id || layout.descendants(of: $0).contains(id) }
                })
                let camera = GraphFraming.opening.camera(for: layout, in: size, focus: id)
                #expect(camera.scale >= GraphCamera.networkCaptionScale)
                #expect(viewport.contains(camera.screen(frame)))
                let context = frame.union(hub.frame).union(hub.captionFrame).insetBy(dx: -24, dy: -24)
                let possible = GraphCamera.fit(context, in: size, inset: 16, minimumScale: 0.01)
                if possible.scale >= GraphCamera.networkCaptionScale {
                    #expect(viewport.contains(camera.screen(hub.frame)))
                    #expect(viewport.contains(camera.screen(hub.captionFrame)))
                }
            }
        }
    }

    @Test func crossProviderWorkersKeepTheirParentsProviderContext() throws {
        let source = fleet(providers: ["claude", "codex", "gemini", "jrbar", "devin"])
        let layout = OverviewGraphLayout.make(source, presentation: .network)
        let worker = try #require(layout.nodes["camera1"])
        #expect(worker.parentID == "camera0")
        let hub = try #require(layout.hubs.first { $0.id == "claude" })
        #expect(hub.sessionIDs.contains("camera0"))
        #expect(!hub.sessionIDs.contains("camera1"))
        let size = CGSize(width: 1000, height: 650)
        let context = worker.frame.union(hub.frame).union(hub.captionFrame).insetBy(dx: -24, dy: -24)
        let possible = GraphCamera.fit(context, in: size, inset: 16, minimumScale: 0.01)
        try #require(possible.scale >= GraphCamera.networkCaptionScale)
        #expect(GraphFraming.whole.camera(for: layout, in: size).scale < GraphCamera.networkCaptionScale)
        let camera = GraphFraming.opening.camera(for: layout, in: size, focus: worker.id)
        let viewport = CGRect(origin: .zero, size: size)
        #expect(viewport.contains(camera.screen(worker.frame)))
        #expect(viewport.contains(camera.screen(hub.frame.union(hub.captionFrame))))
    }

    @Test func smallNetworkOpensWholeAndDenseWholeRemainsASeparateChoice() throws {
        let size = CGSize(width: 1000, height: 650)
        let small = OverviewGraphLayout.make(fleet(1), presentation: .network)
        #expect(GraphFraming.opening.camera(for: small, in: size) == GraphFraming.whole.camera(for: small, in: size))
        let dense = OverviewGraphLayout.make(fleet(), presentation: .network)
        let whole = GraphFraming.whole.camera(for: dense, in: size)
        #expect(whole.scale < GraphCamera.networkCaptionScale)
        #expect(CGRect(origin: .zero, size: size).contains(whole.screen(dense.bounds)))
        #expect(GraphFraming.opening.camera(for: dense, in: size).scale >= GraphCamera.networkCaptionScale)
    }

    @Test func missingFocusUsesTheFirstRealSession() throws {
        let layout = OverviewGraphLayout.make(fleet(), presentation: .network)
        let first = try #require(layout.order.first)
        let size = CGSize(width: 400, height: 600)
        let expected = GraphFraming.opening.camera(for: layout, in: size, focus: first)
        #expect(GraphFraming.opening.camera(for: layout, in: size) == expected)
        #expect(GraphFraming.opening.camera(for: layout, in: size, focus: "missing") == expected)
    }

    @Test func unreadableProviderContextCentersTheFocusedSession() throws {
        let layout = OverviewGraphLayout.make(fleet(), presentation: .network)
        let id = try #require(layout.order.first)
        let frame = try #require(layout.nodes[id]?.frame)
        let size = CGSize(width: 160, height: 160)
        let camera = GraphFraming.opening.camera(for: layout, in: size, focus: id)
        #expect(camera.scale == GraphCamera.readableScale)
        let center = camera.screen(CGPoint(x: frame.midX, y: frame.midY))
        #expect(abs(center.x - size.width / 2) < 0.000001)
        #expect(abs(center.y - size.height / 2) < 0.000001)
    }

    @Test func manualFramingSurvivesResizeAndRosterReplacementExactly() {
        let camera = GraphCamera(scale: 0.137, offset: CGPoint(x: -412.5, y: 219.25))
        for count in [0, 1, 64] {
            for presentation in OverviewGraphLayout.Presentation.allCases {
                let layout = OverviewGraphLayout.make(fleet(count), presentation: presentation)
                for size in [CGSize(width: 400, height: 600), CGSize(width: 1200, height: 800)] {
                    #expect(GraphFraming.manual(camera).camera(for: layout, in: size, focus: "camera0") == camera)
                }
            }
        }
    }

    @Test func cabinetOpeningAndWholeKeepTheirExistingCameraRules() throws {
        let layout = OverviewGraphLayout.make(fleet())
        let id = try #require(layout.order.first)
        let frame = try #require(layout.nodes[id]?.frame.insetBy(dx: -12, dy: -12))
        for size in [CGSize(width: 400, height: 600), CGSize(width: 1000, height: 650)] {
            let expected = GraphCamera.opening(layout.bounds, in: size, focus: frame, inset: 16)
            #expect(GraphFraming.opening.camera(for: layout, in: size, focus: id) == expected)
            let whole = GraphCamera.fit(layout.bounds, in: size, inset: 16)
            #expect(GraphFraming.whole.camera(for: layout, in: size) == whole)
        }
    }

    @Test func emptyNetworkHasAValidWholeCamera() {
        let layout = OverviewGraphLayout.make([], presentation: .network)
        let size = CGSize(width: 400, height: 600)
        let camera = GraphFraming.opening.camera(for: layout, in: size, focus: "missing")
        #expect(camera == GraphFraming.whole.camera(for: layout, in: size))
        #expect(camera.scale.isFinite && camera.scale > 0)
        #expect(camera.offset.x.isFinite && camera.offset.y.isFinite)
    }
}
