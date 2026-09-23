import AppKit
import Foundation
import Testing
@testable import JRBarApp

/// The media row's artwork tint: a cover's mean colour, lifted so it
/// reads on black, and nothing at all for grey art.
@Suite("Shelf artwork tint")
@MainActor
struct ShelfArtworkTintTests {
    /// A solid PNG, made in memory.
    private func png(red: CGFloat, green: CGFloat, blue: CGFloat) -> Data? {
        guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 8, pixelsHigh: 8,
                                         bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                                         isPlanar: false, colorSpaceName: .deviceRGB,
                                         bytesPerRow: 0, bitsPerPixel: 0) else { return nil }
        let color = NSColor(deviceRed: red, green: green, blue: blue, alpha: 1)
        for x in 0..<8 { for y in 0..<8 { rep.setColor(color, atX: x, y: y) } }
        return rep.representation(using: .png, properties: [:])
    }

    @Test("grey art has no colour; a dark cover's colour is lifted to read on black")
    func readable() throws {
        #expect(ShelfUtilityModel.readableTint(red: 0.5, green: 0.5, blue: 0.52) == nil)
        #expect(ShelfUtilityModel.readableTint(red: 0.05, green: 0.05, blue: 0.05) == nil)
        let darkRed = try #require(ShelfUtilityModel.readableTint(red: 0.3, green: 0.05, blue: 0.05))
        #expect(darkRed.hue < 0.02 || darkRed.hue > 0.98, "still red")
        #expect(darkRed.brightness >= 0.78, "lifted off the black")
        #expect(darkRed.saturation <= 0.75, "never neon")
        let blue = try #require(ShelfUtilityModel.readableTint(red: 0.1, green: 0.3, blue: 0.9))
        #expect(abs(blue.hue - 0.6) < 0.05)
    }

    @Test("a cover's mean colour is read from the image itself")
    func average() throws {
        let data = try #require(png(red: 0.9, green: 0.2, blue: 0.1))
        let mean = try #require(ShelfUtilityModel.averageColor(of: data))
        #expect(mean.red > 0.7 && mean.green < 0.4 && mean.blue < 0.3)
        #expect(ShelfUtilityModel.averageColor(of: Data("not an image".utf8)) == nil)
    }
}
