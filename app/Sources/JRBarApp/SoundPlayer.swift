import AVFoundation
import CoreAudio
import Foundation
import JRBarCore

/// Which kind of moment a sound marks. The event policy names its sounds
/// by these defaults (`EventPolicy.completionSound`, …), so a played name
/// that is a role's default is that role — and plays whatever the person
/// chose for it on Settings › Sounds.
enum SoundRole: String, CaseIterable, Sendable {
    case completion, ask, failure, quota, chime

    var title: String {
        switch self {
        case .completion: return "A session finishes"
        case .ask: return "An agent asks"
        case .failure: return "A session fails"
        case .quota: return "A usage window fills"
        case .chime: return "An ask is ignored"
        }
    }

    var subtitle: String {
        switch self {
        case .completion: return "Once, when a main session settles."
        case .ask: return "Repeated as the alert burst."
        case .failure: return "Once, when a session ends in an error."
        case .quota: return "At each threshold a window crosses."
        case .chime: return "The final escalation stage, every 30 s until answered."
        }
    }

    var defaultSound: String {
        switch self {
        case .completion: return EventPolicy.completionSound
        case .ask: return EventPolicy.askSound
        case .failure: return EventPolicy.failureSound
        case .quota: return EventPolicy.quotaSound
        case .chime: return EventPolicy.chimeSound
        }
    }

    /// The role whose default `name` is, if any.
    init?(defaultName name: String) {
        guard let role = SoundRole.allCases.first(where: {
            $0.defaultSound.caseInsensitiveCompare(name) == .orderedSame
        }) else { return nil }
        self = role
    }
}

/// Settings › Sounds, app-local: the sound per role (absent = the
/// shipped one, `none` = silent), one volume for every JR-Bar sound, and
/// whether sounds follow macOS's alert device instead of the current
/// output.
struct SoundPreferences: Equatable, Sendable {
    nonisolated static let silent = "none"

    var choices: [SoundRole: String] = [:]
    var volume: Double = 1
    var useAlertDevice = false
    /// Hold every event sound while another app captures from a
    /// microphone — a call, a recording, dictation (`MicrophoneCapture`).
    /// Lights and banners still land. On unless the person turns it off.
    var quietOnCalls = true

    nonisolated static func choiceKey(_ role: SoundRole) -> String { "sound.choice.\(role.rawValue)" }
    nonisolated static let volumeKey = "sound.volume"
    nonisolated static let alertDeviceKey = "sound.alertDevice"
    nonisolated static let quietOnCallsKey = "sound.quietOnCalls"

    nonisolated static func load(from defaults: UserDefaults = .standard) -> SoundPreferences {
        var preferences = SoundPreferences()
        for role in SoundRole.allCases {
            if let choice = defaults.string(forKey: choiceKey(role)), !choice.isEmpty {
                preferences.choices[role] = choice
            }
        }
        if defaults.object(forKey: volumeKey) != nil {
            preferences.volume = min(1, max(0, defaults.double(forKey: volumeKey)))
        }
        preferences.useAlertDevice = defaults.bool(forKey: alertDeviceKey)
        if defaults.object(forKey: quietOnCallsKey) != nil {
            preferences.quietOnCalls = defaults.bool(forKey: quietOnCallsKey)
        }
        return preferences
    }

    nonisolated func save(to defaults: UserDefaults = .standard) {
        for role in SoundRole.allCases {
            if let choice = choices[role] {
                defaults.set(choice, forKey: Self.choiceKey(role))
            } else {
                defaults.removeObject(forKey: Self.choiceKey(role))
            }
        }
        defaults.set(volume, forKey: Self.volumeKey)
        defaults.set(useAlertDevice, forKey: Self.alertDeviceKey)
        defaults.set(quietOnCalls, forKey: Self.quietOnCallsKey)
    }

    /// What to actually play for a requested name: a role's default is
    /// swapped for the person's choice (nil when they chose silence); any
    /// other name — a sound a daemon event names itself — plays as asked.
    nonisolated func resolve(_ name: String) -> String? {
        guard let role = SoundRole(defaultName: name) else { return name }
        let choice = choices[role] ?? role.defaultSound
        return choice == Self.silent ? nil : choice
    }

