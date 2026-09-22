import Foundation

/// The media row's live visualizer math — pure, no audio hardware: the
/// tap hands it PCM windows, it hands back six band levels. Three
/// pieces: the band table itself (which frequencies the row cares
/// about), the Goertzel magnitudes that turn a window of samples into
/// a level per band, and the attack/release smoother that keeps the
/// bars alive without flutter. `AudioLevelTap` (JRBarApp) owns the
/// Core Audio plumbing; everything here runs on numbers alone, so the
/// tests drive it with synthetic sines.
public enum NotchAudioLevels {
    /// The six bands the row draws, as centre frequencies — spaced
    /// like an octave-ish ladder so bass, mids and presence all get a
    /// voice: kick/bass, low mids, body, presence, brilliance, air.
    public static let bandCenters: [Double] = [60, 150, 400, 1000, 2500, 6000]

    /// How many samples each analysis window holds. 1024 at the usual
    /// 48 kHz output rate is ~21 ms — fine enough for the 60 Hz band
    /// to resolve (its ~16 ms period fits inside the window), short
    /// enough for the ~30 Hz publish rate to feel live.
    public static let windowSize = 1024

    /// The level floor/ceiling in dB: -60 dB reads as silence, -15 dB
    /// pins the bar. The visualizer's bars live between them.
    public static let levelFloorDB: Float = -60
    public static let levelCeilingDB: Float = -15

    /// A Goertzel magnitude for one centre frequency — the single-pole
    /// DFT term for the bin nearest `frequency`. Cheap enough to run
    /// six of these per publish tick on a 1024-sample window.
    public static func goertzel(_ samples: [Float], frequency: Double,
                                sampleRate: Double) -> Float {
        guard !samples.isEmpty, sampleRate > 0, frequency > 0 else { return 0 }
        let n = Double(samples.count)
        let k = (0.5 + n * frequency / sampleRate).rounded(.down)
        let omega = 2 * Double.pi * k / n
        let coeff = 2 * cos(omega)
        var s0 = 0.0, s1 = 0.0, s2 = 0.0
        for sample in samples {
            s0 = Double(sample) + coeff * s1 - s2
            s2 = s1
            s1 = s0
        }
        // The magnitude at the bin, normalised by the window length —
        // a full-scale sine lands near 0.5.
        let power = s1 * s1 + s2 * s2 - coeff * s1 * s2
        return Float(sqrt(max(0, power)) * 2 / n)
    }

    /// One Goertzel pass per band, mapped onto the 0…1 decibel ramp —
    /// silence is 0, a loud bar pins at 1.
    public static func bandLevels(_ samples: [Float],
                                  sampleRate: Double) -> [Float] {
        bandCenters.map { center in
            let magnitude = goertzel(samples, frequency: center,
                                     sampleRate: sampleRate)
            let db = 20 * log10(max(magnitude, 1e-7))
            return min(1, max(0, (db - levelFloorDB)
                                / (levelCeilingDB - levelFloorDB)))
        }
    }

    /// Whether the tap may run. Every caller-side fact arrives as a
    /// bool so the rule — media row on screen AND something playing
    /// AND the user opted in — is one line and one state table.
    public static func shouldRun(mediaRowVisible: Bool, playing: Bool,
                                 settingEnabled: Bool) -> Bool {
        settingEnabled && mediaRowVisible && playing
    }
}

/// The bars' memory: a per-band exponential smoother. Attack is fast —
/// a hit should land within a frame or two — release decays over
/// roughly a quarter of a second so silence fades instead of snapping.
public struct NotchBandSmoother: Equatable, Sendable {
    /// Attack time constant — how quickly a rising level is believed.
    public var attack: TimeInterval
    /// Release time constant — the ~250 ms fall the spec asks for.
    public var release: TimeInterval
    private var levels: [Float]

    public init(bands: Int = 6, attack: TimeInterval = 0.03,
                release: TimeInterval = 0.25) {
        self.attack = attack
        self.release = release
        levels = [Float](repeating: 0, count: bands)
    }

    public var current: [Float] { levels }

    /// Fold one raw reading in. Each band chases the raw value with a
    /// per-sample coefficient chosen by direction: rising uses the
    /// attack constant, falling the release. `dt` is the wall time
    /// since the last reading, so the feel is frame-rate independent.
    @discardableResult
    public mutating func update(_ raw: [Float], dt: TimeInterval) -> [Float] {
        let count = min(raw.count, levels.count)
        let step = max(0, dt)
        for i in 0..<count {
            let tau = raw[i] > levels[i] ? attack : release
            let k = Float(1 - exp(-step / max(tau, 0.001)))
            levels[i] += (raw[i] - levels[i]) * min(1, max(0, k))
        }
        // A shorter reading than the band count decays the tail toward
        // silence — a dead tap never leaves a bar pinned.
        if raw.count < levels.count {
            let k = Float(1 - exp(-step / max(release, 0.001)))
            for i in raw.count..<levels.count {
                levels[i] += (0 - levels[i]) * min(1, max(0, k))
            }
        }
        return levels
    }
}
