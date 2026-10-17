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
    /// The last quiet spot handed to the pump — same dedup reason.
    @ObservationIgnored private var quietPushed: Double?

    @ObservationIgnored private let pump = SensorPump()

    init() {
        pump.publish = { [weak self] sample in
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
        if !on { quietPushed = nil }
    }

    /// The lid is resting at `center` and nothing in the fold is moving:
    /// the pump keeps readings within `SensorPump.quietBand` of it on its
    /// own queue instead of waking the main thread ten times a second.
    /// A reading outside the band, one inside the arming band, a failed
    /// read and the once-a-second clamshell beat still come through, and
    /// the first reading outside the band ends the quiet by itself. nil
    /// ends it now. A no-op when nothing changed.
    func quiet(around center: Double?) {
        guard center != quietPushed else { return }
        quietPushed = center
        pump.setQuiet(center)
    }

    /// Readings a second over the last few, counted on the pump's queue —
    /// every read, including the ones a quiet rest keeps off the main
    /// thread.
    func readRate(at now: TimeInterval = ProcessInfo.processInfo.systemUptime) -> Double {
        pump.reads.rate(at: now)
    }
}

/// Counts the pump's reads for the card's cost line. Written on the
/// pump's queue, read on the main thread, so it takes a lock; a read is
/// ten a second at rest, 120 at most.
final class SensorReadMeter: @unchecked Sendable {
    /// The span a rate is measured over, as `ToyMeter`'s.
    static let window: TimeInterval = 3
    private let lock = NSLock()
    private var stamps: [TimeInterval]
    private var next = 0

    init(capacity: Int = 512) {
        stamps = Array(repeating: -.infinity, count: max(1, capacity))
    }

    func tick(at now: TimeInterval) {
        lock.lock()
        stamps[next] = now
        next = (next + 1) % stamps.count
        lock.unlock()
    }

    /// Reads a second over the last `window`.
    func rate(at now: TimeInterval) -> Double {
        lock.lock()
        defer { lock.unlock() }
        let since = now - Self.window
        return Double(stamps.lazy.filter { $0 > since && $0 <= now }.count) / Self.window
    }
}

/// When the pump gives up polling. A desktop Mac has no lid sensor, and a
/// poll that reads nothing ten times a second forever is a wake-up for
/// no reason: after `failureLimit` failed reads in a row the pump rests,
/// and looks for the device again every `probeInterval`. A probe that
/// finds nothing rests again on its first failed read. Pure, so the rule
/// is tested with no HID.
struct SensorProbePolicy: Equatable {
    enum Verdict: Equatable { case keepPolling, rest }

    /// Failed reads in a row before the pump rests: five seconds at the
    /// parked 10 Hz.
    static let failureLimit = 50
    /// How long a resting pump waits before it looks for the device again.
    static let probeInterval: TimeInterval = 60

    private var failures = 0

    mutating func note(read succeeded: Bool) -> Verdict {
        if succeeded {
            failures = 0
            return .keepPolling
        }
        failures += 1
        return failures >= Self.failureLimit ? .rest : .keepPolling
    }

    /// A probe is about to poll again: it gets one failed read to prove
    /// itself, not a whole new run.
    mutating func resumeProbing() {
        failures = Self.failureLimit - 1
    }
}

/// Whether the sensor has gone quiet while the fold believes it. A polling
/// pump always delivers something at least once a second — even a lid at
/// rest sends its clamshell beat — so a stretch with nothing at all means
/// the pump is stuck or resting, and the last angle it reported is no
/// longer a fact the fold may stay up on.
enum FoldSensorSilence {
    /// Seconds without a sample before the last reading is let go.
    static let limit: TimeInterval = 3

