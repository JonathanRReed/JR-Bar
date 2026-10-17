import EventKit
import Foundation
import Testing
@testable import JRBarApp

@Suite("Reminder refresh order")
@MainActor
struct ShelfReminderRefreshTests {
    nonisolated private static func isMainThread() -> Bool { Thread.isMainThread }

    @Test("EventKit callback converts reminders off main and delivers value rows on main")
    func callbackIsolation() async throws {
        let signal = AsyncStream<([ShelfRemindersModel.Entry]?, Bool)>.makeStream(
            bufferingPolicy: .bufferingOldest(1))
        let callback = ShelfRemindersModel.reminderCallback { entries in
            signal.continuation.yield((entries, Thread.isMainThread))
            signal.continuation.finish()
        }
        let deadline = Task {
            try? await Task.sleep(for: .seconds(10))
            guard !Task.isCancelled else { return }
            signal.continuation.finish()
        }
        defer {
            deadline.cancel()
            signal.continuation.finish()
        }
        let ranOnMain = await Task.detached {
            let store = EKEventStore()
            let titled = EKReminder(eventStore: store)
            titled.title = "Fixture reminder"
            let blank = EKReminder(eventStore: store)
            blank.title = ""
            callback([titled, blank])
            return Self.isMainThread()
        }.value
        #expect(!ranOnMain)
        var iterator = signal.stream.makeAsyncIterator()
        let result = await iterator.next()
        let received = try #require(result)
        #expect(received.1)
        let entries = try #require(received.0)
        #expect(entries.map(\.title) == ["Fixture reminder", "Reminder"])
        #expect(entries.allSatisfy { $0.due == nil })
    }

    @MainActor
    private final class FetchGate {
        private var replies: [@MainActor @Sendable ([ShelfRemindersModel.Entry]?) -> Void] = []
        private(set) var cancelled: [Int] = []
        var replyOnCancel = false

        var count: Int { replies.count }

        func request(_ reply: @escaping @MainActor @Sendable ([ShelfRemindersModel.Entry]?) -> Void) -> (() -> Void) {
            replies.append(reply)
            let call = replies.count
            return {
                self.cancelled.append(call)
                if self.replyOnCancel { reply([]) }
            }
        }

        func answer(_ call: Int, with entries: [ShelfRemindersModel.Entry]?) {
            replies[call - 1](entries)
        }
    }

    private func entry(_ id: String, due: Date? = nil) -> ShelfRemindersModel.Entry {
        ShelfRemindersModel.Entry(id: id, title: id, due: due)
    }

    private func model(_ gate: FetchGate) -> ShelfRemindersModel {
        let model = ShelfRemindersModel()
        model.authorization = { .fullAccess }
        model.fetchEntries = { gate.request($0) }
        model.scheduleRefreshOverride = {}
        return model
    }

    @Test("an older reply cannot replace the newer rows or schedule another refresh")
    func olderReplyLandingLast() {
        let gate = FetchGate()
        let model = model(gate)
        var scheduled = 0
        model.scheduleRefreshOverride = { scheduled += 1 }
        model.refreshNow()
        model.refreshNow()
        #expect(gate.cancelled == [1])

        gate.answer(2, with: [entry("New")])
        #expect(model.state == .items([entry("New")]))
        #expect(scheduled == 1)
        gate.answer(1, with: [entry("Old")])
        #expect(model.state == .items([entry("New")]))
        #expect(scheduled == 1)
        model.stop()
        #expect(gate.cancelled == [1], "a completed fetch needs no cancellation")
    }

    @Test("an older reply is discarded while the newer read is still pending")
    func olderReplyWhileNewerPending() {
        let gate = FetchGate()
        let model = model(gate)
        model.refreshNow()
        model.refreshNow()
        gate.answer(1, with: [entry("Old")])
        #expect(model.state == .needsPermission)
        gate.answer(2, with: [])
        #expect(model.state == .idle)
        model.stop()
    }

