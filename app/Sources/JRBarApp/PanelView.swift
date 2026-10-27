import JRBarCore
import JRBarUI
import SwiftUI

/// The click-open panel. Cached facts are laid out before the window arrives.
struct PanelView: View {
    @Bindable var store: PanelStore
    var panelWidth: CGFloat = PanelComposition.width
    static let width = PanelComposition.width

    var body: some View {
        let composition = PanelComposition(store: store)
        VStack(spacing: 0) {
            PanelTitleBar(store: store)
            if store.coreCrashed {
                StatusBanner("Monitor stopped", kind: .failure, detail: store.coreCrashDetail) {
                    Button("Restart") { store.restartCore() }
                }.padding(.horizontal, JRBarTokens.Space.md).frame(height: 70)
            } else if !store.isLive {
                StatusBanner(MonitorWords.reconnecting, detail: store.connectionDescription)
                    .padding(.horizontal, JRBarTokens.Space.md).frame(height: 70)
            } else if let failure = store.providerList.failure {
                StatusBanner("Provider list unavailable", kind: .failure, detail: failure)
                    .padding(.horizontal, JRBarTokens.Space.md).frame(height: 70)
            }
            if !store.visibleAskRows.isEmpty || store.demoRow != nil {
                panelSectionTitle("Needs you")
                SnapshotScrollView {
                    VStack(spacing: 0) {
                        if let demo = store.demoRow { AskRow(row: demo, store: store, detailHeight: composition.askDetailHeight) }
                        ForEach(store.visibleAskRows) { row in AskRow(row: row, store: store, detailHeight: composition.askDetailHeight) }
                    }
                }.frame(height: composition.asksHeight)
            }
            if store.panelAgentsFirst ?? store.panelHasRunningAgents {
                PanelAgentsSection(store: store, composition: composition)
                Hairline()
                PanelProviderSection(store: store, composition: composition)
            } else {
                PanelProviderSection(store: store, composition: composition)
                Hairline()
                PanelAgentsSection(store: store, composition: composition)
            }
            Hairline()
            PanelActionsFooter(store: store)
        }
        .font(JRBarTokens.TypeStyle.body.font)
        .foregroundStyle(JRBarTokens.Ink.label)
        .frame(width: panelWidth, height: composition.totalHeight, alignment: .top)
        .jrbarAccessibility(reduceMotion: store.reduceMotion || !store.marksMove)
        .overlay(alignment: .bottom) { ToastView(text: store.toast, action: store.toastAction, reduced: store.reduceMotion, armed: store.animationsArmed) }
        .onChange(of: store.layout) { _, layout in store.layoutDidChange(layout) }
    }
}

// MARK: - Shared atoms

struct Hairline: View {
    var body: some View {
        Rectangle().fill(.primary.opacity(0.08)).frame(height: CGFloat(PanelLayout.hairline))
    }
}

/// A provider tile using the shared component.
struct ProviderTile: View {
    let style: ProviderStyle
    var size: CGFloat = 20
    @Environment(\.colorScheme) private var colorScheme

    /// How much of the tile's side the mark's box takes. A symbol at half
    /// the side in points carried its own padding; a mark's path does not.
    static let markShare: CGFloat = 0.58

    var body: some View {
        ProviderLogoTile(provider: style.id, size: size, accent: style.accent)
    }
}

/// The activity mark: breathing dot (working), amber pulse (waiting),
/// check (done), cross (failed), still dot (idle).
struct ActivityMark: View {
    let activity: SessionActivity
    let accent: Color
    let reduced: Bool
    /// Only an open panel breathes: a repeating SwiftUI animation keeps the
    /// hosting view re-rendering at 60 Hz even while the window is ordered
    /// out, which cost 13 % CPU with one working session and the panel closed.
    var active: Bool = true

    /// Whether the mark moves at all: a working or waiting mark in an
    /// open panel, with motion allowed. Anything else draws still.
    static func pulses(_ activity: SessionActivity, reduced: Bool, active: Bool) -> Bool {
        active && !reduced && (activity == .working || activity == .waiting)
    }

    var body: some View {
        Group {
            if Self.pulses(activity, reduced: reduced, active: active) {
                // A view of its own, there only while the mark may move: a
                // running `repeatForever` cannot be stopped by setting its
                // value back, but it ends with the view that runs it. The
                // id restarts the pulse when working turns to waiting.
                PulsingActivityMark(activity: activity, accent: accent)
                    .id(activity)
            } else {
                Self.still(activity, accent: accent, reduced: reduced)
            }
        }
        .frame(width: 8, height: 8)
        // The row's label already speaks the word; alone the mark would
        // be an unlabeled dot VoiceOver has to step over.
        .accessibilityHidden(true)
    }

    /// The mark at rest — `phase` false — or its reduced-motion form.
    @ViewBuilder
    static func still(_ activity: SessionActivity, accent: Color, reduced: Bool) -> some View {
        switch activity {
        case .working:
            ActivityMarkShape.working(accent: accent, phase: false, reduced: reduced)
        case .waiting:
            ActivityMarkShape.waiting(phase: false, reduced: reduced)
        case .done:
            Image(systemName: "checkmark.circle.fill")
                .font(JRBarTokens.TypeStyle.caption.font)
                .foregroundStyle(SessionActivity.done.tint.opacity(0.9))
        case .ended:
            // The process went away without finishing anything: grey,
            // and deliberately not the green check a completion earns.
            Circle()
                .strokeBorder(Color.secondary.opacity(0.55), lineWidth: 1.4)
        case .failed:
            Image(systemName: "xmark.circle.fill")
                .font(JRBarTokens.TypeStyle.caption.font)
                .foregroundStyle(SessionActivity.failed.tint.opacity(0.9))
        case .idle:
            Circle().fill(.quaternary)
        }
    }
}

/// The two marks that move, drawn at a phase: working breathes, waiting
/// sends out an amber ring.
enum ActivityMarkShape {
    @ViewBuilder
    static func working(accent: Color, phase: Bool, reduced: Bool) -> some View {
        Circle().fill(accent)
            .opacity(reduced ? 0.9 : (phase ? 1.0 : 0.35))
            .scaleEffect(reduced ? 1 : (phase ? 1.0 : 0.85))
    }

    @ViewBuilder
    static func waiting(phase: Bool, reduced: Bool) -> some View {
        ZStack {
            Circle().fill(SessionActivity.waiting.tint.opacity(0.35))
                .scaleEffect(reduced ? 1.4 : (phase ? 2.1 : 1.0))
                .opacity(reduced ? 0.6 : (phase ? 0 : 0.8))
            Circle().fill(SessionActivity.waiting.tint)
        }
    }
}

/// A working or waiting mark while it moves. It starts its repeating
/// animation when it appears and takes it away when it goes: the parent
/// keeps it in the tree only while the panel is open.
struct PulsingActivityMark: View {
    let activity: SessionActivity
    let accent: Color
    @ViewState private var phase = false

    var body: some View {
        Group {
            if activity == .working {
                ActivityMarkShape.working(accent: accent, phase: phase, reduced: false)
            } else {
                ActivityMarkShape.waiting(phase: phase, reduced: false)
            }
        }
        .onAppear {
            PanelPulses.running += 1
            phase = false
            let pulse = activity == .working
                ? Animation.easeInOut(duration: StateDot.State.working.breathDuration!).repeatForever(autoreverses: true)
                : Animation.easeOut(duration: StateDot.State.asking.breathDuration!).repeatForever(autoreverses: false)
            withAnimation(pulse) { phase = true }
        }
        .onDisappear { PanelPulses.running -= 1 }
    }
}

