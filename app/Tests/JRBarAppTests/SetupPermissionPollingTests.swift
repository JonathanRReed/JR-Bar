import Foundation
import Testing
@testable import JRBarApp

@MainActor
@Suite("Setup permission poll ownership", .serialized)
struct SetupPermissionPollingTests {
    @MainActor
    private final class Gate {
        private var pending: [Int: CheckedContinuation<[SetupPermission: SetupPermissionStatus], Never>] = [:]
        private(set) var calls = 0

        func read() async -> [SetupPermission: SetupPermissionStatus] {
            calls += 1
            let call = calls
            return await withCheckedContinuation { pending[call] = $0 }
        }

        func answer(_ call: Int, _ statuses: [SetupPermission: SetupPermissionStatus]) {
            pending.removeValue(forKey: call)?.resume(returning: statuses)
        }

        func finish() {
            let held = Array(pending.values)
            pending.removeAll()
            for continuation in held { continuation.resume(returning: [:]) }
        }
    }

    private func until(_ predicate: () -> Bool) async throws {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(5))
        while !predicate(), clock.now < deadline, !Task.isCancelled { await Task.yield() }
        try #require(predicate(), "Synthetic permission read did not start")
    }

    @Test("the initial permission scan owns the poll until it settles")
    func initialScanCoalescesWithPoll() async throws {
        let gate = Gate()
        var model = SetupModel()
        model.refreshPermissions = { await gate.read() }
        let store = SetupStore(model: model, load: { SetupState() }, persist: { _ in })
        defer { store.stopPermissionUpdates(); gate.finish() }
        let initial = try #require(store.startPermissionUpdates())
        try await until { gate.calls == 1 }
        let duplicate = store.pollPermissions()
        #expect(duplicate == nil, "The initial scan must own the poll")
        if let duplicate {
            try await until { gate.calls == 2 }
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
        let store = SetupStore(model: model, load: { SetupState() }, persist: { _ in })
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
        let store = SetupStore(model: model, load: { SetupState() }, persist: { _ in })
        defer { store.stopPermissionUpdates(); gate.finish() }
        let initial = try #require(store.startPermissionUpdates())
        #expect(store.startPermissionUpdates() == nil)
        try await until { gate.calls == 1 }
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
        let store = SetupStore(model: model, load: { SetupState() }, persist: { _ in })
        defer { store.stopPermissionUpdates(); gate.finish() }
        let old = try #require(store.startPermissionUpdates())
        store.stopPermissionUpdates()
        let current = try #require(store.startPermissionUpdates())
        await old.value
        try await until { gate.calls == 1 }
        #expect(store.pollPermissions() == nil)
        #expect(store.startPermissionUpdates() == nil)
        gate.answer(1, [.camera: .granted])
        await current.value
        #expect(gate.calls == 1)
        #expect(store.status(of: .camera) == .granted)
        let next = try #require(store.pollPermissions())
        try await until { gate.calls == 2 }
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
        let store = SetupStore(model: model, load: { SetupState() }, persist: { _ in })
        let old = try #require(store.pollPermissions())
        try await until { gate.calls == 1 }
        store.stopPermissionUpdates()

        let requested = store.pollPermissions()
        #expect(requested != nil, "A retired cycle must not keep the reopened poll busy")
        guard let current = requested else {
            gate.answer(1, [.camera: .denied])
            await old.value
            return
        }
        try await until { gate.calls == 2 }
        gate.answer(1, [.camera: .denied])
        await old.value
        #expect(store.status(of: .camera) == .unknown)
        let unwanted = store.pollPermissions()
        #expect(unwanted == nil, "Old cleanup must not release the newer poll")
        if let unwanted {
            try await until { gate.calls == 3 }
            gate.answer(3, [:])
            await unwanted.value
        }
        gate.answer(2, [.camera: .granted])
        await current.value
        #expect(store.status(of: .camera) == .granted)
        let next = try #require(store.pollPermissions())
        let nextCall = gate.calls + 1
        try await until { gate.calls == nextCall }
        gate.answer(nextCall, [.camera: .needed])
        await next.value
        #expect(store.status(of: .camera) == .needed)
    }

    @Test("stopping before a queued poll starts prevents its permission probe")
    func stoppedQueuedPollDoesNotProbe() async throws {
        var reads = 0
        var model = SetupModel()
        model.refreshPermissions = { reads += 1; return [.camera: .granted] }
        let store = SetupStore(model: model, load: { SetupState() }, persist: { _ in })
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
        let store = SetupStore(model: model, load: { SetupState() }, persist: { _ in })
        store.stopPermissionUpdates()
        store.stopPermissionUpdates()
        let read = try #require(store.pollPermissions())
        try await until { gate.calls == 1 }
        #expect(store.pollPermissions() == nil)
        gate.answer(1, [.camera: .granted])
        await read.value
        let retry = try #require(store.pollPermissions())
        try await until { gate.calls == 2 }
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
                               persist: { saved.append($0) })
        let health = Task { await store.reviewPermissionHealth() }
        try await until { gate.calls == 1 }
        let poll = try #require(store.pollPermissions())
        try await until { gate.calls == 2 }
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
