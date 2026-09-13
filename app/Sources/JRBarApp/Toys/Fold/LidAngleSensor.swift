import Foundation
import IOKit
import IOKit.hid
import Observation
import QuartzCore

/// The MacBook lid-angle sensor: an Apple HID device on usage page 0x20
/// (Sensor), usage 0x8A (Orientation), vendor 0x05AC, product 0x8104.
/// Feature report 1 carries the angle in bytes 1–2, little-endian
/// degrees.
///
/// The class is split in two on purpose: this shell is the observed,
/// main-actor surface (latest angle, availability, the sample callback),
/// while `SensorPump` below owns every HID touch on a serial queue.
/// `IOHIDDeviceGetReport` is a kernel call — a hung report would stall
/// whatever thread issued it, so the main runloop never polls.
@MainActor
@Observable
final class LidAngleSensor {
    /// One transport delivery: the raw angle (nil on a corrupt/missing
    /// report), when it was read, and the latest clamshell truth (nil
    /// until the first 1 Hz beat).
    struct Sample: Sendable {
        let angle: Double?
        let at: TimeInterval
        let clamshell: Bool?
    }

    /// The latest degrees reading; nil until the first good report.
    private(set) var angle: Double?
    /// A matching HID device answered when we last looked. Internal
    /// hardware never hot-plugs, so this is checked at open and whenever
    /// polling starts rather than watched.
    private(set) var available = false
    /// Every poll result lands here, jitter unfiltered.
    var onSample: (@MainActor (Sample) -> Void)?

    /// The bottom of the arming band: readings at or below it mean the
    /// fold is showing or about to, so the poll steps up to 60 Hz. The
    /// toy sets it to `activation + margin`; above it idles at 10 Hz.
    var armingAngle: Double = -.infinity {
        didSet { pump.setArmingAngle(armingAngle) }
    }

    @ObservationIgnored private let pump = SensorPump()

    init() {
        pump.publish = { [weak self] sample in
            self?.angle = sample.angle
            self?.onSample?(sample)
        }
        pump.publishAvailability = { [weak self] value in
            self?.available = value
        }
    }

    /// Starts or stops the poll. A no-op when nothing changed, so the
    /// toy can call it on every reconcile.
    func setPolling(_ on: Bool) { pump.setPolling(on) }
}

/// The queue-side half of the sensor: every HID read, the adaptive poll
/// timer, and the once-a-second clamshell beat live here, confined to a
/// serial queue. Not actor-isolated, not observed — just a pump that
/// publishes immutable `Sample`s back to the main runloop.
///
/// The poll rate is adaptive because there is no event stream: 10 Hz
/// while the lid sits above the arming band (nothing to show), 60 Hz
/// inside it, and 120 Hz while the lid is actually swinging — the
/// closing gesture is where the fold earns its tracking.
final class SensorPump: @unchecked Sendable {
    /// Publishes a sample on the main runloop; set by the shell.
    var publish: (@MainActor @Sendable (LidAngleSensor.Sample) -> Void)?
    /// Publishes the availability fact on the main runloop.
    var publishAvailability: (@MainActor @Sendable (Bool) -> Void)?
    /// Queue-side state — only ever touched on `io`.
    private var armingAngle: Double = -.infinity

    private let io = DispatchQueue(label: "devin.jrbar.fold.hid", qos: .userInteractive)
    private let manager: IOHIDManager
    /// Everything below is queue-side state — only ever touched on `io`.
    private var devices: [IOHIDDevice] = []
    private var timer: DispatchSourceTimer?
    private var rateClass = 0 {
        didSet {
            guard oldValue != rateClass, timer != nil else { return }
            scheduleTimer()
        }
    }
    /// Instantaneous velocity for the closing kick — a two-sample
    /// estimate, not the toy's predictor; it only moves the poll rate.
    private var lastRaw: Double?
    private var lastAt: TimeInterval?
    private var lastVelocity = 0.0
    /// Counts poll fires; the clamshell read lands once a second.
    private var beats = 0
    private var clamshell: Bool?

