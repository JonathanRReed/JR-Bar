import Carbon
import Foundation
import Testing
@testable import JRBarApp
@testable import JRBarCore

@MainActor
@Suite("Studio light plans", .serialized, .timeLimit(.minutes(2)))
struct StudioLightsTests {
    private func preview(_ program: String = "#0088FF") -> StudioFleetPreview {
        StudioFleetPreview(program: program, label: "Two providers", played: "cycle",
                           reason: "Provider animations take turns.", warnings: ["Weave does not fit."], ledCount: 8)
    }

    @Test("scenario previews use the daemon and retain its fallback explanation")
    func wireContractAndCache() async throws {
        let fixture = try CoreCommandReplyFixture()
        do {
            try await fixture.start()
            let lights = EffectStudioLights(core: fixture.core)
            #expect(lights.playOnDevices)
            lights.scenario = .two
            let read = Task { await lights.refreshPreviews() }
            let request = try await fixture.request()
            #expect(request["name"] == "preview_fleet")
            #expect(request["args"]?["scenario"] == "pair")
            #expect(request["args"]?["led_count"] == 8)
            try await fixture.release(result: ["program": "#0088FF", "label": "Two providers", "played": "cycle",
                                              "reason": "Provider animations take turns.", "warnings": ["Weave does not fit."], "led_count": 8])
            await read.value
            #expect(lights.program == "#0088FF")
            #expect(lights.selectedPreview?.warnings == ["Weave does not fit."])
            #expect(lights.selectedPreview?.reason == "Provider animations take turns.")
            lights.cancelReads()
            #expect(lights.program == "#0088FF", "cached programs survive window close")
            await fixture.stop()
        } catch { await fixture.stop(); throw error }
    }

    @Test("cached previews ignore unchanged settings frames and refresh after a real edit")
    func cacheUsesDocumentChanges() async {
        let core = CoreModel(socketPath: "/tmp/jrbar-studio-cache-unused.sock")
        core.handle(.connected)
        core.apply(.state(CoreState()))
        let original: JSONValue = ["colors": ["blend_mode": "color_blend", "cycle_speed_seconds": 2.2]]
        core.apply(.settings(CoreSettings(generation: 1, document: original)))
        let lights = EffectStudioLights(core: core)
        var calls = 0
        lights.requestPreview = { _, _ in calls += 1; return preview() }
        await lights.refreshPreviews()
        core.apply(.settings(CoreSettings(generation: 2, document: original)))
        await drainMainQueue()
        await lights.refreshPreviews()
        #expect(calls == 1 && lights.program == "#0088FF")
        let edited = SettingsDocument(original).replacing("colors.cycle_speed_seconds", with: 4)
        core.apply(.settings(CoreSettings(generation: 3, document: edited.root)))
        await drainMainQueue()
        await lights.refreshPreviews()
        #expect(calls == 2)
    }

    @Test("calm modes report motion when the daemon sends a travelling program")
    func calmMotionIsNotHidden() {
        let source = "#0088FF #000000 #000000 #000000 #000000 #000000 #000000 #000000 100ms cosine\nroll-right 2s linear\nrepeat"
        for (mode, name) in [("classic", "Status Only"), ("color_blend", "Smooth")] {
            let moving = StudioFleetPreview(program: source, label: "Two providers", played: mode,
                                            reason: "Current state", warnings: [], ledCount: 8)
            #expect(moving.playbackWarnings == ["\(name) still moves the working light."])
            let still = StudioFleetPreview(program: "#0088FF", label: "Two providers", played: mode,
                                           reason: "Current state", warnings: [], ledCount: 8)
            #expect(still.playbackWarnings.isEmpty)
        }
    }

