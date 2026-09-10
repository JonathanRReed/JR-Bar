import Foundation
import Testing
@testable import JRBarCore

/// Runs the mock with a slow timeline and round-trips every app-proposed
/// command through the real client: usage_history, refresh_usage,
/// list_effects, render_effect, list_assignments, set_assignment,
/// clear_assignment, export_effect_pack and import_effect_pack.
@Suite("Mock core round trips", .serialized)
struct MockEffectsRoundTripTests {
    @MainActor
    static func connectedModel(socket: String) async throws -> CoreModel {
        #expect(await MockCoreIntegrationTests.waitForSocket(socket), "the mock should create its socket")
        let model = CoreModel(socketPath: socket)
        model.start()
        let populated = await MockCoreIntegrationTests.wait { model.hello != nil && model.state != nil }
        #expect(populated, "hello and state should arrive")
        return model
    }

    @Test("usage_history and refresh_usage")
    @MainActor
    func usage() async throws {
        let socket = MockCoreIntegrationTests.temporarySocketPath()
        let mock = try MockCoreIntegrationTests.launchMock(socket: socket, extraArguments: ["--step", "600"])
        defer {
            if mock.isRunning { mock.terminate() }
            try? FileManager.default.removeItem(atPath: socket)
        }
        let model = try await Self.connectedModel(socket: socket)
        defer { model.stop() }

        #expect(model.usage.count == 4)
        let gemini = try #require(model.usage.first { $0.id == "gemini" })
        #expect(gemini.windows.first?.usedPct ?? 0 >= 91)
        #expect(gemini.forecast?.exhaustsAt != nil)
        let cursor = try #require(model.usage.first { $0.id == "cursor" })
        #expect(cursor.isSignedOut)
        #expect(model.usage.first { $0.id == "claude" }?.windows.map(\.name) == ["5h", "7d", "30d"])
        #expect(model.usage.first { $0.id == "claude" }?.account?.fidelity == "official")
        #expect(!model.usageSamples.samples(provider: "claude", window: "5h").isEmpty)

        let week = try await model.usageHistory(provider: "claude", range: .week)
        #expect(week.days.count == 7)
        #expect(week.hours.count == 168)
        #expect(week.pricing?.approximate == true)
        #expect(week.account?.plan == "Max 20×")
        let year = try await model.usageHistory(provider: "codex", range: .year)
        #expect(year.days.count == 365)
        #expect(year.range == "365d")
        let none = try await model.usageHistory(provider: "cursor", range: .month)
        #expect(none.isEmpty)
        await #expect(throws: CoreReplyError.self) {
            _ = try await model.usageHistory(provider: "nobody", range: .month)
        }

