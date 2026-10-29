import JRBarTestSupport
import AppKit
import Foundation
import SwiftUI
import Testing
@testable import JRBarApp
@testable import JRBarCore

@MainActor
@Suite("Window recovery render proof", .renderProofAppearance)
struct WindowRecoveryRenderProofTests {
    @Test(.enabled(if: WindowsRenderProofTests.enabled))
    func disconnectedUsage() throws {
        let time = Date().timeIntervalSince1970 - 60
        let core = UsageCenterOfflineTests.core(readAt: time)
        let store = UsageCenterStore(core: core)
        core.handle(.disconnected(reason: "Monitor restarted"))
        try WindowsRenderProofTests.write("usage-center-last-reading", size: CGSize(width: 760, height: 640)) {
            UsageCenterView(store: store)
        }
    }

    @Test(.enabled(if: WindowsRenderProofTests.enabled))
    func effectsLoadFailure() async throws {
        let core = CoreModel(socketPath: NSTemporaryDirectory() + "jrbar-effect-load-proof.sock")
        core.handle(.connected)
        core.apply(.state(CoreState()))
        let store = EffectStudioStore(core: core)
        let load = try #require(store.reload())
        await load.value
        #expect(store.loadError != nil)
        try WindowsRenderProofTests.write("effect-studio-load-failure", size: CGSize(width: 900, height: 540)) {
            EffectStudioView(store: store).effectsRoom
        }
    }
}
