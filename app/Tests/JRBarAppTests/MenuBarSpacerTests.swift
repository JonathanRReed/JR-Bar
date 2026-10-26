import AppKit
import Foundation
import Testing
@testable import JRBarApp
@testable import JRBarCore

@MainActor
private final class GeometryReportingButtonCell: NSButtonCell {
    var reportedImageFrame: NSRect?

    override func imageRect(forBounds rect: NSRect) -> NSRect {
        reportedImageFrame ?? super.imageRect(forBounds: rect)
    }
}

/// The Menu Bar utility's positional model (docs/UTILITIES.md): an
/// item's section is where it sits relative to the boundary, hiding is
/// the boundary's spacer growing from the fit edge to pack the items
/// left of it off the row, and the section map is overrides only. All
/// pure inputs — no screen, no status items.
@Suite("Menu Bar — spacers")
struct MenuBarSpacerTests {
    private func item(_ id: String, owner: String = "App", x: Double, y: Double = 0,
                      w: Double = 24, overflow: Bool = false, pid: pid_t = 500) -> MenuBarItem {
        MenuBarItem(id: id, ownerPID: pid, ownerName: owner,
                    bounds: CGRect(x: x, y: y, width: w, height: 24),
                    title: nil, windowID: 0, isNativeOverflowControl: overflow)
    }

    private let row = CGRect(x: 0, y: 0, width: 1512, height: 24)
    /// The fit edge on a 1512-point display: the notch's right edge
    /// (848) plus the room the system keeps for its «.
    private let fitEdge: CGFloat = 902
    /// The collapsed boundary: one glyph wide at 1000.
    private let controls = MenuBarControlFrames(
        hidden: CGRect(x: 1000, y: 0, width: 24, height: 24))

    // MARK: Sections are positional

    @Test("left of the boundary is hidden, the rest shown; always-hidden is an override only")
    func positionalSections() {
        let items = [item("Deep", x: 906), item("Mid", x: 960), item("Up", x: 1030),
                     item("Up2", x: 1070)]
        let plan = MenuBarItemHider.plan(items: items, sections: [:], row: row,
                                         controls: controls, fitEdge: fitEdge)
        #expect(plan.alwaysHidden.isEmpty, "no second boundary — nothing is positionally deeper")
        #expect(plan.hidden.map(\.id) == ["Deep", "Mid"])
        #expect(plan.shown.map(\.id) == ["Up", "Up2"])
        // Positionally hidden items are pushed, never covered.
        #expect(plan.hiddenCovers.isEmpty)
        #expect(plan.alwaysHiddenCovers.isEmpty)
    }

    @Test("an item under an expanded control's spacer counts as hidden, not shown")
    func underSpacer() {
        let expanded = MenuBarControlFrames(
            hidden: CGRect(x: 902, y: 0, width: 122, height: 24))
        let items = [item("Stacked", x: 956), item("Up", x: 1030)]
        let plan = MenuBarItemHider.plan(items: items, sections: [:], row: row,
                                         controls: expanded, fitEdge: fitEdge)
        #expect(plan.hidden.map(\.id) == ["Stacked"])
        #expect(plan.shown.map(\.id) == ["Up"])
    }

