import AppKit
import Foundation
import JRBarCore
import JRBarUI
import Testing
@testable import JRBarApp

/// The seasonal garland hangs exactly along the Screen Bar: its string
/// starts and ends at the lit strip's rounded caps and every piece stays
/// inside that span. Pinned against a real `ScreenBarView` laid out under
/// the island, at several notch widths, offsets and card sizes, so the
/// garland follows the band's own geometry rather than a constant.
@Suite("Seasonal garland alignment")
@MainActor
struct SeasonalGarlandAlignmentTests {
    private let depth: CGFloat = 32
    private let resting: CGFloat = 8
    private let size = CGSize(width: 900, height: 600)

    /// A real band under an island `island` (view coordinates, y up).
    private func strip(notchWidth: CGFloat, island: CGRect) -> CGRect {
        let bar = ScreenBarView(frame: CGRect(origin: .zero, size: size))
        bar.earRecoveryReduceMotionOverride = true
        bar.updateLayout {
            bar.notchCornerRadius = resting
            bar.wingGeometry = ScreenBarWingGeometry(notchWidth: notchWidth, notchDepth: depth,
                                                    bandSpan: size.width, leftExtent: 0, rightExtent: 0)
            bar.islandFrame = island
        }
        bar.relayout()
        return bar.bandRect
    }

    /// Every set's pieces lie inside `span` when hung at `size` points.
    private func expectInside(_ span: SeasonalGarlandSpan, pieceSize: Double, _ what: String) {
        for holiday in SeasonalHoliday.allCases {
            let half = SeasonLook.pieceHalfWidth(holiday) * pieceSize
            let count = SeasonLook.count(for: span.length, holiday: holiday)
            let centres = span.centres(count: count, halfWidth: half)
            #expect(!centres.isEmpty, "\(what) \(holiday): nothing hangs")
            for x in centres {
                #expect(x - half >= span.start - 1e-9 && x + half <= span.end + 1e-9,
                        "\(what) \(holiday): a piece at \(x) reaches past \(span.start)…\(span.end)")
            }
        }
    }

    @Test("closed: the garland's window is the strip's width and its string meets the caps",
          arguments: [CGFloat(150), 185, 200, 230, 262])
    func closedNotch(notchWidth: CGFloat) throws {
        for shoulders: CGFloat in [0, 46] {
            for offset: CGFloat in [0, 0.25, 0.5] {
                let width = notchWidth + shoulders
                let island = CGRect(x: (size.width - width) / 2 + offset, y: size.height - depth,
                                    width: width, height: depth)
                let band = strip(notchWidth: notchWidth, island: island)
                #expect(band.width > 0)
                let frame = try #require(SeasonalBandOverlay.frame(strip: band, island: island, notchDepth: depth))
                #expect(frame.minX == band.minX && frame.maxX == band.maxX,
                        "notch \(notchWidth) +\(shoulders) @\(offset): \(frame) vs \(band)")
                #expect(frame.maxY == band.minY, "it hangs from the strip's lower edge")
                // The garland view draws in the window's own coordinates.
                let cap = ScreenBarGeometry.bandCapRadius(band)
                let local = SeasonalGarlandSpan(start: Double(cap), end: Double(frame.width - cap))
                let onScreen = SeasonalGarlandSpan(band: band)
                #expect(abs(Double(frame.minX) + local.start - onScreen.start) < 1e-9)
                #expect(abs(Double(frame.minX) + local.end - onScreen.end) < 1e-9)
                #expect(abs(onScreen.start - Double(band.minX + cap)) < 1e-9)
                #expect(abs(onScreen.end - Double(band.maxX - cap)) < 1e-9)
                expectInside(local, pieceSize: 9.5, "closed \(notchWidth)")
            }
        }
    }

    @Test("open: the card strip's span is the Screen Bar's under the grown card",
          arguments: [CGFloat(300), 320, 360, 420])
    func openCard(cardWidth: CGFloat) {
        let metrics = SeasonalIslandMetrics(notchWidth: 185, notchDepth: depth, restingRadius: resting, topPad: 36)
        for cardHeight: CGFloat in [150, 260, 440] {
            let islandHeight = cardHeight + metrics.topPad
            let island = CGRect(x: 120.5, y: size.height - islandHeight, width: cardWidth, height: islandHeight)
            let band = strip(notchWidth: metrics.notchWidth, island: island)
            let expected = SeasonalGarlandSpan(band: band.offsetBy(dx: -island.minX, dy: 0))
            let span = SeasonalCardStrip.span(cardWidth: cardWidth, cardHeight: cardHeight, metrics: metrics)
            #expect(abs(span.start - expected.start) < 1e-6 && abs(span.end - expected.end) < 1e-6,
                    "card \(cardWidth)×\(cardHeight): \(span) vs the band's \(expected)")
            expectInside(span, pieceSize: 9, "card \(cardWidth)")
        }
    }

    @Test("the string's ends are the strip's cap centres, from the band layer's own radius")
    func capCentres() {
        let band = CGRect(x: 40, y: 10, width: 200, height: ScreenBarDesign.bandHeight)
        let span = SeasonalGarlandSpan(band: band)
        let cap = Double(ScreenBarGeometry.bandCapRadius(band))
        #expect(cap == Double(min(ScreenBarDesign.cornerRadius, ScreenBarDesign.bandHeight / 2)))
        #expect(span.start == 40 + cap && span.end == 240 - cap)
        #expect(span.centres(count: 1, halfWidth: 3) == [140])
        let many = span.centres(count: 5, halfWidth: 4)
        #expect(many.first == span.start + 4 && many.last == span.end - 4)
        #expect(SeasonalGarlandSpan(start: 0, end: 4).centres(count: 3, halfWidth: 3).isEmpty,
                "no room, no pieces")
    }
}
