import AppKit
import JRBarCore
import SwiftUI

/// The island's face. At rest a black capsule hugging the notch — the
/// `lip` strip under the hardware carries the working providers' dots
/// and the live count, breathing slowly while anything works. Hover
/// (`expandOnHover`) grows the same shape into the session card: live
/// rows in the panel's precedence, then the providers' headline usage
/// meters when `showUsage` is on and the daemon sent windows. The
/// window is exactly this shape — the toy resizes it from
/// `AlcoveIslandLayout` — so nothing invisible swallows a menu-bar
/// click.
struct AlcoveIslandView: View {
    let toy: AlcoveToy
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let summary = toy.islandSummary
        ZStack(alignment: .top) {
            islandBackground
            if toy.islandExpanded {
                expanded(summary: summary, meters: toy.islandMeters)
            } else {
                idle(summary: summary)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onHover { toy.setHovered($0) }
        .animation(reduceMotion ? nil : .spring(response: 0.32, dampingFraction: 0.82),
                   value: toy.islandExpanded)
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
        } else if toy.islandExpanded {
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(.black)
        } else {
            Capsule(style: .continuous)
                .fill(.black)
        }
    }

    // MARK: Idle

    /// The lip row: a dot per working provider in its colour, an orange
    /// one for open asks, a red one for failures, then the live count.
    /// Idle it is a single dim dot — the island is present, not busy.
    /// The breath is the same slow cosine the status chip uses, paused
    /// outright when nothing works, under Reduce Motion, or while the
    /// island is ordered out.
    private func idle(summary: AlcoveIslandSummary) -> some View {
        let live = summary.working > 0 && toy.islandVisible && !reduceMotion
        return TimelineView(.animation(minimumInterval: 1.0 / 15.0, paused: !live)) { context in
            let breath = live
                ? (1 - cos(context.date.timeIntervalSinceReferenceDate * .pi * 2 / 2.6)) / 2
                : 0
            HStack(spacing: 4) {
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
}
