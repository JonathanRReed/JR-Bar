import AppKit
import Testing
@testable import JRBarApp

@Suite("Menu Bar remembered fit edge")
struct MenuBarFitEdgeRecoveryTests {
    private let row = CGRect(x: 0, y: 0, width: 1512, height: 33)

    @Test("a remembered edge inside the moved meter glyph is unusable")
    func movedDivider() {
        let controls = MenuBarControlFrames(
            hidden: CGRect(x: 971, y: 4.5, width: 75, height: 24), hiddenGlyph: 45)
        #expect(MenuBarItemHider.learnedFitEdgeNeedsReset(1038.5, controls: controls, row: row))
        #expect(!MenuBarItemHider.learnedFitEdgeNeedsReset(902, controls: controls, row: row))
    }

    @Test("an unchanged valid anchor retains its learned edge")
    func validAnchor() {
        let controls = MenuBarControlFrames(
            hidden: CGRect(x: 1100, y: 4.5, width: 75, height: 24), hiddenGlyph: 45)
        #expect(!MenuBarItemHider.learnedFitEdgeNeedsReset(1038.5, controls: controls, row: row))
    }

    @Test("a missing or parked divider provides no evidence to discard a learned edge")
    func unknownAnchor() {
        #expect(!MenuBarItemHider.learnedFitEdgeNeedsReset(1038.5,
            controls: MenuBarControlFrames(), row: row))
        let parked = MenuBarControlFrames(
            hidden: CGRect(x: 971, y: 970, width: 75, height: 24), hiddenGlyph: 45)
        #expect(!MenuBarItemHider.learnedFitEdgeNeedsReset(1038.5, controls: parked, row: row))
    }

    @MainActor
    @Test("moving left discards only the unusable cached edge and grows the spacer from the guess")
    func recoveryWritesNewReservation() {
        let hider = MenuBarItemHider()
        let memory = MenuBarMemoryFitEdgeStore()
        var boundary = CGRect(x: 1100, y: 4.5, width: 75, height: 24)
        hider.edgeStore = memory
        hider.edgeKey = { "1512x982" }
        hider.guessedFitEdge = { 902 }
        hider.rowRect = { self.row }
        hider.controlFrames = { MenuBarControlFrames(hidden: boundary, hiddenGlyph: 45) }
        hider.listItems = { [] }
        hider.barShowing = { false }
        hider.pointerHolds = { false }
        hider.shuttersSuppressed = true
        hider.spacerCeiling = { .infinity }
        defer { hider.stop() }
        memory.save(700, key: "other-screen")
        hider.nudgeFitEdge(by: 136.5)
        #expect(hider.learnedFitEdge == 1038.5)
        #expect(memory.load(key: "1512x982") == 1038.5)
        boundary = CGRect(x: 971, y: 4.5, width: 75, height: 24)
        hider.reconcile()
        #expect(hider.learnedFitEdge == nil)
        #expect(memory.load(key: "1512x982") == nil)
        #expect(memory.load(key: "other-screen") == 700)
        #expect(hider.fitEdge == 902)
        #expect(hider.assignedLengths[.hidden] == 144)
    }

    @MainActor
    @Test("a transient moved divider during wake quiet keeps the learned edge and spacer")
    func wakeQuietKeepsLearnedEdge() {
        let hider = MenuBarItemHider()
        let memory = MenuBarMemoryFitEdgeStore()
        var boundary = CGRect(x: 1100, y: 4.5, width: 75, height: 24)
        var seconds: TimeInterval = 10_000
        hider.edgeStore = memory
        hider.edgeKey = { "1512x982" }
        hider.guessedFitEdge = { 902 }
        hider.rowRect = { self.row }
        hider.controlFrames = { MenuBarControlFrames(hidden: boundary, hiddenGlyph: 45) }
        hider.listItems = { [] }
        hider.barShowing = { true }
        hider.pointerHolds = { false }
        hider.shuttersSuppressed = true
        hider.spacerCeiling = { .infinity }
        hider.now = { Date(timeIntervalSinceReferenceDate: seconds) }
        defer { hider.stop() }

        hider.nudgeFitEdge(by: 136.5)
        seconds += 2
        hider.reconcile()
        let written = hider.assignedLengths[.hidden]
        #expect(hider.learnedFitEdge == 1038.5)
        #expect(written == 137)

        hider.noteBarReformed("test wake")
        boundary = CGRect(x: 971, y: 4.5, width: 75, height: 24)
        seconds += 0.5
        hider.reconcile()
        #expect(hider.learnedFitEdge == 1038.5)
        #expect(memory.load(key: "1512x982") == 1038.5)
        #expect(hider.assignedLengths[.hidden] == written)

        seconds += MenuBarWakeRecovery.quiet
        hider.reconcile()
        #expect(hider.learnedFitEdge == nil)
        #expect(memory.load(key: "1512x982") == nil)
        #expect(hider.assignedLengths[.hidden] == 144)
    }
}
