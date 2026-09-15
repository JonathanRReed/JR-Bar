import AppKit
import JRBarCore
import OSLog

/// Where the utility's controls sit right now, in Quartz coordinates.
/// A control that is not installed — or that macOS has parked off the
/// row — reports nil, and the plan treats its boundary as unknown.
struct MenuBarControlFrames: Equatable, Sendable {
    /// The boundary's live frame: the hidden run's edge and spacer —
    /// JR-Bar's own status item when it hosts the run, else the
    /// separate chevron.
    var hidden: CGRect?
    /// The always-hidden control's live frame.
    var alwaysHidden: CGRect?
    /// The boundary's glyph share — the icon's own width when JR-Bar's
    /// item hosts the run (a strip of session dots is wider than a
    /// chevron), `glyphLength` for the separate chevron.
    var hiddenGlyph: CGFloat = MenuBarControlFrames.glyphLength

    /// The glyph's share of a control — the part that is not spacer.
    /// A collapsed control is exactly this wide; an expanded one keeps
    /// its right-most glyph and spends the rest pushing items off the
    /// row.
    nonisolated static let glyphLength: CGFloat = 24

    init(hidden: CGRect? = nil, alwaysHidden: CGRect? = nil,
         hiddenGlyph: CGFloat = MenuBarControlFrames.glyphLength) {
        self.hidden = hidden
        self.alwaysHidden = alwaysHidden
        self.hiddenGlyph = hiddenGlyph
    }
}

/// The longest spacer each control may claim before macOS parks the
/// control itself — learned live: a control found off the row while it
/// should stand on it lowers its cap. Reset when the bar's geometry
/// changes (a screen reconfigure, another app's menus taking the left).
struct MenuBarSpacerCaps: Equatable, Sendable {
    var hidden: CGFloat = .infinity
    var alwaysHidden: CGFloat = .infinity

    init(hidden: CGFloat = .infinity, alwaysHidden: CGFloat = .infinity) {
        self.hidden = hidden
        self.alwaysHidden = alwaysHidden
    }
}

/// What `reconcile` decided: every item's section, the spacer length
/// each control should claim, and the covers the explicit overrides
/// still need.
///
/// Sections are *positional*, the way Bartender's separator works: an
/// item to the left of the chevron is hidden, an item to the left of
/// the always-hidden control is always-hidden, everything else is
/// shown. Hiding is the chevron growing a spacer: macOS 26 packs the
/// status region right-to-left and parks whatever no longer fits in
/// its own overflow — verified live — so a spacer that claims the
/// stretch left of the chevron takes the hidden items off the row
/// without moving a single one. Revealing is the spacer collapsing.
struct MenuBarHidePlan: Equatable, Sendable {
    /// Items on the row, uncovered — everything right of the chevron
    /// without an override, plus protected owners wherever they sit.
    var shown: [MenuBarItem] = []
    /// Items left of the chevron, items macOS has parked, and items
    /// covered in place by an explicit override.
    var hidden: [MenuBarItem] = []
    /// Items left of the always-hidden control, or overridden into
    /// the deeper section.
    var alwaysHidden: [MenuBarItem] = []
    /// The Quartz x-ranges the hidden shutter covers — only overrides
    /// need one: an item that sits right of the chevron but was
    /// assigned hidden by hand. Positionally hidden items are pushed,
    /// never covered.
    var hiddenCovers: [ClosedRange<CGFloat>] = []
    /// Same for the deeper section's overrides.
    var alwaysHiddenCovers: [ClosedRange<CGFloat>] = []
    /// The length the chevron should claim; nil when it is not on the
    /// row (leave it be).
    var hiddenControlLength: CGFloat?
    /// The length the always-hidden control should claim; nil when it
    /// is not on the row.
    var alwaysHiddenControlLength: CGFloat?
}

