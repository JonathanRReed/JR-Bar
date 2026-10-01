import Foundation
import JRBarUI

/// How often each of the tank's five passes redraws, and which of them
/// stand still, once the Mac's power state is read in (`PowerPolicy`).
///
/// At normal power these are the numbers the tank has always run at: the
/// plants at 20 frames a second, the light pass at 12, the live canvas at
/// 30, and the two baked rasters on their slow tick. Under Reduce Motion
/// the moving passes keep their one-a-second heartbeat. Low Power Mode or
/// a serious thermal state halves every rate; a critical thermal state
/// also stops the passes that only decorate. The live canvas carries the
/// simulation (pellets still sink to mouths, meals are still served), so
/// it only ever slows.
struct AquariumFrameRates: Equatable {
    /// The plants' sway.
    static let plants: TimeInterval = 1.0 / 20.0
    /// The light pass: shafts, caustics and the sheen drift.
    static let light: TimeInterval = 1.0 / 12.0
    /// The live canvas: fish, bubbles, plankton, visitors.
    static let live: TimeInterval = 1.0 / 30.0
    /// What the moving passes tick at under Reduce Motion.
    static let heartbeat: TimeInterval = 1

    /// The far tank and the near bed, rasterized on the slow tick.
    let still: TimeInterval
    let plants: TimeInterval
    let light: TimeInterval
    let live: TimeInterval

    init(power: PowerPolicy, reduceMotion: Bool, stillTick: TimeInterval) {
        // The slow tick already settles to its resting two seconds under
        // Reduce Motion; the policy leaves that alone.
        still = power.interval(stillTick, reduceMotion: reduceMotion, heartbeat: stillTick)
        plants = power.interval(Self.plants, reduceMotion: reduceMotion, heartbeat: Self.heartbeat)
        light = power.interval(Self.light, reduceMotion: reduceMotion, heartbeat: Self.heartbeat)
        live = power.interval(Self.live, reduceMotion: reduceMotion, heartbeat: Self.heartbeat)
    }

    /// Whether the passes that only decorate stand still: the window is
    /// out of sight (`occluded`, as it always was) or the Mac is critically
    /// hot.
    static func decorationPaused(power: PowerPolicy, occluded: Bool) -> Bool {
        power.pauses(occluded: occluded)
    }

    /// Whether the live canvas stands still: only when out of sight.
    static func livePaused(power: PowerPolicy, occluded: Bool) -> Bool {
        power.pauses(occluded: occluded, decorativeOnly: false)
    }
}
