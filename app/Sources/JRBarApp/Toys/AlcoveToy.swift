import AppKit
import JRBarCore
import Observation
import SwiftUI

/// Alcove (docs/TOYS.md): the notch island — a black capsule hugging the
/// notch that shows who's working and grows into a session card on
/// hover. Like Fold, someone renders it: JR-Bar's own island
/// (`AlcoveIslandWindow` + `AlcoveIslandView`, fed by `AlcoveIsland`'s
/// pure summary), or the capsule owned by an external app — Henrik's
/// Alcove or the open-source boring.notch — and then ours stays parked.
///
/// The Screen Bar's capsule-following (`AlcoveFollower`,
/// `screen_bar_follow_alcove`) is a different feature that only makes
/// sense while the Alcove app is the renderer, so its toggle lives
/// under that provider. The island's frame is always exactly its drawn
/// shape — an invisible window would sit over the menu bar swallowing
/// clicks.
@MainActor
@Observable
final class AlcoveToy: Toy {
    let core: CoreModel
    /// The owning store; weak, the store keeps the toy.
    weak var store: ToysStore?
    /// Bumped on every app launch/terminate so the external-provider
    /// checks re-read `NSWorkspace`.
    private(set) var workspaceVersion = 0
    /// Bumped on display-parameter changes so the island reframes.
    private(set) var displayVersion = 0
    /// The island's hover state — the view reads it to pick its face,
    /// `setHovered` writes it.
    private(set) var islandExpanded = false
    /// Whether the island panel is ordered in — the view's pulse pauses
    /// on `false` so a parked island runs no clock at all.
    private(set) var islandVisible = false
    /// The notification capsule on screen, if any — Alcove's instant
    /// notification: the island's third face, between idle and the card.
    private(set) var activeCapsule: AlcoveNotice?
    /// What Now Playing reports, nil while MediaRemote is absent, off,
    /// or has nothing playing. The view reads it for the idle strip and
    /// the card's transport row.
    private(set) var islandMedia: AlcoveMedia?
    /// The raw hover state, kept separately from `islandExpanded` so a
    /// cursor that arrives during a capsule still lands its expand when
    /// the capsule steps down.
    private var hoverHeld = false
    /// The frame last asked of the window — `reconcile` re-runs on every
    /// sessions doc, and a no-change applyFrame would snap an in-flight
    /// morph (the capsule slide-in dies on the doc that follows its
    /// event). Same target, no re-apply.
    @ObservationIgnored private var desiredFrame: NSRect?
    /// The capsule decisions — pure, in `AlcoveCapsuleQueue`; the toy
    /// only owns the timers that run them.
    @ObservationIgnored private var capsuleQueue = AlcoveCapsuleQueue()
    /// The pending capsule timer — the show-delay gap or the 2.4 s life.
    @ObservationIgnored private var capsuleWork: DispatchWorkItem?
    /// The Now Playing source; exists only while the island is ours,
    /// shown, and `mediaEnabled`. A parked island holds no listener.
    @ObservationIgnored private var mediaMonitor: AlcoveMediaMonitor?
    /// The battery poller; exists only while the island is ours, shown,
    /// and `capsuleNotifications` + `capsuleKinds.charging` are on.
    @ObservationIgnored private var powerMonitor: AlcovePowerMonitor?
    /// The hover-leave timer — a short delay so a cursor grazing the
    /// island's edge doesn't ping-pong the morph.
    @ObservationIgnored private var collapseWork: DispatchWorkItem?
    @ObservationIgnored private var island: AlcoveIslandWindow?
    @ObservationIgnored private var observers: [NSObjectProtocol] = []

    /// The island's three faces on the same window.
    private enum AlcoveIslandFace { case idle, notice, expanded }

