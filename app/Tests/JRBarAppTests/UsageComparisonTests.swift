import Foundation
import Testing
import JRBarCore
@testable import JRBarApp

@Suite struct UsageComparisonTests {
    private func graph(_ metric: String = "tokens") -> CoreUsageGraph {
        var graph = CoreUsageGraph()
        graph.days = 3
        graph.metric = metric
        graph.providers = ["claude", "codex", "gemini", "factory"]
        graph.partialProviderIds = ["gemini"]
        graph.series = [
            .init(providerId: "claude", values: [10, 20, 30], hasPricedUsage: true),
            .init(providerId: "codex", values: [0, 10, -1], hasPricedUsage: true),
            .init(providerId: "gemini", values: [0, 0, 0], hasPricedUsage: false),
        ]
        return graph
    }

    @Test func recordedTotalsSharesAndMissingDays() throws {
        let comparison = try #require(UsageComparison.make(graph()))
        #expect(comparison.total == 70)
        #expect(comparison.providers.map(\.id) == ["claude", "codex", "gemini", "factory"])
        #expect(comparison.providers[0].share == 60.0 / 70.0)
        #expect(comparison.providers[2].amount == .known(0))
        #expect(comparison.providers[2].partial)
        #expect(comparison.providers[3].amount == .missing)
        #expect(comparison.providers[3].share == nil)
        #expect(comparison.days[2].missing == ["codex", "factory"])
        #expect(comparison.days.map(\.total) == [10, 30, 30])
        for day in comparison.days {
            #expect(day.portions.map(\.value).reduce(0, +) == day.total)
        }
    }

    @Test func costNeverPricesUnknownUsageAsZero() throws {
        let comparison = try #require(UsageComparison.make(graph("cost")))
        let unknown = try #require(comparison.providers.first { $0.id == "gemini" })
        #expect(unknown.amount == .unpriced)
        #expect(unknown.share == nil)
        #expect(comparison.days.allSatisfy { $0.unpriced == ["gemini"] })
        #expect(comparison.total == 70)
        #expect(comparison.denominator == "known estimate")
    }

    @Test func knownFreePricesHaveZeroAmountAndNoShareDenominator() throws {
        var source = graph("cost")
        source.providers = ["codex"]
        source.series = [.init(providerId: "codex", values: [0, 0, 0], hasPricedUsage: true)]
        let comparison = try #require(UsageComparison.make(source))
        #expect(comparison.total == 0)
        #expect(comparison.providers[0].amount == .known(0))
        #expect(comparison.providers[0].share == nil)
        #expect(comparison.days.allSatisfy { !$0.incomplete })
    }

    @Test func whollyMissingHistoryHasNoZeroTotal() throws {
        var source = graph()
        source.series = []
        let comparison = try #require(UsageComparison.make(source))
        #expect(comparison.total == nil)
        #expect(comparison.providers.allSatisfy { $0.amount == .missing && $0.share == nil })
        #expect(comparison.days.allSatisfy { $0.portions.isEmpty && $0.incomplete })
    }

    @Test func totalsUseOnlyTheLoadedRangeAndMetric() throws {
        var source = graph("sessions")
        source.days = 1
        let comparison = try #require(UsageComparison.make(source))
        #expect(comparison.total == 10)
        #expect(comparison.days.count == 1)
        #expect(comparison.title == "Recorded sessions")
        #expect(comparison.denominator == "recorded sessions")
    }

    @Test func quotaInstancesNeverGetAnAdditiveComparison() {
        var source = graph("percent")
        source.series = [
            .init(providerId: "codex", sourceInstanceId: "default", values: [70, 50, 40]),
            .init(providerId: "codex", sourceInstanceId: "work", values: [80, 60, 30]),
        ]
        #expect(UsageComparison.make(source) == nil)
    }
    @Test func unpricedCostNeverAddsAZeroTrendPoint() {
        var source = graph("cost")
        source.series = [.init(providerId: "gemini", values: [0, 0, 0], hasPricedUsage: false)]
        #expect(UsageGraphView.splitPoints(source).isEmpty)
        source.series = [.init(providerId: "codex", values: [0, 0, 0], hasPricedUsage: true)]
        #expect(UsageGraphView.splitPoints(source).count == 3)
    }

}

