import AppKit
import JRBarCore
import OSLog

/// What the card currently names: the top-priority session, or the
/// aggregate when there is none.
struct ScreenBarFocus: Equatable {
    var style: ProviderStyle?
    var label: String
    var word: String
    /// The session a click opens; nil when nothing should be raised.
    var clickSession: String?
    /// The session the header names — kept out of the card's row list
    /// so it is never listed twice.
    var focusSession: String? = nil
    /// "Why this light", as a second line — the reason without its
    /// motion prefix.
    var explanation: String? = nil
}

/// Hover and click for a click-through band. The panel keeps
/// `ignoresMouseEvents` so it never takes focus or blocks the menu bar --
/// which is also why an `NSTrackingArea` cannot do this job (a tracking area
/// needs the window to take mouse events, and the band shares its strip of
/// screen with the island, so eating clicks there is not an option).
/// Instead a `moveInterval` poll reads `NSEvent.mouseLocation` and
/// hit-tests it against the band's own rounded rect — a global
/// `mouseMoved` monitor would do the same job but every delivery costs a
/// `TCCAccessRequest` round trip, which was the tccd flood. Hovering
/// drops the glass notch
/// card as a peek under the band, clicking pins it open — the card
/// itself belongs to `NotchCardPresenter`. While the Notch island owns
/// the notch (`islandOwnsNotch`) the island IS the card: the band's
/// hover arms nothing and its pin/dismiss route to the toy's
/// expand/collapse instead. A press dragged down is the swipe — it
/// expands the pinned card — and a press dragged up while pinned
/// collapses it; a click is simply a down+up that never crossed the
/// threshold, so it resolves on release instead of on down. A press
/// that began ON the island's own window is the island's gesture — its
/// hosting view owns the tap and the pull — so the band's machine never
/// arms it (a release there is never an outside-click either).
@MainActor
final class ScreenBarInteraction {
    nonisolated static let log = Logger(subsystem: "devin.jrbar", category: "wings")
    /// Diagnostics channel that bypasses os_log capture quirks — appends
    /// one line to /tmp/jrbar-wings.log per call, but only when the
    /// JRBAR_WING_DEBUG env var is set so a shipping build stays silent.
    private nonisolated static let wingDebug = ProcessInfo.processInfo.environment["JRBAR_WING_DEBUG"] != nil
    nonisolated static func diag(_ message: String) {
        guard wingDebug else { return }
        let line = "\(ISO8601DateFormatter().string(from: Date())) \(message)\n"
        let url = URL(fileURLWithPath: "/tmp/jrbar-wings.log")
        if let handle = try? FileHandle(forWritingTo: url) {
            handle.seekToEndOfFile(); handle.write(Data(line.utf8)); try? handle.close()
        } else {
            try? line.write(to: url, atomically: true, encoding: .utf8)
        }
    }
    /// Deliberate-intent delay: long enough that a pointer cutting across
    /// the notch never arms a peek, short enough that aiming at one feels
    /// immediate.
    static let hoverDelay: TimeInterval = 0.12
    /// The hover poll's cadence — ~20 Hz reads the pointer often enough
    /// that entry feels instant and costs nothing per tick.
    nonisolated static let moveInterval: TimeInterval = 0.05
    /// The cadence while the pointer is far below the bar.
    nonisolated static let farMoveInterval: TimeInterval = 0.25
    nonisolated static let nearReach: CGFloat = 120
    /// The peek is a glance, not a label: it leaves on its own while the
    /// pointer is away…
    static let maxTooltipLife: TimeInterval = 4.0
    /// …but a pointer parked on the card or the band keeps it — the card
    /// is reachable, so leaving must not make it vanish mid-crossing.
    static let lifeExtension: TimeInterval = 2.0
    /// Leaving the hit region gets this long to come back before the peek
    /// really goes — covers the dead pixel or two between the band, the
    /// chips and the card.
    static let closeGrace: TimeInterval = 0.30

