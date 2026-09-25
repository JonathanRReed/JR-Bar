import AppKit
import CoreVideo
import JRBarCore
import Observation
import OSLog
import QuartzCore
import SwiftUI

/// Fold's decision chain lands in unified logging under
/// `devin.jrbar / fold` — `log stream --predicate 'subsystem ==
/// "devin.jrbar" && category == "fold"'` shows live state during a real
/// lid close: sensor edge → gate → armed/busy → delta → frame → texture
/// → visible. Every emission is a state transition, not a per-poll or
/// per-frame line, so the log stays quiet at rest.
enum FoldLog {
    static let log = Logger(subsystem: "devin.jrbar", category: "fold")
    private static let handle = OSLog(subsystem: "devin.jrbar", category: "fold")
    /// Someone is streaming debug lines (`log stream --level debug`):
    /// only then is a debug line worth writing out.
    static var debugEnabled: Bool { handle.isEnabled(type: .debug) }
}

/// Fold (docs/TOYS.md): closing the lid folds the desktop. The Duo look
/// (the default) is the iPhone Duo's fold: the picture holds still in
/// space while the glass swings through it, softening and going dark
/// away from the hinge; the Room look is the older lit room seen
/// through the screen. The pieces stay small: `LidAngleSensor` reads
/// the hinge, `FoldArming` decides when the ScreenCaptureKit streams
/// may exist (from the first real move, or inside the arming band, plus
/// a short cooldown, so the purple indicator only shows while a fold
/// can be on screen), `FoldCapture` grabs the built-in display — one
/// picture for the Duo, the desktop plus the wallpaper-only far wall
/// and the window cards for the Room — `EdgeInterpolator` and
/// `SlewTracker` turn the 10 Hz integer sensor into a steady,
/// overshoot-free glide, `DeltaChase` unwinds the displayed delta when
/// the gate snaps it to 0 mid-motion, and `FoldRenderer` draws the look
/// into the click-through `FoldOverlayWindow`. Render can also be
/// handed to Bendy or Lid Plane; then all of this stays parked.
@MainActor
@Observable
final class FoldToy: Toy {
    let core: CoreModel
    /// The owning store; weak, the store keeps the toy.
    weak var store: ToysStore?

    /// The hinge. Polls only while the toy is on and JR-Bar is rendering.
    let sensor = LidAngleSensor()

    /// The Simulate slider owns the angle while it is held, so the toy
    /// works on a Mac with no lid sensor at all. Not observed: it moves
    /// 60 times a second under a drag or Try it; the slider's own write
    /// schedules the reconcile, and the card reads `cardAngle`.
    @ObservationIgnored private(set) var simulatedAngle: Double?
    /// True while the slider or Try it drives the angle.
    private(set) var simulating = false
    /// The newest raw sensor reading, jitter unfiltered — the activation
    /// gate checks this so a predicted lead can never open the overlay
    /// early, and a filtered straggler can never hold it open above the
    /// limit. Not observed: the engine reads it where it needs it, and
    /// the card reads `cardAngle`.
    @ObservationIgnored private(set) var rawAngle: Double?
    /// What the card shows: the lid in whole degrees (the simulation
    /// while one plays), the fold's state line, and why it is paused —
    /// each changed at most ten times a second (`FoldCardFeed`), and only
    /// when it changed, so a lid at rest redraws nothing.
    private(set) var cardAngle: Double?
    /// Whether the card has an angle to show — the label's size follows
    /// it, and it changes only when the sensor starts or stops reading.
    private(set) var cardHasAngle = false
    private(set) var cardDetail = ""
    private(set) var cardPause: String?
    @ObservationIgnored private var cardFeed = FoldCardFeed()
    @ObservationIgnored private var cardFlush: DispatchWorkItem?
    /// The resting lid's flicker stops here (`FoldRestGate`).
    @ObservationIgnored private var restGate = FoldRestGate()
    /// A reconcile asked for by the slider, not yet run.
    @ObservationIgnored private var reconcileQueued = false
    /// Metal or the shader failed, so the fold is parked — but not for
    /// the app's lifetime: re-enabling the toy clears the flag at once,
    /// and past `rendererRetryCooldown` the next arm attempt tries the
    /// init again, so a transient Metal failure can't bench the fold
    /// forever. While it stands the chip keeps saying why.
    private(set) var rendererFailed = false
    /// When the last renderer init failed (host seconds) — the retry
    /// cooldown counts from here.
    @ObservationIgnored private var rendererFailedAt: TimeInterval = 0
    /// Seconds a renderer failure holds before the next arm attempt may
    /// retry: long enough that a still-broken renderer can't spam a
    /// Metal compile every sensor beat, short enough that a transient
    /// hiccup clears itself inside a minute.
    private static let rendererRetryCooldown: TimeInterval = 30
    /// Notification-fed state, kept as observed vars so one observation
    /// pass sees every change.
    private(set) var screenAsleep = false
    /// The login window is up over this session (`com.apple.screenIsLocked`).
    private(set) var screenLocked = FoldSessionState.current().locked
    /// Another user switched in over this session (fast user switching).
    private(set) var sessionInactive = !FoldSessionState.current().onConsole
    private(set) var displayVersion = 0
    private(set) var motionVersion = 0
    private(set) var workspaceVersion = 0
    /// Bumped when the app re-activates, the moment a granted Screen
    /// Recording permission actually lands.
    private(set) var permissionVersion = 0

    @ObservationIgnored private var jitter = JitterFilter(tolerance: 0)
    /// The display-angle tracker: critically damped and slew-limited, so
    /// the 10 Hz integer-degree sensor becomes a continuous glide that
    /// can never overshoot — a slammed lid eases shut in ~300 ms instead
    /// of lurching between samples. Fed on accepted samples, ticked on
    /// every vsync.
    @ObservationIgnored private var tracker = SlewTracker()
    /// The Duo's sensor smoothing: the lid drawn one sensor period in
    /// the past, straight between edges, so a steady close moves at a
    /// steady speed. Feeds the tracker every tick; the simulate slider
    /// and Try it bypass it (they are already smooth).
    @ObservationIgnored private var edges = EdgeInterpolator()
    /// The movement fold's ease from 0 to the live delta when the first
    /// captured frame lands late.
    @ObservationIgnored private var catchUp = FirstFrameCatchUp()
    /// Set when a capture starts; the first frame clears it.
    @ObservationIgnored private var awaitingFirstFrame = false
    /// The Duo's black hold across the closed-lid pause.
    @ObservationIgnored private var blackout = FoldBlackout()
    @ObservationIgnored private var blackoutWork: DispatchWorkItem?
    /// When the overlay last ordered in, for the Duo's order-in fade;
    /// nil while it is out.
    @ObservationIgnored private var overlayShownAt: TimeInterval?
    /// The reference the Duo draws this gesture from: taken as the
    /// overlay orders in and kept until it orders out, so an unwind that
    /// outlives its anchor (the dwell re-seat, a reopen that settles
    /// short of the old rest, a reset) still draws from the same lid,
    /// and a reopen from the black hold unfolds from the lid it closed
    /// from.
    @ObservationIgnored private var heldReference: Double?
    /// The displayed-delta follower: instant while the fold deepens, a
    /// slew-limited unwind when the gate snaps the target to 0 —
    /// opening counter-rotates the room back through the hinge instead
    /// of cutting to black mid-swing.
    @ObservationIgnored private var chase = DeltaChase()
    /// The capture-lifecycle machine: the streams exist only inside the
    /// arming band and through its cooldown, and it owns the fold gate's
    /// hysteresis at the activation edge.
    @ObservationIgnored private var arming = FoldArming()
    /// The movement-anchored reference (`FoldAnchor.movement`): where
    /// the lid was resting when the gesture began. Fed every raw sample
    /// — stillness IS its signal — while the jitter filter still guards
    /// what reaches the tracker.
    @ObservationIgnored private var moveAnchor = MoveAnchor()
    /// The latest window-card layout, kept so an overlay created after
    /// the poll still gets it.
    @ObservationIgnored private var lastCards: [PortalDepth.Card] = []
    /// Fires when a cooling arming phase expires — the stream shutdown
    /// is scheduled, not polled.
    @ObservationIgnored private var cooldownWork: DispatchWorkItem?
    /// What the renderer is currently showing — diagnostics only.
    @ObservationIgnored private var displayedDelta = 0.0
    @ObservationIgnored private var overlay: FoldOverlayWindow?

    /// True while the fold plane is on screen — overlay guests like the
    /// island use it to let clicks fall through glass they can't see.
    var overlayOnScreen: Bool { overlay?.isVisible == true }
    /// The frames: the ScreenCaptureKit streams, or — without Screen
    /// Recording — the wallpaper alone (`FoldWallpaperSource`).
    @ObservationIgnored private var capture: (any FoldFrameSource)?
    @ObservationIgnored private var observers: [NSObjectProtocol] = []
    /// The lock and unlock broadcasts arrive on the distributed centre.
    @ObservationIgnored private var distributedObservers: [NSObjectProtocol] = []
    @ObservationIgnored private var lastDeltaTick: TimeInterval = 0
    /// Safety facts, cached instead of queried per frame: the clamshell
    /// truth rides in on the sensor's 1 Hz beat, and display topology
    /// only re-reads when the screen-parameters notification bumps
    /// `displayVersion` (plus a 2 s staleness backstop while armed).
    /// IOKit and CoreGraphics queries at vsync rate were the jitter.
    @ObservationIgnored private var cachedClamshell: Bool?
    @ObservationIgnored private var cachedBuiltinPresent = true
    @ObservationIgnored private var cachedMirrored = false
    @ObservationIgnored private var cachedFactsVersion = -1
    @ObservationIgnored private var cachedFactsAt: TimeInterval = 0
    /// The vsync heartbeat while the fold is armed. CADisplayLink needs
    /// an NSObject target, so the box holds the closure.
    @ObservationIgnored private var tickLink: CADisplayLink?
    @ObservationIgnored private let tickBox = TickBox()
    /// A missing built-in screen makes `ensureOverlay` fail; retrying
    /// every vsync would spin, so attempts are half a second apart.
    @ObservationIgnored private var lastOverlayAttempt: TimeInterval = 0
    /// When the current capture was asked to start — a stream that stays
    /// frameless for seconds is dead on arrival (a hung
    /// SCShareableContent fetch never throws), so it gets recycled.
    @ObservationIgnored private var captureBeganAt: TimeInterval = 0
    /// Last frameless-capture recycle; retries stay seconds apart.
    @ObservationIgnored private var lastCaptureRecycle: TimeInterval = 0
    /// The displayParameters version the overlay was last framed for.
    @ObservationIgnored private var reframedVersion = -1
    /// Set when a safety input parked us; only a resume from here waits
    /// the half-second quiet — a first fold starts right away.
    @ObservationIgnored private var paused = false
    /// The half-second "all clear" before a paused fold resumes.
    @ObservationIgnored private var resumeWork: DispatchWorkItem?
    /// The dwell pause — a lid parked mid-fold past `dwellTimeout`
    /// hands the desktop back until the hinge moves again. Unlike the
    /// safety `paused`, the capture streams stay armed so the return
    /// is instant.
    @ObservationIgnored private var dwellPaused = false
    /// The angle the dwell timer parked on — a move past the jitter
    /// deadband from here wakes the fold.
    @ObservationIgnored private var dwellAnchor: Double?
    @ObservationIgnored private var dwellWork: DispatchWorkItem?
    /// Tracks whether the fold was ever up this run, so the restore
    /// click only sounds on a real unwind, not on every at-rest tick.
    @ObservationIgnored private var foldWasUp = false
    /// The last diagnostic line logged, as numbers — the log only speaks
    /// when the machine's state actually changes, so a parked fold stays
    /// silent, and no text is built for a pass that changed nothing.
    @ObservationIgnored private var lastDiag: (state: FoldDiagState, angles: FoldDiagAngles)?
    /// The last notice line's dedup key, angles left out — see
    /// `noteDiag`.
    @ObservationIgnored private var lastNoticeDiag: FoldDiagState?