    /// The same, with the microphone asked about: nil while it is live
    /// and `quietOnCalls` is on. `micLive` is only read when it matters.
    nonisolated func resolve(_ name: String, micLive: () -> Bool) -> String? {
        guard let resolved = resolve(name) else { return nil }
        return quietOnCalls && micLive() ? nil : resolved
    }
}

/// Plays the system alert sounds through AVAudioPlayer rather than
/// NSSound, so a muted alert channel (System Settings → Sound → alert
/// volume) does not silence a completion the way it would codenotch's.
/// Settings › Sounds picks the sound per moment (or none), the volume,
/// and whether sounds follow macOS's alert device — so a chime can stay
/// on the speakers while a call runs in AirPods.
@MainActor
final class SoundPlayer {
    private var players: [String: AVAudioPlayer] = [:]
    private var burst: DispatchWorkItem?
    private var chimeTimer: Timer?
    /// Set to route the daemon's log a line when a sound is missing.
    var onMissing: ((String) -> Void)?
    /// Read at every play, so a Settings change lands on the next sound.
    var preferences: () -> SoundPreferences = { SoundPreferences.load() }
    /// Whether another app is capturing from a microphone — read only
    /// when a sound is about to play and the person keeps sounds quiet
    /// on calls; no poll. Input-specific, so music playing through
    /// AirPods (one device, both directions) never reads as a call.
    var microphoneLive: () -> Bool = { MicrophoneCapture.isLive() }
    /// Told when a sound is held for a live microphone.
    var onHeldForCall: ((String) -> Void)?
    private lazy var alertDevice = AlertDevicePlayer()
    /// Where synthesized sounds (`playSynthesized`) are kept as WAV
    /// files: the app's caches folder. Tests point it at a scratch one.
    var synthesizedFolder: URL = SoundPlayer.defaultSynthesizedFolder
    /// Stands in for the speakers when set: each synthesized play lands
    /// here instead of being heard, so a test can read the volume back.
    var synthesizedOutput: ((SynthesizedPlay) -> Void)?
    /// The synthesized files already checked against their bytes this
    /// run: each is written at most once, then only read.
    private var synthesizedChecked: Set<String> = []

    /// The folders a sound name is looked up in: the system's, then the
    /// person's own (`~/Library/Sounds`, where macOS keeps custom alerts).
    nonisolated static let userSoundsFolder = NSString(string: "~/Library/Sounds").expandingTildeInPath
    nonisolated static let systemSoundsFolder = "/System/Library/Sounds"
    nonisolated static let soundExtensions = ["aiff", "aif", "caf", "wav", "m4a", "mp3"]

    static func url(for name: String) -> URL? {
        var candidates = [
            "\(systemSoundsFolder)/\(name).aiff",
            "\(systemSoundsFolder)/\(name.capitalized).aiff",
        ]
        candidates += soundExtensions.map { "\(userSoundsFolder)/\(name).\($0)" }
        return candidates.first { FileManager.default.fileExists(atPath: $0) }.map { URL(fileURLWithPath: $0) }
    }

    /// Every sound Settings can offer: the system's, then the person's
    /// own, by name, without duplicates.
    nonisolated static func availableSounds(fileManager: FileManager = .default) -> (system: [String], custom: [String]) {
        func names(in folder: String) -> [String] {
            let files = (try? fileManager.contentsOfDirectory(atPath: folder)) ?? []
            return files
                .filter { soundExtensions.contains(($0 as NSString).pathExtension.lowercased()) }
                .map { ($0 as NSString).deletingPathExtension }
                .sorted { $0.localizedStandardCompare($1) == .orderedAscending }
        }
        let system = names(in: systemSoundsFolder)
        let custom = names(in: userSoundsFolder).filter { !system.contains($0) }
        return (system, custom)
    }

