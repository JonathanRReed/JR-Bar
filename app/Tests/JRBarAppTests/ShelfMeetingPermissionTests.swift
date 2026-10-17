import EventKit
import Foundation
import Testing
@testable import JRBarApp

@MainActor
@Suite("Meeting watcher permissions", .serialized)
struct ShelfMeetingPermissionTests {
    private func event(start: Date) -> ShelfCalendarModel.Event {
        ShelfCalendarModel.Event(title: "Synthetic meeting", start: start,
            end: start.addingTimeInterval(1800), url: URL(string: "https://example.test/join"))
    }

    @Test("stopping in a heads-up callback cannot restore a live meeting")
    func stopDuringHeadsUp() {
        let watch = ShelfMeetingWatch()
        let now = Date(timeIntervalSince1970: 1000)
        let previous = event(start: now.addingTimeInterval(-120))
        watch.note([previous], now: now)
        #expect(watch.live == previous)
        var changes: [ShelfCalendarModel.Event?] = []
        watch.onLiveChange = { changes.append($0) }
        watch.onSoon = { _ in watch.stop() }

        watch.note([event(start: now.addingTimeInterval(-30))], now: now)

        #expect(watch.live == nil)
        #expect(changes.count == 1)
        #expect(changes.first == .some(nil))
        #expect(!watch.running)
    }

    @Test("a new read in a heads-up callback ends the older batch")
    func newReadDuringHeadsUp() {
        let watch = ShelfMeetingWatch()
        defer { watch.stop() }
        watch.authorization = { .fullAccess }
        watch.fetchEvents = { _ in [] }
        watch.sync(enabled: true)
        var changes = 0
        watch.onLiveChange = { _ in changes += 1 }
        watch.onSoon = { _ in watch.read() }
        let now = Date(timeIntervalSince1970: 1000)

        watch.note([event(start: now.addingTimeInterval(-30))], now: now)

        #expect(watch.live == nil)
        #expect(changes == 0)
        #expect(watch.running)
    }

    @Test("revocation while fetching drops meeting titles and stops the watch",
          arguments: [EKAuthorizationStatus.denied, .restricted, .notDetermined])
    func revokeBeforeReply(status: EKAuthorizationStatus) async {
        let watch = ShelfMeetingWatch()
        defer { watch.stop() }
        watch.authorization = { .fullAccess }
        let now = Date()
        watch.note([event(start: now.addingTimeInterval(-120))], now: now)
        #expect(watch.live != nil)
        var headsUps = 0
        var cleared = 0
        watch.onSoon = { _ in headsUps += 1 }
        watch.onLiveChange = { if $0 == nil { cleared += 1 } }
        let gate = DispatchSemaphore(value: 0)
        let upcoming = event(start: now.addingTimeInterval(60))
        watch.fetchEvents = { _ in
            if gate.wait(timeout: .now() + 5) == .timedOut {
                Issue.record("meeting fetch was not released")
            }
            return [upcoming]
        }
        watch.sync(enabled: true)
        #expect(watch.running)
        watch.authorization = { status }
        gate.signal()
        await withCheckedContinuation { (settled: CheckedContinuation<Void, Never>) in
            watch.fetchQueue.async { DispatchQueue.main.async { settled.resume() } }
        }
        #expect(headsUps == 0)
        #expect(watch.live == nil)
        #expect(!watch.running)
        #expect(cleared == 1)
    }

    @Test("a later scheduled read checks authorization before fetching")
    func revokeBeforeNextRead() async {
        let watch = ShelfMeetingWatch()
        defer { watch.stop() }
        watch.authorization = { .fullAccess }
        watch.fetchEvents = { _ in [] }
        watch.sync(enabled: true)
        await withCheckedContinuation { (settled: CheckedContinuation<Void, Never>) in
            watch.fetchQueue.async { DispatchQueue.main.async { settled.resume() } }
        }
        watch.authorization = { .denied }
        watch.fetchEvents = { _ in Issue.record("revoked calendar was read"); return [] }
        watch.read()
        #expect(!watch.running)
        #expect(watch.live == nil)
    }
}
