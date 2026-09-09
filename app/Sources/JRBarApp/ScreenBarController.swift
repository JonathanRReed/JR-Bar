import AppKit
import JRBarLEDS
import QuartzCore

/// Owns the Screen Bar panel, the program currently on it, and the frame clock.
///
/// The sampler is evaluated only on display-link ticks (capped at 60 Hz, the
/// Python pipeline's `MAX_SAMPLE_RATE_HZ`), and the link pauses whenever the
/// program has gone still, the bar is hidden, or the display is asleep, so a
/// static program costs nothing.
@MainActor
final class ScreenBarController {
    static let wrapMenuBar = true

    private let panel: ScreenBarPanel
    private let view: ScreenBarView
    private var displayLink: CADisplayLink?
    private var sampler: LEDSSampler?
    private var anchor: CFTimeInterval = 0
    private var lastCodes: [RGB8] = []
    private var lastRaw: [RGB8] = Array(repeating: .black, count: ScreenBarGeometry.ledCount)
    private var displayAsleep = false
    private(set) var isShown = false
    private(set) var programText: String = ""
    private var lastRawText = ""
    private(set) var lastRejection: String?

    init() {
        let screen = ScreenBarGeometry.preferredScreen()
        let frame = screen.map { ScreenBarGeometry.windowFrame(for: $0, wrapMenuBar: Self.wrapMenuBar) }
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

    // MARK: Visibility

    func show() {
        isShown = true
        reposition()
        panel.orderFrontRegardless()
        updateClock()
    }

    func hide() {
        isShown = false
        panel.orderOut(nil)
        updateClock()
    }

    @objc private func screensChanged(_ note: Notification) { reposition() }
    @objc private func screensDidSleep(_ note: Notification) { displayAsleep = true; updateClock() }
    @objc private func screensDidWake(_ note: Notification) { displayAsleep = false; updateClock() }

    private func reposition() {
        guard let screen = ScreenBarGeometry.preferredScreen() else { return }
        let frame = ScreenBarGeometry.windowFrame(for: screen, wrapMenuBar: Self.wrapMenuBar)
        if panel.frame != frame {
            panel.setFrame(frame, display: false)
            view.frame = NSRect(origin: .zero, size: frame.size)
            view.relayout()
            lastCodes = []
            renderCurrentFrame()
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
        sampler = LEDSSampler(program: program, ledCount: ScreenBarGeometry.ledCount, initialCodes: lastRaw)
        anchor = now
        if let anchorEpoch {
            let locked = Self.mediaTime(forEpoch: anchorEpoch)
            // Trust anchors from the recent past; a future or absurd anchor
            // (clock skew, a daemon restart) falls back to "now".
            if locked <= now + 0.05, now - locked < 6 * 3600 { anchor = locked }
        }
        lastCodes = []
        renderCurrentFrame()
        updateClock()
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

    // MARK: Frame clock

    private func updateClock() {
        guard let sampler else { displayLink?.isPaused = true; return }
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
