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
    /// The slots' base content, pushed from the panel store on each core
    /// change. A nil slot collapses: the window claims no room for it.
    var wings: ScreenBarWings = .empty {
        didSet {
            if wings != oldValue {
                // A dismissed wing's slot changing is new information —
                // the dismissal was of what it showed, and it revives.
                dismissedWings = dismissedWings.filter { wings[$0.key] == $0.value }
                pushWings()
            }
        }
    }
    /// Sides the user flicked away, keyed by the slot that was dismissed.
    /// Session-scoped — a relaunch brings the wings back.
    private var dismissedWings: [ScreenBarWingSide: ScreenBarWingSlot] = [:]
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
    private var lastRawText = ""
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
        return [view.bandRect, view.leftWingRect, view.rightWingRect]
            .compactMap { $0 }
            .map { panel.convertToScreen(view.convert($0, to: nil)) }
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
        present()
    }

    func hide() {
        isShown = false
        updateNoticeMonitors()
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
    @objc private func screensDidSleep(_ note: Notification) { displayAsleep = true; updateClock() }
    @objc private func screensDidWake(_ note: Notification) {
        displayAsleep = false
        if let epoch = lastAnchorEpoch {
            let now = CACurrentMediaTime()
            let locked = Self.mediaTime(forEpoch: epoch)
            if locked <= now + 0.05, now - locked < 6 * 3600 { anchor = locked }
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
                shown.right == nil ? 0
                    : ScreenBarGeometry.contentWingExtent(of: screen, side: .right, notchWidth: notchWidth))
    }

    /// The base slots minus what the user flicked away, plus a live
    /// device notice — the wings the view and the geometry share.
    private var effectiveWings: ScreenBarWings {
        var shown = wings
        for (side, dismissed) in dismissedWings where shown[side] == dismissed {
            shown[side] = nil
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

    /// The outward flick: the slot stays down until its content changes
    /// or a summon brings it back.
    func dismissWing(_ side: ScreenBarWingSide) {
        guard let slot = wings[side] else { return }
        dismissedWings[side] = slot
        pushWings()
    }

    /// The summon: every dismissed wing comes back.
    func restoreWings() {
        guard !dismissedWings.isEmpty else { return }
        dismissedWings = [:]
        pushWings()
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

    private func reposition() {
        guard let screen = ScreenBarGeometry.preferredScreen() else { return }
        let oldRects = (view.bandRect, view.leftWingRect, view.rightWingRect)
        let depth = ScreenBarGeometry.notchDepth(of: screen)
        let notchWidth = ScreenBarGeometry.resolvedNotchWidth(slotWidth: ScreenBarGeometry.slotWidth(of: screen),
                                                            gapWidth: gapWidth)
        let extents = wingExtents(on: screen, notchWidth: notchWidth, notchDepth: depth)
        let frame = ScreenBarGeometry.windowFrame(for: screen, wrapMenuBar: wrapMenuBar,
                                                  gapWidth: gapWidth, wingLength: wingLength, capsule: capsule,
                                                  contentExtent: max(extents.left, extents.right))
        view.bandSpan = ScreenBarGeometry.windowFrame(for: screen, wrapMenuBar: wrapMenuBar,
                                                      gapWidth: gapWidth, wingLength: wingLength,
                                                      capsule: capsule).width
        view.wingGeometry = ScreenBarWingGeometry(notchWidth: notchWidth, notchDepth: depth,
                                                  bandSpan: view.bandSpan,
                                                  leftExtent: extents.left, rightExtent: extents.right)
        syncWings()
        if panel.frame != frame {
            panel.setFrame(frame, display: false)
            view.frame = NSRect(origin: .zero, size: frame.size)
            lastCodes = []
            present()
        }
        view.relayout()
        // Wing chips come and go without a frame change; the hit region
        // follows the drawn capsules, not the window.
        if (view.bandRect, view.leftWingRect, view.rightWingRect) != oldRects {
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
        lastRawText = text
        let decision = Self.programDecision(text, fallback: programText.isEmpty ? LEDSPresentationCompiler.safeFallbackProgram : programText)
        lastRejection = decision.rejection
        guard let program = decision.program, let compiledText = decision.programText else {
            NSLog("JR-Bar: refusing LEDS program (%@); keeping the previous one", decision.rejection ?? "?")
            return
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
