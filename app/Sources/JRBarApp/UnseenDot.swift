import AppKit
import SwiftUI

/// The one "new since you looked" dot: History's rows newer than the
/// last visit, panel and Overview rows finished since you last looked,
/// a Screen Bar peek tile that changed, the archive's live tail. A
/// fixed calm blue, never the accent colour — with a red accent every
/// unseen row read as a failure, and red is failure's word here.
/// Each place keeps its own tooltip.
struct UnseenDot: View {
    /// systemBlue whatever the accent; it still follows light and dark.
    static let fill = NSColor.systemBlue
    static let diameter: CGFloat = 5

    var body: some View {
        Circle()
            .fill(Color(nsColor: Self.fill))
            .frame(width: Self.diameter, height: Self.diameter)
    }
}
