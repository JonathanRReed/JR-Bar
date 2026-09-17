import AppKit
import Foundation
import Testing
@testable import JRBarApp

/// The media-key decode: which `data1` layouts carry a HUD-worthy
/// press and which are releases, repeats-of-nothing, or another
/// subtype entirely.
@Suite struct MediaKeyPressTests {

    private func data1(_ key: Int, state: Int = 0x0A, rep: Bool = false) -> Int {
        (key << 16) | (state << 8) | (rep ? 1 : 0)
    }

    @Test func volumeAndBrightnessDownsDecode() {
        #expect(MediaKeyPress.down(type: .systemDefined, subtype: 8,
                                   data1: data1(0))?.key == .volumeUp)
        #expect(MediaKeyPress.down(type: .systemDefined, subtype: 8,
                                   data1: data1(1))?.key == .volumeDown)
        #expect(MediaKeyPress.down(type: .systemDefined, subtype: 8,
                                   data1: data1(2))?.key == .brightnessUp)
        #expect(MediaKeyPress.down(type: .systemDefined, subtype: 8,
                                   data1: data1(3))?.key == .brightnessDown)
        #expect(MediaKeyPress.down(type: .systemDefined, subtype: 8,
                                   data1: data1(7))?.key == .mute)
    }

    @Test func aKeyReleaseIsNotAPress() {
        #expect(MediaKeyPress.down(type: .systemDefined, subtype: 8,
                                   data1: data1(0, state: 0x0B)) == nil,
                "state 0x0B is the release — no HUD for letting go")
    }

    @Test func aHeldKeyRepeats() {
        let press = MediaKeyPress.down(type: .systemDefined, subtype: 8,
                                       data1: data1(0, rep: true))
        #expect(press?.key == .volumeUp)
        #expect(press?.isRepeat == true, "a held key's repeats still nudge the meter")
    }

    @Test func otherSubtypesAndKeysStayQuiet() {
        // Subtype 0 (the system-defined screen-saver/rotation family)
        // and unknown key ids draw nothing.
        #expect(MediaKeyPress.down(type: .systemDefined, subtype: 0,
                                   data1: data1(0)) == nil)
        #expect(MediaKeyPress.down(type: .systemDefined, subtype: 8,
                                   data1: data1(16)) == nil,
                "play is a media transport — not a level capsule")
        // A plain keyDown is not system-defined at all.
        #expect(MediaKeyPress.down(type: .keyDown, subtype: 8,
                                   data1: data1(0)) == nil)
    }
}
