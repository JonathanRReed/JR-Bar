import AVFoundation
import Foundation
import JRBarCore
import Synchronization

/// Fold's optional hinge voice (Fold card → Hinge voice, off by
/// default): LidAngleSensor's famous creaking door, done properly. The
/// lid's own speed plays it — a slow, deliberate close creaks, a quick
/// flip shut stays quiet — with a softer paper-rustle variant for a
/// shared room. It listens to the one sensor pump the fold already runs
/// (no second HID reader), synthesizes everything live (no bundled
/// asset), only runs its audio engine while the lid is actually moving,
/// and never plays while JR-Bar is quiet. It only listens: the fold's
/// motion is untouched.
@MainActor
final class FoldHingeVoice {
    private let controls = HingeVoiceControls()
    private var speed = HingeSpeed()
    private var engine: AVAudioEngine?
    private var watchdog: Timer?
    /// Host time of the last reading, and of the last one loud enough to
    /// hear — the engine stands down after a quiet stretch.
    private var lastFeedAt: TimeInterval = 0
    private var lastLoudAt: TimeInterval = 0
    /// A failed engine start waits before trying again.
    private var retry = HingeVoiceRetry()

    /// How long the engine idles on silence before it stops.
    static let standDownAfter: TimeInterval = 1.5

    /// One reading of the lid, raw or simulated. `allowed` is the room
    /// and the toy together: Fold on, rendered by JR-Bar, not hushed.
    func feed(angle: Double, at t: TimeInterval, voice: HingeVoice, allowed: Bool) {
        lastFeedAt = t
        let degreesPerSecond = speed.feed(angle, at: t)
        let gain = allowed && voice != .off ? HingeVoiceShape.gain(speed: degreesPerSecond) : 0
        controls.set(gain: gain, rate: HingeVoiceShape.clickRate(speed: degreesPerSecond),
                     kind: voice == .rustle ? .rustle : .creak)
        if gain > 0.02 {
            lastLoudAt = t
            startIfNeeded(at: t)
        }
    }

    /// Silence now and let the engine go — the fold switched off, the
    /// room hushed, the sensor stopped.
    func stop() {
        controls.set(gain: 0, rate: 0, kind: .creak)
        speed.reset()
        watchdog?.invalidate()
        watchdog = nil
        engine?.stop()
        engine = nil
    }

    var isRunning: Bool { engine != nil }

    private func startIfNeeded(at t: TimeInterval) {
        guard engine == nil, retry.mayStart(at: t) else { return }
        let engine = AVAudioEngine()
        let rate = engine.outputNode.outputFormat(forBus: 0).sampleRate
        guard let format = AVAudioFormat(standardFormatWithSampleRate: rate > 0 ? rate : 44_100,
                                         channels: 1) else {
            retry.noteFailure(at: t)
            return
        }
        let synth = HingeVoiceSynth(controls: controls, sampleRate: format.sampleRate)
        let node = Self.sourceNode(format: format, synth: synth)
        engine.attach(node)
        engine.connect(node, to: engine.mainMixerNode, format: format)
        do { try engine.start() } catch {
            // No output device, or one mid-switch: a lid moving at 120
            // readings a second must not build an engine per reading.
            retry.noteFailure(at: t)
            return
        }
        retry.noteSuccess()
        self.engine = engine
        // The engine's only clock: a slow look for a quiet stretch or a
        // sensor that stopped talking.
        let timer = Timer(timeInterval: 0.5, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.checkQuiet() }
        }
        RunLoop.main.add(timer, forMode: .common)
        watchdog = timer
    }

    /// Built outside the main actor on purpose: the render block runs on
    /// the audio thread, and a closure formed in main-actor code would
    /// carry a main-actor isolation check into it.
    nonisolated private static func sourceNode(format: AVAudioFormat,
                                               synth: HingeVoiceSynth) -> AVAudioSourceNode {
        AVAudioSourceNode(format: format) { _, _, frameCount, list in
            let buffers = UnsafeMutableAudioBufferListPointer(list)
            guard let first = buffers.first?.mData?.assumingMemoryBound(to: Float.self) else {
                return noErr
            }
            synth.render(frames: Int(frameCount), into: first)
            for buffer in buffers.dropFirst() {
                buffer.mData?.copyMemory(from: first, byteCount: Int(frameCount) * MemoryLayout<Float>.size)
            }
            return noErr
        }
    }

    private func checkQuiet() {
        let now = CACurrentMediaTime()
        if now - lastFeedAt > 0.5 { controls.set(gain: 0, rate: 0, kind: .creak) }
        if now - max(lastLoudAt, 0) > Self.standDownAfter { stop() }
    }
}

