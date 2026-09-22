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
    /// The notice's entrance state — driven so the slide-down-fade-in
    /// runs at `noticeFadeIn` and the dismissal reverses at
    /// `noticeFadeOut`, two durations a single transition can't carry.
    @ViewState private var noticeShown = false
    /// The departing notice's ghost: while it fades the face behind is
    /// still "notice", so the out-fade plays over the black housing
    /// instead of letting the idle dots read through.
    @ViewState private var lastNotice: AlcoveNotice?

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
            if let notice = toy.activeCapsule ?? lastNotice {
                noticeCapsule(notice)
                    .opacity(noticeShown ? 1 : 0)
                    .offset(y: reduceMotion || noticeShown
                            ? 0 : -NotchMotion.noticeSlide)
                    .allowsHitTesting(toy.activeCapsule != nil)
            } else if toy.islandExpanded {
                // The card, grown out of the notch — the same rows the
                // glass fallback shows, on black under `cardTopPad`.
                ScrollView(.vertical) {
                    NotchCardView(model: toy.cardModel, style: .island,
                                  width: toy.expandedCardWidth)
                }
                    .padding(.top, toy.cardTopPad)
                    .transition(.opacity)
            } else {
                idle(summary: summary)
                    // A tap on the resting island grows the card — the
                    // face carries it, so a tap on a dot is a tap too.
                    .contentShape(Rectangle())
                    .onTapGesture { toy.islandTapped() }
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel("Notch island")
                    .accessibilityValue(summary.statusLine + sensorSpokenSuffix)
                    .accessibilityHint("Opens the notch card")
                    .accessibilityAddTraits(.isButton)
                    .accessibilityAction { toy.islandTapped() }
                    .transition(.opacity)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .clipShape(silhouette)
        .onHover { toy.setHovered($0) }
        // Every face decision funnels through `NotchMotion.faceTransition`
        // — the morph spring normally, the quiet crossfade under
        // Reduce Motion — so the accessibility path is one pinned fact.
        .animation(NotchMotion.faceTransition(reduceMotion: reduceMotion) == .crossfade
                   ? .easeInOut(duration: NotchMotion.reduceMotionFade)
                   : .spring(response: 0.32, dampingFraction: 0.82),
                   value: face)
        .onChange(of: toy.activeCapsule != nil) { _, showing in
            if showing {
                lastNotice = toy.activeCapsule
                withAnimation(reduceMotion
                              ? .easeInOut(duration: NotchMotion.reduceMotionFade)
                              : .easeOut(duration: NotchMotion.noticeFadeIn)) {
                    noticeShown = true
                }
            } else {
                // The dismissal reverses the entrance, a touch quicker.
                withAnimation(reduceMotion
                              ? .easeInOut(duration: NotchMotion.reduceMotionFade)
                              : .easeIn(duration: NotchMotion.noticeFadeOut)) {
                    noticeShown = false
                }
                DispatchQueue.main.asyncAfter(
                    deadline: .now() + NotchMotion.noticeFadeOut + 0.05
                ) {
                    if toy.activeCapsule == nil { lastNotice = nil }
                }
            }
        }
    }

    /// Plain black — the black the notch's bezel already reads as — so
    /// the island and the hardware merge into one shape (the glass rule:
    /// only a surface floating free of the notch gets Liquid Glass, and
    /// this one is flush with it). Flush top corners while notched (the
    /// screen's edge is the island's top), and the bottom corners take
    /// the notch profile's own radius so island and bar tray match.
    /// Notch-less: a floating pill.
    private var silhouette: NotchSilhouette {
        NotchSilhouette(notchDepth: toy.notchDepth, restingRadius: toy.notchCornerRadius)
    }

    private var islandBackground: some View {
        silhouette.fill(.black)
            .onTapGesture { toy.islandTapped() }
            .accessibilityHidden(true)
    }

    // MARK: Idle

    /// The resting face. Notched: the shoulders carry everything and the
    /// slot stays the notch — a dot centred under the hardware is a dot
    /// nobody sees. Left is the agent HUD (a dot per working provider
    /// in its colour, then the live count); right is attention (open
    /// asks in amber, failures in red) or the Now Playing strip. While
    /// the Screen Bar draws its ears over the same shoulders the face is
    /// a bare housing. Notch-less: the old centred row in a pill. The
    /// breath is the same slow cosine the status chip uses, paused
    /// outright when nothing works, under Reduce Motion, while the
    /// island is ordered out, or while the face is bare.
    private func idle(summary: NotchIslandSummary) -> some View {
        let layout = toy.idleLayout
        let notched = toy.notchDepth > 0
        let live = summary.working > 0 && toy.islandVisible && !reduceMotion
            && !(notched && layout.bare)
        return TimelineView(.animation(minimumInterval: 1.0 / 15.0, paused: !live)) { context in
            let breath = live
                ? (1 - cos(context.date.timeIntervalSinceReferenceDate * .pi * 2 / 2.6)) / 2
                : 0
            Group {
                if notched {
                    shoulders(summary: summary, layout: layout)
                } else {
                    centredRow(summary: summary)
                }
            }
            .opacity(0.85 + 0.15 * breath)
            // The hover wink's other half — the frame grows a few
            // points (the toy's `islandHoverPeek` reframe), and the
            // marks swell inside it. A passing cursor earns only this.
            .scaleEffect(toy.islandHoverPeek ? NotchMotion.hoverContentScale : 1)
            .animation(reduceMotion ? .easeInOut(duration: 0.12)
                                    : .spring(response: 0.22, dampingFraction: 0.75),
                       value: toy.islandHoverPeek)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
        }
    }

    /// The notched layout: the window's shoulder each side of the slot
    /// (the wider side's width, so the window stays centred on the
    /// notch), each side's content hugging the notch inside it.
    private func shoulders(summary: NotchIslandSummary, layout: NotchIdleLayout) -> some View {
        HStack(spacing: 0) {
            Group {
                if !layout.bare, layout.leftWidth > 0 {
                    agentRow(summary: summary)
                        .padding(.trailing, NotchIslandLayout.shoulderPad)
                } else {
                    Color.clear
                }
            }
            .frame(width: layout.windowShoulder, alignment: .trailing)
            Spacer(minLength: 0)
            Group {
                if !layout.bare {
                    HStack(spacing: 0) {
                        // The privacy dots lead, hugging the notch —
                        // the hardware LED's own spot.
                        if layout.sensors.anyInUse {
                            sensorDots(layout.sensors)
                                .padding(.trailing, layout.right == .nothing
                                         ? 0 : NotchIsland.sensorSeparatorWidth)
                        }
                        switch layout.right {
                        case .attention(let count):
                            markCount(count, color: .orange)
                        case .failed(let count):
                            markCount(count, color: .red)
                        case .media:
                            if let media = toy.islandMedia, toy.settings.mediaEnabled {
                                mediaStrip(media)
                            } else {
                                Color.clear
                            }
                        case .nothing:
                            Color.clear
                        }
                    }
                    .padding(.leading, NotchIslandLayout.shoulderPad)
                } else {
                    Color.clear
                }
            }
            .frame(width: layout.windowShoulder, alignment: .leading)
        }
    }

    /// A dot per working provider in its colour, then the working count.
    private func agentRow(summary: NotchIslandSummary) -> some View {
        HStack(spacing: 4) {
            ForEach(summary.workingProviders.prefix(NotchIsland.dotLimit), id: \.self) { provider in
                Circle()
                    .fill(ProviderStyle.style(for: provider).accent)
                    .frame(width: 5, height: 5)
            }
            Text("\(summary.working)")
                .font(.system(size: 10, weight: .bold, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(.white.opacity(0.92))
        }
        .accessibilityLabel(Text("\(summary.working) working"))
    }

    /// The attention mark: a coloured dot and the count beside it.
    private func markCount(_ count: Int, color: Color) -> some View {
        HStack(spacing: 3) {
            Circle().fill(color).frame(width: 5, height: 5)
            Text("\(count)")
                .font(.system(size: 10, weight: .bold, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(color)
        }
    }

    /// The idle face's spoken tail — the privacy dots named, since the
    /// dots themselves are colour alone.
    private var sensorSpokenSuffix: String {
        guard toy.sensorIndicatorsEnabled else { return "" }
        let sensors = toy.sensorState
        if sensors.cameraInUse, sensors.microphoneInUse {
            return " · camera and microphone in use"
        }
        if sensors.cameraInUse { return " · camera in use" }
        if sensors.microphoneInUse { return " · microphone in use" }
        return ""
    }

    /// The privacy dots — macOS's own convention in the island's own
    /// dot language: green while a camera rolls, orange while a mic is
    /// live. Camera leads, sitting nearest the notch like the hardware
    /// LED it mirrors.
    private func sensorDots(_ sensors: NotchSensorState) -> some View {
        HStack(spacing: 4) {
            if sensors.cameraInUse {
                Circle().fill(.green).frame(width: 5, height: 5)
            }
            if sensors.microphoneInUse {
                Circle().fill(.orange).frame(width: 5, height: 5)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(sensors.cameraInUse && sensors.microphoneInUse
                                 ? "Camera and microphone in use"
                                 : sensors.cameraInUse ? "Camera in use"
                                 : "Microphone in use"))
    }

    /// The notch-less pill's row: the Now Playing strip when media is
    /// up, then a dot per working provider, an orange one for open
    /// asks, a red one for failures, then the live count — or a single
    /// dim dot when nothing is live.
    private func centredRow(summary: NotchIslandSummary) -> some View {
        HStack(spacing: 4) {
            if toy.sensorIndicatorsEnabled, toy.sensorState.anyInUse {
                sensorDots(toy.sensorState)
            }
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
    /// still, and an ordered-out island's timeline never runs. A live
    /// audio tap swaps them for the real band levels — the tap's gate
    /// only ever runs it with the card grown, so the strip falls back
    /// to the decorative dance whenever the pipeline is down.
    private func visualizer(playing: Bool) -> some View {
        let utility = toy.cardModel.utility
        let live = playing && toy.islandVisible && !reduceMotion
        return Group {
            if utility.audioTapLive {
                HStack(alignment: .bottom, spacing: 1.5) {
                    ForEach(utility.audioLevels.indices, id: \.self) { index in
                        let level = CGFloat(min(1, max(0, utility.audioLevels[index])))
                        RoundedRectangle(cornerRadius: 1, style: .continuous)
                            .fill(.white.opacity(0.75))
                            .frame(width: 2.5, height: 3 + 6 * level)
                    }
                }
                .frame(height: 10, alignment: .bottom)
            } else {
                TimelineView(.animation(minimumInterval: 1.0 / 12.0, paused: !live)) { context in
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
        }
    }

    // MARK: Notice capsule

    /// The event capsule — Alcove's instant notification, one line:
    /// the kind's glyph in its colour (the provider's accent for a
    /// quota reset) and "Claude · rename-the-fish needs you" — title
    /// and subtitle joined into a single truncating line, centred in the
    /// lip under the notch inside the notice frame the toy sized.
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
        // The line lives in the lip below the notch, centred in it: the
        // bar's tray ends at the bezel above and its strip seats at the
        // lip's bottom edge, so neither crosses the line.
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
        .padding(.top, toy.notchDepth)
        // A tap on the capsule puts it away — it never re-opens it.
        .contentShape(Rectangle())
        .onTapGesture { toy.islandTapped() }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Notch notification")
        .accessibilityValue("\(notice.title). \(notice.subtitle)")
        .accessibilityHint("Dismisses the notification")
        .accessibilityAddTraits(.isButton)
        .accessibilityAction { toy.islandTapped() }
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
