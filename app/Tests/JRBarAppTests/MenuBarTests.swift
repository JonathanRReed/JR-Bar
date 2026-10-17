import AppKit
import Foundation
import Testing
@testable import JRBarApp
@testable import JRBarCore

/// The Menu Bar utility's pure halves (docs/UTILITIES.md): the window
/// list's filter rules, the cover plan, the reveal's state machine and
/// the Item Bar's layout. All are functions of plain inputs so the
/// rules get tested without a screen, a status item, or another app's
/// items.
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

    @Test("a scan walks every app on the slow clock or with no owners known; a launch asks only the launched app")
    func fullWalkCadence() {
        let t0 = Date(timeIntervalSince1970: 1_800_000_000)
        func walks(_ seconds: TimeInterval, owners: Bool = true) -> Bool {
            MenuBarItemLister.walksAll(now: t0.addingTimeInterval(seconds), lastFull: t0,
                                       ownersKnown: owners)
        }
        #expect(!walks(20), "a known owner set carries the quick scans past the old 20 s")
        #expect(!walks(MenuBarItemLister.fullScanInterval - 1))
        #expect(walks(MenuBarItemLister.fullScanInterval))
        #expect(walks(1, owners: false), "nothing known yet: walk")

        var probes = MenuBarLaunchProbes()
        let launch = t0.addingTimeInterval(5)
        probes.noteLaunch(4242, at: launch)
        #expect(probes.pids(dueAt: launch) == [4242], "the next scan asks the launched app")
        probes.spend(dueAt: launch)
        #expect(probes.pids(dueAt: t0.addingTimeInterval(6)).isEmpty)
        #expect(probes.pids(dueAt: t0.addingTimeInterval(7)) == [4242], "two seconds after the launch")
        probes.spend(dueAt: t0.addingTimeInterval(7))
        #expect(probes.pids(dueAt: t0.addingTimeInterval(14)).isEmpty)
        #expect(probes.pids(dueAt: t0.addingTimeInterval(15)) == [4242], "ten seconds after it")
        probes.spend(dueAt: t0.addingTimeInterval(15))
        #expect(probes.pids(dueAt: t0.addingTimeInterval(35)) == [4242], "half a minute after it")
        probes.spend(dueAt: t0.addingTimeInterval(35))
        #expect(probes.due.isEmpty, "four looks, then the launched app is an owner or nobody")
        probes.noteLaunch(77, at: launch)
        probes.noteQuit(77)
        #expect(probes.due.isEmpty, "a quit app is not asked")
        #expect(MenuBarItemLister.launchWalkDelays == [2, 10, 30])
    }

    @Test("a scan's targets come from the index, filtered before any app is asked")
    func scanTargetsFilterFirst() {
        let apps = [
            RunningApp(pid: 10, bundleID: "io.example.owner", name: "Owner", policy: .accessory),
            RunningApp(pid: 11, bundleID: "io.example.quiet", name: "Quiet", policy: .regular),
            RunningApp(pid: 12, bundleID: "io.example.fresh", name: "Fresh", policy: .regular),
            RunningApp(pid: 13, bundleID: "io.example.daemon", name: "Daemon", policy: .prohibited),
            RunningApp(pid: 14, bundleID: "io.example.slow", name: "Slow", policy: .regular),
            RunningApp(pid: 15, bundleID: nil, name: "", policy: .regular),
        ]
        let quick = MenuBarItemLister.scanTargets(apps: apps, walkAll: false, owners: [10],
                                                  launched: [12, 13], slow: [14])
        #expect(quick.map(\.pid) == [10, 12, 13, 14], "owners, launched and retried apps only")
        let wait = Dictionary(uniqueKeysWithValues: quick.map { ($0.pid, $0.timeout) })
        #expect(wait[10] == MenuBarAX.messagingTimeout, "an owner gets the long wait")
        #expect(wait[12] == MenuBarAX.messagingTimeout, "a launched app that can draw UI too")
        #expect(wait[13] == MenuBarAX.quickTimeout, "a launched background process gets the short one")
        #expect(wait[14] == MenuBarAX.messagingTimeout, "a retry gets the long wait")
        let full = MenuBarItemLister.scanTargets(apps: apps, walkAll: true, owners: [10],
                                                 launched: [], slow: [])
        #expect(full.map(\.pid) == [10, 11, 12, 13, 14], "every named app on a full walk")
        #expect(full.first { $0.pid == 11 }?.timeout == MenuBarAX.quickTimeout)
        #expect(full.first { $0.pid == 10 }?.bundleID == "io.example.owner")
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

    @MainActor
    private final class HoverBoundaryHost: MenuBarBoundaryHost {
        let appKitFrame: NSRect
        let spacer: CGFloat
        var boundaryFrame: CGRect? {
            let height = CGDisplayBounds(CGMainDisplayID()).height
            return CGRect(x: appKitFrame.minX, y: height - appKitFrame.maxY,
                          width: appKitFrame.width, height: appKitFrame.height)
        }
        var boundaryHoverFrame: NSRect? {
            StatusItemController.boundaryRevealBounds(
                NSRect(origin: .zero, size: appKitFrame.size), spacer: spacer,
                glyphWidth: boundaryGlyphLength).offsetBy(dx: appKitFrame.minX, dy: appKitFrame.minY)
        }
        var boundaryGlyphLength: CGFloat { appKitFrame.width - spacer }
        var onBoundaryClick: (@MainActor () -> Void)?
        var hiddenItemsMenu: (@MainActor () -> NSMenu?)?
        var hiddenCount = 0
        var hiddenRevealed = false
        var barAppearance: NSAppearance? { nil }
        init(frame: NSRect, spacer: CGFloat) {
            appKitFrame = frame
            self.spacer = spacer
        }
        func setBoundarySpacer(_: CGFloat) {}
    }

    @MainActor
    private func boundaryHoverHarness(spacer: CGFloat = 150) -> RevealHarness {
        let h = RevealHarness()
        let utility = MenuBarUtility()
        let host = HoverBoundaryHost(
            frame: NSRect(x: 450, y: 958, width: spacer + 24, height: 24), spacer: spacer)
        utility.host = host
        h.boundaryUtility = utility
        h.boundaryHost = host
        h.reveal.hotFrames = utility.reveal.hotFrames
        h.reveal.clickHandledFrames = utility.reveal.clickHandledFrames
        let row = h.rowRect
        h.reveal.revealZone = {
            MenuBarUtility.revealZone(row: row, boundary: host.appKitFrame,
                                     hoverFrame: host.boundaryHoverFrame, fitEdge: nil)
        }
        h.reveal.hoverDwell = 0.2
        return h
    }

    @MainActor
    @Test("the shared native blank geometry never admits chevron or icon hover")
    func chevronAndIconHoverNeverReveal() {
        for x in [CGFloat(580), CGFloat(590), CGFloat(600), CGFloat(610), CGFloat(650)] {
            let h = RevealHarness()
            let bounds = NSRect(x: 0, y: 0, width: 174, height: 24)
            let blank = StatusItemController.boundaryRevealBounds(bounds, spacer: 150)
                .offsetBy(dx: 450, dy: 958)
            h.reveal.revealZone = { blank }
            h.reveal.hotFrames = { [blank] }
            h.reveal.hoverDwell = 0.2
            h.point = NSPoint(x: x, y: 965)
            h.reveal.pollHover()
            h.time += 1
            h.reveal.pollHover()
            #expect(h.reveals == 0)
            #expect(h.pending == nil)
        }
    }

    @MainActor
    @Test("click, scroll and direct hover reject the chevron and everything to its right")
    func strictBlankZoneGatesScrollAndDirectHover() {
        let blank = NSRect(x: 450, y: 958, width: 130, height: 24)
        for x in [CGFloat(580), CGFloat(590), CGFloat(600), CGFloat(610), CGFloat(650)] {
            for gesture in 0..<3 {
                let h = RevealHarness()
                h.reveal.revealZone = { blank }
                h.reveal.hotFrames = { [blank] }
                let point = NSPoint(x: x, y: 965)
                // The cursor has moved since the queued event was captured.
                h.point = NSPoint(x: 470, y: 965)
                switch gesture {
                case 0: h.reveal.pointerDown(at: point)
                case 1: h.reveal.scrolled(at: point)
                default: h.reveal.pointerEnteredRow(at: point)
                }
                #expect(h.reveals == 0)
                #expect(h.pending == nil)
            }
        }
    }

    @MainActor
    @Test("a clipped composite reveals only its measured blank seat")
    func clippedCompositeBlankRoutesAllGestures() {
        let blank = StatusItemController.boundaryRevealBounds(
            NSRect(x: 0, y: 0, width: 93, height: 24), spacer: 150,
            glyphWidth: 24).offsetBy(dx: 450, dy: 958)
        for x in [CGFloat(480), CGFloat(499), CGFloat(510), CGFloat(530), CGFloat(560)] {
            for gesture in 0..<3 {
                let h = RevealHarness()
                var settings = MenuBarSettings()
                settings.revealOnHover = true
                settings.revealOnClick = true
                settings.revealOnScroll = true
                let configured = settings
                h.reveal.settings = { configured }
                h.reveal.revealZone = { blank }
                h.reveal.hotFrames = { [blank] }
                let point = NSPoint(x: x, y: 965)
                switch gesture {
                case 0: h.reveal.pointerDown(at: point)
                case 1: h.reveal.scrolled(at: point)
                default: h.reveal.pointerEnteredRow(at: point)
                }
                #expect(h.reveals == (x < 499 ? 1 : 0))
            }
        }
    }

    @MainActor
    @Test("moving onto the chevron cancels a blank-space hover dwell")
    func chevronEntryCancelsBlankDwell() {
        let h = boundaryHoverHarness()
        h.point = NSPoint(x: 570, y: 965)
        h.reveal.pollHover()
        h.time += 0.1
        h.point.x = 590
        h.reveal.pollHover()
        h.time += 1
        h.reveal.pollHover()
        #expect(h.reveals == 0)
        #expect(h.pending == nil)
    }

    @MainActor
    @Test("only the blank spacer left of the native chevron reveals after the hover dwell")
    func boundarySpacerAndChevronHoverReveal() {
        for x in [CGFloat(470), CGFloat(570)] {
            let h = boundaryHoverHarness()
            h.point = NSPoint(x: x, y: 965)
            h.reveal.pollHover()
            #expect(h.reveals == 0)
            h.time += 0.2
            h.reveal.pollHover()
            #expect(h.reveals == 1)
        }
    }

    @MainActor
    @Test("hovering JR-Bar's own icon never starts a reveal dwell")
    func boundaryIconHoverDoesNotReveal() {
        let h = boundaryHoverHarness()
        h.point = NSPoint(x: 610, y: 965)
        h.reveal.pollHover()
        h.time += 1
        h.reveal.pollHover()
        #expect(h.reveals == 0)
        #expect(!h.reveal.revealed)
        #expect(h.pending == nil)
    }

    @MainActor
    @Test("moving from the spacer onto JR-Bar's icon cancels its pending hover")
    func boundarySpacerToIconCancelsDwell() {
        let h = boundaryHoverHarness()
        h.point = NSPoint(x: 570, y: 965)
        h.reveal.pollHover()
        h.time += 0.1
        h.point.x = 610
        h.reveal.pollHover()
        h.time += 1
        h.reveal.pollHover()
        #expect(h.reveals == 0)
        h.point.x = 570
        h.reveal.pollHover()
        #expect(h.reveals == 0, "returning to the spacer must start a fresh dwell")
        h.time += 0.2
        h.reveal.pollHover()
        #expect(h.reveals == 1)
    }

    @MainActor
    @Test("a collapsed spacer gives hover an empty zone rather than the whole row")
    func boundaryCollapsedSpacerDoesNotReveal() {
        for x in [CGFloat(400), CGFloat(460)] {
            let h = boundaryHoverHarness(spacer: 0)
            h.point = NSPoint(x: x, y: 965)
            #expect(h.reveal.revealZone() != nil)
            h.reveal.pollHover()
            h.time += 1
            h.reveal.pollHover()
            #expect(h.reveals == 0)
        }
    }

    @MainActor
    @Test("the utility's live reveal wiring cancels hover when its host disappears")
    func missingHostWiringCancelsPendingHover() throws {
        let h = boundaryHoverHarness()
        h.point = NSPoint(x: 570, y: 965)
        h.reveal.pollHover()
        h.time += 0.1
        let utility = try #require(h.boundaryUtility)
        utility.host = nil
        h.reveal.revealZone = utility.reveal.revealZone
        #expect(h.reveal.revealZone() != nil)
        #expect(h.reveal.revealZone()?.isEmpty == true)
        h.point.x = 610
        h.reveal.pollHover()
        h.time += 1
        h.reveal.pollHover()
        #expect(h.reveals == 0)
        #expect(!h.reveal.revealed)
        #expect(h.pending == nil)
    }

    @MainActor
    @Test("missing or off-row boundaries never make JR-Bar's icon hoverable")
    func unavailableBoundaryDoesNotRevealIcon() {
        let offRow = NSRect(x: 450, y: 700, width: 174, height: 24)
        for boundary in [nil, offRow] as [NSRect?] {
            let h = RevealHarness()
            let row = h.rowRect
            h.reveal.hoverDwell = 0.2
            h.reveal.revealZone = {
                MenuBarUtility.revealZone(row: row, boundary: boundary,
                                         hoverFrame: nil, fitEdge: nil)
            }
            h.reveal.hotFrames = { [] }
            h.point = NSPoint(x: 610, y: 965)
            h.reveal.pollHover()
            h.time += 1
            h.reveal.pollHover()
            #expect(h.reveals == 0)
            #expect(!h.reveal.revealed)
            #expect(h.pending == nil)
        }
    }

    @MainActor
    @Test("losing the boundary cancels a spacer dwell before the pointer reaches the icon")
    func unavailableBoundaryCancelsPendingDwell() {
        let offRow = NSRect(x: 450, y: 700, width: 174, height: 24)
        for lostBoundary in [nil, offRow] as [NSRect?] {
            let h = RevealHarness()
            let row = h.rowRect
            var boundary: NSRect? = NSRect(x: 450, y: 958, width: 174, height: 24)
            let blank = NSRect(x: 450, y: 958, width: 150, height: 24)
            h.reveal.hoverDwell = 0.2
            h.reveal.revealZone = {
                MenuBarUtility.revealZone(row: row, boundary: boundary,
                                         hoverFrame: blank, fitEdge: nil)
            }
            h.reveal.hotFrames = { [] }
            h.point = NSPoint(x: 590, y: 965)
            h.reveal.pollHover()
            h.time += 0.1
            boundary = lostBoundary
            h.point.x = 610
            h.reveal.pollHover()
            h.time += 1
            h.reveal.pollHover()
            #expect(h.reveals == 0)
            #expect(!h.reveal.revealed)
            #expect(h.pending == nil)
        }
    }

    @MainActor
    @Test("restoring a lost boundary under a still pointer requires a fresh hover entry")
    func restoredBoundaryNeedsPointerMovement() {
        let offRow = NSRect(x: 450, y: 700, width: 174, height: 24)
        for lostBoundary in [nil, offRow] as [NSRect?] {
            let h = RevealHarness()
            let row = h.rowRect
            let standing = NSRect(x: 450, y: 958, width: 174, height: 24)
            var boundary: NSRect? = standing
            let blank = NSRect(x: 450, y: 958, width: 150, height: 24)
            h.reveal.hoverDwell = 0.2
            h.reveal.revealZone = {
                MenuBarUtility.revealZone(row: row, boundary: boundary,
                                         hoverFrame: blank, fitEdge: nil)
            }
            h.reveal.hotFrames = { [] }
            h.point = NSPoint(x: 590, y: 965)
            h.reveal.pollHover()
            h.time += 0.1
            boundary = lostBoundary
            h.reveal.pollHover()
            boundary = standing
            h.reveal.pollHover()
            h.time += 1
            h.reveal.pollHover()
            #expect(h.reveals == 0)
            h.point.x += 1
            h.reveal.pollHover()
            #expect(h.reveals == 0)
            h.time += 0.2
            h.reveal.pollHover()
            #expect(h.reveals == 1)
        }
    }

    /// A reveal wired to counters with a manual clock, a fixed row,
    /// and a pointer the test steers.
    @MainActor
    private final class RevealHarness {
        let reveal = MenuBarReveal()
        var boundaryUtility: MenuBarUtility?
        var boundaryHost: HoverBoundaryHost?
        var reveals = 0
        var hides = 0
        var ownedElsewhere = false
        var point = NSPoint(x: 400, y: 400)
        var pending: (@MainActor () -> Void)?
        var delays: [TimeInterval] = []
        var traces: [String] = []
        var time = Date(timeIntervalSince1970: 1000)
        let rowRect = NSRect(x: 0, y: 958, width: 1512, height: 27)

        init() {
            reveal.diagnostic = { [weak self] in self?.traces.append($0) }
            reveal.onReveal = { [weak self] in self?.reveals += 1 }
            reveal.onHide = { [weak self] in self?.hides += 1 }
            reveal.gestureOwnedElsewhere = { [weak self] _ in self?.ownedElsewhere ?? false }
            reveal.row = { [weak self] in self?.rowRect }
            reveal.mouseLocation = { [weak self] in self?.point ?? .zero }
            reveal.now = { [weak self] in self?.time ?? .distantPast }
            // The dwell is a wall-clock deadline — zero keeps the
            // entry-fires-once semantics these tests pin.
            reveal.hoverDwell = 0
            reveal.scheduleRehide = { [weak self] seconds, fire in
                self?.delays.append(seconds)
                self?.pending = fire
                return {}
            }
        }
        /// The rehide clock's landing, fired by hand.
        func fireClock() { pending?() }
    }

    @MainActor
    @Test("hover reveal uses a short exit grace while deliberate reveal keeps its timer")
    func hoverExitGrace() {
        let h = RevealHarness()
        var settings = MenuBarSettings()
        settings.rehideMode = .timed
        settings.rehideSeconds = 15
        let configured = settings
        h.reveal.settings = { configured }
        h.point = NSPoint(x: 400, y: 965)
        h.reveal.pointerEnteredRow()
        #expect((h.delays.last ?? 15) <= 0.35)
        h.fireClock()
        #expect(h.hides == 0)
        #expect((h.delays.last ?? 15) <= 0.35)
        h.point = NSPoint(x: 400, y: 400)
        h.reveal.itemMenuOpen = { true }
        h.fireClock()
        #expect(h.hides == 0)
        #expect(h.traces.contains { $0.contains("menu=true") })
        h.reveal.itemMenuOpen = { false }
        h.fireClock()
        #expect(h.hides == 1)
        h.time += 1
        h.reveal.triggerReveal("deliberate click")
        #expect(h.delays.last == 15)
        h.reveal.pointerEnteredRow()
        #expect(h.delays.last == 15, "Hovering over a deliberate reveal must not shorten its timer")
    }

    @MainActor
    @Test("configured hover entry and exit clocks remain independent of deliberate reveals")
    func configuredHoverClocks() {
        let h = RevealHarness()
        let settings = MenuBarSettings(rehideSeconds: 9, hoverRevealSeconds: 0.4, hoverHideSeconds: 0.6)
        h.reveal.settings = { settings }
        let reveal = MenuBarReveal()
        reveal.settings = { settings }
        #expect(reveal.hoverDwell == 0.4)
        h.point = NSPoint(x: 400, y: 965)
        h.reveal.pointerEnteredRow()
        #expect(h.delays.last == 0.6)
        h.reveal.cancelReveal()
        h.time += 1
        h.reveal.triggerReveal("click")
        #expect(h.delays.last == 9)
    }

    @MainActor
    @Test("Notch-owned hover, clicks and scrolls cannot start native reveal or its clock")
    func notchOwnsRevealGesture() {
        let h = RevealHarness()
        h.point = NSPoint(x: 400, y: 965)
        h.ownedElsewhere = true
        let hotFrame = h.rowRect
        h.reveal.hotFrames = { [hotFrame] }
        h.reveal.pollHover()
        h.reveal.pointerEnteredRow()
        h.reveal.pointerDown(at: h.point)
        h.reveal.scrolled()
        #expect(h.reveals == 0)
        #expect(!h.reveal.revealed)
        #expect(h.pending == nil)
    }

    @MainActor
    @Test("queued click and scroll ownership follows the event origin after the cursor moves")
    func delayedGestureKeepsItsOrigin() {
        let nativePoint = NSPoint(x: 400, y: 965)
        let notchPoint = NSPoint(x: 1000, y: 965)
        for scroll in [false, true] {
            let native = RevealHarness()
            native.point = notchPoint
            native.reveal.gestureOwnedElsewhere = { $0.x >= 900 }
            if scroll { native.reveal.scrolled(at: nativePoint) }
            else { native.reveal.pointerDown(at: nativePoint) }
            #expect(native.reveals == 1, "a native gesture keeps its origin")
            let notch = RevealHarness()
            notch.point = nativePoint
            notch.reveal.gestureOwnedElsewhere = { $0.x >= 900 }
            if scroll { notch.reveal.scrolled(at: notchPoint) }
            else { notch.reveal.pointerDown(at: notchPoint) }
            #expect(notch.reveals == 0 && notch.pending == nil, "a Notch gesture stays with the Notch")
        }
    }

    @MainActor
    @Test("crossing the hidden space never completes a stationary hover dwell")
    func movingAcrossBlankSpaceDoesNotReveal() {
        let h = RevealHarness()
        h.reveal.hoverDwell = 0.18
        h.point = NSPoint(x: 400, y: 965)
        h.reveal.pollHover()
        for _ in 0..<8 {
            h.time += 0.1
            h.point.x += 12
            h.reveal.pollHover()
        }
        #expect(h.reveals == 0)
        h.time += 0.19
        h.reveal.pollHover()
        #expect(h.reveals == 1, "resting in the blank space still reveals at the configured delay")
        h.time += 1
        h.reveal.pollHover()
        #expect(h.reveals == 1)
    }

    @MainActor
    @Test("small pointer tremor does not prevent a deliberate hover reveal")
    func hoverDwellAllowsSmallTremor() {
        let h = RevealHarness()
        h.reveal.hoverDwell = 0.18
        h.point = NSPoint(x: 400, y: 965)
        h.reveal.pollHover()
        h.time += 0.1
        h.point.x += 1
        h.reveal.pollHover()
        h.time += 0.1
        h.point.x += 1
        h.reveal.pollHover()
        #expect(h.reveals == 1)
    }

    @MainActor
    @Test("hover admission and ownership share one pointer sample")
    func hoverUsesOnePoint() {
        let h = RevealHarness()
        var reads = 0
        h.reveal.mouseLocation = {
            reads += 1
            return NSPoint(x: reads == 1 ? 400 : 1000, y: 965)
        }
        h.reveal.gestureOwnedElsewhere = { $0.x >= 900 }
        h.reveal.pollHover()
        #expect(reads == 1 && h.reveals == 1)
    }

    @MainActor
    @Test("an explicit item reveal remains available while the pointer is on the Notch")
    func explicitRevealKeepsItsIntent() {
        let h = RevealHarness()
        h.ownedElsewhere = true
        h.reveal.triggerReveal("explicit item pick")
        #expect(h.reveals == 1 && h.reveal.revealed)
        #expect(h.pending != nil)
    }

    @MainActor
    @Test("losing Notch ownership under a stationary pointer is not a native hover entry")
    func ownershipChangeNeedsFreshHover() {
        let h = RevealHarness()
        h.point = NSPoint(x: 400, y: 965)
        h.ownedElsewhere = true
        h.reveal.hoverDwell = 0.18
        h.reveal.pollHover()
        h.ownedElsewhere = false
        h.time += 1
        h.reveal.pollHover()
        #expect(h.reveals == 0)
        h.point.x += 1
        h.reveal.pollHover()
        h.time += 0.1
        h.reveal.pollHover()
        #expect(h.reveals == 0)
        h.time += 0.1
        h.reveal.pollHover()
        #expect(h.reveals == 1)
    }

    @MainActor
    @Test("divider reflow under a stationary pointer is not a fresh reveal gesture")
    func dividerReflowDoesNotReveal() {
        let h = RevealHarness()
        h.point = NSPoint(x: 400, y: 965)
        var zone = NSRect(x: 800, y: 958, width: 100, height: 27)
        h.reveal.revealZone = { zone }
        h.reveal.pollHover()
        zone.origin.x = 350
        h.reveal.pollHover()
        h.time += 1
        h.reveal.pollHover()
        #expect(h.reveals == 0)
        h.point.x += 1
        h.reveal.pollHover()
        #expect(h.reveals == 1)
        h.reveal.cancelReveal()
        zone.origin.x = 800
        h.reveal.pollHover()
        zone.origin.x = 350
        h.time += 1
        h.reveal.pollHover()
        #expect(h.reveals == 1)
        #expect(!h.reveal.revealed)
        h.point.x += 1
        h.reveal.pollHover()
        #expect(h.reveals == 2)
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
    @Test("a sustained gesture burst keeps one reveal until the input pauses")
    func sustainedRevealBurst() {
        let h = RevealHarness()
        defer { h.reveal.stop() }
        h.reveal.triggerReveal()
        for _ in 0..<4 {
            h.time = h.time.addingTimeInterval(0.3)
            h.reveal.triggerReveal()
            #expect(h.reveals == 1)
        }
        h.time = h.time.addingTimeInterval(MenuBarReveal.revealThrottle + 0.01)
        h.reveal.triggerReveal()
        #expect(h.reveals == 2, "a new gesture after a pause can reopen the surface")
        h.reveal.cancelReveal()
        h.reveal.triggerReveal()
        #expect(h.reveals == 3, "an explicit hide must not suppress the next reveal")
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
    @Test("the native button owns its click while blank-space hover can still reveal")
    func dividerClickHasOneOwner() {
        let h = RevealHarness()
        let divider = NSRect(x: 450, y: 958, width: 150, height: 24)
        h.reveal.clickHandledFrames = { [divider] }
        h.reveal.hotFrames = { [divider] }
        var shown = false
        h.reveal.onReveal = { shown = true }
        h.reveal.pointerDown(at: NSPoint(x: 500, y: 965))
        #expect(!shown, "mouse-down must leave the native button's toggle alone")
        shown.toggle()
        #expect(shown, "the button's mouse-up opens rather than closes the reveal")
        h.point = NSPoint(x: 500, y: 965)
        h.reveal.pollHover()
        #expect(h.reveal.revealed, "the native click owner must not suppress hover")
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
    @Test("the hover poll parks while the displays sleep or the screen is locked, and resumes once both clear")
    func hoverPollParks() {
        let h = RevealHarness()
        h.reveal.startHoverPoll()
        #expect(h.reveal.hoverPollArmed)
        h.reveal.park(.displaysAsleep)
        h.reveal.park(.locked)
        #expect(!h.reveal.hoverPollArmed)
        h.reveal.unpark(.displaysAsleep)
        #expect(!h.reveal.hoverPollArmed, "awake behind the lock screen: still parked")
        h.reveal.unpark(.locked)
        #expect(h.reveal.hoverPollArmed)
        h.reveal.stop()
        #expect(!h.reveal.hoverPollArmed)
        h.reveal.park(.sessionInactive)
        h.reveal.unpark(.sessionInactive)
        #expect(!h.reveal.hoverPollArmed, "a resume after stop arms nothing")
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
        @Captured var bar: NSRect? = nil
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
    @Test("hovering another app's item is not an empty-space reveal gesture")
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
    @Test("an always-hidden pick writes just that item's cover and persists as one write")
    func setSectionCascades() {
        let utility = MenuBarUtility()
        var state = MenuBarSettings(enabled: true)
        var writes = 0
        utility.settings = { state }
        utility.onSettingsChange = { draft in state = draft; writes += 1 }
        utility.hider.listingIsComplete = { true }
        utility.hider.listItems = { [self.item("A", x: 100), self.item("B", x: 200), self.item("C", x: 300)] }
        utility.hider.rowRect = { self.row }
        utility.hider.shuttersSuppressed = true
        utility.hider.reconcile()   // fills lastPlan through onPlan — no covers, nothing moves
        utility.setSection(.alwaysHidden, for: "A")
        #expect(writes == 1)
        #expect(state.sections == ["A": .alwaysHidden])
    }

    @MainActor
    @Test("under the divider a hide pick is answered with the ⌘-drag, and writes nothing")
    func setSectionGuides() {
        let utility = MenuBarUtility()
        var state = MenuBarSettings(enabled: true)
        var writes = 0
        var notes: [String] = []
        utility.settings = { state }
        utility.onSettingsChange = { draft in state = draft; writes += 1 }
        utility.presentDropNote = { notes.append($0) }
        utility.hider.listingIsComplete = { true }
        utility.hider.obscuredFrames = { [] }
        utility.hider.listItems = { [self.item("A", x: 100), self.item("B", x: 200), self.item("C", x: 300)] }
        utility.hider.rowRect = { self.row }
        utility.hider.shuttersSuppressed = true
        utility.hider.reconcile()
        #expect(utility.lastPlan.shown.map(\.id) == ["A", "B", "C"])
        #expect(utility.lastPlan.hidden.isEmpty)
        utility.setSection(.hidden, for: "A")
        #expect(writes == 0, "JR-Bar never moves another app's item")
        #expect(state.sections.isEmpty)
        #expect(notes.count == 1)
        #expect(notes.first?.contains("⌘") == true && notes.first?.contains("left of the JR-Bar icon") == true)
        // Asking for what is already so says nothing.
        utility.setSection(.shown, for: "A")
        #expect(notes.count == 1)
    }

    @MainActor
    @Test("the Item Bar style opens the panel and never touches the row")
    func revealStyleBar() {
        let utility = MenuBarUtility()
        let state = MenuBarSettings(enabled: true, sections: ["A": .hidden],
                                    revealStyle: .bar)
        utility.settings = { state }
        utility.hider.listingIsComplete = { true }
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
        utility.hider.listingIsComplete = { true }
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
        utility.hider.listingIsComplete = { true }
        utility.hider.obscuredFrames = { [] }
        utility.hider.listItems = { [self.item("A", x: 100)] }
        utility.hider.rowRect = { self.row }
        utility.hider.shuttersSuppressed = true
        utility.hider.reconcile()
        #expect(utility.lastPlan.shown.map(\.id) == ["A"])
        #expect(utility.lastPlan.hidden.isEmpty)
        utility.reveal.onReveal()
        #expect(!utility.bar.isOpen)
        #expect(utility.hider.revealed.isEmpty)
    }

    @Test("synthetic menu obstruction alone changes shown items into hidden items")
    func syntheticObstructionChangesThePlan() {
        let items = [item("A", x: 100), item("B", x: 200)]
        let obstructed = MenuBarItemHider.plan(
            items: items, sections: [:], row: row, obscuredFrames: [row])
        #expect(obstructed.shown.isEmpty)
        #expect(obstructed.hidden.map(\.id) == ["A", "B"])
        let clear = MenuBarItemHider.plan(
            items: items, sections: [:], row: row, obscuredFrames: [])
        #expect(clear.shown.map(\.id) == ["A", "B"])
        #expect(clear.hidden.isEmpty)
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

    // MARK: lane menubar — the reveal stands down for a drag

    /// The dwell's clock and the drag's suppression, steered by hand.
    @MainActor
    private final class DragSteer {
        var now = Date(timeIntervalSince1970: 1_000)
        var suppressed = true
        var settings = MenuBarSettings(enabled: true)
    }

    @MainActor
    @Test("hover with the drag's suppression never reveals, and a fresh entry after it waits the full dwell")
    func hoverSuppressed() {
        let h = RevealHarness()
        let steer = DragSteer()
        h.reveal.now = { steer.now }
        h.reveal.hoverDwell = 0.18
        h.reveal.suppressed = { steer.suppressed }
        let inZone = NSPoint(x: 400, y: 965)
        let offRow = NSPoint(x: 400, y: 400)
        // Mid-drag, the pointer rests in the blank stretch for a while.
        h.point = inZone
        h.reveal.pollHover()
        steer.now += 1
        h.reveal.pollHover()
        #expect(h.reveals == 0, "a drag in flight is never a hover")
        // The drop landed there and the drag let go: still no entry.
        steer.suppressed = false
        h.reveal.pollHover()
        steer.now += 1
        h.reveal.pollHover()
        #expect(h.reveals == 0, "the pointer resting where the drop landed is not an entry")
        // A fresh entry waits the full dwell.
        h.point = offRow
        h.reveal.pollHover()
        h.point = inZone
        h.reveal.pollHover()
        #expect(h.reveals == 0)
        steer.now += 0.1
        h.reveal.pollHover()
        #expect(h.reveals == 0, "not before the dwell")
        steer.now += 0.1
        h.reveal.pollHover()
        #expect(h.reveals == 1)
    }

    @MainActor
    @Test("the rehide clock re-arms while a drag holds the bar, and folds once it lets go")
    func rehideWaitsForDrag() {
        let h = RevealHarness()
        let steer = DragSteer()
        h.reveal.suppressed = { steer.suppressed }
        h.reveal.triggerReveal()
        h.point = NSPoint(x: 400, y: 400)
        h.fireClock()
        #expect(h.hides == 0, "an inline reveal never folds mid-drag")
        steer.suppressed = false
        h.fireClock()
        #expect(h.hides == 1)
    }

    @MainActor
    @Test("under the focus-change rehide a reveal holds on no clock and folds when another app comes forward")
    func focusChangeRehide() {
        let h = RevealHarness()
        let steer = DragSteer()
        steer.settings.rehideMode = .focusChange
        h.reveal.settings = { steer.settings }
        h.reveal.triggerReveal()
        #expect(h.pending == nil, "no clock armed")
        h.reveal.frontAppChanged()
        #expect(h.hides == 1)
        #expect(!h.reveal.revealed)
        // A second switch with nothing out folds nothing.
        h.reveal.frontAppChanged()
        #expect(h.hides == 1)
        // Timed mode ignores the switch.
        steer.settings.rehideMode = .timed
        h.reveal.triggerReveal()
        h.reveal.frontAppChanged()
        #expect(h.hides == 1)
    }

    @Test("the monitor hands the drag only a ⌘-press on a bar and the release that ends it")
    func dragEventForwarding() {
        /// One left-button event and whether the drag hears it.
        struct Step {
            var down: Bool
            var command = false
            var onBar = true
            var heard: Bool
            var why: String
        }
        let steps = [
            Step(down: true, heard: false, why: "a plain press is no drag"),
            Step(down: false, heard: false, why: "and its release is never handed over"),
            Step(down: true, command: true, onBar: false, heard: false, why: "a ⌘-press off every bar"),
            Step(down: false, heard: false, why: "its release neither"),
            Step(down: true, command: true, heard: true, why: "a ⌘-press on a bar"),
            Step(down: false, heard: true, why: "its release ends the drag"),
            Step(down: false, heard: false, why: "one release per press"),
            // A ⌘-press whose release was lost, then a plain click: the
            // click's release is the click's, not the drag's.
            Step(down: true, command: true, heard: true, why: "a ⌘-press whose release gets lost"),
            Step(down: true, heard: false, why: "a plain click after it"),
            Step(down: false, heard: false, why: "the click's release is the click's"),
        ]
        var held = false
        for step in steps {
            let heard = MenuBarReveal.forwardsDragEvent(down: step.down, command: step.command,
                                                       onBar: step.onBar, held: &held)
            #expect(heard == step.heard, "\(step.why)")
        }
    }
}
