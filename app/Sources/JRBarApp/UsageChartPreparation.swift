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
