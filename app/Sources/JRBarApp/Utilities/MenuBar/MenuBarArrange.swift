import AppKit
import JRBarCore

/// Arrange mode's plan, pure so a test pins every decision: the live
/// item list plus the desired order → the ⌘-drags that physically
/// rebuild the run.
///
/// The menu bar packs its movable extras against a fixed right edge —
/// the system items (Control Center, the clock, the utility's own
/// controls) that nothing may move. The plan therefore works
/// **right to left**: the desired-rightmost item is placed at the
/// boundary first, each next item at the slot immediately left of the
/// one already placed. A drop's target is an absolute x computed from
/// the desired layout, so every drag lands deterministically no matter
/// where the item sat before.
///
/// Minimal moves: the items that keep their fingers off the bar are
/// the longest subsequence whose relative order already matches the
/// desired order (an LCS). Everything else is lifted out and dropped
/// into its final slot — the kept items are already correctly ordered
/// relative to each other, so reseating only the moved ones converges.
///
/// Desired-order semantics: `order` names item ids left→right. Ids
/// that are not listed are ignored; listed movable items the order
/// does not name keep their current relative order as a block at the
/// run's deep (left) end, so an arrange never disturbs items the
/// person did not ask about. Protected items and items macOS parked
/// off the row are never moved — they cannot even be grabbed.
enum MenuBarArrangePlan {
    /// The gap the pack assumes between two slots — the system's own
    /// extras spacing.
    nonisolated static let itemSpacing: CGFloat = 2

    /// The movable run: on-row, unprotected items in bar order.
    nonisolated static func movableItems(_ items: [MenuBarItem], row: CGRect) -> [MenuBarItem] {
        items.filter { !MenuBarItemLister.isProtected($0) && $0.bounds.intersects(row) }
            .sorted { $0.bounds.minX == $1.bounds.minX ? $0.id < $1.id
                                                       : $0.bounds.minX < $1.bounds.minX }
    }

    /// The edge the movable run packs against: the left edge of the
    /// leftmost fixed on-row item (a protected system item or one of
    /// the utility's own controls — both list as protected), else the
    /// display's right edge.
    nonisolated static func rightBoundary(items: [MenuBarItem], regionMax: CGFloat,
                                          row: CGRect) -> CGFloat {
        items.filter { MenuBarItemLister.isProtected($0) && $0.bounds.intersects(row) }
            .map(\.bounds.minX).min() ?? regionMax
    }

    /// The full left→right target order: unnamed movable items first
    /// (in current bar order), then the named order filtered to items
    /// actually present.
    nonisolated static func resolvedOrder(items: [MenuBarItem], order: [String],
                                          row: CGRect) -> [MenuBarItem] {
        let movable = movableItems(items, row: row)
        var named: [MenuBarItem] = []
        var used: Set<String> = []
        for id in order where !used.contains(id) {
            if let item = movable.first(where: { $0.id == id }) {
                named.append(item)
                used.insert(id)
            }
        }
        return movable.filter { !used.contains($0.id) } + named
    }

    /// The absolute slot centers of the desired layout: packed right
    /// against `boundary`, one `itemSpacing` gap between slots.
    nonisolated static func targetCenters(_ desired: [MenuBarItem],
                                          boundary: CGFloat) -> [String: CGFloat] {
        var targets: [String: CGFloat] = [:]
        var edge = boundary
        for item in desired.reversed() {
            let minX = edge - itemSpacing - item.bounds.width
            targets[item.id] = minX + item.bounds.width / 2
            edge = minX
        }
        return targets
    }

    /// The ids that keep their seats: the longest subsequence of the
    /// current order that is also a subsequence of the desired order.
    /// Keeping the maximum number of items unmoved is what makes the
    /// arrange cheap — and what makes "already in place" a real skip
    /// rather than a per-position comparison (an item can be at the
    /// wrong index and still be a correct link in the kept chain).
    nonisolated static func keptIDs(current: [String], desired: [String]) -> Set<String> {
        let n = current.count, m = desired.count
        guard n > 0, m > 0 else { return [] }
        // dp[i][j] = LCS length of current[i...] vs desired[j...].
        var dp = [[Int]](repeating: [Int](repeating: 0, count: m + 1), count: n + 1)
        for i in stride(from: n - 1, through: 0, by: -1) {
            for j in stride(from: m - 1, through: 0, by: -1) {
                dp[i][j] = current[i] == desired[j]
                    ? dp[i + 1][j + 1] + 1
                    : max(dp[i + 1][j], dp[i][j + 1])
            }
        }
        var keep: Set<String> = []
        var i = 0, j = 0
        while i < n, j < m {
            if current[i] == desired[j] {
                keep.insert(current[i]); i += 1; j += 1
            } else if dp[i + 1][j] >= dp[i][j + 1] {
                i += 1
            } else {
                j += 1
            }
        }
        return keep
    }