        let before = model.state?.usage?.refreshedAt ?? 0
        let reply = try await model.refreshUsage()
        #expect(reply.ok)
        let refreshed = await MockCoreIntegrationTests.wait { (model.state?.usage?.refreshedAt ?? 0) > before }
        #expect(refreshed, "refresh_usage bumps refreshed_at in the next state")
    }

    @Test("effects, assignments and packs")
    @MainActor
    func effects() async throws {
        let socket = MockCoreIntegrationTests.temporarySocketPath()
        let mock = try MockCoreIntegrationTests.launchMock(socket: socket, extraArguments: ["--step", "600"])
        defer {
            if mock.isRunning { mock.terminate() }
            try? FileManager.default.removeItem(atPath: socket)
        }
        let model = try await Self.connectedModel(socket: socket)
        defer { model.stop() }

        let catalog = try await model.listEffects()
        #expect(catalog.effects.count == 28)
        #expect(catalog.packs.count == 1)
        #expect(catalog.effects.allSatisfy { $0.preview != nil })

        // Parameters change the rendered program; out-of-range values are clamped.
        let slow = try await model.renderEffect("chase", parameters: ["duration_seconds": .number(4), "direction": .string("reverse")])
        let fast = try await model.renderEffect("chase", parameters: ["duration_seconds": .number(0.5)])
        #expect(slow.program != fast.program)
        #expect(slow.program.contains("4000ms"))
        #expect(fast.program.contains("500ms"))
        let clamped = try await model.renderEffect("steady", parameters: ["luminance": .number(9)])
        #expect(clamped.program == catalog.effect("steady")?.preview?.program)
        await #expect(throws: CoreReplyError.self) {
            _ = try await model.renderEffect("nope", parameters: [:])
        }

        var document = try await model.listAssignments()
        #expect(document.assignments.count == 5)
        #expect(document.activeScene == "calm")
        let generation = document.generation

        document = try await model.setAssignment(EffectAssignment(effectID: "comet", scope: .provider, targetID: "codex", parameters: ["trail_length": .number(99)]))
        #expect(document.generation > generation)
        let codex = try #require(document.assignment(scope: .provider, targetID: "codex"))
        #expect(codex.effectID == "comet")
        #expect(codex.parameters["trail_length"] == .number(12), "the mock clamps like the registry")
        #expect(codex.parameters["direction"] == .string("forward"), "defaults are filled in")

        // Replacing the same scope/target keeps one row.
        document = try await model.setAssignment(EffectAssignment(effectID: "drift", scope: .provider, targetID: "codex"))
        #expect(document.assignments.filter { $0.scope == .provider && $0.targetID == "codex" }.count == 1)
        #expect(document.assignment(scope: .provider, targetID: "codex")?.effectID == "drift")

        // The reserved semantics and malformed targets are refused.
        await #expect(throws: CoreReplyError.self) {
            _ = try await model.setAssignment(EffectAssignment(effectID: "alert", scope: .semantic, targetID: "asking"))
        }
        await #expect(throws: CoreReplyError.self) {
            _ = try await model.setAssignment(EffectAssignment(effectID: "alert", scope: .global, targetID: "claude"))
        }
        await #expect(throws: CoreReplyError.self) {
            _ = try await model.setAssignment(EffectAssignment(effectID: "alert", scope: .scene, targetID: "party"))
        }
        await #expect(throws: CoreReplyError.self) {
            _ = try await model.setAssignment(EffectAssignment(effectID: "ghost", scope: .global))
        }

        document = try await model.clearAssignment(scope: .provider, targetID: "codex")
        #expect(document.assignment(scope: .provider, targetID: "codex") == nil)
        document = try await model.clearAssignment(scope: .provider, targetID: "codex")
        #expect(document.assignments.count == 5, "clearing twice is harmless")

        // Export a pack from registry and pack effects, then import it back.
        let directory = FileManager.default.temporaryDirectory.appending(path: "jrbar-pack-\(UUID().uuidString.prefix(6))")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let exported = directory.appending(path: "My Looks.json")
        let reply = try await model.exportEffectPack(ids: ["heartbeat", "pack:nightlab:ember", "pack:nightlab:coal"], path: exported.path, name: "My Looks")
        #expect(reply.result?["effects"]?.intValue == 3)
        let payload = try JSONSerialization.jsonObject(with: Data(contentsOf: exported)) as? [String: Any]
        #expect(payload?["version"] as? Int == 2)
        #expect((payload?["safety"] as? [String: Any])?["data_only"] as? Bool == true)
        let effects = payload?["effects"] as? [[String: Any]]
        #expect(effects?.count == 3)
        #expect(effects?.first?["motion"] as? String == "heartbeat")
        #expect(effects?[1]["reduce_motion_fallback"] as? String == "coal", "fallbacks inside the export stay local")

        let imported = try await model.importEffectPack(path: exported.path)
        #expect(imported.packs.count == 2)
        #expect(imported.packs.contains { $0.id == "my-looks" })
        #expect(imported.effect("pack:my-looks:heartbeat") != nil)
        #expect(imported.effect("pack:my-looks:ember")?.reduceMotionFallback == "pack:my-looks:coal")
        #expect(imported.effect("pack:my-looks:heartbeat")?.preview != nil)
        #expect(try await model.listEffects().effects.count == 31)

        // Executable content and bad shapes are refused.
        let evil = directory.appending(path: "evil.json")
        try Data(#"{"id":"evil","name":"Evil","version":2,"safety":{"data_only":true,"network":false},"accessibility":{"reduced_motion":true,"high_contrast":true},"effects":[{"id":"x","label":"x","script":"python -c 1"}]}"#.utf8).write(to: evil)
        await #expect(throws: CoreReplyError.self) {
            _ = try await model.importEffectPack(path: evil.path)
        }
        await #expect(throws: CoreReplyError.self) {
            _ = try await model.importEffectPack(path: directory.appending(path: "missing.json").path)
        }
        let network = directory.appending(path: "network.json")
        try Data(#"{"id":"net","name":"Net","version":2,"safety":{"data_only":true,"network":true},"accessibility":{"reduced_motion":true,"high_contrast":true},"effects":[]}"#.utf8).write(to: network)
        await #expect(throws: CoreReplyError.self) {
            _ = try await model.importEffectPack(path: network.path)
        }
    }
}
