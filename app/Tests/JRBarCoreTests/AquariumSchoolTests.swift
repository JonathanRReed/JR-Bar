import Foundation
import Testing
@testable import JRBarCore

/// `SchoolFlock` is the little schools' motion: boids on a fixed step,
/// bounded per fish and per frame, that never mirror and never stray.
@Suite("Aquarium school flock")
struct AquariumSchoolTests {
    private let bounds = SchoolFlock.Bounds(minX: 0, minY: 0, maxX: 900, maxY: 500)
    private let step = SchoolFlock.step
    private let t0 = 1_800_000_000.0

    /// A school of `count` fish spawned round `at`, `spread` points apart.
    private func school(_ count: Int, at: (x: Double, y: Double), spread: Double,
                        t: Double) -> SchoolFlock {
        var flock = SchoolFlock()
        for i in 0..<count {
            let angle = Double(i) * 2.4
            flock.join("fish-\(i)", at: t,
                       spawn: { (at.x + cos(angle) * spread * Double(i % 3 + 1) / 3,
                                 at.y + sin(angle) * spread * Double(i % 3 + 1) / 3) },
                       facing: i.isMultiple(of: 2) ? 1 : -1)
        }
        return flock
    }

    /// Run `seconds` of frames, every member asked for each frame.
    private func run(_ flock: inout SchoolFlock, from t: Double, seconds: Double,
                     goal: (x: Double, y: Double), obstacles: [SchoolFlock.Obstacle] = [],
                     tuning: SchoolFlock.Tuning = .fry,
                     each: (SchoolFlock) -> Void = { _ in }) -> Double {
        var now = t
        for _ in 0..<Int(seconds / step) {
            now += step
            for member in flock.members {
                flock.join(member.id, at: now, spawn: { (0, 0) }, facing: 1)
            }
            flock.advance(to: now, goal: goal, bounds: bounds, obstacles: obstacles, tuning: tuning)
            each(flock)
        }
        return now
    }

    @Test("fish spawned on top of each other spread to a comfortable gap")
    func separates() {
        var flock = school(6, at: (400, 250), spread: 1, t: t0)
        flock.advance(to: t0, goal: (400, 250), bounds: bounds, obstacles: [], tuning: .fry)
        _ = run(&flock, from: t0, seconds: 4, goal: (400, 250))
        let members = flock.members
        var closest = Double.infinity
        for i in members.indices {
            for j in members.indices where j > i {
                closest = min(closest, hypot(members[i].x - members[j].x, members[i].y - members[j].y))
            }
        }
        #expect(closest > 5, "closest pair \(closest)")
    }

    @Test("a scattered school gathers on its goal and stays on its leash")
    func gathers() {
        var flock = school(8, at: (200, 120), spread: 160, t: t0)
        flock.advance(to: t0, goal: (500, 260), bounds: bounds, obstacles: [], tuning: .fry)
        _ = run(&flock, from: t0, seconds: 8, goal: (500, 260))
        for member in flock.members {
            let d = hypot(member.x - 500, member.y - 260)
            #expect(d < SchoolFlock.Tuning.fry.leash, "\(member.id) is \(d) from its goal")
        }
    }

    @Test("speeds stay inside the tuning, and the facing turns through head-on, never in one step")
    func capsAndTurns() {
        var flock = school(7, at: (450, 250), spread: 40, t: t0)
        flock.advance(to: t0, goal: (450, 250), bounds: bounds, obstacles: [], tuning: .tetra)
        var last = flock.members
        var turned = false
        let maxTurn = 2 / SchoolFlock.Tuning.tetra.turnTime * step + 1e-9
        // The goal swings side to side, so the school reverses.
        var now = t0
        for frame in 0..<(30 * 30) {
            now += step
            let goal = (x: 450 + 300 * sin(Double(frame) / 60), y: 250.0)
            for member in flock.members { flock.join(member.id, at: now, spawn: { (0, 0) }, facing: 1) }
            flock.advance(to: now, goal: goal, bounds: bounds, obstacles: [], tuning: .tetra)
            for (a, b) in zip(last, flock.members) {
                #expect(hypot(b.vx, b.vy) <= SchoolFlock.Tuning.tetra.maxSpeed + 1e-6)
                #expect(abs(b.facing - a.facing) <= maxTurn)
                if (a.facing >= 0) != (b.facing >= 0) {
                    turned = true
                    #expect(abs(a.facing) <= maxTurn && abs(b.facing) <= maxTurn, "flipped side-on")
                }
            }
            last = flock.members
        }
        #expect(turned, "the school came round")
    }

