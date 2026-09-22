import JRBarCore
import SwiftUI

struct NotchSilhouette: Shape {
    var notchDepth: CGFloat
    var restingRadius: CGFloat

    func path(in rect: CGRect) -> Path {
        let radius = NotchSilhouetteGeometry.radius(
            size: rect.size, notchDepth: notchDepth, restingRadius: restingRadius)
        let top: CGFloat = notchDepth > 0 ? 0 : radius
        return UnevenRoundedRectangle(
            topLeadingRadius: top, bottomLeadingRadius: radius,
            bottomTrailingRadius: radius, topTrailingRadius: top,
            style: .continuous).path(in: rect)
    }
}
