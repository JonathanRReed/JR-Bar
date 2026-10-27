import Foundation
@testable import JRBarCore
import JRBarTestSupport
import Testing
@testable import JRBarApp

@Suite("Shared provider list", .serialized, .timeLimit(.minutes(1)))
@MainActor
struct ProviderListStoreTests {
    func row(_ id: String = "claude", enabled: Bool = true, consent: Bool = false, hidden: Bool = false) throws -> ProviderRow {
        let data = try JSONSerialization.data(withJSONObject: [
            "id": id, "enabled": enabled, "usage_consent": ["granted": consent],
            "options": ["panel_hidden": hidden ? "true" : "false"],
        ])
        return try JSONDecoder().decode(ProviderRow.self, from: data)
    }

    func reply(_ choices: MenuBarProviderPreferences, ok: Bool = true) -> CoreReply {
        CoreReply(id: "fixture", ok: ok, result: .object([
            "generation": .number(4), "value": .object([
                "order": .array(choices.order.map(JSONValue.string)),
                "hidden": .array(choices.hidden.map(JSONValue.string)),
            ]),
        ]), error: ok ? nil : CoreReplyError(code: "refused", message: "Could not save"))
    }

    @Test func orderIsSharedAndVisibilityDoesNotChangeConsent() async throws {
        let core = CoreModel(socketPath: "/nonexistent-u1.sock")
        let list = ProviderListStore(core: core)
        let rows = try [row(), row("codex"), row("t3code")]
        list.readRows = { rows }
        await list.refresh()
        list.writePresentation = { reply($0) }
        try await list.setOrder(["codex", "claude"])
        try await list.setMenuBarVisible("codex", false)
        let ids = ["claude", "t3code", "codex"]
        #expect(list.arranged(ids, provider: { $0 }, surface: .panel) == ["codex", "claude"])
        #expect(list.arranged(ids, provider: { $0 }, surface: .menuBar) == ["claude"])
        #expect(list.providers.map(\.id) == ["codex", "claude"])
        #expect(list.providers.allSatisfy { $0.usageConsent?.granted == false })
        let settings = SettingsStore(core: core, providerList: list)
        let panel = PanelStore(core: core, providerList: list)
        #expect(settings.providerList === panel.providerList)
    }

    @Test func trackAndPanelUseIndependentCommandsAndSavedReplies() async throws {
        let list = ProviderListStore(core: CoreModel(socketPath: "/nonexistent-u1.sock"))
        let original = try row(consent: true)
        list.readRows = { [original] }
        await list.refresh()
        var trackCalls = 0
        var panelCalls = 0
        var consentCalls = 0
        list.writeTrack = { value, on in
            trackCalls += 1
            var saved = value
            saved.enabled = on
            return saved
        }
        list.writePanel = { value, visible in
            panelCalls += 1
            var saved = value
            saved.options["panel_hidden"] = visible ? "false" : "true"
            return saved
        }
        list.writeConsent = { value, _ in consentCalls += 1; return value }
        try await list.setPanelVisible(original, false)
        #expect(list.rows[0].enabled)
        #expect(list.rows[0].usageConsent?.granted == true)
        #expect(!list.showsInPanel(list.rows[0]))
        try await list.setTracked(list.rows[0], false)
        #expect(!list.rows[0].enabled)
        #expect(!list.showsInMenuBar("claude"))
        #expect(trackCalls == 1 && panelCalls == 1 && consentCalls == 0)
        try await list.setTracked(list.rows[0], true)
        #expect(list.rows[0].options["panel_hidden"] == "true")
        #expect(consentCalls == 0)
    }

    @Test func failedSaveKeepsLastGoodChoicesAndNamesFailure() async throws {
        let list = ProviderListStore(core: CoreModel(socketPath: "/nonexistent-u1.sock"))
        list.writePresentation = { reply($0, ok: false) }
        await #expect(throws: CoreReplyError.self) { try await list.setOrder(["codex"]) }
        #expect(list.preferences.order.isEmpty)
        #expect(list.failure == "Could not save.")
        #expect(!list.writingPresentation)
    }

    @Test func lateRefreshCannotUndoTrackChange() async throws {
        let list = ProviderListStore(core: CoreModel(socketPath: "/nonexistent-u1.sock"))
        let original = try row()
        let started = TestSignal()
        var continuation: CheckedContinuation<[ProviderRow], Never>?
        list.readRows = {
            await withCheckedContinuation { value in continuation = value; started.signal() }
        }
        let refresh = Task { await list.refresh() }
        _ = await started.wait()
        list.writeTrack = { value, on in var saved = value; saved.enabled = on; return saved }
        try await list.setTracked(original, false)
        continuation?.resume(returning: [original])
        await refresh.value
        #expect(list.rows.first?.enabled == false)
    }

    @Test func echoedOlderGenerationCannotUndoSavedOrder() async throws {
        let core = CoreModel(socketPath: "/nonexistent-u1.sock")
        core.apply(.settings(CoreSettings(generation: 1, document: .object([
            "provider_display": .object(["order": .array([]), "hidden": .array([])]),
        ]))))
        let list = ProviderListStore(core: core)
        list.writePresentation = { reply($0) }
        try await list.setOrder(["codex", "claude"])
        list.synchronize()
        #expect(list.preferences.order == ["codex", "claude"])
    }

    @Test func reconnectWaitsForThisConnectionsSettingsFrame() async throws {
        let core = CoreModel(socketPath: "/nonexistent-u1.sock")
        core.apply(.hello(CoreHello(stream: "first")))
        core.apply(.settings(CoreSettings(generation: 1, document: .object([
            "provider_display": .object(["order": .array([]), "hidden": .array([])]),
        ]))))
        let list = ProviderListStore(core: core)
        list.writePresentation = { reply($0) }
        try await list.setOrder(["codex", "claude"])
        core.apply(.hello(CoreHello(stream: "second")))
        list.synchronize()
        #expect(list.preferences.order == ["codex", "claude"])
        core.apply(.settings(CoreSettings(generation: 1, document: .object([
            "provider_display": .object(["order": .array([.string("claude")]), "hidden": .array([])]),
        ]))))
        list.synchronize()
        #expect(list.preferences.order == ["claude"])
    }

    @Test func importsLegacyOnlyWhenDaemonExplicitlyHasNoPreferences() async throws {
        let core = CoreModel(socketPath: "/nonexistent-u1.sock")
        let list = ProviderListStore(core: core, legacy: .init(order: ["codex", "claude"], hidden: ["claude"]))
        var writes = 0
        let saved = TestSignal()
        list.writePresentation = { choices in writes += 1; saved.signal(); return reply(choices) }
        core.handle(.connected)
        core.apply(.settings(CoreSettings(generation: 1, document: .object(["provider_display": .null]))))
        list.synchronize()
        _ = await saved.wait()
        #expect(list.preferences == .init(order: ["codex", "claude"], hidden: ["claude"]))
        #expect(writes == 1)
    }
}
