import AVFoundation
import Foundation

/// The tank's little voice (Aquarium card › Sound, off by default): five
/// short sounds synthesized once into in-memory WAVs — no bundled asset,
/// no permission — and played quietly through AVAudioPlayer at the
/// Settings › Sounds volume. The toy decides when: only for a tap or a
/// window event, never on the wallpaper or the screensaver, never while
/// the room is quiet or the window is covered.
@MainActor
enum AquariumSound {
    /// What the tank can say.
    enum Voice: String, CaseIterable, Sendable {
        /// A pinch of food lands in the water.
        case plop
        /// A fish eats a pellet.
        case gulp
        /// A pearl or a coin is picked up.
        case clink
        /// A purchase, or a reward card sliding in.
        case chime
        /// A visitor arrives, or an alien is shooed off.
        case whoosh
    }

    nonisolated static let sampleRate = 44_100
    /// The peak every voice is normalized to — quiet, under whatever
    /// else is playing.
    nonisolated static let gain: Double = 0.25
    /// The same voice never starts twice inside this — a burst of
    /// pellets eaten in one frame is one gulp.
    nonisolated static let minimumGap: TimeInterval = 0.03

    private static var players: [Voice: AVAudioPlayer] = [:]
    private static var gate = RateGate()

    /// Plays `voice` at `volume` (0…1, the Sounds page's master). A
    /// player that fails to build just stays silent — a toy is not
    /// worth an error.
    static func play(_ voice: Voice, volume: Double, at now: TimeInterval = Date().timeIntervalSince1970) {
        guard volume > 0, gate.allow(voice, at: now) else { return }
        let player: AVAudioPlayer
        if let cached = players[voice] {
            player = cached
        } else {
            let data = wav(from: samples(voice), sampleRate: sampleRate)
            guard let built = try? AVAudioPlayer(data: data) else { return }
            built.prepareToPlay()
            players[voice] = built
            player = built
        }
        player.volume = Float(min(1, max(0, volume)))
        player.currentTime = 0
        player.play()
    }

    /// Per-voice spacing: a voice may start again only `minimumGap`
    /// after it last started. Pure, so the limit is testable.
    struct RateGate: Sendable {
        private var last: [Voice: TimeInterval] = [:]

        mutating func allow(_ voice: Voice, at now: TimeInterval) -> Bool {
            if let previous = last[voice], now - previous < AquariumSound.minimumGap,
               now >= previous {
                return false
            }
            last[voice] = now
            return true
        }
    }

    /// How long each voice runs, end to end.
    nonisolated static func duration(_ voice: Voice) -> TimeInterval {
        switch voice {
        case .plop: return 0.16
        case .gulp: return 0.12
        case .clink: return 0.30
        case .chime: return 0.72
        case .whoosh: return 0.55
        }
    }

    /// One voice's samples, pure and deterministic: shaped, normalized
    /// to `gain` and faded to silence on the last sample.
    nonisolated static func samples(_ voice: Voice, sampleRate: Int = sampleRate,
                                    gain: Double = gain) -> [Float] {
        let rate = Double(sampleRate)
        let count = Int(duration(voice) * rate)
        var out = [Double](repeating: 0, count: count)
        switch voice {
        case .plop:
            // A water drop: a sine sweeping up from 340 Hz to about
            // 880 Hz over 110 ms, under a quick decay.
            var phase = 0.0
            for i in 0..<count {
                let t = Double(i) / rate
                let sweep = min(1, t / 0.11)
                let freq = 340 * pow(2.6, sweep)
                phase += 2 * .pi * freq / rate
                out[i] = sin(phase) * attack(t, 0.003) * exp(-t / 0.045)
            }
        case .gulp:
            // A swallow: a triangle falling from 780 Hz to 180 Hz in
            // 70 ms.
            var phase = 0.0
            for i in 0..<count {
                let t = Double(i) / rate
                let fall = min(1, t / 0.07)
                let freq = 780 - 600 * fall
                phase += freq / rate
                let tri = 4 * abs(phase - (phase + 0.5).rounded(.down)) - 1
                out[i] = tri * attack(t, 0.004) * exp(-t / 0.035)
            }
        case .clink:
            // A pearl on glass: two bright partials, 2.1 and 3.3 kHz,
            // with a 90 ms ring.
            for i in 0..<count {
                let t = Double(i) / rate
                let ring = exp(-t / 0.09)
                out[i] = (sin(2 * .pi * 2100 * t) * 0.65 + sin(2 * .pi * 3300 * t) * 0.35)
                    * attack(t, 0.002) * ring
            }
        case .chime:
            // A small bell: 392 Hz and its fifth and ninth, each struck
            // 50 ms after the last.
            for (k, ratio) in [1.0, 1.5, 2.25].enumerated() {
                let start = Double(k) * 0.05
                let freq = 392 * ratio
                for i in Int(start * rate)..<count {
                    let t = Double(i) / rate - start
                    out[i] += sin(2 * .pi * freq * t) * attack(t, 0.004) * exp(-t / 0.22) / Double(k + 1)
                }
            }
        case .whoosh:
            // Water moving: seeded noise through a band-pass whose
            // centre slides from 900 Hz down to 160 Hz, swelling and
            // falling away.
            var seed: UInt64 = 0xA0_0A_5E_ED_15_C0_FF_EE
            func noise() -> Double {
                seed = seed &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
                return Double(Int64(bitPattern: seed >> 11) % 2_000_001) / 1_000_000 - 1
            }
            // A two-pole resonator, retuned per sample.
            var y1 = 0.0, y2 = 0.0
            for i in 0..<count {
                let t = Double(i) / rate
                let p = t / duration(voice)
                let centre = 900 * pow(160.0 / 900.0, p)
                let r = 0.985
                let theta = 2 * .pi * centre / rate
                let y = noise() * (1 - r) + 2 * r * cos(theta) * y1 - r * r * y2
                y2 = y1
                y1 = y
                let swell = sin(.pi * min(1, p * 1.25))
                out[i] = y * max(0, swell)
            }
        }
        // Every voice ends on silence: a short fade over the last 12 ms.
        let tail = max(1, Int(0.012 * rate))
        for i in max(0, count - tail)..<count {
            out[i] *= Double(count - 1 - i) / Double(tail)
        }
        let peak = out.map(abs).max() ?? 0
        let scale = peak > 0 ? gain / peak : 0
        return out.map { Float($0 * scale) }
    }

    /// 16-bit mono PCM in a RIFF/WAVE container — what AVAudioPlayer
    /// reads straight from memory. The confetti's pop already writes
    /// this exact container, so the tank shares its writer.
    nonisolated static func wav(from samples: [Float], sampleRate: Int) -> Data {
        ConfettiSound.wav(from: samples, sampleRate: sampleRate)
    }

    /// A linear rise over the first `seconds`, so nothing clicks on.
    nonisolated private static func attack(_ t: Double, _ seconds: Double) -> Double {
        min(1, t / seconds)
    }
}
