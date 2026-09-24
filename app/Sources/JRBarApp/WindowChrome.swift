import SwiftUI

// MARK: - Render proofs

private struct RenderSnapshotKey: EnvironmentKey {
    static let defaultValue = false
}

extension EnvironmentValues {
    /// A still picture of the view is being taken (the render proofs):
    /// `ImageRenderer` draws no scroll view's contents, so the lists
    /// below lay their rows out flat instead.
    var renderSnapshot: Bool {
        get { self[RenderSnapshotKey.self] }
        set { self[RenderSnapshotKey.self] = newValue }
    }
}

/// A scroll view that lays its content out flat, cut off where its
/// viewport ends, while a render proof takes a still. Everywhere else it
/// is the plain `ScrollView`.
struct SnapshotScrollView<Content: View>: View {
    var axes: Axis.Set = .vertical
    var showsIndicators = true
    @ViewBuilder let content: () -> Content
    @Environment(\.renderSnapshot) private var snapshot

    var body: some View {
        if snapshot {
            SnapshotViewport(axes: axes) { content() }
                .clipped()
        } else {
            ScrollView(axes, showsIndicators: showsIndicators) { content() }
        }
    }
}

/// A scroll view's geometry without the scrolling: the content is offered
/// all the room it wants along the scrolling axes and hangs from the
/// top-leading corner, and the viewport takes the room it is offered
/// along them — the same sizes a `ScrollView` reports.
private struct SnapshotViewport: Layout {
    let axes: Axis.Set

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        guard let content = subviews.first else { return .zero }
        let natural = content.sizeThatFits(offer(proposal))
        return CGSize(width: axes.contains(.horizontal) ? (proposal.width ?? natural.width) : natural.width,
                      height: axes.contains(.vertical) ? (proposal.height ?? natural.height) : natural.height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        subviews.first?.place(at: bounds.origin, anchor: .topLeading, proposal: offer(proposal))
    }

    private func offer(_ proposal: ProposedViewSize) -> ProposedViewSize {
        ProposedViewSize(width: axes.contains(.horizontal) ? nil : proposal.width,
                         height: axes.contains(.vertical) ? nil : proposal.height)
    }
}
