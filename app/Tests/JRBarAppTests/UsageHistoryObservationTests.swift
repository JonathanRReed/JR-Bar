import Foundation
import Testing
@testable import JRBarApp
@testable import JRBarCore

@MainActor
@Suite("Usage history failure observations", .serialized)
struct UsageHistoryObservationTests {
    private static let message = "Local history could not be refreshed. Try again."

    private func makeStore() -> UsageCenterStore {
        let core = CoreModel(socketPath: NSTemporaryDirectory() + "jrbar-history-observation-\(UUID().uuidString).sock")
        core.handle(.connected)
        core.apply(.state(CoreState(usage: CoreUsage(providers: [CoreProviderUsage(id: "claude")]))))
        let store = UsageCenterStore(core: core)
        store.readProviderRows = { [] }
        return store
    }

    private func history(_ tokens: Int, range: UsageHistoryRange = .week, partial: Bool = false) -> UsageHistory {
        let formatter = DateFormatter()
        formatter.calendar = .current
        formatter.timeZone = Calendar.current.timeZone
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        let day = formatter.string(from: Date())
        return UsageHistory(provider: "claude", range: range.rawValue,
                            days: tokens == 0 ? [] : [UsageHistoryDay(date: day, tokensIn: tokens)],
                            records: tokens == 0 ? 0 : 1, partial: partial)
    }

    private func completed(_ store: UsageCenterStore, failed: Bool, id: String,
                           range: UsageHistoryRange = .week) {
        let kind = failed ? CoreEvent.usageHistoryFailedKind : CoreEvent.usageHistoryReadyKind
        store.core.apply(.event(CoreEvent(id: id, kind: kind, provider: "claude", range: range.rawValue)))
        store.coreDidChange()
    }

