import AVFoundation
import Foundation

/// Plays the system alert sounds through AVAudioPlayer rather than
/// NSSound, so a muted alert channel (System Settings → Sound → alert
/// volume) does not silence a completion the way it would codenotch's.
@MainActor
final class SoundPlayer {
    private var players: [String: AVAudioPlayer] = [:]
    private var burst: DispatchWorkItem?
    private var chimeTimer: Timer?
    /// Set to route the daemon's log a line when a sound is missing.
    var onMissing: ((String) -> Void)?

    static func url(for name: String) -> URL? {
        let candidates = [
            "/System/Library/Sounds/\(name).aiff",
            "/System/Library/Sounds/\(name.capitalized).aiff",
            NSString(string: "~/Library/Sounds/\(name).aiff").expandingTildeInPath,
        ]
        return candidates.first { FileManager.default.fileExists(atPath: $0) }.map { URL(fileURLWithPath: $0) }
    }

    /// Plays `name` `repeats` times, 0.45 s apart.
    func play(_ name: String, repeats: Int = 1) {
        burst?.cancel()
        guard let player = player(named: name) else {
            onMissing?(name)
            return
        }
        player.currentTime = 0
        player.play()
        guard repeats > 1 else { return }
        var remaining = repeats - 1
        let work = DispatchWorkItem { [weak self] in
            guard let self, remaining > 0 else { return }
            remaining -= 1
            player.currentTime = 0
            player.play()
            if remaining > 0, let again = self.burst {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.45, execute: again)
            }
        }
        burst = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.45, execute: work)
    }

    /// The stage-3 escalation chime: every `interval` seconds until `stopChime`.
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

    private func player(named name: String) -> AVAudioPlayer? {
        if let cached = players[name] { return cached }
        guard let url = Self.url(for: name), let player = try? AVAudioPlayer(contentsOf: url) else { return nil }
        player.prepareToPlay()
        players[name] = player
        return player
    }
}
