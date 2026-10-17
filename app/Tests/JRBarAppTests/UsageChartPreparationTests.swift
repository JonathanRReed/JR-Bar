import Foundation
import Testing
import JRBarCore
@testable import JRBarApp

@Suite struct UsageChartPreparationTests {
    @Test func tokenPointsKeepRowAndStackOrderWhileTotalsCombineDuplicateDates() throws {
        let history = UsageHistory(provider: "claude", range: "30d", days: [
            .init(date: "2026-10-03", tokensIn: 10, tokensOut: 5, cacheRead: 2),
            .init(date: "invalid", tokensIn: 900),
            .init(date: "2026-10-01", tokensIn: 4, tokensOut: 3, cacheRead: 1),
            .init(date: "2026-10-03", tokensIn: 20, tokensOut: 7, cacheRead: 6),
        ])
        let points = UsageChartPreparation.points(history, range: .month, metric: .tokens)
        #expect(points.map(\.kind) == ["Cache reads", "Input", "Output", "Cache reads", "Input", "Output", "Cache reads", "Input", "Output"])
        #expect(points.map(\.value) == [2, 10, 5, 1, 4, 3, 6, 20, 7])
        #expect(points[0].date == points[6].date)
        let totals = UsageChartPreparation.totals(points)
        #expect(totals.map(\.value) == [8, 50])
        #expect(totals.allSatisfy { $0.kind == "Total" })
        let selected = try #require(history.days[0].day)
        let found = try #require(UsageChartPreparation.bucket(history, range: .month, at: selected))
        #expect(found.input == 10 && found.output == 5 && found.cache == 2)
    }

    @Test func costPointsKeepExactAmountsWithoutChangingTheirOrder() {
        let history = UsageHistory(provider: "claude", range: "30d", days: [
            .init(date: "2026-10-03", costUsd: 0.125),
            .init(date: "2026-10-01", costUsd: 0),
            .init(date: "2026-10-03", costUsd: 0.25),
        ])
        let points = UsageChartPreparation.points(history, range: .month, metric: .cost)
        #expect(points.map(\.kind) == ["Cost", "Cost", "Cost"])
        #expect(points.map(\.value) == [0.125, 0, 0.25])
        #expect(UsageChartPreparation.totals(points).map(\.value) == [0, 0.375])
    }

    @Test func weekUsesHoursButAnEmptyHourListFallsBackToDays() throws {
        let history = UsageHistory(provider: "claude", range: "7d", days: [
            .init(date: "2026-10-01", tokensIn: 400),
        ], hours: [
            .init(hour: "invalid", tokensIn: 900),
            .init(hour: "2026-10-01T12:00", tokensIn: 10, tokensOut: 5, cacheRead: 2),
        ])
        #expect(UsageChartPreparation.usesHours(history, range: .week))
        #expect(UsageChartPreparation.points(history, range: .week, metric: .tokens).map(\.value) == [2, 10, 5])
        #expect(UsageChartPreparation.points(history, range: .month, metric: .tokens).map(\.value) == [0, 400, 0])
        var withoutHours = history
        withoutHours.hours = []
        #expect(!UsageChartPreparation.usesHours(withoutHours, range: .week))
        #expect(UsageChartPreparation.points(withoutHours, range: .week, metric: .tokens).map(\.value) == [0, 400, 0])
        let selected = try #require(history.hours[1].date)
        #expect(UsageChartPreparation.bucket(history, range: .week, at: selected)?.input == 10)
    }

    @Test func nonemptyInvalidHoursDoNotBorrowDailyData() {
        let history = UsageHistory(provider: "claude", range: "7d", days: [
            .init(date: "2026-10-01", tokensIn: 400),
        ], hours: [.init(hour: "invalid", tokensIn: 900)])
        #expect(UsageChartPreparation.points(history, range: .week, metric: .tokens).isEmpty)
        #expect(UsageChartPreparation.bucket(history, range: .week, at: Date(timeIntervalSince1970: 0)) == nil)
    }

    @Test func epochHoursTakePrecedenceAndSelectionKeepsTheFirstMatchingRow() throws {
        let history = UsageHistory(provider: "claude", range: "7d", hours: [
            .init(hour: "invalid", at: 1_800_000_000, tokensIn: 11, costUsd: 0.1),
            .init(hour: "invalid", at: 1_800_000_000, tokensIn: 22, costUsd: 0.2),
        ])
        let selected = Date(timeIntervalSince1970: 1_800_000_000)
        #expect(UsageChartPreparation.points(history, range: .week, metric: .cost).map(\.date) == [selected, selected])
        let found = try #require(UsageChartPreparation.bucket(history, range: .week, at: selected))
        #expect(found.input == 11 && found.cost == 0.1)
        #expect(found.date == selected)
    }