    /// The hover zones in screen coordinates: the band plus each drawn
    /// wing chip — the drawn capsules, so hovering them is hovering us.
    var hitRects: @MainActor () -> [NSRect]
    var focus: @MainActor () -> ScreenBarFocus?
    /// The frame the buddy's HUD clearance comes from — while the card
    /// is up the HUD panel is part of its hover corridor, so crossing
    /// the buddy between band and card never counts as leaving.
    var underBandRegion: @MainActor () -> NSRect? = { nil }
    /// Rects the hit region should also count — the island's frame while
    /// it is up: the island is the card's other anchor, so a click on it
    /// must not read as "outside" and dismiss the card it summoned.
    var extraHitRects: @MainActor () -> [NSRect] = { [] }
    /// Which drawn wing a screen point is over — the dismiss swipe's
    /// target; the band and empty flank room answer nil.
    var wingSideAt: @MainActor (NSPoint) -> ScreenBarWingSide? = { _ in nil }
    /// A wing was flicked away from the notch — the controller hides it.
    var onWingDismiss: @MainActor (ScreenBarWingSide) -> Void = { _ in }
    /// A horizontal swipe on the band summoned dismissed wings back.
    var onWingRestore: @MainActor () -> Void = {}
    /// An ear is being pulled — it follows the finger with resistance
    /// until the flick commits; `dx` is finger-space, rightward positive.
    var onWingPull: @MainActor (ScreenBarWingSide, CGFloat) -> Void = { _, _ in }
    /// The pull ended without a dismiss — the ear springs home.
    var onWingPullEnd: @MainActor (ScreenBarWingSide) -> Void = { _ in }
    /// A plain click on an ear — the ear does what its mark shows (the
    /// left ear is the focused session's glyph: one click opens that
    /// session). Return true when the ear's own action consumed the
    /// click; false falls back to the band's pin.
    var onWingActivate: @MainActor (ScreenBarWingSide) -> Bool = { _ in false }
    /// The hidden-run handle's slice of the right ear, in screen
    /// coordinates — a click inside it is the run's toggle, not the
    /// wing's.
    var menuHandleAt: @MainActor (NSPoint) -> Bool = { _ in false }
    /// The handle was clicked — reveal or rehide the run.
    var onMenuHandle: @MainActor () -> Void = {}

    /// Points of vertical travel before a press-on-the-band becomes a
    /// swipe — small enough that a deliberate pull feels instant, large
    /// enough that a jittery click never fires it.
    nonisolated static let swipeThreshold: CGFloat = 14
    /// Points of accumulated finger travel before a trackpad swipe
    /// commits — matches the island's vertical read so both surfaces
    /// feel the same.
    nonisolated static let scrollSwipeThreshold: CGFloat = 40

    private var globalMonitors: [Any] = []
    private var localMonitors: [Any] = []
    /// The hover poll — `moveInterval` cadence, replaces the moved
    /// event tap whose every delivery cost a `TCCAccessRequest`.
    private var hoverTimer: Timer?
    private(set) var hovering = false
    private var showWork: DispatchWorkItem?
    private var hideWork: DispatchWorkItem?
    private var lifeWork: DispatchWorkItem?
    /// The shared card — owned by `NotchCardPresenter`, which also keeps
    /// its anchor, its content and the Esc-to-close watch on a pin.
    /// Band-only: the glass fallback for when the island is not drawn.
    let card: NotchCardPresenter
    /// The Notch island owns the notch while the toy draws it — the
    /// grown island IS the card then, so hover arms no glass peek and
    /// pin/dismiss route to the toy instead of the panel.
    var islandOwnsNotch: @MainActor () -> Bool = { false }
    /// The grown island card is up — the click/swipe state machine's
    /// "pinned" answer while the island owns the notch.
    var islandExpanded: @MainActor () -> Bool = { false }
    /// The deliberate expand/collapse the band's gestures mean while
    /// the island owns the notch.
    var onIslandExpand: @MainActor () -> Void = {}
    var onIslandCollapse: @MainActor () -> Void = {}
    /// The pointer entered (true) or left (false) the band's region —
    /// the ears, the tray, the island — while the island owns the
    /// notch. `fromBar` says the arrival was on the bar's row rather
    /// than straight onto the island, so the island's debounce can keep
    /// its longer floor for a pointer only crossing the menu bar.
    var onIslandHover: @MainActor (Bool, _ fromBar: Bool) -> Void = { _, _ in }
    /// The drawn ear under the pointer right now — the hover tell's
    /// target. Fires on the side's edges only, nil off the ears.
    var onWingHover: @MainActor (ScreenBarWingSide?) -> Void = { _ in }
    /// The side `onWingHover` last announced.
    private var hoveredWing: ScreenBarWingSide?