    init(core: CoreModel, store: ToysStore) {
        self.core = core
        self.store = store
        jitter.tolerance = store.state.fold.jitterTolerance

        let workspace = NSWorkspace.shared.notificationCenter
        observers.append(workspace.addObserver(
            forName: NSWorkspace.screensDidSleepNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.screenAsleep = true }
        })
        observers.append(workspace.addObserver(
            forName: NSWorkspace.screensDidWakeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.screenAsleep = false }
        })
        observers.append(workspace.addObserver(
            forName: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification,
            object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.motionVersion += 1 }
        })
        for name in [NSWorkspace.didLaunchApplicationNotification,
                     NSWorkspace.didTerminateApplicationNotification] {
            observers.append(workspace.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.workspaceVersion += 1 }
            })
        }
        // The lock and a fast-user switch both hand the screen to
        // someone who is not looking at this desktop: the fold stands
        // down and its capture streams stop, so the Screen Recording
        // indicator never sits behind a lock screen.
        observers.append(workspace.addObserver(
            forName: NSWorkspace.sessionDidResignActiveNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.sessionInactive = true }
        })
        observers.append(workspace.addObserver(
            forName: NSWorkspace.sessionDidBecomeActiveNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.sessionInactive = false }
        })
        let distributed = DistributedNotificationCenter.default()
        distributedObservers.append(distributed.addObserver(
            forName: FoldSessionState.lockedNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.screenLocked = true }
        })
        distributedObservers.append(distributed.addObserver(
            forName: FoldSessionState.unlockedNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.screenLocked = false }
        })
        let center = NotificationCenter.default
        observers.append(center.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.displayVersion += 1 }
        })
        observers.append(center.addObserver(
            forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                // Re-activating is the moment a granted Screen
                // Recording permission lands — drop the cached
                // preflight so the next read asks TCC once, here,
                // instead of waiting out the 30 s freshness.
                FoldCapturePermission.invalidate()
                self?.permissionVersion += 1
            }
        })

        sensor.onSample = { [weak self] angle in self?.noteSensorSample(angle) }
        tickBox.onTick = { [weak self] in
            MainActor.assumeIsolated { self?.tickFrame() }
        }
        observe()
        publishCard()
    }

    let id = "fold"
    let name = "Fold"
    let blurb = "Your desktop folds into the screen as the lid comes down."
    let symbol = "laptopcomputer"

    var isOn: Bool {
        get { store?.state.fold.enabled ?? false }
        set {
            store?.state.fold.enabled = newValue
            store?.save()
            if newValue {
                // Re-enabling is a fresh ask — a stale renderer
                // failure must not outlive the toggle.
                rendererFailed = false
            }
            reconcile()
        }
    }

    // MARK: Status

    var settings: FoldSettings { store?.state.fold ?? FoldSettings() }

    /// What the chip says — always a fact, never a promise.
    var status: ToyStatus {
        let settings = settings
        _ = workspaceVersion
        _ = permissionVersion
        switch settings.provider {
        case .bendy:
            guard bendyURL != nil else { return .unavailable("Bendy isn't installed") }
            return settings.enabled ? .external("Bendy is rendering it") : .off
        case .lidPlane:
            guard lidPlaneURL != nil else { return .unavailable("Lid Plane isn't installed") }
            return settings.enabled ? .external("Lid Plane is rendering it") : .off
        case .jrbar:
            break
        }
        if !settings.enabled {
            return sensor.available ? .off : .unavailable("No lid-angle sensor on this Mac")
        }
        if rendererFailed { return .unavailable("Fold can't start its renderer") }
        if !sensor.available && !simulating {
            return .unavailable("No lid-angle sensor on this Mac")
        }
        if !FoldCapturePermission.granted && !settings.wallpaperFallback {
            return .needsPermission("Needs Screen Recording")
        }
        // The pause as the card last heard it: reading the live one here
        // would redraw the chip on every sensor reading.
        if let reason = cardPause { return .paused(reason) }
        if !FoldCapturePermission.granted { return .limited("Wallpaper only") }
        return .on
    }


    /// The optional creak (`FoldHingeVoice`): it only listens to the
    /// readings the fold already takes.
    @ObservationIgnored private let hingeVoice = FoldHingeVoice()

    /// One reading to the voice. It plays only while the fold is on,
    /// JR-Bar renders it, and the room isn't hushed; otherwise any
    /// running engine stands down.
    private func voice(_ angle: Double, at t: TimeInterval) {
        let settings = settings
        let allowed = settings.enabled && settings.provider == .jrbar
            && settings.hingeVoice != .off && store?.hushReason() == nil
        guard allowed || hingeVoice.isRunning else { return }
        if !allowed { hingeVoice.stop(); return }
        hingeVoice.feed(angle: angle, at: t, voice: settings.hingeVoice, allowed: true)
    }

    /// The sensor's measured pace and whether capture is live. Bendy or
    /// Lid Plane rendering it costs them, not us — no line.
    func cost(at now: TimeInterval) -> String? {
        guard settings.provider == .jrbar else { return nil }
        // Counted on the sensor's queue: a lid at rest keeps its flicker
        // off the main thread, but every read still counts.
        let reads = sensor.readRate(at: now)
        return [
            reads < 0.5 ? "Lid sensor idle" : "Lid sensor \(Int(reads.rounded())) reads/s",
            "10 at rest, 120 near the fold",
            capture != nil ? "capturing now" : "capture only while folding",
        ].joined(separator: " · ")
    }

    /// Frames can come from somewhere: the capture with Screen Recording,
    /// or the wallpaper without it when the card allows.
    private var canFold: Bool {
        FoldCapturePermission.granted || settings.wallpaperFallback
    }

    /// Why the fold is parked right now, per the safety contract: closed
    /// lid (sensor ≤ 5° or real clamshell state), no built-in display,
    /// a mirrored one, a sleeping screen, a locked one, or another user
    /// switched in. Every input is a cached fact — IOKit and CoreGraphics
    /// queries on the per-frame path were the jitter the old engine
    /// could never ease away.
    private var pauseReason: String? {
        refreshDisplayFactsIfStale()
        return FoldPause.reason(
            angle: gateAngle,
            closedLid: cachedClamshell == true,
            builtInPresent: cachedBuiltinPresent,
            mirrored: cachedMirrored,
            screenAsleep: screenAsleep,
            screenLocked: screenLocked,
            sessionInactive: sessionInactive)
    }

    /// Re-reads the display-topology facts when the screen-parameters
    /// notification bumped `displayVersion`, or when the cache is more
    /// than two seconds old while something still wants it — a cheap
    /// query a few times a minute, never once a frame.
    private func refreshDisplayFactsIfStale() {
        let now = CACurrentMediaTime()
        guard displayVersion != cachedFactsVersion || now - cachedFactsAt > 2 else { return }
        cachedBuiltinPresent = FoldOverlayWindow.builtinDisplayID() != nil
        cachedMirrored = FoldOverlayWindow.builtinIsMirrored()
        cachedFactsVersion = displayVersion
        cachedFactsAt = now
    }

    /// The freshest truth for the activation gate: the simulation while
    /// held, else the raw sensor reading — never the predicted one, so a
    /// lead cannot open the overlay a hair early.
    private var gateAngle: Double? { simulatedAngle ?? rawAngle }

    /// What the fold amount reads: the tracker's smoothed angle (the
    /// simulation feeds it while held, so the slider glides too). Before
    /// the first accepted sample there is no estimate — fall back to the
    /// raw truth rather than the tracker's zero.
    private var renderAngle: Double? {
        tracker.primed ? tracker.angle : (simulatedAngle ?? rawAngle)
    }

    /// The number the "Lid angle" row prints — the measured truth.
    private var measuredAngle: Double? { simulatedAngle ?? rawAngle }

    // MARK: Engine

    /// One place that reads every input and makes the machine match:
    /// sensor polling while on and ours to render, `FoldArming` owning
    /// the streams (they exist only inside the arming band and through
    /// its cooldown, so the Screen Recording indicator only shows while
    /// a fold can be on screen), a half-second quiet before a paused
    /// fold comes back.
    private func reconcile() {
        let settings = settings
        jitter.tolerance = settings.jitterTolerance
        moveAnchor.tolerance = settings.jitterTolerance
        // Both looks arm on 3° of real travel down, so a nudge never
        // flashes the Screen Recording indicator, and neither does
        // tilting the screen back: neither look folds on the way up. The
        // Duo's tracker runs stiffer: the edge interpolator already
        // smooths what it chases.
        moveAnchor.armThreshold = max(3, settings.jitterTolerance)
        tracker.omega = isDuo ? 40 : 20
        overlay?.renderer.look = settings.look
        // Every path — off, parked, paused — leaves the vsync link
        // matching the machine; a parked fold runs no timer. The card
        // hears the outcome.
        defer {
            refreshTick()
            publishCard()
        }
        guard settings.enabled, settings.provider == .jrbar else {
            endBlackout(hide: true)
            edges.reset()
            catchUp.reset()
            paused = false
            resumeWork?.cancel()
            resumeWork = nil
            dwellWork?.cancel()
            dwellWork = nil
            dwellPaused = false
            dwellAnchor = nil
            arming.reset()
            scheduleCooldown(nil)
            tracker.reset()
            chase.reset()
            moveAnchor.reset()
            restGate.reset()
            displayedDelta = 0
            standDown()
            sensor.setPolling(false)
            return
        }
        // Inside this band the sensor polls at 120 Hz so a 10 Hz sensor
        // edge is timestamped to ±8 ms; above it the poll idles at the
        // sensor's own 10 Hz — dense where the fold lives, quiet where
        // it doesn't. Movement mode has no band: nothing consumes edge
        // timestamps any more (the slew tracker ticks on vsync dt), so
        // the poll stays at the sensor's own 10 Hz the whole time —
        // the idle-power floor. A pause parks the band the same way: a
        // sleeping or mirrored screen, or no built-in one, cannot show
        // a fold wherever the lid sits, and the pass that lifts the
        // pause restores the band as the resume quiet starts. A shut
        // lid the pump parks by itself, beat by beat, without waiting
        // for a pass here.
        // The Duo's movement fold is the exception: while it is armed the
        // poll runs 120 Hz so each edge the interpolator glides between is
        // timestamped to ±8 ms; parked, it idles at 10 Hz like the rest.
        sensor.armingAngle = pauseReason != nil ? -.infinity
            : settings.anchor == .angle ? settings.activationAngle + 12
            : (isDuo && arming.phase != .idle) ? .infinity : -.infinity
        // The sensor keeps polling while paused — its next reading is the
        // thing that tells us the lid reopened.
        sensor.setPolling(true)
        // A failed renderer re-arms past its cooldown rather than
        // staying benched for the app's lifetime: the flag lifts here
        // and the next arm attempt retries the init — if Metal is
        // still broken the attempt stamps the failure again and the
        // gate re-shuts for another cooldown.
        if rendererFailed,
           CACurrentMediaTime() - rendererFailedAt >= Self.rendererRetryCooldown {
            FoldLog.log.notice("renderer: retrying after cooldown")
            rendererFailed = false
        }
        guard !rendererFailed, canFold else {
            endBlackout(hide: true)
            arming.reset()
            scheduleCooldown(nil)
            standDown()
            noteDiag(stage: "armed-gate")
            return
        }
        if pauseReason != nil {
            // The Duo holds black across a close instead of flashing the
            // desktop on its way out; anything else lets go of it.
            if blackoutAllowed {
                holdBlackout()
                return
            }
            endBlackout(hide: true)
            // Pausing is immediate; only resuming debounces.
            paused = true
            resumeWork?.cancel()
            resumeWork = nil
            dwellWork?.cancel()
            dwellWork = nil
            dwellPaused = false
            dwellAnchor = nil
            arming.reset()
            scheduleCooldown(nil)
            catchUp.reset()
            chase.reset()
            moveAnchor.reset()
            displayedDelta = 0
            standDown()
            noteDiag(stage: "paused")
            return
        }
        if blackout.active && !isDuo {
            // The look changed under the hold: the Room has no blackout.
            endBlackout(hide: true)
        } else if blackout.active {
            // The lid is back above the closed line: the reopen gets its
            // own watchdog to land a frame and cross the release angle.
            blackout.note(angle: gateAngle, at: CACurrentMediaTime())
            scheduleBlackoutWatchdog()
        }
        if paused {
            // All clear: half a second of quiet before the fold comes
            // back, so a lid bouncing between reasons cannot flap the
            // overlay.
            guard resumeWork == nil else { return }
            let work = DispatchWorkItem { [weak self] in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    self.resumeWork = nil
                    self.paused = false
                    self.reconcile()
                }
            }
            resumeWork = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5, execute: work)
            return
        }
        // The arming machine decides whether the streams may exist —
        // inside the band, or lingering through its cooldown — and owns
        // the fold gate's hysteresis at the activation edge. Movement
        // mode arms on the first real move off the anchor instead: the
        // streams come up with the gesture's start, which is the warm-up
        // that keeps the first painted frame from being black. A reopen
        // from the black hold films at once, wherever the lid is and
        // whatever the fold measures from: a fresh frame is what lets it
        // unfold from black, and after it lets go the cooldown carries
        // the unwind.
        let outcome: FoldArming.Outcome
        if settings.anchor == .movement || blackout.active {
            let moving = blackout.active || (gateAngle.map { moveAnchor.moving($0) } ?? false)
            let lidShut = cachedClamshell == true
                || (gateAngle.map { $0 <= FoldPause.closedAngle } ?? false)
            outcome = arming.updateMovement(
                moving: moving, closed: lidShut, now: CACurrentMediaTime())
        } else {
            outcome = arming.update(
                angle: gateAngle,
                activation: settings.activationAngle,
                closed: cachedClamshell == true,
                now: CACurrentMediaTime())
        }
        scheduleCooldown(outcome.cooldownEndsAt)
        if outcome.capture {
            ensureCaptureRunning()
        } else {
            standDown()
        }
        // Dwell pause: parked mid-fold past `dwellTimeout`, the desktop
        // comes back until the hinge moves past the deadband. The gate
        // closing or any real move clears it — `dwellAnchor` keeps the
        // ±1° sensor wobble from counting as a move.
        if dwellPaused {
            let moved = gateAngle.flatMap { angle in
                dwellAnchor.map { abs(angle - $0) > max(settings.jitterTolerance, 2) }
            } ?? true
            if !outcome.capture || !arming.foldGateOpen || moved {
                dwellPaused = false
                dwellAnchor = nil
            }
        } else {
            let dwellSeconds = settings.dwellTimeout
            let dwellArmed = dwellSeconds > 0 && outcome.capture
                && arming.foldGateOpen && tracker.atRest && chase.atRest
                && targetDelta > 0.002
            if dwellArmed {
                // One pending timer per rest stretch — reconcile runs
                // per sensor sample inside the band, so re-arming every
                // pass would push the deadline out forever.
                if dwellWork == nil {
                    dwellAnchor = gateAngle
                    let work = DispatchWorkItem { [weak self] in
                        MainActor.assumeIsolated {
                            guard let self else { return }
                            self.dwellWork = nil
                            self.dwellPaused = true
                            // Movement mode: the parked angle re-seats
                            // the anchor — the desktop came back, and
                            // the next close folds from here.
                            if let parked = self.dwellAnchor {
                                self.moveAnchor.reseat(
                                    parked, at: CACurrentMediaTime())
                            }
                            self.reconcile()
                        }
                    }
                    dwellWork = work
                    DispatchQueue.main.asyncAfter(
                        deadline: .now() + dwellSeconds, execute: work)
                }
            } else {
                dwellWork?.cancel()
                dwellWork = nil
                dwellAnchor = nil
            }
        }
        if displayVersion != reframedVersion {
            overlay?.reframe()
            reframedVersion = displayVersion
        }
        noteDiag(stage: "reconcile")
    }

    /// The whole decision chain on one line, logged only on change —
    /// `arm` is the capture-lifecycle phase, `raw/render` the angles,
    /// then the delta chain, then frame/texture/overlay. A lid close
    /// should read armed→gate→delta growing→frame→tex→vis. The tick
    /// pass speaks at debug: `render` moves every display-link frame
    /// of a glide, so at notice it was ~30 persisted lines a second
    /// (2026-09-22: 655 of them in 30 min, gate shut, nothing on
    /// screen). `log stream --level debug` still shows every frame;
    /// the notice lines dedup against each other, so a change a tick
    /// saw first still reaches them on the next reconcile. They also
    /// leave the angles out of that dedup: an angle that moves while
    /// nothing else does is a wobble the filter held back, or a glide
    /// with the delta at 0 and nothing on screen — and a lid parked in
    /// the band reconciles on every 120 Hz sample. The reconcile pass
    /// speaks at debug too: it ran for every flicker of a resting lid,
    /// and its notice lines were 2.3 persisted lines a second
    /// (2026-09-25). The other stages — paused, blackout, the gate —
    /// are rare and stay at notice.
    ///
    /// The comparison is on numbers (`FoldDiagState`); the line is only
    /// written out when the log takes it.
    private func noteDiag(stage: String) {
        let state = FoldDiagState(
            enabled: settings.enabled, provider: settings.provider.rawValue, paused: paused,
            pause: pauseReason, target: Self.milli(targetDelta), shown: Self.milli(displayedDelta),
            phase: arming.phase, gate: arming.foldGateOpen,
            capture: capture == nil ? 0 : capture!.hasFrame ? 2 : 1,
            texture: overlay?.renderer.hasTexture ?? false, visible: overlay?.isVisible ?? false,
            link: tickLink != nil, blackout: blackout.active)
        let angles = diagAngles
        if stage == "tick" {
            if let last = lastDiag, last.state == state, last.angles == angles { return }
            lastDiag = (state, angles)
            guard FoldLog.debugEnabled else { return }
            let line = diagLine(state)
            FoldLog.log.debug("\(stage, privacy: .public) \(line, privacy: .public)")
        } else {
            guard state != lastNoticeDiag else { return }
            lastDiag = (state, angles)
            lastNoticeDiag = state
            if stage == "reconcile" {
                guard FoldLog.debugEnabled else { return }
                let line = diagLine(state)
                FoldLog.log.debug("\(stage, privacy: .public) \(line, privacy: .public)")
            } else {
                let line = diagLine(state)
                FoldLog.log.notice("\(stage, privacy: .public) \(line, privacy: .public)")
            }
        }
    }

    private static func milli(_ value: Double) -> Int {
        value.isFinite ? Int((value * 1000).rounded()) : Int.max
    }

    private static func tenths(_ value: Double?) -> Int? {
        value.flatMap { $0.isFinite ? Int(($0 * 10).rounded()) : nil }
    }

    /// The angles and the Duo's numbers, as the line prints them.
    private var diagAngles: FoldDiagAngles {
        let p = isDuo ? overlay?.renderer.params : nil
        return FoldDiagAngles(
            raw: gateAngle.flatMap { $0.isFinite ? Int($0.rounded()) : nil },
            render: Self.tenths(renderAngle),
            duo: isDuo,
            reference: isDuo ? Self.tenths(duoReference) : nil,
            motion: Int(((p?.motion ?? 0) * 100).rounded()),
            endFade: Int(((p?.endFade ?? 0) * 100).rounded()))
    }

    /// The line itself — built only when the log keeps it.
    private func diagLine(_ state: FoldDiagState) -> String {
        let raw = gateAngle.map { String(format: "%.0f", $0) } ?? "nil"
        let render = renderAngle.map { String(format: "%.1f", $0) } ?? "nil"
        let head = "en=\(state.enabled) prv=\(state.provider) "
            + "paused=\(state.paused) pause=\(state.pause ?? "-") "
        let angles = "raw=\(raw) render=\(render) " + duoDiag
        let cap = state.capture == 0 ? "nil" : state.capture == 2 ? "frame" : "wait"
        let tail = "target=\(String(format: "%.3f", targetDelta)) "
            + "disp=\(String(format: "%.3f", displayedDelta)) "
            + "arm=\(state.phase) gate=\(state.gate) "
            + "cap=\(cap) "
            + "tex=\(state.texture) vis=\(state.visible) "
            + "link=\(state.link) black=\(state.blackout)"
        return head + angles + tail
    }

    /// The Duo's numbers for the log: the look, the reference the fold
    /// measures from, the eased motion and the end fade — `m`, `θref`
    /// and `endFade` in the hand check. They ride with the angles, so
    /// they print on every notice line without deduping one on its own.
    private var duoDiag: String {
        guard isDuo else { return "look=room " }
        let p = overlay?.renderer.params
        let ref = duoReference.map { String(format: "%.1f", $0) } ?? "nil"
        let m = String(format: "%.2f", p?.motion ?? 0)
        let end = String(format: "%.2f", p?.endFade ?? 0)
        return "look=duo θref=\(ref) m=\(m) endFade=\(end) "
    }

    /// True while the Duo look is the one drawing.
    private var isDuo: Bool { settings.look == .duo }

    /// The Duo's edge interpolation runs on the real sensor only: the
    /// simulate slider and Try it are already smooth.
    private var smoothsEdges: Bool { isDuo && simulatedAngle == nil }

    /// Where the Duo's picture stays put: the resting angle the gesture
    /// started from, or the set angle.
    private var duoReference: Double? {
        settings.anchor == .movement ? moveAnchor.anchor : settings.activationAngle
    }

    /// The fold's travel in radians. The Room clamps at 1.25 rad, the arc
    /// its room is stable over; the Duo's geometry goes to black by
    /// itself, so its travel runs all the way to the deck.
    private func foldDelta(angle: Double, reference: Double) -> Double {
        guard isDuo else { return FoldMath.deltaRadians(angle: angle, reference: reference) }
        guard angle.isFinite, reference.isFinite, angle < reference else { return 0 }
        return (reference - max(0, angle)) * .pi / 180
    }

    /// The delta the fold wants right now — 0 when the gate is closed.
    /// The gate is `FoldArming`'s, fed the raw angle in `reconcile` with
    /// a degree of hysteresis so a sensor wobble on the line can never
    /// flick the fold; the delta itself rides the tracker's render
    /// angle, so the room counter-rotates by the hinge's own arc — and
    /// when the gate shuts mid-motion the chase unwinds the displayed
    /// delta home instead of snapping it.
    private var targetDelta: Double {
        guard arming.foldGateOpen, pauseReason == nil, !dwellPaused else { return 0 }
        if settings.anchor == .movement {
            // The streams arm on the first move; until the first
            // complete frame lands the delta holds at 0 — the capture
            // warm-up, so the room never opens black. The delta itself
            // is positive only: opening back through the anchor reads 0.
            guard capture?.hasFrame == true,
                  let reference = moveAnchor.anchor,
                  let angle = renderAngle ?? gateAngle else { return 0 }
            return foldDelta(angle: angle, reference: reference)
        }
        guard let angle = renderAngle ?? gateAngle else { return 0 }
        return foldDelta(angle: angle, reference: settings.activationAngle)
    }

    /// Starts or stops the vsync heartbeat to match the machine: armed
    /// means the fold could be or become visible — enabled, ours to
    /// render, permissioned, unpaused. A stopped link is not a parked
    /// fold; `reconcile` calls `tickFrame` once on every pass so a new
    /// sample is never a frame late.
    private func refreshTick() {
        let armed = settings.enabled && settings.provider == .jrbar && !paused
            && !rendererFailed && canFold && pauseReason == nil
        // The link exists only to move pixels: a parked fold — gate
        // shut, tracker settled — runs no timer at all. Without this
        // check the link was born and killed on every parked sensor
        // sample.
        let busy = targetDelta > 0 || displayedDelta > 0.002
            || !tracker.atRest || !chase.atRest || blackout.active
            || (smoothsEdges && !edges.settled(at: CACurrentMediaTime()))
        if armed && busy {
            if tickLink == nil {
                // On macOS the link comes from the screen it drives.
                let link = (FoldOverlayWindow.builtinScreen() ?? NSScreen.main)?
                    .displayLink(target: tickBox, selector: #selector(TickBox.tick))
                link?.add(to: .main, forMode: .common)
                tickLink = link
            }
            lastDeltaTick = CACurrentMediaTime()
            tickFrame()
        } else if let link = tickLink {
            link.invalidate()
            tickLink = nil
            // The blackout outlives the link: it is a flat clear with no
            // motion to tick, and it lets go on its own terms.
            if !blackout.active { hideOverlay() }
        }
    }

    /// One heartbeat: advance the tracker's slew-limited glide, read
    /// the delta off it, push the uniforms, and show or hide the
    /// overlay to match. Runs at the display's refresh while armed, so
    /// the fold's motion is the screen's own cadence — the sensor only
    /// moves the target.
    private func tickFrame() {
        let now = CACurrentMediaTime()
        defer { publishCard(now: now) }
        let dt = now - lastDeltaTick
        lastDeltaTick = now
        if smoothsEdges, let drawn = edges.value(at: now) { tracker.feed(drawn) }
        tracker.tick(dt: dt)
        refreshDisplayFactsIfStale()
        if blackout.active {
            // The reopen takes over from black once the lid is past the
            // release angle with a frame captured after the close.
            guard blackout.releases(angle: gateAngle, freshFrame: capture?.hasFrame == true) else {
                showBlackout()
                noteDiag(stage: "tick")
                return
            }
            FoldLog.log.notice("blackout: reopened, unfolding from black")
            endBlackout(hide: false)
            // The unfold starts from the last angle that still draws all
            // black, so the first frame matches the hold, and the chase
            // unwinds from there to the live lid.
            let reference = heldReference ?? duoReference ?? 110
            chase.reset(to: FoldDuoModel.reopenDelta(
                reference: reference, perspective: self.settings.perspective))
        }
        // The tracker's glide IS the easing while the lid moves; the
        // chase owns the rest — instant while the target grows, a damped
        // unwind when the gate snaps it to 0 mid-motion, so opening
        // counter-rotates back through the hinge instead of snapping.
        // A late first frame eases in over `FirstFrameCatchUp.duration`.
        displayedDelta = chase.tick(target: targetDelta * catchUp.scale(at: now), dt: dt)
        // Bendy's return click: the fold fully unwound after being up.
        if displayedDelta > 0.05 {
            foldWasUp = true
        } else if foldWasUp, displayedDelta <= 0.002 {
            foldWasUp = false
            if settings.restoreSound { NotchSounds.tick() }
        }
        let wantVisible = FoldMath.showsOverlay(
            delta: displayedDelta, hasFrame: capture?.hasFrame ?? false)
        noteDiag(stage: "tick")
        guard wantVisible else {
            hideOverlay()
            // A capture that stays frameless for seconds is dead on
            // arrival — a hung SCShareableContent fetch never throws, it
            // just never delivers. Recycle it, seconds apart, instead of
            // waiting on a stream that is not coming back.
            if let capture, !capture.hasFrame,
               now - captureBeganAt > 5, now - lastCaptureRecycle > 5 {
                lastCaptureRecycle = now
                self.capture = nil
                FoldLog.log.warning("capture: no frame in 5s — restarting stream")
                Task { await capture.stop() }
                ensureCaptureRunning()
            }
            // The link's only job is motion; fully at rest — gate shut,
            // the tracker settled and the unwind landed — it stands
            // down until the next reconcile arms it again.
            let glideDone = !smoothsEdges || edges.settled(at: now)
            if targetDelta == 0 && tracker.atRest && chase.atRest && glideDone, let link = tickLink {
                link.invalidate()
                tickLink = nil
            }
            return
        }
        let settings = settings
        let reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        if overlay == nil {
            guard now - lastOverlayAttempt > 0.5 else { return }
            lastOverlayAttempt = now
            guard ensureOverlay() != nil else { return }
        }
        if let overlay {
            overlay.renderer.look = settings.look
            if !overlay.isVisible { overlayShownAt = now }
            // `apply` writes only the animatable fields, so the upload's
            // imageSize/texAspect survive the per-tick pass.
            if isDuo {
                // The Duo: the picture held where the resting lid showed
                // it, the glass drawn at the reference minus the delta —
                // one reference per gesture, however the anchor moves.
                heldReference = FoldDuoModel.drawnReference(
                    held: heldReference, current: duoReference, overlayVisible: overlay.isVisible)
                // With no reference ever seen, a lid's usual rest.
                let reference = heldReference ?? 110
                FoldDuoModel.apply(to: &overlay.renderer.params, reference: reference,
                                   theta: reference - displayedDelta * 180 / .pi,
                                   hold: settings.holdStrength, perspective: settings.perspective,
                                   blur: settings.blur, shade: settings.shade,
                                   fadeLength: settings.fadeLength, reduceMotion: reduceMotion)
                // The first degrees fade the overlay in, and so does its
                // first 120 ms on screen — a late frame never pops.
                let ramp = FoldDuoModel.orderInRamp(elapsed: now - (overlayShownAt ?? now))
                overlay.alphaValue = CGFloat(Double(overlay.renderer.params.opacity) * ramp)
            } else {
                // The Room: Perspective, Blur, Shade and Frost are the
                // knobs. A switch back to the Duo takes a fresh reference.
                heldReference = nil
                FoldPortalModel.apply(to: &overlay.renderer.params,
                                      delta: displayedDelta,
                                      perspective: settings.perspective,
                                      blur: reduceMotion ? 0 : settings.blur,
                                      shade: settings.shade,
                                      frost: settings.frost,
                                      hold: settings.holdStrength,
                                      usedBuckets: overlay.renderer.usedBucketCount,
                                      reduceMotion: reduceMotion)
                // The activation-edge fade is the window's own alpha — a
                // crossfade under Reduce Motion, a materialize otherwise.
                overlay.alphaValue = CGFloat(overlay.renderer.params.opacity)
            }
            overlay.setVisible(true)
        }
    }

    /// Orders the overlay out and forgets when it came in.
    private func hideOverlay() {
        overlay?.setVisible(false)
        overlayShownAt = nil
    }

    // MARK: Blackout

    /// The Duo holds black across a close when the fold was on screen as
    /// the lid reached the closed line, and nothing says the person has
    /// stopped looking at this desktop: not asleep, locked or switched
    /// away, the built-in screen present and not mirrored.
    private var blackoutAllowed: Bool {
        guard isDuo, settings.enabled, settings.provider == .jrbar else { return false }
        let lidShut = cachedClamshell == true
            || (gateAngle.map { $0 <= FoldPause.closedAngle } ?? false)
        guard lidShut, !screenAsleep, !screenLocked, !sessionInactive,
              cachedBuiltinPresent, !cachedMirrored else { return false }
        return blackout.active || (overlay?.isVisible == true && displayedDelta > 0.002)
    }

    /// Hold black: capture stopped, the anchor kept (the reopen unfolds
    /// from the same resting lid), the overlay up as a flat clear.
    private func holdBlackout() {
        let now = CACurrentMediaTime()
        if !blackout.active {
            FoldLog.log.notice("blackout: holding black across the close")
            blackout.hold(at: now)
        }
        paused = true
        resumeWork?.cancel()
        resumeWork = nil
        dwellWork?.cancel()
        dwellWork = nil
        dwellPaused = false
        dwellAnchor = nil
        arming.reset()
        scheduleCooldown(nil)
        catchUp.reset()
        chase.reset()
        displayedDelta = 0
        stopCapture()
        showBlackout()
        scheduleBlackoutWatchdog()
        noteDiag(stage: "blackout")
    }

    /// The flat black frame, fully opaque.
    private func showBlackout() {
        guard let overlay else { return }
        FoldDuoModel.applyBlackout(to: &overlay.renderer.params)
        overlay.alphaValue = 1
        overlay.setVisible(true)
    }

    /// Let go of the black hold: ordered out (`hide`), or handed to the
    /// fold that takes over from black.
    private func endBlackout(hide: Bool) {
        guard blackout.active else { return }
        blackout.end()
        blackoutWork?.cancel()
        blackoutWork = nil
        overlay?.renderer.params.blackout = 0
        if hide { hideOverlay() }
    }

    /// The watchdog: a full-screen black window never outlives its
    /// deadline, whatever else happens.
    private func scheduleBlackoutWatchdog() {
        blackoutWork?.cancel()
        blackoutWork = nil
        guard blackout.active else { return }
        let delay = max(0, blackout.deadline - CACurrentMediaTime())
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.blackoutWork = nil
                guard self.blackout.expired(at: CACurrentMediaTime()) else {
                    self.scheduleBlackoutWatchdog()
                    return
                }
                FoldLog.log.notice("blackout: watchdog let go")
                self.expireBlackout()
                self.reconcile()
            }
        }
        blackoutWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }

    /// The watchdog's let-go: handed to the live fold with the overlay
    /// kept up when the lid is open again with a frame in hand (the fold
    /// draws black there too), ordered out otherwise.
    private func expireBlackout() {
        let handsOver = FoldBlackout.watchdogHandsOver(
            angle: gateAngle, drawing: !paused && pauseReason == nil,
            freshFrame: capture?.hasFrame == true)
        guard handsOver else {
            endBlackout(hide: true)
            return
        }
        FoldLog.log.notice("blackout: watchdog handed over to the fold")
        endBlackout(hide: false)
        let reference = heldReference ?? duoReference ?? 110
        chase.reset(to: FoldDuoModel.reopenDelta(
            reference: reference, perspective: self.settings.perspective))
    }

    private func ensureOverlay() -> FoldOverlayWindow? {
        if let overlay { return overlay }
        guard let screen = FoldOverlayWindow.builtinScreen() else { return nil }
        do {
            let overlay = try FoldOverlayWindow(screen: screen)
            overlay.renderer.look = settings.look
            overlay.renderer.setCards(lastCards)
            self.overlay = overlay
            reframedVersion = -1
            return overlay
        } catch {
            rendererFailed = true
            rendererFailedAt = CACurrentMediaTime()
            core.appendLocalLog(level: "error", "Fold can't start its renderer: \(error.localizedDescription)")
            return nil
        }
    }

    /// The streams run only while `FoldArming` says they may — inside
    /// the band or its cooldown — so the purple indicator never outlives
    /// a fold that could be on screen.
    private func ensureCaptureRunning() {
        // A wallpaper stand-in yields to the real capture the moment the
        // permission lands — the next arm films the windows too.
        if let current = capture, current is FoldWallpaperSource, FoldCapturePermission.granted {
            self.capture = nil
            Task { await current.stop() }
        }
        // The Duo runs one stream and the Room two: a look change swaps
        // the capture for the right shape.
        let dual = settings.look == .room
        if let current = capture as? FoldCapture, current.dual != dual {
            self.capture = nil
            Task { await current.stop() }
        }
        guard capture == nil else { return }
        let capture: any FoldFrameSource = FoldCapturePermission.granted
            ? FoldCapture(dual: dual) : FoldWallpaperSource()
        self.capture = capture
        captureBeganAt = CACurrentMediaTime()
        awaitingFirstFrame = true
        capture.onFullFrame = { [weak self, weak capture] buffer in
            // A stream already stopped may land one last frame: it is not
            // the fold's any more, and must not bring the picture back.
            guard let self, let capture, self.capture === capture,
                  let overlay = self.ensureOverlay() else { return }
            // Push once per delivered frame; a draw then costs one
            // triangle, not a texture conversion. The overlay is made
            // here, not at show time: on a static screen SCK may deliver
            // a single frame ever, and dropping it on a nil renderer is
            // how the overlay ordered in with no texture — painted clear,
            // invisible, for the whole fold.
            overlay.renderer.look = self.settings.look
            guard overlay.renderer.setFullFrame(buffer) else { return }
            if self.awaitingFirstFrame {
                self.awaitingFirstFrame = false
                self.noteFirstFrame()
            }
            self.tickFrame()
        }
        capture.onFarFrame = { [weak self] buffer in
            // The wallpaper-only far wall is the Room's nice-to-have half —
            // the renderer stands the full texture in until it lands. The
            // Duo has no far wall.
            guard let self, self.settings.look == .room else { return }
            _ = self.overlay?.renderer.setFarFrame(buffer)
        }
        capture.onCards = { [weak self] cards in
            guard let self else { return }
            self.lastCards = cards
            self.overlay?.renderer.setCards(cards)
        }
        capture.onError = { [weak self] message in
            // The stream died mid-run: drop it so the next reconcile
            // builds a fresh one rather than trusting a dead hasFrame.
            // A revoked grant kills streams this way, so the cached
            // preflight goes stale here — re-ask on the next read.
            FoldCapturePermission.invalidate()
            guard let self, let capture = self.capture else { return }
            self.capture = nil
            self.core.appendLocalLog(level: "error", "Fold capture stopped: \(message)")
            Task { await capture.stop() }
            self.noteDiag(stage: "capture-error")
            self.publishCard()
        }
        FoldLog.log.notice("capture: starting stream")
        Task { [weak self, weak capture] in
            do {
                try await capture?.start()
            } catch {
                FoldCapturePermission.invalidate()
                guard let self, self.capture === capture else { return }
                self.capture = nil
                FoldLog.log.error("capture: start failed: \(error.localizedDescription, privacy: .public)")
                self.core.appendLocalLog(level: "error", "Fold capture failed: \(error.localizedDescription)")
            }
        }
    }

    /// A cooling arming phase ends on a schedule, not a poll: the work
    /// item re-runs `reconcile` the moment the streams should die, and
    /// each pass replaces whatever was pending (nil just cancels).
    private func scheduleCooldown(_ until: TimeInterval?) {
        cooldownWork?.cancel()
        cooldownWork = nil
        guard let until else { return }
        let delay = max(0, until - CACurrentMediaTime())
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.cooldownWork = nil
                self.reconcile()
            }
        }
        cooldownWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }

    /// The movement Duo's first frame of a gesture: a quick close is
    /// already well in, so the displayed delta eases up to it. Not after
    /// a blackout — that fold unfolds from black, not from the desktop.
    private func noteFirstFrame() {
        guard isDuo, settings.anchor == .movement, !blackout.active else { return }
        catchUp.begin(liveDelta: targetDelta, at: CACurrentMediaTime())
    }

    /// Overlay off, capture stopped. The sensor is the caller's choice —
    /// a pause keeps it, off/external stops it.
    private func standDown() {
        hideOverlay()
        stopCapture()
        // Parked with no stream: the picture and the drawables go, until
        // the next capture brings a fresh frame. The black hold keeps its
        // overlay up.
        if !blackout.active { overlay?.releaseFrames() }
    }

    /// Capture stopped, the overlay left as it is — the blackout keeps
    /// its black frame up with nothing being recorded.
    private func stopCapture() {
        awaitingFirstFrame = false
        guard let capture else { return }
        self.capture = nil
        Task { await capture.stop() }
    }

    /// The raw reading always lands — `targetDelta` gates on it every
    /// tick, so a suppressed or extrapolated reading above the limit
    /// still drives the delta to zero and the overlay eases home on the
    /// same glide the simulate slider gets — then the filter and tracker
    /// decide what the fold does with it.
    private func noteSensorSample(_ sample: LidAngleSensor.Sample) {
        // The clamshell flag is the one pause input that changes on
        // this path with no trigger of its own — the angle reconciles
        // on accepted samples, the display facts through observed
        // versions — so a flip must reach reconcile whatever the
        // filter says of the reading it rode in on. A paused machine
        // is idle, so a rejected sample would otherwise drop the flip
        // and leave the fold paused under a chip that reads on.
        let clamshellChanged = sample.clamshell != nil && sample.clamshell != cachedClamshell
        // A lid at rest: its whole-degree flicker stops here, and the
        // sensor is told it may keep the next ones on its own queue.
        // Nothing in the machine could use them — see `FoldRestGate`.
        if let angle = sample.angle, simulatedAngle == nil, !clamshellChanged,
           !restGate.admits(angle, at: sample.at, idle: restingQuietly(at: sample.at),
                            insideArmingBand: angle <= sensor.armingAngle) {
            // The shared hinge signal stays fresh on the resting reading.
            store?.noteHinge(rawAngle ?? angle)
            sensor.quiet(around: restGate.center)
            return
        }
        sensor.quiet(around: nil)
        rawAngle = sample.angle
        // The shared hinge signal: published, never read back here.
        store?.noteHinge(sample.angle)
        if let angle = sample.angle, simulatedAngle == nil { voice(angle, at: sample.at) }
        if let clamshell = sample.clamshell { cachedClamshell = clamshell }
        guard let angle = sample.angle, simulatedAngle == nil else {
            if clamshellChanged { reconcile() }
            publishCard()
            return
        }
        if settings.anchor == .movement {
            // Stillness is the anchor's signal, so it sees every raw
            // sample — jitter-rejected ones included — while the filter
            // still guards what reaches the tracker. Reconcile runs on
            // every sample too: the 400 ms stillness boundary and the
            // first-move arm can't wait for an accepted edge.
            moveAnchor.feed(angle, at: sample.at)
            if jitter.accept(angle, at: sample.at) { feedTracker(angle, at: sample.at) }
            reconcile()
            return
        }
        guard jitter.accept(angle, at: sample.at) else {
            // Inside the band the machine still reads every raw sample:
            // the gate edge, the band exit and the dwell clock ride
            // reconcile, and a parked lid's deadband would otherwise
            // starve them a third of a second after it stops — before
            // the tracker lands, so the dwell never arms. Only the
            // tracker is spared the wobble. Parked above the band
            // (idle) the reading stops here, unless it carried a
            // clamshell flip.
            if arming.phase != .idle || clamshellChanged { reconcile() } else { publishCard() }
            return
        }
        feedTracker(angle, at: sample.at)
        reconcile()
    }

    /// Nothing a reading could change is live: ours to render and on,
    /// no simulation, no capture and nothing armed, the fold gate shut
    /// and nothing on screen, no pause, resume, dwell or blackout under
    /// way, and the hinge voice quiet. Only then may the rest gate hold
    /// readings back. The tracker and the edge glide may still be
    /// settling on the last reading that got through: they draw nothing
    /// with the gate shut, and the link stands down once they land. (A
    /// flicker the jitter filter lets through keeps them from ever
    /// settling, which is why settled cannot be the test.)
    private func restingQuietly(at now: TimeInterval) -> Bool {
        let settings = settings
        guard settings.enabled, settings.provider == .jrbar, simulatedAngle == nil, !tryingIt else { return false }
        guard !paused, resumeWork == nil, !blackout.active, !dwellPaused, dwellWork == nil else { return false }
        guard arming.phase == .idle, !arming.foldGateOpen, capture == nil,
              overlay?.isVisible != true, displayedDelta <= 0.002 else { return false }
        return !hingeVoice.isRunning
    }

    // MARK: The card

    /// Offers the card what it shows now: it lands at once, or when the
    /// last change's tenth of a second is up (`FoldCardFeed`), and only
    /// the fields that changed are written. Cheap to call on every pass:
    /// inside the tenth it only makes sure one flush is waiting.
    private func publishCard(now: TimeInterval = CACurrentMediaTime()) {
        let due = cardFeed.due(at: now)
        guard due <= now else {
            scheduleCardFlush(after: due - now)
            return
        }
        let reading = FoldCardFeed.Reading(angle: measuredAngle, detail: foldDetail, pause: pauseReason)
        guard let shown = cardFeed.land(reading, at: now) else { return }
        if shown.angle != cardAngle { cardAngle = shown.angle }
        if (shown.angle != nil) != cardHasAngle { cardHasAngle = shown.angle != nil }
        if shown.detail != cardDetail { cardDetail = shown.detail }
        if shown.pause != cardPause { cardPause = shown.pause }
    }

    private func scheduleCardFlush(after delay: TimeInterval) {
        guard cardFlush == nil else { return }
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.cardFlush = nil
                self.publishCard()
            }
        }
        cardFlush = work
        DispatchQueue.main.asyncAfter(deadline: .now() + max(0, delay), execute: work)
    }

    /// The slider's and Try it's writes run the machine on the next turn,
    /// once however many landed — as the observation of the angle did.
    private func scheduleReconcile() {
        guard !reconcileQueued else { return }
        reconcileQueued = true
        Task { @MainActor [weak self] in
            guard let self else { return }
            self.reconcileQueued = false
            self.reconcile()
        }
    }

    /// An accepted reading into the motion: through the edge
    /// interpolator in the Duo (the tick feeds the tracker from it),
    /// straight to the tracker in the Room.
    private func feedTracker(_ angle: Double, at t: TimeInterval) {
        if isDuo {
            edges.feed(angle, at: t)
        } else {
            tracker.feed(angle)
        }
    }

    /// One observation pass over every input, re-armed on each change —
    /// the same pattern `observeSessions` uses for the buddy.
    private func observe() {
        withObservationTracking {
            _ = store?.state.fold
            _ = sensor.available
            // rawAngle is deliberately NOT tracked: every suppressed poll
            // rewrites it, and a second, async reconcile per sample is
            // churn the machine does not need — the sample path calls
            // reconcile itself whenever a reading can matter (accepted,
            // or inside the band). The simulated angle's writes schedule
            // their own reconcile, and the card reads `cardAngle`.
            _ = screenAsleep
            _ = screenLocked
            _ = sessionInactive
            _ = displayVersion
            _ = motionVersion
            _ = workspaceVersion
            _ = permissionVersion
            _ = rendererFailed
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.reconcile()
                self.observe()
            }
        }
    }

    // MARK: Simulate

    /// While the slider is held its value is the lid angle; letting go
    /// hands the fold back to the sensor.
    var simulateBinding: Binding<Double> {
        Binding(
            get: { self.simulatedAngle ?? self.measuredAngle ?? 90 },
            set: {
                self.simulatedAngle = $0
                if !self.simulating { self.simulating = true }
                // The card's demo and the slider preview the voice too.
                self.voice($0, at: CACurrentMediaTime())
                // The tracker turns the slider's jumps into the same
                // capped glide the hinge gets.
                self.tracker.feed($0)
                if self.settings.anchor == .movement {
                    // The slider exercises the movement path too — a
                    // still drag end re-seats the anchor on its own.
                    self.moveAnchor.feed($0, at: CACurrentMediaTime())
                }
                self.scheduleReconcile()
                self.publishCard()
            })
    }

    // MARK: Try it

    /// True while the card's "Try it" demo plays.
    private(set) var tryingIt = false
    @ObservationIgnored private var tryTimer: Timer?

    /// Foldy's one-click demo: a scripted close and reopen fed through
    /// the simulate path at 60 Hz — the same tracker and chase the hinge
    /// drives — then the fold goes back to the sensor. A drag on the
    /// Simulate slider takes over from it.
    func tryIt() {
        guard !tryingIt else { return }
        // The demo folds from the fold's own reference: where the lid
        // rests, or the set angle.
        let resting = settings.anchor == .movement
        let reference = resting ? (moveAnchor.anchor ?? measuredAngle ?? 110) : settings.activationAngle
        let start = FoldTryIt.startAngle(current: measuredAngle, reference: reference,
                                         lead: resting ? 0 : FoldTryIt.setAngleLead)
        let began = CACurrentMediaTime()
        tryingIt = true
        simulateBinding.wrappedValue = start
        let timer = Timer(timeInterval: 1.0 / 60.0, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                let elapsed = CACurrentMediaTime() - began
                if let angle = FoldTryIt.angle(at: elapsed, start: start, reference: reference) {
                    self.simulateBinding.wrappedValue = angle
                } else {
                    self.stopTrying()
                }
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        tryTimer = timer
    }

    private func stopTrying() {
        tryTimer?.invalidate()
        tryTimer = nil
        guard tryingIt else { return }
        tryingIt = false
        endSimulate()
    }

    func endSimulate() {
        if tryingIt {
            // A hand on the slider ends the demo; the slider's own
            // release lands here again and hands the lid back.
            tryTimer?.invalidate()
            tryTimer = nil
            tryingIt = false
        }
        simulatedAngle = nil
        if simulating { simulating = false }
        restGate.reset()
        // The tracker's glide belongs to the real lid — a drag that
        // just jumped the angle 40° must not carry over.
        tracker.reset()
        edges.reset()
        catchUp.reset()
        moveAnchor.reset()
        if let raw = rawAngle {
            tracker.feed(raw)
            edges.feed(raw, at: CACurrentMediaTime())
        }
        reconcile()
    }

    /// "104°" while anything is driving the angle, "no sensor" on a Mac
    /// without the hinge, "—" for a sensor that has not read yet (the
    /// poll only runs while the toy is on). The card shows it for
    /// `cardAngle`.
    nonisolated static func angleText(_ angle: Double?, sensorAvailable: Bool) -> String {
        if let angle { return "\(Int(angle.rounded()))°" }
        return sensorAvailable ? "—" : "no sensor"
    }

    /// What the fold is doing right now, or the first link in the chain
    /// that is missing — the card's truth row for "nothing is
    /// happening". Reads unobserved engine state; the card refreshes on
    /// the sensor cadence, which is plenty.
    var foldDetail: String {
        _ = workspaceVersion
        _ = permissionVersion
        guard settings.provider == .jrbar else { return "Handed off" }
        // The black hold rides out the closed-lid pause, so it speaks first.
        if blackout.active { return "Holding black across the close" }
        if let reason = pauseReason { return "Paused — \(reason)" }
        guard canFold else { return "Waiting for Screen Recording" }
        if rendererFailed { return "Renderer failed to start" }
        if let lastError = capture?.lastError { return "Capture stopped — \(lastError)" }
        let tilted = displayedDelta * 180 / .pi
        guard tilted > 0.1 else {
            if settings.anchor == .movement {
                return "Parked — the next move folds from here"
            }
            return "Parked — close the lid past \(Int(settings.activationAngle.rounded()))°"
        }
        if capture?.hasFrame != true { return "Tilted \(Int(tilted))° — waiting for a screen frame" }
        if overlay?.renderer.hasTexture != true { return "Tilted \(Int(tilted))° — frames not reaching the GPU" }
        return overlay?.isVisible == true ? "Holding \(Int(tilted))° of tilt" : "Tilted \(Int(tilted))° — overlay hidden"
    }

    // MARK: External providers

    /// Bendy ships no published bundle id, so it is read from the app's
    /// own Info.plist when the app is in /Applications — honest, and a
    /// renamed install still resolves.
    var bendyURL: URL? {
        _ = workspaceVersion
        let path = URL(fileURLWithPath: "/Applications/Bendy.app")
        guard let id = Bundle(url: path)?.bundleIdentifier else { return nil }
        return NSWorkspace.shared.urlForApplication(withBundleIdentifier: id) ?? path
    }

    /// Lid Plane's bundle id, from its repo's Info.plist.
    var lidPlaneURL: URL? {
        _ = workspaceVersion
        return NSWorkspace.shared.urlForApplication(withBundleIdentifier: "dev.jhey.lidplane")
    }

    /// The picker's write path: choosing an external renderer parks ours
    /// and opens that app; JR-Bar just hands the fold back to `reconcile`.
    func setProvider(_ provider: FoldProvider) {
        store?.state.fold.provider = provider
        store?.save()
        guard provider != .jrbar else {
            // Handing the render back to us is a fresh ask — a stale
            // failure must not outlive the switch.
            rendererFailed = false
            reconcile()
            return
        }
        paused = false
        resumeWork?.cancel()
        resumeWork = nil
        arming.reset()
        scheduleCooldown(nil)
        endBlackout(hide: true)
        tracker.reset()
        edges.reset()
        catchUp.reset()
        chase.reset()
        moveAnchor.reset()
        restGate.reset()
        displayedDelta = 0
        standDown()
        sensor.setPolling(false)
        refreshTick()
        let url = provider == .bendy ? bendyURL : lidPlaneURL
        if let url {
            NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration()) { _, _ in }
        }
    }

    /// Settings deep link for the Screen Recording row.
    func openScreenRecordingSettings() {
        NSWorkspace.shared.open(FoldCapturePermission.settingsURL)
    }

    /// The "Allow Screen Recording" button: the system prompt, then a
    /// re-check on the next activate.
    func requestScreenRecording() {
        FoldCapturePermission.request()
        reconcile()
    }

    // MARK: Controls

    /// A binding into `store.state.fold`; the store's `didSet` debounces
    /// the write so a dragged slider does not stream file saves.
    func bind<T>(_ keyPath: WritableKeyPath<FoldSettings, T>) -> Binding<T> {
        Binding(
            get: { self.store?.state.fold[keyPath: keyPath] ?? FoldSettings()[keyPath: keyPath] },
            set: { self.store?.state.fold[keyPath: keyPath] = $0 })
    }

    var providerBinding: Binding<FoldProvider> {
        Binding(
            get: { self.store?.state.fold.provider ?? .jrbar },
            set: { self.setProvider($0) })
    }

    var controls: AnyView {
        AnyView(FoldControlsView(toy: self))
    }
}

