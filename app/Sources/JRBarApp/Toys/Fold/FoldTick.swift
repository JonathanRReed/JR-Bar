import AppKit
import QuartzCore

/// Something that ticks once per display refresh until it is invalidated.
/// The real one is a `CADisplayLink`; the tests pass a counter, so the
/// rule "no link runs while the lid is at rest" is checked without a
/// screen.
protocol FoldTickLink: AnyObject {
    func invalidate()
}

/// When the fold needs its clock. Pure, so "no link while the lid is at
/// rest" is a rule with a test, not a habit.
enum FoldTickPolicy {
    /// The link runs only while it can move or draw pixels: the fold is
    /// armed (on, ours to render, permissioned, unpaused) and something
    /// is in motion or on screen — a delta still to show, a motion or
    /// ease still settling, a fade still running, or the closed-lid hold.
    static func wantsTick(armed: Bool, targetDelta: Double, displayedDelta: Double,
                          motionAtRest: Bool, easeAtRest: Bool,
                          blackout: Bool, entryFading: Bool) -> Bool {
        guard armed else { return false }
        return targetDelta > 0 || displayedDelta > 0.002
            || !motionAtRest || !easeAtRest || blackout || entryFading
    }
}

/// Owns the fold's one clock. The toy asks it, after every change, whether
/// a tick is wanted; it creates the link when one is, tears it down when
/// none is, and does nothing at all otherwise. Nothing else in the fold
/// ticks: not the Metal view (it is paused and drawn by hand), not a timer.
@MainActor
final class FoldTickDriver {
    enum Change: Equatable { case started, stopped, unchanged }

    /// Builds a link that calls its closure with the time the frame it
    /// precedes will be shown, in `CACurrentMediaTime`'s base. Nil when
    /// there is no screen to tick on.
    typealias Factory = @MainActor (_ onTick: @escaping @MainActor (TimeInterval) -> Void) -> FoldTickLink?

    private let makeLink: Factory
    private var link: FoldTickLink?
    /// Receives each tick's frame time.
    var onTick: @MainActor (TimeInterval) -> Void = { _ in }

    init(makeLink: @escaping Factory) {
        self.makeLink = makeLink
    }

    isolated deinit {
        link?.invalidate()
    }

    var isRunning: Bool { link != nil }

    /// Matches the link to `wanted`.
    func update(wanted: Bool) -> Change {
        guard wanted else { return stop() ? .stopped : .unchanged }
        guard link == nil else { return .unchanged }
        link = makeLink { [weak self] time in self?.onTick(time) }
        return link == nil ? .unchanged : .started
    }

    /// Tears the link down; true when there was one.
    @discardableResult
    func stop() -> Bool {
        guard let link else { return false }
        link.invalidate()
        self.link = nil
        return true
    }

    /// The real link: on macOS it comes from the screen it drives, here the
    /// built-in one the overlay covers.
    static let displayLink: Factory = { onTick in
        guard let screen = FoldOverlayWindow.builtinScreen() ?? NSScreen.main else { return nil }
        return DisplayLinkTick(screen: screen, onTick: onTick)
    }
}

/// `CADisplayLink` needs an `NSObject` target with an `@objc` selector, so
/// the tick rides inside this box. It reports the time the frame will be
/// shown (`targetTimestamp`), so the motion is evaluated for the frame on
/// screen, not the one before it.
private final class DisplayLinkTick: NSObject, FoldTickLink {
    private var link: CADisplayLink?
    private let onTick: @MainActor (TimeInterval) -> Void

    init(screen: NSScreen, onTick: @escaping @MainActor (TimeInterval) -> Void) {
        self.onTick = onTick
        super.init()
        let link = screen.displayLink(target: self, selector: #selector(tick(_:)))
        link.add(to: .main, forMode: .common)
        self.link = link
    }

    @objc private func tick(_ link: CADisplayLink) {
        let time = link.targetTimestamp
        let deliver = onTick
        MainActor.assumeIsolated { deliver(time) }
    }

    func invalidate() {
        link?.invalidate()
        link = nil
    }
}
