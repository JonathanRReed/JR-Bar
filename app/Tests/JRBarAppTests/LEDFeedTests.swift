import Foundation
import Testing
@testable import JRBarApp

/// `LEDFeed.resolveDevicePath` -- the mounted-volume rules the daemon uses:
/// a name hint or STATUS.TXT beside LEDS.LED makes a device, the serial
/// outranks the name, and a strip wins over a Dot.
@Suite("LED feed device discovery")
struct LEDFeedTests {
    private func makeVolumesRoot() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("jrbar-volumes-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    @discardableResult
    private func makeVolume(_ root: URL, _ name: String, ledFile: Bool = true, status: String? = nil, marker: Bool = false) throws -> URL {
        let volume = root.appendingPathComponent(name)
        try FileManager.default.createDirectory(at: volume, withIntermediateDirectories: true)
        if ledFile {
            try "off\n".write(to: volume.appendingPathComponent("LEDS.LED"), atomically: true, encoding: .utf8)
        }
        if let status {
            try status.write(to: volume.appendingPathComponent("STATUS.TXT"), atomically: true, encoding: .utf8)
        } else if marker {
            try "".write(to: volume.appendingPathComponent("STATUS.TXT"), atomically: true, encoding: .utf8)
        }
        return volume
    }

    @Test func noVolumesMeansNoDevice() throws {
        let root = try makeVolumesRoot()
        #expect(LEDFeed.resolveDevicePath(volumesDirectory: root.path) == nil)
    }

    @Test func aLoneDotIsADevice() throws {
        let root = try makeVolumesRoot()
        try makeVolume(root, "PulseDot")
        #expect(LEDFeed.resolveDevicePath(volumesDirectory: root.path) == root.appendingPathComponent("PulseDot/LEDS.LED").path)
    }

    @Test func aStripWinsOverADot() throws {
        let root = try makeVolumesRoot()
        try makeVolume(root, "PulseDot")
        // The live Pro mounts as bare "SidePulse" -- a name the daemon's
        // device_kind reads as a Dot. Its STATUS.TXT serial (SPP, eight
        // LEDs) is what makes it the strip, and the strip wins the feed.
        try makeVolume(root, "SidePulse", status: "serial SPP-000067\n")
        #expect(LEDFeed.resolveDevicePath(volumesDirectory: root.path) == root.appendingPathComponent("SidePulse/LEDS.LED").path)
    }

    @Test func theSerialOutranksTheMountName() throws {
        let root = try makeVolumesRoot()
        // Named like the live Pro, but the firmware says Dot.
        try makeVolume(root, "SidePulse", status: "serial SPD-000042\n")
        // No name hint at all; the serial says strip.
        try makeVolume(root, "Foo", status: "serial SPP-000067\n")
        #expect(LEDFeed.resolveDevicePath(volumesDirectory: root.path) == root.appendingPathComponent("Foo/LEDS.LED").path)
    }

    @Test func aFileNamedLikeALedFileOnAnUnknownVolumeIsNotADevice() throws {
        let root = try makeVolumesRoot()
        try makeVolume(root, "Somebody Elses Card")
        #expect(LEDFeed.resolveDevicePath(volumesDirectory: root.path) == nil)
        // The firmware's own telemetry file is the other identity.
        try makeVolume(root, "Untitled", marker: true)
        #expect(LEDFeed.resolveDevicePath(volumesDirectory: root.path) == root.appendingPathComponent("Untitled/LEDS.LED").path)
    }

    @Test func isDotVolumeFollowsSerialThenName() throws {
        let root = try makeVolumesRoot()
        let dot = try makeVolume(root, "PulseDot")
        #expect(LEDFeed.isDotVolume(dot.path))
        // Bare "SidePulse" is ambiguous: the daemon's device_kind calls
        // it a Dot, and guessing strip would push eight-LED programs to
        // two-LED hardware. The real Pro's SPP serial is what lifts it.
        let ambiguous = try makeVolume(root, "SidePulse")
        #expect(LEDFeed.isDotVolume(ambiguous.path))
        let strip = try makeVolume(root, "SidePulse Pro", status: "serial SPP-000067\n")
        #expect(!LEDFeed.isDotVolume(strip.path))
        // The serial is the canonical identity: a Dot mounted as "SidePulse".
        let renamed = try makeVolume(root, "AlsoSidePulse", status: "serial SPD-000042\n")
        #expect(LEDFeed.isDotVolume(renamed.path))
    }
}
