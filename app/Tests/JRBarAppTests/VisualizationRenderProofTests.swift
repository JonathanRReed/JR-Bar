import Foundation
import SwiftUI
import Testing
@testable import JRBarApp
@testable import JRBarCore

@Suite("Usage and Network render proof", .serialized)
@MainActor
struct VisualizationRenderProofTests {
    private func connectedCore() throws -> CoreModel {
        let core = CoreModel(socketPath: NSTemporaryDirectory() + "jrbar-visualization-proof.sock")
        core.handle(.connected)
        core.apply(.state(CoreState(sessions: [])))
        try #require(core.isLive, "A chart proof requires a connected state snapshot")
        return core
    }

    private func usageGraph() throws -> CoreUsageGraph {
        var graph = CoreUsageGraph()
        graph.metric = "cost"
        graph.days = 7
        graph.periodLabel = "Oct 7 to Oct 13 · 7 days"
        graph.labels = ["Oct 7", "", "Oct 9", "", "Oct 11", "", "Oct 13"]
        graph.providers = ["claude", "codex", "gemini", "factory"]
        graph.partialProviderIds = ["gemini"]
        graph.costSemantics = "api_equivalent_estimate"
        graph.series = [
            .init(providerId: "claude", values: [1.2, 1.8, 2.4, 2.4, 1.8, 2.4, 2.4], hasPricedUsage: true),
            .init(providerId: "codex", values: [0.6, 0.9, 1.2, 1.2, 0.9, 1.2, 1.2], hasPricedUsage: true),
            .init(providerId: "gemini", values: [0.3, 0.3, 0.6, -1, 0.3, 0.3, 0.6], hasPricedUsage: true),
            .init(providerId: "factory", values: [0, 0, 0, 0, 0, 0, 0], hasPricedUsage: false),
        ]
        let data = Data(#"{"observed_records":100,"priced_records":80,"unpriced_records":20,"unpriced_sessions":6,"token_categories":{"input":24000,"cached_input":81000,"cache_creation":4500,"output":7800}}"#.utf8)
        graph.scaleMax = 5
        #expect(graph.series.flatMap(\.values).allSatisfy { $0 <= graph.scaleMax })
        graph.costCoverage = try JSONDecoder().decode(CoreUsageCostCoverage.self, from: data)
        graph.sourceStatistics = [.init(sourceId: "t3code", label: "T3 Code", attributionStatus: "mixed",
            tokens: 105, sessions: 3, includedTokens: 35, includedSessions: 1,
            dataStatus: "partial", providerIds: ["claude", "codex"])]
        return graph
    }

    @Test(.enabled(if: WindowsRenderProofTests.enabled))
    func usagePresentations() throws {
        let graph = try usageGraph()
        for composition in [false, true] {
            for width in [CGFloat(400), CGFloat(860)] {
                let core = try connectedCore()
                let store = OverviewStore(core: core)
                store.graph = CoreUsageGraphDocument(graph: graph, summary: "Synthetic fixture. Factory pricing has no verified telemetry.")
                store.graphDays = 7
                store.graphMetric = "cost"
                store.graphComposition = composition
                store.graphProviderOptions = graph.providers
                try #require(store.isLive && store.graph != nil)
                #expect(store.graphComposition == composition)
                let name = "usage-\(composition ? "composition" : "trends")-\(Int(width))"
                try WindowsRenderProofTests.write(name, size: CGSize(width: width, height: 920)) {
                    UsageGraphView(store: store)
                }
            }
        }
        let core = try connectedCore()
        let store = OverviewStore(core: core)
        store.graph = CoreUsageGraphDocument(graph: graph, summary: "Synthetic fixture. Factory pricing has no verified telemetry.")
        store.graphMetric = "tokens"
        store.graphDays = 30
        store.graphError = "Fixture refresh failure"
        try WindowsRenderProofTests.write("usage-previous-loaded-range", size: CGSize(width: 620, height: 920)) {
            UsageGraphView(store: store)
        }
        var underscaled = graph
        underscaled.scaleMax = 1
        store.graph = CoreUsageGraphDocument(graph: underscaled)
        store.graphError = nil
        store.graphMetric = "cost"
        store.graphDays = 7
        try WindowsRenderProofTests.write("usage-underscaled-metadata", size: CGSize(width: 400, height: 920)) {
            UsageGraphView(store: store)
        }
        var unfinished = graph
        unfinished.readingFiles = 3
        store.graph = CoreUsageGraphDocument(graph: unfinished, summary: "Still reading 3 files")
        for width in [CGFloat(400), CGFloat(860)] {
            try WindowsRenderProofTests.write("usage-scan-in-progress-\(Int(width))",
                                              size: CGSize(width: width, height: 920)) {
                UsageGraphView(store: store)
            }
        }
    }

    @Test(.enabled(if: WindowsRenderProofTests.enabled))
    func legacyCalendarDrilldown() throws {
        var graph = CoreUsageGraph()
        graph.metric = "tokens"
        graph.days = 2
        graph.periodLabel = "Dec 31, 2024 to Jan 1, 2025"
        graph.labels = ["12/31", "01/01"]
        graph.providers = ["claude", "t3code"]
        graph.series = [.init(providerId: "claude", values: [10, 20]),
                        .init(providerId: "t3code", values: [5, 7])]
        let data = Data(#"{"days":["2024-12-31","2025-01-01"],"providers":{"t3code":{"provider_id":"t3code","cells":[],"totals":{"tokens":12,"sessions":1},"data_status":"available"}},"aggregate":{"provider_id":"all","cells":[],"totals":{"tokens":42,"sessions":3},"data_status":"available"},"timezone":"UTC"}"#.utf8)
        graph.heatmap = try JSONDecoder().decode(CoreUsageHeatmap.self, from: data)
        graph.scaleMax = 50
        let core = try connectedCore()
        let store = OverviewStore(core: core)
        store.graph = CoreUsageGraphDocument(graph: graph)
        store.graphMetric = "tokens"
        store.graphDays = 7
        store.graphComposition = true
        try WindowsRenderProofTests.write("usage-composition-legacy-calendar", size: CGSize(width: 620, height: 920)) {
            UsageGraphView(store: store)
        }
    }

    @Test(.enabled(if: WindowsRenderProofTests.enabled))
    func networkFleets() throws {
        let now = Date(timeIntervalSince1970: 1_770_000_000)
        var busy = OverviewGraphRenderProofTests.busyRoster(now: now)
        busy[0].session.sourceIntegration = "t3code"
        var fleet = OverviewGraphRenderProofTests.fleetRoster(now: now)
        for index in 60..<64 {
            fleet.append(CoreRosterEntry(session: CoreSession(id: "extra\(index)", provider: "codex",
                kind: "main", label: "Session \(index)", cwd: "/synthetic/extra", mode: "working")))
        }
        for (label, roster) in [("16", busy), ("64", fleet)] {
            for width in [CGFloat(400), CGFloat(1000)] {
                for presentation in OverviewGraphLayout.Presentation.allCases {
                    let store = OverviewGraphRenderProofTests.store(roster, now: now)
                    store.graphPresentation = presentation
                    store.graphScope = .everything
                    store.selectInGraph(roster[0].id)
                    let style = presentation == .map ? "cabinet" : "network"
                    try WindowsRenderProofTests.write("overview-\(style)-\(label)-\(Int(width))",
                                                      size: CGSize(width: width, height: 720)) {
                        OverviewGraphView(store: store, frozenTime: 1.35, reduceMotionOverride: true)
                    }
                }
            }
        }
        for selection in ["unselected", "worker"] {
            let store = OverviewGraphRenderProofTests.store(fleet, now: now)
            store.graphPresentation = .network
            store.graphScope = .everything
            if selection == "worker", let worker = fleet.first(where: { $0.session.parent != nil }) {
                store.selectInGraph(worker.id)
            }
            try WindowsRenderProofTests.write("overview-network-64-\(selection)-400",
                                              size: CGSize(width: 400, height: 720)) {
                OverviewGraphView(store: store, frozenTime: 1.35, reduceMotionOverride: true)
            }
        }
        let fitNodes = fleet.map(OverviewGraphNode.init)
        let fitLayout = OverviewGraphLayout.make(fitNodes, presentation: .network)
        let fitModel = GraphSceneModel(layout: fitLayout, previous: nil,
            nodes: Dictionary(uniqueKeysWithValues: fitNodes.map { ($0.id, $0) }),
            captions: [:], hubCaptions: [:], unseen: [], selectedID: nil, lit: nil,
            now: now.timeIntervalSince1970)
        for width in [CGFloat(400), CGFloat(1000)] {
            let size = CGSize(width: width, height: 720)
            let camera = GraphFraming.whole.camera(for: fitLayout, in: size)
            try WindowsRenderProofTests.write("overview-network-64-fit-\(Int(width))", size: size) {
                GraphScene(model: fitModel, camera: camera, settle: 0, dim: 0, generation: 0,
                           motion: false, running: false, frozenTime: 1.35)
                    .frame(width: size.width, height: size.height)
            }
        }
        let disconnected = OverviewGraphRenderProofTests.store(busy, now: now)
        disconnected.core.handle(.disconnected(reason: "Fixture disconnect"))
        disconnected.graphPresentation = .network
        try WindowsRenderProofTests.write("overview-network-disconnected", size: CGSize(width: 900, height: 640)) {
            OverviewGraphView(store: disconnected, frozenTime: 1.35, reduceMotionOverride: true)
        }
    }
}
