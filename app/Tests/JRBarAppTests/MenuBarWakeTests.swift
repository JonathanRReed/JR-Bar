import AppKit
import CoreGraphics
import Foundation
import Testing
@testable import JRBarApp
import JRBarCore

/// What the divider does when the bar re-forms under it (wake, displays,
/// session, Space), and the spacer that a settings write used to fold.
/// Every clock is cranked by hand, no test sleeps, and no run-loop timer is
/// involved: the hider's passes are called directly.
@Suite("Menu Bar — the divider after the bar re-forms")
struct MenuBarWakeTests {
    // MARK: Fixtures

    private let row = CGRect(x: 0, y: 0, width: 1512, height: 33)

    private func item(_ id: String, x: Double, w: Double = 28, y: Double = 4, pid: Int32 = 500) -> MenuBarItem {
        var item = MenuBarItem(id: id, ownerPID: pid, ownerName: id,
                               bounds: CGRect(x: x, y: y, width: w, height: 24), title: nil, windowID: 1)
        item.bundleID = "app.\(id.lowercased())"
        return item
    }

    @MainActor
    private final class Host: MenuBarBoundaryHost {
        /// Set to place the item by hand (parked, shifted, the wrong width);
        /// nil lets it follow the spacer: right edge fixed, width = icon + spacer.
        var manualFrame: CGRect?
        var boundaryFrame: CGRect? {
            if let manualFrame { return manualFrame }
            return CGRect(x: 1123 - (boundaryGlyphLength + spacer), y: 4,
                          width: boundaryGlyphLength + spacer, height: 24)
        }
        var boundaryGlyphLength: CGFloat = 39
        var spacer: CGFloat = 0
        var spacers: [CGFloat] = []
        func setBoundarySpacer(_ length: CGFloat) { spacer = length; spacers.append(length) }
        var onBoundaryClick: (@MainActor () -> Void)?
        var hiddenItemsMenu: (@MainActor () -> NSMenu?)?
        var hiddenCount = 0
        var hiddenRevealed = false
        var barAppearance: NSAppearance? { nil }
    }

    /// A hider on seams with a clock and a listing generation the test turns.
    @MainActor
    private final class Rig {
        let utility = MenuBarUtility()
        let host = Host()
        var settings = MenuBarSettings(enabled: true)
        var items: [MenuBarItem] = []
        var seconds: TimeInterval = 10_000
        var generation = 1
        var showing = true
        var scanned = true
        var hider: MenuBarItemHider { utility.hider }

        /// One pass at the current time and listing.
        func pass() { hider.reconcile() }

        /// Advance the clock and take a fresh listing, then one pass.
        func fresh(after delta: TimeInterval) {
            seconds += delta
            generation += 1
            hider.reconcile()
        }
    }

    @MainActor
    private func makeRig(_ items: [MenuBarItem] = []) -> Rig {
        let rig = Rig()
        rig.items = items
        let utility = rig.utility
        utility.settings = { rig.settings }
        utility.onSettingsChange = { rig.settings = $0 }
        utility.host = rig.host
        let hider = utility.hider
        hider.listingIsComplete = { true }
        hider.rowRect = { self.row }
        hider.listItems = { rig.items }
        hider.listingGeneration = { rig.generation }
        hider.listingIsScanned = { rig.scanned }
        hider.barShowing = { rig.showing }
        hider.barIsVisible = { true }
        hider.guessedFitEdge = { 902 }
        hider.edgeStore = MenuBarMemoryFitEdgeStore()
        hider.edgeKey = { "wake" }
        hider.shuttersSuppressed = true
        hider.spacerCeiling = { .infinity }
        hider.ourPID = 1
        hider.now = { Date(timeIntervalSinceReferenceDate: rig.seconds) }
        hider.onPlan = { [weak utility] plan in utility?.lastPlan = plan }
        return rig
    }

    /// The spacer the fixture settles at: the boundary's right edge (1123)
    /// less the fit edge (902) is 221, 182 of it past the icon's own 39 pt.
    private let settledSpacer: CGFloat = 182

    /// Let the first length out: two agreeing passes, a cooldown apart.
    @MainActor
    private func settle(_ rig: Rig) {
        rig.pass()
        rig.fresh(after: 2)
        #expect(rig.host.spacers.last == settledSpacer)
    }

