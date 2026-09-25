import Foundation
import Testing
@testable import JRBarCore
@testable import JRBarApp

/// The tank's five synthesized voices: each is the same every time,
/// never louder than its gain, shorter than a second and ends on
/// silence — and one voice can't stutter inside its rate limit.
@Suite("Aquarium sound")
struct AquariumSoundTests {
    @Test("every voice is deterministic, peaks at its gain, stays under a second and ends at 0",
          arguments: AquariumSound.Voice.allCases)
    func voice(_ voice: AquariumSound.Voice) {
        let samples = AquariumSound.samples(voice, sampleRate: 22_050)
        #expect(!samples.isEmpty)
        #expect(samples.count == Int(AquariumSound.duration(voice) * 22_050))
        #expect(AquariumSound.duration(voice) < 1)
        let peak = samples.map { abs($0) }.max() ?? 0
        #expect(Double(peak) <= AquariumSound.gain + 1e-6)
        #expect(Double(peak) > AquariumSound.gain * 0.99, "normalized, not silent")
        #expect(samples.last == 0, "the buffer ends on silence")
        #expect(samples.allSatisfy { $0.isFinite })
        #expect(AquariumSound.samples(voice, sampleRate: 22_050) == samples, "deterministic")
    }

    @Test("the voices sound different from each other")
    func distinct() {
        let all = AquariumSound.Voice.allCases.map { AquariumSound.samples($0, sampleRate: 8_000) }
        for (i, a) in all.enumerated() {
            for b in all.dropFirst(i + 1) {
                #expect(a != b)
            }
        }
    }

    @Test("a voice can't start twice inside 30 ms; another voice can")
    func rateLimit() {
        var gate = AquariumSound.RateGate()
        let first = gate.allow(.gulp, at: 100)
        let tooSoon = gate.allow(.gulp, at: 100.01)
        let otherVoice = gate.allow(.clink, at: 100.01)
        let later = gate.allow(.gulp, at: 100.031)
        #expect(first)
        #expect(!tooSoon)
        #expect(otherVoice, "the limit is per voice")
        #expect(later)
    }

    @Test("the voice holds for a Focus, JR-Bar's quiet, a call or the daemon's no-sounds, with no hush switch in it")
    func heldByTheRoom() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        func held(_ focus: CoreFocus?, onCall: Bool = false) -> Bool {
            AquariumSound.held(focus: focus, onCall: onCall, quietOnCalls: false,
                               micLive: { false }, now: now)
        }
        #expect(!held(nil), "a clear room plays")
        #expect(!held(CoreFocus(mode: "off")))
        #expect(held(CoreFocus(mode: "dnd", source: "focus")), "a macOS Focus")
        #expect(held(CoreFocus(mode: "mute", source: "schedule")), "quiet hours")
        #expect(held(nil, onCall: true), "a call")
        #expect(held(CoreFocus(mode: "off", source: "call", audibleAllowed: false)),
                "the daemon's call quiet takes only the sounds")
        #expect(!held(CoreFocus(mode: "mute", source: "schedule",
                                until: now.timeIntervalSince1970 - 1)), "an expired quiet has lifted")
    }

    @Test("a live microphone holds the voice only while Settings › Sounds keeps quiet on calls")
    func heldByTheMicrophone() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        var reads = 0
        let live = { () -> Bool in reads += 1; return true }
        #expect(AquariumSound.held(focus: nil, onCall: false, quietOnCalls: true, micLive: live, now: now))
        #expect(!AquariumSound.held(focus: nil, onCall: false, quietOnCalls: false, micLive: live, now: now))
        #expect(reads == 1, "the microphone is only asked when it matters")
        #expect(!AquariumSound.held(focus: nil, onCall: false, quietOnCalls: true,
                                    micLive: { false }, now: now))
    }

    @Test("the WAV header matches the samples")
    func wav() {
        let data = AquariumSound.wav(from: [0, 0.25, -0.25], sampleRate: 8_000)
        #expect(data.count == 44 + 6)
        #expect(String(decoding: data.prefix(4), as: UTF8.self) == "RIFF")
    }
}
