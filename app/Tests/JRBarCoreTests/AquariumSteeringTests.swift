import Foundation
import Testing
@testable import JRBarCore

/// `AquariumSteering` is the tank's motion (docs/TOYS.md): wander
/// noise, a soft boundary turn, a direct food seek and a weak school
/// pull — pure functions of body, clock and seed.
@Suite("Aquarium steering")
struct AquariumSteeringTests {
    private func body(x: Double = 0.5, y: Double = 0.5, heading: Double = 0,
                      speed: Double = 0.06, energy: Double = 1,
                      homeY: Double = 0.5) -> SwimBody {
        SwimBody(x: x, y: y, heading: heading, speed: speed,
                 turnRate: 2.0, energy: energy, homeY: homeY)
    }

    @Test("wander noise is bounded, smooth and per-seed")
    func wander() {
        for seed: UInt64 in [1, 7, 999] {
            for i in 0..<200 {
                let v = AquariumSteering.wanderNoise(seed: seed, at: Double(i) * 0.1)
                #expect(v >= -1.001 && v <= 1.001)
            }
        }
        // Deterministic: same seed & clock, same nudge.
        #expect(AquariumSteering.wanderNoise(seed: 42, at: 3.7)
                == AquariumSteering.wanderNoise(seed: 42, at: 3.7))
        // Different seeds wander differently.
        #expect(AquariumSteering.wanderNoise(seed: 1, at: 3.7)
                != AquariumSteering.wanderNoise(seed: 2, at: 3.7))
        // Smooth: one frame's step is tiny.
        let d = abs(AquariumSteering.wanderNoise(seed: 9, at: 10.0)
                    - AquariumSteering.wanderNoise(seed: 9, at: 10.033))
        #expect(d < 0.1)
    }

    @Test("steer takes the shortest arc and respects the turn cap")
    func steer() {
        // A quarter turn, room to make it (π/2 < 2).
        let turned = AquariumSteering.steer(0, toward: .pi / 2, maxTurn: 2)
        #expect(abs(turned - .pi / 2) < 1e-9)
        // The short way around: +π → −π is the same seam, so 0 → 3π/2
        // goes backwards.
        let wrapped = AquariumSteering.steer(0, toward: .pi * 1.5, maxTurn: 10)
        #expect(abs(wrapped - (-.pi / 2)) < 1e-9)
        // The cap binds.
        #expect(abs(AquariumSteering.steer(0, toward: .pi, maxTurn: 0.2) - 0.2) < 1e-9)
    }

    @Test("the boundary turns a fish back into the tank before the wall")
    func boundary() {
        var b = body(x: 0.05, heading: .pi)   // nose at the left glass
        let desired = AquariumSteering.boundaryDesired(b, bounds: SwimBounds())
        #expect(desired != nil)
        // The correction points right-ish: cos > 0.
        #expect(cos(desired!) > 0)
        // Stepped, it turns and the x grows.
        let ctx = SwimContext(wander: 0)
        for _ in 0..<120 {
            AquariumSteering.step(&b, dt: 1.0 / 30, t: 0, seed: 1, context: ctx)
        }
        #expect(cos(b.heading) > 0)
        #expect(b.x > 0.05)
        // Deep water gives no correction.
        let clear = body(x: 0.5, heading: .pi)
        #expect(AquariumSteering.boundaryDesired(clear, bounds: SwimBounds()) == nil)
        // And nothing ever leaves the water.
        var hugger = body(x: 0.02, y: 0.05, heading: .pi * 0.9, speed: 0.5)
        for i in 0..<300 {
            AquariumSteering.step(&hugger, dt: 1.0 / 30, t: Double(i) / 30,
                                  seed: 3, context: SwimContext(wander: 1))
            #expect((0...1).contains(hugger.x))
            #expect((0...1).contains(hugger.y))
        }
    }

    @Test("a fish with food seeks straight at it and arrives")
    func seek() {
        var b = body(x: 0.2, y: 0.6, heading: -.pi / 2)   // facing away
        let ctx = SwimContext(food: (x: 0.8, y: 0.3), wander: 0)
        var t = 0.0
        var arrived = false
        for _ in 0..<600 {
            t += 1.0 / 30
            AquariumSteering.step(&b, dt: 1.0 / 30, t: t, seed: 5, context: ctx)
            let dx = b.x - 0.8, dy = b.y - 0.3
            if (dx * dx + dy * dy).squareRoot() < 0.04 { arrived = true; break }
        }
        #expect(arrived)
    }

    @Test("two seeds never share a path")
    func noIdenticalPaths() {
        var a = body()
        var b = body()
        let ctx = SwimContext(wander: 1)
        var t = 0.0
        var diverged = false
        for _ in 0..<120 {
            t += 1.0 / 30
            AquariumSteering.step(&a, dt: 1.0 / 30, t: t, seed: 11, context: ctx)
            AquariumSteering.step(&b, dt: 1.0 / 30, t: t, seed: 12, context: ctx)
            if a != b { diverged = true }
        }
        #expect(diverged)
    }

    @Test("the school pull only acts when the group drifts apart")
    func schooling() {
        let b = body(x: 0.5, y: 0.5, heading: 0)
        // A nearby centre doesn't bend the wander.
        var near = b
        AquariumSteering.step(&near, dt: 1.0 / 30, t: 0, seed: 1,
                              context: SwimContext(school: (x: 0.55, y: 0.5), wander: 0))
        #expect(near.heading == b.heading)
        // A far one pulls the heading toward it — checked while the
        // fish is still approaching; run long enough and it cruises
        // past the school into the glass and banks back, as it should.
        var far = b
        for i in 0..<120 {
            AquariumSteering.step(&far, dt: 1.0 / 30, t: Double(i) / 30, seed: 1,
                                  context: SwimContext(school: (x: 0.9, y: 0.5), wander: 0))
        }
        #expect(far.x > b.x)
        #expect(far.heading > -0.6 && far.heading < 0.6)
    }
}
