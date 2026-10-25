import Foundation
import JRBarCore
import Testing
@testable import JRBarApp

/// The lid-angle pump's rate rule (LidAngleSensor.swift): which readings
/// earn the 120 Hz armed class, stay nearby at 10 Hz or rest at 2 Hz.
/// Pure — no HID device, no queue, no timer.
@Suite("Fold sensor pump")
struct FoldSensorTests {
    /// The band defaults to 82°: a 70° activation plus the toy's 12°
    /// margin.
    private func rate(_ angle: Double?, band: Double = 82, clamshell: Bool? = false) -> Int {
        SensorPump.rateClassFor(rawAngle: angle, armingAngle: band, clamshell: clamshell, stillReads: SensorMotionCadence.stillReadLimit)
    }

    @Test("inside the band an open lid polls armed, above it parked")
    func armedBand() {
        #expect(rate(82) == 1, "the band's edge is inside")
        #expect(rate(60) == 1)
        #expect(rate(6) == 1, "just above the closed-lid floor still arms")
        #expect(rate(82.5) == 2)
        #expect(rate(120) == 2)
    }

    @Test("distant reads slow down without changing nearby or armed timing")
    func distantCadence() {
        #expect(SensorPump.intervals[rate(170)] == 0.5)
        #expect(SensorPump.intervals[rate(115)] == 0.1)
        #expect(SensorPump.intervals[rate(102)] == 0.1)
        #expect(SensorPump.intervals[rate(102.5)] == 0.1)
        #expect(SensorPump.intervals[rate(82)] == 1.0 / 120)
        #expect(SensorPump.intervals[rate(nil)] == 0.1)
    }

    @Test("motion resets the still-read run before idle polling resumes")
    func motionCadence() {
        var cadence = SensorMotionCadence()
        cadence.note(170)
        for _ in 0..<SensorMotionCadence.stillReadLimit { cadence.note(170) }
        #expect(cadence.stillReads == SensorMotionCadence.stillReadLimit)
        cadence.note(168)
        #expect(cadence.stillReads == 0)
        let movingRate = SensorPump.rateClassFor(rawAngle: 168, armingAngle: 82, clamshell: false,
                                                stillReads: cadence.stillReads)
        #expect(movingRate == 2)
        cadence.note(nil)
        #expect(cadence.stillReads == 0)
    }

    @Test("fast closes arm before the closed angle from every idle sampling phase")
    func fastCloses() {
        for speed in [150.0, 300.0] {
            for start in [115.0, 170.0] {
                for phase in stride(from: 0.001, through: 0.499, by: 0.003) {
                    var cadence = SensorMotionCadence()
                    for _ in 0...SensorMotionCadence.stillReadLimit { cadence.note(start) }
                    var time = 0.0
                    var angle = start
                    var armed = false
                    while angle > FoldPause.closedAngle {
                        let rate = SensorPump.rateClassFor(rawAngle: angle, armingAngle: 82,
                                                           clamshell: false, stillReads: cadence.stillReads)
                        if rate == 1 { armed = true; break }
                        time += SensorPump.intervals[rate]
                        angle = max(0, start - speed * max(0, time - phase))
                        cadence.note(angle)
                    }
                    #expect(armed, "speed=\(speed), start=\(start), phase=\(phase)")
                }
            }
        }
    }

    @Test("a shut lid stays parked however low it reads")
    func shutLid() {
        // At or under FoldPause.closedAngle the fold is paused and cannot
        // draw; a lid shut on an awake Mac must not hold 120 Hz for hours.
        #expect(rate(FoldPause.closedAngle) == 0)
        #expect(rate(3) == 0)
        #expect(rate(0) == 0)
        // The clamshell flag parks it wherever the (possibly stale)
        // reading sits — and only a set flag does: unknown is not shut.
        #expect(rate(60, clamshell: true) == 0)
        #expect(rate(60, clamshell: nil) == 1, "a desktop Mac has no clamshell to read")
    }

    @Test("unknown readings and movement mode retain the normal cadence")
    func noBand() {
        #expect(rate(nil) == 2, "before the first good report there is nothing to arm on")
        #expect(rate(60, band: -.infinity) == 2,
                "movement mode and a pause clear the band")
    }
}