@Suite struct UsageCompatibilitySourceTests {
    @Test func sourceStatisticsDoNotAddASecondCopyToProviderTotals() throws {
        var graph = CoreUsageGraph()
        graph.days = 1
        graph.providers = ["claude", "codex"]
        graph.series = [
            .init(providerId: "claude", values: [35], sourceId: "t3code"),
            .init(providerId: "codex", values: [70]),
        ]
        graph.sourceStatistics = [.init(sourceId: "t3code", label: "T3 Code", attributionStatus: "mixed",
            tokens: 105, sessions: 3, includedTokens: 35, includedSessions: 1,
            dataStatus: "partial", providerIds: ["claude", "codex"])]
        let comparison = try #require(UsageComparison.make(graph))
        #expect(comparison.total == 105)
        #expect(comparison.providers.map(\.id) == ["codex", "claude"])
        #expect(comparison.providers.first { $0.id == "claude" }?.amount == .known(35))
    }

    @Test func legacyImportsRemainReadableWithoutBeingProviders() throws {
        var graph = CoreUsageGraph()
        graph.days = 3
        graph.providers = ["claude", "t3code"]
        graph.series = [.init(providerId: "claude", values: [10, 20, 30]),
                        .init(providerId: "t3code", values: [5, -1, 7])]
        let comparison = try #require(UsageComparison.make(graph))
        #expect(comparison.total == 60)
        #expect(comparison.providers.map(\.id) == ["claude"])
        #expect(UsageSourceReading.legacyAmount(graph) == 12)
        #expect(UsageSourceReading.providerGraph(graph).series.map(\.providerId) == ["claude"])
        graph.metric = "cost"
        graph.series[1].hasPricedUsage = false
        #expect(UsageSourceReading.legacyAmount(graph) == nil)
    }
}

@MainActor
@Suite struct UsageLoadedCalendarTests {
    @Test func mixedLegacyAndNativeHistoryKeepsItsExactCalendarAndRunRoute() throws {
        var loaded = CoreUsageGraph()
        loaded.days = 2
        loaded.labels = ["12/31", "01/01"]
        loaded.providers = ["claude", "t3code"]
        loaded.series = [.init(providerId: "claude", values: [10, 20]),
                         .init(providerId: "t3code", values: [5, 7])]
        let data = Data(#"{"days":["2024-12-31","2025-01-01"],"providers":{"t3code":{"provider_id":"t3code","cells":[],"totals":{"tokens":12,"sessions":1},"data_status":"available"}},"aggregate":{"provider_id":"all","cells":[],"totals":{"tokens":42,"sessions":3},"data_status":"available"},"timezone":"UTC"}"#.utf8)
        loaded.heatmap = try JSONDecoder().decode(CoreUsageHeatmap.self, from: data)
        let filtered = UsageSourceReading.providerGraph(loaded)
        #expect(filtered.heatmap == nil, "The legacy aggregate cannot be labeled as native provider history")
        #expect(filtered.series.map(\.providerId) == ["claude"])
        let calendar = UsageChartCalendar(loaded)
        #expect(calendar.label(1) == "2025-01-01")
        #expect(calendar.drilldownDay(1) == "2025-01-01")
        let comparison = try #require(UsageComparison.make(filtered))
        let store = OverviewStore(core: CoreModel())
        store.pane = .usage
        let view = UsageCompositionView(graph: filtered, comparison: comparison, calendar: calendar) {
            store.showDay($0, provider: "all")
        }
        view.showRuns(1)
        #expect(store.pane == .roster)
        #expect(store.dayFilter?.day == HistoryDayParse.date("2025-01-01"))
        #expect(store.dayFilter?.provider == nil)
    }

    @Test func shortAxisDatesNeverInventAFullCalendarDay() {
        var graph = CoreUsageGraph()
        graph.labels = ["01/01"]
        let calendar = UsageChartCalendar(graph)
        #expect(calendar.label(0) == "01/01")
        #expect(calendar.drilldownDay(0) == nil)
    }
}
