import AppKit
import JRBarCore
import JRBarLEDS
import QuartzCore

/// Owns the Screen Bar panel, the program currently on it, and how it moves.
///
/// A program is rendered once into keyframe tracks (`LEDSKeyframePlan`) and
/// handed to Core Animation, phase-locked to the daemon's anchor, so the
/// render server does every frame and this process idles. A program whose
/// cycle is too long to keyframe keeps the older frame clock: a
/// `CADisplayLink` (capped at 60 Hz, the Python pipeline's
/// `MAX_SAMPLE_RATE_HZ`) that runs the sampler on ticks and pauses whenever
/// the program has gone still or nobody can see the bar
/// (`ScreenBarVisibility`).
@MainActor
final class ScreenBarController {
    /// The document value's default when the daemon has not sent
    /// `virtual_status_device_wraps_menu_bar`: wrap, as it always was.
    static let defaultWrapMenuBar = true

    /// `virtual_status_device_wraps_menu_bar`, live from the settings
    /// document: the wings along the menu bar. Off means a plain band
    /// exactly the notch gap wide.
    var wrapMenuBar = ScreenBarController.defaultWrapMenuBar {
        didSet { if wrapMenuBar != oldValue { reposition() } }
    }
    /// `screen_bar_show_in_full_screen` (absent = show, as it always was):
    /// whether the panel keeps its `.fullScreenAuxiliary` membership.
    var showsInFullScreen = true {
        didSet {
            panel.showsInFullScreen = showsInFullScreen
            if showsInFullScreen != oldValue { updateVideoGuard() }
        }
    }
    /// `jrbar.screenBarHideOverVideo` (default on): with Show in full
    /// screen on, the band still steps aside while the frontmost app is
    /// the one playing media and fills the screen — over a movie, not
    /// over a full-screen terminal with music behind it. App-local, like
    /// the camera hold: the band and the now-playing reading are the app's.
    static let hideOverVideoDefaultsKey = "jrbar.screenBarHideOverVideo"
    private var hideOverVideo = UserDefaults.standard.object(forKey: ScreenBarController.hideOverVideoDefaultsKey) as? Bool ?? true
    /// The defaults watch that re-reads the two switches above; held for
    /// the controller's life, which is the app's.
    private var defaultsObserver: NSObjectProtocol?
    /// The now-playing app's bundle id while it is actually playing; nil
    /// when nothing plays or the source named no app.
    var nowPlaying: String? {
        didSet { if nowPlaying != oldValue { updateVideoGuard() } }
    }
    /// Whether the band has stepped aside for a full-screen video: the
    /// panel stays ordered in (no Space dance) at zero alpha, and it
    /// answers no hover or click while it does.
    var steppedAsideForVideo: Bool { visibility.steppedAside }
    /// Shown, asleep, stepped aside — and whether anybody can see the
    /// band at all, whose edges park and restart its clocks.
    private var visibility = ScreenBarVisibility()
    /// Every edge of "somebody can see the band": the hover poll
    /// (`ScreenBarInteraction.setParked`) follows it.
    var onLiveChange: (@MainActor (Bool) -> Void)?
    /// `screen_bar_gap_width`, live from the settings document: the manual
    /// width of the notch gap the band is centred on. nil is Automatic.
    var gapWidth: CGFloat? {
        didSet { if gapWidth != oldValue { reposition() } }
    }
    /// `screen_bar_wing_length`, live from the settings document: manual
    /// points of wing per side. nil is Automatic (measured).
    var wingLength: CGFloat? {
        didSet { if wingLength != oldValue { reposition() } }
    }
    /// `screen_bar_notch_wings` (absent = on): the status slots in the
    /// menu-bar areas flanking the notch — the selected task and the
    /// attention count on the left, the headline usage meter on the right.
    var notchWingsEnabled = true {
        didSet {
            guard notchWingsEnabled != oldValue else { return }
            reposition()
            updateNoticeMonitors()
            updateAppMenuWatch()
        }
    }
    /// `screen_bar_wing_notices` (absent = on): the device transitions —
    /// charger, battery full, output route — that hold a wing for a beat.
    var wingNoticesEnabled = true {
        didSet { if wingNoticesEnabled != oldValue { updateNoticeMonitors() } }
    }
    /// `screen_bar_notch_profile` + `screen_bar_notch_corner`: which
    /// MacBook's notch the tray's bottom corners copy, and the custom
    /// radius when the profile is `custom`.
    var notchProfile: NotchProfile = .auto {
        didSet { if notchProfile != oldValue { syncNotchCorner() } }
    }
    var notchCornerManual: CGFloat? {
        didSet { if notchCornerManual != oldValue { syncNotchCorner() } }
    }
    /// The slots' base content, pushed from the panel store on each core
    /// change. A nil slot collapses: the window claims no room for it.
    var wings: ScreenBarWings = .empty {
        didSet {
            if wings != oldValue {
                // A dismissal belongs to the wing's *subject* — the
                // session ear, the meter ear, the media ear — not the
                // exact words it carried. A meter's tick or a countdown's
                // minute is the same ear still dismissed; a different
                // subject claiming the side is new information that
                // revives it.
                reconcileDismissals()
                pushWings()
            }
        }
    }
    /// The ears' own marks on top of `wings` — the ask-age ring and the
    /// quiet moon — pushed beside the slots on each core change.
    var earMarks = ScreenBarEarMarks() {
        didSet {
            guard earMarks != oldValue else { return }
            reconcileDismissals()
            pushWings()
            // A hanging peek names the keep-awake hold at its foot.
            if earMarks.awake != oldValue.awake { syncPeek() }
        }
    }
    /// The island's mic/camera reading. With the ears drawn the island
    /// rests bare, so its privacy dots ride the right ear instead —
    /// after dismissals and notices, because a flick or a charger beat
    /// must never hide that a microphone is live.
    var sensors = NotchSensorState() {
        didSet {
            guard sensors != oldValue else { return }
            pushWings()
            if sensors.cameraInUse != oldValue.cameraInUse, stillOnCamera { present() }
        }
    }
    /// `jrbar.screenBarStillOnCamera` (default on): while any camera is
    /// live the band holds its program still — the Reduce Motion path —
    /// so nothing pulses millimetres from the lens or in the glasses of
    /// the person on the call; an ask stays a steady amber.
    static let stillOnCameraDefaultsKey = "jrbar.screenBarStillOnCamera"
    private var stillOnCamera = UserDefaults.standard.object(forKey: ScreenBarController.stillOnCameraDefaultsKey) as? Bool ?? true
    /// Whether the band is held still right now: Reduce Motion, or the
    /// camera hold with a camera rolling.
    private var holdsStill: Bool { reduceMotion || (stillOnCamera && sensors.cameraInUse) }
    /// Whether the ears can draw the privacy dots right now: shown, the
    /// wings on, no external capsule holding the flanks. The read the
    /// sensor poll's owner can gate on — a reading nothing can draw is
    /// a poll worth stopping.
    var drawsSensorDots: Bool { isShown && notchWingsEnabled && capsule == nil }
    /// The slots as the ears present them: the store's pick, dressed
    /// with the menu bar's marks and the ears' own. Dismissal and the
    /// draw both read this, so a flick on the moon dismisses the moon.
    private var markedWings: ScreenBarWings {
        ScreenBarEarMarks.apply(earMarks, to: ScreenBarMenuBarMarks.apply(
            menuBarMarks(menuBarFeed), to: wings))
    }

    /// The menu bar's marks for `feed`: a nudge's glyph only while its
    /// beat on the ear lasts.
    private func menuBarMarks(_ feed: MenuBarEarFeed?) -> ScreenBarMenuBarMarks {
        ScreenBarMenuBarMarks(feed: feed, showsNudge: nudgeMark != nil && nudgeMark?.id == feed?.nudge?.id)
    }

    /// The nudge whose glyph holds the right ear, and until when; nil
    /// once its beat is over — the peek keeps offering its choices after.
    private var nudgeMark: (id: String, until: Date)?
    private var nudgeMarkWork: DispatchWorkItem?
    /// How long a nudge's glyph holds the right ear: long enough to be
    /// seen and reached, then the side goes back to what it showed.
    static let nudgeMarkLife: TimeInterval = 10

