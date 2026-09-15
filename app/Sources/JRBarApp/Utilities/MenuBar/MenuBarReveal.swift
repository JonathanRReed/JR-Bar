import AppKit
import JRBarCore

/// The gestures that bring the hidden run back: the pointer entering
/// the menu bar row, a click on empty bar space (one that lands on no
/// item frame), or a scroll over the bar — each behind its own setting.
/// A gesture lifts the covers through `onReveal` and arms a rehide for
/// `rehideSeconds`; while the pointer is still on the row or the open
/// Item Bar the timer re-arms instead of firing, so a reveal never folds
/// away under the hand that is using it.
///
/// Hover is a poll timer, not an event tap: a global `mouseMoved`
/// monitor delivers ~125 events a second and every delivery costs a
/// `TCCAccessRequest` round trip — that was the tccd flood. One global
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
    /// The Item Bar panel's frame while it is up — a surface a reveal
    /// stays alive for.
    var barFrame: @MainActor () -> NSRect? = { nil }
    /// A gesture landed: drop the covers.
    var onReveal: @MainActor () -> Void = {}
    /// The rehide timer's landing: the covers go back.
    var onHide: @MainActor () -> Void = {}

    /// Seams so a test can drive the gestures without a screen, a
    /// pointer, or a real clock.
    var row: @MainActor () -> NSRect? = { MenuBarReveal.currentMenuBarRow() }
    var mouseLocation: @MainActor () -> NSPoint = { NSEvent.mouseLocation }
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
    private var hoverTimer: Timer?
    /// The armed rehide's cancel token, whatever clock supplied it.
    private var cancelPendingRehide: (() -> Void)?
    private var screenObserver: NSObjectProtocol?
    /// The poll's last inside-ness — entry is the gesture, not presence.
    private var hoverInside = false
    /// The last time `onReveal` actually fired; back-to-back gestures
    /// inside the throttle just keep the clock warm.
    private var lastRevealAt = Date.distantPast

    /// How far past the row's band a pointer can sit and still count as
    /// "on the bar" — the reveal is not a pixel hunt.
    nonisolated static let rowSlack: CGFloat = 3
    /// The hover poll's cadence — fast enough that entry feels instant.
    nonisolated static let hoverPollInterval: TimeInterval = 0.1
    /// A gesture burst this close together is one reveal, not many —
    /// a scroll stream would otherwise reconcile per tick.
    nonisolated static let revealThrottle: TimeInterval = 0.5

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
        // event stream the TCC service gets pinged for.
        globalMonitor = NSEvent.addGlobalMonitorForEvents(
            matching: [.leftMouseDown, .scrollWheel],
            handler: { [weak self] event in self?.noteGlobalEvent(event) })
        let timer = Timer(timeInterval: Self.hoverPollInterval, repeats: true,
                          block: { [weak self] _ in
            MainActor.assumeIsolated { self?.pollHover() }
        })
        RunLoop.main.add(timer, forMode: .common)
        hoverTimer = timer
    }

    func stop() {
        if let globalMonitor { NSEvent.removeMonitor(globalMonitor) }
        globalMonitor = nil
        hoverTimer?.invalidate()
        hoverTimer = nil
        if let screenObserver { NotificationCenter.default.removeObserver(screenObserver) }
        screenObserver = nil
        cancelPendingRehide?()
        cancelPendingRehide = nil
        revealed = false
        holdOpen = false
        hoverInside = false
        lastRevealAt = .distantPast
    }

    isolated deinit {
        if let globalMonitor { NSEvent.removeMonitor(globalMonitor) }
        hoverTimer?.invalidate()
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
        gate.lock.lock()
        let inside = gate.row.contains(point)
        gate.lock.unlock()
        guard inside else { return }
        switch event.type {
        case .leftMouseDown:
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
        let inZone = (row() ?? .zero).contains(point)
            && !itemFrames().contains(where: { $0.contains(point) })
        let entered = inZone && !hoverInside
        hoverInside = inZone
        guard entered else { return }
        pointerEnteredRow()
    }

    func pointerEnteredRow() {
        guard settings().revealOnHover else { return }
        triggerReveal()
    }

    func pointerDown(at point: NSPoint) {
        guard settings().revealOnClick else { return }
        // Only empty space counts — a click on an item is that item's.
        guard !itemFrames().contains(where: { $0.contains(point) }) else { return }
        triggerReveal()
    }

    func scrolled() {
        guard settings().revealOnScroll else { return }
        triggerReveal()
    }

    /// Any gesture: reveal once, then keep the timer fresh. A burst
    /// inside `revealThrottle` re-arms without re-firing `onReveal` —
    /// reveal and hide are transitions, and a scroll stream must not
    /// turn into a reconcile storm.
    func triggerReveal() {
        let now = Date()
        if revealed, now.timeIntervalSince(lastRevealAt) < Self.revealThrottle {
            armRehide(settings().rehideSeconds)
            return
        }
        lastRevealAt = now
        revealed = true
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
    /// arms their return.
    func rearm(for seconds: TimeInterval) {
        revealed = true
        armRehide(max(0.5, seconds))
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
    /// clock rather than leaving the items up indefinitely.
    func noteBarClosed() {
        if revealed { armRehide(0.6) }
    }

    private func armRehide(_ seconds: TimeInterval) {
        cancelPendingRehide?()
        cancelPendingRehide = scheduleRehide(seconds) { [weak self] in self?.rehideTimerFired() }
    }

    /// The timer's landing: if the pointer is still on a surface the
    /// reveal serves — the row or the open bar — it re-arms briefly
    /// instead of folding the items out from under it.
    func rehideTimerFired() {
        cancelPendingRehide = nil
        // A cancelled reveal owes no hide — the covers already stand.
        guard revealed else { return }
        let point = mouseLocation()
        let onRow = row()?.contains(point) ?? false
        let onBar = barFrame()?.insetBy(dx: -2, dy: -2).contains(point) ?? false
        if onRow || onBar || holdOpen {
            armRehide(0.5)
            return
        }
        revealed = false
        onHide()
    }
}
