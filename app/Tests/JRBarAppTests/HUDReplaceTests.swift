import AppKit
import Foundation
import Testing
@testable import JRBarApp

/// The replace-the-overlay rules: the key→action table, the
/// pass-through rules, and the swallow decisions against a fake
/// volume/brightness backend — no event tap, no hardware.
@Suite struct SystemHUDKeysTests {

    private func press(_ key: MediaKeyPress.Key) -> MediaKeyPress {
        MediaKeyPress(key: key, isRepeat: false)
    }

    @Test func theActionTable() {
        for (key, expected) in [
            (MediaKeyPress.Key.volumeUp, SystemHUDAction.adjustVolume),
            (.volumeDown, .adjustVolume),
            (.mute, .toggleMute),
            (.brightnessUp, .adjustBrightness),
            (.brightnessDown, .adjustBrightness),
        ] {
            #expect(SystemHUDKeys.action(
                for: press(key), flags: [], brightnessWritable: true) == expected)
        }
    }

    @Test func modifierVariantsPassThrough() {
        // Option is fine-step volume / prefs; Shift rides along in the
        // same shortcuts — macOS owns both meanings.
        for flags: NSEvent.ModifierFlags in [.option, .shift, [.option, .shift]] {
            #expect(SystemHUDKeys.action(
                for: press(.volumeUp), flags: flags,
                brightnessWritable: true) == .passThrough)
            #expect(SystemHUDKeys.action(
                for: press(.brightnessUp), flags: flags,
                brightnessWritable: true) == .passThrough)
            #expect(SystemHUDKeys.action(
                for: press(.mute), flags: flags,
                brightnessWritable: true) == .passThrough)
        }
    }

    @Test func illuminationAlwaysPassesThrough() {
        // No reliable public setter for the keyboard backlight — a
        // swallowed key we cannot apply is a lost key, so it passes.
        for key in [MediaKeyPress.Key.illuminationUp,
                    .illuminationDown, .illuminationToggle] {
            #expect(SystemHUDKeys.action(
                for: press(key), flags: [],
                brightnessWritable: true) == .passThrough)
        }
    }

    @Test func brightnessWithoutDisplayServicesPassesThrough() {
        for key in [MediaKeyPress.Key.brightnessUp, .brightnessDown] {
            #expect(SystemHUDKeys.action(
                for: press(key), flags: [],
                brightnessWritable: false) == .passThrough)
        }
        // Volume is unaffected — it never needed the private framework.
        #expect(SystemHUDKeys.action(
            for: press(.volumeUp), flags: [],
            brightnessWritable: false) == .adjustVolume)
    }

    @Test func theStepIsOneSixteenth() {
        #expect(SystemHUDKeys.step == 1.0 / 16.0)
        #expect(SystemHUDKeys.stepped(0.5, up: true) == 0.5625)
        #expect(SystemHUDKeys.stepped(0.5, up: false) == 0.4375)
        // The rails clamp — a press at the end is still honoured.
        #expect(SystemHUDKeys.stepped(1, up: true) == 1)
        #expect(SystemHUDKeys.stepped(0, up: false) == 0)
    }
}

/// `HUDKeyMonitor.handle` against a fake backend — the swallow means
/// the event dies and our value lands; every failure hands the key
/// back to macOS.
@MainActor @Suite struct HUDReplaceMonitorTests {

    private final class FakeBackend: SystemHUDBackend {
        var brightnessWritable = true
        var volumeValue: Float? = 0.5
        var mutedValue: Bool? = false
        var brightnessValue: Float? = 0.5
        var writes: [(String, Float)] = []
        var muteWrites: [Bool] = []
        var failWrites = false

        func volume() -> Float? { volumeValue }
        func muted() -> Bool? { mutedValue }
        func setVolume(_ value: Float) -> Bool {
            guard !failWrites else { return false }
            volumeValue = value
            writes.append(("volume", value))
            return true
        }
        func setMuted(_ muted: Bool) -> Bool {
            guard !failWrites else { return false }
            mutedValue = muted
            muteWrites.append(muted)
            return true
        }
        func brightness() -> Float? { brightnessValue }
        func setBrightness(_ value: Float) -> Bool {
            guard !failWrites else { return false }
            brightnessValue = value
            writes.append(("brightness", value))
            return true
        }
    }

