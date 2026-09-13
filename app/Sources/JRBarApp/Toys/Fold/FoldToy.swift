import AppKit
import CoreVideo
import JRBarCore
import Observation
import QuartzCore
import SwiftUI

/// Fold (docs/TOYS.md): the desktop tilts, dims and blurs as the lid
/// comes down, like it is holding its angle in the room. The pieces stay
/// small: `LidAngleSensor` reads the hinge, `FoldCapture` grabs the
/// built-in display, `FoldRenderer` warps it into the click-through
/// `FoldOverlayWindow`. When the fold amount is 0 the overlay is ordered
/// out and nothing — not even the capture — is running. Render can also
/// be handed to Bendy or Lid Plane; then all of this stays parked.
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
    /// gate checks this so a filtered straggler can never hold the
    /// overlay open above the limit.
    private(set) var rawAngle: Double?
    /// The last sensor reading the jitter filter let through.
    private(set) var filteredAngle: Double?
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
    @ObservationIgnored private var overlay: FoldOverlayWindow?
    @ObservationIgnored private var capture: FoldCapture?
    @ObservationIgnored private var observers: [NSObjectProtocol] = []
    /// The smoothed radians past the anchor the renderer is showing —
    /// sensor readings step at 30 Hz, the fold should glide.
    @ObservationIgnored private var displayedDelta = 0.0
    @ObservationIgnored private var lastDeltaTick: TimeInterval = 0
    /// The displayParameters version the overlay was last framed for.
    @ObservationIgnored private var reframedVersion = -1
    /// Set when a safety input parked us; only a resume from here waits
    /// the half-second quiet — a first fold starts right away.
    @ObservationIgnored private var paused = false
    /// The half-second "all clear" before a paused fold resumes.
    @ObservationIgnored private var resumeWork: DispatchWorkItem?

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
    /// a mirrored one, or a sleeping screen.
    private var pauseReason: String? {
        _ = displayVersion
        return FoldPause.reason(
            angle: effectiveAngle,
            // The registry's own answer — the daemon's `closed_lid.holding`
            // is the keep-awake assertion instead, which stays armed
            // whenever agents are working and would park the fold on an
            // open lid.
            closedLid: ClamshellState.read() == true,
            builtInPresent: FoldOverlayWindow.builtinDisplayID() != nil,
            mirrored: FoldOverlayWindow.builtinIsMirrored(),
            screenAsleep: screenAsleep)
    }

    /// The freshest truth for the activation gate: the simulation while
    /// held, else the raw sensor reading — never the filtered one, so a
    /// suppressed sample cannot hold the overlay open above the limit.
    private var gateAngle: Double? { simulatedAngle ?? rawAngle }

    /// What drives the fold amount: the simulation while held, else the
    /// jitter-filtered reading.
    private var effectiveAngle: Double? { simulatedAngle ?? filteredAngle }

    // MARK: Engine

    /// One place that reads every input and makes the machine match:
    /// sensor polling while on and ours to render, capture live while
    /// unpaused (it survives the activation line — restarting the stream
    /// on every threshold crossing was the stutter), a half-second quiet
    /// before a paused fold comes back.
    private func reconcile() {
        let settings = settings
        jitter.tolerance = settings.jitterTolerance
        guard settings.enabled, settings.provider == .jrbar else {
            paused = false
            resumeWork?.cancel()
            resumeWork = nil
            displayedDelta = 0
            standDown()
            sensor.setPolling(false)
            return
        }
        // The sensor keeps polling while paused — its next reading is the
        // thing that tells us the lid reopened.
        sensor.setPolling(true)
        guard !rendererFailed, FoldCapturePermission.granted else {
            standDown()
            return
        }
        if pauseReason != nil {
            // Pausing is immediate; only resuming debounces.
            paused = true
            resumeWork?.cancel()
            resumeWork = nil
            displayedDelta = 0
            standDown()
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
        updatePresentation()
    }

    /// Gates, smooths and presents the fold. The gate reads the raw
    /// angle; the shader gets an eased delta so 30 Hz sensor steps glide
    /// instead of clicking.
    private func updatePresentation() {
        guard let gate = gateAngle,
              FoldMath.allows(rawAngle: gate, activation: settings.activationAngle),
              pauseReason == nil else {
            displayedDelta = 0
            overlay?.setVisible(false)
            return
        }
        let target = FoldMath.deltaRadians(
            angle: effectiveAngle ?? gate, activation: settings.activationAngle)
        let now = CACurrentMediaTime()
        displayedDelta = FoldMath.smoothed(
            current: displayedDelta, target: target, dt: now - lastDeltaTick)
        lastDeltaTick = now
        guard FoldMath.showsOverlay(
            delta: displayedDelta, hasFrame: capture?.hasFrame ?? false) else {
            overlay?.setVisible(false)
            return
        }
        guard let overlay = ensureOverlay() else { return }
        let settings = settings
        let reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        let fold = Float(FoldMath.foldAmount(
            angle: effectiveAngle ?? gate, activation: settings.activationAngle))
        overlay.renderer.params = FoldRenderer.Params(
            delta: Float(displayedDelta),
            blur: settings.style == .fog && !reduceMotion ? Float(settings.blur) : 0,
            persp: Float(settings.perspective),
            dim: settings.style == .tilt ? 0 : fold * Float(settings.shade))
        overlay.setVisible(true)
        overlay.redraw()
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
        capture.onFrame = { [weak self] buffer in
            guard let self, let overlay = self.overlay else { return }
            // Push once per delivered frame; a draw then costs one
            // triangle, not a texture conversion.
            if overlay.renderer.setDesktopFrame(buffer), overlay.isVisible {
                overlay.redraw()
            }
        }
        Task { [weak self, weak capture] in
            do {
                try await capture?.start()
            } catch {
                guard let self, self.capture === capture else { return }
                self.capture = nil
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

    /// The raw reading always lands — the gate re-checks every sample so
    /// a jitter-suppressed reading above the limit still hides the
    /// overlay — and the filter decides whether it moves the fold.
    private func noteSensorSample(_ angle: Double?) {
        rawAngle = angle
        if simulatedAngle == nil,
           !(angle.map { FoldMath.allows(rawAngle: $0, activation: settings.activationAngle) } ?? true) {
            displayedDelta = 0
            overlay?.setVisible(false)
        }
        guard let angle, jitter.accept(angle) else { return }
        filteredAngle = angle
        reconcile()
    }

    /// One observation pass over every input, re-armed on each change —
    /// the same pattern `observeSessions` uses for the buddy.
    private func observe() {
        withObservationTracking {
            _ = store?.state.fold
            _ = sensor.available
            _ = filteredAngle
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
            get: { self.simulatedAngle ?? self.effectiveAngle ?? 90 },
            set: { self.simulatedAngle = $0 })
    }

    func endSimulate() {
        simulatedAngle = nil
        reconcile()
    }

    /// "104°" while anything is driving the angle, "no sensor" on a Mac
    /// without the hinge, "—" for a sensor that has not read yet (the
    /// poll only runs while the toy is on).
    var angleText: String {
        if let angle = effectiveAngle { return "\(Int(angle.rounded()))°" }
        return sensor.available ? "—" : "no sensor"
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
