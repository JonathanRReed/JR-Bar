import Foundation
import Testing
@testable import JRBarApp
@testable import JRBarCore

@MainActor
@Suite("Usage history reply order")
struct UsageHistoryLoadOrderTests {
    private func makeStore() -> UsageCenterStore {
        let core = CoreModel(socketPath: NSTemporaryDirectory() + "jrbar-usage-read-order.sock")
        core.handle(.connected)
        core.apply(.state(CoreState(usage: CoreUsage(providers: [CoreProviderUsage(id: "claude")]))))
        return UsageCenterStore(core: core)
    }

    private func history(tokens: Int, partial: Bool = false) -> UsageHistory {
        UsageHistory(provider: "claude", range: "7d",
                     days: [UsageHistoryDay(date: "2026-10-10", tokensIn: tokens)], partial: partial)
    }

    @Test("a ready refresh that is still partial retries until complete")
    func partialReadyRefreshRetries() async throws {
        let store = makeStore()
        let provider = try #require(store.providers.first)
        store.readProviderRows = { [] }
        store.readHistory = { _, _ in self.history(tokens: 100) }
        let initial = try #require(store.load(provider: provider))
        await initial.value
        store.windowDidOpen()
        defer { store.windowDidClose() }
        var retries: [@MainActor () -> Void] = []
        store.scheduleColdRetry = { retries.append($0) }
        store.readHistory = { _, _ in self.history(tokens: 200, partial: true) }
        store.core.apply(.event(CoreEvent(id: "partial-ready", kind: CoreEvent.usageHistoryReadyKind,
                                          provider: provider.id, range: store.range.rawValue)))
        store.coreDidChange()
        await waitUntil { !store.isLoading(provider) }
        #expect(store.history(for: provider)?.totalTokens == 200)
        try #require(store.isScanning(provider))
        try #require(retries.count == 1)
        var reads = 0
        store.readHistory = { _, _ in reads += 1; return self.history(tokens: 300) }
        retries.removeFirst()()
        await waitUntil { !store.isLoading(provider) }
        #expect(reads == 1)
        #expect(store.history(for: provider)?.totalTokens == 300)
        #expect(!store.isScanning(provider))
        #expect(store.error(for: provider) == nil)
    }

    @Test("failed ready refresh keeps its cached graph and retries on reopen")
    func failedReadyRefreshRetriesOnReopen() async throws {
        let store = makeStore()
        let provider = try #require(store.providers.first)
        store.readProviderRows = { [] }
        store.readHistory = { _, _ in self.history(tokens: 100) }
        let initial = try #require(store.load(provider: provider))
        await initial.value
        store.windowDidOpen()
        defer { store.windowDidClose() }
        var retries: [@MainActor () -> Void] = []
        store.scheduleColdRetry = { retries.append($0) }
        store.readHistory = { _, _ in throw CoreClientError.timeout }
        store.core.apply(.event(CoreEvent(id: "failed-ready", kind: CoreEvent.usageHistoryReadyKind,
                                          provider: provider.id, range: store.range.rawValue)))
        store.coreDidChange()
        await waitUntil { !store.isLoading(provider) }
        for _ in 0..<UsageCenterStore.coldRetries {
            try #require(store.isScanning(provider))
            try #require(!retries.isEmpty)
            retries.removeFirst()()
            await waitUntil { !store.isLoading(provider) }
        }
        #expect(!store.isScanning(provider))
        #expect(store.error(for: provider) != nil)
        #expect(store.history(for: provider)?.totalTokens == 100)
        store.windowDidClose()
        store.readHistory = { _, _ in self.history(tokens: 300) }
        store.windowDidOpen()
        await waitUntil { !store.isLoading(provider) }
        #expect(store.history(for: provider)?.totalTokens == 300)
        #expect(store.error(for: provider) == nil)
    }

    private func waitUntil(_ ready: () -> Bool) async {
        for _ in 0..<10_000 {
            if ready() { return }
            await Task.yield()
        }
        #expect(ready())
    }