    init(core: CoreModel, store: ToysStore) {
        self.core = core
        self.store = store
        let workspace = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.didLaunchApplicationNotification,
                     NSWorkspace.didTerminateApplicationNotification] {
            observers.append(workspace.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.workspaceVersion += 1 }
            })
        }
        observers.append(NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.displayVersion += 1 }
        })
        observe()
        // The first pass: a toy that loads enabled must not wait for a
        // change to show its island.
        reconcile()
    }

    let id = "alcove"
    let name = "Alcove"
    let blurb = "A notch island: who's working, up in the notch. Alcove or Boring Notch can draw it instead."
    let symbol = "capsule.fill"

    var settings: AlcoveSettings { store?.state.alcove ?? AlcoveSettings() }

    var isOn: Bool {
        get { settings.enabled }
        set {
            store?.state.alcove.enabled = newValue
            store?.save()
            reconcile()
        }
    }

    // MARK: Status

    /// What the chip says — always a fact, never a promise.
    var status: ToyStatus {
        let settings = settings
        _ = workspaceVersion
        switch settings.provider {
        case .alcove:
            guard alcoveURL != nil else { return .unavailable("Alcove isn't installed") }
            guard settings.enabled else { return .off }
            return isAlcoveRunning
                ? .external("Alcove is rendering it")
                : .unavailable("Alcove isn't running")
        case .boringNotch:
            guard boringNotchURL != nil else { return .unavailable("Boring Notch isn't installed") }
            guard settings.enabled else { return .off }
            return isBoringNotchRunning
                ? .external("Boring Notch is rendering it")
                : .unavailable("Boring Notch isn't running")
        case .jrbar:
            if !settings.enabled { return .off }
            return settings.islandEnabled ? .on : .paused("Island hidden")
        }
    }

    // MARK: External providers

    var isAlcoveRunning: Bool {
        _ = workspaceVersion
        return NSWorkspace.shared.runningApplications.contains { $0.bundleIdentifier == AlcoveGeometry.bundleIdentifier }
    }

    var alcoveURL: URL? {
        _ = workspaceVersion
        return NSWorkspace.shared.urlForApplication(withBundleIdentifier: AlcoveGeometry.bundleIdentifier)
    }

    var isBoringNotchRunning: Bool {
        _ = workspaceVersion
        guard let id = boringNotchBundleID else { return false }
        return NSWorkspace.shared.runningApplications.contains { $0.bundleIdentifier == id }
    }

    /// boring.notch ships no bundle id we can pin, so it is read off the
    /// app's own Info.plist — the way `FoldToy.bendyURL` resolves Bendy.
    /// /Applications and ~/Applications are both probed, and a renamed
    /// install still resolves.
    private var boringNotchProbe: (id: String, path: URL)? {
        for folder in ["/Applications", NSHomeDirectory() + "/Applications"] {
            for name in ["boring.notch.app", "Boring Notch.app", "boringNotch.app"] {
                let path = URL(fileURLWithPath: "\(folder)/\(name)")
                if let id = Bundle(url: path)?.bundleIdentifier {
                    return (id, path)
                }
            }
        }
        return nil
    }

    private var boringNotchBundleID: String? { boringNotchProbe?.id }

    var boringNotchURL: URL? {
        _ = workspaceVersion
        guard let probe = boringNotchProbe else { return nil }
        return NSWorkspace.shared.urlForApplication(withBundleIdentifier: probe.id) ?? probe.path
    }

    /// The URL the "Open" button launches for the chosen provider.
    var externalURL: URL? {
        switch settings.provider {
        case .jrbar: return nil
        case .alcove: return alcoveURL
        case .boringNotch: return boringNotchURL
        }
    }

    /// The picker's write path: choosing an external renderer parks our
    /// island and opens that app; JR-Bar just hands the notch back to
    /// `reconcile`.
    func setProvider(_ provider: AlcoveProvider) {
        store?.state.alcove.provider = provider
        store?.save()
        guard provider != .jrbar else {
            reconcile()
            return
        }
        parkIsland()
        if let url = externalURLFor(provider) {
            NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration()) { _, _ in }
        }
    }

    private func externalURLFor(_ provider: AlcoveProvider) -> URL? {
        switch provider {
        case .jrbar: return nil
        case .alcove: return alcoveURL
        case .boringNotch: return boringNotchURL
        }
    }

    func openExternal() {
        guard let url = externalURL else { return }
        NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration()) { _, _ in }
    }

    // MARK: Island

    /// The capsule's contents, reduced by `AlcoveIsland` — the view reads
    /// this and `core.sessions` is observed, so it never sits stale.
    var islandSummary: AlcoveIslandSummary { AlcoveIsland.summarize(core.sessions) }

    /// The headline meters — empty while `showUsage` is off or the
    /// daemon sent no usage document.
    var islandMeters: [AlcoveIslandMeter] {
        settings.showUsage ? AlcoveIsland.meters(core.state?.usage) : []
    }

    /// The preferred screen's notch depth — the island's top clearance —
    /// re-measured whenever `displayVersion` bumps.
    var notchDepth: CGFloat {
        _ = displayVersion
        guard let screen = ScreenBarGeometry.preferredScreen() else { return 0 }
        return ScreenBarGeometry.notchDepth(of: screen)
    }

    /// The clearance the expanded card's content keeps under the notch —
    /// `AlcoveIslandLayout.expandedHeight` counts the same inset.
    var islandTopInset: CGFloat {
        notchDepth > 0 ? notchDepth + AlcoveIslandLayout.expandedNotchInset + ledClearance : 8
    }

    /// Points of dead space the island keeps under the notch while the
    /// Screen Bar's band is live: the island's window sits one level
    /// under the bar, so the LED strip draws across the island's top
    /// dead zone and the island's own content starts below it — neither
    /// covers the other. The flag is the daemon's
    /// `virtual_status_device_enabled`, which the delegate keeps in
    /// step with the Screen Bar's visibility.
    var ledClearance: CGFloat {
        guard screenBarLive, notchDepth > 0 else { return 0 }
        return AlcoveIslandLayout.ledBandClearance
    }

    /// Whether the Screen Bar is up — read off the settings document the
    /// delegate syncs with the window's visibility.
    var screenBarLive: Bool {
        SettingsDocument(core.settings?.document ?? .object([:]))
            .bool("virtual_status_device_enabled") ?? false
    }

    /// True while Fold's overlay is covering the screen — the island is
    /// invisible under it, so its window must let clicks fall through.
    var foldEngaged: Bool { store?.fold?.overlayOnScreen ?? false }

    /// The hover path: grow while the cursor is over the capsule, shrink
    /// when it leaves — the shrink rides a short delay, so a cursor that
    /// grazes the island's edge on its way past never fires the morph at
    /// all and a brief leave-and-return doesn't ping-pong it. "Grow on
    /// hover" off still lets the *shrink* half through — otherwise a
    /// capsule expanded when the toggle flipped could never collapse.
    /// A showing notification capsule owns the island, so the hover is
    /// only remembered then — it lands as an expand when the capsule
    /// steps down.
    private static let collapseDelay: TimeInterval = 0.18

    func setHovered(_ hovering: Bool) {
        let s = settings
        guard s.enabled, s.provider == .jrbar, s.islandEnabled else { return }
        hoverHeld = hovering
        collapseWork?.cancel()
        collapseWork = nil
        guard activeCapsule == nil else { return }
        if hovering {
            applyHover()
        } else if islandExpanded {
            let work = DispatchWorkItem { [weak self] in
                MainActor.assumeIsolated { self?.collapseTimerFired() }
            }
            collapseWork = work
            DispatchQueue.main.asyncAfter(deadline: .now() + Self.collapseDelay, execute: work)
        }
    }

    /// The leave timer's landing: only collapses if the cursor stayed
    /// away — a re-hover cancels the work before it fires.
    private func collapseTimerFired() {
        collapseWork = nil
        guard !hoverHeld else { return }
        applyHover()
    }

    /// Apply `hoverHeld` to the expanded flag and reframe on a change.
    private func applyHover() {
        let want = hoverHeld && settings.expandOnHover
        guard want != islandExpanded else { return }
        islandExpanded = want
        reframeCurrent(animated: !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion)
    }

    /// The face the window should wear right now: a capsule beats hover,
    /// hover beats idle.
    private var currentFace: AlcoveIslandFace {
        if activeCapsule != nil { return .notice }
        return islandExpanded ? .expanded : .idle
    }

    /// Resize the window to `face`'s frame — the island morphs in place;
    /// there is never a second panel. A request already in flight is not
    /// re-issued: the second applyFrame would snap the ease. A nudge too
    /// small to see (a session row's label settling by a point) applies
    /// without animation — animating a sub-2 pt delta reads as jitter.
    private func reframe(_ face: AlcoveIslandFace, animated: Bool) {
        guard let frame = islandFrame(face: face) else { return }
        guard frame != desiredFrame else { return }
        var animated = animated
        if let last = desiredFrame,
           abs(last.height - frame.height) < 2, abs(last.width - frame.width) < 2 {
            animated = false
        }
        desiredFrame = frame
        island?.applyFrame(frame, animated: animated)
    }

    private func reframeCurrent(animated: Bool) {
        reframe(currentFace, animated: animated)
    }

    /// The island's frame for a face: centred on the notch slot, top
    /// edge pinned to the screen's top (or floating a few points under
    /// it on a notch-less screen).
    private func islandFrame(face: AlcoveIslandFace) -> NSRect? {
        _ = displayVersion
        guard let screen = ScreenBarGeometry.preferredScreen() else { return nil }
        let slot = AlcoveIslandLayout.slot(left: screen.auxiliaryTopLeftArea,
                                           right: screen.auxiliaryTopRightArea)
        let depth = ScreenBarGeometry.notchDepth(of: screen)
        let centerX = slot?.centerX ?? screen.frame.midX
        let size: CGSize
        switch face {
        case .expanded:
            let summary = islandSummary
            size = CGSize(width: AlcoveIslandLayout.expandedWidth,
                          height: AlcoveIslandLayout.expandedHeight(
                              notchDepth: depth,
                              rows: min(summary.rows.count, AlcoveIsland.rowLimit),
                              meters: islandMeters.count,
                              overflow: summary.rows.count > AlcoveIsland.rowLimit,
                              media: cardMedia != nil,
                              ledClearance: ledClearance))
        case .notice:
            size = AlcoveIslandLayout.noticeSize(slotWidth: slot?.width ?? 0,
                                                 notchDepth: depth,
                                                 ledClearance: ledClearance)
        case .idle:
            size = AlcoveIslandLayout.idleSize(
                slotWidth: slot?.width ?? 0, notchDepth: depth,
                contentWidth: AlcoveIsland.idleContentWidth(islandSummary, media: idleMedia))
        }
        return AlcoveIslandLayout.frame(
            screenFrame: screen.frame, centerX: centerX, size: size,
            topInset: slot == nil ? AlcoveIslandLayout.floatingTopInset : 0)
    }

    /// The media the idle capsule draws — nil when the user switched
    /// Now Playing off, so the strip and its width vanish together.
    private var idleMedia: AlcoveMedia? {
        settings.mediaEnabled ? islandMedia : nil
    }

    /// The card's transport row follows the same switch.
    private var cardMedia: AlcoveMedia? { idleMedia }

    /// One place that reads the settings and makes the panel match:
    /// ordered in and framed while the island is ours, enabled and shown;
    /// fully ordered out otherwise — a parked island runs no timers.
    private func reconcile() {
        let s = settings
        guard s.enabled, s.provider == .jrbar, s.islandEnabled,
              let frame = islandFrame(face: currentFace) else {
            parkIsland()
            return
        }
        if island == nil { island = AlcoveIslandWindow(toy: self) }
        if desiredFrame != frame {
            desiredFrame = frame
            island?.applyFrame(frame, animated: false)
        }
        if island?.isVisible != true {
            island?.orderFrontRegardless()
        }
        islandVisible = true
        syncMediaMonitor()
        syncPowerMonitor()
    }

    /// Ordered out and collapsed. The window object stays — a re-show is
    /// a frame, not a rebuild — but nothing in it ticks while hidden:
    /// the capsule timers die and the media listener lets go.
    private func parkIsland() {
        islandExpanded = false
        hoverHeld = false
        activeCapsule = nil
        capsuleWork?.cancel()
        capsuleWork = nil
        collapseWork?.cancel()
        collapseWork = nil
        capsuleQueue.clear()
        desiredFrame = nil
        islandVisible = false
        island?.orderOut(nil)
        syncMediaMonitor()
        syncPowerMonitor()
    }

    // MARK: Event capsules

    /// `EventCoordinator.apply` hands every daemon event here, next to
    /// the confetti call. `AlcoveEventPolicy` decides whether it earns a
    /// capsule; the queue's cooldown keeps a burst of asks from strobing
    /// the notch. While the card is open the event is already visible in
    /// its rows — a capsule over it would only blink — so expanded eats
    /// them quietly.
    func noteEvent(_ event: CoreEvent) {
        let s = settings
        guard s.enabled, s.provider == .jrbar, s.islandEnabled,
              s.capsuleNotifications, islandVisible, !islandExpanded else { return }
        let session = event.session.flatMap { core.state?.session(withID: $0) }
        guard let notice = AlcoveEventPolicy.notice(for: event, session: session,
                                                    kinds: s.capsuleKinds) else { return }
        offer(notice)
    }

    /// A battery transition the power monitor saw — `AlcovePower.notice`
    /// shapes it; the same queue and gate as daemon events.
    private func notePowerTransition(from old: AlcovePowerState, to new: AlcovePowerState) {
        let s = settings
        guard s.enabled, s.provider == .jrbar, s.islandEnabled,
              s.capsuleNotifications, islandVisible, !islandExpanded else { return }
        guard let notice = AlcovePower.notice(from: old, to: new,
                                              id: UUID().uuidString,
                                              kinds: s.capsuleKinds) else { return }
        offer(notice)
    }

    /// Every capsule enters through here — daemon event or synthesized —
    /// so the cooldown and the single pending slot police them equally.
    private func offer(_ notice: AlcoveNotice) {
        switch capsuleQueue.offer(notice, at: Date()) {
        case .now: showCurrentCapsule()
        case .after(let delay): scheduleCapsuleShow(after: delay)
        case .queued, .suppressed: break
        }
    }

    /// Draw `capsuleQueue.current` as the island's face and arm its life
    /// timer. A capsule outranks the expanded card — the card folds away
    /// first and the remembered hover decides what comes back.
    private func showCurrentCapsule() {
        guard capsuleQueue.current != nil, islandVisible else { return }
        if islandExpanded { islandExpanded = false }
        activeCapsule = capsuleQueue.current
        reframe(.notice, animated: !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion)
        capsuleWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated { self?.finishCapsule() }
        }
        capsuleWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + AlcoveCapsuleQueue.life,
                                      execute: work)
    }

    /// The gap between two capsules: nothing drawn yet, `current` already
    /// picked — this is the timer that draws it.
    private func scheduleCapsuleShow(after delay: TimeInterval) {
        capsuleWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated { self?.showCurrentCapsule() }
        }
        capsuleWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }

    /// The shown capsule's life ended: the queue promotes whatever was
    /// waiting (after the minimum gap), or the island settles back to
    /// whatever the cursor currently wants — idle, or the deferred
    /// expand a mid-capsule hover earned.
    private func finishCapsule() {
        capsuleWork = nil
        switch capsuleQueue.finish(at: Date()) {
        case .idle:
            activeCapsule = nil
            settleToRest()
        case .now:
            showCurrentCapsule()
        case .after(let delay, _):
            activeCapsule = nil
            settleToRest()
            scheduleCapsuleShow(after: delay)
        }
    }

    /// A swipe down on the island. "Stop" rather than "next": the shown
    /// capsule AND anything waiting behind it are dropped. The swipe is
    /// a dismissal — the held cursor must not pop the card right back
    /// open where the capsule was.
    func dismissCapsule() {
        guard activeCapsule != nil || capsuleQueue.current != nil else { return }
        capsuleWork?.cancel()
        capsuleWork = nil
        capsuleQueue.cancel(at: Date())
        activeCapsule = nil
        hoverHeld = false
        settleToRest()
    }

    /// Back to the face the cursor wants: the remembered hover, shrunk
    /// to idle when it left during the capsule.
    private func settleToRest() {
        let want = hoverHeld && settings.expandOnHover
        if islandExpanded != want { islandExpanded = want }
        reframeCurrent(animated: !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion)
    }

    // MARK: Now Playing

    /// The monitor lives exactly as long as the island is shown with
    /// `mediaEnabled` on; `reconcile`/`parkIsland` both land here.
    private func syncMediaMonitor() {
        let want = islandVisible && settings.mediaEnabled
        if want {
            if mediaMonitor == nil {
                let monitor = AlcoveMediaMonitor()
                monitor.onChange = { [weak self] media in self?.noteMedia(media) }
                mediaMonitor = monitor
            }
            mediaMonitor?.start()
        } else {
            mediaMonitor?.stop()
            mediaMonitor = nil
            if islandMedia != nil {
                islandMedia = nil
                reframeCurrent(animated: false)
            }
        }
    }

    /// A now-playing refresh landed: keep the media, and reframe — the
    /// strip changes the idle width and the card's height. Capsule faces
    /// don't measure media, so a mid-capsule update just waits.
    private func noteMedia(_ media: AlcoveMedia?) {
        guard media != islandMedia else { return }
        islandMedia = media
        if currentFace != .notice {
            reframeCurrent(animated: !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion)
        }
    }

    /// The card's transport buttons and the swipe gestures land here.
    func mediaTogglePlayPause() { mediaMonitor?.send(.togglePlayPause) }
    func mediaNextTrack() { mediaMonitor?.send(.nextTrack) }
    func mediaPreviousTrack() { mediaMonitor?.send(.previousTrack) }

    // MARK: Power

    /// The battery poller lives exactly as long as the island is shown
    /// with both capsule switches on; `reconcile`/`parkIsland` land here.
    private func syncPowerMonitor() {
        let s = settings
        let want = islandVisible && s.capsuleNotifications && s.capsuleKinds.charging
        if want {
            if powerMonitor == nil {
                let monitor = AlcovePowerMonitor()
                monitor.onTransition = { [weak self] old, new in
                    self?.notePowerTransition(from: old, to: new)
                }
                powerMonitor = monitor
            }
            powerMonitor?.start()
        } else {
            powerMonitor?.stop()
            powerMonitor = nil
        }
    }

    // MARK: Swipe

    /// A two-finger swipe on the island, read off the hosting view's
    /// scroll events. Horizontal rides the media transport — only while
    /// the island is actually showing a track, so a stray swipe never
    /// pokes a player we aren't displaying. Down dismisses the capsule,
    /// or folds the open card back to the capsule.
    func islandSwipe(_ swipe: AlcoveIslandSwipe) {
        switch swipe {
        case .left:
            if islandMedia != nil { mediaNextTrack() }
        case .right:
            if islandMedia != nil { mediaPreviousTrack() }
        case .down:
            if activeCapsule != nil || capsuleQueue.current != nil {
                dismissCapsule()
            } else if islandExpanded {
                hoverHeld = false
                islandExpanded = false
                reframe(.idle, animated: !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion)
            }
        }
    }

    /// One observation pass over every input, re-armed on each change —
    /// the same pattern `NotchBuddyToy.observeSessions` uses.
    private func observe() {
        withObservationTracking {
            _ = store?.state.alcove
            _ = core.sessions
            _ = core.state?.usage
            _ = core.settings?.document   // virtual_status_device_enabled → ledClearance
            _ = displayVersion
            // islandExpanded is deliberately NOT tracked: `setHovered`
            // reframes the window itself, and a reconcile re-fired off
            // the same write would call `applyFrame(animated: false)`
            // mid-ease and snap it.
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.reconcile()
                self.observe()
            }
        }
    }

    // MARK: Controls

    /// A binding into `store.state.alcove`; the store's `didSet`
    /// debounces the write.
    func bind<T>(_ keyPath: WritableKeyPath<AlcoveSettings, T>) -> Binding<T> {
        Binding(
            get: { self.store?.state.alcove[keyPath: keyPath] ?? AlcoveSettings()[keyPath: keyPath] },
            set: { self.store?.state.alcove[keyPath: keyPath] = $0 })
    }

    var providerBinding: Binding<AlcoveProvider> {
        Binding(
            get: { self.settings.provider },
            set: { self.setProvider($0) })
    }

    /// What the follower sees — the Capsule row under the Alcove provider.
    var capsuleFact: String {
        _ = workspaceVersion
        guard alcoveURL != nil else { return "not installed" }
        guard isAlcoveRunning else { return "Alcove isn't running" }
        if let capsule = store?.alcoveCapsule { return "following: \(Int(capsule.width.rounded())) pt wide" }
        return "running, no capsule seen"
    }

    var controls: AnyView {
        AnyView(AlcoveControlsView(toy: self))
    }
}

