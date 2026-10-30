import Foundation
import Testing
@testable import JRBarApp

@Suite("Dock reminder due words")
struct DockReminderDueWordsTests {
    static var utc: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }

    @Test func anAllDayReminderUnderTodayRepeatsNothing() {
        let due = Date(timeIntervalSince1970: 1_793_232_000)
        #expect(DockRemindersCard.dueWords(due, hasTime: false, overdue: false, calendar: Self.utc) == nil)
        #expect(DockRemindersCard.dueWords(due, hasTime: true, overdue: false, calendar: Self.utc) != nil)
        #expect(DockRemindersCard.dueWords(due, hasTime: false, overdue: true, calendar: Self.utc) != nil)
    }
}
