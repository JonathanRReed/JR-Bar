import AppKit
import JRBarCore
import OSLog

/// Where the utility's control sits right now, in Quartz coordinates.
/// A control that is not installed — or that macOS has parked off the
/// row — reports nil, and the plan treats its boundary as unknown.
///
/// One control, on purpose. A second status item of ours (the old
/// always-hidden control) traded places with the boundary every time
/// the spacer changed — a length write re-sorts the bar, and two of
/// our keys straddled the spacer's range — and each swap changed the
/// spacer again: a two-state dance at three beats a second, verified
/// live. The always-hidden section is override-only now.
struct MenuBarControlFrames: Equatable, Sendable {
    /// The boundary's live frame: the hidden run's edge and spacer —
    /// JR-Bar's own status item when it hosts the run, else the
    /// separate chevron.
    var hidden: CGRect?
    /// The boundary's glyph share — the icon's own width when JR-Bar's
    /// item hosts the run (a strip of session dots is wider than a
    /// chevron), `glyphLength` for the separate chevron.
    var hiddenGlyph: CGFloat = MenuBarControlFrames.glyphLength

    /// The glyph's share of a control — the part that is not spacer.
    /// A collapsed control is exactly this wide; an expanded one keeps
    /// its right-most glyph and spends the rest pushing items off the
    /// row.
    nonisolated static let glyphLength: CGFloat = 24

    init(hidden: CGRect? = nil, hiddenGlyph: CGFloat = MenuBarControlFrames.glyphLength) {
        self.hidden = hidden
        self.hiddenGlyph = hiddenGlyph
    }
}

/// The longest spacer the control may claim before macOS parks the
/// control itself — learned live: a control found off the row while it
/// should stand on it lowers its cap. Reset when the bar's geometry
/// changes (a screen reconfigure, another app's menus taking the left).
struct MenuBarSpacerCaps: Equatable, Sendable {
    var hidden: CGFloat = .infinity

    init(hidden: CGFloat = .infinity) {
        self.hidden = hidden
    }
}

/// Where the learned fit edge is kept between launches — keyed by the
/// screen it was learned on, so a display swap never applies one
/// bar's lesson to another. The default is `UserDefaults`; tests keep
/// theirs in memory.
@MainActor
protocol MenuBarFitEdgeStore: AnyObject {
    func load(key: String) -> CGFloat?
    func save(_ edge: CGFloat?, key: String)
}

@MainActor
final class MenuBarDefaultsFitEdgeStore: MenuBarFitEdgeStore {
    func load(key: String) -> CGFloat? {
        UserDefaults.standard.object(forKey: "JRBarMenuBar.fitEdge.\(key)") as? CGFloat
    }
    func save(_ edge: CGFloat?, key: String) {
        let name = "JRBarMenuBar.fitEdge.\(key)"
        if let edge { UserDefaults.standard.set(edge, forKey: name) }
        else { UserDefaults.standard.removeObject(forKey: name) }
    }
}

@MainActor
final class MenuBarMemoryFitEdgeStore: MenuBarFitEdgeStore {
    private(set) var edges: [String: CGFloat] = [:]
    func load(key: String) -> CGFloat? { edges[key] }
    func save(_ edge: CGFloat?, key: String) { edges[key] = edge }
}

/// What `reconcile` decided: every item's section, the spacer length
/// each control should claim, and the covers the explicit overrides
/// still need.
///
/// Sections are *positional*, the way Bartender's separator works: an
/// item to the left of the boundary is hidden, an item to the left of
/// the always-hidden control is always-hidden, everything else is
/// shown. Hiding is the boundary growing a spacer: macOS 26 packs the
/// status region right-to-left and parks whatever no longer fits in
/// its own overflow — verified live — so a spacer that claims the
/// stretch left of the boundary takes the hidden items off the row
/// without moving a single one. Revealing is the spacer collapsing.
struct MenuBarHidePlan: Equatable, Sendable {
    /// Items on the row, uncovered — everything right of the boundary
    /// without an override, plus protected owners wherever they sit.
    var shown: [MenuBarItem] = []
    /// Items left of the boundary, items macOS has parked, and items
    /// covered in place by an explicit override.
    var hidden: [MenuBarItem] = []
    /// Items overridden into the deeper section — hidden even while the
    /// hidden run is revealed. Override-only: there is no second
    /// control to stand left of.
    var alwaysHidden: [MenuBarItem] = []
    /// The Quartz x-ranges the hidden shutter covers — only overrides
    /// need one: an item that sits right of the boundary but was
    /// assigned hidden by hand. Positionally hidden items are pushed,
    /// never covered.
    var hiddenCovers: [ClosedRange<CGFloat>] = []
    /// Same for the deeper section's overrides.
    var alwaysHiddenCovers: [ClosedRange<CGFloat>] = []
    /// Bartender Golden Gate's swap: while a reveal is out with
    /// `hideShownWhileRevealing` on, the shown run is covered too —
    /// the bar reads as hidden-run-only. Empty in every other state.
    var shownCovers: [ClosedRange<CGFloat>] = []
    /// The length the boundary should claim; nil when it is not on the
    /// row (leave it be).
    var hiddenControlLength: CGFloat?
    /// macOS's own « while it stands beside a hidden run — the Screen
    /// Bar's ear stops short of it. Quartz.
    var overflowControlFrame: CGRect?
}

