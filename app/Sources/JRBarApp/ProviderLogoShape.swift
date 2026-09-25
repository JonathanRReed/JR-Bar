import JRBarUI
import SwiftUI

/// A provider's mark as a SwiftUI shape. It has no colour of its own: it
/// takes the foreground style, so the accent, the notch's white and a
/// state tint all work unchanged.
struct ProviderLogoShape: Shape {
    let logo: ProviderLogo

    func path(in rect: CGRect) -> Path { Path(logo.path(in: rect)) }
}

/// The mark in a `size`-point square, with the hairline a small Claude or
/// Grok mark gets so its thin strokes survive the pixel grid.
struct ProviderLogoMark: View {
    let logo: ProviderLogo
    let size: CGFloat

    var body: some View {
        let shape = ProviderLogoShape(logo: logo)
        let weight = ProviderLogo.hairline(for: logo.id, side: size)
        Group {
            if weight > 0 {
                shape.fill().overlay(shape.stroke(style: StrokeStyle(lineWidth: weight, lineJoin: .round)))
            } else {
                shape.fill()
            }
        }
        .frame(width: size, height: size)
    }
}
