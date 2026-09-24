import AppKit
import Foundation
import SwiftUI
import Testing
import JRBarCore
@testable import JRBarApp

/// The tank outside its window: the live wallpaper's picker and the idle
/// screensaver's rules. The panels themselves need a screen; the rules
/// that decide when they show are pure and pinned here.
@Suite("Aquarium ambient")
struct AquariumAmbientTests {
    @Test("the idle clock alone: at or past the minutes, never when off")
    func idleClock() {
        #expect(AquariumScreensaver.isIdle(idleSeconds: 600, minutes: 10))
        #expect(AquariumScreensaver.isIdle(idleSeconds: 601, minutes: 10))
        #expect(!AquariumScreensaver.isIdle(idleSeconds: 599, minutes: 10))
        #expect(!AquariumScreensaver.isIdle(idleSeconds: 99_999, minutes: 0), "0 is off")
        #expect(!AquariumScreensaver.isIdle(idleSeconds: .infinity, minutes: 5))
        #expect(!AquariumScreensaver.isIdle(idleSeconds: .nan, minutes: 5))
    }

    @Test("the room vetoes: a lock screen, someone watching, no free screen")
    func roomVetoes() {
        func show(locked: Bool = false, watching: Bool = false, free: Int = 1) -> Bool {
            AquariumScreensaver.shouldShow(idleSeconds: 900, minutes: 10, locked: locked,
                                           someoneWatching: watching, freeScreens: free)
        }
        #expect(show())
        #expect(!show(locked: true))
        #expect(!show(watching: true))
        #expect(!show(free: 0), "every screen is a fullscreen app's")
        #expect(!AquariumScreensaver.shouldShow(idleSeconds: 60, minutes: 10, locked: false,
                                                someoneWatching: false, freeScreens: 2))
    }

    @Test("input since showing: the idle clock fell behind the time it's been up")
    func inputSinceShowing() {
        // Up for 30 s and idle for 630: nobody touched it.
        #expect(!AquariumScreensaver.inputSinceShowing(idleSeconds: 630, shownFor: 30))
        // The poll's own jitter is not a touch.
        #expect(!AquariumScreensaver.inputSinceShowing(idleSeconds: 29.9, shownFor: 30))
        // A key two seconds ago.
        #expect(AquariumScreensaver.inputSinceShowing(idleSeconds: 2, shownFor: 30))
    }

    @Test("a video or a call holding the display is watching; our own keep-awake isn't")
    func watching() {
        typealias A = AquariumScreensaver.Assertion
        let own: Int32 = 42
        #expect(AquariumScreensaver.isWatching(
            [A(pid: 7, process: "IINA", type: "PreventUserIdleDisplaySleep")], ownPID: own))
        #expect(!AquariumScreensaver.isWatching(
            [A(pid: 9, process: "caffeinate", type: "PreventUserIdleDisplaySleep")], ownPID: own),
            "JR-Bar's keep-display-awake is the reason the screen is lit")
        #expect(!AquariumScreensaver.isWatching(
            [A(pid: own, process: "JR-Bar", type: "PreventUserIdleDisplaySleep")], ownPID: own))
        #expect(!AquariumScreensaver.isWatching(
            [A(pid: 7, process: "backupd", type: "PreventUserIdleSystemSleep")], ownPID: own),
            "keeping the system up is not watching the screen")
        #expect(!AquariumScreensaver.isWatching([], ownPID: own))
    }

    @Test("the wallpaper picker lists each display once, and keeps an unplugged pick")
    func displayChoices() {
        #expect(AquariumWallpaper.displayChoices(connected: ["Built-in", "LG", "LG"], saved: nil)
                == ["Built-in", "LG"])
        #expect(AquariumWallpaper.displayChoices(connected: ["Built-in"], saved: "Studio Display")
                == ["Built-in", "Studio Display"])
        #expect(AquariumWallpaper.displayChoices(connected: ["Built-in", "LG"], saved: "LG")
                == ["Built-in", "LG"])
    }

    @Test("the screensaver's clock defaults on and reads tolerantly")
    func clockSetting() throws {
        #expect(AquariumSettings().saverClock)
        let off = try JSONDecoder().decode(AquariumSettings.self, from: Data(#"{"saverClock": false}"#.utf8))
        #expect(!off.saverClock)
        let junk = try JSONDecoder().decode(AquariumSettings.self, from: Data(#"{"saverClock": 2}"#.utf8))
        #expect(junk.saverClock)
    }

    @MainActor
    @Test("the screensaver wears the clock; the wallpaper never does")
    func clockGate() throws {
        var settings = AquariumSettings()
        #expect(AquariumSceneryView.wearsClock(panel: true, settings: settings))
        #expect(!AquariumSceneryView.wearsClock(panel: false, settings: settings), "the wallpaper")
        settings.saverClock = false
        #expect(!AquariumSceneryView.wearsClock(panel: true, settings: settings))
        // And the scenery draws with it on.
        let core = CoreModel()
        let store = ToysStore(core: core, settings: SettingsStore(core: core), state: ToysState(),
                              cardModel: makeTestCardModel(), notchRuntimeEnabled: false)
        let tank = try #require(store.aquarium)
        let renderer = ImageRenderer(content: AquariumSceneryView(toy: tank, clock: true)
            .frame(width: 480, height: 300))
        renderer.scale = 1
        #expect(renderer.cgImage != nil)
    }

    @MainActor
    @Test("with the window closed, the chip names a scenery surface that still draws")
    func closedChip() {
        #expect(AquariumToy.closedStatus(wallpaper: nil, connected: ["Built-in"], saverMinutes: 0)
                == .note("Watching quietly"))
        #expect(AquariumToy.closedStatus(wallpaper: "LG", connected: ["Built-in", "LG"], saverMinutes: 10)
                == .note("Live wallpaper on LG"), "drawing now outranks armed")
        #expect(AquariumToy.closedStatus(wallpaper: "LG", connected: ["Built-in"], saverMinutes: 10)
                == .note("Screensaver after 10 min"), "an unplugged display draws nothing")
        #expect(AquariumToy.closedStatus(wallpaper: "LG", connected: ["Built-in"], saverMinutes: 0)
                == .note("Watching quietly"))
        #expect(ToyStatus.note("x").tint == ToyStatus.unavailable("x").tint,
                "a closed tank that keeps count is a neutral fact, not the paused orange")
    }

    @MainActor
    @Test("a chip draws only when it says more than the switch beside it")
    func chipsOnlyWhenInformative() {
        #expect(!ToyStatus.on.showsChip)
        #expect(!ToyStatus.off.showsChip)
        #expect(ToyStatus.paused("Island hidden").showsChip)
        #expect(ToyStatus.note("Watching quietly").showsChip)
        #expect(ToyStatus.needsPermission("Needs Accessibility").showsChip)
        #expect(ToyStatus.external("Alcove is rendering it").showsChip)
        #expect(ToyStatus.unavailable("Alcove isn't installed").showsChip)
        #expect(ToyStatus.limited("Wallpaper only").showsChip)
    }

    private final class Touches { var count = 0 }

    @MainActor
    @Test("the screensaver takes the waking key itself; the wallpaper never takes the keyboard")
    func saverSwallowsKeys() throws {
        let core = CoreModel()
        let store = ToysStore(core: core, settings: SettingsStore(core: core), state: ToysState(),
                              cardModel: makeTestCardModel(), notchRuntimeEnabled: false)
        let tank = try #require(store.aquarium)
        let frame = NSRect(x: 0, y: 0, width: 320, height: 200)
        let saver = AquariumAmbientPanel(frame: frame, toy: tank, mode: .screensaver)
        let wallpaper = AquariumAmbientPanel(frame: frame, toy: tank, mode: .wallpaper)
        #expect(saver.canBecomeKey, "so Return never reaches a hidden agent prompt")
        #expect(!saver.canBecomeMain)
        #expect(!wallpaper.canBecomeKey)
        let touches = Touches()
        saver.onTouch = { touches.count += 1 }

        func key(_ type: NSEvent.EventType, _ characters: String, code: UInt16,
                 flags: NSEvent.ModifierFlags = []) throws -> NSEvent {
            try #require(NSEvent.keyEvent(with: type, location: .zero, modifierFlags: flags,
                                          timestamp: 0, windowNumber: saver.windowNumber,
                                          context: nil, characters: characters,
                                          charactersIgnoringModifiers: characters,
                                          isARepeat: false, keyCode: code))
        }
        // Return, the key that would approve a tool call underneath.
        saver.sendEvent(try key(.keyDown, "\r", code: 36))
        #expect(touches.count == 1)
        saver.sendEvent(try key(.keyUp, "\r", code: 36))
        #expect(touches.count == 2)
        // A lone modifier wakes it too.
        saver.sendEvent(try key(.flagsChanged, "", code: 56, flags: .shift))
        #expect(touches.count == 3)
        // ⌘Q wakes the tank; it neither quits JR-Bar nor passes on.
        #expect(saver.performKeyEquivalent(with: try key(.keyDown, "q", code: 12, flags: .command)))
        #expect(touches.count == 4)
        saver.close()
        wallpaper.close()
    }

    @Test("both switches default off, round-trip, and read tolerantly")
    func settings() throws {
        let fresh = AquariumSettings()
        #expect(fresh.idleFillMinutes == 0)
        #expect(fresh.ambientDisplay == nil)

        var on = AquariumSettings(enabled: true)
        on.idleFillMinutes = 15
        on.ambientDisplay = "LG UltraFine"
        let back = try JSONDecoder().decode(AquariumSettings.self,
                                            from: JSONEncoder().encode(on))
        #expect(back == on)

        func decode(_ json: String) throws -> AquariumSettings {
            try JSONDecoder().decode(AquariumSettings.self, from: Data(json.utf8))
        }
        // A file from before either existed.
        let old = try decode(#"{"enabled": true, "density": 0.5}"#)
        #expect(old.idleFillMinutes == 0 && old.ambientDisplay == nil)
        #expect(old.density == 0.5)
        // A minute count the picker never offers is off, not a surprise.
        #expect(try decode(#"{"idleFillMinutes": 7}"#).idleFillMinutes == 0)
        #expect(try decode(#"{"idleFillMinutes": "ten"}"#).idleFillMinutes == 0)
        #expect(try decode(#"{"idleFillMinutes": 30}"#).idleFillMinutes == 30)
        // An empty or mistyped display name is no display.
        #expect(try decode(#"{"ambientDisplay": ""}"#).ambientDisplay == nil)
        #expect(try decode(#"{"ambientDisplay": 3, "showLabels": false}"#).ambientDisplay == nil)
        #expect(try decode(#"{"ambientDisplay": 3, "showLabels": false}"#).showLabels == false)
    }
}
