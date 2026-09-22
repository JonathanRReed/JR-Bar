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
}

/// Fold (docs/TOYS.md): the desktop is a portal — a lit room seen
/// through the screen — and closing the lid reads as the UI continuing
/// INTO the display, the iPhone Duo animation. The pieces stay small:
/// `LidAngleSensor` reads the hinge, `FoldArming` decides when the
/// ScreenCaptureKit streams may exist (inside the arming band, plus a
/// short cooldown, so the purple indicator only shows while a fold can
/// be on screen), `FoldCapture` grabs the built-in display twice — the
/// full desktop and the wallpaper-only far wall — plus the window-card
/// layout, `SlewTracker` turns the 10 Hz integer sensor into a capped,
/// overshoot-free glide, `DeltaChase` unwinds the displayed delta when
/// the gate snaps it to 0 mid-motion, and `FoldRenderer` composites
/// the frosted cover's room into the click-through `FoldOverlayWindow`.
/// Render can also be handed to
/// Bendy or Lid Plane; then all of this stays parked.
@MainActor
@Observable
final class FoldToy: Toy {
    let core: CoreModel
    /// The owning store; weak, the store keeps the toy.
    weak var store: ToysStore?

    /// The hinge. Polls only while the toy is on and JR-Bar is rendering.
    let sensor = LidAngleSensor()

