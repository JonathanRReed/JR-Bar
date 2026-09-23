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

    @Test("time words count as a time")
    func timeWords() {
        #expect(ShelfRemindersModel.hasTime("tomorrow at 3pm"))
        #expect(ShelfRemindersModel.hasTime("tonight"))
        #expect(ShelfRemindersModel.hasTime("in 2 hours"))
        #expect(!ShelfRemindersModel.hasTime("next Friday"))
        #expect(!ShelfRemindersModel.hasTime("tomorrow"))
    }
}
