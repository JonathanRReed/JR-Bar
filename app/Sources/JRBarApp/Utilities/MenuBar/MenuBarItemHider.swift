import AppKit
import JRBarCore

/// What `reconcile` decided: which items are covered right now and
/// the exact Quartz x-ranges the shutters draw over. Sections are a
/// *logical* assignment — an item assigned `hidden` is covered where
/// it sits; nothing is ever physically moved, so the plan is always
/// honest: covered items still exist, still answer `AXPress`, and
/// return the instant the shutter drops.
struct MenuBarHidePlan: Equatable, Sendable {
    /// Items left uncovered — everything unassigned, plus protected
    /// owners wherever they sit.
    var shown: [MenuBarItem] = []
    /// Assigned-hidden items — covered until a reveal gesture.
    var hidden: [MenuBarItem] = []
    /// Assigned-always-hidden items — covered even while the hidden
    /// run is revealed, plus items macOS itself has parked off the
    /// row.
    var alwaysHidden: [MenuBarItem] = []
    /// The Quartz x-ranges the hidden shutter covers — one range per
    /// contiguous covered run, split wherever a shown item's frame
    /// sits in the gap so a cover never hides what was not assigned.
    var hiddenCovers: [ClosedRange<CGFloat>] = []
    /// Same for the deeper section's shutter.
    var alwaysHiddenCovers: [ClosedRange<CGFloat>] = []
}

/// The hide machinery. Shutter panels — borderless windows drawing
/// the menu bar's own `.menu` material over the assigned items — do
/// the hiding, because macOS 26 offers no way to evict a foreign
/// item: oversized status items, removal/reinsertion, `isVisible`,
/// and off-screen drops were all tested and all leave the item drawn.
/// Covering is what remains, and it is honest: covered items still
/// exist, still answer `AXPress`, and return the instant the shutter
/// drops.
///
/// Nothing in this file posts events or moves the pointer — covers
/// are the whole mechanism. Physically reordering items belongs to
/// `MenuBarItemMover`, which only an explicit, user-initiated arrange
/// gesture may ever invoke.
///
/// Reconcile runs on a timer plus `didChangeScreenParameters`: items
/// come and go as other apps add and remove theirs, and a covered
/// item's frame drifts when the bar reflows, so each pass re-reads
/// the cached listing and re-covers the runs.
@MainActor
final class MenuBarItemHider {
    /// The current settings, supplied by the owning utility.
    var settings: @MainActor () -> MenuBarSettings = { MenuBarSettings() }
    /// Every reconcile hands the fresh plan up — the card's count row
    /// and the bar's tiles read it.
    var onPlan: (@MainActor (MenuBarHidePlan) -> Void)?

    /// Seams so a test can drive `reconcile` without a screen, an AX
    /// scan, or control items: the row, the items the list would
    /// report, and the Quartz-space frames a cover must never span —
    /// the utility wires its own control items here so a merged run
    /// can never swallow the chevron.
    var rowRect: @MainActor () -> CGRect = { MenuBarItemLister.menuBarRow() }
    var listItems: @MainActor () -> [MenuBarItem] = { MenuBarItemLister.list() }
    var protectedFrames: @MainActor () -> [CGRect] = { [] }
    /// Test seam: suppress the cover panels entirely — a unit test
    /// must not draw over the real menu bar.
    var shuttersSuppressed = false

    private let hiddenShutter = MenuBarShutter()
    private let alwaysHiddenShutter = MenuBarShutter()
    private var timer: Timer?
    private var screenObserver: NSObjectProtocol?
    /// Sections a reveal gesture has uncovered.
    private(set) var revealed: Set<MenuBarItemSection> = []
    /// The last plan — the card's "N hidden · M always-hidden" row.
    private(set) var lastPlan = MenuBarHidePlan()

