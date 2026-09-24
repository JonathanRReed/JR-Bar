import Foundation
import JRBarCore
import Testing
@testable import JRBarApp

/// The Duo's sensor smoothing, on a simulated lid: a 10 Hz sensor that
/// reports whole degrees on its own clock, polled at 120 Hz, drawn at
/// 120 fps. `EdgeInterpolator` draws the lid one sensor period in the
/// past and the `SlewTracker` (ω 40) chases that; the old path fed the
/// raw staircase to an ω 20 tracker and pulsed ±25 % ten times a second.
/// Pure: the clock is the loop counter, nothing waits on the wall.
@Suite("Fold smoothing")
struct FoldSmoothingTests {
    struct Row {
        var t: Double
        var truth: Double
        var shown: Double
        var velocity: Double
        /// The whole degree the sensor was reporting.
        var reported: Double
    }

    /// The real lid: at `start` until 0.3 s, then closing at `speed` °/s
    /// down to `stop`; with `reopen`, it turns there and opens at the
    /// same speed back to `start`.
    private func truth(_ t: Double, speed: Double, start: Double = 110, stop: Double = 40,
                       reopen: Bool = false) -> Double {
        let t0 = 0.3
        guard t > t0 else { return start }
        let down = start - speed * (t - t0)
        if down >= stop { return down }
        guard reopen else { return stop }
        let turnAt = t0 + (start - stop) / speed
        return min(start, stop + speed * (t - turnAt))
    }

    private func run(speed: Double, interpolate: Bool, omega: Double,
                     stop: Double = 40, reopen: Bool = false, duration: Double = 2.4) -> [Row] {
        let dt = 1.0 / 120
        let period = 0.1, phase = 0.037
        var tracker = SlewTracker()
        tracker.omega = omega
        var edges = EdgeInterpolator()
        var lastBeat = Int.min
        var reported = truth(0, speed: speed, stop: stop, reopen: reopen).rounded()
        var rows: [Row] = []
        var t = 0.0
        while t < duration {
            // The sensor publishes a fresh whole degree every 100 ms on
            // its own clock; the 120 Hz poll sees it on the next beat.
            let beat = Int(((t - phase) / period).rounded(.down))
            if beat != lastBeat {
                lastBeat = beat
                reported = truth(Double(beat) * period + phase, speed: speed,
                                 stop: stop, reopen: reopen).rounded()
            }
            if interpolate {
                edges.feed(reported, at: t)
                if let drawn = edges.value(at: t) { tracker.feed(drawn) }
            } else {
                tracker.feed(reported)
            }
            tracker.tick(dt: dt)
            rows.append(Row(t: t, truth: truth(t, speed: speed, stop: stop, reopen: reopen),
                            shown: tracker.angle, velocity: tracker.velocity, reported: reported))
            t += dt
        }
        return rows
    }

    /// Lag (ms) and visible-speed ripple (peak-to-peak, % of the lid's
    /// speed) over the steady stretch of a close.
    private func steady(_ rows: [Row], speed: Double, stop: Double = 40) -> (lagMs: Double, ripple: Double) {
        let tStop = 0.3 + (110 - stop) / speed
        let window = rows.filter { $0.t > 0.7 && $0.t < tStop - 0.05 }
        guard window.count > 5 else { return (.nan, .nan) }
        let lag = window.map { $0.shown - $0.truth }.reduce(0, +) / Double(window.count)
        let speeds = window.map { -$0.velocity }
        let ripple = ((speeds.max() ?? 0) - (speeds.min() ?? 0)) / speed * 100
        return (lag / speed * 1000, ripple)
    }

    @Test("a steady close moves at a steady speed with no added lag", arguments: [40.0, 90, 140])
    func steadyClose(speed: Double) {
        let s = steady(run(speed: speed, interpolate: true, omega: 40), speed: speed)
        #expect(s.ripple < 5, "speed ripple \(s.ripple)% at \(speed)°/s")
        #expect(s.lagMs < 170, "lag \(s.lagMs) ms at \(speed)°/s")
        #expect(s.lagMs > 0, "never ahead of the lid")
    }

    @Test("the old path pulses: a raw staircase into ω 20 fails the ripple bound")
    func oldPathPulses() {
        // The regression pin: if this ever passes, the test above has
        // stopped measuring what the interpolator fixed.
        let s = steady(run(speed: 90, interpolate: false, omega: 20), speed: 90)
        #expect(s.ripple > 5, "old ripple \(s.ripple)%")
    }

