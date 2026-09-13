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
        didSet { if capsule != oldValue { reposition() } }
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
    }

    /// The band's rounded rect in screen coordinates, for hit testing.
    var bandScreenRect: NSRect? {
        guard isShown, panel.isVisible else { return nil }
        return panel.convertToScreen(view.convert(view.bandRect, to: nil))
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
        present()
    }

    func hide() {
        isShown = false
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

    private func reposition() {
        guard let screen = ScreenBarGeometry.preferredScreen() else { return }
        let frame = ScreenBarGeometry.windowFrame(for: screen, wrapMenuBar: wrapMenuBar,
                                                  gapWidth: gapWidth, wingLength: wingLength, capsule: capsule)
        if panel.frame != frame {
            panel.setFrame(frame, display: false)
            view.frame = NSRect(origin: .zero, size: frame.size)
            view.relayout()
            lastCodes = []
            present()
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