/// The lid seen from the side: the deck, the hinge, the lid at the
/// measured angle with its screen lit along the inside face, and — in
/// "Set angle" mode — the fold's zone swept out from the deck up to
/// where the fold starts, so where the fold begins reads at a glance.
/// The glyph tilts along while the sensor or a demo moves it; with no
/// reading the lid stands as a faint dashed ghost. Drawn in whatever
/// frame it is given.
struct FoldLidGlyph: View {
    let angle: Double?
    let activation: Double?

    /// The lid's far end for an opening `degrees` (0 shut on the deck,
    /// 90 upright, past that leaning back), from a hinge at `hinge`.
    nonisolated static func lidEnd(hinge: CGPoint, length: Double, degrees: Double) -> CGPoint {
        let radians = min(180, max(0, degrees)) * .pi / 180
        return CGPoint(x: hinge.x + length * cos(radians), y: hinge.y - length * sin(radians))
    }

    var body: some View {
        Canvas { context, size in
            for mark in Self.marks(in: size, angle: angle, activation: activation) {
                let base = mark.ink == .accent ? Color.accentColor : Color.primary
                let shading = GraphicsContext.Shading.color(base.opacity(mark.opacity))
                if let stroke = mark.stroke {
                    context.stroke(Path(mark.path), with: shading, style: stroke)
                } else {
                    context.fill(Path(mark.path), with: shading)
                }
            }
        }
        .accessibilityHidden(true)
    }