    /// The AX listing's refresh cadence driver.
    private var listingTask: Task<Void, Never>?
    /// How often the AX listing re-scans while the utility runs.
    nonisolated static let listingInterval: TimeInterval = 2.0

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
        screenObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.reconcile() }
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

    /// Stops reconciling, lifts the covers and cancels the refresh
    /// loop.
    func stop() {
        timer?.invalidate()
        timer = nil
        listingTask?.cancel()
        listingTask = nil
        if let screenObserver { NotificationCenter.default.removeObserver(screenObserver) }
        screenObserver = nil
        restoreAll()
    }

    isolated deinit {
        timer?.invalidate()
        listingTask?.cancel()
        if let screenObserver { NotificationCenter.default.removeObserver(screenObserver) }
    }

    /// Every cover down: hidden runs come back, reveals forgotten.
    func restoreAll() {
        revealed = []
        hiddenShutter.orderOut()
        alwaysHiddenShutter.orderOut()
        lastPlan = MenuBarHidePlan()
        onPlan?(lastPlan)
    }

    /// A gesture asks for these sections back for a while; `hide`
    /// covers them again.
    func reveal(_ sections: Set<MenuBarItemSection>) {
        revealed.formUnion(sections)
        reconcile()
    }

    /// The rehide timer's landing: the covers go back.
    func hide() {
        guard !revealed.isEmpty else { return }
        revealed = []
        reconcile()
    }

    /// Recompute the plan and the covers.
    func reconcile() {
        let row = rowRect()
        let plan = Self.plan(items: listItems(),
                             sections: settings().sections, row: row,
                             protectedFrames: protectedFrames())
        lastPlan = plan
        updateShutters(plan: plan, rowHeight: row.height)
        onPlan?(plan)
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

    // MARK: Plan (pure)

    /// The layout for a candidate list, sorted by x: an item's section
    /// is its assignment — `hidden` and `alwaysHidden` are covered in
    /// place, everything else is shown. Protected owners always report
    /// shown. Items parked off the row (macOS's own overflow) join the
    /// run their mapping says — they are hidden regardless, and the
    /// Item Bar reaches them through `AXPress`.
    /// - Parameter protectedFrames: Quartz-space frames a cover may
    ///   never span even though they are not listed items — the
    ///   utility's own controls, on the no-AX path where they cannot
    ///   appear in the listing at all.
    nonisolated static func plan(items: [MenuBarItem],
                                 sections: [String: MenuBarItemSection],
                                 row: CGRect,
                                 protectedFrames: [CGRect] = []) -> MenuBarHidePlan {
        var plan = MenuBarHidePlan()
        let sorted = items.sorted(by: { $0.bounds.minX < $1.bounds.minX })
        for item in sorted where item.bounds.intersects(row) {
            if MenuBarItemLister.isProtected(item) {
                plan.shown.append(item)
                continue
            }
            switch sections[item.id] {
            case .hidden: plan.hidden.append(item)
            case .alwaysHidden: plan.alwaysHidden.append(item)
            default: plan.shown.append(item)
            }
        }
        // Parked items report after the on-row ones — their stashed
        // positions are not bar order.
        for item in sorted where !item.bounds.intersects(row) {
            if sections[item.id] == .alwaysHidden {
                plan.alwaysHidden.append(item)
            } else {
                plan.hidden.append(item)
            }
        }
        // Covers span on-row items only — a parked item's stash frame
        // sits off the row, and covering it would paint a strip where
        // nothing is. Shown items *and* the utility's own controls are
        // blockers: a run breaks rather than cover either.
        let blockers = plan.shown.map(\.bounds) + protectedFrames
        plan.hiddenCovers = coverRuns(
            covered: plan.hidden.filter { $0.bounds.intersects(row) }, blockers: blockers)
        // The deeper cover splits on shown items and the controls — an
        // always-hidden cover may span a hidden item, which stays
        // covered anyway.
        plan.alwaysHiddenCovers = coverRuns(
            covered: plan.alwaysHidden.filter { $0.bounds.intersects(row) }, blockers: blockers)
        return plan
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

    /// The card's section write: the single mapping, kept honest — a
    /// protected owner is never written, a shown assignment clears the
    /// key, and an item that is not listed still records its mapping
    /// for when it returns.
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
