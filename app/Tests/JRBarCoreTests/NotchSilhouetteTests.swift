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
        for height in 36...200 {
            let current = NotchSilhouetteGeometry.radius(size: CGSize(width: 340, height: height),
                notchDepth: 32, restingRadius: 8)
            #expect(current >= previous && current <= 28)
            #expect(current - previous < 0.4)
            previous = current
        }
        #expect(previous == 28)
        #expect(NotchSilhouetteGeometry.radius(size: CGSize(width: 340, height: 36),
            notchDepth: 32, restingRadius: 8) == 8)
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