/// The panel's repeating animations in the tree right now — a test hook
/// proving a closed panel runs none. Only the pulsing views count.
enum PanelPulses {
    @MainActor static var running = 0
}

/// A small count in a capsule. `symbol` names what is counted, so a bare
/// "10" beside a session's model never reads as a version or a score.
/// It rides a line of small type, so the capsule draws past the count's
/// height instead of adding to it and the line keeps its height.
struct CountBadge: View {
    let text: String
    var symbol: String? = nil

    var body: some View {
        StatusBadge(text, symbol: symbol).monospacedDigit()
    }
}

/// A row that is a button: hover tint only under the pointer while the
/// panel is open, a pressed tint only while the mouse is down, and the
/// selection tint only for the keyboard's row.
struct RowChrome<Content: View>: View {
    let selected: Bool
    let active: Bool
    let height: CGFloat
    let action: () -> Void
    @ViewBuilder let content: () -> Content

    var body: some View {
        Button(action: action) {
            content()
                .padding(.horizontal, 8)
                .frame(maxWidth: .infinity, alignment: .leading)
                .frame(height: height)
        }
        .buttonStyle(PanelRowStyle(selected: selected, active: active))
        .padding(.horizontal, 6)
    }
}

struct PanelRowStyle: ButtonStyle {
    let selected: Bool
    let active: Bool
    @ViewState private var hovering = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .background(
                RoundedRectangle(cornerRadius: JRBarTokens.Radius.control, style: .continuous)
                    .fill(Color.primary.opacity(fill(pressed: configuration.isPressed)))
            )
            .contentShape(RoundedRectangle(cornerRadius: JRBarTokens.Radius.control, style: .continuous))
            .onHover { hovering = $0 }
            .onChange(of: active) { _, isActive in if !isActive { hovering = false } }
    }

    private func fill(pressed: Bool) -> Double {
        if pressed { return 0.13 }
        if selected { return 0.10 }
        if hovering && active { return 0.05 }
        return 0
    }
}

// MARK: - Header

struct ConnectionDot: View {
    let state: PanelStore.ConnectionDot
    let reduced: Bool
    var active: Bool = true

    private var color: Color {
        switch state {
        case .live: return Tone.done.color
        case .connecting: return Tone.neutral.color
        case .fileFeeds: return Color.secondary.opacity(0.5)
        case .crashed: return Tone.failure.color
        }
    }

    /// Only a connecting dot in an open panel pulses, and only with
    /// motion allowed.
    static func pulses(_ state: PanelStore.ConnectionDot, reduced: Bool, active: Bool) -> Bool {
        state == .connecting && !reduced && active
    }

    var body: some View {
        Group {
            if Self.pulses(state, reduced: reduced, active: active) {
                // In the tree only while it may pulse, so closing the
                // panel ends the repeating animation with the view.
                PulsingConnectionDot(color: color)
            } else {
                // At rest a connecting dot shows its dim phase, as it did
                // when the pulse was stopped in place.
                Circle().fill(color)
                    .opacity(state == .connecting && !reduced ? 0.3 : 1)
            }
        }
        .frame(width: 6, height: 6)
        .accessibilityLabel(state == .live ? "Monitor connected" : (state == .connecting ? MonitorWords.reconnecting : (state == .crashed ? "Monitor crashed" : "Using file feeds")))
    }
}

/// The connecting dot's pulse, for as long as the view is shown.
struct PulsingConnectionDot: View {
    let color: Color
    @ViewState private var phase = false

    var body: some View {
        Circle()
            .fill(color)
            .opacity(phase ? 1 : 0.3)
            .onAppear {
                PanelPulses.running += 1
                withAnimation(.easeInOut(duration: StateDot.State.live.breathDuration ?? 1).repeatForever(autoreverses: true)) { phase = true }
            }
            .onDisappear { PanelPulses.running -= 1 }
    }
}

// MARK: - Sessions

struct SessionRowView: View {
    let row: SessionRow
    @Bindable var store: PanelStore
    /// The state word, mark and elapsed time sit in one column every row
    /// in the list shares (`trailingWidth(for:)`).
    let trailingWidth: CGFloat
    @ViewState private var hovering = false
    @ViewState private var contextFrame = CGRect.zero

    /// The trailing column: as wide as the widest state word the list
    /// shows plus its mark, and never narrower than the longest elapsed
    /// time a row can show -- "23h 59m", or "quiet 23h 59m" once a working
    /// row has gone quiet (`quiet`). Shared, it keeps every row's title the
    /// same room and every context hairline the same length; it moves only
    /// when a row's word changes or a row goes quiet, never as the clock
    /// ticks. A list of working rows leaves its titles the width "Waiting
    /// on you" used to hold back.
    static func trailingWidth(for activities: [SessionActivity], quiet: Bool = false) -> CGFloat {
        let widest = activities.map { wordWidths[$0] ?? 0 }.max() ?? 0
        let elapsed = quiet ? quietElapsedWidth : elapsedWidth
        return max(elapsed, widest + markRoom).rounded(.up)
    }

    /// The column for these rows as they read at `now`: a quiet working
    /// row's warning is never cut short.
    static func trailingWidth(rows: [SessionRow], now: Date) -> CGFloat {
        let quiet = rows.contains { $0.isQuiet(now: now) }
        return trailingWidth(for: rows.map(\.activity), quiet: quiet)
    }

    /// The tint of a quiet row's "quiet 12m": amber-leaning, a notch softer
    /// than an ask's, so a stuck run reads differently from a healthy one
    /// without claiming it needs you.
    static let quietTint = Tone.neutral.color.opacity(0.85)

    /// The word's HStack spacing and the mark's slot, which an orb and
    /// every mark share (`SessionRowMark.slot`).
    static let markRoom: CGFloat = 5 + SessionRowMark.slot

    /// Each state word in the trailing column's type.
    static let wordWidths: [SessionActivity: CGFloat] = {
        let font = NSFont.systemFont(ofSize: 11, weight: .medium)
        let pairs = SessionActivity.allCases.map { activity in
            (activity, (activity.word as NSString).size(withAttributes: [.font: font]).width)
        }
        return Dictionary(uniqueKeysWithValues: pairs)
    }()

    /// The longest elapsed time `PanelStore.elapsed` writes ("23h 59m").
    static let elapsedWidth: CGFloat = elapsedTextWidth("00h 00m")

    /// The same, on a working row gone quiet (`SessionRow.quietText`).
    static let quietElapsedWidth: CGFloat = elapsedTextWidth("quiet 00h 00m")

