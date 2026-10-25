import Foundation
import Testing
import JRBarCore
@testable import JRBarApp

@MainActor
@Suite("Overview export snapshots")
struct OverviewExportLoadTests {
    private typealias Gate = OverviewLoadOrderTests.Gate<CoreReply>

    private func bundle(_ marker: String) -> CoreReply {
        CoreReply(id: "fixture-export", ok: true, result: .object([
            "document": .object(["marker": .string(marker)]),
            "text": .string("# \(marker)\n"),
        ]))
    }

    @Test("both export formats come from one daemon snapshot")
    func oneSnapshot() async throws {
        let store = OverviewStore(core: CoreModel())
        var requests: [[String: JSONValue]] = []
        store.fetchAuditExport = { args in
            requests.append(args)
            return bundle("snapshot-\(requests.count)")
        }
        await store.prepareExport(everything: true)
        #expect(requests.count == 1)
        #expect(requests.first?["format"]?.stringValue == "markdown")
        #expect(requests.first?["ids"] == nil)
        let preview = try #require(store.exportPreview)
        #expect(preview.document["marker"]?.stringValue == "snapshot-1")
        #expect(preview.markdown == "# snapshot-1\n")
    }

    @Test("an older export cannot overwrite the newer scope", .timeLimit(.minutes(10)))
    func latestExportWins() async {
        let gate = Gate()
        let store = OverviewStore(core: CoreModel())
        store.fetchAuditExport = { _ in try await gate.request() }
        let first = Task { await store.prepareExport() }
        await gate.untilRequests(1)
        let second = Task { await store.prepareExport(everything: true) }
        await gate.untilRequests(2)
        gate.answer(2, with: bundle("newer"))
        await second.value
        gate.answer(1, with: bundle("older"))
        await first.value
        #expect(store.exportPreview?.document["marker"]?.stringValue == "newer")
        #expect(store.exportPreview?.markdown == "# newer\n")
    }

    @Test("a failed newer export cannot revive a previous preview", .timeLimit(.minutes(10)))
    func failureDoesNotShowAnOlderScope() async {
        let gate = Gate()
        let store = OverviewStore(core: CoreModel())
        store.exportPreview = (.object(["marker": .string("previous")]), "# previous\n")
        store.fetchAuditExport = { _ in try await gate.request() }
        let first = Task { await store.prepareExport() }
        await gate.untilRequests(1)
        #expect(store.exportPreview == nil)
        let second = Task { await store.prepareExport(everything: true) }
        await gate.untilRequests(2)
        gate.fail(2, with: CoreClientError.disconnected)
        await second.value
        let failure = store.error
        #expect(failure != nil)
        gate.answer(1, with: bundle("older"))
        await first.value
        #expect(store.exportPreview == nil && store.error == failure)
    }

    @Test("malformed export replies cannot become blank saved files", arguments: [
        JSONValue.object(["document": .object([:])]),
        .object(["text": .string("# fixture\n")]),
        .object(["document": .string("wrong type"), "text": .string("# fixture\n")]),
    ])
    func malformedBundle(result: JSONValue) async {
        let store = OverviewStore(core: CoreModel())
        store.fetchAuditExport = { _ in CoreReply(id: "fixture", ok: true, result: result) }
        await store.prepareExport()
        #expect(store.exportPreview == nil)
        #expect(store.error != nil)
    }

    @Test("cancelled export tasks do not publish a late reply", .timeLimit(.minutes(10)))
    func cancelledExportDoesNotPublish() async {
        let gate = Gate()
        let store = OverviewStore(core: CoreModel())
        store.fetchAuditExport = { _ in try await gate.request() }
        let request = Task { await store.prepareExport() }
        await gate.untilRequests(1)
        request.cancel()
        gate.answer(1, with: bundle("cancelled"))
        await request.value
        #expect(store.exportPreview == nil && store.error == nil)
    }
}
