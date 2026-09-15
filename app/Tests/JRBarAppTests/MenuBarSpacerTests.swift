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
        // Chevron right edge 950 − 852 − 12 = 86.
        #expect(plan.hiddenControlLength == 86)
        // Always-hidden right edge 904 − 852 − 12 = 40.
        #expect(plan.alwaysHiddenControlLength == 40)
        #expect(MenuBarItemHider.spacerLength(
            controlFrame: CGRect(x: 926, y: 0, width: 24, height: 24), regionMin: regionMin) == 86)
    }

    @Test("a revealed section collapses its control to the glyph; an unknown region collapses both")
    func revealedCollapses() {
        let revealed = MenuBarItemHider.plan(items: [], sections: [:], row: row,
                                             controls: controls, regionMin: regionMin,
                                             revealed: [.hidden])
        #expect(revealed.hiddenControlLength == MenuBarControlFrames.glyphLength)
        #expect(revealed.alwaysHiddenControlLength == 40)
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
        #expect(plan.hiddenControlLength == 86)
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
        #expect(writes().map(\.1) == [86, 40])
        hider.reconcile()
        #expect(writes().count == 2, "an unchanged length is not rewritten")
        hider.reveal([.hidden])
        #expect(writes().last?.0 == .hidden)
        #expect(writes().last?.1 == MenuBarControlFrames.glyphLength)
        hider.hide()
        #expect(writes().last?.1 == 86)
    }

    @MainActor
    @Test("a chevron found parked lowers its cap and collapses; the next pass grows it under the cap")
    func parkedChevronLearnsCap() {
        var frames = controls
        let (hider, writes) = makeHider(controls: { frames })
        hider.reconcile()
        #expect(hider.assignedLengths[.hidden] == 86)
        // macOS parked it: the frame reports off the row.
        frames.hidden = CGRect(x: 0, y: 1000, width: 86, height: 24)
        hider.reconcile()
        #expect(hider.caps.hidden == 86 - MenuBarItemHider.capStep)
        #expect(writes().last?.0 == .hidden)
        #expect(writes().last?.1 == MenuBarControlFrames.glyphLength)
        // Back on the row, it grows again — but only to the cap.
        frames.hidden = CGRect(x: 926, y: 0, width: 24, height: 24)
        hider.reconcile()
        #expect(hider.assignedLengths[.hidden] == 46)
        hider.resetCaps()
        hider.reconcile()
        #expect(hider.assignedLengths[.hidden] == 86)
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
        #expect(hider.assignedLengths[.alwaysHidden] == 40)
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
        // The reseat is a separate one-time step that waits for the
        // controls to stand on a real bar.
        #expect(state.controlsSeated == false)
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
    @Test("the reseat lands the chevron just left of JR-Bar's item, calibrated off the chevron's own slot")
    func reseatPositions() {
        // The chevron seated at preferred 660 sits at x=926, so the bar's
        // offset is 1586; the main item at 1038 wants the chevron's left
        // edge at 1038 − 24 − 2 = 1012 → preferred 574.
        let positions = MenuBarUtility.reseatPositions(mainItemMinX: 1038, chevronMinX: 926,
                                                       chevronPreferred: 660)
        #expect(positions.chevron == 574)
        #expect(positions.alwaysHidden == 604)
    }
}
