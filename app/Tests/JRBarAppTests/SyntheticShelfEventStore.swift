import EventKit
import Foundation
import os
@testable import JRBarApp

/// No native stores, permissions, or personal data. Tests release each reply by hand.
final class SyntheticShelfEventStore: ShelfEventStore, @unchecked Sendable {
    struct Calls {
        var events = 0
        var seasonal = 0
        var months: [DateInterval] = []
        var permissions: [EKEntityType] = []
        var completed: [String] = []
        var drafts: [ShelfReminderDraft] = []
    }
    let calls = OSAllocatedUnfairLock(initialState: Calls())
    @MainActor private var replies: [Int: ShelfReminderReader.Reply] = [:]
    @MainActor private(set) var fetches = 0
    @MainActor private(set) var peakInFlight = 0
    @MainActor var inFlight: Int { replies.count }
    @MainActor var synchronous = false
    var hasDefaultList = true
    var writeError: (any Error)?

    func events(from now: Date) -> [ShelfCalendarModel.Event] {
        calls.withLock { $0.events += 1 }
        return []
    }

    func events(in range: DateInterval) -> [ShelfCalendarModel.Event] {
        calls.withLock { $0.months.append(range) }
        return []
    }

    func seasonal(now: Date, birthdays: Bool) -> SeasonalReading {
        calls.withLock { $0.seasonal += 1 }
        return SeasonalReading(entries: [], holidayCalendars: 2)
    }

    func requestAccess(to entity: EKEntityType, completion: @escaping @Sendable (Bool) -> Void) {
        calls.withLock { $0.permissions.append(entity) }
        completion(true)
    }

    @MainActor func fetchReminders(_ completion: @escaping ShelfReminderReader.Reply) {
        fetches += 1
        replies[fetches] = completion
        peakInFlight = max(peakInFlight, inFlight)
        if synchronous { answer(fetches, with: []) }
    }

    @MainActor @discardableResult
    func answer(_ number: Int, with entries: [ShelfRemindersModel.Entry]?) -> ShelfReminderReader.Reply? {
        let reply = replies.removeValue(forKey: number)
        reply?(entries)
        return reply
    }

    func completeReminder(id: String) throws -> Bool {
        if let writeError { throw writeError }
        calls.withLock { $0.completed.append(id) }
        return true
    }

    func addReminder(_ draft: ShelfReminderDraft) throws -> Bool {
        if let writeError { throw writeError }
        guard hasDefaultList else { return false }
        calls.withLock { $0.drafts.append(draft) }
        return true
    }
}
