import AVFoundation
import Foundation

/// The burst's optional voice (Confetti card → Sound, off by default): a
/// soft pop and a paper rustle, synthesized once into a small WAV — no
/// bundled asset, no system sound that might be renamed away — and
/// played through `SoundPlayer`, so it follows Settings › Sounds like
/// every other JR-Bar sound: the one volume, the alert device when
/// that's picked, and held while another app has the microphone.
/// 1-Click Confetti's one advantage, kept calm: about half a second,
/// low, a touch higher or lower each burst, and never while JR-Bar is
/// quiet (`ConfettiToy` decides).
enum ConfettiSound {
    nonisolated static let sampleRate = 44_100
    /// Pop plus rustle, end to end.
    nonisolated static let duration: TimeInterval = 0.62
    /// The peak the mix is normalized to — well under full scale, so it
    /// sits under whatever else is playing.
    nonisolated static let gain: Double = 0.32
    /// The cached file's name in the sounds folder.
    nonisolated static let key = "confetti-pop"
    /// The pop as a WAV, built once.
    nonisolated static let wavData: Data = wav(from: samples(), sampleRate: sampleRate)

    /// Plays the burst's pop through `player` at a pitch step near
    /// `rate` (±6 %) and `pan` (-1 … 1, where the burst came from).
    /// Returns what played — nil when Settings › Sounds held or muted it.
    @MainActor
    @discardableResult
    static func play(through player: SoundPlayer, rate: Double = 1,
                     pan: Double = 0) -> SoundPlayer.SynthesizedPlay? {
        player.playSynthesized(wavData, key: key, gain: 1, rate: rate, pan: pan)
    }

    /// The mix, pure and deterministic. The pop is a 90 ms sine that
    /// falls from 190 Hz to 80 Hz under a fast exponential decay — a
    /// cork, not a click. The rustle is seeded noise through a one-pole
    /// high-pass (so it reads as paper, not hiss), broken into little
    /// crinkles by a slow random envelope and fading out over the rest.
    nonisolated static func samples(sampleRate: Int = sampleRate, gain: Double = gain) -> [Float] {
        let rate = Double(sampleRate)
        let count = Int(duration * rate)
        var out = [Double](repeating: 0, count: count)
        // The pop.
        var phase = 0.0
        for i in 0..<count {
            let t = Double(i) / rate
            guard t < 0.09 else { break }
            let freq = 80 + 110 * exp(-t / 0.018)
            phase += 2 * .pi * freq / rate
            out[i] += sin(phase) * exp(-t / 0.022) * 0.9
        }
        // The rustle, after the pop's attack.
        var seed: UInt64 = 0x9E37_79B9_7F4A_7C15
        func noise() -> Double {
            seed = seed &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
            return Double(Int64(bitPattern: seed >> 11) % 2_000_001) / 1_000_000 - 1
        }
        var previousIn = 0.0
        var previousOut = 0.0
        var crinkle = 0.0
        let start = Int(0.03 * rate)
        for i in start..<count {
            let t = Double(i - start) / rate
            let white = noise()
            // One-pole high-pass at ~1.8 kHz.
            let alpha = 0.86
            let high = alpha * (previousOut + white - previousIn)
            previousIn = white
            previousOut = high
            // A new crinkle level every 12 ms — paper crackles in steps.
            if i % Int(0.012 * rate) == 0 { crinkle = 0.35 + 0.65 * abs(noise()) }
            let fade = exp(-t / 0.16) * min(1, t / 0.01)
            out[i] += high * crinkle * fade * 0.45
        }
        // A short fade on the tail so the buffer never ends on a step.
        let tail = Int(0.02 * rate)
        for i in max(0, count - tail)..<count {
            out[i] *= Double(count - i) / Double(tail)
        }
        let peak = out.map(abs).max() ?? 0
        let scale = peak > 0 ? gain / peak : 0
        return out.map { Float($0 * scale) }
    }

    /// 16-bit mono PCM in a RIFF/WAVE container — what AVAudioPlayer
    /// reads straight from memory.
    nonisolated static func wav(from samples: [Float], sampleRate: Int) -> Data {
        var data = Data()
        func append<T: FixedWidthInteger>(_ value: T) {
            withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) }
        }
        let bytes = samples.count * 2
        data.append(contentsOf: Array("RIFF".utf8))
        append(UInt32(36 + bytes))
        data.append(contentsOf: Array("WAVE".utf8))
        data.append(contentsOf: Array("fmt ".utf8))
        append(UInt32(16))
        append(UInt16(1))                      // PCM
        append(UInt16(1))                      // mono
        append(UInt32(sampleRate))
        append(UInt32(sampleRate * 2))         // byte rate
        append(UInt16(2))                      // block align
        append(UInt16(16))                     // bits per sample
        data.append(contentsOf: Array("data".utf8))
        append(UInt32(bytes))
        for sample in samples {
            let clamped = max(-1, min(1, sample))
            append(Int16(clamped * Float(Int16.max)))
        }
        return data
    }
}
