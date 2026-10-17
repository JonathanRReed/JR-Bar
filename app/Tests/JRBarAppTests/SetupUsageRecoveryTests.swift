import AppKit
import Foundation
import Observation
import SwiftUI
import Testing
@testable import JRBarApp
@testable import JRBarCore

@MainActor
@Suite("Setup usage recovery", .serialized)
struct SetupUsageRecoveryTests {
    @MainActor
    private final class ReadGate<Value: Sendable> {
        private var pending: [Int: CheckedContinuation<Value, Error>] = [:]
        private(set) var calls = 0
        func read() async throws -> Value {
            calls += 1
            let call = calls
            return try await withCheckedThrowingContinuation { pending[call] = $0 }
        }
        func answer(_ call: Int, _ result: Result<Value, Error>) {
            pending.removeValue(forKey: call)?.resume(with: result)
        }
        func finish() {
            let held = Array(pending.values)
            pending.removeAll()
            for continuation in held { continuation.resume(throwing: CancellationError()) }
        }
    }

    private func offer(_ summary: String = "Synthetic usage offer.") -> SetupUsageOffer {
        SetupUsageOffer(id: "claude", name: "Claude", question: "Show Claude usage?", summary: summary, isOn: false)
    }

    @MainActor
    @Observable
    final class Detection { var found = false }

