import JRBarTestSupport
import Foundation
import SwiftUI
import Testing
@testable import JRBarApp
@testable import JRBarCore

@MainActor
@Suite("Panel presentation", .serialized, .renderProofAppearance)
struct PanelPresentationTests {
    @Test("closed panel Quiet countdown uses the current time")
    func closedQuietCountdown() {
        let reference = Date()
        let state = CoreState(focus: CoreFocus(mode: "pause", source: "override",
                                               until: reference.addingTimeInterval(1800).timeIntervalSince1970))
        withPanel(state) { store in
            store.isOpen = false
            store.now = reference.addingTimeInterval(-7200)
            #expect(store.quietLabel == "Paused 30m")
            #expect(store.quietIsOurs)
        }
    }

    @Test("open panel Quiet countdown follows its manually advanced clock")
    func openQuietCountdown() {
        let reference = Date()
        let state = CoreState(focus: CoreFocus(mode: "dim", source: "schedule",
                                               until: reference.addingTimeInterval(1800).timeIntervalSince1970))
        withPanel(state) { store in
            store.isOpen = true
            store.now = reference.addingTimeInterval(300)
            #expect(store.quietLabel == "Dimmed 25m")
            #expect(!store.quietIsOurs)
        }
    }

    @Test("an elapsed countdown keeps the daemon's Quiet state")
    func elapsedQuietCountdown() {
        let reference = Date()
        let state = CoreState(focus: CoreFocus(mode: "pause", source: "override",
                                               until: reference.addingTimeInterval(-60).timeIntervalSince1970))
        withPanel(state) { store in
            store.isOpen = false
            store.now = reference.addingTimeInterval(-7200)
            #expect(store.quietLabel == "Paused")
            #expect(store.quiet?.mode == "pause")
            #expect(store.core.state?.focus == state.focus)
        }
    }

    @Test(.enabled(if: WindowsRenderProofTests.enabled))
    func guidanceAndToastRenderProof() throws {
        try withPanel(CoreState()) { store in
            try render("panel-empty-guidance", store)
        }
        let missing = CoreState(health: .object([
            "detected": .object(["claude": .bool(true)]),
            "hooks": .object(["claude": .string("missing"), "codex": .string("missing"),
                              "gemini": .string("missing")])
        ]))
        try withPanel(missing) { store in
            #expect(store.missingHooks == ["claude", "codex", "gemini"])
            try render("panel-missing-hooks-guidance", store)
        }
        let busy = CoreState(devices: WindowsRenderProofTests.devices)
        try withPanel(busy) { store in
            store.toast = "Quiet failed: Synthetic refused"
            try render("panel-toast-short", store)
            store.toast = "Quiet failed: the monitor is not answering. Try again after it reconnects."
            try render("panel-toast-long", store)
            store.toastAction = ("Open Settings", {})
            try render("panel-toast-action", store)
        }
    }

    private func render(_ name: String, _ store: PanelStore) throws {
        try WindowsRenderProofTests.write(name, size: WindowsRenderProofTests.panelSize(store), plate: .glass) {
            WindowsRenderProofTests.panel(store)
        }
    }

    private func withPanel(_ state: CoreState, _ body: (PanelStore) throws -> Void) rethrows {
        let suite = ScratchDefaults.suiteName("panel-presentation")
        defer { ScratchDefaults.remove(suite) }
        let core = WindowsRenderProofTests.liveCore(state)
        let store = PanelStore(core: core, draftsDefaults: ScratchDefaults.open(suite), screenBarShown: false)
        store.animationsArmed = false
        store.screenHeight = 1200
        try body(store)
    }
}
