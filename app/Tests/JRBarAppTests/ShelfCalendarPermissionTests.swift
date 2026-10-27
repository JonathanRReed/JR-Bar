import EventKit
import Foundation
import os
import JRBarTestSupport
import Testing
@testable import JRBarApp

@Suite("Shelf calendar permissions", .serialized, .timeLimit(.minutes(2)))
@MainActor
struct ShelfCalendarPermissionTests {
    @Test("stop cancels calendar work queued behind another read")
    func stoppedQueuedReadMakesNoCall() async {
        let model = ShelfCalendarModel()
        let gate = TestGate()
        let calls = OSAllocatedUnfairLock(initialState: 0)
        model.authorization = { .fullAccess }
        model.fetchEvents = { _ in calls.withLock { $0 += 1 }; return [] }
        model.readQueue.async { gate.wait() }
        model.sync(enabled: true)
        model.stop()
        gate.signal()
        await withCheckedContinuation { continuation in
            model.readQueue.async { continuation.resume() }
        }
        #expect(calls.withLock { $0 } == 0)
    }

    @Test("a pending calendar read never arms another periodic fetch")
    func oneReadOwnsRefresh() async throws {
        let model = ShelfCalendarModel()
        model.authorization = { .fullAccess }
        let entered = TestSignal()
        let release = TestGate()
        defer { release.signal(); model.stop() }
        var scheduled = 0
        model.scheduleRefreshOverride = { scheduled += 1 }
        model.fetchEvents = { _ in
            entered.signal()
            release.wait()
            return []
        }
        model.sync(enabled: true)
        try #require(await entered.wait())
        #expect(scheduled == 0)
        release.signal()
        #expect(await waitForObservedState { model.state == .idle })
        #expect(scheduled == 1)
    }

    @Test("a delayed calendar reply removes ended meetings before applying the row limit")
    func delayedReplyUsesCurrentTime() async {
        let model = ShelfCalendarModel()
        model.scheduleRefreshOverride = {}
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
        let gate = TestGate()
        defer { gate.signal(); model.stop() }
        model.fetchEvents = { _ in
            gate.wait()
            return events
        }
        model.sync(enabled: true)
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
        model.scheduleRefreshOverride = {}
        model.authorization = { .fullAccess }
        let base = Date(timeIntervalSince1970: 1000)
        var now = base
        model.clock = { now }
        let event = ShelfCalendarModel.Event(title: "Ended", start: base.addingTimeInterval(10),
                                             end: base.addingTimeInterval(60), url: nil)
        let gate = TestGate()
        defer { gate.signal(); model.stop() }
        model.fetchEvents = { _ in
            gate.wait()
            return [event]
        }
        model.sync(enabled: true)
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
        model.scheduleRefreshOverride = {}
        model.authorization = { .fullAccess }
        let start = Date().addingTimeInterval(600)
        let event = ShelfCalendarModel.Event(title: "Private meeting", start: start,
                                             end: start.addingTimeInterval(900), url: nil)
        let gate = TestGate()
        defer { gate.signal(); model.stop() }
        model.fetchEvents = { _ in
            gate.wait()
            return [event]
        }
        // Revocation happens before yielding the main actor. The reply
        // cannot publish while the test waits for an unrelated main-queue hop.
        model.sync(enabled: true)
        model.authorization = { status }
        gate.signal()
        await withCheckedContinuation { (settled: CheckedContinuation<Void, Never>) in
            model.readQueue.async { DispatchQueue.main.async { settled.resume() } }
        }
        let expected: ShelfCalendarModel.State = status == .notDetermined ? .needsPermission : .hidden
        #expect(model.state == expected)
    }
}
