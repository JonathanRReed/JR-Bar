import AppKit
import JRBarCore
import JRBarUI
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

    /// What the notice face draws: key feedback over a capsule, a
    /// capsule over nothing.
    private var shownNotice: AlcoveNotice? { toy.activeOverlay ?? toy.activeCapsule }

    /// Which face is up — the notice outranks the card, the card
    /// outranks idle; the ask and its takeover are faces of their own.
    /// The animation value, so the morph gets the spring (or, under
    /// Reduce Motion, the quiet crossfade the opacity transitions on the
    /// faces provide).
    private var face: Int {
        if let notice = shownNotice {
            guard notice.kind.hasVerbs else { return 1 }
            return notice.takeover ? 4 : 3
        }
        return cardOnStage ? 2 : 0
    }

    /// How tall the content under the shape's foot is: a notice's own
    /// frame, the card's, or nothing at rest.
    private var footContentHeight: CGFloat? {
        if shownNotice != nil || lastNotice != nil { return toy.stage.noticeMorph?.open }
        return cardOnStage ? toy.stage.cardHeight : nil
    }

    /// The card stays on stage through its fold, until the shape has
    /// carried the content out of sight (`NotchReveal.staged`).
    private var cardOnStage: Bool { toy.islandExpanded || toy.stage.cardStaged }

    var body: some View {
        let summary = toy.islandSummary
        // The shape is the proposed size, whatever the faces inside ask
        // for: a face with a rigid width (the grown card's 320 points, a
        // wide idle row) is laid out in an overlay, so it can neither
        // widen the silhouette nor shrink it, and the clip below cuts it
        // to the shape the stage says.
        Color.clear.overlay(alignment: .top) { faces(summary: summary) }
        // The soft foot sits over the faces too, while the shape is
        // still short of the content it uncovers.
        .overlay(alignment: .bottom) {
            NotchFootFade(stage: toy.stage, contentHeight: footContentHeight)
        }
        // The edge light sits over the faces and under the clip, so
        // half its width is cut away and one point of light is left.
        .overlay { NotchEdgeLight(stage: toy.stage, silhouette: silhouette) }
        .clipShape(silhouette)
        // Hover and the press belong to the shape, not to the window
        // around it (a stage is larger than the shape while it moves).
        .contentShape(silhouette)
        .onHover { toy.setHovered($0) }
        // Every face decision funnels through `NotchMotion.faceTransition`
        // — the fades normally, the quiet crossfade under Reduce
        // Motion — so the accessibility path is one pinned fact.
        .animation(reduceMotion ? JRBarTokens.Motion.reduced.animation : nil, value: face)
        .modifier(NotchStageFrame(stage: toy.stage))
        .overlay {
            if let path = toy.shoulderInputPath {
                Color.clear
                    .contentShape(Path(path))
                    .onTapGesture { toy.islandTapped() }
                    .accessibilityHidden(true)
                    .transaction { $0.animation = nil; $0.disablesAnimations = true }
            }
        }
        // A face built while a notice is already up (a rebuilt root, a
        // re-hosted window) shows it at once — the entrance only ever
        // plays on the change.
        .onAppear {
            guard let notice = shownNotice else { return }
            lastNotice = notice
            noticeShown = true
        }
        .onChange(of: shownNotice) { _, shown in
            if let shown {
                lastNotice = shown
                guard !noticeShown else { return }
                withAnimation(reduceMotion
                              ? .easeInOut(duration: JRBarTokens.Motion.reduced.duration)
                              : .easeOut(duration: NotchMotion.noticeFadeIn)) {
                    noticeShown = true
                }
            } else {
                // The dismissal reverses the entrance, a touch quicker.
                withAnimation(reduceMotion
                              ? .easeInOut(duration: JRBarTokens.Motion.reduced.duration)
                              : .easeIn(duration: NotchMotion.noticeFadeOut)) {
                    noticeShown = false
                }
                DispatchQueue.main.asyncAfter(
                    deadline: .now() + NotchMotion.noticeFadeOut + 0.05
                ) {
                    if toy.activeOverlay == nil, toy.activeCapsule == nil { lastNotice = nil }
                }
            }
        }
    }

    /// The faces, stacked on the black.
    private func faces(summary: NotchIslandSummary) -> some View {
        ZStack(alignment: .top) {
            islandBackground
            if let notice = shownNotice ?? lastNotice {
                // Laid out once at its own width and uncovered by the
                // shape: it never re-wraps while the island grows.
                noticeCapsule(notice)
                    .frame(width: toy.stage.noticeMorph?.openWidth)
                    .modifier(NotchNoticeReveal(stage: toy.stage, shown: noticeShown))
                    .allowsHitTesting(shownNotice != nil)
            } else if cardOnStage {
                let width = toy.stage.cardWidth ?? toy.expandedCardWidth
                let height = toy.stage.cardHeight.map { max(0, $0 - toy.cardTopPad) }
                // The card, grown out of the notch — the same rows the
                // glass fallback shows, on black under `cardTopPad`. Its
                // sheet and rows read the shape's travel, so no
                // transition of its own.
                ScrollView(.vertical) {
                    NotchCardView(model: toy.cardModel, style: .island,
                                  width: width)
                }
                    .allowsHitTesting(toy.islandExpanded)
                    .frame(width: width, height: height, alignment: .top)
                    // No scroller on the black and no rubber band on a
                    // card that fits: it scrolls only when it must.
                    .scrollIndicators(.hidden)
                    .scrollBounceBehavior(.basedOnSize)
                    .modifier(NotchSheetReveal())
                    .padding(.top, toy.cardTopPad)
                    .environment(\.notchStage, toy.stage)
            } else {
                idle(summary: summary)
                    // A tap on the resting island grows the card — the
                    // face carries it, so a tap on a dot is a tap too.
                    .contentShape(Rectangle())
                    .onTapGesture { toy.islandTapped() }
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel("Notch island")
                    .accessibilityValue(summary.statusLine + mediaSpokenSuffix + sensorSpokenSuffix)
                    .accessibilityHint("Opens the notch card")
                    .accessibilityAddTraits(.isButton)
                    .accessibilityAction { toy.islandTapped() }
                    .transition(swapTransition)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    /// Face changes fade under Reduce Motion.
    private var swapTransition: AnyTransition {
        reduceMotion ? .opacity : .identity
    }

    /// Plain black — the black the notch's bezel already reads as — so
    /// the island and the hardware merge into one shape (the glass rule:
    /// only a surface floating free of the notch gets Liquid Glass, and
    /// this one is flush with it). Flush top corners while notched (the
    /// screen's edge is the island's top), and the bottom corners take
    /// the notch profile's own radius so island and bar tray match.
    /// Notch-less: a floating pill.
    private var silhouette: NotchSilhouette {
        NotchSilhouette(notchDepth: toy.notchDepth, restingRadius: toy.notchCornerRadius,
                        notchWidth: toy.notchSlotWidth)
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
    /// How the breath ticks: 15 frames a second while the island has work
    /// to show, and not at all otherwise. The Mac asking for restraint
    /// (`PowerPolicy`) halves the rate, and a critical thermal state holds
    /// the face still.
    nonisolated static func breathCadence(working: Bool, shown: Bool, reduceMotion: Bool, bare: Bool,
                                          power: PowerPolicy) -> (interval: TimeInterval, live: Bool) {
        (power.interval(1.0 / 15.0),
         working && shown && !reduceMotion && !bare && !power.pauses(occluded: false))
    }

    private func idle(summary: NotchIslandSummary) -> some View {
        let layout = toy.idleLayout
        let notched = toy.notchDepth > 0
        let breath = Self.breathCadence(
            working: summary.working > 0, shown: toy.islandVisible, reduceMotion: reduceMotion,
            bare: notched && layout.bare, power: PowerConditions.shared.policy)
        let live = breath.live
        return TimelineView(.animation(minimumInterval: breath.interval, paused: !live)) { context in
            let swell = live
                ? (1 - cos(context.date.timeIntervalSinceReferenceDate * .pi * 2 / 2.6)) / 2
                : 0
            Group {
                if notched {
                    shoulders(summary: summary, layout: layout)
                } else {
                    centredRow(summary: summary)
                }
            }
            .opacity(0.85 + 0.15 * swell)
            // The hover wink's other half — the frame grows a few
            // points (the toy's `islandHoverPeek` reframe), and the
            // marks swell inside it. A passing cursor earns only this.
            .scaleEffect(toy.islandHoverPeek ? NotchMotion.hoverContentScale : 1)
            .animation(reduceMotion ? .easeInOut(duration: JRBarTokens.Motion.reduced.duration)
                                    : JRBarTokens.Motion.quick.animation,
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
                    if layout.mediaArtLeft, let media = toy.islandMedia, toy.settings.mediaEnabled {
                        // The compact live activity: the cover left of
                        // the notch, the waveform right of it.
                        mediaCover(media)
                            .padding(.trailing, NotchIslandLayout.shoulderPad)
                    } else {
                        agentRow(summary: summary)
                            .padding(.trailing, NotchIslandLayout.shoulderPad)
                    }
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
                            // The amber count goes straight to the
                            // longest-waiting session, not the card.
                            markCount(count, color: .orange)
                                .contentShape(Rectangle())
                                .onTapGesture { toy.openOldestAsk() }
                                .help("Open the session that has waited longest")
                        case .failed(let count):
                            markCount(count, color: .red)
                        case .media:
                            if let media = toy.islandMedia, toy.settings.mediaEnabled {
                                mediaStrip(media, withCover: !layout.mediaArtLeft)
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
                NotchDot(color: ProviderStyle.style(for: provider).accent)
            }
            Text("\(summary.working)")
                .font(.system(size: JRBarTokens.TypeStyle.caption.size, weight: .bold, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(.white.opacity(0.92))
        }
        .accessibilityLabel(Text("\(summary.working) working"))
    }

    /// The attention mark: a coloured dot and the count beside it.
    private func markCount(_ count: Int, color: Color) -> some View {
        HStack(spacing: 3) {
            NotchDot(color: color)
            Text("\(count)")
                .font(.system(size: JRBarTokens.TypeStyle.caption.size, weight: .bold, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(color)
        }
    }

    /// The track the compact strip no longer prints: said to VoiceOver.
    private var mediaSpokenSuffix: String {
        guard toy.settings.mediaEnabled, let media = toy.islandMedia else { return "" }
        return " · \(media.playing ? "playing" : "paused") \(media.displayLine)"
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
            if sensors.cameraInUse { NotchDot(color: .green) }
            if sensors.microphoneInUse { NotchDot(color: .orange) }
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
                mediaStrip(media, withCover: true)
            }
            ForEach(summary.workingProviders.prefix(NotchIsland.dotLimit), id: \.self) { provider in
                NotchDot(color: ProviderStyle.style(for: provider).accent)
            }
            if summary.waiting > 0 { NotchDot(color: .orange) }
            if summary.failed > 0 { NotchDot(color: .red) }
            if summary.working + summary.waiting + summary.failed > 0 {
                Text("\(summary.working + summary.waiting + summary.failed)")
                    .font(.system(size: JRBarTokens.TypeStyle.caption.size, weight: .bold, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(.white.opacity(0.85))
            } else {
                Circle().fill(.white.opacity(0.28)).frame(width: 4, height: 4)
            }
        }
    }

    /// The track's cover as a small rounded thumbnail (or a note glyph
    /// when the player sent none), decoded once, small, off the main
    /// thread: the strip redraws on every breath tick. A new track's cover
    /// dissolves into the last one's.
    private func mediaCover(_ media: AlcoveMedia) -> some View {
        NotchCoverSwap(image: media.artworkData != nil ? toy.islandArtwork : nil) {
            Image(systemName: "music.note")
                .font(.system(size: 7, weight: .semibold)) // jrbar-token-exception: glyph inside the cover thumbnail
                .foregroundStyle(.white.opacity(0.7))
        }
        .frame(width: NotchIsland.mediaArtWidth, height: NotchIsland.mediaArtWidth)
        .clipShape(RoundedRectangle(cornerRadius: 3.5, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 3.5, style: .continuous)
            .strokeBorder(.white.opacity(0.14), lineWidth: 0.5))
        .notchTrackSwap(key: media.displayLine)
        .help(media.displayLine)
    }

    /// The idle capsule's Now Playing half, Alcove's compact live
    /// activity: a small waveform, animated only while the track is
    /// actually playing (paused and Reduce Motion both get still bars,
    /// and the frame never asks the player for spectrum data it cannot
    /// give), with the cover beside it when the other shoulder is taken.
    /// Never the title: that is on the card and in the tooltip, so the
    /// strip is the same width for every track.
    private func mediaStrip(_ media: AlcoveMedia, withCover: Bool) -> some View {
        HStack(spacing: NotchIsland.mediaGap) {
            if withCover { mediaCover(media) }
            visualizer(playing: media.playing)
                .frame(width: NotchIsland.mediaBarsWidth, alignment: .leading)
        }
        .help(media.displayLine)
    }

    /// The shared decorative bars while the track plays — set dressing,
    /// not a spectrum; paused, Reduce Motion or an ordered-out island
    /// draws them still. A live audio tap swaps them for the real band
    /// levels — the tap's gate only ever runs it with the card grown, so
    /// the strip falls back to the decorative dance whenever the
    /// pipeline is down.
    private func visualizer(playing: Bool) -> some View {
        let utility = toy.cardModel.utility
        return Group {
            if utility.audioTapLive {
                LiveEqualizer(utility: utility, color: .white.opacity(0.75), barWidth: 2.4, height: 10)
            } else {
                DecorativeBars(live: playing && toy.islandVisible, color: .white.opacity(0.75), barWidth: 2.4)
            }
        }
    }

    // MARK: Notice capsule

    /// The notice face for whatever the queue put up: the ask with its
    /// verbs, a level as one continuous fill, or the one-line capsule.
    @ViewBuilder
    private func noticeCapsule(_ notice: AlcoveNotice) -> some View {
        switch notice.kind {
        case .ask: askFace(notice)
        case .meeting: meetingFace(notice)
        case .level: levelFace(notice)
        default: lineFace(notice)
        }
    }

    /// The event capsule — Alcove's instant notification, one line:
    /// the glyph in its colour (the provider's accent for a quota
    /// reset) and "Claude · rename-the-fish finished" — title and
    /// subtitle joined into a single truncating line, centred in the lip
    /// under the notch, above a live Screen Bar's housing, inside the
    /// notice frame the toy sized.
    private func lineFace(_ notice: AlcoveNotice) -> some View {
        // A tap that could not open the session says why in the line.
        let refusal = notice.session.flatMap { toy.cardModel.openRefusals[$0] }
        return HStack(spacing: 7) {
            NotchGlyph(symbol: notice.symbol, tint: noticeTint(notice))
            Group {
                if let refusal {
                    Text(refusal).foregroundStyle(.orange)
                } else {
                    Self.noticeLine(notice)
                }
            }
            .font(JRBarTokens.TypeStyle.caption.font)
            .lineLimit(1)
            .truncationMode(.middle)
        }
        .padding(.horizontal, 16)
        // The line clears the notch and persistent wing strip. The
        // bottom pad keeps its copy above the Screen Bar's housing.
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
        .padding(.top, toy.noticeTopPad)
        .padding(.bottom, toy.noticeClimb)
        // A tap on news about a session opens it; anything else puts
        // itself away. Neither re-opens the card.
        .contentShape(Rectangle())
        .onTapGesture { toy.islandTapped() }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Notch notification")
        .accessibilityValue("\(notice.title). \(notice.subtitle)")
        .accessibilityHint(notice.session != nil ? "Opens the session" : "Dismisses the notification")
        .accessibilityAddTraits(.isButton)
        .accessibilityAction { toy.islandTapped() }
    }

    /// The notice's copy as one line: who or what, bright and set a
    /// weight up, then what happened, quieter.
    static func noticeLine(_ notice: AlcoveNotice) -> Text {
        let title = Text(notice.title)
            .fontWeight(.semibold)
            .foregroundStyle(Color.white.opacity(0.95))
        guard !notice.subtitle.isEmpty else { return title }
        let rest = Text(verbatim: "  \(notice.subtitle)")
            .foregroundStyle(Color.white.opacity(0.6))
        return Text("\(title)\(rest)")
    }

    /// A level key's answer, grown out of the notch — the Alcove HUD in
    /// the island's own black rather than a pill hung under it. The
    /// reading is one continuous fill with its number: no segments, the
    /// same unbroken language the Screen Bar speaks. Muted is red.
    private func levelFace(_ notice: AlcoveNotice) -> some View {
        let fraction = min(1, max(0, notice.fraction ?? 0))
        return HStack(spacing: 10) {
            // The glyph's own waves light with the level where the
            // symbol has them — the system HUD's speaker, in white.
            Image(systemName: notice.symbol, variableValue: notice.muted ? nil : fraction)
                .font(.system(size: JRBarTokens.TypeStyle.callout.size, weight: .semibold))
                .foregroundStyle(notice.muted ? AnyShapeStyle(Color.red) : AnyShapeStyle(Color.white.opacity(0.9)))
                .frame(width: 20)
            NotchLevelBar(fraction: fraction, tint: notice.muted ? .red : .white,
                          dimmed: notice.muted)
            // A level reads its percent; a readout with words of its own
            // (the ⌘-drag timer's minutes) reads those.
            Text(notice.muted ? "Muted"
                 : notice.subtitle.isEmpty ? "\(Int((fraction * 100).rounded()))" : notice.subtitle)
                .font(.system(size: JRBarTokens.TypeStyle.caption.size, weight: .semibold, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(notice.muted ? AnyShapeStyle(Color.red.opacity(0.9))
                                              : AnyShapeStyle(Color.white.opacity(0.75)))
                .contentTransition(.numericText(value: fraction))
                .lineLimit(1)
                .fixedSize()
                .frame(minWidth: 26, alignment: .trailing)
        }
        .animation(reduceMotion ? nil : .smooth(duration: NotchMotion.levelFollow), value: fraction)
        .padding(.horizontal, 18)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
        .padding(.top, toy.noticeTopPad)
        .padding(.bottom, toy.noticeClimb)
        .contentShape(Rectangle())
        .onTapGesture { toy.islandTapped() }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(notice.title)
        .accessibilityValue(notice.muted ? "Muted"
                            : notice.subtitle.isEmpty ? "\(Int((fraction * 100).rounded())) percent" : notice.subtitle)
    }

    /// The ask, where it can be answered: who (the glyph, "Claude ·
    /// rename-the-fish" and how long it has waited), what they ask (the
    /// summary — one line on the capsule, up to three on the takeover
    /// card), and the verbs. Each verb exists only where `AskVerbs` says
    /// the daemon can deliver it, and every one goes through the shared
    /// desk; every other ask offers Open with its reason
    /// (`NotchAskVerbs`). A refused answer or open takes the reason's
    /// place in orange and the ask stays. A tap anywhere off the buttons
    /// opens the session.
    private func askFace(_ notice: AlcoveNotice) -> some View {
        let verbs = toy.askVerbs(for: notice)
        let session = notice.session ?? ""
        let live = toy.liveAsk(for: notice)
        let desk = toy.cardModel.askDesk()
        let pending = desk?.isPending(session) ?? false
        let deskNote = desk?.note(for: session)
        let refusal = toy.cardModel.openRefusals[session] ?? deskNote.flatMap { $0.refused ? $0.text : nil }
        let local = verbs.answers
        let lines = toy.askSummaryLines
        let plan = toy.askKeyVerbs(for: notice)
        let engaged = toy.askKeyboardEngaged
        let focus = engaged ? toy.askFocus.focused : nil
        let keyHint = pending ? "Sending response" : focus != nil ? "Press Return"
            : live?.isDestructive == true || !plan.contains(.approve) ? "Choose a verb" : "Return to approve"
        return VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 7) {
                askMark(notice)
                Text(notice.title)
                    .font(.system(size: JRBarTokens.TypeStyle.callout.size, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.95))
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer(minLength: 4)
                if live?.isDestructive == true {
                    AskRiskMark(size: 9.5)
                }
                if let opened = live?.openedAt ?? notice.ask?.openedAt {
                    TimelineView(.periodic(from: .now, by: 15)) { context in
                        NotchWaitChip(text: Self.waitedText(since: opened, stale: live?.isStale == true,
                                                            now: context.date))
                    }
                }
            }
            .frame(height: NotchIslandLayout.askTitleLine)
            NotchAskCopy.line(toy.askSummary(notice), preview: live?.previewLine,
                              destructive: live?.isDestructive == true)
                .font(JRBarTokens.TypeStyle.caption.font)
                .foregroundStyle(.white.opacity(0.7))
                .lineLimit(lines)
                .truncationMode(.tail)
                .frame(maxWidth: .infinity,
                       minHeight: CGFloat(lines) * NotchIslandLayout.askSummaryLine,
                       maxHeight: CGFloat(lines) * NotchIslandLayout.askSummaryLine,
                       alignment: .topLeading)
            Spacer(minLength: NotchIslandLayout.askGap)
            HStack(spacing: 6) {
                // A held question answers here whatever the keystroke
                // path says, so its "answer it in its window" is moot.
                if engaged, refusal == nil {
                    Text(keyHint)
                        .font(JRBarTokens.TypeStyle.caption.font)
                        .foregroundStyle(Color.white.opacity(0.55))
                        .lineLimit(1)
                        .truncationMode(.tail)
                } else if let line = refusal ?? (live.map(AskVerbs.chooses) == true ? nil : verbs.note) {
                    Text(line)
                        .font(JRBarTokens.TypeStyle.caption.font)
                        .foregroundStyle(refusal != nil
                                         ? AnyShapeStyle(Color.orange)
                                         : AnyShapeStyle(Color.white.opacity(0.4)))
                        .lineLimit(1)
                        .truncationMode(.tail)
                        .help(line)
                }
                Spacer(minLength: 4)
                if let live, desk != nil, !CoreSession.isRemoteID(session),
                   AskVerbs.chooses(live) || (local && AskVerbs.approves(live)) {
                    NotchHoldRing(ask: live, style: .island)
                }
                if let live, let desk, !CoreSession.isRemoteID(session), AskVerbs.chooses(live) {
                    // A held question: Deny declines it through its hook,
                    // and its options are the answer.
                    NotchVerbButton(title: "Deny", style: .island, busy: pending,
                                    focused: focus == .deny, hint: Self.askHint(.deny)) {
                        toy.performAskVerb(.deny)
                    }
                    NotchAskChoices(ask: live, desk: desk, style: .island, busy: pending, focus: focus)
                } else if local, let live, desk != nil, AskVerbs.approves(live) {
                    NotchVerbButton(title: "Deny", style: .island, busy: pending,
                                    focused: focus == .deny, hint: Self.askHint(.deny)) {
                        toy.performAskVerb(.deny)
                    }
                    if AskVerbs.alwaysAllows(live) {
                        NotchVerbButton(title: "Always", style: .island, busy: pending,
                                        focused: focus == .always, hint: Self.askHint(.always)) {
                            toy.performAskVerb(.always)
                        }
                        .help("Approve, and let the agent remember the rule it offered")
                    }
                    NotchVerbButton(title: "Approve", style: .island, prominent: true, busy: pending,
                                    focused: focus == .approve, hint: Self.askHint(.approve)) {
                        toy.performAskVerb(.approve)
                    }
                }
                if verbs.opens {
                    NotchVerbButton(title: "Open", style: .island, systemImage: "arrow.up.forward",
                                    focused: focus == .open, hint: Self.askHint(.open)) {
                        toy.performAskVerb(.open)
                    }
                }
            }
            .frame(height: NotchIslandLayout.askVerbRow)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, NotchIslandLayout.askPad)
        .padding(.top, toy.askTopPad)
        .padding(.bottom, toy.askClimb)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .contentShape(Rectangle())
        .onTapGesture { toy.islandTapped() }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("\(notice.title) needs you")
        .accessibilityValue(toy.askSummary(notice))
        .accessibilityActions { askActions(plan) }
    }

    /// VoiceOver's way to every verb the face draws: each one is an
    /// action a person chooses on purpose, through the same door as the
    /// button and the keyboard.
    @ViewBuilder
    private func askActions(_ plan: [NotchAskVerbKey]) -> some View {
        ForEach(plan, id: \.self) { verb in
            Button(verb.title) { toy.performAskVerb(verb) }
        }
    }

    /// What pressing a verb does, said to VoiceOver on its button.
    nonisolated static func askHint(_ verb: NotchAskVerbKey) -> String {
        switch verb {
        case .deny: return "Declines what the agent asked to do"
        case .always: return "Approves it and lets the agent remember the rule"
        case .approve: return "Approves what the agent asked to do"
        case .open: return "Brings the session's window forward"
        case .choice: return "Answers the question"
        }
    }

    /// A meeting about to start, in the ask's verb face: which meeting
    /// and a live countdown, its times and where it is held, and the
    /// verbs — the Mirror for a last look (when the Mirror is on) and
    /// Join (when the event carries a link). A tap off the buttons puts
    /// it away; the card's calendar row keeps Join after it goes.
    private func meetingFace(_ notice: AlcoveNotice) -> some View {
        let meeting = toy.headsUpMeeting
        return VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 7) {
                NotchGlyph(symbol: notice.symbol, tint: noticeTint(notice), size: 11)
                    .frame(width: NotchIslandLayout.askTitleLine)
                Text(notice.title)
                    .font(.system(size: JRBarTokens.TypeStyle.callout.size, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.95))
                    .lineLimit(1)
                    .truncationMode(.tail)
                Spacer(minLength: 4)
                if let start = meeting?.start {
                    TimelineView(.periodic(from: .now, by: 15)) { context in
                        NotchWaitChip(text: ShelfMeetingWatch.countdown(to: start, now: context.date),
                                      tint: .blue)
                    }
                }
            }
            .frame(height: NotchIslandLayout.askTitleLine)
            Text(notice.subtitle)
                .font(JRBarTokens.TypeStyle.caption.font)
                .foregroundStyle(.white.opacity(0.7))
                .lineLimit(1)
                .truncationMode(.tail)
                .frame(maxWidth: .infinity, minHeight: NotchIslandLayout.askSummaryLine,
                       maxHeight: NotchIslandLayout.askSummaryLine, alignment: .topLeading)
            Spacer(minLength: NotchIslandLayout.askGap)
            HStack(spacing: 6) {
                Spacer(minLength: 4)
                if toy.settings.mirror {
                    NotchVerbButton(title: "Mirror", style: .island, systemImage: "person.crop.square") {
                        toy.mirrorBeforeMeeting()
                    }
                }
                if meeting?.url != nil {
                    NotchVerbButton(title: "Join", style: .island, prominent: true,
                                    systemImage: "video.fill") {
                        toy.joinHeadsUpMeeting()
                    }
                }
            }
            .frame(height: NotchIslandLayout.askVerbRow)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, NotchIslandLayout.askPad)
        .padding(.top, toy.askTopPad)
        .padding(.bottom, toy.askClimb)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .contentShape(Rectangle())
        .onTapGesture { toy.islandTapped() }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("\(notice.title) is starting")
        .accessibilityValue(notice.subtitle)
    }

    /// Who is asking: the provider's own tile, or the ask glyph in amber
    /// when the notice names no provider.
    @ViewBuilder
    private func askMark(_ notice: AlcoveNotice) -> some View {
        if let provider = notice.provider {
            ProviderTile(style: ProviderStyle.style(for: provider), size: NotchIslandLayout.askTitleLine)
        } else {
            NotchGlyph(symbol: notice.symbol, tint: .orange, size: 11)
                .frame(width: NotchIslandLayout.askTitleLine)
        }
    }

    /// The wait chip's words: "4m", or for an ask that may be stale
    /// "may be stale · 9 hours" -- still an ask, with its age said plainly.
    static func waitedText(since openedAt: Double, stale: Bool, now: Date) -> String {
        guard stale else { return waited(since: openedAt, now: now) }
        return "may be stale · \(CoreAsk.ageWords(now.timeIntervalSince1970 - openedAt))"
    }

    /// "4m", "1h 5m" — how long the ask has waited, off its own
    /// `opened_at`.
    static func waited(since openedAt: Double, now: Date) -> String {
        let seconds = max(0, Int(now.timeIntervalSince1970 - openedAt))
        if seconds < 60 { return "now" }
        let minutes = seconds / 60
        if minutes < 60 { return "\(minutes)m" }
        return "\(minutes / 60)h \(minutes % 60)m"
    }

    /// Waiting is amber, finished is green, failed is red — the app's
    /// standing state colours; a quota reset borrows its provider's
    /// accent and power is yellow, the bolt's own colour. The Mac's own
    /// announcements stay white: they are facts, not states.
    private func noticeTint(_ notice: AlcoveNotice) -> Color {
        switch notice.kind {
        case .ask: return .orange
        case .completed: return .green
        case .failed: return .red
        case .quotaReset: return ProviderStyle.style(for: notice.provider ?? "").accent
        case .charging: return .yellow
        case .timer: return .orange
        case .meeting: return .blue
        case .focus: return .indigo
        case .level, .device, .capsLock, .display: return .white.opacity(0.85)
        }
    }
}

/// A mark in the island's dot language: a small disc in its colour with
/// a faint halo, so a working provider reads as lit on the black rather
/// than printed on it.
struct NotchDot: View {
    let color: Color
    var size: CGFloat = 5

    var body: some View {
        Circle()
            .fill(color)
            .frame(width: size, height: size)
            .shadow(color: color.opacity(0.55), radius: size * 0.5)
    }
}

/// A notice's glyph: the kind's symbol solid in its colour — a filled
/// disc keeps its mark cut clean through to the black, as the system
/// draws it — lit from behind by a soft halo of the same colour, the
/// one flourish the black lip allows, and it stays inside the line's
/// room.
struct NotchGlyph: View {
    let symbol: String
    let tint: Color
    var size: CGFloat = 11.5

    var body: some View {
        Image(systemName: symbol)
            .font(.system(size: size, weight: .semibold))
            .foregroundStyle(tint)
            .shadow(color: tint.opacity(0.5), radius: 3.5)
            .accessibilityHidden(true)
    }
}

/// How long something has waited, or how soon it starts, as a small
/// tinted capsule beside a title — "3m", "in 2 min".
struct NotchWaitChip: View {
    let text: String
    var tint: Color = .orange

    var body: some View {
        Text(text)
            .font(.system(size: JRBarTokens.TypeStyle.caption.size, weight: .semibold, design: .rounded))
            .monospacedDigit()
            .foregroundStyle(tint.mix(with: .white, by: 0.25))
            .padding(.horizontal, 6)
            .padding(.vertical, 1.5)
            .background(Capsule(style: .continuous).fill(tint.opacity(0.18)))
            .fixedSize()
    }
}

/// One continuous level — the island's volume, brightness and backlight
/// answer and the HUD pill's: a track, and a fill that brightens toward
/// its head and ends in a soft glow. Never segments: the same unbroken
/// language the Screen Bar speaks.
struct NotchLevelBar: View {
    let fraction: Double
    var tint: Color = .white
    var track: Color = .white.opacity(0.16)
    var height: CGFloat = 6
    /// A muted level keeps its reading but stops glowing.
    var dimmed = false
    /// The head's halo — the island's black wants it, a pale HUD does not.
    var glows = true

    var body: some View {
        GeometryReader { geo in
            let clamped = min(1, max(0, fraction))
            let width = clamped > 0 ? max(geo.size.height, geo.size.width * clamped) : 0
            ZStack(alignment: .leading) {
                Capsule(style: .continuous).fill(track)
                Capsule(style: .continuous)
                    .fill(LinearGradient(colors: [tint.opacity(dimmed ? 0.45 : 0.72),
                                                  tint.opacity(dimmed ? 0.6 : 1)],
                                         startPoint: .leading, endPoint: .trailing))
                    .frame(width: width)
                    .shadow(color: tint.opacity(dimmed || !glows ? 0 : 0.45), radius: height * 0.7)
            }
        }
        .frame(height: height)
        .accessibilityHidden(true)
    }
}
