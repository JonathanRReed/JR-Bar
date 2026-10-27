import JRBarUI
import Foundation
import SwiftUI
import Testing
@testable import JRBarApp
@testable import JRBarCore

@MainActor
@Suite("Setup request order")
struct SetupRequestOrderTests {
    @MainActor
    final class Gate<Value: Sendable> {
        var pending: [CheckedContinuation<Value, Never>] = []
        var watchers: [(Int, CheckedContinuation<Void, Never>)] = []
        func request() async -> Value {
            await withCheckedContinuation { continuation in
                pending.append(continuation)
                let ready = watchers.filter { pending.count >= $0.0 }
                watchers.removeAll { pending.count >= $0.0 }
                ready.forEach { $0.1.resume() }
            }
        }
        func untilRequests(_ count: Int) async {
            if pending.count >= count { return }
            await withCheckedContinuation { watchers.append((count, $0)) }
        }
        func answer(_ call: Int, _ value: Value) { pending[call - 1].resume(returning: value) }
    }

    @Test(.timeLimit(.minutes(2)))
    func anOlderPermissionReadCannotReplaceANewerGrant() async {
        let gate = Gate<[SetupPermission: SetupPermissionStatus]>()
        var model = SetupModel()
        model.refreshPermissions = { await gate.request() }
        let store = SetupStore(model: model, load: { SetupState() }, persist: { _ in })
        let old = Task { await store.refreshPermissions() }
        await gate.untilRequests(1)
        let new = Task { await store.refreshPermissions() }
        await gate.untilRequests(2)
        gate.answer(2, [.camera: .granted])
        await new.value
        gate.answer(1, [.camera: .denied])
        await old.value
        #expect(store.status(of: .camera) == .granted)
    }

    @Test(.timeLimit(.minutes(2)))
    func aPermissionActionRunsOnceAndCanRetryAfterItFinishes() async {
        let gate = Gate<Void>()
        var calls = 0
        var model = SetupModel()
        model.act = { _ in calls += 1; await gate.request() }
        model.refreshPermissions = { [.camera: .needed] }
        let store = SetupStore(model: model, load: { SetupState() }, persist: { _ in })
        await store.refreshPermissions()
        let first = store.act(on: .camera)
        #expect(store.permissionBusy == [.camera])
        let duplicate = store.act(on: .camera)
        await duplicate.value
        await gate.untilRequests(1)
        #expect(calls == 1)
        gate.answer(1, ())
        await first.value
        #expect(store.permissionBusy.isEmpty)
        let retry = store.act(on: .camera)
        await gate.untilRequests(2)
        gate.answer(2, ())
        await retry.value
        #expect(calls == 2)
    }

    @Test func aGrantedPermissionCannotRequestAgain() async {
        var calls = 0
        var model = SetupModel()
        model.act = { _ in calls += 1 }
        model.refreshPermissions = { [.camera: .granted] }
        let store = SetupStore(model: model, load: { SetupState() }, persist: { _ in })
        await store.refreshPermissions()
        await store.act(on: .camera).value
        #expect(calls == 0)
    }

    @Test func anOfflineMonitorDoesNotClaimTheHooksAreLive() {
        var model = SetupModel()
        model.agents = { [SetupAgent(id: "claude", name: "Claude", detected: true, hookStatus: "ok")] }
        let store = SetupStore(model: model, load: { SetupState() }, persist: { _ in })
        #expect(store.agentRows[0].statusWord(monitorLive: false) == "Monitor not connected")
        #expect(store.summaryRows.first { $0.text == "Agents" }?.ok == false)
    }

    @Test func aRejectedStateKeepsHookFactsButMakesTheActualProviderRowOffline() {
        let core = CoreModel(socketPath: NSTemporaryDirectory() + "jrbar-hook-status.sock")
        var state = CoreState()
        state.health = .object(["hooks": .object(["claude": .string("ok")])])
        core.handle(.connected)
        core.apply(.state(state))
        let store = SettingsStore(core: core)
        let row = AgentRow(store: store, provider: "claude")
        #expect(row.statusWord == "Live")
        #expect(row.statusColor == JRBarUI.Tone.live.color)

        core.handle(.stateRejected("missing generation"))

        #expect(core.connection.isConnected)
        #expect(store.hookStatus("claude") == "ok")
        #expect(!store.isLive)
        #expect(row.statusWord == "Monitor not connected")
        #expect(row.statusColor == JRBarUI.Tone.neutral.color)
        #expect(row.statusColor != JRBarUI.Tone.live.color)
    }

