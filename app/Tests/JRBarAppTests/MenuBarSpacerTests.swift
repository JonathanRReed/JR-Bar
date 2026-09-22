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
        // Settled at the narrower frame: a shorter length waits out the
        // shrink hold (the fast clock leaps past it), then goes out.
        frames.hidden = mid
        for _ in 0..<4 { settle(hider) }
        #expect(writes().count == 2)
        #expect(writes().last?.1 == 70)
    }

    @MainActor
    @Test("a bar that shifted left under the same length is held, not chased — and teaches nothing")
    func shiftIsHeld() {
        var t = Date()
        var frames = controls
        var items: [MenuBarItem] = []
        var generation = 0
        let store = MenuBarMemoryFitEdgeStore()
        let (hider, writes) = makeHider(controls: { frames }, store: store)
        hider.listItems = { items }
        hider.listingGeneration = { generation }
        hider.now = { t }
        settle(hider)
        #expect(writes().map(\.1) == [122])
        // The spacer landed: 902–1024.
        frames.hidden = CGRect(x: 902, y: 0, width: 122, height: 24)
        generation += 1
        hider.reconcile()
        // macOS shows its recording indicator beside the clock: the whole
        // bar shifts left 56 points, our item with it, and the « lands
        // on our glyph because we no longer fit.
        frames.hidden = CGRect(x: 846, y: 0, width: 122, height: 24)
        items = [item("«", owner: "MenuBarAgent", x: 1000, w: 17, overflow: true)]
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

    // MARK: Show All — explicit, and it survives a restart

    @MainActor
    @Test func showAllSurvivesRestart() throws {
        let utility = MenuBarUtility()
        var settings = MenuBarSettings(enabled: false)
        settings.concealedApps = ["com.example.one": .hidden, "com.example.two": .alwaysHidden]
        settings.sections = ["old-cover": .hidden]
        utility.settings = { settings }
        utility.onSettingsChange = { settings = $0 }
        utility.hider.listItems = { [] }
        utility.hider.rowRect = { self.row }
        utility.hider.onPlan = nil
        utility.showAllListed()
        let restored = try JSONDecoder().decode(MenuBarSettings.self,
            from: JSONEncoder().encode(settings))
        #expect(restored.concealedApps == ["com.example.one": .shown, "com.example.two": .shown])
        #expect(restored.sections.isEmpty)
    }

    // MARK: Ghost triage — only a novel on-row move proves a live escapee

    /// A concealed item's Accessibility ghost reports the frame it
    /// froze at forever — identical bounds, pass after pass, and it
    /// must never count as an escapee. Only a move to an on-row slot
    /// the ghost never showed is a registration the assertion missed.
    @Test("a frozen concealed item is the ghost, never an escapee")
    func concealedEscapeesGhost() {
        let frame = CGRect(x: 993, y: 4, width: 36, height: 24)
        let now = Date()
        let first = MenuBarUtility.concealedEscapees(
            onRow: ["cmux"], frames: ["cmux": frame],
            previous: [:], ghostHistory: [:], proven: [:], now: now)
        #expect(first.proven.isEmpty)
        #expect(first.ghostHistory["cmux"] == [frame])
        // Pass after pass at the same frame stays the ghost.
        let still = MenuBarUtility.concealedEscapees(
            onRow: ["cmux"], frames: ["cmux": frame],
            previous: ["cmux": frame], ghostHistory: first.ghostHistory,
            proven: first.proven, now: now)
        #expect(still.proven.isEmpty)
    }

    @Test("a move to a novel on-row slot is a live registration — inside the proof window")
    func concealedEscapeesMoves() {
        let old = CGRect(x: 993, y: 4, width: 36, height: 24)
        let new = CGRect(x: 940, y: 4, width: 36, height: 24)
        let t0 = Date()
        let proven = MenuBarUtility.concealedEscapees(
            onRow: ["cmux"], frames: ["cmux": new],
            previous: ["cmux": old], ghostHistory: ["cmux": [old]], proven: [:], now: t0)
        #expect(proven.proven["cmux"] == t0)
        // Holding still inside the window keeps the proof — a live
        // item standing still is still a live item.
        let still = MenuBarUtility.concealedEscapees(
            onRow: ["cmux"], frames: ["cmux": new],
            previous: ["cmux": new], ghostHistory: proven.ghostHistory,
            proven: proven.proven, now: t0.addingTimeInterval(5))
        #expect(still.proven["cmux"] == t0)
        // Ten seconds without a novel slot expires the proof — a
        // still-standing "escapee" reads as the ghost relayouted, and
        // its slot joins the ghost's history.
        let expired = MenuBarUtility.concealedEscapees(
            onRow: ["cmux"], frames: ["cmux": new],
            previous: ["cmux": new], ghostHistory: still.ghostHistory,
            proven: still.proven, now: t0.addingTimeInterval(11))
        #expect(expired.proven["cmux"] == nil)
        #expect(expired.ghostHistory["cmux"]?.contains(new) == true)
    }

    /// A MenuBarAgent restart relayouts the ghosts: the concealed run
    /// went from frozen on-row frames to parked ones, then reported
    /// back on-row at the same slots. A move back to a reported slot
    /// is the ghost's bookkeeping, not an escape.
    @Test("a ghost returning to a reported slot is still the ghost")
    func concealedEscapeesGhostReturn() {
        let slot = CGRect(x: 993, y: 4, width: 36, height: 24)
        let parked = CGRect(x: -1, y: 986, width: 36, height: 24)
        let now = Date()
        // Concealment: ghost reports its frozen slot once.
        let born = MenuBarUtility.concealedEscapees(
            onRow: ["cmux"], frames: ["cmux": slot],
            previous: [:], ghostHistory: [:], proven: [:], now: now)
        #expect(born.proven.isEmpty)
        // The agent's restart parks the ghost off-row — off-row reports
        // change nothing (the slot stays the only ghost frame known).
        let off = MenuBarUtility.concealedEscapees(
            onRow: [], frames: ["cmux": parked],
            previous: ["cmux": slot], ghostHistory: born.ghostHistory,
            proven: born.proven, now: now)
        #expect(off.proven.isEmpty)
        // Back on-row at the same slot: moved, yes, but the slot is in
        // the ghost's history — still the ghost, never an escapee.
        let back = MenuBarUtility.concealedEscapees(
            onRow: ["cmux"], frames: ["cmux": slot],
            previous: ["cmux": parked], ghostHistory: off.ghostHistory,
            proven: off.proven, now: now)
        #expect(back.proven.isEmpty)
    }

    @Test("a proven item returning to a ghost slot un-proves at once")
    func concealedEscapeesProofGhostReturn() {
        let ghost = CGRect(x: 993, y: 4, width: 36, height: 24)
        let novel = CGRect(x: 940, y: 4, width: 36, height: 24)
        let t0 = Date()
        let proven = MenuBarUtility.concealedEscapees(
            onRow: ["cmux"], frames: ["cmux": novel],
            previous: ["cmux": ghost], ghostHistory: ["cmux": [ghost]],
            proven: [:], now: t0)
        #expect(proven.proven["cmux"] == t0)
        // Back at the ghost's own slot two seconds later: proof gone —
        // the ghost's bookkeeping, not a live item.
        let back = MenuBarUtility.concealedEscapees(
            onRow: ["cmux"], frames: ["cmux": ghost],
            previous: ["cmux": novel], ghostHistory: proven.ghostHistory,
            proven: proven.proven, now: t0.addingTimeInterval(2))
        #expect(back.proven["cmux"] == nil)
    }

    @Test("proof decays off-row too — a vanished item is the ghost again in ten seconds")
    func concealedEscapeesOffRowDecay() {
        let ghost = CGRect(x: 993, y: 4, width: 36, height: 24)
        let novel = CGRect(x: 940, y: 4, width: 36, height: 24)
        let t0 = Date()
        let proven = MenuBarUtility.concealedEscapees(
            onRow: ["cmux"], frames: ["cmux": novel],
            previous: ["cmux": ghost], ghostHistory: ["cmux": [ghost]],
            proven: [:], now: t0)
        #expect(proven.proven["cmux"] == t0)
        // Gone from the row entirely: no sighting refreshes the stamp.
        let gone = MenuBarUtility.concealedEscapees(
            onRow: [], frames: [:], previous: [:],
            ghostHistory: proven.ghostHistory, proven: proven.proven,
            now: t0.addingTimeInterval(11))
        #expect(gone.proven.isEmpty)
    }

    @Test("a first sighting has no baseline — it is not an escape on its own")
    func concealedEscapeesFirstSeen() {
        let proven = MenuBarUtility.concealedEscapees(
            onRow: ["late"], frames: ["late": CGRect(x: 900, y: 4, width: 24, height: 24)],
            previous: [:], ghostHistory: [:], proven: [:], now: Date())
        #expect(proven.proven.isEmpty)
    }

    @Test("standings accumulate one per re-assert, ≥20 s apart — three earn the cover")
    func escapeStandings() {
        let t0 = Date()
        var stamps = MenuBarUtility.recordEscapeStanding(stamps: [], lastReassert: t0)
        // The same re-assert read twice counts once.
        stamps = MenuBarUtility.recordEscapeStanding(stamps: stamps, lastReassert: t0)
        #expect(stamps == [t0])
        // A re-assert closer than 20 s does not count.
        let close = MenuBarUtility.recordEscapeStanding(
            stamps: stamps, lastReassert: t0.addingTimeInterval(10))
        #expect(close == [t0])
        // Two more spaced re-asserts complete the proof.
        stamps = MenuBarUtility.recordEscapeStanding(
            stamps: stamps, lastReassert: t0.addingTimeInterval(21))
        stamps = MenuBarUtility.recordEscapeStanding(
            stamps: stamps, lastReassert: t0.addingTimeInterval(42))
        #expect(stamps.count == 3)
    }

    /// A solid or glyph-bearing tile, for the pixel-proof test.
    private func tileImage(_ draw: (CGContext) -> Void, size: Int = 32) -> CGImage? {
        guard let context = CGContext(
            data: nil, width: size, height: size, bitsPerComponent: 8,
            bytesPerRow: size * 4, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return nil }
        draw(context)
        return context.makeImage()
    }

    @Test("the pixel test: a drawn glyph has luma variance, empty bar material does not")
    func tilePixelProof() {
        let flat = tileImage { context in
            context.setFillColor(NSColor.windowBackgroundColor.cgColor)
            context.fill(CGRect(x: 0, y: 0, width: 32, height: 32))
        }
        #expect(!MenuBarUtility.tileHasPixels(flat))
        let glyph = tileImage { context in
            context.setFillColor(NSColor.white.cgColor)
            context.fill(CGRect(x: 0, y: 0, width: 32, height: 32))
            context.setFillColor(NSColor.black.cgColor)
            context.fill(CGRect(x: 10, y: 5, width: 12, height: 22))
        }
        #expect(MenuBarUtility.tileHasPixels(glyph))
        #expect(!MenuBarUtility.tileHasPixels(nil))
    }

    @Test("the palette reads effective sections — concealed items read hidden, Apple's the item map")
    func effectiveSections() {
        let concealed = MenuBarUtility.effectiveSection(
            itemID: "ChatGPT", bundleID: "com.openai.chat",
            sections: [:], concealedApps: ["com.openai.chat": .hidden],
            concealing: true, ownBundleID: "com.jonathanreed.jrbar")
        #expect(concealed == .hidden)
        // A concealed-map miss reads shown — the palette offers "Hide".
        let shown = MenuBarUtility.effectiveSection(
            itemID: "ChatGPT", bundleID: "com.openai.chat",
            sections: [:], concealedApps: [:],
            concealing: true, ownBundleID: "com.jonathanreed.jrbar")
        #expect(shown == .shown)
        // Apple extras have no app-level path — the positional map speaks.
        let apple = MenuBarUtility.effectiveSection(
            itemID: "Clock", bundleID: "com.apple.controlcenter",
            sections: ["Clock": .hidden],
            concealedApps: ["com.apple.controlcenter": .hidden],
            concealing: true, ownBundleID: "com.jonathanreed.jrbar")
        #expect(apple == .hidden)
        // Our own family is never concealed by us.
        let own = MenuBarUtility.effectiveSection(
            itemID: "JR-Bar", bundleID: "com.jonathanreed.jrbar.helper",
            sections: [:], concealedApps: ["com.jonathanreed.jrbar.helper": .hidden],
            concealing: true, ownBundleID: "com.jonathanreed.jrbar")
        #expect(own == .shown)
        // Spacer engine: the item map, always.
        let legacy = MenuBarUtility.effectiveSection(
            itemID: "ChatGPT", bundleID: "com.openai.chat",
            sections: ["ChatGPT": .alwaysHidden],
            concealedApps: ["com.openai.chat": .hidden],
            concealing: false, ownBundleID: "com.jonathanreed.jrbar")
        #expect(legacy == .alwaysHidden)
    }

    @Test("the Item Bar orders concealed apps by their last on-row x, unseen last")
    func itemBarOrder() {
        let apps: [String: MenuBarItemSection] = [
            "b.app": .hidden, "a.app": .alwaysHidden, "z.app": .hidden, "c.app": .hidden]
        let order = MenuBarUtility.concealedOrder(
            apps: apps, lastX: ["b.app": 940, "a.app": 1200, "z.app": 600])
        #expect(order.map(\.id) == ["z.app", "b.app", "a.app", "c.app"])
    }

    // MARK: The concealer's steady state — no lifts, no stale state

    /// Records what the utility's concealer asks of the agent.
    @MainActor
    private final class FakeConcealBackend: MenuBarConcealBackend {
        var log: [String] = []
        var n = 0
        func activate(allowedBundleIDs: [String]) async throws -> MenuBarAssertionToken {
            n += 1
            log.append("activate \(n): \(allowedBundleIDs.joined(separator: ","))")
            return MenuBarAssertionToken(NSNumber(value: n))
        }
        func invalidate(_ token: MenuBarAssertionToken) {
            log.append("invalidate \((token.object as! NSNumber).intValue)")
        }
    }

    @MainActor
    @Test("an unmapped app launch never lifts the bar — the union re-assert shows it")
    func launchNeverLifts() async {
        let fake = FakeConcealBackend()
        // "n.app" is the newcomer — the running read already answers it.
        let utility = MenuBarUtility(runningBundleIDRead: { ["h.app", "s.app", "n.app"] })
        utility.settings = {
            MenuBarSettings(enabled: true, concealedApps: ["h.app": .hidden], concealSeeded: true)
        }
        utility.concealer = MenuBarConcealer(backend: fake)
        utility.concealer?.apply(concealed: ["h.app"], running: ["h.app", "s.app"])
        try? await Task.sleep(nanoseconds: 100_000_000)
        #expect(fake.n == 1, "\(fake.log)")
        utility.noteWorkspaceChange()
        try? await Task.sleep(nanoseconds: 150_000_000)
        #expect(fake.n == 2, "one union re-assert, never a drop: \(fake.log)")
        #expect(utility.concealer?.isConcealing == true)
        // Every invalidate rides behind an activate — a standalone one
        // is a full lift, the churn this kills.
        for (index, entry) in fake.log.enumerated() where entry.hasPrefix("invalidate") {
            #expect(index > 0 && fake.log[index - 1].hasPrefix("activate"),
                    "a bare invalidate is a full lift: \(fake.log)")
        }
    }

    @MainActor
    @Test("disable releases the assertion and resets the hider — re-enable leaves no stale state")
    func stopConcealerResets() async {
        let fake = FakeConcealBackend()
        let utility = MenuBarUtility(runningBundleIDRead: { ["h.app", "s.app"] })
        utility.settings = {
            MenuBarSettings(enabled: true, concealedApps: ["h.app": .hidden], concealSeeded: true)
        }
        utility.concealer = MenuBarConcealer(backend: fake)
        utility.concealer?.apply(concealed: ["h.app"], running: ["h.app", "s.app"])
        try? await Task.sleep(nanoseconds: 100_000_000)
        utility.hider.shuttersSuppressed = true
        utility.hider.externalPlan = MenuBarHidePlan()
        utility.stopConcealer()
        #expect(utility.concealer == nil)
        #expect(utility.hider.externalPlan == nil)
        #expect(!utility.hider.shuttersSuppressed)
        try? await Task.sleep(nanoseconds: 150_000_000)
        #expect(fake.log.last == "invalidate 1", "the drop lands on disable: \(fake.log)")
        // Enable again: a fresh engine, and the hider's concealer
        // state resets just as clean — no stale covers ride along.
        utility.concealer = MenuBarConcealer(backend: fake)
        utility.hider.shuttersSuppressed = true
        utility.hider.externalPlan = MenuBarHidePlan()
        utility.stopConcealer()
        #expect(utility.hider.externalPlan == nil)
        #expect(!utility.hider.shuttersSuppressed)
        #expect(utility.concealer == nil)
    }

    @MainActor
    @Test("a parked icon at first scan does not hold the engine — seeding proceeds past the deadline")
    func seedAfterDeadline() {
        let utility = MenuBarUtility()
        var draft = MenuBarSettings(enabled: true)
        utility.settings = { draft }
        utility.onSettingsChange = { draft = $0 }
        // Our icon is parked — no own item in the listing — and the
        // engine is young: the seed still waits for it to land.
        utility.concealerStartedAt = Date()
        #expect(!utility.seedConcealedAppsIfNeeded(from: MenuBarHidePlan()))
        #expect(!draft.concealSeeded)
        // Past the deadline the same listing seeds anyway — a fresh
        // install can never wedge waiting for a visible icon.
        utility.concealerStartedAt = Date().addingTimeInterval(-9)
        #expect(utility.seedConcealedAppsIfNeeded(from: MenuBarHidePlan()))
        #expect(draft.concealSeeded)
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
        var boundaryGlyphLength: CGFloat = 39
        var spacers: [CGFloat] = []
        func setBoundarySpacer(_ length: CGFloat) { spacers.append(length) }
        var anchorWantsVisibleSeat = true
        var mirrors: [Bool] = []
        func setFaceMirrored(_ mirrored: Bool) { mirrors.append(mirrored) }
        var mirroredFaceFrame: NSRect?
        var face = MenuBarIconFace()
        var onFaceChange: (@MainActor () -> Void)?
        // The mirror's clicks are pinned in MenuBarIconMirrorTests.
        func faceClicked() {}
        func popUpMenu(in view: NSView) {}
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
        // One status item of ours: with a host the chevron is never
        // registered, not even hidden.
        #expect(utility.chevron == nil, "the host stands in for the chevron")
        settle(utility.hider)
        // The icon's right edge is 1123: 1123 − 902 = 221 of length,
        // less the 39-point icon = 182 of spacer.
        #expect(host.spacers.last == 182)
        #expect(utility.lastPlan.hidden.map(\.id) == ["Left"])
        #expect(utility.lastPlan.shown.map(\.id) == ["Right"])
        #expect(host.hiddenCount == 1)
        utility.hider.reveal([.hidden])
        #expect(host.spacers.last == 30, "revealed, the affordance floor keeps the drop zone visible")
        #expect(host.hiddenRevealed)
        utility.removeChevron()
        #expect(host.hiddenCount == 0)
        #expect(host.mirrors.isEmpty, "the spacer engine never hands the face to a mirror — the real item is the icon")
    }

    @MainActor
    @Test("a gesture only opens the Item Bar — a second one never folds it, and a fold's own click never reopens it")
    func gesturesOpenIdempotently() {
        let utility = MenuBarUtility()
        utility.settings = {
            MenuBarSettings(enabled: true, sections: ["A": .hidden], revealStyle: .bar)
        }
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
    @Test("a host arriving takes the fallback chevron down — one status item of ours")
    func hostRetiresTheChevron() {
        let utility = MenuBarUtility()
        utility.settings = { MenuBarSettings(enabled: true) }
        utility.installChevron()
        #expect(utility.chevron != nil, "no host: the chevron is the boundary")
        let host = FakeHost()
        utility.host = host
        utility.installChevron()
        #expect(utility.chevron == nil)
        utility.removeChevron()
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
            concealedApps: [:], sections: [:], revealed: [], chevron: nil,
            ourPID: 999)
        #expect(right == 824, "the straddler's left edge is the right ear's limit")
        #expect(left == nil)
        // An item whose centre is left of the island's clamps the left ear.
        let leftItem = item("Left", x: 700, w: 24)
        let (l2, _) = MenuBarUtility.earLimits(
            items: [leftItem], island: island, row: row,
            concealedApps: [:], sections: [:], revealed: [], chevron: nil,
            ourPID: 999)
        #expect(l2 == 724)
        // A concealed item not revealed earns no limit — it is invisible.
        let hidden = item("Hidden", x: 900, w: 24)
        let (_, r3) = MenuBarUtility.earLimits(
            items: [hidden], island: island, row: row,
            concealedApps: [:], sections: ["Hidden": .hidden], revealed: [],
            chevron: nil, ourPID: 999)
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
            concealedApps: [:], sections: [:], revealed: [], chevron: nil,
            ourPID: 500)
        #expect(right == 1130, "our anchor is exempt — the foreign item still limits")
        #expect(left == nil)
        // Another app's item at the same slot still clamps — only ours is exempt.
        let foreignAnchor = item("ForeignAnchor", x: 824, w: 28, pid: 700)
        let (_, r2) = MenuBarUtility.earLimits(
            items: [foreignAnchor], island: island, row: row,
            concealedApps: [:], sections: [:], revealed: [], chevron: nil,
            ourPID: 500)
        #expect(r2 == 824)
    }
}
