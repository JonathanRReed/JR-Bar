import AppKit
import JRBarCore
import Observation
import SwiftUI

/// Notch (docs/TOYS.md): the notch island — a black capsule hugging the
/// notch that shows who's working, and the notch's drop-down. Idle, the
/// island dots the working providers. A tap, a pull, a held hover (or a
/// band click) grows it into the card, Dynamic-Island style — the same
/// `NotchCardView` the glass fallback wears, on black, contiguous with
/// the notch; a daemon event that matters morphs the capsule into a
/// notice — ask, finished, failed, quota reset, charge state — for a
/// couple of seconds. A two-finger horizontal swipe on the capsule is
/// the media transport; a downward swipe or pull dismisses the notice
/// or folds the card away. A cursor only passing through never grows
/// it — it earns the wink (`islandHoverPeek`), and nothing more.
///
/// Anything that comes out of the notch must feel like part of the
/// notch, so while this island is drawn it IS the card — the glass
/// `NotchCardPanel` only ever shows when the toy is off or an external
/// provider owns the notch, driven by the band's peek/pin as before.
/// Never both.
///
/// `provider` in settings picks who draws the island: JR-Bar's own
/// (`NotchIslandWindow` + `NotchIslandView`, fed by `NotchIsland`'s
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
final class NotchToy: Toy {
    let core: CoreModel
    /// The owning store; weak, the store keeps the toy.
    weak var store: ToysStore?
    /// The grown card's model — its own `NotchCardModel`, but built on
    /// the same timer and tray stores the glass panel's model was given,
    /// so a timer fires once no matter which surface is up.
    let cardModel: NotchCardModel
    /// The focus the card's header names — AppDelegate wires it to
    /// `PanelStore.screenBarFocus`, same read the glass card makes.
    var cardFocus: @MainActor () -> ScreenBarFocus? = { nil }
    /// The roster affordance — AppDelegate's Overview window.
    var onOpenOverview: @MainActor () -> Void = {}
    /// Bumped on every app launch/terminate so the external-provider
    /// checks re-read `NSWorkspace`.
    private(set) var workspaceVersion = 0
    /// Bumped on display-parameter changes so the island reframes.
    private(set) var displayVersion = 0
    /// Whether the island panel is ordered in — the view's pulse pauses
    /// on `false` so a parked island runs no clock at all. The setter is
    /// internal so tests can run the capsule flow without a panel.
    var islandVisible = false
    /// The notification capsule on screen, if any — Alcove's instant
    /// notification: the island's only face besides idle.
    private(set) var activeCapsule: AlcoveNotice?
    /// What Now Playing reports, nil while MediaRemote is absent, off,
    /// or has nothing playing. The view reads it for the idle strip.
    private(set) var islandMedia: AlcoveMedia?
    /// The raw hover state: the island's `.onHover` writes it; the card
    /// it may grow drops when the hover — and any capsule in the way —
    /// is done.
    private var hoverHeld = false
    /// The hover wink: a cursor ON the island earns a few points of
    /// grow — proof of life — while the intent debounce decides whether
    /// this was a pause that meant the card. The view swells the dots
    /// on it; `islandFrame` grows the idle frame on it.
    private(set) var islandHoverPeek = false
    /// The intent debounce — a cursor pausing this long on the resting
    /// island meant it; a pointer cutting across only ever earns the
    /// wink. Armed in `setHovered`, fires `hoverExpandFired`.
    @ObservationIgnored private var expandWork: DispatchWorkItem?
    /// The press-and-pull is live — the finger owns the frame, so the
    /// hover debounce must not fold the card the finger is holding and
    /// a mid-pull morph calls `cancelPull` rather than fight it.
    private(set) var pullActive = false
    /// The island is grown into the card right now.
    private(set) var islandExpanded = false
    /// A band click's deliberate expand — survives pointer-leave until
    /// an outside click, a swipe-down or Esc lets it go; a hover's own
    /// expand answers to the leave debounce alone.
    private var expandHeld = false
    /// A band click landed mid-capsule — the capsule owns the island
    /// until it steps down, then the expand lands.
    private var bandExpandPending = false
    /// Esc lets the card go — the island never becomes key, so the toy
    /// watches for it while grown.
    @ObservationIgnored private var cardKeyMonitors: [Any] = []
    /// The frame last asked of the window — `reconcile` re-runs on every
    /// sessions doc, and a no-change applyFrame would snap an in-flight
    /// morph (the capsule slide-in dies on the doc that follows its
    /// event). Same target, no re-apply.
    @ObservationIgnored private var desiredFrame: NSRect?
    /// The capsule decisions — pure, in `AlcoveCapsuleQueue`; the toy
    /// only owns the timers that run them.
    @ObservationIgnored private(set) var capsuleQueue = AlcoveCapsuleQueue()
    /// The pending capsule timer — the show-delay gap or the 2.4 s life.
    @ObservationIgnored private var capsuleWork: DispatchWorkItem?
    /// A capsule promoted into its show-gap the moment the island grew:
    /// it could never draw over the card, so `expand` shelves it here
    /// and `collapseIsland` re-shows it while it is still fresh.
    @ObservationIgnored private(set) var shelvedCapsule: (notice: AlcoveNotice, at: Date)?
    /// The Now Playing reader's token on the shared feed; held only
    /// while the island is ours, shown, and `mediaEnabled`. A parked
    /// island holds no listener.
    @ObservationIgnored private var mediaToken: UUID?
    /// The shared Now Playing source — one helper for every surface.
    @ObservationIgnored private let mediaFeed: MediaFeed
    /// The battery poller; exists only while the island is ours, shown,
    /// and `capsuleNotifications` + `capsuleKinds.charging` are on.
    @ObservationIgnored private var powerMonitor: AlcovePowerMonitor?
    /// The hover-leave timer — a short delay so a cursor grazing the
    /// island's edge doesn't flap the card.
    @ObservationIgnored private var collapseWork: DispatchWorkItem?
    @ObservationIgnored private var island: NotchIslandWindow?
    @ObservationIgnored private var observers: [NSObjectProtocol] = []

