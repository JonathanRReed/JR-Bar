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
        /// The frame clock it was drawn at.
        var t: Double
    }

    /// A change of state: when it came, which way the fish faced going
    /// in, and the gap between the old state's last pose and the new
    /// state's first, which eases away.
    struct Handoff {
        var state: FishState
        var t: Double
        var facing: Double
        var dx: Double
        var dy: Double
        var dc: Double
        var dpitch: Double
    }

    var drawn: [String: Drawn] = [:]
    var handoffs: [String: Handoff] = [:]
    /// The swim settings as this frame read them.
    var settings: AquariumSettings?

    /// Remember where `fish` was drawn this frame.
    func record(_ fish: Fish, layout l: AquariumView.Layout, t: Double) {
        drawn[fish.id] = Drawn(state: fish.state, x: l.x, y: l.y, yawCos: l.yawCos,
                               pitch: l.pitch, t: t)
    }

    /// Forget fish that have left the tank.
    func prune(keeping live: Set<String>) {
        if drawn.count > live.count { drawn = drawn.filter { live.contains($0.key) } }
        if handoffs.count > live.count { handoffs = handoffs.filter { live.contains($0.key) } }
    }
}