/// A Mac with no lid sensor must not poll at 10 Hz forever: after a run
/// of failed reads the pump rests, and looks again rarely.
@Suite("Fold sensor probe policy")
struct FoldSensorProbeTests {
    @Test("a run of failed reads ends the poll; a good one starts the count over")
    func restsAfterBoundedFailures() {
        var policy = SensorProbePolicy()
        for _ in 0..<(SensorProbePolicy.failureLimit - 1) {
            #expect(policy.note(read: false) == .keepPolling)
        }
        #expect(policy.note(read: true) == .keepPolling)
        for _ in 0..<(SensorProbePolicy.failureLimit - 1) {
            #expect(policy.note(read: false) == .keepPolling, "the good read reset the run")
        }
        #expect(policy.note(read: false) == .rest)
    }

    @Test("resting is rare, and a re-probe that finds nothing rests again at once")
    func probesRarely() {
        #expect(SensorProbePolicy.probeInterval >= 30)
        var policy = SensorProbePolicy()
        for _ in 0..<SensorProbePolicy.failureLimit { _ = policy.note(read: false) }
        policy.resumeProbing()
        // One failed read after a probe is enough: the run was not reset.
        #expect(policy.note(read: false) == .rest)
        policy.resumeProbing()
        #expect(policy.note(read: true) == .keepPolling)
        #expect(policy.note(read: false) == .keepPolling, "a working sensor earns its full run back")
    }

    @Test("the limit is a few seconds at the parked rate, never a blink")
    func limitIsBounded() {
        let seconds = Double(SensorProbePolicy.failureLimit) * 0.1
        #expect(seconds >= 3 && seconds <= 30)
    }
}

/// A sensor that stops talking must not leave the fold standing on its
/// last reading.
@Suite("Fold sensor silence")
struct FoldSensorSilenceTests {
    @Test("a sensor is silent only after the limit, and only once it has spoken")
    func silence() {
        #expect(!FoldSensorSilence.isSilent(lastSampleAt: nil, now: 100), "never spoke: nothing to forget")
        #expect(!FoldSensorSilence.isSilent(lastSampleAt: 100, now: 100 + FoldSensorSilence.limit))
        #expect(FoldSensorSilence.isSilent(lastSampleAt: 100, now: 100 + FoldSensorSilence.limit + 0.1))
    }

    @Test("the limit outlasts the pump's once-a-second beat")
    func limitOutlastsTheBeat() {
        #expect(FoldSensorSilence.limit >= 2)
    }
}

@Suite("Fold clamshell cadence")
struct FoldClamshellCadenceTests {
    @Test("poll rate changes preserve the one-second clamshell deadline")
    func changingRate() {
        var cadence = SensorClamshellCadence()
        let initialRead = cadence.shouldRead(at: 10)
        #expect(initialRead)
        // Parked samples followed by armed samples still share one deadline.
        for time in [10.1, 10.2, 10.3, 10.31, 10.32, 10.9, 10.99] {
            let readBeforeFirstDeadline = cadence.shouldRead(at: time)
            #expect(!readBeforeFirstDeadline)
        }
        let readAtFirstDeadline = cadence.shouldRead(at: 11)
        #expect(readAtFirstDeadline)
        // Returning to the parked rate does not turn old fast beats into seconds.
        for time in [11.008, 11.016, 11.1, 11.2, 11.9] {
            let readBeforeSecondDeadline = cadence.shouldRead(at: time)
            #expect(!readBeforeSecondDeadline)
        }
        let readAtSecondDeadline = cadence.shouldRead(at: 12)
        #expect(readAtSecondDeadline)
    }

    @Test("clock resets recover and invalid times leave the deadline alone")
    func clockReset() {
        var cadence = SensorClamshellCadence()
        let invalidInitialRead = cadence.shouldRead(at: .nan)
        #expect(!invalidInitialRead)
        let initialRead = cadence.shouldRead(at: 10)
        #expect(initialRead)
        let infiniteTimeRead = cadence.shouldRead(at: .infinity)
        #expect(!infiniteTimeRead)
        let readBeforeReset = cadence.shouldRead(at: 10.5)
        #expect(!readBeforeReset)
        let resetRead = cadence.shouldRead(at: 2)
        #expect(resetRead)
        let readBeforeDeadline = cadence.shouldRead(at: 2.5)
        #expect(!readBeforeDeadline)
        let readAtDeadline = cadence.shouldRead(at: 3)
        #expect(readAtDeadline)
    }
}
