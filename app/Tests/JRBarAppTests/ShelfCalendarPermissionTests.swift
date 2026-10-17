import EventKit
import Foundation
import Testing
@testable import JRBarApp

@Suite("Shelf calendar permissions", .serialized)
@MainActor
struct ShelfCalendarPermissionTests {
    @Test("a delayed calendar reply removes ended meetings before applying the row limit")
    func delayedReplyUsesCurrentTime() async {
        let model = ShelfCalendarModel()
        model.authorization = { .fullAccess }
        let base = Date(timeIntervalSince1970: 1000)
        var now = base
        model.clock = { now }
        let ended = (0..<ShelfCalendarModel.eventLimit).map { index in
            ShelfCalendarModel.Event(title: "Ended \(index)", start: base.addingTimeInterval(60),
                                     end: base.addingTimeInterval(120), url: nil)
        }
        let upcoming = ShelfCalendarModel.Event(title: "Upcoming", start: base.addingTimeInterval(200),
                                                end: base.addingTimeInterval(400), url: nil)
        let events = ended + [upcoming]
        let gate = DispatchSemaphore(value: 0)
        defer { gate.signal(); model.stop() }
        model.fetchEvents = { _ in
            if gate.wait(timeout: .now() + 5) == .timedOut { Issue.record("calendar read was not released") }
            return events
        }
        model.refreshNow()
        now = base.addingTimeInterval(130)
        gate.signal()
        await withCheckedContinuation { (settled: CheckedContinuation<Void, Never>) in
            model.readQueue.async { DispatchQueue.main.async { settled.resume() } }
        }
        #expect(model.state == .events([upcoming]))
    }

    @Test("events ending at or before reply time leave an authorized glance idle", arguments: [60.0, 90.0])
    func allEventsEndWhileReading(replyAge: TimeInterval) async {
        let model = ShelfCalendarModel()
        model.authorization = { .fullAccess }
        let base = Date(timeIntervalSince1970: 1000)
        var now = base
        model.clock = { now }
        let event = ShelfCalendarModel.Event(title: "Ended", start: base.addingTimeInterval(10),
                                             end: base.addingTimeInterval(60), url: nil)
        let gate = DispatchSemaphore(value: 0)
        defer { gate.signal(); model.stop() }
        model.fetchEvents = { _ in
            if gate.wait(timeout: .now() + 5) == .timedOut { Issue.record("calendar read was not released") }
            return [event]
        }
        model.refreshNow()
        now = base.addingTimeInterval(replyAge)
        gate.signal()
        await withCheckedContinuation { (settled: CheckedContinuation<Void, Never>) in
            model.readQueue.async { DispatchQueue.main.async { settled.resume() } }
        }
        #expect(model.state == .idle)
    }

    @Test("permission lost before a calendar reply hides its events",
          arguments: [EKAuthorizationStatus.denied, .notDetermined])
    func permissionLostBeforeReply(status: EKAuthorizationStatus) async {
        let model = ShelfCalendarModel()
        model.authorization = { .fullAccess }
        let start = Date().addingTimeInterval(600)
        let event = ShelfCalendarModel.Event(title: "Private meeting", start: start,
                                             end: start.addingTimeInterval(900), url: nil)
        let gate = DispatchSemaphore(value: 0)
        defer { gate.signal(); model.stop() }
        model.fetchEvents = { _ in
            let released = gate.wait(timeout: .now() + 5)
            if released == .timedOut { Issue.record("calendar fetch was never released") }
            return [event]
        }
        // Revocation happens before yielding the main actor. The reply
        // cannot publish while the test waits for an unrelated main-queue hop.
        model.refreshNow()
        model.authorization = { status }
        gate.signal()
        await withCheckedContinuation { (settled: CheckedContinuation<Void, Never>) in
            model.readQueue.async { DispatchQueue.main.async { settled.resume() } }
        }
        let expected: ShelfCalendarModel.State = status == .notDetermined ? .needsPermission : .hidden
        #expect(model.state == expected)
    }
}
