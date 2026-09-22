import Foundation
import Testing
@testable import JRBarCore

/// The visualizer's pure math: Goertzel band mapping, the
/// attack/release smoother, the run-gate state table, and the
/// Reduce Motion branch — no audio hardware anywhere in here.
@Suite struct NotchAudioLevelsTests {

    /// A unit-amplitude sine at `frequency`, one analysis window long.
    private func sine(_ frequency: Double,
                      count: Int = NotchAudioLevels.windowSize,
                      rate: Double = 48000) -> [Float] {
        (0..<count).map {
            Float(sin(2 * .pi * frequency * Double($0) / rate))
        }
    }

    @Test func theDrivingFrequencyWinsItsBand() {
        // A 400 Hz sine reads strongest in the 400 Hz band — and a
        // 150 Hz sine wins the low-mid slot instead. The mapping is
        // frequency-honest, not a ripple animation.
        for (frequency, expected) in [(60.0, 0), (150.0, 1), (400.0, 2),
                                      (1000.0, 3), (2500.0, 4), (6000.0, 5)] {
            let bands = NotchAudioLevels.bandLevels(
                sine(frequency), sampleRate: 48000)
            let peak = bands.indices.max(by: { bands[$0] < bands[$1] })!
            #expect(peak == expected,
                    "\(frequency) Hz should pin band \(expected), won \(peak)")
            #expect(bands[peak] > 0.5)
        }
    }

    @Test func silenceAndEmptyWindowsReadZero() {
        #expect(NotchAudioLevels.bandLevels(
            [Float](repeating: 0, count: NotchAudioLevels.windowSize),
            sampleRate: 48000).allSatisfy { $0 == 0 })
        #expect(NotchAudioLevels.bandLevels([], sampleRate: 48000)
            .allSatisfy { $0 == 0 })
        // A bad rate is a bad read — never a crash.
        #expect(NotchAudioLevels.goertzel(sine(400), frequency: 400,
                                        sampleRate: 0) == 0)
    }

    @Test func magnitudeTracksAmplitude() {
        let loud = NotchAudioLevels.goertzel(
            sine(150), frequency: 150, sampleRate: 48000)
        let quiet = NotchAudioLevels.goertzel(
            sine(150).map { $0 * 0.1 }, frequency: 150, sampleRate: 48000)
        #expect(loud > quiet * 5)
        // Off-bin energy lands lower than the matching bin.
        let offBin = NotchAudioLevels.goertzel(
            sine(6000), frequency: 150, sampleRate: 48000)
        #expect(offBin < loud * 0.5)
    }

    @Test func attackIsFastReleaseIsSlow() {
        var smoother = NotchBandSmoother()
        // Rising: 30 ms in, the bar has believed most of the hit.
        let up = smoother.update([1, 1, 1, 1, 1, 1], dt: 0.03)
        #expect(up[0] > 0.6)
        // Falling: the same step barely moves — the 250 ms tail.
        let down = smoother.update([0, 0, 0, 0, 0, 0], dt: 0.03)
        #expect(down[0] > up[0] * 0.8)
        // And over a full release window the bar dies on its own.
        var level = down[0]
        var tail = smoother
        for _ in 0..<10 {
            level = tail.update([0, 0, 0, 0, 0, 0], dt: 0.05)[0]
        }
        #expect(level < 0.1)
    }

    @Test func aShortReadingDecaysTheTail() {
        var smoother = NotchBandSmoother()
        _ = smoother.update([1, 1, 1, 1, 1, 1], dt: 0.03)
        let after = smoother.update([], dt: 0.25)
        #expect(after[5] < 0.5,
                "a dead feed must not leave a bar pinned")
    }

    @Test func theRunGateIsAStateTable() {
        #expect(NotchAudioLevels.shouldRun(mediaRowVisible: true,
                                           playing: true,
                                           settingEnabled: true))
        for (visible, playing, setting) in [
            (false, true, true), (true, false, true), (true, true, false),
        ] {
            #expect(!NotchAudioLevels.shouldRun(
                mediaRowVisible: visible, playing: playing,
                settingEnabled: setting))
        }
    }

    @Test func reduceMotionSelectsTheCrossfadePath() {
        #expect(NotchMotion.faceTransition(reduceMotion: true) == .crossfade)
        #expect(NotchMotion.faceTransition(reduceMotion: false) == .morph)
    }
}
