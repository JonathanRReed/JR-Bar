import Foundation
import JRBarCore

struct UsagePoint: Identifiable, Equatable, Sendable {
    let date: Date
    let kind: String
    let value: Double
    var id: String { "\(kind)|\(date.timeIntervalSince1970)" }
}

enum UsageChartPreparation {
    enum Metric: Sendable {
        case tokens, cost
    }

    struct Bucket: Equatable, Sendable {
        let date: Date
        let input: Int
        let output: Int
        let cache: Int
        let cost: Double
    }

    struct Prepared: Equatable, Sendable {
        let points: [UsagePoint]
        let totals: [UsagePoint]
        let selectedBucket: Bucket?
    }

    nonisolated static func prepare(_ history: UsageHistory, range: UsageHistoryRange,
                                    metric: Metric, selected: Date? = nil,
                                    calendar: Calendar = .current) -> Prepared {
        let points = Self.points(history, range: range, metric: metric)
        let totals = Self.totals(points)
        let selectedBucket = selected.flatMap { Self.bucket(history, range: range, at: $0, calendar: calendar) }
        return Prepared(points: points, totals: totals, selectedBucket: selectedBucket)
    }

    static let tokenKinds = ["Cache reads", "Input", "Output"]

    nonisolated static func usesHours(_ history: UsageHistory, range: UsageHistoryRange) -> Bool {
        range == .week && !history.hours.isEmpty
    }

    nonisolated static func points(_ history: UsageHistory, range: UsageHistoryRange, metric: Metric) -> [UsagePoint] {
        if usesHours(history, range: range) {
            return history.hours.flatMap { hour -> [UsagePoint] in
                guard let date = hour.date else { return [] }
                return rows(date: date, input: hour.tokensIn, output: hour.tokensOut, cache: hour.cacheRead, cost: hour.costUsd, metric: metric)
            }
        }
        return history.days.flatMap { day -> [UsagePoint] in
            guard let date = day.day else { return [] }
            return rows(date: date, input: day.tokensIn, output: day.tokensOut, cache: day.cacheRead, cost: day.costUsd, metric: metric)
        }
    }

    nonisolated static func totals(_ points: [UsagePoint]) -> [UsagePoint] {
        let sums = Dictionary(grouping: points, by: \.date).mapValues { $0.reduce(0) { $0 + $1.value } }
        return sums.map { UsagePoint(date: $0.key, kind: "Total", value: $0.value) }.sorted { $0.date < $1.date }
    }

    nonisolated static func bucket(_ history: UsageHistory, range: UsageHistoryRange,
                                   at date: Date, calendar: Calendar = .current) -> Bucket? {
        if usesHours(history, range: range) {
            for hour in history.hours {
                guard let parsed = hour.date,
                      calendar.isDate(parsed, equalTo: date, toGranularity: .hour) else { continue }
                return Bucket(date: parsed, input: hour.tokensIn, output: hour.tokensOut, cache: hour.cacheRead, cost: hour.costUsd)
            }
            return nil
        }
        for day in history.days {
            guard let parsed = day.day,
                  calendar.isDate(parsed, equalTo: date, toGranularity: .day) else { continue }
            return Bucket(date: parsed, input: day.tokensIn, output: day.tokensOut, cache: day.cacheRead, cost: day.costUsd)
        }
        return nil
    }

    nonisolated private static func rows(date: Date, input: Int, output: Int,
                                        cache: Int, cost: Double, metric: Metric) -> [UsagePoint] {
        switch metric {
        case .tokens:
            return [
                UsagePoint(date: date, kind: "Cache reads", value: Double(cache)),
                UsagePoint(date: date, kind: "Input", value: Double(input)),
                UsagePoint(date: date, kind: "Output", value: Double(output)),
            ]
        case .cost:
            return [UsagePoint(date: date, kind: "Cost", value: cost)]
        }
    }
}

/// Parsed dates and chart summaries survive selection changes and the window's clock tick.
@MainActor
final class UsageChartCache {
    struct HistoryData {
        let points: [UsagePoint]
        let visible: [UsagePoint]
        let totals: [String: Double]
        let axis: UsageChartAxis
        let singletons: [UsagePoint]
        let dates: [Date]
        let byDate: [Date: [UsagePoint]]

