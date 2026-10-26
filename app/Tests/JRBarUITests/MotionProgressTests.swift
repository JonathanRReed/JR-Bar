import JRBarUI
import Testing

@Suite struct MotionProgressTests {
    @Test func nativeCurvesLandAtTheTokenDurationWithoutOvershoot() {
        for motion in JRBarTokens.Motion.allCases {
            #expect(motion.progress(at: 0) == 0)
            #expect(motion.progress(at: motion.duration) == 1)
            #expect(motion.progress(at: motion.duration * 2) == 1)
            var previous = 0.0
            for frame in 0...120 {
                let value = motion.progress(at: Double(frame) / 120 * motion.duration)
                #expect((0...1).contains(value))
                #expect(value >= previous)
                previous = value
            }
        }
    }
}