    @Test("a close that stops lands on the stop without overshooting it")
    func noOvershootAtStop() {
        let rows = run(speed: 140, interpolate: true, omega: 40)
        let lowest = rows.map(\.shown).min() ?? 0
        #expect(lowest >= 40 - 1e-9, "overshot the stop: \(lowest)")
        #expect(abs((rows.last?.shown ?? 0) - 40) < 1e-9, "settled on the stop")
        // And the drawn angle only ever goes down on the way there.
        var last = Double.infinity
        for row in rows {
            #expect(row.shown <= last + 1e-9, "moved back up at \(row.t)")
            last = row.shown
        }
    }

    @Test("a reversal retraces: it turns at the bottom and opens back to where it started")
    func reversalRetraces() {
        let rows = run(speed: 90, interpolate: true, omega: 40, stop: 30, reopen: true, duration: 2.6)
        let lowest = rows.map(\.shown).min() ?? 0
        // The sensor's lowest whole degree is the turn the display can
        // know about: it never goes past it, and it turns within a few
        // degrees of it (a smooth turn rounds the corner, it doesn't
        // stop dead).
        let turn = rows.map(\.reported).min() ?? 0
        #expect(lowest >= turn - 1e-9, "went past the turn: \(lowest) vs \(turn)")
        #expect(lowest <= turn + 3, "turned early: \(lowest) vs \(turn)")
        #expect(abs((rows.last?.shown ?? 0) - 110) < 1e-9, "back where it started")
        // Retracing: once both legs are steady, at the same lid angle the
        // display trails the lid by as much going down as coming back up.
        let turnIndex = rows.firstIndex { $0.shown == lowest } ?? 0
        let turnAt = 0.3 + 80.0 / 90
        for angle in [72.0, 68, 64] {
            let down = rows[..<turnIndex].first { $0.truth <= angle }
            let up = rows[turnIndex...].first { $0.truth >= angle && $0.t > turnAt }
            guard let down, let up else { Issue.record("no crossing of \(angle)°"); continue }
            let behindDown = down.shown - angle
            let behindUp = angle - up.shown
            #expect(abs(behindDown - behindUp) < 0.75,
                    "at \(angle)° it trails \(behindDown)° closing, \(behindUp)° opening")
        }
        // The opening leg is as steady as the close.
        let opening = rows.filter { $0.t > turnAt + 0.35 && $0.t < turnAt + 80.0 / 90 - 0.05 }
        let speeds = opening.map(\.velocity)
        let ripple = ((speeds.max() ?? 0) - (speeds.min() ?? 0)) / 90 * 100
        #expect(ripple < 5, "opening ripple \(ripple)%")
        let lag = opening.map { $0.truth - $0.shown }.reduce(0, +) / Double(max(1, opening.count))
        #expect(lag / 90 * 1000 < 170, "opening lag")
    }

    @Test("a ±1° flicker at rest never reaches the picture")
    func flickerAtRest() {
        // The jitter filter holds its deadband; the interpolator sees one
        // reading and the tracker never moves.
        var jitter = JitterFilter(tolerance: 1.5)
        var edges = EdgeInterpolator()
        var tracker = SlewTracker()
        tracker.omega = 40
        let dt = 1.0 / 120
        var shown: [Double] = []
        for frame in 0..<480 {
            let t = Double(frame) * dt
            let reading = (Int(t / 0.1) % 2 == 0) ? 100.0 : 101.0
            if jitter.accept(reading, at: t) { edges.feed(reading, at: t) }
            if let drawn = edges.value(at: t) { tracker.feed(drawn) }
            tracker.tick(dt: dt)
            shown.append(tracker.angle)
        }
        #expect((shown.max() ?? 0) - (shown.min() ?? 0) < 1e-9, "the flicker moved the picture")
        #expect(edges.settled(at: 4), "nothing left to glide")
    }

    @Test("the interpolator holds past its last edge and back-dates a lid leaving rest")
    func interpolatorEdges() {
        var edges = EdgeInterpolator()
        #expect(edges.value(at: 0) == nil)
        edges.feed(100, at: 1)
        #expect(edges.value(at: 1) == 100)
        #expect(edges.settled(at: 1.1))
        // A second later the lid moves: the glide starts at once, from
        // the rest value, and reaches the new edge one period later.
        edges.feed(99, at: 2)
        #expect(!edges.settled(at: 2))
        #expect(edges.value(at: 2) == 100)
        #expect(abs((edges.value(at: 2.05) ?? 0) - 99.5) < 1e-9)
        #expect(edges.value(at: 2.1) == 99)
        #expect(edges.value(at: 3) == 99, "past the last edge it holds")
        // Repeats are not edges.
        edges.feed(99, at: 3.2)
        #expect(edges.settled(at: 3.2))
        edges.reset()
        #expect(edges.value(at: 4) == nil)
    }
}