    /// A new nudge in the feed stands its glyph on the ear for its beat;
    /// the beat holds while the peek is open on it.
    private func noteNudge(_ feed: MenuBarEarFeed?) {
        guard let id = feed?.nudge?.id else {
            nudgeMark = nil
            nudgeMarkWork?.cancel()
            nudgeMarkWork = nil
            return
        }
        guard nudgeMark?.id != id, id != lastNudgeID else { return }
        lastNudgeID = id
        nudgeMark = (id, Date().addingTimeInterval(Self.nudgeMarkLife))
        scheduleNudgeMarkLapse(after: Self.nudgeMarkLife)
    }
    /// The last nudge given its beat — one beat per nudge.
    private var lastNudgeID: String?

    private func scheduleNudgeMarkLapse(after seconds: TimeInterval) {
        nudgeMarkWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated {
                guard let self, self.nudgeMark != nil else { return }
                // The person is reading its peek: the mark stays.
                if self.peek.isShown {
                    self.scheduleNudgeMarkLapse(after: 2)
                    return
                }
                self.nudgeMark = nil
                self.reconcileDismissals()
                self.pushWings()
            }
        }
        nudgeMarkWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds, execute: work)
    }

    /// What the menu bar tells the right ear — its hidden runs' tiles —
    /// pushed from the utility's feed (`attachMenuBar`). The ears re-lay
    /// only when the marks it makes move; a new photograph only touches
    /// the peek.
    var menuBarFeed: MenuBarEarFeed? {
        didSet {
            guard menuBarFeed != oldValue else { return }
            let before = menuBarMarks(oldValue)
            noteNudge(menuBarFeed)
            if menuBarMarks(menuBarFeed) != before {
                reconcileDismissals()
                pushWings()
            }
            syncPeek()
        }
    }
    /// The black peek that hangs from the right ear — the menu bar's
    /// reveal surface (`ScreenBarPeek`).
    let peek = ScreenBarPeek()

    /// A dismissal survives only while the same subject still holds its
    /// side; a different subject claiming it is news that revives it.
    private func reconcileDismissals() {
        let marked = markedWings
        dismissedWings = dismissedWings.filter { side, slot in
            marked[side].map { Self.sameWingSubject($0, slot) } ?? false
        }
        dismissedWingRects = dismissedWingRects.filter { dismissedWings[$0.key] != nil }
    }
    /// Sides the user flicked away, keyed by the slot that was dismissed.
    /// The dismissal lasts until a summon, a relaunch, or a *different
    /// subject* taking the side — not until the slot's words churn.
    private var dismissedWings: [ScreenBarWingSide: ScreenBarWingSlot] = [:]
    /// Where a dismissed side's lobe last stood, in *screen* coordinates —
    /// kept inside the hit region so a swipe across the ghost is the
    /// summon gesture even though nothing draws there. Screen space because
    /// the view's own frame shifts the moment the wing comes out.
    private var dismissedWingRects: [ScreenBarWingSide: CGRect] = [:]

    /// Two slots are the same wing when they present the same subject:
    /// the provider glyph, the symbol, or the live equalizer. The meter
    /// ticking 41%→42% is the same ear; the equalizer replacing the
    /// meter is a different one.
    nonisolated static func sameWingSubject(_ a: ScreenBarWingSlot, _ b: ScreenBarWingSlot) -> Bool {
        a.provider == b.provider && a.symbol == b.symbol && a.visualizer == b.visualizer
            && (a.artworkData != nil) == (b.artworkData != nil)
            && (a.glyph != nil) == (b.glyph != nil) && a.markID == b.markID
    }
    /// The device notice holding a side, and when it lets go.
    private var wingNotice: (side: ScreenBarWingSide, slot: ScreenBarWingSlot, until: Date)?
    private var wingNoticeWork: DispatchWorkItem?
    /// Same-subject notices already shown (audio route names); the
    /// cooldown lives in `ScreenBarNotices.audio`.
    private var recentAudioNotices: [String: Date] = [:]
    /// Devices that already spoke inside the cooldown
    /// (`ScreenBarNotices.hardware`).
    private var recentDeviceNotices: [String: Date] = [:]
    /// When the monitor's device list went live — the start of its settle
    /// window; nil while the monitor is away.
    private var hardwareLiveSince: Date?
    /// The monitor's device rows while it is live, nil while it is not.
    /// A monitor going away is not every strip unplugging, so the next
    /// live list is a fresh baseline rather than a burst of arrivals.
    /// A strip or Dot coming or going holds the right ear for a beat —
    /// only while the ears and their notices are up; otherwise the list
    /// just moves the baseline. So does every list inside the monitor's
    /// first seconds live (`ScreenBarNotices.hardwareSettle`): its device
    /// scan lands after its first state, and a strip that was there all
    /// along is not an arrival.
    var hardware: [CoreDevice]? {
        didSet {
            guard let hardware else { hardwareLiveSince = nil; return }
            guard hardware != oldValue else { return }
            let now = Date()
            if oldValue == nil { hardwareLiveSince = now }
            if Self.stripLeft(from: oldValue, to: hardware) { crossfadeNextProgram() }
            let settling = ScreenBarNotices.hardwareSettling(liveSince: hardwareLiveSince, now: now)
            let result = ScreenBarNotices.hardware(from: settling ? nil : oldValue, to: hardware,
                                                   recent: recentDeviceNotices, now: now)
            recentDeviceNotices = result.recent
            if noticeMonitorsRunning, let slot = result.slot { presentWingNotice(.right, slot: slot) }
        }
    }

    /// Whether a strip that was lit in `old` is gone from `new` — the
    /// moment the band stops mirroring it. A baseline (`old` nil) is not.
    nonisolated static func stripLeft(from old: [CoreDevice]?, to new: [CoreDevice]) -> Bool {
        guard let old else { return false }
        let present = Set(new.filter { $0.kind == "pro" && $0.isPresent }.map(\.id))
        return old.contains { $0.kind == "pro" && $0.isPresent && !present.contains($0.id) }
    }

    /// A strip leaving makes the band's next program change a cross-fade
    /// instead of a cut, for a few seconds: the MacBook's SD reader can
    /// power the Pro off on its own, and a snap from the strip's program
    /// to the band's own display reads as a glitch where a fade reads as
    /// meant. The fade is armed on the view when the program lands.
    private var crossfadeUntil: Date?
    static let unplugCrossfadeWindow: TimeInterval = 5
    static let unplugCrossfadeSeconds: CFTimeInterval = 1.2

    func crossfadeNextProgram() {
        crossfadeUntil = Date().addingTimeInterval(Self.unplugCrossfadeWindow)
    }

    /// How long a level-only change eases for.
    static let levelCrossfadeSeconds: CFTimeInterval = 0.6

    /// Whether `new` is `old` with only its `brightness` lines changed —
    /// the same steps, colours and timings at another level. Brightness
    /// is global in the firmware, wherever the line sits, so the lines
    /// are compared without it; blank lines and surrounding space never
    /// count.
    nonisolated static func onlyBrightnessChanged(from old: String, to new: String) -> Bool {
        func split(_ text: String) -> (steps: [String], levels: [String]) {
            var steps: [String] = []
            var levels: [String] = []
            for raw in text.split(omittingEmptySubsequences: true, whereSeparator: \.isNewline) {
                let line = raw.trimmingCharacters(in: .whitespaces)
                guard !line.isEmpty else { continue }
                if line.lowercased().hasPrefix("brightness") { levels.append(line.lowercased()) } else { steps.append(line) }
            }
            return (steps, levels)
        }
        let before = split(old), after = split(new)
        return !before.steps.isEmpty && before.steps == after.steps && before.levels != after.levels
    }
    private let powerMonitor = AlcovePowerMonitor()
    private let audioMonitor = ScreenBarAudioMonitor()
    private var noticeMonitorsRunning = false
    /// `JRBAR_LOG_MOTION=1` logs which path each program takes.
    private static let logsMotion = ProcessInfo.processInfo.environment["JRBAR_LOG_MOTION"] != nil

    private let panel: ScreenBarPanel
    private let view: ScreenBarView
    private var displayLink: CADisplayLink?
    private var sampler: LEDSSampler?
    private var plan: LEDSKeyframePlan?
    private var anchor: CFTimeInterval = 0
    private var lastCodes: [RGB8] = []
    private var lastRaw: [RGB8] = Array(repeating: .black, count: ScreenBarGeometry.ledCount)
    /// The island frame the last scan saw — the watcher's dedup, so a
    /// poll that finds nothing new runs no layout.
    private var lastIslandScan: NSRect?
    /// The island watch: a pure safety net under the pushes. The island
    /// posts its moves, resizes and orderings (`islandWindowChanged`),
    /// the menu-bar utility pushes its ear limits and every flip of the
    /// ear's ‹ handle (a reveal or rehide, the mirror taking the icon or
    /// handing it back) through `ScreenBarGeometry.earLimitsChanged`,
    /// and a handle click rescans right after its toggle. No change
    /// reaches the band through the poll alone any more; it only bounds
    /// a missed push to a second, so it runs at 1 Hz with a quarter
    /// second of slack to ride other wakeups, not the 4 Hz it once did.
    private var islandWatch: Timer?
    private static let islandWatchInterval: TimeInterval = 1.0
    /// The pending settle pass (`scheduleIslandRescan`).
    private var islandRescanWork: DispatchWorkItem?
    /// The daemon's last epoch anchor — kept so wake can re-lock: the
    /// strip's firmware clock runs through sleep while `CACurrentMediaTime`
    /// pauses, so the media-time anchor computed before the sleep no longer
    /// maps to the strip's phase afterwards.
    private var lastAnchorEpoch: Double?
    /// Reduce Motion: the band holds the program's brightest frame instead
    /// of playing it. Live-read and re-presented on the workspace's change.
    private var reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
    var isShown: Bool { visibility.shown }
    private(set) var programText: String = ""
    /// The raw text of the last ACCEPTED program -- refusal never reaches
    /// it, so a refused republish can neither dedupe against nor move the
    /// anchor of the program actually on the bar.
    private var lastRawText = ""
    /// What `apply` was last handed, accepted or not: the dedupe pair.
    /// `lastRawText` cannot do this job -- a refused program must be
    /// re-checked (the compiler's answer could change) but must never be
    /// mistaken for the running one.
    private var lastSeenText = ""
    private var lastSeenAnchor: Double?
    private(set) var lastRejection: String?

    /// Settings › Screen Bar › Minimum glow — the housing rim's dial,
    /// pushed live from the settings document.
    var minGlow: CGFloat {
        get { view.minGlow }
        set { view.minGlow = newValue }
    }

    /// Alcove's capsule when the band follows it; nil hugs the notch.
    var capsule: AlcoveCapsule? {
        didSet {
            guard capsule != oldValue else { return }
            reposition()
            updateNoticeMonitors()
            updateAppMenuWatch()
            publishStatus()
        }
    }

    /// The frontmost app's menu titles: each ear yields to them as it
    /// does to status items. Read only while a notched screen's ears can
    /// draw (`updateAppMenuWatch`).
    private let appMenus = AppMenuExtent()

    init() {
        let screen = ScreenBarGeometry.preferredScreen()
        // The settings-document geometry lands through the properties
        // above on the first `coreDidChange`; the first frame uses the
        // defaults (`wrap`, no manual gap or wing).
        let frame = screen.map { ScreenBarGeometry.windowFrame(for: $0, wrapMenuBar: Self.defaultWrapMenuBar, capsule: nil) }
            ?? NSRect(x: 0, y: 0, width: ScreenBarDesign.windowWidth, height: ScreenBarGeometry.windowHeight(notchDepth: 0))
        panel = ScreenBarPanel(frame: frame)
        view = ScreenBarView(frame: NSRect(origin: .zero, size: frame.size))
        panel.contentView = view
        view.relayout()

        let center = NotificationCenter.default
        center.addObserver(self, selector: #selector(screensChanged(_:)), name: NSApplication.didChangeScreenParametersNotification, object: nil)
        // The island's frame is the band's silhouette while it is drawn:
        // every setFrame — each step of a morph included — re-reads it,
        // and the ordering notifications catch a show or a park that
        // never moves a point.
        for name in [NSWindow.didMoveNotification, NSWindow.didResizeNotification,
                     NSWindow.didExposeNotification, NSWindow.didChangeOcclusionStateNotification,
                     NotchIslandWindow.didChangeOrderingNotification] {
            center.addObserver(self, selector: #selector(islandWindowChanged(_:)), name: name, object: nil)
        }
        // The flank limits change on the menu-bar utility's reconcile,
        // and the ‹ handle flips with its reveal and its mirror; the
        // utility pushes both here, which beats waiting for the watch.
        ScreenBarGeometry.earLimitsChanged = { [weak self] in self?.scheduleIslandRescan() }
        appMenus.onChange = { [weak self] in self?.reposition() }
        let workspace = NSWorkspace.shared.notificationCenter
        workspace.addObserver(self, selector: #selector(screensDidSleep(_:)), name: NSWorkspace.screensDidSleepNotification, object: nil)
        workspace.addObserver(self, selector: #selector(screensDidWake(_:)), name: NSWorkspace.screensDidWakeNotification, object: nil)
        workspace.addObserver(self, selector: #selector(reduceMotionChanged(_:)), name: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification, object: nil)
        // The video guard's two moving parts besides the media feed: who
        // is frontmost, and a window going full screen (its own Space).
        workspace.addObserver(self, selector: #selector(frontmostMayHaveChanged(_:)), name: NSWorkspace.didActivateApplicationNotification, object: nil)
        workspace.addObserver(self, selector: #selector(frontmostMayHaveChanged(_:)), name: NSWorkspace.activeSpaceDidChangeNotification, object: nil)
        // Settings › Screen Bar's camera hold is an app-local default;
        // re-read it whenever the defaults move. A main-queue block, not
        // a selector: the notification posts on whichever thread wrote
        // the default, and a framework writing off the main thread must
        // not trip this main-actor class's isolation check.
        defaultsObserver = center.addObserver(forName: UserDefaults.didChangeNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.defaultsChanged() }
        }

        // A device transition takes the ambient wing for a beat, then the
        // slot it replaced comes back — the queue's life constant is the
        // same beat the island's capsules hold.
        powerMonitor.onTransition = { [weak self] old, new in
            guard let self, let slot = ScreenBarNotices.power(from: old, to: new) else { return }
            self.presentWingNotice(.right, slot: slot)
        }
        peek.anchor = { [weak self] in self?.peekAnchor }
        audioMonitor.onChange = { [weak self] name, transport in
            guard let self else { return }
            let result = ScreenBarNotices.audio(name: name, transport: transport,
                                                recent: self.recentAudioNotices, now: Date())
            self.recentAudioNotices = result.recent
            if let slot = result.slot { self.presentWingNotice(.right, slot: slot) }
        }
    }

    /// The band's rounded rect in screen coordinates, for hit testing.
    var bandScreenRect: NSRect? {
        guard isShown, panel.isVisible, !steppedAsideForVideo else { return nil }
        return panel.convertToScreen(view.convert(view.bandRect, to: nil))
    }

    /// The hover and click zones in screen coordinates: the band plus each
    /// drawn wing chip. The panel is click-through, so these are only ever
    /// read by `ScreenBarInteraction`'s monitors — and they are exactly the
    /// drawn capsules, so a click on one is a click on something of ours.
    var hoverScreenRects: [NSRect] {
        guard isShown, panel.isVisible, !steppedAsideForVideo else { return [] }
        let drawn: [CGRect?] = [view.bandRect, view.leftWingRect, view.rightWingRect,
                                view.trayRect, view.housingRect]
        // A dismissed wing's ghost stays in the region: the lobe is gone
        // but a swipe across where it stood is the summon gesture. Ghost
        // rects are already screen-space — stored post-conversion.
        return drawn.compactMap { $0 }
            .map { panel.convertToScreen(view.convert($0, to: nil)) }
            + dismissedWingRects.values
    }

    var onGeometryChange: (@MainActor () -> Void)?

    /// A short reason the band is not animating, for the status menu —
    /// nil while it plays normally. Frame-path detail stays in NSLog.
    var menuMotionNote: String? {
        guard sampler != nil else { return "no sampler" }
        if plan?.isStatic == true { return "a still program" }
        if reduceMotion { return "still under Reduce Motion" }
        if holdsStill { return "still while the camera is on" }
        return nil
    }

    /// "keyframes (12 + 61 frames)" or "frame clock", for the log.
    var motionDescription: String {
        guard sampler != nil else { return "nothing" }
        if plan?.isStatic == true { return "static" }
        if reduceMotion { return "still (Reduce Motion)" }
        if holdsStill { return "still (camera on)" }
        if let plan {
            return "keyframes (\(plan.lead?.count ?? 0) + \(plan.loop?.count ?? 0) frames)"
        }
        return "frame clock"
    }

    // MARK: Visibility

    /// The band eases in and out like every other surface (the tooltip's
    /// 0.18 s); Reduce Motion keeps the instant swap.
    private static let fadeSeconds: TimeInterval = 0.18

    func show() {
        visibility.shown = true
        reposition()
        visibility.steppedAside = wantsVideoGuard()
        let shown: CGFloat = steppedAsideForVideo ? 0 : 1
        if reduceMotion {
            panel.alphaValue = shown
            panel.orderFrontRegardless()
        } else {
            panel.alphaValue = 0
            panel.orderFrontRegardless()
            NSAnimationContext.runAnimationGroup { context in
                context.duration = Self.fadeSeconds
                panel.animator().alphaValue = shown
            }
        }
        updateNoticeMonitors()
        updateAppMenuWatch()
        settleVisibility()
        present()
    }

    func hide() {
        visibility.shown = false
        visibility.steppedAside = false
        peek.hide()
        publishStatus()
        ScreenBarGeometry.menuHandleScreenRect = nil
        updateNoticeMonitors()
        updateAppMenuWatch()
        settleVisibility()
        if reduceMotion {
            panel.alphaValue = 1
            panel.orderOut(nil)
        } else {
            NSAnimationContext.runAnimationGroup({ context in
                context.duration = Self.fadeSeconds
                panel.animator().alphaValue = 0
            }, completionHandler: { [weak self] in
                MainActor.assumeIsolated {
                    guard let self, !self.isShown else { return }
                    self.panel.orderOut(nil)
                    self.panel.alphaValue = 1
                }
            })
        }
        updateClock()
    }

    @objc private func screensChanged(_ note: Notification) {
        // The preferred screen can change hands here (the lid closed
        // onto an external, or opened again), so the reader starts or
        // stops before the running one re-reads the titles that moved.
        updateAppMenuWatch()
        appMenus.refresh()
        reposition()
    }

    /// The island moved, resized, or crossed the visible threshold —
    /// re-read its frame and reseat the band. Filtered to the island's
    /// own window: the band's panel fires the same notifications and
    /// must never answer them.
    @objc private func islandWindowChanged(_ note: Notification) {
        guard note.object is NotchIslandWindow else { return }
        islandFrameChanged()
        scheduleIslandRescan()
    }

    /// A settle pass once the run loop turns: a frame write posts before
    /// the order-in lands, the utility sets its two ear limits one after
    /// the other (and pushes a handle flip on the same route), and a
    /// handle click flips the hidden run right after the hit test
    /// answers. One debounced look covers them all.
    private func scheduleIslandRescan() {
        islandRescanWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated { self?.islandFrameChanged() }
        }
        islandRescanWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.06, execute: work)
    }

    /// The poll that owns the coupling's truth: when the island's
    /// on-screen frame is not what the band was last laid out against —
    /// including gone — reposition. The window notifications land here
    /// too, so the morph's steps and the poll share one dedup.
    private func islandFrameChanged() {
        let island = ScreenBarGeometry.islandScreenRect
        let avoidL = ScreenBarGeometry.earItemLimitLeft
        let avoidR = ScreenBarGeometry.earItemLimitRight
        guard island != lastIslandScan || avoidL != lastEarAvoidLeft
                || avoidR != lastEarAvoidRight
                || menuHandleProvider?() != view.menuHandleRevealed else { return }
        reposition()
    }

    /// The hidden-run handle's state: the ear's ‹ is the fallback
    /// affordance while the menu-bar concealer runs and no mirror
    /// carries the icon (the Hidden style, or an empty target); nil
    /// otherwise, which hides it. Every rescan compares it against what
    /// the view last drew, and the utility pushes each flip through
    /// `ScreenBarGeometry.earLimitsChanged`; a click on the handle
    /// rescans at once.
    var menuHandleProvider: (@MainActor () -> Bool?)?

    /// The handle's slice of the right ear as a screen-space hit test —
    /// a click inside it toggles the hidden run, it is not the wing's.
    func menuHandle(atScreenPoint point: NSPoint) -> Bool {
        guard isShown, panel.isVisible, !steppedAsideForVideo, let rect = view.menuHandleRect else {
            // Debug, not notice: every band click asks, and no handle is
            // the normal state while the mirror carries the icon.
            MenuBarCombinedItem.log.debug("menuHandle: dead — shown=\(self.isShown) visible=\(self.panel.isVisible) rect=\(self.view.menuHandleRect == nil ? "nil" : "set")")
            return false
        }
        let hit = panel.convertToScreen(view.convert(rect, to: nil))
            .insetBy(dx: -2, dy: -3).contains(point)
        MenuBarCombinedItem.log.notice("menuHandle: point=\(point.x, privacy: .public),\(point.y, privacy: .public) rect=\(rect.debugDescription, privacy: .public) hit=\(hit)")
        // A hit is followed straight away by the toggle; the rescan
        // flips the glyph without waiting a whole watch period.
        if hit { scheduleIslandRescan() }
        return hit
    }

    /// The flank item edges the ears were last laid out against.
    private var lastEarAvoidLeft: CGFloat?
    private var lastEarAvoidRight: CGFloat?

    /// The safety poll lives exactly as long as somebody can see the
    /// band: a hidden, sleeping or stepped-aside band has no silhouette
    /// to keep in step, and the edge back looks once at once.
    private func syncIslandWatch() {
        if visibility.live, islandWatch == nil {
            let timer = Timer(timeInterval: Self.islandWatchInterval, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated { self?.islandFrameChanged() }
            }
            timer.tolerance = Self.islandWatchInterval / 4
            RunLoop.main.add(timer, forMode: .common)
            islandWatch = timer
            islandFrameChanged()
        } else if !visibility.live {
            islandWatch?.invalidate()
            islandWatch = nil
        }
    }

    /// A visibility fact moved: on an edge of "somebody can see it", the
    /// island watch, the hover poll, the frame clock and the ears'
    /// timelines start or park together.
    private func settleVisibility() {
        guard let live = visibility.settle() else { return }
        view.wingsLive = live
        syncIslandWatch()
        updateClock()
        onLiveChange?(live)
    }

    @objc private func screensDidSleep(_ note: Notification) {
        visibility.displayAsleep = true
        settleVisibility()
    }
    @objc private func screensDidWake(_ note: Notification) {
        visibility.displayAsleep = false
        if let epoch = lastAnchorEpoch {
            let now = CACurrentMediaTime()
            let locked = Self.mediaTime(forEpoch: epoch)
            // A sane epoch re-locks the phase; one that fails the check
            // (clock skew, a daemon restarted while we slept) would pin
            // the program to a garbage offset -- restart from wake instead.
            anchor = locked <= now + 0.05 && now - locked < 6 * 3600 ? locked : now
        }
        settleVisibility()
        present()
    }

    /// Reduce Motion toggled in System Settings: freeze the moving program
    /// or hand a still one back to Core Animation.
    @objc private func reduceMotionChanged(_ note: Notification) {
        reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        present()
    }

    /// The camera hold's or the video guard's switch moved (or any other
    /// default did — the reads are cheap and only a real change acts).
    private func defaultsChanged() {
        let overVideo = UserDefaults.standard.object(forKey: Self.hideOverVideoDefaultsKey) as? Bool ?? true
        if overVideo != hideOverVideo {
            hideOverVideo = overVideo
            updateVideoGuard()
        }
        let wanted = UserDefaults.standard.object(forKey: Self.stillOnCameraDefaultsKey) as? Bool ?? true
        guard wanted != stillOnCamera else { return }
        stillOnCamera = wanted
        if sensors.cameraInUse { present() }
    }

    @objc private func frontmostMayHaveChanged(_ note: Notification) {
        updateVideoGuard()
        // A window entering or leaving full screen is still resizing when
        // the Space change lands; look again once it has settled.
        videoGuardRecheck?.cancel()
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated { self?.updateVideoGuard() }
        }
        videoGuardRecheck = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0, execute: work)
    }

    private var videoGuardRecheck: DispatchWorkItem?

    // MARK: Full-screen video

    /// Whether the band should step aside right now: shown over full
    /// screen, the guard on, and the frontmost app both the one playing
    /// and filling the band's screen.
    private func wantsVideoGuard() -> Bool {
        guard isShown, showsInFullScreen, hideOverVideo,
              let playing = nowPlaying,
              let front = NSWorkspace.shared.frontmostApplication,
              front.bundleIdentifier == playing,
              let screen = ScreenBarGeometry.preferredScreen() else { return false }
        return Self.windowFillsScreen(pid: front.processIdentifier, screen: screen)
    }

    /// Fades the band out over a full-screen video, and back in after.
    private func updateVideoGuard() {
        let want = wantsVideoGuard()
        guard want != steppedAsideForVideo, isShown else { return }
        visibility.steppedAside = want
        if want { peek.hide() }
        publishStatus()
        settleVisibility()
        onGeometryChange?()
        let alpha: CGFloat = want ? 0 : 1
        if reduceMotion {
            panel.alphaValue = alpha
        } else {
            NSAnimationContext.runAnimationGroup { context in
                context.duration = Self.fadeSeconds
                panel.animator().alphaValue = alpha
            }
        }
    }

    /// Whether `pid` has an ordinary on-screen window filling `screen`: its
    /// whole width and height, the top allowed to start under the camera
    /// housing, where a notched MacBook puts full-screen content by
    /// default. Window bounds and owners need no Screen Recording grant;
    /// titles would.
    static func windowFillsScreen(pid: pid_t, screen: NSScreen) -> Bool {
        guard let info = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] else { return false }
        let bounds = info.compactMap { window -> CGRect? in
            guard (window[kCGWindowOwnerPID as String] as? pid_t) == pid,
                  (window[kCGWindowLayer as String] as? Int) == 0,
                  let raw = window[kCGWindowBounds as String] as? NSDictionary else { return nil }
            return CGRect(dictionaryRepresentation: raw as CFDictionary)
        }
        let primaryHeight = NSScreen.screens.first?.frame.height ?? screen.frame.height
        return coversScreen(windowBounds: bounds, screenFrame: screen.frame, primaryHeight: primaryHeight,
                            topInset: screen.safeAreaInsets.top)
    }

    /// The pure half: a window rect (Quartz, top-left origin) spanning the
    /// screen's frame (AppKit, bottom-left origin) side to side and to the
    /// bottom, its top no lower than the camera housing's inset. A zoomed
    /// window stops under the menu bar, which on a notched screen is one
    /// point deeper than the housing (33 against 32 on a 14-inch), so the
    /// top gets only half a point of slack; the sides and bottom a point.
    nonisolated static func coversScreen(windowBounds: [CGRect], screenFrame: CGRect, primaryHeight: CGFloat,
                                         topInset: CGFloat = 0) -> Bool {
        let quartz = CGRect(x: screenFrame.minX, y: primaryHeight - screenFrame.maxY,
                            width: screenFrame.width, height: screenFrame.height)
        return windowBounds.contains { window in
            window.minX <= quartz.minX + 1 && window.maxX >= quartz.maxX - 1
                && window.maxY >= quartz.maxY - 1 && window.minY <= quartz.minY + max(0, topInset) + 0.5
        }
    }

    /// Hands what the band is doing to Settings' "Right now" line.
    private func publishStatus() {
        let status = ScreenBarLiveStatus.shared
        if status.rejection != lastRejection { status.rejection = lastRejection }
        let note = menuMotionNote
        if status.motionNote != note { status.motionNote = note }
        if status.followingAlcove != (capsule != nil) { status.followingAlcove = capsule != nil }
        if status.steppedAsideForVideo != steppedAsideForVideo { status.steppedAsideForVideo = steppedAsideForVideo }
    }

    /// Each side's content-wing claim: the measured flank room beside the
    /// notch, or a fixed reach beside the band where there is no safe area
    /// to measure. A side with no slot claims nothing, and while the band
    /// follows an external capsule the flanks belong to it — both stand down.
    private func wingExtents(on screen: NSScreen, notchWidth: CGFloat, notchDepth: CGFloat) -> (left: CGFloat, right: CGFloat) {
        let shown = effectiveWings
        guard notchWingsEnabled, capsule == nil else { return (0, 0) }
        if notchDepth <= 0 {
            return (shown.left == nil ? 0 : ScreenBarGeometry.notchlessWingClaim,
                    shown.right == nil ? 0 : ScreenBarGeometry.notchlessWingClaim)
        }
        return (shown.left == nil ? 0
                    : ScreenBarGeometry.contentWingExtent(of: screen, side: .left, notchWidth: notchWidth),
                // The menu handle claims the right flank even with no
                // session wing — a handle with no ear has no home.
                shown.right == nil && menuHandleProvider?() == nil ? 0
                    : ScreenBarGeometry.contentWingExtent(of: screen, side: .right, notchWidth: notchWidth))
    }

    /// The base slots minus what the user flicked away, plus a live
    /// device notice — the wings the view and the geometry share.
    private var effectiveWings: ScreenBarWings {
        var shown = markedWings
        for (side, dismissed) in dismissedWings {
            if let slot = shown[side], Self.sameWingSubject(slot, dismissed) {
                shown[side] = nil
            }
        }
        if let notice = wingNotice, notice.until > Date() {
            shown[notice.side] = notice.slot
        }
        return ScreenBarWings.withSensors(sensors, on: shown)
    }

    /// The view keeps the effective slots; `reposition` reads them
    /// through `wingExtents`, so the geometry and the draw never split.
    private func syncWings() {
        view.wings = effectiveWings
    }

    /// A wing state change outside `reposition`'s own path — dismiss,
    /// summon, notice — pushes the slots and relayouts once.
    private func pushWings() {
        syncWings()
        reposition()
    }

    // MARK: Wing gestures and device notices

    /// Which drawn wing a screen point is over — the dismiss swipe's
    /// target. The band and empty flank room answer nil.
    func wingSide(atScreenPoint point: NSPoint) -> ScreenBarWingSide? {
        guard isShown, panel.isVisible, !steppedAsideForVideo else { return nil }
        for (side, rect) in [(ScreenBarWingSide.left, view.leftWingRect),
                             (.right, view.rightWingRect)] {
            if let rect, panel.convertToScreen(view.convert(rect, to: nil))
                .insetBy(dx: -2, dy: -3).contains(point) { return side }
        }
        return nil
    }

    /// The outward flick: the side stays down until a summon, a
    /// relaunch, or a different subject claiming it — not until its
    /// own words churn. The lobe's rect survives as the ghost a
    /// summon swipe lands on.
    func dismissWing(_ side: ScreenBarWingSide) {
        guard let slot = markedWings[side] else { return }
        NotchCardModel.wingGesturesUsed = true
        if let viewRect = side == .left ? view.leftWingRect : view.rightWingRect {
            dismissedWingRects[side] = panel.convertToScreen(view.convert(viewRect, to: nil))
        }
        dismissedWings[side] = slot
        pushWings()
    }

    /// The summon: every dismissed wing comes back.
    func restoreWings() {
        guard !dismissedWings.isEmpty else { return }
        NotchCardModel.wingGesturesUsed = true
        dismissedWings = [:]
        dismissedWingRects = [:]
        pushWings()
    }

    /// The ear rides a dismiss-pull — the view owns the easing; the
    /// controller only forwards the finger's travel.
    func pullWing(_ side: ScreenBarWingSide, to dx: CGFloat) {
        guard isShown else { return }
        view.setWingPull(side, to: dx)
    }

    /// The pull ended short of a flick — the ear springs home.
    func releaseWingPull(_ side: ScreenBarWingSide) {
        view.setWingPull(side, to: 0, springBack: true)
    }

    /// The pointer's ear — the hover tell the view swells. No `isShown`
    /// gate: a settle under a hidden panel must still land, or the next
    /// show would draw a stale swell.
    func hoverWing(_ side: ScreenBarWingSide?) {
        view.setWingHover(side)
    }

    /// A device transition holds the ambient wing for `life`, then the
    /// slot it replaced returns.
    private func presentWingNotice(_ side: ScreenBarWingSide, slot: ScreenBarWingSlot) {
        wingNotice = (side, slot, Date().addingTimeInterval(ScreenBarNotices.life))
        pushWings()
        wingNoticeWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.wingNotice = nil
                self.pushWings()
            }
        }
        wingNoticeWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + ScreenBarNotices.life, execute: work)
    }

    /// The transition monitors earn their keep only while the wings are
    /// actually up — the island's own pollers take over when the band
    /// follows an Alcove capsule.
    private func updateNoticeMonitors() {
        let want = isShown && notchWingsEnabled && wingNoticesEnabled && capsule == nil
        guard want != noticeMonitorsRunning else { return }
        noticeMonitorsRunning = want
        if want {
            powerMonitor.start()
            audioMonitor.start()
        } else {
            powerMonitor.stop()
            audioMonitor.stop()
        }
    }

    /// The menu-title reader follows the ears that can yield to it:
    /// shown, wings on, no external capsule holding the flanks, and a
    /// real notch on the band's screen. A notch-less screen's chips
    /// carry themselves in their whole claim (`ScreenBarView`'s
    /// `earRect` returns before it reads a limit), so the titles never
    /// move a pixel there and each activation's two AX walks bought
    /// nothing. The simulated notch has no safe-area depth either, so
    /// it takes the same answer. A notched screen keeps the reader even
    /// while no ear draws: content or the handle can arrive at any
    /// moment, and a reader started then would leave the new ear over
    /// the titles for a frame while its first walk is in flight.
    private func updateAppMenuWatch() {
        let notched = ScreenBarGeometry.preferredScreen().map(ScreenBarGeometry.hasNotch) ?? false
        if isShown && notchWingsEnabled && capsule == nil && notched {
            appMenus.start()
        } else {
            appMenus.stop()
        }
    }

    /// Resolves the profile (and the custom slider) into the corner the
    /// tray draws — the bezel's own radius on this Mac.
    private func syncNotchCorner() {
        view.notchCornerRadius = notchProfile.cornerRadius(manual: notchCornerManual)
    }

    private func reposition() {
        guard let screen = ScreenBarGeometry.preferredScreen() else { return }
        let oldRects = (view.bandRect, view.leftWingRect, view.rightWingRect, view.housingRect, view.menuHandleRect)
        let depth = ScreenBarGeometry.notchDepth(of: screen)
        // Our notch island, while it is drawn: the band couples to it —
        // the strip runs the island's width under it and the black
        // housing continues its silhouette. Only on the notched screen
        // the band belongs to; a floating island on a notch-less display
        // keeps the standalone band, as does any other provider's.
        let island = ScreenBarGeometry.islandScreenRect
        lastIslandScan = island
        lastEarAvoidLeft = ScreenBarGeometry.earItemLimitLeft
        lastEarAvoidRight = ScreenBarGeometry.earItemLimitRight
        let coupledIsland = island.flatMap { rect -> NSRect? in
            guard depth > 0, rect.width > 1,
                  screen.frame.contains(NSPoint(x: rect.midX, y: rect.midY)) else { return nil }
            return rect
        }
        let notchWidth = ScreenBarGeometry.resolvedNotchWidth(slotWidth: ScreenBarGeometry.slotWidth(of: screen),
                                                            gapWidth: gapWidth)
        let extents = wingExtents(on: screen, notchWidth: notchWidth, notchDepth: depth)
        // A claimed wing hangs the tray `wingEarDrop` below the bezel
        // (flush today); `windowFrame` grows the window by that much
        // plus the strip's housing under it.
        let chin = extents.left > 0 || extents.right > 0 ? ScreenBarGeometry.wingEarDrop : 0
        let frame = ScreenBarGeometry.windowFrame(for: screen, wrapMenuBar: wrapMenuBar,
                                                  gapWidth: gapWidth, wingLength: wingLength, capsule: capsule,
                                                  contentExtent: max(extents.left, extents.right),
                                                  chin: chin, coupledIsland: coupledIsland)
        view.bandSpan = ScreenBarGeometry.windowFrame(for: screen, wrapMenuBar: wrapMenuBar,
                                                      gapWidth: gapWidth, wingLength: wingLength,
                                                      capsule: capsule).width
        view.wingGeometry = ScreenBarWingGeometry(notchWidth: notchWidth, notchDepth: depth,
                                                  bandSpan: view.bandSpan,
                                                  leftExtent: extents.left, rightExtent: extents.right)
        // Each ear stops short of the nearest status item or app menu
        // title on its flank — the « a hidden run keeps beside the notch,
        // our own chevron, whatever macOS parks there, a long menu bar's
        // last titles. A drawn wing paving a real item hides it and
        // swallows its clicks (screen x → view x). The gap
        // is a real 8 pt: transient indicators macOS drops in the flank
        // — the mic pill, a voice-recording mark — are never in the
        // listing, and a 2 pt seam reads as overlap when one lands.
        let limits = ScreenBarGeometry.earLimits(itemLeft: lastEarAvoidLeft, itemRight: lastEarAvoidRight,
                                                 menuTitles: appMenus.titles, screen: screen.frame,
                                                 notchMidX: frame.midX)
        view.rightEarLimit = limits.right.flatMap { limit in
            limit > frame.midX ? limit - frame.minX - 8 : nil
        }
        view.leftEarLimit = limits.left.flatMap { limit in
            limit < frame.midX ? limit - frame.minX + 8 : nil
        }
        view.menuHandleRevealed = menuHandleProvider?()
        syncWings()
        if panel.frame != frame {
            panel.setFrame(frame, display: false)
            view.frame = NSRect(origin: .zero, size: frame.size)
            lastCodes = []
            present()
        }
        view.islandFrame = coupledIsland.map { island in
            CGRect(x: island.minX - frame.minX, y: island.minY - frame.minY,
                   width: island.width, height: island.height)
        }
        view.relayout()
        // The hidden-run handle's screen frame goes to the reveal engine —
        // hovering the glyph is a reveal gesture, same as Bartender's «.
        ScreenBarGeometry.menuHandleScreenRect = view.menuHandleRect.map {
            panel.convertToScreen(view.convert($0, to: nil))
        }
        // Wing chips come and go without a frame change; the hit region
        // follows the drawn capsules, not the window.
        if (view.bandRect, view.leftWingRect, view.rightWingRect, view.housingRect, view.menuHandleRect) != oldRects {
            onGeometryChange?()
        }
        // A peek hanging from the right ear follows it — or folds with it.
        syncPeek()
    }

    // MARK: The menu bar's peek

    /// Whether the ears are up to carry the menu bar's marks: shown, the
    /// wings on, no external capsule holding the flanks, not stepped
    /// aside for a video.
    var carriesMenuBarMarks: Bool {
        isShown && notchWingsEnabled && capsule == nil && !steppedAsideForVideo
    }

    /// Whether the right ear opens the peek right now: the ears carry
    /// the menu bar, the feed has something to show, and the ear draws.
    var peekAvailable: Bool {
        carriesMenuBarMarks && panel.isVisible && view.rightWingRect != nil
            && !(menuBarFeed?.isEmpty ?? true)
    }

    /// Whether a screen point is on the part of the right ear that
    /// answers with the peek: the whole ear but the ‹ slice, which keeps
    /// its own click and its own hover reveal. The two never overlap,
    /// slack included. False while there is nothing to peek at.
    func peekZone(atScreenPoint point: NSPoint) -> Bool {
        guard peekAvailable, let ear = view.rightWingRect,
              let zone = Self.peekZoneRect(ear: ear, handle: view.menuHandleRect) else { return false }
        return panel.convertToScreen(view.convert(zone, to: nil))
            .insetBy(dx: -2, dy: -3).contains(point)
    }

    /// The peek's zone of the right ear, view coordinates: the ear up to
    /// four points short of the ‹ slice, so the zone's 2 pt of slack and
    /// the handle's own never meet. nil when the handle leaves no room.
    /// Pure so a test pins the seam.
    nonisolated static func peekZoneRect(ear: CGRect, handle: CGRect?) -> CGRect? {
        var zone = ear
        if let handle { zone.size.width = max(0, handle.minX - 4 - ear.minX) }
        return zone.width > 0 ? zone : nil
    }

    /// The hanging peek's frame; nil while it is down.
    var peekFrame: NSRect? { peek.frame }

    /// Whether a screen point is on the corridor from the ear down to the
    /// hanging peek — the peek, the ear, and the band's stretch between
    /// them, so crossing the light on the way to a glyph never counts as
    /// leaving. False while the peek is down.
    func peekCorridor(contains point: NSPoint) -> Bool {
        guard let frame = peek.frame else { return false }
        return Self.peekCorridor(frame.union(rightEarScreenRect ?? frame), contains: point,
                                 handle: menuHandleScreenRect)
    }

    /// The corridor's test — pure so a test pins the seam: its box, but
    /// never the ‹ slice inside it, which keeps its own hover reveal and
    /// its own click while the peek hangs as while it is down.
    nonisolated static func peekCorridor(_ corridor: CGRect, contains point: CGPoint, handle: CGRect?) -> Bool {
        corridor.contains(point) && !(handle?.contains(point) ?? false)
    }

    /// The ‹ slice's drawn bounds in screen coordinates while it stands.
    private var menuHandleScreenRect: NSRect? {
        guard isShown, panel.isVisible, !steppedAsideForVideo, let rect = view.menuHandleRect else { return nil }
        return panel.convertToScreen(view.convert(rect, to: nil))
    }

    /// The right ear's drawn bounds in screen coordinates while it
    /// stands.
    private var rightEarScreenRect: NSRect? {
        guard isShown, panel.isVisible, !steppedAsideForVideo, let rect = view.rightWingRect else { return nil }
        return panel.convertToScreen(view.convert(rect, to: nil))
    }

    /// Where the peek hangs: the right ear, the band it stays under, the
    /// band's screen.
    private var peekAnchor: ScreenBarPeekAnchor? {
        guard let ear = rightEarScreenRect,
              let screen = panel.screen ?? ScreenBarGeometry.preferredScreen() else { return nil }
        return ScreenBarPeekAnchor(ear: ear, band: bandScreenRect, screen: screen.frame)
    }

    /// The pointer's ask of the peek.
    func handlePeek(_ intent: ScreenBarPeekIntent) {
        switch intent {
        case .hover:
            guard peekAvailable, !peek.isShown else { return }
            syncPeekModel()
            peek.show(pinned: false)
        case .pin:
            guard peekAvailable else { return }
            syncPeekModel()
            peek.show(pinned: true)
        case .toggle:
            if peek.isShown, peek.isPinned {
                peek.hide()
            } else if peekAvailable {
                syncPeekModel()
                peek.show(pinned: true)
            }
        case .close:
            peek.hide()
        }
    }

    /// A hanging peek follows the feed and the ear, and folds once there
    /// is nothing left to show or no ear to hang from.
    private func syncPeek() {
        guard peek.isShown else { return }
        guard peekAvailable else { peek.hide(); return }
        syncPeekModel()
        peek.relayout()
    }

    private func syncPeekModel() {
        let tiles = menuBarFeed?.hidden ?? []
        if peek.model.tiles != tiles { peek.model.tiles = tiles }
        if peek.model.failure != menuBarFeed?.failure { peek.model.failure = menuBarFeed?.failure }
        if peek.model.nudge != menuBarFeed?.nudge { peek.model.nudge = menuBarFeed?.nudge }
        if peek.model.awake != earMarks.awake { peek.model.awake = earMarks.awake }
        let width = ScreenBarPeekLayout.width(tileWidths: tiles.map(\.width), hasWords: peek.model.hasWords)
        if peek.model.width != width { peek.model.width = width }
    }

    // MARK: Programs

    /// Parses `text` and puts it on the bar. Refused programs (the firmware
    /// would strobe red) keep the previous program and are reported, never shown.
    ///
    /// `anchorEpoch` is the daemon's `lights.surfaces.screen_bar.anchor`: the
    /// Unix time at which the strip started this program. Passing it
    /// phase-locks the band to the hardware, so a pulse on the desk and the
    /// pulse under the notch swell together. Without it the program starts
    /// now, as a file feed would.
    func apply(programText text: String, anchorEpoch: Double? = nil) {
        if text == lastSeenText, anchorEpoch == lastSeenAnchor, sampler != nil {
            // A verbatim republish -- same text at the same epoch -- carries
            // no new information at all.
            return
        }
        lastSeenText = text
        lastSeenAnchor = anchorEpoch
        if text == lastRawText, sampler != nil {
            // Same program: only a moved anchor is a reason to act at all,
            // and a re-aligned anchor replays the plan instead of paying
            // for a recompile. A nil anchor carries no phase word, so an
            // identical republish never restarts.
            lastAnchorEpoch = anchorEpoch
            guard let anchorEpoch else { return }
            let now = CACurrentMediaTime()
            let locked = Self.mediaTime(forEpoch: anchorEpoch)
            guard locked <= now + 0.05, now - locked < 6 * 3600 else { return }
            if abs(locked - anchor) < 0.02 { return }
            anchor = locked
            present()
            return
        }
        let decision = Self.programDecision(text, fallback: programText.isEmpty ? LEDSPresentationCompiler.safeFallbackProgram : programText)
        let wasRefusing = lastRejection != nil
        lastRejection = decision.rejection
        guard let program = decision.program, let compiledText = decision.programText else {
            // Refused: `lastRawText`/`lastAnchorEpoch` keep describing the
            // program still on the bar -- a refused text must not move the
            // running program's anchor (it used to, through `lastRawText`).
            NSLog("JR-Bar: refusing LEDS program (%@); keeping the previous one", decision.rejection ?? "?")
            // The first refusal in a run holds the right ear for a beat —
            // a mark, not words: the band kept the last safe program and
            // says so where the eye already is.
            if !wasRefusing, let slot = ScreenBarNotices.refused(decision.rejection) {
                presentWingNotice(.right, slot: slot)
            }
            publishStatus()
            return
        }
        let previousText = lastRawText
        lastRawText = text
        // Only a band on screen arms a fade: armed while hidden, it would
        // wait for whatever change came after the next show.
        if !isShown {
            crossfadeUntil = nil
        } else if let until = crossfadeUntil, until > Date() {
            crossfadeUntil = nil
            view.crossfadeNextChange(over: Self.unplugCrossfadeSeconds)
        } else if Self.onlyBrightnessChanged(from: previousText, to: text) {
            // A dimmer step (the panel's slider, idle dim, a Focus rule)
            // rewrites the program with a new `brightness N` and nothing
            // else; the band eases to the new level instead of jumping.
            crossfadeUntil = nil
            view.crossfadeNextChange(over: Self.levelCrossfadeSeconds)
        }
        // The firmware starts a new program from the colours currently showing.
        let now = CACurrentMediaTime()
        if let sampler {
            lastRaw = sampler.rawCodes(atMilliseconds: milliseconds(now))
        }
        programText = compiledText
        let sampler = LEDSSampler(program: program, ledCount: ScreenBarGeometry.ledCount, initialCodes: lastRaw)
        self.sampler = sampler
        plan = LEDSKeyframePlan.render(sampler: sampler)
        anchor = now
        lastAnchorEpoch = anchorEpoch
        if let anchorEpoch {
            let locked = Self.mediaTime(forEpoch: anchorEpoch)
            // Trust anchors from the recent past; a future or absurd anchor
            // (clock skew, a daemon restart) falls back to "now".
            if locked <= now + 0.05, now - locked < 6 * 3600 { anchor = locked }
        }
        lastCodes = []
        present()
    }

    /// The compile-and-parse verdict `apply` reaches before anything moves:
    /// the program to install and its canonical text, or the refusal reason
    /// (the firmware would strobe red). Pure — no panel, no clock — so the
    /// acceptance rules are testable. On refusal nothing is installed and
    /// `lastRejection` carries the reason; the previous program stays.
    nonisolated static func programDecision(_ text: String, fallback: String) -> (program: LEDSProgram?, programText: String?, rejection: String?) {
        let compiled = LEDSPresentationCompiler.compile(text, ledCount: ScreenBarGeometry.ledCount, fallback: fallback)
        guard compiled.accepted else {
            // The compiler's own reasons when the raw text parses; the
            // parse error itself when it does not — the more specific
            // sentence is the one worth logging.
            do {
                _ = try LEDSProgram.parse(text, ledCount: ScreenBarGeometry.ledCount)
                return (nil, nil, compiled.reasons.joined(separator: ", "))
            } catch {
                return (nil, nil, error.description)
            }
        }
        do {
            let program = try LEDSProgram.parse(compiled.program, ledCount: ScreenBarGeometry.ledCount)
            return (program, compiled.program, nil)
        } catch {
            return (nil, nil, error.description)
        }
    }

    /// Converts a Unix timestamp into the display link's `CACurrentMediaTime` clock.
    nonisolated static func mediaTime(forEpoch epoch: Double) -> CFTimeInterval {
        CACurrentMediaTime() - (Date().timeIntervalSince1970 - epoch)
    }

    /// Seconds since the current program's t=0 (for the menu's "why" line).
    var programAge: TimeInterval { CACurrentMediaTime() - anchor }

    private func milliseconds(_ time: CFTimeInterval) -> Int {
        Int(((time - anchor) * 1000.0).rounded(.down))
    }

    /// The codes the band shows right now (tests and the why popover).
    var currentCodes: [RGB8] {
        let ms = max(0, milliseconds(CACurrentMediaTime()))
        if let plan { return plan.codes(atMilliseconds: ms) }
        return sampler?.codes(atMilliseconds: ms) ?? []
    }

    // MARK: Presentation

    /// Puts the current program on the layers: keyframes when the plan fits,
    /// else the frame clock — or, under Reduce Motion, one still frame and
    /// no clock at all. The colour still carries the state; the motion is
    /// what goes away.
    private func present() {
        guard sampler != nil else { updateClock(); return }
        if Self.logsMotion { NSLog("JR-Bar: screen bar %@, anchor %.1f s ago", motionDescription, programAge) }
        updateAccessibility()
        defer { publishStatus() }
        if holdsStill {
            view.stopKeyframes()
            displayLink?.isPaused = true
            renderStillFrame()
            return
        }
        if let plan {
            displayLink?.isPaused = true
            if isShown { view.play(plan: plan, anchor: anchor) }
        } else {
            view.stopKeyframes()
            renderCurrentFrame()
            updateClock()
        }
    }

    /// The frame Reduce Motion holds: the brightest instant of the program's
    /// first cycle — the same still `LEDStripPreview` shows — so a pulse
    /// keeps its peak and a chase keeps its gradient, not a dark first frame.
    private func renderStillFrame() {
        guard let sampler else { return }
        var t = 0.0
        let span = sampler.cycleDuration ?? sampler.motionEndsAt ?? 0
        if span > 0 {
            var bestLevel = -1.0
            for k in 0..<12 {
                let probe = span * Double(k) / 12
                let level = sampler.colors(at: probe).map(\.maxChannel).reduce(0, +)
                if level > bestLevel { bestLevel = level; t = probe }
            }
        }
        let codes = sampler.codes(atMilliseconds: Int((t * 1000).rounded()))
        lastCodes = codes
        view.display(colors: codes.map(\.rgb))
    }

    /// VoiceOver's name for the band: the current focus session when one is
    /// on the band ("Screen Bar — Codex, needs you"), else what the band is;
    /// either way it owns up when a program was refused. Refreshed from
    /// `present()` and from `coreDidChange`, so a state change that doesn't
    /// move the light still reaches VoiceOver.
    var focusProvider: (@MainActor () -> ScreenBarFocus?)?
    func updateAccessibility() {
        let summary = focusProvider?().map { "\($0.label) — \($0.word.lowercased())" }
        view.setAccessibilityLabel(lastRejection == nil
            ? "Screen Bar — \(summary ?? "agent status light")"
            : "Screen Bar — \(summary ?? "agent status light"); a program was refused, showing the last safe one")
    }

    // MARK: Frame clock (fallback)

    private func updateClock() {
        guard let sampler, plan == nil else { displayLink?.isPaused = true; return }
        let stillMoving: Bool
        if let end = sampler.motionEndsAt {
            stillMoving = CACurrentMediaTime() - anchor < end + 0.1
        } else {
            stillMoving = true
        }
        let shouldRun = visibility.live && stillMoving
        if shouldRun {
            if displayLink == nil {
                let link = view.displayLink(target: self, selector: #selector(tick(_:)))
                link.preferredFrameRateRange = CAFrameRateRange(minimum: 24, maximum: 60, preferred: 60)
                link.add(to: .main, forMode: .common)
                displayLink = link
            }
            displayLink?.isPaused = false
        } else {
            displayLink?.isPaused = true
        }
    }

    @objc private func tick(_ link: CADisplayLink) {
        guard plan == nil else { link.isPaused = true; return }
        renderCurrentFrame(at: link.targetTimestamp)
        if let sampler, let end = sampler.motionEndsAt, link.targetTimestamp - anchor >= end + 0.1 {
            // Final frame is on screen; stop asking for more.
            link.isPaused = true
        }
    }

    private func renderCurrentFrame(at time: CFTimeInterval? = nil) {
        guard let sampler else { return }
        let ms = max(0, milliseconds(time ?? CACurrentMediaTime()))
        let codes = sampler.codes(atMilliseconds: ms)
        if codes == lastCodes { return }
        lastCodes = codes
        view.display(colors: codes.map(\.rgb))
    }
}

