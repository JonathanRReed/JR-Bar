import Foundation
import Testing
@testable import JRBarLEDS

/// The keyframe plan the Screen Bar hands to Core Animation must show the
/// sampler's exact codes at every keyframe, and stay close in between.
@Suite struct KeyframeTests {
    /// At its own keyframe times the plan reproduces the sampler within one
    /// code (the sampler is the firmware within one code, so the animation
    /// is within two of the strip at those instants).
    @Test(arguments: try Fixtures.programs().map(\.name))
    func planMatchesSamplerAtKeyframes(fixtureName: String) throws {
        let fixture = try #require(try Fixtures.programs().first { $0.name == fixtureName })
        let program = try LEDSProgram.parse(fixture.program, ledCount: fixture.led_count)
        let sampler = LEDSSampler(program: program, ledCount: fixture.led_count)
        let plan = try #require(LEDSKeyframePlan.render(sampler: sampler), "\(fixtureName) should keyframe")
        var worst = 0
        var checked = 0
        if let lead = plan.lead {
            for offset in lead.offsetsMs {
                worst = max(worst, LEDSKeyframePlan.maxDifference(plan.codes(atMilliseconds: offset), sampler.codes(atMilliseconds: offset)))
                checked += 1
            }
        }
        if let loop = plan.loop {
            for pass in 0..<3 {
                for offset in loop.offsetsMs where offset < loop.durationMs {
                    let t = plan.loopStartMs + pass * loop.durationMs + offset
                    worst = max(worst, LEDSKeyframePlan.maxDifference(plan.codes(atMilliseconds: t), sampler.codes(atMilliseconds: t)))
                    checked += 1
                }
            }
        }
        #expect(checked > 0 || plan.isStatic)
        #expect(worst <= 1, Comment(rawValue: "\(fixtureName): worst keyframe error \(worst) codes"))
        // The fixtures' own sample times (the firmware's) between keyframes
        // stay within the plan's tolerance.
        var between = 0
        for sample in fixture.samples {
            let got = plan.codes(atMilliseconds: sample.t_ms)
            let want = sampler.codes(atMilliseconds: sample.t_ms)
            between = max(between, LEDSKeyframePlan.maxDifference(got, want))
        }
        #expect(between <= LEDSKeyframePlan.defaultTolerance, Comment(rawValue: "\(fixtureName): worst between-keyframe error \(between) codes"))
    }

    @Test func staticProgramHasNoTracks() throws {
        let program = try LEDSProgram.parse("#ff8800")
        let plan = try #require(LEDSKeyframePlan.render(sampler: LEDSSampler(program: program)))
        #expect(plan.isStatic)
        #expect(plan.keyframeCount == 0)
        #expect(plan.codes(atMilliseconds: 5000) == Array(repeating: RGB8(r: 255, g: 136, b: 0), count: 8))
    }

    @Test func finiteProgramEndsOnItsFinalFrame() throws {
        let program = try LEDSProgram.parse("#000000\n#ffffff 1000ms linear")
        let sampler = LEDSSampler(program: program)
        let plan = try #require(LEDSKeyframePlan.render(sampler: sampler))
        #expect(plan.loop == nil)
        let lead = try #require(plan.lead)
        #expect(lead.durationMs == 1017)
        // A linear ramp keeps its ends plus the frame-boundary jump.
        #expect(lead.count <= 5, Comment(rawValue: "linear ramp kept \(lead.count) keyframes"))
        #expect(LEDSKeyframePlan.maxDifference(plan.codes(atMilliseconds: 517), sampler.codes(atMilliseconds: 517)) <= 1)
        #expect(plan.codes(atMilliseconds: 99_999) == plan.finalCodes)
        #expect(plan.finalCodes[0] == RGB8(r: 255, g: 255, b: 255))
    }

