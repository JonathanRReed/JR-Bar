import CoreAudio
import Foundation
import Testing
@testable import JRBarApp

/// The notch's audio surfaces read the default device and its facts
/// through one set of pure CoreAudio readers. Nothing here listens,
/// writes or depends on which device this Mac has.
@Suite("CoreAudio defaults")
struct CoreAudioDefaultsTests {
    @Test("an object CoreAudio does not know answers nil, never a zero value")
    func unknownObjectReadsNil() {
        let unknown = AudioObjectID(kAudioObjectUnknown)
        #expect(CoreAudioDefaults.name(of: unknown) == nil)
        #expect(CoreAudioDefaults.transport(of: unknown) == nil)
        #expect(CoreAudioDefaults.uid(of: unknown) == nil)
        #expect(CoreAudioDefaults.volume(of: unknown, scope: kAudioObjectPropertyScopeOutput) == nil)
        #expect(CoreAudioDefaults.muted(of: unknown, scope: kAudioObjectPropertyScopeOutput) == nil)
    }

    @Test("a default device read never hands back kAudioObjectUnknown")
    func defaultsAreNeverUnknown() {
        for device in [CoreAudioDefaults.defaultOutput, CoreAudioDefaults.defaultInput] {
            if let device { #expect(device != kAudioObjectUnknown) }
        }
    }

    @Test("the notch's audio readers go through CoreAudioDefaults, not their own HAL reads")
    func readersShareOnePath() throws {
        let sources = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appending(path: "Sources/JRBarApp")
        let pinned = [
            "NotchHUDKeys.swift": ["kAudioObjectPropertyName", "kAudioDevicePropertyTransportType"],
            "ScreenBarNotices.swift": ["kAudioObjectPropertyName", "kAudioDevicePropertyTransportType",
                                       "AudioObjectGetPropertyData"],
            "Toys/Notch/SystemTogglesStore.swift": ["kAudioDevicePropertyDeviceUID"],
            "Toys/Notch/AudioLevelTap.swift": ["kAudioDevicePropertyDeviceUID"],
        ]
        for (file, banned) in pinned {
            let text = try String(contentsOf: sources.appending(path: file), encoding: .utf8)
            #expect(text.contains("CoreAudioDefaults."), "\(file) reads through CoreAudioDefaults")
            for symbol in banned {
                #expect(!text.contains(symbol), "\(file) still reads \(symbol) itself")
            }
        }
    }
}
