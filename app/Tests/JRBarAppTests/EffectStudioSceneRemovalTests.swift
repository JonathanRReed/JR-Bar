import Foundation
import Observation
import SwiftUI
import Synchronization
import Testing
@testable import JRBarApp
@testable import JRBarCore

@MainActor
@Suite("Effect Studio scene and removal ownership", .serialized, .timeLimit(.minutes(10)))
struct EffectStudioSceneRemovalTests {
    @Test("automatic scene facts change the displayed scene without changing its saved selection")
    func automaticSceneFactIsDisplayed() async throws {
        try await withStore { fixture, store in
            fixture.core.apply(.settings(CoreSettings(generation: 1, schema: CoreProtocol.knownSettingsSchema,
                document: .object(["active_scene": .string("calm"), "scene_state": .object([
                    "effective_scene": .string("focus"), "selected_scene": .string("calm"),
                ])]))))
            #expect(store.activeScene == "focus")
            #expect(fixture.core.settings?.document["active_scene"]?.stringValue == "calm")
        }
    }

    @Test("confirmed manual choice retires the automatic hint before its settings echo")
    func manualConfirmationBeatsOldAutomaticFact() async throws {
        try await withStore { fixture, store in
            fixture.core.apply(.settings(CoreSettings(generation: 1, schema: CoreProtocol.knownSettingsSchema,
                document: .object(["active_scene": .string("calm"), "scene_state": .object([
                    "effective_scene": .string("focus"), "lease_id": .string("synthetic-lease"),
                ])]))))
            #expect(store.activeSceneIsAutomatic)
            let action = try #require(store.setActiveScene(store.activeScene))
            try await fixture.pending(1)
            try await fixture.release(result: settingReply("active_scene", value: .string("focus"), generation: 2))
            await action.value
            #expect(store.activeScene == "focus" && !store.activeSceneIsAutomatic)
        }
    }

    @Test(.enabled(if: WindowsRenderProofTests.enabled))
    func automaticSceneRenderProof() async throws {
        try await withStore { fixture, store in
            fixture.core.apply(.settings(CoreSettings(generation: 1, schema: CoreProtocol.knownSettingsSchema,
                document: .object(["active_scene": .string("calm"), "scene_state": .object([
                    "effective_scene": .string("focus"), "lease_id": .string("synthetic-lease"),
                ])]))))
            try render("effect-scene-automatic", store)
        }
    }

    @Test("lost confirmation is not reported as a refused mutation", arguments: [false, true])
    func disconnectedMutationIsUnconfirmed(_ removal: Bool) async throws {
        try await withStore { fixture, store in
            let action = try #require(removal ? store.remove(row("codex")) : store.setActiveScene("focus"))
            try await fixture.pending(1)
            fixture.core.stop()
            await action.value
            #expect(store.lastError?.contains("not confirmed") == true)
            #expect(!store.sceneChanging && !store.isRemoving(row("codex")))
        }
    }

    @Test("a settings-only state revision does not wake catalog loading")
    func settingsOnlyRevisionDoesNotWakeCatalog() async throws {
        try await withStore { fixture, _ in
            fixture.core.apply(.state(CoreState(settingsGeneration: 1, catalogGeneration: 1)))
            let notices = Mutex(0)
            withObservationTracking { EffectStudioStore.observedFacts(fixture.core) } onChange: {
                notices.withLock { $0 += 1 }
            }
            fixture.core.apply(.state(CoreState(settingsGeneration: 2, catalogGeneration: 1)))
            #expect(notices.withLock { $0 } == 0)
        }
    }

    @Test("settings observers see the document and its stream together")
    func settingsAssociationIsAtomicAndObserved() async throws {
        try await withStore { fixture, _ in
            let notices = Mutex(0)
            withObservationTracking { _ = fixture.core.settings } onChange: {
                notices.withLock { $0 += 1 }
            }
            fixture.core.onSettingsFrame = { [weak core = fixture.core] value in
                #expect(core?.settingsFrame?.settings == value)
                #expect(core?.settingsFrame?.stream == "scene-peer")
            }
            settings(fixture, generation: 2, scene: "focus")
            #expect(notices.withLock { $0 } == 1)
            #expect(fixture.core.settings?.generation == 2)
        }
    }

    @Test("an old removal cannot release a new removal of the same slot")
    func oldRemovalCleanupKeepsNewOwner() async throws {
        try await withStore { fixture, store in
            let old = try #require(store.remove(row("codex")))
            try await fixture.pending(1)
            store.windowDidClose()
            try await seed(fixture, store, rows: [row("codex"), row("gemini")], pending: 3)
            let current = try #require(store.remove(row("codex")))
            try await fixture.pending(2)
            try await fixture.release(error: "refused")
            await old.value
            #expect(store.isRemoving(row("codex")) && store.lastError == nil)
            try await fixture.release(result: object(EffectAssignmentDocument(assignments: [row("gemini")])))
            await current.value
            #expect(!store.isRemoving(row("codex")))
        }
    }

