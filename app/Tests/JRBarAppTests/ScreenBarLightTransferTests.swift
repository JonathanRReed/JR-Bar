import Foundation
import JRBarCore
import JRBarLEDS
import Testing
@testable import JRBarApp

@Suite("Linked Screen Bar emitted light")
struct ScreenBarLightTransferTests {
    @Test("the morning drive palette retains the strip's dark tail and raised third beat")
    func morningPalette() throws {
        let transfer = try #require(CoreStripTransfer(channelGains: [1, 1, 1]))
        let drive = [RGB8(r: 16, g: 18, b: 31), RGB8(r: 7, g: 9, b: 14),
                     RGB8(r: 9, g: 9, b: 14), .black, .black, .black]
        let colors = ScreenBarLightTransfer.colors(drive, brightness: 255, transfer: transfer)
        let encoded = colors.map { RGB8(r: UInt8(($0.r * 255).rounded()),
                                        g: UInt8(($0.g * 255).rounded()), b: UInt8(($0.b * 255).rounded())) }
        #expect(encoded == [RGB8(r: 71, g: 75, b: 98), RGB8(r: 46, g: 53, b: 66),
                            RGB8(r: 53, g: 53, b: 66), .black, .black, .black])
    }

    @Test("conversion follows PWM sampling instead of interpolating encoded endpoints")
    func midFade() throws {
        let transfer = try #require(CoreStripTransfer(channelGains: [1, 1, 1]))
        let program = try LEDSProgram.parse("#10121F 250ms linear", ledCount: 8)
        let sampler = LEDSSampler(program: program)
        let half = ScreenBarLightTransfer.colors(sampler.rawCodes(atMilliseconds: 125),
                                                brightness: 255, transfer: transfer)[0]
        let end = ScreenBarLightTransfer.colors(sampler.rawCodes(atMilliseconds: 250),
                                               brightness: 255, transfer: transfer)[0]
        #expect(abs(half.r - 0.19435316156242727) < 0.000001)
        #expect(half.r > end.r / 2, "linear PWM's half light is brighter than half an sRGB code")
    }

    @Test("source calibration is removed and the bar's own gain and brightness apply once")
    func independentControls() throws {
        let transfer = try #require(CoreStripTransfer(channelGains: [1, 0.38, 1],
                                                      displayChannelGains: [1, 1, 1]))
        let code = RGB8(r: 16, g: 7, b: 31)
        let full = ScreenBarLightTransfer.colors([code], brightness: 255, transfer: transfer)[0]
        #expect(abs(full.g * 255 - 75.9831667595151) < 0.000001)
        let dim = ScreenBarLightTransfer.colors([code], brightness: 128, transfer: transfer)[0]
        #expect(abs(dim.g - full.g * 128 / 255) < 0.000001)
        #expect(ScreenBarLightTransfer.colors([code], brightness: 0, transfer: transfer)[0] == RGB(r: 0, g: 0, b: 0))
        let own = try #require(CoreStripTransfer(channelGains: [1, 0.38, 1],
                                                displayChannelGains: [1, 0.5, 1]))
        let tuned = ScreenBarLightTransfer.colors([code], brightness: 255, transfer: own)[0]
        #expect(tuned.r == full.r && tuned.b == full.b && tuned.g < full.g)
    }
    @Test func dotMirrorKeepsItsSourceBudgetAndCanvas() throws {
        let paint = "0:#1D050A 1:#02152A 500ms linear"
        let text = Array(repeating: paint, count: 12).joined(separator: "\n") + "\nroll 2s\nrepeat"
        #expect(text.utf8.count <= 512)
        let decision = ScreenBarController.programDecision(text, sourceLedCount: 2, fallback: "off")
        let program = try #require(decision.program)
        #expect(decision.rejection == nil)
        let source = LEDSSampler(program: program, ledCount: 2)
        let bar = LEDSSampler(program: program, ledCount: 2, outputLedCount: 8)
        for ms in stride(from: 0, through: 24000, by: 37) {
            let expected = source.rawCodes(atMilliseconds: ms)
            #expect(bar.rawCodes(atMilliseconds: ms) == (0..<8).map { expected[$0 / 4] })
        }
    }



    @Test func auditedDotCorpusPlaysOnTheSourceCanvas() throws {
        guard let path = ProcessInfo.processInfo.environment["JRBAR_DELIVERED_AUDIT_PROGRAMS"] else { return }
        struct Row: Decodable { let leds: Int; let program: String }
        let rows = try JSONDecoder().decode([Row].self, from: Data(contentsOf: URL(fileURLWithPath: path)))
        var checked = 0
        for row in rows where row.leds == 2 {
            let sourceProgram = try LEDSProgram.parse(row.program, ledCount: 2)
            let source = LEDSSampler(program: sourceProgram, ledCount: 2)
            let decision = ScreenBarController.programDecision(row.program, sourceLedCount: 2, fallback: "off")
            let installed = try #require(decision.program)
            let mirror = LEDSSampler(program: installed, ledCount: 2, outputLedCount: 8)
            let span = Int(((source.cycleDuration ?? source.motionEndsAt ?? 1) * 3000).rounded())
            for ms in stride(from: 0, through: max(1, span), by: 37) {
                let pixels = source.codes(atMilliseconds: ms)
                let expected = (0..<8).map { pixels[$0 / 4] }
                let actual = mirror.codes(atMilliseconds: ms)
                if actual != expected {
                    Issue.record("Dot mirror changed at \(ms) ms: \(row.program) -> \(decision.programText ?? "refused")")
                    break
                }
            }
            checked += 1
        }
        #expect(checked > 0)
        print("Audited \(checked) Dot programs through the Screen Bar parser and sampler")
    }

}
