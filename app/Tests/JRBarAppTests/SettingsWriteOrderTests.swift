import Foundation
import Testing
@testable import JRBarApp
@testable import JRBarCore

@MainActor
@Suite("Settings write order")
struct SettingsWriteOrderTests {
    enum Outcome: CaseIterable { case refused, disconnected, clamped }

    @Test("an older reply cannot erase a newer edit, even when the value repeats",
          .timeLimit(.minutes(10)),
          arguments: Outcome.allCases)
    func newerEditSurvives(_ outcome: Outcome) async throws {
        let core = CoreModel(socketPath: NSTemporaryDirectory() + "jrbar-settings-order.sock")
        let store = SettingsStore(core: core)
        let gate = OverviewLoadOrderTests.Gate<CoreReply>()
        store.settingWriter = { _, _ in try await gate.request() }

        store.set("global_brightness_scale", .number(0.4), throttled: true)
        let olderWrite = try #require(store.flush("global_brightness_scale"))
        await gate.untilRequests(1)
        store.set("global_brightness_scale", .number(0.6), throttled: true)
        store.set("global_brightness_scale", .number(0.4), throttled: true)
        let newerWrite = try #require(store.flush("global_brightness_scale"))
        await gate.untilRequests(2)

        switch outcome {
        case .refused:
            gate.answer(1, with: CoreReply(id: "older", ok: false,
                error: CoreReplyError(code: "busy", message: "Earlier write refused")))
        case .disconnected:
            gate.fail(1, with: CoreClientError.notConnected)
        case .clamped:
            gate.answer(1, with: CoreReply(id: "older", ok: true,
                result: .object(["value": .number(0.3)])))
        }
        await olderWrite.value
        #expect(store.values.double("global_brightness_scale") == 0.4)
        #expect(store.lastError == nil)
        #expect(store.pendingWrites == 1)

        core.apply(.settings(CoreSettings(generation: 2, schema: CoreProtocol.knownSettingsSchema,
            document: .object(["global_brightness_scale": .number(0.4)]))))
        gate.answer(2, with: CoreReply(id: "newer", ok: true,
            result: .object(["value": .number(0.4)])))
        await newerWrite.value
        #expect(store.values.double("global_brightness_scale") == 0.4)
        #expect(store.pendingWrites == 0)
    }

    @Test("a current refused write still reverts and reports its reason")
    func currentFailureIsVisible() async throws {
        let core = CoreModel(socketPath: NSTemporaryDirectory() + "jrbar-settings-refusal.sock")
        core.apply(.settings(CoreSettings(generation: 1, schema: CoreProtocol.knownSettingsSchema,
            document: .object(["global_brightness_scale": .number(0.8)]))))
        let store = SettingsStore(core: core)
        store.settingWriter = { _, _ in
            CoreReply(id: "current", ok: false, error: CoreReplyError(code: "busy", message: "Try again"))
        }
        store.set("global_brightness_scale", .number(0.4), throttled: true)
        let write = try #require(store.flush("global_brightness_scale"))
        await write.value
        #expect(store.values.double("global_brightness_scale") == 0.8)
        #expect(store.lastError == "Try again")
        #expect(store.pendingWrites == 0)
    }

    @Test("turning plan limits off during consent does not send the older enable command",
          .timeLimit(.minutes(10)))
    func planLimitsStayOff() async throws {
        let core = CoreModel(socketPath: NSTemporaryDirectory() + "jrbar-plan-limits-order.sock")
        core.apply(.settings(CoreSettings(generation: 1, schema: CoreProtocol.knownSettingsSchema,
            document: .object(["claude_plan_limits_enabled": .bool(false)]))))
        let store = SettingsStore(core: core)
        let gate = OverviewLoadOrderTests.Gate<CoreReply>()
        var sent: [(String, JSONValue)] = []
        store.settingWriter = { path, value in
            sent.append((path.description, value))
            return try await gate.request()
        }

        let enable = store.setClaudePlanLimits(true)
        await gate.untilRequests(1)
        let disable = store.setClaudePlanLimits(false)
        await gate.untilRequests(2)
        gate.answer(2, with: CoreReply(id: "disable", ok: true, result: .object(["value": .bool(false)])))
        await disable.value
        gate.answer(1, with: CoreReply(id: "consent", ok: true, result: .object(["value": .number(1)])))
        await enable.value

        #expect(sent.map { $0.0 } == ["claude_plan_limits_consent_version", "claude_plan_limits_enabled"])
        #expect(sent.last?.1 == .bool(false))
        #expect(store.values.bool("claude_plan_limits_enabled") == false)
        #expect(store.lastError == nil)
        #expect(store.pendingWrites == 0)
    }
}
