import Foundation
import SwiftUI
import Testing
@testable import JRBarApp

@MainActor
@Suite("Setup reliability render proof")
struct SetupReliabilityRenderProofTests {
    @Test(.enabled(if: WindowsRenderProofTests.enabled), .timeLimit(.minutes(1)))
    func aPermissionRequestDisablesOnlyItsRow() async throws {
        var resume: CheckedContinuation<Void, Never>?
        var model = SetupModel()
        model.refreshPermissions = { [.camera: .needed, .calendar: .denied] }
        model.act = { _ in await withCheckedContinuation { resume = $0 } }
        let store = SetupStore(model: model, load: { SetupState() }, persist: { _ in })
        await store.refreshPermissions()
        let request = store.act(on: .camera)
        for _ in 0..<10_000 where resume == nil { await Task.yield() }
        let continuation = try #require(resume)
        let rendered = Result<Void, Error> {
            try WindowsRenderProofTests.write("setup-permission-waiting", size: CGSize(width: 680, height: 270)) {
                VStack(alignment: .leading, spacing: 16) {
                    Text("Permissions").font(.system(size: 24, weight: .semibold))
                    SetupPermissionRow(store: store, permission: .camera)
                    Divider()
                    SetupPermissionRow(store: store, permission: .calendar)
                }.padding(24)
            }
        }
        continuation.resume()
        await request.value
        try rendered.get()
    }

    @Test(.enabled(if: WindowsRenderProofTests.enabled))
    func offlineSetupKeepsItsLastHooksWithoutClaimingTheyAreLive() throws {
        var model = SetupModel()
        model.agents = { [SetupAgent(id: "claude", name: "Claude", detected: true, hookStatus: "ok")] }
        let store = SetupStore(model: model, load: { SetupState() }, persist: { _ in })
        try WindowsRenderProofTests.write("setup-monitor-offline", size: CGSize(width: 680, height: 390)) {
            VStack(alignment: .leading, spacing: 16) {
                Text("Setup").font(.system(size: 24, weight: .semibold))
                SetupAgentRow(store: store, agent: store.agentRows[0])
                SetupDoneStep(store: store)
            }.padding(24)
        }
    }

    @Test(.enabled(if: WindowsRenderProofTests.enabled))
    func failedFinishShowsSaveFailureAndRetryButtons() throws {
        let store = SetupStore(model: SetupModel(), load: { SetupState() }, persist: { _ in
            throw CocoaError(.fileWriteNoPermission)
        })
        store.goNext()
        store.skip()
        store.skip()
        store.goNext()
        #expect(store.step == .done)
        #expect(!store.finish())
        #expect(store.persistenceFailure != nil)
        try WindowsRenderProofTests.write("setup-finish-save-failure", size: SetupWindowController.contentSize) {
            SetupView(store: store)
        }
    }
}
