import JRBarCore
import SwiftUI

/// What a tank's swimmers remember between frames beyond their steering
/// bodies (docs/TOYS.md §Aquarium, Swimming): where each fish was last
/// drawn, and the leftover of its last change of state — so an ask
/// answered swims back down from the glass, a fish failing mid-turn
/// finishes coming round, and nothing ever jumps from one pose to the
/// next. One per tank, like the bodies: the window, the wallpaper and
/// the screensaver each keep their own.
final class TankSwimMemory {
    /// How long a change of state takes to settle, seconds.
    static let settleTime = 0.6

    /// One fish's last drawn pose, in the tank's points.
    struct Drawn {
        var state: FishState
        var x: Double
        var y: Double
        var yawCos: Double
        var pitch: Double
        var scale: Double
        var lead: Double
        var wag: Double
        var roll: Double
        /// The frame clock it was drawn at.
        var t: Double
    }

    /// A change of state: when it came, which way the fish faced going
    /// in, and the gap between the old state's last pose and the new
    /// state's first, which eases away — its place, its turn, its size
    /// (an ask draws a fish a touch bigger), its tail and its roll.
    struct Handoff {
        var state: FishState
        var t: Double
        var facing: Double
        var dx: Double
        var dy: Double
        var dc: Double
        var dpitch: Double
        var dscale: Double
        var dlead: Double
        var dwag: Double
        var droll: Double
    }

    /// A finished run's meal as it was planned the first frame it was
    /// seen: which fish comes for each pellet — decided once, so an eater
    /// never changes its mind halfway over — and when each was eaten.
    struct Meal {
        /// The leave this meal belongs to (the leaver's `stateSince`).
        var since: Date
        var eaters: [String?]
        /// A fish with no steering body yet (a fixture's) is pulled over
        /// on this clock instead of swimming: seconds to reach its pellet.
        var darts: [Double]
        /// Seconds into the leave each pellet was eaten, once it was.
        var eatenAt: [Double?]
    }

    /// A barrel roll as it began: when, and whether the fish was clear to
    /// roll then. Decided once, so a started roll finishes and a roll
    /// that was waited out never reappears half done.
    struct Roll {
        var start: Double
        var go: Bool
    }

    /// A fry's place round its parent: how far round its orbit it has
    /// come, and the frame clock it had come that far by.
    struct Orbit {
        var angle: Double
        var t: Double
    }

    var drawn: [String: Drawn] = [:]
    var handoffs: [String: Handoff] = [:]
    /// Keyed by the leaver's id.
    var meals: [String: Meal] = [:]
    var rolls: [String: Roll] = [:]
    /// The cleaner shrimp's last drawn spot and the fish its round was
    /// out with then, plus the leftover of its last change of client —
    /// the gap from where it was to where the new round puts it, easing
    /// away over `length` seconds from `since`.
    struct ShrimpTrail {
        var client: String?
        var x: Double
        var y: Double
        var t: Double
        var dx: Double
        var dy: Double
        var since: Double
        var length: Double
    }

    /// Keyed by the fry's id.
    var orbits: [String: Orbit] = [:]
    /// The cleaner shrimp's, while the tank has one.
    var shrimp: ShrimpTrail?
    /// The swim settings as this frame read them.
    var settings: AquariumSettings?
    /// The swim clock as it stood when the Swimming speed last moved:
    /// the frame it moved on, the seconds of swimming by then, and the
    /// new speed. nil until a frame has stepped.
    private var retimed: (t: Double, swum: Double, tempo: Double)?

    /// Seconds of swimming by frame time `t` — the clock times the
    /// Swimming speed, carried on from where it stood each time the
    /// speed moves. The patrol sweep runs on it, so moving the slider
    /// changes how fast a fish sweeps, never where along the sweep it is.
    func swimTime(at t: Double, tempo: Double) -> Double {
        guard let r = retimed else { return t * tempo }
        return r.swum + (t - r.t) * r.tempo
    }

    /// Take this frame's Swimming speed (`stepSwim` calls it once a
    /// frame): a change starts running the swim clock at the new rate
    /// from here.
    func retime(to tempo: Double, at t: Double) {
        if let r = retimed, r.tempo == tempo { return }
        retimed = (t, swimTime(at: t, tempo: tempo), tempo)
    }

    /// How far round its orbit fry `id` has come by `t`, circling at
    /// `rate` radians a second: the first sight places it at `start`,
    /// and every frame after adds on only the time since the one before
    /// — so the Swimming speed or its parent dozing off changes how fast
    /// it circles, never where it is. A paused window picks up where it
    /// stopped.
    func orbit(_ id: String, t: Double, rate: Double, start: () -> Double) -> Double {
        guard var o = orbits[id] else {
            let angle = start()
            orbits[id] = Orbit(angle: angle, t: t)
            return angle
        }
        let dt = t - o.t
        guard dt > 0 else { return o.angle }
        if dt <= 0.5 { o.angle += rate * dt }
        o.t = t
        orbits[id] = o
        return o.angle
    }

    /// Remember where `fish` was drawn this frame.
    func record(_ fish: Fish, layout l: AquariumView.Layout, t: Double) {
        drawn[fish.id] = Drawn(state: fish.state, x: l.x, y: l.y, yawCos: l.yawCos,
                               pitch: l.pitch, scale: l.scale, lead: l.lead, wag: l.wag,
                               roll: l.roll, t: t)
    }

    /// Forget fish that have left the tank.
    func prune(keeping live: Set<String>) {
        if drawn.count > live.count { drawn = drawn.filter { live.contains($0.key) } }
        if handoffs.count > live.count { handoffs = handoffs.filter { live.contains($0.key) } }
        if meals.count > live.count { meals = meals.filter { live.contains($0.key) } }
        if rolls.count > live.count { rolls = rolls.filter { live.contains($0.key) } }
        if orbits.count > live.count { orbits = orbits.filter { live.contains($0.key) } }
    }
}
