import Foundation
import Testing
@testable import JRBarApp

/// The reminders row's quick add: a typed line read as a title and a
/// due date. The detector reads dates relative to now, so the checks
/// are relative too. Nothing is saved.
@Suite("Reminder quick add")
@MainActor
struct ShelfReminderQuickAddTests {
    private let calendar = Calendar.current

    @Test("a day and a time leave the title and become the due date")
    func dayAndTime() throws {
        let parsed = try #require(ShelfRemindersModel.quickAdd("Call Sam tomorrow at 3pm"))
        #expect(parsed.title == "Call Sam")
        let due = try #require(parsed.due)
        #expect(due.hour == 15)
        #expect(due.minute == 0)
        let tomorrow = calendar.date(byAdding: .day, value: 1, to: Date())!
        #expect(due.day == calendar.component(.day, from: tomorrow))
    }

    @Test("a day alone stays a day — no invented noon")
    func dayOnly() throws {
        let parsed = try #require(ShelfRemindersModel.quickAdd("Pay rent tomorrow"))
        #expect(parsed.title == "Pay rent")
        #expect(parsed.due?.hour == nil)
        #expect(parsed.due?.day != nil)
    }

    @Test("a line without a date is a dateless reminder")
    func noDate() throws {
        let parsed = try #require(ShelfRemindersModel.quickAdd("  buy oat milk  "))
        #expect(parsed.title == "Buy oat milk", "trimmed, first letter up")
        #expect(parsed.due == nil)
    }

    @Test("\"remind me to\" and a dangling connector leave the title")
    func cleanup() throws {
        let parsed = try #require(ShelfRemindersModel.quickAdd("remind me to water the plants on Friday"))
        #expect(parsed.title == "Water the plants")
        #expect(parsed.due != nil)
    }

    @Test("nothing to title is nothing to add")
    func empty() {
        #expect(ShelfRemindersModel.quickAdd("") == nil)
        #expect(ShelfRemindersModel.quickAdd("   ") == nil)
        #expect(ShelfRemindersModel.quickAdd("tomorrow at 3pm") == nil)
    }

    @Test("the preview names today and tomorrow, and a time only when there is one")
    func whenText() {
        let now = Date()
        #expect(ShelfRemindersModel.whenText(now, hasTime: false) == "Today")
        let tomorrow = calendar.date(byAdding: .day, value: 1, to: now)!
        #expect(ShelfRemindersModel.whenText(tomorrow, hasTime: true).hasPrefix("Tomorrow, "))
        let later = calendar.date(byAdding: .day, value: 5, to: now)!
        let day = ShelfRemindersModel.whenText(later, hasTime: false)
        #expect(day != "Today" && day != "Tomorrow")
        #expect(ShelfRemindersModel.whenText(later, hasTime: true).hasPrefix(day + ", "),
                "the time only follows the day")
    }

    @Test("remind-me-later lands an hour on, this evening, or tomorrow morning")
    func later() throws {
        var utc = Calendar(identifier: .gregorian)
        utc.timeZone = TimeZone(identifier: "UTC")!
        let morning = try #require(utc.date(from: DateComponents(year: 2026, month: 9, day: 23, hour: 10)))
        let hour = ShelfRemindersModel.due(.inAnHour, now: morning, calendar: utc)
        #expect(hour.day == 23 && hour.hour == 11 && hour.minute == 0)
        let evening = ShelfRemindersModel.due(.thisEvening, now: morning, calendar: utc)
        #expect(evening.day == 23 && evening.hour == 18)
        let late = try #require(utc.date(from: DateComponents(year: 2026, month: 9, day: 23, hour: 20)))
        let pastEvening = ShelfRemindersModel.due(.thisEvening, now: late, calendar: utc)
        #expect(pastEvening.hour == 21, "past six, 'this evening' is an hour on")
        let tomorrow = ShelfRemindersModel.due(.tomorrowMorning, now: late, calendar: utc)
        #expect(tomorrow.day == 24 && tomorrow.hour == 9 && tomorrow.minute == 0)
    }

    @Test("a session's reminder names the run and where it ran")
    func sessionReminder() {
        let made = ShelfRemindersModel.sessionReminder(label: "rename-the-fish", provider: "claude",
                                                       cwd: NSHomeDirectory() + "/Code/fish")
        #expect(made.title == "Look at rename-the-fish")
        #expect(made.notes.contains("~/Code/fish"), "the path is shortened, never lost")
        #expect(made.notes.contains("Claude"))
        let bare = ShelfRemindersModel.sessionReminder(label: "x", provider: "codex", cwd: nil)
        #expect(!bare.notes.contains(" in "))
    }

    @Test("time words count as a time")
    func timeWords() {
        #expect(ShelfRemindersModel.hasTime("tomorrow at 3pm"))
        #expect(ShelfRemindersModel.hasTime("tonight"))
        #expect(ShelfRemindersModel.hasTime("in 2 hours"))
        #expect(!ShelfRemindersModel.hasTime("next Friday"))
        #expect(!ShelfRemindersModel.hasTime("tomorrow"))
    }
}
