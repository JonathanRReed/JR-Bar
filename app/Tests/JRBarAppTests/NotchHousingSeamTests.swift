import SwiftUI
import Testing
import JRBarCore
import JRBarUI
@testable import JRBarApp

/// The Screen Bar's housing continues the island's body downward, so its
/// sides must be the body's: the silhouette draws its body in from the
/// frame's edge by the shoulder's width, and a housing cut to the frame
/// stepped out past it by that width on both sides, a visible jog under
/// every notice, ask and card while the Screen Bar was up.
@Suite("Notch housing seam")
@MainActor
struct NotchHousingSeamTests {
    private let slot: CGFloat = 185
    private let depth: CGFloat = 32

    @Test("the body is the frame less the shoulders, and the bare housing and a notch-less pill lose nothing")
    func bodyRect() {
        let notice = CGRect(x: 100, y: 0, width: 285, height: 54)
        let body = NotchSilhouetteGeometry.body(of: notice, notchWidth: slot, notchDepth: depth)
        #expect(body.minX == notice.minX + NotchSilhouetteGeometry.maximumTopFlare)
        #expect(body.maxX == notice.maxX - NotchSilhouetteGeometry.maximumTopFlare)
        #expect(body.minY == notice.minY && body.height == notice.height)

        let bare = CGRect(x: 100, y: 0, width: slot, height: depth)
        #expect(NotchSilhouetteGeometry.body(of: bare, notchWidth: slot, notchDepth: depth) == bare)
        #expect(NotchSilhouetteGeometry.body(of: notice, notchWidth: slot, notchDepth: 0) == notice)
        #expect(NotchSilhouetteGeometry.body(of: notice, notchWidth: 0, notchDepth: depth) == notice)
    }

    @Test("the body is exactly the span the silhouette fills at mid-height")
    func bodyMatchesTheDrawnShape() {
        let silhouette = NotchSilhouette(notchDepth: depth, restingRadius: 8, notchWidth: slot)
        for size in [CGSize(width: 285, height: 54), CGSize(width: 300, height: 107),
                     CGSize(width: 320, height: 300)] {
            let frame = CGRect(origin: .zero, size: size)
            let body = NotchSilhouetteGeometry.body(of: frame, notchWidth: slot, notchDepth: depth)
            let path = silhouette.path(in: frame)
            let y = size.height / 2
            #expect(path.contains(CGPoint(x: body.minX + 0.5, y: y)))
            #expect(!path.contains(CGPoint(x: body.minX - 0.5, y: y)))
            #expect(path.contains(CGPoint(x: body.maxX - 0.5, y: y)))
            #expect(!path.contains(CGPoint(x: body.maxX + 0.5, y: y)))
        }
    }

    @Test("a coupled Screen Bar's housing stands under the island's body, not its frame")
    func housingFollowsTheBody() throws {
        for size in [CGSize(width: 285, height: 54), CGSize(width: 300, height: 107),
                     CGSize(width: 320, height: 422)] {
            let canvas = CGSize(width: 520, height: size.height + ScreenBarDesign.bandHeight
                                + ScreenBarGeometry.coupledChin + ScreenBarGeometry.coupledSlack + 30)
            let frame = CGRect(x: (canvas.width - size.width) / 2, y: canvas.height - size.height,
                               width: size.width, height: size.height)
            let bar = ScreenBarView(frame: CGRect(origin: .zero, size: canvas))
            bar.wingGeometry = ScreenBarWingGeometry(notchWidth: slot, notchDepth: depth,
                                                     bandSpan: size.width, leftExtent: 40, rightExtent: 40)
            bar.notchCornerRadius = 8
            bar.islandFrame = frame
            bar.relayout()
            let housing = try #require(bar.housingRect)
            let body = NotchSilhouetteGeometry.body(of: frame, notchWidth: slot, notchDepth: depth)
            #expect(housing.minX == body.minX && housing.maxX == body.maxX,
                    "the housing's sides are the island body's at \(size)")
            #expect(housing.minX > frame.minX, "and not the frame's")
        }
    }
}