/// When a failed engine start may try again: not before `backOff` has
/// passed on the sensor's clock. Pure, so the pace can be pinned.
struct HingeVoiceRetry {
    static let backOff: TimeInterval = 5
    private var failedAt: TimeInterval?

    func mayStart(at t: TimeInterval) -> Bool {
        guard let failedAt else { return true }
        // A clock that ran backwards (a new host-time base) retries.
        return t - failedAt >= Self.backOff || t < failedAt
    }

    mutating func noteFailure(at t: TimeInterval) { failedAt = t }
    mutating func noteSuccess() { failedAt = nil }
}

/// The lid's speed from raw readings: degrees a second, eased over about
/// 150 ms. The sensor wobbles about a degree while the lid sits still,
/// so movement only counts once it clears a small deadband from where
/// it last settled — a slow close still registers (the travel adds up
/// across readings), a still lid reads zero.
struct HingeSpeed {
    private(set) var speed: Double = 0
    private var anchor: (angle: Double, at: TimeInterval)?
    private var lastAt: TimeInterval?

    /// The fold's own default jitter tolerance: the sensor's still-lid
    /// wobble stays inside it.
    static let deadband: Double = 1.5
    static let timeConstant: TimeInterval = 0.15
    /// No movement past the deadband for this long reads as still —
    /// long enough that a 2.5°/s close still clears the band first.
    static let stillAfter: TimeInterval = 0.6

    mutating func feed(_ angle: Double, at t: TimeInterval) -> Double {
        guard angle.isFinite else { return speed }
        defer { lastAt = t }
        guard let anchor, let lastAt, t > lastAt, t - lastAt < 1 else {
            self.anchor = (angle, t)
            speed = 0
            return 0
        }
        let moved = abs(angle - anchor.angle)
        let elapsed = t - anchor.at
        var instant: Double?
        if moved >= Self.deadband {
            instant = moved / max(elapsed, 1e-3)
            self.anchor = (angle, t)
        } else if elapsed > Self.stillAfter {
            instant = 0
            self.anchor = (angle, t)
        }
        if let instant {
            // Eased over the time since the last estimate, not the last
            // reading: at 120 Hz an estimate lands every dozen readings.
            let alpha = 1 - exp(-elapsed / Self.timeConstant)
            speed += (instant - speed) * alpha
        }
        return speed
    }

    mutating func reset() {
        speed = 0
        anchor = nil
        lastAt = nil
    }
}

/// How the hinge's speed sounds, pure so it can be pinned.
enum HingeVoiceShape {
    private static func smooth(_ x: Double, _ a: Double, _ b: Double) -> Double {
        let p = min(1, max(0, (x - a) / (b - a)))
        return p * p * (3 - 2 * p)
    }

    /// Loudness 0…1 for a lid moving `speed` °/s. A creak wants a slow,
    /// deliberate close: it swells in from 2°/s, is fullest from about
    /// 8 to 25°/s, and falls away by 70°/s — flipping the lid shut
    /// stays quiet.
    static func gain(speed: Double) -> Double {
        guard speed.isFinite, speed > 0 else { return 0 }
        return smooth(speed, 2, 8) * (1 - smooth(speed, 25, 70))
    }

    /// Stick-slip clicks a second: the faster the hinge turns, the
    /// faster it catches and lets go.
    static func clickRate(speed: Double) -> Double {
        guard speed.isFinite else { return 5 }
        return min(45, 5 + max(0, speed) * 1.6)
    }
}

/// What the main actor tells the audio thread: lock-free, three words.
final class HingeVoiceControls: Sendable {
    enum Kind: Int { case creak = 1, rustle = 2 }

    private let gainBits = Atomic<UInt64>(0)
    private let rateBits = Atomic<UInt64>(0)
    private let kindRaw = Atomic<Int>(Kind.creak.rawValue)