        func nearest(to selected: Date?) -> Date? {
            guard let selected, !dates.isEmpty else { return nil }
            var low = 0
            var high = dates.count
            while low < high {
                let middle = (low + high) / 2
                if dates[middle] < selected { low = middle + 1 } else { high = middle }
            }
            if low == 0 { return dates[0] }
            if low == dates.count { return dates[low - 1] }
            let before = dates[low - 1]
            let after = dates[low]
            return selected.timeIntervalSince(before) <= after.timeIntervalSince(selected) ? before : after
        }
    }

    private struct Choice: Hashable {
        let metric: String
        let hidden: Set<String>
    }
    private struct HistoryEntry {
        let history: UsageHistory
        var choices: [Choice: HistoryData] = [:]
        var points: [String: [UsagePoint]] = [:]
    }
    private var histories: [String: HistoryEntry] = [:]
    private(set) var historyPreparations = 0
    private(set) var historyPointPreparations = 0
    private(set) var overviewPreparations = 0
    private(set) var overviewPointPreparations = 0

    func history(_ history: UsageHistory, range: UsageHistoryRange,
                 metric: UsageCenterStore.Metric, hidden: Set<String>) -> HistoryData {
        let key = history.provider + "|" + range.rawValue
        var entry = histories[key] ?? HistoryEntry(history: history)
        if entry.history != history { entry = HistoryEntry(history: history) }
        let choice = Choice(metric: metric.rawValue, hidden: hidden)
        if let data = entry.choices[choice] { return data }
        let points: [UsagePoint]
        if let cached = entry.points[metric.rawValue] { points = cached }
        else {
            historyPointPreparations += 1
            points = UsageChartPreparation.points(history, range: range, metric: metric == .tokens ? .tokens : .cost)
            entry.points[metric.rawValue] = points
        }
        historyPreparations += 1
        let visible = points.filter { !hidden.contains($0.kind) }
        let byDate = Dictionary(grouping: visible, by: \.date)
        let totals = Dictionary(grouping: points, by: \.kind).mapValues { $0.reduce(0) { $0 + $1.value } }
        let singles = Dictionary(grouping: visible, by: \.kind).values.filter { $0.count == 1 }.compactMap(\.first)
        let axis = UsageChartAxis(maximum: visible.map(\.value).max() ?? 0, minimumStep: metric == .tokens ? 1 : 0.01)
        let data = HistoryData(points: points, visible: visible, totals: totals, axis: axis,
            singletons: singles, dates: byDate.keys.sorted(), byDate: byDate)
        entry.choices[choice] = data
        histories[key] = entry
        return data
    }

    struct OverviewData {
        let points: [UsageGraphView.Point]
        let axis: UsageChartAxis
        let providers: [String]
        let runs: [String]
        let colors: [String]
        let totals: [String: Double]
        let byDay: [Int: [UsageGraphView.Point]]
    }
    private var graph: CoreUsageGraph?
    private var overviewChoices: [Set<String>: OverviewData] = [:]
    private var overviewPoints: [UsageGraphView.Point] = []

    func overview(_ graph: CoreUsageGraph, hidden: Set<String>) -> OverviewData {
        if self.graph != graph {
            self.graph = graph
            overviewChoices = [:]
            overviewPoints = UsageGraphView.splitPoints(graph)
            overviewPointPreparations += 1
        }
        if let data = overviewChoices[hidden] { return data }
        overviewPreparations += 1
        let points = overviewPoints.filter { !hidden.contains($0.providerId) }
        let providers = Array(Set(graph.series.map(\.providerId))).sorted()
        let runProviders = Dictionary(points.map { ($0.seriesId, $0.providerId) }, uniquingKeysWith: { first, _ in first })
        let runs = runProviders.keys.sorted()
        let totals = Dictionary(grouping: graph.series, by: \.providerId).mapValues {
            $0.flatMap(\.values).filter { $0 >= 0 }.reduce(0, +)
        }
        let data = OverviewData(points: points, axis: UsageChartAxis(maximum: points.map(\.value).max() ?? 0),
            providers: providers, runs: runs, colors: runs.map { runProviders[$0] ?? "" },
            totals: totals, byDay: Dictionary(grouping: points, by: \.day))
        overviewChoices[hidden] = data
        return data
    }
}