    @Test("coalesced history completions read each provider and range once using the last outcome",
          arguments: [[false, false], [true, true], [false, true], [true, false]])
    func completionBurst(failures: [Bool]) async throws {
        let store = makeStore()
        let provider = try #require(store.providers.first)
        store.readProviderRows = { [] }
        store.readHistory = { _, _ in self.history(tokens: 100) }
        let initial = try #require(store.load(provider: provider))
        await initial.value
        store.windowDidOpen()
        defer { store.windowDidClose() }
        var reads: [String] = []
        store.readHistory = { _, _ in reads.append("request"); return self.history(tokens: 200) }
        store.readHistoryStatus = { _, _ in reads.append("observe"); return self.history(tokens: 200) }
        for (index, failed) in failures.enumerated() {
            store.core.apply(.event(CoreEvent(
                id: "completion-\(index)",
                kind: failed ? CoreEvent.usageHistoryFailedKind : CoreEvent.usageHistoryReadyKind,
                provider: provider.id, range: store.range.rawValue)))
        }
        store.coreDidChange()
        await waitUntil { !store.isLoading(provider) }
        #expect(reads == [failures.last == true ? "observe" : "request"])
        #expect(store.history(for: provider)?.totalTokens == 200)
    }

    @Test("wildcard completions coalesce with specific outcomes in event order", arguments: [false, true])
    func wildcardCompletionOrder(wildcardLast: Bool) async throws {
        let core = CoreModel(socketPath: NSTemporaryDirectory() + "jrbar-history-wildcard.sock")
        core.handle(.connected)
        let providers = [CoreProviderUsage(id: "claude", state: "ready"),
                         CoreProviderUsage(id: "codex", state: "ready")]
        core.apply(.state(CoreState(usage: CoreUsage(providers: providers))))
        let store = UsageCenterStore(core: core)
        store.readProviderRows = { [] }
        store.readHistory = { id, range in UsageHistory(provider: id, range: range.rawValue, records: 1) }
        for provider in providers {
            let initial = try #require(store.load(provider: provider))
            await initial.value
        }
        store.windowDidOpen()
        defer { store.windowDidClose() }
        var reads: [String] = []
        store.readHistory = { id, range in
            reads.append("\(id):request")
            return UsageHistory(provider: id, range: range.rawValue, records: 2)
        }
        store.readHistoryStatus = { id, range in
            reads.append("\(id):observe")
            return UsageHistory(provider: id, range: range.rawValue, records: 2)
        }
        let wildcard = CoreEvent(id: "wildcard", kind: CoreEvent.usageHistoryReadyKind)
        let specific = CoreEvent(id: "specific", kind: CoreEvent.usageHistoryFailedKind,
                                 provider: "claude", range: store.range.rawValue)
        for event in wildcardLast ? [specific, wildcard] : [wildcard, specific] {
            core.apply(.event(event))
        }
        store.coreDidChange()
        await waitUntil { providers.allSatisfy { !store.isLoading($0) } }
        let claudeMode = wildcardLast ? "request" : "observe"
        #expect(reads.sorted() == ["claude:\(claudeMode)", "codex:request"])
        #expect(providers.allSatisfy { store.history(for: $0)?.records == 2 })
    }

    @Test("quota resets retain their event order relative to history failures", arguments: [false, true])
    func completionAndResetOrder(resetLast: Bool) async throws {
        let store = makeStore()
        let provider = try #require(store.providers.first)
        store.readProviderRows = { [] }
        store.readHistory = { _, _ in self.history(tokens: 100) }
        let initial = try #require(store.load(provider: provider))
        await initial.value
        store.windowDidOpen()
        defer { store.windowDidClose() }
        store.readHistory = { _, _ in self.history(tokens: 300) }
        store.readHistoryStatus = { _, _ in self.history(tokens: 200) }
        let reset = CoreEvent(id: "ordered-reset", kind: "quota_reset", provider: provider.id)
        let failure = CoreEvent(id: "ordered-failure", kind: CoreEvent.usageHistoryFailedKind,
                                provider: provider.id, range: store.range.rawValue)
        for event in resetLast ? [failure, reset] : [reset, failure] { store.core.apply(.event(event)) }
        store.coreDidChange()
        await waitUntil { !store.isLoading(provider) }
        #expect(store.history(for: provider)?.totalTokens == (resetLast ? 300 : 200))
    }

