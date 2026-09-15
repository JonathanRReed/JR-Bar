import AppKit
import Foundation
import Testing
@testable import JRBarApp
@testable import JRBarCore

/// The Menu Bar utility's positional model (docs/UTILITIES.md): an
/// item's section is where it sits relative to the controls, hiding is
/// the control's spacer growing to pack the items left of it off the
/// row, and the section map is overrides only. All pure inputs — no
/// screen, no status items.
@Suite("Menu Bar — spacers")
struct MenuBarSpacerTests {
    private func item(_ id: String, owner: String = "App", x: Double, y: Double = 0,
                      w: Double = 24, overflow: Bool = false) -> MenuBarItem {
        MenuBarItem(id: id, ownerPID: 500, ownerName: owner,
                    bounds: CGRect(x: x, y: y, width: w, height: 24),
                    title: nil, windowID: 0, isNativeOverflowControl: overflow)
    }

    private let row = CGRect(x: 0, y: 0, width: 1512, height: 24)
    /// The notch's right edge on a 1512-point display.
    private let regionMin: CGFloat = 852
    /// Collapsed controls: the always-hidden control at 880, the
    /// chevron at 926 — both one glyph wide.
    private let controls = MenuBarControlFrames(
        hidden: CGRect(x: 926, y: 0, width: 24, height: 24),
        alwaysHidden: CGRect(x: 880, y: 0, width: 24, height: 24))

    // MARK: Sections are positional

    @Test("left of the chevron is hidden, left of the always-hidden control is deeper, the rest shown")
    func positionalSections() {
        let items = [item("Deep", x: 856), item("Mid", x: 900), item("Up", x: 964),
                     item("Up2", x: 1002)]
        let plan = MenuBarItemHider.plan(items: items, sections: [:], row: row,
                                         controls: controls, regionMin: regionMin)
        #expect(plan.alwaysHidden.map(\.id) == ["Deep"])
        #expect(plan.hidden.map(\.id) == ["Mid"])
        #expect(plan.shown.map(\.id) == ["Up", "Up2"])
        // Positionally hidden items are pushed, never covered.
        #expect(plan.hiddenCovers.isEmpty)
        #expect(plan.alwaysHiddenCovers.isEmpty)
    }

    @Test("an item under an expanded control's spacer counts as hidden, not shown")
    func underSpacer() {
        // The chevron has grown to span 864…986; an item macOS stacked
        // at 956 reports inside that span.
        let expanded = MenuBarControlFrames(
            hidden: CGRect(x: 864, y: 0, width: 122, height: 24))
        let items = [item("Stacked", x: 956), item("Up", x: 998)]
        let plan = MenuBarItemHider.plan(items: items, sections: [:], row: row,
                                         controls: expanded, regionMin: regionMin)
        #expect(plan.hidden.map(\.id) == ["Stacked"])
        #expect(plan.shown.map(\.id) == ["Up"])
    }

