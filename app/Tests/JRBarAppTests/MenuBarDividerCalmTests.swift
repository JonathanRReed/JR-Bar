import AppKit
import CoreGraphics
import Foundation
import Testing
@testable import JRBarApp
import JRBarCore

/// A ⌘-drag under the divider: the bar holds still for the press and the
/// beat after the drop, then reads once and says what moved. Nothing
/// toggles while a button is down, nothing re-seats, and the drag handler
/// only observes. Every clock is cranked by hand; nothing sleeps.
@Suite("Menu Bar — the divider stays calm under a drag")
struct MenuBarDividerCalmTests {
    // MARK: The gate

    /// The gate is a value that mutates when asked; `#expect` cannot call
    /// a mutating member, so the tests hold it in a box.
    private final class Probe {
        var gate = MenuBarPointerGate()
        var pressing: Bool { gate.pressing }
        func press(now: TimeInterval) { gate.press(now: now) }
        func release(now: TimeInterval) { gate.release(now: now) }
        func holds(_ buttonDown: Bool, _ now: TimeInterval) -> Bool {
            gate.holding(buttonDown: buttonDown, now: now)
        }
    }

    @Test("a press holds the bar, and so does the beat after the release; then it is free")
    func gateLifecycle() {
        let gate = Probe()
        #expect(!gate.holds(false, 0))
        gate.press(now: 10)
        #expect(gate.holds(true, 10.05))
        #expect(gate.holds(true, 12))
        gate.release(now: 12.5)
        #expect(!gate.pressing)
        #expect(gate.holds(false, 12.6), "the settle beat")
        #expect(gate.holds(false, 12.5 + MenuBarPointerGate.settle - 0.01))
        #expect(!gate.holds(false, 12.5 + MenuBarPointerGate.settle))
        #expect(!gate.holds(false, 14), "and it stays free")
    }

