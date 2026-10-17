import Foundation
import Testing
@testable import JRBarApp
@testable import JRBarCore

@MainActor
@Suite("Provider inspection reply order")
struct ProviderInspectionOrderTests {
    private func store() -> UsageCenterStore {
        let core = CoreModel(socketPath: NSTemporaryDirectory() + "jrbar-provider-order-\(UUID().uuidString).sock")
        core.handle(.connected)
        core.apply(.hello(CoreHello(pid: 41)))
        core.apply(.state(CoreState()))
        return UsageCenterStore(core: core)
    }

    private func row(_ label: String) throws -> ProviderRow {
        try JSONDecoder().decode(ProviderRow.self, from: Data(#"{"id":"claude","label":"\#(label)"}"#.utf8))
    }

    @Test("a late older inspection cannot replace a newer provider row")
    func newerReadWins() async throws {
        let store = store()
        let gate = ProviderReadGate()
        defer { gate.finish([]) }
        store.readProviderRows = { try await gate.read() }
        let old = try #require(store.loadProviderRows())
        let started = await gate.waitUntilStarted()
        try #require(started)
        let fresh = try row("Current")
        store.readProviderRows = { [fresh] }
        let next = try #require(store.loadProviderRows())
        await next.value
        gate.finish([try row("Old")])
        await old.value
        #expect(store.row(for: "claude")?.label == "Current")
    }

    @Test("a reply arriving after disconnect cannot restore cleared inspection rows")
    func disconnectRetiresRead() async throws {
        let store = store()
        store.readProviderRows = { [] }
        store.coreDidChange()
        let gate = ProviderReadGate()
        defer { gate.finish([]) }
        store.readProviderRows = { try await gate.read() }
        let task = try #require(store.loadProviderRows())
        let started = await gate.waitUntilStarted()
        try #require(started)
        store.core.handle(.disconnected(reason: "fixture"))
        store.coreDidChange()
        gate.finish([try row("Old")])
        await task.value
        #expect(store.row(for: "claude") == nil)
    }

    @Test("a changed daemon hello retires a read even if liveness is already restored")
    func newPeerRetiresRead() async throws {
        let store = store()
        let gate = ProviderReadGate()
        defer { gate.finish([]) }
        store.readProviderRows = { try await gate.read() }
        let task = try #require(store.loadProviderRows())
        let started = await gate.waitUntilStarted()
        try #require(started)
        store.core.apply(.hello(CoreHello(pid: 42)))
        store.core.apply(.state(CoreState()))
        gate.finish([try row("Old")])
        await task.value
        #expect(store.row(for: "claude") == nil)
    }
}

@MainActor
private final class ProviderReadGate {
    private var started = false
    private var continuation: CheckedContinuation<[ProviderRow], Error>?

    func read() async throws -> [ProviderRow] {
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

    func finish(_ rows: [ProviderRow]) {
        continuation?.resume(returning: rows)
        continuation = nil
    }
}
