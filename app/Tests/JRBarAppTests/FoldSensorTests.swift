import Foundation
import JRBarCore
import Testing
@testable import JRBarApp

/// The lid-angle pump's rate rule (LidAngleSensor.swift): which readings
/// earn the 120 Hz armed class and which idle at the sensor's own 10 Hz.
/// Pure — no HID device, no queue, no timer.
@Suite("Fold sensor pump")
struct FoldSensorTests {
    /// The band defaults to 82°: a 70° activation plus the toy's 12°
    /// margin.
    private func rate(_ angle: Double?, band: Double = 82, clamshell: Bool? = false) -> Int {
        SensorPump.rateClassFor(rawAngle: angle, armingAngle: band, clamshell: clamshell)
    }

    @Test("inside the band an open lid polls armed, above it parked")
    func armedBand() {
        #expect(rate(82) == 1, "the band's edge is inside")
        #expect(rate(60) == 1)
        #expect(rate(6) == 1, "just above the closed-lid floor still arms")
        #expect(rate(82.5) == 0)
        #expect(rate(120) == 0)
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

    @Test("no reading, or no band, is the parked class")
    func noBand() {
        #expect(rate(nil) == 0, "before the first good report there is nothing to arm on")
        #expect(rate(60, band: -.infinity) == 0,
                "movement mode and a pause clear the band")
    }
}
