import Foundation
import SwiftUI
import Testing
import JRBarCore
@testable import JRBarApp

/// The turn as the tank lays it out (docs/TOYS.md §Aquarium, Swimming):
/// stepped through the real steering and `layout(of:)` a frame at a
/// time, nothing ever pops — not through a U-turn, not when an ask comes
/// and goes, not when a left-facing fish leaves, not round a fry's orbit
/// and not when a pet's loop comes round. The facing only changes inside
/// the head-on frame.
@Suite("Aquarium turn layout")
@MainActor
struct AquariumTurnLayoutTests {
    private let size = CGSize(width: 900, height: 560)
    private let dt = 1.0 / 30
    /// A fixed frame clock well away from zero, as the wall clock is.
    private let t0 = 1_800_000_000.0

    private func makeFish(_ id: String, state: FishState = .swimming, species: FishSpecies = .clownfish,
                          direction: Double = 1, since: Double) -> Fish {
        Fish(id: id, label: id, providerID: "claude", state: state, lane: 0.4, speed: 0.1,
             direction: direction, stateSince: Date(timeIntervalSince1970: since),
             enteredAt: .distantPast, species: species)
    }

    private func makeTank(_ fish: [Fish]) -> AquariumView {
        AquariumView(fixture: AquariumView.Fixture(fish: fish, night: 0))
    }

    /// One frame of the live timeline: the steering step, then the
    /// layout, then the draw's bookkeeping (where the fish was drawn).
    private func frame(_ tank: AquariumView, _ roster: [Fish], _ fish: Fish, t: Double) -> AquariumView.Layout {
        let now = Date(timeIntervalSince1970: t)
        tank.stepSwim(roster, in: size, t: t, now: now)
        let l = tank.layout(of: fish, in: size, at: t, now: now)
        tank.motion.swim.record(fish, layout: l, t: t)
        return l
    }

