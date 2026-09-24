import SwiftUI

/// The decorative playing tell every media surface shares — the island's
/// strip, the Screen Bar's media ear and the card's media row: rounded
/// bars breathing out from their middle like a waveform, each on its
/// own phase at 12 fps, set dressing and not a
/// spectrum (a live audio tap draws the real levels instead, six bands,
/// so six bars here too and nothing jumps when it takes over). Not
/// `live` — paused, out of sight — or under Reduce Motion they stand
/// still in one frozen frame and the timeline stops ticking.
struct DecorativeBars: View {
    var count = DecorativeBars.defaultCount
    let live: Bool
    let color: Color
    var barWidth: CGFloat = 2.2
    var spacing: CGFloat = 1.5
    var height: CGFloat = 10
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// The live tap's band count.
    static let defaultCount = 6
    static let frameInterval: TimeInterval = 1.0 / 12.0

    var body: some View {
        let moving = live && !reduceMotion
        TimelineView(.animation(minimumInterval: Self.frameInterval, paused: !moving)) { context in
            let t = moving ? context.date.timeIntervalSinceReferenceDate : 0
            HStack(alignment: .center, spacing: spacing) {
                ForEach(0..<count, id: \.self) { index in
                    Capsule(style: .continuous)
                        .fill(color)
                        .frame(width: barWidth, height: Self.barHeight(index: index, at: t, height: height))
                }
            }
            .frame(height: height, alignment: .center)
        }
        .accessibilityHidden(true)
    }

    /// One bar at `t`: a floor of three tenths of the row, the rest a
    /// bounce on the bar's own phase — the strip's old `|sin(3.2t + 1.9i)|`.
    /// At `t == 0` it is the still frame.
    nonisolated static func barHeight(index: Int, at t: TimeInterval, height: CGFloat) -> CGFloat {
        let floor = height * 0.3
        return floor + (height - floor) * CGFloat(abs(sin(t * 3.2 + Double(index) * 1.9)))
    }
}