    static func isSilent(lastSampleAt: TimeInterval?, now: TimeInterval) -> Bool {
        guard let lastSampleAt else { return false }
        return now - lastSampleAt > limit
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
/// the motion's edge timing needs. A shut lid sits under the band
/// but never arms it: see `rateClassFor`.
///
/// The parked class is a background chore and is timed like one:
/// utility QoS and a 15 ms leeway, so its ten wakes a second can
/// coalesce with the system's — it runs whenever Fold is on, lid
/// still, shut or not. Only the armed class earns user-interactive QoS
/// and a 2 ms leeway. Every sample is still published: the movement
/// anchor's settle clock needs each one, and the jitter filter is what
/// keeps a parked wobble off the picture.
final class SensorPump: @unchecked Sendable {
    /// Publishes a sample on the main runloop; set by the shell.
    var publish: (@MainActor @Sendable (LidAngleSensor.Sample) -> Void)?
    /// Publishes the availability fact on the main runloop.
    var publishAvailability: (@MainActor @Sendable (Bool) -> Void)?
    /// Every read, counted here rather than on the main thread.
    let reads = SensorReadMeter()
    /// Degrees either side of a quiet rest that stay on the queue: the
    /// sensor's whole-degree flicker.
    static let quietBand: Double = 1
    /// Queue-side state — only ever touched on `io`.
    private var armingAngle: Double = -.infinity
    /// The resting reading the toy asked to be left alone about, or nil.
    private var quietCenter: Double?

    /// Utility, the parked class's QoS; the armed beat enforces its own.
    private let io = DispatchQueue(label: "devin.jrbar.fold.hid", qos: .utility)
    private let manager: IOHIDManager
    /// Everything below is queue-side state — only ever touched on `io`.
    private var devices: [IOHIDDevice] = []
    private var timer: DispatchSourceTimer?
    /// Looks for the device again while the poll rests (no sensor, or one
    /// that never answers); exists only then.
    private var probeTimer: DispatchSourceTimer?
    private var probe = SensorProbePolicy()
    /// Whether the toy wants polling at all — a probe only resumes the
    /// poll while it does.
    private var wantsPolling = false
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
    /// Clamshell reads follow elapsed time across sensor-rate changes.
    private var clamshellCadence = SensorClamshellCadence()
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

    func setQuiet(_ center: Double?) {
        io.async { self.quietCenter = center }
    }

    /// Whether a beat's reading can stay on the queue: the toy asked for
    /// quiet, the reading sits within the band of the resting one, and it
    /// is outside the arming band — inside it the machine reads every
    /// sample. A failed read and the clamshell beat always go through.
    /// Static and pure so the rule is testable with no HID.
    static func staysQuiet(raw: Double?, center: Double?, armingAngle: Double, clamshellBeat: Bool) -> Bool {
        guard !clamshellBeat, let raw, let center else { return false }
        return abs(raw - center) <= quietBand && raw > armingAngle
    }

    func setPolling(_ on: Bool) {
        io.async {
            self.wantsPolling = on
            if on {
                guard self.timer == nil else { return }
                // Switching on is a fresh look: it ends any rest.
                self.cancelProbe()
                self.probe = SensorProbePolicy()
                self.clamshellCadence = SensorClamshellCadence()
                self.refreshDevices()
                self.rateClass = self.wantedRateClass
                // No direct beat() here: the fresh timer's deadline is
                // .now, so it fires the first sample itself.
                self.scheduleTimer()
            } else {
                self.timer?.cancel()
                self.timer = nil
                self.cancelProbe()
                self.quietCenter = nil
            }
        }
    }

    /// 10 Hz above the arming band — the sensor's own cadence — and
    /// 120 Hz inside it, where an edge's poll timestamp is the motion's
    /// edge time. A shut lid stays parked however low it reads: at or
    /// under `FoldPause.closedAngle`, or with the clamshell flag set,
    /// the fold is paused and cannot draw, and a lid shut on an awake
    /// Mac (clamshell with an external display, or the daemon's
    /// closed-lid keep-awake) must not hold 120 Hz user-interactive
    /// reads for as long as it stays shut.
    ///
    /// Two layers keep it there. Under the toy the band itself is
    /// -infinity for as long as any pause holds, so a shut lid is
    /// mostly parked by the band alone. This floor covers what the
    /// band cannot: the park on the way down, which lands on the very
    /// beat that reads the close rather than a main hop and a pass
    /// later, and a failed read, which leaves the toy's angle nil (no
    /// angle to pause on) while `lastRaw` here still reads shut. The
    /// same band is why a reopen does not step up on the beat that
    /// sees it: that beat still finds -infinity and stays at 10 Hz.
    /// The step back up comes from the reconcile that lifts the pause
    /// (the accepted reading above the floor, or the once-a-second
    /// read that clears the clamshell flag, whichever lands last): it
    /// restores the band as the half-second resume quiet starts, and
    /// `setArmingAngle` re-evaluates the class on the queue. Nothing is
    /// lost: the band is back before the quiet ends and the fold can
    /// draw. Static and pure so the rule is testable with no HID.
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
    /// in, re-evaluate the arming band, publish — unless the lid is
    /// resting quietly and the reading is only the sensor's flicker.
    private func beat() {
        let now = CACurrentMediaTime()
        let raw = readAngle()
        reads.tick(at: ProcessInfo.processInfo.systemUptime)
        if raw != nil { lastRaw = raw }
        if probe.note(read: raw != nil) == .rest {
            restPolling()
            // The failed read still goes out below, so the toy sees nil
            // and the card says the sensor is not answering.
        }
        let clamshellBeat = clamshellCadence.shouldRead(at: now)
        if clamshellBeat { clamshell = ClamshellState.read() }
        let next = wantedRateClass
        if next != rateClass { rateClass = next }
        if Self.staysQuiet(raw: raw, center: quietCenter, armingAngle: armingAngle, clamshellBeat: clamshellBeat) {
            return
        }
        // Anything else that gets through a quiet rest ends it: the toy
        // decides again once the lid settles.
        if let center = quietCenter, !clamshellBeat || raw.map({ abs($0 - center) > Self.quietBand }) ?? true {
            quietCenter = nil
        }
        let sample = LidAngleSensor.Sample(angle: raw, at: now, clamshell: clamshell)
        DispatchQueue.main.async { [weak self] in
            MainActor.assumeIsolated { self?.publish?(sample) }
        }
    }

    /// Stops the poll and schedules the rare look for the device.
    private func restPolling() {
        timer?.cancel()
        timer = nil
        quietCenter = nil
        cancelProbe()
        let probeTimer = DispatchSource.makeTimerSource(queue: io)
        probeTimer.schedule(deadline: .now() + SensorProbePolicy.probeInterval,
                            leeway: .seconds(5))
        probeTimer.setEventHandler { [weak self] in self?.probeForDevice() }
        probeTimer.resume()
        self.probeTimer = probeTimer
    }

    private func cancelProbe() {
        probeTimer?.cancel()
        probeTimer = nil
    }

    /// The rare look: refresh the device list, and poll again once there
    /// is something to read. A probe that finds a device but still reads
    /// nothing rests again after one failed read.
    private func probeForDevice() {
        cancelProbe()
        guard wantsPolling, timer == nil else { return }
        refreshDevices()
        if devices.isEmpty {
            restPolling()
            return
        }
        probe.resumeProbing()
        rateClass = wantedRateClass
        scheduleTimer()
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

/// Reads clamshell state immediately on startup, then once per host second.
/// Changing the sensor's polling rate never changes this deadline.
struct SensorClamshellCadence {
    private var lastReadAt: TimeInterval?

    mutating func shouldRead(at now: TimeInterval) -> Bool {
        guard now.isFinite else { return false }
        if let lastReadAt, now >= lastReadAt, now - lastReadAt < 1 { return false }
        lastReadAt = now
        return true
    }
}
