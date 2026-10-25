import Foundation
import Testing
@testable import JRBarCore
@testable import JRBarApp

@MainActor
@Suite("Settings transfer store")
struct SettingsTransferStoreTests {
    private func makeStore(style: String? = "agents", ready: Bool = true) -> (CoreModel, SettingsStore) {
        let core = CoreModel(socketPath: NSTemporaryDirectory() + "jrbar-transfer-store-tests.sock")
        let document: JSONValue = .object(style.map { ["menu_bar_icon_style": .string($0)] } ?? [:])
        core.apply(.settings(CoreSettings(generation: 1, schema: CoreProtocol.knownSettingsSchema, document: document)))
        if ready {
            core.handle(.connected)
            core.apply(.state(CoreState()))
        }
        return (core, SettingsStore(core: core))
    }

    private func bundle() -> SettingsBundle {
        var bundle = SettingsBundle()
        bundle.monitor = ["menu_bar_icon_style": .string("orbit")]
        return bundle
    }

    @Test("empty or busy import attempts preserve the pending checklist", .timeLimit(.minutes(2)))
    func refusedImportKeepsChecklist() async throws {
        let (_, store) = makeStore()
        var draft = SettingsBundle()
        draft.appVersion = "synthetic-draft"
        draft.monitor = ["menu_bar_icon_style": .string("agents")]
        store.pendingImport = draft
        #expect(store.applyImport(draft, categories: []) == nil)
        #expect(store.pendingImport?.appVersion == draft.appVersion)
        #expect(!store.importing)

        let gate = OverviewLoadOrderTests.Gate<CoreReply>()
        store.settingWriter = { _, _ in try await gate.request() }
        let first = try #require(store.applyImport(bundle(), categories: [.monitor]))
        await gate.untilRequests(1)
        #expect(store.pendingImport == nil, "an admitted import consumes its checklist")
        store.pendingImport = draft
        #expect(store.applyImport(draft, categories: [.monitor]) == nil)
        #expect(store.pendingImport?.appVersion == draft.appVersion)
        #expect(store.pendingImport?.monitor == draft.monitor)
        #expect(store.importing)
        gate.answer(1, with: CoreReply(id: "synthetic-refusal", ok: false))
        await first.value
        #expect(!store.importing)
        #expect(store.pendingImport?.appVersion == draft.appVersion)
    }

    @Test("an offline import keeps the local icon style")
    func offlineStyleIsNotCopied() async throws {
        let (core, store) = makeStore(ready: false)
        var writes = 0
        var copied: [String] = []
        store.settingWriter = { _, _ in writes += 1; return CoreReply(id: "unexpected", ok: true) }
        store.onSetMenuBarIconStyle = { copied.append($0) }
        // A previous state does not make this connection ready.
        core.apply(.state(CoreState()))
        core.handle(.connected)
        let task = try #require(store.applyImport(bundle(), categories: [.monitor]))
        await task.value
        #expect(store.menuBarIconStyle == "agents")
        #expect(copied.isEmpty)
        #expect(writes == 0)
        #expect(store.lastError?.contains("need the monitor running") == true)
        #expect(!store.importing)
    }