    private func monitor(_ backend: FakeBackend,
                         allowed: Bool = true) -> HUDKeyMonitor {
        let monitor = HUDKeyMonitor()
        monitor.backend = backend
        monitor.isAllowed = { allowed }
        monitor.consuming = true
        return monitor
    }

    private func press(_ key: MediaKeyPress.Key) -> MediaKeyPress {
        MediaKeyPress(key: key, isRepeat: false)
    }

    @Test func aVolumeKeyIsSwallowedAndStepped() {
        let backend = FakeBackend()
        let monitor = monitor(backend)
        var levels: [(MediaKeyPress.Key, Float?)] = []
        monitor.onLevel = { key, value, _ in levels.append((key, value)) }
        #expect(monitor.handle(press(.volumeUp), flags: []))
        #expect(backend.writes.contains {
            $0.0 == "volume" && abs($0.1 - 0.5625) < 0.0001 })
        #expect(levels.count == 1 && levels[0].0 == .volumeUp
                && abs((levels[0].1 ?? 0) - 0.5625) < 0.0001,
                "the capsule draws the value we set")
        #expect(monitor.handle(press(.volumeDown), flags: []))
        #expect(abs((backend.volumeValue ?? 0) - 0.5) < 0.0001,
                "down lands back where the fake started")
    }

    @Test func theMuteKeyToggles() {
        let backend = FakeBackend()
        let monitor = monitor(backend)
        var muted: Bool?
        monitor.onLevel = { _, _, m in muted = m }
        #expect(monitor.handle(press(.mute), flags: []))
        #expect(backend.muteWrites == [true])
        #expect(muted == true)
        #expect(monitor.handle(press(.mute), flags: []))
        #expect(backend.muteWrites == [true, false])
    }

    @Test func aFailedWriteHandsTheKeyBack() {
        let backend = FakeBackend()
        backend.failWrites = true
        let monitor = monitor(backend)
        #expect(!monitor.handle(press(.volumeUp), flags: []),
                "a set that failed re-posts the original event")
        #expect(!monitor.handle(press(.mute), flags: []))
        #expect(backend.muteWrites.isEmpty && backend.writes.isEmpty)
    }

    @Test func aDeviceWithNoLevelPassesThrough() {
        let backend = FakeBackend()
        backend.volumeValue = nil
        backend.mutedValue = nil
        backend.brightnessValue = nil
        let monitor = monitor(backend)
        #expect(!monitor.handle(press(.volumeUp), flags: []))
        #expect(!monitor.handle(press(.mute), flags: []))
        #expect(!monitor.handle(press(.brightnessUp), flags: []))
    }

    @Test func brightnessWithoutTheWriterPassesThrough() {
        let backend = FakeBackend()
        backend.brightnessWritable = false
        let monitor = monitor(backend)
        #expect(!monitor.handle(press(.brightnessUp), flags: []))
        #expect(backend.writes.isEmpty)
    }

    @Test func modifiersAndIlluminationStayUnswallowed() {
        let backend = FakeBackend()
        let monitor = monitor(backend)
        #expect(!monitor.handle(press(.volumeUp), flags: .option))
        #expect(!monitor.handle(press(.brightnessDown), flags: .shift))
        #expect(!monitor.handle(press(.illuminationUp), flags: []))
        #expect(backend.writes.isEmpty)
    }

    @Test func listenModeNeverSwallows() {
        let backend = FakeBackend()
        let monitor = monitor(backend)
        monitor.consuming = false
        #expect(!monitor.handle(press(.volumeUp), flags: []))
        #expect(backend.writes.isEmpty,
                "the listen tap observes; the OS still owns the key")
    }

    @Test func aDeniedCapsuleTouchesNothing() {
        let backend = FakeBackend()
        let monitor = monitor(backend, allowed: false)
        #expect(!monitor.handle(press(.volumeUp), flags: []))
        #expect(backend.writes.isEmpty)
    }
}
