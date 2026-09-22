import Foundation
import Testing
@testable import JRBarLEDS

/// `LEDSProgram.widened` -- the Dot's two LEDs spread over the bar's eight,
/// band for band (the Screen Bar mirroring a lone Dot).
@Suite struct WidenTests {
    @Test func aColourListBecomesTwoBandsOfFour() throws {
        let program = try LEDSProgram.parse("#FF0000 #00FF00 500ms cosine\nrepeat", ledCount: 2)
        let widened = program.widened(from: 2, to: 8)
        #expect(widened.ledCount == 8)
        #expect(widened.render() == "#FF0000 #FF0000 #FF0000 #FF0000 #00FF00 #00FF00 #00FF00 #00FF00 500ms cosine\nrepeat")
    }

    @Test func aWholeBarAndTheDirectivesPassThrough() throws {
        let text = "brightness 128\n// keep me\nroll-left 2s\n#12E3B0 600ms pulse\nrepeat 3"
        let widened = try LEDSProgram.parse(text, ledCount: 2).widened(from: 2, to: 8)
        #expect(widened.render() == text)
    }

    @Test func indexedPaintExpandsEachSourceLEDToItsBand() throws {
        let widened = try LEDSProgram.parse("0:#FF0000 400ms", ledCount: 2).widened(from: 2, to: 8)
        #expect(widened.render() == "0:#FF0000 1:#FF0000 2:#FF0000 3:#FF0000 400ms")
    }

    @Test func indicesPastTheSourceAreDropped() throws {
        let widened = try LEDSProgram.parse("0:#FF0000 1:#00FF00 5:#0000FF 400ms", ledCount: 2).widened(from: 2, to: 8)
        #expect(widened.render() == "0:#FF0000 1:#FF0000 2:#FF0000 3:#FF0000 4:#00FF00 5:#00FF00 6:#00FF00 7:#00FF00 400ms")
        // A line naming only out-of-range LEDs takes no time on either device.
        let empty = try LEDSProgram.parse("5:#0000FF 400ms", ledCount: 2).widened(from: 2, to: 8)
        #expect(empty.steps.isEmpty)
    }

    /// The parity check against the Python `upsample_program`: the widened
    /// text parses at eight and its sampled frame lights bands, not LEDs.
    @Test func theWidenedProgramPlaysAsBands() throws {
        let widened = try LEDSProgram.parse("#FF0000 #00FF00 500ms cosine\nrepeat", ledCount: 2).widened(from: 2, to: 8)
        let reparsed = try LEDSProgram.parse(widened.render(), ledCount: 8)
        let codes = LEDSSampler(program: reparsed, ledCount: 8).codes(atMilliseconds: 500)
        #expect(codes.count == 8)
        for index in 0..<4 {
            #expect(codes[index].r > 200 && codes[index].g < 40 && codes[index].b < 40,
                    "LED \(index) should be red-ish, got \(codes[index].hex)")
        }
        for index in 4..<8 {
            #expect(codes[index].g > 200 && codes[index].r < 40 && codes[index].b < 40,
                    "LED \(index) should be green-ish, got \(codes[index].hex)")
        }
    }
}
