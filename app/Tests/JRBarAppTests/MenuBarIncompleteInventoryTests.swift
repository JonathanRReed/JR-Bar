import AppKit
import Testing
import JRBarCore
@testable import JRBarApp

@MainActor
@Suite("Menu Bar incomplete inventory")
struct MenuBarIncompleteInventoryTests {
    private func hider() -> MenuBarItemHider {
        let hider = MenuBarItemHider()
        hider.shuttersSuppressed = true
        hider.edgeStore = MenuBarMemoryFitEdgeStore()
        hider.edgeKey = { "fixture" }
        hider.guessedFitEdge = { 900 }
        hider.spacerCeiling = { 300 }
        hider.rowRect = { CGRect(x: 0, y: 0, width: 1440, height: 24) }
        hider.controlFrames = { MenuBarControlFrames(hidden: CGRect(x: 1000, y: 0, width: 24, height: 24)) }
        hider.barShowing = { true }
        hider.barIsVisible = { true }
        hider.listingIsScanned = { false }
        hider.settleSleep = { _ in await Task.yield() }
        return hider
    }

    @Test("partial inventory cannot publish a new plan or certify geometry, but manual reveal and hide remain usable")
    func partialInventoryKeepsManualControl() {
        let hider = hider()
        defer { hider.stop() }
        var complete = true
        hider.listingIsComplete = { complete }
        hider.listItems = { [] }
        var plans = 0
        var writes: [CGFloat] = []
        hider.onPlan = { _ in plans += 1 }
        hider.setControlLength = { _, length in writes.append(length) }
        hider.reconcile()
        hider.reconcile()
        let concealed = hider.assignedLengths[.hidden]
        #expect(concealed.map { $0 > MenuBarControlFrames.glyphLength } == true)
        let before = writes.count
        complete = false
        hider.reconcile()
        #expect(plans == 2 && writes.count == before)
        #expect(!hider.hasFreshControlListing)
        hider.reveal([.hidden])
        #expect(hider.assignedLengths[.hidden] == MenuBarControlFrames.glyphLength)
        hider.hide()
        #expect(hider.assignedLengths[.hidden] == concealed)
        #expect(plans == 2)
        complete = true
        hider.reconcile()
        #expect(plans == 3 && hider.hasFreshControlListing)
    }

    @Test("an incomplete scan updates its notice without publishing new geometry")
    func incompleteScanPublishesInventoryStatus() {
        let hider = hider()
        defer { hider.stop() }
        hider.listingIsComplete = { false }
        var updates = 0
        var plans = 0
        hider.onInventoryUpdate = { updates += 1 }
        hider.onPlan = { _ in plans += 1 }
        hider.inventoryDidRefresh()
        #expect(updates == 1)
        #expect(plans == 0)
        #expect(!hider.hasFreshControlListing)
    }

    @Test("explicit reveal collapses even an unmeasurable boundary during an incomplete scan")
    func revealDoesNotNeedFreshGeometry() {
        let hider = hider()
        defer { hider.stop() }
        hider.listingIsComplete = { false }
        hider.controlFrames = { MenuBarControlFrames() }
        hider.reveal([.hidden])
        #expect(hider.assignedLengths[.hidden] == MenuBarControlFrames.glyphLength)
        #expect(!hider.hasFreshControlListing)
    }

    @Test("an old display's concealed width is not reused on another display")
    func anotherDisplayDoesNotReuseTheWidth() {
        let hider = hider()
        defer { hider.stop() }
        hider.listItems = { [] }
        hider.reconcile()
        hider.reconcile()
        hider.listingIsComplete = { false }
        hider.reveal([.hidden])
        hider.edgeKey = { "other-display" }
        hider.hide()
        #expect(hider.assignedLengths[.hidden] == MenuBarControlFrames.glyphLength)
    }
}