    /// The "is the card pinned" read — the glass panel's pin normally,
    /// the grown island's hold while it owns the notch.
    private func cardPinned() -> Bool {
        islandOwnsNotch() ? islandExpanded() : card.isPinned
    }

    private var isTooltipShown: Bool { card.isShown }
    private var lastFocus: ScreenBarFocus?

    init(card: NotchCardPresenter,
         hitRects: @escaping @MainActor () -> [NSRect],
         focus: @escaping @MainActor () -> ScreenBarFocus?) {
        self.card = card
        self.hitRects = hitRects
        self.focus = focus
    }

    func start() {
        Self.diag("start() monitors=\(globalMonitors.count)")
        guard globalMonitors.isEmpty else { return }
        // Global: events bound for other apps (the band is click-through, so
        // that is every pointer event over it while we are not active).
        // Local: the same events when this app happens to be active.
        // Hover is a poll, not an event tap: a global `mouseMoved` monitor
        // delivers ~125 events a second and every delivery costs a
        // `TCCAccessRequest` round trip — that was the tccd flood. Polling
        // `NSEvent.mouseLocation` at `moveInterval` hits the same code
        // path for free, and `pointerMoved` reads the live location
        // rather than an event, so nothing is lost.
        scheduleMovePoll(after: Self.moveInterval)
        if let down = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown], handler: { [weak self] event in
            let point = NSEvent.mouseLocation
            Self.diag("global down raw (\(Int(point.x)),\(Int(point.y)))")
            let time = event.timestamp
            Task { @MainActor [weak self] in self?.pointerDown(at: point, time: time) }
        }) { globalMonitors.append(down) } else {
            Self.diag("global down monitor FAILED")
        }
        if let drag = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDragged], handler: { [weak self] event in
            let point = NSEvent.mouseLocation
            let time = event.timestamp
            Task { @MainActor [weak self] in self?.pointerDragged(to: point, at: time) }
        }) { globalMonitors.append(drag) }
        if let up = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseUp], handler: { [weak self] event in
            let time = event.timestamp
            Task { @MainActor [weak self] in self?.pointerReleased(at: time) }
        }) { globalMonitors.append(up) }
        if let down = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown], handler: { [weak self] event in
            let point = NSEvent.mouseLocation
            let time = event.timestamp
            Task { @MainActor [weak self] in self?.pointerDown(at: point, time: time) }
            return event
        }) { localMonitors.append(down) }
        if let drag = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDragged], handler: { [weak self] event in
            let point = NSEvent.mouseLocation
            let time = event.timestamp
            Task { @MainActor [weak self] in self?.pointerDragged(to: point, at: time) }
            return event
        }) { localMonitors.append(drag) }
        if let up = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseUp], handler: { [weak self] event in
            let time = event.timestamp
            Task { @MainActor [weak self] in self?.pointerReleased(at: time) }
            return event
        }) { localMonitors.append(up) }
        // Trackpad swipes arrive as scrollWheel, never as drags — the
        // same stream the island's hosting view reads.
        if let scroll = NSEvent.addGlobalMonitorForEvents(matching: [.scrollWheel], handler: { [weak self] event in
            Task { @MainActor [weak self] in self?.pointerScrolled(event) }
        }) { globalMonitors.append(scroll) }
        if let scroll = NSEvent.addLocalMonitorForEvents(matching: [.scrollWheel], handler: { [weak self] event in
            Task { @MainActor [weak self] in self?.pointerScrolled(event) }
            return event
        }) { localMonitors.append(scroll) }
    }

    /// One-shot, re-armed at the cadence the pointer's distance earns:
    /// 20 Hz within reach of the bar, 4 Hz far below it.
    private func scheduleMovePoll(after interval: TimeInterval) {
        hoverTimer?.invalidate()
        let timer = Timer(timeInterval: interval, repeats: false, block: { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.pointerMoved()
                let point = NSEvent.mouseLocation
                let top = NSScreen.screens.first { $0.frame.contains(point) }?.frame.maxY ?? point.y
                let near = top - point.y <= Self.nearReach || self.hovering || self.isTooltipShown
                self.scheduleMovePoll(after: near ? Self.moveInterval : Self.farMoveInterval)
            }
        })
        RunLoop.main.add(timer, forMode: .common)
        hoverTimer = timer
    }

    func stop() {
        for monitor in globalMonitors + localMonitors { NSEvent.removeMonitor(monitor) }
        globalMonitors = []
        localMonitors = []
        hoverTimer?.invalidate()
        hoverTimer = nil
        hovering = false
        swipeStart = nil
        swipeFired = false
        pressOnIsland = false
        dragFlick = NotchPullGesture()
        scrollLive = false
        scrollFired = false
        if hoveredWing != nil { hoveredWing = nil; onWingHover(nil) }
        hideTooltip()
        // A band going away takes a grown island with it — the card is
        // the band's guest, it cannot outlive its host.
        onIslandCollapse()
    }

    /// The band or a wing rect moved. The presenter re-anchors a live
    /// card under its new anchor instead of hiding it — killing it
    /// while the pointer sat on the band just re-armed the hover, and a
    /// wing slot coming and going on state churn turned that into an
    /// open/close flap. A pinned card re-anchors the same way.
    func geometryChanged() {
        // A live card re-anchors under the moved band — unless the
        // island took the notch meanwhile: the island IS the card then,
        // and re-presenting the glass one would double the surface.
        if islandOwnsNotch() { card.hide() } else { card.geometryChanged() }
        hovering = false
        pointerMoved()
    }

    // MARK: Pointer

    /// Inside = the union of the band, the drawn wing chips, the island
    /// while it is up, and — once it is up — the card itself. The slack
    /// around each chip is a couple of points so the edge is not a pixel
    /// hunt; the card gets a point too, so brushing its frame does not
    /// count as leaving.
    private func pointerInHitRegion() -> Bool {
        let point = NSEvent.mouseLocation
        if hitRects().contains(where: { $0.insetBy(dx: -2, dy: -3).contains(point) }) { return true }
        if extraHitRects().contains(where: { $0.insetBy(dx: -1, dy: -1).contains(point) }) { return true }
        guard isTooltipShown else { return false }
        if let frame = card.cardFrame, frame.insetBy(dx: -1, dy: -1).contains(point) { return true }
        // The buddy's HUD frame sits in the corridor between band and
        // card — without it, crossing the pet kills and re-arms the peek.
        if let region = underBandRegion(), region.insetBy(dx: -1, dy: -1).contains(point) { return true }
        return false
    }

    /// The island's frame arrives through `extraHitRects` — the toy
    /// publishes exactly its own desired rect — so a point on it is a
    /// press the island's window answers itself: tap to toggle, pull to
    /// grow or fold. `contains` is exact (no slack inset) — the window
    /// IS the shape, and a point beside it is still the band's.
    private func onIsland(_ point: NSPoint) -> Bool {
        extraHitRects().contains { $0.contains(point) }
    }

    private func pointerMoved() {
        // Ownership can flip under a still pointer — the island coming
        // on while a peek or pinned glass card is up, or the utility
        // switching off under one. Every move stream tick re-checks the
        // card's own surface answer, so a stale card retires on the
        // next pointer event instead of doubling the island — or
        // lingering as the one thing a switched-off utility drew.
        if isTooltipShown, card.surface() != .glass { hideTooltip() }
        let inside = pointerInHitRegion()
        // The ear tell tracks every tick while the pointer is in the
        // region, not just the region's edges — crossing between ears
        // and tray inside it is the whole point of the tell.
        let wing = inside ? wingSideAt(NSEvent.mouseLocation) : nil
        if wing != hoveredWing {
            hoveredWing = wing
            onWingHover(wing)
        }
        guard inside != hovering else {
            if inside, isTooltipShown, let current = focus(), current != lastFocus { showTooltip(current) }
            return
        }
        hovering = inside
        showWork?.cancel()
        showWork = nil
        hideWork?.cancel()
        hideWork = nil
        if inside {
            if islandOwnsNotch() {
                // The island is the peek: hovering an ear is hovering
                // the island. A leftover glass card goes away. The
                // arrival reports whether it came by the bar's row —
                // the island's hover debounce floors longer for a
                // pointer that may only be crossing the menu bar.
                if isTooltipShown { hideTooltip() }
                onIslandHover(true, !onIsland(NSEvent.mouseLocation))
            } else if isTooltipShown {
                // Back inside before the grace fired — the peek never went
                // anywhere; refresh it if the focus moved on.
                if let current = focus(), current != lastFocus { showTooltip(current) }
            } else {
                let work = DispatchWorkItem { [weak self] in
                    MainActor.assumeIsolated {
                        guard let self, self.hovering, let focus = self.focus() else { return }
                        self.showTooltip(focus)
                    }
                }
                showWork = work
                DispatchQueue.main.asyncAfter(deadline: .now() + Self.hoverDelay, execute: work)
            }
        } else if islandOwnsNotch() {
            onIslandHover(false, false)
        } else if isTooltipShown && !card.isPinned {
            let work = DispatchWorkItem { [weak self] in MainActor.assumeIsolated { self?.hideTooltip() } }
            hideWork = work
            DispatchQueue.main.asyncAfter(deadline: .now() + Self.closeGrace, execute: work)
        }
    }

    /// What a click in the hit region does next — factored pure so the
    /// state machine is testable without a pointer (T46/T47):
    /// pinned + outside dismisses; pinned + inside is the card's own
    /// buttons; not pinned + inside pins (deliberate focus entry).
    enum ClickOutcome { case pin, unpin, cardButton, none }

    nonisolated static func clickOutcome(pinned: Bool, inside: Bool) -> ClickOutcome {
        if pinned { return inside ? .cardButton : .unpin }
        return inside ? .pin : .none
    }

    /// What a vertical drag that started on the band becomes — pure so
    /// the gesture's truth table is testable without a pointer: down
    /// expands an unpinned band, up collapses a pinned card, anything
    /// else or below the threshold is still just a click pending.
    /// `deltaY` is in screen coordinates — upward positive.
    enum SwipeOutcome { case expand, collapse, none }

    nonisolated static func swipeOutcome(pinnedAtDown: Bool, deltaY: CGFloat,
                                         threshold: CGFloat = swipeThreshold) -> SwipeOutcome {
        if deltaY <= -threshold { return pinnedAtDown ? .none : .expand }
        if deltaY >= threshold { return pinnedAtDown ? .collapse : .none }
        return .none
    }

    /// The release-speed half of the swipe truth table — a flick is a
    /// swipe that lifted short of the travel threshold: a fast pull
    /// never needs the full distance. `velocityY` is screen-space,
    /// upward positive; slow releases answer `.none` and stay clicks.
    nonisolated static func flickOutcome(pinnedAtDown: Bool, velocityY: CGFloat,
                                         flick: CGFloat = NotchPullGesture.flickVelocity) -> SwipeOutcome {
        guard abs(velocityY) >= flick else { return .none }
        return swipeOutcome(pinnedAtDown: pinnedAtDown,
                            deltaY: velocityY > 0 ? swipeThreshold : -swipeThreshold)
    }

    /// Where a press or a two-finger gesture began: a drawn wing, or the
    /// band under everything else in the hit region.
    enum SwipeRegion: Equatable { case wing(ScreenBarWingSide), band }

    /// What a horizontal gesture becomes — pure: flicking a wing in
    /// either direction dismisses it — the Dynamic Island's rule, where
    /// the pill answers any sideways swipe, not just the outward one —
    /// and a horizontal swipe on the band summons dismissed wings back.
    /// `deltaX` is in screen coordinates — rightward positive.
    /// Sub-threshold travel is nothing.
    enum WingSwipeOutcome: Equatable { case dismiss(ScreenBarWingSide), restore, none }

    nonisolated static func wingSwipeOutcome(region: SwipeRegion, deltaX: CGFloat,
                                             threshold: CGFloat = swipeThreshold) -> WingSwipeOutcome {
        guard abs(deltaX) >= threshold else { return .none }
        switch region {
        case .wing(let side): return .dismiss(side)
        case .band: return .restore
        }
    }

    /// Where the press started and what surface it started on, whether
    /// the card was pinned then, and whether the drag already fired its
    /// outcome — one pending press at a time; a down outside the region
    /// never arms one, and a down on the island's own window is the
    /// island's gesture, never the band's.
    private var swipeStart: NSPoint?
    private var swipeRegion: SwipeRegion = .band
    private var swipePinnedAtDown = false
    private var swipeFired = false
    /// A press that began on the island's frame: the island's hosting
    /// view owns the tap and the pull — here the press only proves
    /// "inside", so it can never arm the band's swipe or fire the
    /// outside-click dismissal.
    private var pressOnIsland = false
    /// The drag's flick tracker — travel commits mid-drag, release
    /// speed is the other way a swipe is a swipe.
    private var dragFlick = NotchPullGesture()

    private func pointerDown(at point: NSPoint, time: TimeInterval) {
        let islandRects = self.extraHitRects().map { String(describing: $0) }.joined(separator: ";")
        Self.diag("down (\(Int(point.x)),\(Int(point.y))) islandRects=\(islandRects)")
        pressOnIsland = false
        if onIsland(point) {
            Self.diag("island press unarmed")
            // The island's window answers its own presses — tap to
            // toggle, pull to grow or fold. The press is inside, so it
            // is never the outside-click dismissal either.
            pressOnIsland = true
            swipeStart = nil
            return
        }
        if pointerInHitRegion() {
            // Inside: the press might become a swipe — the click resolves
            // on release instead.
            swipeStart = point
            swipeRegion = wingSideAt(point).map { .wing($0) } ?? .band
            swipePinnedAtDown = cardPinned()
            swipeFired = false
            dragFlick = NotchPullGesture()
            dragFlick.move(translation: 0, at: time)
            let rects = self.hitRects().map { String(describing: $0) }.joined(separator: ";")
            Self.diag("down inside region=\(swipeRegion) rects=\(rects)")
        } else {
            swipeStart = nil
            // Diagnostics: a down near the top edge that missed the hit
            // region is worth a line — it means the drawn rects and the
            // pointer disagree about where our capsules are.
            if point.y > (NSScreen.screens.first { $0.frame.contains(point) }?.frame.maxY ?? 0) - 60 {
                let rects = self.hitRects().map { String(describing: $0) }.joined(separator: ";")
                Self.diag("down OUTSIDE (\(Int(point.x)),\(Int(point.y))) rects=\(rects)")
            }
            // Outside: only the dismiss-a-pinned-card case, and it wants
            // the press, not the release.
            if case .unpin = Self.clickOutcome(pinned: cardPinned(), inside: false) { unpin() }
        }
    }

    private func pointerDragged(to point: NSPoint, at time: TimeInterval) {
        guard let start = swipeStart, !swipeFired else { return }
        dragFlick.move(translation: point.y - start.y, at: time)
        // The gesture's axis wins: a sideways drag on a wing dismisses
        // it, a sideways drag on the band summons — the vertical
        // expand/collapse only fires when the pull is honestly vertical.
        if abs(point.x - start.x) > abs(point.y - start.y) {
            // The ear follows the finger with resistance until the
            // flick commits.
            if case .wing(let side) = swipeRegion { onWingPull(side, point.x - start.x) }
            switch Self.wingSwipeOutcome(region: swipeRegion, deltaX: point.x - start.x) {
            case .dismiss(let side):
                swipeFired = true
                Self.diag("drag dismiss dx=\(Int(point.x - start.x)) side=\(side)")
                onWingPullEnd(side)
                onWingDismiss(side)
            case .restore:
                swipeFired = true
                Self.diag("drag restore dx=\(Int(point.x - start.x))")
                onWingRestore()
            case .none:
                return
            }
            return
        }
        // A downward pull that has not committed still slides the card
        // out under the pointer.
        if point.y - start.y <= -Self.swipeThreshold * 0.25, !isTooltipShown {
            showPullPeek()
        }
        switch Self.swipeOutcome(pinnedAtDown: swipePinnedAtDown, deltaY: point.y - start.y) {
        case .expand:
            swipeFired = true
            pinCard()
        case .collapse:
            swipeFired = true
            unpin()
        case .none:
            return
        }
    }

    private func pointerReleased(at time: TimeInterval) {
        Self.diag("released fired=\(swipeFired) armed=\(swipeStart != nil) island=\(pressOnIsland)")
        let wasSwipe = swipeFired
        let armed = swipeStart != nil
        let pinnedAtDown = swipePinnedAtDown
        let flick = dragFlick.flickSpeed(at: time)
        // A wing pull that never committed springs the ear home.
        if case .wing(let side) = swipeRegion { onWingPullEnd(side) }
        swipeStart = nil
        swipeFired = false
        let onIsland = pressOnIsland
        pressOnIsland = false
        // A release resolves only a press that armed here — a swipe
        // that already fired, and an island press (the island's window
        // owns its own verdicts), both skip.
        guard !wasSwipe, !onIsland, armed else { return }
        // The flick: a fast pull released short of the travel
        // threshold is still the swipe it felt like.
        switch Self.flickOutcome(pinnedAtDown: pinnedAtDown, velocityY: flick) {
        case .expand: pinCard(); return
        case .collapse: unpin(); return
        case .none: break
        }
        // A press that never crossed the threshold is the click it always
        // was — the handle's own toggle gets first claim, then an ear's
        // own action (the mark's session opens directly), then the pin.
        if case .pin = Self.clickOutcome(pinned: cardPinned(), inside: pointerInHitRegion()) {
            if menuHandleAt(NSEvent.mouseLocation) { onMenuHandle(); return }
            if let side = wingSideAt(NSEvent.mouseLocation), onWingActivate(side) { return }
            pinCard()
        }
    }

    /// The pull's early answer: the peek slides out before the commit
    /// lands — a gesture with no visible response until the threshold
    /// reads dead. While the island owns the notch the pull's commit
    /// grows the island instead, so no glass slides out early.
    private func showPullPeek() {
        guard !isTooltipShown, !islandOwnsNotch(),
              let focus = focus() ?? lastFocus else { return }
        showTooltip(focus)
    }

    // MARK: Scroll swipe

    /// The trackpad's two-finger swipe, read off scroll events the same
    /// way the island's hosting view reads them — the band is
    /// click-through, so this runs on the monitor stream and only ever
    /// counts a gesture that began inside the hit region.
    private var scrollAccumY: CGFloat = 0
    private var scrollAccumX: CGFloat = 0
    private var scrollLive = false
    private var scrollFired = false
    private var scrollPinnedAtStart = false
    private var scrollRegion: SwipeRegion = .band

    private func pointerScrolled(_ event: NSEvent) {
        // Only a trackpad gesture carries phases; a wheel's deltas and a
        // gesture's momentum tail arrive with `phase` empty.
        guard event.hasPreciseScrollingDeltas, event.phase != [] else { return }
        if event.phase.contains(.began) {
            // A two-finger gesture that began on the island's window is
            // the island's own — its hosting view reads the same scroll
            // stream, so both machines counting one flick would double
            // every swipe.
            scrollLive = pointerInHitRegion() && !onIsland(NSEvent.mouseLocation)
            scrollRegion = wingSideAt(NSEvent.mouseLocation).map { .wing($0) } ?? .band
            scrollPinnedAtStart = cardPinned()
            scrollFired = false
            scrollAccumY = 0
            scrollAccumX = 0
        }
        if event.phase.contains(.ended) {
            // A flick is a gesture that lifts short of the threshold —
            // a fast pull past roughly half commits on release instead
            // of evaporating. `.cancelled` is the OS retracting the
            // gesture (a palm), so only `.ended` commits.
            if scrollLive, !scrollFired {
                let commit = Self.scrollSwipeThreshold * 0.55
                if abs(scrollAccumX) > abs(scrollAccumY), abs(scrollAccumX) >= commit {
                    switch Self.wingSwipeOutcome(region: scrollRegion, deltaX: scrollAccumX,
                                                 threshold: commit) {
                    case .dismiss(let side):
                        onWingPullEnd(side)
                        onWingDismiss(side)
                    case .restore:
                        onWingRestore()
                    case .none:
                        break
                    }
                } else if abs(scrollAccumY) >= commit {
                    switch Self.swipeOutcome(pinnedAtDown: scrollPinnedAtStart,
                                             deltaY: scrollAccumY, threshold: commit) {
                    case .expand:
                        pinCard()
                    case .collapse:
                        unpin()
                    case .none:
                        break
                    }
                }
            }
            if case .wing(let side) = scrollRegion { onWingPullEnd(side) }
            scrollLive = false
            scrollAccumY = 0
            scrollAccumX = 0
            return
        }
        if event.phase.contains(.cancelled) {
            if case .wing(let side) = scrollRegion { onWingPullEnd(side) }
            scrollLive = false
            scrollAccumY = 0
            scrollAccumX = 0
            return
        }
        guard scrollLive, !scrollFired else { return }
        // Recover the finger's direction: under natural scrolling the
        // delta is inverted from the fingers (`isDirectionInvertedFrom-
        // Device`), so finger travel is the delta's negation; a legacy
        // wheel reports finger direction already. The drag path reads
        // the pointer — the same space — so both feeds meet
        // `swipeOutcome`/`wingSwipeOutcome` in one sign convention.
        scrollAccumY += Self.scrollFingerDelta(event.scrollingDeltaY,
                                               inverted: event.isDirectionInvertedFromDevice)
        scrollAccumX += Self.scrollFingerDelta(event.scrollingDeltaX,
                                               inverted: event.isDirectionInvertedFromDevice)
        // The dominant axis decides which gesture this is — a sideways
        // flick dismisses or summons wings, a vertical pull expands or
        // collapses the card, and a diagonal never fires either until
        // one axis honestly wins.
        if abs(scrollAccumX) > abs(scrollAccumY) {
            // An ear being pulled follows the finger with resistance
            // until the flick commits — touch that reads dead is what
            // made these feel absent.
            if case .wing(let side) = scrollRegion { onWingPull(side, scrollAccumX) }
            switch Self.wingSwipeOutcome(region: scrollRegion, deltaX: scrollAccumX,
                                         threshold: Self.scrollSwipeThreshold) {
            case .dismiss(let side):
                scrollFired = true
                onWingPullEnd(side)
                onWingDismiss(side)
            case .restore:
                scrollFired = true
                onWingRestore()
            case .none:
                return
            }
            return
        }
        // A downward pull that has not committed still slides the card
        // out under the fingers.
        if scrollAccumY <= -Self.scrollSwipeThreshold * 0.25, !isTooltipShown {
            showPullPeek()
        }
        switch Self.swipeOutcome(pinnedAtDown: scrollPinnedAtStart, deltaY: scrollAccumY,
                                 threshold: Self.scrollSwipeThreshold) {
        case .expand:
            scrollFired = true
            pinCard()
        case .collapse:
            scrollFired = true
            unpin()
        case .none:
            return
        }
    }

    /// Scroll delta → finger travel. Positive is the pointer-space
    /// "up"/"right" the drag path reports — under natural scrolling the
    /// deltas run inverted from the fingers, so they are negated.
    nonisolated static func scrollFingerDelta(_ delta: CGFloat, inverted: Bool) -> CGFloat {
        inverted ? -delta : delta
    }

    /// Deliberate focus entry: a click or swipe pins the peek open as an
    /// interactive card — Open session lives on the card, so a stray
    /// band click never yanks a terminal forward. While the island owns
    /// the notch the same click grows the island, deliberately.
    private func pinCard() {
        if islandOwnsNotch() {
            showWork?.cancel(); showWork = nil
            hideWork?.cancel(); hideWork = nil
            lifeWork?.cancel(); lifeWork = nil
            onIslandExpand()
            return
        }
        guard let focus = focus() ?? lastFocus else { return }
        lastFocus = focus
        showWork?.cancel(); showWork = nil
        hideWork?.cancel(); hideWork = nil
        lifeWork?.cancel(); lifeWork = nil
        card.pin()
    }

    private func unpin() {
        if islandOwnsNotch() {
            onIslandCollapse()
            return
        }
        hideTooltip()
    }

    // MARK: Card

    private func showTooltip(_ focus: ScreenBarFocus) {
        // The island IS the peek while it owns the notch — no glass.
        guard !islandOwnsNotch() else { return }
        lastFocus = focus
        card.peek()
        lifeWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated { self?.tooltipLifeExpired() }
        }
        lifeWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.maxTooltipLife, execute: work)
    }

    /// The life timer firing: a pointer still on the card or the band
    /// means someone is reading it — extend rather than yank it away.
    /// A pinned card answers to its buttons, not the clock.
    private func tooltipLifeExpired() {
        lifeWork = nil
        guard isTooltipShown, !card.isPinned else { return }
        if pointerInHitRegion() {
            let work = DispatchWorkItem { [weak self] in
                MainActor.assumeIsolated { self?.tooltipLifeExpired() }
            }
            lifeWork = work
            DispatchQueue.main.asyncAfter(deadline: .now() + Self.lifeExtension, execute: work)
        } else {
            hideTooltip()
        }
    }

    func hideTooltip() {
        showWork?.cancel()
        hideWork?.cancel()
        lifeWork?.cancel()
        showWork = nil
        hideWork = nil
        lifeWork = nil
        card.hide()
    }
}