    @Test("reopen reloads a completed closed-window scan and keeps unchanged caches", arguments: [false, true])
    func reopenHistory(scanCompleted: Bool) async throws {
        let store = makeStore()
        let provider = try #require(store.providers.first)
        store.readProviderRows = { [] }
        store.readHistory = { _, _ in self.history(tokens: 100) }
        let initial = try #require(store.load(provider: provider))
        await initial.value
        store.windowDidOpen()
        store.windowDidClose()
        if scanCompleted {
            store.core.apply(.event(CoreEvent(id: "closed-scan", kind: CoreEvent.usageHistoryReadyKind,
                                              provider: provider.id, range: store.range.rawValue)))
            store.coreDidChange()
        }
        var reads = 0
        store.readHistory = { _, _ in reads += 1; return self.history(tokens: 300) }
        store.windowDidOpen()
        defer { store.windowDidClose() }
        for _ in 0..<10_000 {
            if scanCompleted && reads > 0 && !store.isLoading(provider) { break }
            await Task.yield()
        }
        #expect(reads == (scanCompleted ? 1 : 0))
        #expect(store.history(for: provider)?.totalTokens == (scanCompleted ? 300 : 100))
    }

    @Test("a completed hidden range reloads when requested without disturbing the visible range")
    func readyHiddenRange() async throws {
        let store = makeStore()
        let provider = try #require(store.providers.first)
        store.readProviderRows = { [] }
        store.readHistory = { _, range in
            UsageHistory(provider: provider.id, range: range.rawValue,
                         days: [UsageHistoryDay(date: "2026-10-10", tokensIn: 100)])
        }
        let week = try #require(store.load(provider: provider, range: .week))
        await week.value
        let month = try #require(store.load(provider: provider, range: .month))
        await month.value
        store.windowDidOpen()
        defer { store.windowDidClose() }
        store.core.apply(.event(CoreEvent(id: "month-scan", kind: CoreEvent.usageHistoryReadyKind,
                                          provider: provider.id, range: UsageHistoryRange.month.rawValue)))
        store.coreDidChange()
        var requested: [UsageHistoryRange] = []
        store.readHistory = { _, range in
            requested.append(range)
            return UsageHistory(provider: provider.id, range: range.rawValue,
                                days: [UsageHistoryDay(date: "2026-10-10", tokensIn: 300)])
        }
        let refreshed = try #require(store.load(provider: provider, range: .month))
        await refreshed.value
        #expect(requested == [.month])
        #expect(store.history(for: provider)?.totalTokens == 100)
        #expect(store.histories.values.first(where: { $0.range == "30d" })?.totalTokens == 300)
    }

    @Test("an older partial scan cannot replace the completed refresh")
    func oldScanDoesNotReplaceRefresh() async throws {
        let store = makeStore()
        let provider = try #require(store.providers.first)
        let gate = UsageHistoryReadGate()
        store.readHistory = { _, _ in try await gate.read() }
        let oldTask = try #require(store.load(provider: provider))
        let didStart = await gate.waitUntilStarted()
        try #require(didStart, "Usage history read did not start")
        let fresh = history(tokens: 200)
        store.readHistory = { _, _ in fresh }
        let newTask = try #require(store.load(provider: provider, force: true))
        await newTask.value
        gate.finish(history(tokens: 100, partial: true))
        await oldTask.value
        #expect(store.history(for: provider)?.totalTokens == 200)
        #expect(!store.isLoading(provider))
        #expect(!store.isScanning(provider))
        #expect(store.error(for: provider) == nil)
    }

    @Test("an older error cannot clear the newer request's loading state")
    func oldFailureDoesNotFinishNewLoad() async throws {
        let store = makeStore()
        let provider = try #require(store.providers.first)
        let oldGate = UsageHistoryReadGate()
        store.readHistory = { _, _ in try await oldGate.read() }
        let oldTask = try #require(store.load(provider: provider))
        let oldDidStart = await oldGate.waitUntilStarted()
        try #require(oldDidStart, "Older usage history read did not start")
        let newGate = UsageHistoryReadGate()
        store.readHistory = { _, _ in try await newGate.read() }
        let newTask = try #require(store.load(provider: provider, force: true))
        let newDidStart = await newGate.waitUntilStarted()
        try #require(newDidStart, "Newer usage history read did not start")
        oldGate.fail()
        await oldTask.value
        #expect(store.isLoading(provider))
        #expect(!store.isScanning(provider))
        #expect(store.error(for: provider) == nil)
        newGate.finish(history(tokens: 300))
        await newTask.value
        #expect(store.history(for: provider)?.totalTokens == 300)
        #expect(!store.isLoading(provider))
    }

