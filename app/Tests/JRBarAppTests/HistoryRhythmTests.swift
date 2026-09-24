import Foundation
import SwiftUI
import Testing
@testable import JRBarApp
@testable import JRBarCore

/// History's two-week rhythm and the smooth line it and the sparklines
/// draw: which days the strip covers, what it counts, and that the curve
/// never swings past the points it passes through.
@Suite("History rhythm")
@MainActor
struct HistoryRhythmTests {
    private let calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }()

    private func row(_ date: Date, kind: String = "completed") -> CoreHistoryRow {
        CoreHistoryRow(at: date.timeIntervalSince1970, kind: kind)
    }

    private var now: Date { calendar.date(from: DateComponents(year: 2026, month: 9, day: 24, hour: 9))! }

    private func daysAgo(_ days: Int, hour: Int = 12) -> Date {
        let day = calendar.date(byAdding: .day, value: -days, to: calendar.startOfDay(for: now))!
        return calendar.date(byAdding: .hour, value: hour, to: day)!
    }

    @Test("the strip starts at the oldest loaded row, never before it")
    func startsAtTheOldestLoadedRow() {
        let rows = [row(daysAgo(0)), row(daysAgo(3))]
        let days = HistoryRhythm.days(rows, loadedFrom: daysAgo(3), now: now, calendar: calendar)
        #expect(days.count == 4)
        #expect(days.first?.date == calendar.startOfDay(for: daysAgo(3)))
        #expect(days.last?.date == calendar.startOfDay(for: now))
    }

    @Test("a long history is cut to two weeks; a single day still draws a line")
    func spanBounds() {
        let long = HistoryRhythm.days([row(daysAgo(40))], loadedFrom: daysAgo(40), now: now, calendar: calendar)
        #expect(long.count == HistoryRhythm.span)
        let today = HistoryRhythm.days([row(daysAgo(0))], loadedFrom: daysAgo(0), now: now, calendar: calendar)
        #expect(today.count == 2)
    }

    @Test("quiet days inside the range count zero, and failures are counted apart")
    func counts() {
        let rows = [row(daysAgo(0)), row(daysAgo(0), kind: "failed"), row(daysAgo(2)), row(daysAgo(2))]
        let days = HistoryRhythm.days(rows, loadedFrom: daysAgo(2), now: now, calendar: calendar)
        #expect(days.map(\.rows) == [2, 0, 2])
        #expect(days.map(\.failed) == [0, 0, 1])
    }

    @Test("the smooth line passes through its points and never overshoots them")
    func monotoneLine() {
        let points = [CGPoint(x: 0, y: 10), CGPoint(x: 10, y: 10), CGPoint(x: 20, y: 2), CGPoint(x: 30, y: 2), CGPoint(x: 40, y: 8)]
        let path = SmoothLine.path(through: points)
        let box = path.boundingRect
        #expect(box.minY >= 2 - 0.001, "a dip never goes below the lowest point")
        #expect(box.maxY <= 10 + 0.001, "a flat run never bulges past its level")
        #expect(abs(box.minX) < 0.001 && abs(box.maxX - 40) < 0.001)
    }
}
