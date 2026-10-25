import Foundation
import Testing
@testable import JRBarApp

@MainActor
@Suite("Setup permission poll ownership", .serialized, .timeLimit(.minutes(10)))
struct SetupPermissionPollingTests {
    @MainActor
    private final class Gate {
        private let starts = TestEvents<Int>()
        private var finished = false

        func waitForCall(_ call: Int) async throws {
            if calls < call { _ = try await starts.next { $0 >= call } }
            try #require(calls == call)
        }
        private var pending: [Int: CheckedContinuation<[SetupPermission: SetupPermissionStatus], Never>] = [:]
        private(set) var calls = 0

        func read() async -> [SetupPermission: SetupPermissionStatus] {
            guard !finished else { return [:] }
            calls += 1
            let call = calls
            return await withCheckedContinuation {
                pending[call] = $0
                starts.send(call)
            }
        }

        func answer(_ call: Int, _ statuses: [SetupPermission: SetupPermissionStatus]) {
            pending.removeValue(forKey: call)?.resume(returning: statuses)
        }

        func finish() {
            finished = true
            let held = Array(pending.values)
            pending.removeAll()
            for continuation in held { continuation.resume(returning: [:]) }
        }
    }

    private static func manualPoll(_ tick: @escaping @MainActor () -> Void) -> Timer {
        Timer(timeInterval: 1.5, repeats: true) { _ in MainActor.assumeIsolated { tick() } }
    }

    @Test("only an explicit clock tick polls again, and stopping disarms it")
    func manualClockOwnsPolling() async throws {
        let gate = Gate()
        var timer: Timer?
        var model = SetupModel()
        model.refreshPermissions = { await gate.read() }
        let store = SetupStore(model: model, load: { SetupState() }, persist: { _ in },
                               schedulePermissionPoll: { tick in
            let scheduled = Self.manualPoll(tick)
            timer = scheduled
            return scheduled
        })
        defer { store.stopPermissionUpdates(); gate.finish() }
        let initial = try #require(store.startPermissionUpdates())
        try await gate.waitForCall(1)
        gate.answer(1, [.camera: .granted])
        await initial.value
        #expect(gate.calls == 1)
        let scheduled = try #require(timer)
        scheduled.fire()
        try await gate.waitForCall(2)
        #expect(store.pollPermissions() == nil)
        gate.answer(2, [.camera: .denied])
        #expect(await waitForObservedState { store.status(of: .camera) == .denied })
        store.stopPermissionUpdates()
        #expect(!scheduled.isValid)
    }

    @Test("the initial permission scan owns the poll until it settles")
    func initialScanCoalescesWithPoll() async throws {
        let gate = Gate()
        var model = SetupModel()
        model.refreshPermissions = { await gate.read() }
        let store = SetupStore(model: model, load: { SetupState() }, persist: { _ in }, schedulePermissionPoll: Self.manualPoll)
        defer { store.stopPermissionUpdates(); gate.finish() }
        let initial = try #require(store.startPermissionUpdates())
        try await gate.waitForCall(1)
        let duplicate = store.pollPermissions()
        #expect(duplicate == nil, "The initial scan must own the poll")
        if let duplicate {
            try await gate.waitForCall(2)
            gate.finish()
            await duplicate.value
        } else {
            gate.finish()
        }
        await initial.value
    }

    @Test("stopping updates before the initial task starts prevents its probe")
    func stoppedQueuedInitialScanDoesNotProbe() async throws {
        var reads = 0
        var model = SetupModel()
        model.refreshPermissions = { reads += 1; return [.camera: .granted] }
        let store = SetupStore(model: model, load: { SetupState() }, persist: { _ in }, schedulePermissionPoll: Self.manualPoll)
        defer { store.stopPermissionUpdates() }
        let initial = try #require(store.startPermissionUpdates())
        store.stopPermissionUpdates()
        await initial.value
        #expect(reads == 0)
        #expect(store.status(of: .camera) == .unknown)
    }

    @Test("repeated starts share the initial permission scan")
    func repeatedStartCoalesces() async throws {
        let gate = Gate()
        var model = SetupModel()
        model.refreshPermissions = { await gate.read() }
        let store = SetupStore(model: model, load: { SetupState() }, persist: { _ in }, schedulePermissionPoll: Self.manualPoll)
        defer { store.stopPermissionUpdates(); gate.finish() }
        let initial = try #require(store.startPermissionUpdates())
        #expect(store.startPermissionUpdates() == nil)
        try await gate.waitForCall(1)
        #expect(store.startPermissionUpdates() == nil)
        #expect(store.pollPermissions() == nil)
        gate.finish()
        await initial.value
        #expect(gate.calls == 1)
        #expect(store.startPermissionUpdates() == nil)
    }