    @Test("an item stacked under macOS's own overflow control is parked, not shown")
    func stackedUnderOverflow() {
        let overflow = item("Overflow", owner: "MenuBarAgent", x: 970, w: 17, overflow: true)
        let items = [overflow, item("Stacked", x: 966), item("Up", x: 1002)]
        let plan = MenuBarItemHider.plan(items: items, sections: [:], row: row,
                                         controls: MenuBarControlFrames(), regionMin: regionMin)
        #expect(plan.hidden.map(\.id) == ["Stacked"])
        #expect(plan.shown.map(\.id) == ["Overflow", "Up"],
                "the system's control is protected and lists as shown for the hit test")
    }

    @Test("an override covers an item that sits right of the chevron; a shown override is no override")
    func overridesCover() {
        let items = [item("Up", x: 964), item("Up2", x: 1002)]
        let plan = MenuBarItemHider.plan(items: items,
                                         sections: ["Up": .hidden, "Up2": .shown], row: row,
                                         controls: controls, regionMin: regionMin)
        #expect(plan.hidden.map(\.id) == ["Up"])
        #expect(plan.hiddenCovers == [964...988])
        #expect(plan.shown.map(\.id) == ["Up2"])
    }

    @Test("an override on an item already left of the chevron changes its section but draws no cover")
    func overrideDeeper() {
        let items = [item("Mid", x: 900)]
        let plan = MenuBarItemHider.plan(items: items, sections: ["Mid": .alwaysHidden],
                                         row: row, controls: controls, regionMin: regionMin)
        #expect(plan.alwaysHidden.map(\.id) == ["Mid"])
        #expect(plan.alwaysHiddenCovers.isEmpty)
    }

    @Test("parked items are hidden regardless of position; only an override calls them always-hidden")
    func parkedItems() {
        let items = [item("P", x: 7, y: 970), item("Q", x: 7, y: 970)]
        let plan = MenuBarItemHider.plan(items: items, sections: ["Q": .alwaysHidden],
                                         row: row, controls: controls, regionMin: regionMin)
        #expect(plan.hidden.map(\.id) == ["P"])
        #expect(plan.alwaysHidden.map(\.id) == ["Q"])
    }

    @Test("without controls on the row nothing is positionally hidden")
    func noControls() {
        let items = [item("A", x: 900), item("B", x: 1002)]
        let plan = MenuBarItemHider.plan(items: items, sections: [:], row: row,
                                         controls: MenuBarControlFrames(), regionMin: regionMin)
        #expect(plan.shown.map(\.id) == ["A", "B"])
        #expect(plan.hiddenControlLength == nil)
        #expect(plan.alwaysHiddenControlLength == nil)
    }

    // MARK: Spacer lengths

    @Test("a control on the row claims the stretch from the region's margin to its right edge")
    func spacerLengths() {
        let plan = MenuBarItemHider.plan(items: [], sections: [:], row: row,
                                         controls: controls, regionMin: regionMin)
        // Chevron right edge 950 − 852 − 22 = 76: the « needs its room.
        #expect(plan.hiddenControlLength == 76)
        // Always-hidden right edge 904 − 852 − 22 = 30.
        #expect(plan.alwaysHiddenControlLength == 30)
        #expect(MenuBarItemHider.spacerLength(
            controlFrame: CGRect(x: 926, y: 0, width: 24, height: 24), regionMin: regionMin) == 76)
        #expect(MenuBarItemHider.spacerMargin > 17, "wider than the « button")
        #expect(MenuBarItemHider.spacerMargin < 22 + 1, "narrower than any item")
    }

    @Test("a revealed section collapses its control to the glyph; an unknown region collapses both")
    func revealedCollapses() {
        let revealed = MenuBarItemHider.plan(items: [], sections: [:], row: row,
                                             controls: controls, regionMin: regionMin,
                                             revealed: [.hidden])
        #expect(revealed.hiddenControlLength == MenuBarControlFrames.glyphLength)
        #expect(revealed.alwaysHiddenControlLength == 30)
        let unknown = MenuBarItemHider.plan(items: [], sections: [:], row: row,
                                            controls: controls, regionMin: nil)
        #expect(unknown.hiddenControlLength == MenuBarControlFrames.glyphLength)
        #expect(unknown.alwaysHiddenControlLength == MenuBarControlFrames.glyphLength)
    }

    @Test("a cap bounds the spacer and never drops it under the glyph")
    func caps() {
        let capped = MenuBarItemHider.plan(items: [], sections: [:], row: row,
                                           controls: controls, regionMin: regionMin,
                                           caps: MenuBarSpacerCaps(hidden: 50))
        #expect(capped.hiddenControlLength == 50)
        #expect(MenuBarItemHider.spacerLength(
            controlFrame: CGRect(x: 926, y: 0, width: 24, height: 24),
            regionMin: regionMin, cap: 10) == MenuBarControlFrames.glyphLength)
        // A control whose right edge is already at the margin claims
        // just the glyph.
        #expect(MenuBarItemHider.spacerLength(
            controlFrame: CGRect(x: 852, y: 0, width: 24, height: 24),
            regionMin: regionMin) == MenuBarControlFrames.glyphLength)
    }

    @Test("a control off the row reports no length — nothing to write until it is back")
    func offRowControl() {
        let pushed = MenuBarControlFrames(
            hidden: CGRect(x: 926, y: 0, width: 24, height: 24),
            alwaysHidden: CGRect(x: 7, y: 970, width: 24, height: 24))
        let plan = MenuBarItemHider.plan(items: [], sections: [:], row: row,
                                         controls: pushed, regionMin: regionMin)
        #expect(plan.hiddenControlLength == 76)
        #expect(plan.alwaysHiddenControlLength == nil)
    }

    // MARK: The hider drives the controls

    @MainActor
    private func makeHider(controls: @escaping @MainActor () -> MenuBarControlFrames,
                           items: [MenuBarItem] = []) -> (MenuBarItemHider, () -> [(MenuBarItemSection, CGFloat)]) {
        final class Box { var writes: [(MenuBarItemSection, CGFloat)] = [] }
        let box = Box()
        let hider = MenuBarItemHider()
        hider.listItems = { items }
        hider.rowRect = { self.row }
        hider.controlFrames = controls
        hider.regionMin = { self.regionMin }
        hider.shuttersSuppressed = true
        hider.settings = { MenuBarSettings(enabled: true) }
        hider.setControlLength = { section, length in box.writes.append((section, length)) }
        return (hider, { box.writes })
    }

    @MainActor
    @Test("reconcile writes each control's length once, reveal collapses, hide grows it back")
    func reconcileWritesLengths() {
        let (hider, writes) = makeHider(controls: { self.controls })
        hider.reconcile()
        #expect(writes().map(\.0) == [.hidden, .alwaysHidden])
        #expect(writes().map(\.1) == [76, 30])
        hider.reconcile()
        #expect(writes().count == 2, "an unchanged length is not rewritten")
        hider.reveal([.hidden])
        #expect(writes().last?.0 == .hidden)
        #expect(writes().last?.1 == MenuBarControlFrames.glyphLength)
        hider.hide()
        #expect(writes().last?.1 == 76)
    }

    @MainActor
    @Test("a chevron found parked lowers its cap and collapses; the next pass grows it under the cap")
    func parkedChevronLearnsCap() {
        var frames = controls
        let (hider, writes) = makeHider(controls: { frames })
        hider.reconcile()
        #expect(hider.assignedLengths[.hidden] == 76)
        // macOS parked it: the frame reports off the row.
        frames.hidden = CGRect(x: 0, y: 1000, width: 76, height: 24)
        hider.reconcile()
        #expect(hider.caps.hidden == 76 - MenuBarItemHider.capStep)
        #expect(writes().last?.0 == .hidden)
        #expect(writes().last?.1 == MenuBarControlFrames.glyphLength)
        // Back on the row, it grows again — but only to the cap.
        frames.hidden = CGRect(x: 926, y: 0, width: 24, height: 24)
        hider.reconcile()
        #expect(hider.assignedLengths[.hidden] == 36)
        hider.resetCaps()
        hider.reconcile()
        #expect(hider.assignedLengths[.hidden] == 76)
    }

    @MainActor
    @Test("the always-hidden control pushed off by an expanded chevron is not a parked control")
    func pushedAlwaysHiddenIsNotParked() {
        var frames = controls
        let (hider, _) = makeHider(controls: { frames })
        hider.reconcile()
        // The chevron is expanded (86) and the ah control went with the
        // hidden run: expected, no cap learned.
        frames.alwaysHidden = CGRect(x: 7, y: 970, width: 40, height: 24)
        hider.reconcile()
        #expect(hider.caps.alwaysHidden == .infinity)
        #expect(hider.assignedLengths[.alwaysHidden] == 30)
    }

    @MainActor
    @Test("stop collapses both controls and forgets the reveal")
    func stopCollapses() {
        let (hider, writes) = makeHider(controls: { self.controls })
        hider.reconcile()
        hider.reveal([.alwaysHidden])
        hider.stop()
        #expect(hider.revealed.isEmpty)
        #expect(hider.assignedLengths[.hidden] == MenuBarControlFrames.glyphLength)
        #expect(hider.assignedLengths[.alwaysHidden] == MenuBarControlFrames.glyphLength)
        #expect(writes().last?.1 == MenuBarControlFrames.glyphLength)
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
        // A fresh override written under the current model survives.
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
}