    /// The Simulate slider owns the angle while it is held, so the toy
    /// works on a Mac with no lid sensor at all.
    private(set) var simulatedAngle: Double?
    /// The newest raw sensor reading, jitter unfiltered — the activation
    /// gate checks this so a predicted lead can never open the overlay
    /// early, and a filtered straggler can never hold it open above the
    /// limit.
    private(set) var rawAngle: Double?
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
    @ObservationIgnored private var capture: FoldCapture?
    @ObservationIgnored private var observers: [NSObjectProtocol] = []
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
    /// The last diagnostic line logged — the log only speaks when the
    /// machine's state actually changes, so a parked fold stays silent.
    @ObservationIgnored private var lastDiag = ""
    /// The last notice line's dedup key, angles left out — see
    /// `noteDiag`.
    @ObservationIgnored private var lastNoticeDiag = ""

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
        if !sensor.available && simulatedAngle == nil {
            return .unavailable("No lid-angle sensor on this Mac")
        }
        if !FoldCapturePermission.granted { return .needsPermission("Needs Screen Recording") }
        if let reason = pauseReason { return .paused(reason) }
        return .on
    }

    /// Why the fold is parked right now, per the safety contract: closed
    /// lid (sensor ≤ 5° or real clamshell state), no built-in display,
    /// a mirrored one, or a sleeping screen. Every input is a cached
    /// fact — IOKit and CoreGraphics queries on the per-frame path were
    /// the jitter the old engine could never ease away.
    private var pauseReason: String? {
        refreshDisplayFactsIfStale()
        return FoldPause.reason(
            angle: gateAngle,
            closedLid: cachedClamshell == true,
            builtInPresent: cachedBuiltinPresent,
            mirrored: cachedMirrored,
            screenAsleep: screenAsleep)
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
        // Every path — off, parked, paused — leaves the vsync link
        // matching the machine; a parked fold runs no timer.
        defer { refreshTick() }
        guard settings.enabled, settings.provider == .jrbar else {
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
        sensor.armingAngle = (settings.anchor == .movement || pauseReason != nil)
            ? -.infinity : settings.activationAngle + 12
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
        guard !rendererFailed, FoldCapturePermission.granted else {
            arming.reset()
            scheduleCooldown(nil)
            standDown()
            noteDiag(stage: "armed-gate")
            return
        }
        if pauseReason != nil {
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
            chase.reset()
            moveAnchor.reset()
            displayedDelta = 0
            standDown()
            noteDiag(stage: "paused")
            return
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
        // that keeps the first painted frame from being black.
        let outcome: FoldArming.Outcome
        if settings.anchor == .movement {
            let moving = gateAngle.map { moveAnchor.moving($0) } ?? false
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
    /// the band reconciles on every 120 Hz sample.
    private func noteDiag(stage: String) {
        let raw = gateAngle.map { String(format: "%.0f", $0) } ?? "nil"
        let render = renderAngle.map { String(format: "%.1f", $0) } ?? "nil"
        // Dedup on the state only — the stage prefix differs between the
        // reconcile and tick passes, and comparing it would print both
        // sides of every unchanged frame.
        let head = "en=\(settings.enabled) prv=\(settings.provider.rawValue) "
            + "paused=\(paused) pause=\(pauseReason ?? "-") "
        let angles = "raw=\(raw) render=\(render) "
        let tail = "target=\(String(format: "%.3f", targetDelta)) "
            + "disp=\(String(format: "%.3f", displayedDelta)) "
            + "arm=\(arming.phase) gate=\(arming.foldGateOpen) "
            + "cap=\(capture == nil ? "nil" : capture!.hasFrame ? "frame" : "wait") "
            + "tex=\(overlay?.renderer.hasTexture ?? false) vis=\(overlay?.isVisible ?? false) "
            + "link=\(tickLink != nil)"
        let state = head + angles + tail
        if stage == "tick" {
            guard state != lastDiag else { return }
            lastDiag = state
            FoldLog.log.debug("\(stage, privacy: .public) \(state, privacy: .public)")
        } else {
            let key = head + tail
            guard key != lastNoticeDiag else { return }
            lastDiag = state
            lastNoticeDiag = key
            FoldLog.log.notice("\(stage, privacy: .public) \(state, privacy: .public)")
        }
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
            return FoldMath.deltaRadians(angle: angle, reference: reference)
        }
        guard let angle = renderAngle ?? gateAngle else { return 0 }
        return FoldMath.deltaRadians(
            angle: angle, reference: settings.activationAngle)
    }

    /// Starts or stops the vsync heartbeat to match the machine: armed
    /// means the fold could be or become visible — enabled, ours to
    /// render, permissioned, unpaused. A stopped link is not a parked
    /// fold; `reconcile` calls `tickFrame` once on every pass so a new
    /// sample is never a frame late.
    private func refreshTick() {
        let armed = settings.enabled && settings.provider == .jrbar && !paused
            && !rendererFailed && FoldCapturePermission.granted && pauseReason == nil
        // The link exists only to move pixels: a parked fold — gate
        // shut, tracker settled — runs no timer at all. Without this
        // check the link was born and killed on every parked sensor
        // sample.
        let busy = targetDelta > 0 || displayedDelta > 0.002
            || !tracker.atRest || !chase.atRest
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
            overlay?.setVisible(false)
        }
    }

    /// One heartbeat: advance the tracker's slew-limited glide, read
    /// the delta off it, push the uniforms, and show or hide the
    /// overlay to match. Runs at the display's refresh while armed, so
    /// the fold's motion is the screen's own cadence — the sensor only
    /// moves the target.
    private func tickFrame() {
        let now = CACurrentMediaTime()
        let dt = now - lastDeltaTick
        lastDeltaTick = now
        tracker.tick(dt: dt)
        refreshDisplayFactsIfStale()
        // The tracker's glide IS the easing while the lid moves; the
        // chase owns the rest — instant while the target grows, a damped
        // unwind when the gate snaps it to 0 mid-motion, so opening
        // counter-rotates back through the hinge instead of snapping.
        displayedDelta = chase.tick(target: targetDelta, dt: dt)
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
            overlay?.setVisible(false)
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
            if targetDelta == 0 && tracker.atRest && chase.atRest, let link = tickLink {
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
            // One style — the portal: Perspective, Blur, Shade and
            // Frost are the knobs. `apply` writes only the animatable
            // fields, so the upload's imageSize/texAspect survive the
            // per-tick pass.
            FoldPortalModel.apply(to: &overlay.renderer.params,
                                  delta: displayedDelta,
                                  perspective: settings.perspective,
                                  blur: reduceMotion ? 0 : settings.blur,
                                  shade: settings.shade,
                                  frost: settings.frost,
                                  holdPicture: settings.holdPicture,
                                  usedBuckets: overlay.renderer.usedBucketCount,
                                  reduceMotion: reduceMotion)
            // The activation-edge fade is the window's own alpha — a
            // crossfade under Reduce Motion, a materialize otherwise.
            overlay.alphaValue = CGFloat(overlay.renderer.params.opacity)
            overlay.setVisible(true)
        }
    }

    private func ensureOverlay() -> FoldOverlayWindow? {
        if let overlay { return overlay }
        guard let screen = FoldOverlayWindow.builtinScreen() else { return nil }
        do {
            let overlay = try FoldOverlayWindow(screen: screen)
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
        guard capture == nil else { return }
        let capture = FoldCapture()
        self.capture = capture
        captureBeganAt = CACurrentMediaTime()
        capture.onFullFrame = { [weak self] buffer in
            guard let self else { return }
            // Push once per delivered frame; a draw then costs one
            // triangle, not a texture conversion. The overlay is made
            // here, not at show time: on a static screen SCK may deliver
            // a single frame ever, and dropping it on a nil renderer is
            // how the overlay ordered in with no texture — painted clear,
            // invisible, for the whole fold.
            if self.ensureOverlay()?.renderer.setFullFrame(buffer) ?? false {
                self.tickFrame()
            }
        }
        capture.onFarFrame = { [weak self] buffer in
            // The wallpaper-only far wall is the nice-to-have half — the
            // renderer stands the full texture in until it lands.
            _ = self?.overlay?.renderer.setFarFrame(buffer)
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

    /// Overlay off, capture stopped. The sensor is the caller's choice —
    /// a pause keeps it, off/external stops it.
    private func standDown() {
        overlay?.setVisible(false)
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
        rawAngle = sample.angle
        // The clamshell flag is the one pause input that changes on
        // this path with no trigger of its own — the angle reconciles
        // on accepted samples, the display facts through observed
        // versions — so a flip must reach reconcile whatever the
        // filter says of the reading it rode in on. A paused machine
        // is idle, so a rejected sample would otherwise drop the flip
        // and leave the fold paused under a chip that reads on.
        let clamshellChanged = sample.clamshell != nil && sample.clamshell != cachedClamshell
        if let clamshell = sample.clamshell { cachedClamshell = clamshell }
        guard let angle = sample.angle, simulatedAngle == nil else {
            if clamshellChanged { reconcile() }
            return
        }
        if settings.anchor == .movement {
            // Stillness is the anchor's signal, so it sees every raw
            // sample — jitter-rejected ones included — while the filter
            // still guards what reaches the tracker. Reconcile runs on
            // every sample too: the 400 ms stillness boundary and the
            // first-move arm can't wait for an accepted edge.
            moveAnchor.feed(angle, at: sample.at)
            if jitter.accept(angle, at: sample.at) { tracker.feed(angle) }
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
            if arming.phase != .idle || clamshellChanged { reconcile() }
            return
        }
        tracker.feed(angle)
        reconcile()
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
            // or inside the band), and the card's own view observes
            // rawAngle for the live reading.
            _ = simulatedAngle
            _ = screenAsleep
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
                // The tracker turns the slider's jumps into the same
                // capped glide the hinge gets.
                self.tracker.feed($0)
                if self.settings.anchor == .movement {
                    // The slider exercises the movement path too — a
                    // still drag end re-seats the anchor on its own.
                    self.moveAnchor.feed($0, at: CACurrentMediaTime())
                }
            })
    }

    func endSimulate() {
        simulatedAngle = nil
        // The tracker's glide belongs to the real lid — a drag that
        // just jumped the angle 40° must not carry over.
        tracker.reset()
        moveAnchor.reset()
        if let raw = rawAngle {
            tracker.feed(raw)
        }
        reconcile()
    }

    /// "104°" while anything is driving the angle, "no sensor" on a Mac
    /// without the hinge, "—" for a sensor that has not read yet (the
    /// poll only runs while the toy is on).
    var angleText: String {
        if let angle = measuredAngle { return "\(Int(angle.rounded()))°" }
        return sensor.available ? "—" : "no sensor"
    }

    /// What the fold is doing right now, or the first link in the chain
    /// that is missing — the card's truth row for "nothing is
    /// happening". Reads unobserved engine state; the card refreshes on
    /// the sensor cadence, which is plenty.
    var foldDetail: String {
        _ = workspaceVersion
        _ = permissionVersion
        guard settings.provider == .jrbar else { return "Handed off" }
        if let reason = pauseReason { return "Paused — \(reason)" }
        guard FoldCapturePermission.granted else { return "Waiting for Screen Recording" }
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
        tracker.reset()
        chase.reset()
        moveAnchor.reset()
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

/// The card's disclosure body. Every row writes `store.state.fold` (which
/// persists itself) except the provider picker, which goes through
/// `setProvider` so the swap can stop our renderer and open theirs.
private struct FoldControlsView: View {
    let toy: FoldToy

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Picker(selection: toy.bind(\.anchor)) {
                Text("Set angle").tag(FoldAnchor.angle)
                Text("Wherever the lid rests").tag(FoldAnchor.movement)
            } label: {
                SettingLabel(title: "Fold from", subtitle: "A fixed angle, or wherever the lid was parked when it started to move.")
            }
            .pickerStyle(.menu)
            .fixedSize()

            LabeledContent {
                HStack(spacing: 10) {
                    Slider(value: toy.bind(\.activationAngle), in: 60...160)
                        .frame(width: 180)
                        .disabled(toy.settings.anchor == .movement)
                    ValueText(text: "\(Int(toy.settings.activationAngle.rounded()))°")
                }
            } label: {
                SettingLabel(title: "Starts folding at", subtitle: "The lid angle where the tilt begins.")
            }

            LabeledContent {
                HStack(spacing: 10) {
                    Slider(value: toy.bind(\.perspective), in: 0...1)
                        .frame(width: 180)
                    ValueText(text: percent(toy.settings.perspective))
                }
            } label: {
                SettingLabel(title: "Perspective", subtitle: "How much the far edge tapers, like a real tilted plane.")
            }

            LabeledContent {
                HStack(spacing: 10) {
                    Slider(value: toy.bind(\.shade), in: 0...1)
                        .frame(width: 180)
                    ValueText(text: percent(toy.settings.shade))
                }
            } label: {
                SettingLabel(title: "Shade", subtitle: "How dark the room goes toward the hinge and the far wall.")
            }

            LabeledContent {
                HStack(spacing: 10) {
                    Slider(value: toy.bind(\.blur), in: 0...1)
                        .frame(width: 180)
                    ValueText(text: percent(toy.settings.blur))
                }
            } label: {
                SettingLabel(title: "Blur", subtitle: "How much the room defocuses — deeper layers and the far edge soften first. Never under Reduce Motion.")
            }

            LabeledContent {
                HStack(spacing: 10) {
                    Slider(value: toy.bind(\.frost), in: 0...1)
                        .frame(width: 180)
                    ValueText(text: percent(toy.settings.frost))
                }
            } label: {
                SettingLabel(title: "Frost", subtitle: "How milky the cover is — 0 is a black room, higher reads as frosted plastic.")
            }

            LabeledContent {
                Toggle("", isOn: toy.bind(\.holdPicture))
                    .labelsHidden()
            } label: {
                SettingLabel(title: "Hold picture in place", subtitle: "The desktop stays put while the lid tilts over it; off keeps the picture glued to the glass.")
            }

            LabeledContent {
                HStack(spacing: 10) {
                    Slider(value: toy.bind(\.jitterTolerance), in: 0...5, step: 0.5)
                        .frame(width: 180)
                    ValueText(text: degrees(toy.settings.jitterTolerance))
                }
            } label: {
                SettingLabel(title: "Jitter", subtitle: "Ignore angle wobbles smaller than this.")
            }

            LabeledContent {
                HStack(spacing: 10) {
                    Slider(value: toy.bind(\.dwellTimeout), in: 0...10, step: 1)
                        .frame(width: 180)
                    ValueText(text: toy.settings.dwellTimeout == 0
                              ? "Off" : "\(Int(toy.settings.dwellTimeout))s")
                }
            } label: {
                SettingLabel(title: "Release when parked", subtitle: "Seconds a lid held mid-fold waits before the desktop comes back — until the hinge moves again.")
            }

            LabeledContent {
                Toggle("", isOn: toy.bind(\.restoreSound))
                    .labelsHidden()
            } label: {
                SettingLabel(title: "Click on return", subtitle: "A quiet Tink when the fold unwinds all the way.")
            }

            LabeledContent {
                HStack(spacing: 10) {
                    Slider(value: toy.simulateBinding, in: 0...160) { editing in
                        if !editing { toy.endSimulate() }
                    }
                    .frame(width: 180)
                    ValueText(text: toy.simulatedAngle.map { degrees($0) } ?? "—")
                }
            } label: {
                SettingLabel(title: "Simulate a fold", subtitle: "Pretends the lid is moving while you drag.")
            }

            LabeledContent {
                Text(toy.angleText)
                    .font(.callout)
                    .foregroundStyle(.secondary)
            } label: {
                SettingLabel(title: "Lid angle", subtitle: "Live, from the hinge sensor.")
            }

            LabeledContent {
                Text(toy.foldDetail)
                    .font(.callout)
                    .foregroundStyle(.secondary)
            } label: {
                SettingLabel(title: "Fold state", subtitle: "What the fold is doing right now.")
            }

            Picker(selection: toy.providerBinding) {
                Text("JR-Bar").tag(FoldProvider.jrbar)
                Text("Bendy").tag(FoldProvider.bendy)
                Text("Lid Plane").tag(FoldProvider.lidPlane)
            } label: {
                SettingLabel(title: "Render with", subtitle: "Let Bendy or Lid Plane draw the fold instead.")
            }
            .pickerStyle(.menu)
            .fixedSize()

            providerNote

            if toy.isOn && !FoldCapturePermission.granted {
                HStack(spacing: 8) {
                    Button("Allow Screen Recording") { toy.requestScreenRecording() }
                    Button("Open Settings") { toy.openScreenRecordingSettings() }
                }
            }
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
