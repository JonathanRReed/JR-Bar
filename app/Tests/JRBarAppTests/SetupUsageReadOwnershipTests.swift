import JRBarTestSupport
import Foundation
import SwiftUI
import Testing
@testable import JRBarApp

@MainActor
@Suite("Setup usage read ownership", .serialized, .renderProofAppearance)
struct SetupUsageReadOwnershipTests {
    @MainActor
    private final class Gate<Value: Sendable> {
        private var pending: [Int: CheckedContinuation<Value, Error>] = [:]
        private(set) var calls = 0

        func read() async throws -> Value {
            calls += 1
            let call = calls
            return try await withCheckedThrowingContinuation { pending[call] = $0 }
        }

        func answer(_ call: Int, _ value: Value) {
            pending.removeValue(forKey: call)?.resume(returning: value)
        }

        func finish() {
            let held = Array(pending.values)
            pending.removeAll()
            for continuation in held { continuation.resume(throwing: CancellationError()) }
        }
    }

    private func offer(on: Bool, summary: String = "Synthetic usage choices.") -> SetupUsageOffer {
        SetupUsageOffer(id: "claude", name: "Claude", question: "Show Claude usage?",
                        summary: summary, isOn: on)
    }

    private func until(_ predicate: () -> Bool) async throws {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(5))
        while !predicate(), clock.now < deadline, !Task.isCancelled { await Task.yield() }
        try #require(predicate(), "Synthetic Setup request did not start")
    }

    @Test("an admitted consent action retires metadata loading before the old reply returns",
          arguments: [false, true])
    func admissionRetiresLoading(on: Bool) async throws {
        let reads = Gate<[SetupUsageOffer]>()
        let writes = Gate<SetupNote>()
        defer { reads.finish(); writes.finish() }
        let before = offer(on: !on)
        var model = SetupModel()
        model.monitorLive = { true }
        model.usageOffers = { [before] }
        model.setUsage = { _, _ in
            (try? await writes.read()) ?? SetupNote("Synthetic refusal", isError: true)
        }
        let store = SetupStore(model: model, load: { SetupState() }, persist: { _ in })
        await store.refreshUsageOffers()
        store.model.usageOffers = { try await reads.read() }
        let oldRead = Task { await store.refreshUsageOffers() }
        try await until { reads.calls == 1 }
        #expect(store.loadingUsageOffers)

        let requested = on ? store.turnOnUsage(for: "claude") : store.turnOffUsage(for: "claude")
        let write = try #require(requested)
        #expect(!store.loadingUsageOffers, "The retired read no longer owns the loading message")
        #expect(store.usageBusy == ["claude"])
        try await until { writes.calls == 1 }
        writes.answer(1, SetupNote("Synthetic saved", isError: false))
        await write.value
        #expect(!store.loadingUsageOffers, "Consent settled while the retired metadata read is still held")
        #expect(store.usageOffer(for: "claude")?.isOn == on)

        reads.answer(1, [before])
        await oldRead.value
        #expect(store.usageOffer(for: "claude")?.isOn == on)
        #expect(!store.loadingUsageOffers)
    }

    @Test("consent completion retires a read started during the write and leaves later retry ownership intact",
          arguments: [false, true])
    func completionRetiresLoading(accepted: Bool) async throws {
        let reads = Gate<[SetupUsageOffer]>()
        let writes = Gate<SetupNote>()
        defer { reads.finish(); writes.finish() }
        let before = offer(on: false)
        var model = SetupModel()
        model.monitorLive = { true }
        model.usageOffers = { [before] }
        model.setUsage = { _, _ in
            (try? await writes.read()) ?? SetupNote("Synthetic refusal", isError: true)
        }
        let store = SetupStore(model: model, load: { SetupState() }, persist: { _ in })
        await store.refreshUsageOffers()
        let write = try #require(store.turnOnUsage(for: "claude"))
        try await until { writes.calls == 1 }
        store.model.usageOffers = { try await reads.read() }
        let superseded = Task { await store.refreshUsageOffers() }
        try await until { reads.calls == 1 }
        #expect(store.loadingUsageOffers)
        let result = SetupNote(accepted ? "Synthetic saved" : "Synthetic refusal", isError: !accepted)
        writes.answer(1, result)
        await write.value
        #expect(!store.loadingUsageOffers, "The write retired the pending metadata reply")
        #expect(store.usageBusy.isEmpty)
        #expect(store.usageOffer(for: "claude")?.isOn == accepted)
        #expect(store.usageNotes["claude"] == (accepted ? nil : result))

        let retry = Task { await store.refreshUsageOffers() }
        try await until { reads.calls == 2 }
        #expect(store.loadingUsageOffers)
        reads.answer(1, [before])
        await superseded.value
        #expect(store.loadingUsageOffers, "Old cleanup must not settle the newer retry")
        #expect(store.usageNotes["claude"] == (accepted ? nil : result))
        let current = offer(on: accepted, summary: "Fresh synthetic choices.")
        reads.answer(2, [current])
        await retry.value
        #expect(store.usageOffers == [current])
        #expect(!store.loadingUsageOffers)
    }

    @Test("an offline action does not retire a current metadata read")
    func offlineActionKeepsLoading() async throws {
        let reads = Gate<[SetupUsageOffer]>()
        defer { reads.finish() }
        var writes = 0
        var model = SetupModel()
        model.monitorLive = { false }
        model.usageOffers = { try await reads.read() }
        model.setUsage = { _, _ in writes += 1; return SetupNote("Unexpected write", isError: true) }
        let store = SetupStore(model: model, load: { SetupState() }, persist: { _ in })
        let read = Task { await store.refreshUsageOffers() }
        try await until { reads.calls == 1 }
        #expect(store.turnOnUsage(for: "claude") == nil)
        #expect(store.loadingUsageOffers)
        reads.answer(1, [offer(on: false)])
        await read.value
        #expect(!store.loadingUsageOffers)
        #expect(writes == 0)
    }

    @Test("a duplicate action does not retire a read while the admitted write is held")
    func duplicateActionKeepsLoading() async throws {
        let reads = Gate<[SetupUsageOffer]>()
        let writes = Gate<SetupNote>()
        defer { reads.finish(); writes.finish() }
        var model = SetupModel()
        model.monitorLive = { true }
        model.usageOffers = { try await reads.read() }
        model.setUsage = { _, _ in
            (try? await writes.read()) ?? SetupNote("Synthetic refusal", isError: true)
        }
        let store = SetupStore(model: model, load: { SetupState() }, persist: { _ in })
        let write = try #require(store.turnOnUsage(for: "claude"))
        try await until { writes.calls == 1 }
        let read = Task { await store.refreshUsageOffers() }
        try await until { reads.calls == 1 }
        #expect(store.turnOffUsage(for: "claude") == nil)
        #expect(store.loadingUsageOffers)
        writes.answer(1, SetupNote("Synthetic saved", isError: false))
        await write.value
        reads.answer(1, [offer(on: false)])
        await read.value
        #expect(writes.calls == 1)
    }

    @Test(.enabled(if: WindowsRenderProofTests.enabled), arguments: [false, true])
    func settledConsentRenderProof(accepted: Bool) async throws {
        let reads = Gate<[SetupUsageOffer]>()
        defer { reads.finish() }
        let before = offer(on: false)
        let result = SetupNote("Synthetic consent refused. Try again.", isError: true)
        var model = SetupModel()
        model.monitorLive = { true }
        model.agents = { [SetupAgent(id: "claude", name: "Claude", detected: true, hookStatus: "ok")] }
        model.usageOffers = { [before] }
        model.setUsage = { _, _ in accepted ? SetupNote("Synthetic saved", isError: false) : result }
        let store = SetupStore(model: model, load: { SetupState() }, persist: { _ in })
        await store.refreshUsageOffers()
        store.model.usageOffers = { try await reads.read() }
        let oldRead = Task { await store.refreshUsageOffers() }
        try await until { reads.calls == 1 }
        #expect(store.loadingUsageOffers)
        let state = accepted ? "saved" : "refused"
        let readingProof = Result<Void, Error> {
            try render("setup-consent-\(state)-reading", store: store)
        }
        let write = try #require(store.turnOnUsage(for: "claude"))
        await write.value
        #expect(!store.loadingUsageOffers)
        #expect(store.usageOffer(for: "claude")?.isOn == accepted)
        #expect(store.usageNotes["claude"] == (accepted ? nil : result))
        let settledProof = Result<Void, Error> {
            try render("setup-consent-\(state)-settled", store: store)
        }
        reads.answer(1, [before])
        await oldRead.value
        try readingProof.get()
        try settledProof.get()
    }

    private func render(_ name: String, store: SetupStore) throws {
        try WindowsRenderProofTests.write(name, size: CGSize(width: 560, height: 390)) {
            VStack(alignment: .leading, spacing: 14) {
                Text("Connect your agents").font(.title2.weight(.semibold)).padding(.horizontal, 24)
                SetupAgentsStep(store: store)
            }.padding(.vertical, 24)
        }
    }
}