    /// `text` in the elapsed line's type.
    static func elapsedTextWidth(_ text: String) -> CGFloat {
        let font = NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .regular)
        return (text as NSString).size(withAttributes: [.font: font]).width
    }

    /// Waiting and failed are the words that shout -- a failure used to be
    /// as quiet as "Idle" here, which is the app-side half of the same
    /// defect the strip had. An ended run is quieter than a finished one,
    /// so "Done" and "Ended" never read the same. See SessionActivity.tint.
    static func wordColor(_ activity: SessionActivity) -> Color { activity.wordColor }

    var body: some View {
        RowChrome(selected: store.selectedID == row.id, active: store.isOpen, height: CGFloat(PanelLayout.sessionRowHeight), action: { store.open(row) }) {
            HStack(spacing: 9) {
                ProviderTile(style: row.style)
                VStack(alignment: .leading, spacing: 1) {
                    HStack(spacing: 6) {
                        Text(row.label).fontWeight(.medium).lineLimit(1).truncationMode(.tail)
                        if row.activity == .done, store.unseenCompletionIDs.contains(row.id) {
                            // `state.unseen_completions`: the one unseen
                            // dot History gives a row newer than the last
                            // visit, a fixed blue — never the accent, which
                            // a red accent would turn into a failure.
                            UnseenDot()
                                .help("Finished since you last looked")
                        }
                        if row.isSnoozed(now: store.now) {
                            // The family mailbox is muted until the time in
                            // the tooltip: say so, or the quiet row reads
                            // as a session nobody is answering.
                            Text("snoozed").font(JRBarTokens.TypeStyle.caption.font).foregroundStyle(.tertiary).lineLimit(1)
                        }
                        if row.stale { Text("stale").font(JRBarTokens.TypeStyle.caption.font).foregroundStyle(.tertiary).lineLimit(1) }
                        if row.canWatchForDone || store.isWatchedForDone(row) {
                            DoneBell(watched: store.isWatchedForDone(row), revealed: hovering || store.selectedID == row.id) {
                                store.toggleDoneWatch(row)
                            }
                        }
                        if let quiet = store.quietFeedText(for: row) {
                            // The provider's hook feed stopped arriving
                            // while the row still claims to be live: the
                            // daemon's `health.sources` fact, once per
                            // provider.
                            Text(quiet).font(JRBarTokens.TypeStyle.caption.font).foregroundStyle(.tertiary).lineLimit(1)
                                .help("\(row.style.name)'s hook feed has not delivered — this row may be behind")
                        }
                    }
                    HStack(spacing: 4) {
                        // The model the run is on ("Opus 4.5") once its
                        // transcript was read — the tile already names the
                        // provider, so the model is the better use of the
                        // words.
                        Text(row.usage?.modelName ?? row.style.name).foregroundStyle(.secondary).lineLimit(1).fixedSize()
                        if row.workers > 0 {
                            // The run's workers ride the model line, so the
                            // title keeps the label column's whole width.
                            CountBadge(text: "\(row.workers)", symbol: "square.stack")
                                .help([row.workersText, row.workersWaitingText].compactMap { $0 }.joined(separator: ", "))
                        }
                        if let waiting = row.workersWaitingShortText {
                            // Sub-agents blocked on a request that stays
                            // quiet (Sub-agent asks off): "1 waiting" in
                            // plain words, no tint, no card, no verb — a
                            // fact, not an ask. It takes the activity
                            // fact's place, because the model name, the
                            // workers badge and a fact already fill the
                            // label column; the full words ride the row's
                            // tooltip and its spoken label.
                            Text("·").foregroundStyle(.quaternary)
                            Text(waiting).foregroundStyle(.secondary).lineLimit(1).truncationMode(.tail)
                        } else if let fact = row.activityFact {
                            // The hook's last word ("running Bash") — the
                            // row's activity made specific.
                            Text("·").foregroundStyle(.quaternary)
                            Text(fact).foregroundStyle(.secondary).lineLimit(1).fixedSize()
                        }
                        if row.isRemote {
                            // A peer's session: name the machine, never a
                            // path this Mac cannot open.
                            Text("·").foregroundStyle(.quaternary)
                            Text("on \(row.remoteMachine ?? "a peer")").foregroundStyle(.tertiary).lineLimit(1).truncationMode(.tail)
                        } else if let tail = row.cwdTail {
                            Text("·").foregroundStyle(.quaternary)
                            Text(tail).foregroundStyle(.tertiary).lineLimit(1).truncationMode(.head)
                        }
                        if let origin = row.originLabel {
                            // Provenance, kept quiet: where the session was
                            // launched from, trailing so it yields first.
                            Text("·").foregroundStyle(.quaternary)
                            Text("via \(origin)").foregroundStyle(.tertiary).lineLimit(1).truncationMode(.tail)
                        }
                    }
                    .font(JRBarTokens.TypeStyle.caption.font)
                }
                // The label column runs to the trailing column whatever the
                // title's length, so every hairline's track is the same and
                // one row's fraction reads against another's.
                .frame(maxWidth: .infinity, alignment: .leading)
                .overlay(alignment: .bottomLeading) {
                    // How full the run's context window is: a hairline under
                    // the words, below the text so nothing moves when it
                    // arrives. Only a live run's context is worth a mark.
                    if let fraction = row.liveContextFraction {
                        ContextHairline(fraction: fraction, accent: row.style.accent)
                            .offset(y: 5)
                    }
                }
                Spacer(minLength: 6)
                VStack(alignment: .trailing, spacing: 1) {
                    HStack(spacing: 5) {
                        Text(row.activity.word)
                            .font(JRBarTokens.TypeStyle.caption.font)
                            .foregroundStyle(Self.wordColor(row.activity))
                            .lineLimit(1)
                            .contentTransition(.opacity)
                        SessionRowMark(activity: row.activity, agentActivity: row.agentActivity, accent: row.style.accent,
                                       reduced: store.reduceMotion, active: store.marksMove, quiet: row.isQuiet(now: store.now))
                    }
                    Text(row.elapsedText(now: store.now) ?? " ")
                        .font(JRBarTokens.TypeStyle.caption.font).monospacedDigit()
                        .foregroundStyle(row.isQuiet(now: store.now) ? AnyShapeStyle(SessionRowView.quietTint) : AnyShapeStyle(.tertiary))
                        .lineLimit(1)
                }
                .frame(width: trailingWidth, alignment: .trailing)
            }
        }
        .animation(PanelMotion.crossfade(reduced: store.reduceMotion, armed: store.animationsArmed), value: row.activity)
        // A keyboard pick gets an accent stroke on top of the fill; a
        // pointer pick keeps the fill alone.
        .overlay {
            if store.selectionByKeyboard, store.selectedID == row.id {
                RoundedRectangle(cornerRadius: JRBarTokens.Radius.control, style: .continuous)
                    .inset(by: 1)
                    .strokeBorder(Color.accentColor.opacity(0.55), lineWidth: 1)
                    .padding(.horizontal, 6)
                    .allowsHitTesting(false)
            }
        }
        .help(row.help(now: store.now) ?? "")
        .onHover { hovering = $0 }
        .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { contextFrame = $0 }
        .contextMenu { SessionContextMenu(row: row, store: store, anchor: contextFrame) }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(spokenLabel)
        .accessibilityActions {
            if row.canWatchForDone || store.isWatchedForDone(row) {
                Button(DoneBell.actionName(watched: store.isWatchedForDone(row))) { store.toggleDoneWatch(row) }
            }
        }
        .accessibilityHint(row.isRemote
            ? "Remote session — manage it on \(row.remoteMachine ?? "the machine it runs on")"
            : "Opens the session in its terminal")
        .accessibilityAddTraits(.isButton)
    }

    /// "sidepulse, 10 workers, Claude, Working, 4m, in sidepulse": the
    /// worker count said in words, never a bare number after the name.
    private var spokenLabel: String {
        let elapsed: String = PanelStore.elapsed(since: row.since, now: store.now) ?? "just started"
        let place: String = row.isRemote
            ? "on \(row.remoteMachine ?? "a peer")"
            : (row.cwdTail.map { "in \($0)" } ?? "no folder on record")
        let quiet: String? = row.isQuiet(now: store.now) ? "no signal for \(elapsed)" : nil
        let parts: [String?] = [row.label, row.workersText, row.workersWaitingText, row.style.name,
                                row.activity.word, quiet ?? elapsed, place,
                                store.isWatchedForDone(row) ? DoneBell.spokenState : nil]
        return parts.compactMap { $0 }.joined(separator: ", ")
    }
}

