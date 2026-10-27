import AppKit
import SwiftUI
import Testing
@testable import JRBarApp
@testable import JRBarCore

@MainActor
@Suite("Usage Center recovery and shortcuts")
struct UsageCenterRecoveryTests {
    private func store(live: Bool = true) -> UsageCenterStore {
        let core = CoreModel(socketPath: NSTemporaryDirectory() + "jrbar-usage-recovery-\(UUID().uuidString).sock")
        if live { core.handle(.connected) }
        core.apply(.state(CoreState()))
        let store = UsageCenterStore(core: core)
        store.readProviderRows = { [] }
        return store
    }

    @Test("failed range save stays readable until its successful retry")
    func failedRangeRetry() async throws {
        let store = store()
        var expiry: (@MainActor () -> Void)?
        store.scheduleNoticeExpiry = { expiry = $0 }
        store.writeSetting = { _, _ in
            CoreReply(id: "fixture", ok: false, error: CoreReplyError(code: "busy", message: "Try again"))
        }
        let failed = try #require(store.setRange(.month))
        await failed.value
        #expect(store.notice?.text == "Range not saved: Try again.")
        #expect(store.notice?.isFailure == true)
        #expect(expiry == nil)
        store.writeSetting = { _, _ in CoreReply(id: "fixture", ok: true) }
        let retry = try #require(store.setRange(.month))
        await retry.value
        #expect(store.notice == nil)
        #expect(store.range == .month)
    }

    @Test("a successful metric save preserves an unrelated range failure")
    func unrelatedSuccess() async throws {
        let store = store()
        store.show(error: "Range could not be saved", action: .range)
        store.writeSetting = { _, _ in CoreReply(id: "fixture", ok: true) }
        let metric = try #require(store.setMetric(.cost))
        await metric.value
        #expect(store.notice?.text == "Range could not be saved")
        #expect(store.metric == .cost)
    }

    @Test("copy needs a click and dismissal removes the displayed failure")
    func copyAndDismiss() {
        let store = store()
        var copied: [String] = []
        store.copyNoticeText = { copied.append($0) }
        store.show(error: "Refresh failed: monitor offline", action: .refresh)
        #expect(copied.isEmpty)
        store.copyNotice()
        #expect(copied == ["Refresh failed: monitor offline"])
        store.dismissNotice()
        store.copyNotice()
        #expect(store.notice == nil)
        #expect(copied == ["Refresh failed: monitor offline"])
    }

    @Test("an expired success cannot clear a newer failure")
    func expiryCannotEraseFailure() throws {
        let store = store()
        var expire: (@MainActor () -> Void)?
        store.scheduleNoticeExpiry = { expire = $0 }
        store.actionSucceeded(.providerAction("fixture"), message: "Checked provider")
        #expect(store.notice?.text == "Checked provider")
        let completion = try #require(expire)
        store.show(error: "Refresh failed", action: .refresh)
        completion()
        #expect(store.notice?.text == "Refresh failed")
        #expect(store.notice?.isFailure == true)
    }

    @Test("success notices expire but another provider cannot dismiss a failure")
    func successExpiryAndIdentity() throws {
        let store = store()
        var expire: (@MainActor () -> Void)?
        store.scheduleNoticeExpiry = { expire = $0 }
        store.actionSucceeded(.providerAction("fixture"), message: "Checked provider")
        let completion = try #require(expire)
        completion()
        #expect(store.notice == nil)
        store.show(error: "Provider needs repair", action: .providerAction("fixture|one"))
        store.actionSucceeded(.providerAction("fixture|two"), message: "Checked second provider")
        #expect(store.notice?.text == "Provider needs repair")
        store.actionSucceeded(.providerAction("fixture|one"))
        #expect(store.notice == nil)
    }

    @Test("modified shortcuts write the existing range and metric settings")
    func shortcutWrites() async throws {
        let store = store()
        var writes: [(SettingsPath, JSONValue)] = []
        store.writeSetting = { path, value in
            writes.append((path, value))
            return CoreReply(id: "fixture", ok: true)
        }
        let rangeCommand = try #require(UsageCenterShortcut.resolve(key: "4", modifiers: [.command, .option], blocked: false))
        let rangeTask = try #require(rangeCommand.perform(on: store))
        await rangeTask.value
        let metricCommand = try #require(UsageCenterShortcut.resolve(key: "c", modifiers: [.command, .option], blocked: false))
        let metricTask = try #require(metricCommand.perform(on: store))
        await metricTask.value
        #expect(writes.count == 2)
        #expect(writes[0].0 == "usage_graph_days")
        #expect(writes[0].1 == .number(365))
        #expect(writes[1].0 == "usage_display_mode")
        #expect(writes[1].1 == .string("cost"))
    }

    @Test("plain letters, refresh, extra modifiers and blocked controls pass through")
    func shortcutBoundaries() {
        #expect(UsageCenterShortcut.resolve(key: "t", modifiers: [], blocked: false) == nil)
        #expect(UsageCenterShortcut.resolve(key: "r", modifiers: .command, blocked: false) == nil)
        #expect(UsageCenterShortcut.resolve(key: "2", modifiers: [.command, .option, .control], blocked: false) == nil)
        #expect(UsageCenterShortcut.resolve(key: "2", modifiers: [.command, .option, .shift], blocked: false) == .range(.month))
        #expect(UsageCenterShortcut.resolve(key: "t", modifiers: [.command, .option, .shift], blocked: false) == nil)
        #expect(UsageCenterShortcut.resolve(key: "c", modifiers: [.command, .option, .shift], blocked: false) == nil)
        #expect(UsageCenterShortcut.resolve(key: "2", modifiers: [.command, .option], blocked: true) == nil)
        #expect(UsageCenterShortcut.resolve(key: "2", modifiers: [.command, .option], blocked: false) == .range(.month))
        #expect(UsageCenterShortcutReader.ReaderView.blocksShortcuts(NSTextView()))
        #expect(UsageCenterShortcutReader.ReaderView.blocksShortcuts(NSPopUpButton()))
        #expect(!UsageCenterShortcutReader.ReaderView.blocksShortcuts(NSView()))
    }

