import AppKit
import Testing
@testable import JRBarUI

/// The provider marks as data: every mark parses, fitted and centred in
/// its square; a mark is parsed once; bad data throws and never traps;
/// and a fill lands where the mark is.
@Suite("Provider logo data")
struct ProviderLogoTests {
    @Test func everyMarkInTheDataIsFittedAndCentred() throws {
        #expect(ProviderLogo.ids.count == ProviderLogoData.paths.count)
        #expect(ProviderLogo.ids.count >= 15)
        for id in ProviderLogo.ids {
            let logo = try #require(ProviderLogo.named(id), "\(id) does not parse")
            #expect(logo.id == id)
            let bounds = logo.unitPath.boundingBoxOfPath
            #expect(bounds.minX >= -0.001 && bounds.minY >= -0.001, "\(id) is \(bounds)")
            #expect(bounds.maxX <= 1.001 && bounds.maxY <= 1.001, "\(id) is \(bounds)")
            #expect(abs(bounds.midX - 0.5) < 0.005 && abs(bounds.midY - 0.5) < 0.005, "\(id) is off centre")
            // The longer side is the mark's optical scale: 0.84 for the
            // blocky marks, up to the whole square.
            let longer = max(bounds.width, bounds.height)
            #expect(longer > 0.83 && longer < 1.001, "\(id) fills \(longer)")
        }
    }

    @Test func aMarkIsParsedOnceAndShared() {
        let first = ProviderLogo.named("claude")
        #expect(first != nil)
        #expect(first === ProviderLogo.named("claude"))
        #expect(ProviderLogo.named("not-a-provider") == nil)
    }

    @Test("bad path data throws and never traps",
          arguments: ["7 7", "L1 2", "Z", "M1", "M1 2Z3", "Mx 1", "M0 0A1 1 0 2 0 1 1", "M0 0Q1", "M1e999 0",
                      "M0 0K1 1"])
    func theParserRejectsBadData(_ data: String) {
        #expect(throws: SVGPathParser.ParseError.self) { try SVGPathParser.parse(data) }
    }

    @Test func theParserReadsEveryCommand() throws {
        // A 10-unit square, absolute and relative.
        let absolute = try SVGPathParser.parse("M0 0H10V10H0Z")
        let relative = try SVGPathParser.parse("m0,0h10v10h-10z")
        #expect(absolute.boundingBoxOfPath == CGRect(x: 0, y: 0, width: 10, height: 10))
        #expect(relative.boundingBoxOfPath == absolute.boundingBoxOfPath)
        // Curves, their smooth forms, an arc and an exponent.
        let curves = try SVGPathParser.parse("M0 0C0 5 5 10 10 10S20 5 20 0Q25 -5 30 0T40 0A5 5 0 0 1 50 0L50 1e1Z")
        let bounds = curves.boundingBoxOfPath
        #expect(bounds.minX == 0 && abs(bounds.maxX - 50) < 0.001 && abs(bounds.maxY - 10) < 0.001)
        #expect(bounds.minY < -2, "the arc and the quadratic dip below the line")
        // Packed numbers and packed arc flags, as the upstream files write them.
        let packed = try SVGPathParser.parse("M.5.5l1-1a1 1 0 00-.4 1z")
        #expect(!packed.isEmpty)
        #expect(try SVGPathParser.parse("").isEmpty)
    }

    @Test func theHairlineIsForSmallClaudeAndGrokOnly() {
        #expect(ProviderLogo.hairline(for: "claude", side: 8) == 0.45)
        #expect(ProviderLogo.hairline(for: "grok", side: 11) == 0.3)
        #expect(ProviderLogo.hairline(for: "claude", side: 12) == 0)
        #expect(ProviderLogo.hairline(for: "openai", side: 8) == 0)
        #expect(ProviderLogo.hairline(for: "hermes", side: 9) == 0)
    }

    /// Inked pixels per row of a 40 px bitmap (row 0 is the top) after a
    /// fill into `rect` of its y-up context.
    static func rows(_ logo: ProviderLogo, rect: CGRect) throws -> [Int] {
        let context = try #require(CGContext(data: nil, width: 40, height: 40, bitsPerComponent: 8, bytesPerRow: 40,
                                             space: CGColorSpaceCreateDeviceGray(),
                                             bitmapInfo: CGImageAlphaInfo.none.rawValue))
        context.setFillColor(gray: 1, alpha: 1)
        logo.fill(in: rect, context: context)
        let data = try #require(context.data)
        let pixels = data.bindMemory(to: UInt8.self, capacity: 40 * 40)
        return (0..<40).map { y in (0..<40).filter { pixels[y * 40 + $0] > 127 }.count }
    }

    @Test func aFillLandsInItsRectTheRightWayUp() throws {
        let jrbar = try #require(ProviderLogo.named("jrbar"))
        // JR-Bar's mark is the notch cap (9 of 13 units wide) over the bar
        // (all 13). Right way up, a row through the cap inks about 28 px
        // and a row through the bar all 40.
        let whole = try Self.rows(jrbar, rect: CGRect(x: 0, y: 0, width: 40, height: 40))
        #expect(whole[12] > 20 && whole[12] < 32, "cap row \(whole[12])")
        #expect(whole[28] > 36, "bar row \(whole[28])")
        #expect(whole[0] == 0 && whole[39] == 0, "the mark sits inside its optical margin")
        // The lower-left quarter of the context only: nothing lands above it.
        let corner = try Self.rows(jrbar, rect: CGRect(x: 0, y: 0, width: 20, height: 20))
        #expect(corner[0..<20].allSatisfy { $0 == 0 })
        #expect(corner[20..<40].reduce(0, +) > 100)
        #expect(corner.allSatisfy { $0 <= 20 })
    }
}