    /// One stroke or fill of the glyph, in the frame's own points (y
    /// down): the Canvas above and the Settings card's layers
    /// (`FoldLidLayerView`) draw the same list.
    struct Mark {
        enum Ink { case primary, accent }
        let path: CGPath
        let ink: Ink
        let opacity: Double
        /// nil fills the path.
        let stroke: StrokeStyle?
    }

    /// The glyph for a frame of `size`: the fold zone in "Set angle"
    /// mode, the deck, then the lid (or its dashed ghost with no
    /// reading) with its lit screen and the hinge.
    nonisolated static func marks(in size: CGSize, angle: Double?, activation: Double?) -> [Mark] {
        var marks: [Mark] = []
        let unit = min(size.width / 44, size.height / 26)
        let hinge = CGPoint(x: size.width * 0.36, y: size.height - 3 * unit)
        let lidLength = Double(size.height) - 7 * unit
        if let activation {
            // The fold zone: shut up to the start angle.
            let radius = lidLength + 3 * unit
            let sweep = Angle.degrees(-min(180, max(0, activation)))
            var wedge = Path()
            wedge.move(to: hinge)
            wedge.addArc(center: hinge, radius: radius, startAngle: .degrees(0), endAngle: sweep, clockwise: true)
            wedge.closeSubpath()
            marks.append(Mark(path: wedge.cgPath, ink: .accent, opacity: 0.1, stroke: nil))
            var rim = Path()
            rim.addArc(center: hinge, radius: radius, startAngle: .degrees(0), endAngle: sweep, clockwise: true)
            marks.append(Mark(path: rim.cgPath, ink: .accent, opacity: 0.45,
                              stroke: StrokeStyle(lineWidth: max(0.8, unit * 0.6), dash: [2 * unit, 1.6 * unit])))
            let tick = lidEnd(hinge: hinge, length: radius, degrees: activation)
            let dot = 1.6 * unit
            let knob = CGRect(x: tick.x - dot, y: tick.y - dot, width: dot * 2, height: dot * 2)
            marks.append(Mark(path: CGPath(ellipseIn: knob, transform: nil), ink: .accent, opacity: 1, stroke: nil))
        }
        // The deck: the keyboard half, with a lit top edge.
        let deck = CGMutablePath()
        deck.move(to: hinge)
        deck.addLine(to: CGPoint(x: size.width - 2 * unit, y: hinge.y))
        marks.append(Mark(path: deck, ink: .primary, opacity: 0.4,
                          stroke: StrokeStyle(lineWidth: 2.6 * unit, lineCap: .round)))
        marks.append(Mark(path: deck, ink: .primary, opacity: 0.18,
                          stroke: StrokeStyle(lineWidth: 0.7 * unit, lineCap: .round)))
        // The lid, or its ghost while there is no reading.
        let degrees = angle ?? 105
        let end = lidEnd(hinge: hinge, length: lidLength, degrees: degrees)
        let lid = CGMutablePath()
        lid.move(to: hinge)
        lid.addLine(to: end)
        guard angle != nil else {
            marks.append(Mark(path: lid, ink: .primary, opacity: 0.25,
                              stroke: StrokeStyle(lineWidth: 1.4 * unit, lineCap: .round, dash: [2.4 * unit, 2 * unit])))
            return marks
        }
        marks.append(Mark(path: lid, ink: .primary, opacity: 0.85,
                          stroke: StrokeStyle(lineWidth: 2.2 * unit, lineCap: .round)))
        // The screen along the lid's inside face, glowing faintly.
        let radians = min(180, max(0, degrees)) * .pi / 180
        let inset = CGSize(width: sin(radians) * 1.9 * unit, height: cos(radians) * 1.9 * unit)
        let screen = CGMutablePath()
        screen.move(to: CGPoint(x: hinge.x + inset.width + (end.x - hinge.x) * 0.12,
                                y: hinge.y + inset.height + (end.y - hinge.y) * 0.12))
        screen.addLine(to: CGPoint(x: end.x + inset.width - (end.x - hinge.x) * 0.06,
                                   y: end.y + inset.height - (end.y - hinge.y) * 0.06))
        marks.append(Mark(path: screen, ink: .accent, opacity: 0.25,
                          stroke: StrokeStyle(lineWidth: 3 * unit, lineCap: .round)))
        marks.append(Mark(path: screen, ink: .accent, opacity: 1,
                          stroke: StrokeStyle(lineWidth: 0.9 * unit, lineCap: .round)))
        // The hinge itself.
        let knuckle = 1.5 * unit
        let pin = CGRect(x: hinge.x - knuckle, y: hinge.y - knuckle, width: knuckle * 2, height: knuckle * 2)
        marks.append(Mark(path: CGPath(ellipseIn: pin, transform: nil), ink: .primary, opacity: 0.7, stroke: nil))
        return marks
    }
}

