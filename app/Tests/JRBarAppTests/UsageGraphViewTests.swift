import Foundation
import Testing
import JRBarCore
@testable import JRBarApp

/// The Usage pane's pure chart logic: `splitPoints` is what keeps the
/// graph honest — gap days break the line instead of bridging to zero,
/// and two instances of one provider can never merge into a fabricated
/// single line. The helpers are `nonisolated` — pure, and the View's
/// MainActor isolation must not reach them.
@Suite struct UsageGraphViewTests {
    @Test func observedValuesRemainVisibleWhenScaleMetadataIsMissingOrInvalid() {
        var chart = CoreUsageGraph()
        chart.days = 3
        chart.series = [.init(providerId: "codex", values: [-1, 4, 12, 999])]
        #expect(UsageGraphView.chartMaximum(chart) == 12)
        chart.scaleMax = .nan
        #expect(UsageGraphView.chartMaximum(chart) == 12)
        chart.scaleMax = 20
        #expect(UsageGraphView.chartMaximum(chart) == 20)
        chart.metric = "percent"
        #expect(UsageGraphView.chartMaximum(chart) == 100)
    }

    @Test func missingPricesAreNotPresentedAsZeroDollars() {
        let unknown = CoreUsageGraph.Series(providerId: "t3code", values: [-1, 0], hasPricedUsage: false)
        let free = CoreUsageGraph.Series(providerId: "codex", values: [-1, 0], hasPricedUsage: true)
        #expect(UsageGraphView.legendValueLabel(unknown, metric: "cost") == "Unpriced")
        #expect(UsageGraphView.legendValueLabel(free, metric: "cost") == UsageFormat.cost(0))
    }

    @Test func hoverReadoutDoesNotPresentMissingPricesAsZeroDollars() {
        let unknown = CoreUsageGraph.Series(providerId: "codex", values: [0], hasPricedUsage: false)
        let free = CoreUsageGraph.Series(providerId: "codex", values: [0], hasPricedUsage: true)
        #expect(UsageGraphView.readoutValueLabel(unknown, day: 0, metric: "cost") == "Unpriced")
        #expect(UsageGraphView.readoutValueLabel(free, day: 0, metric: "cost") == UsageFormat.cost(0))
        #expect(UsageGraphView.readoutValueLabel(unknown, day: 0, metric: "tokens") == UsageFormat.tokens(0))
    }

    @Test func hoverReadoutOmitsGapsAndInvalidDays() {
        let row = CoreUsageGraph.Series(providerId: "codex", values: [-1, 12], hasPricedUsage: false)
        for day in [-1, 0, 2, Int.max] {
            #expect(UsageGraphView.readoutValueLabel(row, day: day, metric: "cost") == nil)
        }
        let missing = CoreUsageGraph.Series(providerId: "codex", values: [])
        #expect(UsageGraphView.readoutValueLabel(missing, day: 0, metric: "cost") == nil)
        #expect(UsageGraphView.readoutValueLabel(row, day: 1, metric: "tokens") == UsageFormat.tokens(12))
    }

    @Test func chartKeepsTheEntireSelectedRange() {
        for days in [7, 30, 365] {
            #expect(UsageGraphView.xDomain(days: days) == 0...Double(days - 1))
        }
        #expect(UsageGraphView.xDomain(days: 1) == -0.5...0.5)
        #expect(UsageGraphView.xDomain(days: 0) == -0.5...0.5)
    }

    @Test func selectionRejectsInvalidCoordinatesAndPreviousRanges() {
        for coordinate: Double? in [nil, .nan, .infinity, -.infinity, 1e300, -1, 7, 180] {
            #expect(UsageGraphView.selectedDay(coordinate, days: 7) == nil)
        }
        #expect(UsageGraphView.selectedDay(180, days: 365) == 180)
        #expect(UsageGraphView.selectedDay(2.4, days: 7) == 2)
        #expect(UsageGraphView.selectedDay(2.6, days: 7) == 3)
        #expect(UsageGraphView.selectedDay(0, days: 0) == nil)
    }

    private func graph(series: [CoreUsageGraph.Series], days: Int = 30) -> CoreUsageGraph {
        var graph = CoreUsageGraph()
        graph.days = days
        graph.series = series
        return graph
    }

    private func series(_ providerId: String, instance: String? = nil,
                        values: [Double]) -> CoreUsageGraph.Series {
        var row = CoreUsageGraph.Series(providerId: providerId, values: values)
        row.sourceInstanceId = instance
        return row
    }

    @Test func percentModeMarksTheDaysAProviderStoodAtItsLimit() {
        // The daemon's percent series is the day's lowest REMAINING percent:
        // 100 is an untouched quota and 0 is a spent one.
        var percent = graph(series: [
            series("claude", values: [40, 0, -1, 0.3, 12]),
            series("claude", instance: "work", values: [0, 0, 3, 5, 6]),
            series("codex", values: [100, 100, 100, 99.7, 100]),
        ], days: 5)
        percent.metric = "percent"
        let hits = UsageGraphView.limitDays(percent)
        // One mark per provider per day, even with two accounts spent; a
        // full quota is never "at its limit".
        #expect(hits.map { "\($0.day)\($0.providerId)" } == ["0claude", "1claude", "3claude"])
        percent.metric = "tokens"
        #expect(UsageGraphView.limitDays(percent).isEmpty, "tokens have no ceiling")
    }