/// The hide machinery. Two mechanisms, one plan:
///
///   * **Spacer** (the default, positional): the boundary grows a
///     spacer that reaches from the *fit edge* to its glyph, so every
///     item left of it is packed off the row into macOS's own
///     overflow. Revealing collapses the spacer and the items pack
///     back where they were.
///   * **Covers** (overrides only): an item the person assigned hidden
///     by hand while it sits right of the boundary is covered in place
///     by a shutter panel — the only way to hide an item without
///     moving it, and honest about being a hole.
///
/// The fit edge is the one number the whole thing turns on: the screen
/// x where a spacer's left edge may land and still be drawn (macOS 26
/// draws a status item only when it fits; one that reaches too far is
/// overflowed with its glyph, and then hides nothing visibly). It is a
/// property of the screen — the notch's edge plus the room the system
/// keeps for its own « — not of our layout, so it is learned once and
/// remembered per screen: start from `fitInset` right of the notch,
/// and whenever the « lands on the boundary's glyph (the proof of an
/// overflowed boundary) move the edge right by `overflowStep`. It is
/// never moved left on its own — a spacer that once drew keeps
/// drawing — and a screen change reloads the edge learned for that
/// screen.
///
/// Nothing in this file posts events or moves the pointer. Physically
/// reordering items belongs to `MenuBarItemMover`, which only an
/// explicit, user-initiated arrange gesture may ever invoke.
///
/// Reconcile runs after every AX scan, on a 1 Hz timer while a boundary
/// stands or the listing is the live window list (`timerTick`), and on
/// `didChangeScreenParameters`: items come and go as other apps add and
/// remove theirs, and the controls' frames drift when the bar reflows,
/// so each pass re-reads the cached listing, re-measures the controls,
/// and re-applies the lengths.
@MainActor
final class MenuBarItemHider {
    static let log = Logger(subsystem: "devin.jrbar", category: "menubar")

    /// The current settings, supplied by the owning utility.
    var settings: @MainActor () -> MenuBarSettings = { MenuBarSettings() }
    /// Every reconcile hands the fresh plan up — the card's count row
    /// and the bar's tiles read it.
    var onPlan: (@MainActor (MenuBarHidePlan) -> Void)?

    /// Seams so a test can drive `reconcile` without a screen, an AX
    /// scan, or control items: the row, the items the list would
    /// report, the controls' live frames, the fit edge's first guess,
    /// and the Quartz-space frames a cover must never span.
    var rowRect: @MainActor () -> CGRect = { MenuBarItemLister.menuBarRow() }
    var listItems: @MainActor () -> [MenuBarItem] = { MenuBarItemLister.list() }
    /// Whether the listing loop keeps `listItems` fresh and reconciles
    /// after each scan — true under Accessibility, where the list is
    /// the AX scan's cache. The 1 Hz pass stands down then unless a
    /// boundary is on the row (see `timerTick`).
    var listingIsScanned: @MainActor () -> Bool = { MenuBarItemLister.axTrusted() }
    var controlFrames: @MainActor () -> MenuBarControlFrames = { MenuBarControlFrames() }
    /// The first guess at the fit edge — `fitInset` right of the notch
    /// on a notched display. nil means unknown: the controls stay
    /// collapsed.
    var guessedFitEdge: @MainActor () -> CGFloat? = { MenuBarItemHider.currentGuessedFitEdge() }
    /// The key the learned edge is remembered under — the screen's size.
    var edgeKey: @MainActor () -> String = { MenuBarItemHider.currentEdgeKey() }
    /// Where the learned edge persists.
    var edgeStore: any MenuBarFitEdgeStore = MenuBarDefaultsFitEdgeStore()
    var protectedFrames: @MainActor () -> [CGRect] = { [] }
    /// On-row zones where an item is drawn but unreachable — the
    /// notch band, the stretch the front app's menus overdraw. Items
    /// there plan as hidden so the Item Bar can reach them.
    var obscuredFrames: @MainActor () -> [CGRect] = { [] }
    /// The listing's generation — bumped per completed AX scan — so a
    /// rule that reads item frames after a length write can wait for a
    /// listing taken after the bar reflowed.
    var listingGeneration: @MainActor () -> Int = { MenuBarItemLister.axGeneration }
    /// The utility's write path for a control's length.
    var setControlLength: @MainActor (MenuBarItemSection, CGFloat) -> Void = { _, _ in }
    /// Test seam: suppress the cover panels entirely — a unit test
    /// must not draw over the real menu bar.
    /// Under the agent (`startConcealer`) this stands too — the spacer
    /// stays down — but an `externalPlan` the utility hands over still
    /// draws its covers (items the agent cannot target, e.g. helpers
    /// with no bundle identifier).
    var shuttersSuppressed = false
    /// The utility-owned plan drawn while `shuttersSuppressed` stands.
    /// nil under the spacer engine.
    var externalPlan: MenuBarHidePlan?