    @Test("an item stacked under macOS's own overflow control is parked, not shown")
    func stackedUnderOverflow() {
        let overflow = item("Overflow", owner: "MenuBarAgent", x: 970, w: 17, overflow: true)
        let items = [overflow, item("Stacked", x: 966), item("Up", x: 1002)]
        let plan = MenuBarItemHider.plan(items: items, sections: [:], row: row,
                                         controls: MenuBarControlFrames(), fitEdge: fitEdge)
        #expect(plan.hidden.map(\.id) == ["Stacked"])
        #expect(plan.shown.map(\.id) == ["Overflow", "Up"],
                "the system's control is protected and lists as shown for the hit test")
    }

    @Test("two overflowed items sharing one spot keep a stable order across listings")
    func stableOrder() {
        let items = [item("B", x: 855), item("A", x: 855), item("Up", x: 1130)]
        let plan = MenuBarItemHider.plan(items: items, sections: [:], row: row,
                                         controls: controls, fitEdge: fitEdge)
        let swapped = MenuBarItemHider.plan(items: items.reversed(), sections: [:], row: row,
                                            controls: controls, fitEdge: fitEdge)
        #expect(swapped == plan, "listing order never changes the plan")
        #expect(plan.hidden.map(\.id) == ["A", "B"], "left of the boundary, sorted by id at one x")
    }

    @Test("an override covers an item that sits right of the boundary; a shown override is no override")
    func overridesCover() {
        let items = [item("Up", x: 1030), item("Up2", x: 1070)]
        let plan = MenuBarItemHider.plan(items: items,
                                         sections: ["Up": .hidden, "Up2": .shown], row: row,
                                         controls: controls, fitEdge: fitEdge)
        #expect(plan.hidden.map(\.id) == ["Up"])
        #expect(plan.hiddenCovers == [1030...1054])
        #expect(plan.shown.map(\.id) == ["Up2"])
    }

    @Test("an override on an item already left of the boundary changes its section but draws no cover")
    func overrideDeeper() {
        let items = [item("Mid", x: 960)]
        let plan = MenuBarItemHider.plan(items: items, sections: ["Mid": .alwaysHidden],
                                         row: row, controls: controls, fitEdge: fitEdge)
        #expect(plan.alwaysHidden.map(\.id) == ["Mid"])
        #expect(plan.alwaysHiddenCovers.isEmpty)
    }

    @Test("parked items are hidden regardless of position; only an override calls them always-hidden")
    func parkedItems() {
        let items = [item("P", x: 7, y: 970), item("Q", x: 7, y: 970)]
        let plan = MenuBarItemHider.plan(items: items, sections: ["Q": .alwaysHidden],
                                         row: row, controls: controls, fitEdge: fitEdge)
        #expect(plan.hidden.map(\.id) == ["P"])
        #expect(plan.alwaysHidden.map(\.id) == ["Q"])
    }

    @Test("without controls on the row nothing is positionally hidden")
    func noControls() {
        let items = [item("A", x: 960), item("B", x: 1070)]
        let plan = MenuBarItemHider.plan(items: items, sections: [:], row: row,
                                         controls: MenuBarControlFrames(), fitEdge: fitEdge)
        #expect(plan.shown.map(\.id) == ["A", "B"])
        #expect(plan.hiddenControlLength == nil)
    }

    // MARK: Spacer lengths

    @Test("a control on the row claims the stretch from the fit edge to its right edge")
    func spacerLengths() {
        let plan = MenuBarItemHider.plan(items: [], sections: [:], row: row,
                                         controls: controls, fitEdge: fitEdge)
        // Boundary right edge 1024 − 902 = 122.
        #expect(plan.hiddenControlLength == 122)
        #expect(MenuBarItemHider.spacerLength(
            controlFrame: CGRect(x: 1000, y: 0, width: 24, height: 24), fitEdge: fitEdge) == 122)
        #expect(MenuBarItemHider.fitInset > 17, "wider than the « button")
    }

    @Test("a revealed run collapses the boundary to the glyph; so does an unknown edge")
    func revealedCollapses() {
        let revealed = MenuBarItemHider.plan(items: [], sections: [:], row: row,
                                             controls: controls, fitEdge: fitEdge,
                                             revealed: [.hidden])
        #expect(revealed.hiddenControlLength == MenuBarControlFrames.glyphLength)
        let unknown = MenuBarItemHider.plan(items: [], sections: [:], row: row,
                                            controls: controls, fitEdge: nil)
        #expect(unknown.hiddenControlLength == MenuBarControlFrames.glyphLength)
    }

    @Test("a cap bounds the spacer and never drops it under the glyph")
    func caps() {
        let capped = MenuBarItemHider.plan(items: [], sections: [:], row: row,
                                           controls: controls, fitEdge: fitEdge,
                                           caps: MenuBarSpacerCaps(hidden: 50))
        #expect(capped.hiddenControlLength == 50)
        #expect(MenuBarItemHider.spacerLength(
            controlFrame: CGRect(x: 1000, y: 0, width: 24, height: 24),
            fitEdge: fitEdge, cap: 10) == MenuBarControlFrames.glyphLength)
        // A control whose right edge is already at the edge claims just
        // the glyph.
        #expect(MenuBarItemHider.spacerLength(
            controlFrame: CGRect(x: 890, y: 0, width: 24, height: 24),
            fitEdge: fitEdge) == MenuBarControlFrames.glyphLength)
    }

    @Test("a control off the row reports no length — nothing to write until it is back")
    func offRowControl() {
        let parked = MenuBarControlFrames(hidden: CGRect(x: 7, y: 970, width: 24, height: 24))
        let plan = MenuBarItemHider.plan(items: [item("A", x: 960)], sections: [:], row: row,
                                         controls: parked, fitEdge: fitEdge)
        #expect(plan.hiddenControlLength == nil)
        #expect(plan.shown.map(\.id) == ["A"], "no boundary on the row hides nothing")
    }

    // MARK: The hider drives the controls

    @MainActor
    private func makeHider(controls: @escaping @MainActor () -> MenuBarControlFrames,
                           items: [MenuBarItem] = [],
                           store: MenuBarMemoryFitEdgeStore = MenuBarMemoryFitEdgeStore())
        -> (MenuBarItemHider, () -> [(MenuBarItemSection, CGFloat)]) {
        final class Box { var writes: [(MenuBarItemSection, CGFloat)] = [] }
        let box = Box()
        let hider = MenuBarItemHider()
        hider.listItems = { items }
        hider.rowRect = { self.row }
        hider.controlFrames = controls
        hider.guessedFitEdge = { self.fitEdge }
        hider.edgeKey = { "test" }
        hider.edgeStore = store
        hider.shuttersSuppressed = true
        hider.settings = { MenuBarSettings(enabled: true) }
        hider.setControlLength = { section, length in box.writes.append((section, length)) }
        hider.now = Self.fastClock()
        return (hider, { box.writes })
    }

    /// A clock that leaps past the write cooldown on every read, so a
    /// test's back-to-back passes count as settled.
    @MainActor
    private static func fastClock() -> @MainActor () -> Date {
        var t = Date()
        return { t += MenuBarItemHider.writeCooldown * 2; return t }
    }

    /// Two passes: a length goes out only when consecutive passes agree.
    @MainActor
    private func settle(_ hider: MenuBarItemHider) {
        hider.reconcile()
        hider.reconcile()
    }

    @MainActor
    @Test("a length goes out on the second pass that wants it; reveal and hide write at once")
    func reconcileWritesLengths() {
        let (hider, writes) = makeHider(controls: { self.controls })
        hider.reconcile()
        #expect(writes().isEmpty, "one pass is a wish, not a write")
        #expect(hider.pendingLength == 122)
        hider.reconcile()
        #expect(writes().map(\.0) == [.hidden])
        #expect(writes().map(\.1) == [122])
        #expect(hider.pendingLength == nil)
        hider.reconcile()
        #expect(writes().count == 1, "an unchanged length is not rewritten")
        hider.reveal([.hidden])
        #expect(writes().last?.0 == .hidden)
        #expect(writes().last?.1 == MenuBarControlFrames.glyphLength)
        #expect(writes().count == 2, "a reveal does not wait for a second pass")
        hider.hide()
        #expect(writes().last?.1 == 122)
        #expect(writes().count == 3)
    }

    @MainActor
    @Test("a length that flips between passes is never written — that is the reflow, not the bar")
    func flappingNeverWrites() {
        @Captured var frames = controls
        let (hider, writes) = makeHider(controls: { frames })
        settle(hider)
        #expect(writes().count == 1)
        // The frame reads 52 points narrower on every other pass.
        let rest = controls.hidden!
        let mid = CGRect(x: rest.minX - 52, y: 0, width: rest.width, height: 24)
        for pass in 0..<8 {
            frames.hidden = pass.isMultiple(of: 2) ? mid : rest
            hider.reconcile()
        }
        #expect(writes().count == 1, "no two passes agreed, so nothing went out")
        // Settled at the narrower frame: a shorter length waits out the
        // shrink hold (the fast clock leaps past it), then goes out.
        frames.hidden = mid
        for _ in 0..<4 { settle(hider) }
        #expect(writes().count == 2)
        #expect(writes().last?.1 == 70)
    }

    @MainActor
    @Test("a visible shifted icon keeps the shrink hold and teaches nothing")
    func shiftIsHeld() {
        var t = Date()
        @Captured var frames = controls
        @Captured var items: [MenuBarItem] = []
        @Captured var generation = 0
        let store = MenuBarMemoryFitEdgeStore()
        let (hider, writes) = makeHider(controls: { frames }, store: store)
        hider.listingIsScanned = { false }
        hider.listItems = { items }
        hider.listingGeneration = { generation }
        hider.now = { t }
        defer { hider.stop() }
        settle(hider)
        #expect(writes().map(\.1) == [122])
        // The spacer landed: 902–1024.
        frames.hidden = CGRect(x: 902, y: 0, width: 122, height: 24)
        generation += 1
        hider.reconcile()
        // The whole bar shifts left, but our glyph remains visible.
        frames.hidden = CGRect(x: 846, y: 0, width: 122, height: 24)
        for _ in 0..<4 {
            t += 1.1
            generation += 1
            hider.reconcile()
        }
        #expect(writes().count == 1, "a shorter length is held through the shift")
        #expect(hider.learnedFitEdge == nil, "an overflow from a shift is not a lesson")
        // The indicator leaves, the bar shifts back: nothing to do.
        frames.hidden = CGRect(x: 902, y: 0, width: 122, height: 24)
        items = []
        t += 1.1
        settle(hider)
        #expect(writes().count == 1)
        // A shift that lasts past the hold is a real change.
        frames.hidden = CGRect(x: 846, y: 0, width: 122, height: 24)
        t += MenuBarItemHider.shrinkHold + 0.5
        settle(hider)
        #expect(writes().count == 1, "the hold starts when the shorter length is first wanted")
        t += MenuBarItemHider.shrinkHold + 0.5
        settle(hider)
        #expect(writes().last?.1 == 66)
    }

    @MainActor
    @Test("a fresh overflow over a shifted icon shortens its reservation immediately")
    func shiftedOverflowRestoresIcon() {
        var t = Date()
        @Captured var frames = controls
        @Captured var items: [MenuBarItem] = []
        let (hider, writes) = makeHider(controls: { frames })
        hider.listingIsScanned = { false }
        hider.barShowing = { true }
        hider.barIsVisible = { true }
        hider.listItems = { items }
        hider.now = { t }
        defer { hider.stop() }
        settle(hider)
        #expect(writes().map(\.1) == [122])
        frames.hidden = CGRect(x: 846, y: 0, width: 122, height: 24)
        items = [item("«", owner: "MenuBarAgent", x: 948, w: 17, overflow: true)]
        t += 0.1
        hider.reconcile()
        #expect(writes().map(\.1) == [122, 66])
        #expect(hider.learnedFitEdge == nil)
    }

    @MainActor
    @Test("an older in-flight scan cannot shorten a shifted reservation before reflow refresh")
    func shiftedOverflowWaitsForFreshRevision() async {
        var t = Date()
        @Captured var frames = controls
        @Captured var items: [MenuBarItem] = []
        @Captured var generation = 10
        var release: CheckedContinuation<Void, Never>?
        let (hider, writes) = makeHider(controls: { frames })
        hider.listingIsScanned = { true }
        hider.listingGeneration = { generation }
        hider.barShowing = { true }
        hider.barIsVisible = { true }
        hider.listItems = { items }
        hider.now = { t }
        hider.settleSleep = { _ in }
        hider.refreshListingAfterReflow = {
            await withCheckedContinuation { release = $0 }
            return true
        }
        defer { hider.stop(); release?.resume() }
        settle(hider)
        #expect(writes().map(\.1) == [122])
        frames.hidden = CGRect(x: 846, y: 0, width: 122, height: 24)
        items = [item("«", owner: "MenuBarAgent", x: 948, w: 17, overflow: true)]
        generation += 1
        t += 0.1
        hider.reconcile()
        #expect(!hider.hasFreshControlListing)
        #expect(writes().map(\.1) == [122])
        for _ in 0..<10_000 {
            if release != nil { break }
            await Task.yield()
        }
        #expect(release != nil)
        let pending = release
        release = nil
        pending?.resume()
        for _ in 0..<10_000 {
            if writes().count == 2 { break }
            await Task.yield()
        }
        #expect(writes().map(\.1) == [122, 66])
        #expect(hider.learnedFitEdge == nil)
    }

    @MainActor
    @Test("two passes inside the cooldown do not write; after it they do")
    func cooldown() {
        var t = Date()
        @Captured var frames = controls
        let (hider, writes) = makeHider(controls: { frames })
        hider.now = { t }
        settle(hider)
        #expect(writes().count == 1)
        // The bar moved the boundary right by 40 points (an item to its
        // right went away) — a real change, but read within the cooldown.
        frames.hidden = CGRect(x: 1040, y: 0, width: 24, height: 24)
        t += 0.2
        settle(hider)
        #expect(writes().count == 1, "the write that just went out has not settled")
        t += MenuBarItemHider.writeCooldown
        settle(hider)
        #expect(writes().count == 2)
        #expect(writes().last?.1 == 162)
    }

    @MainActor
    @Test("a boundary found parked lowers its cap and collapses; the next pass grows it under the cap")
    func parkedBoundaryLearnsCap() {
        @Captured var frames = controls
        let (hider, writes) = makeHider(controls: { frames })
        settle(hider)
        #expect(hider.assignedLengths[.hidden] == 122)
        // macOS parked it: the frame reports off the row. The collapse
        // goes out on the spot — a parked boundary is not drawn.
        frames.hidden = CGRect(x: 0, y: 1000, width: 122, height: 24)
        hider.reconcile()
        #expect(hider.caps.hidden == 122 - MenuBarItemHider.capStep)
        #expect(writes().last?.0 == .hidden)
        #expect(writes().last?.1 == MenuBarControlFrames.glyphLength)
        // Back on the row, it grows again — but only to the cap.
        frames.hidden = CGRect(x: 1000, y: 0, width: 24, height: 24)
        settle(hider)
        #expect(hider.assignedLengths[.hidden] == 82)
        hider.resetCaps()
        settle(hider)
        #expect(hider.assignedLengths[.hidden] == 122)
    }

    @MainActor
    @Test("stop collapses the boundary and forgets the reveal")
    func stopCollapses() {
        let (hider, writes) = makeHider(controls: { self.controls })
        settle(hider)
        hider.reveal([.alwaysHidden])
        hider.stop()
        #expect(hider.revealed.isEmpty)
        #expect(hider.assignedLengths[.hidden] == MenuBarControlFrames.glyphLength)
        #expect(hider.assignedLengths[.alwaysHidden] == nil, "there is no second control to collapse")
        #expect(writes().last?.1 == MenuBarControlFrames.glyphLength)
    }

    @MainActor
    @Test("a reinstalled control forgets the old length so the new item gets sized again")
    func reinstallForgets() {
        let (hider, writes) = makeHider(controls: { self.controls })
        settle(hider)
        let before = writes().count
        hider.controlsReinstalled()
        settle(hider)
        #expect(writes().count == before + 1, "the length is handed to the fresh item")
    }

    // MARK: The fit edge — learned from the «, remembered per screen

    @Test("the « landing on our glyph means the boundary itself was overflowed")
    func overflowDetection() {
        let boundary = CGRect(x: 902, y: 0, width: 122, height: 24)
        let overflowOnGlyph = item("«", owner: "MenuBarAgent", x: 1010, w: 17, overflow: true)
        #expect(MenuBarItemHider.controlOverflowed(controlFrame: boundary, items: [overflowOnGlyph], row: row))
        let overflowLeft = item("«", owner: "MenuBarAgent", x: 880, w: 17, overflow: true)
        #expect(!MenuBarItemHider.controlOverflowed(controlFrame: boundary, items: [overflowLeft], row: row))
        #expect(!MenuBarItemHider.controlOverflowed(controlFrame: boundary, items: [], row: row))
    }

    @MainActor
    @Test("native overflow learns the fit edge after two fresh listings")
    func overflowLearnsFitEdge() {
        @Captured var items: [MenuBarItem] = []
        @Captured var generation = 0
        let store = MenuBarMemoryFitEdgeStore()
        let hider = MenuBarItemHider()
        hider.listItems = { items }
        hider.rowRect = { self.row }
        hider.controlFrames = { self.controls }
        hider.guessedFitEdge = { self.fitEdge }
        hider.edgeKey = { "1512x982" }
        hider.edgeStore = store
        hider.listingGeneration = { generation }
        hider.shuttersSuppressed = true
        hider.settings = { MenuBarSettings(enabled: true) }
        hider.now = Self.fastClock()
        settle(hider)
        #expect(hider.assignedLengths[.hidden] == 122)
        #expect(hider.fitEdge == fitEdge)
        // A « on the glyph in a listing from before the write proves
        // nothing — the bar has not reflowed yet.
        items = [item("«", owner: "MenuBarAgent", x: 1005, w: 17, overflow: true)]
        hider.reconcile()
        #expect(hider.learnedFitEdge == nil, "stale frames never move the edge")
        generation += 1
        hider.reconcile()
        hider.reconcile()
        #expect(hider.learnedFitEdge == nil, "one fresh listing can be the launch handoff — not proof")
        generation += 1
        hider.reconcile()
        // Two fresh listings agree. The spacer was placed at 1024 − 122
        // = 902; the edge steps right of that, and the shorter spacer
        // goes out on the spot — an overflowed boundary is not drawn.
        #expect(hider.learnedFitEdge == 902 + MenuBarItemHider.overflowStep)
        #expect(store.edges["1512x982"] == 910)
        #expect(hider.assignedLengths[.hidden] == 114)
        // The same listing again: one step per reflow, never three.
        hider.reconcile()
        #expect(hider.learnedFitEdge == 910)
        // The « moved left of the glyph: the edge stays where it is —
        // it is never moved back left on its own — and a lone proof
        // after that starts the count over.
        generation += 1
        items = [item("«", owner: "MenuBarAgent", x: 880, w: 17, overflow: true)]
        hider.reconcile()
        #expect(hider.learnedFitEdge == 910)
        generation += 1
        items = [item("«", owner: "MenuBarAgent", x: 1005, w: 17, overflow: true)]
        hider.reconcile()
        #expect(hider.learnedFitEdge == 910, "a transient after a clean listing is one, not two")
        hider.forgetFitEdge()
        #expect(hider.learnedFitEdge == nil)
        #expect(store.edges["1512x982"] == nil)
        hider.reconcile()
        #expect(hider.assignedLengths[.hidden] == 122)
    }

    @MainActor
    @Test("a screen change reloads the edge learned for that screen")
    func edgePerScreen() {
        let store = MenuBarMemoryFitEdgeStore()
        store.save(930, key: "1512x982")
        @Captured var key = "1512x982"
        let (hider, _) = makeHider(controls: { self.controls }, store: store)
        hider.edgeKey = { key }
        hider.start()
        hider.reconcile()
        #expect(hider.fitEdge == 930, "the learned edge outranks the guess")
        #expect(hider.assignedLengths[.hidden] == 94)
        key = "2560x1440"
        hider.stop()
        hider.start()
        #expect(hider.fitEdge == fitEdge, "a screen with no lesson uses the guess")
        hider.stop()
    }

    @Test("the « beside a hidden run is reported for the ear to dodge, never covered; revealed, nothing")
    func overflowBesideTheRun() {
        let boundary = MenuBarControlFrames(hidden: CGRect(x: 902, y: 0, width: 122, height: 24))
        let overflow = item("«", owner: "MenuBarAgent", x: 877, w: 18, overflow: true)
        let hidden = MenuBarItemHider.plan(items: [overflow], sections: [:], row: row,
                                           controls: boundary, fitEdge: fitEdge)
        #expect(hidden.hiddenCovers.isEmpty, "a cover under the « hides nothing — it draws above us")
        #expect(hidden.overflowControlFrame == CGRect(x: 877, y: 0, width: 18, height: 24))
        let revealed = MenuBarItemHider.plan(items: [overflow], sections: [:], row: row,
                                             controls: boundary, fitEdge: fitEdge,
                                             revealed: [.hidden])
        #expect(revealed.hiddenCovers.isEmpty)
        #expect(revealed.overflowControlFrame == nil)
        // A « on the glyph (our boundary overflowed) is not beside the run.
        let onGlyph = item("«", owner: "MenuBarAgent", x: 1010, w: 18, overflow: true)
        let overflowed = MenuBarItemHider.plan(items: [onGlyph], sections: [:], row: row,
                                               controls: boundary, fitEdge: fitEdge)
        #expect(overflowed.overflowControlFrame == nil)
    }

    // MARK: The Golden Gate swap — cover shown while revealing

    @Test("coverShown paints the shown run; protected, the « and the boundary stay blockers")
    func shownCovers() {
        let overflow = item("«", owner: "MenuBarAgent", x: 1180, w: 18, overflow: true)
        let protected = item("Clock", owner: "Control Center", x: 1205)
        let items = [item("Deep", x: 906), item("Mid", x: 960),
                     item("Up", x: 1030), item("Up2", x: 1070),
                     overflow, protected]
        let plan = MenuBarItemHider.plan(items: items, sections: [:], row: row,
                                         controls: controls, fitEdge: fitEdge,
                                         coverShown: true)
        // The swap covers the shown run only — sections stay honest.
        #expect(plan.hidden.map(\.id) == ["Deep", "Mid"])
        #expect(plan.shown.map(\.id).contains("Up"))
        #expect(!plan.shownCovers.isEmpty)
        // The cover spans the shown run but never the « or Control
        // Center, and never the boundary's own frame at 1000–1024.
        for cover in plan.shownCovers {
            #expect(!cover.contains(1180) && !cover.contains(1205),
                    "protected and native-overflow frames stay uncovered")
            #expect(!cover.overlaps(1000...1024),
                    "the rehide affordance is never covered")
        }
        // Up@1030 and Up2@1070 sit under one merged run.
        #expect(plan.shownCovers.contains { $0.contains(1030) && $0.contains(1070) })
        // Off, the plan carries no shown coverage at all.
        let plain = MenuBarItemHider.plan(items: items, sections: [:], row: row,
                                          controls: controls, fitEdge: fitEdge)
        #expect(plain.shownCovers.isEmpty)
    }

    @Test("a shown-cover plan never paints over a protected owner's slot")
    func shownCoversRespectProtected() {
        // Two shown items flanking a protected one: the run breaks at
        // it rather than paving it.
        let protected = item("Clock", owner: "Control Center", x: 1070)
        let items = [item("Up", x: 1030), protected, item("Up2", x: 1110)]
        let plan = MenuBarItemHider.plan(items: items, sections: [:], row: row,
                                         controls: controls, fitEdge: fitEdge,
                                         coverShown: true)
        for cover in plan.shownCovers {
            #expect(!cover.overlaps(1070...1094))
        }
    }

    // MARK: Migration and the control face

    @MainActor
    @Test("a cover-era section map is cleared once on apply; a current file is left alone")
    func migration() {
        let utility = MenuBarUtility()
        var state = MenuBarSettings(enabled: false, sections: ["A": .hidden], layoutModel: 0)
        var writes = 0
        utility.settings = { state }
        utility.onSettingsChange = { draft in state = draft; writes += 1 }
        utility.migrateSectionsIfNeeded()
        #expect(writes == 1)
        #expect(state.sections.isEmpty)
        #expect(state.layoutModel == MenuBarSettings.currentLayoutModel)
        utility.migrateSectionsIfNeeded()
        #expect(writes == 1)
        state.sections = ["B": .hidden]
        utility.migrateSectionsIfNeeded()
        #expect(state.sections == ["B": .hidden])
        #expect(writes == 1)
    }

    @MainActor
    @Test func appleExtrasKeepTheirVisiblePickerChoice() {
        let utility = MenuBarUtility()
        var state = MenuBarSettings(enabled: false)
        state.concealedApps = ["com.apple.Passwords.MenuBarExtra": .hidden,
                               "com.example.app": .hidden]
        state.sections = ["WeatherMenu": .alwaysHidden]
        utility.settings = { state }
        utility.onSettingsChange = { state = $0 }
        utility.migrateSectionsIfNeeded()
        #expect(state.concealedApps == ["com.example.app": .hidden])
        #expect(state.sections == ["WeatherMenu": .alwaysHidden])
    }

    // MARK: Show All — explicit, it survives a restart, and it forgets nothing

    /// Show all used to write every app Shown, so one press (or one rule
    /// pair) erased the curation. It is an overlay now: it survives a
    /// restart like any setting, the live map shows everything, and the
    /// curated map underneath is exactly what it was.
    @MainActor
    @Test func showAllSurvivesRestart() throws {
        let utility = MenuBarUtility()
        var settings = MenuBarSettings(enabled: false)
        settings.concealedApps = ["com.example.one": .hidden, "com.example.two": .alwaysHidden]
        settings.sections = ["old-cover": .hidden]
        utility.settings = { settings }
        utility.onSettingsChange = { settings = $0 }
        utility.hider.listingIsComplete = { true }
        utility.hider.listItems = { [] }
        utility.hider.rowRect = { self.row }
        utility.hider.onPlan = nil
        utility.showAllListed()
        let restored = try JSONDecoder().decode(MenuBarSettings.self,
            from: JSONEncoder().encode(settings))
        #expect(restored.curation.overlay?.kind == .showEverything)
        #expect(restored.concealedApps == ["com.example.one": .hidden, "com.example.two": .alwaysHidden])
        #expect(restored.sections == ["old-cover": .hidden])
        settings = restored
        #expect(utility.liveSettings().concealedApps == ["com.example.one": .shown, "com.example.two": .shown])
        #expect(utility.liveSettings().sections.isEmpty)
        // Restore is the curated bar, exactly.
        utility.restoreCuratedBar()
        #expect(settings.curation.overlay == nil)
        #expect(utility.liveSettings().concealedApps == ["com.example.one": .hidden,
                                                         "com.example.two": .alwaysHidden])
    }

    @MainActor
    @Test("the palette answers effective sections per listed item — stale map keys never leak")
    func paletteSections() {
        let utility = MenuBarUtility()
        utility.settings = {
            MenuBarSettings(enabled: true, sections: ["Left": .hidden, "ghost": .hidden])
        }
        utility.hider.rowRect = { self.row }
        utility.hider.guessedFitEdge = { 902 }
        utility.hider.edgeStore = MenuBarMemoryFitEdgeStore()
        utility.hider.edgeKey = { "test" }
        utility.hider.listingIsComplete = { true }
        utility.hider.listItems = { [self.item("Left", x: 1000), self.item("Right", x: 1130)] }
        utility.hider.now = Self.fastClock()
        settle(utility.hider)
        let map = utility.menuBarSections(for: utility.actions)
        #expect(map["Left"] == .hidden)
        #expect(map["Right"] == .shown)
        #expect(map["ghost"] == nil, "the raw settings map must not leak through")
    }

    // MARK: The boundary host — JR-Bar's own status item

    /// A host that records what the utility asks of it.
    @MainActor
    private final class FakeHost: MenuBarBoundaryHost {
        var frame: CGRect? = CGRect(x: 1084, y: 0, width: 39, height: 24)
        var boundaryFrame: CGRect? { frame }
        var boundaryHoverFrame: NSRect?
        var boundaryGlyphLength: CGFloat = 39
        var spacers: [CGFloat] = []
        func setBoundarySpacer(_ length: CGFloat) { spacers.append(length) }
        var onBoundaryClick: (@MainActor () -> Void)?
        var hiddenItemsMenu: (@MainActor () -> NSMenu?)?
        var hiddenCount = 0
        var hiddenRevealed = false
        var barAppearance: NSAppearance? { nil }
    }

    @Test("the reveal zone ends before the icon on translated menu bar rows")
    func revealZoneEndsAtSpacerAcrossDisplays() {
        for origin in [CGPoint(x: 450, y: 958), CGPoint(x: -1200, y: 1658),
                       CGPoint(x: 2100, y: 658)] {
            let boundary = NSRect(origin: origin, size: NSSize(width: 174, height: 24))
            let row = NSRect(x: origin.x - 400, y: origin.y, width: 1200, height: 27)
            let blank = NSRect(origin: origin, size: NSSize(width: 130, height: 24))
            let zone = MenuBarUtility.revealZone(row: row, boundary: boundary,
                                                 hoverFrame: blank, fitEdge: origin.x - 60)
            #expect(zone == NSRect(x: origin.x - 90, y: row.minY, width: 220, height: row.height))
            #expect(zone?.contains(NSPoint(x: blank.maxX - 10, y: blank.midY)) == true)
            #expect(zone?.contains(NSPoint(x: blank.maxX, y: blank.midY)) == false)
            #expect(zone?.contains(NSPoint(x: blank.maxX + 12, y: blank.midY)) == false)
        }
    }

    @Test("a collapsed reveal zone stays empty even when the fit edge is farther left")
    func collapsedRevealZoneDoesNotFallBackToRow() {
        let boundary = NSRect(x: 450, y: 958, width: 24, height: 24)
        let row = NSRect(x: 0, y: 958, width: 1512, height: 27)
        for blank in [NSRect(x: 450, y: 958, width: 0, height: 24), nil] as [NSRect?] {
            let zone = MenuBarUtility.revealZone(row: row, boundary: boundary,
                                                 hoverFrame: blank, fitEdge: 100)
            #expect(zone != nil)
            #expect(zone?.isEmpty == true)
            #expect(zone?.contains(NSPoint(x: 460, y: 965)) == false)
            #expect(zone?.contains(NSPoint(x: 200, y: 965)) == false)
        }
    }

    @Test("native spacer clicks stop strictly before the chevron seat")
    func nativeSpacerClickExcludesChevronAndIcon() {
        let bounds = NSRect(x: 0, y: 0, width: 174, height: 24)
        let blank = StatusItemController.boundaryRevealBounds(bounds, spacer: 150)
        #expect(blank.contains(NSPoint(x: 129, y: 12)))
        for x in [CGFloat(130), CGFloat(140), CGFloat(149), CGFloat(150), CGFloat(162)] {
            #expect(!blank.contains(NSPoint(x: x, y: 12)))
        }
        #expect(!blank.contains(NSPoint(x: -1, y: 12)))
    }

    @Test("hoverable blank space ends before the chevron across native reflow widths")
    func blankHoverBoundsExcludeChevronDuringReflow() {
        let settled = NSRect(x: 0, y: 0, width: 174, height: 24)
        let blank = StatusItemController.boundaryRevealBounds(settled, spacer: 150)
        #expect(blank.maxX == 130)
        #expect(blank.contains(NSPoint(x: 129, y: 12)))
        for x in [CGFloat(130), CGFloat(140), CGFloat(149), CGFloat(150), CGFloat(162)] {
            #expect(!blank.contains(NSPoint(x: x, y: 12)))
        }
        let partial = NSRect(x: 0, y: 0, width: 100, height: 24)
        #expect(StatusItemController.boundaryRevealBounds(partial, spacer: 150).maxX <= 56)
        let shifted = NSRect(x: 10, y: 4, width: 174, height: 24)
        let shiftedBlank = StatusItemController.boundaryRevealBounds(shifted, spacer: 150)
        #expect(shiftedBlank.minX == 10)
        #expect(shiftedBlank.maxX == 140)
    }

    @Test("shared blank bounds leave controls clear even when the requested spacer is oversized")
    func hoverBoundsMatchNativeSpacerClicks() {
        let bounds = NSRect(x: 0, y: 0, width: 174, height: 24)
        let blank = StatusItemController.boundaryRevealBounds(bounds, spacer: 150)
        #expect(blank.contains(NSPoint(x: 129, y: 12)))
        #expect(!blank.contains(NSPoint(x: 130, y: 12)))
        #expect(StatusItemController.boundaryRevealBounds(bounds, spacer: 0).isEmpty)
        #expect(StatusItemController.boundaryRevealBounds(bounds, spacer: 500).width == 130)
    }

    @Test("owned source width and title padding stay outside the blank seat")
    func blankBoundsReserveFullSourceAndTitle() {
        let bounds = NSRect(x: 10, y: 4, width: 260, height: 24)
        let blank = StatusItemController.boundaryRevealBounds(bounds, spacer: 150,
                                                              glyphWidth: 108, trailingWidth: 48)
        #expect(blank == NSRect(x: 10, y: 4, width: 84, height: 24))
        for x in [CGFloat(94), CGFloat(100), CGFloat(120), CGFloat(180), CGFloat(269)] {
            #expect(!blank.contains(NSPoint(x: x, y: 12)))
        }
        let compressed = NSRect(x: 0, y: 0, width: 24, height: 24)
        #expect(StatusItemController.boundaryRevealBounds(compressed, spacer: 150,
                                                         glyphWidth: 108, trailingWidth: 48).isEmpty)
    }

    @MainActor
    @Test("revealing the native spacer keeps the painted icon in place")
    func nativeSpacerCollapseKeepsPaintedIconInPlace() throws {
        for glyphWidth in [CGFloat(18), CGFloat(108)] {
            for label in ["", "Synthetic status"] {
                let source = NSImage(size: NSSize(width: glyphWidth, height: 18), flipped: false) { rect in
                    NSColor.red.setFill()
                    rect.insetBy(dx: 2, dy: 2).fill()
                    return true
                }
                var paintedFrames: [CGRect] = []
                var pixelWidths: [CGFloat] = []
                for spacer in [CGFloat(150), CGFloat(0)] {
                    let image = spacer > 0
                        ? StatusItemController.folded(source, spacer: spacer, chevron: true, hintTint: .white)
                        : source
                    let title = StatusItemController.labelTitle(label)
                    let contentWidth = StatusItemController.paintedLength(imageWidth: glyphWidth,
                                                                          label: label.isEmpty ? nil : label)
                    let length = StatusItemController.itemLength(spacer: spacer, contentWidth: contentWidth)
                    let width: CGFloat
                    if length == NSStatusItem.variableLength {
                        width = image.size.width + title.size().width + 8
                    } else if length == NSStatusItem.squareLength {
                        width = 24
                    } else {
                        width = length
                    }
                    let button = NSButton(frame: NSRect(x: 0, y: 0, width: width, height: 24))
                    button.isBordered = false
                    button.image = image
                    button.imageScaling = spacer > 0 ? .scaleNone : .scaleProportionallyDown
                    button.imagePosition = label.isEmpty ? .imageOnly : .imageLeading
                    button.imageHugsTitle = true
                    button.attributedTitle = title
                    let bitmap = try #require(button.bitmapImageRepForCachingDisplay(in: button.bounds))
                    button.cacheDisplay(in: button.bounds, to: bitmap)
                    let scaleX = CGFloat(bitmap.pixelsWide) / width
                    let scaleY = CGFloat(bitmap.pixelsHigh) / 24
                    var painted: CGRect?
                    for y in 0..<bitmap.pixelsHigh {
                        for x in 0..<bitmap.pixelsWide {
                            guard let color = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.sRGB),
                                  color.alphaComponent > 0.5, color.redComponent > 0.7,
                                  color.greenComponent < 0.3, color.blueComponent < 0.3 else { continue }
                            let pixel = CGRect(x: 1000 - width + CGFloat(x) / scaleX,
                                               y: CGFloat(y) / scaleY,
                                               width: 1 / scaleX, height: 1 / scaleY)
                            painted = painted.map { $0.union(pixel) } ?? pixel
                        }
                    }
                    paintedFrames.append(try #require(painted))
                    pixelWidths.append(1 / scaleX)
                    let blank = StatusItemController.boundaryRevealBounds(for: button, spacer: spacer,
                                                                           glyphWidth: glyphWidth)
                    if spacer == 0 { #expect(blank.isEmpty) }
                    if ProcessInfo.processInfo.environment["JRBAR_RENDER_PROOF"] == "1" {
                        let path = ProcessInfo.processInfo.environment["JRBAR_RENDER_PROOF_DIR"] ?? "/tmp/jrbar-audit"
                        let directory = URL(fileURLWithPath: path)
                        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                        let png = try #require(bitmap.representation(using: .png, properties: [:]))
                        let name = "menu-anchor-\(Int(glyphWidth))-\(label.isEmpty ? "icon" : "title")-\(Int(spacer)).png"
                        try png.write(to: directory.appendingPathComponent(name))
                    }
                }
                let pixelTolerance = max(pixelWidths[0], pixelWidths[1])
                let leftDrift = abs(paintedFrames[0].minX - paintedFrames[1].minX)
                let rightDrift = abs(paintedFrames[0].maxX - paintedFrames[1].maxX)
                #expect(leftDrift < pixelTolerance)
                #expect(rightDrift < pixelTolerance)
            }
        }
    }

    @MainActor
    @Test("the rendered folded button keeps a reachable blank seat")
    func foldedButtonNativeLayoutKeepsBlankReachable() throws {
        for glyphWidth in [CGFloat(24), CGFloat(108)] {
            for label in ["", "Synthetic status"] {
                let icon = NSImage(size: NSSize(width: glyphWidth, height: 18), flipped: false) { rect in
                    NSColor.white.setFill()
                    rect.insetBy(dx: 2, dy: 2).fill()
                    return true
                }
                let folded = StatusItemController.folded(icon, spacer: 150, chevron: true, hintTint: .white)
                let title = StatusItemController.labelTitle(label)
                let width = folded.size.width + (label.isEmpty ? 0 : title.size().width + 8)
                let button = NSButton(frame: NSRect(x: 0, y: 0, width: width, height: 24))
                let cell = GeometryReportingButtonCell()
                button.cell = cell
                button.isBordered = false
                button.image = folded
                button.imageScaling = .scaleNone
                button.imagePosition = label.isEmpty ? .imageOnly : .imageLeading
                button.imageHugsTitle = true
                button.attributedTitle = title
                let bitmap = try #require(button.bitmapImageRepForCachingDisplay(in: button.bounds))
                button.cacheDisplay(in: button.bounds, to: bitmap)
                // Reporting changes after drawing model cells whose public geometry
                // disagrees with the painted composite, without changing its pixels.
                let reports: [NSRect?] = [nil, .zero, NSRect(x: 0, y: 0, width: 24, height: 18)]
                for report in reports {
                    cell.reportedImageFrame = report
                    if let report { #expect(cell.imageRect(forBounds: button.bounds) == report) }
                    let blank = StatusItemController.boundaryRevealBounds(for: button, spacer: 150,
                                                                           glyphWidth: glyphWidth)
                    #expect(abs(blank.width - 130) < 0.01)
                    #expect(blank.contains(NSPoint(x: 30, y: 12)))
                    for x in [CGFloat(130), CGFloat(140), CGFloat(160), width - 1] {
                        #expect(!blank.contains(NSPoint(x: x, y: 12)))
                    }
                }
                if ProcessInfo.processInfo.environment["JRBAR_RENDER_PROOF"] == "1" {
                    let path = ProcessInfo.processInfo.environment["JRBAR_RENDER_PROOF_DIR"] ?? "/tmp/jrbar-audit"
                    let directory = URL(fileURLWithPath: path)
                    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                    let png = try #require(bitmap.representation(using: .png, properties: [:]))
                    let name = "menu-reveal-\(Int(glyphWidth))-\(label.isEmpty ? "icon" : "title").png"
                    try png.write(to: directory.appendingPathComponent(name))
                }
            }
        }
    }

    @MainActor
    @Test("a stale or absent folded image cannot lend the button a blank seat")
    func blankSeatRequiresMatchingComposite() {
        let button = NSButton(frame: NSRect(x: 0, y: 0, width: 174, height: 24))
        #expect(StatusItemController.boundaryRevealBounds(for: button, spacer: 150, glyphWidth: 24).isEmpty)
        let source = NSImage(size: NSSize(width: 24, height: 18))
        button.image = source
        #expect(StatusItemController.boundaryRevealBounds(for: button, spacer: 150, glyphWidth: 24).isEmpty)
        button.image = StatusItemController.folded(source, spacer: 120, chevron: true)
        #expect(StatusItemController.boundaryRevealBounds(for: button, spacer: 150, glyphWidth: 24).isEmpty)
        button.image = StatusItemController.folded(source, spacer: 150, chevron: true)
        #expect(StatusItemController.boundaryRevealBounds(for: button, spacer: 0, glyphWidth: 24).isEmpty)
        button.frame.size.width = 24
        #expect(StatusItemController.boundaryRevealBounds(for: button, spacer: 150, glyphWidth: 24).isEmpty)
    }

    @Test("native reflow preserves only the measured blank seat")
    func clippedCompositeKeepsMeasuredBlank() {
        for origin in [CGFloat(0), CGFloat(10)] {
            let bounds = NSRect(x: origin, y: 0, width: 93, height: 24)
            let blank = StatusItemController.boundaryRevealBounds(bounds, spacer: 150,
                glyphWidth: 24)
            #expect(blank.width == 49)
            #expect(blank.contains(NSPoint(x: origin + 30, y: 12)))
            for x in [CGFloat(49), CGFloat(60), CGFloat(70), CGFloat(92), CGFloat(120)] {
                #expect(!blank.contains(NSPoint(x: origin + x, y: 12)))
            }
        }
        let collapsed = NSRect(x: 0, y: 0, width: 24, height: 24)
        #expect(StatusItemController.boundaryRevealBounds(collapsed, spacer: 150,
            glyphWidth: 24).isEmpty)
        let titled = NSRect(x: 0, y: 0, width: 193, height: 24)
        let titleBlank = StatusItemController.boundaryRevealBounds(titled, spacer: 150,
            glyphWidth: 24, trailingWidth: 100)
        #expect(titleBlank.width == 49)
        #expect(!titleBlank.contains(NSPoint(x: 140, y: 12)))
    }

    @Test("a spacer awaiting native reflow leaves the measured icon seat unhoverable")
    func hoverBoundsProtectMeasuredIconDuringReflow() {
        let collapsed = NSRect(x: 0, y: 0, width: 24, height: 24)
        let partial = NSRect(x: 0, y: 0, width: 100, height: 24)
        let settled = NSRect(x: 0, y: 0, width: 174, height: 24)
        let collapsedBlank = StatusItemController.boundaryRevealBounds(collapsed, spacer: 150)
        let partialBlank = StatusItemController.boundaryRevealBounds(partial, spacer: 150)
        let settledBlank = StatusItemController.boundaryRevealBounds(settled, spacer: 150)
        #expect(collapsedBlank.isEmpty)
        #expect(!collapsedBlank.contains(NSPoint(x: 12, y: 12)))
        #expect(partialBlank.maxX <= 76)
        #expect(!partialBlank.contains(NSPoint(x: 88, y: 12)))
        #expect(settledBlank.width == 130)
        #expect(!settledBlank.contains(NSPoint(x: 162, y: 12)))
        let wideIconBlank = StatusItemController.boundaryRevealBounds(partial, spacer: 150, glyphWidth: 39)
        #expect(wideIconBlank.maxX == 41)
        let normalWideIcon = NSRect(x: 0, y: 0, width: 189, height: 24)
        #expect(StatusItemController.boundaryRevealBounds(normalWideIcon, spacer: 150,
                                                         glyphWidth: 39).width == 130)
    }

    @MainActor
    @Test("host hover frames contain only the blank spacer across translated displays")
    func hostHoverFrameExcludesIconAcrossDisplays() {
        let height = CGDisplayBounds(CGMainDisplayID()).height
        for origin in [CGPoint(x: 450, y: 4), CGPoint(x: -1200, y: -700),
                       CGPoint(x: 2100, y: 300)] {
            let utility = MenuBarUtility()
            let host = FakeHost()
            host.frame = CGRect(origin: origin, size: CGSize(width: 174, height: 24))
            host.boundaryGlyphLength = 24
            let blank = NSRect(x: origin.x, y: height - origin.y - 24, width: 130, height: 24)
            host.boundaryHoverFrame = blank
            utility.host = host
            #expect(utility.reveal.hotFrames() == [blank])
            let icon = NSPoint(x: blank.maxX + 32, y: blank.midY)
            #expect(!utility.reveal.hotFrames().contains { $0.contains(icon) })
            #expect(utility.reveal.clickHandledFrames().contains { $0.contains(icon) },
                    "the native button still owns the icon's click")
        }
    }

    @MainActor
    @Test("a host with no spacer publishes no hoverable icon")
    func hostCollapsedSpacerHasNoHotFrame() {
        let utility = MenuBarUtility()
        let host = FakeHost()
        let height = CGDisplayBounds(CGMainDisplayID()).height
        host.frame = CGRect(x: 450, y: 4, width: 24, height: 24)
        host.boundaryGlyphLength = 24
        host.boundaryHoverFrame = NSRect(x: 450, y: height - 28, width: 0, height: 24)
        utility.host = host
        let icon = NSPoint(x: 462, y: height - 16)
        #expect(!utility.reveal.hotFrames().contains { $0.contains(icon) })
        #expect(utility.reveal.clickHandledFrames().contains { $0.contains(icon) })
    }

    @MainActor
    @Test("with a host the boundary is the JR-Bar icon: the spacer is the length past the icon")
    func hostIsTheBoundary() {
        let utility = MenuBarUtility()
        let host = FakeHost()
        utility.settings = { MenuBarSettings(enabled: true) }
        utility.host = host
        utility.hider.rowRect = { self.row }
        utility.hider.guessedFitEdge = { 902 }
        utility.hider.edgeStore = MenuBarMemoryFitEdgeStore()
        utility.hider.edgeKey = { "test" }
        utility.hider.shuttersSuppressed = true
        utility.hider.listingIsComplete = { true }
        utility.hider.listItems = { [self.item("Left", x: 1000), self.item("Right", x: 1130)] }
        utility.hider.now = Self.fastClock()
        utility.installBoundary()
        settle(utility.hider)
        // The icon's right edge is 1123: 1123 − 902 = 221 of length,
        // less the 39-point icon = 182 of spacer.
        #expect(host.spacers.last == 182)
        #expect(utility.lastPlan.hidden.map(\.id) == ["Left"])
        #expect(utility.lastPlan.shown.map(\.id) == ["Right"])
        #expect(host.hiddenCount == 1)
        utility.hider.reveal([.hidden])
        #expect(host.spacers.last == 0, "revealed, the native spacer folds completely")
        #expect(host.hiddenRevealed)
        utility.removeBoundary()
        #expect(host.hiddenCount == 0)
    }

    @MainActor
    @Test("a gesture only opens the Item Bar — a second one never folds it, and a fold's own click never reopens it")
    func gesturesOpenIdempotently() {
        let utility = MenuBarUtility()
        utility.settings = {
            MenuBarSettings(enabled: true, sections: ["A": .hidden], revealStyle: .bar)
        }
        utility.hider.listingIsComplete = { true }
        utility.hider.listItems = { [self.item("A", x: 100)] }
        utility.hider.rowRect = { self.row }
        utility.hider.shuttersSuppressed = true
        utility.hider.reconcile()
        utility.reveal.onReveal()
        #expect(utility.bar.isOpen)
        // The scroll stream's next tick, a hover re-entry.
        utility.reveal.onReveal()
        #expect(utility.bar.isOpen, "a gesture never folds the bar")
        // A click on the blank stretch: the bar's outside-click monitor
        // folds it, and the same click's reveal lands a hop later.
        utility.bar.close()
        utility.reveal.onReveal()
        #expect(!utility.bar.isOpen, "the click that folded the bar does not reopen it")
        #expect(MenuBarUtility.gestureRefolds(closedAt: 10, now: 10.1))
        #expect(!MenuBarUtility.gestureRefolds(closedAt: 10, now: 10.5))
        #expect(!MenuBarUtility.gestureRefolds(closedAt: -.infinity, now: 0))
    }

    @MainActor
    @Test("the boundary is the host's spacer: install claims the affordance, teardown folds it, no host holds none")
    func boundaryLifecycle() {
        let utility = MenuBarUtility()
        utility.settings = { MenuBarSettings(enabled: true) }
        // No host, no boundary: nothing is registered to stand in.
        utility.installBoundary()
        utility.removeBoundary()
        let host = FakeHost()
        utility.host = host
        #expect(host.spacers.isEmpty, "a parked utility claims nothing when the host arrives")
        utility.installBoundary()
        utility.installBoundary()
        #expect(host.spacers == [30, 30], "the affordance, however often the settings re-apply")
        host.hiddenCount = 3
        host.hiddenRevealed = true
        utility.removeBoundary()
        #expect(host.spacers.last == 0, "teardown folds the spacer")
        #expect(host.hiddenCount == 0)
        #expect(!host.hiddenRevealed)
        // Stop on a parked utility is a no-op.
        utility.stop()
        #expect(host.spacers.count == 3)
    }

    @Test("the retired items' slots are cleared, and the app's own item's never")
    func retiredItemKeys() {
        var removed: [String] = []
        MenuBarUtility.forgetRetiredItems { removed.append($0) }
        #expect(removed == MenuBarUtility.retiredItemKeys)
        #expect(removed.contains("NSStatusItem VisibleCC com.jonathanreed.jrbar.menubar-chevron-v2"))
        #expect(!removed.contains { $0.hasSuffix(".status-item") }, "the icon's own slot stays")
    }

    @Test("the host folds the icon at the right end of its spacer, ‹ mark drawn inside it")
    func hostFold() {
        let icon = NSImage(size: NSSize(width: 39, height: 18), flipped: false) { _ in true }
        icon.isTemplate = true
        let plain = StatusItemController.folded(icon, spacer: 120, chevron: false)
        #expect(plain.size.width == 159)
        #expect(plain.isTemplate)
        let hinted = StatusItemController.folded(icon, spacer: 120, chevron: true, hintTint: .white)
        #expect(hinted.size.width == 159)
        let bounds = NSRect(x: 0, y: 0, width: 159, height: 24)
        let blank = StatusItemController.boundaryRevealBounds(bounds, spacer: 120, glyphWidth: 39)
        #expect(blank.contains(NSPoint(x: 30, y: 12)))
        #expect(!blank.contains(NSPoint(x: 100, y: 12)))
        #expect(!blank.contains(NSPoint(x: 130, y: 12)))
        #expect(StatusItemController.boundaryRevealBounds(bounds, spacer: 0).isEmpty)
    }

    @Test("the boundary's glyph share follows the host's icon, not the chevron constant")
    func hostGlyphShare() {
        let wide = MenuBarControlFrames(hidden: CGRect(x: 1084, y: 0, width: 39, height: 24),
                                        hiddenGlyph: 39)
        let items = [item("UnderIcon", x: 1090), item("Right", x: 1130)]
        let plan = MenuBarItemHider.plan(items: items, sections: [:], row: row,
                                         controls: wide, fitEdge: 902)
        #expect(plan.hidden.isEmpty, "an item overlapping the icon itself is not under a spacer")
        #expect(plan.hiddenControlLength == 221)
        let collapsed = MenuBarItemHider.plan(items: items, sections: [:], row: row,
                                              controls: wide, fitEdge: nil)
        #expect(collapsed.hiddenControlLength == 39, "no edge: the icon alone")
    }

    // MARK: Ear avoidance

    @Test("an item straddling the island edge still clamps the wing — side is by centre, not edge clearance")
    func earLimitStraddler() {
        // The island spans 795–857; a foreign item's slot at 824–893
        // crosses its right edge. The old fully-clear test skipped it and
        // the wing drew straight over the item.
        let island = CGRect(x: 795, y: 0, width: 62, height: 30)
        let straddler = item("Foreign", x: 824, w: 69)
        let further = item("Right", x: 1130)
        let (left, right) = MenuBarUtility.earLimits(
            items: [straddler, further], island: island, row: row,
            concealedApps: [:], sections: [:], revealed: [],
            ourPID: 999)
        #expect(right == 824, "the straddler's left edge is the right ear's limit")
        #expect(left == nil)
        // An item whose centre is left of the island's clamps the left ear.
        let leftItem = item("Left", x: 700, w: 24)
        let (l2, _) = MenuBarUtility.earLimits(
            items: [leftItem], island: island, row: row,
            concealedApps: [:], sections: [:], revealed: [],
            ourPID: 999)
        #expect(l2 == 724)
        // A concealed item not revealed earns no limit — it is invisible.
        let hidden = item("Hidden", x: 900, w: 24)
        let (_, r3) = MenuBarUtility.earLimits(
            items: [hidden], island: island, row: row,
            concealedApps: [:], sections: ["Hidden": .hidden], revealed: [],
            ourPID: 999)
        #expect(r3 == nil, "a covered item paves nothing — the wing may stand on it")
    }

    @Test("our own items never clamp the ear — the anchor is the island's slot, the ‹ is its mark")
    func earLimitOwnItem() {
        // The live wound: the slim 28pt anchor seats on-row beside the
        // notch's right edge (824–852 under an island spanning 795–857),
        // lands in plan.shown as a protected owner, and clamps the right
        // ear to under a point — the ‹ handle vanishes and the island
        // face goes blank where the icon sits.
        let island = CGRect(x: 795, y: 0, width: 62, height: 30)
        let anchor = item("JR-Bar", x: 824, w: 28, pid: 500)
        let foreign = item("Foreign", x: 1130, pid: 700)
        let (left, right) = MenuBarUtility.earLimits(
            items: [anchor, foreign], island: island, row: row,
            concealedApps: [:], sections: [:], revealed: [],
            ourPID: 500)
        #expect(right == 1130, "our anchor is exempt — the foreign item still limits")
        #expect(left == nil)
        // Another app's item at the same slot still clamps — only ours is exempt.
        let foreignAnchor = item("ForeignAnchor", x: 824, w: 28, pid: 700)
        let (_, r2) = MenuBarUtility.earLimits(
            items: [foreignAnchor], island: island, row: row,
            concealedApps: [:], sections: [:], revealed: [],
            ourPID: 500)
        #expect(r2 == 824)
    }
}