/// The login session's two facts the fold pauses on, read once at
/// launch from the window server's session dictionary (no permission
/// needed); after that the lock broadcasts and the workspace's session
/// notifications keep them current.
enum FoldSessionState {
    static let lockedNotification = Notification.Name("com.apple.screenIsLocked")
    static let unlockedNotification = Notification.Name("com.apple.screenIsUnlocked")

    static func current() -> (locked: Bool, onConsole: Bool) {
        guard let info = CGSessionCopyCurrentDictionary() as? [String: Any] else {
            return (false, true)
        }
        return parse(info)
    }

    /// Pure, for the tests: a missing key reads as the unlocked,
    /// on-console session — a guess that pauses would bench the fold for
    /// the life of the app.
    static func parse(_ info: [String: Any]) -> (locked: Bool, onConsole: Bool) {
        let locked = (info["CGSSessionScreenIsLocked"] as? Bool)
            ?? ((info["CGSSessionScreenIsLocked"] as? NSNumber)?.boolValue ?? false)
        let onConsole = (info[kCGSessionOnConsoleKey as String] as? Bool)
            ?? ((info[kCGSessionOnConsoleKey as String] as? NSNumber)?.boolValue ?? true)
        return (locked, onConsole)
    }
}

/// The card's disclosure body: the lid at the top, live — its angle,
/// what the fold is doing, and Try it — then the rows in runs: the look
/// and where it folds from, how it looks, how it sounds, the simulator,
/// and who renders it. Rows that only one look uses show for that look
/// alone (Frost is the Room's, "Goes dark over" the Duo's). Every row
/// writes `store.state.fold` (which persists itself) except the
/// provider picker, which goes through `setProvider` so the swap can
/// stop our renderer and open theirs.
private struct FoldControlsView: View {
    let toy: FoldToy
    @Environment(SettingsStore.self) private var settingsStore: SettingsStore?