    private func until(_ predicate: () -> Bool) async throws {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(5))
        while !predicate(), clock.now < deadline, !Task.isCancelled { await Task.yield() }
        try #require(predicate(), "Expected history transition did not complete")
    }

    @Test("a later cold or cached scan failure is observed without another scan", arguments: [false, true])
    func asynchronousFailure(cached: Bool) async throws {
        let store = makeStore()
        let provider = try #require(store.providers.first)
        var normalReads = 0
        var observedReads = 0
        var retries: [@MainActor () -> Void] = []
        store.scheduleColdRetry = { retries.append($0) }
        store.readHistory = { _, _ in
            normalReads += 1
            return self.history(cached ? 100 : 0, partial: !cached)
        }
        store.readHistoryStatus = { _, _ in
            observedReads += 1
            throw CoreReplyError(code: "unavailable", message: Self.message)
        }
        store.windowDidOpen()
        defer { store.windowDidClose() }
        try await until { store.history(for: provider) != nil && !store.isLoading(provider) }
        let originalRetries = retries.count
        completed(store, failed: true, id: "synthetic-failed")
        try await until { store.error(for: provider) == Self.message && !store.isLoading(provider) }
        #expect(normalReads == 1 && observedReads == 1)
        #expect(store.history(for: provider)?.totalTokens == (cached ? 100 : 0))
        #expect(!store.isScanning(provider))
        #expect(!store.hasNoLocalRecords(provider))
        #expect(retries.count == originalRetries)
        for retry in retries { retry() }
        store.readHistory = { _, _ in
            normalReads += 1
            return self.history(300)
        }
        let retry = try #require(store.load(provider: provider, force: true))
        await retry.value
        #expect(normalReads == 2)
        #expect(store.history(for: provider)?.totalTokens == 300)
        #expect(store.error(for: provider) == nil)
    }

    @Test("a failure event before the initial reply owns the error")
    func failureBeforePendingReply() async throws {
        let store = makeStore()
        let provider = try #require(store.providers.first)
        let gate = HistoryObservationGate()
        defer { gate.finish(history(0, partial: true)) }
        store.readHistory = { _, _ in try await gate.read() }
        store.readHistoryStatus = { _, _ in throw CoreReplyError(code: "unavailable", message: Self.message) }
        var retries = 0
        store.scheduleColdRetry = { _ in retries += 1 }
        let original = try #require(store.load(provider: provider))
        store.windowDidOpen()
        defer { store.windowDidClose() }
        try await until { gate.started }
        completed(store, failed: true, id: "synthetic-before-reply")
        try await until { store.error(for: provider) == Self.message }
        gate.finish(history(0, partial: true))
        await original.value
        #expect(store.history(for: provider) == nil)
        #expect(store.error(for: provider) == Self.message)
        #expect(!store.isScanning(provider) && !store.isLoading(provider))
        #expect(retries == 0)
    }

    @Test("a delayed failure event reads newer success instead of installing an old error")
    func delayedFailureAfterSuccess() async throws {
        let store = makeStore()
        let provider = try #require(store.providers.first)
        let current = history(300)
        store.readHistory = { _, _ in current }
        var observations = 0
        store.readHistoryStatus = { _, _ in observations += 1; return current }
        store.windowDidOpen()
        defer { store.windowDidClose() }
        try await until { store.history(for: provider) == current }
        completed(store, failed: true, id: "synthetic-old-failure")
        try await until { observations == 1 && !store.isLoading(provider) }
        #expect(store.history(for: provider) == current)
        #expect(store.error(for: provider) == nil)
        #expect(store.load(provider: provider) == nil)
    }

    @Test("an older observation cannot replace an explicit newer reading")
    func olderObservationAfterRetry() async throws {
        let store = makeStore()
        let provider = try #require(store.providers.first)
        store.readHistory = { _, _ in self.history(100) }
        store.windowDidOpen()
        defer { store.windowDidClose() }
        try await until { store.history(for: provider)?.totalTokens == 100 }
        let gate = HistoryObservationGate()
        defer { gate.fail() }
        store.readHistoryStatus = { _, _ in try await gate.read() }
        completed(store, failed: true, id: "synthetic-old-observation")
        try await until { gate.started }
        store.readHistory = { _, _ in self.history(300) }
        let retry = try #require(store.load(provider: provider, force: true))
        await retry.value
        gate.fail()
        for _ in 0..<10 { await Task.yield() }
        #expect(store.history(for: provider)?.totalTokens == 300)
        #expect(store.error(for: provider) == nil)
        #expect(!store.isLoading(provider))
    }

    @Test("a failure event can observe a newer scan still running without retrying it")
    func failureDuringNewerScan() async throws {
        let store = makeStore()
        let provider = try #require(store.providers.first)
        store.readHistory = { _, _ in self.history(100) }
        store.windowDidOpen()
        defer { store.windowDidClose() }
        try await until { store.history(for: provider)?.totalTokens == 100 }
        let gate = HistoryObservationGate()
        defer { gate.finish(history(0, partial: true)) }
        store.readHistory = { _, _ in try await gate.read() }
        let retry = try #require(store.load(provider: provider, force: true))
        try await until { gate.started }
        var observed = false
        var automaticRetries = 0
        store.scheduleColdRetry = { _ in automaticRetries += 1 }
        store.readHistoryStatus = { _, _ in observed = true; return self.history(100, partial: true) }
        completed(store, failed: true, id: "synthetic-prior-scan-failure")
        try await until { observed && !store.isLoading(provider) }
        #expect(store.error(for: provider) == nil)
        #expect(store.isScanning(provider))
        #expect(automaticRetries == 0)
        store.readHistory = { _, _ in self.history(300) }
        completed(store, failed: false, id: "synthetic-current-scan-ready")
        try await until { store.history(for: provider)?.totalTokens == 300 }
        gate.finish(history(200))
        await retry.value
        #expect(store.history(for: provider)?.totalTokens == 300)
        #expect(!store.isScanning(provider))
    }

    @Test("closed and off-range failures invalidate their next reading", arguments: [false, true])
    func hiddenFailure(closed: Bool) async throws {
        let store = makeStore()
        let provider = try #require(store.providers.first)
        let range: UsageHistoryRange = closed ? .week : .month
        var reads = 0
        var observations = 0
        store.readHistory = { _, requested in reads += 1; return self.history(reads * 100, range: requested) }
        store.readHistoryStatus = { _, requested in observations += 1; return self.history(0, range: requested) }
        let initial = try #require(store.load(provider: provider, range: range))
        await initial.value
        store.windowDidOpen()
        defer { store.windowDidClose() }
        try await until { store.history(for: provider) != nil && !store.isLoading(provider) }
        if closed { store.windowDidClose() }
        completed(store, failed: true, id: "synthetic-hidden-failure", range: range)
        let before = reads
        let fresh = try #require(store.load(provider: provider, range: range))
        await fresh.value
        #expect(reads == before + 1 && observations == 0)
        let retained = store.histories.values.first { $0.range == range.rawValue }
        #expect(retained?.totalTokens == reads * 100)
    }

    @Test("an unfinished empty history keeps the panel's last sparkline until completion")
    func pendingSparklineRetainsItsReading() async throws {
        let core = CoreModel(socketPath: NSTemporaryDirectory() + "jrbar-sparkline-observation-fixture.sock")
        core.handle(.connected)
        let provider = CoreProviderUsage(id: "claude", windows: [CoreUsageWindow(name: "5h", usedPct: 40)])
        core.apply(.state(CoreState(usage: CoreUsage(providers: [provider]))))
        let defaults = try #require(UserDefaults(suiteName: ScratchDefaults.suiteName("jrbar.history.observation")))
        let panel = PanelStore(core: core, draftsDefaults: defaults, screenBarShown: false)
        var calls = 0
        var current = history(100)
        panel.fetchUsageHistory = { _, _ in calls += 1; return current }
        panel.refreshSparklines(force: true)
        try await until { panel.sparkline(for: "claude") != nil }
        let previous = panel.sparkline(for: "claude")
        current = history(0, partial: true)
        panel.refreshSparklines(force: true)
        try await until { calls == 2 }
        for _ in 0..<10 { await Task.yield() }
        #expect(panel.sparkline(for: "claude") == previous)
        current = history(0)
        panel.refreshSparklines(force: true)
        try await until { calls == 3 && panel.sparkline(for: "claude") == nil }
    }
}

@MainActor
private final class HistoryObservationGate {
    private(set) var started = false
    private var continuation: CheckedContinuation<UsageHistory, Error>?

    func read() async throws -> UsageHistory {
        try await withCheckedThrowingContinuation { continuation in
            self.continuation = continuation
            started = true
        }
    }

    func finish(_ history: UsageHistory) {
        continuation?.resume(returning: history)
        continuation = nil
    }

    func fail() {
        continuation?.resume(throwing: CoreReplyError(code: "unavailable", message: "Synthetic failed observation"))
        continuation = nil
    }
}
