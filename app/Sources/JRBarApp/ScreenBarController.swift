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
/// the program has gone still, the bar is hidden, or the display is asleep.
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
        didSet { panel.showsInFullScreen = showsInFullScreen }
    }
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
                dismissedWings = dismissedWings.filter { side, slot in
                    wings[side].map { Self.sameWingSubject($0, slot) } ?? false
                }
                dismissedWingRects = dismissedWingRects.filter { dismissedWings[$0.key] != nil }
                pushWings()
            }
        }
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
    }
    /// The device notice holding a side, and when it lets go.
    private var wingNotice: (side: ScreenBarWingSide, slot: ScreenBarWingSlot, until: Date)?
    private var wingNoticeWork: DispatchWorkItem?
    /// Same-subject notices already shown (audio route names); the
    /// cooldown lives in `ScreenBarNotices.audio`.
    private var recentAudioNotices: [String: Date] = [:]
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
    private var displayAsleep = false
    /// The island frame the last scan saw — the watcher's dedup, so a
    /// poll that finds nothing new runs no layout.
    private var lastIslandScan: NSRect?
    /// The island watch: a slow poll under the window notifications —
    /// ordering the island out posts nothing we can hang a rescan on
    /// reliably, so while the band is up a 4 Hz look at `NSApp.windows`
    /// is the safety net that drops the coupling when the island parks.
    private var islandWatch: Timer?
    /// A settle pass after an island notification: the frame write posts
    /// before the order-in lands, so the coupling re-reads once the run
    /// loop turns.
    private var islandRescanWork: DispatchWorkItem?
    /// The daemon's last epoch anchor — kept so wake can re-lock: the
    /// strip's firmware clock runs through sleep while `CACurrentMediaTime`
    /// pauses, so the media-time anchor computed before the sleep no longer
    /// maps to the strip's phase afterwards.
    private var lastAnchorEpoch: Double?
    /// Reduce Motion: the band holds the program's brightest frame instead
    /// of playing it. Live-read and re-presented on the workspace's change.
    private var reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
    private(set) var isShown = false
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
        }
    }

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
                     NSWindow.didExposeNotification, NSWindow.didChangeOcclusionStateNotification] {
            center.addObserver(self, selector: #selector(islandWindowChanged(_:)), name: name, object: nil)
        }
        let workspace = NSWorkspace.shared.notificationCenter
        workspace.addObserver(self, selector: #selector(screensDidSleep(_:)), name: NSWorkspace.screensDidSleepNotification, object: nil)
        workspace.addObserver(self, selector: #selector(screensDidWake(_:)), name: NSWorkspace.screensDidWakeNotification, object: nil)
        workspace.addObserver(self, selector: #selector(reduceMotionChanged(_:)), name: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification, object: nil)

        // A device transition takes the ambient wing for a beat, then the
        // slot it replaced comes back — the queue's life constant is the
        // same beat the island's capsules hold.
        powerMonitor.onTransition = { [weak self] old, new in
            guard let self, let slot = ScreenBarNotices.power(from: old, to: new) else { return }
            self.presentWingNotice(.right, slot: slot)
        }
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
        guard isShown, panel.isVisible else { return nil }
        return panel.convertToScreen(view.convert(view.bandRect, to: nil))
    }

    /// The hover and click zones in screen coordinates: the band plus each
    /// drawn wing chip. The panel is click-through, so these are only ever
    /// read by `ScreenBarInteraction`'s monitors — and they are exactly the
    /// drawn capsules, so a click on one is a click on something of ours.
    var hoverScreenRects: [NSRect] {
        guard isShown, panel.isVisible else { return [] }
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
        return nil
    }

    /// "keyframes (12 + 61 frames)" or "frame clock", for the log.
    var motionDescription: String {
        guard sampler != nil else { return "nothing" }
        if plan?.isStatic == true { return "static" }
        if reduceMotion { return "still (Reduce Motion)" }
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
        isShown = true
        reposition()
        if reduceMotion {
            panel.alphaValue = 1
            panel.orderFrontRegardless()
        } else {
            panel.alphaValue = 0
            panel.orderFrontRegardless()
            NSAnimationContext.runAnimationGroup { context in
                context.duration = Self.fadeSeconds
                panel.animator().alphaValue = 1
            }
        }
        updateNoticeMonitors()
        syncIslandWatch()
        present()
    }

    func hide() {
        isShown = false
        ScreenBarGeometry.menuHandleScreenRect = nil
        updateNoticeMonitors()
        syncIslandWatch()
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

    @objc private func screensChanged(_ note: Notification) { reposition() }

    /// The island moved, resized, or crossed the visible threshold —
    /// re-read its frame and reseat the band. Filtered to the island's
    /// own window: the band's panel fires the same notifications and
    /// must never answer them.
    @objc private func islandWindowChanged(_ note: Notification) {
        guard note.object is NotchIslandWindow else { return }
        islandFrameChanged()
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

    /// The hidden-run handle's state while the menu-bar concealer runs —
    /// nil hides it. Read live by the island watch so the utility's
    /// reveal/hide flips relayout on the poll's cadence.
    var menuHandleProvider: (@MainActor () -> Bool?)?

    /// The handle's slice of the right ear as a screen-space hit test —
    /// a click inside it toggles the hidden run, it is not the wing's.
    func menuHandle(atScreenPoint point: NSPoint) -> Bool {
        guard isShown, panel.isVisible, let rect = view.menuHandleRect else {
            MenuBarCombinedItem.log.notice("menuHandle: dead — shown=\(self.isShown) visible=\(self.panel.isVisible) rect=\(self.view.menuHandleRect == nil ? "nil" : "set")")
            return false
        }
        let hit = panel.convertToScreen(view.convert(rect, to: nil))
            .insetBy(dx: -2, dy: -3).contains(point)
        MenuBarCombinedItem.log.notice("menuHandle: point=\(point.x, privacy: .public),\(point.y, privacy: .public) rect=\(rect.debugDescription, privacy: .public) hit=\(hit)")
        return hit
    }

    /// The flank item edges the ears were last laid out against.
    private var lastEarAvoidLeft: CGFloat?
    private var lastEarAvoidRight: CGFloat?

    /// The safety poll lives exactly as long as the band is shown: a
    /// hidden band has no silhouette to keep in step.
    private func syncIslandWatch() {
        if isShown, islandWatch == nil {
            let timer = Timer(timeInterval: 0.25, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated { self?.islandFrameChanged() }
            }
            RunLoop.main.add(timer, forMode: .common)
            islandWatch = timer
        } else if !isShown {
            islandWatch?.invalidate()
            islandWatch = nil
        }
    }
    @objc private func screensDidSleep(_ note: Notification) { displayAsleep = true; updateClock() }
    @objc private func screensDidWake(_ note: Notification) {
        displayAsleep = false
        if let epoch = lastAnchorEpoch {
            let now = CACurrentMediaTime()
            let locked = Self.mediaTime(forEpoch: epoch)
            // A sane epoch re-locks the phase; one that fails the check
            // (clock skew, a daemon restarted while we slept) would pin
            // the program to a garbage offset -- restart from wake instead.
            anchor = locked <= now + 0.05 && now - locked < 6 * 3600 ? locked : now
        }
        present()
    }

    /// Reduce Motion toggled in System Settings: freeze the moving program
    /// or hand a still one back to Core Animation.
    @objc private func reduceMotionChanged(_ note: Notification) {
        reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        present()
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
        var shown = wings
        for (side, dismissed) in dismissedWings {
            if let slot = shown[side], Self.sameWingSubject(slot, dismissed) {
                shown[side] = nil
            }
        }
        if let notice = wingNotice, notice.until > Date() {
            shown[notice.side] = notice.slot
        }
        return shown
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
        guard isShown, panel.isVisible else { return nil }
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
        guard let slot = wings[side] else { return }
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
        // the strip runs edge to edge under the island and the black
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
        // A claimed wing gets the ears' lobes below the bezel — the
        // window grows by exactly that much so the lobes have room.
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
        // Each ear stops short of the nearest status item on its flank —
        // the « a hidden run keeps beside the notch, our own chevron,
        // whatever macOS parks there. A drawn wing paving a real item
        // hides it and swallows its clicks (screen x → view x). The gap
        // is a real 8 pt: transient indicators macOS drops in the flank
        // — the mic pill, a voice-recording mark — are never in the
        // listing, and a 2 pt seam reads as overlap when one lands.
        view.rightEarLimit = lastEarAvoidRight.flatMap { limit in
            limit > frame.midX ? limit - frame.minX - 8 : nil
        }
        view.leftEarLimit = lastEarAvoidLeft.flatMap { limit in
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
        lastRejection = decision.rejection
        guard let program = decision.program, let compiledText = decision.programText else {
            // Refused: `lastRawText`/`lastAnchorEpoch` keep describing the
            // program still on the bar -- a refused text must not move the
            // running program's anchor (it used to, through `lastRawText`).
            NSLog("JR-Bar: refusing LEDS program (%@); keeping the previous one", decision.rejection ?? "?")
            return
        }
        lastRawText = text
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
        if reduceMotion {
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
        let shouldRun = isShown && !displayAsleep && stillMoving
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