    /// The drags, in execution order: each non-kept item, desired
    /// rightmost first, from its current center to its final slot's
    /// center. `from` is the position at plan time — a drop earlier in
    /// the run can push a not-yet-moved item, so the coordinator
    /// re-plans after every drag and only ever executes `steps.first`.
    nonisolated static func steps(items: [MenuBarItem], order: [String],
                                  boundary: CGFloat, row: CGRect) -> [MenuBarMoveStep] {
        let movable = movableItems(items, row: row)
        let desired = resolvedOrder(items: items, order: order, row: row)
        let keep = keptIDs(current: movable.map(\.id), desired: desired.map(\.id))
        let targets = targetCenters(desired, boundary: boundary)
        var steps: [MenuBarMoveStep] = []
        for item in desired.reversed() where !keep.contains(item.id) {
            guard let target = targets[item.id] else { continue }
            steps.append(MenuBarMoveStep(
                itemID: item.id,
                from: CGPoint(x: item.bounds.midX, y: row.midY),
                to: CGPoint(x: target, y: row.midY)))
        }
        return steps
    }
}

/// The abort watcher's seam: "the person touched the machine". Esc —
/// or any real keypress, mousedown or scroll that is not one of the
/// coordinator's own posted drags — cancels the arrange immediately.
/// A protocol so a test can raise the abort without posting a single
/// event on the real machine. Nonisolated + Sendable: the monitor's
/// event handler and the coordinator's loop live on different threads.
protocol MenuBarArrangeWatching: AnyObject, Sendable {
    var cancelled: Bool { get }
    func stop()
}

/// While the coordinator's own synthetic drag is in flight, the
/// watcher must not read its posted presses as the person's hand.
/// Lock-guarded: the poster writes from the drag's worker task, the
/// monitor reads on whatever thread the event tap runs on.
final class MenuBarPostingGate: @unchecked Sendable {
    private let lock = NSLock()
    private var posting = false
    var isPosting: Bool {
        lock.lock(); defer { lock.unlock() }
        return posting
    }
    func set(_ value: Bool) {
        lock.lock(); posting = value; lock.unlock()
    }
}

/// The real watcher: one global + one local monitor over the gestures
/// that mean "hands on". Only installed between `init` and `stop` —
/// the arrange run's duration — so an idle utility owns no monitors.
/// Created and stopped on the main actor by the coordinator; the flag
/// itself is lock-guarded for the off-actor monitor deliveries.
final class MenuBarArrangeEventWatcher: MenuBarArrangeWatching, @unchecked Sendable {
    private let lock = NSLock()
    private var monitors: [Any] = []
    private var flag = false

    private let gate: MenuBarPostingGate

    var cancelled: Bool {
        lock.lock(); defer { lock.unlock() }
        return flag
    }

    @MainActor
    init(gate: MenuBarPostingGate) {
        self.gate = gate
        let mask: NSEvent.EventTypeMask = [.keyDown, .flagsChanged, .scrollWheel,
                                           .leftMouseDown, .rightMouseDown, .otherMouseDown]
        if let global = NSEvent.addGlobalMonitorForEvents(
            matching: mask, handler: { [weak self] in self?.noteEvent($0) }) {
            monitors.append(global)
        }
        if let local = NSEvent.addLocalMonitorForEvents(
            matching: mask,
            handler: { [weak self] event in self?.noteEvent(event); return event }) {
            monitors.append(local)
        }
    }

    func stop() {
        lock.lock()
        let taken = monitors
        monitors = []
        lock.unlock()
        for monitor in taken { NSEvent.removeMonitor(monitor) }
    }

    deinit { stop() }

    /// An event is foreign — the person's hand — unless it is one of
    /// ours. Ours is marked two ways: the posting gate is raised for
    /// the whole press→release, and every posted event carries
    /// `MenuBarItemMover.eventMarker` in its source user data for when
    /// a delivered NSEvent can answer `cgEvent` at all.
    nonisolated private func noteEvent(_ event: NSEvent) {
        if gate.isPosting { return }
        if event.cgEvent?.getIntegerValueField(.eventSourceUserData)
            == MenuBarItemMover.eventMarker { return }
        lock.lock(); flag = true; lock.unlock()
    }
}

