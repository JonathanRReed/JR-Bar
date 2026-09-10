import Foundation
import Testing
@testable import JRBarCore

/// Runs the mock with a slow timeline and round-trips every app-proposed
/// command through the real client: usage_history, refresh_usage,
/// list_effects, render_effect, list_assignments, apply_effect (set and
/// remove), export_effect_pack and import_effect_pack.
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

    /// `usage_history` until the daemon stops calling it partial: the
    /// mock finishes its simulated scan on the second ask, as the daemon
    /// does once the scan is warm.
    @MainActor
    static func fullHistory(_ model: CoreModel, provider: String, range: UsageHistoryRange) async throws -> UsageHistory {
        var history = try await model.usageHistory(provider: provider, range: range)
        var tries = 0
        while history.partial, tries < 20 {
            try? await Task.sleep(for: .milliseconds(120))
            history = try await model.usageHistory(provider: provider, range: range)
            tries += 1
        }
        return history
    }

    @Test("usage_history and refresh_usage")
    @MainActor
    func usage() async throws {
        let socket = MockCoreIntegrationTests.temporarySocketPath()
        let mock = try MockCoreIntegrationTests.launchMock(socket: socket, extraArguments: ["--step", "600", "--history-scan", "0.4"])
        defer {
            if mock.isRunning { mock.terminate() }
            try? FileManager.default.removeItem(atPath: socket)
        }
        let model = try await Self.connectedModel(socket: socket)
        defer { model.stop() }

        #expect(model.usage.count == 5)
        let gemini = try #require(model.usage.first { $0.id == "gemini" })
        #expect(gemini.windows.first?.usedPct ?? 0 >= 91)
        #expect(gemini.forecast?.exhaustsAt != nil)
        let cursor = try #require(model.usage.first { $0.id == "cursor" })
        #expect(cursor.isSignedOut)
        #expect(model.usage.first { $0.id == "claude" }?.windows.map(\.name) == ["5h", "7d", "30d"])
        #expect(model.usage.first { $0.id == "claude" }?.account?.fidelity == "official")
        #expect(!model.usageSamples.samples(provider: "claude", window: "5h").isEmpty)

        // A cold scan answers with what it has, marked `partial`, and says
        // so again with a `usage_history_ready` event when it lands.
        let cold = try await model.usageHistory(provider: "claude", range: .week)
        #expect(cold.partial, "the first ask for a range catches the scan mid-flight")
        #expect(cold.days.isEmpty, "nothing cached yet: the daemon answers pending, not wrong")
        #expect(cold.records == 0)
        #expect(!cold.hasNoLocalRecords, "a scan that has not finished is not a verdict about the Mac")
        let announced = await MockCoreIntegrationTests.wait {
            model.lastEvent?.kind == CoreEvent.usageHistoryReadyKind
        }
        #expect(announced, "the scan announces itself when it finishes")
        #expect(model.lastEvent?.provider == "claude")
        #expect(model.lastEvent?.range == "7d")
        #expect(model.lastEvent?.notify == false, "it is a hint to re-ask, not a banner")

        let week = try await Self.fullHistory(model, provider: "claude", range: .week)
        #expect(!week.partial)
        #expect(week.days.count == 7)
        #expect(week.hours.count == 168)
        #expect(week.pricing?.approximate == true)
        #expect(week.account?.plan == "Max 20×")
        #expect((week.records ?? 0) > 0)
        #expect(!week.hasNoLocalRecords)
        let year = try await Self.fullHistory(model, provider: "codex", range: .year)
        #expect(year.days.count == 365)
        #expect(year.range == "365d")
        let none = try await Self.fullHistory(model, provider: "cursor", range: .month)
        #expect(none.isEmpty)
        #expect(none.records == 0)
        #expect(none.hasNoLocalRecords, "the scan ran and this Mac has nothing local for that provider")
        // Signed in, reporting windows, and still nothing to scan: the
        // Usage Center says so rather than drawing a month of zero.
        let devin = try await Self.fullHistory(model, provider: "devin", range: .month)
        #expect(devin.records == 0)
        #expect(devin.hasNoLocalRecords)
        let devinUsage = try #require(model.usage.first { $0.id == "devin" })
        #expect(devinUsage.windows.count == 2)
        // The third state end to end: the daemon reports Devin's weekly
        // window with `used_pct: null`, and it must arrive as unknown, not
        // as a window at zero with plenty left.
        let weekly = try #require(devinUsage.windows.first { $0.name == "7d" })
        #expect(weekly.usedPct == nil)
        #expect(weekly.isUnknown)
        #expect(weekly.resetsAt != nil, "unread is not absent: the reset is still known")
        #expect(weekly.percentText == "—")
        #expect(try #require(devinUsage.windows.first { $0.name == "5h" }).usedPct == 4.0)
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
