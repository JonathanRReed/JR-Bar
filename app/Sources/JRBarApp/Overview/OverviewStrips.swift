import JRBarCore
import SwiftUI

// The two strips over the Overview's roster: the counts of the rows in
// view, and the connections the roster runs on.

/// "2 live · 1 needs you · 1 failed · 1 unreviewed · 3 hidden" —
/// over the filtered rows, so the strip and the table can never
/// disagree. Each count is a small pill in its state's tint; failed
/// gets its own red: a dead run is not a question and must not read
/// as one anywhere in the window.
struct OverviewSummaryStrip: View {
    @Bindable var store: OverviewStore

    var body: some View {
        let counts = store.stripCounts
        HStack(spacing: 6) {
            OverviewCountPill(text: "\(counts.live) live", tint: counts.live > 0 ? .green : .secondary)
            if counts.attention > 0 {
                OverviewCountPill(text: "\(counts.attention) need\(counts.attention == 1 ? "s" : "") you", tint: .orange)
            }
            if counts.failed > 0 {
                OverviewCountPill(text: "\(counts.failed) failed", tint: .red)
            }
            if counts.unreviewed > 0 {
                OverviewCountPill(text: "\(counts.unreviewed) unreviewed", tint: .secondary)
            }
            if counts.hidden > 0 {
                OverviewCountPill(text: "\(counts.hidden) hidden", tint: .secondary, quiet: true)
            }
            if let whole = store.wholeRosterPhrase {
                // The counts above are this view's; this is everyone's.
                Text(whole).foregroundStyle(.tertiary).lineLimit(1)
            }
            Spacer()
            if store.loading {
                DelayedWait(size: 12)
            } else if let loadedAt = store.loadedAt {
                Text("Updated \(loadedAt, style: .time)").foregroundStyle(.tertiary).font(.system(size: 10.5))
            }
        }
        .padding(.horizontal, 12).padding(.top, 8).padding(.bottom, 6)
        .font(.system(size: 11))
        .accessibilityElement(children: .combine)
    }
}

/// The wiring row: core link, this Mac, each peer, each device,
/// each provider — the live connections the roster runs on, visible
/// even when no session is. A chip focuses the same link's facts in
/// the inspector. The row scrolls sideways, and its edges fade so a
/// chip cut by the pane reads as "more", not as a clipped view.
struct OverviewConnectionsStrip: View {
    @Bindable var store: OverviewStore

    var body: some View {
        SnapshotScrollView(axes: .horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                ForEach(store.links) { link in
                    connectionChip(link)
                }
            }
            .padding(.horizontal, 12)
        }
        .mask {
            HStack(spacing: 0) {
                LinearGradient(colors: [.clear, .black], startPoint: .leading, endPoint: .trailing)
                    .frame(width: 12)
                Color.black
                LinearGradient(colors: [.black, .clear], startPoint: .leading, endPoint: .trailing)
                    .frame(width: 12)
            }
        }
        .fixedSize(horizontal: false, vertical: true)
        .padding(.bottom, 5)
    }

    private func connectionChip(_ link: OverviewLink) -> some View {
        let selected = store.selectedLinkID == link.id
        return Button {
            store.selectLink(selected ? nil : link.id)
        } label: {
            HStack(spacing: 5) {
                Circle()
                    .fill(link.tone.color)
                    .frame(width: 5, height: 5)
                OverviewLinkGlyph(link: link, size: 12)
                Text(link.title)
                    .font(.system(size: 11, weight: .medium))
                    .lineLimit(1)
                if let subtitle = link.subtitle {
                    Text(subtitle)
                        .font(.system(size: 10))
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                }
            }
            .padding(.horizontal, 8).padding(.vertical, 3.5)
            .background(Capsule().fill(.primary.opacity(selected ? 0.14 : 0.06)))
            .overlay(Capsule().strokeBorder(
                selected ? Color.accentColor.opacity(0.6) : .primary.opacity(0.08),
                lineWidth: 0.5))
        }
        .buttonStyle(.plain)
        .help(link.helpText)
        .accessibilityLabel(OverviewView.chipLabel(link))
    }
}

/// A count in the Overview's summary strip: the number and its word in a
/// capsule of its tint, a dot leading.
struct OverviewCountPill: View {
    let text: String
    let tint: Color
    var quiet = false

    /// Grey counts read in the primary ink, dimmer when quiet.
    private var ink: Color {
        guard tint == .secondary else { return tint }
        return Color.primary.opacity(quiet ? 0.55 : 0.75)
    }

    var body: some View {
        HStack(spacing: 4) {
            Circle().fill(tint).frame(width: 5, height: 5).opacity(quiet ? 0.6 : 1)
            Text(text)
                .font(.system(size: 11, weight: .medium))
                .monospacedDigit()
                .foregroundStyle(ink)
        }
        .padding(.horizontal, 7)
        .padding(.vertical, 2.5)
        .background(Capsule().fill(tint.opacity(tint == .secondary ? 0.08 : 0.12)))
    }
}