    @Test("reconnect resumes a partial scan after its offline retry was skipped")
    func reconnectResumesPartialScan() async throws {
        let store = makeStore()
        let provider = try #require(store.providers.first)
        var retries: [@MainActor () -> Void] = []
        store.scheduleColdRetry = { retries.append($0) }
        let partial = history(tokens: 100, partial: true)
        store.readHistory = { _, _ in partial }
        let firstTask = try #require(store.load(provider: provider))
        await firstTask.value
        #expect(store.isScanning(provider))
        #expect(retries.count == 1)
        store.windowDidOpen()
        defer { store.windowDidClose() }
        let initialResume = store.coreDidChange()
        for task in initialResume { await task.value }

        // A completed cached card must keep its reading on reconnect.
        let cachedProvider = CoreProviderUsage(id: "codex")
        store.core.apply(.state(CoreState(usage: CoreUsage(providers: [provider, cachedProvider]))))
        store.coreDidChange()
        let complete = UsageHistory(provider: "codex", range: "7d",
                                   days: [UsageHistoryDay(date: "2026-10-10", tokensIn: 500)])
        store.readHistory = { _, _ in complete }
        let completedTask = try #require(store.load(provider: cachedProvider, force: true))
        await completedTask.value
        store.core.handle(.disconnected(reason: "Monitor restarted"))
        store.coreDidChange()
        for retry in retries { retry() }
        #expect(store.isScanning(provider))
        #expect(!store.isLoading(provider))
        #expect(store.history(for: provider)?.totalTokens == 100)

        var requested: [String] = []
        let fresh = history(tokens: 300)
        store.readHistory = { id, _ in requested.append(id); return fresh }
        store.core.handle(.connected)
        store.core.apply(.state(CoreState(usage: CoreUsage(providers: [provider, cachedProvider]))))
        let resumed = store.coreDidChange()
        #expect(resumed.count == 1)
        for task in resumed { await task.value }
        #expect(requested == ["claude"])
        #expect(store.history(for: provider)?.totalTokens == 300)
        #expect(!store.isScanning(provider))
        #expect(!store.isLoading(provider))
        #expect(store.error(for: provider) == nil)
        #expect(store.history(for: cachedProvider)?.totalTokens == 500)
    }

    @Test("a stale or disconnected quota keeps its number without a live pace")
    func staleForecast() throws {
        let store = makeStore()
        let window = CoreUsageWindow(name: "5h", usedPct: 42, resetsAt: 1_800_003_600)
        var provider = CoreProviderUsage(id: "claude", windows: [window], state: "stale",
                                        forecast: CoreUsageForecast(exhaustsAt: 1_800_000_600, pace: "ahead"))
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let stale = UsageCenterStore.forecast(for: provider, window: window, core: store.core, now: now)
        #expect(stale.verdict == .guarded(reason: "stale_samples"))
        #expect(stale.remainingPct == 58)
        #expect(stale.rateText == nil)
        #expect(stale.projectedAtReset(now: now.timeIntervalSince1970) == nil)
        provider.state = "ready"
        store.core.handle(.disconnected(reason: "Monitor restarted"))
        let offline = UsageCenterStore.forecast(for: provider, window: window, core: store.core, now: now)
        #expect(offline.verdict == .guarded(reason: "monitor_offline"))
        #expect(offline.remainingPct == 58)
    }
}

@MainActor
private final class UsageHistoryReadGate {
    private var started = false
    private var result: CheckedContinuation<UsageHistory, Error>?

    func read() async throws -> UsageHistory {
        try await withCheckedThrowingContinuation { continuation in
            result = continuation
            started = true
        }
    }

    func waitUntilStarted() async -> Bool {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(5))
        while !started {
            guard !Task.isCancelled, clock.now < deadline else { return false }
            await Task.yield()
        }
        return !Task.isCancelled
    }

    func finish(_ history: UsageHistory) {
        result?.resume(returning: history)
        result = nil
    }

    func fail() {
        result?.resume(throwing: CoreClientError.timeout)
        result = nil
    }
}