/// "Tell me when this finishes": the bell on a working row. Quiet until
/// the pointer or the keyboard is on the row, filled and always shown once
/// it is on, so a row you asked about never loses its mark. It banners that
/// one run's ending whatever the completion setting says, then turns itself
/// off. The room for it is kept either way, so nothing shifts on hover.
struct DoneBell: View {
    let watched: Bool
    let revealed: Bool
    let toggle: () -> Void

    static let spokenState = "will notify when done"

    static func actionName(watched: Bool) -> String {
        watched ? "Stop notifying when done" : "Notify when done"
    }

    static func help(watched: Bool) -> String {
        watched ? "You'll get a banner when this run ends. Click to cancel"
                : "Get one banner when this run ends"
    }

    private var shown: Bool { watched || revealed }

    var body: some View {
        Button(action: toggle) {
            Image(systemName: watched ? "bell.fill" : "bell")
                .font(JRBarTokens.TypeStyle.caption.font)
                // Never the accent: a red accent would read as a failure.
                .foregroundStyle(watched ? AnyShapeStyle(.primary) : AnyShapeStyle(.secondary))
                .frame(width: 14, height: 14)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .opacity(shown ? 1 : 0)
        .allowsHitTesting(shown)
        .help(Self.help(watched: watched))
        .accessibilityLabel(Self.actionName(watched: watched))
        .accessibilityValue(watched ? "on" : "off")
        .accessibilityHidden(!shown)
    }
}

/// The right-click menu both row types share: answer an open ask, open the
/// session in its own terminal, snooze the family while it is waiting (or
/// lift a snooze that is on), copy or reveal the working directory, clear
/// a finished row. A remote row gets none of the local verbs — it has no
/// window here to open and no local path to copy.
struct SessionContextMenu: View {
    let row: SessionRow
    @Bindable var store: PanelStore
    let anchor: CGRect

    /// Which of an ask's verbs the menu offers: `AskVerbs`' rule, the one
    /// every other surface reads. An ask JR-Bar already answered offers
    /// none, whatever an older daemon still says about it, and a held
    /// question offers its options and Deny, never a bare Approve.
    struct AskMenuVerbs: Equatable {
        var choose = false
        var approve = false
        var alwaysAllow = false
        var deny = false

        var any: Bool { choose || approve || alwaysAllow || deny }
    }

    static func askVerbs(_ ask: CoreAsk, at now: Date = Date()) -> AskMenuVerbs {
        AskMenuVerbs(choose: AskVerbs.chooses(ask, at: now),
                     approve: AskVerbs.approves(ask),
                     alwaysAllow: AskVerbs.alwaysAllows(ask, at: now),
                     deny: AskVerbs.denies(ask, at: now))
    }

    var body: some View {
        if store.lightExplanation != nil {
            Button("Why this light") {
                store.whyRowFrame = anchor
                store.whyHover(true, frame: anchor)
            }
            Divider()
        }
        if row.isRemote {
            Text(row.remoteMachine.map { "Runs on \($0)" } ?? "Runs on a peer Mac")
            if let host = store.screenSharingHost(for: row) {
                // Reaching the peer is the local verb a remote row can
                // have: Screen Sharing to it — nothing runs on the peer.
                Button("Open Screen Sharing to \(row.remoteMachine ?? host)") { store.openScreenSharing(host: host) }
            }
            if row.activity.isClearable || row.stale {
                Divider()
                Button("Clear") { store.clear(row) }
            }
        } else {
            // The card's buttons, also on the menu — behind the daemon's
            // own answerability gate, never an offer it would refuse.
            if let ask = row.ask, ask.session != nil {
                let verbs = Self.askVerbs(ask)
                if verbs.choose {
                    Menu(AskChoiceLayout.menuTitle(ask.decision?.choices ?? [], picks: store.picks(for: ask))) {
                        AskChoiceMenuItems(choices: ask.decision?.choices ?? [], picks: store.picks(for: ask),
                                           pick: { store.pick($0, in: $1, of: ask) },
                                           send: { store.sendPicks(ask) })
                    }
                }
                if verbs.approve { Button("Approve") { store.approve(ask) } }
                if verbs.alwaysAllow { Button("Always Allow") { store.alwaysAllow(ask) } }
                if verbs.deny { Button("Deny") { store.deny(ask) } }
                if verbs.any { Divider() }
            }
            Button(row.terminalApp.map { "Open in \($0)" } ?? "Open session") { store.open(row) }
            if !row.activity.isClearable, row.activity != .failed {
                // One banner when this run ends — without turning
                // completion banners on for every run and sub-agent.
                Button(store.isWatchedForDone(row) ? "Stop Notifying When Done" : "Notify When Done") {
                    store.toggleDoneWatch(row)
                }
            }
            if row.isSnoozed(now: store.now) {
                Button("Unsnooze") { store.snooze(row, seconds: 0) }
            } else if row.ask != nil || row.activity == .waiting {
                // Snooze quiets the session's whole family at the mailbox;
                // the daemon resolves the work key from the session id.
                Button("Snooze 15 minutes") { store.snooze(row, seconds: 900) }
                Button("Snooze 1 hour") { store.snooze(row, seconds: 3600) }
                Button(PanelStore.morningLabel(verb: "Snooze until", target: store.morningTarget)) {
                    store.snooze(row, seconds: PanelStore.secondsUntilMorning())
                }
            } else if PanelStore.canQuietRun(row) {
                // A run you have already seen stops claiming the light and
                // the banners; the daemon lets a real ask through anyway,
                // so it still reaches you the moment it needs you.
                Menu("Quiet This Run") {
                    Button("For 15 Minutes") { store.quietRun(row, seconds: 900) }
                    Button("For 1 Hour") { store.quietRun(row, seconds: 3600) }
                    Button(PanelStore.morningLabel(verb: "Until", target: store.morningTarget)) {
                        store.quietRun(row, seconds: PanelStore.secondsUntilMorning())
                    }
                }
                .help("Its lights and banners go quiet; an ask still gets through")
            }
            if let cwd = row.cwd, !cwd.isEmpty {
                Divider()
                Button("Copy Path") { store.copyPath(row) }
                Button("Reveal in Finder") { store.reveal(row) }
            }
            if row.activity.isClearable || row.stale {
                Divider()
                Button("Clear") { store.clear(row) }
            }
            if row.isDismissible {
                // Hide until it next speaks — for the row that is alive
                // and going nowhere; a row an open ask pins never gets it.
                Divider()
                Button("Dismiss") { store.dismiss(row) }
            }
        }
    }
}

/// The ask card's plate: an amber wash that is warmest along its top
/// edge, and an amber hairline. Stronger while the card is the
/// selection; greyed out while the family is snoozed.
struct AskCardPlate: View {
    let selected: Bool
    var quiet = false
    /// The Try it ask wears violet, never the asks' amber.
    var demo = false

