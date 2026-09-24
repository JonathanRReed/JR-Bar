import AppKit
import JRBarCore
import OSLog

/// The gestures that bring the hidden run back: the pointer entering
/// the menu bar row, a click on empty bar space (one that lands on no
/// item frame), or a scroll over the bar — each behind its own setting.
/// A gesture lifts the covers through `onReveal` and arms a rehide for
/// `rehideSeconds`; while the pointer is still on the row or the open
/// Item Bar the timer re-arms instead of firing, so a reveal never folds
/// away under the hand that is using it. `rehideMode == .untilClick`
/// arms no clock at all: the reveal stands until a click lands off the
/// row — the fold `outsideDown` already performs for the timed mode.
///
/// Hover is a poll timer, not an event tap: a global `mouseMoved`
/// monitor delivers ~125 events a second and every delivery costs a
/// `TCCAccessRequest` round trip — that was the tccd flood. With hover
/// reveal switched off the poll idles and reads nothing, and it parks
/// outright while the displays sleep, the session is switched away or
/// the screen is locked. One global
/// monitor covers the discrete gestures (click, scroll); local
/// monitors are gone entirely, so a click on our own chevron or Item
/// Bar can never be mistaken for an empty-space gesture.
@MainActor
final class MenuBarReveal {
    /// The current settings, supplied by the owning utility.
    var settings: @MainActor () -> MenuBarSettings = { MenuBarSettings() }
    /// Every layer-25 frame on the row in *AppKit* screen coordinates —
    /// the empty-space click's hit test.
    var itemFrames: @MainActor () -> [NSRect] = { [] }
    /// The stretch a hover or an empty-space click means "show me what
    /// is hidden": the blank run left of the boundary, in AppKit screen
    /// coordinates. nil widens the gesture to the whole row (the old
    /// rule) — a pointer crossing the app menus or the notch's island
    /// must not pop the run, so the utility always supplies one.
    var revealZone: @MainActor () -> NSRect? = { nil }
    /// Item frames hovering which reveals anyway — the « control itself:
    /// Bartender's chevron opens on hover, and an affordance that waits
    /// for a click reads as dead. Kept out of `itemFrames` so a click on
    /// it stays its own action, not a second reveal.
    var hotFrames: @MainActor () -> [NSRect] = { [] }
    /// The Item Bar panel's frame while it is up — a surface a reveal
    /// stays alive for.
    var barFrame: @MainActor () -> NSRect? = { nil }
    /// Whether a listed item's owner has a menu-layer window open —
    /// the reveal must not fold the run out from under a menu the
    /// person is reading.
    var itemMenuOpen: @MainActor () -> Bool = { false }
    /// A gesture landed: drop the covers.
    var onReveal: @MainActor () -> Void = {}
    /// The rehide timer's landing: the covers go back.
    var onHide: @MainActor () -> Void = {}
    /// Whether the gestures stand down right now: a ⌘-drag is in flight
    /// (or just landed), or a mouse button is held. The drop of a drag
    /// lands in the blank stretch more often than not, and a hover there
    /// popped the Item Bar under the hand. While it holds, the pointer's
    /// presence is tracked but never counts; a fresh entry after it
    /// waits the full dwell. The rehide clock re-arms instead of folding.
    var suppressed: @MainActor () -> Bool = { false }
    /// A ⌘-press anywhere, in AppKit screen coordinates — the drag
    /// learn's fallback while the click bridge's tap is down.
    var onCommandDown: @MainActor (NSPoint, NSEvent.ModifierFlags) -> Void = { _, _ in }
    /// Every left-button release, in AppKit screen coordinates — the
    /// fallback's end of a drag.
    var onPointerUp: @MainActor (NSPoint, NSEvent.ModifierFlags) -> Void = { _, _ in }

    /// Seams so a test can drive the gestures without a screen, a
    /// pointer, or a real clock.
    var row: @MainActor () -> NSRect? = { MenuBarReveal.currentMenuBarRow() }
    var mouseLocation: @MainActor () -> NSPoint = { NSEvent.mouseLocation }
    /// The dwell's clock — a test steers it.
    var now: @MainActor () -> Date = { Date() }
    /// The rehide clock; returns a cancel for the armed fire. Tests
    /// inject a manual clock.
    var scheduleRehide: @MainActor (TimeInterval, @escaping @MainActor () -> Void) -> () -> Void = { seconds, fire in
        let work = DispatchWorkItem { MainActor.assumeIsolated { fire() } }
        DispatchQueue.main.asyncAfter(deadline: .now() + max(0.1, seconds), execute: work)
        return { work.cancel() }
    }

