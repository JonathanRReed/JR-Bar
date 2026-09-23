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

    @Test func theMenusOfferTheSystemsSoundsOnce() {
        let available = SoundPlayer.availableSounds()
        #expect(available.system.contains("Glass"))
        #expect(Set(available.system).count == available.system.count)
        #expect(Set(available.custom).isDisjoint(with: available.system))
    }
}
