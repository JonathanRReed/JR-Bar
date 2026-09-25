import AppKit
import Foundation
import JRBarCore
import Testing
@testable import JRBarApp

/// The fold at rest (FoldRest.swift): the hinge's whole-degree flicker
/// stops at the gate once the lid has settled, the sensor keeps it on its
/// own queue, and the card hears about a moving lid ten times a second at
/// most. All on injected clocks — no HID device, no timers.
@Suite("Fold at rest")
struct FoldRestTests {
    // MARK: The rest gate

    /// Feeds `readings` a tenth of a second apart from `start`, the way
    /// the parked pump delivers them, and returns which got through.
    private func feed(_ gate: inout FoldRestGate, _ readings: [Double], start: TimeInterval = 0,
                      idle: Bool = true, band: Double = -.infinity) -> [Bool] {
        readings.enumerated().map { index, angle in
            gate.admits(angle, at: start + Double(index) * 0.1, idle: idle, insideArmingBand: angle <= band)
        }
    }

    @Test("the flicker gets through while the lid settles, then stops at the gate")
    func flickerStopsAfterTheSettle() {
        var gate = FoldRestGate()
        let passed = feed(&gate, [95, 94, 95, 94, 95, 94, 95, 94, 95, 94])
        // 0.0 … 0.4 s: the jitter filter's re-arm and the anchor's settle
        // run on real readings.
        #expect(passed.prefix(5).allSatisfy { $0 })
        // From 0.5 s the flicker stops here.
        #expect(passed.dropFirst(5).allSatisfy { !$0 })
        #expect(gate.closed(at: 0.9))
    }

    @Test("a real move always gets through, and the settle starts again from it")
    func aMoveGetsThrough() {
        var gate = FoldRestGate()
        _ = feed(&gate, Array(repeating: 95, count: 8))
        let flicker = gate.admits(94, at: 0.8, idle: true, insideArmingBand: false)
        #expect(!flicker)
        let travel = gate.admits(93, at: 0.9, idle: true, insideArmingBand: false)
        #expect(travel, "two degrees is travel")
        #expect(gate.center == 93)
        let settling = gate.admits(93, at: 1.0, idle: true, insideArmingBand: false)
        #expect(settling, "settling again")
        #expect(!gate.closed(at: 1.0))
    }

    @Test("nothing is held back while the machine is busy")
    func busyMachineSeesEverything() {
        var gate = FoldRestGate()
        let passed = feed(&gate, Array(repeating: 95, count: 12), idle: false)
        #expect(passed.allSatisfy { $0 })
    }

    @Test("inside the arming band every reading gets through: arming is never a reading late")
    func armingIsNeverLate() {
        var gate = FoldRestGate()
        // Parked right on the band's edge (activation 70 + 12 = 82).
        _ = feed(&gate, Array(repeating: 83, count: 8), band: 82)
        let intoTheBand = gate.admits(82, at: 0.8, idle: true, insideArmingBand: true)
        #expect(intoTheBand, "a one-degree step into the band arms at once")
    }

    @Test("a reset forgets the resting spot")
    func reset() {
        var gate = FoldRestGate()
        _ = feed(&gate, Array(repeating: 95, count: 8))
        gate.reset()
        let fresh = gate.admits(95, at: 0.8, idle: true, insideArmingBand: false)
        #expect(fresh)
    }

    // MARK: The pump's quiet

    @Test("the pump keeps a quiet rest's flicker on its queue, and nothing else")
    func pumpQuiet() {
        func quiet(_ raw: Double?, center: Double? = 95, band: Double = -.infinity, beat: Bool = false) -> Bool {
            SensorPump.staysQuiet(raw: raw, center: center, armingAngle: band, clamshellBeat: beat)
        }
        #expect(quiet(95))
        #expect(quiet(94))
        #expect(quiet(96))
        #expect(!quiet(93), "travel wakes the main thread")
        #expect(!quiet(95, center: nil), "no quiet asked for")
        #expect(!quiet(nil), "a failed read goes through")
        #expect(!quiet(95, beat: true), "the once-a-second clamshell beat goes through")
        #expect(!quiet(80, center: 80, band: 82), "inside the arming band the machine reads every sample")
    }

