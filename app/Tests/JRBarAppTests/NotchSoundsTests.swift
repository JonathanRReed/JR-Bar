import Foundation
import Testing
import JRBarCore
@testable import JRBarApp

/// The announcement's click plays off the main thread: stopping and
/// starting a sound waits on the audio server, and that wait used to
/// land on the island's first frames. A recorder stands in for Tink, so
/// no suite makes a sound.
@Suite("Notch sounds", .serialized)
@MainActor
struct NotchSoundsTests {
    private final class Recorder: NotchTickPlayer, @unchecked Sendable {
        private let lock = NSLock()
        private var calls: [(name: String, onMain: Bool)] = []

        func prepare() { note("prepare") }
        func play() { note("play") }

        private func note(_ name: String) {
            let onMain = Thread.isMainThread
            lock.withLock { calls.append((name, onMain)) }
        }

        var log: [(name: String, onMain: Bool)] { lock.withLock { calls } }
    }

    private func withRecorder(_ body: (Recorder) -> Void) {
        let recorder = Recorder()
        let saved = NotchSounds.player
        NotchSounds.player = recorder
        defer { NotchSounds.player = saved }
        body(recorder)
        // Everything asked of the queue so far has run once this returns.
        NotchSounds.queue.sync {}
    }

    @Test("a tick reaches the player on the sound queue, never on the main thread")
    func tickOffMain() {
        withRecorder { recorder in
            NotchSounds.prepare()
            for _ in 0..<3 { NotchSounds.tick() }
            NotchSounds.queue.sync {}
            let log = recorder.log
            #expect(log.contains { $0.name == "prepare" })
            #expect(log.filter { $0.name == "play" }.count >= 3)
            #expect(log.allSatisfy { !$0.onMain }, "the audio server's wait never lands on main")
        }
    }

    @Test("the HUD's announcement clicks through the same player")
    func hudTicks() {
        withRecorder { recorder in
            let hud = NotchHUD(anchorRect: { nil })
            hud.islandPresent = { _ in true }
            hud.soundEffectsAllowed = { true }
            let before = recorder.log.filter { $0.name == "play" }.count
            hud.announce(NotchAnnouncements.displayNotice(connected: false))
            NotchSounds.queue.sync {}
            let plays = recorder.log.filter { $0.name == "play" }
            #expect(plays.count > before)
            #expect(plays.allSatisfy { !$0.onMain })
        }
    }

    @Test("Tink's player finds the system's sound and loads without playing")
    func tinkLoads() {
        // Prepare only: it loads the file and never starts it.
        let player = TinkPlayer(volume: 0)
        NotchSounds.queue.sync { player.prepare() }
        #expect(TinkPlayer.candidates.contains { FileManager.default.fileExists(atPath: $0) })
    }
}