extension MenuBarSpacerTests {
    @Test("an always-hidden control stacked under the expanded chevron is pushed, not a boundary")
    func pushedAlwaysHidden() {
        // The chevron grew to 833…985; macOS reports the pushed control
        // stacked inside that span.
        let pushed = MenuBarControlFrames(
            hidden: CGRect(x: 833, y: 0, width: 152, height: 24),
            alwaysHidden: CGRect(x: 833, y: 0, width: 152, height: 24))
        #expect(MenuBarItemHider.alwaysHiddenPushed(controls: pushed, row: row))
        let plan = MenuBarItemHider.plan(items: [], sections: [:], row: row,
                                         controls: pushed, regionMin: regionMin)
        #expect(plan.alwaysHiddenControlLength == nil, "no slot to size from")
        #expect(plan.hiddenControlLength == 111)
        // Side by side, both stand.
        #expect(!MenuBarItemHider.alwaysHiddenPushed(controls: controls, row: row))
    }

    @MainActor
    @Test("a pushed always-hidden control collapses to its glyph so it returns small")
    func pushedCollapses() {
        var frames = controls
        let (hider, writes) = makeHider(controls: { frames })
        hider.reconcile()
        #expect(hider.assignedLengths[.alwaysHidden] == 30)
        frames.hidden = CGRect(x: 833, y: 0, width: 152, height: 24)
        frames.alwaysHidden = CGRect(x: 840, y: 0, width: 140, height: 24)
        hider.reconcile()
        #expect(hider.assignedLengths[.alwaysHidden] == MenuBarControlFrames.glyphLength)
        #expect(writes().contains { $0.0 == .alwaysHidden && $0.1 == MenuBarControlFrames.glyphLength })
        #expect(hider.caps.alwaysHidden == .infinity, "pushed is not parked — no cap learned")
    }

