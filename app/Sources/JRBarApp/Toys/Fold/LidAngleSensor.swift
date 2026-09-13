import Foundation
import IOKit
import IOKit.hid
import Observation

/// The MacBook lid-angle sensor: an Apple HID device on usage page 0x20
/// (Sensor), usage 0x8A (Orientation), vendor 0x05AC, product 0x8104.
/// Feature report 1 carries the angle in bytes 1–2, little-endian
/// degrees. There is no event stream, so the report is polled at 30 Hz —
/// but only while `setPolling(true)`; at rest there is no timer at all.
@MainActor
@Observable
final class LidAngleSensor {
    /// The latest degrees reading; nil until the first good report.
    private(set) var angle: Double?
    /// A matching HID device answered when we last looked. Internal
    /// hardware never hot-plugs, so this is checked at open and whenever
    /// polling starts rather than watched.
    private(set) var available = false
    /// Every raw poll result lands here, jitter unfiltered.
    var onSample: (@MainActor (Double?) -> Void)?

    @ObservationIgnored private let manager: IOHIDManager
    @ObservationIgnored private var devices: [IOHIDDevice] = []
    @ObservationIgnored private var timer: Timer?

    init() {
        manager = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))
        IOHIDManagerSetDeviceMatching(manager, [
            kIOHIDDeviceUsagePageKey: 0x20,
            kIOHIDDeviceUsageKey: 0x8A,
            kIOHIDVendorIDKey: 0x05AC,
            kIOHIDProductIDKey: 0x8104,
        ] as CFDictionary)
        IOHIDManagerOpen(manager, IOOptionBits(kIOHIDOptionsTypeNone))
        refreshDevices()
    }

    /// Starts or stops the 30 Hz poll. A no-op when nothing changed, so
    /// the toy can call it on every reconcile.
    func setPolling(_ on: Bool) {
        if on {
            guard timer == nil else { return }
            refreshDevices()
            let timer = Timer(timeInterval: 1.0 / 30.0, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated { self?.poll() }
            }
            RunLoop.main.add(timer, forMode: .common)
            self.timer = timer
            poll()
        } else {
            timer?.invalidate()
            timer = nil
        }
    }

    private func refreshDevices() {
        guard let set = IOHIDManagerCopyDevices(manager) else {
            devices = []
            available = false
            return
        }
        devices = (set as NSSet).allObjects.map { $0 as! IOHIDDevice }
        // The manager opens matched devices itself; the explicit open is
        // a fallback for that not holding, and "already open" is a fine
        // answer. Done once here rather than on every poll.
        for device in devices {
            _ = IOHIDDeviceOpen(device, IOOptionBits(kIOHIDOptionsTypeNone))
        }
        available = !devices.isEmpty
    }

    private func poll() {
        angle = readAngle()
        onSample?(angle)
    }

    /// Report 1: byte 0 is the report id, bytes 1–2 are the angle as a
    /// little-endian UInt16 of degrees. A reading outside 0–180 is a
    /// corrupt report, not a lid position — the hinge cannot be there.
    private func readAngle() -> Double? {
        for device in devices {
            var report = [UInt8](repeating: 0, count: 8)
            var length = CFIndex(report.count)
            let result = IOHIDDeviceGetReport(device, kIOHIDReportTypeFeature, CFIndex(1), &report, &length)
            guard result == kIOReturnSuccess, length >= 3 else { continue }
            let angle = Double(UInt16(report[1]) | (UInt16(report[2]) << 8))
            if (0...180).contains(angle) { return angle }
        }
        return nil
    }
}

/// The real "is the lid shut" fact: `AppleClamshellState` on
/// `IOPMrootDomain`, the same property `ioreg` reports. The daemon's
/// `power.closed_lid.holding` is NOT it — that is the keep-awake
/// caffeinate assertion, held whenever the policy is armed and agents
/// are working, lid open or not.
enum ClamshellState {
    /// true lid closed, false lid open, nil when the registry does not
    /// answer (a desktop Mac has no clamshell to close).
    static func read() -> Bool? {
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("IOPMrootDomain"))
        guard service != 0 else { return nil }
        defer { IOObjectRelease(service) }
        guard let property = IORegistryEntryCreateCFProperty(
            service, "AppleClamshellState" as CFString, kCFAllocatorDefault, 0
        )?.takeRetainedValue() else { return nil }
        return (property as? Bool) ?? (property as? NSNumber)?.boolValue
    }
}
