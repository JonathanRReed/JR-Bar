import Foundation
import JRBarCore

/// The tank's personality layer (docs/TOYS.md): pure seeded schedules —
/// which fish is the rare golden one, when a swimmer throws a
/// barrel-roll flourish, how deep into the night an idler dozes, and
/// who wears the streak crown. Everything is a function of a fish's
/// seed and the frame clock, so a replayed frame decides the same
/// thing and the schedules are testable without a window.
enum AquariumBehavior {
    /// A murmur-style scramble (the family `decorSet` uses): the
    /// seed's low bits already carry the swim, the lane and the
    /// direction — each personality draw goes through its own tag so
    /// the rolls can't line up with the patrol.
    static func scramble(_ bits: UInt64) -> UInt64 {
        var h = bits
        h ^= h >> 33
        h &*= 0xff51afd7ed558ccd
        h ^= h >> 33
        return h
    }

    // MARK: Flourish

    /// The roll's length in seconds.
    static let flourishDuration: Double = 1.6

    /// How far through a barrel roll `seed` is at `t`, or nil while it
    /// isn't rolling. About six fish in ten ever roll; those that do
    /// go on a 45–110 s cycle at a seeded phase, so two fish never
    /// roll together and one fish's rolls replay identically.
    static func flourishProgress(seed: UInt64, at t: Double) -> Double? {
        let h = scramble(seed ^ 0x7FB5A329E3A5B1C7)
        guard (h >> 40) & 0xFF < 0x9C else { return nil }
        let period = 45 + Double(h & 0xFF) / 0xFF * 65
        let phase = Double((h >> 8) & 0xFFFF) / 0xFFFF
        let cycle = t / period + phase
        let age = (cycle - cycle.rounded(.down)) * period
        guard age < flourishDuration else { return nil }
        return age / flourishDuration
    }

    // MARK: Tricks

    /// The tap-trick's length in seconds — a barrel roll or a bubble
    /// ring, over quick enough to read as a flourish.
    static let trickDuration: Double = 0.9

    // MARK: Doze

    /// The tank's night factor — the same slow breath `drawWater`
    /// washes with (0 bright … 1 deepest), on its four-minute cycle.
    static func night(at t: Double) -> Double {
        0.5 + 0.5 * sin(t * .pi * 2 / 240)
    }

    /// The real-clock night factor (0 bright … 1 deepest): full dark
    /// from 21:00 to 06:00, dawn blending down 06–08 and dusk blending
    /// up 19–21 — smoothsteps, so the wash never snaps.
    static func realTimeNight(at date: Date, calendar: Calendar = .current) -> Double {
        let hour = Double(calendar.component(.hour, from: date))
            + Double(calendar.component(.minute, from: date)) / 60
        switch hour {
        case ..<6, 21...: return 1
        case 6..<8:
            let p = (hour - 6) / 2
            return 1 - p * p * (3 - 2 * p)
        case 19..<21:
            let p = (hour - 19) / 2
            return p * p * (3 - 2 * p)
        default: return 0
        }
    }

    /// How asleep an idling fish is, 0…1. Each fish has its own
    /// nod-off threshold (~62–82 % night) so the tank falls asleep one
    /// fish at a time; about a third never doze — there's always a
    /// night owl. Smooth at the edges so nobody snaps awake.
    static func doze(seed: UInt64, night: Double) -> Double {
        let h = scramble(seed ^ 0xD1B54A32D192ED03)
        guard (h >> 32) & 0xFF < 0xB4 else { return 0 }
        let threshold = 0.62 + Double((h >> 16) & 0xFF) / 0xFF * 0.20
        let d = min(1, max(0, (night - threshold) / 0.16))
        return d * d * (3 - 2 * d)
    }

    /// The cycle-clock doze — kept for callers (and tests) that speak
    /// in frame time rather than a resolved night factor.
    static func doze(seed: UInt64, at t: Double) -> Double {
        doze(seed: seed, night: night(at: t))
    }

    // MARK: Golden

    /// The rare golden variant: about one fish in twenty-four swims in
    /// gold lamé. Seeded off the session id, so the same session always
    /// draws the golden ticket — or never does.
    static func isGolden(seed: UInt64) -> Bool {
        scramble(seed ^ 0x9E3779B97F4A7C15) % 24 == 0
    }

    // MARK: Royalty

    /// The streak needed before grown fish go royal.
    static let crownStreakDays = 3

    /// A full-grown fish on a streak tank wears the crown — a bought
    /// hat still wins, so this is only the default headwear.
    static func wearsCrown(streakDays: Int, stage: Int) -> Bool {
        streakDays >= crownStreakDays && stage >= AquariumRules.maxStage
    }

    // MARK: Pearl flight

    /// A pearl's arc to the counter chip: an ease-out hop on a
    /// quadratic Bézier peaked above the straight line — the path a
    /// collected drop or an eaten pellet's pearl takes home.
    static func flightPoint(from a: CGPoint, to b: CGPoint, p: Double) -> CGPoint {
        let e = 1 - pow(1 - min(1, max(0, p)), 3)
        let mid = CGPoint(x: (a.x + b.x) / 2, y: min(a.y, b.y) - 46)
        let u = 1 - e
        return CGPoint(x: u * u * a.x + 2 * u * e * mid.x + e * e * b.x,
                       y: u * u * a.y + 2 * u * e * mid.y + e * e * b.y)
    }
}
