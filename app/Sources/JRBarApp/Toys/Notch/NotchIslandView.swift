import AppKit
import JRBarCore
import SwiftUI

/// The island's faces — three of them on one window. At rest a black
/// capsule hugging the notch: exactly the hardware's depth, so nothing
/// hangs below it — the working providers' dots and the live count sit
/// centred inside, breathing slowly while anything works, with the Now
/// Playing strip when media is up. A daemon event that matters morphs
/// it into the notice capsule — glyph and one line of copy — for a
/// couple of seconds. A tap, a pull, or a held hover grows it into the
/// card — the same `NotchCardView` the glass fallback wears — still
/// black, still contiguous with the notch, Dynamic-Island style; a
/// passing hover only earns the wink (`islandHoverPeek`), a few points
/// of grow and a swell of the dots. The window is exactly this shape —
/// the toy resizes it from `NotchIslandLayout` — so nothing invisible
/// swallows a menu-bar click.
struct NotchIslandView: View {
    let toy: NotchToy
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// Which face is up — the notice outranks the card, the card
    /// outranks idle. The animation value, so the morph gets the spring
    /// (or, under Reduce Motion, the quiet crossfade the opacity
    /// transitions on the faces provide).
    private var face: Int {
        toy.activeCapsule != nil ? 1 : (toy.islandExpanded ? 2 : 0)
    }

