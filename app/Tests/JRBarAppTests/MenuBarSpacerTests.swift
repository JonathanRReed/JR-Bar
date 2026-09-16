import AppKit
import Foundation
import Testing
@testable import JRBarApp
@testable import JRBarCore

/// The Menu Bar utility's positional model (docs/UTILITIES.md): an
/// item's section is where it sits relative to the boundary, hiding is
/// the boundary's spacer growing from the fit edge to pack the items
/// left of it off the row, and the section map is overrides only. All
/// pure inputs — no screen, no status items.
@Suite("Menu Bar — spacers")
struct MenuBarSpacerTests {
    private func item(_ id: String, owner: String = "App", x: Double, y: Double = 0,
                      w: Double = 24, overflow: Bool = false) -> MenuBarItem {
        MenuBarItem(id: id, ownerPID: 500, ownerName: owner,
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
        var frames = controls
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
        // Settled at the narrower frame: two passes agree and it goes out.
        frames.hidden = mid
        settle(hider)
        #expect(writes().count == 2)
        #expect(writes().last?.1 == 70)
    }

    @MainActor
    @Test("two passes inside the cooldown do not write; after it they do")
    func cooldown() {
        var t = Date()
        var frames = controls
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
        var frames = controls
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
    @Test("an overflowed boundary moves the fit edge right one step per fresh listing, and remembers it")
    func overflowLearnsFitEdge() {
        var items: [MenuBarItem] = []
        var generation = 0
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
        var key = "1512x982"
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

    @Test("the control face is as wide as the control (less the bar's inset) and template")
    func controlFace() {
        let collapsed = MenuBarUtility.controlImage(symbol: "chevron.left", length: 24,
                                                    description: "x")
        #expect(collapsed?.size.width == 16)
        #expect(collapsed?.isTemplate == true)
        let expanded = MenuBarUtility.controlImage(symbol: "chevron.left", length: 120,
                                                   description: "x")
        #expect(expanded?.size.width == 112)
        #expect(expanded?.size.height == collapsed?.size.height)
    }

    // MARK: The boundary host — JR-Bar's own status item

    /// A host that records what the utility asks of it.
    @MainActor
    private final class FakeHost: MenuBarBoundaryHost {
        var frame: CGRect? = CGRect(x: 1084, y: 0, width: 39, height: 24)
        var boundaryFrame: CGRect? { frame }
        var boundaryGlyphLength: CGFloat = 39
        var spacers: [CGFloat] = []
        func setBoundarySpacer(_ length: CGFloat) { spacers.append(length) }
        var onBoundaryClick: (@MainActor () -> Void)?
        var hiddenItemsMenu: (@MainActor () -> NSMenu?)?
        var hiddenCount = 0
        var hiddenRevealed = false
    }

    @MainActor
    @Test("with a host the boundary is the JR-Bar icon: no chevron item, the spacer is the length past the icon")
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
        utility.hider.listItems = { [self.item("Left", x: 1000), self.item("Right", x: 1130)] }
        utility.hider.now = Self.fastClock()
        utility.installChevron()
        #expect(utility.chevron == nil, "the host stands in for the chevron")
        settle(utility.hider)
        // The icon's right edge is 1123: 1123 − 902 = 221 of length,
        // less the 39-point icon = 182 of spacer.
        #expect(host.spacers.last == 182)
        #expect(utility.lastPlan.hidden.map(\.id) == ["Left"])
        #expect(utility.lastPlan.shown.map(\.id) == ["Right"])
        #expect(host.hiddenCount == 1)
        utility.hider.reveal([.hidden])
        #expect(host.spacers.last == 0, "revealed, the icon folds to itself")
        #expect(host.hiddenRevealed)
        utility.removeChevron()
        #expect(host.hiddenCount == 0)
    }

    @Test("the host folds the icon at the right end of its spacer, chevron only while something hides")
    func hostFold() {
        let icon = NSImage(size: NSSize(width: 39, height: 18), flipped: false) { _ in true }
        icon.isTemplate = true
        let plain = StatusItemController.folded(icon, spacer: 120, chevron: false)
        #expect(plain.size.width == 159)
        #expect(plain.isTemplate)
        let hinted = StatusItemController.folded(icon, spacer: 120, chevron: true, hintTint: .white)
        #expect(hinted.size.width == 159)
        #expect(StatusItemController.clickIsOnSpacer(x: 30, spacer: 120))
        #expect(!StatusItemController.clickIsOnSpacer(x: 130, spacer: 120))
        #expect(!StatusItemController.clickIsOnSpacer(x: 10, spacer: 0))
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
}