/// The hide machinery. Two mechanisms, one plan:
///
///   * **Spacers** (the default, positional): each control grows a
///     spacer that reaches from just right of the region's left edge
///     to the control's glyph, so every item left of the control is
///     packed off the row into macOS's own overflow. Revealing
///     collapses the spacer and the items pack back where they were.
///   * **Covers** (overrides only): an item the person assigned hidden
///     by hand while it sits right of the chevron is covered in place
///     by a shutter panel — the only way to hide an item without
///     moving it, and honest about being a hole.
///
/// Nothing in this file posts events or moves the pointer. Physically
/// reordering items belongs to `MenuBarItemMover`, which only an
/// explicit, user-initiated arrange gesture may ever invoke.
///
/// Reconcile runs on a timer plus `didChangeScreenParameters`: items
/// come and go as other apps add and remove theirs, and the controls'
/// frames drift when the bar reflows, so each pass re-reads the cached
/// listing, re-measures the controls, and re-applies the lengths.
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
    /// report, the controls' live frames, the region's left edge, and
    /// the Quartz-space frames a cover must never span.
    var rowRect: @MainActor () -> CGRect = { MenuBarItemLister.menuBarRow() }
    var listItems: @MainActor () -> [MenuBarItem] = { MenuBarItemLister.list() }
    var controlFrames: @MainActor () -> MenuBarControlFrames = { MenuBarControlFrames() }
    /// The left edge of the stretch status items may occupy — the
    /// notch's right edge on a notched display. A spacer never reaches
    /// past it. nil means unknown: the controls stay collapsed.
    var regionMin: @MainActor () -> CGFloat? = { MenuBarItemHider.currentRegionMin() }
    var protectedFrames: @MainActor () -> [CGRect] = { [] }
    /// The listing's generation — bumped per completed AX scan — so a
    /// rule that reads item frames after a length write can wait for a
    /// listing taken after the bar reflowed.
    var listingGeneration: @MainActor () -> Int = { MenuBarItemLister.axGeneration }
    /// The utility's write path for a control's length.
    var setControlLength: @MainActor (MenuBarItemSection, CGFloat) -> Void = { _, _ in }
    /// Test seam: suppress the cover panels entirely — a unit test
    /// must not draw over the real menu bar.
    var shuttersSuppressed = false

    private let hiddenShutter = MenuBarShutter()
    private let alwaysHiddenShutter = MenuBarShutter()
    private var timer: Timer?
    private var observers: [NSObjectProtocol] = []
    private var settleTask: Task<Void, Never>?
    /// Sections a reveal gesture has uncovered.
    private(set) var revealed: Set<MenuBarItemSection> = []
    /// The last plan — the card's "N hidden · M always-hidden" row.
    private(set) var lastPlan = MenuBarHidePlan()
    /// The fit caps learned this geometry.
    private(set) var caps = MenuBarSpacerCaps()
    /// The lengths last handed to `setControlLength`, so a parked
    /// control's cap can be derived from what it was asked to claim.
    private(set) var assignedLengths: [MenuBarItemSection: CGFloat] = [:]
    /// The listing generation at the last length write — frames from
    /// that generation predate the reflow the write caused.
    private var lengthWrittenAtGeneration = -1
    /// The region's left edge as the bar last packed it — the «'s left
    /// edge whenever it stood clear of our glyph. Remembered across cap
    /// resets so an app switch never restarts the settle from the notch
    /// edge; a screen change forgets it.
    private(set) var knownRegionEdge: CGFloat?

    /// The AX listing's refresh cadence driver.
    private var listingTask: Task<Void, Never>?
    /// How often the AX listing re-scans while the utility runs.
    nonisolated static let listingInterval: TimeInterval = 2.0
    /// The empty bar a spacer leaves between the region's edge and
    /// itself. Verified live: macOS 26 draws a status item only when it
    /// fits in the visible run, and puts its own overflow control
    /// (`«`, 17 pt) at the run's left end — so the spacer must leave
    /// room for that button or it is itself overflowed and its glyph
    /// never draws. The room is the button plus a few points, still
    /// narrower than any item, so nothing hidden slips back in.
    nonisolated static let spacerMargin: CGFloat = 22
    /// How much a cap drops each time a control is found parked.
    nonisolated static let capStep: CGFloat = 40
    /// The beat after a length change before the plan is re-read —
    /// the bar reflows asynchronously.
    nonisolated static let settleDelay: TimeInterval = 0.35

    /// Starts the reconcile cadence and the AX refresh loop. Safe to
    /// call twice.
    func start() {
        guard timer == nil else { return }
        let timer = Timer(timeInterval: 1.0, repeats: true,
                          block: { [weak self] _ in
            MainActor.assumeIsolated { self?.reconcile() }
        })
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
        observers.append(NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.knownRegionEdge = nil
                self?.resetCaps()
                self?.reconcile()
            }
        })
        // Another app's menus take the left of the bar: the room a
        // spacer can claim changes with the frontmost app, so the caps
        // learned under one app are forgotten under the next.
        observers.append(NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.resetCaps()
                self?.scheduleSettle()
            }
        })
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
        hiddenShutter.orderOut()
        alwaysHiddenShutter.orderOut()
        for section in [MenuBarItemSection.hidden, .alwaysHidden] {
            assign(section, length: MenuBarControlFrames.glyphLength)
        }
        lastPlan = MenuBarHidePlan()
        onPlan?(lastPlan)
    }

    /// Forget the learned caps — the geometry they were learned under
    /// is gone.
    func resetCaps() {
        caps = MenuBarSpacerCaps()
    }

    /// The controls were torn down and reinstalled (a reseat): the
    /// lengths handed to the old items mean nothing to the new ones.
    func controlsReinstalled() {
        assignedLengths = [:]
        resetCaps()
        scheduleSettle()
    }

    /// A gesture asks for these sections back for a while; `hide`
    /// pushes them off again.
    func reveal(_ sections: Set<MenuBarItemSection>) {
        revealed.formUnion(sections)
        reconcile()
        scheduleSettle()
    }

    /// The rehide timer's landing: the spacers grow back.
    func hide() {
        guard !revealed.isEmpty else { return }
        revealed = []
        reconcile()
        scheduleSettle()
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
        if let edge = Self.observedRegionEdge(controls: controls, items: items, row: row) {
            knownRegionEdge = edge
        }
        // A pushed always-hidden control keeps only its glyph, so when
        // the chevron collapses it comes back small and grows from a
        // measured slot rather than returning oversized and parking.
        if Self.alwaysHiddenPushed(controls: controls, row: row),
           (assignedLengths[.alwaysHidden] ?? 0) > MenuBarControlFrames.glyphLength + 1 {
            assign(.alwaysHidden, length: MenuBarControlFrames.glyphLength)
        }
        let plan = Self.plan(items: items,
                             sections: settings().sections, row: row,
                             controls: controls,
                             regionMin: Self.effectiveRegionMin(regionMin(), knownEdge: knownRegionEdge),
                             revealed: revealed, caps: caps,
                             protectedFrames: protectedFrames())
        let changed = plan != lastPlan
        lastPlan = plan
        if let length = plan.hiddenControlLength { assign(.hidden, length: length) }
        if let length = plan.alwaysHiddenControlLength { assign(.alwaysHidden, length: length) }
        updateShutters(plan: plan, rowHeight: row.height)
        onPlan?(plan)
        if changed {
            let describe = { (r: CGRect?) -> String in
                r.map { String(format: "%.0f–%.0f@%.0f", $0.minX, $0.maxX, $0.minY) } ?? "none"
            }
            Self.log.notice("plan: chevron \(describe(controls.hidden), privacy: .public) → \(plan.hiddenControlLength.map { String(format: "%.0f", $0) } ?? "–", privacy: .public); ah \(describe(controls.alwaysHidden), privacy: .public) → \(plan.alwaysHiddenControlLength.map { String(format: "%.0f", $0) } ?? "–", privacy: .public); regionMin \(self.regionMin().map { String(format: "%.0f", $0) } ?? "nil", privacy: .public); revealed \(self.revealed.map(\.rawValue).sorted().joined(separator: ","), privacy: .public); shown \(plan.shown.map(\.id).joined(separator: " | "), privacy: .public); hidden \(plan.hidden.map(\.id).joined(separator: " | "), privacy: .public); always \(plan.alwaysHidden.map(\.id).joined(separator: " | "), privacy: .public); covers \(plan.hiddenCovers.count + plan.alwaysHiddenCovers.count, privacy: .public)")
        }
    }

    /// A control that should stand on the row but is off it was parked
    /// by macOS because its spacer did not fit: lower its cap below
    /// what it was asked to claim and collapse it, so the next pass
    /// measures it on the row and grows it again — under the cap.
    private func learnCaps(controls: MenuBarControlFrames, row: CGRect) {
        let glyph = controls.hiddenGlyph
        let hiddenOnRow = controls.hidden.map { $0.intersects(row) } ?? true
        let hiddenExpanded = (assignedLengths[.hidden] ?? 0) > glyph + 1
        if controls.hidden != nil, !hiddenOnRow {
            let asked = assignedLengths[.hidden] ?? glyph
            if asked > glyph + 1 {
                caps.hidden = max(glyph, asked - Self.capStep)
                Self.log.notice("boundary parked at \(asked, privacy: .public)pt; cap now \(self.caps.hidden, privacy: .public)")
                assign(.hidden, length: glyph)
            }
        }
        // The always-hidden control is expected on the row only while
        // the chevron is collapsed — an expanded chevron pushes it off
        // by design.
        let ahOnRow = controls.alwaysHidden.map { $0.intersects(row) } ?? true
        if controls.alwaysHidden != nil, !ahOnRow, !hiddenExpanded {
            let asked = assignedLengths[.alwaysHidden] ?? MenuBarControlFrames.glyphLength
            if asked > MenuBarControlFrames.glyphLength + 1 {
                caps.alwaysHidden = max(MenuBarControlFrames.glyphLength, asked - Self.capStep)
                Self.log.notice("always-hidden control parked at \(asked, privacy: .public)pt; cap now \(self.caps.alwaysHidden, privacy: .public)")
                assign(.alwaysHidden, length: MenuBarControlFrames.glyphLength)
            }
        }
    }

    /// macOS's own overflow control sits at the left end of the visible
    /// run; when it sits at or past our control's glyph, our control
    /// itself was overflowed (not drawn) — the spacer reached too far.
    /// Lower the cap under what was asked so the next pass sizes it to
    /// fit. Pure on the frames, so a test can pin it.
    nonisolated static func controlOverflowed(controlFrame: CGRect, items: [MenuBarItem],
                                              row: CGRect,
                                              glyph: CGFloat = MenuBarControlFrames.glyphLength) -> Bool {
        guard let overflow = items.first(where: {
            $0.isNativeOverflowControl && $0.bounds.intersects(row)
        }) else { return false }
        return overflow.bounds.minX >= controlFrame.maxX - glyph - 4
    }

    /// The region's left edge as the bar actually packs it: macOS keeps
    /// its overflow control at the visible run's left end, so whenever
    /// the « stands clear of our glyph its own left edge is the truth —
    /// on this hardware ~28 pt right of the notch, not the notch edge.
    /// nil when there is no « or it sits on our glyph (then our chevron
    /// is the overflowed one and the « says nothing about the edge).
    nonisolated static func observedRegionEdge(controls: MenuBarControlFrames, items: [MenuBarItem],
                                               row: CGRect) -> CGFloat? {
        guard let hidden = controls.hidden, hidden.intersects(row),
              let overflow = items.first(where: { $0.isNativeOverflowControl && $0.bounds.intersects(row) }),
              overflow.bounds.maxX < hidden.maxX - controls.hiddenGlyph - 4 else { return nil }
        return overflow.bounds.minX
    }

    /// The edge a spacer sizes from: the remembered « edge when one has
    /// been seen, else the notch edge. Sizing from the « lands the
    /// spacer flush against it in one pass.
    nonisolated static func effectiveRegionMin(_ regionMin: CGFloat?, knownEdge: CGFloat?) -> CGFloat? {
        guard let regionMin else { return nil }
        guard let knownEdge else { return regionMin }
        return max(regionMin, knownEdge)
    }

    private func learnOverflow(controls: MenuBarControlFrames, row: CGRect, items: [MenuBarItem]) {
        // The listing must postdate the last length write — the frames
        // it carries are from before the bar reflowed otherwise, and
        // acting on them shrinks the spacer three times for one cause.
        guard listingGeneration() > lengthWrittenAtGeneration else { return }
        guard let hidden = controls.hidden, hidden.intersects(row),
              !revealed.contains(.hidden),
              let asked = assignedLengths[.hidden],
              asked > controls.hiddenGlyph + 1,
              Self.controlOverflowed(controlFrame: hidden, items: items, row: row,
                                     glyph: controls.hiddenGlyph) else { return }
        let cap = max(controls.hiddenGlyph, asked - Self.overflowStep)
        guard cap < caps.hidden else { return }
        caps.hidden = cap
        Self.log.notice("chevron overflowed at \(asked, privacy: .public)pt (the « sits on it); cap now \(cap, privacy: .public)")
    }

    /// How much a spacer gives back when the overflow control lands on it.
    nonisolated static let overflowStep: CGFloat = 8
    /// Points of the « left bare under the ear so its ring never clips.
    nonisolated static let overflowCoverInset: CGFloat = 3

    /// Hand a length to the utility only when it changes — a status
    /// item's length write reflows the whole bar.
    private func assign(_ section: MenuBarItemSection, length: CGFloat) {
        let rounded = length.rounded()
        if let current = assignedLengths[section], abs(current - rounded) < 1 { return }
        assignedLengths[section] = rounded
        lengthWrittenAtGeneration = listingGeneration()
        setControlLength(section, rounded)
        scheduleSettle()
    }

    /// Make the shutters match the plan and the reveal state.
    private func updateShutters(plan: MenuBarHidePlan, rowHeight: CGFloat) {
        guard !shuttersSuppressed else {
            hiddenShutter.orderOut()
            alwaysHiddenShutter.orderOut()
            return
        }
        let appearance = MenuBarCoverAppearance(settings: settings())
        hiddenShutter.cover(revealed.contains(.hidden) ? [] : plan.hiddenCovers,
                            rowHeight: rowHeight, appearance: appearance)
        alwaysHiddenShutter.cover(revealed.contains(.alwaysHidden) ? [] : plan.alwaysHiddenCovers,
                                  rowHeight: rowHeight, appearance: appearance)
    }

    // MARK: Geometry

    /// The left edge of the status region on the screen carrying the
    /// menu bar: the notch's right edge where there is one. Without a
    /// notch the app menus' extent is unknowable from here, so the
    /// midpoint stands in — a spacer that reaches past the real edge
    /// is parked, learned, and capped.
    static func currentRegionMin() -> CGFloat? {
        guard let screen = NSScreen.main else { return nil }
        if let right = screen.auxiliaryTopRightArea {
            // AppKit and Quartz share x on the main display.
            return right.minX
        }
        return screen.frame.midX
    }

    // MARK: Plan (pure)

    /// The spacer a control on the row should claim so that every item
    /// left of it is pushed off: from `spacerMargin` right of the
    /// region's edge to the control's right edge (which the pack
    /// anchors), capped by what has been seen to fit, never shorter
    /// than the glyph.
    nonisolated static func spacerLength(controlFrame: CGRect, regionMin: CGFloat,
                                         cap: CGFloat = .infinity,
                                         glyph: CGFloat = MenuBarControlFrames.glyphLength) -> CGFloat {
        let wanted = controlFrame.maxX - regionMin - spacerMargin
        return max(glyph, min(cap, wanted))
    }

    /// The layout for a candidate list: an item's section is its
    /// position relative to the controls — left of the always-hidden
    /// control is always-hidden, left of the chevron's glyph is hidden,
    /// the rest shown — unless an explicit override assigns it deeper,
    /// in which case it is covered where it sits. Protected owners
    /// always report shown. Items macOS has parked off the row, or
    /// stacked under its overflow control, are hidden regardless — the
    /// Item Bar reaches them through `AXPress`.
    ///
    /// The control lengths come out of the same pass: a control on the
    /// row claims `spacerLength` unless its section is revealed, in
    /// which case it collapses to the glyph. A control off the row
    /// reports nil — nothing to do until it is back.
    nonisolated static func plan(items: [MenuBarItem],
                                 sections: [String: MenuBarItemSection],
                                 row: CGRect,
                                 controls: MenuBarControlFrames = MenuBarControlFrames(),
                                 regionMin: CGFloat? = nil,
                                 revealed: Set<MenuBarItemSection> = [],
                                 caps: MenuBarSpacerCaps = MenuBarSpacerCaps(),
                                 protectedFrames: [CGRect] = []) -> MenuBarHidePlan {
        var plan = MenuBarHidePlan()
        let sorted = items.sorted(by: { $0.bounds.minX < $1.bounds.minX })
        let hiddenControl = controls.hidden.flatMap { $0.intersects(row) ? $0 : nil }
        // A control the chevron's spacer pushed off reports a frame
        // stacked inside the chevron's own — not a boundary, and not a
        // slot to size a spacer from.
        let ahControl = alwaysHiddenPushed(controls: controls, row: row)
            ? nil : controls.alwaysHidden.flatMap { $0.intersects(row) ? $0 : nil }
        // The boundary is the glyph's left edge: an item under the
        // spacer part of a control has been pushed, not shown.
        let hiddenBoundary = hiddenControl.map { $0.maxX - controls.hiddenGlyph }
        let ahBoundary = ahControl.map { $0.maxX - MenuBarControlFrames.glyphLength }
        let overflowFrames = sorted.filter { $0.isNativeOverflowControl && $0.bounds.intersects(row) }
            .map(\.bounds)

        var hiddenToCover: [MenuBarItem] = []
        var ahToCover: [MenuBarItem] = []
        var parked: [MenuBarItem] = []
        for item in sorted {
            if MenuBarItemLister.isProtected(item) {
                if item.bounds.intersects(row) { plan.shown.append(item) }
                continue
            }
            let onRow = item.bounds.intersects(row)
                && !overflowFrames.contains { $0.intersection(item.bounds).width >= 4 }
            guard onRow else {
                parked.append(item)
                continue
            }
            let positional: MenuBarItemSection
            if let ahBoundary, item.bounds.minX < ahBoundary {
                positional = .alwaysHidden
            } else if let hiddenBoundary, item.bounds.minX < hiddenBoundary {
                positional = .hidden
            } else {
                positional = .shown
            }
            let override = sections[item.id].flatMap { $0 == .shown ? nil : $0 }
            let final = override ?? positional
            switch final {
            case .shown:
                plan.shown.append(item)
            case .hidden:
                plan.hidden.append(item)
                if positional == .shown { hiddenToCover.append(item) }
            case .alwaysHidden:
                plan.alwaysHidden.append(item)
                if positional == .shown { ahToCover.append(item) }
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
        // macOS's own « sits at the visible run's left end — flush
        // against the chevron's spacer, half under the Screen Bar's
        // ear. While the run is hidden it is redundant with the chevron
        // (its popover lists what the Item Bar lists), so it wears the
        // bar's material; the click it swallowed is the reveal gesture.
        // Its first few points stay bare so the ear's ring is never
        // clipped.
        if let hiddenControl, !revealed.contains(.hidden),
           let overflow = overflowFrames.first(where: { $0.maxX <= hiddenControl.minX + 4 }),
           overflow.width > overflowCoverInset + 4 {
            plan.hiddenCovers.append((overflow.minX + overflowCoverInset)...overflow.maxX)
        }

        // Spacer lengths.
        if let hiddenControl {
            if revealed.contains(.hidden) || regionMin == nil {
                plan.hiddenControlLength = controls.hiddenGlyph
            } else if let regionMin {
                plan.hiddenControlLength = spacerLength(
                    controlFrame: hiddenControl, regionMin: regionMin, cap: caps.hidden,
                    glyph: controls.hiddenGlyph)
            }
        }
        if let ahControl {
            if revealed.contains(.alwaysHidden) || regionMin == nil {
                plan.alwaysHiddenControlLength = MenuBarControlFrames.glyphLength
            } else if let regionMin {
                plan.alwaysHiddenControlLength = spacerLength(
                    controlFrame: ahControl, regionMin: regionMin, cap: caps.alwaysHidden)
            }
        }
        return plan
    }

    /// True while the always-hidden control sits under the chevron's
    /// expanded spacer: macOS packed it off the row and reports its
    /// frame stacked inside the chevron's.
    nonisolated static func alwaysHiddenPushed(controls: MenuBarControlFrames, row: CGRect) -> Bool {
        guard let hidden = controls.hidden, let ah = controls.alwaysHidden,
              hidden.intersects(row), ah.intersects(row) else { return false }
        return ah.intersection(hidden).width > 4
    }

    /// The plan with the utility parked: everything on the row is
    /// shown, everything off it is already the system's hidden — and
    /// no covers are computed, because a parked utility draws none.
    nonisolated static func unzonedPlan(items: [MenuBarItem], row: CGRect) -> MenuBarHidePlan {
        var plan = MenuBarHidePlan()
        plan.shown = items.filter { $0.bounds.intersects(row) }
            .sorted { $0.bounds.minX < $1.bounds.minX }
        plan.alwaysHidden = items.filter { !$0.bounds.intersects(row) }
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