    @Test(.timeLimit(.minutes(2)))
    func aUsageReadStartedBeforeTurningOffCannotTurnTheRowBackOn() async {
        let gate = Gate<[SetupUsageOffer]>()
        var model = SetupModel()
        model.monitorLive = { true }
        model.usageOffers = { await gate.request() }
        model.setUsage = { _, _ in SetupNote("Usage off", isError: false) }
        let store = SetupStore(model: model, load: { SetupState() }, persist: { _ in })
        let offer = SetupUsageOffer(id: "claude", name: "Claude", question: "Show usage?", summary: "Only usage.", isOn: true)
        let seed = Task { await store.refreshUsageOffers() }
        await gate.untilRequests(1)
        gate.answer(1, [offer])
        await seed.value
        let stale = Task { await store.refreshUsageOffers() }
        await gate.untilRequests(2)
        await store.turnOffUsage(for: "claude")?.value
        gate.answer(2, [offer])
        await stale.value
        #expect(store.usageOffer(for: "claude")?.isOn == false)
    }

    @Test func offlineUsageActionsDoNotWrite() {
        var model = SetupModel()
        model.monitorLive = { false }
        let store = SetupStore(model: model, load: { SetupState() }, persist: { _ in })
        #expect(store.turnOnUsage(for: "claude") == nil)
        #expect(store.turnOffUsage(for: "claude") == nil)
    }

    @Test(.timeLimit(.minutes(2)))
    func aDoctorRefreshRequestedDuringAReadRunsAfterward() async throws {
        let gate = Gate<CoreReply>()
        let doctor = HooksDoctorModel()
        let first = try #require(doctor.refresh { await gate.request() })
        await gate.untilRequests(1)
        #expect(doctor.refresh { await gate.request() } == nil)
        #expect(doctor.refresh { await gate.request() } == nil)
        gate.answer(1, CoreReply(id: "doctor", ok: true, result: report(events: 2)))
        await gate.untilRequests(2)
        #expect(doctor.entries.isEmpty, "a superseded report is not published")
        gate.answer(2, CoreReply(id: "doctor", ok: true, result: report(events: 12)))
        await first.value
        #expect(doctor.entry(for: "claude")?.hookEvents == 12)
        #expect(!doctor.loading)
        #expect(!doctor.failed)
        #expect(gate.pending.count == 2, "extra refreshes share one follow-up")
    }

    @Test func aMalformedDoctorReplyPreservesItsLastGoodReport() async throws {
        let doctor = HooksDoctorModel()
        await doctor.refresh { CoreReply(id: "doctor", ok: true, result: report(events: 12)) }?.value
        await doctor.refresh { CoreReply(id: "doctor", ok: true, result: .object([:])) }?.value
        #expect(doctor.entry(for: "claude")?.hookEvents == 12)
        #expect(doctor.failed)
        #expect(doctor.entry(for: "claude")?.isStale == true)
        #expect(HooksDoctor.line(try #require(doctor.entry(for: "claude")))?.hasPrefix("Last report · ") == true)
        await doctor.refresh { CoreReply(id: "doctor", ok: true, result: report(events: 3)) }?.value
        #expect(doctor.entry(for: "claude")?.hookEvents == 3)
        #expect(!doctor.failed)
    }

    @Test func aSuccessfulRecheckClearsTheReceiverWarning() async throws {
        let doctor = HooksDoctorModel()
        await doctor.recheck(live: true) { _, _ in
            CoreReply(id: "first", ok: true, result: report(events: 12, checkedAt: 100, receiver: false))
        }?.value
        #expect(doctor.receiverLine(live: true) == "Hook receiver not answering")
        #expect(doctor.checkedAt == 100)

        await doctor.recheck(live: true) { _, _ in
            CoreReply(id: "second", ok: true, result: report(events: 12, checkedAt: 120, receiver: true))
        }?.value
        #expect(doctor.receiverAnswers == true)
        #expect(doctor.receiverLine(live: true) == "Hook receiver answering")
        #expect(doctor.checkedAt == 120)
        #expect(!doctor.failed)
    }

