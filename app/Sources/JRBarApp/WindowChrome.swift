import SwiftUI

// The pieces every titled window draws the same way: its cards, its
// empty states, the one-line notices under the toolbar, the search
// field, the capsule that says what just happened, and section titles.
// History, the Usage Center, Effect Studio, the Creator Micro window and
// the Overview all take them from here, so the windows read as one app.

/// Corner radii the windows share: cards, the wells inside them, and
/// the controls on them.
enum WindowMetrics {
    static let cardRadius: CGFloat = 16
    static let wellRadius: CGFloat = 10
    static let controlRadius: CGFloat = 8
    /// The inset every window's content keeps from its edges.
    static let margin: CGFloat = 20
}

/// A window's card: a raised plate on the window's background, white
/// with a soft shadow in light, a faint lift in dark, and a hairline
/// edge either way.
struct WindowCard: ViewModifier {
    var padding: CGFloat = 18
    /// A brief wash of `tint` over the whole card (a reset, a drill-in).
    var highlight: Color? = nil
    @Environment(\.colorScheme) private var scheme

    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: WindowMetrics.cardRadius, style: .continuous)
        content
            .padding(padding)
            .background {
                shape
                    .fill(scheme == .dark ? Color.white.opacity(0.045) : Color.white)
                    .shadow(color: .black.opacity(scheme == .dark ? 0 : 0.05), radius: 1.5, y: 1)
            }
            .background {
                shape.fill((highlight ?? .clear).opacity(highlight == nil ? 0 : 0.10))
            }
            .overlay {
                shape.strokeBorder(highlight.map { $0.opacity(0.65) } ?? Color.primary.opacity(scheme == .dark ? 0.09 : 0.07),
                                   lineWidth: highlight == nil ? 0.5 : 1.5)
            }
    }
}

/// A recessed well inside a card or a pane: parameter lists, hints, a
/// code line.
struct WindowWell: ViewModifier {
    var padding: CGFloat = 12
    var tint: Color? = nil

    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: WindowMetrics.wellRadius, style: .continuous)
        content
            .padding(padding)
            .background(shape.fill(tint.map { $0.opacity(0.08) } ?? Color.primary.opacity(0.035)))
            .overlay(shape.strokeBorder(tint.map { $0.opacity(0.18) } ?? Color.primary.opacity(0.06), lineWidth: 0.5))
    }
}

extension View {
    func windowCard(padding: CGFloat = 18, highlight: Color? = nil) -> some View {
        modifier(WindowCard(padding: padding, highlight: highlight))
    }

    func windowWell(padding: CGFloat = 12, tint: Color? = nil) -> some View {
        modifier(WindowWell(padding: padding, tint: tint))
    }
}

/// A section's title inside a window: 13 pt semibold, with an optional
/// quiet count or caption on the right.
struct WindowSectionTitle<Trailing: View>: View {
    let title: String
    var symbol: String? = nil
    @ViewBuilder var trailing: () -> Trailing

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            if let symbol {
                Image(systemName: symbol)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.secondary)
            }
            Text(title)
                .font(.system(size: 13, weight: .semibold))
                .accessibilityAddTraits(.isHeader)
            Spacer(minLength: 8)
            trailing()
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .monospacedDigit()
        }
    }
}

extension WindowSectionTitle where Trailing == EmptyView {
    init(_ title: String, symbol: String? = nil) {
        self.init(title: title, symbol: symbol) { EmptyView() }
    }
}

/// Nothing to show, drawn rather than said: the symbol in a soft halo of
/// its tint, a headline, one line of why, and at most one way forward.
struct WindowEmptyState: View {
    let symbol: String
    let title: String
    let text: String
    /// Grey for "nothing yet"; amber when something is wrong (the monitor
    /// is away), green for good news.
    var tint: Color = .secondary
    var actionTitle: String? = nil
    var action: (() -> Void)? = nil

    var body: some View {
        VStack(spacing: 14) {
            ZStack {
                Circle()
                    .fill(RadialGradient(colors: [tint.opacity(0.20), tint.opacity(0.05)],
                                         center: .center, startRadius: 4, endRadius: 36))
                Circle()
                    .strokeBorder(tint.opacity(0.18), lineWidth: 0.5)
                Image(systemName: symbol)
                    .font(.system(size: 24, weight: .regular))
                    .symbolRenderingMode(.hierarchical)
                    .foregroundStyle(tint)
            }
            .frame(width: 64, height: 64)
            .accessibilityHidden(true)
            VStack(spacing: 5) {
                Text(title)
                    .font(.system(size: 15, weight: .semibold))
                    .multilineTextAlignment(.center)
                Text(text)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 340)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let actionTitle, let action {
                Button(actionTitle, action: action)
                    .controlSize(.regular)
                    .padding(.top, 2)
            }
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        // A button of its own must stay a button to VoiceOver.
        .accessibilityElement(children: actionTitle == nil ? .combine : .contain)
    }
}

/// One line under a window's toolbar that says something about what is
/// below it — a failed refresh, an outcome, a filter in force — with the
/// way to act on it at the right.
struct WindowNoticeRow<Trailing: View>: View {
    let symbol: String
    var tint: Color = .secondary
    let text: String
    @ViewBuilder var trailing: () -> Trailing

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: symbol)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(tint)
                .frame(width: 16)
            Text(text)
                .font(.system(size: 11.5))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.tail)
            Spacer(minLength: 8)
            trailing()
                .font(.system(size: 11.5))
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(RoundedRectangle(cornerRadius: WindowMetrics.controlRadius, style: .continuous)
            .fill(tint == .secondary ? Color.primary.opacity(0.04) : tint.opacity(0.08)))
        .accessibilityElement(children: .combine)
    }
}