    private let hiddenShutter = MenuBarShutter()
    private let alwaysHiddenShutter = MenuBarShutter()
    private var timer: Timer?
    private var observers: [NSObjectProtocol] = []
    private var settleTask: Task<Void, Never>?
    /// Sections a reveal gesture has uncovered.
    private(set) var revealed: Set<MenuBarItemSection> = []
    /// The Item Bar's own reveal signal: under `.bar` style the covers
    /// never drop, so `revealed` stays empty — the utility reports the
    /// bar's open state here so `coverShown` fires under both styles.
    private var barCoveringShown = false
    /// The last plan — the card's "N hidden · M always-hidden" row.
    private(set) var lastPlan = MenuBarHidePlan()
    /// The parked caps learned this geometry.
    private(set) var caps = MenuBarSpacerCaps()
    /// The lengths last handed to `setControlLength`, so a parked
    /// control's cap can be derived from what it was asked to claim.
    private(set) var assignedLengths: [MenuBarItemSection: CGFloat] = [:]
    /// The listing generation at the last length write — frames from
    /// that generation predate the reflow the write caused.
    private var lengthWrittenAtGeneration = -1
    /// Fresh listings in a row that showed the « on our glyph. A lesson
    /// needs two: one listing's proof can be the handoff at launch (the
    /// old instance's item still on the bar, so the new one's spacer
    /// briefly did not fit) or a reflow read half-way — both moved the
    /// edge right for nothing, and the edge never comes back on its own.
    private var overflowStreak = 0
    private var overflowSeenAtGeneration = -1
    /// The length the last pass wanted but did not write yet — a write
    /// needs two passes in a row to agree (see `request`).
    private(set) var pendingLength: CGFloat?
    /// When the last length went out; the next waits `writeCooldown`.
    private var lastWriteAt: Date = .distantPast
    /// A reveal or a hide writes on the very next pass — the person is
    /// waiting on it. Set by `reveal`/`hide`, spent by the next write.
    private var writeAtOnce = false
    /// Test seam for the cooldown clock.
    var now: @MainActor () -> Date = { Date() }
    /// The boundary's right edge the current length was computed from —
    /// the pack anchors there. A right edge that moved with the length
    /// unchanged is the whole bar shifting (macOS's recording indicator
    /// appearing beside the clock, a wider battery or weather readout,
    /// the clock ticking to a wider time), not a change in what the
    /// spacer should reach — and an overflow read under a shift is the
    /// shift's doing, never the edge's.
    private var restMaxX: CGFloat?
    /// The right edge the pass now planning read — `assign` keeps it as
    /// `restMaxX` when the length goes out.
    private var planningMaxX: CGFloat?
    /// Since when a shorter length has been wanted.
    private var shrinkWantedSince: Date?
    /// The fit edge learned for this screen — nil until the first
    /// overflow moved it off the guess. Loaded from `edgeStore`.
    private(set) var learnedFitEdge: CGFloat?
    private var loadedEdgeKey: String?

    /// The AX listing's refresh cadence driver.
    private var listingTask: Task<Void, Never>?
    /// How often the AX listing re-scans while the utility runs.
    nonisolated static let listingInterval: TimeInterval = 2.0
    /// The first guess at how far right of the notch's edge a spacer's
    /// left edge may land and still be drawn: the room macOS keeps for
    /// its own « plus its gaps. Measured on a notched MacBook Pro
    /// (2026-09-15): 54 pt held, 46 pt overflowed. A screen that needs
    /// more learns it in `overflowStep`s.
    nonisolated static let fitInset: CGFloat = 54
    /// How much a cap drops each time a control is found parked.
    nonisolated static let capStep: CGFloat = 40
    /// How far right the fit edge moves each time the « lands on the
    /// boundary's glyph.
    nonisolated static let overflowStep: CGFloat = 8
    /// The beat after a length change before the plan is re-read —
    /// the bar reflows asynchronously.
    nonisolated static let settleDelay: TimeInterval = 0.35
    /// The least time between two length writes. A write reflows the
    /// bar; frames read while it settles disagree with frames read at
    /// rest, and acting on each one is what a dance is made of.
    nonisolated static let writeCooldown: TimeInterval = 1.0
    /// How long a shorter length must be wanted before it goes out.
    /// The bar shifts left for a few seconds when macOS shows its
    /// screen-recording indicator (every Dock thumbnail capture); a
    /// spacer that chased it shrank, the indicator left, the spacer
    /// grew — a reflow each way, several times a preview. Overflowed
    /// for the shift's few seconds, the boundary and everything left
    /// of it simply sit in macOS's own overflow, and come back on
    /// their own when the bar shifts back. Nothing reappears: the
    /// overflow is the run's tail, and the boundary heads it.
    nonisolated static let shrinkHold: TimeInterval = 5.0

