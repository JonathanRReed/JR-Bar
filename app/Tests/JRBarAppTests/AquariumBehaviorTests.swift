import Foundation
import Testing
import JRBarCore
@testable import JRBarApp

/// `AquariumBehavior` is the tank's personality layer (docs/TOYS.md):
/// seeded schedules — who rolls, who dozes, who's golden, who wears
/// the streak crown — pure functions of a seed and a clock.
@Suite("Aquarium behavior")
struct AquariumBehaviorTests {
    @Test("flourish progress is deterministic and bounded")
    func flourishDeterminism() {
        for seed: UInt64 in [1, 42, 777] {
            for i in 0..<400 {
                let t = Double(i) * 0.5
                let a = AquariumBehavior.flourishProgress(seed: seed, at: t)
                #expect(a == AquariumBehavior.flourishProgress(seed: seed, at: t))
                if let a { #expect(a >= 0 && a <= 1) }
            }
        }
        // The roll direction is one of the two valid signs, per seed.
        for seed: UInt64 in [3, 9, 512] {
            let d = AquariumBehavior.flourishDirection(seed: seed)
            #expect(d == 1 || d == -1)
        }
    }

    @Test("some fish roll, briefly and occasionally")
    func flourishRarity() {
        var rollers = 0
        var rolling = 0
        var total = 0
        // Two minutes at 10 Hz per seed.
        for seed: UInt64 in 0..<40 {
            var saw = false
            for i in 0..<1200 {
                total += 1
                if AquariumBehavior.flourishProgress(seed: seed, at: Double(i) * 0.1) != nil {
                    saw = true
                    rolling += 1
                }
            }
            if saw { rollers += 1 }
        }
        #expect(rollers > 0)          // somebody shows off
        #expect(rollers < 40)         // not everybody
        // A roll is ~1.6 s per ≥45 s — under 4 % of the clock.
        #expect(Double(rolling) / Double(total) < 0.04)
    }

    @Test("the golden variant is rare and stable")
    func golden() {
        var count = 0
        for seed: UInt64 in 0..<1000 {
            if AquariumBehavior.isGolden(seed: seed) { count += 1 }
        }
        #expect(count > 0)            // the ticket exists
        #expect(count < 100)          // and stays rare (~4 %)
        #expect(AquariumBehavior.isGolden(seed: 7)
                == AquariumBehavior.isGolden(seed: 7))
    }

    @Test("idlers doze at night and never by day")
    func doze() {
        // The night factor peaks at sin(2πt/240) = 1 → t = 60,
        // bottoms at -1 → t = 180.
        let nightT = 60.0
        let dayT = 180.0
        var sleepers = 0
        for seed: UInt64 in 0..<60 {
            #expect(AquariumBehavior.doze(seed: seed, at: dayT) == 0)
            if AquariumBehavior.doze(seed: seed, at: nightT) > 0 { sleepers += 1 }
        }
        #expect(sleepers >= 20)       // most of the tank nods off
        #expect(sleepers < 60)        // the night owls stay up
        // Half-way up the wash it's a partial doze, not a switch.
        let midT = 60.0 + 120.0 * 0.25 // sin(2π·90/240)=sin(0.75π)≈0.707 → night≈0.85
        for seed: UInt64 in 0..<60 {
            let d = AquariumBehavior.doze(seed: seed, at: midT)
            #expect(d >= 0 && d <= 1)
        }
    }

    @Test("the streak crown needs a streak and a grown fish")
    func crown() {
        #expect(!AquariumBehavior.wearsCrown(streakDays: 0, stage: 2))
        #expect(!AquariumBehavior.wearsCrown(streakDays: 2, stage: 2))
        #expect(!AquariumBehavior.wearsCrown(streakDays: 3, stage: 0))
        #expect(!AquariumBehavior.wearsCrown(streakDays: 3, stage: 1))
        #expect(AquariumBehavior.wearsCrown(streakDays: 3, stage: 2))
        #expect(AquariumBehavior.wearsCrown(streakDays: 9, stage: 2))
    }

    @Test("a pearl's flight lands on the counter and arcs above the line")
    func flight() {
        let a = CGPoint(x: 200, y: 300)
        let b = CGPoint(x: 34, y: 20)
        #expect(AquariumBehavior.flightPoint(from: a, to: b, p: 0) == a)
        #expect(AquariumBehavior.flightPoint(from: a, to: b, p: 1) == b)
        let mid = AquariumBehavior.flightPoint(from: a, to: b, p: 0.5)
        #expect(mid.y < (a.y + b.y) / 2)   // hops up, not a straight slide
        // Out-of-range progress clamps, not crashes.
        #expect(AquariumBehavior.flightPoint(from: a, to: b, p: -1) == a)
        #expect(AquariumBehavior.flightPoint(from: a, to: b, p: 2) == b)
    }

    @Test("the clock's night runs nine-to-six with blended edges")
    func realTimeNight() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        func at(_ hour: Int, _ minute: Int = 0) -> Date {
            calendar.date(from: DateComponents(year: 2026, month: 9, day: 20,
                                               hour: hour, minute: minute))!
        }
        #expect(AquariumBehavior.realTimeNight(at: at(0), calendar: calendar) == 1)
        #expect(AquariumBehavior.realTimeNight(at: at(5, 59), calendar: calendar) == 1)
        #expect(AquariumBehavior.realTimeNight(at: at(21), calendar: calendar) == 1)
        #expect(AquariumBehavior.realTimeNight(at: at(23, 30), calendar: calendar) == 1)
        #expect(AquariumBehavior.realTimeNight(at: at(12), calendar: calendar) == 0)
        #expect(AquariumBehavior.realTimeNight(at: at(8), calendar: calendar) == 0)
        #expect(AquariumBehavior.realTimeNight(at: at(18, 59), calendar: calendar) == 0)
        // The edges blend, not snap: mid-dawn and mid-dusk are partial.
        let dawn = AquariumBehavior.realTimeNight(at: at(7), calendar: calendar)
        #expect(dawn > 0 && dawn < 1)
        let dusk = AquariumBehavior.realTimeNight(at: at(20), calendar: calendar)
        #expect(dusk > 0 && dusk < 1)
        // And they stay inside 0…1 at every boundary tick.
        for hour in 0..<24 {
            let n = AquariumBehavior.realTimeNight(
                at: at(hour, 30), calendar: calendar)
            #expect(n >= 0 && n <= 1)
        }
    }
}