    @Test("assignment and removal cannot overlap on the same slot")
    func sameSlotAdmission() async throws {
        try await withStore { fixture, store in
            let removal = try #require(store.remove(row("codex")))
            try await fixture.pending(1)
            let effect = try #require(store.catalog?.effect("synthetic"))
            store.beginAssigning(effect, scope: .provider, target: "codex")
            #expect(!store.canCommitAssignment && store.commitAssignment() == nil)
            store.beginAssigning(effect, scope: .provider, target: "gemini")
            let assignment = try #require(store.commitAssignment())
            #expect(store.remove(row("gemini")) == nil)
            try await fixture.pending(2)
            try await fixture.release(result: object(EffectAssignmentDocument(assignments: [row("gemini")])))
            await removal.value
            try await fixture.release(result: object(EffectAssignmentDocument(assignments: [row("gemini")])))
            await assignment.value
        }
    }

    @Test("closing before a removal starts prevents dispatch")
    func retiredUnsentRemovalDoesNotDispatch() async throws {
        try await withStore { fixture, store in
            let action = try #require(store.remove(row("codex")))
            store.windowDidClose()
            await action.value
            try await fixture.pending(0)
        }
    }

    @Test("incomplete scene-setting receipts cannot change the displayed scene", arguments: [
        ["path": JSONValue.string("active_scene"), "value": .string("focus"), "generation": .bool(true)],
        ["path": .string("active_scene"), "value": .string("focus"), "generation": .number(1.5)],
        ["path": .string("active_scene"), "value": .string("focus"), "generation": .number(-1)],
        ["path": .string("other"), "value": .string("focus"), "generation": .number(2)],
        ["path": .string("active_scene"), "value": .null, "generation": .number(2)]
    ])
    func malformedSceneReceiptIsRefused(_ result: [String: JSONValue]) async throws {
        try await withStore { fixture, store in
            let action = try #require(store.setActiveScene("focus"))
            try await fixture.pending(1)
            try await fixture.release(result: result)
            await action.value
            #expect(!store.sceneChanging && store.activeScene == "calm")
            #expect(store.lastError?.contains("incomplete") == true)
        }
    }

    @Test("an old peer's reply cannot replace a new peer's scene")
    func oldPeerReplyIsIgnored() async throws {
        try await withStore { fixture, store in
            let action = try #require(store.setActiveScene("focus"))
            try await fixture.pending(1)
            fixture.core.apply(.hello(CoreHello(stream: "replacement-peer")))
            settings(fixture, generation: 1, scene: "night")
            try await fixture.release(result: settingReply("active_scene", value: .string("focus"), generation: 2))
            await action.value
            #expect(store.activeScene == "night" && store.lastError == nil)
        }
    }