    @Test func dstSelectionUsesCalendarGranularityAndExistingFirstMatchSemantics() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try #require(TimeZone(identifier: "America/Chicago"))
        let formatter = ISO8601DateFormatter()
        let first = try #require(formatter.date(from: "2026-11-01T01:00:00-05:00"))
        let second = try #require(formatter.date(from: "2026-11-01T01:00:00-06:00"))
        let history = UsageHistory(provider: "claude", range: "7d", hours: [
            .init(hour: "first", at: first.timeIntervalSince1970, tokensIn: 11),
            .init(hour: "second", at: second.timeIntervalSince1970, tokensIn: 22),
        ])
        for selected in [first.addingTimeInterval(600), second.addingTimeInterval(600)] {
            let expected = history.hours.first { row in
                row.date.map { calendar.isDate($0, equalTo: selected, toGranularity: .hour) } ?? false
            }
            let found = UsageChartPreparation.bucket(history, range: .week, at: selected, calendar: calendar)
            #expect(found?.input == expected?.tokensIn)
            #expect(found?.date == expected?.date)
        }
    }

    @Test func absentSelectionAndEmptyDataStayAbsent() {
        let empty = UsageHistory(provider: "claude", range: "365d")
        #expect(UsageChartPreparation.points(empty, range: .year, metric: .tokens).isEmpty)
        #expect(UsageChartPreparation.totals([]).isEmpty)
        #expect(UsageChartPreparation.bucket(empty, range: .year, at: Date(timeIntervalSince1970: 0)) == nil)
    }

    @Test func preparedMatchesTheBaselineSuboperationsForBothMetrics() throws {
        let history = UsageHistory(provider: "claude", range: "30d", days: [
            .init(date: "2026-10-03", tokensIn: 10, tokensOut: 5, cacheRead: 2, costUsd: 0.125),
            .init(date: "invalid", tokensIn: 900),
            .init(date: "2026-10-01", tokensIn: 4, costUsd: 0.25),
            .init(date: "2026-10-03", tokensIn: 20, costUsd: 0.5),
        ])
        let selected = try #require(history.days[0].day)
        for metric in [UsageChartPreparation.Metric.tokens, .cost] {
            let expectedPoints = UsageChartPreparation.points(history, range: .month, metric: metric)
            let expectedTotals = UsageChartPreparation.totals(UsageChartPreparation.points(history, range: .month, metric: metric))
            let expectedBucket = UsageChartPreparation.bucket(history, range: .month, at: selected)
            let prepared = UsageChartPreparation.prepare(history, range: .month, metric: metric, selected: selected)
            #expect(prepared.points == expectedPoints)
            #expect(prepared.totals == expectedTotals)
            #expect(prepared.selectedBucket == expectedBucket)
            #expect(prepared.selectedBucket?.input == 10)
        }
    }

    @Test func preparedKeepsDataWhenSelectionIsNilOrOutsideTheHistory() throws {
        let history = UsageHistory(provider: "claude", range: "30d", days: [
            .init(date: "2026-10-01", tokensIn: 4, tokensOut: 3, cacheRead: 1),
        ])
        let withoutSelection = UsageChartPreparation.prepare(history, range: .month, metric: .tokens)
        #expect(withoutSelection.points.map(\.value) == [1, 4, 3])
        #expect(withoutSelection.totals.map(\.value) == [8])
        #expect(withoutSelection.selectedBucket == nil)
        let date = try #require(history.days[0].day)
        let outside = try #require(Calendar.current.date(byAdding: .day, value: 2, to: date))
        let unmatched = UsageChartPreparation.prepare(history, range: .month, metric: .tokens, selected: outside)
        #expect(unmatched.points == withoutSelection.points)
        #expect(unmatched.totals == withoutSelection.totals)
        #expect(unmatched.selectedBucket == nil)
    }

    @Test func preparedUsesTheSuppliedDstCalendarForItsFirstMatch() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try #require(TimeZone(identifier: "America/Chicago"))
        let formatter = ISO8601DateFormatter()
        let first = try #require(formatter.date(from: "2026-11-01T01:00:00-05:00"))
        let second = try #require(formatter.date(from: "2026-11-01T01:00:00-06:00"))
        let history = UsageHistory(provider: "claude", range: "7d", hours: [
            .init(hour: "first", at: first.timeIntervalSince1970, tokensIn: 11, costUsd: 0.125),
            .init(hour: "second", at: second.timeIntervalSince1970, tokensIn: 22, costUsd: 0.25),
        ])
        for date in [first.addingTimeInterval(600), second.addingTimeInterval(600)] {
            let expected = UsageChartPreparation.bucket(history, range: .week, at: date, calendar: calendar)
            let prepared = UsageChartPreparation.prepare(history, range: .week, metric: .cost,
                                                        selected: date, calendar: calendar)
            #expect(prepared.selectedBucket == expected)
            #expect(prepared.points.map(\.value) == [0.125, 0.25])
        }
    }

    @Test func aFreshPreparationReflectsRangeMetricAndHistoryChanges() {
        var history = UsageHistory(provider: "claude", range: "7d", days: [
            .init(date: "2026-10-01", tokensIn: 4, tokensOut: 3, cacheRead: 1, costUsd: 0.125),
        ], hours: [.init(hour: "epoch", at: 1_800_000_000, tokensIn: 11, tokensOut: 2, cacheRead: 1, costUsd: 0.25)])
        let original = UsageChartPreparation.prepare(history, range: .week, metric: .tokens)
        #expect(original.points.map(\.value) == [1, 11, 2])
        let daily = UsageChartPreparation.prepare(history, range: .month, metric: .tokens)
        #expect(daily.points.map(\.value) == [1, 4, 3])
        let cost = UsageChartPreparation.prepare(history, range: .week, metric: .cost)
        #expect(cost.points.map(\.value) == [0.25])
        history.hours[0].tokensIn = 99
        let changed = UsageChartPreparation.prepare(history, range: .week, metric: .tokens)
        #expect(changed.points.map(\.value) == [1, 99, 2])
        #expect(original.points.map(\.value) == [1, 11, 2])
    }
}