    @MainActor
    @Test("a collapsed native reveal does not start a recovery re-seat", arguments: [false, true])
    func revealedSpacerDoesNotTriggerRecovery(forced: Bool) {
        let rig = makeRig([])
        settle(rig)
        defer { rig.hider.stop() }
        if forced {
            rig.hider.forcedReveal = { [.hidden] }
            rig.pass()
        } else {
            rig.hider.reveal([.hidden])
        }
        #expect(rig.host.spacer == 0)
        let writes = rig.host.spacers.count
        for _ in 0..<12 { rig.fresh(after: 1) }
        #expect(!rig.hider.wake.isOpen)
        #expect(rig.host.spacers.count == writes, "a healthy folded spacer must never be re-seated")
        #expect(rig.host.spacer == 0)
    }

    // MARK: The state machine

    private func healthy() -> MenuBarWakeRecovery.Health { .init() }
    private func overlapped(_ names: [String] = ["Typeless"]) -> MenuBarWakeRecovery.Health {
        .init(overlapping: names)
    }

    /// `#expect` cannot call a mutating member; the machine sits in a box.
    private final class Box {
        var recovery = MenuBarWakeRecovery()
        func event(_ now: TimeInterval) { recovery.noteEvent(now: now) }
        func look(_ now: TimeInterval, gen: Int, floor: Int = 0, judgeable: Bool = true,
                  _ health: MenuBarWakeRecovery.Health) -> MenuBarWakeRecovery.Action {
            recovery.assess(now: now, generation: gen, floor: floor, judgeable: judgeable, health: health)
        }
        func remeasure(_ now: TimeInterval) -> Bool { recovery.takeRemeasure(now: now) }
    }

    @Test("events inside the quiet extend it, but never past the longest from the first")
    func quietIsBounded() {
        let box = Box()
        box.event(100)
        #expect(box.recovery.isQuiet(now: 102))
        #expect(!box.recovery.isQuiet(now: 102.6))
        box.event(102)          // the displays wake as the Mac does
        #expect(box.recovery.isQuiet(now: 104))
        // A stream of events cannot hold the bar quiet forever.
        for beat in stride(from: 104.0, through: 120, by: 1) { box.event(beat) }
        #expect(!box.recovery.isQuiet(now: 100 + MenuBarWakeRecovery.longest + 0.1))
    }

    @Test("the re-measure is taken once, at the first look after the quiet")
    func remeasureOnce() {
        let box = Box()
        box.event(0)
        #expect(!box.remeasure(1), "not while the bar is forming")
        #expect(box.remeasure(3))
        #expect(!box.remeasure(4))
    }

    @Test("a clear icon closes the episode without a single write")
    func clearCloses() {
        let box = Box()
        box.event(0)
        #expect(box.look(1, gen: 5, healthy()) == .none, "inside the quiet nothing is judged")
        #expect(box.look(3, gen: 6, healthy()) == .none)
        #expect(box.recovery.verdict == .clear)
        #expect(!box.recovery.isOpen)
        #expect(MenuBarWakeRecovery.line(for: box.recovery.verdict) == nil)
    }