/// The card's disclosure body. Every toggle writes `store.state.alcove`
/// (which persists itself) except the provider picker, which goes
/// through `setProvider` so the swap can park our island and open theirs.
private struct AlcoveControlsView: View {
    let toy: AlcoveToy

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Picker(selection: toy.providerBinding) {
                Text("JR-Bar").tag(AlcoveProvider.jrbar)
                Text("Alcove").tag(AlcoveProvider.alcove)
                Text("Boring Notch").tag(AlcoveProvider.boringNotch)
            } label: {
                SettingLabel(title: "Render with",
                             subtitle: "Let Alcove or Boring Notch draw the island instead.")
            }
            .pickerStyle(.menu)
            .fixedSize()

            providerNote
            providerControls
        }
    }

    /// The rows that belong to whoever renders: ours get the island's
    /// knobs, Alcove's keep the capsule-following that already existed,
    /// Boring Notch's get nothing — there is nothing of ours to set.
    @ViewBuilder
    private var providerControls: some View {
        switch toy.settings.provider {
        case .jrbar:
            Toggle(isOn: toy.bind(\.islandEnabled)) {
                SettingLabel(title: "Show the island",
                             subtitle: "The capsule under the notch.")
            }
            Toggle(isOn: toy.bind(\.expandOnHover)) {
                SettingLabel(title: "Grow on hover",
                             subtitle: "Hover expands it into the session card.")
            }
            Toggle(isOn: toy.bind(\.showUsage)) {
                SettingLabel(title: "Usage meters",
                             subtitle: "Per-provider quota bars inside the card.")
            }
            Toggle(isOn: toy.bind(\.capsuleNotifications)) {
                SettingLabel(title: "Event capsules",
                             subtitle: "The island briefly morphs into a notice when an ask opens, a run ends or a quota resets.")
            }
            if toy.settings.capsuleNotifications {
                Toggle(isOn: toy.bind(\.capsuleKinds.ask)) {
                    SettingLabel(title: "Asks", subtitle: "A session opens a question.")
                }
                Toggle(isOn: toy.bind(\.capsuleKinds.completed)) {
                    SettingLabel(title: "Completions", subtitle: "An agent finishes a run.")
                }
                Toggle(isOn: toy.bind(\.capsuleKinds.failed)) {
                    SettingLabel(title: "Failures", subtitle: "A session stops on an error.")
                }
                Toggle(isOn: toy.bind(\.capsuleKinds.quotaReset)) {
                    SettingLabel(title: "Quota resets", subtitle: "A provider's usage window refills.")
                }
                Toggle(isOn: toy.bind(\.capsuleKinds.charging)) {
                    SettingLabel(title: "Power", subtitle: "Plugging in, switching to battery, fully charged.")
                }
            }
            Toggle(isOn: toy.bind(\.mediaEnabled)) {
                SettingLabel(title: "Now Playing",
                             subtitle: "The capsule carries the current track; the card gains transport buttons.")
            }
        case .alcove:
            if let settings = toy.store?.settings {
                SettingToggle(settings, "Follow Alcove's capsule",
                              subtitle: "The Screen Bar matches the capsule's width while Alcove is up.",
                              path: "screen_bar_follow_alcove", default: true)
            }
            LabeledContent {
                Text(toy.capsuleFact)
                    .font(.callout)
                    .foregroundStyle(.secondary)
            } label: {
                SettingLabel(title: "Capsule", subtitle: "What the follower sees right now.")
            }
        case .boringNotch:
            EmptyView()
        }
    }

    /// What the chosen external renderer is doing — installed and
    /// launched, or a link to get it.
    @ViewBuilder
    private var providerNote: some View {
        switch toy.settings.provider {
        case .jrbar:
            EmptyView()
        case .alcove:
            externalNote(installed: toy.alcoveURL != nil, name: "Alcove",
                         link: URL(string: "https://alcove.app")!)
        case .boringNotch:
            externalNote(installed: toy.boringNotchURL != nil, name: "Boring Notch",
                         link: URL(string: "https://github.com/TheBoringNotch/boring.notch")!)
        }
    }

    private func externalNote(installed: Bool, name: String, link: URL) -> some View {
        HStack(spacing: 8) {
            Text(installed ? "\(name) is installed" : "\(name) isn't installed")
                .font(.callout)
                .foregroundStyle(.secondary)
            if installed {
                Button("Open \(name)") { toy.openExternal() }
            } else {
                Link("Get \(name)", destination: link)
                    .font(.callout)
            }
        }
    }
}