    /// Plays `name` `repeats` times, 0.45 s apart — or the person's
    /// choice for that moment, or nothing when they chose silence.
    func play(_ name: String, repeats: Int = 1) {
        burst?.cancel()
        let preferences = preferences()
        guard let chosen = preferences.resolve(name) else { return }
        guard let resolved = preferences.resolve(name, micLive: microphoneLive) else {
            onHeldForCall?(chosen)
            return
        }
        guard let once = playback(for: resolved, preferences: preferences) else {
            onMissing?(resolved)
            return
        }
        once()
        guard repeats > 1 else { return }
        var remaining = repeats - 1
        let work = DispatchWorkItem { [weak self] in
            guard let self, remaining > 0 else { return }
            remaining -= 1
            once()
            if remaining > 0, let again = self.burst {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.45, execute: again)
            }
        }
        burst = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.45, execute: work)
    }

    /// Settings' preview button: `name` once, at the chosen volume and
    /// on the chosen device, whatever role it would stand for.
    func preview(_ name: String) {
        let preferences = preferences()
        guard name != SoundPreferences.silent,
              let once = playback(for: name, preferences: preferences) else { return }
        once()
    }

    /// The stage-3 escalation chime: every `interval` seconds until
    /// `stopChime`. Each ring re-reads the choice, so a change in
    /// Settings lands on the next ring.
    func startChime(_ name: String, interval: TimeInterval) {
        guard chimeTimer == nil else { return }
        play(name)
        let timer = Timer(timeInterval: interval, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in self?.play(name) }
        }
        RunLoop.main.add(timer, forMode: .common)
        chimeTimer = timer
    }

    func stopChime() {
        chimeTimer?.invalidate()
        chimeTimer = nil
    }

    var isChiming: Bool { chimeTimer != nil }

    /// One ring of `name`: on the alert device when that is asked for
    /// and reachable, else the cached AVAudioPlayer on the current output.
    private func playback(for name: String, preferences: SoundPreferences) -> (() -> Void)? {
        let volume = Float(preferences.volume)
        if preferences.useAlertDevice, let url = Self.url(for: name) {
            let device = alertDevice
            return { [weak self] in
                if !device.play(url: url, volume: volume) { self?.playOnCurrentOutput(name, volume: volume) }
            }
        }
        guard player(named: name) != nil else { return nil }
        return { [weak self] in self?.playOnCurrentOutput(name, volume: volume) }
    }

    private func playOnCurrentOutput(_ name: String, volume: Float) {
        guard let player = player(named: name) else { return }
        player.volume = volume
        player.currentTime = 0
        player.play()
    }

    private func player(named name: String) -> AVAudioPlayer? {
        if let cached = players[name] { return cached }
        guard let url = Self.url(for: name), let player = try? AVAudioPlayer(contentsOf: url) else { return nil }
        player.prepareToPlay()
        players[name] = player
        return player
    }
}

// MARK: Synthesized sounds

extension SoundPlayer {
    /// One play of a synthesized sound as it went out: the cached file,
    /// the volume after Settings › Sounds, the pitch step, the pan and
    /// whether it took the alert device.
    struct SynthesizedPlay: Equatable, Sendable {
        var file: URL
        var volume: Float
        var rate: Double
        var pan: Float
        var alertDevice: Bool
    }

