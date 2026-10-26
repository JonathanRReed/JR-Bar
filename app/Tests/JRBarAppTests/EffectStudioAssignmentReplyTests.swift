import Foundation
import SwiftUI
import Testing
@testable import JRBarApp
@testable import JRBarCore

@MainActor
@Suite("Effect Studio assignment replies", .serialized, .timeLimit(.minutes(2)))
struct EffectStudioAssignmentReplyTests {
    @Test("an old task cannot clear a newer submission's pending state")
    func oldCleanupLeavesNewSubmissionAlone() async throws {
        try await withStore { fixture, store in
            store.beginAssigning(effect("first"), scope: .provider, target: "codex")
            let old = try #require(store.commitAssignment())
            try await fixture.pending(1)
            store.windowDidClose()
            store.beginAssigning(effect("second"), scope: .provider, target: "gemini")
            let draft = try #require(store.draft)
            let current = try #require(store.commitAssignment())
            try await fixture.pending(2)
            try await fixture.release(error: "refused")
            await old.value
            #expect(store.assignmentSaving && store.assignmentSavingThisDraft)
            #expect(store.assigning && store.draft == draft)
            #expect(store.assignmentError == nil && store.lastError == nil)
            try await fixture.release(result: object(EffectAssignmentDocument(assignments: [draft])))
            await current.value
            #expect(!store.assignmentSaving && !store.assigning)
        }
    }

    @Test("canceling confirmation releases admission and retains the visible draft")
    func cancelledConfirmationSettles() async throws {
        try await withStore { fixture, store in
            store.beginAssigning(effect("first"), scope: .provider, target: "codex")
            let draft = try #require(store.draft)
            let action = try #require(store.commitAssignment())
            try await fixture.pending(1)
            action.cancel()
            try await fixture.release(error: "refused")
            await action.value
            #expect(!store.assignmentSaving && store.canCommitAssignment)
            #expect(store.assigning && store.draft == draft)
            #expect(store.assignmentError == nil && store.lastError == nil)
        }
    }

    @Test("the assignment sheet waits for acceptance and retains a refused draft", arguments: [false, true])
    func sheetWaitsForAcceptance(_ accepted: Bool) async throws {
        try await withStore { fixture, store in
            store.beginAssigning(effect("first"), scope: .provider, target: "codex")
            store.draftUsesParameters = false
            let draft = try #require(store.draft)
            let action = try #require(store.commitAssignment())
            #expect(store.assigning)
            try await fixture.pending(1)
            try await fixture.release(error: accepted ? nil : "refused",
                                      result: object(EffectAssignmentDocument(assignments: [draft])))
            await action.value
            #expect(store.assigning == !accepted)
            if accepted {
                #expect(store.assignments?.assignments == [draft])
                #expect(store.status?.contains("assigned") == true)
            } else {
                #expect(store.draft == draft)
                #expect(!store.draftUsesParameters)
                #expect(store.lastError == "Assignment refused: Synthetic refused")
            }
        }
    }

    @Test("duplicate submissions do not send a second assignment")
    func duplicateSubmission() async throws {
        try await withStore { fixture, store in
            store.beginAssigning(effect("first"), scope: .provider, target: "codex")
            let draft = try #require(store.draft)
            let first = try #require(store.commitAssignment())
            let second = store.commitAssignment()
            #expect(second == nil)
            try await fixture.pending(second == nil ? 1 : 2)
            try await fixture.release(result: object(EffectAssignmentDocument(assignments: [draft])))
            if second != nil {
                try await fixture.release(result: object(EffectAssignmentDocument(assignments: [draft])))
            }
            await first.value
            await second?.value
        }
    }

    @Test("a closed session's refusal cannot report inside a newer sheet")
    func oldRefusalIsRetired() async throws {
        try await withStore { fixture, store in
            store.beginAssigning(effect("first"), scope: .provider, target: "codex")
            let action = try #require(store.commitAssignment())
            try await fixture.pending(1)
            store.windowDidClose()
            store.beginAssigning(effect("second"), scope: .provider, target: "gemini")
            let replacement = store.draft
            try await fixture.release(error: "refused")
            await action.value
            #expect(store.assigning && store.draft == replacement)
            #expect(store.lastError == nil && store.status == nil)
        }
    }

    @Test("a closed session's success cannot replace a fresh library snapshot")
    func oldSuccessDoesNotReplaceFreshSnapshot() async throws {
        try await withStore { fixture, store in
            store.beginAssigning(effect("first"), scope: .provider, target: "codex")
            let draft = try #require(store.draft)
            let action = try #require(store.commitAssignment())
            try await fixture.pending(1)
            store.windowDidClose()
            let external = EffectAssignment(effectID: "second", scope: .provider, targetID: "gemini")
            try await seed(fixture, store, assignments: [external], pending: 3)
            store.beginAssigning(effect("second"), scope: .provider, target: "gemini")
            let replacement = store.draft
            try await fixture.release(result: object(EffectAssignmentDocument(assignments: [draft])))
            await action.value
            #expect(store.assignments?.assignments == [external])
            #expect(store.assigning && store.draft == replacement)
            #expect(store.status == nil && store.lastError == nil)
        }
    }

    @Test("a refused draft survives a catalog refresh that removes its effect")
    func refusedDraftSurvivesCatalogRefresh() async throws {
        try await withStore { fixture, store in
            store.beginAssigning(effect("first"), scope: .provider, target: "codex")
            let draft = try #require(store.draft)
            let action = try #require(store.commitAssignment())
            try await fixture.pending(1)
            try await fixture.release(error: "refused")
            await action.value
            try await seed(fixture, store, effects: [effect("second")])
            #expect(store.assigning)
            #expect(store.draft == draft)
        }
    }

