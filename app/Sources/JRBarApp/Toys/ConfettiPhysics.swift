import CoreGraphics
import Foundation

/// The burst's motion in closed form: spray, then flutter. A piece
/// leaves the cannon fast and loses that speed to linear drag (the
/// spray), while its fall ramps up from nothing to a slow terminal
/// flutter (the settle) — the two halves canvas-confetti and iMessage
/// get their wide, fast pop and their slow float from. Both solve to
/// plain exponentials, so a frame is pure evaluation: nothing is
/// integrated or stored per piece, a frozen time renders the same frame
/// every run, and a piece's landing time is known the moment it fires.
enum ConfettiPhysics {
    /// Distance travelled along one axis `t` seconds after launching at
    /// `v0` under linear drag with time constant `tau`: v0·τ·(1 − e^(−t/τ)).
    /// It never passes v0·τ, so how far the spray reaches grows with the
    /// launch speed in a straight line — double the speed, double the
    /// spread.
    static func spray(v0: Double, tau: Double, t: Double) -> Double {
        guard t > 0 else { return 0 }
        return v0 * tau * (1 - exp(-t / tau))
    }

    /// The spray's speed `t` seconds in: v0·e^(−t/τ).
    static func sprayVelocity(v0: Double, tau: Double, t: Double) -> Double {
        v0 * exp(-max(0, t) / tau)
    }

    /// Distance fallen `t` seconds in when the fall speed ramps from 0 to
    /// the flutter speed `vt` with time constant `tf`:
    /// vt·(t − tf·(1 − e^(−t/tf))). Its slope settles at exactly vt.
    static func settle(vt: Double, tf: Double, t: Double) -> Double {
        guard t > 0 else { return 0 }
        return vt * (t - tf * (1 - exp(-t / tf)))
    }

    /// The settle's speed `t` seconds in: vt·(1 − e^(−t/tf)).
    static func settleVelocity(vt: Double, tf: Double, t: Double) -> Double {
        vt * (1 - exp(-max(0, t) / tf))
    }

    /// Downward travel `t` seconds in: the spray's vertical part plus the
    /// settle (y grows down, so a piece fired up starts negative).
    static func drop(vy: Double, tau: Double, vt: Double, tf: Double, t: Double) -> Double {
        spray(v0: vy, tau: tau, t: t) + settle(vt: vt, tf: tf, t: t)
    }

    /// When a piece fired up stops rising: the spray's upward speed and
    /// the settle's downward one cancel. 0 for a piece fired level or
    /// down — it never rises.
    static func apexTime(vy: Double, tau: Double, vt: Double, tf: Double) -> Double {
        guard vy < 0 else { return 0 }
        var low = 0.0, high = 0.05
        while vy * exp(-high / tau) + settleVelocity(vt: vt, tf: tf, t: high) < 0, high < 60 { high *= 2 }
        for _ in 0..<60 {
            let mid = (low + high) / 2
            if vy * exp(-mid / tau) + settleVelocity(vt: vt, tf: tf, t: mid) < 0 { low = mid } else { high = mid }
        }
        return high
    }

    /// When a piece has dropped `d` points on its way down — `drop`
    /// inverted past the apex, where it only grows. A target above the
    /// apex (a piece fired up that never gets that high) answers the
    /// apex itself. Bisection on a monotone curve: exact to well under a
    /// point, and only ever run at fire time.
    static func settleTime(vy: Double, tau: Double, vt: Double, tf: Double, d: Double) -> Double {
        let start = apexTime(vy: vy, tau: tau, vt: vt, tf: tf)
        guard drop(vy: vy, tau: tau, vt: vt, tf: tf, t: start) < d else { return start }
        // drop ≥ min(0, vy·τ) + vt·(t − tf), so this bound is past the root.
        var low = start
        var high = max(start, (d - min(0, vy * tau)) / max(1, vt) + tf) + 0.01
        while drop(vy: vy, tau: tau, vt: vt, tf: tf, t: high) < d { high *= 1.5 }
        for _ in 0..<64 {
            let mid = (low + high) / 2
            if drop(vy: vy, tau: tau, vt: vt, tf: tf, t: mid) < d { low = mid } else { high = mid }
        }
        return high
    }

    /// The flutter speed that has a piece drop `d` points by `t` seconds:
    /// the settle is linear in vt, so it solves in one line. How a slow
    /// piece on a long fall is nudged to finish inside the burst's life.
    static func flutterNeeded(vy: Double, tau: Double, tf: Double, d: Double, by t: Double) -> Double {
        let unit = settle(vt: 1, tf: tf, t: t)
        guard unit > 0 else { return .infinity }
        return max(0, (d - spray(v0: vy, tau: tau, t: t)) / unit)
    }

