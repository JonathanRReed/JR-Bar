import AppKit

/// Day & night › Follow Light & Dark: the tank's night is macOS's Dark
/// mode. A flip doesn't snap — the wash eases over two seconds, and the
/// still passes (the water, the back wall, the sand), which otherwise
/// redraw every two seconds, tick at `easingTick` until it lands, so
/// the whole tank dims together the way a room does.
@MainActor
enum AquariumNightEase {
    /// Seconds a Light↔Dark flip takes to reach the water.
    static let seconds = 2.0
    /// The still passes' tick while a flip eases in.
    static let easingTick = 1.0 / 15.0
    /// The still passes' usual tick.
    static let restingTick = 2.0

    /// The ease in flight: where it started, where it's going, when.
    private static var ease: (from: Double, to: Double, at: Double)?

    /// 1 while the Mac is in Dark mode, 0 in Light.
    static var darkNow: Double {
        let appearance = NSApp?.effectiveAppearance ?? NSAppearance.currentDrawing()
        return appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? 1 : 0
    }

    /// The wash at `t` for the current appearance. `still` (Reduce
    /// Motion) lands on the new value at once.
    static func appearanceNight(at t: Double, still: Bool = false) -> Double {
        value(toward: darkNow, at: t, still: still)
    }

    /// The pure ease: heads for `target`, restarting from wherever it
    /// was when the target moves.
    static func value(toward target: Double, at t: Double, still: Bool) -> Double {
        guard let current = ease, !still else {
            ease = (target, target, t)
            return target
        }
        let now = blend(current, at: t)
        if current.to != target {
            ease = (now, target, t)
            return now
        }
        return now
    }

    private static func blend(_ e: (from: Double, to: Double, at: Double), at t: Double) -> Double {
        let p = min(1, max(0, (t - e.at) / seconds))
        let s = p * p * (3 - 2 * p)
        return e.from + (e.to - e.from) * s
    }

    /// Whether a flip is still on its way to the water at `t`.
    static func isEasing(at t: Double) -> Bool {
        guard let e = ease, e.from != e.to else { return false }
        return t >= e.at && t - e.at < seconds
    }

    /// The still passes' tick: quick from a flip (`flipAt`, when the
    /// view saw the appearance change) until the ease has landed, then
    /// the resting two seconds. A little margin covers the ease
    /// starting a frame after the flip.
    static func stillTick(flipAt: Double?, at t: Double) -> Double {
        guard let flipAt, t - flipAt < seconds + 0.5 || isEasing(at: t) else { return restingTick }
        return easingTick
    }

    /// Forgets the ease — for tests.
    static func reset() { ease = nil }
}
