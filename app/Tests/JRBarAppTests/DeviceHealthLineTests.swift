import Foundation
import Testing
@testable import JRBarCore
@testable import JRBarApp

/// A device card's "Right now" line: what the strip or Dot was last
/// sent and how that write went, instead of a bare "Connected".
@Suite("Device health line")
@MainActor
struct DeviceHealthLineTests {
    private static let now = Date(timeIntervalSince1970: 1_800_000_000)
    private static let program = "#FF9F0A 420ms pulse\noff 420ms pulse\nrepeat"

    private static func pro(id: String = "pro-1", connected: Bool = true, lastWrite: Double? = 1_799_999_988,
                            error: String? = nil) -> CoreDevice {
        CoreDevice(id: id, kind: "pro", name: "SidePulse Pro", leds: 8, connected: connected,
                   lastWrite: lastWrite, error: error)
    }

    @Test func aStripSaysWhyWhenAndHowBig() {
        let surface = CoreLightSurface(program: Self.program, brightness: 0.79, why: "waiting")
        let line = DeviceHealthLine.describe(device: Self.pro(), surface: surface, now: Self.now)
        #expect(line == "Waiting · written 12 s ago · 3 lines, \(Self.program.utf8.count) of 512 bytes · driven at 79%")
    }

    @Test func anAbsentDeviceLeavesItToTheHeader() {
        #expect(DeviceHealthLine.describe(device: Self.pro(connected: false), surface: nil, now: Self.now) == nil)
        #expect(DeviceHealthLine.describe(device: nil, surface: nil, now: Self.now) == nil)
    }

    @Test func aFailedWriteIsNamed() throws {
        let line = try #require(DeviceHealthLine.describe(device: Self.pro(error: "write_timeout"), surface: nil, now: Self.now))
        #expect(line.contains("the last write failed (write timeout)"))
    }

    @Test func noWriteYetIsSaidPlainly() throws {
        let line = try #require(DeviceHealthLine.describe(device: Self.pro(lastWrite: nil), surface: nil, now: Self.now))
        #expect(line == "not written since the monitor started")
    }

    @Test func aProgramTheFirmwareWouldRefuseIsFlagged() throws {
        let surface = CoreLightSurface(program: "#c 100ms", why: "studio")
        let line = try #require(DeviceHealthLine.describe(device: Self.pro(), surface: surface, now: Self.now))
        #expect(line.contains("the firmware would reject this program: bad-color"))
    }

    @Test func agesAreCoarse() {
        #expect(DeviceHealthLine.age(-3) == "0 s")
        #expect(DeviceHealthLine.age(59) == "59 s")
        #expect(DeviceHealthLine.age(125) == "2 min")
        #expect(DeviceHealthLine.age(7300) == "2 h")
    }

    @Test func eachDeviceReadsItsOwnSurface() {
        let strip = CoreLightSurface(program: "#FF0000 1s none", why: "failed")
        let second = CoreLightSurface(program: "#00FF00 1s none", why: "working")
        let dot = CoreLightSurface(program: "#0000FF 1s none", why: "waiting")
        let lights = CoreLights(surfaces: ["hardware": strip, "hardware:pro-2": second, "dot": dot])
        let devices = [Self.pro(), Self.pro(id: "pro-2"),
                       CoreDevice(id: "dot-1", kind: "dot", leds: 2, connected: true)]
        #expect(DeviceHealthLine.surface(for: devices[0], lights: lights, devices: devices) == strip)
        #expect(DeviceHealthLine.surface(for: devices[1], lights: lights, devices: devices) == second)
        #expect(DeviceHealthLine.surface(for: devices[2], lights: lights, devices: devices) == dot)
        // A strip that is not the first and has no surface of its own plays nothing we know of.
        let third = Self.pro(id: "pro-3")
        #expect(DeviceHealthLine.surface(for: third, lights: lights, devices: devices + [third]) == nil)
        #expect(DeviceHealthLine.surface(for: devices[0], lights: nil, devices: devices) == nil)
    }
}