    @Test("an older preview cannot replace a newer scenario or clear its busy state")
    func oldReplyCannotWin() async throws {
        let core = CoreModel(socketPath: "/tmp/jrbar-studio-order-unused.sock")
        core.handle(.connected)
        core.apply(.state(CoreState()))
        let lights = EffectStudioLights(core: core)
        let started = TestEvents<String>()
        var pending: [String: CheckedContinuation<StudioFleetPreview, Never>] = [:]
        lights.requestPreview = { scenario, _ in
            await withCheckedContinuation { pending[scenario] = $0; started.send(scenario) }
        }
        lights.scenario = .one
        let old = Task { await lights.refreshPreviews() }
        #expect(try await started.next() == "one_working")
        lights.scenario = .two
        let current = Task { await lights.refreshPreviews() }
        #expect(try await started.next() == "pair")
        pending["one_working"]?.resume(returning: preview("#FF0000"))
        await old.value
        #expect(lights.program == nil && lights.refreshing)
        pending["pair"]?.resume(returning: preview())
        await current.value
        #expect(lights.program == "#0088FF" && !lights.refreshing)
    }

    @Test("closing retires an in-flight plan, and a failed refresh keeps the last plan")
    func closedAndFailedReads() async throws {
        let core = CoreModel(socketPath: "/tmp/jrbar-studio-close-unused.sock")
        core.handle(.connected)
        core.apply(.state(CoreState()))
        let lights = EffectStudioLights(core: core)
        let started = TestEvents<Void>()
        var finish: CheckedContinuation<StudioLightPlan, Never>?
        lights.requestPlan = { await withCheckedContinuation { finish = $0; started.send(()) } }
        let read = Task { await lights.refreshPlan() }
        _ = try await started.next()
        lights.cancelReads()
        finish?.resume(returning: StudioLightPlan(mixes: [], devices: []))
        await read.value
        #expect(lights.plan == nil)
        lights.requestPlan = { StudioLightPlan(mixes: [], devices: []) }
        await lights.refreshPlan()
        lights.requestPlan = { throw CoreReplyError(code: "refused", message: "Synthetic refusal") }
        await lights.refreshPlan()
        #expect(lights.plan != nil)
        #expect(lights.planFailure?.contains("Synthetic refusal") == true)
    }

