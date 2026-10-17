import AppKit
import SwiftUI
import Testing
@testable import JRBarCore
@testable import JRBarApp

@Suite("Deck control render proof")
@MainActor
struct DeckControlRenderProofTests {
    @Test(.enabled(if: WindowsRenderProofTests.enabled))
    func pendingReviewAndCalibrationRefusal() async throws {
        let store = DeckControlStateTests.store()
        store.sheet = .apply
        store.applyLayer = DeckControlStateTests.layer
        store.applyScopes[DeckControlStateTests.layer.id] = "codex"
        store.planLoading = true
        let calibration = CalibrationSubmission()
        _ = await calibration.apply {
            CoreReply(id: "synthetic", ok: false,
                      error: CoreReplyError(code: "not_found", message: "The device disconnected. Reconnect it and try Apply again."))
        }
        let settings = SettingsStore(core: store.core)
        try WindowsRenderProofTests.write("deck-calibration-recovery", size: CGSize(width: 1140, height: 620)) {
            HStack(alignment: .top, spacing: 16) {
                ApplyKeymapSheet(store: store)
                CalibrationSheet(store: settings, deviceID: "virtual:status-bar", dismiss: {}, submission: calibration)
            }
        }
    }
}