    @Test("an older export imports saved scene preferences without writing scene facts")
    func oldSceneMetadataDoesNotCauseAnImportRefusal() async throws {
        let (core, store) = makeStore()
        core.apply(.settings(CoreSettings(
            generation: 2, schema: CoreProtocol.knownSettingsSchema,
            document: .object([
                "active_scene": .string("warm"),
                "scene_state": .object(["revision": .string("synthetic-current")]),
            ]))))
        let bundle = try SettingsBundle.read(Data(#"""
        {"format":"jrbar-settings","version":1,"monitor":{
          "active_scene":"calm","scene_state":{"revision":"synthetic-old","effective_scene":"focus"}
        }}
        """#.utf8))
        var written: [String] = []
        store.settingWriter = { path, value in
            written.append(path.description)
            return CoreReply(id: "synthetic-import", ok: path.description == "active_scene",
                             result: .object(["value": value]))
        }
        let task = try #require(store.applyImport(bundle, categories: [.monitor]))
        await task.value
        #expect(written == ["active_scene"])
        #expect(store.lastError == nil)
        #expect(store.status == "Imported 1 monitor settings")
        #expect(!store.importing)
    }

    @Test("a refused or normalized import keeps the local icon style", arguments: [false, true])
    func rejectedStyleIsNotCopied(normalized: Bool) async throws {
        let (_, store) = makeStore()
        var copied: [String] = []
        store.onSetMenuBarIconStyle = { copied.append($0) }
        store.settingWriter = { _, _ in
            CoreReply(id: "style", ok: normalized, result: .object(["value": .string("agents")]))
        }
        let task = try #require(store.applyImport(bundle(), categories: [.monitor]))
        await task.value
        #expect(store.menuBarIconStyle == "agents")
        #expect(copied.isEmpty)
        #expect(store.lastError?.contains("refused menu_bar_icon_style") == true)
    }

    @Test("an accepted icon import copies the local style after its write", .timeLimit(.minutes(2)))
    func acceptedStyleIsCopiedAfterReply() async throws {
        let (_, store) = makeStore()
        let gate = OverviewLoadOrderTests.Gate<CoreReply>()
        var writes: [String] = []
        var copied: [String] = []
        store.settingWriter = { path, _ in
            writes.append(path.description)
            return try await gate.request()
        }
        store.onSetMenuBarIconStyle = { copied.append($0) }
        let task = try #require(store.applyImport(bundle(), categories: [.monitor]))
        await gate.untilRequests(1)
        #expect(store.menuBarIconStyle == "agents")
        #expect(copied.isEmpty)
        gate.answer(1, with: CoreReply(id: "style", ok: true, result: .object(["value": .string("orbit")])))
        await task.value
        #expect(store.menuBarIconStyle == "orbit")
        #expect(copied == ["orbit"])
        #expect(writes == ["menu_bar_icon_style"])
        #expect(store.flush("menu_bar_icon_style") == nil, "copying the accepted value does not queue another write")
        #expect(store.lastError == nil)
        #expect(store.status == "Imported 1 monitor settings")
    }

    @Test("a live document already carrying the icon style needs no write")
    func unchangedStyleIsCopied() async throws {
        let (_, store) = makeStore(style: "orbit")
        var writes = 0
        store.settingWriter = { _, _ in writes += 1; return CoreReply(id: "unexpected", ok: true) }
        let task = try #require(store.applyImport(bundle(), categories: [.monitor]))
        await task.value
        #expect(store.menuBarIconStyle == "orbit")
        #expect(writes == 0)
        #expect(store.flush("menu_bar_icon_style") == nil)
        #expect(store.lastError == nil)
    }

    @Test("an unknown icon setting does not change the local style")
    func unknownStyleIsNotCopied() async throws {
        let (_, store) = makeStore(style: nil)
        var writes = 0
        store.settingWriter = { _, _ in writes += 1; return CoreReply(id: "unexpected", ok: true) }
        let task = try #require(store.applyImport(bundle(), categories: [.monitor]))
        await task.value
        #expect(store.menuBarIconStyle == "agents")
        #expect(writes == 0)
        #expect(store.lastError?.contains("does not know were skipped") == true)
    }

    @Test("malformed preferences report an error without applying anything")
    func malformedPreferencesAreNamed() async throws {
        let (_, store) = makeStore(ready: false)
        let hotkey = store.panelHotkeyEnabled
        var bundle = SettingsBundle()
        bundle.preferences = ["panelHotkeyEnabled": .string("invalid"), "sound.volume": .object([:])]
        let task = try #require(store.applyImport(bundle, categories: [.preferences]))
        await task.value
        #expect(store.panelHotkeyEnabled == hotkey)
        #expect(store.status == nil)
        #expect(store.lastError == "Imported 0 preferences — preferences could not be read: panelHotkeyEnabled, sound.volume")
    }
}