/// Whether anybody can see the band: shown, the display awake, and not
/// stepped aside for a full-screen video. Everything that exists only to
/// be seen — the hover poll, the island watch, the frame clock, the
/// ears' timelines — runs while `live` and parks on its edge down, so an
/// overnight run with the display asleep, or a movie, wakes nothing.
struct ScreenBarVisibility: Equatable {
    var shown = false
    var displayAsleep = false
    var steppedAside = false
    /// The `live` the clocks were last set to.
    private(set) var applied = false

    var live: Bool { shown && !displayAsleep && !steppedAside }

    /// The edge since the last settle, once: true starts the clocks,
    /// false parks them, nil leaves them as they are.
    mutating func settle() -> Bool? {
        guard live != applied else { return nil }
        applied = live
        return live
    }
}

/// What the band is doing right now, published by the controller for
/// Settings › Devices › Screen Bar — the same facts the status menu's
/// lights line reads, in one observable place.
@MainActor
@Observable
final class ScreenBarLiveStatus {
    static let shared = ScreenBarLiveStatus()
    /// The last refused program's reason while the band holds the
    /// previous one; nil while the running program is the latest.
    var rejection: String?
    /// Why the band is not moving ("still under Reduce Motion"), or nil.
    var motionNote: String?
    var followingAlcove = false
    /// True while the band has stepped aside for a full-screen video.
    var steppedAsideForVideo = false
    /// True while the notch island's mic/camera poll runs — the only
    /// camera reading the band has (`ScreenBarCameraHold.readable`).
    /// Without it "Hold still on camera" has nothing to hold on, and the
    /// card says so instead of promising it.
    var cameraReadable = false
    /// What the band plays while the monitor is offline — the file feed
    /// the app fell back to — so the line names the idle breath as the
    /// idle breath, not as the strip's last program.
    var offlineFeed: ScreenBarSourceLine.OfflineFeed?

