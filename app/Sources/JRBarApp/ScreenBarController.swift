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
    static let wrapMenuBar = true
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
    private(set) var isShown = false
    private(set) var programText: String = ""
    private var lastRawText = ""
    private(set) var lastRejection: String?

    /// Alcove's capsule when the band follows it; nil hugs the notch.
    var capsule: AlcoveCapsule? {
        didSet { if capsule != oldValue { reposition() } }
    }

    init() {
        let screen = ScreenBarGeometry.preferredScreen()
        let frame = screen.map { ScreenBarGeometry.windowFrame(for: $0, wrapMenuBar: Self.wrapMenuBar, capsule: nil) }
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
    }

    /// The band's rounded rect in screen coordinates, for hit testing.
    var bandScreenRect: NSRect? {
        guard isShown, panel.isVisible else { return nil }
        return panel.convertToScreen(view.convert(view.bandRect, to: nil))
    }

    var onGeometryChange: (@MainActor () -> Void)?

    /// "keyframes (12 + 61 frames)" or "frame clock", for the status menu.
    var motionDescription: String {
        guard sampler != nil else { return "nothing" }
        if let plan {
            if plan.isStatic { return "static" }
            return "keyframes (\(plan.lead?.count ?? 0) + \(plan.loop?.count ?? 0) frames)"
        }
        return "frame clock"
    }

    // MARK: Visibility

    func show() {
        isShown = true
        reposition()
        panel.orderFrontRegardless()
        present()
    }

    func hide() {
        isShown = false
        panel.orderOut(nil)
        updateClock()
    }

    @objc private func screensChanged(_ note: Notification) { reposition() }
    @objc private func screensDidSleep(_ note: Notification) { displayAsleep = true; updateClock() }
    @objc private func screensDidWake(_ note: Notification) { displayAsleep = false; present() }

    private func reposition() {
        guard let screen = ScreenBarGeometry.preferredScreen() else { return }
        let frame = ScreenBarGeometry.windowFrame(for: screen, wrapMenuBar: Self.wrapMenuBar, capsule: capsule)
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
        if text == lastRawText, let anchorEpoch, abs(Self.mediaTime(forEpoch: anchorEpoch) - anchor) < 0.02 {
            return  // Same program, same phase: nothing to restart.
        }
        lastRawText = text
        let compiled = LEDSPresentationCompiler.compile(text, ledCount: ScreenBarGeometry.ledCount, fallback: programText.isEmpty ? LEDSPresentationCompiler.safeFallbackProgram : programText)
        guard compiled.accepted else {
            let reason: String
            do {
                _ = try LEDSProgram.parse(text, ledCount: ScreenBarGeometry.ledCount)
                reason = compiled.reasons.joined(separator: ",")
            } catch {
                reason = error.description
            }
            lastRejection = reason
            NSLog("JR-Bar: refusing LEDS program (%@); keeping the previous one", reason)
            return
        }
        lastRejection = nil
        let program: LEDSProgram
        do {
            program = try LEDSProgram.parse(compiled.program, ledCount: ScreenBarGeometry.ledCount)
        } catch {
            lastRejection = error.description
            return
        }
        // The firmware starts a new program from the colours currently showing.
        let now = CACurrentMediaTime()
        if let sampler {
            lastRaw = sampler.rawCodes(atMilliseconds: milliseconds(now))
        }
        programText = compiled.program
        let sampler = LEDSSampler(program: program, ledCount: ScreenBarGeometry.ledCount, initialCodes: lastRaw)
        self.sampler = sampler
        plan = LEDSKeyframePlan.render(sampler: sampler)
        anchor = now
        if let anchorEpoch {
            let locked = Self.mediaTime(forEpoch: anchorEpoch)
            // Trust anchors from the recent past; a future or absurd anchor
            // (clock skew, a daemon restart) falls back to "now".
            if locked <= now + 0.05, now - locked < 6 * 3600 { anchor = locked }
        }
        lastCodes = []
        present()
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
    /// else the frame clock.
    private func present() {
        guard sampler != nil else { updateClock(); return }
        if Self.logsMotion { NSLog("JR-Bar: screen bar %@, anchor %.1f s ago", motionDescription, programAge) }
        if let plan {
            displayLink?.isPaused = true
            if isShown { view.play(plan: plan, anchor: anchor) }
        } else {
            view.stopKeyframes()
            renderCurrentFrame()
            updateClock()
        }
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