extension WindowNoticeRow where Trailing == EmptyView {
    init(symbol: String, tint: Color = .secondary, text: String) {
        self.init(symbol: symbol, tint: tint, text: text) { EmptyView() }
    }
}

/// The capsule at a window's foot that says what just happened, or what
/// went wrong, for a few seconds.
struct WindowStatusCapsule: View {
    let text: String
    var isError = false

    var body: some View {
        HStack(spacing: 7) {
            Image(systemName: isError ? "exclamationmark.triangle.fill" : "checkmark.circle.fill")
                .foregroundStyle(isError ? Color.orange : Color.green)
            Text(text)
                .foregroundStyle(.primary)
                .lineLimit(2)
        }
        .font(.system(size: 12, weight: .medium))
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(.regularMaterial, in: Capsule())
        .overlay(Capsule().strokeBorder(Color.primary.opacity(0.10), lineWidth: 0.5))
        .shadow(color: .black.opacity(0.12), radius: 10, y: 3)
        .padding(.bottom, 16)
        .padding(.horizontal, 24)
        .transition(.opacity.combined(with: .offset(y: 6)))
    }
}

/// A window's search field: the glass in the magnifier, the text, and a
/// clear button once there is something to clear.
struct WindowSearchField<Accessory: View>: View {
    let prompt: String
    @Binding var text: String
    @ViewBuilder var accessory: () -> Accessory

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.tertiary)
            TextField(prompt, text: $text)
                .textFieldStyle(.plain)
                .font(.system(size: 12.5))
            if !text.isEmpty {
                Button { text = "" } label: {
                    Image(systemName: "xmark.circle.fill").foregroundStyle(.tertiary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Clear search")
            }
            accessory()
        }
        .padding(.horizontal, 9)
        .frame(height: 28)
        .background(RoundedRectangle(cornerRadius: WindowMetrics.controlRadius, style: .continuous)
            .fill(Color.primary.opacity(0.055)))
        .overlay(RoundedRectangle(cornerRadius: WindowMetrics.controlRadius, style: .continuous)
            .strokeBorder(Color.primary.opacity(0.06), lineWidth: 0.5))
    }
}

extension WindowSearchField where Accessory == EmptyView {
    init(prompt: String, text: Binding<String>) {
        self.init(prompt: prompt, text: text) { EmptyView() }
    }
}

// MARK: - Lines

/// A smooth line through chart points without the overshoot a plain
/// curve has: a monotone cubic (Fritsch–Carlson), so a quiet day stays
/// on the floor and a peak is never drawn taller than it was.
enum SmoothLine {
    /// `points` in ascending x.
    static func path(through points: [CGPoint]) -> Path {
        var path = Path()
        guard let first = points.first else { return path }
        path.move(to: first)
        let count = points.count
        guard count > 1 else { return path }
        var slopes = [CGFloat](repeating: 0, count: count - 1)
        for index in 0..<(count - 1) {
            let dx = points[index + 1].x - points[index].x
            slopes[index] = dx == 0 ? 0 : (points[index + 1].y - points[index].y) / dx
        }
        var tangents = [CGFloat](repeating: 0, count: count)
        tangents[0] = slopes[0]
        tangents[count - 1] = slopes[count - 2]
        for index in 1..<(count - 1) {
            let left = slopes[index - 1], right = slopes[index]
            tangents[index] = left * right <= 0 ? 0 : (left + right) / 2
        }
        for index in 0..<(count - 1) {
            let slope = slopes[index]
            guard slope != 0 else {
                tangents[index] = 0
                tangents[index + 1] = 0
                continue
            }
            let a = tangents[index] / slope, b = tangents[index + 1] / slope
            let length = a * a + b * b
            if length > 9 {
                let scale = 3 / length.squareRoot()
                tangents[index] = scale * a * slope
                tangents[index + 1] = scale * b * slope
            }
        }
        for index in 0..<(count - 1) {
            let start = points[index], end = points[index + 1]
            let third = (end.x - start.x) / 3
            path.addCurve(to: end,
                          control1: CGPoint(x: start.x + third, y: start.y + tangents[index] * third),
                          control2: CGPoint(x: end.x - third, y: end.y - tangents[index + 1] * third))
        }
        return path
    }
}

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
