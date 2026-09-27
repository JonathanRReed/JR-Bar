import Foundation
import Testing
@testable import JRBarLEDS

/// Opt-in receipt for the expensive half moved off the main actor. Run with
/// `JRBAR_KEYFRAME_BENCHMARK=1 swift test --filter KeyframePlanningBenchmarkTests`.
@Suite("Keyframe planning benchmark", .serialized)
struct KeyframePlanningBenchmarkTests {
    @Test("a maximum-span easing reports render time and plan size")
    func maximumSpan() throws {
        guard ProcessInfo.processInfo.environment["JRBAR_KEYFRAME_BENCHMARK"] == "1" else { return }
        let program = try LEDSProgram.parse("#ff4d40 60s ease\n#111827 60s ease", ledCount: 8)
        let sampler = LEDSSampler(program: program, ledCount: 8)
        #expect(sampler.motionEndsAt == 120)
        let started = ContinuousClock.now
        let plan = LEDSKeyframePlan.render(sampler: sampler)
        let elapsed = started.duration(to: ContinuousClock.now)
        let rendered = try #require(plan)
        #expect(rendered.keyframeCount <= LEDSKeyframePlan.defaultMaxKeyframes)
        print("keyframe-plan span_ms=120000 leds=8 frames=\(rendered.keyframeCount) elapsed=\(elapsed)")
    }
}