    static let radius = JRBarTokens.Radius.group

    private var tint: Color {
        if demo { return DemoAskLook.tint }
        return quiet ? .secondary : SessionActivity.waiting.tint
    }
    private var top: Color { tint.opacity(selected ? 0.20 : 0.13) }
    private var bottom: Color { tint.opacity(selected ? 0.12 : 0.06) }

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: Self.radius, style: .continuous)
        shape
            .fill(LinearGradient(colors: [top, bottom], startPoint: .top, endPoint: .bottom))
            .overlay(shape.strokeBorder(LinearGradient(colors: [tint.opacity(0.38), tint.opacity(0.16)],
                                                       startPoint: .top, endPoint: .bottom),
                                        lineWidth: 0.75))
    }
}

struct AskRow: View {
    let row: SessionRow
    @Bindable var store: PanelStore
    var detailHeight: CGFloat = CGFloat(PanelLayout.askDetailHeight)
    @ViewState private var contextFrame = CGRect.zero
    /// The reply draft rides the store: a half-typed answer survives the
    /// panel closing and a relaunch, and a refused send keeps the text.
    private var replyText: Binding<String> {
        Binding(
            get: { self.row.ask.map { self.store.replyDraft(for: $0) } ?? "" },
            set: { text in if let ask = self.row.ask { self.store.setReplyDraft(text, for: ask) } }
        )
    }

    @Environment(\.renderSnapshot) private var snapshot

    /// The whole card goes quiet while the family mailbox is snoozed —
    /// dim, still, and stamped "snoozed until", never dressed as a fresh ask.
    private var snoozed: Bool { row.isSnoozed(now: store.now) }

    /// The person opened this ask's chevron: its command, plan or edit
    /// summary sits under the question, and the card is that much taller
    /// (`PanelLayout.askDetailHeight`).
    private var showsDetail: Bool { AskExpansion.shared.isShowing(row.ask) }

