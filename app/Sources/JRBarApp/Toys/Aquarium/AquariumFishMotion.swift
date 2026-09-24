import SwiftUI

extension CartoonFish {
    /// One frame's swim pose for a kit: the tail's swing, the body's
    /// flex behind the gills and the fins' ripple, applied to the rest
    /// paths point by point. A still fish hands the cached paths back
    /// untouched.
    struct Pose {
        let moving: Bool
        private let pivotX: Double
        private let rootX: Double
        private let flex: Double
        private let tailAngle: Double
        private let fore: Double
        private let ripple: Double
        private let finAmp: Double

        init(art: Art, swim: Swim) {
            let amp = max(0, swim.amplitude)
            moving = amp > 0.0001
            pivotX = art.flexPivot
            rootX = art.tailRootX
            // The body wave runs head to tail: the flex leads, the tail
            // tip follows a beat behind it.
            flex = amp * 0.13 * sin(swim.phase + 0.9)
            let span = max(0.05, art.flexPivot - art.tailRootX)
            let slope = atan(2 * flex / span)
            tailAngle = amp * 1.35 * sin(swim.phase) + slope
            // At the ends of the stroke the tail turns edge-on to the
            // glass and reads shorter.
            fore = 1 - 0.24 * abs(sin(swim.phase)) * min(1, amp / 0.22)
            ripple = swim.phase * 0.55
            // Fins keep a gentle flutter even while the fish hovers.
            finAmp = moving ? max(amp, 0.12) : 0
        }

        /// How far the body bends down at `x` (unit space, y down).
        private func bend(_ x: Double) -> Double {
            guard x < pivotX else { return 0 }
            let s = min(1.4, (pivotX - x) / max(0.05, pivotX - rootX))
            return flex * s * s
        }

        /// Swing `p` about `c` by `a` radians. Swim angles stay under
        /// ~0.6 rad, where the short series is as good as the real
        /// thing to a hundredth of a point and far cheaper per point.
        private func rotate(_ p: CGPoint, about c: CGPoint, by a: Double, stretch: Double = 1) -> CGPoint {
            let dx = p.x - c.x, dy = p.y - c.y
            let a2 = a * a
            let ca = 1 - a2 * (0.5 - a2 / 24), sa = a * (1 - a2 / 6)
            return CGPoint(x: c.x + (dx * ca - dy * sa) * stretch, y: c.y + dx * sa + dy * ca)
        }

        func bodyPoint(_ p: CGPoint) -> CGPoint {
            CGPoint(x: p.x, y: p.y + bend(p.x))
        }

        func finPoint(_ p: CGPoint, _ fin: Fin) -> CGPoint {
            guard moving else { return p }
            let d = hypot(p.x - fin.pivot.x, p.y - fin.pivot.y) / fin.reach
            switch fin.motion {
            case .tail:
                let angle = -tailAngle * (0.75 + 0.45 * d)
                let swung = rotate(p, about: fin.pivot, by: angle, stretch: fore)
                return CGPoint(x: swung.x, y: swung.y + bend(fin.pivot.x))
            case .ripple(let k):
                let angle = finAmp * k * sin(ripple - d * 2.4) * d
                return bodyPoint(rotate(p, about: fin.pivot, by: angle))
            case .paddle(let k):
                let angle = finAmp * k * sin(ripple * 1.6 + 1.3) * (0.55 + 0.45 * d)
                return bodyPoint(rotate(p, about: fin.pivot, by: angle))
            case .fixed:
                return bodyPoint(p)
            }
        }

        func body(_ path: Path) -> Path {
            moving ? Self.map(path) { bodyPoint($0) } : path
        }

        func fin(_ path: Path, _ fin: Fin) -> Path {
            moving ? Self.map(path) { finPoint($0, fin) } : path
        }

        /// `path` with every point sent through `f`, built straight
        /// into a CoreGraphics path — the cheap way, every frame.
        static func map(_ path: Path, _ f: (CGPoint) -> CGPoint) -> Path {
            let out = CGMutablePath()
            path.cgPath.applyWithBlock { element in
                let e = element.pointee
                switch e.type {
                case .moveToPoint:
                    out.move(to: f(e.points[0]))
                case .addLineToPoint:
                    out.addLine(to: f(e.points[0]))
                case .addQuadCurveToPoint:
                    out.addQuadCurve(to: f(e.points[1]), control: f(e.points[0]))
                case .addCurveToPoint:
                    out.addCurve(to: f(e.points[2]), control1: f(e.points[0]), control2: f(e.points[1]))
                case .closeSubpath:
                    out.closeSubpath()
                @unknown default:
                    break
                }
            }
            return Path(out)
        }
    }
}

/// Each fish's tail-beat clock. The phase advances by the beat
/// frequency every frame — never recomputed from the wall clock — so a
/// fish that speeds up beats faster without its tail ever jumping. The
/// frequency follows how fast the fish is really moving, in body
/// lengths per second, measured off its drawn position frame to frame.
@MainActor
final class FishSwimClock {
    static let shared = FishSwimClock()

    private struct Entry {
        var phase: Double
        var t: Double
        var x: Double
        var y: Double
        /// Smoothed speed, body lengths per second.
        var speed: Double
    }

    private var entries: [String: Entry] = [:]

    /// Advance `id`'s clock to `t` at position (`x`, `y`) for a fish
    /// `length` points long; `vigor` (1 calm … ~1.5) quickens a fish
    /// whose session just spoke. Returns the beat phase and the
    /// smoothed speed.
    func advance(_ id: String, seed: Double, t: Double, x: Double, y: Double,
                 length: Double, vigor: Double) -> (phase: Double, speed: Double) {
        guard var e = entries[id] else {
            entries[id] = Entry(phase: seed, t: t, x: x, y: y, speed: 0.4)
            prune(before: t)
            return (seed, 0.4)
        }
        let dt = t - e.t
        if dt <= 0 || dt > 0.5 {
            // A paused window or a clock that ran backwards: pick up
            // where we are without a lurch.
            e.t = t
            e.x = x
            e.y = y
            entries[id] = e
            return (e.phase, e.speed)
        }
        let moved = hypot(x - e.x, y - e.y) / max(1, length)
        let raw = min(4, moved / dt)
        e.speed += (raw - e.speed) * min(1, dt * 4)
        let hz = (0.85 + 1.35 * min(2.6, e.speed)) * vigor
        e.phase += dt * hz * .pi * 2
        e.t = t
        e.x = x
        e.y = y
        entries[id] = e
        return (e.phase, e.speed)
    }

    /// Forget fish that stopped drawing a while ago.
    private func prune(before t: Double) {
        guard entries.count > 48 else { return }
        entries = entries.filter { t - $0.value.t < 10 }
    }
}
