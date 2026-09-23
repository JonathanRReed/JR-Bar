import Foundation
import JRBarCore
import Testing
@testable import JRBarApp

/// Settings › Sounds: a role's default name plays the person's choice
/// for that moment (or nothing), any other name plays as asked, and the
/// choices survive a relaunch. Nothing here plays a sound.
@Suite struct SoundPreferencesTests {
    @Test func theRolesAreTheEventPolicysOwnSounds() {
        #expect(SoundRole(defaultName: EventPolicy.completionSound) == .completion)
        #expect(SoundRole(defaultName: "funk") == .ask)
        #expect(SoundRole(defaultName: EventPolicy.chimeSound) == .chime)
        #expect(SoundRole(defaultName: "Ping") == nil)
        #expect(Set(SoundRole.allCases.map(\.defaultSound)).count == SoundRole.allCases.count)
    }

    @Test func aChoiceReplacesItsRolesSoundAndSilenceIsNil() {
        var preferences = SoundPreferences()
        #expect(preferences.resolve("Glass") == "Glass")
        preferences.choices[.completion] = "Tink"
        preferences.choices[.ask] = SoundPreferences.silent
        #expect(preferences.resolve("Glass") == "Tink")
        #expect(preferences.resolve("Funk") == nil)
        // A sound a daemon event names itself is not a role: it plays.
        #expect(preferences.resolve("Submarine") == "Submarine")
    }

    @Test func choicesVolumeAndDeviceSurviveARelaunch() throws {
        let suite = "SoundPreferencesTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        #expect(SoundPreferences.load(from: defaults) == SoundPreferences())
        var preferences = SoundPreferences()
        preferences.choices[.chime] = "Purr"
        preferences.volume = 0.4
        preferences.useAlertDevice = true
        preferences.save(to: defaults)
        #expect(SoundPreferences.load(from: defaults) == preferences)
        // Back to the default forgets the stored choice.
        preferences.choices[.chime] = nil
        preferences.save(to: defaults)
        #expect(defaults.string(forKey: SoundPreferences.choiceKey(.chime)) == nil)
        defaults.set(3.0, forKey: SoundPreferences.volumeKey)
        #expect(SoundPreferences.load(from: defaults).volume == 1)
    }

    @Test func aLiveMicrophoneHoldsTheSoundOnlyWhenAsked() {
        var preferences = SoundPreferences()
        #expect(preferences.quietOnCalls, "on unless turned off")
        #expect(preferences.resolve("Glass", micLive: { true }) == nil)
        #expect(preferences.resolve("Glass", micLive: { false }) == "Glass")
        preferences.choices[.ask] = SoundPreferences.silent
        var asked = false
        #expect(preferences.resolve("Funk", micLive: { asked = true; return true }) == nil)
        #expect(!asked, "silence needs no microphone read")
        preferences.quietOnCalls = false
        #expect(preferences.resolve("Glass", micLive: { asked = true; return true }) == "Glass")
        #expect(!asked, "off never reads the microphone")
    }

    @Test func quietOnCallsSurvivesARelaunch() throws {
        let suite = "SoundPreferencesTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        var preferences = SoundPreferences()
        preferences.quietOnCalls = false
        preferences.save(to: defaults)
        #expect(SoundPreferences.load(from: defaults).quietOnCalls == false)
        #expect(SettingsBundle.travels(SoundPreferences.quietOnCallsKey))
    }

    @MainActor @Test func thePlayerHoldsASoundForALiveMicrophone() {
        let player = SoundPlayer()
        player.preferences = { SoundPreferences() }
        player.microphoneLive = { true }
        var held: [String] = []
        player.onHeldForCall = { held.append($0) }
        player.play(EventPolicy.completionSound)
        #expect(held == [EventPolicy.completionSound])
    }

    @Test func onlyAnotherAppsMicrophoneInputIsACall() {
        typealias Client = MicrophoneCapture.Client
        let own: pid_t = 100
        // Music through AirPods: output only.
        #expect(!MicrophoneCapture.isLive([Client(pid: 200, runningInput: false, microphoneDevices: 0)], ownPID: own))
        // JR-Bar's own notch visualizer taps output in this process.
        #expect(!MicrophoneCapture.isLive([Client(pid: own, runningInput: true, microphoneDevices: 1)], ownPID: own))
        // Another app's tap on system audio runs input from no device.
        #expect(!MicrophoneCapture.isLive([Client(pid: 300, runningInput: true, microphoneDevices: 0)], ownPID: own))
        // A call.
        #expect(MicrophoneCapture.isLive([Client(pid: 200, runningInput: false, microphoneDevices: 0),
                                          Client(pid: 400, runningInput: true, microphoneDevices: 1)], ownPID: own))
        #expect(!MicrophoneCapture.isLive([], ownPID: own))
    }

    @Test func theReaderNeverCountsThisProcess() {
        let clients = MicrophoneCapture.clients(skipping: getpid())
        #expect(clients.filter { $0.pid == getpid() }.allSatisfy { $0.microphoneDevices == 0 })
    }

    @Test func theMenusOfferTheSystemsSoundsOnce() {
        let available = SoundPlayer.availableSounds()
        #expect(available.system.contains("Glass"))
        #expect(Set(available.system).count == available.system.count)
        #expect(Set(available.custom).isDisjoint(with: available.system))
    }
}

