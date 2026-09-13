import AppKit
import JRBarCore
import SwiftUI

/// The island's face — three of them on one window. At rest a black
/// capsule hugging the notch: the `lip` strip under the hardware carries
/// the working providers' dots and the live count, breathing slowly
/// while anything works, and the Now Playing strip when media is up.
/// Hover (`expandOnHover`) grows the same shape into the session card:
/// live rows in the panel's precedence, then the providers' headline
/// usage meters when `showUsage` is on and the daemon sent windows. A
/// daemon event that matters morphs it into the notice capsule — icon,
/// title, subtitle — for a couple of seconds. The window is exactly this
/// shape — the toy resizes it from `AlcoveIslandLayout` — so nothing
/// invisible swallows a menu-bar click.
struct AlcoveIslandView: View {
    let toy: AlcoveToy
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// Which face is up — a notice outranks the card, the card outranks
    /// idle. The animation value, so each morph gets the spring (or,
    /// under Reduce Motion, the quiet crossfade the opacity transitions
    /// on the faces provide).
    private var face: Int {
        if toy.activeCapsule != nil { return 2 }
        return toy.islandExpanded ? 1 : 0
    }

    var body: some View {
        let summary = toy.islandSummary
        ZStack(alignment: .top) {
            islandBackground
            if let notice = toy.activeCapsule {
                noticeCapsule(notice)
                    .transition(.opacity)
            } else if toy.islandExpanded {
                expanded(summary: summary, meters: toy.islandMeters)
                    .transition(.opacity)
            } else {
                idle(summary: summary)
                    .transition(.opacity)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onHover { toy.setHovered($0) }
        .animation(reduceMotion ? .easeInOut(duration: 0.15)
                              : .spring(response: 0.32, dampingFraction: 0.82),
                   value: face)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Alcove island")
        .accessibilityValue(summary.statusLine)
    }

    /// Plain black — the black the notch's bezel already reads as — so
    /// the island and the hardware merge into one shape. Flush top
    /// corners while notched (the screen's edge is the island's top);
    /// fully rounded as a floating pill or card where there is no notch.
    @ViewBuilder private var islandBackground: some View {
        if toy.notchDepth > 0 {
            UnevenRoundedRectangle(bottomLeadingRadius: 16, bottomTrailingRadius: 16,
                                   style: .continuous)
                .fill(.black)
        } else if toy.islandExpanded || toy.activeCapsule != nil {
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(.black)
        } else {
            Capsule(style: .continuous)
                .fill(.black)
        }
    }

    // MARK: Idle

    /// The lip row: the Now Playing strip when media is up, then a dot
    /// per working provider in its colour, an orange one for open asks,
    /// a red one for failures, then the live count. Idle it is a single
    /// dim dot — the island is present, not busy. The breath is the same
    /// slow cosine the status chip uses, paused outright when nothing
    /// works, under Reduce Motion, or while the island is ordered out.
    private func idle(summary: AlcoveIslandSummary) -> some View {
        let live = summary.working > 0 && toy.islandVisible && !reduceMotion
        return TimelineView(.animation(minimumInterval: 1.0 / 15.0, paused: !live)) { context in
            let breath = live
                ? (1 - cos(context.date.timeIntervalSinceReferenceDate * .pi * 2 / 2.6)) / 2
                : 0
            HStack(spacing: 4) {
                if let media = toy.islandMedia, toy.settings.mediaEnabled {
                    mediaStrip(media)
                }
                ForEach(summary.workingProviders.prefix(AlcoveIsland.dotLimit), id: \.self) { provider in
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
            .frame(maxWidth: .infinity, maxHeight: .infinity,
                   alignment: toy.notchDepth > 0 ? .bottom : .center)
            .padding(.bottom, toy.notchDepth > 0 ? 4 : 0)
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

    /// The event capsule — Alcove's instant notification: the kind's
    /// glyph in its colour (the provider's accent for a quota reset),
    /// the "Claude · rename-the-fish" title and the "needs you" line
    /// under it. Content sits low, centred under the notch like the
    /// idle strip, inside the notice frame the toy sized.
    private func noticeCapsule(_ notice: AlcoveNotice) -> some View {
        HStack(spacing: 10) {
            Image(systemName: notice.kind.symbol)
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(noticeTint(notice))
            VStack(alignment: .leading, spacing: 1) {
                Text(notice.title)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.white)
                    .lineLimit(1)
                    .truncationMode(.tail)
                Text(notice.subtitle)
                    .font(.system(size: 10))
                    .foregroundStyle(.white.opacity(0.6))
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
        }
        .padding(.horizontal, 16)
        .frame(maxWidth: .infinity, maxHeight: .infinity,
               alignment: toy.notchDepth > 0 ? .bottom : .center)
        .padding(.bottom, toy.notchDepth > 0 ? 9 : 0)
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

    // MARK: Expanded

    /// The card: the status line, the live rows (waiting outranks
    /// failed outranks working — the panel's precedence), then the
    /// meters. Fixed row heights keep the view honest with
    /// `AlcoveIslandLayout.expandedHeight`, which sized the window.
    private func expanded(summary: AlcoveIslandSummary, meters: [AlcoveIslandMeter]) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            // The notch clearance, as a row: `expandedHeight` counts it.
            Color.clear.frame(height: toy.islandTopInset)
            Text(summary.statusLine)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.white)
                .frame(height: 20, alignment: .leading)
            if let media = toy.islandMedia, toy.settings.mediaEnabled {
                mediaCardRow(media)
                Divider()
                    .overlay(.white.opacity(0.15))
                    .frame(height: 10)
            }
            ForEach(summary.rows.prefix(AlcoveIsland.rowLimit)) { row in
                rowView(row)
            }
            if summary.rows.count > AlcoveIsland.rowLimit {
                Text("+\(summary.rows.count - AlcoveIsland.rowLimit) more")
                    .font(.system(size: 10))
                    .foregroundStyle(.white.opacity(0.5))
                    .frame(height: 18, alignment: .leading)
            }
            if !meters.isEmpty {
                Divider()
                    .overlay(.white.opacity(0.15))
                    .frame(height: 10)
                ForEach(meters) { meter in
                    meterView(meter)
                }
            }
        }
        .padding(.horizontal, 14)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }

    private func rowView(_ row: AlcoveIslandRow) -> some View {
        HStack(spacing: 6) {
            Circle()
                .fill(ProviderStyle.style(for: row.provider).accent)
                .frame(width: 5, height: 5)
            Text(row.label)
                .font(.system(size: 11))
                .foregroundStyle(.white.opacity(0.9))
                .lineLimit(1)
                .truncationMode(.tail)
            Spacer(minLength: 4)
            Text(row.activity.word)
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(row.activity.tint)
        }
        .frame(height: 22)
    }

    /// "Claude · 5h ▓▓▓░░ 62%" — a stated unknown is an em dash and an
    /// empty track, never a full bar.
    private func meterView(_ meter: AlcoveIslandMeter) -> some View {
        HStack(spacing: 6) {
            Text(ProviderStyle.style(for: meter.provider).name)
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(.white.opacity(0.7))
                .lineLimit(1)
            Text(meter.window)
                .font(.system(size: 9))
                .foregroundStyle(.white.opacity(0.4))
            Spacer(minLength: 4)
            Capsule()
                .fill(.white.opacity(0.14))
                .frame(width: 48, height: 4)
                .overlay(alignment: .leading) {
                    if let percent = meter.percent {
                        Capsule()
                            .fill(ProviderStyle.style(for: meter.provider).accent)
                            .frame(width: 48 * min(1, max(0, percent / 100)), height: 4)
                    }
                }
            Text(meter.percentText)
                .font(.system(size: 10))
                .monospacedDigit()
                .foregroundStyle(.white.opacity(0.7))
                .frame(width: 30, alignment: .trailing)
        }
        .frame(height: 18)
    }

    /// The card's Now Playing row — artwork, the track line, then the
    /// transport: previous, play/pause, next, straight through to
    /// MediaRemote. Thirty points tall plus the divider, which is the
    /// forty `expandedHeight` reserves for it.
    private func mediaCardRow(_ media: AlcoveMedia) -> some View {
        HStack(spacing: 8) {
            Group {
                if let data = media.artworkData, let artwork = NSImage(data: data) {
                    Image(nsImage: artwork)
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                } else {
                    Image(systemName: "music.note")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.6))
                }
            }
            .frame(width: 22, height: 22)
            .clipShape(RoundedRectangle(cornerRadius: 5, style: .continuous))
            VStack(alignment: .leading, spacing: 1) {
                Text(media.title)
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.9))
                if let artist = media.artist, !artist.isEmpty {
                    Text(artist)
                        .font(.system(size: 9))
                        .foregroundStyle(.white.opacity(0.5))
                }
            }
            .lineLimit(1)
            .truncationMode(.tail)
            Spacer(minLength: 4)
            mediaButton("backward.fill") { toy.mediaPreviousTrack() }
            mediaButton(media.playing ? "pause.fill" : "play.fill") { toy.mediaTogglePlayPause() }
            mediaButton("forward.fill") { toy.mediaNextTrack() }
        }
        .frame(height: 30)
    }

    private func mediaButton(_ symbol: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.white.opacity(0.8))
                .frame(width: 22, height: 22)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}