    @Test("they part round a bigger fish instead of swimming through it")
    func avoids() {
        let fish = SchoolFlock.Obstacle(x: 450, y: 250, radius: 24)
        var flock = school(6, at: (250, 250), spread: 20, t: t0)
        flock.advance(to: t0, goal: (650, 250), bounds: bounds, obstacles: [fish], tuning: .tetra)
        var deepest = Double.infinity
        _ = run(&flock, from: t0, seconds: 10, goal: (650, 250), obstacles: [fish], tuning: .tetra) { flock in
            for member in flock.members {
                deepest = min(deepest, hypot(member.x - fish.x, member.y - fish.y))
            }
        }
        #expect(deepest > fish.radius * 0.6, "came within \(deepest) of its centre")
        #expect(flock.members.allSatisfy { $0.x > 500 }, "and re-formed past it")
    }

    @Test("a frame pays for at most four steps; a long gap is skipped, not replayed")
    func boundedPerFrame() {
        var flock = school(5, at: (450, 250), spread: 30, t: t0)
        flock.advance(to: t0, goal: (450, 250), bounds: bounds, obstacles: [], tuning: .fry)
        let before = flock.members
        for member in before { flock.join(member.id, at: t0 + 0.5, spawn: { (0, 0) }, facing: 1) }
        flock.advance(to: t0 + 0.5, goal: (450, 250), bounds: bounds, obstacles: [], tuning: .fry)
        #expect(flock.time == t0 + 0.5, "the gap is dropped")
        let most = SchoolFlock.Tuning.fry.maxSpeed * step * Double(SchoolFlock.maxStepsPerFrame) + 1e-6
        for (a, b) in zip(before, flock.members) {
            #expect(hypot(b.x - a.x, b.y - a.y) <= most)
        }
        // A clock set back holds the school and counts from there.
        let held = flock.members
        flock.advance(to: t0 + 0.2, goal: (450, 250), bounds: bounds, obstacles: [], tuning: .fry)
        #expect(flock.members == held)
        #expect(flock.time == t0 + 0.2)
    }

    @Test("the same frames make the same school, and leavers are forgotten")
    func deterministicAndForgets() {
        func make() -> SchoolFlock {
            var flock = school(9, at: (300, 200), spread: 60, t: t0)
            flock.advance(to: t0, goal: (500, 260), bounds: bounds, obstacles: [], tuning: .fry)
            _ = run(&flock, from: t0, seconds: 3, goal: (500, 260))
            return flock
        }
        #expect(make() == make())
        var flock = make()
        let now = t0 + 3 + SchoolFlock.forgetAfter + 0.5
        flock.join("fish-0", at: now, spawn: { (0, 0) }, facing: 1)
        flock.advance(to: now, goal: (500, 260), bounds: bounds, obstacles: [], tuning: .fry)
        #expect(flock.members.map(\.id) == ["fish-0"])
    }

    @Test("a fish that stops flocking holds where it is while the rest swim on")
    func pausedMemberHolds() {
        var flock = school(4, at: (300, 200), spread: 30, t: t0)
        flock.advance(to: t0, goal: (300, 200), bounds: bounds, obstacles: [], tuning: .fry)
        let stopped = flock.join("fish-1", at: t0, spawn: { (0, 0) }, facing: 1, active: false)
        var now = t0
        for _ in 0..<60 {
            now += step
            for member in flock.members where member.id != "fish-1" {
                flock.join(member.id, at: now, spawn: { (0, 0) }, facing: 1)
            }
            flock.join("fish-1", at: now, spawn: { (0, 0) }, facing: 1, active: false)
            flock.advance(to: now, goal: (600, 300), bounds: bounds, obstacles: [], tuning: .fry)
        }
        let held = flock.member("fish-1")
        #expect(held?.x == stopped.x && held?.y == stopped.y)
        #expect((flock.member("fish-0")?.x ?? 0) > 330)
    }
}