    /// The Try it ask: violet, labelled "Demo", answering nothing.
    private var isDemo: Bool { row.ask?.isDemo == true }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .top, spacing: 9) {
                ProviderTile(style: row.style)
                VStack(alignment: .leading, spacing: 2) {
                    titleLine
                    question
                }
                Spacer(minLength: 6)
                VStack(alignment: .trailing, spacing: 1) {
                    AskWaitMark(since: store.answerPendingSince(row.ask), accent: row.style.accent,
                                reduced: store.reduceMotion, active: store.marksMove && !snoozed)
                        .padding(.top, 3)
                    Text(ageText)
                        .font(JRBarTokens.TypeStyle.caption.font).monospacedDigit().foregroundStyle(.tertiary).lineLimit(1)
                }
            }
            if showsDetail, let ask = row.ask {
                AskDetailView(ask: ask, height: detailHeight - 6,
                              onOpenSession: row.isRemote || ask.session == nil ? nil : { store.open(row) })
            }
            verbRow
        }
        .opacity(snoozed ? 0.55 : 1)
        .padding(.horizontal, 8)
        .frame(height: CGFloat(PanelLayout.askRowHeight) + (showsDetail ? detailHeight : 0))
        .background(AskCardPlate(selected: store.selectedID == row.id, quiet: snoozed, demo: isDemo))
        .overlay(
            RoundedRectangle(cornerRadius: AskCardPlate.radius, style: .continuous)
                .inset(by: 1)
                .strokeBorder(Color.accentColor.opacity(0.55), lineWidth: 1)
                .opacity(store.selectionByKeyboard && store.selectedID == row.id ? 1 : 0)
        )
        // An answer on the wire past three seconds: a beam round this
        // card while the panel is open, display only (`askBeamSince`).
        .waitBeam(since: store.askBeamSince(row.ask), track: .ring(cornerRadius: AskCardPlate.radius),
                  tint: SessionActivity.waiting.tint)
        .padding(.horizontal, 6)
        .contentShape(Rectangle())
        .onTapGesture { store.open(row) }
        .help(row.help(now: store.now) ?? "")
        .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { contextFrame = $0 }
        .contextMenu {
            if isDemo {
                Button("Put the Demo Away") { store.dismissDemo() }
            } else {
                SessionContextMenu(row: row, store: store, anchor: contextFrame)
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(accessibilityLabel)
        .accessibilityHint(accessibilityHint)
    }

    /// What VoiceOver reads for the row: who asks, what, the command it
    /// would run and whether it is destructive. Built apart from the
    /// modifier chain — inline, the concatenation of optionals left a
    /// slower CI runner's type checker timing out on the whole body.
    private var accessibilityLabel: String {
        var label = "\(isDemo ? "Demo, not a real ask," : row.label) asks: \(row.ask?.summary ?? "")"
        if let stale = row.ask?.staleLine(now: store.now) { label += ", \(stale)" }
        if let preview = row.ask?.previewLine { label += ", runs \(preview)" }
        if row.ask?.isDestructive == true { label += ", destructive" }
        if let detail = row.ask?.detail { label += ", \(AskDetailCopy.noun(detail)) available" }
        return label
    }

    /// Who asks and what kind of ask, the destructive mark, and the
    /// row's quiet states.
    private var titleLine: some View {
        HStack(spacing: 6) {
            Text(isDemo ? DemoAsk.label : "\(row.style.name) · \(row.cwdTail ?? row.label)").fontWeight(.medium).lineLimit(1).truncationMode(.tail)
            if isDemo {
                DemoAskBadge()
            } else {
                StatusBadge(row.ask?.kind?.replacingOccurrences(of: "_", with: " ").capitalized ?? "Ask", tone: .ask)
            }
            staleCapsule
            if row.ask?.isDestructive == true {
                AskRiskMark(size: 10)
            }
            if snoozed, let until = row.snoozedUntil {
                Text("snoozed until \(PanelStore.clockTime(Date(timeIntervalSince1970: until)))")
                    .font(JRBarTokens.TypeStyle.caption.font).foregroundStyle(.tertiary).lineLimit(1)
            } else if snoozed {
                Text("snoozed").font(JRBarTokens.TypeStyle.caption.font).foregroundStyle(.tertiary).lineLimit(1)
            }
            if let quiet = store.quietFeedText(for: row) {
                // Same once-per-provider marker as the plain
                // rows: an ask can be the provider's topmost
                // live row.
                Text(quiet).font(JRBarTokens.TypeStyle.caption.font).foregroundStyle(.tertiary).lineLimit(1)
                    .help("\(row.style.name)'s hook feed has not delivered — this row may be behind")
            }
        }
    }

    /// The question, and under it what would run — a line each when
    /// there is a preview, so the card keeps its height.
    private var question: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(row.ask?.summary ?? "Needs your answer")
                .font(JRBarTokens.TypeStyle.callout.font)
                .foregroundStyle(.secondary)
                .lineLimit(row.ask?.previewLine == nil && row.ask?.hasDetail != true ? 2 : 1)
            if let preview = row.ask?.previewLine, let ask = row.ask {
                HStack(spacing: 2) {
                    AskPreviewLine(text: preview, size: 10.5,
                                   tint: ask.isDestructive ? Tone.failure.color.opacity(0.9) : Color.primary.opacity(0.75),
                                   well: true)
                    AskDetailToggle(ask: ask)
                }
            } else if let ask = row.ask, ask.hasDetail {
                AskDetailToggle(ask: ask, labelled: true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .frame(height: 32, alignment: .topLeading)
    }

    /// When the hook's hold on this ask lapses: the verbs are drawn again
    /// at that moment, not a clock tick later, so Always and the choices
    /// leave with the hold.
    private var holdEnd: Date? { row.ask.flatMap { AskHold.end($0, at: store.now) } }

    /// The card's verbs, re-drawn once more at the hold's end. A render
    /// proof's still is taken at the store's clock, not the timeline's.
    /// The schedule is framed (`ExplicitTimeline`): a lone future date
    /// drew the verbs as of the hold's end from the first frame, and
    /// never fired.
    private var verbRow: some View {
        TimelineView(.explicit(ExplicitTimeline.moments(holdEnd.map { [$0] } ?? []))) { context in
            verbs(now: snapshot ? store.now : max(store.now, context.date))
        }
    }

    /// The card's verbs: a reply field, a held question's options, or
    /// Deny · Always Allow · Approve — each only where the daemon says
    /// it can land — else the honest way to the session's own window. An
    /// ask JR-Bar already answered says it is waiting for the agent and
    /// draws no verb. A held ask's verbs sit beside a ring draining with
    /// its hold.
    private func verbs(now: Date) -> some View {
        HStack(spacing: 6) {
            Spacer()
            staleDismiss
            if let ask = row.ask, !row.isRemote, let left = AskHold.remaining(ask, at: now) {
                AskHoldRing(fraction: left, reduced: store.reduceMotion)
                    .help(AskHold.help(ask, at: now) ?? "")
                    .accessibilityLabel(AskHold.help(ask, at: now) ?? "")
            }
            if let ask = row.ask, ask.session != nil, !row.isRemote, let line = ask.decidedLine {
                // Answered from JR-Bar, and the agent's own events have not
                // closed the request: the approved tool may still be
                // running. The daemon takes the verbs away
                // (`answerable: false`); the words say what is going on
                // instead of sending the person to the session's window,
                // and this comes first so no verb is drawn for it whatever
                // else the ask says.
                Text(line)
                    .font(JRBarTokens.TypeStyle.caption.font).foregroundStyle(.tertiary).lineLimit(1)
                    .help("JR-Bar sent the answer through \(row.style.name)'s own permission hook; the agent has not moved on yet")
            } else if let ask = row.ask, ask.wantsTextReply, ask.canAnswer, ask.session != nil, !row.isRemote {
                // A reply-kind ask wants words, not a verdict: a field
                // and Send; `reply_text` rides the same answer_ask. A
                // daemon that cannot take text for it says so, and the
                // toast carries that.
                TextField("Reply…", text: replyText)
                    .textFieldStyle(.plain)
                    .font(JRBarTokens.TypeStyle.callout.font)
                    .padding(.horizontal, 9).padding(.vertical, 3.5)
                    .background(Capsule().fill(Color.primary.opacity(0.08)))
                    .overlay(Capsule().strokeBorder(Color.primary.opacity(0.10), lineWidth: 0.5))
                    .frame(maxWidth: 200)
                    .disabled(store.isAnswerPending(ask))
                    .onSubmit { send(ask) }
                ActionButton("Send", prominent: true) { send(ask) }
                    .disabled(replyText.wrappedValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || store.isAnswerPending(ask))
                    .help("Type this reply into \(row.terminalApp ?? "the session's terminal")")
            } else if let ask = row.ask, ask.session != nil, !row.isRemote, AskVerbs.chooses(ask, at: now) {
                // A held question: its options are the answer, sent
                // through the agent's own hook — Deny declines it.
                ActionButton("Deny ⌘D") { store.deny(ask) }
                    .disabled(store.isAnswerPending(ask))
                    .help("Decline the question (⌘D)")
                AskRowChoices(ask: ask, store: store)
            } else if let ask = row.ask, ask.canAnswer, !ask.wantsTextReply, ask.session != nil, !row.isRemote {
                // Approve/Deny go through the agent's permission hook
                // when it holds the ask, else type the answer into the
                // session's own terminal (the daemon raises it first);
                // the refusal — not a guess — is what the toast then
                // shows. All go quiet while the answer is on the wire
                // so a double click cannot post twice.
                ActionButton("Deny ⌘D") { store.deny(ask) }
                    .disabled(store.isAnswerPending(ask))
                    .help("Answer no (⌘D)")
                if AskVerbs.alwaysAllows(ask, at: now) {
                    // Its own button, never a chord: the agent will
                    // remember this rule and stop asking.
                    ActionButton("Always Allow") { store.alwaysAllow(ask) }
                        .disabled(store.isAnswerPending(ask))
                        .help("Approve, and let \(row.style.name) remember the rule it offered")
                }
                ActionButton("Approve ⌘↩", prominent: true) { store.approve(ask) }
                    .disabled(store.isAnswerPending(ask))
                    .help(approveHelp(ask, now: now))
            } else if row.isRemote {
                // A peer's ask: nothing local can type into it.
                Text("on \(row.remoteMachine ?? "a peer")")
                    .font(JRBarTokens.TypeStyle.caption.font).foregroundStyle(.tertiary).lineLimit(1)
            } else if row.ask?.session != nil {
                // Not answerable from the panel (the daemon said so, or
                // it wants a reply this core will not take): a view-only
                // agent, or a host that cannot prove its focused tab. Say
                // where to answer, plainly, and open that app. No verb is
                // drawn for what no daemon could deliver.
                Text(AskAnswerHost.line(host: row.answerHost))
                    .font(JRBarTokens.TypeStyle.caption.font).foregroundStyle(.secondary).lineLimit(1)
                    .truncationMode(.tail)
                ActionButton(AskAnswerHost.buttonTitle(host: row.answerHost)) { store.open(row) }

                    .help(row.ask?.wantsTextReply == true
                          ? "This ask wants a typed reply — answer it in the session's window"
                          : "The panel cannot answer this one — answer it in the session's window")
            } else {
                // No session left to open or answer: just say so.
                Text("answer it in its own window")
                    .font(JRBarTokens.TypeStyle.caption.font).foregroundStyle(.tertiary).lineLimit(1)
            }
        }
    }

    /// "may be stale": a long-unanswered ask is still an ask, and says so
    /// beside its kind. The whole sentence with its age ("may be stale ·
    /// asked 9 hours ago") is the capsule's tooltip and the row's spoken
    /// label; the age in words is the column on the right.
    @ViewBuilder
    private var staleCapsule: some View {
        if row.ask?.isStale == true {
            StatusBadge("May be stale", tone: .stale)
                .help(staleHelp)
        }
    }

    /// The capsule's tooltip: the whole sentence with the ask's age.
    private var staleHelp: String {
        let sentence = row.ask?.staleLine(now: store.now) ?? "may be stale"
        return sentence + ". Nothing has been heard from this session for a long while, "
            + "so the ask may already be settled. It stays here until you answer it, "
            + "it ends, or you dismiss it."
    }

    /// The age column: a plain age normally, in words ("9 hours") once the
    /// ask may be stale.
    private var ageText: String {
        let opened = row.ask?.openedAt.map { Date(timeIntervalSince1970: $0) } ?? row.since
        if row.ask?.isStale == true, let opened {
            return CoreAsk.ageWords(store.now.timeIntervalSince(opened))
        }
        return PanelStore.elapsed(since: opened, now: store.now) ?? " "
    }

    /// One click to clear a stale ask from this Mac. Not an answer: the
    /// agent is told nothing.
    @ViewBuilder
    private var staleDismiss: some View {
        if isDemo {
            ActionButton("Put Away") { store.dismissDemo() }

                .help("Take the demo down. Nothing was ever sent to an agent.")
        } else if let ask = row.ask, ask.isDismissible, !row.isRemote {
            ActionButton("Dismiss") { store.dismissStaleAsk(ask) }

                .help("Hide this ask on this Mac. \(row.style.name) is not told anything and its own prompt is unchanged.")
        }
    }

    /// Approve's route: the agent's own hook while it holds the ask, else
    /// the terminal the daemon brings forward.
    private func approveHelp(_ ask: CoreAsk, now: Date) -> String {
        if ask.isHeld(at: now) { return "Approve through \(row.style.name)'s own permission hook (⌘↩)" }
        return "Bring \(row.terminalApp ?? "the terminal") forward and approve there (⌘↩)"
    }

    private var accessibilityHint: String {
        guard let ask = row.ask, !row.isRemote else { return "Answer it in the session's own window" }
        if let line = ask.decidedLine { return line }
        if AskVerbs.chooses(ask) { return "Pick one of its options, or deny with ⌘D" }
        return ask.canAnswer ? "Approve with ⌘Return, deny with ⌘D" : "Answer it in the session's own window"
    }

    private func send(_ ask: CoreAsk) {
        // No eager clear: the draft clears when the send confirms, so a
        // refused reply keeps its text.
        store.reply(ask, text: store.replyDraft(for: ask))
    }
}

/// A held question's options on the ask card: a pill each for one short
/// single-pick question — a click is the answer — else one menu that
/// holds every question, with Send once each has a pick.
struct AskRowChoices: View {
    let ask: CoreAsk
    @Bindable var store: PanelStore

    private var choices: [CoreAskChoice] { ask.decision?.choices ?? [] }

    var body: some View {
        switch AskChoiceLayout.layout(choices) {
        case .buttons(let labels):
            ForEach(Array(labels.enumerated()), id: \.offset) { index, label in
                ActionButton(label, prominent: index == 0) {
                    if let choice = choices.first { store.pick(label, in: choice, of: ask) }
                }
                .disabled(store.isAnswerPending(ask))
                .help("Answer “\(label)” through the agent's own hook")
            }
        case .menu:
            let picks = store.picks(for: ask)
            Menu(AskChoiceLayout.menuTitle(choices, picks: picks)) {
                AskChoiceMenuItems(choices: choices, picks: picks,
                                   pick: { store.pick($0, in: $1, of: ask) },
                                   send: { store.sendPicks(ask) })
            }
            .menuStyle(.button)
            .controlSize(.small)
            .fixedSize()
            .disabled(store.isAnswerPending(ask))
            .help(choices.count == 1 ? choices[0].question : "\(choices.count) questions — pick an answer for each")
            if picks.isComplete(choices), choices.count > 1 || choices.first?.multi == true {
                ActionButton("Send", prominent: true) { store.sendPicks(ask) }
                    .disabled(store.isAnswerPending(ask))
            }
        }
    }
}

/// The panel's buttons: a quiet capsule, or — for the one verb that
/// answers yes — a filled amber one with a little depth. Both brighten
/// under the pointer and fade while they cannot be clicked.
// MARK: - Context

struct ContextHairline: View {
    let fraction: Double
    let accent: Color

    static let height: CGFloat = 1.5

    nonisolated static func level(_ fraction: Double) -> ContextLevel {
        if fraction >= 0.95 { return .critical }
        if fraction >= 0.80 { return .warning }
        return .calm
    }

    enum ContextLevel { case calm, warning, critical }

    private var fill: Color {
        switch Self.level(fraction) {
        case .critical: return Tone.failure.color
        case .warning: return Tone.neutral.color
        case .calm: return accent.opacity(0.55)
        }
    }

    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .leading) {
                Capsule().fill(Color.primary.opacity(0.06))
                Capsule().fill(fill)
                    .frame(width: max(2, proxy.size.width * CGFloat(min(1, max(0, fraction)))))
            }
        }
        .frame(height: Self.height)
        .accessibilityLabel("Context \(Int((fraction * 100).rounded())) percent full")
    }
}

