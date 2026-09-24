import AppKit
import Foundation
import Testing
@testable import JRBarApp
@testable import JRBarCore

/// The Menu Bar utility's pure halves (docs/UTILITIES.md): the window
/// list's filter rules, the zone plan, and the position seeding that
/// drives the ⌘-drag mover. All are functions of plain inputs so the
/// rules get tested without a screen, a status item, or another app's
/// items to move.
@Suite("Menu Bar")
struct MenuBarTests {
    /// A `CGWindowList` window-info dict the way the real list hands
    /// them over: layer, owner pid/name, bounds dict, optional title.
    private func info(layer: Int = MenuBarItemLister.statusWindowLayer,
                      pid: Int32 = 500, owner: String = "SomeApp",
                      x: Double = 100, y: Double = 0, w: Double = 24, h: Double = 24,
                      title: String? = nil, windowID: UInt32 = 1) -> [String: Any] {
        var dict: [String: Any] = [
            kCGWindowLayer as String: NSNumber(value: layer),
            kCGWindowOwnerPID as String: NSNumber(value: pid),
            kCGWindowOwnerName as String: owner,
            kCGWindowNumber as String: NSNumber(value: windowID),
        ]
        let bounds = CGRect(x: x, y: y, width: w, height: h)
        dict[kCGWindowBounds as String] = (bounds.dictionaryRepresentation as? [String: Any]) ?? [:]
        if let title { dict[kCGWindowName as String] = title }
        return dict
    }

    private func item(_ id: String, owner: String = "App", x: Double, y: Double = 0,
                      w: Double = 24, windowID: UInt32 = 0) -> MenuBarItem {
        MenuBarItem(id: id, ownerPID: 500, ownerName: owner,
                    bounds: CGRect(x: x, y: y, width: w, height: 24),
                    title: nil, windowID: windowID)
    }

    /// The menu bar strip the tests filter against.
    private let row = CGRect(x: 0, y: 0, width: 1512, height: 24)
    private let ownPID: pid_t = 42

    /// A fixed zone layout: always-hidden under x=100, hidden in
    /// 124–500, shown right of x=524.
    private let zones = MenuBarZones(
        regionMin: 0,
        alwaysHiddenControl: CGRect(x: 100, y: 0, width: 24, height: 24),
        hiddenControl: CGRect(x: 500, y: 0, width: 24, height: 24),
        regionMax: 1512)

    // MARK: Lister — one dict → an item or not

    @Test("a layer-25 window on the row owned by another app is an item")
    func itemBasics() {
        let item = MenuBarItemLister.item(from: info(pid: 500, owner: "Wi-Fi",
                                                   x: 900, title: "status", windowID: 7),
                                          ownPID: ownPID, rows: [row])
        #expect(item?.ownerPID == 500)
        #expect(item?.ownerName == "Wi-Fi")
        #expect(item?.title == "status")
        #expect(item?.windowID == 7)
        #expect(item?.bounds == CGRect(x: 900, y: 0, width: 24, height: 24))
    }

    @Test("only the status window layer counts")
    func wrongLayer() {
        #expect(MenuBarItemLister.item(from: info(layer: 24), ownPID: ownPID, rows: [row]) == nil)
        #expect(MenuBarItemLister.item(from: info(layer: 0), ownPID: ownPID, rows: [row]) == nil)
        #expect(MenuBarItemLister.item(from: info(layer: 26), ownPID: ownPID, rows: [row]) == nil)
    }

    @Test("our own process is never listed — the spacers must not hide themselves")
    func ownProcess() {
        #expect(MenuBarItemLister.item(from: info(pid: ownPID), ownPID: ownPID, rows: [row]) == nil)
    }

    @Test("Control Center's items are protected — a spacer can never move the clock")
    func protectedOwners() {
        #expect(MenuBarItemLister.isProtected(ownerName: "Control Center"))
        #expect(MenuBarItemLister.isProtected(ownerName: "ControlCenter"))
        #expect(!MenuBarItemLister.isProtected(ownerName: "SomeApp"))
        #expect(MenuBarItemLister.item(from: info(owner: "Control Center"), ownPID: ownPID, rows: [row]) == nil)
    }