    @Test("stop cancels the read and its late reply cannot restart refreshes")
    func stopDuringRead() {
        let gate = FetchGate()
        let model = model(gate)
        var scheduled = 0
        model.scheduleRefreshOverride = { scheduled += 1 }
        model.refreshNow()
        model.stop()
        #expect(gate.cancelled == [1])
        gate.answer(1, with: [entry("Late")])
        #expect(model.state == .needsPermission)
        #expect(scheduled == 0)
        model.stop()
        #expect(gate.cancelled == [1])
    }

    @Test("disable and re-enable retain only the new read")
    func disableAndEnable() {
        let gate = FetchGate()
        let model = model(gate)
        model.sync(enabled: true)
        model.sync(enabled: false)
        #expect(model.state == .hidden)
        model.sync(enabled: true)
        gate.answer(1, with: [entry("Old")])
        #expect(model.state == .hidden)
        gate.answer(2, with: [entry("New")])
        #expect(model.state == .items([entry("New")]))
        model.stop()
    }

    @Test("permission lost before a reply hides the rows without another read",
          arguments: [EKAuthorizationStatus.denied, .restricted, .notDetermined])
    func permissionLostBeforeReply(status: EKAuthorizationStatus) {
        let gate = FetchGate()
        let model = model(gate)
        var scheduled = 0
        model.scheduleRefreshOverride = { scheduled += 1 }
        model.refreshNow()
        model.authorization = { status }
        gate.answer(1, with: [entry("Private")])
        let expected: ShelfRemindersModel.State = status == .notDetermined ? .needsPermission : .hidden
        #expect(model.state == expected)
        #expect(scheduled == 0)
        #expect(gate.count == 1)
    }

    @Test("a permission refresh cancels the pending read and drops its reply")
    func permissionLossCancels() {
        let gate = FetchGate()
        let model = model(gate)
        model.refreshNow()
        model.authorization = { .denied }
        model.refreshNow()
        #expect(gate.cancelled == [1])
        gate.answer(1, with: [entry("Private")])
        #expect(model.state == .hidden)
        #expect(gate.count == 1)
    }

    @Test("a failed latest read keeps the last rows and an empty read clears them")
    func failedLatestRead() {
        let gate = FetchGate()
        let model = model(gate)
        model.refreshNow()
        gate.answer(1, with: [entry("Kept")])
        model.refreshNow()
        model.refreshNow()
        gate.answer(3, with: nil)
        gate.answer(2, with: [entry("Old")])
        #expect(model.state == .items([entry("Kept")]))
        model.refreshNow()
        gate.answer(4, with: [])
        #expect(model.state == .idle)
        model.stop()
    }

    @Test("due reminders sort first and dateless reminders sort by title")
    func dueOrder() {
        let gate = FetchGate()
        let model = model(gate)
        let early = Date(timeIntervalSinceReferenceDate: 1000)
        let late = early.addingTimeInterval(60)
        let entries = [entry("Z"), entry("Late", due: late), entry("A"), entry("Early", due: early)]
        model.refreshNow()
        gate.answer(1, with: entries)
        #expect(model.state == .items([entries[3], entries[1], entries[2], entries[0]]))
        model.stop()
    }

    @Test("a reply delivered during cancellation is already stale")
    func replyDuringCancellation() {
        let gate = FetchGate()
        let model = model(gate)
        gate.replyOnCancel = true
        model.refreshNow()
        model.refreshNow()
        #expect(model.state == .needsPermission)
        #expect(gate.cancelled == [1])
        model.stop()
        #expect(model.state == .needsPermission)
        #expect(gate.cancelled == [1, 2])
    }

    @Test("synchronous and duplicate replies complete one read only once")
    func synchronousReply() {
        let model = ShelfRemindersModel()
        model.authorization = { .fullAccess }
        var cancelled = 0
        var scheduled = 0
        model.scheduleRefreshOverride = { scheduled += 1 }
        model.fetchEntries = { reply in
            reply([])
            reply([self.entry("Duplicate")])
            return { cancelled += 1 }
        }
        model.refreshNow()
        #expect(model.state == .idle)
        #expect(scheduled == 1)
        model.stop()
        #expect(cancelled == 0)
    }
}
