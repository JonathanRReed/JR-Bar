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
    private static let transitions = NSMapTable<NSWindow, NSNumber>.weakToStrongObjects()

    private static func beginTransition(_ panel: NSWindow) -> UInt64 {
        let generation = (transitions.object(forKey: panel)?.uint64Value ?? 0) &+ 1
        transitions.setObject(NSNumber(value: generation), forKey: panel)
        return generation
    }

    /// `NotchMotion.panelCurve` for Core Animation.
    static var panelCurve: CAMediaTimingFunction {
        let curve = NotchMotion.panelCurve
        return CAMediaTimingFunction(controlPoints: curve.x1, curve.y1, curve.x2, curve.y2)
    }

    static var reduceMotion: Bool { NSWorkspace.shared.accessibilityDisplayShouldReduceMotion }

    private static let layerFadeKey = "jrbar.surface-visibility"

    /// Layer fades do not retain a window. Off cancels the layer's motion
    /// before detaching the view and releasing its panel.
    static func fade(layer: CALayer, to opacity: Float, from start: Float? = nil,
                     duration: TimeInterval, reduced: Bool) {
        let before = start ?? layer.presentation()?.opacity ?? layer.opacity
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        layer.opacity = opacity
        layer.removeAnimation(forKey: layerFadeKey)
        CATransaction.commit()
        guard !reduced, before != opacity else { return }
        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = before
        fade.toValue = opacity
        fade.duration = duration
        fade.timingFunction = CAMediaTimingFunction(name: .default)
        layer.add(fade, forKey: layerFadeKey)
    }

    static func cancelFade(layer: CALayer?) {
        layer?.removeAnimation(forKey: layerFadeKey)
    }

    /// One fade of `panel` to `alpha`, with whatever else moves in the
    /// same group (`alongside` gets the animator, or the panel itself on
    /// an instant swap). Under Reduce Motion `reducedDuration` is the
    /// fade's length, and nil swaps at once. A nil `curve` keeps the
    /// context's own.
    static func fade(_ panel: NSWindow, to alpha: CGFloat, duration: TimeInterval,
                     reducedDuration: TimeInterval?, curve: CAMediaTimingFunction?,
                     alongside: (NSWindow) -> Void = { _ in }) {
        _ = beginTransition(panel)
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
                        presenter: WindowPresenter = .automatic,
                        alongside: (NSWindow) -> Void = { _ in }) {
        let rest = panel.frame.origin
        let travels = settle != 0 && !reduceMotion
        if travels { panel.setFrameOrigin(NSPoint(x: rest.x, y: rest.y + settle)) }
        if let start { panel.alphaValue = start }
        presenter.order(panel)
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
                        animate: ((@escaping () -> Void, @escaping () -> Void) -> Void)? = nil,
                        then: @escaping @MainActor @Sendable () -> Void = {}) {
        let generation = beginTransition(panel)
        let reduced = reduceMotion
        if reduced, reducedDuration == nil {
            panel.orderOut(nil)
            then()
            return
        }
        let animations = {
            panel.animator().alphaValue = 0
        }
        let completion: @Sendable () -> Void = {
            MainActor.assumeIsolated {
                // A later show or hide owns the panel, even when its alpha is
                // still zero or its own fade has not finished yet.
                guard transitions.object(forKey: panel)?.uint64Value == generation else { return }
                guard stillGone?() ?? (panel.alphaValue < 0.01) else { return }
                panel.orderOut(nil)
                then()
            }
        }
        if let animate {
            animate(animations, completion)
        } else {
            NSAnimationContext.runAnimationGroup({ context in
                context.duration = reduced ? reducedDuration ?? 0 : duration
                if let curve { context.timingFunction = curve }
                animations()
            }, completionHandler: completion)
        }
    }
}