    /// The island's three faces on the same window — idle capsule,
    /// notice capsule, the grown card.
    private enum NotchIslandFace { case idle, notice, expanded }

    init(core: CoreModel, store: ToysStore, cardModel: NotchCardModel, mediaFeed: MediaFeed? = nil) {
        self.core = core
        self.store = store
        self.cardModel = cardModel
        self.mediaFeed = mediaFeed ?? MediaFeed.shared
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
        cardModel.onClose = { [weak self] in self?.collapseIsland() }
        cardModel.onOpenSession = { [weak self] in
            guard let self, let session = self.cardModel.focus.clickSession else { return }
            self.collapseIsland()
            self.core.openSession(session)
        }
        cardModel.onOpenOverview = { [weak self] in self?.onOpenOverview() }
        observe()
        // The first pass: a toy that loads enabled must not wait for a
        // change to show its island.
        reconcile()
    }

    let id = "notch"
    let name = "Notch"
    let blurb = "Who's working, up in the notch. Alcove or Boring Notch can draw it instead."
    let symbol = "capsule.fill"

    var settings: NotchSettings { store?.state.notch ?? NotchSettings() }

    var isOn: Bool {
        get { settings.enabled }
        set {
            store?.state.notch.enabled = newValue
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
            guard settings.islandEnabled else { return .paused("Island hidden") }
            return earsDrawn ? .paused("Bare — the Screen Bar's ears carry the HUD") : .on
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
    func setProvider(_ provider: NotchProvider) {
        store?.state.notch.provider = provider
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

    private func externalURLFor(_ provider: NotchProvider) -> URL? {
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

    /// The capsule's contents, reduced by `NotchIsland` — the view reads
    /// this and `core.sessions` is observed, so it never sits stale.
    var islandSummary: NotchIslandSummary { NotchIsland.summarize(core.sessions) }

    /// The island's on-screen frame — part of the band's shared hover
    /// region while the island is up.
    var islandScreenRect: NSRect? { islandVisible ? desiredFrame : nil }

    /// The one surface the notch system may show right now — the
    /// island, the glass fallback, or nothing. The glass card's
    /// presenter reads the same answer (wired in the delegate), so the
    /// two surfaces can never disagree about whose turn it is.
    var notchSurface: NotchSurface {
        NotchIsland.surface(settings, islandVisible: islandVisible)
    }

    /// True while our island is the notch's card surface — the band's
    /// peek/pin route to `expandFromBand`/`collapseFromBand` and the
    /// glass card stays dark. Only while the island is actually drawn:
    /// a parked island owns nothing and the band gets its glass
    /// fallback — unless the utility itself is off, which draws
    /// nothing at all.
    var isDrawingIsland: Bool { notchSurface == .island }

    /// The grown card's width — the slot plus its shoulders, bounded.
    var expandedCardWidth: CGFloat {
        _ = displayVersion
        guard let screen = ScreenBarGeometry.preferredScreen() else {
            return NotchIslandLayout.expandedMinWidth
        }
        let slot = NotchIslandLayout.slot(left: screen.auxiliaryTopLeftArea,
                                          right: screen.auxiliaryTopRightArea)
        return NotchIslandLayout.expandedWidth(slotWidth: slot?.width ?? 0)
    }

    /// The grown card's top pad — past the notch's own depth, its inset
    /// and a live band's clearance, so the card's content starts clear
    /// of both.
    var cardTopPad: CGFloat {
        NotchIslandLayout.expandedTopInset(notchDepth: notchDepth,
                                           ledClearance: ledClearance)
    }

    /// The island's bottom corners take the notch profile's own radius —
    /// `screen_bar_notch_profile` + `screen_bar_notch_corner`, the same
    /// read the bar's tray silhouette makes, so island and tray match.
    var notchCornerRadius: CGFloat {
        _ = displayVersion
        let doc = SettingsDocument(core.settings?.document ?? .object([:]))
        let profile = NotchProfile(setting: doc.string("screen_bar_notch_profile"))
        return profile.cornerRadius(manual: doc.double("screen_bar_notch_corner").map { CGFloat($0) })
    }

    /// The preferred screen's notch depth — the island's top clearance —
    /// re-measured whenever `displayVersion` bumps.
    var notchDepth: CGFloat {
        _ = displayVersion
        guard let screen = ScreenBarGeometry.preferredScreen() else { return 0 }
        return ScreenBarGeometry.notchDepth(of: screen)
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
        return NotchIslandLayout.ledBandClearance
    }

    /// Whether the Screen Bar is up — read off the settings document the
    /// delegate syncs with the window's visibility.
    var screenBarLive: Bool {
        SettingsDocument(core.settings?.document ?? .object([:]))
            .bool("virtual_status_device_enabled") ?? false
    }

    /// Whether the Screen Bar draws its ears over the notch's shoulders
    /// (`screen_bar_notch_wings`, on by default) — then the island's
    /// resting face stays a bare housing so the two never stack marks.
    var earsDrawn: Bool {
        guard screenBarLive, notchDepth > 0 else { return false }
        return SettingsDocument(core.settings?.document ?? .object([:]))
            .bool("screen_bar_notch_wings") ?? true
    }

    /// What the resting island draws in its shoulders — the view and
    /// the frame read the same answer.
    var idleLayout: NotchIdleLayout {
        NotchIsland.idleLayout(islandSummary, media: idleMedia, earsDrawn: earsDrawn)
    }

    /// True while Fold's overlay is covering the screen — the island is
    /// invisible under it, so its window must let clicks fall through.
    var foldEngaged: Bool { store?.fold?.overlayOnScreen ?? false }

    /// The hover path: a cursor on the resting island earns the wink —
    /// a few points of grow (`islandHoverPeek`), never the card — and
    /// only a cursor that STAYS, past `hoverExpandDelay`, earns the
    /// grow `expandOnHover` promised. A pointer cutting across the
    /// notch to reach a menu gets the wink and nothing else; that is
    /// the whole reason the debounce exists. On the grown card the
    /// hover just holds it open — the card IS the island's window, so
    /// the pointer wandering down into the rows is still the same
    /// hover — and leaving folds it on the short `collapseDelay`, so a
    /// brief leave-and-return doesn't ping-pong it. A showing capsule
    /// owns the island, so the hover is only remembered then — it
    /// lands its grow when the capsule steps down.
    private static let collapseDelay: TimeInterval = 0.18
    /// Alcove-quick: a pointer that reaches the notch or an ear wants
    /// the card, and the notch sits where nothing else is aimed at.
    private static let hoverExpandDelay: TimeInterval = 0.12

    /// Whether the pointer is on the Screen Bar's region — its ears,
    /// tray or the island — right now. The band's hover is the
    /// island's hover; a leave from the island's own window onto an
    /// ear is not a leave.
    var pointerOnBand: @MainActor () -> Bool = { false }

    /// The band's hover, forwarded: the ears are the island's hover
    /// surface while the island owns the notch.
    func bandHover(_ hovering: Bool) {
        setHovered(hovering)
    }

    func setHovered(_ hovering: Bool) {
        let s = settings
        guard s.enabled, s.provider == .jrbar, s.islandEnabled else { return }
        hoverHeld = hovering
        // The wink only where it means something: a card that can grow
        // on hover, and a face that draws — a bare housing under the
        // Screen Bar's ears has nothing to swell.
        islandHoverPeek = hovering && !islandExpanded && s.expandOnHover && !idleLayout.bare
        collapseWork?.cancel()
        collapseWork = nil
        expandWork?.cancel()
        expandWork = nil
        guard activeCapsule == nil else { return }
        if hovering {
            if !islandExpanded, s.expandOnHover {
                // The wink lands now; the card only after the pause.
                reframeCurrent(
                    animated: !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion)
                let work = DispatchWorkItem { [weak self] in
                    MainActor.assumeIsolated { self?.hoverExpandFired() }
                }
                expandWork = work
                DispatchQueue.main.asyncAfter(deadline: .now() + Self.hoverExpandDelay,
                                             execute: work)
            }
        } else {
            if !islandExpanded {
                reframeCurrent(
                    animated: !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion)
            }
            if islandExpanded && !expandHeld { scheduleCollapseCheck() }
        }
    }

    /// The intent debounce landed: a cursor still on the island earns
    /// the card — `expandOnHover` remains the user's say over whether
    /// a held hover grows at all.
    private func hoverExpandFired() {
        expandWork = nil
        applyHover()
    }

    /// The leave debounce a hover-grown card folds on — shared by the
    /// hover's exit and the pull's let-go.
    private func scheduleCollapseCheck() {
        collapseWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated { self?.collapseTimerFired() }
        }
        collapseWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.collapseDelay, execute: work)
    }

    /// The leave timer's landing: only folds while the cursor stayed
    /// away — a re-hover cancels the work before it fires, a pull owns
    /// the card it is holding, and a card the band click deliberately
    /// grew is its master's to let go.
    private func collapseTimerFired() {
        collapseWork = nil
        guard !hoverHeld, !pullActive, !pointerOnBand() else { return }
        if islandExpanded && !expandHeld { collapseIsland() }
    }

    /// A click or swipe on the band while our island is up: the island
    /// grows, deliberately — it stays until an outside click, a
    /// swipe-down or Esc lets it go. Mid-capsule the click is
    /// remembered and lands when the capsule steps down.
    func expandFromBand() {
        // Fold's overlay owns the screen: a band press through it must
        // not grow a card the user cannot see — it would still be open
        // when the fold lets go.
        guard isDrawingIsland, !foldEngaged else { return }
        if activeCapsule != nil {
            bandExpandPending = true
            return
        }
        expand(held: true)
    }

    /// The band's dismiss paths — an outside click or a swipe up —
    /// fold the grown card whatever grew it.
    func collapseFromBand() {
        bandExpandPending = false
        collapseIsland()
    }

    /// Grow the island into the card — `held` is the band click's
    /// deliberate pin, surviving pointer-leave; a hover's expand
    /// answers to the leave debounce alone.
    private func expand(held: Bool) {
        guard isDrawingIsland, !foldEngaged else { return }
        if held { expandHeld = true }
        guard !islandExpanded else { return }
        // A capsule promoted into its show-gap can never draw over the
        // card — `showCurrentCapsule` guards on expanded — so its gap
        // timer must not keep running: it would fire into the early
        // return and leave `current` parked forever, wedging every
        // later offer behind it. Shelve it instead; `collapseIsland`
        // re-shows it while it is still fresh.
        if activeCapsule == nil, let promoted = capsuleQueue.current {
            shelvedCapsule = (promoted, Date())
            capsuleWork?.cancel()
            capsuleWork = nil
        }
        islandExpanded = true
        feedCard()
        cardModel.pinned = true
        syncCardKeyMonitors()
        reframe(.expanded,
                animated: !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion)
    }

    /// Fold the grown card back — every dismiss path lands here. The
    /// held cursor goes with it: a collapse is a "let it go", so a
    /// pointer still sitting on the island (Esc, the close button, a
    /// swipe) must not re-grow the card the next time a capsule
    /// settles and re-reads the hover.
    private func collapseIsland() {
        guard islandExpanded else { return }
        islandExpanded = false
        expandHeld = false
        hoverHeld = false
        islandHoverPeek = false
        cardModel.pinned = false
        syncCardKeyMonitors()
        // A capsule the grow shelved is still news while it is fresh —
        // the card outranked it; the user did not dismiss it. A stale
        // or orphaned `current` gets cancelled instead, so the slot can
        // never outlive the card that hid it.
        let shelved = shelvedCapsule
        shelvedCapsule = nil
        if let current = capsuleQueue.current {
            if let shelved, current == shelved.notice,
               Date().timeIntervalSince(shelved.at) < AlcoveCapsuleQueue.life {
                showCurrentCapsule()
                return
            }
            capsuleQueue.cancel(at: Date())
        }
        reframe(currentFace,
                animated: !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion)
    }

    /// Esc while the card is grown lets it go — the island never takes
    /// key status, so the toy watches both monitors itself.
    private func syncCardKeyMonitors() {
        for monitor in cardKeyMonitors { NSEvent.removeMonitor(monitor) }
        cardKeyMonitors = []
        guard islandExpanded else { return }
        if let local = NSEvent.addLocalMonitorForEvents(
            matching: .keyDown,
            handler: { [weak self] event in
                if event.keyCode == 53 {
                    Task { @MainActor [weak self] in self?.collapseIsland() }
                    return nil
                }
                return event
            }) {
            cardKeyMonitors.append(local)
        }
        if let global = NSEvent.addGlobalMonitorForEvents(
            matching: .keyDown,
            handler: { [weak self] event in
                if event.keyCode == 53 {
                    Task { @MainActor [weak self] in self?.collapseIsland() }
                }
            }) {
            cardKeyMonitors.append(global)
        }
    }

    /// Refill the card's rows from the live state — the same facts the
    /// glass card's presenter would hand it.
    private func feedCard() {
        if let focus = cardFocus() { cardModel.focus = focus }
        cardModel.rows = islandSummary.rows.filter { $0.id != cardModel.focus.focusSession }
        cardModel.meters = settings.showUsage ? NotchIsland.meters(core.state?.usage) : []
    }

    /// Hover on the island grows it — the full card, its Open and
    /// transport live.
    private func applyHover() {
        guard hoverHeld, settings.expandOnHover, activeCapsule == nil else { return }
        expand(held: false)
    }

    /// The face the window should wear right now — a capsule outranks
    /// the card, the card outranks idle.
    private var currentFace: NotchIslandFace {
        activeCapsule != nil ? .notice : (islandExpanded ? .expanded : .idle)
    }

    /// Resize the window to `face`'s frame — the island morphs in place;
    /// there is never a second panel. A request already in flight is not
    /// re-issued (the window's frame spring retargets rather than
    /// restart, but a no-change ask is still no ask). A nudge too small
    /// to see (a session row's label settling by a point) applies
    /// without animation — animating a sub-2 pt delta reads as jitter.
    /// A morph landing mid-pull owns the frame: the pull lets go
    /// without a verdict rather than fight the spring.
    private func reframe(_ face: NotchIslandFace, animated: Bool) {
        guard let frame = islandFrame(face: face) else { return }
        guard frame != desiredFrame else { return }
        if pullActive {
            pullActive = false
            island?.cancelPull()
        }
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
    private func islandFrame(face: NotchIslandFace) -> NSRect? {
        _ = displayVersion
        guard let screen = ScreenBarGeometry.preferredScreen() else { return nil }
        let slot = NotchIslandLayout.slot(left: screen.auxiliaryTopLeftArea,
                                          right: screen.auxiliaryTopRightArea)
        let depth = ScreenBarGeometry.notchDepth(of: screen)
        let centerX = slot?.centerX ?? screen.frame.midX
        let size: CGSize
        switch face {
        case .notice:
            size = NotchIslandLayout.noticeSize(slotWidth: slot?.width ?? 0,
                                                notchDepth: depth,
                                                ledClearance: ledClearance)
        case .expanded:
            let width = NotchIslandLayout.expandedWidth(slotWidth: slot?.width ?? 0)
            let content = island?.expandedCardHeight(width: width) ?? 0
            size = CGSize(width: width,
                          height: NotchIslandLayout.expandedTopInset(
                              notchDepth: depth, ledClearance: ledClearance)
                              + content)
        case .idle:
            // Notched: each shoulder carries its own content, the slot
            // stays the notch. Notch-less: the floating pill wraps the
            // row.
            let layout = idleLayout
            var idle = depth > 0
                ? NotchIslandLayout.idleSize(
                    slotWidth: slot?.width ?? 0, notchDepth: depth,
                    leftShoulder: layout.leftShoulder, rightShoulder: layout.rightShoulder)
                : NotchIslandLayout.floatingSize(
                    contentWidth: NotchIsland.idleContentWidth(islandSummary, media: idleMedia))
            if islandHoverPeek {
                // The wink's frame half — a few points of grow under
                // the pointer, symmetric, never the card. Width only:
                // a taller housing would drop below the hardware.
                idle.width += 2 * NotchIslandLayout.peekGrow
            }
            size = idle
            if depth > 0, let slot {
                return NotchIslandLayout.frame(
                    screenFrame: screen.frame,
                    centerX: NotchIslandLayout.idleCenterX(
                        slotCenterX: slot.centerX, leftShoulder: layout.leftShoulder,
                        rightShoulder: layout.rightShoulder),
                    size: size)
            }
        }
        return NotchIslandLayout.frame(
            screenFrame: screen.frame, centerX: centerX, size: size,
            topInset: slot == nil ? NotchIslandLayout.floatingTopInset : 0)
    }

    /// The media the idle capsule draws — nil when the user switched
    /// Now Playing off, so the strip and its width vanish together.
    private var idleMedia: AlcoveMedia? {
        settings.mediaEnabled ? islandMedia : nil
    }

    /// One place that reads the settings and makes the panel match:
    /// ordered in and framed while the island is ours, enabled and shown;
    /// fully ordered out otherwise — a parked island runs no timers.
    private func reconcile() {
        // Sessions, usage or the focus may have moved while the card is
        // grown — refill before the frame re-measures its height.
        if islandExpanded { feedCard() }
        let s = settings
        guard s.enabled, s.provider == .jrbar, s.islandEnabled,
              islandFrame(face: currentFace) != nil else {
            parkIsland()
            return
        }
        if island == nil { island = NotchIslandWindow(toy: self) }
        // Content-driven size changes — a dot arriving, the media strip
        // coming or going, the grown card's rows refilling — ease like
        // any face morph: `reframe` keeps the no-change guard and the
        // sub-2 pt nudge rule, and a raw `setFrame` here would snap an
        // in-flight morph the doc churn used to kill. `applyFrame`
        // itself snaps while the window is ordered out, so a first
        // show still lands unanimated.
        reframe(currentFace,
                animated: !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion)
        if island?.isVisible != true {
            island?.orderFrontRegardless()
        }
        islandVisible = true
        publishSurface()
        syncMediaMonitor()
        syncPowerMonitor()
    }

    /// The glass card's presenter reads the same `notchSurface` answer
    /// through `NotchCardPresenter.publishedSurface` — pushed here on
    /// every reconcile so a settings flip that never moves the island
    /// (the utility off, a provider swap while parked) still reaches it.
    private func publishSurface() {
        NotchCardPresenter.publishedSurface = notchSurface
    }

    /// Ordered out and collapsed. The window object stays — a re-show is
    /// a frame, not a rebuild — but nothing in it ticks while hidden:
    /// the capsule timers die and the media listener lets go.
    private func parkIsland() {
        islandExpanded = false
        expandHeld = false
        bandExpandPending = false
        cardModel.pinned = false
        syncCardKeyMonitors()
        hoverHeld = false
        islandHoverPeek = false
        pullActive = false
        island?.cancelPull()
        island?.cancelSpring()
        expandWork?.cancel()
        expandWork = nil
        activeCapsule = nil
        shelvedCapsule = nil
        capsuleWork?.cancel()
        capsuleWork = nil
        collapseWork?.cancel()
        collapseWork = nil
        capsuleQueue.clear()
        desiredFrame = nil
        islandVisible = false
        publishSurface()
        island?.orderOut(nil)
        syncMediaMonitor()
        syncPowerMonitor()
    }

    // MARK: Event capsules

    /// `EventCoordinator.apply` hands every daemon event here, next to
    /// the confetti call. `AlcoveEventPolicy` decides whether it earns a
    /// capsule; the queue's cooldown keeps a burst of asks from strobing
    /// the notch. While the card is grown the event is already visible
    /// in its rows — a capsule over it would only blink — so a grown
    /// island eats them quietly.
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
    /// The queue itself is newest-wins (`AlcoveCapsuleQueue`); the
    /// waiting slot's priority is policed here at the door: a
    /// lower-priority offer never displaces a capsule already queued —
    /// an arriving power blip does not push a waiting ask aside, it
    /// simply never enters (and so never spends its key's cooldown).
    /// Internal so tests can drive the queue straight — `noteEvent` and
    /// the power path both land here.
    func offer(_ notice: AlcoveNotice) {
        if let pending = capsuleQueue.pending,
           notice.kind.queueRank > pending.kind.queueRank { return }
        switch capsuleQueue.offer(notice, at: Date()) {
        case .now: showCurrentCapsule()
        case .after(let delay): scheduleCapsuleShow(after: delay)
        case .queued, .suppressed: break
        }
    }

    /// Draw `capsuleQueue.current` as the island's face and arm its life
    /// timer. A grown island already tells the event's story in its
    /// rows — a capsule queued before the grow simply does not draw.
    private func showCurrentCapsule() {
        guard capsuleQueue.current != nil, islandVisible, !islandExpanded else { return }
        activeCapsule = capsuleQueue.current
        reframe(.notice, animated: !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion)
        armCapsuleLife()
    }

    /// The 2.4 s a shown capsule holds before `finishCapsule` steps it
    /// down — the same arm a collapse-restored capsule gets.
    private func armCapsuleLife() {
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
    /// whatever the cursor currently wants — idle, or the card a
    /// mid-capsule hover earned.
    /// Internal so tests can end a capsule's run without sleeping out
    /// its whole life.
    func finishCapsule() {
        // The firing work item cancels itself cleanly; a direct call
        // (tests, dismiss paths) must not leave the life timer armed.
        capsuleWork?.cancel()
        capsuleWork = nil
        switch capsuleQueue.finish(at: Date()) {
        case .idle:
            activeCapsule = nil
            settleToRest()
        case .now:
            activeCapsule = nil
            showCurrentCapsule()
        case .after(let delay, _):
            activeCapsule = nil
            settleToRest()
            // The settle may have grown the card — `expand` shelved the
            // promoted capsule (it stays `current`; the shelf IS the
            // queue's slot) — so the gap timer only arms when the
            // island settled to rest with a capsule still waiting to
            // be drawn. Firing it under the card would just land in
            // `showCurrentCapsule`'s early return.
            if !islandExpanded, capsuleQueue.current != nil {
                scheduleCapsuleShow(after: delay)
            }
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
        shelvedCapsule = nil
        hoverHeld = false
        islandHoverPeek = false
        // A dismissal eats a remembered band click too — the swipe is
        // "go away", so the card must not pop open off the back of it.
        bandExpandPending = false
        settleToRest()
    }

    /// Back to the face the cursor wants: a remembered band click grows
    /// the card, a remembered hover grows it too, or nothing — the
    /// capsule just stepped down. The grow runs INSTEAD of the idle
    /// reframe, not after it: easing to idle and then straight back out
    /// reads as the island dipping under the capsule's feet.
    private func settleToRest() {
        if bandExpandPending {
            bandExpandPending = false
            expand(held: true)
            return
        }
        // The face that just stepped down is wider than idle — the
        // notice carries a line of copy. A cursor over its shoulder is
        // already outside the resting capsule, and the tracking-area
        // exit lands a tick after this pass. Re-check the real pointer
        // against the resting frame before trusting the remembered
        // hover: the card must never grow out from under a cursor that
        // already left.
        if hoverHeld, let resting = islandFrame(face: .idle),
           !resting.contains(NSEvent.mouseLocation) {
            hoverHeld = false
        }
        islandHoverPeek = hoverHeld
        if hoverHeld { applyHover() }
        reframeCurrent(animated: !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion)
    }

    // MARK: Now Playing

    /// The feed subscription lives exactly as long as the island is
    /// shown with `mediaEnabled` on; `reconcile`/`parkIsland` both land
    /// here. The feed itself is shared with the card's row, so the two
    /// can never disagree about the track.
    private func syncMediaMonitor() {
        let want = islandVisible && settings.mediaEnabled
        if want {
            if mediaToken == nil {
                mediaToken = mediaFeed.subscribe { [weak self] media in self?.noteMedia(media) }
            }
        } else {
            if let mediaToken { mediaFeed.unsubscribe(mediaToken) }
            mediaToken = nil
            if islandMedia != nil {
                islandMedia = nil
                reframeCurrent(animated: false)
            }
        }
    }

    /// A now-playing refresh landed: keep the media, and reframe — the
    /// strip changes the idle width. The capsule face does not measure
    /// media, so a mid-capsule update just waits.
    private func noteMedia(_ media: AlcoveMedia?) {
        guard media != islandMedia else { return }
        islandMedia = media
        if currentFace != .notice {
            reframeCurrent(animated: !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion)
        }
    }

    /// The island's swipe transport lands here.
    func mediaNextTrack() { mediaFeed.send(.nextTrack) }
    func mediaPreviousTrack() { mediaFeed.send(.previousTrack) }

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

    // MARK: Tap

    /// A tap on the island itself — the view's tap gesture. The card
    /// toggles: grown folds, resting grows (the same deliberate pin a
    /// band click earns — a tap is a click, so outside-click and Esc
    /// still let it go), and a showing capsule dismisses — a tap on
    /// news puts it away, it never re-opens it.
    func islandTapped() {
        guard isDrawingIsland, !foldEngaged else { return }
        if islandExpanded {
            collapseIsland()
        } else if activeCapsule != nil {
            dismissCapsule()
        } else {
            expandFromBand()
        }
    }

    // MARK: Pull

    /// The press-and-pull engaged — the window's finger-following
    /// stretch is live. While it runs, `pullActive` keeps the hover
    /// debounce from folding the card the finger is holding; the
    /// pending hover-expand cancels too — the pull IS the intent.
    func islandPullBegan() {
        pullActive = true
        collapseWork?.cancel()
        collapseWork = nil
        expandWork?.cancel()
        expandWork = nil
    }

    /// The pull let go — `verdict` is the pure machine's call. A commit
    /// is the surface's act: the resting island's pull-down is the
    /// swipe-down's own truth (open on idle, dismiss on a capsule,
    /// fold on the card — `islandSwipe(.down)` already says it). A
    /// retreat springs the frame back to wherever the island's face
    /// wants it; a pull that never engaged stays the click it was.
    func islandPullEnded(_ verdict: NotchPullGesture.Verdict) {
        pullActive = false
        switch verdict {
        case .commit:
            islandSwipe(.down)
        case .retreat:
            // A pull that ended off the island is a leave the debounce
            // never saw — re-check the real pointer against the frame
            // the face actually wants before it stays grown.
            if islandExpanded, !expandHeld,
               let resting = desiredFrame ?? islandFrame(face: currentFace),
               !resting.contains(NSEvent.mouseLocation) {
                hoverHeld = false
                islandHoverPeek = false
                scheduleCollapseCheck()
            }
        case .click:
            break
        }
        // Either way the window lands on its face's frame — the
        // verdict's own path reframed when it acted; a refused commit
        // (gestures switched off mid-pull) still settles.
        if let frame = desiredFrame {
            island?.applyFrame(frame,
                               animated: !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion)
        }
    }

    // MARK: Swipe

    /// A two-finger swipe on the island, read off the hosting view's
    /// scroll events — or the pull's commit verdict, which means the
    /// same thing. Horizontal rides the media transport — only while
    /// the island is actually showing a track, so a stray swipe never
    /// pokes a player we aren't displaying. Down folds the open card
    /// back under the notch, dismisses the capsule, and — on the plain
    /// resting island — is the pull-open: the same deliberate grow a
    /// band click earns.
    func islandSwipe(_ swipe: NotchIslandSwipe) {
        guard settings.pullGestures else { return }
        switch swipe {
        case .left:
            if islandMedia != nil { mediaNextTrack() }
        case .right:
            if islandMedia != nil { mediaPreviousTrack() }
        case .down:
            if islandExpanded {
                // The swipe folds the grown card — and it is a
                // dismissal, so a capsule shelved beneath it goes with
                // it: collapsing alone would only replay the shelf as
                // a fresh notice where the card just was.
                if capsuleQueue.current != nil || shelvedCapsule != nil {
                    capsuleWork?.cancel()
                    capsuleWork = nil
                    capsuleQueue.cancel(at: Date())
                    shelvedCapsule = nil
                }
                collapseIsland()
            } else if activeCapsule != nil || capsuleQueue.current != nil {
                dismissCapsule()
            } else {
                // The pull-open: a down swipe on the resting island
                // grows the card, deliberately — it holds like a band
                // click, not like a hover.
                expand(held: true)
            }
        }
    }

    /// One observation pass over every input, re-armed on each change —
    /// the same pattern `NotchBuddyToy.observeSessions` uses.
    private func observe() {
        withObservationTracking {
            _ = store?.state.notch
            _ = core.sessions
            _ = core.state?.usage
            _ = core.settings?.document   // virtual_status_device_enabled → ledClearance; screen_bar_notch_wings → earsDrawn
            _ = displayVersion
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.reconcile()
                self.observe()
            }
        }
    }

    // MARK: Controls

    /// A binding into `store.state.notch`; the store's `didSet`
    /// debounces the write.
    func bind<T>(_ keyPath: WritableKeyPath<NotchSettings, T>) -> Binding<T> {
        Binding(
            get: { self.store?.state.notch[keyPath: keyPath] ?? NotchSettings()[keyPath: keyPath] },
            set: { self.store?.state.notch[keyPath: keyPath] = $0 })
    }

    var providerBinding: Binding<NotchProvider> {
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
        AnyView(NotchControlsView(toy: self))
    }
}

/// The card's disclosure body. Every toggle writes `store.state.notch`
/// (which persists itself) except the provider picker, which goes
/// through `setProvider` so the swap can park our island and open theirs.
private struct NotchControlsView: View {
    let toy: NotchToy

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Picker(selection: toy.providerBinding) {
                Text("JR-Bar").tag(NotchProvider.jrbar)
                Text("Alcove").tag(NotchProvider.alcove)
                Text("Boring Notch").tag(NotchProvider.boringNotch)
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
                             subtitle: toy.earsDrawn
                                ? "The housing under the notch — hover or click it for the card. The Screen Bar's ears are drawing the HUD beside it, so the island itself stays bare."
                                : "The housing under the notch: working agents in the left shoulder, asks or the track in the right. Hover or click it for the card.")
            }
            Toggle(isOn: toy.bind(\.expandOnHover)) {
                SettingLabel(title: "Card on hover",
                             subtitle: "A pointer that rests on the notch for a third of a second grows the card. Off, only a click or a pull opens it.")
            }
            Toggle(isOn: toy.bind(\.pullGestures)) {
                SettingLabel(title: "Pull & swipe gestures",
                             subtitle: "Drag the island down to open it; swipe or pull down to fold it away.")
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
                             subtitle: toy.earsDrawn
                                ? "The card carries the track and transport buttons. (The island's own strip is off while the Screen Bar's ears draw.)"
                                : "The right shoulder carries the track when nothing needs a hand; the card gains transport buttons.")
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