    @Test func loopingProgramRepeatsItsSteadyCycle() throws {
        let program = try LEDSProgram.parse("#ff0000 200ms linear\n#0000ff 200ms linear\nrepeat")
        let sampler = LEDSSampler(program: program, initialCodes: Array(repeating: RGB8(r: 0, g: 255, b: 0), count: 8))
        let plan = try #require(LEDSKeyframePlan.render(sampler: sampler))
        let loop = try #require(plan.loop)
        #expect(plan.loopStartMs == 400)
        #expect(loop.durationMs == 400)
        // The first pass starts from green; the steady cycle never sees it.
        #expect(plan.codes(atMilliseconds: 0)[0] == RGB8(r: 0, g: 255, b: 0))
        #expect(plan.codes(atMilliseconds: 400) == sampler.codes(atMilliseconds: 400))
        for t in [4100, 4300, 12_345] {
            #expect(LEDSKeyframePlan.maxDifference(plan.codes(atMilliseconds: t), sampler.codes(atMilliseconds: t)) <= 1, Comment(rawValue: "t=\(t)"))
        }
        // Wrapping: the end of the loop track equals its start.
        #expect(loop.frames.first == loop.frames.last)
    }

    @Test func jumpsKeepBothSides() throws {
        let program = try LEDSProgram.parse("#000000 500ms none\n#ffffff 500ms none\nrepeat")
        let sampler = LEDSSampler(program: program)
        let plan = try #require(LEDSKeyframePlan.render(sampler: sampler))
        let loop = try #require(plan.loop)
        // The jump to white happens at 500 ms into the cycle: frames at 499 and 500.
        #expect(loop.offsetsMs.contains(499))
        #expect(loop.offsetsMs.contains(500))
        #expect(plan.codes(atMilliseconds: plan.loopStartMs + 499)[0] == .black)
        #expect(plan.codes(atMilliseconds: plan.loopStartMs + 500)[0] == RGB8(r: 255, g: 255, b: 255))
    }

    @Test func busyProgramsTradeToleranceForSize() throws {
        let program = try LEDSProgram.parse("#ff0000 1s cosine\n#0000ff 1s cosine\nrepeat")
        let sampler = LEDSSampler(program: program)
        let tight = try #require(LEDSKeyframePlan.render(sampler: sampler, tolerance: 1))
        let capped = try #require(LEDSKeyframePlan.render(sampler: sampler, tolerance: 1, maxKeyframes: 24))
        #expect(tight.keyframeCount > 24)
        #expect(capped.keyframeCount <= 24)
        // A roll that cannot fit even at the loosest tolerance falls back.
        let roll = try LEDSProgram.parse("roll-left 3s ease\nrepeat")
        let rolling = LEDSSampler(program: roll, initialCodes: (0..<8).map { RGB8(r: UInt8($0 * 30), g: 255 - UInt8($0 * 30), b: 90) })
        #expect(LEDSKeyframePlan.render(sampler: rolling, tolerance: 1, maxKeyframes: 8) == nil)
    }

    @Test func oversizeProgramsFallBack() throws {
        let program = try LEDSProgram.parse("#ff0000 60s linear\n#0000ff 60s linear\n#00ff00 60s linear\nrepeat")
        let sampler = LEDSSampler(program: program)
        #expect(LEDSKeyframePlan.render(sampler: sampler) == nil)
        let short = try LEDSProgram.parse("#ff0000 1s cosine\n#0000ff 1s cosine\nrepeat")
        #expect(LEDSKeyframePlan.render(sampler: LEDSSampler(program: short), maxKeyframes: 4) == nil)
    }

    @Test func trackInterpolatesLinearly() {
        let track = LEDSKeyframeTrack(offsetsMs: [0, 100], frames: [[.black], [RGB8(r: 200, g: 100, b: 0)]])
        #expect(track.codes(atMilliseconds: 50) == [RGB8(r: 100, g: 50, b: 0)])
        #expect(track.codes(atMilliseconds: -5) == [.black])
        #expect(track.codes(atMilliseconds: 500) == [RGB8(r: 200, g: 100, b: 0)])
        #expect(track.keyTimes == [0, 1])
    }
}