/// How an arrange run ended.
enum MenuBarArrangeOutcome: Equatable, Sendable {
    /// Every needed drag landed and the re-plan came back clean.
    case completed(moves: Int)
    /// The bar already matched the order — nothing was dragged.
    case alreadyInOrder
    /// The person touched the machine mid-run; `completedMoves` drags
    /// had already landed.
    case aborted(completedMoves: Int)
    /// The step cap fired — the bar never settled into the plan.
    /// `moves` drags ran; the leftover plan was abandoned, not forced.
    case incomplete(moves: Int)
    /// A run was already in flight.
    case busy
}

/// Performs an arrange — the *only* sanctioned caller of
/// `MenuBarItemMover`'s posting machinery, and itself only ever
/// invoked by the explicit `arrange(to:)` action. Never from a timer,
/// a reconcile, an observer, or a test on a real machine.
///
/// Safety, each piece answering a failure the unguarded version had:
///   * a visible banner states the run and its cancel key;
///   * the cursor position is captured first and warped back after
///     *every* drag, so a cancelled run still leaves the pointer where
///     the person left it;
///   * `MenuBarArrangeEventWatcher` aborts on any foreign input;
///   * the run re-lists and re-plans after every drag — a pushed-aside
///     item's planned grab point would be stale, and a reflow that
///     already satisfies the plan ends the run early;
///   * a hard step cap: a bar that never settles is reported
///     `.incomplete`, not dragged forever.
@MainActor
final class MenuBarArrangeCoordinator {
    /// The run's fuse: more drags than this means the bar is not
    /// converging (an app keeps re-adding an item, a drop keeps being
    /// refused) — stop and say so.
    nonisolated static let stepLimit = 64

    private(set) var running = false
    private var cancelRequested = false

    /// The run's report — the card can toast it.
    var onFinish: (@MainActor (MenuBarArrangeOutcome) -> Void)?

    // MARK: Seams — the maintainer wires these to the utility

    /// The live item list. Default: the lister's cached listing.
    var listItems: @MainActor () -> [MenuBarItem] = { MenuBarItemLister.list() }
    /// The menu bar row in Quartz coordinates.
    var rowRect: @MainActor () -> CGRect = { MenuBarItemLister.menuBarRow() }
    /// The edge the run packs against. Default: the main display's
    /// right edge — the maintainer should pass
    /// `MenuBarArrangePlan.rightBoundary(items:regionMax:row:)` with the
    /// live list so the run packs against the real fixed items.
    var rightBoundary: @MainActor () -> CGFloat = { CGDisplayBounds(CGMainDisplayID()).maxX }
    /// Where the person's cursor is, captured at run start.
    var cursorLocation: @MainActor () -> CGPoint = {
        CGEvent(source: nil)?.location ?? .zero
    }
    /// Put the cursor back. Default: `CGWarpMouseCursorPosition`.
    var warpCursor: @MainActor (CGPoint) -> Void = { CGWarpMouseCursorPosition($0) }
    /// The one drag. Runs off the main actor. ⚠️ The default is the
    /// real `MenuBarItemMover.postCommandDrag` — it moves the person's
    /// cursor. Tests must inject a recorder, never let this fire.
    var postDrag: @Sendable (CGPoint, CGPoint) -> Void = {
        MenuBarItemMover.postCommandDrag(from: $0, to: $1)
    }
    /// The settle beat between drags — the bar reflows after a drop.
    var settle: @MainActor () async -> Void = {
        try? await Task.sleep(nanoseconds: UInt64(MenuBarItemMover.betweenDragsDelay) * 1_000)
    }
    /// The abort watcher factory — tests inject a fake; the default
    /// installs the real monitors for the run's duration only.
    var makeWatcher: @MainActor (MenuBarPostingGate) -> any MenuBarArrangeWatching = {
        MenuBarArrangeEventWatcher(gate: $0)
    }
    /// Test seam: suppress the banner window entirely — a unit test
    /// must not draw over the real screen.
    var bannerSuppressed = false

    private var banner: MenuBarArrangeBanner?

