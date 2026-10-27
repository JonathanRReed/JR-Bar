import Foundation
import Testing
@testable import JRBarApp
@testable import JRBarCore

@MainActor
@Suite("Studio read ownership", .serialized, .timeLimit(.minutes(2)))
struct EffectStudioReadOwnershipTests {
    @Test("canceling a reload without closing releases busy state without an error")
    func cancelledLoadSettles() async throws {
        try await withStore { fixture, store in
            let load = try #require(store.reload())
            try await fixture.pending(2)
            load.cancel()
            try await finishLibrary(fixture, generation: 1, error: "refused")
            await load.value
            #expect(!store.loading)
            #expect(store.loadError == nil && store.lastError == nil)
            #expect(store.catalog == nil)
        }
    }

    @Test("closing retires a library load and its later error")
    func closeRetiresLibraryLoad() async throws {
        try await withStore { fixture, store in
            let load = try #require(store.reload())
            try await fixture.pending(2)
            store.windowDidClose()
            #expect(!store.loading)
            try await finishLibrary(fixture, generation: 1, error: "refused")
            await load.value
            #expect(store.loadError == nil)
            #expect(store.lastError == nil)
            #expect(store.catalog == nil)
        }
    }

    @Test("a closed session cannot block or overwrite the next library load")
    func newLibraryLoadOwnsCompletion() async throws {
        try await withStore { fixture, store in
            let old = try #require(store.reload())
            try await fixture.pending(2)
            store.windowDidClose()
            let replacement = store.reload()
            #expect(replacement != nil)
            guard let replacement else {
                try await finishLibrary(fixture, generation: 1, error: "refused")
                await old.value
                return
            }
            try await fixture.pending(4)
            try await finishLibrary(fixture, generation: 2, newest: true)
            await replacement.value
            #expect(store.catalog?.generation == 2)
            #expect(store.assignments?.generation == 2)
            try await finishLibrary(fixture, generation: 1, error: "refused")
            await old.value
            #expect(store.catalog?.generation == 2)
            #expect(store.assignments?.generation == 2)
            #expect(!store.loading && store.loadError == nil && store.lastError == nil)
        }
    }

    @Test("the latest scene-pack list survives an older successful reply")
    func latestSceneListWins() async throws {
        try await withStore { fixture, store in
            let old = try pack("old")
            let current = try pack("current")
            let started = TestEvents<Void>()
            var finish: CheckedContinuation<[ScenePackSummary], Error>?
            store.scenePackLoader = { try await withCheckedThrowingContinuation { finish = $0; started.send(()) } }
            let first = Task { await store.loadScenePacks() }
            _ = try await started.next()
            store.scenePackLoader = { [current] }
            await store.loadScenePacks()
            finish?.resume(returning: [old])
            await first.value
            #expect(store.scenePacks == [current])
            #expect(store.scenePacksSupported)
        }
    }

    @Test("an obsolete unsupported reply cannot hide a supported scene-pack list")
    func oldUnsupportedReplyIsIgnored() async throws {
        try await withStore { fixture, store in
            let current = try pack("current")
            let started = TestEvents<Void>()
            var finish: CheckedContinuation<[ScenePackSummary], Error>?
            store.scenePackLoader = { try await withCheckedThrowingContinuation { finish = $0; started.send(()) } }
            let first = Task { await store.loadScenePacks() }
            _ = try await started.next()
            store.scenePackLoader = { [current] }
            await store.loadScenePacks()
            finish?.resume(throwing: CoreReplyError(code: "unknown_command"))
            await first.value
            #expect(store.scenePacks == [current])
            #expect(store.scenePacksSupported)
            #expect(store.lastError == nil)
        }
    }

    @Test("closing ignores a late scene-pack error")
    func closeRetiresSceneLoad() async throws {
        try await withStore { fixture, store in
            let started = TestEvents<Void>()
            var finish: CheckedContinuation<[ScenePackSummary], Error>?
            store.scenePackLoader = { try await withCheckedThrowingContinuation { finish = $0; started.send(()) } }
            let load = Task { await store.loadScenePacks() }
            _ = try await started.next()
            store.windowDidClose()
            finish?.resume(throwing: CoreReplyError(code: "refused", message: "Obsolete failure"))
            await load.value
            #expect(store.lastError == nil)
        }
    }

    private func pack(_ id: String) throws -> ScenePackSummary {
        try JSONDecoder().decode(ScenePackSummary.self, from: Data("{\"id\":\"\(id)\",\"scenes\":[\"calm\"],\"installed\":true}".utf8))
    }

    private func finishLibrary(_ fixture: CoreCommandReplyFixture, generation: Int,
                               newest: Bool = false, error: String? = nil) async throws {
        for name in ["list_effects", "list_assignments"] {
            let reply = try await fixture.core.send("fixture_pending")
            let requests = try #require(reply.result?["requests"]?.arrayValue)
            let matches: (JSONValue) -> Bool = { $0.objectValue?["name"]?.stringValue == name }
            let index = try #require(newest ? requests.lastIndex(where: matches) : requests.firstIndex(where: matches))
            let field = name == "list_effects" ? "effects" : "assignments"
            try await fixture.release(index: index, error: error,
                                      result: [field: .array([]), "generation": .number(Double(generation))])
        }
    }

    private func withStore(_ body: (CoreCommandReplyFixture, EffectStudioStore) async throws -> Void) async throws {
        let fixture = try CoreCommandReplyFixture()
        let suite = ScratchDefaults.suiteName("effect-read-ownership")
        defer { ScratchDefaults.remove(suite) }
        let store = EffectStudioStore(core: fixture.core, defaults: ScratchDefaults.open(suite))
        store.covered = true
        store.scenePackLoader = { [] }
        do {
            try await fixture.start()
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
