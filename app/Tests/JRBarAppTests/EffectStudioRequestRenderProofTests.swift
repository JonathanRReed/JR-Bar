import Foundation
import SwiftUI
import Testing
@testable import JRBarApp
@testable import JRBarCore

@MainActor
@Suite("Effect Studio request render proof")
struct EffectStudioRequestRenderProofTests {
    private static func makeStore() -> EffectStudioStore {
        EffectStudioStore(core: CoreModel(socketPath: NSTemporaryDirectory() + "jrbar-effects-" + UUID().uuidString + ".sock"))
    }

    private static func pack() throws -> ScenePackSummary {
        try JSONDecoder().decode(ScenePackSummary.self, from: Data(#"{"id":"quiet","name":"Quiet desk","scenes":["calm","night"],"installed":true}"#.utf8))
    }

    @Test(.enabled(if: WindowsRenderProofTests.enabled))
    func aScenePackShowsTheCurrentPreview() async throws {
        let store = Self.makeStore()
        store.windowDidOpen()
        defer { store.windowDidClose() }
        let pack = try Self.pack()
        store.scenePackRenderer = { _, leds in EffectPreview(program: "#0A84FF", ledCount: leds) }
        await store.previewScenePack(pack).value
        try WindowsRenderProofTests.write("effect-studio-scene-preview", size: CGSize(width: 640, height: 150)) {
            VStack(alignment: .leading, spacing: 16) {
                Text("Scene packs").font(.title3.weight(.semibold))
                ScenePackRow(pack: pack, store: store)
            }.padding(24)
        }
    }

    @Test(.enabled(if: WindowsRenderProofTests.enabled))
    func aFailedRefreshKeepsTheInstalledScenePackVisible() async throws {
        let store = Self.makeStore()
        let pack = try Self.pack()
        store.scenePackLoader = { [pack] }
        await store.loadScenePacks()
        store.scenePackLoader = { throw CoreReplyError(code: "timeout", message: "The monitor did not answer. Refresh to try again.") }
        await store.loadScenePacks()
        let message = try #require(store.lastError)
        try WindowsRenderProofTests.write("effect-studio-scene-refresh-failed", size: CGSize(width: 640, height: 210)) {
            VStack(alignment: .leading, spacing: 16) {
                Text("Scene packs").font(.title3.weight(.semibold))
                ForEach(store.scenePacks) { ScenePackRow(pack: $0, store: store) }
                WindowStatusCapsule(text: message, isError: true)
            }.padding(24)
        }
    }
}
