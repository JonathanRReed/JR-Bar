import Testing
@testable import JRBarApp

@Suite("Screen Bar crossfade policy")
struct ScreenBarCrossfadeTests {
    @Test func aQueuedFadeUsesTheLiveReduceMotionSetting() {
        var fade = ScreenBarCrossfade()
        fade.arm(over: 1.2, reduceMotion: false)
        #expect(fade.duration == 1.2)

        let cancelled = fade.consume(reduceMotion: true)
        #expect(cancelled == nil)
        #expect(fade.duration == nil)
        let replay = fade.consume(reduceMotion: false)
        #expect(replay == nil,
                "turning motion back on cannot replay a cancelled fade")
    }

    @Test func aFadeIsConsumedOnce() {
        var fade = ScreenBarCrossfade()
        fade.arm(over: 1.2, reduceMotion: false)

        let first = fade.consume(reduceMotion: false)
        #expect(first == 1.2)
        let second = fade.consume(reduceMotion: false)
        #expect(second == nil)
    }

    @Test func reducedMotionDoesNotArmAFade() {
        var fade = ScreenBarCrossfade()
        fade.arm(over: 1.2, reduceMotion: true)

        #expect(fade.duration == nil)
        let consumed = fade.consume(reduceMotion: false)
        #expect(consumed == nil)
    }

    @Test func aNewRequestReplacesTheQueuedFade() {
        var fade = ScreenBarCrossfade()
        fade.arm(over: 1.2, reduceMotion: false)
        fade.arm(over: 0.16, reduceMotion: false)

        let consumed = fade.consume(reduceMotion: false)
        #expect(consumed == 0.16)
    }
}
