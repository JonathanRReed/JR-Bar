import Foundation
import Testing
@testable import JRBarLEDS

/// Every fixture program sampled by the firmware (sdled.wasm) must match the
/// Swift sampler within one 8-bit code per channel at every recorded time.
@Suite struct SamplerParityTests {
    static let tolerance = 1

    @Test func fixturesArePresent() throws {
        let fixtures = try Fixtures.programs()
        #expect(fixtures.count >= 12, Comment(rawValue: "expected at least a dozen program fixtures, found \(fixtures.count)"))
        let required = [0, 50, 100, 250, 500, 1000, 1500, 2000, 3700]
        for fixture in fixtures {
            let times = Set(fixture.samples.map(\.t_ms))
            #expect(required.allSatisfy(times.contains), Comment(rawValue: "\(fixture.name) is missing a required sample time"))
        }
    }

    @Test(arguments: try Fixtures.programs().map(\.name))
    func matchesFirmware(fixtureName: String) throws {
        let fixture = try #require(try Fixtures.programs().first { $0.name == fixtureName })
        let program = try LEDSProgram.parse(fixture.program, ledCount: fixture.led_count)
        let sampler = LEDSSampler(program: program, ledCount: fixture.led_count)
        var worst = 0
        var mismatches: [String] = []
        for sample in fixture.samples {
            let codes = sampler.codes(atMilliseconds: sample.t_ms)
            #expect(codes.count == sample.colors.count)
            for (index, expected) in sample.colors.enumerated() where index < codes.count {
                let got = codes[index]
                let diff = max(abs(Int(got.r) - expected[0]), abs(Int(got.g) - expected[1]), abs(Int(got.b) - expected[2]))
                worst = max(worst, diff)
                if diff > Self.tolerance, mismatches.count < 8 {
                    mismatches.append("t=\(sample.t_ms)ms led\(index): got \(got.hex) expected #\(String(format: "%02X%02X%02X", expected[0], expected[1], expected[2]))")
                }
            }
        }
        #expect(mismatches.isEmpty, Comment(rawValue: "\(fixture.name): \(mismatches.joined(separator: "; "))"))
        #expect(worst <= Self.tolerance, Comment(rawValue: "\(fixture.name): worst per-channel error \(worst)"))
    }

    @Test func colorsAtSecondsFloorsToMilliseconds() throws {
        let program = try LEDSProgram.parse("#000000\n#ffffff 1000ms linear")
        let sampler = LEDSSampler(program: program)
        let atSeconds = sampler.colors(at: 0.5179)
        let atMs = sampler.codes(atMilliseconds: 517)
        #expect(atSeconds[0].codes == atMs[0])
        // 127.5 rounds toward zero on the delta, as the firmware does.
        #expect(atMs[0] == RGB8(r: 127, g: 127, b: 127))
    }

    @Test func transitionsStartFromInitialCodes() throws {
        let program = try LEDSProgram.parse("#0000ff 1000ms linear")
        let sampler = LEDSSampler(program: program, initialCodes: Array(repeating: RGB8(r: 255, g: 0, b: 0), count: 8))
        #expect(sampler.codes(atMilliseconds: 0)[0] == RGB8(r: 255, g: 0, b: 0))
        #expect(sampler.codes(atMilliseconds: 500)[0] == RGB8(r: 128, g: 0, b: 127))
        #expect(sampler.codes(atMilliseconds: 1000)[0] == RGB8(r: 0, g: 0, b: 255))
    }

    @Test func rawCodesIgnoreBrightness() throws {
        let program = try LEDSProgram.parse("brightness 10\n#ff0000")
        let sampler = LEDSSampler(program: program)
        #expect(sampler.codes(atMilliseconds: 0)[0] == RGB8(r: 10, g: 0, b: 0))
        #expect(sampler.rawCodes(atMilliseconds: 0)[0] == RGB8(r: 255, g: 0, b: 0))
    }

    @Test func durationsAndStaticness() throws {
        #expect(try LEDSProgram.parse("#ff0000").isStatic)
        #expect(try LEDSProgram.parse("off").isStatic)
        #expect(try LEDSProgram.parse("#ff0000").cycleDuration == nil)
        let breathing = try LEDSProgram.parse("off 160ms cosine\n#020204 1900ms cosine\noff 2550ms cosine\noff 850ms none\nrepeat")
        #expect(!breathing.isStatic)
        #expect(breathing.cycleDuration == 5.46)
        #expect(breathing.motionEndsAt == nil)
        let finite = try LEDSProgram.parse("#ff0000 1s pulse")
        #expect(!finite.isStatic)
        #expect(finite.motionEndsAt == 1.0)
        let twoFrames = try LEDSProgram.parse("#ff0000\n#00ff00")
        #expect(twoFrames.motionEndsAt == 0.017)
        let repeated = try LEDSProgram.parse("#ff0000 200ms none\n#0000ff 200ms none\nrepeat 3\n#00ff00 100ms linear")
        #expect(repeated.cycleDuration == 0.4)
        #expect(repeated.motionEndsAt == 1.3)
    }

    @Test func easingCurvesHitKnownPoints() {
        #expect(abs(LEDSEasing.ease.value(0.5) - 0.8024) < 0.002)
        #expect(abs(LEDSEasing.easeIn.value(0.5) - 0.3153) < 0.002)
        #expect(abs(LEDSEasing.easeOut.value(0.5) - 0.6847) < 0.002)
        #expect(abs(LEDSEasing.easeInOut.value(0.5) - 0.5) < 0.002)
        #expect(abs(LEDSEasing.cosine.value(0.5) - 0.5) < 1e-12)
        #expect(abs(LEDSEasing.cosine.value(1.0 / 16.0) - 0.0096) < 0.0002)
        #expect(abs(LEDSEasing.cosine.value(1.0 / 32.0) - 0.0048) < 0.0002)
        #expect(abs(LEDSEasing.pulse.value(0.5) - 1.0) < 1e-12)
        #expect(LEDSEasing.pulse.value(1.0) == 0.0)
        #expect(LEDSEasing.none.value(0.0) == 1.0)
    }

    @Test func colorTransferRoundTrips() {
        for value in stride(from: 0.0, through: 1.0, by: 0.05) {
            #expect(abs(LEDSTransfer.linearToSRGB(LEDSTransfer.srgbToLinear(value)) - value) < 1e-9)
        }
        #expect(abs(LEDSTransfer.srgbToLinear(0.5) - 0.2140) < 0.001)
    }
}