    /// Starts the reconcile cadence and the AX refresh loop. Safe to
    /// call twice.
    func start() {
        guard timer == nil else { return }
        reloadFitEdge()
        let timer = Timer(timeInterval: 1.0, repeats: true,
                          block: { [weak self] _ in
            MainActor.assumeIsolated { self?.timerTick() }
        })
        timer.tolerance = 0.25
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
        observers.append(NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.reloadFitEdge()
                self?.resetCaps()
                self?.reconcile()
            }
        })
        // Another app's menus take the left of the bar on a notch-less
        // screen: the room a spacer can claim changes with the
        // frontmost app, so the parked caps learned under one app are
        // forgotten under the next. The fit edge is the screen's and
        // stays.
        observers.append(NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.resetCaps()
                self?.scheduleSettle()
            }
        })
        // A launch or a quit changes who owns items: the next scan
        // walks every app; the ones between ask only known owners.
        for name in [NSWorkspace.didLaunchApplicationNotification,
                     NSWorkspace.didTerminateApplicationNotification] {
            observers.append(NSWorkspace.shared.notificationCenter.addObserver(
                forName: name, object: nil, queue: .main
            ) { _ in
                MainActor.assumeIsolated { MenuBarItemLister.invalidateOwners() }
            })
        }
        // The listing refreshes off-actor; each completed scan is a
        // reconcile. Skipped entirely without Accessibility — the
        // scan would only collect errors.
        listingTask = Task { [weak self] in
            while !Task.isCancelled {
                if MenuBarItemLister.axTrusted() {
                    _ = await MenuBarItemLister.refreshAXItems()
                    self?.reconcile()
                }
                try? await Task.sleep(nanoseconds: UInt64(Self.listingInterval * 1e9))
            }
        }
        reconcile()
    }

    /// The 1 Hz pass, for what the listing loop cannot see. A boundary on
    /// the row is the spacer engine's: the host item's frame drifts as
    /// the bar reflows and is read live each pass. Without Accessibility
    /// there is no loop and the window list is read per pass. Otherwise
    /// — the concealer, whose plan has no boundary, with the grant — the
    /// pass would re-plan the same cached listing the loop reconciled
    /// after its last scan and run the whole `onPlan` pipeline for
    /// nothing, two passes in three. Reveals, hides, settles and screen
    /// changes still reconcile on their own.
    func timerTick() {
        guard controlFrames().hidden != nil || !listingIsScanned() else { return }
        reconcile()
    }

    /// Stops reconciling, collapses the spacers, lifts the covers and
    /// cancels the refresh loop.
    func stop() {
        timer?.invalidate()
        timer = nil
        listingTask?.cancel()
        listingTask = nil
        settleTask?.cancel()
        settleTask = nil
        for observer in observers {
            NotificationCenter.default.removeObserver(observer)
            NSWorkspace.shared.notificationCenter.removeObserver(observer)
        }
        observers = []
        restoreAll()
    }

    isolated deinit {
        timer?.invalidate()
        listingTask?.cancel()
        settleTask?.cancel()
        for observer in observers {
            NotificationCenter.default.removeObserver(observer)
            NSWorkspace.shared.notificationCenter.removeObserver(observer)
        }
    }

    /// Every spacer collapsed and every cover down: hidden runs come
    /// back, reveals forgotten.
    func restoreAll() {
        revealed = []
        barCoveringShown = false
        hiddenShutter.orderOut()
        alwaysHiddenShutter.orderOut()
        pendingLength = nil
        assign(.hidden, length: MenuBarControlFrames.glyphLength)
        lastPlan = MenuBarHidePlan()
        onPlan?(lastPlan)
    }

    /// Forget the parked caps — the geometry they were learned under
    /// is gone.
    func resetCaps() {
        caps = MenuBarSpacerCaps()
    }

    /// The controls were torn down and reinstalled (a host arrived):
    /// the lengths handed to the old items mean nothing to the new ones.
    func controlsReinstalled() {
        assignedLengths = [:]
        pendingLength = nil
        lastWriteAt = .distantPast
        resetCaps()
        scheduleSettle()
    }

    /// Forget the learned fit edge for this screen — the card's reset,
    /// for a bar that has changed under us.
    func forgetFitEdge() {
        learnedFitEdge = nil
        edgeStore.save(nil, key: edgeKey())
        resetCaps()
        reconcile()
    }

    /// The fit edge in use: the learned one, else the guess.
    var fitEdge: CGFloat? { learnedFitEdge ?? guessedFitEdge() }

    /// Load the edge remembered for the current screen.
    private func reloadFitEdge() {
        let key = edgeKey()
        guard key != loadedEdgeKey else { return }
        loadedEdgeKey = key
        learnedFitEdge = edgeStore.load(key: key)
    }

    /// A gesture asks for these sections back for a while; `hide`
    /// pushes them off again.
    func reveal(_ sections: Set<MenuBarItemSection>) {
        revealed.formUnion(sections)
        writeAtOnce = true
        reconcile()
        scheduleSettle()
    }

    /// The rehide timer's landing: the spacers grow back.
    func hide() {
        guard !revealed.isEmpty else { return }
        revealed = []
        writeAtOnce = true
        reconcile()
        scheduleSettle()
    }

    /// The Item Bar opened or closed — the `.bar`-style half of the
    /// Golden Gate swap. The flag lives in settings; this is only the
    /// "a reveal surface is up" bit, so a mid-session toggle of the
    /// setting takes effect on the next reconcile either way.
    func setBarCoveringShown(_ covering: Bool) {
        guard barCoveringShown != covering else { return }
        barCoveringShown = covering
        reconcile()
    }

    /// One more reconcile after the bar has had a beat to reflow.
    func scheduleSettle() {
        settleTask?.cancel()
        settleTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(Self.settleDelay * 1e9))
            guard !Task.isCancelled else { return }
            self?.reconcile()
        }
    }

    /// Recompute the plan, the spacer lengths and the covers.
    func reconcile() {
        let row = rowRect()
        let controls = controlFrames()
        let items = listItems()
        learnCaps(controls: controls, row: row)
        learnOverflow(controls: controls, row: row, items: items)
        let edge = fitEdge
        planningMaxX = controls.hidden.flatMap { $0.intersects(row) ? $0.maxX : nil }
        let coverShown = settings().hideShownWhileRevealing
            && (revealed.contains(.hidden) || barCoveringShown)
        let plan = Self.plan(items: items,
                             sections: settings().sections, row: row,
                             otherRows: MenuBarItemLister.menuBarRows().filter { $0 != row },
                             controls: controls, fitEdge: edge,
                             revealed: revealed, caps: caps,
                             protectedFrames: protectedFrames(),
                             obscuredFrames: obscuredFrames(),
                             coverShown: coverShown)
        let changed = plan != lastPlan
        lastPlan = plan
        if let length = plan.hiddenControlLength { request(length) }
        // The plan lands with the utility before the shutters update:
        // under the concealer the callback hands back `externalPlan`,
        // and reading it here keeps the cover pass on this listing
        // instead of lagging one behind.
        onPlan?(plan)
        updateShutters(plan: plan, row: row)
        if changed {
            let describe = { (r: CGRect?) -> String in
                r.map { String(format: "%.0f–%.0f@%.0f", $0.minX, $0.maxX, $0.minY) } ?? "none"
            }
            let tag = { (i: MenuBarItem) in "\(i.id)@\(Int(i.bounds.minX))" }
            Self.log.notice("plan: boundary \(describe(controls.hidden), privacy: .public) → \(plan.hiddenControlLength.map { String(format: "%.0f", $0) } ?? "–", privacy: .public); fit edge \(edge.map { String(format: "%.0f", $0) } ?? "nil", privacy: .public)\(self.learnedFitEdge == nil ? " (guess)" : " (learned)", privacy: .public); revealed \(self.revealed.map(\.rawValue).sorted().joined(separator: ","), privacy: .public); shown \(plan.shown.map(tag).joined(separator: " | "), privacy: .public); hidden \(plan.hidden.map(tag).joined(separator: " | "), privacy: .public); always \(plan.alwaysHidden.map(tag).joined(separator: " | "), privacy: .public); covers \(plan.hiddenCovers.count + plan.alwaysHiddenCovers.count, privacy: .public)")
        }
    }

    /// A control that should stand on the row but is off it was parked
    /// by macOS because its spacer did not fit: lower its cap below
    /// what it was asked to claim and collapse it, so the next pass
    /// measures it on the row and grows it again — under the cap.
    private func learnCaps(controls: MenuBarControlFrames, row: CGRect) {
        let glyph = controls.hiddenGlyph
        let hiddenOnRow = controls.hidden.map { $0.intersects(row) } ?? true
        if controls.hidden != nil, !hiddenOnRow {
            let asked = assignedLengths[.hidden] ?? glyph
            if asked > glyph + 1 {
                caps.hidden = max(glyph, asked - Self.capStep)
                Self.log.notice("boundary parked at \(asked, privacy: .public)pt; cap now \(self.caps.hidden, privacy: .public)")
                assign(.hidden, length: glyph)
            }
        }
    }

    /// macOS's own overflow control sits at the left end of the visible
    /// run; when it sits at or past our boundary's glyph, the boundary
    /// itself was overflowed (not drawn) — the spacer reached too far.
    /// Pure on the frames, so a test can pin it.
    nonisolated static func controlOverflowed(controlFrame: CGRect, items: [MenuBarItem],
                                              row: CGRect,
                                              glyph: CGFloat = MenuBarControlFrames.glyphLength) -> Bool {
        guard let overflow = items.first(where: {
            $0.isNativeOverflowControl && $0.bounds.intersects(row)
        }) else { return false }
        return overflow.bounds.minX >= controlFrame.maxX - glyph - 4
    }

    /// The proof of an overflowed boundary moves the fit edge right —
    /// past the left edge the spacer was placed at — and remembers it
    /// for this screen. Only on listings taken after the last length
    /// write (earlier frames predate the reflow), and only when two
    /// fresh listings in a row agree (one can be a transient).
    private func learnOverflow(controls: MenuBarControlFrames, row: CGRect, items: [MenuBarItem]) {
        let generation = listingGeneration()
        guard generation > lengthWrittenAtGeneration else { return }
        guard let hidden = controls.hidden, hidden.intersects(row),
              !revealed.contains(.hidden),
              let asked = assignedLengths[.hidden],
              asked > controls.hiddenGlyph + 1 else { return }
        guard Self.controlOverflowed(controlFrame: hidden, items: items, row: row,
                                     glyph: controls.hiddenGlyph) else {
            overflowStreak = 0
            return
        }
        // Overflowed because the whole bar moved under the same length:
        // the edge is where it was; the shift will pass. A drift
        // counts as a clean listing — the streak restarts so the next
        // real overflow still needs two fresh listings in a row.
        if let restMaxX, abs(hidden.maxX - restMaxX) > 2 {
            overflowStreak = 0
            overflowSeenAtGeneration = -1
            return
        }
        guard generation != overflowSeenAtGeneration else { return }
        overflowSeenAtGeneration = generation
        overflowStreak += 1
        guard overflowStreak >= 2 else { return }
        overflowStreak = 0
        let placedEdge = hidden.maxX - asked
        let current = fitEdge ?? placedEdge
        let next = max(current, placedEdge) + Self.overflowStep
        learnedFitEdge = next
        edgeStore.save(next, key: edgeKey())
        // One step per listing, and the shorter spacer goes out on this
        // pass: an overflowed boundary is not drawn at all.
        lengthWrittenAtGeneration = listingGeneration()
        writeAtOnce = true
        Self.log.notice("boundary overflowed at \(asked, privacy: .public)pt (the « sits on it); fit edge now \(next, privacy: .public)")
    }

    /// The plan's length for the boundary, damped: it goes out when two
    /// passes in a row want it and `writeCooldown` has passed since the
    /// last write — except after a reveal or a hide, which write on the
    /// spot because a person is waiting on them. A length that flips
    /// between passes never goes out at all: that is the reflow being
    /// read mid-way, and writing it would keep the bar reflowing.
    private func request(_ length: CGFloat) {
        let rounded = length.rounded()
        if let current = assignedLengths[.hidden], abs(current - rounded) < 1 {
            pendingLength = nil
            shrinkWantedSince = nil
            return
        }
        if writeAtOnce {
            pendingLength = nil
            shrinkWantedSince = nil
            assign(.hidden, length: rounded)
            return
        }
        if let current = assignedLengths[.hidden], rounded < current {
            // A shorter spacer waits out `shrinkHold` — see there.
            let since = shrinkWantedSince ?? now()
            shrinkWantedSince = since
            guard now().timeIntervalSince(since) >= Self.shrinkHold else { return }
        } else {
            shrinkWantedSince = nil
        }
        guard now().timeIntervalSince(lastWriteAt) >= Self.writeCooldown else { return }
        if let pending = pendingLength, abs(pending - rounded) < 1 {
            pendingLength = nil
            assign(.hidden, length: rounded)
        } else {
            pendingLength = rounded
        }
    }

    /// Hand a length to the utility only when it changes — a status
    /// item's length write reflows the whole bar.
    private func assign(_ section: MenuBarItemSection, length: CGFloat) {
        let rounded = length.rounded()
        writeAtOnce = false
        if let current = assignedLengths[section], abs(current - rounded) < 1 { return }
        assignedLengths[section] = rounded
        lengthWrittenAtGeneration = listingGeneration()
        lastWriteAt = now()
        restMaxX = planningMaxX
        setControlLength(section, rounded)
        scheduleSettle()
    }

    /// The last blend probe's answer and when it ran — re-sampling is
    /// a screen capture, so it is cached rather than paid every pass.
    private var blendSample: (hex: String, at: Date)?
    private var blendProbeInFlight = false
    /// The probe's pixel source — the same ScreenCaptureKit one-shot
    /// the tiles use; nil falls back to the shared display filter.
    var blendCapture: (@MainActor (CGRect) async -> CGImage?)?
    private let blendFilterSource = DisplayFilterSource()

    /// Make the shutters match the plan and the reveal state.
    private func updateShutters(plan: MenuBarHidePlan, row: CGRect) {
        // Under the agent the reconcile's own positional plan draws
        // nothing — unless the utility handed over an external plan
        // carrying covers for items the agent cannot target.
        let effective = externalPlan ?? plan
        guard !shuttersSuppressed || externalPlan != nil else {
            hiddenShutter.orderOut()
            alwaysHiddenShutter.orderOut()
            return
        }
        var appearance = MenuBarCoverAppearance(settings: settings())
        if appearance.material == .blend {
            appearance.blendHex = blendHex(plan: effective, row: row)
        }
        hiddenShutter.cover(revealed.contains(.hidden) ? [] : effective.hiddenCovers,
                            rowHeight: row.height, appearance: appearance)
        // The swap's covers ride this shutter: `shownCovers` come from
        // the fresh plan (never `externalPlan` — the concealer's
        // handoff carries no shown coverage) and paint while any
        // reveal surface is up.
        alwaysHiddenShutter.cover(
            (revealed.contains(.alwaysHidden) ? [] : effective.alwaysHiddenCovers)
                + plan.shownCovers,
            rowHeight: row.height, appearance: appearance)
    }

    /// The sampled bar color for `.blend` covers — the cached answer
    /// while a capture is in flight, "" when nothing has landed yet
    /// (the material fallback stands in for the sample). The probe is
    /// a strip of real bar just outside a covered run — never over a
    /// shown item or another run — captured off the render path.
    private func blendHex(plan: MenuBarHidePlan, row: CGRect) -> String {
        if let cached = blendSample, now().timeIntervalSince(cached.at) < 1.5 {
            return cached.hex
        }
        let runs = plan.hiddenCovers + plan.alwaysHiddenCovers
        guard let run = runs.first, !blendProbeInFlight else {
            blendSample = (blendSample?.hex ?? "", now())
            return blendSample?.hex ?? ""
        }
        let blockers = plan.shown.map(\.bounds)
        let probes = [
            CGRect(x: run.lowerBound - 26, y: row.minY, width: 22, height: row.height),
            CGRect(x: run.upperBound + 4, y: row.minY, width: 22, height: row.height),
        ]
        guard let probe = probes.first(where: { p in
            !blockers.contains { $0.intersects(p) }
                && !runs.contains { $0.lowerBound < p.maxX && $0.upperBound > p.minX }
        }) else {
            blendSample = ("", now())
            return ""
        }
        blendProbeInFlight = true
        let capture = blendCapture ?? { [blendFilterSource] rect in
            await blendFilterSource.capture(rect)
        }
        Task { [weak self] in
            let image = await capture(probe)
            let hex = image.flatMap { MenuBarBarSampler.averageHex(of: $0) } ?? ""
            self?.blendSample = (hex, self?.now() ?? Date())
            self?.blendProbeInFlight = false
        }
        return blendSample?.hex ?? ""
    }

    // MARK: Geometry

    /// The first guess at the fit edge on the screen carrying the menu
    /// bar: `fitInset` right of the notch's right edge where there is
    /// one. Without a notch the app menus' extent is unknowable from
    /// here, so the midpoint stands in — a spacer that reaches past the
    /// real edge is parked, learned, and capped.
    static func currentGuessedFitEdge() -> CGFloat? {
        guard let screen = NSScreen.main else { return nil }
        if let right = screen.auxiliaryTopRightArea {
            // AppKit and Quartz share x on the main display.
            return right.minX + fitInset
        }
        return screen.frame.midX
    }

    /// The learned edge's key: the main screen's size.
    static func currentEdgeKey() -> String {
        guard let screen = NSScreen.main else { return "none" }
        return "\(Int(screen.frame.width))x\(Int(screen.frame.height))"
    }

    // MARK: Plan (pure)

    /// The spacer a control on the row should claim so that every item
    /// left of it is pushed off: from the fit edge to the control's
    /// right edge (which the pack anchors), capped by what has been seen
    /// to fit, never shorter than the glyph.
    nonisolated static func spacerLength(controlFrame: CGRect, fitEdge: CGFloat,
                                         cap: CGFloat = .infinity,
                                         glyph: CGFloat = MenuBarControlFrames.glyphLength) -> CGFloat {
        max(glyph, min(cap, controlFrame.maxX - fitEdge))
    }

    /// The layout for a candidate list: an item's section is its
    /// position relative to the boundary — left of its glyph is hidden,
    /// the rest shown — unless an explicit override assigns it deeper
    /// (hidden, or always-hidden), in which case it is covered where
    /// it sits. Protected
    /// owners always report shown. Items macOS has parked off the row,
    /// or stacked under its overflow control, are hidden regardless —
    /// the Item Bar reaches them through `AXPress`.
    ///
    /// The boundary's length comes out of the same pass: on the row it
    /// claims `spacerLength` unless the run is revealed, in which case
    /// it collapses to the glyph. Off the row it reports nil — nothing
    /// to do until it is back.
    ///
    /// `coverShown` is the Golden Gate swap: the pass runs normally —
    /// so the section lists stay honest — then the shown run's frames
    /// additionally become `shownCovers`, painted like any other
    /// cover. Protected owners, the native overflow control, and the
    /// utility's own boundary are never covered: the rehide affordance
    /// and the system's own items must stay reachable.
    nonisolated static func plan(items: [MenuBarItem],
                                 sections: [String: MenuBarItemSection],
                                 row: CGRect,
                                 /// Every OTHER display's bar strip —
                                 /// an item standing on one is shown,
                                 /// never parked, but the boundary and
                                 /// covers are the managed row's alone.
                                 otherRows: [CGRect] = [],
                                 controls: MenuBarControlFrames = MenuBarControlFrames(),
                                 fitEdge: CGFloat? = nil,
                                 revealed: Set<MenuBarItemSection> = [],
                                 caps: MenuBarSpacerCaps = MenuBarSpacerCaps(),
                                 protectedFrames: [CGRect] = [],
                                 obscuredFrames: [CGRect] = [],
                                 coverShown: Bool = false) -> MenuBarHidePlan {
        var plan = MenuBarHidePlan()
        // A stable order: two overflowed items macOS stacks on one
        // position would otherwise trade places between listings and
        // flap the plan.
        let sorted = items.sorted {
            $0.bounds.minX != $1.bounds.minX ? $0.bounds.minX < $1.bounds.minX : $0.id < $1.id
        }
        let hiddenControl = controls.hidden.flatMap { $0.intersects(row) ? $0 : nil }
        // The boundary is the glyph's left edge: an item under the
        // spacer part of the control has been pushed, not shown.
        let hiddenBoundary = hiddenControl.map { $0.maxX - controls.hiddenGlyph }
        let overflowFrames = sorted.filter { $0.isNativeOverflowControl && $0.bounds.intersects(row) }
            .map(\.bounds)
        let onForeignRow: (CGRect) -> Bool = { bounds in
            otherRows.contains { $0.intersects(bounds) }
        }

        var hiddenToCover: [MenuBarItem] = []
        var ahToCover: [MenuBarItem] = []
        var parked: [MenuBarItem] = []
        for item in sorted {
            if MenuBarItemLister.isProtected(item) {
                if item.bounds.intersects(row) || onForeignRow(item.bounds) {
                    plan.shown.append(item)
                }
                continue
            }
            // Standing means on a row — any row. The boundary compare
            // only means something on the managed strip, so a foreign-
            // display item skips it and lands shown outright.
            let managed = item.bounds.intersects(row)
            let onRow = (managed || onForeignRow(item.bounds))
                && !overflowFrames.contains { $0.intersection(item.bounds).width >= 4 }
            guard onRow else {
                parked.append(item)
                continue
            }
            let positional: MenuBarItemSection
            if !managed {
                positional = .shown
            } else if let hiddenBoundary, item.bounds.minX < hiddenBoundary {
                positional = .hidden
            } else {
                positional = .shown
            }
            let override = sections[item.id].flatMap { $0 == .shown ? nil : $0 }
            var final = override ?? positional
            // An item under the notch or under the front app's menus is
            // drawn but unreachable — macOS leaves it behind the glass.
            // Hiding it is honest: the Item Bar lists it and a cover
            // marks the stretch as ours, never the item's pixels as
            // the bar's own blank space. An always-hidden override
            // already outranks the band.
            if final == .shown,
               obscuredFrames.contains(where: { $0.intersects(item.bounds) }) {
                final = .hidden
            }
            switch final {
            case .shown:
                plan.shown.append(item)
            case .hidden:
                plan.hidden.append(item)
                // Covers are painted on the managed row — a foreign-
                // display item must never feed a run's X-range.
                if managed, positional == .shown { hiddenToCover.append(item) }
            case .alwaysHidden:
                plan.alwaysHidden.append(item)
                if managed, positional == .shown { ahToCover.append(item) }
            }
        }
        // Parked items report after the on-row ones — their stashed
        // positions are not bar order. A parked item is hidden by
        // macOS itself; only an override can call it always-hidden.
        for item in parked {
            if sections[item.id] == .alwaysHidden {
                plan.alwaysHidden.append(item)
            } else {
                plan.hidden.append(item)
            }
        }
        // Covers span override items only. Shown items *and* the
        // utility's own controls are blockers: a run breaks rather than
        // cover either.
        let blockers = plan.shown.map(\.bounds) + protectedFrames
        plan.hiddenCovers = coverRuns(covered: hiddenToCover, blockers: blockers)
        plan.alwaysHiddenCovers = coverRuns(covered: ahToCover, blockers: blockers)
        // The swap: with a reveal out and the flag on, the shown run is
        // covered in place. Untouchables — protected owners, the native
        // «, the boundary itself — stay as blockers so a cover can
        // never paint over the affordance that ends the reveal.
        if coverShown {
            let coverable = plan.shown.filter {
                !MenuBarItemLister.isProtected($0) && !$0.isNativeOverflowControl
            }
            let untouchable = plan.shown.filter {
                MenuBarItemLister.isProtected($0) || $0.isNativeOverflowControl
            }.map(\.bounds)
            plan.shownCovers = coverRuns(
                covered: coverable,
                blockers: untouchable + protectedFrames
                    + [hiddenControl].compactMap { $0 })
        }
        // macOS's own « sits at the visible run's left end — flush
        // against the boundary's spacer. It draws above any panel of
        // ours (a cover under it hid nothing, verified live), so it
        // stays: it says "more here", which is true, and its popover
        // lists the hidden run. The Screen Bar's ear reads its frame
        // and stops short of it so the two never overlap.
        if let hiddenControl, !revealed.contains(.hidden),
           let overflow = overflowFrames.first(where: { $0.maxX <= hiddenControl.minX + 4 }) {
            plan.overflowControlFrame = overflow
        }

        // The spacer length.
        if let hiddenControl {
            if revealed.contains(.hidden) || fitEdge == nil {
                plan.hiddenControlLength = controls.hiddenGlyph
            } else if let fitEdge {
                plan.hiddenControlLength = spacerLength(
                    controlFrame: hiddenControl, fitEdge: fitEdge, cap: caps.hidden,
                    glyph: controls.hiddenGlyph)
            }
        }
        return plan
    }

    /// The plan with the utility parked: everything on a bar's row is
    /// shown, everything off all of them is already the system's
    /// hidden — and no covers are computed, because a parked utility
    /// draws none. `rows` carries every display's strip so a
    /// secondary-screen item isn't misread as hidden.
    nonisolated static func unzonedPlan(items: [MenuBarItem], rows: [CGRect]) -> MenuBarHidePlan {
        var plan = MenuBarHidePlan()
        plan.shown = items.filter { item in rows.contains { $0.intersects(item.bounds) } }
            .sorted { $0.bounds.minX < $1.bounds.minX }
        plan.alwaysHidden = items.filter { item in !rows.contains { $0.intersects(item.bounds) } }
        return plan
    }

    /// Group covered item frames into cover ranges. Items merge across
    /// an empty gap — the stretch reads as ordinary menu bar under the
    /// cover and doubles as reveal space — then every blocker frame (a
    /// shown item, one of the utility's own controls) is subtracted
    /// from each run: a cover must never hide what was not assigned,
    /// even when the bar packs two items into overlapping frames mid-
    /// reflow.
    nonisolated static func coverRuns(covered: [MenuBarItem],
                                      blockers: [CGRect]) -> [ClosedRange<CGFloat>] {
        var runs: [(start: CGFloat, end: CGFloat)] = []
        for item in covered.sorted(by: { $0.bounds.minX < $1.bounds.minX }) {
            if let last = runs.last {
                let touches = item.bounds.minX <= last.end + 1
                let gapBlocked = !touches && blockers.contains {
                    $0.minX < item.bounds.minX && $0.maxX > last.end
                }
                if touches || !gapBlocked {
                    runs[runs.count - 1] = (last.start, max(last.end, item.bounds.maxX))
                    continue
                }
            }
            runs.append((item.bounds.minX, item.bounds.maxX))
        }
        var out: [ClosedRange<CGFloat>] = []
        for run in runs {
            var segments: [(CGFloat, CGFloat)] = [(run.start, run.end)]
            for blocker in blockers where blocker.minX < run.end && blocker.maxX > run.start {
                segments = segments.flatMap { seg in
                    [ (seg.0, min(seg.1, blocker.minX)),
                      (max(seg.0, blocker.maxX), seg.1) ]
                        .filter { $0.1 - $0.0 > 4 }
                }
            }
            out.append(contentsOf: segments.map { $0.0...$0.1 })
        }
        return out
    }

    /// What "changed" means for show-for-updates: the title the app
    /// writes plus the identity-level churn an icon-only rewrite
    /// carries — the `AXIdentifier`, the extras index, the window. The
    /// bounds are deliberately absent: our own reveal moves them.
    nonisolated static func updateSignature(of item: MenuBarItem) -> String {
        "\(item.title ?? "")\u{1f}\(item.identifier ?? "")\u{1f}\(item.extrasIndex)\u{1f}\(item.windowID)"
    }

    /// "Show for updates": a hidden item whose signature changed
    /// between scans updated itself — a clock's minute, a VPN's
    /// "Connected", a download's percent, an icon swap. Bartender
    /// reveals the run for it; so do we. `sections` empty means
    /// nothing new — `signatures` is the fresh map either way, so a
    /// change that lands while a reveal is open seeds quietly instead
    /// of firing late.
    nonisolated static func updatedHidden(
        previous: [String: String],
        hidden: [MenuBarItem],
        alwaysHidden: [MenuBarItem]
    ) -> (sections: Set<MenuBarItemSection>, signatures: [String: String]) {
        var sections = Set<MenuBarItemSection>()
        var signatures: [String: String] = [:]
        for item in hidden {
            signatures[item.id] = updateSignature(of: item)
            if let old = previous[item.id], old != signatures[item.id] {
                sections.insert(.hidden)
            }
        }
        for item in alwaysHidden {
            signatures[item.id] = updateSignature(of: item)
            if let old = previous[item.id], old != signatures[item.id] {
                sections.insert(.alwaysHidden)
            }
        }
        return (sections, signatures)
    }

    /// The card's override write: the single mapping, kept honest — a
    /// protected owner is never written, a shown assignment clears the
    /// key (position decides again), and an item that is not listed
    /// still records its mapping for when it returns.
    /// - Parameters:
    ///   - items: the currently listed items (used to protect system
    ///     owners; order irrelevant).
    ///   - sections: the section map as persisted.
    ///   - changedID: the item the picker assigned.
    ///   - target: the section it was assigned to.
    nonisolated static func updatedSections(items: [MenuBarItem],
                                            sections: [String: MenuBarItemSection],
                                            changedID: String,
                                            target: MenuBarItemSection) -> [String: MenuBarItemSection] {
        var result = sections
        if let item = items.first(where: { $0.id == changedID }),
           MenuBarItemLister.isProtected(item) {
            return result
        }
        if target == .shown { result[changedID] = nil } else { result[changedID] = target }
        return result
    }
}
