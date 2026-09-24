import Foundation

/// Burst ballistics in closed form: gravity plus quadratic air drag,
/// `dv/dt = −g − (g/vt²)·v|v|` with `vt` the piece's terminal speed.
/// Each axis solves to a plain log/tan expression, so a frame is pure
/// evaluation — nothing is integrated or stored per piece.
enum ConfettiPhysics {
    /// Downward acceleration, pt/s².
    static let gravity: Double = 1100

    /// Seconds from launch to the top of the arc (v hits 0).
    static func apexTime(v0: Double, vt: Double) -> Double {
        (vt / gravity) * atan(v0 / vt)
    }

    /// Height above the launch point `t` seconds in, while still rising:
    /// v = vt·tan(C − g·t/vt) with C = atan(v0/vt), integrated once.
    static func rise(v0: Double, vt: Double, t: Double) -> Double {
        let c = atan(v0 / vt)
        let u = max(0, c - gravity * t / vt)
        return (vt * vt / gravity) * (log(cos(u)) - log(cos(c)))
    }

    /// Total rise at the apex: `(vt²/2g)·ln(1 + (v0/vt)²)`.
    static func apexHeight(v0: Double, vt: Double) -> Double {
        let r = v0 / vt
        return (vt * vt / (2 * gravity)) * log(1 + r * r)
    }

    /// Distance fallen `t` seconds after the apex: v = −vt·tanh(g·t/vt),
    /// which is exactly vt in the limit — the slow flutter.
    static func fall(vt: Double, t: Double) -> Double {
        (vt * vt / gravity) * log(cosh(gravity * t / vt))
    }

    /// Signed horizontal travel `t` seconds in. Drag bleeds the spray
    /// off fast: v = v0 / (1 + (g/vt²)·|v0|·t), integrated once.
    static func travel(v0: Double, vt: Double, t: Double) -> Double {
        let beta = gravity / (vt * vt)
        return (v0 < 0 ? -1 : 1) * (1 / beta) * log(1 + beta * abs(v0) * t)
    }

    /// Seconds after the apex at which a piece has fallen `d` points —
    /// `fall` inverted (`acosh` on e^(d·g/vt²)). Times the streamer
    /// floor bounce; nothing integrates.
    static func fallTime(vt: Double, d: Double) -> Double {
        guard d > 0 else { return 0 }
        let e = d * gravity / (vt * vt)
        // Past e ≈ 300, acosh(e^e) is e + ln 2 to every bit Double keeps.
        if e > 300 { return d / vt + vt * log(2) / gravity }
        let x = exp(e)
        return (vt / gravity) * log(x + sqrt(x * x - 1))
    }

    /// One squash-bounce on the floor, `t` seconds after touching down:
    /// a single parabolic hop `height` pt tall over `duration` s, then
    /// rest. `squashY` dips hard at impact and softer at the second
    /// touchdown, `squashX` widens to match — a ribbon hitting ground.
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
}