    @Test(.enabled(if: WindowsRenderProofTests.enabled))
    func assignmentSheetRenderProof() async throws {
        try await withStore { fixture, store in
            store.beginAssigning(effect("first"), scope: .provider, target: "codex")
            let action = try #require(store.commitAssignment())
            try await fixture.pending(1)
            try render("effect-assignment-pending", store)
            try await fixture.release(error: "refused", message: "Synthetic settings could not be saved. Reconnect to the monitor, then retry this assignment.")
            await action.value
            let reason = try #require(store.assignmentError)
            store.lastError = nil
            #expect(store.assignmentError == reason)
            try render("effect-assignment-refused", store)
            try await seed(fixture, store, effects: [effect("second")])
            #expect(!store.assignmentEffectAvailable && !store.canCommitAssignment)
            #expect(store.assignmentEffect?.id == "first" && store.draft?.effectID == "first")
            try render("effect-assignment-unavailable", store)
            store.beginAssigning(effect("second"), scope: .provider, target: "codex")
            let draft = try #require(store.draft)
            let previous = try #require(store.commitAssignment())
            try await fixture.pending(1)
            store.assigning = false
            store.beginAssigning(effect("second"), scope: .provider, target: "gemini")
            #expect(store.assignmentSaving && !store.assignmentSavingThisDraft)
            try render("effect-assignment-previous-pending", store)
            try await fixture.release(result: object(EffectAssignmentDocument(assignments: [draft])))
            await previous.value
            #expect(store.assigning && store.draftTarget == "gemini")
        }
    }

    @Test("Mix scope sends the effect and parameters without changing provider assignments", arguments: [false, true])
    func mixAssignment(_ accepted: Bool) async throws {
        try await withStore { fixture, store in
            let marquee = EffectDefinition(id: "marquee", label: "Marquee", meaning: "working", parameters: [
                EffectParameter(name: "duration_seconds", type: .number, defaultValue: .number(2.2), minimum: 0.3, maximum: 10)
            ], preview: EffectPreview(program: "#0A84FF"))
            try await seed(fixture, store, effects: [marquee])
            store.lightsStudio.requestPlan = { StudioLightPlan(mixes: [StudioMix(id: "effect", name: "Play an effect", parameters: [])], devices: []) }
            await store.lightsStudio.refreshPlan()
            store.beginAssigningMix(marquee)
            #expect(store.draftIsMix && store.canCommitAssignment)
            let before = store.assignments?.assignments
            let action = try #require(store.commitAssignment())
            try await fixture.pending(1)
            let pending = try await fixture.core.send("fixture_pending")
            let request = try #require(pending.result?["requests"]?.arrayValue?.first)
            #expect(request["name"]?.stringValue == "set_assignment")
            #expect(request["args"]?["scope"]?.stringValue == "mix")
            #expect(request["args"]?["effect_id"]?.stringValue == "marquee")
            #expect(request["args"]?["parameters"]?["duration_seconds"] == .number(2.2))
            try await fixture.release(error: accepted ? nil : "refused", result: object(EffectAssignmentDocument()))
            await action.value
            #expect(store.assigning == !accepted)
            #expect(store.assignments?.assignments == before)
            #expect(store.draftIsMix)
        }
    }

    private func render(_ name: String, _ store: EffectStudioStore) throws {
        try WindowsRenderProofTests.write(name, size: CGSize(width: 460, height: 430)) {
            AssignSheet(store: store)
        }
    }

    private func effect(_ id: String) -> EffectDefinition {
        EffectDefinition(id: id, label: "Synthetic \(id)", meaning: "general", parameters: [
            EffectParameter(name: "speed", type: .number, defaultValue: .number(1), minimum: 0, maximum: 2)
        ], preview: EffectPreview(program: "#0A84FF"))
    }

    private func object<T: Encodable>(_ value: T) throws -> [String: JSONValue] {
        let data = try JSONEncoder().encode(value)
        return try #require(JSONDecoder().decode(JSONValue.self, from: data).objectValue)
    }

    private func seed(_ fixture: CoreCommandReplyFixture, _ store: EffectStudioStore,
                      effects: [EffectDefinition]? = nil, assignments: [EffectAssignment] = [], pending: Int = 2) async throws {
        let task = try #require(store.reload())
        try await fixture.pending(pending)
        for name in ["list_effects", "list_assignments"] {
            let reply = try await fixture.core.send("fixture_pending")
            let requests = try #require(reply.result?["requests"]?.arrayValue)
            let index = try #require(requests.firstIndex { $0.objectValue?["name"]?.stringValue == name })
            let result: [String: JSONValue]
            if name == "list_effects" {
                result = try object(EffectCatalog(effects: effects ?? [effect("first"), effect("second")]))
            } else {
                result = try object(EffectAssignmentDocument(assignments: assignments))
            }
            try await fixture.release(index: index, result: result)
        }
        await task.value
    }

    private func withStore(_ body: (CoreCommandReplyFixture, EffectStudioStore) async throws -> Void) async throws {
        let fixture = try CoreCommandReplyFixture()
        let suite = ScratchDefaults.suiteName("effect-assignment-replies")
        defer { ScratchDefaults.remove(suite) }
        let store = EffectStudioStore(core: fixture.core, defaults: ScratchDefaults.open(suite))
        store.covered = true
        store.scenePackLoader = { [] }
        store.renderDelay = { throw CancellationError() }
        do {
            try await fixture.start()
            try await seed(fixture, store)
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
