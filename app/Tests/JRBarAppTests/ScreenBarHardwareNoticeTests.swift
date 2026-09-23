import AppKit
import Foundation
import JRBarLEDS
import Testing
@testable import JRBarCore
@testable import JRBarApp

/// A strip or Dot arriving or leaving holds the right ear for a beat —
/// a mark, the words in VoiceOver — so an unplugged Pro no longer just
/// goes dark with nothing said.
@Suite("Screen Bar hardware notices")
@MainActor
struct ScreenBarHardwareNoticeTests {
    private static let now = Date(timeIntervalSince1970: 1_800_000_000)

    private static func pro(_ connected: Bool, name: String? = "SidePulse Pro") -> CoreDevice {
        CoreDevice(id: "pro-1", kind: "pro", name: name, leds: 8, connected: connected)
    }

    private static func dot(_ connected: Bool) -> CoreDevice {
        CoreDevice(id: "dot-1", kind: "dot", name: "PulseDot", leds: 2, connected: connected)
    }

    private static let bar = CoreDevice(id: "screen-bar", kind: "screen_bar", enabled: true)

    @Test func theFirstListIsABaselineNotAnArrival() {
        let result = ScreenBarNotices.hardware(from: nil, to: [Self.pro(true), Self.bar], recent: [:], now: Self.now)
        #expect(result.slot == nil)
        #expect(result.recent.isEmpty)
    }

    @Test func anUnplugIsAHollowAmberMark() throws {
        let result = ScreenBarNotices.hardware(from: [Self.pro(true)], to: [Self.pro(false)], recent: [:], now: Self.now)
        let slot = try #require(result.slot)
        #expect(slot.symbol == "light.beacon.max")
        #expect(slot.tone == .attention)
        #expect(slot.text.hasPrefix("SidePulse Pro unplugged"))
        #expect(result.recent["device:pro-1"] == Self.now)
    }

