import AppKit
import Testing
@testable import JRBarApp

@Suite("Menu bar AX inventory publication")
struct MenuBarAXInventoryTests {
    @MainActor
    @Test("workspace churn invalidates the completed inventory before another scan can settle it")
    func workspaceChurnInvalidatesCompleteness() {
        let previous = MenuBarItemLister.AXPublication(items: MenuBarItemLister.axItems,
            owners: MenuBarItemLister.axOwnerPIDs, complete: MenuBarItemLister.axInventoryComplete)
        let pid = pid_t.max
        defer {
            MenuBarItemLister.noteQuit(pids: [pid])
            MenuBarItemLister.publishAXInventory(previous)
        }
        MenuBarItemLister.publishAXInventory(.init(items: [], owners: [], complete: true))
        MenuBarItemLister.noteLaunch(pids: [pid])
        #expect(!MenuBarItemLister.axInventoryComplete)
        MenuBarItemLister.publishAXInventory(.init(items: [], owners: [pid], complete: true))
        MenuBarItemLister.noteQuit(pids: [pid])
        #expect(!MenuBarItemLister.axInventoryComplete)
        #expect(!MenuBarItemLister.axOwnerPIDs.contains(pid))
    }

    private func item(_ pid: pid_t, x: CGFloat, id: String = "fixture") -> MenuBarItem {
        MenuBarItem(id: id, ownerPID: pid, ownerName: "Fixture",
            bounds: CGRect(x: x, y: 0, width: 20, height: 24), title: nil, windowID: 0)
    }

    @Test("an incomplete owner retains its prior items without certifying partial geometry")
    func incompleteOwnerRetainsPriorInventory() {
        let old = item(1, x: 100)
        let partial = item(1, x: 200)
        let result = MenuBarItemLister.mergeAXInventory(previous: [old], owners: [1],
            scanned: [partial, item(2, x: 300)], targeted: [1, 2], incomplete: [1],
            critical: [1], running: [1, 2])
        #expect(result.items.first == old)
        #expect(!result.items.contains(partial))
        #expect(result.owners == [1, 2])
        #expect(!result.complete)
    }

    @Test("complete empty answers and quit owners leave the inventory")
    func emptyAndQuitOwnersAreRemoved() {
        let result = MenuBarItemLister.mergeAXInventory(
            previous: [item(1, x: 100), item(2, x: 200), item(3, x: 300)], owners: [1, 2, 3],
            scanned: [item(2, x: 210)], targeted: [1, 2], incomplete: [2],
            critical: [1, 2], running: [1, 3])
        #expect(result.items == [item(3, x: 300)])
        #expect(result.owners == [3])
        #expect(!result.complete, "the unasked third owner retains old geometry")
    }

    @Test("irrelevant failed discovery does not freeze known geometry")
    func unknownDiscoveryFailureDoesNotBlock() {
        let result = MenuBarItemLister.mergeAXInventory(previous: [item(1, x: 100)], owners: [1],
            scanned: [item(1, x: 110)], targeted: [1, 2], incomplete: [2],
            critical: [1], running: [1, 2])
        #expect(result.items == [item(1, x: 110)])
        #expect(result.owners == [1])
        #expect(result.complete)
    }

    @Test("partial evidence of a new owner requires a complete retry")
    func partialNewOwnerIsRetryableButNotFresh() {
        let result = MenuBarItemLister.mergeAXInventory(previous: [], owners: [],
            scanned: [item(2, x: 200)], targeted: [2], incomplete: [2],
            critical: [], running: [2])
        #expect(result.items.isEmpty)
        #expect(result.owners == [2])
        #expect(!result.complete)
    }

    @Test("a later complete answer replaces retained geometry")
    func completeRecoveryReplacesOldGeometry() {
        let result = MenuBarItemLister.mergeAXInventory(previous: [item(1, x: 100)], owners: [1],
            scanned: [item(1, x: 200)], targeted: [1], incomplete: [],
            critical: [1], running: [1])
        #expect(result.items == [item(1, x: 200)])
        #expect(result.complete)
    }

    @Test("a complete scan keeps its established on-row and parked ordering")
    func completeOrderingIsPreserved() {
        let ordered = [item(1, x: 900), item(2, x: 0)]
        let result = MenuBarItemLister.mergeAXInventory(previous: [], owners: [],
            scanned: ordered, targeted: [1, 2], incomplete: [], critical: [], running: [1, 2])
        #expect(result.items == ordered)
        #expect(result.complete)
    }
}
