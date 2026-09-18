import Foundation
import Testing
@testable import JRBarCore

/// `usage_graph` decoding: the shared-axis document — strided labels,
/// per-provider series (gap days carried as negatives), the resolved
/// provider echo, the day-grid heatmap, and the disclosures. The fixture
/// is a synthetic percent model projected by the daemon's own
/// `usage_graph_document`, so decoding it is the transport's parity
/// check — including the multi-instance rows percent mode emits.
@Suite struct UsageGraphCodecTests {

    private func decode() throws -> CoreUsageGraphDocument {
        let data = try CoreFixtures.data("usage_graph.json")
        return try JSONDecoder().decode(CoreUsageGraphDocument.self, from: data)
    }

    @Test func documentDecodesGraphAndSummary() throws {
        let document = try decode()
        #expect(document.summary.contains("Last 30 days"))
        #expect(document.summary.contains("Partial local history"))
        let graph = document.graph
        #expect(graph.days == 30)
        #expect(graph.periodLabel == "Last 30 days")
        #expect(graph.metric == "percent")
        #expect(graph.scaleMax == 100)
    }

    @Test func resolvedProvidersEchoTheRequest() throws {
        let graph = try decode().graph
        // `providers` is the resolved request — including cursor, which
        // checked in but had no samples, so series omits it. Without the
        // echo a picker cannot tell unchecked from checked-but-empty.
        #expect(graph.providers == ["claude", "codex", "cursor"])
        #expect(graph.series.map(\.providerId) == ["claude", "codex", "codex"])
    }

    /// Percent mode emits one series per (provider, instance): two rows
    /// share `providerId`, so identity must carry the instance — a chart
    /// keyed on provider alone would merge them into one fabricated line.
    @Test func instancesKeepDistinctSeriesKeys() throws {
        let graph = try decode().graph
        #expect(graph.series.count == 3)
        #expect(graph.series.map(\.seriesKey) == ["claude·default", "codex·default", "codex·work"])
        #expect(Set(graph.series.map(\.seriesKey)).count == 3)
        #expect(graph.series.map(\.label) == ["claude", "codex", "codex · work"])
        #expect(graph.series.map(\.sourceInstanceId) == ["default", "default", "work"])
    }

    @Test func gapDaysStayNegative() throws {
        let graph = try decode().graph
        let codexDefault = graph.series.first { $0.seriesKey == "codex·default" }
        #expect(codexDefault != nil)
        // Codex's first week precedes its first sample — the view must
        // see real negatives to break the line on.
        #expect(codexDefault?.values.prefix(6).allSatisfy { $0 < 0 } == true)
        #expect(codexDefault?.values.dropFirst(6).allSatisfy { $0 >= 0 } == true)
        #expect(codexDefault?.values.count == 30)
        // The second instance starts later — its gap is longer.
        let codexWork = graph.series.first { $0.seriesKey == "codex·work" }
        #expect(codexWork?.values.prefix(12).allSatisfy { $0 < 0 } == true)
        #expect(codexWork?.values.dropFirst(12).allSatisfy { $0 >= 0 } == true)
    }

    @Test func stridedLabelsLand() throws {
        let graph = try decode().graph
        #expect(graph.labels.count == 30)
        #expect(graph.labels[0] == "09/03")
        #expect(graph.labels[1].isEmpty)
    }

    @Test func heatmapProjectsTheDayGrid() throws {
        let heatmap = try decode().graph.heatmap
        #expect(heatmap != nil)
        #expect(heatmap?.days.count == 30)
        #expect(heatmap?.days.first == "2026-09-03")
        #expect(heatmap?.timezone == "America/Los_Angeles")
        let claude = heatmap?.providers["claude"]
        #expect(claude?.cells.count == 30)
        #expect(claude?.cells[0].day == "2026-09-03")
        #expect(claude?.cells[0].tokens == 12000)
        #expect(claude?.cells[0].sessions == 2)
        #expect(claude?.totals.tokens == 450000)
        #expect(claude?.totals.sessions == 60)
        #expect(claude?.dataStatus == "available")
        #expect(heatmap?.providers["cursor"]?.dataStatus == "unavailable")
        #expect(heatmap?.aggregate.providerId == "all")
        #expect(heatmap?.aggregate.totals.tokens == 685200)
        #expect(heatmap?.aggregate.cells.first?.accessibilityLabel.isEmpty == false)
    }

    @Test func partialCoverageDisclosureSurvives() throws {
        let graph = try decode().graph
        #expect(graph.partialProviderIds == ["t3code"])
        // `cost_semantics` is only present for the cost metric.
        #expect(graph.costSemantics == nil)
    }

    @Test func sparseDocumentStillDecodes() throws {
        // A document carrying only what a degenerate reply guarantees —
        // the pane must render its empty state, not crash.
        let data = try JSONSerialization.data(withJSONObject: [
            "graph": ["days": 7, "metric": "tokens"],
            "summary": "",
        ])
        let document = try JSONDecoder().decode(CoreUsageGraphDocument.self, from: data)
        #expect(document.graph.days == 7)
        #expect(document.graph.series.isEmpty)
        #expect(document.graph.heatmap == nil)
        #expect(document.graph.providers.isEmpty)
        #expect(document.summary.isEmpty)
    }
}
