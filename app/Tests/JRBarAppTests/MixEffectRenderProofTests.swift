import JRBarTestSupport
import AppKit
import JRBarUI
import SwiftUI
import Testing
@testable import JRBarApp
@testable import JRBarCore

@MainActor
@Suite("Mix effect render proofs", .serialized, .renderProofAppearance)
struct MixEffectRenderProofTests {
    @Test(.enabled(if: ProcessInfo.processInfo.environment["JRBAR_RENDER_PROOF"] == "1"))
    func mixAndAssignmentAsKeyWindows() async throws {
        let application = NSApplication.shared
        let previousPolicy = application.activationPolicy()
        _ = application.setActivationPolicy(.regular)
        defer { _ = application.setActivationPolicy(previousPolicy) }
        let programs = StudioWorkspaceRenderProofTests.Programs.synthetic()
        let fixture = try CoreCommandReplyFixture()
        let suite = ScratchDefaults.suiteName("mix-effect-render")
        defer { ScratchDefaults.remove(suite) }
        let store = EffectStudioStore(core: fixture.core, defaults: ScratchDefaults.open(suite))
        store.covered = true
        store.scenePackLoader = { [] }
        store.renderDelay = { throw CancellationError() }
        store.lightsStudio.requestPlan = { programs.plan }
        store.lightsStudio.requestPreview = { scenario, mode in try #require(programs.previews["\(scenario)|\(mode)"]) }
        do {
            try await fixture.start()
            fixture.core.apply(.settings(CoreSettings(generation: 1, document: programs.settings)))
            store.lightsStudio.settings.syncMirrors()
            let load = try #require(store.reload())
            try await fixture.pending(2)
            for name in ["list_effects", "list_assignments"] {
                let pending = try await fixture.core.send("fixture_pending")
                let requests = try #require(pending.result?["requests"]?.arrayValue)
                let index = try #require(requests.firstIndex { $0["name"]?.stringValue == name })
                let data = name == "list_effects" ? try JSONEncoder().encode(programs.catalog) : try JSONEncoder().encode(EffectAssignmentDocument())
                let object = try #require(JSONDecoder().decode(JSONValue.self, from: data).objectValue)
                try await fixture.release(index: index, result: object)
            }
            await load.value
            await store.lightsStudio.refreshPlan()
            await store.lightsStudio.refreshPreviews()
            store.mode = .mix
            let marquee = try #require(store.catalog?.effect("marquee"))
            for dark in [false, true] {
                try await DesignFixBProof.write(EffectStudioView(store: store), name: "studio-mix-effect", title: "Studio",
                    size: CGSize(width: 1160, height: 1000), dark: dark)
                store.beginAssigningMix(marquee)
                try await DesignFixBProof.write(AssignSheet(store: store), name: "studio-assign-mix", title: "Assign",
                    size: CGSize(width: 460, height: 360), dark: dark)
                store.assigning = false
            }
            store.windowDidClose()
            await fixture.stop()
        } catch { store.windowDidClose(); await fixture.stop(); throw error }
    }
}
