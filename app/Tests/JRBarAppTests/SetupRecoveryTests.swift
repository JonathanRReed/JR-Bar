import AppKit
import Foundation
import Observation
import SwiftUI
import Testing
@testable import JRBarApp

@MainActor
@Suite("Setup recovery", .serialized, .timeLimit(.minutes(2)))
struct SetupRecoveryTests {
    @MainActor
    private final class PermissionGate {
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
            let held = pending.values
            pending.removeAll()
            for continuation in held { continuation.resume(returning: [:]) }
        }
    }

    private func until(_ predicate: () -> Bool) async throws {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(5))
        while !predicate(), clock.now < deadline, !Task.isCancelled { await Task.yield() }
        try #require(predicate(), "Synthetic Setup operation did not reach its expected state")
    }

    @Test("a UI probe cannot suppress a launch review of a lost grant")
    func uiRefreshDoesNotSuppressLoss() async throws {
        let gate = PermissionGate()
        defer { gate.finish() }
        var saved: [SetupState] = []
        var model = SetupModel()
        model.refreshPermissions = { await gate.read() }
        let store = SetupStore(model: model, load: { SetupState(grantedPermissions: ["camera"]) },
                               persist: { saved.append($0) })
        let health = Task { await store.reviewPermissionHealth() }
        try await gate.waitForCall(1)
        let ui = Task { await store.refreshPermissions() }
        try await gate.waitForCall(2)
        gate.answer(2, [.camera: .denied])
        await ui.value
        gate.answer(1, [.camera: .denied])
        let lost = await health.value
        #expect(lost == [.camera])
        #expect(saved.last?.grantedPermissions == [])
        #expect(store.status(of: .camera) == .denied)
    }

    @Test("a superseded first health review still records the latest grant baseline")
    func firstReviewSurvivesUIRefresh() async throws {
        let gate = PermissionGate()
        defer { gate.finish() }
        var model = SetupModel()
        model.refreshPermissions = { await gate.read() }
        let store = SetupStore(model: model, load: { SetupState() }, persist: { _ in })
        let health = Task { await store.reviewPermissionHealth() }
        try await gate.waitForCall(1)
        let ui = Task { await store.refreshPermissions() }
        try await gate.waitForCall(2)
        gate.answer(2, [.camera: .granted])
        await ui.value
        gate.answer(1, [.camera: .denied])
        #expect(await health.value == [])
        #expect(store.state.grantedPermissions == ["camera"])
        store.model.refreshPermissions = { [.camera: .denied] }
        #expect(await store.reviewPermissionHealth() == [.camera])
    }

    @Test("an older denied health probe cannot erase a newer UI grant")
    func healthUsesLatestAcceptedSnapshot() async throws {
        let gate = PermissionGate()
        defer { gate.finish() }
        var model = SetupModel()
        model.refreshPermissions = { await gate.read() }
        let store = SetupStore(model: model, load: { SetupState(grantedPermissions: ["camera"]) }, persist: { _ in })
        let health = Task { await store.reviewPermissionHealth() }
        try await gate.waitForCall(1)
        let ui = Task { await store.refreshPermissions() }
        try await gate.waitForCall(2)
        gate.answer(2, [.camera: .granted])
        await ui.value
        gate.answer(1, [.camera: .denied])
        #expect(await health.value == [])
        #expect(store.state.grantedPermissions == ["camera"])
        #expect(store.status(of: .camera) == .granted)
    }

    @Test("only the newest overlapping health review records grants")
    func newerHealthReviewOwnsBookkeeping() async throws {
        let gate = PermissionGate()
        defer { gate.finish() }
        var saved: [SetupState] = []
        var model = SetupModel()
        model.refreshPermissions = { await gate.read() }
        let store = SetupStore(model: model, load: { SetupState() }, persist: { saved.append($0) })
        let older = Task { await store.reviewPermissionHealth() }
        try await gate.waitForCall(1)
        let newer = Task { await store.reviewPermissionHealth() }
        try await gate.waitForCall(2)
        gate.answer(2, [.camera: .granted])
        #expect(await newer.value == [])
        gate.answer(1, [.camera: .denied])
        #expect(await older.value == [])
        #expect(store.state.grantedPermissions == ["camera"])
        #expect(store.status(of: .camera) == .granted)
        #expect(saved.count == 1)
    }

    @Test("an unreadable newest UI probe does not revoke a remembered grant")
    func unreadableLatestProbeKeepsBaseline() async throws {
        let gate = PermissionGate()
        defer { gate.finish() }
        var model = SetupModel()
        model.refreshPermissions = { await gate.read() }
        let store = SetupStore(model: model, load: { SetupState(grantedPermissions: ["camera"]) }, persist: { _ in })
        let health = Task { await store.reviewPermissionHealth() }
        try await gate.waitForCall(1)
        let ui = Task { await store.refreshPermissions() }
        try await gate.waitForCall(2)
        gate.answer(2, [.camera: .unknown])
        await ui.value
        gate.answer(1, [.camera: .denied])
        #expect(await health.value == [])
        #expect(store.state.grantedPermissions == ["camera"])
        #expect(store.status(of: .camera) == .unknown)
    }

    @Test("a health review uses the newest of several overlapping UI probes")
    func severalUIReadsKeepNewestSnapshot() async throws {
        let gate = PermissionGate()
        defer { gate.finish() }
        var model = SetupModel()
        model.refreshPermissions = { await gate.read() }
        let store = SetupStore(model: model, load: { SetupState() }, persist: { _ in })
        let health = Task { await store.reviewPermissionHealth() }
        try await gate.waitForCall(1)
        let older = Task { await store.refreshPermissions() }
        try await gate.waitForCall(2)
        let newer = Task { await store.refreshPermissions() }
        try await gate.waitForCall(3)
        gate.answer(3, [.camera: .granted])
        await newer.value
        gate.answer(2, [.camera: .denied])
        await older.value
        gate.answer(1, [.camera: .denied])
        #expect(await health.value == [])
        #expect(store.state.grantedPermissions == ["camera"])
        #expect(store.status(of: .camera) == .granted)
    }

    @Test("UI probes leave launch-health bookkeeping to the health review")
    func UIRefreshDoesNotRecordGrants() async {
        var saved: [SetupState] = []
        var model = SetupModel()
        model.refreshPermissions = { [.camera: .granted] }
        let store = SetupStore(model: model, load: { SetupState() }, persist: { saved.append($0) })
        await store.refreshPermissions()
        #expect(store.status(of: .camera) == .granted)
        #expect(store.state.grantedPermissions == nil)
        #expect(saved.isEmpty)
    }

    @Observable
    final class Connection { var live = false }

    @Test("the visible Agents step loads usage offers when its monitor reconnects")
    func agentsStepReconnects() async throws {
        _ = NSApplication.shared
        let connection = Connection()
        var reads = 0
        var writes = 0
        var liveChecks = 0
        var model = SetupModel()
        model.monitorLive = { liveChecks += 1; return connection.live }
        model.agents = { [SetupAgent(id: "claude", name: "Claude", detected: true, hookStatus: "ok")] }
        model.usageOffers = {
            reads += 1
            return connection.live ? [SetupUsageOffer(id: "claude", name: "Claude", question: "Show Claude usage?",
                summary: "Synthetic usage offer.", isOn: false)] : []
        }
        model.setUsage = { _, _ in writes += 1; return SetupNote("Synthetic write", isError: false) }
        let store = SetupStore(model: model, load: { SetupState() }, persist: { _ in })
        store.jump(to: .agents)
        await store.refreshUsageOffers()
        let host = NSHostingView(rootView: SetupAgentsStep(store: store))
        host.frame = NSRect(x: 0, y: 0, width: 560, height: 390)
        host.layoutSubtreeIfNeeded()
        let initialChecks = liveChecks
        try #require(initialChecks > 0)
        connection.live = true
        host.rootView = SetupAgentsStep(store: store)
        host.layoutSubtreeIfNeeded()
        try await until { liveChecks > initialChecks }
        try await until { store.usageOffers.count == 1 }
        #expect(store.usageOffers.first?.id == "claude")
        #expect(store.usageOffers.first?.isOn == false)
        #expect(reads == 2 && writes == 0)
        withExtendedLifetime(host) {}
    }

    @Test(.enabled(if: WindowsRenderProofTests.enabled))
    func reconnectStatesRenderProof() async throws {
        let connection = Connection()
        var model = SetupModel()
        model.monitorLive = { connection.live }
        model.agents = { [SetupAgent(id: "claude", name: "Claude", detected: true, hookStatus: "ok")] }
        model.usageOffers = {
            connection.live ? [SetupUsageOffer(id: "claude", name: "Claude", question: "Show Claude usage?",
                summary: "Asks the provider for subscription usage only after you turn it on.", isOn: false)] : []
        }
        let store = SetupStore(model: model, load: { SetupState() }, persist: { _ in })
        for live in [false, true] {
            connection.live = live
            await store.refreshUsageOffers()
            try WindowsRenderProofTests.write(live ? "setup-reconnected-usage" : "setup-waiting-monitor",
                                               size: CGSize(width: 560, height: 390)) {
                VStack(alignment: .leading, spacing: 14) {
                    Text("Connect your agents").font(.title2.weight(.semibold)).padding(.horizontal, 24)
                    SetupAgentsStep(store: store)
                }.padding(.vertical, 24)
            }
        }
    }
}
