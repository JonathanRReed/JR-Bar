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
/// under that provider and the follower only runs while this toy names
/// Alcove (`publishRenderer`). The island's frame is always exactly its drawn
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
    /// Poked on every reconcile so the HUD can start or drop its
    /// media-key tap as the notch gates move.
    var onMediaGateChanged: @MainActor () -> Void = {}
    /// Bumped on every app launch/terminate so the external-provider
    /// checks re-read `NSWorkspace` — and the only thing that renews the
    /// shelf rivals answer (`shelfRivalsNow`).
    private(set) var workspaceVersion = 0

    /// An app launched or quit: the external-provider checks re-read,
    /// and Dropover opening or quitting moves the shake's yield at once.
    /// Internal so the tests can stand in for the workspace's note.
    func noteWorkspaceChange() {
        workspaceVersion += 1
        syncShakeMonitor()
    }
    /// Bumped on display-parameter changes so the island reframes.
    private(set) var displayVersion = 0
    /// Whether the island panel is ordered in — the view's pulse pauses
    /// on `false` so a parked island runs no clock at all. The setter is
    /// internal so tests can run the capsule flow without a panel.
    var islandVisible = false
    /// The notification capsule on screen, if any — Alcove's instant
    /// notification: the island's only face besides idle.
    var activeCapsule: AlcoveNotice?
    /// Key feedback drawn over the face — a level, Caps Lock
    /// (`AlcoveCapsuleQueue.present`). It outranks a transient capsule
    /// for its short beat and never covers a latched ask.
    var activeOverlay: AlcoveNotice?
    @ObservationIgnored var overlayWork: DispatchWorkItem?
    /// Per ask notice id: when it was offered and whether its ask has
    /// shown up in the state yet — `NotchIsland.askStillOpen`'s inputs.
    @ObservationIgnored private var askTrack: [String: (offered: Date, seen: Bool)] = [:]
    /// What Now Playing reports, nil while MediaRemote is absent, off,
    /// or has nothing playing. The view reads it for the idle strip.
    private(set) var islandMedia: AlcoveMedia?
    /// The raw hover state: the island's `.onHover` writes it; the card
    /// it may grow drops when the hover — and any capsule in the way —
    /// is done.
    var hoverHeld = false
    /// The hover wink: a cursor ON the island earns a few points of
    /// grow — proof of life — while the intent debounce decides whether
    /// this was a pause that meant the card. The view swells the dots
    /// on it; `islandFrame` grows the idle frame on it.
    var islandHoverPeek = false
    /// The intent debounce — a cursor pausing this long on the resting
    /// island meant it; a pointer cutting across only ever earns the
    /// wink. Armed in `setHovered`, fires `hoverExpandFired`.
    @ObservationIgnored var expandWork: DispatchWorkItem?
    /// The breath's own intent delay — `NotchMotion.hoverDelay` of a
    /// resting cursor earns the few-points grow; a sweep past never
    /// arms it.
    @ObservationIgnored var peekWork: DispatchWorkItem?
    /// The press-and-pull is live — the finger owns the frame, so the
    /// hover debounce must not fold the card the finger is holding and
    /// a mid-pull morph calls `cancelPull` rather than fight it.
    var pullActive = false
    /// The island is grown into the card right now.
    private(set) var islandExpanded = false
    /// A band click's deliberate expand — survives pointer-leave until
    /// an outside click, a swipe-down or Esc lets it go; a hover's own
    /// expand answers to the leave debounce alone.
    var expandHeld = false
    /// A band click landed mid-capsule — the capsule owns the island
    /// until it steps down, then the expand lands.
    var bandExpandPending = false
    /// Esc lets the card go — the island never becomes key, so the toy
    /// watches for it while grown.
    @ObservationIgnored private var cardKeyMonitors: [Any] = []
    /// The frame last asked of the window — `reconcile` re-runs on every
    /// sessions doc, and a no-change applyFrame would snap an in-flight
    /// morph (the capsule slide-in dies on the doc that follows its
    /// event). Same target, no re-apply.
    @ObservationIgnored var desiredFrame: NSRect?
    /// The capsule decisions — pure, in `AlcoveCapsuleQueue`; the toy
    /// only owns the timers that run them.
    @ObservationIgnored var capsuleQueue = AlcoveCapsuleQueue()
    /// The pending capsule timer — the show-delay gap or the 2.4 s life.
    @ObservationIgnored var capsuleWork: DispatchWorkItem?
    /// Where the line's timers are armed — a shown capsule's life and
    /// the gap before the next — and the clock the line runs on: the
    /// queue's gaps and cooldowns, a shelved capsule's freshness. The
    /// main queue and the wall clock; the tests hand in a manual pair
    /// and step the line by hand, so a proof about it never waits on a
    /// main queue the suite is crowding.
    @ObservationIgnored var capsuleTimer: (TimeInterval, DispatchWorkItem) -> Void = { delay, work in
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }
    @ObservationIgnored var capsuleClock: () -> Date = { Date() }
    /// A notice the island took, then gave up from the waiting slot to
    /// newer news of equal or higher rank (`AlcoveCapsuleQueue.onEvict`)
    /// — reported here instead of vanishing. The delegate hands the
    /// Mac's own announcements among them to the HUD's pill; the agents'
    /// news is still on the card's rows.
    @ObservationIgnored var onCapsuleEvicted: (AlcoveNotice) -> Void = { _ in }
    /// A capsule promoted into its show-gap the moment the island grew:
    /// it could never draw over the card, so `expand` shelves it here
    /// and `collapseIsland` re-shows it while it is still fresh.
    @ObservationIgnored var shelvedCapsule: (notice: AlcoveNotice, at: Date)?
    /// The Now Playing reader's token on the shared feed; held only
    /// while the island is ours, shown, and `mediaEnabled`. A parked
    /// island holds no listener.
    @ObservationIgnored private var mediaToken: UUID?
    /// The shared Now Playing source — one helper for every surface.
    @ObservationIgnored private let mediaFeed: MediaFeed
    /// The island's subscription to the shared power feed; exists only
    /// while the island is ours, shown, and `capsuleNotifications` +
    /// `capsuleKinds.charging` are on.
    @ObservationIgnored private var powerMonitor: AlcovePowerMonitor?
    /// The mic/camera poller; exists only while the island is ours,
    /// shown, and the indicators switch is on.
    @ObservationIgnored private var sensorMonitor: NotchSensorMonitor?
    /// The calendar's background heads-up and live-meeting reader —
    /// only while the island is shown with `meetingAlerts` on.
    @ObservationIgnored let meetingWatch = ShelfMeetingWatch()
    /// The meeting the heads-up on screen is about — its face reads the
    /// times and the link off it.
    @ObservationIgnored private(set) var headsUpMeeting: ShelfCalendarModel.Event?
    /// What the idle face reads for its privacy dots — quiet while the
    /// monitor is off or nothing is live.
    private(set) var sensorState = NotchSensorState()
    /// The mic/camera dots' own switch — app-local persistence under a
    /// `jrbar.*` defaults key, the same place the island's wing hints
    /// keep theirs (`NotchCardView`). `NotchSettings` is ToysState's and
    /// not this file's to extend; default on, like the hardware LED it
    /// mirrors.
    static let sensorIndicatorsDefaultsKey = "jrbar.notchSensorIndicators"
    var sensorIndicatorsEnabled = true {
        didSet {
            guard sensorIndicatorsEnabled != oldValue else { return }
            UserDefaults.standard.set(sensorIndicatorsEnabled,
                                      forKey: Self.sensorIndicatorsDefaultsKey)
            if !sensorIndicatorsEnabled { sensorState = NotchSensorState() }
            syncSensorMonitor()
            reframeCurrent(animated: false)
        }
    }
    /// The hover-leave timer — a short delay so a cursor grazing the
    /// island's edge doesn't flap the card.
    @ObservationIgnored var collapseWork: DispatchWorkItem?
    @ObservationIgnored var island: NotchIslandWindow?
    @ObservationIgnored private var observers: [NSObjectProtocol] = []
    /// Production owns AppKit windows and system readers. State-machine
    /// tests opt out before observation starts, so no later settings
    /// change can accidentally reconcile a real surface into the test.
    @ObservationIgnored var runtimeEnabled: Bool

    /// The island's faces on the same window — idle capsule, the
    /// one-line notice capsule, the ask (a two-line capsule with its
    /// verbs, or the takeover card), the grown card.
    enum NotchIslandFace { case idle, notice, ask, expanded }

    init(core: CoreModel, store: ToysStore, cardModel: NotchCardModel,
         mediaFeed: MediaFeed? = nil, runtimeEnabled: Bool = true) {
        self.core = core
        self.store = store
        self.cardModel = cardModel
        self.mediaFeed = mediaFeed ?? MediaFeed.shared
        self.runtimeEnabled = runtimeEnabled
        sensorIndicatorsEnabled = UserDefaults.standard.object(
            forKey: Self.sensorIndicatorsDefaultsKey) as? Bool ?? true
        // The queue only ever runs on the main actor, inside the toy's
        // own calls — its eviction report lands back here in turn.
        capsuleQueue.onEvict = { [weak self] notice in
            MainActor.assumeIsolated { self?.onCapsuleEvicted(notice) }
        }
        cardModel.onOpenRow = { [weak self] session in self?.openFromCard(session) }
        cardModel.onClose = { [weak self] in self?.collapseIsland() }
        cardModel.onDropHover = { [weak self] in self?.shelfDragMoved() }
        cardModel.onDropLanded = { [weak self] in self?.shelfDragLanded() }
        cardModel.onOpenSession = { [weak self] in
            guard let self, let session = self.cardModel.focus.clickSession else { return }
            self.openFromCard(session)
        }
        cardModel.onOpenOverview = { [weak self] in self?.onOpenOverview() }
        cardModel.mirrorEnabled = { [weak self] in self?.settings.mirror ?? false }
        cardModel.utility.weather.allowIPLocation = { [weak self] in
            self?.settings.weatherUseIPLocation ?? false
        }
        wireLyrics(cardModel.utility.lyrics)
        cardModel.heldAwake = { [weak self] in self?.core.state?.power?.keepAwake == true }
        // A due timer morphs the island into its capsule, and a nudge
        // about a run only speaks while that run is still working.
        cardModel.timers.onFireNotice = { [weak self] entry in
            self?.flashLightsForTimer()
            self?.noteTimerFired(entry)
        }
        cardModel.timers.firePredicate = { [weak self] entry in
            guard let session = entry.watchSession else { return true }
            return self?.sessionStillWorking(session) ?? true
        }
        cardModel.calendarEnabled = { [weak self] in self?.settings.calendar ?? true }
        cardModel.remindersEnabled = { [weak self] in self?.settings.reminders ?? true }
        // The shelf's own rows: one tray serves both card surfaces, so
        // the settings ride the tray itself.
        cardModel.tray.newestFirst = { [weak self] in self?.settings.shelfNewestFirst ?? false }
        cardModel.tray.dragOutPolicy = { [weak self] in self?.settings.shelfDragOut ?? .copy }
        cardModel.tray.removeAfterDragOut = { [weak self] in self?.settings.shelfRemoveAfterDragOut ?? false }
        cardModel.tray.shelfEnabled = { [weak self] in self?.settings.shelfEnabled ?? true }
        cardModel.sessionCwd = { [weak self] id in self?.core.state?.session(withID: id)?.cwd }
        // A meeting about to start says so; one running is a quiet
        // stretch, and its end may replay what it held.
        meetingWatch.onSoon = { [weak self] event in self?.noteMeetingSoon(event) }
        meetingWatch.onLiveChange = { [weak self] _ in self?.noteQuietChange() }
        audioTap.onLevels = { [weak self] bands in
            self?.cardModel.utility.audioLevels = bands
        }
        // The row follows the tap's own edges: the start lands after
        // `sync` returns, and a dead tap must drop its bars at once.
        audioTap.onLiveChange = { [weak self] live in
            guard let utility = self?.cardModel.utility else { return }
            utility.audioTapLive = live
            if !live { utility.audioLevels = [Float](repeating: 0, count: utility.audioLevels.count) }
        }
        guard runtimeEnabled else { return }
        let workspace = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.didLaunchApplicationNotification,
                     NSWorkspace.didTerminateApplicationNotification] {
            observers.append(workspace.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.noteWorkspaceChange() }
            })
        }
        observers.append(NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                // "Where the pointer is" seats afresh when screens come
                // and go — the only moments besides a Space change.
                ScreenBarGeometry.reseatPointer()
                self?.displayVersion += 1
            }
        })
        observers.append(workspace.addObserver(
            forName: NSWorkspace.activeSpaceDidChangeNotification, object: nil, queue: .main
        ) { _ in
            MainActor.assumeIsolated { ScreenBarGeometry.reseatPointer() }
        })
        // The Display pick or its seat moved the island: reframe there.
        observers.append(NotificationCenter.default.addObserver(
            forName: ScreenBarGeometry.preferredScreenDidChange, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.displayVersion += 1 }
        })
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
            // Ears drawn or island drawn, the notch HUD is live either
            // way — the delegated mode is not a lesser state to badge.
            return .on
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
        if runtimeEnabled { publishRenderer() }
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

    /// The Screen Bar's Alcove following is opt-in by this pick: it runs
    /// only while the utility is on with Alcove drawing the notch.
    private func publishRenderer() {
        AlcoveFollower.noteRenderer(chosen: settings.enabled && settings.provider == .alcove)
    }

    func openExternal() {
        guard let url = externalURL else { return }
        NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration()) { _, _ in }
    }

    // MARK: Island

    /// The capsule's contents, reduced by `NotchIsland` — the view reads
    /// this and `core.sessions` is observed, so it never sits stale.
    var islandSummary: NotchIslandSummary { NotchIsland.summarize(core.sessions, asks: core.asks) }

    /// The island's on-screen frame — part of the band's shared hover
    /// region while the island is up.
    var islandScreenRect: NSRect? {
        guard islandVisible else { return nil }
        // The Screen Bar follows each presented spring frame, including
        // interrupted expansions and pulls, rather than jumping to its goal.
        return island?.frame ?? desiredFrame
    }

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
        let slot = ScreenBarGeometry.islandSlot(on: screen)
        return NotchIslandLayout.expandedWidth(slotWidth: slot?.width ?? 0)
    }

    /// The grown card's top pad — past the notch's own depth and its
    /// inset, so the card's content starts clear of the bezel.
    var cardTopPad: CGFloat {
        NotchIslandLayout.expandedTopInset(notchDepth: notchDepth)
    }

    /// Points of the notice's foot the Screen Bar's housing draws over —
    /// the view centres the line above them. Zero while no housing
    /// couples under the island.
    var noticeClimb: CGFloat {
        _ = displayVersion
        guard let screen = ScreenBarGeometry.preferredScreen(),
              let corner = housingCorner(on: screen) else { return 0 }
        let depth = ScreenBarGeometry.islandDepth(of: screen)
        let size = NotchIslandLayout.noticeSize(
            slotWidth: ScreenBarGeometry.islandSlot(on: screen)?.width ?? 0,
            notchDepth: depth, underHousing: corner)
        return NotchIslandLayout.housingClimb(size: size, notchDepth: depth, restingRadius: corner)
    }

    /// Points of the ask face's foot the Screen Bar's housing draws over
    /// — the ask's verbs stand clear of it. Zero while no housing
    /// couples under the island or no ask is up.
    var askClimb: CGFloat {
        _ = displayVersion
        guard let screen = ScreenBarGeometry.preferredScreen(),
              let corner = housingCorner(on: screen),
              let size = askFaceSize(on: screen) else { return 0 }
        return NotchIslandLayout.housingClimb(size: size,
                                              notchDepth: ScreenBarGeometry.islandDepth(of: screen),
                                              restingRadius: corner)
    }

    /// The ask face's size on `screen` for the capsule up now — nil
    /// while the capsule is not an ask. The frame and the climb read
    /// the same measure.
    private func askFaceSize(on screen: NSScreen) -> CGSize? {
        guard let capsule = activeCapsule, capsule.kind.hasVerbs else { return nil }
        return NotchIslandLayout.askSize(
            slotWidth: ScreenBarGeometry.islandSlot(on: screen)?.width ?? 0,
            notchDepth: ScreenBarGeometry.islandDepth(of: screen),
            summaryLines: askSummaryLines, takeover: capsule.takeover,
            underHousing: housingCorner(on: screen))
    }

    /// Lines the ask face gives its summary: one on the capsule, as many
    /// as the takeover card's width needs (capped) — decided here so the
    /// frame is exactly the drawn copy. The takeover counts the command
    /// the agent wants to run too, so the card grows to show it rather
    /// than cutting it at the first line's end.
    var askSummaryLines: Int {
        _ = displayVersion
        guard let capsule = activeCapsule, capsule.kind == .ask, capsule.takeover else { return 1 }
        let slot = ScreenBarGeometry.preferredScreen().flatMap { ScreenBarGeometry.islandSlot(on: $0) }
        let width = NotchIslandLayout.askWidth(slotWidth: slot?.width ?? 0, takeover: true)
        let copy = [askSummary(capsule), liveAsk(for: capsule)?.previewLine]
            .compactMap { $0 }.joined(separator: " · ")
        return NotchIslandLayout.askSummaryLines(copy, width: width,
                                                 maxLines: NotchIslandLayout.askTakeoverLines)
    }

    /// The resting corner the Screen Bar's housing is measured with
    /// while it couples under the island — only when the bar is up on a
    /// real notch (a simulated one keeps the standalone band), nil
    /// otherwise.
    private func housingCorner(on screen: NSScreen) -> CGFloat? {
        guard screenBarLive, ScreenBarGeometry.notchDepth(of: screen) > 0 else { return nil }
        return notchCornerRadius
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
        return ScreenBarGeometry.islandDepth(of: screen)
    }

    /// Whether the Screen Bar's band is on screen — wired by the
    /// delegate to `PanelStore.screenBarShown`, the flag the show/hide
    /// calls flip with the window. The daemon's
    /// `virtual_status_device_enabled` doc is deliberately NOT the read:
    /// it freezes stale whenever the core link drops, and a dead monitor
    /// left this false while the bar drew — the island grew its own
    /// shoulders over the bar's ears, a ~500 pt black slab paving the
    /// menu-bar items under it.
    var screenBarShown: @MainActor () -> Bool = { false }

    /// Whether the Screen Bar is up.
    var screenBarLive: Bool { screenBarShown() }

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
        NotchIsland.idleLayout(islandSummary, media: idleMedia, earsDrawn: earsDrawn,
                               sensors: sensorIndicatorsEnabled ? sensorState : NotchSensorState())
    }

    /// True while Fold's overlay is covering the screen — the island is
    /// invisible under it, so its window must let clicks fall through.
    var foldEngaged: Bool { store?.fold?.overlayOnScreen ?? false }

    /// The hover path: a cursor on the resting island earns the wink —
    /// a few points of grow (`islandHoverPeek`), never the card — and
    /// only a cursor that STAYS, past `hoverDelays.expand`, earns the
    /// grow `expandOnHover` promised. A pointer cutting across the
    /// notch to reach a menu gets the wink and nothing else; that is
    /// the whole reason the debounce exists — and why an arrival by the
    /// menu bar's row floors at `NotchMotion.barArrivalFloor` while one
    /// straight onto the island answers quicker. On the grown card the
    /// hover just holds it open — the card IS the island's window, so
    /// the pointer wandering down into the rows is still the same
    /// hover — and leaving folds it on the short `collapseDelay`, so a
    /// brief leave-and-return doesn't ping-pong it. A showing capsule
    /// owns the island, so the hover is only remembered then — it
    /// lands its grow when the capsule steps down.
    private static let collapseDelay: TimeInterval = 0.18
    /// How long a resting pointer waits for the card, and for the breath
    /// before it: the Notch card's "Open after" (Alcove-quick 0.12 s by
    /// default — a pointer that reaches the notch itself wants the card),
    /// floored for an arrival down from the menu bar's row, which may
    /// only be reaching a menu (`NotchMotion.hoverDelays`).
    private var hoverDelays: (peek: TimeInterval, expand: TimeInterval) {
        NotchMotion.hoverDelays(openAfter: settings.hoverOpenDelay, fromBar: hoverArrivedFromBar)
    }
    /// The arrival path of the current hover, latched on the enter
    /// edge: an ear or tray landing starts the longer clock, and the
    /// pointer crossing on to the island mid-pause keeps it.
    private var hoverArrivedFromBar = false

    /// Whether the pointer is on the Screen Bar's region — its ears,
    /// tray or the island — right now. The band's hover is the
    /// island's hover; a leave from the island's own window onto an
    /// ear is not a leave.
    var pointerOnBand: @MainActor () -> Bool = { false }

    /// ⌃⌥D and `jrbar://shelf` while the band's glass card is the
    /// notch's surface — the delegate hands in the band's own toggle
    /// (`ScreenBarInteraction.toggleShelfCard`). nil once it acted, else
    /// the sentence a link says.
    var toggleGlassShelf: @MainActor () -> String? = { "JR-Bar is still starting." }

    /// The grown card's target frame, published for the HUD's toast
    /// anchor — a pill hung under the band while the card is open
    /// would land on its face. Same write/read discipline as
    /// `NotchCardPresenter.publishedSurface`: main actor only. The
    /// island morphs in place, so the target frame — not the
    /// mid-spring one — is the honest answer.
    nonisolated(unsafe) static var publishedExpandedRect: NSRect?

    /// The island's screen reserving no menu-bar strip — a fullscreen
    /// app owns its space (the legacy `space_hides_menu_bar` read). A
    /// closure so tests can answer without a screen.
    var menuBarHidden: @MainActor () -> Bool = {
        ScreenBarGeometry.preferredScreen().map(ScreenBarGeometry.spaceHidesMenuBar) ?? false
    }

    /// The grow's felt edge — a soft trackpad tap as the card lands.
    /// A closure so tests hear it without haptic hardware.
    var expandHaptic: @MainActor () -> Void = {
        NSHapticFeedbackManager.defaultPerformer.perform(.generic, performanceTime: .now)
    }

    /// The band's hover, forwarded: the ears are the island's hover
    /// surface while the island owns the notch.
    func bandHover(_ hovering: Bool, fromBar: Bool = false) {
        setHovered(hovering, fromBar: fromBar)
    }

    func setHovered(_ hovering: Bool, fromBar: Bool = false) {
        let s = settings
        guard s.enabled, s.provider == .jrbar, s.islandEnabled else { return }
        // The island window's own leave is not a leave while the
        // pointer is still on the band's surface — stepping from the
        // housing onto the tray or an ear keeps the hover, and the
        // grow already armed, alive.
        let hovering = hovering || (hoverHeld && pointerOnBand())
        let arriving = hovering && !hoverHeld
        if arriving { hoverArrivedFromBar = fromBar }
        if !hovering { hoverArrivedFromBar = false }
        hoverHeld = hovering
        // The breath waits out its intent delay — a pointer sweeping
        // past never grows the island; a rest of `NotchMotion.hoverDelay`
        // does. A re-entrant call while the peek is armed or landed
        // leaves the deadline alone.
        if hovering, !islandExpanded {
            if !islandHoverPeek, peekWork == nil {
                let work = DispatchWorkItem { [weak self] in
                    MainActor.assumeIsolated {
                        guard let self else { return }
                        self.peekWork = nil
                        guard self.hoverHeld, !self.islandExpanded else { return }
                        self.islandHoverPeek = true
                        self.reframeCurrent(
                            animated: !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion)
                    }
                }
                peekWork = work
                DispatchQueue.main.asyncAfter(deadline: .now() + hoverDelays.peek,
                                             execute: work)
            }
        } else {
            peekWork?.cancel()
            peekWork = nil
            islandHoverPeek = false
        }
        collapseWork?.cancel()
        collapseWork = nil
        guard activeCapsule == nil, activeOverlay == nil else { return }
        if hovering {
            if !islandExpanded, s.expandOnHover {
                // The wink lands now; the card only after the pause.
                reframeCurrent(
                    animated: !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion)
                // One arm per hover: a re-entrant true — the pointer
                // crossing from an ear onto the island — keeps the
                // deadline the arrival already set.
                if expandWork == nil {
                    let delay = hoverDelays.expand
                    let work = DispatchWorkItem { [weak self] in
                        MainActor.assumeIsolated { self?.hoverExpandFired() }
                    }
                    expandWork = work
                    DispatchQueue.main.asyncAfter(deadline: .now() + delay,
                                                 execute: work)
                }
            }
        } else {
            expandWork?.cancel()
            expandWork = nil
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
    func scheduleCollapseCheck() {
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
    /// swipe-down or Esc lets it go. Mid-news the click is remembered
    /// and lands when the capsule steps down; anything that holds the
    /// island longer steps aside for it instead.
    func expandFromBand() {
        // Fold's overlay owns the screen: a band press through it must
        // not grow a card the user cannot see — it would still be open
        // when the fold lets go.
        guard isDrawingIsland, !foldEngaged else { return }
        // Key feedback is a beat, not a face worth waiting on.
        if activeOverlay != nil { endOverlay(settle: false) }
        if let capsule = activeCapsule {
            // News holds the click for its short beat, then the card
            // lands. Whatever holds the island longer yields to a
            // deliberate grow instead: a latched ask (the card carries
            // it with its verbs), a due timer's eight seconds, a
            // meeting's thirty. Waiting those out read as a click that
            // did nothing, then a card popping open unasked. The fold
            // brings the capsule back while it is still fresh.
            if let life = capsule.kind.life, life <= AlcoveCapsuleQueue.life {
                bandExpandPending = true
                return
            }
            shelvedCapsule = (capsule, capsuleClock())
            activeCapsule = nil
            capsuleWork?.cancel()
            capsuleWork = nil
        }
        expand(held: true)
    }

    /// The band's dismiss paths — an outside click or a swipe up —
    /// fold the grown card whatever grew it.
    func collapseFromBand() {
        bandExpandPending = false
        collapseIsland()
    }

    /// A file or link dragged onto the island — NotchNook's shelf
    /// summon: the card grows held so the tray strip is there to take
    /// the drop. `shelfSummoned` remembers it was the drag that grew
    /// it, so an abandoned drag can fold the card it opened without
    /// unpinning one the user pinned themselves.
    private(set) var shelfSummoned = false
    /// Whether the summon itself parked a grow in `bandExpandPending`
    /// (a capsule was showing). An abandoned drag retracts exactly
    /// that ask — a pending grow a band click earned before the drag
    /// ever started is the user's, and survives it.
    private var shelfExpandPending = false

    func shelfSummon() {
        // A drag grows the card on Now: the session rows are drop
        // targets there (let go on an agent to hand it the file), and a
        // drop anywhere else lands in the tray and turns to the shelf.
        // The rows and the card are AppKit destinations of their own
        // (SwiftUI's `onDrop` views), so a drop on one never reaches
        // the hosting view; `shelfDragLeftIsland` keeps the card up
        // while the drag crosses onto them.
        guard !islandExpanded else { return }
        shelfSummoned = true
        let pendingWasClaimed = bandExpandPending
        expandFromBand()
        if bandExpandPending, !pendingWasClaimed { shelfExpandPending = true }
    }

    /// The drag left without a drop — fold the card only if the
    /// summon opened it; a card the user pinned stays pinned. A
    /// summon whose grow is still parked behind a showing capsule
    /// retracts it too: the drag is gone, so `settleToRest` must not
    /// pop the card open uninvited when the capsule steps down.
    func shelfDragAbandoned() {
        shelfSummonExpiry?.cancel()
        shelfSummonExpiry = nil
        shelfDragLeaveWork?.cancel()
        shelfDragLeaveWork = nil
        shelfDragOverIsland = false
        guard shelfSummoned else { return }
        shelfSummoned = false
        if shelfExpandPending {
            shelfExpandPending = false
            bandExpandPending = false
        }
        collapseIsland()
    }

    /// The drop landed — the card stays up (the tray just took a
    /// delivery); the flag alone clears. A grow still parked behind a
    /// capsule is the drop's own now — it stays armed and lands.
    func shelfDragLanded() {
        shelfSummonExpiry?.cancel()
        shelfSummonExpiry = nil
        shelfDragLeaveWork?.cancel()
        shelfDragLeaveWork = nil
        shelfDragOverIsland = false
        shelfSummoned = false
        shelfExpandPending = false
    }

    /// The drag is over the hosting view itself — the notch strip, or
    /// any part of the island the card's own targets do not cover.
    @ObservationIgnored var shelfDragOverIsland = false
    /// The beat before a drag that left every target folds the card.
    @ObservationIgnored var shelfDragLeaveWork: DispatchWorkItem?
    /// Long enough for the target the drag crossed onto to say so —
    /// the hosting view hears the exit first — and short enough that a
    /// drag carried away still folds the card at once.
    static let shelfDragLeaveGrace: TimeInterval = 0.3

    /// The hosting view heard the drag leave. AppKit says that too when
    /// the drag only crossed onto one of the card's own drop targets (a
    /// session row, the tray catch-all), which are destinations of their
    /// own; folding then pulled the card out from under a drag heading
    /// for an agent. The fold waits a beat and lands only if nothing in
    /// the island has the drag by then.
    func shelfDragLeftIsland() {
        shelfDragOverIsland = false
        shelfDragMoved()
    }

    /// Whether a leave fold is waiting out its grace. Tests read it
    /// instead of sleeping past the grace: "the card stays up" is then a
    /// fact about the queue, not a hope about the clock.
    var shelfDragLeavePending: Bool { shelfDragLeaveWork != nil }

    /// Runs a waiting leave fold now, exactly as its grace ending would,
    /// and drops the queued copy. Tests crank it by hand so no claim
    /// races a main queue a parallel suite has backed up.
    func fireShelfDragLeave() {
        guard let work = shelfDragLeaveWork else { return }
        work.perform()
        work.cancel()
    }

    /// The drag moved between the island and the card's targets
    /// (`NotchCardModel.dropHover`).
    func shelfDragMoved() {
        shelfDragLeaveWork?.cancel()
        shelfDragLeaveWork = nil
        if !cardModel.dropHover.isEmpty {
            // A real drag over the card backs a shake summon now; its
            // fold timer stands down, the same as at the notch.
            shelfSummonExpiry?.cancel()
            shelfSummonExpiry = nil
            return
        }
        guard shelfSummoned, !shelfDragOverIsland else { return }
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.shelfDragLeaveWork = nil
                guard !self.shelfDragOverIsland, self.cardModel.dropHover.isEmpty else { return }
                self.shelfDragAbandoned()
            }
        }
        shelfDragLeaveWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.shelfDragLeaveGrace, execute: work)
    }

    /// The drop after the summon — file URLs straight in, web links
    /// materialised as `.webloc`s first so the entry stays a file. With
    /// the shelf switched off the island takes nothing; only a session
    /// row still takes a file.
    func shelfDrop(_ urls: [URL]) {
        shelfSummonExpiry?.cancel()
        shelfSummonExpiry = nil
        guard settings.shelfEnabled else { return }
        cardModel.tray.add(ShelfTrayDrop.trayURLs(from: urls))
        // Show where it landed.
        cardModel.show(.shelf)
    }

    // MARK: - Shake to summon

    /// Told when the shelf is switched on or off — the app delegate hides
    /// the Dock's Send to Shelf while the shelf takes no files. The first
    /// reconcile runs in `init`, before anyone listens, so wiring this
    /// hears the switch as it stands right away: a shelf that launches
    /// off never leaves Send to Shelf on the Dock.
    @ObservationIgnored var onShelfSwitch: (@MainActor (Bool) -> Void)? {
        didSet {
            shelfSwitchSent = settings.shelfEnabled
            onShelfSwitch?(settings.shelfEnabled)
        }
    }
    /// The last switch `onShelfSwitch` heard, so a reconcile that moved
    /// nothing says nothing.
    @ObservationIgnored private var shelfSwitchSent: Bool?

    /// The shake recognizer's feeds — global drag/up monitors, alive
    /// only while the island is up and the setting allows. A shake
    /// during any left-button drag pulls the card open as a drop
    /// target; nothing here inspects what is being dragged.
    @ObservationIgnored var shakeDragMonitor: Any?
    @ObservationIgnored var shakeUpMonitor: Any?
    @ObservationIgnored var shakeSamples: [ShelfShakeDetector.Sample] = []
    /// How the shake's monitors are made and let go — NSEvent's global
    /// pair; a test hands in a counter so no suite watches real drags.
    @ObservationIgnored var installShakeMonitor: (NSEvent.EventTypeMask, @escaping (NSEvent) -> Void) -> Any? = {
        NSEvent.addGlobalMonitorForEvents(matching: $0, handler: $1)
    }
    @ObservationIgnored var removeShakeMonitor: (Any) -> Void = { NSEvent.removeMonitor($0) }
    /// The shelf apps that own the same shake, running now
    /// (`UtilityRivals`, `.shelfGesture`); a test hands in its own list.
    /// Asked through `shelfRivalsNow`, once per launch or quit.
    var shelfRivalsRunning: @MainActor () -> [UtilityRivals.Rival] {
        get { shelfRivalsReader }
        set {
            shelfRivalsReader = newValue
            shelfRivalsMemo = nil
        }
    }
    @ObservationIgnored private var shelfRivalsReader: @MainActor () -> [UtilityRivals.Rival] = {
        UtilityRivals.running(for: .shelfGesture)
    }
    /// The last rivals answer and the `workspaceVersion` it was read at.
    @ObservationIgnored var shelfRivalsMemo: (version: Int, rivals: [UtilityRivals.Rival])?
    /// The app in front while the pointer shakes — the exclusion list's
    /// read.
    @ObservationIgnored var shakeFrontmostApp: @MainActor () -> String? = {
        NSWorkspace.shared.frontmostApplication?.bundleIdentifier
    }
    /// The fold-back timer after a shake-summon — a card nobody
    /// dropped on folds itself rather than standing open forever.
    @ObservationIgnored var shelfSummonExpiry: DispatchWorkItem?

    /// Grow the island into the card — `held` is the band click's
    /// deliberate pin, surviving pointer-leave; a hover's expand
    /// answers to the leave debounce alone.
    func expand(held: Bool) {
        guard isDrawingIsland, !foldEngaged else { return }
        if held { expandHeld = true }
        guard !islandExpanded else { return }
        // A capsule promoted into its show-gap can never draw over the
        // card — `showCurrentCapsule` guards on expanded — so its gap
        // timer must not keep running: it would fire into the early
        // return and leave `current` parked forever, wedging every
        // later offer behind it. Shelve it instead; `collapseIsland`
        // re-shows it while it is still fresh.
        if activeCapsule == nil, let promoted = capsuleQueue.current,
           shelvedCapsule?.notice != promoted {
            shelvedCapsule = (promoted, capsuleClock())
            capsuleWork?.cancel()
            capsuleWork = nil
        }
        islandExpanded = true
        syncAudioTap()
        // Alcove's felt edge: the grow lands with a soft trackpad tap.
        if runtimeEnabled, settings.hapticTick { expandHaptic() }
        feedCard()
        cardModel.pinned = true
        syncCardKeyMonitors()
        // Frame leads, content follows: the rows stay hidden until the
        // spring has carried the frame most of the way — Reduce Motion
        // and an unseen snap show them at once instead.
        let animated = island?.isVisible == true
            && !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        cardModel.contentRevealed = !animated
        reframe(.expanded, animated: animated)
    }

    /// Fold the grown card back — every dismiss path lands here. The
    /// held cursor goes with it: a collapse is a "let it go", so a
    /// pointer still sitting on the island (Esc, the close button, a
    /// swipe) must not re-grow the card the next time a capsule
    /// settles and re-reads the hover.
    func collapseIsland() {
        guard islandExpanded else { return }
        islandExpanded = false
        // A quiet stretch that ended under the card says its summary as
        // the card folds — behind a capsule the fold brings back, if any.
        defer { noteQuietChange() }
        expandHeld = false
        hoverHeld = false
        peekWork?.cancel()
        peekWork = nil
        islandHoverPeek = false
        cardModel.pinned = false
        // The content-follow gate resets open so the next grow arms it
        // fresh — and the shared model never leaves the glass card
        // hiding its rows.
        cardModel.contentRevealed = true
        syncCardKeyMonitors()
        syncAudioTap()
        // A capsule the grow shelved is still news while it is fresh —
        // the card outranked it; the user did not dismiss it. A stale
        // or orphaned `current` gets cancelled instead, so the slot can
        // never outlive the card that hid it.
        let shelved = shelvedCapsule
        shelvedCapsule = nil
        if let current = capsuleQueue.current {
            // A capsule is fresh for its own kind's life (news for its
            // beat, a timer or a meeting for theirs); a latched ask for
            // as long as it is still open.
            if let shelved, current == shelved.notice,
               current.kind.life == nil
                ? askHolds(current)
                : capsuleClock().timeIntervalSince(shelved.at) < (current.kind.life ?? AlcoveCapsuleQueue.life) {
                showCurrentCapsule()
                return
            }
            capsuleQueue.cancel(at: capsuleClock())
        }
        reframe(currentFace,
                animated: !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion)
    }

    /// Esc while the card is grown lets it go — the island never takes
    /// key status, so the toy watches both monitors itself.
    private func syncCardKeyMonitors() {
        for monitor in cardKeyMonitors { NSEvent.removeMonitor(monitor) }
        cardKeyMonitors = []
        guard runtimeEnabled, islandExpanded else { return }
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

    /// The frame spring's height progress toward its target — the
    /// expanded card's rows stay hidden until the frame has carried
    /// most of the way there. Frame leads, content follows: Alcove's
    /// signature, `NotchMotion.contentRevealThreshold` the bar.
    /// The settle tick reports 1.0, so a card can never rest hidden.
    func noteFrameProgress(_ progress: CGFloat) {
        guard islandExpanded, !cardModel.contentRevealed,
              progress >= NotchMotion.contentRevealThreshold else { return }
        cardModel.contentRevealed = true
    }

    /// Refill the card's rows from the live state — the same facts the
    /// glass card's presenter would hand it.
    private func feedCard() {
        if let focus = cardFocus() { cardModel.focus = focus }
        let summary = islandSummary
        cardModel.rows = summary.rows.filter { $0.id != cardModel.focus.focusSession }
        let homes = sessionHomes(summary)
        if cardModel.tray.sessionHomes != homes { cardModel.tray.sessionHomes = homes }
        cardModel.workingCount = summary.working
        cardModel.meters = settings.showUsage ? NotchIsland.meters(core.state?.usage) : []
    }

    /// Where each live local session works — the shelf gathers its files
    /// under its name.
    private func sessionHomes(_ summary: NotchIslandSummary) -> [ShelfTrayModel.SessionHome] {
        summary.rows.compactMap { row -> ShelfTrayModel.SessionHome? in
            guard !CoreSession.isRemoteID(row.id),
                  let cwd = core.state?.session(withID: row.id)?.cwd, !cwd.isEmpty else { return nil }
            return ShelfTrayModel.SessionHome(id: row.id, label: row.label, root: cwd)
        }
    }

    /// Hover on the island grows it — the full card, its Open and
    /// transport live. While the space hides the menu bar (a fullscreen
    /// app is frontmost) the pointer at the top edge is reaching for a
    /// bar that is not there, not for us — the grow stays down; the
    /// wink still answers, it is only a tell.
    func applyHover() {
        guard hoverHeld, settings.expandOnHover, activeCapsule == nil, activeOverlay == nil,
              !menuBarHidden() else { return }
        expand(held: false)
    }

    /// The face the window should wear right now — key feedback
    /// outranks a capsule, a capsule outranks the card, the card
    /// outranks idle. An ask capsule wears the ask face.
    var currentFace: NotchIslandFace {
        if activeOverlay != nil { return .notice }
        if let capsule = activeCapsule { return capsule.kind.hasVerbs ? .ask : .notice }
        return islandExpanded ? .expanded : .idle
    }

    /// Resize the window to `face`'s frame — the island morphs in place;
    /// there is never a second panel. A request already in flight is not
    /// re-issued (the window's frame spring retargets rather than
    /// restart, but a no-change ask is still no ask). A nudge too small
    /// to see (a session row's label settling by a point) applies
    /// without animation — animating a sub-2 pt delta reads as jitter.
    /// A morph landing mid-pull owns the frame: the pull lets go
    /// without a verdict rather than fight the spring. `measured` is
    /// `face`'s frame when the caller already took it.
    func reframe(_ face: NotchIslandFace, measured: NSRect? = nil, animated: Bool) {
        guard let frame = measured ?? islandFrame(face: face) else { return }
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
        if runtimeEnabled {
            Self.publishedExpandedRect = face == .expanded ? frame : nil
        }
        island?.applyFrame(frame, animated: animated)
    }

    func reframeCurrent(animated: Bool) {
        reframe(currentFace, animated: animated)
    }

    /// The island's frame for a face: centred on the notch slot, top
    /// edge pinned to the screen's top (or floating a few points under
    /// it on a notch-less screen).
    func islandFrame(face: NotchIslandFace) -> NSRect? {
        _ = displayVersion
        guard let screen = ScreenBarGeometry.preferredScreen() else { return nil }
        let slot = ScreenBarGeometry.islandSlot(on: screen)
        let depth = ScreenBarGeometry.islandDepth(of: screen)
        let centerX = slot?.centerX ?? screen.frame.midX
        let size: CGSize
        switch face {
        case .notice:
            size = NotchIslandLayout.noticeSize(slotWidth: slot?.width ?? 0, notchDepth: depth,
                                                underHousing: housingCorner(on: screen))
        case .ask:
            size = askFaceSize(on: screen)
                ?? NotchIslandLayout.noticeSize(slotWidth: slot?.width ?? 0, notchDepth: depth,
                                                underHousing: housingCorner(on: screen))
        case .expanded:
            let width = NotchIslandLayout.expandedWidth(slotWidth: slot?.width ?? 0)
            let content = island?.expandedCardHeight(width: width) ?? 0
            size = CGSize(width: width,
                          height: NotchIslandLayout.expandedTopInset(notchDepth: depth) + content)
        case .idle:
            // Notched: each shoulder carries its own content, the slot
            // stays the notch. Notch-less: the floating pill wraps the
            // row.
            let layout = idleLayout
            var idle = depth > 0
                ? NotchIslandLayout.idleSize(
                    slotWidth: slot?.width ?? 0, notchDepth: depth,
                    leftShoulder: layout.windowShoulder, rightShoulder: layout.windowShoulder)
                : NotchIslandLayout.floatingSize(
                    contentWidth: NotchIsland.idleContentWidth(
                        islandSummary, media: idleMedia,
                        sensors: sensorIndicatorsEnabled ? sensorState : NotchSensorState()))
            if islandHoverPeek {
                // The wink's frame half — a few points of grow under
                // the pointer, symmetric on a drawn face, straight
                // down on the bare housing, never the card.
                idle = NotchIslandLayout.peekAdjusted(idle, bare: layout.bare)
            }
            size = idle
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
        reconcileCount += 1
        // What this pass leaves behind is what the next doc is measured
        // against — taken at the end, after the pass moved what it moves.
        defer { reconciledInputs = reconcileInputs }
        guard runtimeEnabled else { return }
        publishRenderer()
        // The shelf's switch reaches the surfaces that offer to shelve a
        // file outside the card (the Dock's Send to Shelf).
        if shelfSwitchSent != settings.shelfEnabled {
            shelfSwitchSent = settings.shelfEnabled
            onShelfSwitch?(settings.shelfEnabled)
        }
        // The media-key tap's lifetime rides the same gates — a flip
        // must install or drop the tap now, not at the next press.
        onMediaGateChanged()
        // The simulate-notch flag every band-hanging surface reads.
        ScreenBarGeometry.simulatedNotch = settings.simulateNotch
        // The Display pick the island and the Screen Bar share.
        ScreenBarGeometry.applyDisplayPick(settings.notchDisplay)
        // Sessions, usage or the focus may have moved while the card is
        // grown — refill before the frame re-measures its height.
        if islandExpanded { feedCard() }
        // A latched ask answered anywhere else steps down on the
        // document that says so.
        noteAskState()
        // A quiet stretch ending replays what it held.
        noteQuietChange()
        // The weather toggle or city text changed — re-read now rather
        // than on the half-hour tick.
        cardModel.utility.weather.reload()
        // The lyrics switch: off clears the line at once, on picks the
        // playing track back up (a key compare when nothing moved).
        cardModel.utility.lyrics.note(media: cardModel.utility.media)
        // The mirror toggle while the card is already pinned — the
        // pin's own sync only runs on the edge. The lens stays shut
        // unless this open summoned it.
        cardModel.mirror.sync(enabled: cardModel.pinned && settings.mirror && cardModel.mirrorSummoned)
        let s = settings
        // The frame the guard measures is the one `reframe` would measure
        // again — for the grown card, a second layout of the height
        // probe. Reused whenever the window already existed to measure it.
        let measuredWithWindow = island != nil
        guard s.enabled, s.provider == .jrbar, s.islandEnabled,
              let frame = islandFrame(face: currentFace) else {
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
        reframe(currentFace, measured: measuredWithWindow ? frame : nil,
                animated: !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion)
        if island?.isVisible != true {
            island?.orderFrontRegardless()
        }
        islandVisible = true
        publishSurface()
        syncMediaMonitor()
        syncPowerMonitor()
        syncSensorMonitor()
        syncAudioTap()
        syncShakeMonitor()
        syncMeetingWatch()
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
        peekWork?.cancel()
        peekWork = nil
        // A parked island forgets it was shake-summoned — the pending
        // fold must not fire into a hidden window.
        shelfSummoned = false
        shelfExpandPending = false
        shelfSummonExpiry?.cancel()
        shelfSummonExpiry = nil
        shelfDragLeaveWork?.cancel()
        shelfDragLeaveWork = nil
        shelfDragOverIsland = false
        activeCapsule = nil
        shelvedCapsule = nil
        capsuleWork?.cancel()
        capsuleWork = nil
        collapseWork?.cancel()
        collapseWork = nil
        activeOverlay = nil
        overlayWork?.cancel()
        overlayWork = nil
        askTrack.removeAll()
        capsuleQueue.clear()
        desiredFrame = nil
        islandVisible = false
        Self.publishedExpandedRect = nil
        publishSurface()
        island?.orderOut(nil)
        syncMediaMonitor()
        syncPowerMonitor()
        syncSensorMonitor()
        syncAudioTap()
        syncShakeMonitor()
        syncMeetingWatch()
    }

    /// Ends every owned runtime source and releases the island. The
    /// hosting view retains this toy through its root view, so dropping
    /// the window here is what breaks that cycle when `ToysStore` dies.
    func shutdown() {
        runtimeEnabled = false
        parkIsland()
        audioTap.stop()
        let workspace = NSWorkspace.shared.notificationCenter
        for observer in observers {
            workspace.removeObserver(observer)
            NotificationCenter.default.removeObserver(observer)
        }
        observers.removeAll()
        island?.close()
        island = nil
    }

    // MARK: Event capsules

    /// `EventCoordinator.apply` hands every daemon event here, next to
    /// the confetti call. `AlcoveEventPolicy` decides whether it earns a
    /// capsule; the queue's cooldown keeps a burst of asks from strobing
    /// the notch. While the card is grown the event is already visible
    /// in its rows — a capsule over it would only blink — so a grown
    /// island eats them quietly. `ask_resolved` is never a capsule, but
    /// it always closes one: an ask answered anywhere steps its capsule
    /// down, whatever face is up.
    func noteEvent(_ event: CoreEvent) {
        if event.kind == "ask_resolved", let session = event.session {
            resolveAsk(session: session, request: event.request)
            return
        }
        let s = settings
        guard s.enabled, s.provider == .jrbar, s.islandEnabled,
              s.capsuleNotifications, islandVisible, !islandExpanded else { return }
        let session = event.session.flatMap { core.state?.session(withID: $0) }
        guard let notice = AlcoveEventPolicy.notice(for: event, session: session,
                                                    kinds: s.capsuleKinds) else { return }
        offer(notice)
    }

    /// A battery transition the power monitor saw — `AlcovePower.notice`
    /// shapes it; the same queue and gate as daemon events. An ear that
    /// speaks for power keeps the island quiet about plugs and charge
    /// states — but not about the one thing the ear can't know: the
    /// battery running low while agents work on it.
    private func notePowerTransition(from old: AlcovePowerState, to new: AlcovePowerState) {
        let s = settings
        guard s.enabled, s.provider == .jrbar, s.islandEnabled,
              s.capsuleNotifications, islandVisible, !islandExpanded else { return }
        if let low = AlcovePower.lowBatteryNotice(from: old, to: new,
                                                  working: islandSummary.working,
                                                  id: UUID().uuidString) {
            offer(low)
            return
        }
        guard !earNoticesLive,
              let notice = AlcovePower.notice(from: old, to: new,
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
    /// the power path both land here. Key feedback never queues: it goes
    /// to the overlay (`presentSystemNotice`).
    ///
    /// True when the island has the notice — shown, due after the gap,
    /// waiting its turn, or held for a quiet stretch's summary. False
    /// when it will never say it: turned away at the door by a waiting
    /// capsule that outranks it, or a repeat inside the cooldown. The
    /// agents' news can let that go (the card's rows still tell it);
    /// the Mac's announcements take the pill instead.
    @discardableResult
    func offer(_ notice: AlcoveNotice) -> Bool {
        if notice.kind.isFeedback {
            return presentFeedback(notice)
        }
        // A quiet stretch holds good news back for one summary later;
        // asks and failures are not held.
        if settings.holdNewsWhileQuiet, quietContext != nil, capsuleQueue.hold(notice) { return true }
        if let pending = capsuleQueue.pending,
           notice.kind.queueRank > pending.kind.queueRank { return false }
        if notice.kind == .ask { askTrack[notice.id] = (Date(), false) }
        switch capsuleQueue.offer(notice, at: capsuleClock()) {
        case .now: showCurrentCapsule()
        case .after(let delay): scheduleCapsuleShow(after: delay)
        case .queued: break
        case .suppressed: return false
        }
        return true
    }

    /// Draw `capsuleQueue.current` as the island's face and arm its life
    /// timer. A grown island already tells the event's story in its
    /// rows — a capsule queued before the grow simply does not draw. An
    /// ask whose question has already gone (answered while it waited
    /// its turn) steps straight down instead of asking again.
    func showCurrentCapsule() {
        guard let current = capsuleQueue.current, islandVisible, !islandExpanded else { return }
        if current.kind == .ask, !askHolds(current) {
            finishCapsule()
            return
        }
        activeCapsule = current
        reframe(currentFace, animated: !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion)
        armCapsuleLife()
    }

    /// The shown capsule's own life (`AlcoveNoticeKind.life`) before
    /// `finishCapsule` steps it down — the same arm a collapse-restored
    /// capsule gets. A latched ask arms nothing: it holds until it is
    /// answered, opened, swiped away or resolved.
    private func armCapsuleLife() {
        capsuleWork?.cancel()
        capsuleWork = nil
        guard let life = activeCapsule?.kind.life else { return }
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated { self?.finishCapsule() }
        }
        capsuleWork = work
        capsuleTimer(life, work)
    }

    // MARK: Asks

    /// The live ask behind an ask capsule — pinned in `state.asks`
    /// first, the session's own otherwise.
    func liveAsk(for notice: AlcoveNotice) -> CoreAsk? {
        notice.session.flatMap { NotchIsland.liveAsk(session: $0, state: core.state) }
    }

    /// What the ask face may offer right now — read live, so a daemon
    /// that learns it can type into the terminal lights the buttons up
    /// without a new capsule.
    func askVerbs(for notice: AlcoveNotice) -> NotchAskVerbs {
        NotchAskVerbs.resolve(live: liveAsk(for: notice), session: notice.session)
    }

    /// The question itself — the live summary, else the event's.
    func askSummary(_ notice: AlcoveNotice) -> String {
        let live = liveAsk(for: notice)?.summary
        let text = (live?.isEmpty == false ? live : nil)
            ?? notice.ask?.summary.flatMap { $0.isEmpty ? nil : $0 }
            ?? notice.subtitle
        return text
    }

    /// Whether a latched ask capsule still holds — `NotchIsland
    /// .askStillOpen` over this notice's own bookkeeping. Reading it
    /// marks the ask seen once the state carries it.
    private func askHolds(_ notice: AlcoveNotice) -> Bool {
        let live = liveAsk(for: notice)
        var track = askTrack[notice.id] ?? (Date(), false)
        if live != nil { track.seen = true }
        askTrack[notice.id] = track
        return NotchIsland.askStillOpen(notice, live: live, seenLive: track.seen,
                                        age: Date().timeIntervalSince(track.offered))
    }

    /// The state moved: a shown ask whose question is gone — answered in
    /// the terminal, replaced by a new request, the session ended —
    /// steps down. `reconcile` calls it on every document; internal so
    /// tests can run it without one.
    func noteAskState() {
        if let capsule = activeCapsule, capsule.kind == .ask, !askHolds(capsule) {
            finishCapsule()
        }
        let live = Set([capsuleQueue.current?.id, capsuleQueue.pending?.id,
                        shelvedCapsule?.notice.id].compactMap { $0 })
        askTrack = askTrack.filter { live.contains($0.key) }
    }

    /// An ask was answered — here, in the panel, or in the terminal. A
    /// waiting capsule about it is dropped; the shown one steps down and
    /// whatever waits behind it gets its turn. A capsule the card
    /// shelved goes too, so the fold never replays a settled question.
    func resolveAsk(session: String, request: String?) {
        let shown = capsuleQueue.resolveAsk(session: session, request: request)
        if let shelved = shelvedCapsule, shelved.notice.kind == .ask,
           shelved.notice.session == session {
            shelvedCapsule = nil
        }
        guard shown else { return }
        finishCapsule()
    }

    /// Approve or Deny on the ask face — only ever from a click on a
    /// button `AskVerbs` drew, sent through the shared desk, which gates
    /// it again. The pin is the episode the capsule shows; answerability
    /// is the live ask's, so an ask not yet in the state sends nothing.
    /// The desk's `onAnswered` steps the capsule down. The returned task
    /// is the answer in flight — the button forgets it, tests await it.
    @discardableResult
    func answerCapsule(approve: Bool) -> Task<Void, Never>? {
        guard let capsule = activeCapsule, capsule.kind == .ask,
              let session = capsule.session, let desk = cardModel.askDesk(),
              var ask = liveAsk(for: capsule) else { return nil }
        if let pinned = capsule.ask?.request { ask.request = pinned }
        if ask.session == nil { ask.session = session }
        let pinned = ask
        return Task { _ = await desk.answer(pinned, approve ? .approve : .deny) }
    }

    /// Open on the ask face, or a tap on any capsule about a session:
    /// news you tap takes you to the thing. The capsule steps down once
    /// the session is in front — the person acted on it; a refusal
    /// stays on the capsule instead. The returned task is the open in
    /// flight.
    @discardableResult
    func openCapsuleSession() -> Task<Void, Never>? {
        guard let capsule = activeCapsule, let session = capsule.session else { return nil }
        let task = Task { [weak self] in
            guard let self, await self.open(session: session),
                  self.activeCapsule?.id == capsule.id else { return }
            self.dismissCapsule()
        }
        openInFlight = task
        return task
    }

    // MARK: Opening

    /// The one way the notch opens a session (`SessionOpener`): the
    /// daemon's raise, and the Dock's window locator when the daemon
    /// cannot find a session still running here. Tests swap it.
    @ObservationIgnored var openSession: @MainActor (_ session: String) async -> String? = { id in
        await SessionOpener.open(id)
    }
    /// The last click's open, still on its way — tests await it.
    @ObservationIgnored var openInFlight: Task<Void, Never>?

    /// Open `session`'s own window. True once it is in front; a refusal
    /// is kept on the card model for the row and the ask face to show.
    @discardableResult
    func open(session: String) async -> Bool {
        guard let refusal = await openSession(session) else { return true }
        cardModel.noteOpenRefused(refusal, session: session)
        return false
    }

    /// A row or the header's Open on the grown card: the card folds once
    /// the session is in front; a refusal stays on the card to be read.
    private func openFromCard(_ session: String) {
        openInFlight = Task { [weak self] in
            guard let self, await self.open(session: session) else { return }
            self.collapseIsland()
        }
    }

    // MARK: Quiet hold

    /// The quiet stretch the Mac is in, by name — nil when it isn't.
    /// The daemon's `state.focus` is one signal (a macOS Focus synced
    /// in, quiet hours, or a quiet mode picked by hand); the Mac's own
    /// Focus, as `NotchAnnouncements` reads it, is the other — so the
    /// hold works on a Mac whose daemon never syncs the Focus. A Focus
    /// goes by the name the Mac gave it.
    var quietContext: String? {
        if let focus = core.state?.focus,
           let context = AlcoveCapsuleQueue.quietContext(mode: focus.mode, source: focus.source,
                                                         focusName: macFocus) {
            return context
        }
        if let macFocus { return macFocus }
        return settings.meetingAlerts ? meetingWatch.live?.title : nil
    }

    /// The last quiet stretch seen — its end is what replays the hold.
    @ObservationIgnored private var lastQuiet: String?
    /// The Mac's Focus while one is on ("Work"), nil otherwise.
    @ObservationIgnored private(set) var macFocus: String?

    /// The Mac's Focus settled (`NotchAnnouncements.onFocus`): its name
    /// while on, and a Focus ending may end the quiet stretch.
    func noteMacFocus(name: String, on: Bool) {
        macFocus = on ? name : nil
        noteQuietChange()
    }

    /// Something quiet moved: a stretch that just ended replays what it
    /// held as one summary capsule ("While you were in Work · 3
    /// finished"). `reconcile`, the Focus and the card's fold call it;
    /// internal for the tests.
    ///
    /// The end is only spent once the summary can be said. A Focus
    /// ended from Control Center while the card is up (or the island is
    /// hidden, or under Fold) keeps the edge and the hold, and the fold
    /// or the next reconcile replays it — offered under the card, it
    /// would have been cancelled as an orphan by the fold. Capsules
    /// switched off entirely have no voice to wait for: the hold goes.
    func noteQuietChange() {
        let now = quietContext
        guard now == nil, let ended = lastQuiet else {
            lastQuiet = now
            return
        }
        let s = settings
        guard s.enabled, s.provider == .jrbar, s.islandEnabled, s.capsuleNotifications else {
            lastQuiet = nil
            _ = capsuleQueue.releaseHeld(id: UUID().uuidString, during: ended)
            return
        }
        guard islandVisible, !islandExpanded, !foldEngaged else { return }
        lastQuiet = nil
        if let summary = capsuleQueue.releaseHeld(id: UUID().uuidString, during: ended) {
            offer(summary)
        }
    }

    /// A Focus turning on says what the island will do about it: good
    /// news waits for the end, asks still show.
    static func focusPolicyNotice(_ notice: AlcoveNotice, holding: Bool) -> AlcoveNotice {
        guard holding, notice.kind == .focus, notice.key == "focus:on" else { return notice }
        var said = notice
        said.subtitle = "Focus on · news waits"
        return said
    }

    // MARK: Meetings

    /// The meeting watch lives exactly as long as the island is shown
    /// with the heads-up and the calendar both on; `reconcile` and
    /// `parkIsland` land here. `runtimeEnabled` is folded in, so the
    /// state-machine tests never make an EventKit store.
    private func syncMeetingWatch() {
        let s = settings
        meetingWatch.sync(enabled: runtimeEnabled && islandVisible
                          && s.meetingAlerts && s.calendar && s.provider == .jrbar)
    }

    /// Two minutes out: the island says which meeting, when, and offers
    /// Join (and the Mirror, for a last look). Internal for the tests.
    func noteMeetingSoon(_ event: ShelfCalendarModel.Event) {
        let s = settings
        guard s.enabled, s.provider == .jrbar, s.islandEnabled, s.meetingAlerts,
              islandVisible, !islandExpanded else { return }
        headsUpMeeting = event
        let key = "meeting:\(ShelfMeetingWatch.key(event))"
        offer(AlcoveNotice(id: key, kind: .meeting, title: event.title,
                           subtitle: ShelfMeetingWatch.detail(event), key: key))
    }

    /// The heads-up's Join: the link opens in the browser (only an
    /// http(s) one ever reaches here) and the heads-up steps down.
    func joinHeadsUpMeeting() {
        if let url = headsUpMeeting?.url { NSWorkspace.shared.open(url) }
        dismissCapsule()
    }

    /// The heads-up's Mirror: a last look before the call — the card
    /// opens straight onto the lens.
    func mirrorBeforeMeeting() {
        dismissCapsule()
        summonMirror()
    }

    // MARK: Timers

    /// A shelf timer came due: the island says so for longer than news
    /// (`AlcoveCapsuleQueue.timerLife`) — it was set to be noticed. A
    /// nudge names its session, so a tap on it opens the run. The card,
    /// when grown, already shows the Done chip.
    func noteTimerFired(_ entry: ShelfTimerModel.Entry) {
        let s = settings
        guard s.enabled, s.provider == .jrbar, s.islandEnabled, islandVisible,
              !islandExpanded else { return }
        offer(AlcoveNotice(id: "timer:\(entry.id):\(Int(entry.deadline.timeIntervalSince1970))",
                           kind: .timer, title: entry.label,
                           subtitle: entry.watchSession != nil ? "still working" : "done",
                           session: entry.watchSession,
                           key: "timer:\(entry.id):\(Int(entry.deadline.timeIntervalSince1970))"))
    }

    /// A due timer breathes the strips, whether or not the island can
    /// say it — the lights are how it reaches across the room.
    func flashLightsForTimer() {
        guard NotchTimerLights.shouldFlash(enabled: settings.timerLights, devices: core.devices,
                                           quiet: quietContext != nil) else { return }
        core.previewProgram(surface: "hardware", program: NotchTimerLights.program,
                            seconds: NotchTimerLights.seconds)
    }

    /// Whether a session is still working — a nudge's condition.
    func sessionStillWorking(_ id: String) -> Bool {
        guard let session = core.state?.session(withID: id) else { return false }
        return SessionActivity.reduce(session) == .working
    }

    // MARK: Takeover

    /// The `takeover` tier's stage 3 (`EventDelivery.takeover`): the
    /// island grows into the ask card and holds it until the person
    /// answers, opens or swipes it away. The card already open carries
    /// the ask in its rows, so a grown island is left alone; so is a
    /// session with no open ask left to show.
    func noteTakeover(_ event: CoreEvent) {
        let s = settings
        guard s.enabled, s.provider == .jrbar, s.islandEnabled, islandVisible,
              !islandExpanded, !foldEngaged, let session = event.session,
              let live = NotchIsland.liveAsk(session: session, state: core.state) else { return }
        let opened = CoreEvent(id: "takeover:\(event.id)", kind: "ask_opened", session: session,
                               label: event.label, provider: event.provider,
                               detail: live.summary, request: live.request)
        // The tier is its own opt-in: the capsule switches do not gate it.
        guard let notice = AlcoveEventPolicy.notice(
            for: opened, session: core.state?.session(withID: session),
            kinds: AlcoveCapsuleKinds()) else { return }
        endOverlay(settle: false)
        capsuleWork?.cancel()
        capsuleWork = nil
        shelvedCapsule = nil
        bandExpandPending = false
        capsuleQueue.takeOver(notice, at: capsuleClock())
        if let current = capsuleQueue.current, askTrack[current.id] == nil {
            askTrack[current.id] = (Date(), true)
        }
        activeCapsule = capsuleQueue.current
        reframe(currentFace, animated: !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion)
    }

    /// The escalation stood down without the ask closing (its pane came
    /// to the front): the card shrinks back to the ask capsule, which
    /// keeps holding.
    func releaseTakeover() {
        guard activeCapsule?.takeover == true else { return }
        capsuleQueue.releaseTakeover()
        activeCapsule = capsuleQueue.current
        reframe(currentFace, animated: !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion)
    }

    /// Writes a level the scroll asked for — the system's own paths, the
    /// same ones the consuming key tap drives. False when the Mac said
    /// no (no settable volume on this output, no built-in panel). The
    /// tests stand in a recorder.
    @ObservationIgnored var levelWriter: (NotchLevelScrub.Target, Float) -> Bool = { target, value in
        switch target {
        case .volume:
            if value > 0, SystemLevelReader.outputMuted() == true { _ = SystemLevelReader.setOutputMuted(false) }
            return SystemLevelReader.setOutputVolume(value)
        case .brightness: return SystemLevelReader.setDisplayBrightness(value)
        case .keyboard: return false
        }
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
    /// media, so a mid-capsule update just waits. Internal for the
    /// render proofs.
    func noteMedia(_ media: AlcoveMedia?) {
        guard media != islandMedia else { return }
        islandMedia = media
        if currentFace != .notice {
            reframeCurrent(animated: !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion)
        }
        syncAudioTap()
    }

    /// The island's swipe transport lands here.
    func mediaNextTrack() { mediaFeed.send(.nextTrack) }
    func mediaPreviousTrack() { mediaFeed.send(.previousTrack) }

    // MARK: Audio visualizer

    /// The system-audio level tap feeding the media row's live bars.
    /// Owned here so its lifecycle rides the island's — a parked
    /// island holds no tap. `runtimeEnabled` is folded into the gate,
    /// so state-machine tests never build a Core Audio object.
    @ObservationIgnored let audioTap = AudioLevelTap()

    /// Push the gating facts. The media row is on screen only while
    /// the card is grown (no notice kind carries media today — the
    /// "notice showing media" branch of the spec's gate is vacuous),
    /// and the strip's decorative bars stay the answer whenever the
    /// tap isn't running.
    private func syncAudioTap() {
        audioTap.sync(visible: islandExpanded && islandVisible,
                      playing: islandMedia?.playing == true,
                      enabled: runtimeEnabled && settings.audioVisualizer,
                      clientBundleID: islandMedia?.bundleIdentifier)
    }

    // MARK: Power

    /// Whether the Screen Bar's ears announce device transitions now —
    /// drawn, with `screen_bar_wing_notices` on. Then the ear is the one
    /// announcer for power and the audio route: the island keeps quiet
    /// about both rather than say a charger plug twice.
    var earNoticesLive: Bool {
        guard earsDrawn else { return false }
        return SettingsDocument(core.settings?.document ?? .object([:]))
            .bool("screen_bar_wing_notices") ?? true
    }

    /// The island's subscription to the shared power feed lives exactly
    /// as long as the island is shown with both capsule switches on —
    /// with the ears speaking for power it stays only for the low-battery
    /// word; `reconcile`/`parkIsland` land here. The feed is one poll
    /// whoever listens.
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

    // MARK: Sensors

    /// Another surface that draws the privacy dots — the Screen Bar's
    /// ears, which carry them while the island rests bare under them.
    /// Asked on every sync; the delegate re-syncs when its answer moves.
    var sensorsWantedElsewhere: @MainActor () -> Bool = { false }
    /// The daemon's presence report, which needs the mic and camera
    /// whether or not anything draws them — a call is a call with the
    /// island off and the dots switched off. Re-synced the same way.
    var sensorsWantedForPresence: @MainActor () -> Bool = { false }
    /// Every edge the monitor reads, for those takers — the raw reading,
    /// whatever the dots' own switch says.
    var onSensorsChanged: (@MainActor (NotchSensorState) -> Void)?
    /// Whether the monitor is reading right now, for whichever taker —
    /// the Screen Bar's camera hold has a camera to hold on only then.
    private(set) var sensorsReading = false

    /// Whether any surface can draw the dots right now: the island's own
    /// face when the ears are not drawn, or a surface that asked.
    var sensorsDrawable: Bool {
        Self.sensorsDrawable(earsDrawn: earsDrawn, wantedElsewhere: sensorsWantedElsewhere())
    }

    static func sensorsDrawable(earsDrawn: Bool, wantedElsewhere: Bool) -> Bool {
        !earsDrawn || wantedElsewhere
    }

    /// Whether the monitor runs: with the dots' switch on, a surface that
    /// draws them — the island's own face (shown, no ears over its
    /// shoulders) or one elsewhere; and the presence report, switch or
    /// not. `runtimeEnabled` is folded in, so state-machine tests never
    /// build a CoreAudio/CoreMediaIO read.
    static func wantsSensorMonitor(runtimeEnabled: Bool, islandVisible: Bool, indicatorsOn: Bool,
                                   earsDrawn: Bool, wantedElsewhere: Bool,
                                   wantedForPresence: Bool) -> Bool {
        let drawn = indicatorsOn && ((islandVisible && !earsDrawn) || wantedElsewhere)
        return runtimeEnabled && (drawn || wantedForPresence)
    }

    /// The mic/camera monitor lives exactly as long as somebody takes
    /// the reading; `reconcile`/`parkIsland` land here, and the delegate
    /// calls it when a taker elsewhere comes or goes.
    func syncSensorMonitor() {
        let want = Self.wantsSensorMonitor(runtimeEnabled: runtimeEnabled, islandVisible: islandVisible,
                                           indicatorsOn: sensorIndicatorsEnabled, earsDrawn: earsDrawn,
                                           wantedElsewhere: sensorsWantedElsewhere(),
                                           wantedForPresence: sensorsWantedForPresence())
        if sensorsReading != want { sensorsReading = want }
        if want {
            if sensorMonitor == nil {
                let monitor = NotchSensorMonitor()
                // Every taker hears every edge; the dots take theirs
                // through `noteSensors`, which the switch can blank.
                monitor.onChange = { [weak self] state in
                    self?.onSensorsChanged?(state)
                    self?.noteSensors(state)
                }
                sensorMonitor = monitor
            }
            sensorMonitor?.start()
            // The dots switched back on while the monitor kept reading
            // for another taker: pick its reading up now rather than at
            // the next edge.
            if sensorIndicatorsEnabled, let monitor = sensorMonitor, monitor.state != sensorState {
                noteSensors(monitor.state)
            }
        } else {
            let wasReading = sensorMonitor != nil
            sensorMonitor?.stop()
            sensorMonitor = nil
            if wasReading { onSensorsChanged?(NotchSensorState()) }
            if sensorState.anyInUse {
                sensorState = NotchSensorState()
                if islandVisible, currentFace == .idle {
                    reframeCurrent(animated: false)
                }
            }
        }
    }

    /// A sensor edge landed: publish it, and reframe when the resting
    /// face is up — the dots change the shoulder's width. Mid-capsule
    /// or mid-card it just waits; the next idle reframe picks it up.
    private func noteSensors(_ state: NotchSensorState) {
        guard state != sensorState else { return }
        sensorState = state
        // An open card names who is listening; an edge re-reads it.
        if cardModel.pinned { cardModel.refreshPrivacy() }
        if currentFace == .idle {
            reframeCurrent(animated: !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion)
        }
    }

    /// One observation pass over every input, re-armed on each change —
    /// the same pattern `NotchBuddyToy.observeSessions` uses. `sessions`
    /// and `asks` hang off the whole `state` document, so every doc the
    /// daemon sends wakes this; `noteInputsChanged` decides whether it
    /// moved anything the notch shows.
    private func observe() {
        guard runtimeEnabled else { return }
        withObservationTracking {
            _ = store?.state.notch
            _ = core.sessions
            _ = core.state?.asks          // a pinned ask answered elsewhere steps its capsule down
            _ = core.state?.usage
            _ = core.state?.focus         // a quiet stretch ending replays what it held
            _ = core.settings?.document   // screen_bar_notch_wings → earsDrawn
            _ = screenBarShown()          // PanelStore.screenBarShown → earsDrawn, the notice's housing climb
            _ = displayVersion
            _ = cardModel.mirror.state    // the lens going live grows the card to hold it
            _ = cardModel.page            // a page turn re-measures the card
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in
                guard let self, self.runtimeEnabled else { return }
                self.noteInputsChanged()
                self.observe()
            }
        }
    }

    // MARK: Reconcile gate

    /// What `reconcile` reads from the inputs `observe` watches, reduced
    /// to what the notch shows: the island's summary rather than the raw
    /// sessions (a working session's `updated_at`, tool and message move
    /// on nearly every doc), the meters rather than the usage document
    /// (its refresh stamp moves every time). While the card is grown it
    /// also carries what `feedCard` refills the card from.
    var reconcileInputs: NotchReconcileInputs {
        let settings = settings
        let summary = islandSummary
        var inputs = NotchReconcileInputs(
            notch: settings,
            summary: summary,
            asks: core.asks,
            meters: settings.showUsage ? NotchIsland.meters(core.state?.usage) : [],
            focus: core.state?.focus,
            settingsDocument: core.settings?.document,
            screenBarShown: screenBarShown(),
            displayVersion: displayVersion,
            mirror: cardModel.mirror.state,
            page: cardModel.page)
        if islandExpanded {
            inputs.card = NotchReconcileInputs.Card(focus: cardFocus(), homes: sessionHomes(summary))
        }
        return inputs
    }

    /// The inputs the last `reconcile` left behind.
    @ObservationIgnored private(set) var reconciledInputs: NotchReconcileInputs?
    /// How many times `reconcile` has run — the tests' window on the gate.
    @ObservationIgnored private(set) var reconcileCount = 0

    /// An input `observe` watches changed. Most `state` docs change
    /// nothing the notch shows, and a full `reconcile` on each one landed
    /// a 13–26 ms stall in whatever the island was animating; those skip
    /// it. The two checks that age on their own still run on every doc:
    /// an ask capsule whose ask never reached the state steps down after
    /// its grace, and a quiet stretch that ended while it could not be
    /// said gets said. Internal so the tests can drive it without a
    /// runtime.
    func noteInputsChanged() {
        guard reconcileInputs == reconciledInputs else {
            reconcile()
            return
        }
        noteAskState()
        noteQuietChange()
        // The grown card's height also follows what no doc carries — a
        // timer set, a file shelved, the weather landing — and every doc
        // used to re-measure it. Still do: with nothing changed the probe
        // answers from the layout it already has, and the frame guard
        // makes an unchanged height no request at all.
        if islandVisible, islandExpanded {
            reframeCurrent(animated: !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion)
        }
    }
}
