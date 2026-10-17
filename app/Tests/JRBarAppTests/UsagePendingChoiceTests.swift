import Foundation
import Testing
@testable import JRBarApp
@testable import JRBarCore

@MainActor
@Suite("Usage pending choices")
struct UsagePendingChoiceTests {
    private func store() -> UsageCenterStore {
        let core = CoreModel(socketPath: NSTemporaryDirectory() + "jrbar-choice-\(UUID().uuidString).sock")
        core.handle(.connected)
        core.apply(.state(CoreState()))
        let store = UsageCenterStore(core: core)
        store.readProviderRows = { [] }
        push(store, generation: 1)
        return store
    }

    private func push(_ store: UsageCenterStore, generation: Int, days: Int = 7, metric: String = "tokens") {
        store.core.apply(.settings(CoreSettings(generation: generation, schema: CoreProtocol.knownSettingsSchema,
            document: .object(["usage_graph_days": .number(Double(days)), "usage_display_mode": .string(metric)]))))
        store.coreDidChange()
    }

    private func accepted(_ generation: Int? = nil) -> CoreReply {
        CoreReply(id: "fixture", ok: true,
            result: generation.map { .object(["generation": .number(Double($0))]) })
    }

    @Test("unrelated pushes cannot retire a range before its save is acknowledged")
    func rangeWaitsForItsGeneration() async throws {
        let store = store()
        let gate = SettingWriteGate()
        defer { gate.finish(accepted()) }
        store.writeSetting = { _, _ in try await gate.write() }
        let task = try #require(store.setRange(.month))
        try #require(await gate.waitUntilStarted())
        push(store, generation: 2)
        #expect(store.range == .month)
        gate.finish(accepted(3))
        await task.value
        #expect(store.range == .month)
        push(store, generation: 3, days: 30)
        #expect(store.range == .month)
        push(store, generation: 4, days: 90)
        #expect(store.range == .quarter)
    }

    @Test("a push received before its acknowledgement settles after the reply")
    func pushBeforeReply() async throws {
        let store = store()
        let gate = SettingWriteGate()
        defer { gate.finish(accepted()) }
        store.writeSetting = { _, _ in try await gate.write() }
        let task = try #require(store.setMetric(.cost))
        try #require(await gate.waitUntilStarted())
        push(store, generation: 2, metric: "cost")
        gate.finish(accepted(2))
        await task.value
        push(store, generation: 3)
        #expect(store.metric == .tokens)
    }

    @Test("an older range failure cannot clear a newer choice or show its error")
    func olderRangeFailure() async throws {
        let store = store()
        let oldGate = SettingWriteGate()
        let newGate = SettingWriteGate()
        defer { oldGate.finish(accepted()); newGate.finish(accepted()) }
        store.writeSetting = { _, _ in try await oldGate.write() }
        let old = try #require(store.setRange(.month))
        try #require(await oldGate.waitUntilStarted())
        store.writeSetting = { _, _ in try await newGate.write() }
        let next = try #require(store.setRange(.quarter))
        try #require(await newGate.waitUntilStarted())
        oldGate.fail()
        await old.value
        push(store, generation: 2, days: 30)
        #expect(store.range == .quarter)
        #expect(store.lastError == nil)
        newGate.finish(accepted(3))
        await next.value
        push(store, generation: 3, days: 90)
        push(store, generation: 4, days: 365)
        #expect(store.range == .year)
    }

    @Test("an older refused metric save cannot undo a rapid toggle back")
    func olderMetricRefusal() async throws {
        let store = store()
        let oldGate = SettingWriteGate()
        let newGate = SettingWriteGate()
        defer { oldGate.finish(accepted()); newGate.finish(accepted()) }
        store.writeSetting = { _, _ in try await oldGate.write() }
        let old = try #require(store.setMetric(.cost))
        try #require(await oldGate.waitUntilStarted())
        store.writeSetting = { _, _ in try await newGate.write() }
        let next = try #require(store.setMetric(.tokens))
        try #require(await newGate.waitUntilStarted())
        push(store, generation: 2)
        oldGate.finish(CoreReply(id: "old", ok: false, error: CoreReplyError(code: "busy")))
        await old.value
        push(store, generation: 3, metric: "cost")
        #expect(store.metric == .tokens)
        #expect(store.lastError == nil)
        newGate.finish(accepted(4))
        await next.value
        push(store, generation: 4)
        push(store, generation: 5, metric: "cost")
        #expect(store.metric == .cost)
    }

    @Test("a current failed range save restores the confirmed range and names the failure")
    func currentFailure() async throws {
        let store = store()
        store.writeSetting = { _, _ in throw CoreClientError.timeout }
        let task = try #require(store.setRange(.month))
        await task.value
        #expect(store.range == .week)
        #expect(store.lastError?.hasPrefix("Range not saved:") == true)
    }

    @Test("a thrown range save loads the confirmed range pushed while the choice was pending")
    func failedRangeLoadsPushedConfirmedHistory() async throws {
        let store = store()
        let provider = CoreProviderUsage(id: "claude", state: "ready")
        store.core.apply(.state(CoreState(usage: CoreUsage(providers: [provider]))))
        var requestedRanges: [UsageHistoryRange] = []
        store.readHistory = { provider, range in
            requestedRanges.append(range)
            return UsageHistory(provider: provider, range: range.rawValue, days: [])
        }
        store.windowDidOpen()
        defer { store.windowDidClose() }
        let gate = SettingWriteGate()
        defer { gate.finish(accepted()) }
        store.writeSetting = { _, _ in try await gate.write() }
        let task = try #require(store.setRange(.month))
        try #require(await gate.waitUntilStarted())
        push(store, generation: 2, days: 90)
        #expect(store.range == .month)
        #expect(!requestedRanges.contains(.quarter))

        gate.fail()
        await task.value
        #expect(store.range == .quarter)
        #expect(store.lastError?.hasPrefix("Range not saved:") == true)
        try #require(store.isLoading(provider) || store.history(for: provider) != nil)
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(5))
        while store.history(for: provider) == nil, clock.now < deadline {
            await Task.yield()
        }
        #expect(requestedRanges.contains(.quarter))
        #expect(store.history(for: provider)?.range == UsageHistoryRange.quarter.rawValue)
    }

    @Test("replies without a generation wait for a matching settings value")
    func legacyReply() async throws {
        let store = store()
        store.writeSetting = { _, _ in accepted() }
        let task = try #require(store.setMetric(.cost))
        await task.value
        push(store, generation: 2)
        #expect(store.metric == .cost)
        push(store, generation: 3, metric: "cost")
        push(store, generation: 4)
        #expect(store.metric == .tokens)
    }
}

@MainActor
private final class SettingWriteGate {
    private var continuation: CheckedContinuation<CoreReply, Error>?
    private var started = false

    func write() async throws -> CoreReply {
        try await withCheckedThrowingContinuation {
            continuation = $0
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
        return true
    }

    func finish(_ reply: CoreReply) {
        continuation?.resume(returning: reply)
        continuation = nil
    }

    func fail() {
        continuation?.resume(throwing: CoreClientError.timeout)
        continuation = nil
    }
}