    @Test("shortcuts cannot write while the monitor is offline")
    func offlineShortcut() {
        let store = store(live: false)
        var writes = 0
        store.writeSetting = { _, _ in
            writes += 1
            return CoreReply(id: "fixture", ok: true)
        }
        #expect(UsageCenterShortcut.range(.month).perform(on: store) == nil)
        #expect(writes == 0)
        #expect(store.range == .week)
    }

    @Test("reader dispatch consumes a live current choice and passes it through after disconnect")
    func readerDispatchUsesCurrentConnection() {
        let store = store()
        var writes = 0
        store.writeSetting = { _, _ in
            writes += 1
            return CoreReply(id: "fixture", ok: true)
        }
        let handler: (UsageCenterShortcut) -> Bool = { $0.handle(on: store) }
        #expect(UsageCenterShortcut.dispatch(key: "1", modifiers: [.command, .option],
            blocked: false, handler: handler))
        #expect(writes == 0)
        store.core.handle(.disconnected(reason: "Fixture disconnected"))
        #expect(!UsageCenterShortcut.dispatch(key: "1", modifiers: [.command, .option],
            blocked: false, handler: handler))
        #expect(writes == 0)
        #expect(store.range == .week)
    }

    @Test("reader dispatch accepts shifted digits and passes shifted letters or blocked events through")
    func readerDispatchShiftAndBlocking() {
        var commands: [UsageCenterShortcut] = []
        let handler: (UsageCenterShortcut) -> Bool = { commands.append($0); return true }
        #expect(UsageCenterShortcut.dispatch(key: "2", modifiers: [.command, .option, .shift],
            blocked: false, handler: handler))
        #expect(!UsageCenterShortcut.dispatch(key: "T", modifiers: [.command, .option, .shift],
            blocked: false, handler: handler))
        #expect(!UsageCenterShortcut.dispatch(key: "C", modifiers: [.command, .option, .shift],
            blocked: false, handler: handler))
        #expect(!UsageCenterShortcut.dispatch(key: "2", modifiers: [.command, .option],
            blocked: true, handler: handler))
        #expect(commands == [.range(.month)])
        #expect(!UsageCenterShortcut.dispatch(key: "2", modifiers: [.command, .option],
            blocked: false, handler: { _ in false }))
    }
    @Test(.enabled(if: WindowsRenderProofTests.enabled))
    func persistentFailureRenderProof() throws {
        let store = store()
        store.show(error: "Refresh failed: The monitor did not answer. The last readings remain visible. Try Refresh again when the monitor reconnects.", action: .refresh)
        let notice = try #require(store.notice)
        try WindowsRenderProofTests.write("usage-center-persistent-failure", size: CGSize(width: 640, height: 160)) {
            UsageCenterNoticeView(notice: notice, copy: {}, dismiss: {})
                .padding(24)
        }
    }

    @Test("another consent profile or browser cannot clear a failed revocation")
    func exactConsentRetry() async throws {
        let store = store()
        func consent(browser: String, profile: String) throws -> ProviderConsentRow {
            let value: [String: Any] = ["browser": browser, "profile": profile,
                "domains": [], "fields": [], "background_repair": false,
                "granted_at": 0, "source_instance_id": "default"]
            let data = try JSONSerialization.data(withJSONObject: value)
            return try JSONDecoder().decode(ProviderConsentRow.self, from: data)
        }
        let first = try consent(browser: "fixture-browser", profile: "profile-a")
        let second = try consent(browser: "fixture-browser", profile: "profile-b")
        let otherBrowser = try consent(browser: "other-browser", profile: "profile-a")
        var requests: [UsageCenterStore.ConsentRevocation] = []
        store.revokeProviderConsent = { request in
            requests.append(request)
            return CoreReply(id: "fixture", ok: false,
                error: CoreReplyError(code: "busy", message: "First consent needs retry"))
        }
        await store.revokeConsent(providerID: "fixture", consent: first).value
        #expect(store.notice?.text == "First consent needs retry")
        store.revokeProviderConsent = { request in
            requests.append(request)
            return CoreReply(id: "fixture", ok: true)
        }
        await store.revokeConsent(providerID: "fixture", consent: second).value
        #expect(store.notice?.text == "First consent needs retry")
        await store.revokeConsent(providerID: "fixture", consent: otherBrowser).value
        #expect(store.notice?.text == "First consent needs retry")
        await store.revokeConsent(providerID: "fixture", consent: first).value
        #expect(store.notice == nil)
        #expect(requests == [
            .init(provider: "fixture", instance: nil, browser: "fixture-browser", profile: "profile-a"),
            .init(provider: "fixture", instance: nil, browser: "fixture-browser", profile: "profile-b"),
            .init(provider: "fixture", instance: nil, browser: "other-browser", profile: "profile-a"),
            .init(provider: "fixture", instance: nil, browser: "fixture-browser", profile: "profile-a")
        ])
    }

}