    @Test("the pump counts every read, quiet or not")
    func readMeter() {
        let meter = SensorReadMeter()
        for index in 0..<30 { meter.tick(at: 100 + Double(index) * 0.1) }
        #expect(abs(meter.rate(at: 103) - 10) < 0.5)
        #expect(meter.rate(at: 200) == 0)
    }

    // MARK: The card

    @Test("the card's angle is whole degrees, and an unchanged one lands nothing")
    func cardRounds() {
        var feed = FoldCardFeed()
        let first = feed.land(.init(angle: 104.4, detail: "Parked", pause: nil), at: 0)
        #expect(first?.angle == 104)
        #expect(feed.due(at: 0.2) == 0.2)
        let again = feed.land(.init(angle: 103.6, detail: "Parked", pause: nil), at: 0.2)
        #expect(again == nil, "104.4 and 103.6 are both 104°")
    }

    @Test("a lid moving at 120 Hz reaches the card ten times a second at most")
    func cardCapsAtTenHertz() {
        var feed = FoldCardFeed()
        var landed: [TimeInterval] = []
        var pending: TimeInterval?
        // One second of a steady close, a reading every 1/120 s.
        for step in 0..<120 {
            let now = Double(step) / 120
            let reading = FoldCardFeed.Reading(angle: 110 - Double(step) * 0.25, detail: "Tilted", pause: nil)
            if let due = pending, due <= now {
                pending = nil
            }
            let due = feed.due(at: now)
            guard due <= now else {
                pending = pending ?? due
                continue
            }
            if feed.land(reading, at: now) != nil { landed.append(now) }
        }
        #expect(landed.count <= 10)
        #expect(landed.count >= 9, "and it keeps up")
        for (a, b) in zip(landed, landed.dropFirst()) {
            #expect(b - a >= FoldCardFeed.interval - 1e-9)
        }
    }

    @Test("a look that finds nothing new still waits its tenth: a held fold is not read 120 times a second")
    func cardLooksAreCapped() {
        var feed = FoldCardFeed()
        _ = feed.land(.init(angle: 90, detail: "Holding 12° of tilt", pause: nil), at: 5)
        let same = feed.land(.init(angle: 90, detail: "Holding 12° of tilt", pause: nil), at: 5.1)
        #expect(same == nil)
        #expect(abs(feed.due(at: 5.12) - 5.2) < 1e-9)
    }

    @Test("a change inside the tenth lands when the tenth is up")
    func cardLandsLate() {
        var feed = FoldCardFeed()
        _ = feed.land(.init(angle: 100, detail: "Parked", pause: nil), at: 1)
        #expect(feed.due(at: 1.03) == 1.1)
        let late = feed.land(.init(angle: 98, detail: "Parked", pause: nil), at: 1.1)
        #expect(late?.angle == 98)
    }

    // MARK: The glyph

    @Test("the card's layer glyph draws the SwiftUI glyph's marks, and follows the angle")
    @MainActor
    func layerGlyph() {
        let view = FoldLidLayerView(angle: 104, activation: 65)
        view.frame = CGRect(x: 0, y: 0, width: 118, height: 70)
        view.layoutSubtreeIfNeeded()
        let marks = FoldLidGlyph.marks(in: CGSize(width: 118, height: 70), angle: 104, activation: 65)
        #expect(view.layer?.sublayers?.count == marks.count)
        view.show(angle: nil)
        view.layoutSubtreeIfNeeded()
        let ghost = FoldLidGlyph.marks(in: CGSize(width: 118, height: 70), angle: nil, activation: 65)
        #expect(view.layer?.sublayers?.count == ghost.count, "no reading: the dashed ghost, no screen, no hinge")
    }

    @Test("the angle reads as the card always said it")
    func angleWords() {
        #expect(FoldToy.angleText(104.4, sensorAvailable: true) == "104°")
        #expect(FoldToy.angleText(nil, sensorAvailable: true) == "—")
        #expect(FoldToy.angleText(nil, sensorAvailable: false) == "no sensor")
    }
}