    @Test func anArrivalIsTheFilledGlyph() throws {
        let slot = try #require(ScreenBarNotices.hardware(from: [Self.dot(false)], to: [Self.dot(true)],
                                                          recent: [:], now: Self.now).slot)
        #expect(slot.symbol == "circle.grid.2x1.fill")
        #expect(slot.tone == .neutral)
        #expect(slot.text == "PulseDot connected")
    }

    @Test func aRowThatVanishesWhilePresentIsALeaving() throws {
        let slot = try #require(ScreenBarNotices.hardware(from: [Self.pro(true), Self.bar], to: [Self.bar],
                                                          recent: [:], now: Self.now).slot)
        #expect(slot.symbol == "light.beacon.max")
    }

    @Test func aNewRowAlreadyConnectedIsAnArrival() {
        let slot = ScreenBarNotices.hardware(from: [Self.bar], to: [Self.bar, Self.pro(true)],
                                             recent: [:], now: Self.now).slot
        #expect(slot?.symbol == "light.beacon.max.fill")
    }

    @Test func theScreenBarsOwnRowIsNotHardware() {
        let off = CoreDevice(id: "screen-bar", kind: "screen_bar", enabled: false)
        #expect(ScreenBarNotices.hardware(from: [Self.bar], to: [off], recent: [:], now: Self.now).slot == nil)
    }

    @Test func nothingMovedSaysNothing() {
        var written = Self.pro(true)
        written.lastWrite = 1_800_000_010
        #expect(ScreenBarNotices.hardware(from: [Self.pro(true)], to: [written], recent: [:], now: Self.now).slot == nil)
    }

    @Test func aFlapInsideTheCooldownIsStrobe() {
        let first = ScreenBarNotices.hardware(from: [Self.pro(true)], to: [Self.pro(false)], recent: [:], now: Self.now)
        #expect(first.slot != nil)
        let back = ScreenBarNotices.hardware(from: [Self.pro(false)], to: [Self.pro(true)], recent: first.recent,
                                             now: Self.now.addingTimeInterval(2))
        #expect(back.slot == nil, "the SD reader powering the Pro off and on is not two pieces of news")
        let later = ScreenBarNotices.hardware(from: [Self.pro(true)], to: [Self.pro(false)], recent: back.recent,
                                              now: Self.now.addingTimeInterval(ScreenBarNotices.cooldown + 1))
        #expect(later.slot != nil)
    }

    @Test func theStripWinsTheBeat() {
        let slot = ScreenBarNotices.hardware(from: [Self.dot(true), Self.pro(true)], to: [Self.dot(false), Self.pro(false)],
                                             recent: [:], now: Self.now).slot
        #expect(slot?.symbol == "light.beacon.max")
    }

    @Test func anUnnamedDeviceStillHasAName() {
        let slot = ScreenBarNotices.hardwareSlot(Self.pro(true, name: nil), present: true)
        #expect(slot.text == "SidePulse Pro connected")
    }

    // MARK: Unplug grace

    @Test func aStripLeavingIsNoticedOnlyWhenItWasLit() {
        #expect(ScreenBarController.stripLeft(from: [Self.pro(true)], to: [Self.pro(false)]))
        #expect(ScreenBarController.stripLeft(from: [Self.pro(true), Self.bar], to: [Self.bar]))
        #expect(!ScreenBarController.stripLeft(from: nil, to: []), "a baseline is not a departure")
        #expect(!ScreenBarController.stripLeft(from: [Self.pro(false)], to: []))
        #expect(!ScreenBarController.stripLeft(from: [Self.dot(true)], to: [Self.dot(false)]),
                "the band mirrors the strip; a Dot leaving changes nothing it plays")
        #expect(!ScreenBarController.stripLeft(from: [Self.pro(true)], to: [Self.pro(true)]))
    }

    @Test func theOfflineFeedWaitsOutAnUnplugBeforeTheIdleBreath() {
        let device = LEDFeed.Source.device("/Volumes/SidePulse/LEDS.LED")
        #expect(LEDFeed.readDelay(from: device, to: .builtInIdle) == LEDFeed.unplugGrace)
        #expect(LEDFeed.readDelay(from: .builtInIdle, to: device) < 0.5, "an arrival reads at once")
        #expect(LEDFeed.readDelay(from: device, to: device) < 0.5)
        #expect(LEDFeed.readDelay(from: .stateFile("/tmp/x.led"), to: .builtInIdle) < 0.5,
                "an emptied override file is not an unplug")
    }

    @Test func aLevelOnlyChangeIsTheSameProgramAtAnotherBrightness() {
        let bright = "brightness 200\n#FF9F0A 1.4s pulse\noff 400ms none\nrepeat"
        let dim = "brightness 90\n#FF9F0A 1.4s pulse\noff 400ms none\nrepeat\n"
        #expect(ScreenBarController.onlyBrightnessChanged(from: bright, to: dim))
        // Brightness is global: where the line sits does not matter.
        #expect(ScreenBarController.onlyBrightnessChanged(from: bright, to: "#FF9F0A 1.4s pulse\noff 400ms none\nrepeat\nBrightness 90"))
        // No line is 255; adding one is a level change too.
        #expect(ScreenBarController.onlyBrightnessChanged(from: "#FF9F0A 1.4s pulse\nrepeat", to: "brightness 64\n#FF9F0A 1.4s pulse\nrepeat"))
        #expect(!ScreenBarController.onlyBrightnessChanged(from: bright, to: bright), "nothing changed")
        #expect(!ScreenBarController.onlyBrightnessChanged(from: bright, to: "brightness 90\n#00FF66 1.4s pulse\noff 400ms none\nrepeat"),
                "a new colour is a new program")
        #expect(!ScreenBarController.onlyBrightnessChanged(from: "", to: dim), "the first program is not a dimmer step")
    }

    @Test func anArmedCrossfadeIsUsedByTheNextChangeOnly() {
        // Both halves pin Reduce Motion instead of reading this Mac's:
        // CI's runner image turns it on, and there the fade half would
        // never run.
        let view = ScreenBarView(frame: NSRect(x: 0, y: 0, width: 500, height: 48))
        view.relayout()
        view.crossfadeNextChange(over: 1.2, reduceMotion: false)
        #expect(view.hasPendingCrossfade)
        view.display(colors: Array(repeating: RGB(r: 1, g: 0.5, b: 0), count: 8))
        #expect(!view.hasPendingCrossfade)
        view.display(colors: Array(repeating: RGB(r: 0, g: 0.5, b: 1), count: 8))
        #expect(!view.hasPendingCrossfade, "used once, not re-armed by the change after")

        view.crossfadeNextChange(over: 1.2, reduceMotion: true)
        #expect(!view.hasPendingCrossfade, "Reduce Motion keeps the cut")
    }

    @Test func everyMarkIsARealSymbol() {
        for device in [Self.pro(true), Self.dot(true)] {
            for present in [true, false] {
                let symbol = ScreenBarNotices.hardwareSlot(device, present: present).symbol ?? ""
                #expect(NSImage(systemSymbolName: symbol, accessibilityDescription: nil) != nil, "\(symbol)")
            }
        }
    }
}
