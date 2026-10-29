import JRBarTestSupport
import Foundation
import SwiftUI
import Testing
@testable import JRBarApp
@testable import JRBarCore

@MainActor
@Suite("Hooks doctor render proof", .renderProofAppearance)
struct HooksDoctorRenderProofTests {
    enum State: String, CaseIterable { case unavailable, recovered, failed, offline }

    @Test(.enabled(if: WindowsRenderProofTests.enabled), arguments: State.allCases)
    func recheckStates(_ state: State) async throws {
        let doctor = HooksDoctorModel()
        let result: JSONValue = .object([
            "checked_at": .number(Date().timeIntervalSince1970 - 30),
            "ingress_socket": .object(["answers": .bool(state != .unavailable)]),
            "providers": .array([.object([
                "provider": .string("claude"), "installed": .bool(true), "hook_events": .number(12),
                "last_event_at": .number(Date().timeIntervalSince1970 - 60), "pending_lines": .number(3),
            ])]),
        ])
        await doctor.refresh { CoreReply(id: "report", ok: true, result: result) }?.value
        if state == .failed {
            await doctor.recheck(live: true) { _, _ in throw CoreClientError.notConnected }?.value
        }
        let live = state != .offline
        let entry = try #require(doctor.entry(for: "claude", live: live))
        let core = CoreModel(socketPath: NSTemporaryDirectory() + "jrbar-hook-proof.sock")
        var snapshot = CoreState()
        snapshot.health = .object(["hooks": .object(["claude": .string("ok")])])
        core.handle(.connected)
        core.apply(.state(snapshot))
        if !live { core.handle(.stateRejected("missing generation")) }
        let store = SettingsStore(core: core)
        try WindowsRenderProofTests.write("hooks-recheck-\(state.rawValue)", size: CGSize(width: 640, height: 240)) {
            VStack(alignment: .leading, spacing: 14) {
                Text("Providers").font(.system(size: 20, weight: .semibold))
                AgentRow(store: store, provider: "claude", doctor: entry)
                Divider()
                HooksDoctorStatusRow(doctor: doctor, live: store.isLive) {}
            }
            .padding(20)
        }
    }
}
