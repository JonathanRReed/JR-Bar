import CoreGraphics
import Foundation
import Testing
import JRBarLEDS
@testable import JRBarApp

/// The band's colour path: the spatial blend that turns eight codes into
/// one continuous strip, and the keyframes Core Animation interpolates.
/// Both used to move the light away from what the strip shows — a 1.5×
/// unnormalised blend clipped per channel, and fades that ran t².
@Suite("Screen Bar blend")
struct ScreenBarBlendTests {
    typealias Sample = ScreenBarBlend.Sample

    /// The coupled strip's width under the idle island.
    static let bandWidth: CGFloat = 209
    /// Claude's accent, the colour the audit caught turning peach.
    static let claude = RGB8(r: 0xD9, g: 0x77, b: 0x57)

    static func samples(_ codes: [RGB8]) -> [Sample] {
        ScreenBarBlend.columnSamples(colors: codes.map(\.rgb), bandWidth: bandWidth,
                                     alphaScale: ScreenBarBlend.coreAlpha)
    }

    /// What lands on a black backdrop: the layer composites
    /// unpremultiplied colour at its alpha.
    static func composite(_ s: Sample) -> (r: Double, g: Double, b: Double) {
        (Double(s.r * s.a), Double(s.g * s.a), Double(s.b * s.a))
    }

    /// Core Animation's `.linear` keyframe interpolation: RGB and alpha
    /// each on their own straight line between the bracketing stops.
    static func presented(_ frames: [[Sample]], keyTimes: [Double], at f: Double) -> [Sample] {
        let i = keyTimes.lastIndex { $0 <= f } ?? 0
        guard i < frames.count - 1 else { return frames[frames.count - 1] }
        let u = CGFloat((f - keyTimes[i]) / (keyTimes[i + 1] - keyTimes[i]))
        return zip(frames[i], frames[i + 1]).map { a, b in
            Sample(r: a.r + (b.r - a.r) * u, g: a.g + (b.g - a.g) * u,
                   b: a.b + (b.b - a.b) * u, a: a.a + (b.a - a.a) * u)
        }
    }

    // MARK: The blend

    @Test func aUniformCodeIsExactFromEndToEnd() throws {
        let columns = Self.samples(Array(repeating: Self.claude, count: 8))
        let want = Self.claude.rgb
        for (index, column) in columns.enumerated() {
            // Every column, the band's ends included, is the code itself —
            // not the 1.5× interior (255,178,130 peach) nor the 0.75× ends.
            #expect(abs(Double(column.r) - want.r) < 1.0 / 512, "column \(index) red \(column.r)")
            #expect(abs(Double(column.g) - want.g) < 1.0 / 512, "column \(index) green \(column.g)")
            #expect(abs(Double(column.b) - want.b) < 1.0 / 512, "column \(index) blue \(column.b)")
            #expect(column.a == ScreenBarBlend.coreAlpha)
        }
        #expect(Set(columns.map { [$0.r, $0.g, $0.b] }).count == 1, "one colour end to end")
        // The hue holds: channel ratios match the code's.
        let middle = columns[columns.count / 2]
        #expect(abs(Double(middle.g / middle.r) - want.g / want.r) < 0.005)
        #expect(abs(Double(middle.b / middle.r) - want.b / want.r) < 0.005)
    }

    @Test func theFrameClockPaintsTheSameUniformColour() {
        let stops = ScreenBarBlend.stops(colors: Array(repeating: Self.claude.rgb, count: 8),
                                         bandWidth: Self.bandWidth, alphaScale: ScreenBarBlend.coreAlpha)
        #expect(!stops.isEmpty)
        #expect(stops.first?.location == 0 && stops.last?.location == 1)
        #expect(Set(stops.map { [$0.r, $0.g, $0.b, $0.a] }).count == 1)
        #expect(abs(Double(stops[0].r) - Self.claude.rgb.r) < 1.0 / 512)
    }

    @Test func aLoneLedSharesItsLightAcrossThreeSlots() {
        // The normalisation's stated cost: one lit LED's centre reads 2/3,
        // its weight (1) over the three it overlaps (1 + 2 × 0.25).
        var codes = Array(repeating: RGB8(r: 0, g: 0, b: 0), count: 8)
        codes[3] = RGB8(r: 255, g: 255, b: 255)
        let ledWidth = Self.bandWidth / 8
        let centre = ScreenBarBlend.blended(codes.map(\.rgb), x: 3.5 * ledWidth, ledWidth: ledWidth)
        #expect(abs(centre.r - 2.0 / 3.0) < 1e-9)
        // And it never lights the far end of the band.
        let far = ScreenBarBlend.blended(codes.map(\.rgb), x: 7.5 * ledWidth, ledWidth: ledWidth)
        #expect(far.r == 0)
    }

