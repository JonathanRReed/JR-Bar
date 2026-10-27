import Foundation
import Testing
@testable import JRBarApp
@testable import JRBarCore

@MainActor
@Suite("Studio request order")
struct EffectStudioRequestOrderTests {
    private static func makeStore() -> EffectStudioStore {
        EffectStudioStore(core: CoreModel(socketPath: NSTemporaryDirectory() + "jrbar-effects-" + UUID().uuidString + ".sock"))
    }

    private static func settle(_ condition: () -> Bool) async -> Bool {
        for _ in 0..<10_000 {
            if condition() { return true }
            await Task.yield()
        }
        return condition()
    }

    @Test func cancelledRendersCannotCacheOrClearANewerRender() async throws {
        let store = Self.makeStore()
        store.renderDelay = {}
        var pending: [Int: CheckedContinuation<EffectPreview, Never>] = [:]
        store.renderer = { _, values, _, _ in
            let width = Int(values["head_width"]?.doubleValue ?? 0)
            return await withCheckedContinuation { pending[width] = $0 }
        }
        let effect = EffectStudioRenderTests.comet()
        store.setValue(2, for: effect.parameters[0], of: effect)
        let first = try #require(store.renderTask)
        let firstStarted = await Self.settle { pending[2] != nil }
        #expect(firstStarted)
        store.setValue(3, for: effect.parameters[0], of: effect)
        let second = try #require(store.renderTask)
        let secondStarted = await Self.settle { pending[3] != nil }
        #expect(secondStarted)
        pending[2]?.resume(returning: EffectPreview(program: "obsolete"))
        await first.value
        #expect(store.renders.isEmpty)
        #expect(store.rendering, "an old completion cannot hide the pending render")
        pending[3]?.resume(returning: EffectPreview(program: "current"))
        await second.value
        #expect(store.previewProgram(for: effect) == "current")
        #expect(!store.rendering)
    }

    @Test func resettingParametersCancelsTheirPendingRender() async throws {
        let store = Self.makeStore()
        store.renderDelay = {}
        var finish: CheckedContinuation<EffectPreview, Never>?
        store.renderer = { _, _, _, _ in await withCheckedContinuation { finish = $0 } }
        let effect = EffectStudioRenderTests.comet()
        store.setValue(3, for: effect.parameters[0], of: effect)
        let request = try #require(store.renderTask)
        let started = await Self.settle { finish != nil }
        #expect(started)
        store.resetParameters(effect)
        finish?.resume(returning: EffectPreview(program: "obsolete"))
        await request.value
        #expect(store.renders.isEmpty)
        #expect(store.previewProgram(for: effect) == effect.preview?.program)
        #expect(!store.rendering)
    }

    @Test func changingDeviceShapeDoesNotReuseAnEightLEDRendition() async throws {
        let store = Self.makeStore()
        store.renderDelay = {}
        store.renderer = { _, _, leds, _ in EffectPreview(program: "leds \(leds)", ledCount: leds) }
        let effect = EffectStudioRenderTests.comet()
        store.setValue(3, for: effect.parameters[0], of: effect)
        let eight = try #require(store.renderTask)
        await eight.value
        #expect(store.previewProgram(for: effect) == "leds 8")
        store.core.apply(.state(CoreState(devices: [CoreDevice(id: "fake-dot", kind: "dot", leds: 2, connected: true)])))
        #expect(store.previewProgram(for: effect) == effect.preview?.program)
        store.setValue(3, for: effect.parameters[0], of: effect)
        let two = try #require(store.renderTask)
        await two.value
        #expect(store.previewProgram(for: effect) == "leds 2")
    }

    private static func pack(_ id: String) throws -> ScenePackSummary {
        try JSONDecoder().decode(ScenePackSummary.self, from: Data("{\"id\":\"\(id)\",\"scenes\":[\"calm\"],\"installed\":true}".utf8))
    }

    @Test func theLatestScenePackPreviewWins() async throws {
        let store = Self.makeStore()
        store.windowDidOpen()
        defer { store.windowDidClose() }
        var finish: CheckedContinuation<EffectPreview, Never>?
        store.scenePackRenderer = { id, _ in
            if id == "first" { return await withCheckedContinuation { finish = $0 } }
            return EffectPreview(program: "new")
        }
        let first = store.previewScenePack(try Self.pack("first"))
        let started = await Self.settle { finish != nil }
        #expect(started)
        let second = store.previewScenePack(try Self.pack("second"))
        await second.value
        finish?.resume(returning: EffectPreview(program: "old"))
        await first.value
        #expect(store.scenePreview?.packID == "second")
        #expect(store.scenePreview?.preview.program == "new")
    }

    @Test func reopeningDoesNotRestoreThePreviousScenePreview() async throws {
        let store = Self.makeStore()
        store.windowDidOpen()
        defer { store.windowDidClose() }
        var finish: CheckedContinuation<EffectPreview, Never>?
        store.scenePackRenderer = { _, _ in await withCheckedContinuation { finish = $0 } }
        let request = store.previewScenePack(try Self.pack("first"))
        let started = await Self.settle { finish != nil }
        #expect(started)
        store.windowDidClose()
        store.windowDidOpen()
        finish?.resume(returning: EffectPreview(program: "old"))
        await request.value
        #expect(store.scenePreview == nil)
    }

    @Test func aScenePackLoadFailureKeepsTheLastListAndExplainsTheFailure() async throws {
        let store = Self.makeStore()
        let saved = try Self.pack("saved")
        store.scenePackLoader = { [saved] }
        await store.loadScenePacks()
        #expect(store.scenePacksSupported)
        store.scenePackLoader = { throw CoreReplyError(code: "timeout", message: "try again") }
        await store.loadScenePacks()
        #expect(store.scenePacks == [saved])
        #expect(store.scenePacksSupported)
        #expect(store.lastError == "Could not load scene packs: try again")
        store.scenePackLoader = { throw CoreReplyError(code: "unknown_command") }
        await store.loadScenePacks()
        #expect(!store.scenePacksSupported)
        #expect(store.scenePacks.isEmpty)
    }
}