    /// The slow ramp the sway and bob ride in on: nothing while the spray
    /// carries a piece, all of it once it flutters.
    static func swayRamp(_ t: Double) -> Double {
        t > 0 ? 1 - exp(-t / 0.35) : 0
    }

    // MARK: The tumble

    /// A 3×3 rotation, row by row — a struct, so a frame allocates
    /// nothing per piece.
    struct Rotation: Equatable {
        var r00, r01, r02: Double
        var r10, r11, r12: Double
        var r20, r21, r22: Double
    }

    /// A rotation about the unit axis (x, y, z) by `angle` (Rodrigues).
    static func rotation(axis: (x: Double, y: Double, z: Double), angle: Double) -> Rotation {
        let c = cos(angle), s = sin(angle), k = 1 - c
        let (x, y, z) = axis
        return Rotation(r00: c + x * x * k, r01: x * y * k - z * s, r02: x * z * k + y * s,
                        r10: y * x * k + z * s, r11: c + y * y * k, r12: y * z * k - x * s,
                        r20: z * x * k - y * s, r21: z * y * k + x * s, r22: c + z * z * k)
    }

    /// The rotated paper seen straight on: its top-left 2×2, which is the
    /// exact orthographic projection of the plane — so a flat piece drawn
    /// through this affine tumbles in 3D. Its determinant is R22, the
    /// normal's pull toward the viewer: the paper's apparent area.
    static func projection(_ r: Rotation) -> CGAffineTransform {
        CGAffineTransform(a: r.r00, b: r.r10, c: r.r01, d: r.r11, tx: 0, ty: 0)
    }

    /// Where the light comes from: up, left and in front (y grows down).
    static let light: (x: Double, y: Double, z: Double) = {
        let v = (-0.35, -0.55, 0.76)
        let n = (v.0 * v.0 + v.1 * v.1 + v.2 * v.2).squareRoot()
        return (v.0 / n, v.1 / n, v.2 / n)
    }()

    /// Halfway between the light and the eye: where a glint comes from.
    static let halfway: (x: Double, y: Double, z: Double) = {
        let v = (light.x, light.y, light.z + 1)
        let n = (v.0 * v.0 + v.1 * v.1 + v.2 * v.2).squareRoot()
        return (v.0 / n, v.1 / n, v.2 / n)
    }()

    /// How the paper catches the light: which side faces you (the sign of
    /// the normal's z), a Lambert shade in 0.7…1 — a piece edge-on to the
    /// light is dimmer, never black or muddy — and a specular glint in
    /// 0…1 when it tips toward the light just so.
    static func lighting(_ r: Rotation) -> (front: Bool, shade: Double, glint: Double) {
        let front = r.r22 >= 0
        let sign = front ? 1.0 : -1.0
        // The paper's normal is the rotated z axis: the third column.
        let n = (r.r02 * sign, r.r12 * sign, r.r22 * sign)
        let diffuse = abs(n.0 * light.x + n.1 * light.y + n.2 * light.z)
        let facing = max(0, n.0 * halfway.x + n.1 * halfway.y + n.2 * halfway.z)
        return (front, 0.7 + 0.3 * diffuse, pow(facing, 24))
    }

    // MARK: Landing

    /// One squash-bounce on a ledge, `t` seconds after touching down:
    /// a single parabolic hop `height` pt tall over `duration` s, then
    /// rest. `squashY` dips hard at impact and softer at the second
    /// touchdown, `squashX` widens to match — paper hitting a surface.
    static func floorBounce(t: Double, height: Double, duration: Double)
        -> (lift: Double, squashX: Double, squashY: Double) {
        guard t >= 0 else { return (0, 1, 1) }
        var dip = 0.45 * exp(-t / 0.05)
        var lift = 0.0
        var stretch = 0.0
        if t < duration {
            let u = t / duration
            lift = height * 4 * u * (1 - u)
            stretch = 0.07 * sin(.pi * u)
        } else {
            dip = max(dip, 0.28 * exp(-(t - duration) / 0.06))
        }
        return (lift, 1 + 0.5 * dip - 0.4 * stretch, 1 - dip + stretch)
    }

    /// Smoothstep, clamped.
    static func smooth(_ t: Double) -> Double {
        let t = min(max(t, 0), 1)
        return t * t * (3 - 2 * t)
    }
}