    @Test("trouble needs two fresh listings, is re-seated once, and then JR-Bar stops")
    func reseatOnceThenStop() {
        let box = Box()
        box.event(0)
        #expect(box.look(3, gen: 6, overlapped()) == .none, "one listing may be stale")
        #expect(box.look(3.1, gen: 6, overlapped()) == .none, "the same listing counts once")
        #expect(box.look(4, gen: 7, overlapped()) == .reseat)
        #expect(box.recovery.verdict == .reseated(.overlapped(["Typeless"])))
        // The re-seat's own settle is quiet again.
        #expect(box.recovery.isQuiet(now: 4.5))
        #expect(box.look(4.5, gen: 8, overlapped()) == .none)
        // After it: two more fresh listings that still disagree end it.
        #expect(box.look(7, gen: 9, overlapped()) == .none)
        #expect(box.look(8, gen: 10, overlapped()) == .none)
        #expect(box.recovery.verdict == .stuck(.overlapped(["Typeless"])))
        #expect(!box.recovery.isOpen)
        // No third try for the same event, however long it is looked at.
        for g in 11..<30 { #expect(box.look(Double(g) + 10, gen: g, overlapped()) == .none) }
        let line = MenuBarWakeRecovery.line(for: box.recovery.verdict)
        #expect(line?.contains("overlapped by Typeless") == true)
        #expect(line?.contains("re-seated once") == true)
    }

    @Test("a re-seat that worked says so, and a new event earns a new single try")
    func recoveredThenNewEvent() {
        let box = Box()
        box.event(0)
        _ = box.look(3, gen: 6, healthy().with(onRow: false))
        #expect(box.look(4, gen: 7, healthy().with(onRow: false)) == .reseat)
        #expect(box.look(7, gen: 9, healthy()) == .none)
        #expect(box.recovery.verdict == .recovered(.offRow))
        // The next wake opens a fresh episode with its own single re-seat.
        box.event(100)
        _ = box.look(104, gen: 20, overlapped())
        #expect(box.look(105, gen: 21, overlapped()) == .reseat)
    }

    @Test("a bar that cannot be judged (a hidden menu bar) is waited on, then dropped unverified")
    func unjudgeable() {
        let box = Box()
        box.event(0)
        #expect(box.look(5, gen: 6, judgeable: false, overlapped()) == .none)
        #expect(box.look(6, gen: 7, judgeable: false, overlapped()) == .none)
        #expect(box.recovery.isOpen)
        #expect(box.look(MenuBarWakeRecovery.giveUp + 1, gen: 8, judgeable: false, overlapped()) == .none)
        #expect(box.recovery.verdict == .unverified)
        #expect(!box.recovery.isOpen)
    }

    @Test("a Space change that never leaves a bar to judge ends without a word; a wake that does says so")
    func lightEpisodeIsSilent() {
        let box = Box()
        box.recovery.noteEvent(now: 0, light: true)
        _ = box.look(MenuBarWakeRecovery.giveUp + 1, gen: 3, judgeable: false, overlapped())
        #expect(box.recovery.verdict == .idle)
        let wake = Box()
        wake.recovery.noteEvent(now: 0, light: true)
        wake.recovery.noteEvent(now: 1)     // the Mac woke inside the same quiet
        _ = wake.look(MenuBarWakeRecovery.giveUp + 1, gen: 3, judgeable: false, overlapped())
        #expect(wake.recovery.verdict == .unverified)
    }

    @Test("a listing from before the last write is not a look")
    func staleListingIsNotALook() {
        let box = Box()
        box.event(0)
        #expect(box.look(3, gen: 4, floor: 4, overlapped()) == .none)
        #expect(box.look(4, gen: 4, floor: 4, overlapped()) == .none)
        #expect(box.look(5, gen: 5, floor: 4, overlapped()) == .none)
        #expect(box.look(6, gen: 6, floor: 4, overlapped()) == .reseat)
    }

    @Test("the bar going dark closes an episode with nothing to judge")
    func darkCloses() {
        let box = Box()
        box.event(0)
        box.recovery.noteDark()
        #expect(!box.recovery.isOpen)
        #expect(box.look(10, gen: 5, overlapped()) == .none)
    }

    @Test("overlap: someone else's item standing over the icon; not ours, not the «, not off the row")
    func overlapRule() {
        let icon = CGRect(x: 1084, y: 4, width: 39, height: 24)
        var overflow = item("Overflow", x: 1040)
        overflow.isNativeOverflowControl = true
        let items = [item("Typeless", x: 1100, pid: 77),
                     item("Graze", x: 1120, pid: 78),       // 3 pt in: a gap's rounding
                     item("Ours", x: 1084, pid: 1),
                     overflow,
                     item("Parked", x: 1090, y: 970, pid: 79)]
        #expect(MenuBarWakeRecovery.overlapping(icon: icon, row: row, items: items, ourPID: 1) == ["Typeless"])
        #expect(MenuBarWakeRecovery.overlapping(icon: CGRect(x: 1084, y: 970, width: 39, height: 24),
                                                row: row, items: items, ourPID: 1).isEmpty,
                "an icon that is off the row is another trouble, not an overlap")
    }

    @Test("native overflow stacks do not count as visible overlaps")
    func overflowStackIsNotAnOverlap() {
        let icon = CGRect(x: 860, y: 4, width: 39, height: 24)
        var overflow = item("Overflow", x: 869, w: 17.5, y: 1)
        overflow.isNativeOverflowControl = true
        let parked = [item("ParkedA", x: 855, w: 24),
                      item("ParkedB", x: 845, w: 42)]
        let visible = item("Visible", x: 887, w: 24)
        #expect(MenuBarWakeRecovery.overlapping(icon: icon, row: row,
            items: parked + [overflow], ourPID: 1).isEmpty)
        #expect(MenuBarWakeRecovery.overlapping(icon: icon, row: row,
            items: parked + [overflow, visible], ourPID: 1) == ["Visible"])
        var offRowOverflow = item("Overflow", x: 869, w: 17.5, y: 970)
        offRowOverflow.isNativeOverflowControl = true
        #expect(MenuBarWakeRecovery.overlapping(icon: icon, row: row,
            items: [parked[0], offRowOverflow], ourPID: 1) == ["ParkedA"])
    }

    @Test("the width that stands is the icon now plus the spacer written, or the floor when that is shorter")
    func widthRule() {
        let frame = { (w: CGFloat) in CGRect(x: 900, y: 4, width: w, height: 24) }
        func stands(_ w: CGFloat, written: CGFloat?, writtenGlyph: CGFloat = 39, glyph: CGFloat = 39) -> Bool {
            MenuBarWakeRecovery.widthStands(frame: frame(w), written: written, writtenGlyph: writtenGlyph,
                                            glyph: glyph, floor: 30)
        }
        #expect(stands(221, written: 221))
        #expect(!stands(69, written: 221), "a folded item that should be 221 wide")
        #expect(stands(69, written: 39), "a revealed run wears the floor")
        #expect(stands(69, written: nil))
        // The session dots widen the icon by 10 pt: the spacer written with it is the same.
        #expect(stands(231, written: 221, glyph: 49))
        #expect(!stands(221, written: 221, glyph: 49), "the icon grew but the item did not: the spacer was lost")
    }

    @Test("which notices re-form the bar, which take it away, and which are nothing")
    func noticeKinds() {
        #expect(MenuBarItemHider.reformsBar(NSWorkspace.didWakeNotification) == true)
        #expect(MenuBarItemHider.reformsBar(NSWorkspace.screensDidWakeNotification) == true)
        #expect(MenuBarItemHider.reformsBar(NSWorkspace.sessionDidBecomeActiveNotification) == true)
        #expect(MenuBarItemHider.reformsBar(NSWorkspace.activeSpaceDidChangeNotification) == true)
        #expect(MenuBarItemHider.reformsBar(NSWorkspace.willSleepNotification) == false)
        #expect(MenuBarItemHider.reformsBar(NSWorkspace.screensDidSleepNotification) == false)
        #expect(MenuBarItemHider.reformsBar(NSWorkspace.sessionDidResignActiveNotification) == false)
        #expect(MenuBarItemHider.reformsBar(NSWorkspace.didActivateApplicationNotification) == nil)
    }

    // MARK: The hider after a wake

    @MainActor
    @Test("after a wake the spacer is left alone while the bar forms, and a clear icon costs no write")
    func quietThenClear() {
        let rig = makeRig([item("Left", x: 1000), item("Right", x: 1130, w: 12)])
        settle(rig)
        let written = rig.host.spacers
        // The icon moves a little while the bar re-forms (the clock widens).
        rig.host.manualFrame = CGRect(x: 1094, y: 4, width: 39, height: 24)
        rig.hider.noteBarReformed("test wake")
        rig.fresh(after: 0.5)
        rig.fresh(after: 0.5)
        #expect(rig.host.spacers == written, "no write while the bar is forming")
        // The quiet ends; the bar is read clean and agrees with itself.
        rig.host.manualFrame = nil
        rig.fresh(after: 2)
        rig.fresh(after: 1)
        rig.fresh(after: 1)
        #expect(rig.hider.wake.verdict == .clear)
        #expect(rig.host.spacers == written, "a clear icon is never re-seated: no flicker")
    }

    @MainActor
    @Test("an icon macOS left under another app's item is re-seated once after a wake, then reported, never retried")
    func overlapIsReseatedOnceThenReported() {
        let rig = makeRig([item("Left", x: 1000), item("Typeless", x: 1100, pid: 77)])
        settle(rig)
        rig.hider.noteBarReformed("test wake")
        // Inside the quiet: nothing is written and nothing is judged.
        rig.fresh(after: 1)
        #expect(rig.hider.wake.verdict == .settling)
        // After it: two fresh listings agree the icon is overlapped.
        rig.fresh(after: 2)
        let before = rig.host.spacers.count
        rig.fresh(after: 0.5)
        #expect(rig.hider.wake.verdict == .reseated(.overlapped(["Typeless"])))
        #expect(rig.host.spacers.count == before + 1)
        #expect(rig.host.spacers.last == MenuBarUtility.boundaryAffordance, "folded to the floor")
        // The next pass writes the spacer again, at once.
        rig.fresh(after: 0.4)
        #expect(rig.host.spacers.last == settledSpacer)
        // Still overlapped after the settle: JR-Bar stops and says so.
        rig.fresh(after: 3)
        rig.fresh(after: 1)
        #expect(rig.hider.wake.verdict == .stuck(.overlapped(["Typeless"])))
        let total = rig.host.spacers.count
        for _ in 0..<12 { rig.fresh(after: 1) }
        #expect(rig.host.spacers.count == total, "no third attempt")
        #expect(rig.hider.wake.verdict == .stuck(.overlapped(["Typeless"])))
        let lines = rig.utility.dividerReadout.lines
        #expect(lines.contains { $0.contains("overlapped by Typeless") })
    }

    @MainActor
    @Test("a boundary found off the bar while it re-forms teaches nothing: no cap, no collapse")
    func noLessonWhileForming() {
        let rig = makeRig([item("Left", x: 1000), item("Right", x: 1130, w: 12)])
        settle(rig)
        let written = rig.host.spacers
        rig.hider.noteBarReformed("test wake")
        rig.host.manualFrame = CGRect(x: 1084, y: -40, width: 39, height: 24)   // parked, mid-reflow
        rig.fresh(after: 0.5)
        rig.fresh(after: 0.5)
        #expect(rig.hider.caps.hidden == .infinity)
        #expect(rig.host.spacers == written)
    }

    @MainActor
    @Test("a full-screen app hiding the bar teaches nothing either")
    func fullScreenTeachesNothing() {
        let rig = makeRig([item("Left", x: 1000), item("Right", x: 1130, w: 12)])
        settle(rig)
        rig.showing = false
        rig.host.manualFrame = CGRect(x: 1084, y: -40, width: 39, height: 24)
        rig.fresh(after: 2)
        rig.fresh(after: 2)
        #expect(rig.hider.caps.hidden == .infinity, "the bar leaving is not a spacer too long")
        // Without the guard the same frames cap the spacer.
        let rig2 = makeRig([item("Left", x: 1000), item("Right", x: 1130, w: 12)])
        settle(rig2)
        rig2.host.manualFrame = CGRect(x: 1084, y: -40, width: 39, height: 24)
        rig2.fresh(after: 2)
        #expect(rig2.hider.caps.hidden < .infinity)
    }

    @MainActor
    @Test("what was learned before the wake is forgotten once the bar has settled")
    func remeasureForgetsLessons() {
        let rig = makeRig([item("Left", x: 1000), item("Right", x: 1130, w: 12)])
        settle(rig)
        rig.host.manualFrame = CGRect(x: 1084, y: -40, width: 39, height: 24)
        rig.fresh(after: 2)
        #expect(rig.hider.caps.hidden < .infinity)
        rig.host.manualFrame = nil
        rig.hider.noteBarReformed("test wake")
        rig.fresh(after: 3)
        #expect(rig.hider.caps.hidden == .infinity)
    }

    @MainActor
    @Test("without Accessibility the check still runs, on passes, and a clear icon closes it")
    func noListingStillChecks() {
        let rig = makeRig([])
        rig.scanned = false
        settle(rig)
        rig.hider.noteBarReformed("test wake")
        rig.fresh(after: 3)
        rig.fresh(after: 1)
        rig.fresh(after: 1)
        #expect(rig.hider.wake.verdict == .clear)
    }

    @MainActor
    @Test("an icon that stays the wrong width opens one check of its own and is re-seated once")
    func wrongWidthSelfCheck() {
        let rig = makeRig([item("Left", x: 1000), item("Right", x: 1130, w: 12)])
        settle(rig)
        // Something outside the hider folded the item: 69 pt, not 221.
        rig.host.manualFrame = CGRect(x: 1054, y: 4, width: 69, height: 24)
        for _ in 0..<2 { rig.fresh(after: 1.5) }
        #expect(!rig.hider.wake.isOpen, "a reflow may still be settling")
        for _ in 0..<2 { rig.fresh(after: 1.5) }
        #expect(rig.hider.wake.isOpen, "four seconds of the wrong width opened a check")
        for _ in 0..<12 { rig.fresh(after: 1) }
        let verdict = rig.hider.wake.verdict
        #expect(verdict == .stuck(.spacerNotStanding), "the frame never changed, so JR-Bar reports it and stops")
        let total = rig.host.spacers.count
        for _ in 0..<12 { rig.fresh(after: 1) }
        #expect(rig.host.spacers.count == total, "one self-opened check per event")
    }

    // MARK: A spacer that cannot reach

    @Test("a spacer held short covers what it cannot push off; one that reaches covers nothing")
    func shortSpacerCovers() {
        let items = [item("Codex", x: 862), item("Shield", x: 929), item("Bars", x: 964),
                     item("Typeless", x: 1105)]
        let controls = MenuBarControlFrames(hidden: CGRect(x: 1017, y: 4, width: 45, height: 24),
                                            hiddenGlyph: 45)
        func plan(cap: CGFloat, revealed: Set<MenuBarItemSection> = []) -> MenuBarHidePlan {
            MenuBarItemHider.plan(items: items, sections: [:], row: row, controls: controls,
                                  fitEdge: 903, revealed: revealed, caps: MenuBarSpacerCaps(hidden: cap))
        }
        let reaching = plan(cap: .infinity)
        #expect(reaching.spacerShortBy == 0)
        #expect(reaching.hiddenCovers.isEmpty)
        #expect(reaching.hiddenControlLength == 159)

        let held = plan(cap: 100)
        #expect(held.hiddenControlLength == 100)
        #expect(held.spacerShortBy == 59)
        #expect(Set(held.hidden.map(\.id)) == ["Codex", "Shield", "Bars"])
        #expect(!held.hiddenCovers.isEmpty, "the three left of the icon are covered in place")
        let covered = held.hiddenCovers.reduce(into: Set<String>()) { acc, run in
            for it in items where run.contains(it.bounds.midX) { acc.insert(it.id) }
        }
        #expect(covered == ["Codex", "Shield", "Bars"])
        #expect(!covered.contains("Typeless"), "never the shown side")

        let shortByAHair = plan(cap: 155)
        #expect(shortByAHair.hiddenCovers.isEmpty, "a few points is a rounding, not a gap")
        #expect(plan(cap: 100, revealed: [.hidden]).spacerShortBy == 0, "a reveal is never short")
    }

    @Test("the card says plainly when the spacer is held short, and what the last wake left")
    func readoutSaysSo() {
        var input = MenuBarDividerReadout.Input(standing: true, iconFrame: CGRect(x: 987, y: 4, width: 75, height: 24),
                                                spacer: 100, fitEdge: 903, hidden: 3, shown: 2)
        input.spacerShortBy = 59
        let short = MenuBarDividerReadout.make(input).lines
        #expect(short.contains { $0.contains("held 59 pt short") && $0.contains("covered in place") })
        input.spacerShortBy = 0
        input.wake = .stuck(.offRow)
        let stuck = MenuBarDividerReadout.make(input).lines
        #expect(stuck.contains { $0.contains("off the bar") && $0.contains("re-seated once") })
        input.wake = .clear
        #expect(!MenuBarDividerReadout.make(input).lines.contains { $0.contains("re-formed") })
    }
}

private extension MenuBarWakeRecovery.Health {
    func with(onRow: Bool) -> MenuBarWakeRecovery.Health {
        var copy = self
        copy.onRow = onRow
        return copy
    }
}
