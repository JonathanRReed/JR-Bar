import AppKit
import Foundation
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

    @Test func everyMarkIsARealSymbol() {
        for device in [Self.pro(true), Self.dot(true)] {
            for present in [true, false] {
                let symbol = ScreenBarNotices.hardwareSlot(device, present: present).symbol ?? ""
                #expect(NSImage(systemSymbolName: symbol, accessibilityDescription: nil) != nil, "\(symbol)")
            }
        }
    }
}