    @MainActor
    @Test("reinstalled controls forget the old lengths so the new items get sized again")
    func reinstallForgets() {
        let (hider, writes) = makeHider(controls: { self.controls })
        hider.reconcile()
        let before = writes().count
        hider.controlsReinstalled()
        hider.reconcile()
        #expect(writes().count == before + 2, "both lengths are handed to the fresh items")
    }

    @Test("the « landing on our glyph means the chevron itself was overflowed")
    func overflowDetection() {
        let chevron = CGRect(x: 851, y: 0, width: 135, height: 24)
        let overflowOnGlyph = item("«", owner: "MenuBarAgent", x: 976, w: 17, overflow: true)
        #expect(MenuBarItemHider.controlOverflowed(controlFrame: chevron, items: [overflowOnGlyph], row: row))
        let overflowLeft = item("«", owner: "MenuBarAgent", x: 848, w: 17, overflow: true)
        #expect(!MenuBarItemHider.controlOverflowed(controlFrame: chevron, items: [overflowLeft], row: row))
        #expect(!MenuBarItemHider.controlOverflowed(controlFrame: chevron, items: [], row: row))
    }

    @MainActor
    @Test("an overflowed chevron lowers its cap one step per fresh listing until it fits")
    func overflowLearnsCap() {
        var items: [MenuBarItem] = []
        var generation = 0
        let hider = MenuBarItemHider()
        hider.listItems = { items }
        hider.rowRect = { self.row }
        hider.controlFrames = { self.controls }
        hider.regionMin = { self.regionMin }
        hider.listingGeneration = { generation }
        hider.shuttersSuppressed = true
        hider.settings = { MenuBarSettings(enabled: true) }
        hider.reconcile()
        #expect(hider.assignedLengths[.hidden] == 76)
        // A « on the glyph in a listing from before the write proves
        // nothing — the bar has not reflowed yet.
        items = [item("«", owner: "MenuBarAgent", x: 940, w: 17, overflow: true)]
        hider.reconcile()
        #expect(hider.caps.hidden == .infinity, "stale frames never shrink the spacer")
        generation += 1
        hider.reconcile()
        #expect(hider.caps.hidden == 76 - MenuBarItemHider.overflowStep)
        #expect(hider.assignedLengths[.hidden] == 68)
        // The same listing again: one step per reflow, never three.
        hider.reconcile()
        #expect(hider.caps.hidden == 68)
        // The « moved left of the glyph: no further shrink.
        generation += 1
        items = [item("«", owner: "MenuBarAgent", x: 860, w: 17, overflow: true)]
        hider.reconcile()
        #expect(hider.caps.hidden == 68)
    }

    @Test("a « standing left of the chevron is the region's real left edge")
    func overflowEdgeIsTheRegion() {
        let chevron = MenuBarControlFrames(hidden: CGRect(x: 926, y: 0, width: 24, height: 24))
        let overflowLeft = item("«", owner: "MenuBarAgent", x: 876, w: 17, overflow: true)
        #expect(MenuBarItemHider.effectiveRegionMin(regionMin, controls: chevron,
                                                    items: [overflowLeft], row: row) == 876)
        // On the glyph, it says nothing about the edge.
        let overflowOnGlyph = item("«", owner: "MenuBarAgent", x: 930, w: 17, overflow: true)
        #expect(MenuBarItemHider.effectiveRegionMin(regionMin, controls: chevron,
                                                    items: [overflowOnGlyph], row: row) == regionMin)
        #expect(MenuBarItemHider.effectiveRegionMin(nil, controls: chevron, items: [overflowLeft], row: row) == nil)
        // The spacer then lands flush against the «: 950 − 876 − 22 = 52.
        let plan = MenuBarItemHider.plan(items: [overflowLeft], sections: [:], row: row,
                                         controls: chevron, regionMin: 876)
        #expect(plan.hiddenControlLength == 52)
    }
}

