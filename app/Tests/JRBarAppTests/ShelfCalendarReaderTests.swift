import EventKit
import Foundation
import JRBarTestSupport
import os
import Testing
@testable import JRBarApp

@Suite("Shared calendar reader", .timeLimit(.minutes(2)))
struct ShelfCalendarReaderTests {
    static let now = Date(timeIntervalSince1970: 1_800_000_000)

    @Test("notch projections and other consumers reuse the same cached read")
    func sharedRead() {
        let reads = OSAllocatedUnfairLock(initialState: 0)
        let timed = ShelfCalendarModel.Event(title: "Meeting", start: Self.now,
            end: Self.now.addingTimeInterval(600), url: nil)
        var allDay = timed
        allDay.isAllDay = true
        let later = ShelfCalendarModel.Event(title: "Later", start: Self.now.addingTimeInterval(90_000),
            end: Self.now.addingTimeInterval(100_000), url: nil)
        var detailed = timed
        detailed.location = "Room 4"
        detailed.calendarTitle = "Synthetic calendar"
        detailed.calendarIdentifier = "test-calendar"
        let events = [detailed, allDay, later]
        let reader = ShelfCalendarReader(fetch: { _ in reads.withLock { $0 += 1 }; return events })
        #expect(reader.events(from: Self.now) == events)
        #expect(ShelfCalendarModel.fetchUpcoming(from: Self.now, reader: reader) == [timed])
        #expect(reader.events(from: Self.now.addingTimeInterval(59)) == events)
        #expect(reads.withLock { $0 } == 1)
        reader.notifications.post(name: .EKEventStoreChanged, object: nil)
        _ = reader.events(from: Self.now)
        #expect(reads.withLock { $0 } == 2)
    }

    @Test("revoked access clears cached events before returning any title")
    func revokedCache() {
        let access = OSAllocatedUnfairLock(initialState: true)
        let reads = OSAllocatedUnfairLock(initialState: 0)
        let event = ShelfCalendarModel.Event(title: "Synthetic event", start: Self.now,
            end: Self.now.addingTimeInterval(600), url: nil)
        let reader = ShelfCalendarReader(fetch: { _ in reads.withLock { $0 += 1 }; return [event] },
            authorization: { access.withLock { $0 } ? .fullAccess : .denied })
        #expect(reader.events(from: Self.now) == [event])
        access.withLock { $0 = false }
        #expect(reader.events(from: Self.now).isEmpty)
        access.withLock { $0 = true }
        #expect(reader.events(from: Self.now) == [event])
        #expect(reads.withLock { $0 } == 2)
    }

    @Test("a store change never waits for a slow read and prevents caching that read")
    func invalidateDuringRead() async {
        let gate = TestGate()
        defer { gate.signal() }
        let entered = TestSignal()
        let reads = OSAllocatedUnfairLock(initialState: 0)
        let reader = ShelfCalendarReader(fetch: { _ in
            let count = reads.withLock { $0 += 1; return $0 }
            if count == 1 { entered.signal(); gate.wait() }
            return []
        })
        let fetch = Task.detached { reader.events(from: Self.now) }
        #expect(await entered.wait())
        let invalidated = TestSignal()
        let invalidation = Task.detached {
            reader.invalidate()
            invalidated.signal()
        }
        #expect(await invalidated.wait())
        gate.signal()
        _ = await fetch.value
        await invalidation.value
        _ = reader.events(from: Self.now)
        #expect(reads.withLock { $0 } == 2)
    }
}
