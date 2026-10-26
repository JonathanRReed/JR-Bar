import SwiftUI

/// Percent values and pace use 0...100. A missing value draws no track.
public struct JRBarGauge: View {
    @Environment(\.jrbarInk) private var neutralInk
    public let value: Double?
    public var tint: Color
    public var stale: Bool
    public var height: CGFloat
    public var pace: Double?

    public init(value: Double?, tint: Color = JRBarTokens.Ink.accent, stale: Bool = false,
                height: CGFloat = 4, pace: Double? = nil) {
        self.value = value
        self.tint = tint
        self.stale = stale
        self.height = height
        self.pace = pace
    }

    public var body: some View {
        if let value, value.isFinite {
            GeometryReader { geometry in
                let fraction = min(100, max(0, value)) / 100
                ZStack(alignment: .leading) {
                    JRBarTokens.Radius.pill.fill(neutralInk.tertiaryFill).frame(height: height)
                    JRBarTokens.Radius.pill.fill(stale ? neutralInk.tertiary : tint)
                        .frame(width: geometry.size.width * fraction, height: height)
                    if let pace, pace.isFinite {
                        let clampedPace = min(100, max(0, pace)) / 100
                        let position = geometry.size.width * clampedPace - 0.75
                        let tickX = min(geometry.size.width - 1.5, max(0, position))
                        Rectangle().fill(neutralInk.secondary)
                            .frame(width: 1.5, height: height + 4)
                            .offset(x: tickX)
                    }
                }
                .frame(width: geometry.size.width, height: height)
            }
            .frame(height: height)
            .accessibilityHidden(true)
        }
    }
}
