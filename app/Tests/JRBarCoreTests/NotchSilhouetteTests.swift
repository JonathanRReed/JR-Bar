import Foundation
import Testing
@testable import JRBarCore

@Suite("Notch silhouette")
struct NotchSilhouetteTests {
    @Test func tallCardFitsSmallAndOffsetDisplays() {
        for screen in [CGRect(x: 0, y: 0, width: 1366, height: 768),
                       CGRect(x: -1366, y: -768, width: 1366, height: 768)] {
            let frame = NotchIslandLayout.frame(screenFrame: screen, centerX: screen.midX,
                size: CGSize(width: 340, height: 1200), topInset: 6)
            #expect(frame.maxY == screen.maxY - 6)
            #expect(frame.minY == screen.minY + NotchIslandLayout.edgeMargin)
            #expect(screen.contains(frame))
        }
    }

    @Test func compactBodyKeepsHardwareCorners() {
        for radius: CGFloat in [4, 8, 16] {
            #expect(NotchSilhouetteGeometry.radius(size: CGSize(width: 260, height: 36),
                notchDepth: 32, restingRadius: radius) == radius)
        }
    }

    @Test func growingBodySoftensContinuouslyAndReversesWithoutState() {
        var previous: CGFloat = 8
        var firstFull: Int?
        for height in 36...300 {
            let current = NotchSilhouetteGeometry.radius(size: CGSize(width: 340, height: height),
                notchDepth: 32, restingRadius: 8)
            #expect(current >= previous && current <= 28)
            #expect(current - previous < 0.25, "the corner changes gently as the body grows: \(current - previous)")
            if firstFull == nil, current >= 28 { firstFull = height }
            previous = current
        }
        #expect(previous == 28)
        // The corner finishes growing only as the body becomes a card, not within its first
        // few points of travel.
        #expect((firstFull ?? 0) > 180, "full corner at \(firstFull ?? 0) pt")
        #expect(NotchSilhouetteGeometry.radius(size: CGSize(width: 340, height: 36),
            notchDepth: 32, restingRadius: 8) == 8)
        // A one-line notice already has a soft foot.
        #expect(NotchSilhouetteGeometry.radius(size: CGSize(width: 285, height: 54),
            notchDepth: 32, restingRadius: 8) > 10)
    }

    @Test func cornerIsAFunctionOfTheSizeAlone() {
        // The same size wears the same corner whichever way the body got there.
        let size = CGSize(width: 300, height: 140)
        let a = NotchSilhouetteGeometry.radius(size: size, notchDepth: 32, restingRadius: 8)
        let b = NotchSilhouetteGeometry.radius(size: size, notchDepth: 32, restingRadius: 8)
        #expect(a == b)
    }

    @Test func shouldersSwellWithTheBodyAndNeverPopIn() {
        // Nothing on the bare housing or a notch-less pill.
        #expect(NotchSilhouetteGeometry.topFlare(size: CGSize(width: 185, height: 32), notchWidth: 185, notchDepth: 32) == 0)
        #expect(NotchSilhouetteGeometry.topFlare(size: CGSize(width: 300, height: 100), notchWidth: 185, notchDepth: 0) == 0)
        var previous: CGFloat = 0
        for width in stride(from: 185.0, through: 330.0, by: 0.5) {
            let flare = NotchSilhouetteGeometry.topFlare(size: CGSize(width: width, height: 120),
                                                         notchWidth: 185, notchDepth: 32)
            #expect(flare >= previous, "the shoulder only grows with the body")
            #expect(flare - previous < 0.15, "and never pops: \(flare - previous) pt per half point of width")
            #expect(flare <= (width - 185) / 2 + 1e-9, "the body below it is never narrower than the notch")
            previous = flare
        }
        #expect(previous == NotchSilhouetteGeometry.maximumTopFlare)
    }

    @Test func externalDisplayGrowsFromPillToCard() {
        #expect(NotchSilhouetteGeometry.radius(size: CGSize(width: 180, height: 24),
            notchDepth: 0, restingRadius: 8) == 12)
        #expect(NotchSilhouetteGeometry.radius(size: CGSize(width: 340, height: 300),
            notchDepth: 0, restingRadius: 8) == 28)
        #expect(NotchSilhouetteGeometry.radius(size: .zero,
            notchDepth: 32, restingRadius: 8) == 0)
    }
}