    /// The explicit action. Returns the run's outcome; `.busy` if a
    /// run is already going — a double-tapped button can never stack
    /// drags.
    @discardableResult
    func arrange(to order: [String]) async -> MenuBarArrangeOutcome {
        guard !running else { return .busy }
        running = true
        cancelRequested = false
        let gate = MenuBarPostingGate()
        // The cursor is the person's: remember where it was before the
        // first synthetic press ever lands.
        let savedCursor = cursorLocation()
        presentBanner()
        let watcher = makeWatcher(gate)
        var moves = 0
        var outcome: MenuBarArrangeOutcome = .incomplete(moves: 0)
        for _ in 0..<Self.stepLimit {
            if watcher.cancelled || cancelRequested {
                outcome = .aborted(completedMoves: moves)
                break
            }
            // Re-plan every step: the previous drop reflowed the bar,
            // and a plan that comes back empty is the finish line.
            let items = listItems()
            let steps = MenuBarArrangePlan.steps(
                items: items, order: order,
                boundary: rightBoundary(), row: rowRect())
            guard let step = steps.first else {
                outcome = moves == 0 ? .alreadyInOrder : .completed(moves: moves)
                break
            }
            gate.set(true)
            let poster = postDrag
            await Task.detached { poster(step.from, step.to) }.value
            gate.set(false)
            // Hands off means *hands off* — the pointer goes home after
            // every drag, not just at the end, so a mid-run abort still
            // leaves it where the person parked it.
            warpCursor(savedCursor)
            moves += 1
            await settle()
        }
        watcher.stop()
        dismissBanner()
        running = false
        cancelRequested = false
        onFinish?(outcome)
        return outcome
    }

    /// Cancel from our own side — a button, a teardown. The person's
    /// inputs reach the same flag through the watcher.
    func cancel() { cancelRequested = true }

    private func presentBanner() {
        guard !bannerSuppressed else { return }
        let banner = MenuBarArrangeBanner()
        banner.present()
        self.banner = banner
    }

    private func dismissBanner() {
        banner?.orderOut(nil)
        banner = nil
    }
}

/// The arrange run's one visible surface: a small nonactivating panel
/// centered under the menu bar saying what is happening and how to
/// stop it. It never takes key — the watcher, not the window, owns Esc.
@MainActor
final class MenuBarArrangeBanner: NSPanel {
    static let cornerRadius: CGFloat = 12

    init() {
        let label = NSTextField(labelWithString:
            "Arranging menu bar items — keep hands off the mouse. Esc cancels.")
        label.font = .systemFont(ofSize: 12, weight: .medium)
        label.alignment = .center
        let glass = NSGlassEffectView(frame: NSRect(x: 0, y: 0, width: 10, height: 10))
        glass.cornerRadius = Self.cornerRadius
        glass.style = .regular
        glass.contentView = label
        label.translatesAutoresizingMaskIntoConstraints = false
        super.init(contentRect: NSRect(x: 0, y: 0, width: 10, height: 10),
                   styleMask: [.borderless, .nonactivatingPanel],
                   backing: .buffered, defer: false)
        contentView = glass
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: glass.leadingAnchor, constant: 14),
            label.trailingAnchor.constraint(equalTo: glass.trailingAnchor, constant: -14),
            label.topAnchor.constraint(equalTo: glass.topAnchor, constant: 9),
            label.bottomAnchor.constraint(equalTo: glass.bottomAnchor, constant: -9),
        ])
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        hidesOnDeactivate = false
        isReleasedWhenClosed = false
        isExcludedFromWindowsMenu = true
        animationBehavior = .none
        isMovable = false
        becomesKeyOnlyIfNeeded = true
        collectionBehavior = [.canJoinAllSpaces, .stationary,
                              .fullScreenAuxiliary, .ignoresCycle]
        level = NSWindow.Level(rawValue: NSWindow.Level.statusBar.rawValue + 2)
        if ProcessInfo.processInfo.environment["JRBAR_CAPTURE_CARD"] == nil {
            sharingType = .none
        }
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    /// Centered under the menu bar on the screen carrying it.
    func present() {
        guard let screen = NSScreen.main else { return }
        let depth = max(NSStatusBar.system.thickness,
                        ScreenBarGeometry.notchDepth(of: screen))
        let size = contentView?.fittingSize ?? frame.size
        setFrame(NSRect(x: screen.frame.midX - size.width / 2,
                        y: screen.frame.maxY - depth - 8 - size.height,
                        width: size.width, height: size.height),
                 display: false)
        orderFrontRegardless()
    }
}