    /// The fallback put `source` on the band. It re-lands on every offline
    /// refresh, so only a different feed touches the observed value.
    func noteOfflineFeed(_ source: LEDFeed.Source) {
        let feed = ScreenBarSourceLine.OfflineFeed(source)
        if offlineFeed != feed { offlineFeed = feed }
    }
}

/// The Screen Bar card's "Right now" line: which source the band plays,
/// whether a program was refused, and why it may be still — the answers
/// the card never gave ("whose clock is it on?", "why is it frozen?").
enum ScreenBarSourceLine {
    /// The app's own fallback while the monitor is away (`LEDFeed`): the
    /// strip's `LEDS.LED`, an override feed file, or the built-in breath.
    enum OfflineFeed: Equatable {
        case strip, file, idleBreath

        init(_ source: LEDFeed.Source) {
            switch source {
            case .device: self = .strip
            case .stateFile: self = .file
            case .builtInIdle: self = .idleBreath
            }
        }

        var playing: String {
            switch self {
            case .strip: return "playing the last program the strip was sent"
            case .file: return "playing the feed file's program"
            case .idleBreath: return "playing the built-in idle breath"
            }
        }
    }

    static func describe(live: Bool, mirrorSetting: Bool, stripPresent: Bool, phaseOffsetMs: Double?,
                         why: String?, rejection: String?, motionNote: String?, followingAlcove: Bool,
                         steppedAsideForVideo: Bool = false, cue: String? = nil,
                         offlineFeed: OfflineFeed? = nil) -> String {
        var parts: [String] = []
        if !live {
            parts.append("Monitor offline — " + (offlineFeed ?? .strip).playing)
        } else if mirrorSetting, stripPresent {
            var mirror = "Mirroring the strip, phase-locked"
            if let offset = phaseOffsetMs, abs(offset) >= 1 {
                mirror += " (nudged \(offset > 0 ? "+" : "−")\(Int(abs(offset).rounded())) ms)"
            }
            parts.append(mirror)
        } else if mirrorSetting {
            parts.append("Its own display — no strip to mirror")
        } else {
            parts.append("Its own display")
        }
        if live, let why, !why.isEmpty {
            parts.append(why.replacingOccurrences(of: "_", with: " "))
        }
        if live, let cue, !cue.isEmpty { parts.append("playing \(cue)") }
        if let rejection {
            parts.append("refused a program (\(rejection)), holding the last safe one")
        }
        if let motionNote { parts.append(motionNote) }
        if followingAlcove { parts.append("following Alcove") }
        if steppedAsideForVideo { parts.append("stepped aside for a full-screen video") }
        return parts.joined(separator: " · ")
    }
}
