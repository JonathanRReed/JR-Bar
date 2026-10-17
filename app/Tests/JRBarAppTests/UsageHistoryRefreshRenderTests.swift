import AppKit
import Foundation
import SwiftUI
import Testing
@testable import JRBarApp
@testable import JRBarCore

@MainActor
@Suite("Usage history refresh presentation", .serialized)
struct UsageHistoryRefreshRenderTests {
    enum Fixture: String, CaseIterable {
        case refreshing, empty, paddedEmpty, offline, offlineEmpty
        case partial, freshEmpty, costOnly, zeroTokenRecord, failure
    }

    @Test(.enabled(if: WindowsRenderProofTests.enabled), arguments: Fixture.allCases)
    func previousReading(fixture: Fixture) async throws {
        let core = CoreModel(socketPath: NSTemporaryDirectory() + "jrbar-history-refresh-render.sock")
        core.handle(.connected)
        let provider = CoreProviderUsage(id: "claude", state: "ready")
        core.apply(.state(CoreState(usage: CoreUsage(providers: [provider]))))
        let store = UsageCenterStore(core: core)
        store.now = Date(timeIntervalSince1970: 1_800_000_000)
        let emptyRows = fixture == .empty || fixture == .offlineEmpty || fixture == .freshEmpty
        let zeroRows = fixture == .paddedEmpty || fixture == .zeroTokenRecord || fixture == .costOnly
        let emptyReading = emptyRows || fixture == .paddedEmpty
        let row: [String: Any] = ["date": "2026-10-10", "tokens_in": zeroRows ? 0 : 100,
                                 "cost_usd": fixture == .costOnly ? 1.25 : 0]
        let fields: [String: Any] = [
            "provider": "claude", "range": "7d", "stale": fixture != .freshEmpty,
            "partial": fixture == .partial, "reading_files": fixture == .partial ? 2 : 0,
            "records": emptyReading ? 0 : 1, "days": emptyRows ? [] : [row],
        ]
        let data = try JSONSerialization.data(withJSONObject: fields)
        let history = try JSONDecoder().decode(UsageHistory.self, from: data)
        var retries = 0
        store.scheduleColdRetry = { _ in retries += 1 }
        store.readHistory = { _, _ in history }
        let loaded = try #require(store.load(provider: provider))
        await loaded.value
        #expect(store.history(for: provider) == history)
        #expect(store.isScanning(provider) == (fixture == .partial))
        #expect(store.hasNoLocalRecords(provider) == (fixture == .freshEmpty))
        if fixture != .partial { #expect(retries == 0) }
        if fixture == .failure {
            store.readHistory = { _, _ in
                throw CoreReplyError(code: "unavailable", message: "Local history could not be refreshed. Try again.")
            }
            let failed = try #require(store.load(provider: provider, force: true))
            await failed.value
            #expect(store.error(for: provider) != nil)
            #expect(store.history(for: provider) == history)
        }
        if fixture == .offline || fixture == .offlineEmpty {
            core.handle(.disconnected(reason: "Synthetic disconnect"))
            #expect(!store.isLive)
        }
        let width: CGFloat = fixture == .refreshing || fixture == .costOnly ? 760 : 520
        try WindowsRenderProofTests.write("usage-history-refresh-\(fixture.rawValue)",
                                         size: CGSize(width: width, height: 800)) {
            ProviderUsageCard(provider: provider, store: store).padding(24)
        }
    }
}
