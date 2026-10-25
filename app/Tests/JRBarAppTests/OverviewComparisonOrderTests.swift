import Foundation
import JRBarCore
import Testing
@testable import JRBarApp

@Suite("Overview comparison ownership")
@MainActor
struct OverviewComparisonOrderTests {
    private typealias Gate = OverviewLoadOrderTests.Gate<CoreRunComparison>
    private struct Refused: Error {}

    private func makeStore(_ gate: Gate) throws -> OverviewStore {
        let store = OverviewStore(core: CoreModel())
        let json = #"{"sessions":[{"id":"claude:a","provider":"claude","mode":"working"},{"id":"claude:b","provider":"claude","mode":"working"},{"id":"claude:c","provider":"claude","mode":"working"}],"counts":{"total":3}}"#
        store.roster = try JSONDecoder().decode(CoreRoster.self, from: Data(json.utf8)).sessions
        store.filter = OverviewFilter(preset: .all)
        store.selectedIDs = ["claude:a", "claude:b"]
        store.fetchComparison = { _, _ in try await gate.request() }
        return store
    }

    private func reply(_ id: String) throws -> CoreRunComparison {
        let json = #"{"a":{"id":"\#(id)"},"b":{"id":"baseline"},"shared":{"provider":true,"workspace":true}}"#
        return try JSONDecoder().decode(CoreRunComparison.self, from: Data(json.utf8))
    }

    @Test("a late older comparison cannot replace the newer pair", .timeLimit(.minutes(2)))
    func newerReplyWins() async throws {
        let gate = Gate()
        let store = try makeStore(gate)
        let older = try #require(store.compareSelected())
        await gate.untilRequests(1)
        store.selectedIDs = ["claude:b", "claude:c"]
        let newer = try #require(store.compareSelected())
        await gate.untilRequests(2)
        gate.answer(2, with: try reply("newer"))
        await newer.value
        gate.answer(1, with: try reply("older"))
        await older.value
        #expect(store.comparison?.a.id == "newer")
        #expect(!store.comparing)
    }

    @Test("an older completion does not clear the newer busy state", .timeLimit(.minutes(2)))
    func newerRequestKeepsBusy() async throws {
        let gate = Gate()
        let store = try makeStore(gate)
        let older = try #require(store.compareSelected())
        await gate.untilRequests(1)
        store.selectedIDs = ["claude:b", "claude:c"]
        let newer = try #require(store.compareSelected())
        await gate.untilRequests(2)
        gate.answer(1, with: try reply("older"))
        await older.value
        #expect(store.comparing)
        #expect(store.comparison == nil)
        gate.answer(2, with: try reply("newer"))
        await newer.value
        #expect(store.comparison?.a.id == "newer")
        #expect(!store.comparing)
    }

    @Test("an older failure does not replace a newer success with an error", .timeLimit(.minutes(2)))
    func olderFailureIsIgnored() async throws {
        let gate = Gate()
        let store = try makeStore(gate)
        let older = try #require(store.compareSelected())
        await gate.untilRequests(1)
        let newer = try #require(store.compareSelected())
        await gate.untilRequests(2)
        gate.answer(2, with: try reply("newer"))
        await newer.value
        gate.fail(1, with: Refused())
        await older.value
        #expect(store.error == nil)
        #expect(store.comparison?.a.id == "newer")
    }

    @Test("close retires pending success and failure replies", .timeLimit(.minutes(2)))
    func closedWindowIgnoresReplies() async throws {
        for fails in [false, true] {
            let gate = Gate()
            let store = try makeStore(gate)
            let task = try #require(store.compareSelected())
            await gate.untilRequests(1)
            store.windowDidClose()
            #expect(!store.comparing)
            if fails { gate.fail(1, with: Refused()) }
            else { gate.answer(1, with: try reply("closed")) }
            await task.value
            #expect(store.comparison == nil)
            #expect(store.error == nil)
            #expect(!store.comparing)
        }
    }

    @Test("the current request still reports a failure", .timeLimit(.minutes(2)))
    func currentFailureIsVisible() async throws {
        let gate = Gate()
        let store = try makeStore(gate)
        let task = try #require(store.compareSelected())
        await gate.untilRequests(1)
        gate.fail(1, with: Refused())
        await task.value
        #expect(store.error != nil)
        #expect(!store.comparing)
    }

    @Test("selection changes do not cancel the explicitly requested pair", .timeLimit(.minutes(2)))
    func selectionChangePreservesRequest() async throws {
        let gate = Gate()
        let store = try makeStore(gate)
        let task = try #require(store.compareSelected())
        await gate.untilRequests(1)
        store.selectedIDs = ["claude:c"]
        gate.answer(1, with: try reply("requested"))
        await task.value
        #expect(store.comparison?.a.id == "requested")
        #expect(!store.comparing)
    }

    @Test("sheet dismissal retires a held replacement and permits a fresh comparison", .timeLimit(.minutes(2)))
    func dismissalRetiresReplacement() async throws {
        let gate = Gate()
        let store = try makeStore(gate)
        let first = try #require(store.compareSelected())
        await gate.untilRequests(1)
        gate.answer(1, with: try reply("first"))
        await first.value
        #expect(store.comparison?.a.id == "first")
        let replacement = try #require(store.compareSelected())
        await gate.untilRequests(2)
        store.dismissComparison()
        #expect(store.comparison == nil)
        #expect(!store.comparing)
        gate.answer(2, with: try reply("dismissed"))
        await replacement.value
        #expect(store.comparison == nil)
        let fresh = try #require(store.compareSelected())
        await gate.untilRequests(3)
        gate.answer(3, with: try reply("fresh"))
        await fresh.value
        #expect(store.comparison?.a.id == "fresh")
    }
}
