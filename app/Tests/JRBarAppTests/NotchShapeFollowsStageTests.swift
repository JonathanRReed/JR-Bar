import AppKit
import SwiftUI
import Testing
import JRBarCore
@testable import JRBarApp

/// The silhouette is the stage's shape on both axes, whatever the face
/// inside it asks for. A face with a rigid width (the grown card's 320
/// points) used to hold the black as wide as itself from the first frame
/// of a grow, so the island arrived as a wide tab and only deepened.
@Suite("Notch shape follows the stage")
@MainActor
struct NotchShapeFollowsStageTests {
    private func blackBounds(_ toy: NotchToy, shapeWidth: CGFloat, row: Int) throws -> (width: Int, center: CGFloat) {
        toy.stage.shape = CGRect(x: (400 - shapeWidth) / 2, y: 0, width: shapeWidth, height: 80)
        let scene = NotchIslandView(toy: toy).frame(width: 400, height: 200).background(Color.white)
        let bitmap = try ProofRender.render(scene, size: CGSize(width: 400, height: 200),
                                            scale: 1, settle: 0)
        var lo = Int.max, hi = -1
        for x in 0..<400 {
            let c = try #require(bitmap.colorAt(x: x, y: row))
            if c.redComponent < 0.2 { lo = min(lo, x); hi = max(hi, x) }
        }
        return hi < lo ? (0, 0) : (hi - lo + 1, CGFloat(lo + hi + 1) / 2)
    }

    @Test("a grown card on a narrow stage shape is cut to that shape, not as wide as the card")
    func cardIsCutToTheShape() throws {
        let (toy, store, monitor) = NotchSurfaceRenderProofTests.makeToy()
        defer { withExtendedLifetime(store) {} }
        NotchSurfaceRenderProofTests.fill(toy.cardModel, monitor: monitor)
        toy.expand(held: true)
        toy.stage.setOpenness(0.1, expanded: true)
        toy.stage.showContent(level: 1, expanded: true)
        for width in [185.0, 240.0, 300.0] {
            let bounds = try blackBounds(toy, shapeWidth: width, row: 40)
            let span = bounds.width
            // Below the shoulders the body sits the flare (at most 4 pt) in from each side.
            #expect(Double(span) <= width + 1 && Double(span) >= width - 9, "shape \(width) drew \(span) wide")
            #expect(abs(bounds.center - 200) <= 1, "shape \(width) drew at \(bounds.center)")
        }
    }

    @Test("a wide resting face on a narrow stage shape is cut to that shape too")
    func idleIsCutToTheShape() throws {
        let (toy, store, monitor) = NotchSurfaceRenderProofTests.makeToy()
        defer { withExtendedLifetime(store) {} }
        NotchSurfaceRenderProofTests.fill(toy.cardModel, monitor: monitor)
        for width in [185.0, 240.0] {
            let bounds = try blackBounds(toy, shapeWidth: width, row: 40)
            let span = bounds.width
            // Below the shoulders the body sits the flare (at most 4 pt) in from each side.
            #expect(Double(span) <= width + 1 && Double(span) >= width - 9, "shape \(width) drew \(span) wide")
            #expect(abs(bounds.center - 200) <= 1, "shape \(width) drew at \(bounds.center)")
        }
    }
}
