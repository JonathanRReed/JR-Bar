import SwiftUI
import Testing
import JRBarCore
@testable import JRBarApp

/// The island meets the bezel without a seam: at every size a morph
/// passes through, the top row of the silhouette is solid from edge to
/// edge (no gap between a shoulder and the body, no notch cut into it),
/// nothing rises above the screen's edge, the hardware's own rectangle
/// is always covered, and a shoulder is never a bump.
@Suite("Notch silhouette seam")
struct NotchSilhouetteSeamTests {
    private let slot: CGFloat = 185
    private let depth: CGFloat = 32

    private func silhouette() -> NotchSilhouette {
        NotchSilhouette(notchDepth: depth, restingRadius: 8, notchWidth: slot)
    }

    /// The sizes of a grow from the resting notch to the card, fine
    /// enough to catch a size where something pops.
    private var sizes: [CGSize] {
        var out: [CGSize] = []
        for step in 0...120 {
            let t = CGFloat(step) / 120
            out.append(CGSize(width: slot + (320 - slot) * t, height: depth + (422 - depth) * t))
        }
        // The overshoot of the grow, a notice, an ask, the swell.
        out += [CGSize(width: 326, height: 430), CGSize(width: 285, height: 54),
                CGSize(width: 300, height: 107), CGSize(width: 191, height: 35),
                CGSize(width: slot, height: 35)]
        return out
    }

    @Test("the top row is solid from the shoulder's tip to the other, with no gap, at every size")
    func topRowIsSolid() {
        let y: CGFloat = 0.25
        for size in sizes {
            let flare = NotchSilhouetteGeometry.topFlare(size: size, notchWidth: slot, notchDepth: depth)
            let path = silhouette().path(in: CGRect(origin: .zero, size: size))
            // A concave shoulder's own curve leaves the very corner empty for a point or so
            // (the arc is tangent to the edge there); everything inside that is solid.
            let tip = flare > 0 ? (flare * flare - (flare - y) * (flare - y)).squareRoot() + 0.3 : 0.25
            var x = tip
            while x < size.width - tip {
                #expect(path.contains(CGPoint(x: x, y: y)),
                        "gap in the top row at x=\(x) of \(size.width)x\(size.height)")
                x += 0.5
            }
        }
    }

    @Test("nothing rises above the screen's edge or past the frame")
    func staysInsideTheFrame() {
        for size in sizes {
            let bounds = silhouette().path(in: CGRect(origin: .zero, size: size)).boundingRect
            #expect(bounds.minY >= -0.001, "rises above the bezel at \(size)")
            #expect(bounds.minX >= -0.001 && bounds.maxX <= size.width + 0.001)
            #expect(bounds.maxY <= size.height + 0.001)
            #expect(abs(bounds.width - size.width) < 0.01, "the top row spans the whole width at \(size)")
        }
    }

    @Test("the hardware's rectangle is always covered, so no gap shows against the notch")
    func coversTheNotch() {
        for size in sizes where size.width >= slot {
            let path = silhouette().path(in: CGRect(origin: .zero, size: size))
            let left = (size.width - slot) / 2 + 1
            let right = left + slot - 2
            var x = left
            while x <= right {
                var y: CGFloat = 0.5
                while y <= min(depth, size.height) - 10 {
                    #expect(path.contains(CGPoint(x: x, y: y)), "gap at (\(x), \(y)) of \(size)")
                    y += 3
                }
                x += 3
            }
        }
    }

    @Test("the shoulder joins the body without a step: the side below it stays on one line")
    func shoulderJoinsTheBody() {
        let size = CGSize(width: 320, height: 300)
        let flare = NotchSilhouetteGeometry.topFlare(size: size, notchWidth: slot, notchDepth: depth)
        #expect(flare == NotchSilhouetteGeometry.maximumTopFlare)
        let path = silhouette().path(in: CGRect(origin: .zero, size: size))
        // Just inside the body's side from the shoulder's foot down to the corner: solid.
        var y = flare + 1
        while y < size.height - 40 {
            #expect(path.contains(CGPoint(x: flare + 0.5, y: y)), "side broken at y=\(y)")
            #expect(!path.contains(CGPoint(x: flare - 0.5, y: y)), "side bulges at y=\(y)")
            y += 4
        }
    }
}