    /// Frame to frame: no step bigger than the motion's own speed allows
    /// (`speed` points a second, or when nil, half again the larger of the
    /// neighbouring steps — a pop is a spike above both), the pitch and the
    /// side-on share never jump, and the facing changes only head-on. A
    /// quick turn for food (0.55 s) comes round up to `yawStep` a frame.
    private func expectSmooth(_ frames: [AquariumView.Layout], speed: Double?, _ what: String,
                              yawStep: Double = 0.25) {
        let steps = zip(frames, frames.dropFirst()).map { (a: $0, b: $1) }
        let moved: [Double] = steps.map { hypot($0.b.x - $0.a.x, $0.b.y - $0.a.y) }
        for (i, step) in steps.enumerated() {
            let (a, b) = step
            let dx = abs(b.x - a.x), dy = abs(b.y - a.y)
            let allowed: Double
            if let speed {
                allowed = 1.5 * speed * dt + 2
            } else {
                let before = i > 0 ? moved[i - 1] : 0
                let after = i + 1 < moved.count ? moved[i + 1] : 0
                allowed = 1.5 * max(before, after) + 2
            }
            #expect(dx <= allowed && dy <= allowed, "\(what): frame \(i) moved \(dx), \(dy) (allowed \(allowed))")
            #expect(abs(b.pitch - a.pitch) <= 0.2, "\(what): frame \(i) pitch jumped \(b.pitch - a.pitch)")
            #expect(abs(b.yawCos - a.yawCos) <= yawStep, "\(what): frame \(i) turned \(b.yawCos - a.yawCos) at once")
            if a.facing != b.facing {
                #expect(abs(a.yawCos) <= AquariumTurn.frontCut && abs(b.yawCos) <= AquariumTurn.frontCut,
                        "\(what): frame \(i) flipped side-on (\(a.yawCos) → \(b.yawCos))")
            }
        }
    }

    /// The head-on frame keeps one mirror from the cut in to the cut out:
    /// nothing worn or drawn on it hops sides mid-face.
    private func expectSteadyFront(_ frames: [AquariumView.Layout], _ what: String) {
        for (i, pair) in zip(frames, frames.dropFirst()).enumerated() where pair.0.front && pair.1.front {
            #expect(pair.0.frontFacing == pair.1.frontFacing, "\(what): frame \(i) mirrored head-on")
        }
    }

    @Test("a U-turn never pops and flips only head-on")
    func uTurn() {
        let fish = makeFish("turner", since: t0 - 100)
        let tank = makeTank([fish])
        var t = t0
        _ = frame(tank, [fish], fish, t: t)
        // Put it near the right glass, heading for it.
        var body = tank.motion.bodies[fish.id]!
        body.x = 0.78
        body.dir = 1
        tank.motion.bodies[fish.id] = body
        var frames: [AquariumView.Layout] = []
        var sawFront = false
        for _ in 0..<(30 * 8) {
            t += dt
            let l = frame(tank, [fish], fish, t: t)
            if l.front { sawFront = true }
            frames.append(l)
        }
        let b = tank.motion.bodies[fish.id]!
        let speed = b.speed * b.energy * size.width * 1.1 + 6
        expectSmooth(frames, speed: speed, "U-turn")
        expectSteadyFront(frames, "U-turn")
        #expect(sawFront, "the turn passes through the head-on frame")
        #expect(zip(frames, frames.dropFirst()).contains { $0.facing != $1.facing }, "it turned round")
        // Anchors off the nose slide round rather than jump.
        let length = tank.drawnSize(of: fish, layout: frames[0]).length
        for (a, b) in zip(frames, frames.dropFirst()) {
            for k in [0.18, 0.30, 0.45] {
                let pa = a.along(k, length: length), pb = b.along(k, length: length)
                #expect(hypot(pb.x - pa.x, pb.y - pa.y) <= 0.25 * length)
            }
        }
    }

    @Test("an ask rises, waits half-turned and level, and swims back down")
    func askAndAnswer() {
        var fish = makeFish("asker", since: t0 - 100)
        let tank = makeTank([fish])
        var t = t0
        var frames: [AquariumView.Layout] = []
        for _ in 0..<60 { t += dt; frames.append(frame(tank, [fish], fish, t: t)) }
        fish.state = .surfacing
        fish.stateSince = Date(timeIntervalSince1970: t)
        for _ in 0..<(30 * 4) { t += dt; frames.append(frame(tank, [fish], fish, t: t)) }
        let waiting = frames[frames.count - 1]
        let held = AquariumTurn.pose(p: AquariumTurn.askHold, dir0: 1, arc: 0).c
        #expect(abs(abs(waiting.yawCos) - held) < 1e-6, "it holds the turn at the ask pose")
        #expect(abs(waiting.pitch) < 1e-6, "level")
        #expect(waiting.y < 60, "up at the glass")
        fish.state = .swimming
        fish.stateSince = Date(timeIntervalSince1970: t)
        let answeredAt = frames.count
        for _ in 0..<(30 * 4) { t += dt; frames.append(frame(tank, [fish], fish, t: t)) }
        expectSmooth(frames, speed: nil, "ask")
        // Answering doesn't pop the fish's size, its head or its tail:
        // the ask's size-up and half-turn settle away.
        let asked = frames[answeredAt - 1], answered = frames[answeredAt]
        #expect(abs(answered.scale / asked.scale - 1) < 0.02, "size \(asked.scale) → \(answered.scale)")
        #expect(abs(answered.lead - asked.lead) < 0.05, "head \(asked.lead) → \(answered.lead)")
        #expect(abs(answered.wag - asked.wag) < 0.1, "tail \(asked.wag) → \(answered.wag)")
        // Answered, it swims back down from the glass instead of jumping.
        #expect(frames[answeredAt].y < 70)
        #expect(frames[frames.count - 1].y > frames[answeredAt].y)
    }

    @Test("the ask pose doesn't depend on where the heading froze")
    func askPoseIsItsOwn() {
        var poses: [AquariumView.Layout] = []
        for (climb, midTurn) in [(0.0, false), (0.4, false), (-0.4, false), (0.0, true)] {
            var fish = makeFish("ask-\(climb)-\(midTurn)", since: t0 - 100)
            let tank = makeTank([fish])
            var t = t0
            _ = frame(tank, [fish], fish, t: t)
            var body = tank.motion.bodies[fish.id]!
            body.dir = 1
            body.climb = climb
            body.pitch = climb
            if midTurn {
                body.turn = SwimTurn(kind: .cruise, start: t, duration: 0.9, from: 1, arc: 1, progress: 0.35)
            }
            tank.motion.bodies[fish.id] = body
            t += dt
            _ = frame(tank, [fish], fish, t: t)
            fish.state = .surfacing
            fish.stateSince = Date(timeIntervalSince1970: t)
            var last = AquariumView.Layout()
            for _ in 0..<(30 * 3) { t += dt; last = frame(tank, [fish], fish, t: t) }
            poses.append(last)
        }
        for pose in poses {
            #expect(abs(pose.pitch - poses[0].pitch) < 1e-9)
            #expect(abs(pose.yawCos - poses[0].yawCos) < 1e-9)
        }
    }

    @Test("a fish facing left turns round before it leaves")
    func leavingFacingLeft() {
        var fish = makeFish("leaver", direction: -1, since: t0 - 100)
        let tank = makeTank([fish])
        var t = t0
        var frames: [AquariumView.Layout] = []
        _ = frame(tank, [fish], fish, t: t)
        var body = tank.motion.bodies[fish.id]!
        body.dir = -1
        body.turn = nil
        body.x = 0.5
        tank.motion.bodies[fish.id] = body
        for _ in 0..<30 { t += dt; frames.append(frame(tank, [fish], fish, t: t)) }
        #expect(frames[frames.count - 1].facing == -1)
        fish.state = .leaving
        fish.stateSince = Date(timeIntervalSince1970: t)
        for _ in 0..<(30 * 2) { t += dt; frames.append(frame(tank, [fish], fish, t: t)) }
        expectSmooth(frames, speed: nil, "leaving")
        expectSteadyFront(frames, "leaving")
        #expect(frames[frames.count - 1].facing == 1, "it heads out facing right")
    }

    @Test("a fry orbits without ever mirroring")
    func fryOrbit() {
        let parent = makeFish("parent", since: t0 - 100)
        var fry = makeFish("fry", since: t0 - 100)
        fry.isFry = true
        fry.anchorID = parent.id
        let tank = makeTank([parent, fry])
        var t = t0
        var frames: [AquariumView.Layout] = []
        var parentFrames: [AquariumView.Layout] = []
        for _ in 0..<(30 * 20) {
            t += dt
            let pl = frame(tank, [parent, fry], parent, t: t)
            parentFrames.append(pl)
            let l = tank.layout(of: fry, in: size, at: t, now: Date(timeIntervalSince1970: t),
                                parent: (parent, pl))
            frames.append(l)
        }
        // A fry's orbit is up to 56 pt at under a turn a second, on top
        // of its parent's swim.
        expectSmooth(frames, speed: 56 * 0.9 + 60, "fry")
        #expect(zip(frames, frames.dropFirst()).contains { $0.facing != $1.facing }, "it came round")
    }

    @Test("moving the Swimming speed slider never jumps a fry or a sweeping fish")
    func swimSpeedMovesSmoothly() {
        // Frame by frame, the slider a notch further every second, the
        // way a drag moves it.
        func tuned(_ second: Int) -> AquariumSettings {
            var tuning = AquariumSettings()
            tuning.swimSpeed = min(1.6, 0.8 + 0.05 * Double(second))
            return tuning
        }
        // A fry circling its parent, and its parent dozing off halfway.
        let parent = makeFish("slider-parent", since: t0 - 100)
        var fry = makeFish("slider-fry", since: t0 - 100)
        fry.isFry = true
        fry.anchorID = parent.id
        let tank = makeTank([parent, fry])
        var t = t0
        var frames: [AquariumView.Layout] = []
        for i in 0..<(30 * 16) {
            t += dt
            if i == 30 * 8 { fry.state = .idling }
            let pl = frame(tank, [parent, fry], parent, t: t)
            tank.motion.swim.settings = tuned(i / 30)
            frames.append(tank.layout(of: fry, in: size, at: t, now: Date(timeIntervalSince1970: t),
                                      parent: (parent, pl)))
        }
        expectSmooth(frames, speed: 56 * 0.9 * 1.6 + 60, "fry")
        // A fish on the patrol sweep (no steering body yet, a fixture's).
        let sweeper = makeFish("slider-sweeper", since: t0 - 100)
        let sweep = makeTank([sweeper])
        t = t0
        var swept: [AquariumView.Layout] = []
        for i in 0..<(30 * 16) {
            t += dt
            let tuning = tuned(i / 30)
            sweep.motion.swim.settings = tuning
            sweep.motion.swim.retime(to: tuning.swimSpeed, at: t)
            swept.append(sweep.layout(of: sweeper, in: size, at: t, now: Date(timeIntervalSince1970: t)))
        }
        // At the quick end of the slider a turn is short, so it comes
        // round a little further each frame.
        expectSmooth(swept, speed: 220, "sweeper", yawStep: 0.34)
    }

    @Test("the turtle, the tetras and the axolotl loop without a jump")
    func petsLoop() {
        let tank = makeTank([])
        func layouts(_ poses: [PetPose]) -> [AquariumView.Layout] {
            poses.map { p in
                var l = AquariumView.Layout()
                l.x = p.x
                l.y = p.y
                l.yawCos = p.c
                return l
            }
        }
        // A whole turtle sweep and a whole axolotl patrol, wraps included.
        let turtle = layouts((0...(30 * 92)).map { tank.seaTurtlePose(size: size, t: t0 + Double($0) * dt) })
        expectSmooth(turtle, speed: size.width / 45, "turtle")
        #expect(Set(turtle.map(\.facing)).count == 2)
        let axolotl = layouts((0...(30 * 162)).map { tank.axolotlPose(size: size, t: t0 + Double($0) * dt).pose })
        expectSmooth(axolotl, speed: 20, "axolotl")
        #expect(Set(axolotl.map(\.facing)).count == 2)
        // The loop comes home: where it ends is where it began.
        let start = tank.axolotlPose(size: size, t: 160 * 11_250_000).pose
        let end = tank.axolotlPose(size: size, t: 160 * 11_250_001 - 0.001).pose
        #expect(abs(start.x - end.x) < 0.5 && abs(start.c - end.c) < 0.01)
        // Seventy seconds of the school: two reversals, every tetra.
        let school = (0...(30 * 72)).map { tank.tetraPoses(size: size, t: t0 + Double($0) * dt) }
        for i in 0..<7 {
            let tetra = layouts(school.map { $0[i] })
            expectSmooth(tetra, speed: 125, "tetra \(i)")
            #expect(Set(tetra.map(\.facing)).count == 2)
        }
        // They don't all come round on the same frame.
        let flips = (0..<7).map { i in
            Array(zip(school, school.dropFirst())).firstIndex { ($0[i].c >= 0) != ($1[i].c >= 0) } ?? -1
        }
        #expect(Set(flips).count > 1)
    }

    @Test("the hover box matches the drawn size at every stage and fish size")
    func hitBoxFollowsTheDrawing() {
        let fish = makeFish("boxed", since: t0 - 100)
        for stage in 0...2 {
            for scale in [0.6, 1.0, 1.6] {
                var settings = AquariumSettings()
                settings.fishScale = scale
                let tank = AquariumView(fixture: AquariumView.Fixture(
                    fish: [fish], game: AquariumGame(pets: [fish.id: FishCare(stage: stage)]),
                    swimSettings: settings))
                var l = AquariumView.Layout()
                l.x = 300
                l.y = 200
                let drawn = tank.drawnSize(of: fish, layout: l).length
                let box = tank.hitBox(of: fish, layout: l)
                #expect(abs(box.width - drawn * 1.24) < 1e-9)
                let bare = AquariumView.fishBaseLength * fish.species.sizeScale * [0.74, 0.92, 1.12][stage]
                #expect(abs(drawn - bare * scale) < 1e-9, "stage \(stage) at \(scale)×")
            }
        }
    }

    @Test("a busy tank for two minutes: calm turns, never a pop")
    func busyTankSoak() {
        // Two schools and a loner, the way sessions fill a real tank.
        let roster: [Fish] = [
            ("claude-1", "claude", FishSpecies.clownfish), ("claude-2", "claude", .clownfish),
            ("claude-3", "claude", .clownfish), ("codex-1", "codex", .shark), ("codex-2", "codex", .shark),
            ("gemini-1", "gemini", .angelfish),
        ].enumerated().map { i, spec in
            Fish(id: spec.0, label: spec.0, providerID: spec.1, state: .swimming,
                 lane: 0.2 + 0.12 * Double(i), speed: 0.05 + 0.018 * Double(i),
                 direction: i % 2 == 0 ? 1 : -1, stateSince: Date(timeIntervalSince1970: t0 - 100),
                 enteredAt: .distantPast, species: spec.2)
        }
        let tank = makeTank(roster)
        var t = t0
        var frames: [String: [AquariumView.Layout]] = [:]
        for _ in 0..<(30 * 120) {
            t += dt
            let now = Date(timeIntervalSince1970: t)
            tank.stepSwim(roster, in: size, t: t, now: now)
            for fish in roster {
                let l = tank.layout(of: fish, in: size, at: t, now: now)
                tank.motion.swim.record(fish, layout: l, t: t)
                frames[fish.id, default: []].append(l)
            }
        }
        for fish in roster {
            let run = frames[fish.id] ?? []
            let b = tank.motion.bodies[fish.id]!
            expectSmooth(run, speed: b.speed * b.energy * size.width * 2 + 8, fish.id)
            expectSteadyFront(run, fish.id)
            let flips = zip(run, run.dropFirst()).filter { $0.facing != $1.facing }.count
            #expect(flips <= 8, "\(fish.id) reversed \(flips) times in two minutes")
            #expect(flips >= 1, "\(fish.id) still crosses the tank")
        }
    }

    @Test("a finished run's meal: every eater keeps its pellet, swims over without a pop and eats at its mouth")
    func completionMealChase() {
        var leaver = makeFish("meal-leaver", since: t0 - 100)
        let eaters: [Fish] = (0..<4).map { i in
            Fish(id: "meal-eater-\(i)", label: "eater", providerID: "claude", state: .swimming,
                 lane: 0.2 + 0.15 * Double(i), speed: 0.08 + 0.02 * Double(i), direction: 1,
                 stateSince: Date(timeIntervalSince1970: t0 - 100), enteredAt: .distantPast,
                 species: i % 2 == 0 ? .clownfish : .shark)
        }
        var roster = [leaver] + eaters
        let tank = makeTank(roster)
        var t = t0
        tank.stepSwim(roster, in: size, t: t, now: Date(timeIntervalSince1970: t))
        var lb = tank.motion.bodies[leaver.id]!
        lb.x = 0.5
        lb.y = 0.35
        tank.motion.bodies[leaver.id] = lb
        // Spread about, two of them facing away from where the food lands.
        for (i, eater) in eaters.enumerated() {
            var b = tank.motion.bodies[eater.id]!
            b.x = [0.25, 0.72, 0.4, 0.62][i]
            b.y = [0.55, 0.5, 0.7, 0.66][i]
            b.dir = [-1.0, 1, 1, -1][i]
            tank.motion.bodies[eater.id] = b
        }
        for _ in 0..<3 {
            t += dt
            tank.stepSwim(roster, in: size, t: t, now: Date(timeIntervalSince1970: t))
        }
        leaver.state = .leaving
        leaver.stateSince = Date(timeIntervalSince1970: t)
        roster = [leaver] + eaters
        var plans: [[String?]] = []
        var runs: [String: [AquariumView.Layout]] = [:]
        var eaten = 0
        var gone: [Int: Double] = [:]
        for _ in 0..<(30 * 9) {
            t += dt
            let now = Date(timeIntervalSince1970: t)
            let age = t - leaver.stateSince.timeIntervalSince1970
            tank.stepSwim(roster, in: size, t: t, now: now)
            var layouts: [String: AquariumView.Layout] = [:]
            for fish in roster where !fish.isRetired(at: now) {
                layouts[fish.id] = tank.layout(of: fish, in: size, at: t, now: now)
            }
            let meals = tank.completionMeals(in: size, now: now, roster: roster)
            tank.applyPursuits(meals, to: &layouts, now: now)
            for fish in roster { if let l = layouts[fish.id] { tank.motion.swim.record(fish, layout: l, t: t) } }
            for eater in eaters { runs[eater.id, default: []].append(layouts[eater.id]!) }
            guard let meal = meals.first else { continue }
            let assigned = meal.pellets.map(\.eater)
            if plans.last != assigned { plans.append(assigned) }
            for (i, pellet) in meal.pellets.enumerated() {
                guard let id = pellet.eater, gone[i] == nil,
                      tank.motion.swim.meals[leaver.id]?.eatenAt[i] != nil else { continue }
                // Eaten this frame: the drawn mouth is at the food.
                gone[i] = pellet.gone
                eaten += 1
                let fish = eaters.first { $0.id == id }!
                let l = layouts[id]!
                let length = tank.drawnSize(of: fish, layout: l).length
                let mouth = l.along(0.42, length: length)
                let food = pellet.position(at: age)
                let off = hypot(l.x + mouth.x - food.x, l.y + mouth.y - food.y)
                #expect(off < 0.5 * length, "\(id) ate from \(off) pt away")
                #expect(pellet.gone <= age + 1e-9 && pellet.gone > age - dt - 1e-9)
            }
        }
        #expect(plans.count == 1, "the eaters never swapped: \(plans)")
        #expect(eaten >= 2, "the eaters got there (\(eaten) eaten)")
        for eater in eaters {
            let b = tank.motion.bodies[eater.id]!
            let run = runs[eater.id] ?? []
            expectSmooth(run, speed: b.speed * b.energy * size.width * 2 + 8, eater.id, yawStep: 0.34)
            expectSteadyFront(run, eater.id)
        }
    }

    @Test("a finished run's eaters are the fish nearest where its pellets really fall")
    func completionMealPicksTheNearest() throws {
        var leaver = makeFish("near-leaver", since: t0 - 100)
        let eaters: [Fish] = (0..<3).map { i in
            Fish(id: "near-eater-\(i)", label: "eater", providerID: "codex", state: .swimming,
                 lane: 0.3, speed: 0.08, direction: 1, stateSince: Date(timeIntervalSince1970: t0 - 100),
                 enteredAt: .distantPast, species: .clownfish)
        }
        var roster = [leaver] + eaters
        let tank = makeTank(roster)
        var t = t0
        tank.stepSwim(roster, in: size, t: t, now: Date(timeIntervalSince1970: t))
        // The leaver swims off from where its state began: by the time it
        // finishes it is far across the tank.
        let began = try #require(tank.motion.anchors[leaver.id])
        var lb = tank.motion.bodies[leaver.id]!
        lb.x = began.x < 0.5 ? 0.8 : 0.2
        lb.y = 0.3
        tank.motion.bodies[leaver.id] = lb
        // One mate waits where the leaver started, the others near where
        // it really is now.
        for (i, eater) in eaters.enumerated() {
            var b = tank.motion.bodies[eater.id]!
            b.x = i == 0 ? began.x : lb.x + (i == 1 ? -0.06 : 0.06)
            b.y = i == 0 ? began.y : 0.42
            tank.motion.bodies[eater.id] = b
        }
        t += dt
        leaver.state = .leaving
        leaver.stateSince = Date(timeIntervalSince1970: t)
        roster = [leaver] + eaters
        let spots = tank.motion.bodies
        let now = Date(timeIntervalSince1970: t)
        tank.stepSwim(roster, in: size, t: t, now: now)
        let meal = try #require(tank.completionMeals(in: size, now: now, roster: roster).first)
        // The meal falls where the leaver was when it finished.
        #expect(abs(meal.spawn.x - lb.x * size.width) < 1 && abs(meal.spawn.y - lb.y * size.height) < 1,
                "the meal fell at \(meal.spawn), the leaver was at \(lb.x * size.width), \(lb.y * size.height)")
        // Each pellet went to the nearest mate still free, measured from
        // where the mates really were.
        var free = Set(eaters.map(\.id))
        for (i, pellet) in meal.pellets.enumerated() where !free.isEmpty {
            func gap(_ id: String) -> Double {
                let b = spots[id]!
                return hypot(b.x * size.width - pellet.rest.x, b.y * size.height - pellet.rest.y)
            }
            let nearest = free.min { gap($0) < gap($1) }!
            #expect(pellet.eater == nearest, "pellet \(i) went to \(pellet.eater ?? "nobody"), not \(nearest)")
            free.remove(nearest)
        }
    }

    @Test("at the biggest Fish size no fin pokes out of the top of the tank")
    func bigFishStayInTheWater() {
        for species in [FishSpecies.shark, .angelfish, .clownfish] {
            var fish = Fish(id: "big-\(species.rawValue)", label: "big", providerID: "claude", state: .swimming,
                            lane: 0, speed: 0.1, direction: 1, stateSince: Date(timeIntervalSince1970: t0 - 100),
                            enteredAt: .distantPast, species: species)
            var settings = AquariumSettings()
            settings.fishScale = AquariumSettings.fishScaleRange.upperBound
            let tank = AquariumView(fixture: AquariumView.Fixture(
                fish: [fish], game: AquariumGame(pets: [fish.id: FishCare(stage: 2)]), night: 0,
                swimSettings: settings))
            var t = t0
            var top = Double.infinity
            for i in 0..<(30 * 24) {
                t += dt
                if i == 30 * 20 {
                    fish.state = .surfacing
                    fish.stateSince = Date(timeIntervalSince1970: t)
                }
                let l = frame(tank, [fish], fish, t: t)
                top = min(top, l.y - tank.drawnSize(of: fish, layout: l).above)
            }
            #expect(top >= -0.5, "\(species): the fins reached \(top) pt")
        }
    }

    @Test("a barrel roll is decided at its start: waited out through a turn, or finished through one")
    func rollIsCommitted() throws {
        // A fish that rolls, and the moment its next roll begins.
        var found: (fish: Fish, start: Double)?
        for n in 0..<200 where found == nil {
            let fish = makeFish("roller-\(n)", since: t0 - 100)
            var probe = t0
            for _ in 0..<(30 * 120) {
                probe += dt
                if let p = AquariumBehavior.flourishProgress(seed: fish.seed, at: probe), p < 0.03 {
                    found = (fish, probe - p * AquariumBehavior.flourishDuration)
                    break
                }
            }
        }
        let roller = try #require(found)
        for turnAt in [-0.15, 0.3] {
            let tank = makeTank([roller.fish])
            var t = roller.start - 1
            _ = frame(tank, [roller.fish], roller.fish, t: t)
            var body = tank.motion.bodies[roller.fish.id]!
            body.x = 0.5
            body.y = 0.5
            tank.motion.bodies[roller.fish.id] = body
            var rolls: [Double] = []
            var turned = false
            while t < roller.start + 2.5 {
                t += dt
                if !turned, t >= roller.start + turnAt {
                    turned = true
                    var b = tank.motion.bodies[roller.fish.id]!
                    b.turn = SwimTurn(kind: .cruise, start: t, duration: 0.9, from: b.dir, arc: 1,
                                      progress: turnAt < 0 ? 0.5 : 0)
                    tank.motion.bodies[roller.fish.id] = b
                }
                rolls.append(frame(tank, [roller.fish], roller.fish, t: t).roll)
            }
            for (a, b) in zip(rolls, rolls.dropFirst()) {
                #expect(abs(b - a) <= 0.2, "the roll jumped \(a) → \(b)")
            }
            if turnAt < 0 {
                #expect(rolls.allSatisfy { $0 == 1 }, "a roll due mid-turn is waited out, not shown half done")
            } else {
                #expect((rolls.min() ?? 1) < -0.9, "a started roll goes belly-up and on round")
            }
        }
    }
}