    @Test("a queued initial scan cannot start or clear a reopened scan's ownership")
    func stoppedQueuedInitialScanKeepsReopenedScanIndependent() async throws {
        let gate = Gate()
        var model = SetupModel()
        model.refreshPermissions = { await gate.read() }
        let store = SetupStore(model: model, load: { SetupState() }, persist: { _ in }, schedulePermissionPoll: Self.manualPoll)
        defer { store.stopPermissionUpdates(); gate.finish() }
        let old = try #require(store.startPermissionUpdates())
        store.stopPermissionUpdates()
        let current = try #require(store.startPermissionUpdates())
        await old.value
        try await gate.waitForCall(1)
        #expect(store.pollPermissions() == nil)
        #expect(store.startPermissionUpdates() == nil)
        gate.answer(1, [.camera: .granted])
        await current.value
        #expect(gate.calls == 1)
        #expect(store.status(of: .camera) == .granted)
        let next = try #require(store.pollPermissions())
        try await gate.waitForCall(2)
        gate.answer(2, [.camera: .denied])
        await next.value
        #expect(store.status(of: .camera) == .denied)
    }

    @Test("a stopped poll does not block a new cycle or clear its busy state")
    func stoppedPollKeepsNewCycleIndependent() async throws {
        let gate = Gate()
        defer { gate.finish() }
        var model = SetupModel()
        model.refreshPermissions = { await gate.read() }
        let store = SetupStore(model: model, load: { SetupState() }, persist: { _ in }, schedulePermissionPoll: Self.manualPoll)
        let old = try #require(store.pollPermissions())
        try await gate.waitForCall(1)
        store.stopPermissionUpdates()

        let requested = store.pollPermissions()
        #expect(requested != nil, "A retired cycle must not keep the reopened poll busy")
        guard let current = requested else {
            gate.answer(1, [.camera: .denied])
            await old.value
            return
        }
        try await gate.waitForCall(2)
        gate.answer(1, [.camera: .denied])
        await old.value
        #expect(store.status(of: .camera) == .unknown)
        let unwanted = store.pollPermissions()
        #expect(unwanted == nil, "Old cleanup must not release the newer poll")
        if let unwanted {
            try await gate.waitForCall(3)
            gate.answer(3, [:])
            await unwanted.value
        }
        gate.answer(2, [.camera: .granted])
        await current.value
        #expect(store.status(of: .camera) == .granted)
        let next = try #require(store.pollPermissions())
        let nextCall = gate.calls + 1
        try await gate.waitForCall(nextCall)
        gate.answer(nextCall, [.camera: .needed])
        await next.value
        #expect(store.status(of: .camera) == .needed)
    }

    @Test("stopping before a queued poll starts prevents its permission probe")
    func stoppedQueuedPollDoesNotProbe() async throws {
        var reads = 0
        var model = SetupModel()
        model.refreshPermissions = { reads += 1; return [.camera: .granted] }
        let store = SetupStore(model: model, load: { SetupState() }, persist: { _ in }, schedulePermissionPoll: Self.manualPoll)
        let queued = try #require(store.pollPermissions())
        store.stopPermissionUpdates()
        await queued.value
        #expect(reads == 0)
        #expect(store.status(of: .camera) == .unknown)
        let next = try #require(store.pollPermissions())
        await next.value
        #expect(reads == 1)
        #expect(store.status(of: .camera) == .granted)
    }

    @Test("repeated stop calls leave a later cycle able to poll without overlap")
    func repeatedStopKeepsPollingAvailable() async throws {
        let gate = Gate()
        defer { gate.finish() }
        var model = SetupModel()
        model.refreshPermissions = { await gate.read() }
        let store = SetupStore(model: model, load: { SetupState() }, persist: { _ in }, schedulePermissionPoll: Self.manualPoll)
        store.stopPermissionUpdates()
        store.stopPermissionUpdates()
        let read = try #require(store.pollPermissions())
        try await gate.waitForCall(1)
        #expect(store.pollPermissions() == nil)
        gate.answer(1, [.camera: .granted])
        await read.value
        let retry = try #require(store.pollPermissions())
        try await gate.waitForCall(2)
        gate.answer(2, [.camera: .denied])
        await retry.value
        #expect(store.status(of: .camera) == .denied)
    }

    @Test("stopping the UI poll does not suppress an independent lost-permission review")
    func healthReviewSurvivesPollStop() async throws {
        let gate = Gate()
        defer { gate.finish() }
        var saved: [SetupState] = []
        var model = SetupModel()
        model.refreshPermissions = { await gate.read() }
        let store = SetupStore(model: model, load: { SetupState(grantedPermissions: ["camera"]) },
                               persist: { saved.append($0) }, schedulePermissionPoll: Self.manualPoll)
        let health = Task { await store.reviewPermissionHealth() }
        try await gate.waitForCall(1)
        let poll = try #require(store.pollPermissions())
        try await gate.waitForCall(2)
        store.stopPermissionUpdates()
        gate.answer(2, [.camera: .denied])
        await poll.value
        gate.answer(1, [.camera: .granted])
        #expect(await health.value == [.camera])
        #expect(store.status(of: .camera) == .denied)
        #expect(saved.count == 1)
        #expect(saved.first?.grantedPermissions == [])
    }
}
