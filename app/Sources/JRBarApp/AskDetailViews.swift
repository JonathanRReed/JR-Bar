import JRBarCore
import Observation
import SwiftUI

/// Which asks the person has chosen to expand. Never on its own: an ask
/// opens only from a click or a key on its chevron, and the choice is
/// shared by every surface that draws the ask, so opening it in the panel
/// does not leave the notch card saying less.
///
/// Expanding is reading. Nothing here sends anything to an agent.
@MainActor
@Observable
final class AskExpansion {
    static let shared = AskExpansion()

    /// Asks (by `key`) the person has opened.
    private(set) var expanded: Set<String> = []

    /// The most keys kept: an ask that has gone leaves its key behind.
    static let keyLimit = 24

    /// The ask's own episode when the daemon pins one, else its id.
    static func key(_ ask: CoreAsk) -> String { ask.request ?? ask.id }

    /// Open now: the ask has something to show and the person asked for it.
    func isShowing(_ ask: CoreAsk?) -> Bool {
        guard let ask, ask.hasDetail else { return false }
        return expanded.contains(Self.key(ask))
    }

    func toggle(_ ask: CoreAsk) {
        let key = Self.key(ask)
        if expanded.remove(key) == nil {
            if expanded.count >= Self.keyLimit { expanded = [] }
            expanded.insert(key)
        }
    }

    func collapse(_ ask: CoreAsk) { expanded.remove(Self.key(ask)) }
}

/// The colours an expanded body is drawn in: the panel's semantic ones,
/// or the notch's white-on-black.
struct AskDetailPalette {
    var text: Color
    var secondary: Color
    var well: Color
    var edge: Color

    static let panel = AskDetailPalette(text: Color.primary.opacity(0.85), secondary: .secondary,
                                        well: Color.primary.opacity(0.06), edge: Color.primary.opacity(0.07))

    static func notch(_ style: NotchCardStyle) -> AskDetailPalette {
        AskDetailPalette(text: style == .island ? Color.white.opacity(0.85) : Color.primary.opacity(0.85),
                         secondary: style.subColor, well: style.chipFaint, edge: style.hairline)
    }
}

/// The chevron that opens an ask: a button with a spoken label, so it is
/// reachable by keyboard and by VoiceOver. `labelled` writes the noun
/// beside it ("Plan ›") for an ask with no preview line to sit next to.
struct AskDetailToggle: View {
    let ask: CoreAsk
    var labelled = false
    var size: CGFloat = 9
    var tint: Color = .secondary
    var expansion: AskExpansion = .shared
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        if let detail = ask.detail {
            let open = expansion.isShowing(ask)
            let title = AskDetailCopy.toggleTitle(detail, expanded: open)
            Button {
                withAnimation(reduceMotion ? nil : .easeOut(duration: 0.14)) { expansion.toggle(ask) }
            } label: {
                HStack(spacing: 3) {
                    if labelled {
                        Text(AskDetailCopy.noun(detail).capitalizedFirst)
                            .font(.system(size: size + 1.5, weight: .medium))
                    }
                    Image(systemName: "chevron.right")
                        .font(.system(size: size, weight: .bold))
                        .rotationEffect(.degrees(open ? 90 : 0))
                }
                .foregroundStyle(tint)
                .padding(.horizontal, labelled ? 2 : 4)
                .frame(minWidth: 18, minHeight: 16)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(title)
            .accessibilityLabel(title)
            .accessibilityValue(open ? "Expanded" : "Collapsed")
            .accessibilityHint(AskDetailCopy.toggleHint(expanded: open))
        }
    }
}

private extension String {
    var capitalizedFirst: String { prefix(1).uppercased() + dropFirst() }
}

/// The expanded ask: an edit's size and files, the whole command or the
/// plan in a monospaced well that scrolls, and, for a plan, the one way
/// to answer it, which is the session. Fixed in height so the surface
/// that draws it is sized by arithmetic.
struct AskDetailView: View {
    let ask: CoreAsk
    var palette: AskDetailPalette = .panel
    var height: CGFloat
    /// "Answer in the session" for a plan; nil draws no action.
    var onOpenSession: (() -> Void)?

    var body: some View {
        if let detail = ask.detail {
            VStack(alignment: .leading, spacing: 4) {
                if let edit = detail.edit {
                    editBlock(edit)
                }
                if let text = AskDetailCopy.body(detail) {
                    bodyWell(text, detail: detail)
                }
                if let note = AskDetailCopy.footnote(detail) {
                    Text(note)
                        .font(.system(size: 9.5))
                        .foregroundStyle(palette.secondary)
                        .lineLimit(1)
                }
                if detail.plan != nil {
                    planAction
                }
                Spacer(minLength: 0)
            }
            .frame(maxWidth: .infinity, alignment: .topLeading)
            .frame(height: height, alignment: .top)
            .accessibilityElement(children: .contain)
        }
    }

    private func editBlock(_ edit: CoreAskEdit) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(edit.summary)
                .font(.system(size: 11, weight: .semibold, design: .monospaced))
                .foregroundStyle(palette.text)
                .lineLimit(1)
            ForEach(Array(AskDetailCopy.pathLines(edit).enumerated()), id: \.offset) { _, path in
                Text(path)
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(palette.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(AskDetailCopy.bodyLabel(CoreAskDetail(edit: edit)) + ". "
                            + AskDetailCopy.pathLines(edit).joined(separator: ", "))
    }

    private func bodyWell(_ text: String, detail: CoreAskDetail) -> some View {
        SnapshotScrollView {
            Text(text)
                .font(.system(size: 10.5, design: .monospaced))
                .foregroundStyle(palette.text)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .topLeading)
                .padding(6)
        }
        .frame(maxHeight: .infinity)
        .background(
            RoundedRectangle(cornerRadius: 5, style: .continuous)
                .fill(palette.well)
                .overlay(RoundedRectangle(cornerRadius: 5, style: .continuous)
                    .strokeBorder(palette.edge, lineWidth: 0.5))
        )
        .clipShape(RoundedRectangle(cornerRadius: 5, style: .continuous))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(AskDetailCopy.bodyLabel(detail))
    }

    private var planAction: some View {
        HStack(spacing: 8) {
            Text(AskDetailCopy.planNote)
                .font(.system(size: 10))
                .foregroundStyle(palette.secondary)
                .lineLimit(1)
                .layoutPriority(-1)
            Spacer(minLength: 4)
            if let onOpenSession {
                Button(AskDetailCopy.sessionActionTitle, action: onOpenSession)
                    .buttonStyle(PillButtonStyle(prominent: true))
                    .fixedSize()
                    .help(AskDetailCopy.sessionActionHelp)
            }
        }
    }
}
