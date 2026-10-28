import EventKit
import Foundation
import Testing
@testable import JRBarApp

@Suite("Reminder refresh order")
@MainActor
struct ShelfReminderRefreshTests {
    private func entry(_ id: String, due: Date? = nil) -> ShelfRemindersModel.Entry {
        ShelfRemindersModel.Entry(id: id, title: id, due: due)
    }

    private func model(_ store: SyntheticShelfEventStore) -> ShelfRemindersModel {
        model(reader: ShelfReminderReader(store: store))
    }

    private func model(reader: ShelfReminderReader) -> ShelfRemindersModel {
        let model = ShelfRemindersModel(reader: reader)
        model.authorization = { .fullAccess }
        model.scheduleRefreshOverride = {}
        return model
    }

    @Test("refreshes coalesce and the superseded reply cannot draw or schedule")
    func olderReplyWhileNewerPending() {
        let store = SyntheticShelfEventStore()
        let model = model(store)
        var scheduled = 0
        model.scheduleRefreshOverride = { scheduled += 1 }
        model.sync(enabled: true)
        for _ in 0..<20 { model.refreshNow() }
        #expect(store.fetches == 1)
        store.answer(1, with: [entry("Old")])
        #expect(model.state == .needsPermission)
        #expect(scheduled == 0)
        #expect(store.fetches == 2)
        store.answer(2, with: [entry("New")])
        #expect(model.state == .items([entry("New")]))
        #expect(scheduled == 1)
        #expect(store.peakInFlight == 1)
        model.stop()
    }

    @Test("stop forgets the reply without ending the outstanding fetch")
    func stopDuringRead() {
        let store = SyntheticShelfEventStore()
        let model = model(store)
        var scheduled = 0
        model.scheduleRefreshOverride = { scheduled += 1 }
        model.sync(enabled: true)
        model.refreshNow()
        model.stop()
        #expect(store.inFlight == 1)
        store.answer(1, with: [entry("Late")])
        #expect(model.state == .needsPermission)
        #expect(scheduled == 0)
        #expect(store.fetches == 1, "stop also removes the queued refresh")
    }

    @Test("disable and re-enable retain only the new read")
    func disableAndEnable() {
        let store = SyntheticShelfEventStore()
        let model = model(store)
        model.sync(enabled: true)
        model.sync(enabled: false)
        #expect(model.state == .hidden)
        model.sync(enabled: true)
        #expect(store.fetches == 1)
        store.answer(1, with: [entry("Old")])
        #expect(model.state == .hidden)
        store.answer(2, with: [entry("New")])
        #expect(model.state == .items([entry("New")]))
        model.stop()
    }

    @Test("permission lost before a reply hides the rows without another read",
          arguments: [EKAuthorizationStatus.denied, .restricted, .notDetermined])
    func permissionLostBeforeReply(status: EKAuthorizationStatus) {
        let store = SyntheticShelfEventStore()
        let model = model(store)
        var scheduled = 0
        model.scheduleRefreshOverride = { scheduled += 1 }
        model.sync(enabled: true)
        model.authorization = { status }
        store.answer(1, with: [entry("Private")])
        let expected: ShelfRemindersModel.State = status == .notDetermined ? .needsPermission : .hidden
        #expect(model.state == expected)
        #expect(scheduled == 0)
        #expect(store.fetches == 1)
    }

    @Test("a permission refresh forgets active and queued replies without cancellation")
    func permissionLossForgets() {
        let store = SyntheticShelfEventStore()
        let model = model(store)
        model.sync(enabled: true)
        model.refreshNow()
        model.authorization = { .denied }
        model.sync(enabled: true)
        #expect(store.inFlight == 1)
        store.answer(1, with: [entry("Private")])
        #expect(model.state == .hidden)
        #expect(store.fetches == 1)
    }

    @Test("a failed latest read keeps the last rows and an empty read clears them")
    func failedLatestRead() {
        let store = SyntheticShelfEventStore()
        let model = model(store)
        model.sync(enabled: true)
        store.answer(1, with: [entry("Kept")])
        model.sync(enabled: true)
        model.sync(enabled: true)
        store.answer(2, with: [entry("Old")])
        store.answer(3, with: nil)
        #expect(model.state == .items([entry("Kept")]))
        model.sync(enabled: true)
        store.answer(4, with: [])
        #expect(model.state == .idle)
        model.stop()
    }

