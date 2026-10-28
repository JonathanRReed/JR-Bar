import EventKit
import Foundation
import os
import Testing
@testable import JRBarApp

@Suite("App-wide EventKit ownership", .timeLimit(.minutes(2)))
@MainActor
struct ShelfEventStoreTests {
    enum Consumer: CaseIterable, Sendable {
        case calendar, reminders, seasonal, calendarPermission, reminderPermission
    }

    nonisolated static var orders: [[Consumer]] {
        func permutations(_ remaining: [Consumer]) -> [[Consumer]] {
            guard !remaining.isEmpty else { return [[]] }
            return remaining.flatMap { first in
                permutations(remaining.filter { $0 != first }).map { [first] + $0 }
            }
        }
        return permutations(Consumer.allCases)
    }

    @Test("every consumer ordering uses the same store", arguments: orders)
    func sharedStoreMatrix(order: [Consumer]) async {
        let store = SyntheticShelfEventStore()
        let calendar = ShelfCalendarReader(authorization: { .fullAccess }, store: store)
        let reader = ShelfReminderReader(store: store)
        let reminders = ShelfRemindersModel(reader: reader)
        reminders.authorization = { .fullAccess }
        reminders.scheduleRefreshOverride = {}
        let seasonal = SeasonalSource.using(reader: calendar)
        let now = Date(timeIntervalSinceReferenceDate: 1000)
        for consumer in order {
            switch consumer {
            case .calendar: _ = ShelfCalendarModel.fetchUpcoming(from: now, reader: calendar)
            case .reminders: reminders.sync(enabled: true)
            case .seasonal:
                #expect(seasonal.calendarAccess() == .granted)
                #expect(seasonal.read(now, true).holidayCalendars == 2)
            case .calendarPermission: #expect(await calendar.requestAccess())
            case .reminderPermission: #expect(await calendar.requestAccess(to: .reminder))
            }
        }
        #expect(calendar.store === store)
        #expect(reader.store === store)
        let calls = store.calls.withLock { $0 }
        #expect(calls.events == 1)
        #expect(calls.seasonal == 1)
        #expect(calls.permissions.count == 2)
        #expect(Set(calls.permissions.map(\.rawValue)) == Set([EKEntityType.event.rawValue, EKEntityType.reminder.rawValue]))
        #expect(store.fetches == 1)
        #expect(store.inFlight == 1)
        reminders.stop()
        #expect(store.inFlight == 1)
        store.answer(1, with: [])
    }

    @Test("production calendar and reminder readers share the lazy native owner")
    func productionOwnership() {
        // Comparing owners never initializes EKEventStore or requests access.
        #expect(ShelfCalendarReader.shared.store === SystemShelfEventStore.shared)
        #expect(ShelfReminderReader.shared.store === ShelfCalendarReader.shared.store)
    }

    struct Reminder: Sendable {
        let id: String?
        let title: String?
        var due: Date?
    }

    @Test("callback projects nullable fields off main before delivering only value rows")
    func callbackProjection() async throws {
        let projections = OSAllocatedUnfairLock(initialState: [Bool]())
        let signal = AsyncStream<([ShelfRemindersModel.Entry]?, Bool)>.makeStream(
            bufferingPolicy: .bufferingOldest(1))
        defer { signal.continuation.finish() }
        let callback = ShelfReminderReader.callback(project: { (reminder: Reminder) in
            projections.withLock { $0.append(Thread.isMainThread) }
            return ShelfReminderReader.entry(id: reminder.id, title: reminder.title, due: reminder.due)
        }, completion: { entries in
            signal.continuation.yield((entries, Thread.isMainThread))
            signal.continuation.finish()
        })
        let due = Date(timeIntervalSinceReferenceDate: 1000)
        await Task.detached {
            callback([
                Reminder(id: "a", title: "Fixture reminder", due: due),
                Reminder(id: "b", title: ""), Reminder(id: "c", title: nil),
                Reminder(id: nil, title: "Missing identifier"), Reminder(id: "", title: "Empty identifier"),
            ])
        }.value
        var iterator = signal.stream.makeAsyncIterator()
        let result = try #require(await iterator.next())
        let entries = try #require(result.0)
        #expect(result.1)
        #expect(projections.withLock { $0 } == Array(repeating: false, count: 5))
        #expect(entries.map(\.title) == ["Fixture reminder", "Reminder", "Reminder"])
        #expect(entries.map(\.id) == ["a", "b", "c"])
        #expect(entries.map(\.due) == [due, nil, nil])
    }

    @Test("nil and empty callback results keep their different meanings", arguments: [false, true])
    func emptyCallback(nilResult: Bool) async throws {
        let signal = AsyncStream<[ShelfRemindersModel.Entry]?>.makeStream(bufferingPolicy: .bufferingOldest(1))
        defer { signal.continuation.finish() }
        let callback = ShelfReminderReader.callback(project: { (reminder: Reminder) in
            ShelfReminderReader.entry(id: reminder.id, title: reminder.title, due: reminder.due)
        }, completion: { rows in
            signal.continuation.yield(rows)
            signal.continuation.finish()
        })
        await Task.detached { callback(nilResult ? nil : []) }.value
        var iterator = signal.stream.makeAsyncIterator()
        let delivered = await iterator.next()
        #expect(delivered != nil)
        if let rows = delivered { #expect(rows == (nilResult ? nil : [])) }
    }

    @Test("writes use the same store and preserve errors and refreshes")
    func reminderWrites() {
        let store = SyntheticShelfEventStore()
        let reminders = ShelfRemindersModel(reader: ShelfReminderReader(store: store))
        reminders.authorization = { .fullAccess }
        reminders.scheduleRefreshOverride = {}
        reminders.sync(enabled: true)
        store.answer(1, with: [])
        #expect(reminders.canWrite)
        #expect(reminders.add("Buy oat milk"))
        reminders.complete(ShelfRemindersModel.Entry(id: "a", title: "Fixture", due: nil))
        let now = Date(timeIntervalSinceReferenceDate: 1000)
        #expect(reminders.remind(about: "Fixture", session: "fixture", provider: "codex", cwd: nil,
                                 later: .inAnHour, now: now))
        let calls = store.calls.withLock { $0 }
        #expect(calls.completed == ["a"])
        #expect(calls.drafts.map(\.title) == ["Buy oat milk", "Look at Fixture"])
        #expect(calls.drafts[1].notes == "Codex session. Left from JR-Bar's notch.")
        #expect(calls.drafts[1].url == ShelfRemindersModel.sessionLink("fixture"))
        #expect(calls.drafts[1].due == ShelfRemindersModel.due(.inAnHour, now: now))
        #expect(store.peakInFlight == 1)
        store.hasDefaultList = false
        #expect(!reminders.add("Fixture"))
        #expect(reminders.writeNotice == "Couldn't add the reminder: Reminders has no default list.")
        store.writeError = NSError(domain: "Fixture", code: 1, userInfo: [NSLocalizedDescriptionKey: "Save refused"])
        reminders.complete(ShelfRemindersModel.Entry(id: "a", title: "Fixture", due: nil))
        #expect(reminders.writeNotice == "Couldn't mark that reminder done: Save refused")
        reminders.stop()
        #expect(!reminders.canWrite)
        #expect(!reminders.add("Disabled"))
        store.answer(2, with: [])
        #expect(store.inFlight == 0)
    }
}