    @Test func aFailedRecheckKeepsTheReceiverAndTimeAsALastReport() async throws {
        let doctor = HooksDoctorModel()
        await doctor.refresh {
            CoreReply(id: "first", ok: true, result: report(events: 12, checkedAt: 100, receiver: true))
        }?.value
        await doctor.recheck(live: true) { _, _ in throw CoreClientError.notConnected }?.value
        #expect(doctor.checkedAt == 100)
        #expect(doctor.receiverAnswers == true)
        #expect(doctor.entry(for: "claude")?.hookEvents == 12)
        #expect(doctor.entry(for: "claude")?.isStale == true)
        #expect(doctor.statusLine(live: true) == "Recheck failed. Showing the last report.")
        #expect(doctor.receiverLine(live: true) == "Last report · Hook receiver answering")
        #expect(!doctor.loading)
    }

    @Test(.timeLimit(.minutes(2)))
    func recheckSendsOnlyTheDoctorCommandAndRefusesBusyOrOfflineReads() async throws {
        let doctor = HooksDoctorModel()
        let gate = Gate<CoreReply>()
        var commands: [String] = []
        var timeouts: [TimeInterval] = []
        let send: @MainActor (String, TimeInterval) async throws -> CoreReply = { name, timeout in
            commands.append(name)
            timeouts.append(timeout)
            return await gate.request()
        }
        #expect(doctor.recheck(live: false, send: send) == nil)
        #expect(commands.isEmpty)
        let read = try #require(doctor.recheck(live: true, send: send))
        await gate.untilRequests(1)
        #expect(doctor.loading)
        #expect(doctor.statusLine(live: true) == "Checking hooks…")
        #expect(doctor.recheck(live: true, send: send) == nil)
        gate.answer(1, CoreReply(id: "doctor", ok: true, result: report(events: 12, checkedAt: 100, receiver: false)))
        await read.value
        #expect(commands == ["hooks_doctor"])
        #expect(timeouts == [10])
        #expect(gate.pending.count == 1)
        #expect(!doctor.loading)
        #expect(doctor.entry(for: "claude", live: false)?.isStale == true)
        #expect(doctor.receiverLine(live: false) == "Last report · Hook receiver not answering")
        #expect(doctor.statusLine(live: false) == "The monitor is not connected. Recheck when it reconnects.")
    }

    @Test func anOlderMonitorDoesNotKeepThePreviousReceiverVerdict() async {
        let doctor = HooksDoctorModel()
        await doctor.refresh {
            CoreReply(id: "first", ok: true, result: report(events: 12, checkedAt: 100, receiver: false))
        }?.value
        await doctor.refresh { CoreReply(id: "second", ok: true, result: report(events: 3)) }?.value
        #expect(doctor.checkedAt == nil)
        #expect(doctor.receiverAnswers == nil)
        #expect(doctor.receiverLine(live: true) == "Hook receiver status unavailable")
    }

    @Test func aConfigReadErrorIsShownWithoutClaimingRepairOrAWorkingHook() throws {
        let value: JSONValue = .object([
            "provider": .string("claude"), "installed": .bool(false),
            "error": .string("PermissionError"), "version": .string("2.1.293"),
        ])
        let entry = try #require(HooksDoctorEntry(value))
        #expect(HooksDoctor.line(entry) == "Could not read hook settings: PermissionError")
        #expect(HooksDoctor.repairReason(entry) == nil)
        #expect(!HooksDoctor.lineShowsVersion(entry))
    }

    @Test(arguments: [Double.nan, Double.infinity, 121.0])
    func invalidEventTimesCannotClaimAnEventJustArrived(_ time: Double) {
        let entry = HooksDoctorEntry(provider: "claude", installed: true, hookEvents: 12,
                                     lastEventAt: time, pendingLines: 3)
        let line = HooksDoctor.line(entry, now: Date(timeIntervalSince1970: 120))
        #expect(line?.contains("event time unavailable") == true)
        #expect(line?.contains("3 queued") == true)
        #expect(line?.contains("last event just now") == false)
    }

    private func report(events: Int, checkedAt: Double? = nil, receiver: Bool? = nil) -> JSONValue {
        var result: [String: JSONValue] = ["providers": .array([.object([
            "provider": .string("claude"), "installed": .bool(true), "hook_events": .number(Double(events)),
        ])])]
        if let checkedAt { result["checked_at"] = .number(checkedAt) }
        if let receiver { result["ingress_socket"] = .object(["answers": .bool(receiver)]) }
        return .object(result)
    }
}
