import JRBarTestSupport
import Foundation
import Testing
@testable import JRBarApp

@Suite("Notch timer glance", .temporaryDirectory)
@MainActor
struct NotchTimerGlanceTests {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    private func entry(_ id: String, seconds: TimeInterval, paused: Bool = false,
                       fired: Bool = false) -> ShelfTimerModel.Entry {
        .init(id: id, label: id, deadline: now.addingTimeInterval(seconds), fired: fired,
              pausedRemaining: paused ? seconds : nil)
    }

    @Test("finished timers wait for dismissal before the next running timer")
    func selection() throws {
        #expect(NotchTimerGlance(entries: [], now: now) == nil)
        let running = entry("Tea", seconds: 125)
        let later = entry("Laundry", seconds: 300)
        let paused = entry("Break", seconds: 10, paused: true)
        let selected = try #require(NotchTimerGlance(entries: [paused, later, running], now: now))
        #expect(selected.entry.id == running.id)
        #expect(selected.count == 3)
        #expect(selected.action == .pause)
        #expect(selected.timeText == "2:05")
        let done = entry("Pasta", seconds: -1, fired: true)
        let finished = try #require(NotchTimerGlance(entries: [running, done], now: now))
        #expect(finished.entry.id == done.id)
        #expect(finished.action == .dismiss)
        #expect(finished.timeText == "Done")
        let onlyPaused = try #require(NotchTimerGlance(entries: [paused], now: now))
        #expect(onlyPaused.action == .resume)
        #expect(onlyPaused.timeText == "0:10")
    }

    @Test("countdown follows the supplied clock and rounds the remaining fraction up")
    func countdown() throws {
        let running = entry("Build", seconds: 3600.2)
        #expect(NotchTimerGlance(entries: [running], now: now)?.timeText == "1:00:01")
        #expect(NotchTimerGlance(entries: [running], now: now.addingTimeInterval(1))?.timeText == "1:00:00")
        let finished = try #require(NotchTimerGlance(entries: [running], now: running.deadline))
        #expect(finished.action == .dismiss)
        #expect(finished.timeText == "Done")
    }

    @Test("equal deadlines select the same timer regardless of input order")
    func stableTies() {
        let a = entry("a", seconds: 30), b = entry("b", seconds: 30)
        #expect(NotchTimerGlance(entries: [a, b], now: now)?.entry.id == "a")
        #expect(NotchTimerGlance(entries: [b, a], now: now)?.entry.id == "a")
    }

    @Test("quick controls pause, resume and dismiss through the existing timer model")
    func controls() throws {
        var clock = now
        let directory = TestTemporaryDirectory.currentURL.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let timers = ShelfTimerModel(storeURL: directory.appendingPathComponent("timers.json"),
                                     schedulingEnabled: false, clock: { clock })
        timers.add(label: "Tea", duration: 120, now: clock)
        clock = clock.addingTimeInterval(30)
        let running = try #require(NotchTimerGlance(entries: timers.entries, now: clock))
        running.perform(on: timers, now: clock)
        #expect(timers.entries.first?.pausedRemaining == 90)
        let paused = try #require(NotchTimerGlance(entries: timers.entries, now: clock))
        clock = clock.addingTimeInterval(600)
        paused.perform(on: timers, now: clock)
        #expect(timers.entries.first?.deadline == clock.addingTimeInterval(90))
        #expect(timers.entries.first?.paused == false)
        clock = clock.addingTimeInterval(90)
        timers.sweep()
        let done = try #require(NotchTimerGlance(entries: timers.entries, now: clock))
        done.perform(on: timers, now: clock)
        #expect(timers.entries.isEmpty)
    }

    @Test("a stale Pause click cannot dismiss a timer which just finished")
    func expiryBetweenDrawAndClick() throws {
        var clock = now
        let directory = TestTemporaryDirectory.currentURL.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let timers = ShelfTimerModel(storeURL: directory.appendingPathComponent("timers.json"),
                                     schedulingEnabled: false, clock: { clock })
        timers.add(label: "Tea", duration: 1, now: clock)
        let running = try #require(NotchTimerGlance(entries: timers.entries, now: clock))
        clock = clock.addingTimeInterval(1)
        running.perform(on: timers, now: clock)
        #expect(timers.entries.count == 1)
        #expect(timers.entries.first?.paused == false)
        #expect(NotchTimerGlance(entries: timers.entries, now: clock)?.action == .dismiss)
    }
}