    private var duo: Bool { toy.settings.look == .duo }

    /// The row a Settings search just landed on in this card. A row the
    /// other look owns is drawn for it, switched off and saying which
    /// look has it, so the search never lands on nothing.
    private var searchedRow: String? {
        guard let hit = settingsStore?.searchHit, hit.card == "fold" else { return nil }
        return hit.title
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            hero
            Divider().padding(.vertical, 6)

            Picker(selection: toy.bind(\.look)) {
                Text("Duo").tag(FoldLook.duo)
                Text("Room").tag(FoldLook.room)
            } label: {
                SettingLabel(title: "Look", subtitle: lookSubtitle)
            }
            .pickerStyle(.menu)

            Picker(selection: toy.bind(\.anchor)) {
                Text("Set angle").tag(FoldAnchor.angle)
                Text("Wherever the lid rests").tag(FoldAnchor.movement)
            } label: {
                SettingLabel(title: "Fold from", subtitle: "A fixed angle, or wherever the lid was parked when it started to move.")
            }
            .pickerStyle(.menu)

            sliderRow(SettingLabel(title: "Starts folding at",
                                   subtitle: startSubtitle),
                      value: toy.bind(\.activationAngle), range: 60...160,
                      readout: "\(Int(toy.settings.activationAngle.rounded()))°")
                .disabled(toy.settings.anchor == .movement)

            sliderRow(SettingLabel(title: "Release when parked",
                                   subtitle: "Seconds a lid held mid-fold waits before the desktop comes back — until the hinge moves again."),
                      value: toy.bind(\.dwellTimeout), range: 0...10, step: 1,
                      readout: toy.settings.dwellTimeout == 0 ? "Off" : "\(Int(toy.settings.dwellTimeout))s")

            sliderRow(SettingLabel(title: "Jitter",
                                   subtitle: "Ignore angle wobbles smaller than this."),
                      value: toy.bind(\.jitterTolerance), range: 0...5, step: 0.5,
                      readout: degrees(toy.settings.jitterTolerance))

            Divider().padding(.vertical, 6)

            sliderRow(SettingLabel(title: "Perspective", subtitle: perspectiveSubtitle),
                      value: toy.bind(\.perspective), range: 0...1, readout: percent(toy.settings.perspective))
            sliderRow(SettingLabel(title: "Shade", subtitle: shadeSubtitle),
                      value: toy.bind(\.shade), range: 0...1, readout: percent(toy.settings.shade))
            sliderRow(SettingLabel(title: "Blur", subtitle: blurSubtitle),
                      value: toy.bind(\.blur), range: 0...1, readout: percent(toy.settings.blur))
            if duo {
                fadeLengthRow(owned: true)
                if searchedRow == "Frost" { frostRow(owned: false) }
            } else {
                frostRow(owned: true)
                if searchedRow == "Goes dark over" { fadeLengthRow(owned: false) }
            }

            sliderRow(SettingLabel(title: "Hold picture in place",
                                   subtitle: "How still the desktop stays while the lid tilts over it: 100% keeps it where you saw it, 0% glues it to the glass."),
                      value: toy.bind(\.holdStrength), range: 0...1,
                      readout: percent(toy.settings.holdStrength))

            Divider().padding(.vertical, 6)

            Toggle(isOn: toy.bind(\.restoreSound)) {
                SettingLabel(title: "Click on return", subtitle: "A quiet Tink when the fold unwinds all the way.")
            }

            Picker(selection: toy.bind(\.hingeVoice)) {
                Text("Off").tag(HingeVoice.off)
                Text("Creak").tag(HingeVoice.creak)
                Text("Paper rustle").tag(HingeVoice.rustle)
            } label: {
                SettingLabel(title: "Hinge voice", subtitle: "The lid's own speed plays it: a slow close creaks, a quick one stays quiet. Silent while JR-Bar is quiet.")
            }
            .pickerStyle(.menu)

            LabeledContent {
                HStack(spacing: 10) {
                    Slider(value: toy.simulateBinding, in: 0...160) { editing in
                        if !editing { toy.endSimulate() }
                    }
                    .frame(width: 180)
                    // Read only while a simulation plays: the lid's own
                    // readings never redraw the card.
                    ValueText(text: toy.simulating ? degrees(toy.cardAngle ?? 0) : "—")
                }
            } label: {
                SettingLabel(title: "Simulate a fold", subtitle: "Pretends the lid is moving while you drag.")
            }

            Divider().padding(.vertical, 6)

            Picker(selection: toy.providerBinding) {
                Text("JR-Bar").tag(FoldProvider.jrbar)
                Text("Bendy").tag(FoldProvider.bendy)
                Text("Lid Plane").tag(FoldProvider.lidPlane)
            } label: {
                SettingLabel(title: "Render with", subtitle: "Let Bendy or Lid Plane draw the fold instead.")
            }
            .pickerStyle(.menu)

            providerNote

            Toggle(isOn: toy.bind(\.wallpaperFallback)) {
                SettingLabel(title: "Wallpaper without Screen Recording",
                             subtitle: "With no permission, the wallpaper alone folds — same motion, just no windows.")
            }

            if toy.isOn && !FoldCapturePermission.granted {
                HStack(spacing: 8) {
                    Button("Allow Screen Recording") { toy.requestScreenRecording() }
                    Button("Open Settings") { toy.openScreenRecordingSettings() }
                }
                .padding(.top, 4)
            }
        }
    }

    /// The Duo's "Goes dark over"; drawn off in the Room only for a
    /// search that landed on it.
    private func fadeLengthRow(owned: Bool) -> some View {
        let subtitle = owned
            ? "How much of the close the picture takes to go soft and dark. 55% is the iPhone Duo's own: done by half-closed."
            : "Only the Duo look goes dark over the close. Set Look to Duo to use it."
        return sliderRow(SettingLabel(title: "Goes dark over", subtitle: subtitle),
                         value: toy.bind(\.fadeLength), range: FoldSettings.fadeLengthRange,
                         readout: percent(toy.settings.fadeLength), live: owned)
    }

    /// The Room's Frost; drawn off in the Duo only for a search that
    /// landed on it.
    private func frostRow(owned: Bool) -> some View {
        let subtitle = owned
            ? "How milky the cover is — 0 is a black room, higher reads as frosted plastic."
            : "Only the Room look has a cover to frost. Set Look to Room to use it."
        return sliderRow(SettingLabel(title: "Frost", subtitle: subtitle),
                         value: toy.bind(\.frost), range: 0...1,
                         readout: percent(toy.settings.frost), live: owned)
    }

    private var lookSubtitle: String {
        "Duo holds your desktop still while the glass folds through it, going soft and dark "
            + "away from the hinge like the iPhone Duo. Room folds it into a lit room of window cards."
    }

    private var startSubtitle: String {
        duo ? "The lid angle the picture holds at. Set it near where your lid rests."
            : "The lid angle where the tilt begins."
    }

    private var perspectiveSubtitle: String {
        duo ? "Where your eyes are: lower sits further back and keeps the fold flatter, higher leans in."
            : "How much the far edge tapers, like a real tilted plane."
    }

    private var shadeSubtitle: String {
        duo ? "How dark the picture goes away from the hinge. The hinge side always stays bright."
            : "How dark the room goes toward the hinge and the far wall."
    }

    private var blurSubtitle: String {
        duo ? "How soft the picture goes away from the hinge; the hinge stays sharp. Never under Reduce Motion."
            : "How much the room defocuses — deeper layers and the far edge soften first. Never under Reduce Motion."
    }

    /// The card's head: the lid drawn large on its own tile, live, beside
    /// its angle, what the fold is doing right now, and the one-click
    /// demo. The lid and the angle follow the sensor in AppKit
    /// (`FoldLiveLid`, `FoldLiveAngle`), so a moving lid redraws them and
    /// not the Toys page; the state line changes with the fold's state.
    private var hero: some View {
        HStack(alignment: .center, spacing: 16) {
            FoldLiveLid(toy: toy,
                        activation: toy.settings.anchor == .angle ? toy.settings.activationAngle : nil)
                .frame(width: 118, height: 70)
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                .background(RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(Color.primary.opacity(0.045)))
                .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .strokeBorder(Color.primary.opacity(0.07), lineWidth: 0.5))
            VStack(alignment: .leading, spacing: 6) {
                SettingLabel(title: "Lid angle", subtitle: "Live, from the hinge sensor.")
                FoldLiveAngle(toy: toy)
                Text(toy.cardDetail)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityLabel("Fold state: \(toy.cardDetail)")
                Button(toy.tryingIt ? "Folding…" : "Try it") { toy.tryIt() }
                    .controlSize(.regular)
                    .disabled(toy.tryingIt || !toy.isOn || toy.settings.provider != .jrbar)
                    .help("Plays one close and reopen through the fold, no lid needed.")
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, 4)
    }

    /// One slider row: the label, the slider and its readout. A row
    /// that is not `live` greys its slider and keeps its words readable,
    /// since they say why.
    private func sliderRow(_ label: SettingLabel, value: Binding<Double>,
                           range: ClosedRange<Double>, step: Double? = nil,
                           readout: String, live: Bool = true) -> some View {
        LabeledContent {
            HStack(spacing: 10) {
                if let step {
                    Slider(value: value, in: range, step: step)
                        .frame(width: 180)
                } else {
                    Slider(value: value, in: range)
                        .frame(width: 180)
                }
                ValueText(text: readout)
            }
            .disabled(!live)
        } label: {
            label
        }
    }

    /// What the chosen external renderer is doing — installed and
    /// launched, or a link to get it.
    @ViewBuilder
    private var providerNote: some View {
        switch toy.settings.provider {
        case .jrbar:
            EmptyView()
        case .bendy:
            externalNote(installed: toy.bendyURL != nil, name: "Bendy",
                         link: URL(string: "https://trybendy.app/")!)
        case .lidPlane:
            externalNote(installed: toy.lidPlaneURL != nil, name: "Lid Plane",
                         link: URL(string: "https://github.com/jh3y/lid-plane")!)
        }
    }

    private func externalNote(installed: Bool, name: String, link: URL) -> some View {
        HStack(spacing: 8) {
            Text(installed ? "\(name) is installed" : "\(name) isn't installed")
                .font(.callout)
                .foregroundStyle(.secondary)
            if !installed {
                Link("Get \(name)", destination: link)
                    .font(.callout)
            }
        }
    }

    private func percent(_ value: Double) -> String {
        "\(Int((value * 100).rounded()))%"
    }

    private func degrees(_ value: Double) -> String {
        value == value.rounded() ? "\(Int(value))°" : String(format: "%.1f°", value)
    }
}

/// The display link's target — CADisplayLink needs an NSObject with an
/// @objc selector, so the toy's `tickFrame` rides inside a closure.
private final class TickBox: NSObject {
    var onTick: () -> Void = {}
    @objc func tick() { onTick() }
}

/// The machine's state as `noteDiag` compares it: the notice line's
/// fields, with the deltas in thousandths as the line prints them.
struct FoldDiagState: Equatable {
    var enabled: Bool
    var provider: String
    var paused: Bool
    var pause: String?
    var target: Int
    var shown: Int
    var phase: FoldArming.Phase
    var gate: Bool
    /// 0 no capture, 1 waiting for a frame, 2 has one.
    var capture: Int
    var texture: Bool
    var visible: Bool
    var link: Bool
    var blackout: Bool
}

/// The angles a tick line adds, rounded as the line prints them.
struct FoldDiagAngles: Equatable {
    var raw: Int?
    var render: Int?
    var duo: Bool
    var reference: Int?
    var motion: Int
    var endFade: Int
}