    @Test("a release nobody heard ends the hold when the button is up, and a lost press ends by itself")
    func gateLostRelease() {
        let gate = Probe()
        gate.press(now: 0)
        // The live button state is not yet down in the press's first beat.
        #expect(gate.holds(false, 0.1))
        // Up and past the grace: the release was lost, the settle beat starts.
        #expect(gate.holds(false, 1))
        #expect(!gate.holds(false, 1 + MenuBarPointerGate.settle + 0.01))
        // A press with the button still down is held, until it is stale.
        gate.press(now: 100)
        #expect(gate.holds(true, 100 + MenuBarPointerGate.stale - 1))
        #expect(gate.holds(true, 100 + MenuBarPointerGate.stale + 1),
                "forgotten, then the settle beat")
        #expect(!gate.holds(true, 100 + MenuBarPointerGate.stale + 5))
    }

    @Test("a release with no press is nothing")
    func gateStrayRelease() {
        let gate = Probe()
        gate.release(now: 5)
        #expect(!gate.holds(false, 5.1))
    }

    // MARK: The hider

    private let row = CGRect(x: 0, y: 0, width: 1512, height: 33)

    private func item(_ id: String, x: Double, w: Double = 28) -> MenuBarItem {
        var item = MenuBarItem(id: id, ownerPID: 500, ownerName: id,
                               bounds: CGRect(x: x, y: 4, width: w, height: 24), title: nil, windowID: 1)
        item.bundleID = "app.\(id.lowercased())"
        return item
    }

    @MainActor
    private final class Host: MenuBarBoundaryHost {
        var frame: CGRect? = CGRect(x: 1084, y: 0, width: 39, height: 24)
        var boundaryFrame: CGRect? { frame }
        var boundaryGlyphLength: CGFloat = 39
        var boundaryOccupiedFrame: CGRect? {
            frame.map { CGRect(x: $0.maxX - boundaryGlyphLength, y: $0.minY,
                               width: boundaryGlyphLength, height: $0.height) }
        }
        var spacers: [CGFloat] = []
        func setBoundarySpacer(_ length: CGFloat) { spacers.append(length) }
        var onBoundaryClick: (@MainActor () -> Void)?
        var hiddenItemsMenu: (@MainActor () -> NSMenu?)?
        var hiddenCount = 0
        var hiddenRevealed = false
        var barAppearance: NSAppearance? { nil }
    }

    @MainActor
    private final class Rig {
        let utility = MenuBarUtility()
        let host = Host()
        var settings = MenuBarSettings(enabled: true)
        var items: [MenuBarItem] = []
        var clock: TimeInterval = 1_000
        var buttonDown = false
        var notes: [String] = []
        var plans = 0
    }

    @MainActor
    @Test func blankReservationDoesNotProtectAHiddenItem() {
        let utility = MenuBarUtility()
        let host = Host()
        host.frame = CGRect(x: 900, y: 0, width: 223, height: 24)
        utility.host = host
        let plan = MenuBarItemHider.plan(
            items: [item("Hidden", x: 1000)], sections: [:], row: row,
            controls: MenuBarControlFrames(hidden: host.frame, hiddenGlyph: 39),
            fitEdge: 902, caps: MenuBarSpacerCaps(hidden: 50),
            protectedFrames: utility.hider.protectedFrames())
        #expect(plan.hidden.map(\.id) == ["Hidden"])
        #expect(plan.hiddenCovers == [1000...1028])
        #expect(!plan.hiddenCovers.contains { $0.overlaps(1084...1123) })
    }

    @MainActor
    private func makeRig(_ items: [MenuBarItem]) -> Rig {
        let rig = Rig()
        rig.items = items
        let utility = rig.utility
        utility.settings = { rig.settings }
        utility.onSettingsChange = { rig.settings = $0 }
        utility.host = rig.host
        utility.presentDropNote = { rig.notes.append($0) }
        utility.engineClock = { rig.clock }
        utility.leftButtonDown = { rig.buttonDown }
        utility.dragRows = { [self.row] }
        utility.hider.rowRect = { self.row }
        utility.hider.listingIsComplete = { true }
        utility.hider.listItems = { rig.items }
        utility.hider.guessedFitEdge = { 902 }
        utility.hider.edgeStore = MenuBarMemoryFitEdgeStore()
        utility.hider.edgeKey = { "calm" }
        utility.hider.shuttersSuppressed = true
        utility.hider.spacerCeiling = { .infinity }
        var now = Date()
        utility.hider.now = { now += MenuBarItemHider.writeCooldown * 2; return now }
        // The hold asks again every beat; each ask moves the clock on.
        utility.hider.pointerSleep = { _ in rig.clock += MenuBarItemHider.pointerPoll }
        utility.hider.onPlan = { [weak utility] plan in
            rig.plans += 1
            utility?.lastPlan = plan
        }
        return rig
    }

    @MainActor
    @Test("while the pointer holds the bar the hider reads and writes nothing, however often it is asked; one reconcile follows")
    func hiderHoldsThenRunsOnce() async {
        let rig = makeRig([item("Left", x: 1000), item("Right", x: 1130)])
        let hider = rig.utility.hider
        hider.reconcile()
        hider.reconcile()
        #expect(rig.plans == 2)
        let writes = rig.host.spacers.count
        // Held for the next three asks, then let go.
        var asks = 0
        hider.pointerHolds = { asks += 1; return asks <= 6 }
        let before = rig.plans
        for _ in 0..<5 { hider.reconcile() }
        #expect(rig.plans == before, "nothing planned while held")
        #expect(rig.host.spacers.count == writes, "nothing written while held")
        await hider.pointerTask?.value
        #expect(rig.plans == before + 1, "exactly one reconcile once it lets go")
        #expect(hider.pointerTask == nil)
    }

    @MainActor
    @Test("a reveal asked for mid-drag waits for the drop instead of reflowing the bar under the hand")
    func revealWaits() async {
        let rig = makeRig([item("Left", x: 1000), item("Right", x: 1130)])
        let utility = rig.utility
        utility.hider.reconcile()
        utility.hider.reconcile()
        let folded = rig.host.spacers.count
        rig.buttonDown = true
        utility.dividerDragPressed(at: CGPoint(x: 1140, y: 14))
        #expect(utility.pointerGate.pressing)
        utility.hider.reveal([.hidden])
        #expect(rig.host.spacers.count == folded, "the spacer does not collapse under a drag")
        #expect(utility.reveal.suppressed(), "the hover reveal and the rehide clock stand down")
        rig.buttonDown = false
        utility.dividerDragReleased()
        await utility.hider.pointerTask?.value
        #expect(utility.hider.revealed.contains(.hidden), "the reveal is not lost, only late")
        #expect(rig.host.spacers.last == 0, "after the drop the native reveal folds the spacer")
    }

    // MARK: The drop

    @MainActor
    @Test("a drop is observed once: the item that changed sides is named, nothing is written to a section")
    func dropIsObserved() async {
        let left = item("Left", x: 1000), right = item("Right", x: 1130)
        let rig = makeRig([left, right])
        let utility = rig.utility
        utility.hider.reconcile()
        utility.hider.reconcile()
        #expect(utility.hider.lastPlan.hidden.map(\.id) == ["Left"])
        #expect(utility.hider.lastPlan.shown.map(\.id) == ["Right"])
        // ⌘-press on Right.
        rig.buttonDown = true
        utility.dividerDragPressed(at: CGPoint(x: 1140, y: 14))
        #expect(utility.pointerGate.pressing)
        #expect(utility.dividerReadout.lines.contains("Spacer: holding still while you drag."))
        // macOS moves it left of the icon while the button is down.
        rig.items = [left, item("Right", x: 960)]
        for _ in 0..<4 { utility.hider.reconcile() }
        #expect(utility.hider.lastPlan.shown.map(\.id) == ["Right"], "mid-drag frames are never read")
        // Drop.
        rig.buttonDown = false
        utility.dividerDragReleased()
        #expect(utility.dividerDropPending)
        await utility.hider.pointerTask?.value
        #expect(Set(utility.hider.lastPlan.hidden.map(\.id)) == ["Left", "Right"])
        utility.notePositions(in: utility.hider.lastPlan)
        #expect(rig.notes == ["Right moved left of the icon: hidden."])
        #expect(utility.lastPositionChange == "Right moved left of the icon: hidden")
        #expect(!utility.dividerDropPending)
        #expect(rig.settings.sections.isEmpty, "the drag handler observes; it writes no section")
        #expect(utility.dividerReadout.lines.last == "Last change: Right moved left of the icon: hidden.")
        // A second pass says nothing more.
        utility.notePositions(in: utility.hider.lastPlan)
        #expect(rig.notes.count == 1)
    }

    @MainActor
    @Test("a drop that moved nothing says nothing, and a ⌘-click on a menu title is no drag")
    func quietDrops() async {
        let rig = makeRig([item("Left", x: 1000), item("Right", x: 1130)])
        let utility = rig.utility
        utility.hider.reconcile()
        utility.hider.reconcile()
        // A ⌘-click on blank bar far from any item.
        utility.dividerDragPressed(at: CGPoint(x: 300, y: 14))
        #expect(!utility.pointerGate.pressing, "an app's menu title is not a status item")
        // A real press and a drop that changes nothing.
        rig.buttonDown = true
        utility.dividerDragPressed(at: CGPoint(x: 1140, y: 14))
        rig.buttonDown = false
        utility.dividerDragReleased()
        await utility.hider.pointerTask?.value
        utility.notePositions(in: utility.hider.lastPlan)
        #expect(rig.notes.isEmpty)
        #expect(utility.lastPositionChange == nil)
        #expect(!utility.dividerDropPending)
    }

    @MainActor
    @Test("the positional record is not written while a drag holds the bar, and waits for the drop's own read")
    func recordWaitsForTheDrop() async {
        let rig = makeRig([item("Left", x: 1000), item("Right", x: 1130)])
        let utility = rig.utility
        utility.hider.reconcile()
        utility.hider.reconcile()
        rig.buttonDown = true
        utility.dividerDragPressed(at: CGPoint(x: 1140, y: 14))
        for _ in 0..<8 {
            rig.clock += 2
            utility.notePositions(in: utility.hider.lastPlan)
        }
        #expect(rig.settings.concealedApps.isEmpty, "mid-drag nothing is recorded")
        rig.buttonDown = false
        utility.dividerDragReleased()
        await utility.hider.pointerTask?.value
        for _ in 0..<4 {
            rig.clock += 2
            utility.notePositions(in: utility.hider.lastPlan)
        }
        #expect(rig.settings.concealedApps == ["app.left": .hidden], "then the settled bar is the record")
    }

    // MARK: Positions diff

    @Test("the diff names items that changed sides and ignores arrivals, departures and jitter")
    func positionDiff() {
        var before = MenuBarHidePlan()
        before.shown = [item("A", x: 1100), item("Stay", x: 1130)]
        before.hidden = [item("B", x: 900), item("Gone", x: 880)]
        var after = MenuBarHidePlan()
        after.hidden = [item("A", x: 950)]
        after.shown = [item("B", x: 1150), item("Stay", x: 1133), item("New", x: 1200)]
        let changes = MenuBarPositionDiff.changes(before: before, after: after)
        #expect(changes.map(\.sentence) == ["A moved left of the icon: hidden",
                                            "B moved right of the icon: shown"])
        #expect(MenuBarPositionDiff.changes(before: before, after: before).isEmpty)
    }

    // MARK: What JR-Bar sees

    @Test("the readout states each fact once and never claims what it does not know")
    func readout() {
        let hiding = MenuBarDividerReadout.make(.init(
            standing: true, iconFrame: CGRect(x: 952, y: 4, width: 30, height: 24), spacer: 79,
            fitEdge: 903, fitEdgeLearned: false, hidden: 9, shown: 3, parked: 6, room: .holds))
        #expect(hiding.lines == [
            "Engine: the icon is the divider. No assertion is taken.",
            "Icon: on the bar at 952–982 pt.",
            "Spacer: 79 pt, fit edge 903 pt (guessed).",
            "Left of the icon: 9 hidden (6 in macOS's « overflow). Right of it: 3 shown.",
        ])
        let revealed = MenuBarDividerReadout.make(.init(
            standing: true, iconFrame: CGRect(x: 952, y: 4, width: 30, height: 24), spacer: 79,
            revealed: true, hidden: 9, shown: 3))
        #expect(revealed.lines.contains("Spacer: folded, the hidden items are drawn."))
        let parked = MenuBarDividerReadout.make(.init(standing: true, room: .noRoom))
        #expect(parked.lines.contains("Icon: not on the bar. macOS parked it for want of room."))
        #expect(MenuBarDividerReadout.make(.init()).lines == ["Engine: starting."])
    }
}