// MARK: - Devices

struct PanelDevicesRow: View {
    @Bindable var store: PanelStore

    /// The daemon's `dot_link` word, when it sends one; the glyph between
    /// the Pro and Dot chips and the chips' help both read it.
    private var dotLink: CoreDotLink? { store.core.lights?.dotLink }

    /// The pair's glyph, shown between the Pro and Dot chips only when the
    /// link is a fact (`linked`) or a problem (`failed`); the four other
    /// states draw nothing between the chips.
    private var linkGlyph: (name: String, style: AnyShapeStyle)? {
        switch dotLink?.state {
        case "linked": return ("link", AnyShapeStyle(.tertiary))
        case "failed": return ("exclamationmark.triangle", AnyShapeStyle(Tone.failure.color))
        default: return nil
        }
    }

    /// `state` is the word VoiceOver says after the name: "connected" for
    /// hardware, "shown"/"hidden"/"not reported" for the Screen Bar chip,
    /// which announces visibility rather than connectivity.
    var chips: [(id: String, name: String, present: Bool, help: String, state: String?)] {
        var result: [(String, String, Bool, String, String?)] = []
        let bar = store.devices.first { $0.kind == "screen_bar" }
        let pairNote: String? = switch dotLink?.state {
        case "linked": "linked as one"
        case "no_strip": "Dot has nothing to extend"
        case "failed": dotLink?.error.map { "linked write failed: \($0)" } ?? "linked write failed"
        default: nil
        }
        for (kind, name, fullName) in [("pro", "Pro", "SidePulse Pro"), ("dot", "Dot", "PulseDot")] {
            let state = store.deviceConnection(kind: kind)
            var parts = [state.help(name: fullName)]
            if state.isConnected, let device = store.devices.first(where: { $0.kind == kind }) {
                if let leds = device.leds { parts.append("\(leds) LEDs") }
                if let error = device.error, !error.isEmpty { parts.append(error) }
                if let pairNote { parts.append(pairNote) }
            }
            parts.append("click for Devices settings")
            let help = parts.joined(separator: " · ")
            result.append((kind, name, state.isConnected, help, state.rawValue))
        }
        // The band is the app's own chrome: no device row means the state
        // is unknown, not "connected".
        let barShown = store.screenBarShown && (bar?.isPresent == true)
        var barHelp = (bar == nil ? "Screen Bar not reported"
                       : (barShown ? "Screen Bar shown under the notch" : "Screen Bar hidden"))
            + (barShown ? " · click to hide" : " · click to show")
        if store.core.lights?.linked == true, store.core.lights?.hardware != nil {
            barHelp += " · in step with the strip"
        }
        result.append(("screen_bar", "Screen Bar", barShown, barHelp, bar == nil ? "not reported" : (barShown ? "shown" : "hidden")))
        return result.map { (id: $0.0, name: $0.1, present: $0.2, help: $0.3, state: $0.4) }
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 6) {
                ForEach(chips, id: \.id) { chip in
                    if chip.id == "dot", let glyph = linkGlyph {
                        Image(systemName: glyph.name)
                            .font(JRBarTokens.TypeStyle.caption.font)
                            .foregroundStyle(glyph.style)
                            .accessibilityHidden(true)
                    }
                    DeviceChip(name: chip.name, present: chip.present, dimmed: !store.isLive && chip.id != "screen_bar",
                               state: chip.state, action: chip.id == "screen_bar" ? "toggles the band" : "opens Devices settings")
                        .help(chip.help)
                        .onTapGesture {
                            if chip.id == "screen_bar" {
                                store.toggleScreenBar()
                            } else {
                                // Pro and Dot chips open their page.
                                store.openSettings(page: .devices)
                            }
                        }
                }
                Spacer()
            }
            .padding(.horizontal, JRBarTokens.Space.md)
            .frame(height: PanelComposition.sectionHeight)
            HStack(spacing: 8) {
                // The bar is a brightness target too — with no strip
                // attached this slider still dims it (`set_brightness
                // "all"` reaches the virtual device), so "no hardware"
                // is not a reason to grey it out.
                let hasTarget = store.hasHardware
                    || store.devices.contains { $0.kind == "screen_bar" && $0.isPresent }
                Text("Devices").font(JRBarTokens.TypeStyle.section.font).foregroundStyle(JRBarTokens.Ink.secondary)
                Slider(value: Binding(
                    get: { store.brightness },
                    set: { store.setBrightness($0, final: false) }
                ), in: 0...1) { editing in
                    if !editing { store.setBrightness(store.brightness, final: true) }
                }
                .controlSize(.mini)
                .disabled(!store.isLive || !hasTarget)
                .accessibilityLabel("Brightness")
                .accessibilityValue(brightnessWords)
                Image(systemName: "sun.max").font(JRBarTokens.TypeStyle.caption.font).foregroundStyle(.tertiary)
                Text(store.brightnessIsMixed ? "Mixed" : "\(Int((store.brightness * 100).rounded()))%")
                    .font(JRBarTokens.TypeStyle.caption.font).monospacedDigit().foregroundStyle(.secondary).lineLimit(1)
                    .frame(width: 38, alignment: .trailing)
                    .contentTransition(.numericText())
            }
            .padding(.horizontal, JRBarTokens.Space.md)
            .frame(height: PanelComposition.sectionHeight)
            .padding(.bottom, JRBarTokens.Space.sm)
            .help(brightnessHelp)
        }
        .frame(height: PanelComposition.sectionHeight * 2 + JRBarTokens.Space.sm, alignment: .top)
        .clipped()
    }

    /// One brightness story: while the devices disagree the tooltip
    /// names each, and says the slider sets them all.
    private var brightnessHelp: String {
        guard store.isLive else { return "Brightness needs the monitor" }
        if store.brightnessIsMixed { return "\(store.brightnessBreakdown) — dragging sets them all" }
        return store.hasHardware ? "Brightness — strip, Dot and Screen Bar" : "Screen Bar brightness — no strip connected"
    }

    private var brightnessWords: String {
        store.brightnessIsMixed ? "Mixed: \(store.brightnessBreakdown)" : "\(Int((store.brightness * 100).rounded())) percent"
    }
}