    private func until(_ predicate: () -> Bool) async throws {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(5))
        while !predicate(), clock.now < deadline, !Task.isCancelled { await Task.yield() }
        try #require(predicate(), "Synthetic Setup usage read did not settle")
    }

    @Test("the live adapter preserves a provider-list failure instead of returning an empty offer list")
    func adapterKeepsReadFailure() async {
        let core = CoreModel(socketPath: NSTemporaryDirectory() + "jrbar-setup-offers-\(UUID().uuidString).sock")
        core.handle(.connected)
        core.apply(.state(CoreState()))
        #expect(core.isLive)
        var failed = false
        do { _ = try await SetupModel.usageOffers(on: core) }
        catch { failed = true }
        #expect(failed, "A failed list must remain distinguishable from a successful empty list")
    }

    @Test("the Agents step notices a newly detected provider while the monitor stays connected")
    func lateDetectionRefreshesOffers() async throws {
        _ = NSApplication.shared
        let detection = Detection()
        var reads = 0
        var writes = 0
        var agentChecks = 0
        var model = SetupModel()
        model.monitorLive = { true }
        model.agents = {
            agentChecks += 1
            return [SetupAgent(id: "claude", name: "Claude", detected: detection.found, hookStatus: "missing")]
        }
        model.usageOffers = {
            reads += 1
            return detection.found ? [SetupUsageOffer(id: "claude", name: "Claude", question: "Show Claude usage?",
                summary: "Synthetic usage offer.", isOn: false)] : []
        }
        model.setUsage = { _, _ in writes += 1; return SetupNote("Synthetic write", isError: false) }
        let store = SetupStore(model: model, load: { SetupState() }, persist: { _ in })
        store.jump(to: .agents)
        await store.refreshUsageOffers()
        let host = NSHostingView(rootView: SetupAgentsStep(store: store))
        host.frame = NSRect(x: 0, y: 0, width: 560, height: 390)
        host.layoutSubtreeIfNeeded()
        let initialChecks = agentChecks
        try #require(initialChecks > 0)
        detection.found = true
        host.rootView = SetupAgentsStep(store: store)
        host.layoutSubtreeIfNeeded()
        try await until { agentChecks > initialChecks }
        try await until { store.usageOffers.count == 1 }
        #expect(store.monitorLive)
        #expect(store.usageOffers.first?.isOn == false)
        #expect(reads == 2 && writes == 0)
        withExtendedLifetime(host) {}
    }

    @Test("returning to Agents reads providers detected while another step was open")
    func backToAgentsRefreshesOffers() async throws {
        let detection = Detection()
        var reads = 0
        var model = SetupModel()
        model.monitorLive = { true }
        model.agents = { [SetupAgent(id: "claude", name: "Claude", detected: detection.found, hookStatus: "missing")] }
        model.usageOffers = {
            reads += 1
            return detection.found ? [SetupUsageOffer(id: "claude", name: "Claude", question: "Show Claude usage?",
                summary: "Synthetic usage offer.", isOn: false)] : []
        }
        let store = SetupStore(model: model, load: { SetupState() }, persist: { _ in })
        await store.refreshUsageOffers()
        store.jump(to: .permissions)
        detection.found = true
        store.goBack()
        #expect(store.step == .agents)
        try await until { store.usageOffers.count == 1 }
        #expect(reads == 2)
        #expect(store.usageOffers.first?.isOn == false)
    }

    @Test("a failed read keeps last choices and Not now, and a metadata retry can recover")
    func failedReadRetainsChoicesAndCanRetry() async {
        let before = offer(), after = offer("Fresh synthetic words.")
        var writes = 0
        var model = SetupModel()
        model.monitorLive = { true }
        model.usageOffers = { [before] }
        model.setUsage = { _, _ in writes += 1; return SetupNote("Synthetic write", isError: false) }
        let store = SetupStore(model: model, load: { SetupState() }, persist: { _ in })
        await store.refreshUsageOffers()
        store.declineUsage(for: "claude")
        store.model.usageOffers = { throw CoreClientError.notConnected }
        await store.refreshUsageOffers()
        #expect(store.usageOffers == [before])
        #expect(store.usageChoices["claude"] == .notNow)
        #expect(store.usageOffersFailure == "Usage choices could not be refreshed. Showing the last choices.")
        #expect(!store.loadingUsageOffers)
        store.model.usageOffers = { [after] }
        await store.refreshUsageOffers()
        #expect(store.usageOffers == [after])
        #expect(store.usageOffersFailure == nil && !store.loadingUsageOffers)
        #expect(store.usageChoices["claude"] == .notNow)
        #expect(writes == 0)
    }

    @Test("a successful empty offer read clears a prior failure")
    func successfulEmptyReadIsNotFailure() async {
        var model = SetupModel()
        model.monitorLive = { true }
        model.usageOffers = { throw CoreClientError.notConnected }
        let store = SetupStore(model: model, load: { SetupState() }, persist: { _ in })
        await store.refreshUsageOffers()
        #expect(store.usageOffersFailure == "Usage choices could not be loaded.")
        store.model.usageOffers = { [] }
        await store.refreshUsageOffers()
        #expect(store.usageOffers.isEmpty)
        #expect(store.usageOffersFailure == nil && !store.loadingUsageOffers)
    }

    @Test("an obsolete failure cannot end a newer read or replace its result")
    func obsoleteFailureKeepsCurrentReadLoading() async throws {
        let gate = ReadGate<[SetupUsageOffer]>()
        defer { gate.finish() }
        let expected = offer()
        var model = SetupModel()
        model.monitorLive = { true }
        model.usageOffers = { try await gate.read() }
        let store = SetupStore(model: model, load: { SetupState() }, persist: { _ in })
        let older = Task { await store.refreshUsageOffers() }
        try await until { gate.calls == 1 }
        let newer = Task { await store.refreshUsageOffers() }
        try await until { gate.calls == 2 }
        gate.answer(1, .failure(CoreClientError.notConnected))
        await older.value
        #expect(store.loadingUsageOffers)
        #expect(store.usageOffersFailure == nil)
        gate.answer(2, .success([expected]))
        await newer.value
        #expect(store.usageOffers == [expected])
        #expect(store.usageOffersFailure == nil && !store.loadingUsageOffers)
    }

    @Test("an accepted consent write retires an old read without leaving its loading state behind")
    func consentWriteRetiresLoadingRead() async throws {
        let gate = ReadGate<[SetupUsageOffer]>()
        defer { gate.finish() }
        let before = offer()
        var writes = 0
        var model = SetupModel()
        model.monitorLive = { true }
        model.usageOffers = { [before] }
        model.setUsage = { _, _ in writes += 1; return SetupNote("Synthetic saved", isError: false) }
        let store = SetupStore(model: model, load: { SetupState() }, persist: { _ in })
        await store.refreshUsageOffers()
        store.model.usageOffers = { try await gate.read() }
        let read = Task { await store.refreshUsageOffers() }
        try await until { gate.calls == 1 }
        let write = try #require(store.turnOnUsage(for: "claude"))
        await write.value
        gate.answer(1, .success([before]))
        await read.value
        #expect(store.usageOffers.first?.isOn == true)
        #expect(store.usageOffersFailure == nil && !store.loadingUsageOffers)
        #expect(writes == 1)
    }

    @Test("a cancelled read retains rows and ends loading without showing an error")
    func cancelledReadRetainsRows() async throws {
        let gate = ReadGate<[SetupUsageOffer]>()
        defer { gate.finish() }
        let before = offer()
        var model = SetupModel()
        model.usageOffers = { [before] }
        let store = SetupStore(model: model, load: { SetupState() }, persist: { _ in })
        await store.refreshUsageOffers()
        store.model.usageOffers = { try await gate.read() }
        let read = Task { await store.refreshUsageOffers() }
        try await until { gate.calls == 1 }
        read.cancel()
        gate.answer(1, .failure(CancellationError()))
        await read.value
        #expect(store.usageOffers == [before])
        #expect(store.usageOffersFailure == nil && !store.loadingUsageOffers)
    }

    @Test("an offline adapter returns no offers without inspecting provider metadata")
    func offlineAdapterHasNoOffers() async throws {
        #expect(try await SetupModel.usageOffers(on: nil).isEmpty)
        let core = CoreModel(socketPath: NSTemporaryDirectory() + "jrbar-offline-setup-\(UUID().uuidString).sock")
        #expect(!core.isLive)
        #expect(try await SetupModel.usageOffers(on: core).isEmpty)
    }

    @Test("overlapping health and UI reads persist only the current grant baseline")
    func healthPersistsOnlyCurrentBaseline() async throws {
        let gate = ReadGate<[SetupPermission: SetupPermissionStatus]>()
        defer { gate.finish() }
        var saved: [SetupState] = []
        var model = SetupModel()
        model.refreshPermissions = { (try? await gate.read()) ?? [:] }
        let store = SetupStore(model: model, load: { SetupState() }, persist: { saved.append($0) })
        let health = Task { await store.reviewPermissionHealth() }
        try await until { gate.calls == 1 }
        let ui = Task { await store.refreshPermissions() }
        try await until { gate.calls == 2 }
        gate.answer(1, .success([.camera: .denied]))
        await Task.yield()
        gate.answer(2, .success([.camera: .granted]))
        #expect(await health.value == [])
        await ui.value
        #expect(saved.count == 1)
        #expect(saved.first?.grantedPermissions == ["camera"])
        #expect(store.status(of: .camera) == .granted)
    }

    @Test(.enabled(if: WindowsRenderProofTests.enabled))
    func readStatesRenderProof() async throws {
        let expected = offer("Asks the provider for subscription usage only after you turn it on.")
        var model = SetupModel()
        model.monitorLive = { true }
        model.agents = { [SetupAgent(id: "claude", name: "Claude", detected: true, hookStatus: "ok")] }
        model.usageOffers = { throw CoreClientError.notConnected }
        let store = SetupStore(model: model, load: { SetupState() }, persist: { _ in })
        await store.refreshUsageOffers()
        try render("setup-usage-failed-empty", store: store)
        store.model.usageOffers = { [expected] }
        await store.refreshUsageOffers()
        store.declineUsage(for: "claude")
        store.model.usageOffers = { throw CoreClientError.notConnected }
        await store.refreshUsageOffers()
        try render("setup-usage-failed-retained", store: store)
        let gate = ReadGate<[SetupUsageOffer]>()
        defer { gate.finish() }
        store.model.usageOffers = { try await gate.read() }
        let read = Task { await store.refreshUsageOffers() }
        try await until { gate.calls == 1 }
        let proof = Result<Void, Error> { try render("setup-usage-reading-retained", store: store) }
        gate.answer(1, .success([expected]))
        await read.value
        try proof.get()
    }

    private func render(_ name: String, store: SetupStore) throws {
        try WindowsRenderProofTests.write(name, size: CGSize(width: 560, height: 390)) {
            VStack(alignment: .leading, spacing: 14) {
                Text("Connect your agents").font(.title2.weight(.semibold)).padding(.horizontal, 24)
                SetupAgentsStep(store: store)
            }.padding(.vertical, 24)
        }
    }
}
