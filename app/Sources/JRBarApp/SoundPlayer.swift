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

    nonisolated static func choiceKey(_ role: SoundRole) -> String { "sound.choice.\(role.rawValue)" }
    nonisolated static let volumeKey = "sound.volume"
    nonisolated static let alertDeviceKey = "sound.alertDevice"

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
    }

    /// What to actually play for a requested name: a role's default is
    /// swapped for the person's choice (nil when they chose silence); any
    /// other name — a sound a daemon event names itself — plays as asked.
    nonisolated func resolve(_ name: String) -> String? {
        guard let role = SoundRole(defaultName: name) else { return name }
        let choice = choices[role] ?? role.defaultSound
        return choice == Self.silent ? nil : choice
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
    private lazy var alertDevice = AlertDevicePlayer()

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
        guard let resolved = preferences.resolve(name) else { return }
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

/// Plays a sound on macOS's alert device — System Settings › Sound ›
/// "Play sound effects through" — rather than the current output, the
/// way the system's own alerts do. AVAudioPlayer always follows the
/// default output; an engine whose output unit is pointed at the alert
/// device does not. Any step that fails answers false and the caller
/// falls back to the ordinary player.
@MainActor
final class AlertDevicePlayer {
    private let engine = AVAudioEngine()
    private let node = AVAudioPlayerNode()
    private var device: AudioObjectID?
    private var attached = false

    func play(url: URL, volume: Float) -> Bool {
        guard let target = AudioListener.defaultDevice(kAudioHardwarePropertyDefaultSystemOutputDevice),
              let file = try? AVAudioFile(forReading: url) else { return false }
        if !attached {
            engine.attach(node)
            attached = true
        }
        // Each ring reconnects with its own file's format (a custom
        // sound's channel count or rate can differ) and follows the alert
        // device if it moved since the last one.
        node.stop()
        engine.stop()
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
        node.scheduleFile(file, at: nil)
        node.play()
        return true
    }
}