    @Test("a sliver under the minimum width is a stray, not an item")
    func tooNarrow() {
        #expect(MenuBarItemLister.item(from: info(w: MenuBarItemLister.minItemWidth - 0.5),
                                       ownPID: ownPID, rows: [row]) == nil)
        #expect(MenuBarItemLister.item(from: info(w: MenuBarItemLister.minItemWidth),
                                       ownPID: ownPID, rows: [row]) != nil)
        #expect(MenuBarItemLister.item(from: info(w: 0), ownPID: ownPID, rows: [row]) == nil)
    }

    @Test("a window outside the row's band is not an item")
    func outsideRow() {
        // Entirely below the row.
        #expect(MenuBarItemLister.item(from: info(y: 40, h: 24), ownPID: ownPID, rows: [row]) == nil)
        // Overlapping by a hair still counts — and horizontally off the
        // screen edge still reports in (that is how a hidden run keeps
        // its identity).
        #expect(MenuBarItemLister.item(from: info(y: 23, h: 24), ownPID: ownPID, rows: [row]) != nil)
        #expect(MenuBarItemLister.item(from: info(x: 2400), ownPID: ownPID, rows: [row]) != nil)
    }

    @Test("a scan walks every app on the slow clock, with no owners known, or when a launch's walk is due")
    func fullWalkCadence() {
        let t0 = Date(timeIntervalSince1970: 1_800_000_000)
        func walks(_ seconds: TimeInterval, owners: Bool = true, due: [Date] = []) -> Bool {
            MenuBarItemLister.walksAll(now: t0.addingTimeInterval(seconds), lastFull: t0,
                                       ownersKnown: owners, launchWalksDue: due)
        }
        #expect(!walks(20), "a known owner set carries the quick scans past the old 20 s")
        #expect(!walks(MenuBarItemLister.fullScanInterval - 1))
        #expect(walks(MenuBarItemLister.fullScanInterval))
        #expect(walks(1, owners: false), "nothing known yet: walk")
        let launch = t0.addingTimeInterval(5)
        let due = MenuBarItemLister.launchWalkDelays.map { launch.addingTimeInterval($0) }
        #expect(!walks(6, due: due))
        #expect(walks(7, due: due), "two seconds after the launch")
        #expect(walks(35, due: due), "half a minute after it")
        #expect(MenuBarItemLister.launchWalkDelays == [2, 10, 30])
    }

    @Test("an empty window name is no title")
    func emptyTitle() {
        let item = MenuBarItemLister.item(from: info(title: ""), ownPID: ownPID, rows: [row])
        #expect(item?.title == nil)
    }

    // MARK: Lister — the list and its identities

    @Test("items sort left to right and take owner names as identities")
    func identities() {
        let infos = [
            info(pid: 3, owner: "Right", x: 300, windowID: 3),
            info(pid: 1, owner: "Left", x: 100, windowID: 1),
            info(pid: 2, owner: "Middle", x: 200, windowID: 2),
        ]
        let items = MenuBarItemLister.items(from: infos, ownPID: ownPID, rows: [row])
        #expect(items.map(\.id) == ["Left", "Middle", "Right"])
    }

    @Test("a titled window's identity is owner·title")
    func titledIdentity() {
        let items = MenuBarItemLister.items(
            from: [info(owner: "Stats", x: 100, title: "CPU", windowID: 9)],
            ownPID: ownPID, rows: [row])
        #expect(items.map(\.id) == ["Stats·CPU"])
    }

    @Test("an owner fielding two of the same item gets ordinals, in bar order")
    func ordinalIdentities() {
        let infos = [
            info(pid: 7, owner: "Multi", x: 200, windowID: 2),
            info(pid: 7, owner: "Multi", x: 100, windowID: 1),
            info(pid: 9, owner: "Solo", x: 300, windowID: 3),
        ]
        let items = MenuBarItemLister.items(from: infos, ownPID: ownPID, rows: [row])
        #expect(items.map(\.id) == ["Multi#0", "Multi#1", "Solo"])
    }

    @Test("each item carries its owner's bundle identifier from the snapshot — nil for a bare helper")
    func bundleIDsFromSnapshot() {
        let infos = [
            info(pid: 7, owner: "Multi", x: 200, windowID: 2),
            info(pid: 7, owner: "Multi", x: 100, windowID: 1),
            info(pid: 9, owner: "Helper", x: 300, windowID: 3),
        ]
        let items = MenuBarItemLister.items(from: infos, ownPID: ownPID, rows: [row],
                                            bundleIDs: [7: "com.example.multi"])
        #expect(items.map(\.bundleID) == ["com.example.multi", "com.example.multi", nil])
        // A listing taken without a snapshot knows no identifiers.
        #expect(MenuBarItemLister.items(from: infos, ownPID: ownPID, rows: [row])
                    .allSatisfy { $0.bundleID == nil })
    }

    // MARK: Zones — the physical section model

    @Test("an item's section is the zone its center sits in")
    func zoneMembership() {
        #expect(zones.section(atCenterX: 60) == .alwaysHidden)
        #expect(zones.section(atCenterX: 110) == .hidden)   // inside the ah control's own frame
        #expect(zones.section(atCenterX: 300) == .hidden)
        #expect(zones.section(atCenterX: 490) == .hidden)   // up to the chevron's left edge
        #expect(zones.section(atCenterX: 600) == .shown)
    }

    @Test("drops target the zone's near edge so reflow finds the slot")
    func zoneDropTargets() {
        #expect(zones.dropX(for: .alwaysHidden) == zones.regionMin + 14)
        #expect(zones.dropX(for: .hidden) == zones.alwaysHiddenControl.maxX
                + (zones.hiddenControl.minX - zones.alwaysHiddenControl.maxX) / 2)
        #expect(zones.dropX(for: .shown) == zones.hiddenControl.maxX + 16)
        // A hidden zone collapsed to a sliver still drops just left of
        // the chevron.
        let tight = MenuBarZones(regionMin: 0,
                                 alwaysHiddenControl: CGRect(x: 100, y: 0, width: 24, height: 24),
                                 hiddenControl: CGRect(x: 130, y: 0, width: 24, height: 24),
                                 regionMax: 1512)
        #expect(tight.dropX(for: .hidden) == tight.hiddenControl.minX - 14)
    }

    // MARK: Hider — the plan

    @Test("an assigned item is covered where it sits — nothing is ever moved")
    func planAssignments() {
        let items = [item("Deep", x: 50), item("Mid", x: 200),
                     item("Mid2", x: 300), item("Up", x: 800)]
        let plan = MenuBarItemHider.plan(items: items,
                                         sections: ["Deep": .alwaysHidden,
                                                    "Mid": .hidden, "Mid2": .hidden],
                                         row: row)
        #expect(plan.alwaysHidden.map(\.id) == ["Deep"])
        #expect(plan.hidden.map(\.id) == ["Mid", "Mid2"])
        #expect(plan.shown.map(\.id) == ["Up"])
        // Mid and Mid2 are contiguous — one cover run.
        #expect(plan.hiddenCovers == [200...324])
        #expect(plan.alwaysHiddenCovers == [50...74])
    }

    @Test("a shown item in the gap splits the cover run")
    func planCoverSplit() {
        let items = [item("H1", x: 200), item("S", x: 300), item("H2", x: 400)]
        let plan = MenuBarItemHider.plan(items: items,
                                         sections: ["H1": .hidden, "H2": .hidden], row: row)
        #expect(plan.hidden.map(\.id) == ["H1", "H2"])
        #expect(plan.hiddenCovers == [200...224, 400...424],
                "S's frame must never sit under a cover")
    }

    @Test("a protected frame in the gap splits the run — the chevron is never covered")
    func planCoverProtected() {
        let items = [item("H1", x: 200), item("H2", x: 400)]
        let chevron = CGRect(x: 300, y: 0, width: 24, height: 24)
        let plan = MenuBarItemHider.plan(items: items,
                                         sections: ["H1": .hidden, "H2": .hidden],
                                         row: row, protectedFrames: [chevron])
        #expect(plan.hiddenCovers == [200...224, 400...424])
    }

    @Test("covered items with only empty bar between them merge into one run")
    func planCoverMerge() {
        let items = [item("H1", x: 200), item("H2", x: 400)]
        let plan = MenuBarItemHider.plan(items: items,
                                         sections: ["H1": .hidden, "H2": .hidden], row: row)
        #expect(plan.hiddenCovers == [200...424])
    }

    @Test("items parked off the row join the run their mapping says")
    func planParked() {
        let items = [item("Up", x: 800),
                     item("Parked", x: 7, y: 970),
                     item("DeepParked", x: 7, y: 970)]
        let plan = MenuBarItemHider.plan(items: items,
                                         sections: ["DeepParked": .alwaysHidden], row: row)
        #expect(plan.shown.map(\.id) == ["Up"])
        #expect(plan.hidden.map(\.id) == ["Parked"])
        #expect(plan.alwaysHidden.map(\.id) == ["DeepParked"])
    }

    @Test("a protected owner stays shown even when the file says hidden")
    func planProtected() {
        let controlCenter = item("Control Center", owner: "Control Center", x: 300)
        let plan = MenuBarItemHider.plan(items: [item("A", x: 800), controlCenter],
                                         sections: ["Control Center": .hidden], row: row)
        #expect(plan.shown.map(\.id) == ["Control Center", "A"])
        #expect(plan.hidden.isEmpty)
    }

    @Test("the plan is order-independent: a scrambled list still sorts by x")
    func planSorts() {
        let items = [item("C", x: 300), item("A", x: 800), item("B", x: 200)]
        let plan = MenuBarItemHider.plan(items: items, sections: ["C": .hidden], row: row)
        #expect(plan.shown.map(\.id) == ["B", "A"])
        #expect(plan.hidden.map(\.id) == ["C"])
        #expect(plan.hiddenCovers == [300...324])
    }

    @Test("an item under an obscured band is hidden and covered — not left drawn behind glass")
    func planObscured() {
        // The notch sits at x≈590–630; an item drawn there is
        // unreachable, so the plan treats it as hidden and marks the
        // stretch with a cover.
        let notch = CGRect(x: 590, y: 0, width: 40, height: 24)
        let items = [item("Free", x: 800), item("UnderNotch", x: 600)]
        let plan = MenuBarItemHider.plan(items: items, sections: [:],
                                         row: row, obscuredFrames: [notch])
        #expect(plan.shown.map(\.id) == ["Free"])
        #expect(plan.hidden.map(\.id) == ["UnderNotch"])
        #expect(plan.hiddenCovers == [600...624])
    }

    @Test("an always-hidden override outranks the band — it covers in the deep lane")
    func planObscuredAlwaysHidden() {
        let notch = CGRect(x: 590, y: 0, width: 40, height: 24)
        let items = [item("Deep", x: 600), item("Up", x: 800)]
        let plan = MenuBarItemHider.plan(items: items,
                                         sections: ["Deep": .alwaysHidden],
                                         row: row, obscuredFrames: [notch])
        #expect(plan.alwaysHidden.map(\.id) == ["Deep"])
        #expect(plan.alwaysHiddenCovers == [600...624])
        #expect(plan.hidden.isEmpty)
    }

    @Test("a shown override cannot beat the band — the item is behind glass regardless")
    func planObscuredOverride() {
        // An explicit "shown" wish on an item sitting under the notch
        // is unfulfillable — macOS keeps it hidden. The plan treats it
        // as hidden and covers the stretch so the lane stays honest.
        let notch = CGRect(x: 590, y: 0, width: 40, height: 24)
        let items = [item("Keep", x: 600), item("Up", x: 800)]
        let plan = MenuBarItemHider.plan(items: items,
                                         sections: ["Keep": .shown],
                                         row: row, obscuredFrames: [notch])
        #expect(plan.hidden.map(\.id) == ["Keep"])
        #expect(plan.shown.map(\.id) == ["Up"])
        #expect(plan.hiddenCovers == [600...624])
    }

    // MARK: Mover — position seeding

    @Test("an assigned item in the wrong zone earns a drag into its zone")
    func moveStepsBasics() {
        let items = [item("Hide", x: 800), item("Show", x: 300), item("Keep", x: 700)]
        let steps = MenuBarItemMover.moveSteps(
            items: items, zones: zones,
            sections: ["Hide": .hidden, "Show": .shown], row: row)
        // "Show" is already in the hidden zone and assigned shown → it
        // drags right of the chevron. "Hide" is in the shown zone → it
        // drags between the controls. "Keep" is unassigned → untouched.
        #expect(steps.count == 2)
        let hide = steps.first { $0.itemID == "Hide" }
        #expect(hide?.from.x == 812)
        #expect(hide?.to.x == zones.dropX(for: .hidden))
        let show = steps.first { $0.itemID == "Show" }
        #expect(show?.to.x == zones.dropX(for: .shown))
    }

    @Test("protected, unassigned, and parked items are never moved")
    func moveStepsExclusions() {
        let items = [
            item("Sys", owner: "MenuBarAgent", x: 800),
            item("Free", x: 850),
            item("Parked", x: 7, y: 970),
        ]
        let steps = MenuBarItemMover.moveSteps(
            items: items, zones: zones,
            sections: ["Sys": .hidden, "Parked": .hidden], row: row)
        #expect(steps.isEmpty)
    }

    @Test("always-hidden drops go first — a later leftward push can't undo them")
    func moveStepsOrdering() {
        let items = [item("ToAH", x: 800), item("ToHidden", x: 850)]
        let steps = MenuBarItemMover.moveSteps(
            items: items, zones: zones,
            sections: ["ToAH": .alwaysHidden, "ToHidden": .hidden], row: row)
        #expect(steps.map(\.itemID) == ["ToAH", "ToHidden"])
    }

    // MARK: The Item Bar's layout

    @Test("the bar sizes to its tiles and hangs under the menu bar's right end")
    func barLayout() {
        let size = MenuBarBarLayout.contentSize(itemCount: 3)
        #expect(size.width == 3 * MenuBarBarLayout.tileSize + 2 * MenuBarBarLayout.tileGap
                + 2 * MenuBarBarLayout.padding)
        #expect(size.height == MenuBarBarLayout.tileSize + 2 * MenuBarBarLayout.padding)

        let screen = NSRect(x: 0, y: 0, width: 1512, height: 982)
        let frame = MenuBarBarLayout.frame(itemCount: 3, menuBarDepth: 24, on: screen)
        #expect(frame.maxX == screen.maxX - MenuBarBarLayout.edgeMargin)
        #expect(frame.maxY == screen.maxY - 24 - MenuBarBarLayout.barGap)
        #expect(frame.size == size)
    }

    @Test("an empty run has room for its explanatory text")
    func barEmpty() {
        #expect(MenuBarBarLayout.contentSize(itemCount: 0).width == 128)
        #expect(MenuBarBarLayout.contentSize(itemCount: 0).height == 46)
    }

    @Test("a packed bar caps its viewport while content remains scrollable")
    func barCap() {
        let crowded = MenuBarBarLayout.contentSize(itemCount: 500)
        let full = MenuBarBarLayout.contentSize(itemCount: MenuBarBarLayout.maxTiles)
        #expect(crowded.width == full.width)
        #expect(crowded.height == full.height + MenuBarBarLayout.scrollIndicatorHeight)
    }

    // MARK: Hider — the reconcile seam

    /// A hider driven by an injected list and row — no window list,
    /// no AX, no real cover panels.
    @MainActor
    private func makeHider(items: [MenuBarItem],
                           sections: [String: MenuBarItemSection]) -> MenuBarItemHider {
        let hider = MenuBarItemHider()
        hider.listItems = { items }
        hider.rowRect = { self.row }
        hider.shuttersSuppressed = true
        hider.settings = { MenuBarSettings(enabled: true, sections: sections) }
        return hider
    }

    @MainActor
    @Test("a parked item keeps its mapped section and never counts as shown")
    func reconcileStashed() async {
        let hider = makeHider(
            items: [item("A", x: 800), item("B", x: 300),
                    item("C", x: 7, y: 970), item("D", x: 7, y: 970)],
            sections: ["B": .hidden, "C": .hidden, "D": .alwaysHidden])
        var emitted: [MenuBarHidePlan] = []
        hider.onPlan = { emitted.append($0) }
        hider.reconcile()
        #expect(emitted.count == 1)
        #expect(hider.lastPlan.shown.map(\.id) == ["A"])
        // C is parked off the row: it counts as hidden because that is
        // what it is — and it must not flap through the shown pass.
        #expect(hider.lastPlan.hidden.map(\.id) == ["B", "C"])
        #expect(hider.lastPlan.alwaysHidden.map(\.id) == ["D"])
    }

    @MainActor
    @Test("a reveal marks the section but the next reconcile still reports the run")
    func reconcileReveal() async {
        let hider = makeHider(items: [item("A", x: 100), item("B", x: 200)],
                              sections: ["B": .hidden])
        hider.reconcile()
        #expect(hider.revealed.isEmpty)
        hider.reveal([.hidden])
        #expect(hider.revealed == [.hidden])
        hider.hide()
        #expect(hider.revealed.isEmpty)
        // hide() with nothing out is a no-op — a stale timer landing
        // late can never resurface the row.
        hider.hide()
        #expect(hider.revealed.isEmpty)
    }

    @MainActor
    @Test("a reconcile with no assignments covers nothing and lists the parked")
    func reconcileNoAssignments() async {
        let hider = MenuBarItemHider()
        hider.listItems = { [self.item("A", x: 800), self.item("P", x: 7, y: 970)] }
        hider.rowRect = { self.row }
        hider.shuttersSuppressed = true
        hider.reconcile()
        #expect(hider.lastPlan.shown.map(\.id) == ["A"])
        #expect(hider.lastPlan.hidden.map(\.id) == ["P"])
        #expect(hider.lastPlan.hiddenCovers.isEmpty,
                "a parked item's offscreen stash never earns a cover")
        #expect(hider.lastPlan.alwaysHiddenCovers.isEmpty)
    }

    // MARK: Reveal — the state machine

    /// A reveal wired to counters with a manual clock, a fixed row,
    /// and a pointer the test steers.
    @MainActor
    private final class RevealHarness {
        let reveal = MenuBarReveal()
        var reveals = 0
        var hides = 0
        var point = NSPoint(x: 400, y: 400)
        var pending: (@MainActor () -> Void)?
        let rowRect = NSRect(x: 0, y: 958, width: 1512, height: 27)

        init() {
            reveal.onReveal = { [weak self] in self?.reveals += 1 }
            reveal.onHide = { [weak self] in self?.hides += 1 }
            reveal.row = { [weak self] in self?.rowRect }
            reveal.mouseLocation = { [weak self] in self?.point ?? .zero }
            // The dwell is a wall-clock deadline — zero keeps the
            // entry-fires-once semantics these tests pin.
            reveal.hoverDwell = 0
            reveal.scheduleRehide = { [weak self] _, fire in
                self?.pending = fire
                return {}
            }
        }
        /// The rehide clock's landing, fired by hand.
        func fireClock() { pending?() }
    }

    @MainActor
    @Test("a gesture reveals once, then the clock holds while the pointer stays on the row")
    func revealThenHoldOnRow() async {
        let h = RevealHarness()
        h.reveal.triggerReveal()
        #expect(h.reveals == 1)
        #expect(h.reveal.revealed)
        // Pointer on the row: the clock re-arms instead of hiding.
        h.point = NSPoint(x: 400, y: 965)
        h.fireClock()
        #expect(h.hides == 0)
        #expect(h.reveal.revealed)
        // Pointer off every surface: the landing hides.
        h.point = NSPoint(x: 400, y: 400)
        h.fireClock()
        #expect(h.hides == 1)
        #expect(!h.reveal.revealed)
    }

    @MainActor
    @Test("a gesture burst inside the throttle is one reveal, not a reconcile storm")
    func revealThrottle() async {
        let h = RevealHarness()
        h.reveal.triggerReveal()
        h.reveal.triggerReveal()
        h.reveal.triggerReveal()
        #expect(h.reveals == 1)
    }

    @MainActor
    @Test("hover reveals on row entry only — parking is not a gesture stream")
    func hoverEntryOnly() async {
        let h = RevealHarness()
        h.point = NSPoint(x: 400, y: 400)   // off the row
        h.reveal.pollHover()
        #expect(h.reveals == 0)
        h.point = NSPoint(x: 400, y: 965)   // entered
        h.reveal.pollHover()
        #expect(h.reveals == 1)
        h.reveal.pollHover()                // parked
        h.reveal.pollHover()
        #expect(h.reveals == 1)
        h.point = NSPoint(x: 400, y: 400)   // left
        h.reveal.pollHover()
        h.point = NSPoint(x: 400, y: 965)   // re-entered — throttled
        h.reveal.pollHover()
        #expect(h.reveals == 1)
    }

    @MainActor
    @Test("an empty-space click reveals; a click on an item frame does not")
    func clickEmptyVsItem() async {
        let h = RevealHarness()
        h.reveal.itemFrames = { [NSRect(x: 100, y: 958, width: 24, height: 24)] }
        h.reveal.pointerDown(at: NSPoint(x: 110, y: 965))  // on the item
        #expect(h.reveals == 0)
        h.reveal.pointerDown(at: NSPoint(x: 500, y: 965))  // empty space
        #expect(h.reveals == 1)
    }

    @MainActor
    @Test("a gesture behind a disabled setting never reaches onReveal")
    func disabledGestures() async {
        let h = RevealHarness()
        h.reveal.settings = {
            MenuBarSettings(enabled: true, revealOnHover: false,
                            revealOnClick: false, revealOnScroll: false)
        }
        h.point = NSPoint(x: 400, y: 965)
        h.reveal.pollHover()
        h.reveal.pointerDown(at: NSPoint(x: 500, y: 965))
        h.reveal.scrolled()
        #expect(h.reveals == 0)
    }

    @MainActor
    @Test("with hover reveal off the poll idles and reads no zone, items or hot frames")
    func hoverPollIdlesWhenOff() async {
        let h = RevealHarness()
        var reads = 0
        h.reveal.revealZone = { reads += 1; return nil }
        h.reveal.itemFrames = { reads += 1; return [] }
        h.reveal.hotFrames = { reads += 1; return [] }
        h.reveal.settings = { MenuBarSettings(enabled: true, revealOnHover: false) }
        h.point = NSPoint(x: 400, y: 965)   // on the row
        #expect(h.reveal.hoverTick() == MenuBarReveal.idlePollInterval)
        #expect(reads == 0)
        #expect(h.reveals == 0)
        // Switched back on: the next tick polls at the near cadence, and
        // a pointer already in the zone counts as an entry.
        h.reveal.settings = { MenuBarSettings(enabled: true, revealOnHover: true) }
        #expect(h.reveal.hoverTick() == MenuBarReveal.hoverPollInterval)
        #expect(reads > 0)
        #expect(h.reveals == 1)
    }

    @MainActor
    @Test("a deliberate hide cancels the clock — a stale fire lands no second onHide")
    func cancelReveal() async {
        let h = RevealHarness()
        h.reveal.triggerReveal()
        h.reveal.cancelReveal()
        #expect(!h.reveal.revealed)
        h.point = NSPoint(x: 400, y: 400)
        h.fireClock()
        #expect(h.hides == 0)
    }

    @MainActor
    @Test("the open Item Bar and holdOpen both keep a reveal alive")
    func holdOpenAndBar() async {
        let h = RevealHarness()
        var bar: NSRect? = nil
        h.reveal.barFrame = { bar }
        h.reveal.triggerReveal()
        h.point = NSPoint(x: 400, y: 400)
        h.reveal.holdOpen = true
        h.fireClock()
        #expect(h.hides == 0)
        h.reveal.holdOpen = false
        bar = NSRect(x: 300, y: 300, width: 200, height: 46)
        h.point = NSPoint(x: 400, y: 320)   // on the bar
        h.fireClock()
        #expect(h.hides == 0)
        h.point = NSPoint(x: 400, y: 400)   // off both
        h.fireClock()
        #expect(h.hides == 1)
    }

    @MainActor
    @Test("untilClick mode arms no clock — the surface closing folds the reveal instead")
    func rehideUntilClick() async {
        let h = RevealHarness()
        h.reveal.settings = { MenuBarSettings(rehideMode: .untilClick) }
        h.reveal.triggerReveal()
        #expect(h.reveals == 1)
        #expect(h.reveal.revealed)
        // No clock is armed — the reveal stands for as long as it stands.
        #expect(h.pending == nil)
        // The bar folding is the fold: no short clock, just the hide.
        h.reveal.noteBarClosed()
        #expect(h.hides == 1)
        #expect(!h.reveal.revealed)
        // An explicit trigger clock still clocks — the rule named its
        // own seconds, the mode does not gate it.
        h.reveal.rearm(for: 3)
        #expect(h.pending != nil)
        h.fireClock()
        #expect(h.hides == 2)
    }

    @MainActor
    @Test("hovering another app's item is not the gesture — the zone is the chevron and empty space")
    func hoverZone() async {
        let h = RevealHarness()
        h.reveal.itemFrames = { [NSRect(x: 390, y: 958, width: 24, height: 24)] }
        h.point = NSPoint(x: 400, y: 965)   // on the item
        h.reveal.pollHover()
        #expect(h.reveals == 0)
        h.point = NSPoint(x: 500, y: 965)   // slid onto empty space — a zone entry
        h.reveal.pollHover()
        #expect(h.reveals == 1)
        h.point = NSPoint(x: 400, y: 965)   // back onto the item — the zone was left
        h.reveal.pollHover()
        h.point = NSPoint(x: 500, y: 965)   // re-entering fires again (throttled)
        h.reveal.pollHover()
        #expect(h.reveals == 1)
    }

    // MARK: Sections — the assignment write

    @Test("a section pick writes the single mapping — the cover, not a move, hides the item")
    func assignSingle() {
        let items = [item("A", x: 100), item("B", x: 200), item("C", x: 300), item("D", x: 400)]
        let sections = MenuBarItemHider.updatedSections(
            items: items, sections: ["D": .alwaysHidden], changedID: "B", target: .hidden)
        #expect(sections == ["B": .hidden, "D": .alwaysHidden],
                "neighbours keep their assignments — the map alone decides coverage")
    }

    @Test("assigning shown clears the key rather than writing it")
    func assignShownClears() {
        let items = [item("A", x: 100), item("B", x: 200)]
        let sections = MenuBarItemHider.updatedSections(
            items: items, sections: ["A": .hidden, "B": .hidden],
            changedID: "A", target: .shown)
        #expect(sections == ["B": .hidden])
    }

    @Test("a protected owner is never written into the map")
    func cascadeProtected() {
        let clock = item("Control Center", owner: "Control Center", x: 300)
        let sections = MenuBarItemHider.updatedSections(
            items: [item("A", x: 100), item("B", x: 200), clock],
            sections: [:], changedID: "Control Center", target: .alwaysHidden)
        #expect(sections.isEmpty)
    }

    @Test("an unlisted item still records its mapping for when it returns")
    func cascadeUnlisted() {
        let items = [item("A", x: 100), item("B", x: 200)]
        let sections = MenuBarItemHider.updatedSections(
            items: items, sections: ["B": .hidden], changedID: "Gone", target: .hidden)
        #expect(sections == ["B": .hidden, "Gone": .hidden])
    }

    // MARK: Utility — seed, cascade write, chevron

    @MainActor
    @Test("a section pick writes just that item's mapping and persists as one write")
    func setSectionCascades() {
        let utility = MenuBarUtility()
        var state = MenuBarSettings(enabled: true)
        var writes = 0
        utility.settings = { state }
        utility.onSettingsChange = { draft in state = draft; writes += 1 }
        utility.hider.listItems = { [self.item("A", x: 100), self.item("B", x: 200), self.item("C", x: 300)] }
        utility.hider.rowRect = { self.row }
        utility.hider.shuttersSuppressed = true
        utility.hider.reconcile()   // fills lastPlan through onPlan — no covers, nothing moves
        utility.setSection(.hidden, for: "A")
        #expect(writes == 1)
        #expect(state.sections == ["A": .hidden])
    }

    @MainActor
    @Test("the Item Bar style opens the panel and never touches the row")
    func revealStyleBar() {
        let utility = MenuBarUtility()
        let state = MenuBarSettings(enabled: true, sections: ["A": .hidden],
                                    revealStyle: .bar)
        utility.settings = { state }
        utility.hider.listItems = { [self.item("A", x: 100)] }
        utility.hider.rowRect = { self.row }
        utility.hider.shuttersSuppressed = true
        utility.hider.reconcile()   // lastPlan.hidden = [A]
        utility.reveal.onReveal()
        #expect(utility.bar.isOpen)
        #expect(utility.hider.revealed.isEmpty,
                "Bartender's rule — the row never un-conceals on a reveal")
        utility.bar.close()
    }

    @MainActor
    @Test("the inline style reflows the run onto the row and not the panel")
    func revealStyleInline() {
        let utility = MenuBarUtility()
        let state = MenuBarSettings(enabled: true, sections: ["A": .hidden],
                                    revealStyle: .inline)
        utility.settings = { state }
        utility.hider.listItems = { [self.item("A", x: 100)] }
        utility.hider.rowRect = { self.row }
        utility.hider.shuttersSuppressed = true
        utility.hider.reconcile()
        utility.reveal.onReveal()
        #expect(utility.hider.revealed == [.hidden],
                "Ice and Hidden Bar's rule — the run reflows onto the bar")
        #expect(!utility.bar.isOpen)
        utility.hider.hide()
    }

    @MainActor
    @Test("a reveal with nothing hidden opens no empty panel")
    func revealStyleBarEmpty() {
        let utility = MenuBarUtility()
        let state = MenuBarSettings(enabled: true, revealStyle: .bar)
        utility.settings = { state }
        utility.hider.listItems = { [self.item("A", x: 100)] }
        utility.hider.rowRect = { self.row }
        utility.hider.shuttersSuppressed = true
        utility.hider.reconcile()
        utility.reveal.onReveal()
        #expect(!utility.bar.isOpen)
        #expect(utility.hider.revealed.isEmpty)
    }

    @MainActor
    @Test("the control installs once per run and stop tears it all the way down")
    func chevronLifecycle() {
        let utility = MenuBarUtility()
        utility.installChevron()
        let first = utility.chevron
        #expect(first != nil)
        utility.installChevron()
        #expect(utility.chevron === first, "a second install must not stack a status item")
        utility.removeChevron()
        #expect(utility.chevron == nil)
        // disable → enable leaves exactly one; disable again drops it.
        utility.installChevron()
        #expect(utility.chevron != nil)
        utility.removeChevron()
        #expect(utility.chevron == nil)
        // stop on a parked utility is a no-op.
        utility.stop()
        #expect(utility.chevron == nil)
    }

    @MainActor
    @Test("stopping the hider puts everything back and forgets the reveal")
    func hiderStopResets() {
        let hider = makeHider(items: [item("A", x: 100), item("B", x: 200)],
                              sections: ["B": .hidden])
        var emitted: [MenuBarHidePlan] = []
        hider.onPlan = { emitted.append($0) }
        hider.reconcile()
        hider.reveal([.hidden])
        #expect(hider.revealed == [.hidden])
        hider.stop()
        #expect(hider.revealed.isEmpty)
        #expect(hider.lastPlan == MenuBarHidePlan())
        #expect(emitted.last == MenuBarHidePlan())
    }

    @Test("show for updates: a hidden item's changed title names its section")
    func updatedHidden() {
        func titled(_ id: String, _ title: String?) -> MenuBarItem {
            MenuBarItem(id: id, ownerPID: 500, ownerName: "App",
                        bounds: CGRect(x: 700, y: 0, width: 24, height: 24),
                        title: title, windowID: 0)
        }
        // The first scan seeds — a baseline title is not an update.
        var result = MenuBarItemHider.updatedHidden(
            previous: [:], hidden: [titled("clock", "10:40")], alwaysHidden: [])
        #expect(result.sections.isEmpty)
        // The signature carries the title plus the identity fields an
        // icon-only swap moves — the title leads it.
        #expect(result.signatures["clock"]?.hasPrefix("10:40") == true)
        // The minute turns — the hidden run reveals.
        result = MenuBarItemHider.updatedHidden(
            previous: result.signatures,
            hidden: [titled("clock", "10:41")], alwaysHidden: [])
        #expect(result.sections == [.hidden])
        // Same title next scan — nothing to announce.
        result = MenuBarItemHider.updatedHidden(
            previous: result.signatures,
            hidden: [titled("clock", "10:41")], alwaysHidden: [])
        #expect(result.sections.isEmpty)
        // An always-hidden item's update names its own run — the
        // hidden run stays parked for it.
        var ah = MenuBarItemHider.updatedHidden(
            previous: [:], hidden: [], alwaysHidden: [titled("vpn", "Connecting")])
        ah = MenuBarItemHider.updatedHidden(
            previous: ah.signatures,
            hidden: [], alwaysHidden: [titled("vpn", "Connected")])
        #expect(ah.sections == [.alwaysHidden])
        // A brand-new item is seeded, not announced — its first sighting
        // is a baseline like the first scan's.
        result = MenuBarItemHider.updatedHidden(
            previous: ah.signatures,
            hidden: [titled("fresh", "just appeared")], alwaysHidden: [])
        #expect(result.sections.isEmpty)
        #expect(result.signatures["fresh"]?.hasPrefix("just appeared") == true)
    }
}