struct DeviceChip: View {
    let name: String
    let present: Bool
    let dimmed: Bool
    /// The word VoiceOver says after the name; hardware chips get
    /// "connected"/"not connected", the Screen Bar chip passes its own.
    var state: String? = nil
    /// What a tap does, for VoiceOver ("opens Devices settings" /
    /// "toggles the band" for the Screen Bar chip).
    var action: String? = nil

    var accessibilityText: String {
        "\(name) \(state ?? (present ? "connected" : "not connected"))" + (action.map { " · \($0)" } ?? "")
    }

    var body: some View {
        StatusBadge(name, tone: present ? .done : .neutral)
            .opacity(dimmed ? 0.55 : 1)
            .contentShape(Rectangle())
            .accessibilityLabel(accessibilityText)
            .accessibilityAddTraits(.isButton)
    }
}

// MARK: - Footer

/// The panel and status item share these commands.
struct PanelMoreMenuItems: View {
    @Bindable var store: PanelStore

    var body: some View {
        let sections = AppMenuCatalog.sections(creatorMicro: store.hasCreatorMicro)
        ForEach(Array(sections.enumerated()), id: \.offset) { index, verbs in
            if index > 0 { Divider() }
            ForEach(verbs) { verb in
                PanelMoreMenuItem(verb: verb, store: store)
            }
        }
    }
}

struct PanelMoreMenuItem: View {
    let verb: AppMenuVerb
    @Bindable var store: PanelStore

    var body: some View {
        if let shortcut = verb.shortcut {
            Button(verb.title) { store.perform(verb) }
                .keyboardShortcut(shortcut)
        } else {
            Button(verb.title) { store.perform(verb) }
        }
    }
}

struct ToastView: View {
    let text: String?
    /// An optional button inside the capsule (the refused-answer "Open
    /// Settings"); when set, the toast takes clicks for it.
    var action: (title: String, run: () -> Void)? = nil
    let reduced: Bool
    var armed: Bool = true

    /// A capsule on one line, a soft card when the message wraps.
    static let cornerRadius = JRBarTokens.Radius.group

    var body: some View {
        ZStack {
            if let text {
                HStack(spacing: 8) {
                    Text(text)
                        .font(JRBarTokens.TypeStyle.caption.font)
                        .foregroundStyle(.primary)
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                    if let action {
                        Button(action.title) { action.run() }
                            .buttonStyle(.plain)
                            .font(JRBarTokens.TypeStyle.caption.font)
                            .foregroundStyle(Color.accentColor)
                            .lineLimit(1)
                            .fixedSize()
                    }
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .background(RoundedRectangle(cornerRadius: Self.cornerRadius, style: .continuous).fill(.regularMaterial))
                .background(RoundedRectangle(cornerRadius: Self.cornerRadius, style: .continuous)
                    .fill(Color(nsColor: .windowBackgroundColor).opacity(0.96)))
                .overlay(RoundedRectangle(cornerRadius: Self.cornerRadius, style: .continuous)
                    .strokeBorder(.primary.opacity(0.10), lineWidth: 0.5))
                .padding(.horizontal, 14)
                .padding(.bottom, 40)
                .transition(reduced ? .opacity : .opacity.combined(with: .offset(y: 6)))
                .id(text)
            }
        }
        .animation(PanelMotion.contents(reduced: reduced, armed: armed), value: text)
        // The toast is the only report of an Approve, a refusal or a failed
        // clear; VoiceOver hears it said, since nothing moves focus to it.
        .onChange(of: text) {
            if let text { AccessibilityNotification.Announcement(text).post() }
        }
        // Click-through unless a button is on the capsule to click.
        .allowsHitTesting(action != nil)
    }
}