    var body: some View {
        let summary = toy.islandSummary
        ZStack(alignment: .top) {
            islandBackground
            if let notice = toy.activeCapsule {
                noticeCapsule(notice)
                    .transition(.opacity)
            } else if toy.islandExpanded {
                // The card, grown out of the notch — the same rows the
                // glass fallback shows, on black under `cardTopPad`.
                NotchCardView(model: toy.cardModel, style: .island,
                              width: toy.expandedCardWidth)
                    .padding(.top, toy.cardTopPad)
                    .transition(.opacity)
            } else {
                idle(summary: summary)
                    // A tap on the resting island grows the card — the
                    // face carries it, so a tap on a dot is a tap too.
                    .contentShape(Rectangle())
                    .onTapGesture { toy.islandTapped() }
                    .transition(.opacity)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onHover { toy.setHovered($0) }
        .animation(reduceMotion ? .easeInOut(duration: 0.15)
                              : .spring(response: 0.32, dampingFraction: 0.82),
                   value: face)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Notch island")
        .accessibilityValue(summary.statusLine)
        .accessibilityHint("Opens the notch card")
        .accessibilityAddTraits(.isButton)
        .accessibilityAction(named: "Toggle card") { toy.islandTapped() }
    }

    /// Plain black — the black the notch's bezel already reads as — so
    /// the island and the hardware merge into one shape (the glass rule:
    /// only a surface floating free of the notch gets Liquid Glass, and
    /// this one is flush with it). Flush top corners while notched (the
    /// screen's edge is the island's top), and the bottom corners take
    /// the notch profile's own radius so island and bar tray match.
    /// Notch-less: a floating pill.
    @ViewBuilder private var islandBackground: some View {
        let tap = { toy.islandTapped() }
        if toy.notchDepth > 0 {
            UnevenRoundedRectangle(bottomLeadingRadius: toy.notchCornerRadius,
                                   bottomTrailingRadius: toy.notchCornerRadius,
                                   style: .continuous)
                .fill(.black)
                .onTapGesture { tap() }
        } else {
            Capsule(style: .continuous)
                .fill(.black)
                .onTapGesture { tap() }
        }
    }

    // MARK: Idle

    /// The lip row: the Now Playing strip when media is up, then a dot
    /// per working provider in its colour, an orange one for open asks,
    /// a red one for failures, then the live count. Idle it is a single
    /// dim dot — the island is present, not busy. The breath is the same
    /// slow cosine the status chip uses, paused outright when nothing
    /// works, under Reduce Motion, or while the island is ordered out.
    private func idle(summary: NotchIslandSummary) -> some View {
        let live = summary.working > 0 && toy.islandVisible && !reduceMotion
        return TimelineView(.animation(minimumInterval: 1.0 / 15.0, paused: !live)) { context in
            let breath = live
                ? (1 - cos(context.date.timeIntervalSinceReferenceDate * .pi * 2 / 2.6)) / 2
                : 0
            HStack(spacing: 4) {
                if let media = toy.islandMedia, toy.settings.mediaEnabled {
                    mediaStrip(media)
                }
                ForEach(summary.workingProviders.prefix(NotchIsland.dotLimit), id: \.self) { provider in
                    Circle()
                        .fill(ProviderStyle.style(for: provider).accent)
                        .frame(width: 5, height: 5)
                }
                if summary.waiting > 0 {
                    Circle().fill(.orange).frame(width: 5, height: 5)
                }
                if summary.failed > 0 {
                    Circle().fill(.red).frame(width: 5, height: 5)
                }
                if summary.working + summary.waiting + summary.failed > 0 {
                    Text("\(summary.working + summary.waiting + summary.failed)")
                        .font(.system(size: 9, weight: .bold, design: .rounded))
                        .monospacedDigit()
                        .foregroundStyle(.white.opacity(0.85))
                } else {
                    Circle().fill(.white.opacity(0.28)).frame(width: 4, height: 4)
                }
            }
            .opacity(0.75 + 0.25 * breath)
            // The hover wink's other half — the frame grows a few
            // points (the toy's `islandHoverPeek` reframe), and the
            // dots swell inside it. A passing cursor earns only this.
            .scaleEffect(toy.islandHoverPeek ? 1.12 : 1)
            .animation(reduceMotion ? .easeInOut(duration: 0.12)
                                    : .spring(response: 0.22, dampingFraction: 0.75),
                       value: toy.islandHoverPeek)
            // The idle capsule is exactly the notch's depth, so the dots
            // centre inside it — the silhouette is the hardware's own.
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
        }
    }

    /// The idle capsule's Now Playing half: the artwork thumbnail (or a
    /// note glyph when the player sent none), "Title — Artist" truncated
    /// to the strip's fixed width, and the visualizer bars — animated
    /// only while the track is actually playing; paused and Reduce
    /// Motion both get still bars, and the frame never asks the player
    /// for spectrum data it cannot give.
    private func mediaStrip(_ media: AlcoveMedia) -> some View {
        HStack(spacing: 5) {
            Group {
                if let data = media.artworkData, let artwork = NSImage(data: data) {
                    Image(nsImage: artwork)
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                } else {
                    Image(systemName: "music.note")
                        .font(.system(size: 7, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.7))
                }
            }
            .frame(width: 12, height: 12)
            .clipShape(RoundedRectangle(cornerRadius: 3, style: .continuous))
            Text(media.displayLine)
                .font(.system(size: 9, weight: .medium))
                .foregroundStyle(.white.opacity(0.85))
                .lineLimit(1)
                .truncationMode(.tail)
                .frame(maxWidth: 96, alignment: .leading)
            visualizer(playing: media.playing)
        }
        .padding(.trailing, 6)
    }

    /// Three bars bouncing on their own phases while the track plays —
    /// set dressing, not a spectrum; paused or Reduce Motion draws them
    /// still, and an ordered-out island's timeline never runs.
    private func visualizer(playing: Bool) -> some View {
        let live = playing && toy.islandVisible && !reduceMotion
        return TimelineView(.animation(minimumInterval: 1.0 / 12.0, paused: !live)) { context in
            let t = context.date.timeIntervalSinceReferenceDate
            HStack(alignment: .bottom, spacing: 1.5) {
                ForEach(0..<3, id: \.self) { index in
                    let height: CGFloat = live
                        ? 3 + 6 * abs(sin(t * 3.2 + Double(index) * 1.9))
                        : 3 + CGFloat(index) * 1.5
                    RoundedRectangle(cornerRadius: 1, style: .continuous)
                        .fill(.white.opacity(0.75))
                        .frame(width: 2.5, height: height)
                }
            }
            .frame(height: 10, alignment: .bottom)
        }
    }

    // MARK: Notice capsule

    /// The event capsule — Alcove's instant notification, one line:
    /// the kind's glyph in its colour (the provider's accent for a
    /// quota reset) and "Claude · rename-the-fish needs you" — title
    /// and subtitle joined into a single truncating line that sits low,
    /// centred under the notch inside the notice frame the toy sized.
    private func noticeCapsule(_ notice: AlcoveNotice) -> some View {
        HStack(spacing: 7) {
            Image(systemName: notice.kind.symbol)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(noticeTint(notice))
            Text("\(notice.title) · \(notice.subtitle)")
                .font(.system(size: 11.5))
                .foregroundStyle(.white.opacity(0.85))
                .lineLimit(1)
                .truncationMode(.middle)
        }
        .padding(.horizontal, 14)
        // The line lives in the lip below the notch — pushed past the
        // LED band's clearance exactly like the expanded card's top
        // inset, so the bar's strip never crosses it.
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .padding(.top, toy.notchDepth + toy.ledClearance)
        // A tap on the capsule puts it away — it never re-opens it.
        .contentShape(Rectangle())
        .onTapGesture { toy.islandTapped() }
    }

    /// Waiting is amber, finished is green, failed is red — the app's
    /// standing state colours; a quota reset borrows its provider's
    /// accent and power is yellow, the bolt's own colour.
    private func noticeTint(_ notice: AlcoveNotice) -> Color {
        switch notice.kind {
        case .ask: return .orange
        case .completed: return .green
        case .failed: return .red
        case .quotaReset: return ProviderStyle.style(for: notice.provider ?? "").accent
        case .charging: return .yellow
        }
    }
}
