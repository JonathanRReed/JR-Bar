import Foundation
import JRBarCore
import Testing
@testable import JRBarApp

@MainActor
@Suite("Sound burst policy")
struct SoundBurstTests {
    private struct Play: Equatable {
        let name: String
        let volume: Double
        let alertDevice: Bool
    }

    @MainActor
    private final class Fixture {
        let player = SoundPlayer()
        var preferences = SoundPreferences()
        var microphone = false
        var quiet = false
        var microphoneReads = 0
        var plays: [Play] = []
        var held: [String] = []
        var jobs: [DispatchWorkItem] = []
        var onPlayed: ((String) -> Void)?

        init() {
            player.preferences = { [unowned self] in preferences }
            player.microphoneLive = { [unowned self] in microphoneReads += 1; return microphone }
            player.isHeld = { [unowned self] in quiet }
            player.onHeldForCall = { [unowned self] in held.append($0) }
            player.scheduleBurst = { [unowned self] in jobs.append($0) }
            player.playbackOverride = { [unowned self] name, preferences in
                return { [weak self] in
                    self?.plays.append(Play(name: name, volume: preferences.volume,
                                            alertDevice: preferences.useAlertDevice))
                    self?.onPlayed?(name)
                }
            }
        }

        func step() { jobs.removeFirst().perform() }
    }

    @Test("each delayed ring follows the current microphone hold")
    func microphoneStartsMidBurst() {
        let f = Fixture()
        f.preferences.choices[.ask] = "Original"
        f.player.play(EventPolicy.askSound, repeats: 3)
        f.microphone = true
        f.step()
        #expect(f.plays.count == 1)
        #expect(f.held == ["Original"])
        f.microphone = false
        f.step()
        #expect(f.plays.count == 2)
        #expect(f.jobs.isEmpty)
    }

    @Test("delayed rings resolve the original role with current choice, volume and routing")
    func preferencesChangeMidBurst() {
        let f = Fixture()
        f.preferences.choices[.ask] = "Original"
        f.preferences.volume = 0.8
        f.preferences.useAlertDevice = true
        f.player.play(EventPolicy.askSound, repeats: 3)
        f.preferences.choices[.ask] = "Replacement"
        f.preferences.volume = 0.25
        f.preferences.useAlertDevice = false
        f.step()
        f.preferences.choices[.ask] = SoundPreferences.silent
        f.step()
        #expect(f.plays == [Play(name: "Original", volume: 0.8, alertDevice: true),
                            Play(name: "Replacement", volume: 0.25, alertDevice: false)])
        #expect(f.jobs.isEmpty)
    }

    @Test("zero volume skips mic reads and disabling call quieting applies to the next ring")
    func volumeAndCallPreferenceChange() {
        let f = Fixture()
        f.player.play(EventPolicy.askSound, repeats: 3)
        f.preferences.volume = 0
        f.microphone = true
        f.step()
        #expect(f.plays.count == 1)
        #expect(f.microphoneReads == 1)
        f.preferences.volume = 0.4
        f.preferences.quietOnCalls = false
        f.step()
        #expect(f.plays.last?.volume == 0.4)
        #expect(f.microphoneReads == 1)
        #expect(f.held.isEmpty)
    }

    @Test("a silent new request preserves the existing burst and quiet skips only its delayed ring")
    func silentRequestAndGlobalQuiet() {
        let f = Fixture()
        f.player.play(EventPolicy.askSound, repeats: 3)
        f.preferences.choices[.completion] = SoundPreferences.silent
        f.player.play(EventPolicy.completionSound)
        #expect(f.jobs.count == 1)
        f.quiet = true
        f.step()
        #expect(f.plays.count == 1)
        f.quiet = false
        f.step()
        #expect(f.plays.map(\.name) == [EventPolicy.askSound, EventPolicy.askSound])
    }

    @Test("a replacement burst started during playback receives no extra schedule from the old burst")
    func reentrantReplacementOwnsItsSchedule() {
        let f = Fixture()
        f.preferences.choices[.ask] = "Original"
        f.player.play(EventPolicy.askSound, repeats: 3)
        f.onPlayed = { name in
            guard name == "Original" else { return }
            f.onPlayed = nil
            f.player.play("Replacement", repeats: 3)
        }
        f.step()
        #expect(f.jobs.count == 1)
        f.step()
        f.step()
        #expect(f.plays.map(\.name) == ["Original", "Original", "Replacement", "Replacement", "Replacement"])
        #expect(f.jobs.isEmpty)
    }
}