    /// `~/Library/Caches/<bundle id>/Sounds`.
    nonisolated static var defaultSynthesizedFolder: URL {
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory())
        return caches.appending(path: Bundle.main.bundleIdentifier ?? "JR-Bar").appending(path: "Sounds")
    }

    /// The pitch steps a synthesized sound can play at: ±6 % in 2 %
    /// steps, so a handful of files covers every pop.
    nonisolated static let pitchSteps: [Double] = [0.94, 0.96, 0.98, 1.0, 1.02, 1.04, 1.06]

    /// The step nearest `rate`.
    nonisolated static func pitchStep(_ rate: Double) -> Double {
        guard rate.isFinite else { return 1 }
        return pitchSteps.min { abs($0 - rate) < abs($1 - rate) } ?? 1
    }

    /// A sound JR-Bar makes itself (the confetti's pop), played by the
    /// same rules as every other: Settings › Sounds' volume times `gain`,
    /// the alert device when that is picked, and held while another app
    /// has the microphone and sounds keep quiet on calls. `wav` is
    /// written to the caches folder once per pitch step — `rate` moves
    /// the pitch (and the length with it) up to 6 % either way — and
    /// `pan` sits it left or right, -1 … 1. Returns what played, or nil
    /// when nothing did.
    @discardableResult
    func playSynthesized(_ wav: Data, key: String, gain: Double = 1, rate: Double = 1,
                         pan: Double = 0) -> SynthesizedPlay? {
        let preferences = preferences()
        if preferences.quietOnCalls, microphoneLive() {
            onHeldForCall?(key)
            return nil
        }
        let volume = Float(min(1, max(0, preferences.volume * gain)))
        guard volume > 0 else { return nil }
        let step = Self.pitchStep(rate)
        guard let file = synthesizedFile(wav, key: key, rate: step) else { return nil }
        let play = SynthesizedPlay(file: file, volume: volume, rate: step,
                                   pan: Float(max(-1, min(1, pan))),
                                   alertDevice: preferences.useAlertDevice)
        if let synthesizedOutput {
            synthesizedOutput(play)
            return play
        }
        if play.alertDevice, alertDevice.play(url: file, volume: volume, pan: play.pan) { return play }
        let name = "synthesized:" + file.lastPathComponent
        let player: AVAudioPlayer
        if let cached = players[name] {
            player = cached
        } else {
            guard let made = try? AVAudioPlayer(contentsOf: file) else { return nil }
            made.prepareToPlay()
            players[name] = made
            player = made
        }
        player.volume = volume
        player.pan = play.pan
        player.currentTime = 0
        player.play()
        return play
    }

    /// The cached file for `key` at a pitch step, written when it is
    /// missing or its bytes changed (a new build's sound) and otherwise
    /// only read; checked once a run.
    private func synthesizedFile(_ wav: Data, key: String, rate: Double) -> URL? {
        let percent = Int((rate * 100).rounded())
        let file = synthesizedFolder.appending(path: "\(key)-\(percent).wav")
        if synthesizedChecked.contains(file.path) { return file }
        guard let bytes = Self.retimed(wav, rate: rate) else { return nil }
        if (try? Data(contentsOf: file)) != bytes {
            do {
                try FileManager.default.createDirectory(at: synthesizedFolder, withIntermediateDirectories: true)
                try bytes.write(to: file, options: .atomic)
            } catch {
                return nil
            }
        }
        synthesizedChecked.insert(file.path)
        return file
    }

    /// The same PCM WAV told to play `rate` times as fast: its sample
    /// and byte rates are rewritten, so the pitch moves with the speed
    /// — a varispeed, not a stretch. nil for bytes that aren't the plain
    /// 44-byte-header WAV `ConfettiSound.wav` writes.
    nonisolated static func retimed(_ wav: Data, rate: Double) -> Data? {
        let bytes = [UInt8](wav)
        guard bytes.count >= 44,
              bytes[0..<4].elementsEqual("RIFF".utf8),
              bytes[8..<12].elementsEqual("WAVE".utf8),
              bytes[12..<16].elementsEqual("fmt ".utf8) else { return nil }
        guard rate != 1 else { return wav }
        func read(_ at: Int) -> UInt32 {
            (0..<4).reduce(UInt32(0)) { $0 | UInt32(bytes[at + $1]) << (8 * UInt32($1)) }
        }
        var out = bytes
        func write(_ value: UInt32, _ at: Int) {
            for i in 0..<4 { out[at + i] = UInt8((value >> (8 * UInt32(i))) & 0xFF) }
        }
        write(UInt32((Double(read(24)) * rate).rounded()), 24)
        write(UInt32((Double(read(28)) * rate).rounded()), 28)
        return Data(out)
    }
}