    @Test("due reminders sort first and dateless reminders sort by title")
    func dueOrder() {
        let store = SyntheticShelfEventStore()
        let model = model(store)
        let early = Date(timeIntervalSinceReferenceDate: 1000)
        let late = early.addingTimeInterval(60)
        let entries = [entry("Z"), entry("Late", due: late), entry("A"), entry("Early", due: early)]
        model.sync(enabled: true)
        store.answer(1, with: entries)
        #expect(model.state == .items([entries[3], entries[1], entries[2], entries[0]]))
        model.stop()
    }

    @Test("synchronous and duplicate replies complete one read only once")
    func synchronousReply() {
        let store = SyntheticShelfEventStore()
        store.synchronous = true
        let model = model(store)
        var scheduled = 0
        model.scheduleRefreshOverride = { scheduled += 1 }
        model.sync(enabled: true)
        #expect(model.state == .idle)
        #expect(scheduled == 1)
        model.stop()

        store.synchronous = false
        model.sync(enabled: true)
        let duplicate = store.answer(2, with: [])
        model.refreshNow()
        duplicate?([entry("Duplicate")])
        #expect(store.inFlight == 1)
        #expect(model.state == .idle)
        #expect(scheduled == 2)
        store.answer(3, with: [])
        #expect(scheduled == 3)
        model.stop()
    }

    enum Action: CaseIterable, Sendable { case sync, stop, refresh, disable }

    /// Every length-three ordering, including repetitions and disabled refreshes.
    nonisolated static var orderings: [[Action]] {
        Action.allCases.flatMap { first in
            Action.allCases.flatMap { second in Action.allCases.map { [first, second, $0] } }
        }
    }

    @Test("lifecycle ordering never cancels, overlaps, or accepts a stale reply",
          arguments: orderings, [false, true])
    func lifecycleMatrix(actions: [Action], twoModels: Bool) {
        let store = SyntheticShelfEventStore()
        let reader = ShelfReminderReader(store: store)
        let first = model(reader: reader)
        let second = twoModels ? model(reader: reader) : first
        first.sync(enabled: true)
        for action in actions {
            switch action {
            case .sync: second.sync(enabled: true)
            case .stop: second.stop()
            case .refresh: second.refreshNow()
            case .disable: second.sync(enabled: false)
            }
            #expect(store.inFlight == 1)
            #expect(store.fetches == 1)
        }
        // A fresh request supersedes every earlier request, even after stop.
        first.sync(enabled: true)
        second.sync(enabled: true)
        store.answer(1, with: [entry("Stale")])
        #expect(first.state != .items([entry("Stale")]))
        #expect(second.state != .items([entry("Stale")]))
        #expect(store.fetches == 2)
        store.answer(2, with: [entry("Fresh")])
        #expect(first.state == .items([entry("Fresh")]))
        #expect(second.state == .items([entry("Fresh")]))
        #expect(store.peakInFlight == 1)
        #expect(store.inFlight == 0)
        first.stop()
        second.stop()
    }

    @Test("every lifecycle ordering retains the store until the outstanding fetch finishes", arguments: orderings)
    func retainsStoreUntilCompletion(actions: [Action]) {
        var store: SyntheticShelfEventStore? = SyntheticShelfEventStore()
        weak var retainedStore = store
        var reader: ShelfReminderReader? = ShelfReminderReader(store: store!)
        weak var retainedReader = reader
        var model: ShelfRemindersModel? = self.model(reader: reader!)
        weak var releasedModel = model
        model?.sync(enabled: true)
        for action in actions {
            switch action {
            case .sync: model?.sync(enabled: true)
            case .stop: model?.stop()
            case .refresh: model?.refreshNow()
            case .disable: model?.sync(enabled: false)
            }
        }
        model?.stop()
        model = nil
        reader = nil
        store = nil
        #expect(releasedModel == nil)
        #expect(retainedReader != nil)
        #expect(retainedStore?.inFlight == 1)
        retainedStore?.answer(1, with: [])
        #expect(retainedReader == nil)
        #expect(retainedStore == nil)
    }
}
