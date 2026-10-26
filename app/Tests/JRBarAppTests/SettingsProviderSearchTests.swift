import Foundation
import SwiftUI
import Testing
@testable import JRBarApp
@testable import JRBarCore

@MainActor
@Suite("Provider settings discovery", .serialized)
struct SettingsProviderSearchTests {
    private func connectedCore() -> CoreModel {
        let core = CoreModel(socketPath: NSTemporaryDirectory() + "jrbar-provider-search-\(UUID().uuidString).sock")
        core.handle(.connected)
        core.apply(.state(CoreState()))
        #expect(core.isLive)
        return core
    }

    private func row(on: Bool) throws -> ProviderRow {
        let json = "{\"id\":\"factory\",\"instance\":\"default\",\"label\":\"Factory\",\"enabled\":true,\"usage_consent\":{\"granted\":\(on),\"version\":1,\"question\":\"Show Factory usage?\",\"detail\":\"Uses a saved API key for subscription usage.\"}}"
        return try JSONDecoder().decode(ProviderRow.self, from: Data(json.utf8))
    }

    private func until(_ predicate: () -> Bool) async throws {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(5))
        while !predicate(), clock.now < deadline, !Task.isCancelled { await Task.yield() }
        try #require(predicate(), "Provider metadata did not reach its expected state")
    }

    @Test("Factory can be found before metadata loads or while offline", arguments: ["Factory", "Factory API key"])
    func factoryFallbackRoutesToUsage(query: String) throws {
        let settings = SettingsStore(core: CoreModel(socketPath: NSTemporaryDirectory() + "jrbar-search-offline.sock"))
        let matches = SettingsSearch.search(query, in: settings.searchEntries)
        let hit = try #require(matches.first { $0.chapter == .usage && $0.group == "Provider usage" })
        settings.reveal(hit)
        #expect(settings.page == .agents)
        #expect(settings.searchHit == hit)
        #expect(!settings.isLive)
    }

    @Test("a provider list started before a consent write cannot overwrite its accepted row")
    func oldListCannotUndoConsent() async throws {
        let core = connectedCore()
        let model = ProviderUsageSwitchesModel()
        let before = try row(on: false), after = try row(on: true)
        model.readRows = { _ in [before] }
        model.refresh(core: core)
        try await until { !model.loading && model.switchRows.count == 1 }
        let gate = ProviderSearchReadGate()
        defer { gate.failAll() }
        model.readRows = { _ in try await gate.read() }
        model.refresh(core: core)
        try await until { gate.count == 1 }
        model.readRows = { _ in [after] }
        model.writeConsent = { _, _, _ in after }
        model.set(before, on: true, core: core)
        try await until { model.busy.isEmpty && model.switchRows.first?.usageConsent?.granted == true }
        gate.release([before])
        try await until { !model.loading }
        #expect(model.switchRows.first?.usageConsent?.granted == true)
    }

    @Test("a refresh requested during an older list is serviced after it finishes")
    func pendingRefreshIsNotDropped() async throws {
        let core = connectedCore()
        let model = ProviderUsageSwitchesModel()
        let before = try row(on: false), after = try row(on: true)
        let gate = ProviderSearchReadGate()
        defer { gate.failAll() }
        model.readRows = { _ in try await gate.read() }
        model.refresh(core: core)
        try await until { gate.count == 1 }
        model.readRows = { _ in [after] }
        model.refresh(core: core)
        gate.release([before])
        try await until { !model.loading }
        #expect(model.switchRows.first?.usageConsent?.granted == true)
    }

    @Test("search reuses actual default-provider controls without starting a read or write")
    func metadataRowsAreSharedAndSearchIsReadOnly() async throws {
        let core = connectedCore()
        let settings = SettingsStore(core: core)
        let factory = try row(on: false)
        var named = factory
        named.instance = "secondary"
        var grok = factory
        grok.id = "grok"
        grok.label = "Grok"
        var reads = 0
        var writes = 0
        settings.providerList.readRows = { reads += 1; return [factory, named, grok] }
        settings.providerList.writeConsent = { _, _ in writes += 1; return factory }
        await settings.providerList.refresh()
        #expect(settings.providerList.providers.count == 2)
        let entry = try #require(SettingsSearch.search("Factory API key", in: settings.searchEntries).first)
        #expect(entry.title == "Factory API key")
        #expect(entry.chapter == .usage && entry.group == "Provider usage")
        #expect(settings.searchEntries.filter { $0.title == "Factory API key" }.count == 1)
        #expect(SettingsSearch.search("Show Grok usage", in: settings.searchEntries).first?.title == "Show Grok usage")
        #expect(!settings.searchEntries.contains { $0.title == "Show T3 Code usage" })
        let planned = try #require(SettingsSearch.search("copilot", in: settings.searchEntries).first)
        #expect(planned.title == "Coming soon" && planned.chapter == .usage)
        #expect(planned.group == "Coming soon")
        #expect(!settings.searchEntries.contains { $0.title == "Show Copilot usage" })
        settings.reveal(planned)
        #expect(settings.page == .agents && settings.searchHit?.title == "Coming soon")
        for _ in 0..<10 { _ = SettingsSearch.search("factory", in: settings.searchEntries) }
        #expect(reads == 1 && writes == 0)
        settings.providerUsage.setActive(false, core: core)
    }

    @Test("an inactive Settings model starts no provider inspection for search")
    func inactiveSearchDoesNotInspectCredentials() {
        let core = connectedCore()
        let settings = SettingsStore(core: core)
        var reads = 0
        settings.providerUsage.readRows = { _ in reads += 1; return [] }
        settings.providerUsage.refresh(core: core)
        _ = SettingsSearch.search("Factory API key", in: settings.searchEntries)
        #expect(reads == 0 && !settings.providerUsage.loading)
    }

    @Test("closing or covering Settings retires the old list and reopening owns the new one")
    func retiredListCannotReplaceReopenedSettings() async throws {
        let core = connectedCore()
        let model = ProviderUsageSwitchesModel()
        let before = try row(on: false), after = try row(on: true)
        let gate = ProviderSearchReadGate()
        defer { gate.failAll() }
        model.readRows = { _ in try await gate.read() }
        let retired = try #require(model.refresh(core: core))
        try await until { gate.count == 1 }
        model.setActive(false, core: core)
        #expect(retired.isCancelled && !model.loading)
        model.readRows = { _ in [after] }
        model.setActive(true, core: core)
        try await until { !model.loading && model.switchRows.first?.usageConsent?.granted == true }
        gate.release([before])
        await retired.value
        #expect(model.switchRows.first?.usageConsent?.granted == true)
        #expect(!model.loading)
        model.setActive(false, core: core)
    }

    @Test("a failed provider list says so and a read-only retry replaces it")
    func listFailureCanRetry() async throws {
        let core = connectedCore()
        let model = ProviderUsageSwitchesModel()
        model.readRows = { _ in throw CoreReplyError(code: "unavailable", message: "Synthetic refusal") }
        let failed = try #require(model.refresh(core: core))
        await failed.value
        #expect(model.loadFailure == "Provider controls could not be loaded. Try again.")
        #expect(!model.loading && model.switchRows.isEmpty)
        let expected = try row(on: false)
        model.readRows = { _ in [expected] }
        let recovered = try #require(model.refresh(core: core))
        await recovered.value
        #expect(model.loadFailure == nil && model.switchRows == [expected])
    }

    @Test(.enabled(if: WindowsRenderProofTests.enabled))
    func searchAndRetryRenderProof() async throws {
        let core = connectedCore()
        let settings = SettingsStore(core: core)
        settings.page = .agents
        let expected = try row(on: false)
        settings.providerUsage.readRows = { _ in [expected] }
        settings.providerUsage.setActive(true, core: core)
        try await until { !settings.providerUsage.loading && settings.providerUsage.switchRows.count == 1 }
        settings.searchQuery = "Factory API key"
        settings.settleSearch()
        try WindowsRenderProofTests.write("provider-search-factory", size: CGSize(width: 400, height: 320)) {
            List { SettingsSearchResults(store: settings) }
                .listStyle(.sidebar)
        }
        settings.providerUsage.readRows = { _ in throw CoreClientError.notConnected }
        let failed = try #require(settings.providerUsage.refresh(core: core))
        await failed.value
        try WindowsRenderProofTests.write("provider-search-retry", size: CGSize(width: 560, height: 520)) {
            Form { ProviderUsageSwitchesGroup(store: settings, model: settings.providerUsage) }
                .formStyle(.grouped)
        }
        settings.providerUsage.setActive(false, core: core)
    }
}

@MainActor
private final class ProviderSearchReadGate {
    private var pending: [CheckedContinuation<[ProviderRow], Error>] = []
    var count: Int { pending.count }

    func read() async throws -> [ProviderRow] {
        try await withCheckedThrowingContinuation { pending.append($0) }
    }

    func release(_ rows: [ProviderRow]) {
        guard !pending.isEmpty else { return }
        pending.removeFirst().resume(returning: rows)
    }

    func failAll() {
        let values = pending
        pending.removeAll()
        for value in values { value.resume(throwing: CoreClientError.notConnected) }
    }
}