/// Plays a sound on macOS's alert device — System Settings › Sound ›
/// "Play sound effects through" — rather than the current output, the
/// way the system's own alerts do. AVAudioPlayer always follows the
/// default output; an engine whose output unit is pointed at the alert
/// device does not. Any step that fails answers false and the caller
/// falls back to the ordinary player.
///
/// Each ring's end stops the engine again: a running output unit keeps
/// the device's IO up — an energy cost, a Bluetooth link that never
/// idles — and the next ring restarts it anyway.
@MainActor
final class AlertDevicePlayer {
    private let output: any AlertDeviceOutput
    /// Where the alert device is read; tests answer their own.
    var alertOutputDevice: () -> AudioObjectID? = {
        AudioListener.defaultDevice(kAudioHardwarePropertyDefaultSystemOutputDevice)
    }
    /// Bumped by every ring, so only the newest ring's end stops the
    /// hardware: a burst's next ring cuts the last one short, and that
    /// stale end must not silence the new one.
    private var ring = 0

    init(output: any AlertDeviceOutput = EngineAlertOutput()) {
        self.output = output
    }

    /// Whether the output unit holds the device right now.
    var isRunning: Bool { output.isRunning }

    /// `pan` is -1 (left) … 1 (right); every ring sets it, so a panned
    /// pop never leaves the next alert off-centre.
    func play(url: URL, volume: Float, pan: Float = 0) -> Bool {
        guard let target = alertOutputDevice(),
              let file = try? AVAudioFile(forReading: url) else { return false }
        ring += 1
        let current = ring
        output.setPan(pan)
        return output.start(file, on: target, volume: volume) { [weak self] in
            guard let self, self.ring == current else { return }
            self.output.stop()
        }
    }
}

/// The hardware half of `AlertDevicePlayer` — the seam a test ends a
/// ring through without an audio device.
@MainActor
protocol AlertDeviceOutput: AnyObject {
    /// Whether the output unit is holding the device's IO.
    var isRunning: Bool { get }
    /// Starts `file` on `device` at `volume`; `ended` runs on the main
    /// actor once it has played out or been cut short. False when any
    /// step fails.
    func start(_ file: AVAudioFile, on device: AudioObjectID, volume: Float,
               ended: @escaping @MainActor @Sendable () -> Void) -> Bool
    /// Stops the node and the engine, so the device can go idle.
    func stop()
    /// Where the next ring sits left to right, -1 … 1.
    func setPan(_ pan: Float)
}

extension AlertDeviceOutput {
    /// An output that can't pan plays centred.
    func setPan(_ pan: Float) {}
}

/// The real output: one AVAudioEngine, its output unit on the alert
/// device, one player node.
@MainActor
final class EngineAlertOutput: AlertDeviceOutput {
    private let engine = AVAudioEngine()
    private let node = AVAudioPlayerNode()
    private var device: AudioObjectID?
    private var attached = false
    private var pan: Float = 0

    var isRunning: Bool { engine.isRunning }

    func setPan(_ pan: Float) {
        self.pan = max(-1, min(1, pan))
    }

    func start(_ file: AVAudioFile, on target: AudioObjectID, volume: Float,
               ended: @escaping @MainActor @Sendable () -> Void) -> Bool {
        if !attached {
            engine.attach(node)
            attached = true
        }
        // Each ring reconnects with its own file's format (a custom
        // sound's channel count or rate can differ) and follows the alert
        // device if it moved since the last one.
        stop()
        if device != target {
            do {
                try engine.outputNode.auAudioUnit.setDeviceID(target)
            } catch {
                return false
            }
            device = target
        }
        engine.connect(node, to: engine.mainMixerNode, format: file.processingFormat)
        do { try engine.start() } catch { return false }
        node.volume = volume
        node.pan = pan
        // The node calls back on its own render thread; the handler is
        // `@Sendable`, so it carries no main-actor isolation and hops.
        node.scheduleFile(file, at: nil, completionCallbackType: .dataPlayedBack) { _ in
            Task { @MainActor in ended() }
        }
        node.play()
        return true
    }

    func stop() {
        node.stop()
        engine.stop()
    }
}