    func set(gain: Double, rate: Double, kind: Kind) {
        gainBits.store(gain.bitPattern, ordering: .relaxed)
        rateBits.store(rate.bitPattern, ordering: .relaxed)
        kindRaw.store(kind.rawValue, ordering: .relaxed)
    }

    var gain: Double { Double(bitPattern: gainBits.load(ordering: .relaxed)) }
    var rate: Double { Double(bitPattern: rateBits.load(ordering: .relaxed)) }
    var kind: Kind { Kind(rawValue: kindRaw.load(ordering: .relaxed)) ?? .creak }
}

/// The voice itself, run on the audio thread only. A creak is stick-slip
/// friction: a train of irregular catches, each ringing two wooden body
/// resonances. The rustle is high-passed noise broken into crinkles.
/// Gain eases toward the target so nothing ever clicks on or off.
final class HingeVoiceSynth: @unchecked Sendable {
    private let controls: HingeVoiceControls
    private let sampleRate: Double
    private var gain = 0.0
    private var phase = 0.0
    private var nextStep = 1.0
    private var seed: UInt64 = 0x2545_F491_4F6C_DD1D
    private var low: Resonator
    private var high: Resonator
    private var hpIn = 0.0
    private var hpOut = 0.0
    private var crinkle = 0.0
    private var crinkleLeft = 0

    /// The whole voice sits well under full scale.
    static let master = 0.16

    init(controls: HingeVoiceControls, sampleRate: Double) {
        self.controls = controls
        self.sampleRate = sampleRate
        low = Resonator(frequency: 420, q: 16, sampleRate: sampleRate)
        high = Resonator(frequency: 1_150, q: 10, sampleRate: sampleRate)
    }

    private func noise() -> Double {
        seed ^= seed << 13
        seed ^= seed >> 7
        seed ^= seed << 17
        return Double(seed % 2_000_001) / 1_000_000 - 1
    }

    func render(frames: Int, into out: UnsafeMutablePointer<Float>) {
        let target = controls.gain
        let rate = controls.rate
        let kind = controls.kind
        // About 15 ms to reach a new level.
        let ease = 1 - exp(-1 / (0.015 * sampleRate))
        let crinkleSpan = max(1, Int(0.011 * sampleRate))
        for i in 0..<frames {
            gain += (target - gain) * ease
            var sample = 0.0
            if gain > 0.0005 {
                switch kind {
                case .creak:
                    // Each catch lands a little early or late — real
                    // friction never keeps time.
                    phase += rate / sampleRate
                    var excite = noise() * 0.015
                    if phase >= nextStep {
                        phase -= nextStep
                        nextStep = 0.75 + 0.5 * abs(noise())
                        excite += 0.55 + 0.45 * abs(noise())
                    }
                    sample = low.process(excite) * 0.75 + high.process(excite) * 0.35
                case .rustle:
                    let white = noise()
                    hpOut = 0.86 * (hpOut + white - hpIn)
                    hpIn = white
                    if crinkleLeft <= 0 {
                        crinkle = 0.2 + 0.8 * abs(noise())
                        crinkleLeft = crinkleSpan
                    }
                    crinkleLeft -= 1
                    sample = hpOut * crinkle * 0.5
                }
            }
            out[i] = Float(tanh(sample * gain * 1.2) * Self.master)
        }
    }

    /// A two-pole resonator: a wooden panel's ring. The input is scaled
    /// by sin(ω) so a unit catch rings at about unit amplitude, decaying
    /// over the bandwidth `frequency / q`.
    struct Resonator {
        private let c1: Double, c2: Double, drive: Double
        private var y1 = 0.0, y2 = 0.0

        init(frequency: Double, q: Double, sampleRate: Double) {
            let w0 = 2 * Double.pi * frequency / sampleRate
            let r = exp(-Double.pi * (frequency / q) / sampleRate)
            c1 = 2 * r * cos(w0)
            c2 = -r * r
            drive = sin(w0)
        }

        mutating func process(_ x: Double) -> Double {
            let y = c1 * y1 + c2 * y2 + drive * x
            y2 = y1
            y1 = y
            return y
        }
    }
}
