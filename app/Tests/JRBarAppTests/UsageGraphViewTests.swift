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
        var percent = graph(series: [
            series("claude", values: [40, 100, -1, 99.7, 12]),
            series("claude", instance: "work", values: [100, 100, 3, 5, 6]),
            series("codex", values: [101, 20, 30, 40, 50]),
        ], days: 5)
        percent.metric = "percent"
        let hits = UsageGraphView.limitDays(percent)
        // One mark per provider per day, even with two accounts at 100 %.
        #expect(hits.map { "\($0.day)\($0.providerId)" } == ["0claude", "0codex", "1claude", "3claude"])
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
}