    /// While the Item Bar is open a reveal cannot fold away under it —
    /// the utility sets this from the bar's open changes.
    var holdOpen = false

    /// True while a reveal is out.
    private(set) var revealed = false

    private var globalMonitor: Any?
    /// The front-app watch behind `RehideMode.focusChange`.
    private var focusObserver: NSObjectProtocol?
    private var hoverTimer: Timer?
    /// Whether the hover poll runs — between `startHoverPoll()` and
    /// `stop()`, parked or not.
    private var polling = false
    /// Why the hover poll is parked, if it is.
    private(set) var parkReasons: Set<ParkReason> = []
    private var presenceObservers: [(center: NotificationCenter, token: NSObjectProtocol)] = []
    /// The armed rehide's cancel token, whatever clock supplied it.
    private var cancelPendingRehide: (() -> Void)?
    private var screenObserver: NSObjectProtocol?
    /// The poll's last inside-ness — entry is the gesture, not presence.
    private var hoverInside = false
    /// The dwell deadline a zone entry arms — the reveal answers only
    /// when the pointer is still inside at the deadline.
    private var hoverDwellDeadline: Date?
    /// The last time `onReveal` actually fired; back-to-back gestures
    /// inside the throttle just keep the clock warm.
    private var lastRevealAt = Date.distantPast

    /// How far past the row's band a pointer can sit and still count as
    /// "on the bar" — the reveal is not a pixel hunt.
    nonisolated static let rowSlack: CGFloat = 3
    /// The hover poll's cadence — fast enough that entry feels instant
    /// near the bar; a pointer far below it is read a few times a
    /// second (twenty wakeups a second across three polls kept the
    /// CPU from idling).
    nonisolated static let hoverPollInterval: TimeInterval = 0.1
    nonisolated static let farPollInterval: TimeInterval = 0.33
    /// With hover reveal off nothing reads the pointer: the poll only
    /// checks, this often, whether the setting has come back on — the
    /// utility tells the reveal nothing when a toggle flips.
    nonisolated static let idlePollInterval: TimeInterval = 1.0
    /// The share of each wait the system may shift a poll by, so the
    /// menu bar's, the Screen Bar's and the Dock's pointer polls land
    /// on the same wakeups instead of three chains of their own.
    nonisolated static let pollTolerance: Double = 0.2
    /// How far below the row "far" starts.
    nonisolated static let nearReach: CGFloat = 120
    /// A gesture burst this close together is one reveal, not many —
    /// a scroll stream would otherwise reconcile per tick.
    nonisolated static let revealThrottle: TimeInterval = 0.5
    /// How long a pointer must rest in the zone before a hover counts —
    /// a graze across the stretch on the way to the clock is not a
    /// gesture. Two polls at the near cadence; an instance property so
    /// a test can pin the old fire-on-entry timing.
    nonisolated static let defaultHoverDwell: TimeInterval = 0.18
    var hoverDwell: TimeInterval = MenuBarReveal.defaultHoverDwell

    /// The row rect the off-actor monitor reads; a lock keeps the
    /// read whole against a screens-changed rewrite.
    private final class RowGate: @unchecked Sendable {
        let lock = NSLock()
        var row: NSRect = .zero
    }
    nonisolated private let gate = RowGate()

