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

    // MARK: The turn

    /// The view's tank: 900×560, the glass where `stepSwim` puts it.
    private static let tank = SwimBounds(minX: 0.05, minY: 30.0 / 560, maxX: 0.95,
                                         maxY: 460.0 / 560, margin: 0.10)

    /// Eight fish built the way the view builds them.
    private static func fleet() -> [(seed: UInt64, body: SwimBody)] {
        ["claude-a", "codex-b", "gemini-c", "opencode-d", "devin-e", "cursor-f", "grok-g", "hermes-h"].map { id in
            let h = AquariumModel.stableHash(id)
            let homeY = min(0.80, max(0.14, (34 + AquariumModel.lane(for: id) * (560 - 142)) / 560))
            let spawned = AquariumSteering.spawn(seed: h, fishSpeed: AquariumModel.speed(for: id),
                                                 direction: AquariumModel.direction(for: id),
                                                 homeY: homeY, length: 60.0 / 900)
            return (h, spawned)
        }
    }

    @Test("open water arcs gently instead of spinning")
    func openWaterArcs() {
        // No glass in reach: only the wander and the depth spring act.
        let open = SwimBounds(minX: -50, minY: -50, maxX: 50, maxY: 50, margin: 0.1)
        for (seed, start) in Self.fleet() {
            var b = start
            var rates: [Double] = []
            var bound = 0
            var t = 100.0
            for _ in 0..<(30 * 20) {
                let before = b.heading
                let climbBefore = b.climb
                t += 1.0 / 30
                AquariumSteering.step(&b, dt: 1.0 / 30, t: t, seed: seed,
                                      context: SwimContext(bounds: open, wander: 1))
                guard b.turn == nil else { continue }
                rates.append(abs(AquariumSteering.turnDelta(from: before, to: b.heading)) * 30)
                if abs(b.climb - climbBefore) * 30 >= b.turnRate * 0.99 { bound += 1 }
            }
            rates.sort()
            #expect(rates[rates.count / 2] < 0.5, "median turn rate stays gentle")
            #expect(Double(bound) / Double(max(1, rates.count)) < 0.10, "the turn cap rarely binds")
        }
    }

    @Test("reversals are rare, deliberate and cooled down")
    func reversalsAreRare() {
        for (seed, start) in Self.fleet() {
            var b = start
            var t = 1000.0
            var reversals = 0
            var ends: [Double] = []
            var starts: [(t: Double, kind: SwimTurn.Kind)] = []
            var wasTurning = false
            for _ in 0..<(30 * 300) {
                t += 1.0 / 30
                let dirBefore = b.dir
                AquariumSteering.step(&b, dt: 1.0 / 30, t: t, seed: seed,
                                      context: SwimContext(bounds: Self.tank))
                if let turn = b.turn, !wasTurning { starts.append((turn.start, turn.kind)) }
                if b.dir != dirBefore { reversals += 1; ends.append(b.lastTurnEnd) }
                wasTurning = b.turn != nil
            }
            #expect(Double(reversals) / 5 <= 4, "\(seed): \(reversals) reversals in five minutes")
            #expect(reversals >= 3, "\(seed): the fish still crosses the tank")
            // No turn starts inside the cooldown of the one before it.
            for s in starts {
                guard let last = ends.last(where: { $0 < s.t }) else { continue }
                #expect(s.t - last >= SwimPace.natural.cooldown - 1e-9,
                        "\(seed): a \(s.kind) turn \(s.t - last) s after the last")
            }
        }
    }

    @Test("a reversal is one committed U-turn")
    func oneCommittedTurn() {
        var b = SwimBody(x: 0.80, y: 0.45, dir: 1, speed: 0.045, turnRate: 2.4, energy: 1,
                         homeY: 0.45, length: 0.07)
        var t = 50.0
        var progress: [Double] = []
        var xs: [Double] = [b.x]
        var dirs: [Double] = [b.dir]
        var duration = 0.0
        var turnFrames = 0
        for _ in 0..<(30 * 6) {
            t += 1.0 / 30
            AquariumSteering.step(&b, dt: 1.0 / 30, t: t, seed: 7,
                                  context: SwimContext(bounds: Self.tank, wander: 0))
            xs.append(b.x)
            dirs.append(b.dir)
            if let turn = b.turn {
                progress.append(turn.progress)
                duration = turn.duration
                turnFrames += 1
            } else if !progress.isEmpty, progress.last != 1 {
                progress.append(1)
                turnFrames += 1
            }
        }
        #expect(!progress.isEmpty, "the glass started a turn")
        #expect(zip(progress, progress.dropFirst()).allSatisfy { $0 <= $1 }, "p only rises")
        let took = Double(turnFrames) / 30
        #expect(took >= 0.95 * duration && took <= 1.05 * duration + 1.0 / 30,
                "the turn ends on time: \(took) s for \(duration)")
        #expect(abs(duration - AquariumTurn.duration(for: .wall, pace: .natural)) < 1e-9)
        // The screen speed changes sign once, and so does the facing.
        let steps = zip(xs, xs.dropFirst()).map { $1 - $0 }.filter { abs($0) > 1e-9 }
        let vxFlips = zip(steps, steps.dropFirst()).filter { ($0 > 0) != ($1 > 0) }.count
        #expect(vxFlips == 1)
        #expect(zip(dirs, dirs.dropFirst()).filter { $0 != $1 }.count == 1)
    }

    @Test("the climb stays capped and the drawn pitch eases")
    func climbCapped() {
        let dt = 1.0 / 30
        for (seed, start) in Self.fleet() {
            var b = start
            var t = 400.0
            for i in 0..<(30 * 120) {
                t += dt
                let pitchBefore = b.pitch
                AquariumSteering.step(&b, dt: dt, t: t, seed: seed,
                                      context: SwimContext(bounds: Self.tank))
                if i > 90, b.turn == nil {
                    #expect(abs(b.climb) <= AquariumSteering.cruiseClimb + 0.02)
                }
                #expect(abs(b.pitch) <= AquariumSteering.maxPitch + 1e-9)
                // One frame's ease never covers more than the damping
                // allows of the widest possible gap.
                #expect(abs(b.pitch - pitchBefore)
                        <= AquariumSteering.pitchDamping * dt * AquariumSteering.maxPitch * 2 + 1e-9)
            }
        }
        // Food far below may steepen the climb, never past the seek cap.
        var diver = SwimBody(x: 0.2, y: 0.15, dir: 1, speed: 0.045, turnRate: 2.4, energy: 1,
                             homeY: 0.15)
        var t = 0.0
        var steepest = 0.0
        for _ in 0..<90 {
            t += dt
            AquariumSteering.step(&diver, dt: dt, t: t, seed: 3,
                                  context: SwimContext(bounds: Self.tank, food: (0.4, 0.8)))
            steepest = max(steepest, abs(diver.climb))
            #expect(abs(diver.pitch) <= AquariumSteering.maxPitch + 1e-9)
        }
        #expect(steepest > AquariumSteering.cruiseClimb, "a dart may steepen")
        #expect(steepest <= AquariumSteering.seekClimb + 1e-9)
    }

    @Test("a wall turn never meets the glass, even at full tilt")
    func wallTurnKeepsClear() {
        let fastest = AquariumSteering.cruiseSpeed(fishSpeed: 0.14)
        for (pace, tempo) in [(SwimPace.natural, 1.0), (.lively, 1.6), (.calm, 0.5)] {
            for dir in [1.0, -1.0] {
                var b = SwimBody(x: 0.5, y: 0.45, dir: dir, speed: fastest, turnRate: 3,
                                 energy: 1.12, homeY: 0.45, length: 0.11)
                var t = 20.0
                var turned = false
                for _ in 0..<(30 * 40) {
                    t += 1.0 / 30
                    AquariumSteering.step(&b, dt: 1.0 / 30, t: t, seed: 11,
                                          context: SwimContext(bounds: Self.tank, wander: 0,
                                                               pace: pace, tempo: tempo))
                    if b.turn?.kind == .wall { turned = true }
                    let nose = b.x + (b.turn?.from ?? b.dir) * 0.55 * b.length
                    #expect(nose <= Self.tank.maxX + 1e-9 && nose >= Self.tank.minX - 1e-9,
                            "\(pace) ×\(tempo): the nose reached the glass at \(nose)")
                    #expect(b.x < Self.tank.maxX && b.x > Self.tank.minX, "the hard clamp never engages")
                    if turned && b.turn == nil { break }
                }
                #expect(turned)
            }
        }
    }

    @Test("a station hold hovers instead of orbiting")
    func stationHover() {
        let anchor = AquariumStations.Anchor(x: 0.52, y: 0.5, spanX: 20.0 / 900, spanY: 0.06)
        for (speed, turnRate, energy) in [(0.045, 2.4, 1.0), (0.050, 1.8, 1.12), (0.030, 3.0, 0.88)] {
            var b = SwimBody(x: 0.49, y: 0.5, dir: 1, speed: speed, turnRate: turnRate, energy: energy,
                             homeY: 0.5, length: 0.07)
            var t = 0.0
            var reversals = 0
            var turnTimes: [Double] = []
            var distances: [Double] = []
            for _ in 0..<(30 * 30) {
                t += 1.0 / 30
                let goal = AquariumStations.target(for: .current, anchor: anchor, t: t, seed: 0xC0FFEE)
                let dist = hypot(goal.x - b.x, goal.y - b.y)
                let dirBefore = b.dir
                AquariumSteering.step(&b, dt: 1.0 / 30, t: t, seed: 7,
                                      context: SwimContext(bounds: Self.tank, wander: 0.35,
                                                           effort: AquariumStations.effort(for: .current, distance: dist),
                                                           station: goal))
                if b.dir != dirBefore { reversals += 1; turnTimes.append(t) }
                distances.append(dist)
            }
            #expect(reversals <= 3, "\(reversals) reversals holding station")
            // Never more than one about-face in any ten seconds.
            for (a, later) in zip(turnTimes, turnTimes.dropFirst()) {
                #expect(later - a >= 3, "two turns \(later - a) s apart")
            }
            let mean = distances.reduce(0, +) / Double(distances.count)
            #expect(mean < AquariumStations.arriveRadius, "mean distance \(mean)")
        }
    }

    @Test("food behind the fish turns it quickly; a scare quicker")
    func foodTurnsQuickly() {
        for (startled, kind) in [(false, SwimTurn.Kind.food), (true, .startle)] {
            var b = SwimBody(x: 0.5, y: 0.5, dir: 1, speed: 0.04, turnRate: 2.4, energy: 1, homeY: 0.5)
            // It has just turned: the whim's cooldown would hold it, food
            // waits only the short beat.
            b.lastTurnEnd = 10
            var t = 10.0
            var began: Double?
            for _ in 0..<60 {
                t += 1.0 / 30
                AquariumSteering.step(&b, dt: 1.0 / 30, t: t, seed: 5,
                                      context: SwimContext(bounds: Self.tank, food: (0.3, 0.5),
                                                           startled: startled))
                if let turn = b.turn, began == nil {
                    began = turn.start
                    #expect(turn.kind == kind)
                    #expect(abs(turn.duration - AquariumTurn.duration(for: kind, pace: .natural)) < 1e-9)
                }
            }
            #expect(began != nil, "the food turned it")
            let start = began ?? 99
            #expect(start - 10 >= AquariumSteering.urgentCooldown - 1e-9)
            #expect(start - 10 <= AquariumSteering.urgentCooldown + 1.0 / 30 + 1e-9,
                    "within a frame of the short cooldown")
        }
        #expect(AquariumTurn.duration(for: .food, pace: .natural) == 0.55)
        #expect(AquariumTurn.duration(for: .startle, pace: .natural) == 0.45)
    }

    @Test("a turn wanted too soon waits: level, slower, then turns")
    func waitsOutTheCooldown() {
        // It just turned at the left glass, and now faces the right one
        // up close — a whim can't turn it yet.
        var b = SwimBody(x: 0.86, y: 0.45, dir: 1, climb: 0.3, speed: 0.045, turnRate: 2.4,
                         energy: 1, homeY: 0.45, length: 0.07)
        b.lastTurnEnd = 0
        var t = 0.0
        var slowest = 1.0
        var turnedAt: Double?
        for _ in 0..<(30 * 4) {
            t += 1.0 / 30
            AquariumSteering.step(&b, dt: 1.0 / 30, t: t, seed: 9,
                                  context: SwimContext(bounds: Self.tank, wander: 0))
            if b.turn != nil, turnedAt == nil { turnedAt = t }
            if turnedAt == nil { slowest = min(slowest, b.throttle) }
        }
        #expect((turnedAt ?? 0) >= SwimPace.natural.cooldown - 1e-9)
        #expect(slowest < 0.5, "it eased off while it waited")
    }

    @Test("a turn bows away from the surface and the sand")
    func arcAvoidsTheEdges() {
        for (y, bow) in [(Self.tank.minY + 0.03, 1.0), (Self.tank.maxY - 0.03, -1.0)] {
            for seed: UInt64 in [1, 2, 3, 4] {
                var b = SwimBody(x: 0.5, y: y, dir: 1, speed: 0.04, turnRate: 2.4, energy: 1, homeY: y)
                AquariumSteering.step(&b, dt: 1.0 / 30, t: 1, seed: seed,
                                      context: SwimContext(bounds: Self.tank, food: (0.3, y)))
                #expect(b.turn?.arc == bow)
            }
        }
    }

    @Test("a faster tempo covers more ground along the same shape of path")
    func tempoScalesDistanceNotRadius() {
        func run(_ tempo: Double, seconds: Double) -> (distance: Double, drift: Double) {
            var b = SwimBody(x: 0.3, y: 0.45, dir: 1, speed: 0.045, turnRate: 2.4, energy: 1,
                             homeY: 0.45, length: 0.07)
            b.throttle = AquariumSteering.glide(seed: 21, at: 0)
            var t = 0.0
            let dt = 1.0 / 240
            let startX = b.x
            var turnX: Double?
            var furthest = 0.0
            var distance = 0.0
            let steps = Int(seconds / dt)
            for i in 0..<steps {
                t += dt
                let x0 = b.x, y0 = b.y
                AquariumSteering.step(&b, dt: dt, t: t, seed: 21,
                                      context: SwimContext(bounds: Self.tank, wander: 0, tempo: tempo))
                if Double(i) * dt < 1 { distance += hypot(b.x - x0, b.y - y0) }
                if b.turn != nil, turnX == nil { turnX = x0 }
                if let turnX { furthest = max(furthest, b.x - turnX) }
            }
            _ = startX
            return (distance, furthest)
        }
        let slow = run(1, seconds: 30)
        let fast = run(2, seconds: 15)
        #expect(abs(fast.distance / slow.distance - 2) < 0.1, "twice the ground in a second")
        #expect(slow.drift > 0)
        #expect(abs(fast.drift / slow.drift - 1) < 0.05, "the U-turn is the same size")
    }

    @Test("the old heading shape still reads and writes")
    func headingCompatibility() {
        var b = SwimBody(x: 0.5, y: 0.5, heading: .pi - 0.2, speed: 0.05, turnRate: 2, energy: 1, homeY: 0.5)
        #expect(b.dir == -1)
        #expect(abs(b.climb - 0.2) < 1e-12)
        #expect(abs(b.heading - (.pi - 0.2)) < 1e-12)
        b.heading = 0.3
        #expect(b.dir == 1 && abs(b.climb - 0.3) < 1e-12)
    }

    @Test("even the quickest turn lasts long enough to show a face")
    func quickestTurnShowsItsFace() throws {
        var b = SwimBody(x: 0.5, y: 0.5, dir: 1, speed: 0.05, turnRate: 3, energy: 1.12, homeY: 0.5)
        AquariumSteering.step(&b, dt: 1.0 / 30, t: 20, seed: 4,
                              context: SwimContext(bounds: Self.tank, food: (0.2, 0.5), startled: true,
                                                   pace: .lively, tempo: 1.6))
        let started = try #require(b.turn)
        #expect(started.kind == .startle)
        #expect(started.duration == AquariumTurn.shortestTurn)
        var poses: [AquariumTurn.Pose] = []
        var t = 20.0
        while b.turn != nil {
            poses.append(AquariumTurn.pose(of: b))
            t += 1.0 / 30
            AquariumSteering.step(&b, dt: 1.0 / 30, t: t, seed: 4,
                                  context: SwimContext(bounds: Self.tank, food: (0.2, 0.5), startled: true,
                                                       pace: .lively, tempo: 1.6))
        }
        let sawFace = poses.contains { $0.isFront }
        #expect(sawFace, "it passed through the head-on frame")
        for (a, next) in zip(poses, poses.dropFirst()) {
            #expect(abs(next.c - a.c) <= 0.4, "the side-on share jumped \(next.c - a.c) in a frame")
        }
    }

    @Test("a working fish potters: at most three turns a minute at the kelp, the survey and the wreck")
    func rangingStationsTurnCalmly() {
        // The view's own station shapes: a kelp strand, two landmarks
        // across the tank, and the wreck.
        let stations: [(TankStation, AquariumStations.Anchor)] = [
            (.kelp, AquariumStations.Anchor(x: 0.4, y: 0.65, spanX: 26.0 / 900, spanY: 0.22)),
            (.survey, AquariumStations.Anchor(x: 0.3, y: 0.5, spanX: 30.0 / 900, spanY: 0.05,
                                              altX: 0.65, altY: 0.5)),
            (.wreck, AquariumStations.Anchor(x: 0.55, y: 0.6, spanX: 60.0 / 900, spanY: 0.06)),
        ]
        for (station, anchor) in stations {
            for fishSpeed in [0.05, 0.1, 0.14] {
                for seed: UInt64 in [0x1234_5678_9ABC, 0xFEED_BEEF_1234] {
                    var b = AquariumSteering.spawn(seed: seed, fishSpeed: fishSpeed, direction: 1,
                                                   homeY: anchor.y, length: 0.065)
                    b.x = anchor.x - 0.1
                    var t = 0.0
                    var turns: [Double] = []
                    var distances: [Double] = []
                    for _ in 0..<(30 * 60) {
                        t += 1.0 / 30
                        let goal = AquariumStations.target(for: station, anchor: anchor, t: t, seed: seed)
                        let d = hypot(goal.x - b.x, goal.y - b.y)
                        let before = b.dir
                        AquariumSteering.step(&b, dt: 1.0 / 30, t: t, seed: seed,
                                              context: SwimContext(bounds: Self.tank, wander: 0.35,
                                                                   effort: AquariumStations.effort(for: station,
                                                                                                   distance: d),
                                                                   station: goal))
                        if b.dir != before { turns.append(t) }
                        distances.append(d)
                    }
                    let what = "\(station) at speed \(fishSpeed)"
                    #expect(turns.count <= 3, "\(what): \(turns.count) turns in a minute")
                    for (a, later) in zip(turns, turns.dropFirst()) {
                        #expect(later - a >= AquariumStations.turnCooldown, "\(what): turns \(later - a) s apart")
                    }
                    if station == .kelp {
                        // It works the strand, rising and sinking with it.
                        let mean = distances.dropFirst(30 * 10).reduce(0, +) / Double(distances.count - 300)
                        #expect(mean < AquariumStations.arriveRadius, "\(what): mean distance \(mean)")
                    }
                }
            }
        }
    }

    @Test("food and work outrank the school: a mate behind never turns a fish from its meal")
    func schoolWaitsForFood() {
        var fed = SwimBody(x: 0.5, y: 0.5, dir: 1, speed: 0.04, turnRate: 2.4, energy: 1, homeY: 0.5)
        var working = fed
        var t = 10.0
        for _ in 0..<(30 * 2) {
            t += 1.0 / 30
            AquariumSteering.step(&fed, dt: 1.0 / 30, t: t, seed: 3,
                                  context: SwimContext(bounds: Self.tank, food: (0.8, 0.5),
                                                       school: (0.1, 0.5), wander: 0))
            AquariumSteering.step(&working, dt: 1.0 / 30, t: t, seed: 3,
                                  context: SwimContext(bounds: Self.tank, school: (0.1, 0.5), wander: 0,
                                                       station: (0.7, 0.5)))
            #expect(fed.turn == nil && fed.dir == 1, "the food ahead wins")
            #expect(working.turn == nil && working.dir == 1, "the work ahead wins")
        }
        #expect(fed.x > 0.55)
    }
}