    @Test func aGapsEdgesCarryTheRunsColourAtAlphaZero() {
        // Lit at the ends, dark in the middle: the frame clock's stops at
        // the gap fade along the run's colour, not toward black.
        var codes = Array(repeating: RGB(r: 0, g: 0, b: 0), count: 8)
        codes[0] = Self.claude.rgb
        codes[7] = RGB(r: 0, g: 0, b: 1)
        let stops = ScreenBarBlend.stops(colors: codes, bandWidth: Self.bandWidth,
                                         alphaScale: ScreenBarBlend.coreAlpha)
        let clear = stops.filter { $0.a == 0 }
        #expect(!clear.isEmpty)
        #expect(clear.allSatisfy { $0.r + $0.g + $0.b > 0 }, "a clear stop borrowed no colour")
    }

    // MARK: Keyframes

    @Test func aFadeFromBlackIsAStraightLineOfLight() throws {
        // A real plan: one frame of black, then a linear second to
        // Claude orange. At the ramp's midpoint the composited band must
        // sit on the straight line, not at a quarter of it.
        let program = try LEDSProgram.parse("#000000\n#d97757 1000ms linear")
        let sampler = LEDSSampler(program: program, ledCount: ScreenBarGeometry.ledCount)
        let plan = try #require(LEDSKeyframePlan.render(sampler: sampler))
        let lead = try #require(plan.lead)
        let frames = lead.frames.map(Self.samples)
        let fades = ScreenBarBlend.keyframes(frames, keyTimes: lead.keyTimes)
        #expect(fades.frames.count == fades.keyTimes.count)

        let midpoint = 517
        let fraction = Double(midpoint) / Double(lead.durationMs)
        let target = Self.samples(plan.codes(atMilliseconds: midpoint)).map(Self.composite)
        let shown = Self.presented(fades.frames, keyTimes: fades.keyTimes, at: fraction).map(Self.composite)
        for (column, (got, want)) in zip(shown, target).enumerated() {
            #expect(abs(got.r - want.r) < 2.0 / 255, "column \(column): red \(got.r) vs \(want.r)")
            #expect(abs(got.g - want.g) < 2.0 / 255, "column \(column): green \(got.g) vs \(want.g)")
            #expect(abs(got.b - want.b) < 2.0 / 255, "column \(column): blue \(got.b) vs \(want.b)")
        }
        // Negative control: the raw stops, (0,0,0,0) into the lit colour,
        // land near a quarter of the light — the fade the probe measured.
        let raw = Self.presented(frames, keyTimes: lead.keyTimes, at: fraction).map(Self.composite)
        let middle = raw.count / 2
        #expect(raw[middle].r < target[middle].r * 0.6,
                "the unfixed keyframes should reproduce the squared fade")
    }

    @Test func aDarkStopBetweenTwoColoursIsEmittedTwice() {
        let red = Self.samples(Array(repeating: RGB8(r: 255, g: 0, b: 0), count: 8))
        let dark = Self.samples(Array(repeating: RGB8(r: 0, g: 0, b: 0), count: 8))
        let blue = Self.samples(Array(repeating: RGB8(r: 0, g: 0, b: 255), count: 8))
        let fades = ScreenBarBlend.keyframes([red, dark, blue], keyTimes: [0, 0.5, 1])
        #expect(fades.keyTimes == [0, 0.5, 0.5, 1])
        // Both copies are dark; the first fades red out, the second
        // fades blue in.
        #expect(fades.frames[1].allSatisfy { $0 == Sample(r: 1, g: 0, b: 0, a: 0) })
        #expect(fades.frames[2].allSatisfy { $0 == Sample(r: 0, g: 0, b: 1, a: 0) })
        // Each half is a straight line of its own colour's light.
        let out = Self.presented(fades.frames, keyTimes: fades.keyTimes, at: 0.25).map(Self.composite)
        let back = Self.presented(fades.frames, keyTimes: fades.keyTimes, at: 0.75).map(Self.composite)
        let half = Double(ScreenBarBlend.coreAlpha) / 2
        #expect(out.allSatisfy { abs($0.r - half) < 1e-6 && $0.b == 0 })
        #expect(back.allSatisfy { abs($0.b - half) < 1e-6 && $0.r == 0 })
    }

    @Test func litOnlyTracksPassThroughUntouched() {
        let red = Self.samples(Array(repeating: RGB8(r: 255, g: 0, b: 0), count: 8))
        let blue = Self.samples(Array(repeating: RGB8(r: 0, g: 0, b: 255), count: 8))
        let fades = ScreenBarBlend.keyframes([red, blue, red], keyTimes: [0, 0.5, 1])
        #expect(fades.frames == [red, blue, red])
        #expect(fades.keyTimes == [0, 0.5, 1])
    }

    @Test func anUnlitColumnBorrowsTheNearestLitColumnAlongTheBand() {
        let lit = Sample(r: 1, g: 0.5, b: 0, a: 0.95)
        let other = Sample(r: 0, g: 0, b: 1, a: 0.95)
        let off = Sample(r: 0, g: 0, b: 0, a: 0)
        let filled = ScreenBarBlend.spatiallyFilled([off, lit, off, off, off, other, off])
        #expect(filled == [lit.cleared, lit, lit.cleared, lit.cleared, other.cleared, other, other.cleared])
        // Nothing lit, nothing to borrow.
        #expect(ScreenBarBlend.spatiallyFilled([off, off]) == [off, off])
    }
}
