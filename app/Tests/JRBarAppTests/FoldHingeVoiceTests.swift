import Foundation
import Testing
import JRBarCore
@testable import JRBarApp

/// Fold's hinge voice: the lid's speed from raw readings, how that speed
/// sounds, and the synth staying in bounds. The engine itself only runs
/// on a moving lid; nothing here starts one.
@Suite("Fold hinge voice")
struct FoldHingeVoiceTests {
    /// Feeds `seconds` of readings at `hz`, the angle from `angle(t)`.
    private func run(_ speed: inout HingeSpeed, from t0: Double = 100, seconds: Double, hz: Double,
                     angle: (Double) -> Double) -> Double {
        var last = 0.0
        var t = 0.0
        while t <= seconds {
            last = speed.feed(angle(t), at: t0 + t)
            t += 1 / hz
        }
        return last
    }

    @Test("a still lid's wobble reads as still")
    func stillLid() {
        var speed = HingeSpeed()
        let s = run(&speed, seconds: 3, hz: 10) { t in 90 + (Int(t * 10) % 2 == 0 ? 0.5 : -0.5) }
        #expect(s == 0)
        var fast = HingeSpeed()
        #expect(run(&fast, seconds: 3, hz: 120) { t in 90 + 0.4 * sin(t * 40) } == 0)
    }

    @Test("a slow close reads its speed at either poll rate")
    func slowClose() {
        var parked = HingeSpeed()
        let at10 = run(&parked, seconds: 2, hz: 10) { 110 - 12 * $0 }
        #expect(abs(at10 - 12) < 2, "\(at10)")
        var armed = HingeSpeed()
        let at120 = run(&armed, seconds: 2, hz: 120) { 110 - 12 * $0 }
        #expect(abs(at120 - 12) < 2, "\(at120)")
    }

    @Test("stopping settles back to zero")
    func settles() {
        var speed = HingeSpeed()
        _ = run(&speed, seconds: 1, hz: 60) { 110 - 20 * $0 }
        let after = run(&speed, from: 101 + 1 / 60, seconds: 2, hz: 60) { _ in 90 }
        #expect(after < 0.5, "\(after)")
    }

    @Test("a long gap between readings starts over instead of inventing speed")
    func gap() {
        var speed = HingeSpeed()
        _ = speed.feed(100, at: 10)
        #expect(speed.feed(40, at: 15) == 0, "five seconds later is a new reading, not 12°/s")
    }

    @Test("a slow close creaks; a still lid and a quick flip stay quiet")
    func shape() {
        #expect(HingeVoiceShape.gain(speed: 0) == 0)
        #expect(HingeVoiceShape.gain(speed: 1) == 0)
        #expect(HingeVoiceShape.gain(speed: 12) == 1)
        #expect(HingeVoiceShape.gain(speed: 45) > 0 && HingeVoiceShape.gain(speed: 45) < 1)
        #expect(HingeVoiceShape.gain(speed: 120) == 0)
        #expect(HingeVoiceShape.gain(speed: .nan) == 0)
        #expect(HingeVoiceShape.clickRate(speed: 0) == 5)
        #expect(HingeVoiceShape.clickRate(speed: 10) > HingeVoiceShape.clickRate(speed: 2))
        #expect(HingeVoiceShape.clickRate(speed: 1000) == 45)
    }

    @Test("the synth is silent at zero gain and stays under its ceiling when loud")
    func synthBounds() {
        for kind in [HingeVoiceControls.Kind.creak, .rustle] {
            let controls = HingeVoiceControls()
            let synth = HingeVoiceSynth(controls: controls, sampleRate: 48_000)
            var buffer = [Float](repeating: 1, count: 4_800)
            buffer.withUnsafeMutableBufferPointer { synth.render(frames: 4_800, into: $0.baseAddress!) }
            #expect(buffer.allSatisfy { $0 == 0 }, "\(kind): silent")
            controls.set(gain: 1, rate: 24, kind: kind)
            var loud = [Float](repeating: 0, count: 48_000)
            loud.withUnsafeMutableBufferPointer { synth.render(frames: 48_000, into: $0.baseAddress!) }
            let peak = loud.map(abs).max() ?? 0
            #expect(peak > 0.01, "\(kind): audible")
            #expect(peak <= Float(HingeVoiceSynth.master) + 0.0001, "\(kind): under the ceiling")
            #expect(loud.allSatisfy { $0.isFinite })
        }
    }

    @Test("the setting defaults off and reads tolerantly")
    func setting() throws {
        #expect(FoldSettings().hingeVoice == .off)
        var on = FoldSettings()
        on.hingeVoice = .rustle
        let back = try JSONDecoder().decode(FoldSettings.self, from: JSONEncoder().encode(on))
        #expect(back.hingeVoice == .rustle)
        let junk = try JSONDecoder().decode(FoldSettings.self, from: Data(#"{"hingeVoice": "theremin"}"#.utf8))
        #expect(junk.hingeVoice == .off)
    }
}
