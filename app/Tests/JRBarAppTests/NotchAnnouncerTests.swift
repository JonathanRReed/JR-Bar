import CoreAudio
import Foundation
import Testing
import JRBarCore
@testable import JRBarApp

/// One announcer at the top of the screen: the Mac's own news becomes
/// notices of its own kinds, the level is one continuous fill with the
/// device's glyph, a headphone the ear already names is not said twice,
/// and the island is asked before the pill. No hardware — the notice
/// builders and the glyph map are pure.
@Suite("Notch announcer")
@MainActor
struct NotchAnnouncerTests {
    @Test("volume names the device the sound is going to")
    func volumeGlyphs() {
        #expect(NotchLevelGlyph.volume(level: 0.5, muted: false,
                                       transport: kAudioDeviceTransportTypeBluetooth,
                                       name: "Jonathan's AirPods Pro") == "airpodspro")
        #expect(NotchLevelGlyph.volume(level: 0.5, muted: false,
                                       transport: kAudioDeviceTransportTypeBluetoothLE,
                                       name: "AirPods Max") == "airpodsmax")
        #expect(NotchLevelGlyph.volume(level: 0.5, muted: false,
                                       transport: kAudioDeviceTransportTypeBluetooth,
                                       name: "AirPods") == "airpods")
        #expect(NotchLevelGlyph.volume(level: 0.5, muted: false,
                                       transport: kAudioDeviceTransportTypeBluetooth,
                                       name: "Beats Studio") == "beats.headphones")
        #expect(NotchLevelGlyph.volume(level: 0.5, muted: false,
                                       transport: kAudioDeviceTransportTypeBluetooth,
                                       name: "WH-1000XM5") == "headphones")
        #expect(NotchLevelGlyph.volume(level: 0.5, muted: false,
                                       transport: kAudioDeviceTransportTypeHDMI, name: "LG") == "tv")
        #expect(NotchLevelGlyph.volume(level: 0.5, muted: false,
                                       transport: kAudioDeviceTransportTypeAirPlay,
                                       name: "Living Room") == "airplayaudio")
        #expect(NotchLevelGlyph.volume(level: 0.5, muted: false,
                                       transport: kAudioDeviceTransportTypeBuiltIn,
                                       name: "External Headphones") == "headphones")
        // Built-in speakers: the waves follow the level.
        let speakers = kAudioDeviceTransportTypeBuiltIn
        #expect(NotchLevelGlyph.volume(level: 0.2, muted: false, transport: speakers,
                                       name: "MacBook Pro Speakers") == "speaker.wave.1.fill")
        #expect(NotchLevelGlyph.volume(level: 0.5, muted: false, transport: speakers,
                                       name: "MacBook Pro Speakers") == "speaker.wave.2.fill")
        #expect(NotchLevelGlyph.volume(level: 0.9, muted: false, transport: speakers,
                                       name: "MacBook Pro Speakers") == "speaker.wave.3.fill")
        // Muted or silent is the slash whatever the device.
        #expect(NotchLevelGlyph.volume(level: 0.5, muted: true,
                                       transport: kAudioDeviceTransportTypeBluetooth,
                                       name: "AirPods") == "speaker.slash.fill")
        #expect(NotchLevelGlyph.volume(level: 0, muted: false, transport: nil,
                                       name: nil) == "speaker.slash.fill")
        #expect(NotchLevelGlyph.brightness(level: 0.2) == "sun.min.fill")
        #expect(NotchLevelGlyph.brightness(level: 0.8) == "sun.max.fill")
        #expect(NotchLevelGlyph.title(for: .volumeUp, deviceName: "AirPods") == "AirPods")
        #expect(NotchLevelGlyph.title(for: .mute, deviceName: "") == "Volume")
        #expect(NotchLevelGlyph.title(for: .brightnessDown, deviceName: "AirPods") == "Brightness")
    }

    @Test("a headphone the ear names is its news; a goodbye always speaks")
    func deviceDedup() {
        let airpods = BluetoothWatcher.Change(name: "AirPods Pro", battery: 80,
                                              connected: true, isAudio: true)
        #expect(NotchAnnouncements.deviceNotice(airpods, earAnnouncesAudioRoute: true) == nil)
        let spoken = NotchAnnouncements.deviceNotice(airpods, earAnnouncesAudioRoute: false)
        #expect(spoken?.kind == .device)
        #expect(spoken?.subtitle == "Connected · 80%")
        #expect(spoken?.symbol == "airpodspro")

        var left = airpods
        left.connected = false
        left.battery = nil
        let goodbye = NotchAnnouncements.deviceNotice(left, earAnnouncesAudioRoute: true)
        #expect(goodbye?.subtitle == "Disconnected")
        #expect(goodbye?.key != spoken?.key, "a leave is not a repeat of the join")

        let keyboard = BluetoothWatcher.Change(name: "Magic Keyboard", battery: nil,
                                               connected: true, isAudio: false)
        let typed = NotchAnnouncements.deviceNotice(keyboard, earAnnouncesAudioRoute: true)
        #expect(typed?.symbol == "keyboard", "not audio: the ear never names it")
        #expect(typed?.subtitle == "Connected")
    }

    @Test("Focus says which mode and which way; off names the mode that ended")
    func focus() {
        let on = NotchAnnouncements.focusNotice(name: "Work", on: true)
        #expect(on.kind == .focus)
        #expect(on.title == "Work")
        #expect(on.subtitle == "Focus on")
        #expect(on.symbol == "briefcase.fill")
        let off = NotchAnnouncements.focusNotice(name: "Work", on: false)
        #expect(off.subtitle == "Focus off")
        #expect(off.key != on.key)
        #expect(FocusWatcher.announcedName(now: (false, "Focus"), before: (true, "Work")) == "Work")
        #expect(FocusWatcher.announcedName(now: (true, "Sleep"), before: (true, "Work")) == "Sleep")
        #expect(FocusWatcher.announcedName(now: (false, "Focus"), before: nil) == "Focus")
    }

    @Test("the daemon's quiet state is a Focus only when its source is a Focus")
    func daemonFocus() {
        // "off" is the daemon's nothing-quiet word — never a Focus on.
        #expect(FocusWatcher.daemonFocus(mode: "off", source: nil).on == false)
        #expect(FocusWatcher.daemonFocus(mode: nil, source: nil).on == false)
        #expect(FocusWatcher.daemonFocus(mode: "dim", source: "focus").on)
        // A quiet mode from the menu, or quiet hours, is not the Mac's Focus.
        #expect(FocusWatcher.daemonFocus(mode: "mute", source: "override").on == false)
        #expect(FocusWatcher.daemonFocus(mode: "dark", source: "schedule").on == false)
    }

    @Test("the daemon's first focus document is a baseline: it settles and says nothing")
    func daemonBaseline() {
        let watcher = FocusWatcher()
        var said: [Bool] = []
        var settled: [Bool] = []
        watcher.onChange = { _, on in said.append(on) }
        watcher.onSettle = { _, on in settled.append(on) }
        // Only a Mac whose Assertions.json is unreadable relays.
        watcher.readFile = { nil }
        watcher.noteDaemon(mode: "off", source: nil)
        #expect(said.isEmpty, "no 'Focus off' at launch")
        #expect(settled == [false])
        watcher.noteDaemon(mode: "dim", source: "focus")
        #expect(said == [true])
        #expect(settled == [false, true])
        watcher.noteDaemon(mode: "dim", source: "focus")
        #expect(said == [true], "the same state twice is one flip")
    }

    @Test("Caps Lock is feedback; a display is news")
    func capsAndDisplays() {
        let caps = NotchAnnouncements.capsLockNotice(on: true)
        #expect(caps.kind.isFeedback)
        #expect(caps.symbol == "capslock.fill")
        #expect(NotchAnnouncements.capsLockNotice(on: false).subtitle == "Off")
        let display = NotchAnnouncements.displayNotice(connected: false)
        #expect(!display.kind.isFeedback)
        #expect(display.subtitle == "Disconnected")
    }

    @Test("the HUD asks the island first and the pill stays down when it takes it")
    func islandFirst() {
        let hud = NotchHUD(anchorRect: { nil })
        var offered: [AlcoveNoticeKind] = []
        hud.islandPresent = { notice in
            offered.append(notice.kind)
            return true
        }
        hud.soundEffectsAllowed = { false }
        hud.announce(NotchAnnouncements.displayNotice(connected: true))
        hud.show("SidePulse connected")
        #expect(offered == [.display, .device])
        #expect(hud.panelFrame == nil, "the pill never showed")
    }

    @Test("the HUD duration decodes clamped and defaults to the system's beat")
    func hudDuration() throws {
        #expect(NotchSettings().hudDuration == 2.0)
        let long = try JSONDecoder().decode(NotchSettings.self, from: Data(#"{"hudDuration": 30}"#.utf8))
        #expect(long.hudDuration == NotchSettings.hudDurationRange.upperBound)
        let short = try JSONDecoder().decode(NotchSettings.self, from: Data(#"{"hudDuration": 0.1}"#.utf8))
        #expect(short.hudDuration == NotchSettings.hudDurationRange.lowerBound)
        var custom = NotchSettings()
        custom.hudDuration = 3.5
        let round = try JSONDecoder().decode(NotchSettings.self, from: JSONEncoder().encode(custom))
        #expect(round.hudDuration == 3.5)
    }
}