    func start() {
        guard globalMonitor == nil else { return }
        refreshRowCache()
        screenObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.refreshRowCache() }
        }
        // One tap, one mask: every additional global monitor is another
        // event stream the TCC service gets pinged for. Mouse-ups are
        // discrete like the downs — they end a ⌘-drag when the click
        // bridge's tap is down — so they bring back no flood.
        globalMonitor = NSEvent.addGlobalMonitorForEvents(
            matching: [.leftMouseDown, .leftMouseUp, .scrollWheel],
            handler: { [weak self] event in self?.noteGlobalEvent(event) })
        watchFocus()
        watchPresence()
        if MenuBarStateRunner.screenIsLocked() { park(.locked) }
        startHoverPoll()
    }

    /// The hover poll alone, without the gestures' monitor — `start()`
    /// runs it, and a test can.
    func startHoverPoll() {
        polling = true
        guard !isParked else { return }
        scheduleHoverPoll(after: Self.hoverPollInterval)
    }

    /// One-shot, re-armed at the cadence the last poll earned.
    private func scheduleHoverPoll(after interval: TimeInterval) {
        hoverTimer?.invalidate()
        hoverTimer = nil
        guard polling, !isParked else { return }
        let timer = Timer(timeInterval: interval, repeats: false, block: { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.scheduleHoverPoll(after: self.hoverTick())
            }
        })
        timer.tolerance = interval * Self.pollTolerance
        RunLoop.main.add(timer, forMode: .common)
        hoverTimer = timer
    }

    /// Whether a poll is armed — false while parked or stopped.
    var hoverPollArmed: Bool { hoverTimer != nil }

    // MARK: Parking

    /// Why the hover poll sleeps: nobody points at a bar on a display
    /// that is asleep, in a session switched away, or behind the lock
    /// screen. The poll parks on the first reason and resumes once every
    /// one has cleared — a wake that still shows the lock screen stays
    /// parked until the unlock.
    enum ParkReason: Hashable, Sendable {
        case displaysAsleep, sessionInactive, locked
    }

    var isParked: Bool { !parkReasons.isEmpty }

    func park(_ reason: ParkReason) {
        parkReasons.insert(reason)
        hoverTimer?.invalidate()
        hoverTimer = nil
        // Entry is learned afresh on the way back.
        hoverInside = false
        hoverDwellDeadline = nil
    }

    func unpark(_ reason: ParkReason) {
        guard parkReasons.remove(reason) != nil, !isParked, polling else { return }
        scheduleHoverPoll(after: Self.hoverPollInterval)
    }

    /// Ice's "smart" rehide: under `.focusChange` a reveal folds when
    /// another app comes to the front — the person has moved on.
    private func watchFocus() {
        guard focusObserver == nil else { return }
        focusObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.frontAppChanged() }
        }
    }

    /// Another app came to the front. Under `.focusChange` the reveal
    /// folds — unless a listed item's menu is open (its app may well be
    /// the one that activated) or a drag holds the bar.
    func frontAppChanged() {
        guard revealed, settings().rehideMode == .focusChange,
              !itemMenuOpen(), !suppressed() else { return }
        Self.log.notice("reveal: the front app changed")
        cancelReveal()
        onHide()
    }

    /// The display, session and lock notices that park and resume the
    /// poll, for as long as the reveal runs.
    private func watchPresence() {
        let workspace = NSWorkspace.shared.notificationCenter
        let distributed = DistributedNotificationCenter.default()
        let notices: [(NotificationCenter, Notification.Name, ParkReason, Bool)] = [
            (workspace, NSWorkspace.screensDidSleepNotification, .displaysAsleep, true),
            (workspace, NSWorkspace.screensDidWakeNotification, .displaysAsleep, false),
            (workspace, NSWorkspace.sessionDidResignActiveNotification, .sessionInactive, true),
            (workspace, NSWorkspace.sessionDidBecomeActiveNotification, .sessionInactive, false),
            (distributed, Notification.Name("com.apple.screenIsLocked"), .locked, true),
            (distributed, Notification.Name("com.apple.screenIsUnlocked"), .locked, false),
        ]
        for (center, name, reason, parks) in notices {
            let token = center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated {
                    if parks { self?.park(reason) } else { self?.unpark(reason) }
                }
            }
            presenceObservers.append((center, token))
        }
    }

    /// One poll, and the wait it earns: fast near the bar, slower far
    /// below it — and with hover reveal off, none of the zone, item or
    /// hot-frame reads at all, only the idle check for the setting.
    /// Entry is re-learned from scratch when it comes back on.
    func hoverTick() -> TimeInterval {
        guard settings().revealOnHover else {
            hoverInside = false
            hoverDwellDeadline = nil
            return Self.idlePollInterval
        }
        pollHover()
        let near = (row().map { $0.minY - Self.nearReach } ?? 0) <= mouseLocation().y
        return near ? Self.hoverPollInterval : Self.farPollInterval
    }

    func stop() {
        if let globalMonitor { NSEvent.removeMonitor(globalMonitor) }
        globalMonitor = nil
        if let focusObserver { NSWorkspace.shared.notificationCenter.removeObserver(focusObserver) }
        focusObserver = nil
        hoverTimer?.invalidate()
        hoverTimer = nil
        polling = false
        parkReasons = []
        for observer in presenceObservers { observer.center.removeObserver(observer.token) }
        presenceObservers = []
        if let screenObserver { NotificationCenter.default.removeObserver(screenObserver) }
        screenObserver = nil
        cancelPendingRehide?()
        cancelPendingRehide = nil
        revealed = false
        holdOpen = false
        hoverInside = false
        hoverDwellDeadline = nil
        lastRevealAt = .distantPast
    }

    isolated deinit {
        if let globalMonitor { NSEvent.removeMonitor(globalMonitor) }
        if let focusObserver { NSWorkspace.shared.notificationCenter.removeObserver(focusObserver) }
        hoverTimer?.invalidate()
        for observer in presenceObservers { observer.center.removeObserver(observer.token) }
        if let screenObserver { NotificationCenter.default.removeObserver(screenObserver) }
        cancelPendingRehide?()
    }

    /// The row in AppKit coordinates, slack included: the top of the
    /// screen carrying the menu bar, `thickness` (or the notch's depth)
    /// deep. Nil when no screen carries a menu bar.
    private static func currentMenuBarRow() -> NSRect? {
        guard let screen = NSScreen.main else { return nil }
        let depth = max(NSStatusBar.system.thickness, ScreenBarGeometry.notchDepth(of: screen))
        return NSRect(x: screen.frame.minX, y: screen.frame.maxY - max(depth, 1),
                      width: screen.frame.width, height: max(depth, 1))
            .insetBy(dx: 0, dy: -rowSlack)
    }

    /// The monitor's cached row, recomputed on start and when the
    /// screens change.
    private func refreshRowCache() {
        let rect = row() ?? .zero
        gate.lock.lock()
        gate.row = rect
        gate.lock.unlock()
    }

    // MARK: Monitor handler (off-actor)

    /// The one global tap: click or scroll inside the row band. The
    /// row hit-test happens here on the cached rect so a stray event
    /// never pays a main-actor hop.
    nonisolated private func noteGlobalEvent(_ event: NSEvent) {
        let point = NSEvent.mouseLocation
        let flags = event.modifierFlags
        if event.type == .leftMouseUp {
            Task { @MainActor [weak self] in self?.onPointerUp(point, flags) }
            return
        }
        // A ⌘-press is a drag's start: reported, and never a reveal click.
        let command = event.type == .leftMouseDown && flags.contains(.command)
        if command {
            Task { @MainActor [weak self] in self?.onCommandDown(point, flags) }
        }
        gate.lock.lock()
        let inside = gate.row.contains(point)
        gate.lock.unlock()
        guard inside else {
            // Off the row is outside the gesture entirely — except a
            // click, which while a reveal is out is the dismiss, the
            // same rule the Item Bar's own panel follows.
            if event.type == .leftMouseDown {
                Task { @MainActor [weak self] in self?.outsideDown(at: point) }
            }
            return
        }
        switch event.type {
        case .leftMouseDown:
            guard !command else { return }
            Task { @MainActor [weak self] in self?.pointerDown(at: point) }
        case .scrollWheel:
            Task { @MainActor [weak self] in self?.scrolled() }
        default:
            break
        }
    }

    // MARK: Gestures (main actor)

    /// The hover gesture, polled: entering the *zone* is the reveal —
    /// the row band minus other apps' item frames, so the gesture is
    /// hovering the chevron or a covered/empty stretch, not parking on
    /// the clock. Item frames are the *shown* items only — a covered
    /// stretch is exactly the zone a gesture belongs to. A pointer
    /// parked in the zone is not a stream of gestures, and the rehide
    /// timer already re-arms while the pointer stays on the row.
    func pollHover() {
        let point = mouseLocation()
        let inZone = ((revealZone() ?? row() ?? .zero).contains(point)
            && !itemFrames().contains(where: { $0.contains(point) }))
            || hotFrames().contains(where: { $0.contains(point) })
        if suppressed() {
            // A drag in flight or a held button: presence is tracked, so
            // the pointer still resting where the drop landed is not an
            // entry once it lifts; a fresh entry waits the full dwell.
            hoverInside = inZone
            hoverDwellDeadline = nil
            return
        }
        let entered = inZone && !hoverInside
        hoverInside = inZone
        guard inZone else {
            hoverDwellDeadline = nil
            return
        }
        if entered {
            // A graze on the way to the clock is not a gesture — the
            // zone must be dwelt in before the reveal answers. The
            // deadline is read on this and later polls, so no extra
            // timer; a zero dwell (tests) fires on entry as before.
            hoverDwellDeadline = now().addingTimeInterval(hoverDwell)
        }
        guard let deadline = hoverDwellDeadline, now() >= deadline else { return }
        hoverDwellDeadline = nil
        pointerEnteredRow()
    }

    static let log = Logger(subsystem: "devin.jrbar", category: "menubar")

    func pointerEnteredRow() {
        guard settings().revealOnHover else { return }
        triggerReveal("hover entered the blank stretch")
    }

    func pointerDown(at point: NSPoint) {
        guard settings().revealOnClick else { return }
        // Only empty space in the zone counts — a click on an item is
        // that item's, a click on the far side of the bar is nobody's.
        if let zone = revealZone(), !zone.contains(point) { return }
        guard !itemFrames().contains(where: { $0.contains(point) }) else { return }
        triggerReveal("click on the blank stretch")
    }

    func scrolled() {
        guard settings().revealOnScroll else { return }
        triggerReveal("scroll on the bar")
    }

    /// A click anywhere off the row while a reveal is out folds it —
    /// the inline reveal's click-outside dismiss. A click on the open
    /// Item Bar is the bar's own business (its monitors fold it), and
    /// a listed item's open menu holds the run out: folding under a
    /// menu the person is reading strands the click's answer.
    private func outsideDown(at point: NSPoint) {
        guard revealed else { return }
        if let frame = barFrame(), frame.insetBy(dx: -2, dy: -2).contains(point) { return }
        guard !itemMenuOpen() else { return }
        Self.log.notice("reveal: click off the row")
        cancelReveal()
        onHide()
    }

    /// Any gesture: reveal once, then keep the timer fresh. A burst
    /// inside `revealThrottle` re-arms without re-firing `onReveal` —
    /// reveal and hide are transitions, and a scroll stream must not
    /// turn into a reconcile storm. The notice names the gesture once
    /// per reveal that fires: logged per event, a trackpad scroll wrote
    /// 65 lines in one second (2026-09-22).
    func triggerReveal(_ gesture: String = "gesture") {
        let now = Date()
        if revealed, now.timeIntervalSince(lastRevealAt) < Self.revealThrottle {
            armRehide(settings().rehideSeconds)
            return
        }
        lastRevealAt = now
        revealed = true
        Self.log.notice("reveal: \(gesture, privacy: .public)")
        onReveal()
        armRehide(settings().rehideSeconds)
    }

    /// Extend the current reveal's clock without re-firing `onReveal` —
    /// a click on a bar tile is a gesture too, but the bar itself is
    /// already going away.
    func rearm() {
        revealed = true
        armRehide(settings().rehideSeconds)
    }

    /// A reveal with an explicit clock — the trigger engine's
    /// `.reveal(seconds)` action. The caller drops the covers; this
    /// arms their return. The rule named its own seconds, so the
    /// `rehideMode` setting does not gate it.
    func rearm(for seconds: TimeInterval) {
        revealed = true
        armClock(max(0.5, seconds))
    }

    /// A deliberate hide — the chevron's own toggle. Drops the pending
    /// clock so a stale fire cannot land a second `onHide` after the
    /// covers already stand.
    func cancelReveal() {
        revealed = false
        cancelPendingRehide?()
        cancelPendingRehide = nil
    }

    /// The bar dismissed: if a reveal is still out, give it a short
    /// clock rather than leaving the items up indefinitely. Under the
    /// click-scoped mode the surface was the reveal — its close is
    /// the fold.
    func noteBarClosed() {
        guard revealed else { return }
        if settings().rehideMode == .timed {
            armRehide(0.6)
        } else {
            cancelReveal()
            onHide()
        }
    }

    /// The settings-driven clock. Click-scoped mode arms none — a
    /// click off the row (`outsideDown`) is the only fold it knows.
    private func armRehide(_ seconds: TimeInterval) {
        guard settings().rehideMode == .timed else { return }
        armClock(seconds)
    }

    /// The clock itself — the explicit `rearm(for:)` seconds and the
    /// re-arm a fired timer earns are clocks regardless of mode.
    private func armClock(_ seconds: TimeInterval) {
        cancelPendingRehide?()
        cancelPendingRehide = scheduleRehide(seconds) { [weak self] in self?.rehideTimerFired() }
    }

    /// Whether the pointer is still on a surface the reveal serves —
    /// the row or the open bar — or the bar holds the reveal open.
    /// The rehide clock's rule, shared with the update reveal's
    /// landing and the click-outside dismiss.
    func pointerOnRevealSurface() -> Bool {
        let point = mouseLocation()
        return (row()?.contains(point) ?? false)
            || (barFrame()?.insetBy(dx: -2, dy: -2).contains(point) ?? false)
            || holdOpen
    }

    /// The timer's landing: if the pointer is still on a surface the
    /// reveal serves — the row or the open bar — or a listed item's
    /// menu is open, it re-arms briefly instead of folding the items
    /// out from under it.
    func rehideTimerFired() {
        cancelPendingRehide = nil
        // A cancelled reveal owes no hide — the covers already stand.
        guard revealed else { return }
        if pointerOnRevealSurface() || itemMenuOpen() || suppressed() {
            armClock(0.5)
            return
        }
        revealed = false
        Self.log.notice("reveal: rehide")
        onHide()
    }
}