    @Test("provider controls save exact Studio values through assignments")
    func providerParameters() async throws {
        let fixture = try CoreCommandReplyFixture()
        let suite = ScratchDefaults.suiteName("studio-provider")
        defer { ScratchDefaults.remove(suite) }
        let store = EffectStudioStore(core: fixture.core, defaults: ScratchDefaults.open(suite))
        do {
            try await fixture.start()
            let effect = EffectDefinition(id: "comet", label: "Comet", meaning: "work", catalog: "provider_animation")
            let values: [String: JSONValue] = ["duration_seconds": 3.4, "tail_length": 4]
            let save = try #require(store.saveProvider("codex", effect: effect, parameters: values))
            let request = try await fixture.request()
            #expect(request["name"] == "set_assignment")
            #expect(request["args"]?["scope"] == "provider")
            #expect(request["args"]?["target_id"] == "codex")
            #expect(request["args"]?["parameters"] == .object(values))
            #expect(store.saveProvider("codex", effect: effect, parameters: values) == nil)
            let row = EffectAssignment(effectID: effect.id, scope: .provider, targetID: "codex", parameters: values)
            let result = try JSONDecoder().decode(JSONValue.self, from: JSONEncoder().encode(EffectAssignmentDocument(assignments: [row])))
            try await fixture.release(result: try #require(result.objectValue))
            await save.value
            #expect(store.assignments?.assignments == [row])
            #expect(store.providerSaving.isEmpty)
            store.windowDidClose()
            await fixture.stop()
        } catch { store.windowDidClose(); await fixture.stop(); throw error }
    }

    @Test("a drag keeps its latest provider parameters while a write is pending")
    func providerDragKeepsLastValue() async throws {
        let fixture = try CoreCommandReplyFixture()
        let suite = ScratchDefaults.suiteName("studio-provider-drag")
        defer { ScratchDefaults.remove(suite) }
        let store = EffectStudioStore(core: fixture.core, defaults: ScratchDefaults.open(suite))
        do {
            try await fixture.start()
            let effect = EffectDefinition(id: "comet", label: "Comet", meaning: "work", catalog: "provider_animation")
            let save = try #require(store.saveProvider("codex", effect: effect, parameters: ["duration_seconds": 2]))
            try await fixture.pending(1)
            _ = store.saveProvider("codex", effect: effect, parameters: ["duration_seconds": 3])
            _ = store.saveProvider("codex", effect: effect, parameters: ["duration_seconds": 4])
            #expect(store.pendingProviderParameters("codex") == ["duration_seconds": 4])
            try await fixture.release(result: ["assignments": [], "generation": 1])
            let latest = try await fixture.request()
            #expect(latest["args"]?["parameters"] == ["duration_seconds": 4])
            try await fixture.release(result: ["assignments": [["effect_id": "comet", "scope": "provider", "target_id": "codex",
                                                               "parameters": ["duration_seconds": 4]]], "generation": 2])
            await save.value
            #expect(store.providerSaving.isEmpty && store.pendingProviderParameters("codex") == nil)
            #expect(store.assignments?.assignments.first?.parameters == ["duration_seconds": 4])
            store.windowDidClose()
            await fixture.stop()
        } catch { store.windowDidClose(); await fixture.stop(); throw error }
    }

    @Test("hardware auditions request each device's own geometry and keep its fallback visible")
    func deviceAudition() async throws {
        let fixture = try CoreCommandReplyFixture()
        do {
            try await fixture.start()
            fixture.core.apply(.state(CoreState(devices: [CoreDevice(id: "synthetic-dot", kind: "dot", name: "Test Dot", leds: 2, connected: true)])))
            let lights = EffectStudioLights(core: fixture.core)
            lights.requestPreview = { _, _ in preview() }
            await lights.refreshPreviews()
            let action = try #require(lights.playPreview())
            let render = try await fixture.request()
            #expect(render["name"] == "preview_fleet")
            #expect(render["args"]?["device"] == "synthetic-dot")
            #expect(render["args"]?["led_count"] == 2)
            #expect(render["args"]?["blend_mode"] == nil, "the daemon applies the device's override")
            try await fixture.release(result: ["program": "#00FF00", "label": "Two providers", "played": "cycle",
                                              "reason": "Taking turns on the Dot.", "warnings": ["Split does not fit."], "led_count": 2])
            let screen = try await fixture.request()
            #expect(screen["name"] == "preview_program")
            #expect(screen["args"]?["surface"] == "screen_bar")
            #expect(screen["args"]?["program"] == "#0088FF")
            try await fixture.release(result: [:])
            let dot = try await fixture.request()
            #expect(dot["args"]?["surface"] == "synthetic-dot")
            #expect(dot["args"]?["program"] == "#00FF00")
            try await fixture.release(result: [:])
            await action.value
            #expect(!lights.playing && lights.playFailure == nil)
            #expect(lights.auditions["Test Dot"]?.warnings == ["Split does not fit."])
            await fixture.stop()
        } catch { await fixture.stop(); throw error }
    }

    @Test("Studio registers option-command-L through the shared shortcut registry")
    func studioShortcut() {
        let registrar = HotkeyCenterTests.Recorder()
        let center = HotkeyCenter(registrar: registrar)
        let suite = ScratchDefaults.suiteName("studio-shortcut")
        defer { ScratchDefaults.remove(suite) }
        let store = EffectStudioStore(core: CoreModel(socketPath: "/tmp/jrbar-studio-shortcut-unused.sock"), defaults: ScratchDefaults.open(suite))
        let controller = EffectStudioWindowController(store: store)
        controller.registerShortcut(center: center)
        #expect(registrar.registered.map(\.chord) == [HotkeyChord(keyCode: UInt32(kVK_ANSI_L), modifiers: UInt32(optionKey | cmdKey))])
    }
}