    @Test(.enabled(if: WindowsRenderProofTests.enabled))
    func sceneAndRemovalRenderProof() async throws {
        try await withStore { fixture, store in
            let pack = try JSONDecoder().decode(ScenePackSummary.self, from: Data(#"{"id":"first-pack","name":"Synthetic scenes","scenes":["calm","focus"],"installed":true}"#.utf8))
            store.scenePackLoader = { [pack] }
            await store.loadScenePacks()
            let scene = try #require(store.setActiveScene("focus"))
            try await fixture.pending(1)
            try render("effect-scene-changing", store)
            try await fixture.release(result: settingReply("active_scene", value: .string("focus"), generation: 2))
            await scene.value
            let packChange = try #require(store.setActiveScenePack(nil))
            try await fixture.pending(1)
            try render("effect-scene-pack-changing", store)
            try await fixture.release(error: "refused")
            await packChange.value
            try render("effect-scene-pack-refused", store)
            store.lastError = nil
            let removal = try #require(store.remove(row("codex")))
            try await fixture.pending(1)
            try render("effect-assignment-removing", store)
            try await fixture.release(result: object(EffectAssignmentDocument(assignments: [row("gemini")])))
            await removal.value
        }
    }

    private func render(_ name: String, _ store: EffectStudioStore) throws {
        try WindowsRenderProofTests.write(name, size: CGSize(width: 520, height: 440)) {
            VStack(spacing: 0) {
                EffectAssignmentsPane(store: store)
                if let error = store.lastError { WindowStatusCapsule(text: error, isError: true) }
            }
        }
    }

    @Test("new settings update the active scene without a catalog refresh")
    func settingsFrameWins() async throws {
        try await withStore { fixture, store in
            settings(fixture, generation: 2, scene: "focus")
            #expect(store.activeScene == "focus")
        }
    }

    @Test("scene and scene-pack refusals reach the existing error UI", arguments: [false, true])
    func refusedSettingsAreVisible(_ pack: Bool) async throws {
        try await withStore { fixture, store in
            let action = try #require(pack ? store.setActiveScenePack("synthetic-pack") : store.setActiveScene("focus"))
            try await fixture.pending(1)
            try await fixture.release(error: "refused")
            try await finish(action, fixture, scene: "calm")
            let prefix = pack ? "Scene pack not changed" : "Scene not changed"
            #expect(store.lastError == "\(prefix): Synthetic refused")
            #expect(store.activeScene == "calm" && store.activeScenePackID == "first-pack")
        }
    }

    @Test("confirmed scene stays current while its settings frame is in transit")
    func confirmedSceneBeforePush() async throws {
        try await withStore { fixture, store in
            let action = try #require(store.setActiveScene("focus"))
            try await fixture.pending(1)
            try await fixture.release(result: settingReply("active_scene", value: .string("focus"), generation: 2))
            try await finish(action, fixture, scene: "focus")
            #expect(store.activeScene == "focus")
            settings(fixture, generation: 2, scene: "focus")
            #expect(store.activeScene == "focus")
            settings(fixture, generation: 3, scene: "night")
            #expect(store.activeScene == "night")
        }
    }

    @Test("a normalized scene is shown and its refused request is explained")
    func normalizationIsVisible() async throws {
        try await withStore { fixture, store in
            let action = try #require(store.setActiveScene("focus"))
            try await fixture.pending(1)
            try await fixture.release(result: settingReply("active_scene", value: .string("calm"), generation: 2))
            try await finish(action, fixture, scene: "calm")
            #expect(store.activeScene == "calm")
            #expect(store.lastError?.contains("kept") == true)
        }
    }

    @Test("explicit null confirms built-in scenes before a settings push")
    func packClearUsesExplicitNull() async throws {
        try await withStore { fixture, store in
            let action = try #require(store.setActiveScenePack(nil))
            try await fixture.pending(1)
            try await fixture.release(result: settingReply("active_scene_pack", value: .null, generation: 2))
            try await finish(action, fixture, scene: "calm")
            #expect(store.activeScenePackID == nil)
            settings(fixture, generation: 2, scene: "calm", pack: nil)
            #expect(store.activeScenePackID == nil)
            settings(fixture, generation: 3, scene: "calm", pack: "second-pack")
            #expect(store.activeScenePackID == "second-pack")
        }
    }

    @Test("a new peer's confirmation cannot be retired by retained old settings")
    func newPeerIgnoresRetainedOldSettings() async throws {
        try await withStore { fixture, store in
            settings(fixture, generation: 99, scene: "night")
            fixture.core.apply(.hello(CoreHello(stream: "replacement-peer")))
            let action = try #require(store.setActiveScene("focus"))
            try await fixture.pending(1)
            try await fixture.release(result: settingReply("active_scene", value: .string("focus"), generation: 2))
            try await finish(action, fixture, scene: "focus")
            #expect(store.activeScene == "focus")
            settings(fixture, generation: 2, scene: "focus")
            #expect(store.activeScene == "focus")
        }
    }

    @Test("a newer external settings frame beats an older successful write reply")
    func newerFrameBeatsLateEcho() async throws {
        try await withStore { fixture, store in
            let action = try #require(store.setActiveScene("focus"))
            try await fixture.pending(1)
            settings(fixture, generation: 3, scene: "night")
            try await fixture.release(result: settingReply("active_scene", value: .string("focus"), generation: 2))
            try await finish(action, fixture, scene: "focus")
            #expect(store.activeScene == "night")
        }
    }

    @Test("retired removal replies cannot replace new rows or revive an error", arguments: [false, true])
    func closedRemovalIsRetired(_ accepted: Bool) async throws {
        try await withStore { fixture, store in
            let action = try #require(store.remove(row("codex")))
            try await fixture.pending(1)
            store.windowDidClose()
            try await seed(fixture, store, rows: [row("gemini")], pending: 3)
            try await fixture.release(error: accepted ? nil : "refused",
                                      result: object(EffectAssignmentDocument()))
            await action.value
            #expect(store.assignments?.assignments == [row("gemini")])
            #expect(store.lastError == nil)
        }
    }

    @Test("duplicate removals send only one command")
    func duplicateRemoval() async throws {
        try await withStore { fixture, store in
            let first = try #require(store.remove(row("codex")))
            let second = store.remove(row("codex"))
            #expect(second == nil)
            try await fixture.pending(second == nil ? 1 : 2)
            try await fixture.release(result: object(EffectAssignmentDocument()))
            if second != nil { try await fixture.release(result: object(EffectAssignmentDocument())) }
            await first.value
            await second?.value
        }
    }

    @Test("an older library read cannot bring back a removed row")
    func olderLibraryCannotResurrectRemoval() async throws {
        try await withStore { fixture, store in
            let read = try #require(store.reload())
            try await fixture.pending(2)
            let removal = try #require(store.remove(row("codex")))
            try await fixture.pending(3)
            try await release("clear_assignment", fixture, result: object(EffectAssignmentDocument(assignments: [row("gemini")])))
            await removal.value
            try await completeLibrary(fixture, rows: [row("codex"), row("gemini")])
            await read.value
            #expect(store.assignments?.assignments == [row("gemini")])
        }
    }

    private func settings(_ fixture: CoreCommandReplyFixture, generation: Int, scene: String, pack: String? = "first-pack") {
        fixture.core.apply(.settings(CoreSettings(generation: generation, schema: CoreProtocol.knownSettingsSchema,
                                                  document: .object(["active_scene": .string(scene), "active_scene_pack": pack.map(JSONValue.string) ?? .null]))))
    }

    private func row(_ provider: String) -> EffectAssignment {
        EffectAssignment(effectID: "synthetic", scope: .provider, targetID: provider)
    }

    private func settingReply(_ path: String, value: JSONValue, generation: Int) -> [String: JSONValue] {
        ["path": .string(path), "value": value, "generation": .number(Double(generation))]
    }

    private func object<T: Encodable>(_ value: T) throws -> [String: JSONValue] {
        let data = try JSONEncoder().encode(value)
        return try #require(JSONDecoder().decode(JSONValue.self, from: data).objectValue)
    }

    private func release(_ command: String, _ fixture: CoreCommandReplyFixture, result: [String: JSONValue]) async throws {
        let reply = try await fixture.core.send("fixture_pending")
        let requests = try #require(reply.result?["requests"]?.arrayValue)
        let index = try #require(requests.firstIndex { $0.objectValue?["name"]?.stringValue == command })
        try await fixture.release(index: index, result: result)
    }

    private func completeLibrary(_ fixture: CoreCommandReplyFixture, rows: [EffectAssignment]) async throws {
        let effect = EffectStudioLibraryTests.makeEffect("synthetic", program: "#0A84FF")
        try await release("list_effects", fixture, result: object(EffectCatalog(effects: [effect])))
        try await release("list_assignments", fixture, result: object(EffectAssignmentDocument(assignments: rows, activeScene: "calm")))
    }

    private func seed(_ fixture: CoreCommandReplyFixture, _ store: EffectStudioStore,
                      rows: [EffectAssignment], pending: Int = 2) async throws {
        let task = try #require(store.reload())
        try await fixture.pending(pending)
        try await completeLibrary(fixture, rows: rows)
        await task.value
    }

    private func finish(_ task: Task<Void, Never>, _ fixture: CoreCommandReplyFixture, scene: String) async throws {
        var completed = false
        let observer = Task { await task.value; completed = true }
        defer { observer.cancel() }
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(5))
        while !completed, clock.now < deadline {
            let reply = try await fixture.core.send("fixture_pending")
            let requests = reply.result?["requests"]?.arrayValue ?? []
            if let index = requests.firstIndex(where: { $0.objectValue?["name"]?.stringValue == "list_assignments" }) {
                try await fixture.release(index: index, result: object(EffectAssignmentDocument(activeScene: scene)))
            }
            await Task.yield()
        }
        try #require(completed)
        await observer.value
    }

    private func withStore(_ body: (CoreCommandReplyFixture, EffectStudioStore) async throws -> Void) async throws {
        let fixture = try CoreCommandReplyFixture()
        let suite = ScratchDefaults.suiteName("effect-scene-removal")
        defer { ScratchDefaults.remove(suite) }
        let store = EffectStudioStore(core: fixture.core, defaults: ScratchDefaults.open(suite))
        store.covered = true
        store.scenePackLoader = { [] }
        store.renderDelay = { throw CancellationError() }
        do {
            try await fixture.start()
            fixture.core.apply(.hello(CoreHello(stream: "scene-peer")))
            settings(fixture, generation: 1, scene: "calm")
            try await seed(fixture, store, rows: [row("codex"), row("gemini")])
            try await body(fixture, store)
            store.windowDidClose()
            await fixture.stop()
        } catch {
            store.windowDidClose()
            await fixture.stop()
            throw error
        }
    }
}
