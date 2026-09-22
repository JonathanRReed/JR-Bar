import Foundation
import Testing
import JRBarCore
@testable import JRBarApp

/// The Overview's Model and Cost columns: sorting by what `session_usage`
/// read, and re-sorting when a reading lands — without re-sorting on
/// every tick when the order does not depend on it.
@MainActor
@Suite struct OverviewUsageTests {
    private static func entry(_ id: String) -> CoreRosterEntry {
        CoreRosterEntry(session: CoreSession(id: id, provider: "claude", mode: "working", lifecycle: "active"),
                        schema: 1, visibility: "live")
    }

    @Test("a Cost column click orders by the estimate, unread rows last")
    func sortsByCost() {
        let store = OverviewStore(core: CoreModel())
        store.filter = OverviewFilter(preset: .all)
        store.roster = [Self.entry("ov-cheap"), Self.entry("ov-unread"), Self.entry("ov-dear")]
        store.sortOrder = [KeyPathComparator(\CoreRosterEntry.costSortKey, order: .reverse)]
        store.sessionUsage.apply(SessionUsageDocument(sessions: [
            "ov-cheap": SessionUsage(model: "claude-haiku-4-5", estimatedCostUSD: 0.2),
            "ov-dear": SessionUsage(model: "claude-opus-4-5", estimatedCostUSD: 9.5),
        ]), asked: ["ov-cheap", "ov-dear"])
        #expect(store.rows.map(\.id) == ["ov-dear", "ov-cheap", "ov-unread"])
    }

    @Test("the export carries the rows on screen and names the cut; two selected rows export as themselves")
    func exportFollowsTheView() {
        let store = OverviewStore(core: CoreModel())
        store.roster = [Self.entry("ov-a"), Self.entry("ov-b"), Self.entry("ov-c")]
        store.filter = OverviewFilter(preset: .working)
        store.search = "ov-"
        let scope = store.exportScope
        #expect(scope.label == "Working · search “ov-”")
        #expect(scope.args["ids"] == .array(["ov-a", "ov-b", "ov-c"].map(JSONValue.string)))
        #expect(scope.args["view"] == .string("Working · search “ov-”"))

        store.selectionChanged(to: ["ov-a", "ov-c"])
        #expect(store.exportScope.args["ids"] == .array(["ov-a", "ov-c"].map(JSONValue.string)))
        #expect(store.exportScope.label.hasPrefix("2 selected rows of Working"))

        #expect(OverviewStore.exportArgs(ids: nil, view: nil) == ["scope": .string("all")])
    }

    @Test("a reading that lands re-sorts a usage column, and only a usage column")
    func generationInvalidatesOnlyUsageSorts() {
        let store = OverviewStore(core: CoreModel())
        store.filter = OverviewFilter(preset: .all)
        store.roster = [Self.entry("ov-a"), Self.entry("ov-b")]
        store.sortOrder = [KeyPathComparator(\CoreRosterEntry.labelSortKey)]
        _ = store.rows
        let before = store.derivedComputations
        store.sessionUsage.apply(SessionUsageDocument(sessions: [
            "ov-a": SessionUsage(model: "claude-opus-4-5", estimatedCostUSD: 1),
        ]), asked: ["ov-a"])
        _ = store.rows
        #expect(store.derivedComputations == before)

        store.sortOrder = [KeyPathComparator(\CoreRosterEntry.modelSortKey)]
        _ = store.rows
        let sorted = store.derivedComputations
        store.sessionUsage.apply(SessionUsageDocument(sessions: [
            "ov-b": SessionUsage(model: "claude-haiku-4-5", estimatedCostUSD: 0.1),
        ]), asked: ["ov-b"])
        #expect(store.rows.map(\.id) == ["ov-b", "ov-a"])
        #expect(store.derivedComputations == sorted + 1)
    }
}