    private static let intervals = [1.0 / 10.0, 1.0 / 60.0, 1.0 / 120.0]

    init() {
        manager = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))
        IOHIDManagerSetDeviceMatching(manager, [
            kIOHIDDeviceUsagePageKey: 0x20,
            kIOHIDDeviceUsageKey: 0x8A,
            kIOHIDVendorIDKey: 0x05AC,
            kIOHIDProductIDKey: 0x8104,
        ] as CFDictionary)
        IOHIDManagerOpen(manager, IOOptionBits(kIOHIDOptionsTypeNone))
        io.async { self.refreshDevices() }
    }

    /// The arming band moves when the toy's activation angle does; the
    /// rate re-evaluates on the queue rather than waiting for a beat.
    func setArmingAngle(_ value: Double) {
        io.async {
            self.armingAngle = value
            self.rateClass = self.rateClassFor(rawAngle: self.lastRaw,
                                               velocity: self.lastVelocity)
        }
    }

    func setPolling(_ on: Bool) {
        io.async {
            if on {
                guard self.timer == nil else { return }
                self.refreshDevices()
                self.rateClass = self.rateClassFor(rawAngle: self.lastRaw, velocity: self.lastVelocity)
                self.scheduleTimer()
                self.beat()
            } else {
                self.timer?.cancel()
                self.timer = nil
            }
        }
    }

    // MARK: Queue side

    /// 10 Hz parked, 60 Hz inside the arming band, 120 Hz while the lid
    /// is actually closing — the kick reads the raw stream's own
    /// instantaneous velocity, so a fast slam densifies within a sample
    /// or two and settles back the moment the lid parks.
    private func rateClassFor(rawAngle: Double?, velocity: Double) -> Int {
        if velocity < -6 { return 2 }
        if let angle = rawAngle, angle <= armingAngle { return 1 }
        return 0
    }

    private func scheduleTimer() {
        timer?.cancel()
        let timer = DispatchSource.makeTimerSource(queue: io)
        timer.schedule(deadline: .now(), repeating: Self.intervals[rateClass],
                       leeway: .milliseconds(2))
        timer.setEventHandler { [weak self] in self?.beat() }
        timer.resume()
        self.timer = timer
    }

    /// One poll: read the report, update the velocity/rate kick, drop
    /// the once-a-second clamshell read in, publish.
    private func beat() {
        let now = CACurrentMediaTime()
        let raw = readAngle()
        if let raw, let prev = lastRaw, let prevAt = lastAt {
            let dt = max(1e-4, now - prevAt)
            lastVelocity = (raw - prev) / dt
        } else {
            lastVelocity = 0
        }
        if raw != nil { lastRaw = raw; lastAt = now }
        beats += 1
        // Once a second in wall time, not in beats — at 120 Hz that is
        // every 120 fires, at 10 Hz every 10.
        if Double(beats) * Self.intervals[rateClass] >= 1 {
            beats = 0
            clamshell = ClamshellState.read()
        }
        let next = rateClassFor(rawAngle: lastRaw, velocity: lastVelocity)
        if next != rateClass { rateClass = next }
        let sample = LidAngleSensor.Sample(angle: raw, at: now, clamshell: clamshell)
        DispatchQueue.main.async { [weak self] in
            MainActor.assumeIsolated { self?.publish?(sample) }
        }
    }

    private func refreshDevices() {
        guard let set = IOHIDManagerCopyDevices(manager) else {
            devices = []
            pushAvailability(false)
            return
        }
        devices = (set as NSSet).allObjects.map { $0 as! IOHIDDevice }
        // The manager opens matched devices itself; the explicit open is
        // a fallback for that not holding, and "already open" is a fine
        // answer. Done once here rather than on every poll.
        for device in devices {
            _ = IOHIDDeviceOpen(device, IOOptionBits(kIOHIDOptionsTypeNone))
        }
        pushAvailability(!devices.isEmpty)
    }

    private func pushAvailability(_ value: Bool) {
        DispatchQueue.main.async { [weak self] in
            MainActor.assumeIsolated { self?.publishAvailability?(value) }
        }
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
