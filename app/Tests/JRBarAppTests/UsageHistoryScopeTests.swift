import JRBarTestSupport
import Foundation
import SwiftUI
import Testing
@testable import JRBarApp
@testable import JRBarCore

@MainActor
@Suite("Provider-wide local history", .serialized, .renderProofAppearance)
struct UsageHistoryScopeTests {
    private func provider(_ instance: String? = nil) -> CoreProviderUsage {
        var row = CoreProviderUsage(id: "claude", state: "ready")
        row.instance = instance
        return row
    }

    private func store(_ rows: [CoreProviderUsage]) -> UsageCenterStore {
        let core = CoreModel(socketPath: NSTemporaryDirectory() + "jrbar-history-scope.sock")
        core.handle(.connected)
        core.apply(.state(CoreState(usage: CoreUsage(providers: rows))))
        return UsageCenterStore(core: core)
    }

    private var localHistory: UsageHistory {
        UsageHistory(provider: "claude", range: "7d",
                     days: [UsageHistoryDay(date: "2026-10-10", tokensIn: 250, costUsd: 0.5)])
    }

    @Test("two account cards load one provider history and preserve it when its owner changes")
    func oneHistory() async throws {
        let local = provider()
        let work = provider("work")
        let model = store([work, local])
        var reads: [String] = []
        model.readHistory = { id, _ in
            reads.append(id)
            return localHistory
        }
        #expect(model.historyProviders.map(\.identity) == ["claude"])
        #expect(model.load(provider: work) == nil)
        let task = try #require(model.load(provider: local))
        await task.value
        #expect(reads == ["claude"])
        #expect(model.history(for: local)?.totalTokens == 250)
        #expect(model.history(for: work) == nil)
        model.core.apply(.state(CoreState(usage: CoreUsage(providers: [work]))))
        model.coreDidChange()
        #expect(model.ownsLocalHistory(work))
        #expect(model.history(for: work)?.totalTokens == 250)
        #expect(reads == ["claude"])
    }

    @Test("named-only accounts keep local history without duplicating it")
    func namedOnly() async throws {
        let work = provider("work")
        let personal = provider("personal")
        let model = store([work, personal])
        model.readHistory = { _, _ in localHistory }
        #expect(model.historyProviders.map(\.identity) == ["claude|work"])
        let task = try #require(model.load(provider: work))
        await task.value
        #expect(model.history(for: work)?.totalCost == 0.5)
        #expect(model.history(for: personal) == nil)
        #expect(model.load(provider: personal, force: true) == nil)
    }

    @Test("Factory quota cards do not request unsupported local token history")
    func factoryHasNoLocalHistory() {
        var factory = CoreProviderUsage(id: "factory", state: "ready")
        factory.instance = "work"
        let claude = provider()
        let model = store([factory, claude])
        #expect(!model.supportsLocalHistory(factory))
        #expect(model.historyProviders.map(\.id) == ["claude"])
        #expect(model.load(provider: factory, force: true) == nil)
        #expect(model.history(for: factory) == nil)
    }

    static func factoryUsageFixture() throws -> CoreUsage {
        let data = Data("""
        {"refreshed_at":1800000000,"providers":[{
          "id":"factory","state":"ready","fidelity":"official","quota_source":true,
          "read_at":1799999970,"observed_at":1800000000,
          "windows":[
            {"id":"standard-5h","name":"Standard 5-hour","used_pct":12,"resets_at":1800007200},
            {"id":"standard-7d","name":"Standard 7-day","used_pct":68,"resets_at":1800432000},
            {"id":"standard-30d","name":"Standard Monthly","used_pct":31,"resets_at":1801728000},
            {"id":"core-5h","name":"Core 5-hour","used_pct":7,"resets_at":1800007200,"bindable":false},
            {"id":"core-7d","name":"Core 7-day","used_pct":54,"resets_at":1800432000,"bindable":false},
            {"id":"core-30d","name":"Core Monthly","used_pct":22,"resets_at":1801728000,"bindable":false}
          ]
        }]}
        """.utf8)
        return try JSONDecoder().decode(CoreUsage.self, from: data)
    }

    @Test("a decoded Factory snapshot reaches the quota card without local history")
    func factoryQuotaSnapshot() throws {
        let usage = try Self.factoryUsageFixture()
        let core = CoreModel(socketPath: NSTemporaryDirectory() + "jrbar-factory-quota-flow.sock")
        core.handle(.connected)
        core.apply(.state(CoreState(usage: usage)))
        let model = UsageCenterStore(core: core)
        let factory = try #require(model.providers.first)
        #expect(model.isLive)
        #expect(model.providers.count == 1)
        #expect(factory.id == "factory")
        #expect(!factory.isSignedOut)
        #expect(!factory.usageIsOff)
        #expect(factory.windows.map(\.usedPct) == [12, 68, 31, 7, 54, 22])
        #expect(factory.windows.map(\.key) == ["standard-5h", "standard-7d", "standard-30d", "core-5h", "core-7d", "core-30d"])
        #expect(Set(factory.windows.map(\.id)).count == 6)
        #expect(UsageSourceNotes.ringWindows(factory.windows).count == 6)
        #expect(UsageSourceNotes.detailWindows(factory.windows).isEmpty)
        #expect(UsageCenterStore.featuredWindow(of: factory) != nil)
        #expect(model.historyProviders.isEmpty)
        #expect(model.load(provider: factory, force: true) == nil)
    }

    @Test("hub accounts never borrow this Mac's transcript history")
    func hubOnly() {
        let hub = provider("cliproxy:fixture")
        let model = store([hub])
        #expect(model.historyProviders.isEmpty)
        #expect(model.load(provider: hub) == nil)
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["JRBAR_RENDER_PROOF"] == "1"))
    func accountScopeCards() async throws {
        let local = provider()
        let work = provider("work")
        let model = store([local, work])
        model.readHistory = { _, _ in localHistory }
        let task = try #require(model.load(provider: local))
        await task.value
        let view = VStack(spacing: 12) {
            UsageProviderDetail(provider: local, store: model, showCost: true)
            UsageProviderDetail(provider: work, store: model, showCost: true)
        }
        .padding(16)
        .frame(width: 720)
        .background(Color(nsColor: .windowBackgroundColor))
        try ProofRender.write(view, size: CGSize(width: 720, height: 850), name: "history-two-accounts")
    }
}
