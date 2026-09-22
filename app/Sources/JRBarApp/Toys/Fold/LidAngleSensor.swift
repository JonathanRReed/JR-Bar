import Foundation
import IOKit
import IOKit.hid
import JRBarCore
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
    /// fold is showing or about to, so the poll steps up to 120 Hz —
    /// unless the lid is shut, which the pump keeps at 10 Hz however
    /// low it reads. The toy sets it to `activation + margin`, or to
    /// -infinity while nothing in the band could draw; above it idles
    /// at 10 Hz. Reconcile sets it every pass — the queue hop only
    /// happens on a real change, not 120 times a second.
    var armingAngle: Double = -.infinity {
        didSet {
            if armingAngle != oldValue { pump.setArmingAngle(armingAngle) }
        }
    }

    /// The last polling state actually pushed to the pump — same
    /// dedup reason as `armingAngle`.
    @ObservationIgnored private var pollingPushed = false

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
    func setPolling(_ on: Bool) {
        guard on != pollingPushed else { return }
        pollingPushed = on
        pump.setPolling(on)
    }
}

/// The queue-side half of the sensor: every HID read, the poll timer,
/// and the once-a-second clamshell beat live here, confined to a serial
/// queue. Not actor-isolated, not observed — just a pump that publishes
/// immutable `Sample`s back to the main runloop.
///
/// Two rates only, because the sensor itself only has one cadence: the
/// report is a 10 Hz device (probed at 240 Hz it changes value every
/// ~100 ms), so above the arming band polling at its own 10 Hz loses
/// nothing. Inside the band the poll runs 120 Hz — a read costs ~0.5 ms
/// and dense polls timestamp each sensor edge to ±8 ms, which is what
/// the tracker's dead reckoning needs. A shut lid sits under the band
/// but never arms it: see `rateClassFor`.
///
/// The parked class is a background chore and is timed like one:
/// utility QoS and a 15 ms leeway, so its ten wakes a second can
/// coalesce with the system's — it runs whenever Fold is on, lid
/// still, shut or not. Only the armed class earns user-interactive QoS
/// and a 2 ms leeway. Every sample is still published: the movement
/// anchor's settle clock needs each one, and the jitter filter is what
/// keeps a parked wobble off the tracker.
final class SensorPump: @unchecked Sendable {
    /// Publishes a sample on the main runloop; set by the shell.
    var publish: (@MainActor @Sendable (LidAngleSensor.Sample) -> Void)?
    /// Publishes the availability fact on the main runloop.
    var publishAvailability: (@MainActor @Sendable (Bool) -> Void)?
    /// Queue-side state — only ever touched on `io`.
    private var armingAngle: Double = -.infinity

    /// Utility, the parked class's QoS; the armed beat enforces its own.
    private let io = DispatchQueue(label: "devin.jrbar.fold.hid", qos: .utility)
    private let manager: IOHIDManager
    /// Everything below is queue-side state — only ever touched on `io`.
    private var devices: [IOHIDDevice] = []
    private var timer: DispatchSourceTimer?
    /// 0 is the parked 10 Hz, 1 is the armed 120 Hz.
    private var rateClass = 0 {
        didSet {
            guard oldValue != rateClass, let timer else { return }
            // Reschedule the live timer — a fresh one would fire a beat
            // ~immediately on top of this one, making the sample timing
            // irregular exactly where regularity matters.
            arm(timer, deadline: .now() + Self.intervals[rateClass])
        }
    }
    /// The last angle read; the arming-band rate decision rides on it.
    private var lastRaw: Double?
    /// Counts poll fires; the clamshell read lands once a second.
    private var beats = 0
    private var clamshell: Bool?

    private static let intervals = [1.0 / 10.0, 1.0 / 120.0]
    private static let leewayMilliseconds = [15, 2]

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
            self.rateClass = self.wantedRateClass
        }
    }

    func setPolling(_ on: Bool) {
        io.async {
            if on {
                guard self.timer == nil else { return }
                self.refreshDevices()
                self.rateClass = self.wantedRateClass
                // No direct beat() here: the fresh timer's deadline is
                // .now, so it fires the first sample itself.
                self.scheduleTimer()
            } else {
                self.timer?.cancel()
                self.timer = nil
            }
        }
    }

    /// 10 Hz above the arming band — the sensor's own cadence — and
    /// 120 Hz inside it, where an edge's poll timestamp is the tracker's
    /// edge time. A shut lid stays parked however low it reads: at or
    /// under `FoldPause.closedAngle`, or with the clamshell flag set,
    /// the fold is paused and cannot draw. The band runs all the way
    /// down to the hinge, so without that floor a lid shut on an awake
    /// Mac (clamshell with an external display, or the daemon's
    /// closed-lid keep-awake) would hold 120 Hz user-interactive reads
    /// for as long as it stayed shut. Nothing is lost on the way back: the 10 Hz
    /// beat sees a reopen within ~100 ms and steps up on that beat, and
    /// the clamshell flag clears on the same once-a-second read that
    /// lifts the toy's pause — both ahead of its half-second resume
    /// quiet. Static and pure so the rule is testable with no HID.
    static func rateClassFor(rawAngle: Double?, armingAngle: Double, clamshell: Bool?) -> Int {
        if let angle = rawAngle, angle > FoldPause.closedAngle, angle <= armingAngle,
           clamshell != true { return 1 }
        return 0
    }

    // MARK: Queue side

    /// The class the queue-side facts ask for right now.
    private var wantedRateClass: Int {
        Self.rateClassFor(rawAngle: lastRaw, armingAngle: armingAngle, clamshell: clamshell)
    }

    private func scheduleTimer() {
        let timer = DispatchSource.makeTimerSource(queue: io)
        arm(timer, deadline: .now())
        timer.resume()
        self.timer = timer
    }

    /// Times `timer` for the current class. The QoS rides the handler,
    /// enforced over the queue's, so a class change swaps it together
    /// with the interval — from inside a beat it takes from the next one.
    private func arm(_ timer: DispatchSourceTimer, deadline: DispatchTime) {
        timer.schedule(deadline: deadline, repeating: Self.intervals[rateClass],
                       leeway: .milliseconds(Self.leewayMilliseconds[rateClass]))
        timer.setEventHandler(qos: rateClass == 1 ? .userInteractive : .utility,
                              flags: .enforceQoS) { [weak self] in self?.beat() }
    }

    /// One poll: read the report, drop the once-a-second clamshell read
    /// in, re-evaluate the arming band, publish.
    private func beat() {
        let now = CACurrentMediaTime()
        let raw = readAngle()
        if raw != nil { lastRaw = raw }
        beats += 1
        // Once a second in wall time, not in beats — at 120 Hz that is
        // every 120 fires, at 10 Hz every 10.
        if Double(beats) * Self.intervals[rateClass] >= 1 {
            beats = 0
            clamshell = ClamshellState.read()
        }
        let next = wantedRateClass
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
        // The manager only vends devices it matched, but the set is
        // bridged — check the CFTypeID rather than force the cast.
        devices = (set as NSSet).allObjects.compactMap { object in
            CFGetTypeID(object as CFTypeRef) == IOHIDDeviceGetTypeID()
                ? (object as! IOHIDDevice) : nil
        }
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
