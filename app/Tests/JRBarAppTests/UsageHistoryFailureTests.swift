import JRBarTestSupport
import AppKit
import SwiftUI
import Testing
@testable import JRBarApp
@testable import JRBarCore

@MainActor
@Suite("Usage history failed refresh", .serialized, .renderProofAppearance)
struct UsageHistoryFailureTests {
    static let message = "Local history could not be refreshed. Try again."

    private func fixture(cachedRecords: Int?) async throws -> (UsageCenterStore, CoreProviderUsage) {
        let provider = CoreProviderUsage(id: "codex", windows: [CoreUsageWindow(name: "5h", usedPct: 42)],
                                         fidelity: "official", state: "ready", observedAt: 1_800_000_000)
        let core = CoreModel(socketPath: NSTemporaryDirectory() + "jrbar-history-failure-\(UUID().uuidString).sock")
        core.handle(.connected)
        core.apply(.state(CoreState(usage: CoreUsage(providers: [provider]))))
        let store = UsageCenterStore(core: core)
        store.readProviderRows = { [] }
        if let cachedRecords {
            let days = cachedRecords == 0 ? [] : (4...10).map { day in
                UsageHistoryDay(date: String(format: "2026-10-%02d", day),
                                tokensIn: day == 10 ? 100 : 0, tokensOut: day == 10 ? 20 : 0)
            }
            let history = UsageHistory(provider: "codex", range: "7d", days: days, records: cachedRecords)
            store.readHistory = { _, _ in history }
            let initial = try #require(store.load(provider: provider))
            await initial.value
        }
        store.readHistory = { _, _ in throw CoreReplyError(code: "unavailable", message: Self.message) }
        let failed = try #require(store.load(provider: provider, force: true))
        await failed.value
        return (store, provider)
    }

    @Test("failed cold or retained readings stay retryable without claiming a new empty scan",
           arguments: [nil, 0, 1] as [Int?])
    func failedReadRetainsDataAndRetries(cachedRecords: Int?) async throws {
        let (store, provider) = try await fixture(cachedRecords: cachedRecords)
        #expect(store.error(for: provider) == Self.message)
        #expect(!store.isScanning(provider))
        #expect(!store.isLoading(provider))
        #expect(!store.hasNoLocalRecords(provider))
        #expect(store.history(for: provider)?.records == cachedRecords)
        if cachedRecords == 1 { #expect(store.history(for: provider)?.totalTokens == 120) }
        var reads = 0
        store.readHistory = { _, _ in
            reads += 1
            return UsageHistory(provider: "codex", range: "7d",
                                days: [UsageHistoryDay(date: "2026-10-10", tokensIn: 300)], records: 1)
        }
        let retry = try #require(store.load(provider: provider, force: true))
        await retry.value
        #expect(reads == 1)
        #expect(store.error(for: provider) == nil)
        #expect(store.history(for: provider)?.totalTokens == 300)
    }

    @Test("an explicit failed ready refresh stops automatic retries and keeps its chart")
    func failedReadyReplyIsShownImmediately() async throws {
        let (store, provider) = try await fixture(cachedRecords: 1)
        store.readHistory = { _, _ in
            UsageHistory(provider: "codex", range: "7d",
                         days: [UsageHistoryDay(date: "2026-10-10", tokensIn: 120)], records: 1)
        }
        let recovered = try #require(store.load(provider: provider, force: true))
        await recovered.value
        store.windowDidOpen()
        defer { store.windowDidClose() }
        var retries: [@MainActor () -> Void] = []
        store.scheduleColdRetry = { retries.append($0) }
        store.readHistory = { _, _ in throw CoreReplyError(code: "unavailable", message: Self.message) }
        store.core.apply(.event(CoreEvent(id: "synthetic-failed-refresh", kind: CoreEvent.usageHistoryReadyKind,
                                         provider: provider.id, range: store.range.rawValue)))
        store.coreDidChange()
        for _ in 0..<10_000 {
            if !store.isLoading(provider) { break }
            await Task.yield()
        }
        #expect(!store.isLoading(provider))
        #expect(!store.isScanning(provider))
        #expect(retries.isEmpty)
        #expect(store.error(for: provider) == Self.message)
        #expect(store.history(for: provider)?.totalTokens == 120)
    }

    @Test(.enabled(if: WindowsRenderProofTests.enabled))
    func failedHistoryCards() async throws {
        let application = NSApplication.shared
        let previousAppearance = application.appearance
        defer { application.appearance = previousAppearance }
        for cachedRecords in [nil, 0, 1] as [Int?] {
            let (store, provider) = try await fixture(cachedRecords: cachedRecords)
            for dark in [false, true] {
                application.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
                for width in [CGFloat(520), CGFloat(760)] {
                    let card = UsageProviderDetail(provider: provider, store: store, showCost: true).padding(24)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                        .background(Color(nsColor: .windowBackgroundColor))
                    let bitmap = try SettingsRenderProofTests.snapshot(card, size: CGSize(width: width, height: 980), dark: dark)
                    let name = cachedRecords.map { "cached-\($0)" } ?? "cold"
                    let directory = SettingsRenderProofTests.directory
                    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                    let png = try #require(bitmap.representation(using: .png, properties: [:]))
                    let filename = "usage-history-failure-\(name)-\(Int(width))-\(dark ? "dark" : "light").png"
                    try png.write(to: directory.appendingPathComponent(filename))
                }
            }
        }
    }
}
