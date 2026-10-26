@testable import JRBarCore
import Testing
@testable import JRBarApp

@MainActor
@Suite("Settings fix round", .serialized)
struct SettingsFixRoundTests {
    private func liveStore() -> SettingsStore {
        let core = CoreModel(socketPath: "/nonexistent-settings-fix.sock")
        core.handle(.connected)
        core.apply(.state(CoreState()))
        return SettingsStore(core: core)
    }

    @Test func cancellingRemovalSendsNothingAndConfirmationSendsOnce() async throws {
        let store = liveStore()
        var removals: [[String]] = []
        store.hookRemover = { providers in
            removals.append(providers)
            return CoreReply(id: "removed", ok: true)
        }
        store.requestIntegrationRemoval("codex")
        #expect(store.pendingIntegrationRemoval == "codex")
        #expect(removals.isEmpty)
        store.cancelIntegrationRemoval()
        #expect(store.confirmIntegrationRemoval() == nil)
        #expect(removals.isEmpty)
        store.requestIntegrationRemoval("claude")
        let task = try #require(store.confirmIntegrationRemoval())
        #expect(store.confirmIntegrationRemoval() == nil)
        await task.value
        #expect(removals == [["claude"]])
        #expect(store.pendingIntegrationRemoval == nil)
    }

    @Test func providerResetUsesOwnersAndKeepsConsent() async throws {
        let store = liveStore()
        store.core.apply(.settings(CoreSettings(generation: 1, schema: CoreProtocol.knownSettingsSchema,
            document: .object(["provider_display": .object(["order": .array([]), "hidden": .array([])])]))))
        let fixture = ProviderListStoreTests()
        let initial = try fixture.row("codex", enabled: false, consent: false, hidden: true)
        store.providerList.readRows = { [initial] }
        var commands: [String] = []
        store.pageResetter = { _ in commands.append("reset_settings"); return CoreReply(id: "reset", ok: true) }
        store.providerList.writeTrack = { row, on in
            commands.append("track:\(row.id):\(on)")
            var saved = row; saved.enabled = on; return saved
        }
        store.providerList.writePanel = { row, on in
            commands.append("panel:\(row.id):\(on)")
            #expect(row.enabled)
            var saved = row; saved.options["panel_hidden"] = "false"; return saved
        }
        store.providerList.writeConsent = { row, _ in commands.append("consent"); return row }
        store.providerList.writePresentation = { choices in
            commands.append("provider_display")
            return fixture.reply(choices)
        }
        let task = try #require(store.resetPage(.agents))
        await task.value
        #expect(commands == ["reset_settings", "track:codex:true", "panel:codex:true", "provider_display"])
        #expect(store.providerList.rows.first?.enabled == true)
        #expect(store.providerList.rows.first?.options["panel_hidden"] == "false")
        #expect(store.providerList.rows.first?.usageConsent?.granted == false)
        #expect(SettingsStore.resetMessage(for: .agents).contains("Usage consent stays"))
    }

    @Test func awakeIndicatorOpensTheKeepAwakeSubpage() {
        let settings = liveStore()
        let panel = PanelStore(core: settings.core)
        var closed = false
        panel.onClose = { closed = true }
        panel.onOpenKeepAwake = { settings.openKeepAwakeSettings() }
        settings.page = .alerts
        panel.openKeepAwakeSettings()
        #expect(closed)
        #expect(settings.page == .utilities)
        #expect(settings.subpage == "keepAwake")
    }

    @Test func providerFailureRetryRefreshesTheSharedList() async throws {
        let store = liveStore()
        let list = store.providerList
        var reads = 0
        list.readRows = { reads += 1; throw CoreReplyError(code: "unavailable", message: "Synthetic failure") }
        await list.refresh()
        #expect(list.failure == "Synthetic failure")
        let expected = try ProviderListStoreTests().row()
        list.readRows = { reads += 1; return [expected] }
        await SettingsProviderFailureBanner(list: list).retry()
        #expect(reads == 2)
        #expect(list.failure == nil)
        #expect(list.providers == [expected])
    }

    @Test func pageNoticeUsesOnePrecedence() {
        let store = liveStore()
        store.searchHit = SettingsSearchEntry(.devices, "Devices", "Brightness")
        store.report(error: "Synthetic failure")
        #expect(SettingsPageNotice.notice(store: store, page: .devices) == .failure("Synthetic failure"))
        store.core.apply(.settings(CoreSettings(generation: 1, schema: CoreProtocol.knownSettingsSchema + 1, document: .object([:]))))
        #expect(SettingsPageNotice.notice(store: store, page: .devices) == .schema(CoreProtocol.knownSettingsSchema + 1))
        store.core.handle(.disconnected(reason: "Synthetic disconnect"))
        #expect(SettingsPageNotice.notice(store: store, page: .devices) == .offline)
    }

    @Test func clickBehaviorSearchOpensProviderDetails() async throws {
        let store = liveStore()
        let provider = try ProviderListStoreTests().row("codex")
        store.providerList.readRows = { [provider] }
        await store.providerList.refresh()
        let entry = try #require(SettingsSearch.rows.first { $0.title == "Clicks Open" })
        store.reveal(entry)
        #expect(store.page == .agents)
        #expect(store.selectedProvider == "codex")
    }

    @Test func dotRoleSearchOpensTheStudioDevicesPage() throws {
        let store = liveStore()
        var opened = 0
        store.onOpenStudioDevices = { opened += 1 }
        let role = try #require(SettingsSearch.rows.first { $0.title == "Role" })
        store.reveal(role)
        #expect(opened == 1)
    }

    @Test func remoteResetLeavesAlertsAndPhoneAlone() {
        let document = SettingsDocument(.object([:]))
        let remote = SettingsStore.Page.remote.resetPaths(in: document)
        let alerts = SettingsStore.Page.alerts.resetPaths(in: document)
        for key in ["escalation_webhook_url", "webhook_events", "ntfy_enabled", "ntfy_topic", "ntfy_only_when_away"] {
            #expect(!remote.contains(key))
            #expect(alerts.contains(key))
        }
    }
}