    @Test func gapDaysBreakTheLineIntoRuns() {
        let points = UsageGraphView.splitPoints(graph(
            series: [series("codex", values: [-1, -1, 5, 6, -1, 7])],
            days: 6))
        // Days 2-3 are one run, day 5 a second — the day-4 gap split it.
        #expect(points.map(\.day) == [2, 3, 5])
        #expect(points.map(\.run) == [0, 0, 1])
        #expect(Set(points.map(\.seriesId)).count == 2)
    }

    @Test func consecutiveGapsStillOneBoundary() {
        let points = UsageGraphView.splitPoints(graph(
            series: [series("claude", values: [3, -1, -1, -1, 8])],
            days: 5))
        #expect(points.map(\.day) == [0, 4])
        #expect(points.map(\.run) == [0, 1])
    }

    /// Percent mode emits one row per (provider, instance): identical
    /// `providerId`s must still plot as separate lines.
    @Test func instancesPlotApart() {
        let points = UsageGraphView.splitPoints(graph(
            series: [
                series("codex", instance: "default", values: [80, 81, 82]),
                series("codex", instance: "work", values: [50, 51, 52]),
            ],
            days: 3))
        #expect(points.count == 6)
        #expect(Set(points.map(\.seriesId)).count == 2)
        // Both rows keep the provider's colour but never share a line.
        #expect(Set(points.map(\.providerId)).count == 1)
    }

    @Test func aSingleObservedDayStillEarnsAPoint() {
        let points = UsageGraphView.splitPoints(graph(
            series: [series("cursor", values: [-1, -1, 42])],
            days: 3))
        // A one-point run draws no line — the view's PointMark layer
        // covers it, but only if the point exists.
        #expect(points.map(\.day) == [2])
    }

    @Test func valuesPastTheDayRangeAreClipped() {
        let points = UsageGraphView.splitPoints(graph(
            series: [series("claude", values: [1, 2, 3, 4, 5])],
            days: 3))
        #expect(points.map(\.day) == [0, 1, 2])
    }

    @Test func percentLegendReadsTheFreshestSample() {
        let row = series("codex", values: [-1, -1, 88.5, 0, 74.25])
        // A sum would claim 162.75% — the glance number is the latest
        // remaining-quota reading, zeros included.
        #expect(UsageGraphView.legendFigure(row, metric: "percent") == 74.25)
        #expect(UsageGraphView.legendFigure(series("x", values: [-1, -1]),
                                          metric: "percent") == 0)
    }

    @Test func countableMetricsSumTheRange() {
        let row = series("claude", values: [100, 0, -1, 250])
        let figure = UsageGraphView.legendFigure(row, metric: "tokens")
        #expect(figure == 350)
        #expect(UsageGraphView.legendFigure(row, metric: "sessions") == 350)
    }

    @Test func axisLabelsNeverRoundIntoTheirNeighbour() {
        #expect(UsageGraphView.axisLabel(0.5, metric: "sessions") == nil)
        #expect(UsageGraphView.axisLabel(2, metric: "sessions") == "2")
        #expect(UsageGraphView.axisLabel(0.5, metric: "tokens") == nil)
        #expect(UsageGraphView.axisLabel(1_500_000, metric: "tokens") == "1.5M")
        #expect(UsageGraphView.axisLabel(100, metric: "percent") == "100%")
        #expect(UsageGraphView.axisLabel(1e300, metric: "tokens") != nil, "a huge tick is words, not a trap")
    }

    @Test func aSeriesIsNamedLikeItsProviderNotLikeTheDaemonsId() {
        #expect(UsageGraphView.seriesName(series("claude", values: [1])) == "Claude")
        var plain = series("claude", values: [1])
        plain.label = "claude"
        #expect(UsageGraphView.seriesName(plain) == "Claude")
        var work = series("claude", instance: "work", values: [1])
        work.label = "claude · work"
        #expect(UsageGraphView.seriesName(work) == "Claude · work")
        let rows = UsageGraphView.legendRows({
            var g = graph(series: [plain, work], days: 1)
            g.providers = ["claude"]
            return g
        }())
        #expect(rows.map(\.label) == ["Claude", "Claude · work"])
    }

    @Test func theEmptyChartExplainsItsOwnMetric() {
        #expect(UsageGraphView.emptyExplanation(metric: "percent").contains("quota"))
        #expect(UsageGraphView.emptyExplanation(metric: "tokens").contains("transcripts"))
        #expect(UsageGraphView.noHistoryText(metric: "percent") == "no quota history")
        #expect(UsageGraphView.noHistoryText(metric: "tokens") == "no local history")
    }
}
