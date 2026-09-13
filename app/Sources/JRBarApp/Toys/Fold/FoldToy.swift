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

/// Fold (docs/TOYS.md): the desktop tilts, dims and blurs as the lid
/// comes down, like it is holding its angle in the room. The pieces stay
/// small: `LidAngleSensor` reads the hinge, `FoldCapture` grabs the
/// built-in display, `FoldRenderer` warps it into the click-through
/// `FoldOverlayWindow`. While the toy is armed the capture stays live —
/// only the overlay hides above the activation angle, so crossing it
/// never restarts a stream. Render can also be handed to Bendy or Lid
/// Plane; then all of this stays parked.
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
    /// Once Metal or the shader fails we stop trying: the chip keeps
    /// saying why instead of retrying a compile every frame.
    private(set) var rendererFailed = false
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
    /// The edge tracker: the hinge sensor only changes every ~100 ms,
    /// so instead of smoothing a high-rate stream it dead-reckons each
    /// sensor edge — `renderAngle` is the edge plus a bounded velocity
    /// extrapolation, `velocity` feeds the motion blur. Fed on accepted
    /// samples, ticked on every vsync.
    @ObservationIgnored private var tracker = LidTracker()
    @ObservationIgnored private var overlay: FoldOverlayWindow?

    /// True while the fold plane is on screen — overlay guests like the
    /// island use it to let clicks fall through glass they can't see.
    var overlayOnScreen: Bool { overlay?.isVisible == true }
    @ObservationIgnored private var capture: FoldCapture?
    @ObservationIgnored private var observers: [NSObjectProtocol] = []
    /// The smoothed delta the renderer is showing — sensor readings
    /// step, the fold glides at the display's own rate because the
    /// display link, not the sensor, carries the easing between samples.
    @ObservationIgnored private var displayedDelta = 0.0
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
    /// The last diagnostic line logged — the log only speaks when the
    /// machine's state actually changes, so a parked fold stays silent.
    @ObservationIgnored private var lastDiag = ""

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
            MainActor.assumeIsolated { self?.permissionVersion += 1 }
        })

        sensor.onSample = { [weak self] angle in self?.noteSensorSample(angle) }
        tickBox.onTick = { [weak self] in
            MainActor.assumeIsolated { self?.tickFrame() }
        }
        observe()
    }

    let id = "fold"
    let name = "Fold"
    let blurb = "Your desktop tilts & blurs as the lid comes down."
    let symbol = "laptopcomputer"

    var isOn: Bool {
        get { store?.state.fold.enabled ?? false }
        set {
            store?.state.fold.enabled = newValue
            store?.save()
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

    /// What the fold amount reads: the simulation while held, else the
    /// tracker's render angle — the edge plus its bounded extrapolation.
    private var renderAngle: Double? { simulatedAngle ?? tracker.renderAngle }

    /// The number the "Lid angle" row prints — the measured truth, not
    /// the lead. A lead of a few degrees belongs to the glass, not the UI.
    private var measuredAngle: Double? { simulatedAngle ?? rawAngle }

    // MARK: Engine

    /// One place that reads every input and makes the machine match:
    /// sensor polling while on and ours to render, capture live while
    /// unpaused (it survives the activation line — restarting the stream
    /// on every threshold crossing was the stutter), a half-second quiet
    /// before a paused fold comes back.
    private func reconcile() {
        let settings = settings
        jitter.tolerance = settings.jitterTolerance
        // Every path — off, parked, paused — leaves the vsync link
        // matching the machine; a parked fold runs no timer.
        defer { refreshTick() }
        guard settings.enabled, settings.provider == .jrbar else {
            paused = false
            resumeWork?.cancel()
            resumeWork = nil
            displayedDelta = 0
            tracker.reset()
            standDown()
            sensor.setPolling(false)
            return
        }
        // Inside this band the sensor polls at 120 Hz so a 10 Hz sensor
        // edge is timestamped to ±8 ms; above it the poll idles at the
        // sensor's own 10 Hz — dense where the fold lives, quiet where
        // it doesn't.
        sensor.armingAngle = settings.activationAngle + 12
        // The sensor keeps polling while paused — its next reading is the
        // thing that tells us the lid reopened.
        sensor.setPolling(true)
        guard !rendererFailed, FoldCapturePermission.granted else {
            standDown()
            noteDiag(stage: "armed-gate")
            return
        }
        if pauseReason != nil {
            // Pausing is immediate; only resuming debounces.
            paused = true
            resumeWork?.cancel()
            resumeWork = nil
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
        ensureCaptureRunning()
        if displayVersion != reframedVersion {
            overlay?.reframe()
            reframedVersion = displayVersion
        }
        noteDiag(stage: "reconcile")
    }

    /// The whole decision chain on one line, logged only on change —
    /// `armed/busy` are the link's terms, `raw/render` the angles, then
    /// the delta chain, then frame/texture/overlay. A lid close should
    /// read armed→busy→delta growing→frame→tex→vis.
    private func noteDiag(stage: String) {
        let raw = gateAngle.map { String(format: "%.0f", $0) } ?? "nil"
        let render = renderAngle.map { String(format: "%.1f", $0) } ?? "nil"
        // Dedup on the state only — the stage prefix differs between the
        // reconcile and tick passes, and comparing it would print both
        // sides of every unchanged frame.
        let state = "en=\(settings.enabled) prv=\(settings.provider.rawValue) "
            + "paused=\(paused) pause=\(pauseReason ?? "-") "
            + "raw=\(raw) render=\(render) target=\(String(format: "%.3f", targetDelta)) "
            + "disp=\(String(format: "%.3f", displayedDelta)) "
            + "cap=\(capture == nil ? "nil" : capture!.hasFrame ? "frame" : "wait") "
            + "tex=\(overlay?.renderer.hasTexture ?? false) vis=\(overlay?.isVisible ?? false) "
            + "link=\(tickLink != nil)"
        guard state != lastDiag else { return }
        lastDiag = state
        FoldLog.log.notice("\(stage, privacy: .public) \(state, privacy: .public)")
    }

    /// The delta the fold wants right now, from the freshest truth — 0
    /// when the gate is closed, so easing home is also how the overlay
    /// leaves. The gate reads the raw angle (an extrapolated lead can
    /// never activate early); the delta itself rides the tracker's
    /// render angle and is the REAL lid travel, so the held plane
    /// counter-rotates by the hinge's own arc.
    private var targetDelta: Double {
        guard let gate = gateAngle,
              FoldMath.allows(rawAngle: gate, activation: settings.activationAngle),
              pauseReason == nil else { return 0 }
        return FoldMath.deltaRadians(
            angle: renderAngle ?? gate, reference: settings.activationAngle)
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
        // shut and the ease finished — runs no timer at all. Without
        // this check the link was born and killed on every parked
        // sensor sample.
        let busy = targetDelta > 0 || displayedDelta > 0.002
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
            displayedDelta = 0
            overlay?.setVisible(false)
        }
    }

    /// One heartbeat: advance the tracker's dead reckoning, ease the
    /// delta toward its target, push the uniforms, and show or hide the
    /// overlay to match. Runs at the display's refresh while armed, so
    /// the fold's motion is the screen's own cadence — the sensor only
    /// moves the target.
    private func tickFrame() {
        let now = CACurrentMediaTime()
        let dt = now - lastDeltaTick
        lastDeltaTick = now
        tracker.tick(dt: dt, at: now)
        refreshDisplayFactsIfStale()
        displayedDelta = FoldMath.smoothed(current: displayedDelta, target: targetDelta, dt: dt)
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
            // The link's only job is motion; fully at rest — gate shut
            // and the ease finished — it stands down until the next
            // reconcile arms it again.
            if targetDelta == 0 && displayedDelta <= 0.002, let link = tickLink {
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
            let styleBlur: Double = switch settings.style {
            case .tilt: 0
            case .dusk: settings.blur * 0.45   // Dusk keeps a light matte
            case .fog: settings.blur
            }
            let blur = reduceMotion ? Float(0) : Float(styleBlur)
            let boost = reduceMotion ? Float(0) : FoldToy.velocityBlurBoost(tracker.velocity)
            // Adaptive disc density, keyed on the shader's own peak
            // radius (the disc is widest at the far edge): sparse while
            // the matte is thin, dense when it is wide.
            let peakRadius = (blur * 65 + boost) * Float(sin(displayedDelta))
            let samples: Float = peakRadius <= 6 ? 12 : peakRadius <= 20 ? 20 : 32
            overlay.renderer.params.delta = Float(displayedDelta)
            overlay.renderer.params.blurStrength = blur
            overlay.renderer.params.motionBoost = boost
            overlay.renderer.params.dimStrength = settings.style == .tilt ? 0
                : Float(settings.shade)
            overlay.renderer.params.persp = Float(settings.perspective)
            overlay.renderer.params.samples = samples
            overlay.setVisible(true)
        }
    }

    /// Velocity-aware blur, in radius units: dead-zoned under 30°/s so
    /// hinge noise at rest adds nothing, and clamped so even a slammed
    /// lid smears instead of washing out.
    static func velocityBlurBoost(_ velocity: Double) -> Float {
        let speed = abs(velocity)
        guard speed > 30 else { return 0 }
        return Float(min((speed - 30) * 0.02, 12))
    }

    private func ensureOverlay() -> FoldOverlayWindow? {
        if let overlay { return overlay }
        guard let screen = FoldOverlayWindow.builtinScreen() else { return nil }
        do {
            let overlay = try FoldOverlayWindow(screen: screen)
            self.overlay = overlay
            reframedVersion = -1
            return overlay
        } catch {
            rendererFailed = true
            core.appendLocalLog(level: "error", "Fold can't start its renderer: \(error.localizedDescription)")
            return nil
        }
    }

    /// The stream runs while the toy is enabled and unpaused — hiding
    /// above the activation angle costs nothing but the frames.
    private func ensureCaptureRunning() {
        guard capture == nil else { return }
        let capture = FoldCapture()
        self.capture = capture
        captureBeganAt = CACurrentMediaTime()
        capture.onFrame = { [weak self] buffer in
            guard let self else { return }
            // Push once per delivered frame; a draw then costs one
            // triangle, not a texture conversion. The overlay is made
            // here, not at show time: on a static screen SCK may deliver
            // a single frame ever, and dropping it on a nil renderer is
            // how the overlay ordered in with no texture — painted clear,
            // invisible, for the whole fold.
            if self.ensureOverlay()?.renderer.setDesktopFrame(buffer) ?? false {
                self.tickFrame()
            }
        }
        capture.onError = { [weak self] message in
            // The stream died mid-run: drop it so the next reconcile
            // builds a fresh one rather than trusting a dead hasFrame.
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
                guard let self, self.capture === capture else { return }
                self.capture = nil
                FoldLog.log.error("capture: start failed: \(error.localizedDescription, privacy: .public)")
                self.core.appendLocalLog(level: "error", "Fold capture failed: \(error.localizedDescription)")
            }
        }
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
        if let clamshell = sample.clamshell { cachedClamshell = clamshell }
        guard let angle = sample.angle, simulatedAngle == nil,
              jitter.accept(angle, at: sample.at) else { return }
        tracker.feed(angle, at: sample.at)
        reconcile()
    }

    /// One observation pass over every input, re-armed on each change —
    /// the same pattern `observeSessions` uses for the buddy.
    private func observe() {
        withObservationTracking {
            _ = store?.state.fold
            _ = sensor.available
            // rawAngle is deliberately NOT tracked: every suppressed poll
            // rewrites it, and a reconcile per 120 Hz sample is churn the
            // machine does not need — accepted samples call reconcile
            // themselves, and the card's own view observes rawAngle for
            // the live reading.
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
            set: { self.simulatedAngle = $0 })
    }

    func endSimulate() {
        simulatedAngle = nil
        // The tracker's extrapolation belongs to the real lid — a drag
        // that just jumped the angle 40° must not carry it.
        tracker.reset()
        if let raw = rawAngle {
            tracker.feed(raw, at: CACurrentMediaTime())
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
            reconcile()
            return
        }
        paused = false
        resumeWork?.cancel()
        resumeWork = nil
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
            Picker(selection: toy.bind(\.style)) {
                Text("Tilt").tag(FoldStyle.tilt)
                Text("Dusk").tag(FoldStyle.dusk)
                Text("Fog").tag(FoldStyle.fog)
            } label: {
                SettingLabel(title: "Style", subtitle: "Tilt only warps; Dusk dims; Fog blurs.")
            }
            .pickerStyle(.segmented)

            LabeledContent {
                HStack(spacing: 10) {
                    Slider(value: toy.bind(\.activationAngle), in: 60...160)
                        .frame(width: 180)
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
                SettingLabel(title: "Shade", subtitle: "How dark it goes toward the top. Dusk & Fog.")
            }

            LabeledContent {
                HStack(spacing: 10) {
                    Slider(value: toy.bind(\.blur), in: 0...1)
                        .frame(width: 180)
                    ValueText(text: percent(toy.settings.blur))
                }
            } label: {
                SettingLabel(title: "Blur", subtitle: "The fog toward the top. Fog only, & never under Reduce Motion.")
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
