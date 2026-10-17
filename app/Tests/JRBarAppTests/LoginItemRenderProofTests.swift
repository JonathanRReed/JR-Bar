import JRBarCore
import SwiftUI
import Testing
@testable import JRBarApp

@Suite("Login item render proof", .serialized)
@MainActor
struct LoginItemRenderProofTests {
    @Test(.enabled(if: WindowsRenderProofTests.enabled))
    func approvedPendingMissingAndFailed() throws {
        let states: [LoginItemState] = [.enabled, .requiresApproval, .notRegistered, .notFound]
        let stores = states.map { state in
            let store = SettingsStore(core: CoreModel())
            store.loginItemState = state
            store.launchAtLogin = state.isEnabled
            store.loginItemStateReader = { state }
            store.loginItemChange = { _ in Issue.record("render proof must not change login items") }
            return store
        }
        let pending = SettingsStore(core: CoreModel())
        pending.launchAtLoginBusy = true
        let failed = SettingsStore(core: CoreModel())
        failed.loginItemState = .notRegistered
        failed.launchAtLoginError = "Registration refused. Try again after opening the installed app."
        try WindowsRenderProofTests.write("login-item-states", size: CGSize(width: 590, height: 650)) {
            Form {
                ForEach(stores.indices, id: \.self) { index in
                    SettingGroup("Startup") { LoginItemRow(store: stores[index]) }
                }
                SettingGroup("Reading") { LoginItemRow(store: pending) }
                SettingGroup("Failure") { LoginItemRow(store: failed) }
            }
            .formStyle(.grouped)
        }
    }
}
