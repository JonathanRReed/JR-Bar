import JRBarCore
import SwiftUI

/// The island's outline. Notched: flush top edge (the screen's edge is
/// its top), concave shoulders where a grown body reaches past the
/// hardware's side, and bottom corners that start at the notch's own
/// radius and soften as it grows, drawn with continuous (squircle)
/// corners like the hardware's. Notch-less: a pill that grows into a
/// card. Pure black fill is the caller's; the shape adds nothing of its
/// own.
struct NotchSilhouette: Shape {
    var notchDepth: CGFloat
    var restingRadius: CGFloat
    /// The hardware's width — the reference the shoulders measure how
    /// far the body has grown past. 0 draws no shoulders.
    var notchWidth: CGFloat = 0

    func path(in rect: CGRect) -> Path {
        let radius = NotchSilhouetteGeometry.radius(
            size: rect.size, notchDepth: notchDepth, restingRadius: restingRadius)
        let flare = NotchSilhouetteGeometry.topFlare(
            size: rect.size, notchWidth: notchWidth, notchDepth: notchDepth)
        let top: CGFloat = notchDepth > 0 ? 0 : radius
        let body = rect.insetBy(dx: flare, dy: 0)
        var path = UnevenRoundedRectangle(
            topLeadingRadius: top, bottomLeadingRadius: radius,
            bottomTrailingRadius: radius, topTrailingRadius: top,
            style: .continuous).path(in: body)
        guard flare > 0 else { return path }
        path = path.union(Self.shoulder(flare: flare, in: rect, leading: true))
        return path.union(Self.shoulder(flare: flare, in: rect, leading: false))
    }

    /// One concave shoulder: the square `flare` points wide under the
    /// screen's edge, less the quarter circle the body's side curves
    /// away on. It runs a point into the body so the union has no seam.
    static func shoulder(flare: CGFloat, in rect: CGRect, leading: Bool) -> Path {
        let k: CGFloat = 0.5523
        let overlap: CGFloat = 1
        var path = Path()
        // Built for the leading corner, mirrored for the trailing one.
        func x(_ value: CGFloat) -> CGFloat { leading ? rect.minX + value : rect.maxX - value }
        let top = rect.minY
        path.move(to: CGPoint(x: x(0), y: top))
        path.addLine(to: CGPoint(x: x(flare + overlap), y: top))
        path.addLine(to: CGPoint(x: x(flare + overlap), y: top + flare))
        path.addLine(to: CGPoint(x: x(flare), y: top + flare))
        path.addCurve(to: CGPoint(x: x(0), y: top),
                      control1: CGPoint(x: x(flare), y: top + flare * (1 - k)),
                      control2: CGPoint(x: x(flare * k), y: top))
        path.closeSubpath()
        return path
    }
}
