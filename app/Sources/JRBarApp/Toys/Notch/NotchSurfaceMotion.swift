import AppKit
import JRBarCore
import QuartzCore

/// How a panel hung from the notch comes and goes — the glass card, the
/// HUD pill, the Screen Bar and its peek. Each surface keeps its own
/// timings, passed in: they differ on purpose, and nothing here evens
/// them out. What lives here once is the shared curve, the Reduce
/// Motion branch, the settle onto the rest frame and the tail that
/// orders a panel out only once it really faded.
@MainActor
enum NotchSurfaceMotion {
    /// `NotchMotion.panelCurve` for Core Animation.
    static var panelCurve: CAMediaTimingFunction {
        let curve = NotchMotion.panelCurve
        return CAMediaTimingFunction(controlPoints: curve.x1, curve.y1, curve.x2, curve.y2)
    }

    static var reduceMotion: Bool { NSWorkspace.shared.accessibilityDisplayShouldReduceMotion }

    /// One fade of `panel` to `alpha`, with whatever else moves in the
    /// same group (`alongside` gets the animator, or the panel itself on
    /// an instant swap). Under Reduce Motion `reducedDuration` is the
    /// fade's length, and nil swaps at once. A nil `curve` keeps the
    /// context's own.
    static func fade(_ panel: NSWindow, to alpha: CGFloat, duration: TimeInterval,
                     reducedDuration: TimeInterval?, curve: CAMediaTimingFunction?,
                     alongside: (NSWindow) -> Void = { _ in }) {
        let reduced = reduceMotion
        if reduced, reducedDuration == nil {
            panel.alphaValue = alpha
            alongside(panel)
            return
        }
        NSAnimationContext.runAnimationGroup { context in
            context.duration = reduced ? reducedDuration ?? 0 : duration
            if let curve { context.timingFunction = curve }
            panel.animator().alphaValue = alpha
            alongside(panel.animator())
        }
    }

    /// Order `panel` in at the frame the caller placed it on and fade it
    /// to `alpha`. `from` resets the alpha first, for a surface that
    /// always arrives from nothing. `settle` points drop an arriving
    /// panel down onto that frame — raised before the order, so the rest
    /// position never flashes first; Reduce Motion never travels.
    static func present(_ panel: NSWindow, to alpha: CGFloat = 1, from start: CGFloat? = nil,
                        settle: CGFloat = 0, duration: TimeInterval, reducedDuration: TimeInterval?,
                        curve: CAMediaTimingFunction? = panelCurve,
                        alongside: (NSWindow) -> Void = { _ in }) {
        let rest = panel.frame.origin
        let travels = settle != 0 && !reduceMotion
        if travels { panel.setFrameOrigin(NSPoint(x: rest.x, y: rest.y + settle)) }
        if let start { panel.alphaValue = start }
        panel.orderFrontRegardless()
        fade(panel, to: alpha, duration: duration, reducedDuration: reducedDuration, curve: curve) { target in
            if travels { target.setFrameOrigin(rest) }
            alongside(target)
        }
    }

    /// Fade `panel` out and order it out once the fade lands — only if
    /// it is still meant to be gone (`stillGone`; by default, still
    /// faded), so a present that arrived mid-fade keeps its panel. `then`
    /// runs after the order-out. Under Reduce Motion a nil
    /// `reducedDuration` orders it out at once.
    static func dismiss(_ panel: NSWindow, duration: TimeInterval, reducedDuration: TimeInterval?,
                        curve: CAMediaTimingFunction? = CAMediaTimingFunction(name: .easeIn),
                        stillGone: (@MainActor @Sendable () -> Bool)? = nil,
                        then: @escaping @MainActor @Sendable () -> Void = {}) {
        let reduced = reduceMotion
        if reduced, reducedDuration == nil {
            panel.orderOut(nil)
            then()
            return
        }
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = reduced ? reducedDuration ?? 0 : duration
            if let curve { context.timingFunction = curve }
            panel.animator().alphaValue = 0
        }, completionHandler: {
            MainActor.assumeIsolated {
                guard stillGone?() ?? (panel.alphaValue < 0.01) else { return }
                panel.orderOut(nil)
                then()
            }
        })
    }
}
