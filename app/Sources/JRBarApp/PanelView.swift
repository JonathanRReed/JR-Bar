import JRBarCore
import SwiftUI

/// The Raycast-style panel under the status item. 360 pt wide, 13 pt type,
/// sections separated by hairlines rather than boxes, colour only where it
/// carries meaning (provider tiles, state dots, quota bars).
///
/// Geometry is `PanelLayout`'s: every row is a fixed height, every label
/// one line, the two lists scroll inside computed viewports, and the tree
/// is exactly `layout.totalHeight` tall, so the window never has to be
/// re-measured after it opens.
struct PanelView: View {
    @Bindable var store: PanelStore

    static let width: CGFloat = CGFloat(PanelLayout.width)

    var body: some View {
        let layout = store.layout
        VStack(spacing: 0) {
            PanelHeader(store: store)
            Hairline()
            SessionsSection(store: store, layout: layout)
            Hairline()
            UsageSection(store: store, layout: layout)
            Hairline()
            DevicesSection(store: store)
            Hairline()
            PanelFooter(store: store)
        }
        .font(.system(size: 13))
        .frame(width: Self.width, height: CGFloat(layout.totalHeight), alignment: .top)
        .clipped()
        .overlay(alignment: .bottom) { ToastView(text: store.toast, action: store.toastAction, reduced: store.reduceMotion, armed: store.animationsArmed) }
        .onChange(of: layout) { _, newLayout in store.layoutDidChange(newLayout) }
    }
}

// MARK: - Shared atoms

struct Hairline: View {
    var body: some View {
        Rectangle().fill(.primary.opacity(0.08)).frame(height: CGFloat(PanelLayout.hairline))
    }
}

struct SectionLabel: View {
    let text: String
    var trailing: String? = nil
    /// An optional "Details ›" affordance on the right (the Usage Center).
    var detailTitle: String? = nil
    var onDetail: (() -> Void)? = nil

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(text)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.secondary)
                .tracking(0.2)
                .lineLimit(1)
            Spacer()
            if let trailing {
                Text(trailing).font(.system(size: 11)).foregroundStyle(.tertiary).monospacedDigit().lineLimit(1)
            }
            if let detailTitle, let onDetail {
                Button(action: onDetail) {
                    HStack(spacing: 2) {
                        Text(detailTitle)
                        Image(systemName: "chevron.right").font(.system(size: 8, weight: .bold))
                    }
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("\(detailTitle) (⌘U)")
            }
        }
        .padding(.horizontal, 14)
        .padding(.bottom, 4)
        .frame(height: CGFloat(PanelLayout.sectionLabelHeight), alignment: .bottom)
    }
}

/// A provider's tile: 22 pt rounded square in the accent with its glyph.
struct ProviderTile: View {
    let style: ProviderStyle
    var size: CGFloat = 22

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: size * 0.28, style: .continuous)
                .fill(style.accent.opacity(0.18))
            RoundedRectangle(cornerRadius: size * 0.28, style: .continuous)
                .strokeBorder(style.accent.opacity(0.35), lineWidth: 0.5)
            switch style.glyph {
            case .symbol(let name):
                Image(systemName: name)
                    .font(.system(size: size * 0.5, weight: .semibold))
                    .foregroundStyle(style.accent)
            case .text(let text):
                Text(text)
                    .font(.system(size: size * 0.56, weight: .semibold, design: .rounded))
                    .foregroundStyle(style.accent)
            }
        }
        .frame(width: size, height: size)
        .accessibilityLabel(style.name)
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
    @ViewState private var phase = false

    var body: some View {
        Group {
            switch activity {
            case .working:
                Circle().fill(accent)
                    .opacity(reduced ? 0.9 : (phase ? 1.0 : 0.35))
                    .scaleEffect(reduced ? 1 : (phase ? 1.0 : 0.85))
            case .waiting:
                ZStack {
                    Circle().fill(SessionActivity.waiting.tint.opacity(0.35))
                        .scaleEffect(reduced ? 1.4 : (phase ? 2.1 : 1.0))
                        .opacity(reduced ? 0.6 : (phase ? 0 : 0.8))
                    Circle().fill(SessionActivity.waiting.tint)
                }
            case .done:
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(SessionActivity.done.tint.opacity(0.9))
            case .ended:
                // The process went away without finishing anything: grey,
                // and deliberately not the green check a completion earns.
                Circle()
                    .strokeBorder(Color.secondary.opacity(0.55), lineWidth: 1.4)
            case .failed:
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(SessionActivity.failed.tint.opacity(0.9))
            case .idle:
                Circle().fill(.quaternary)
            }
        }
        .frame(width: 8, height: 8)
        .onAppear { animate() }
        .onChange(of: activity) { animate() }
        .onChange(of: reduced) { animate() }
        .onChange(of: active) { animate() }
        // The row's label already speaks the word; alone the mark would
        // be an unlabeled dot VoiceOver has to step over.
        .accessibilityHidden(true)
    }

    private func animate() {
        guard !reduced, active else { withAnimation(nil) { phase = false }; return }
        switch activity {
        case .working:
            phase = false
            withAnimation(.easeInOut(duration: 1.3).repeatForever(autoreverses: true)) { phase = true }
        case .waiting:
            phase = false
            withAnimation(.easeOut(duration: 1.4).repeatForever(autoreverses: false)) { phase = true }
        default:
            phase = false
        }
    }
}

struct CountBadge: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.system(size: 10, weight: .semibold))
            .monospacedDigit()
            .foregroundStyle(.secondary)
            .lineLimit(1)
            .padding(.horizontal, 5)
            .padding(.vertical, 1.5)
            .background(Capsule().fill(.primary.opacity(0.08)))
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
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(Color.primary.opacity(fill(pressed: configuration.isPressed)))
            )
            .contentShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
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

/// A list cut half a row from its end fades out over the last few points,
/// so the cut reads as "more below" rather than a torn row.
struct ScrollEdgeFade: ViewModifier {
    let active: Bool
    static let fade: CGFloat = 16

    func body(content: Content) -> some View {
        content.mask(
            VStack(spacing: 0) {
                Rectangle().fill(Color.black)
                if active {
                    LinearGradient(colors: [.black, .black.opacity(0)], startPoint: .top, endPoint: .bottom)
                        .frame(height: Self.fade)
                }
            }
        )
    }
}

// MARK: - Header

struct PanelHeader: View {
    @Bindable var store: PanelStore

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(store.headerWord)
                .font(.system(size: 15, weight: .semibold))
                .lineLimit(1)
                .contentTransition(.opacity)
                .id("word-\(store.headerWord)")
                .transition(.opacity)
            if store.coreCrashed {
                Text(store.coreCrashDetail)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(Color.red)
                    .lineLimit(1)
                Button("Restart") { store.restartCore() }
                    .buttonStyle(PillButtonStyle(prominent: false))
                    .help("Launch the monitor again")
            } else {
                Text(store.headerCounts)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .contentTransition(.numericText())
            }
            Spacer(minLength: 8)
            if let quietLabel = store.quietLabel {
                // `state.focus` says a quiet is in effect: the moon so it
                // is visible at a glance, the label on hover for the
                // countdown. "Quiet…" in the footer says the same words.
                Image(systemName: "moon.zzz.fill")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                    .help(quietLabel)
                    .accessibilityLabel("Quiet: \(quietLabel)")
            }
            ConnectionDot(state: store.coreCrashed ? .crashed : store.connectionDot, reduced: store.reduceMotion, active: store.isOpen)
                .help(store.connectionDescription)
        }
        .padding(.horizontal, 14)
        .padding(.top, 2)
        .frame(height: CGFloat(PanelLayout.headerHeight))
        .animation(PanelMotion.crossfade(reduced: store.reduceMotion, armed: store.animationsArmed), value: store.headerWord)
        .animation(PanelMotion.crossfade(reduced: store.reduceMotion, armed: store.animationsArmed), value: store.headerCounts)
        .animation(PanelMotion.crossfade(reduced: store.reduceMotion, armed: store.animationsArmed), value: store.coreCrashed)
    }
}

struct ConnectionDot: View {
    let state: PanelStore.ConnectionDot
    let reduced: Bool
    var active: Bool = true
    @ViewState private var phase = false

    private var color: Color {
        switch state {
        case .live: return .green
        case .connecting: return .orange
        case .fileFeeds: return Color.secondary.opacity(0.5)
        case .crashed: return .red
        }
    }

    var body: some View {
        Circle()
            .fill(color)
            .frame(width: 6, height: 6)
            .opacity(state == .connecting && !reduced ? (phase ? 1 : 0.3) : 1)
            .onAppear { pulse() }
            .onChange(of: state) { pulse() }
            .onChange(of: active) { pulse() }
            .accessibilityLabel(state == .live ? "Monitor connected" : (state == .connecting ? "Connecting to the monitor" : (state == .crashed ? "Monitor crashed" : "Using file feeds")))
    }

    private func pulse() {
        withAnimation(nil) { phase = false }
        guard state == .connecting, !reduced, active else { return }
        withAnimation(.easeInOut(duration: 0.9).repeatForever(autoreverses: true)) { phase = true }
    }
}

// MARK: - Sessions

struct SessionsSection: View {
    @Bindable var store: PanelStore
    let layout: PanelLayout

    var body: some View {
        VStack(spacing: 0) {
            SectionLabel(text: "Sessions", trailing: sessionsTrailing)
            if store.visibleRows.isEmpty {
                SessionsEmptyState(store: store)
            } else {
                ScrollView(.vertical) {
                    VStack(spacing: CGFloat(PanelLayout.rowSpacing)) {
                        ForEach(store.visibleAskRows) { row in
                            AskRow(row: row, store: store)
                                .transition(PanelMotion.rowTransition(reduced: store.reduceMotion))
                        }
                        ForEach(store.visiblePlainRows) { row in
                            SessionRowView(row: row, store: store)
                                .transition(PanelMotion.rowTransition(reduced: store.reduceMotion))
                        }
                    }
                    .padding(.bottom, CGFloat(PanelLayout.listBottomPadding))
                    .animation(PanelMotion.contents(reduced: store.reduceMotion, armed: store.animationsArmed), value: store.visibleRows.map(\.id))
                }
                .scrollBounceBehavior(.basedOnSize)
                .frame(height: CGFloat(layout.sessionsHeight))
                .clipped()
                .modifier(ScrollEdgeFade(active: layout.sessionsScroll))
            }
            if store.hiddenCount > 0 {
                HiddenSessionsRow(store: store)
                    .transition(PanelMotion.rowTransition(reduced: store.reduceMotion))
            }
            if let explanation = store.lightExplanation {
                WhyLightRow(explanation: explanation, store: store)
                    .transition(PanelMotion.rowTransition(reduced: store.reduceMotion))
            }
        }
        .padding(.bottom, CGFloat(PanelLayout.sessionsBottomPadding))
        .animation(PanelMotion.contents(reduced: store.reduceMotion, armed: store.animationsArmed), value: store.lightExplanation == nil)
        .animation(PanelMotion.contents(reduced: store.reduceMotion, armed: store.animationsArmed), value: store.hiddenCount > 0)
    }

    /// "3" — or, while a find query narrows the list, "“opus” · 2 of 5".
    private var sessionsTrailing: String? {
        if !store.findQuery.isEmpty {
            return "“\(store.findQuery)” · \(store.visibleRows.count) of \(store.rows.count)"
        }
        return store.rows.isEmpty ? nil : "\(store.rows.count)"
    }
}

/// "3 earlier in History →": the runs the daemon has stopped listing
/// because they were acknowledged. Clicking opens History, where they are.
struct HiddenSessionsRow: View {
    @Bindable var store: PanelStore
    @ViewState private var hovering = false

    var body: some View {
        Button { store.openHistory() } label: {
            HStack(spacing: 6) {
                Image(systemName: "clock.arrow.circlepath")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(.tertiary)
                    .frame(width: 12)
                Text(store.hiddenFooterText)
                    .font(.system(size: 11.5))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .contentTransition(.numericText())
                Image(systemName: "arrow.right")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(.tertiary)
                    .opacity(hovering && store.isOpen ? 1 : 0.45)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 8)
            .frame(height: CGFloat(PanelLayout.hiddenFooterHeight) - 3)
            .background(RoundedRectangle(cornerRadius: 7, style: .continuous)
                .fill(Color.primary.opacity(hovering && store.isOpen ? 0.05 : 0)))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 6)
        .padding(.top, 3)
        .onHover { hovering = $0 }
        .help("Sessions you have already cleared live in History (⌘Y)")
        .accessibilityLabel("\(store.hiddenFooterText). Opens History.")
    }
}

/// "Why this light": one line under the sessions explaining what the strip
/// and the Screen Bar are doing; hover for the programs and the settings.
struct WhyLightRow: View {
    let explanation: LightExplanation
    @Bindable var store: PanelStore
    @ViewState private var hovering = false
    @ViewState private var frame: CGRect = .zero
    @ViewState private var pending: DispatchWorkItem?

    private var showsHover: Bool { hovering && store.isOpen }

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 7) {
            Image(systemName: "light.max")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(showsHover ? .secondary : .tertiary)
                .frame(width: 12)
            HStack(spacing: 0) {
                Text("\(explanation.motion): ")
                    .fontWeight(.medium)
                    .foregroundStyle(.primary.opacity(0.85))
                    .lineLimit(1)
                    .fixedSize()
                Text(explanation.reason)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            .font(.system(size: 11.5))
            .id(explanation.headline)
            .transition(.opacity)
            Spacer(minLength: 4)
            if explanation.session != nil {
                Image(systemName: "arrow.up.forward")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(.tertiary)
                    .opacity(showsHover ? 1 : 0)
            }
        }
        .padding(.horizontal, 8)
        .frame(height: CGFloat(PanelLayout.whyRowHeight) - 3)
        .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(Color.primary.opacity(showsHover ? 0.05 : 0)))
        .padding(.horizontal, 6)
        .padding(.top, 3)
        .contentShape(Rectangle())
        .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { newFrame in
            frame = newFrame
            store.whyRowFrame = newFrame
            // Rows above may have come or gone: keep the popover under the row.
            if hovering, pending == nil { store.whyHover(true, frame: newFrame) }
        }
        .onChange(of: explanation.headline) {
            if hovering, pending == nil { store.whyHover(true, frame: frame) }
        }
        .onHover { inside in
            hovering = inside
            pending?.cancel()
            if inside {
                let work = DispatchWorkItem { MainActor.assumeIsolated { pending = nil; if hovering { store.whyHover(true, frame: frame) } } }
                pending = work
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.35, execute: work)
            } else {
                pending = nil
                store.whyHover(false, frame: frame)
            }
        }
        .onChange(of: store.isOpen) { _, open in if !open { hovering = false; pending?.cancel(); pending = nil } }
        .onDisappear { pending?.cancel(); store.whyHover(false, frame: frame) }
        .onTapGesture { store.openExplainedSession() }
        .animation(PanelMotion.crossfade(reduced: store.reduceMotion, armed: store.animationsArmed), value: explanation.headline)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Why this light: \(explanation.headline)")
        .help("Why this light · hover for the programs and brightness settings")
    }
}

/// Nothing to list: a drawn state rather than a sentence in the void — a
/// soft mark, the headline, and one line saying what happens next. Live
/// and quiet reads differently from "the monitor is not there".
struct SessionsEmptyState: View {
    @Bindable var store: PanelStore

    private var live: Bool { store.isLive }

    /// A find query narrowed every row away — a different state from an
    /// empty roster, and it says how to get the rows back.
    private var finding: Bool { !store.findQuery.isEmpty && !store.rows.isEmpty }

    private var symbol: String {
        if finding { return "magnifyingglass" }
        return live ? "moon.stars" : "antenna.radiowaves.left.and.right.slash"
    }

    private var headline: String {
        if finding { return "Nothing matches “\(store.findQuery)”" }
        if live { return store.hiddenCount > 0 ? "All clear" : "No agents right now" }
        return store.coreMayBeStarting ? "Starting…" : "Monitor not connected"
    }

    private var detail: String {
        if finding {
            return "Searched labels, models, folders and asks across \(store.rows.count) session\(store.rows.count == 1 ? "" : "s"). ⌫ edits, Esc clears."
        }
        if live {
            if let stale = store.staleDetail {
                return "\(stale); showing what it last sent."
            }
            if store.hiddenCount > 0 {
                return "Everything you had running is finished and acknowledged."
            }
            // A live core with hooks never installed is a setup state, not
            // a quiet one: say what to do rather than "they will appear".
            if !store.missingHooks.isEmpty {
                let names = store.missingHooks.prefix(3).map { SessionLabel.providerName($0) }.joined(separator: ", ")
                return "Hooks install themselves at first launch — none for \(names) yet, so those agents cannot report in."
            }
            return "Hooks install themselves; Claude, Codex, Gemini and friends appear the moment they start."
        }
        return "Showing the file feeds: \(store.fallbackDetail.lowercased())."
    }

    var body: some View {
        HStack(alignment: .center, spacing: 11) {
            ZStack {
                Circle().fill(.primary.opacity(0.05))
                Circle().strokeBorder(.primary.opacity(0.07), lineWidth: 0.5)
                Image(systemName: symbol)
                    .font(.system(size: 14, weight: .light))
                    .foregroundStyle(live ? AnyShapeStyle(.secondary) : AnyShapeStyle(Color.orange.opacity(0.75)))
            }
            .frame(width: 30, height: 30)
            VStack(alignment: .leading, spacing: 2) {
                Text(headline)
                    .font(.system(size: 12.5, weight: .medium))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Text(detail)
                    .font(.system(size: 11))
                    .foregroundStyle(.tertiary)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
            if live && !finding && !store.missingHooks.isEmpty {
                // The one thing this state needs is a way forward.
                Button("Set up agents…") { store.openSettings(page: .agents) }
                    .buttonStyle(PillButtonStyle(prominent: false))
                    .help("Install or repair agent hooks in Settings › Agents")
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 14)
        .padding(.top, 6)
        .frame(height: CGFloat(PanelLayout.emptySessionsHeight), alignment: .top)
        .clipped()
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(headline). \(detail)")
    }
}

struct SessionRowView: View {
    let row: SessionRow
    @Bindable var store: PanelStore

    /// The state word, mark and elapsed time sit in one fixed column so the
    /// label column never shifts as the clock ticks.
    static let trailingWidth: CGFloat = 96

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
                        if row.workers > 0 { CountBadge(text: "\(row.workers)").help("\(row.workers) workers") }
                        if row.activity == .done, store.unseenCompletionIDs.contains(row.id) {
                            // `state.unseen_completions`: the same accent
                            // dot History gives a row newer than the last
                            // visit.
                            Circle().fill(Color.accentColor).frame(width: 5, height: 5)
                                .help("Finished since you last looked")
                        }
                        if row.isSnoozed(now: store.now) {
                            // The family mailbox is muted until the time in
                            // the tooltip: say so, or the quiet row reads
                            // as a session nobody is answering.
                            Text("snoozed").font(.system(size: 10)).foregroundStyle(.tertiary).lineLimit(1)
                        }
                        if row.stale { Text("stale").font(.system(size: 10)).foregroundStyle(.tertiary).lineLimit(1) }
                        if store.isWatchedForDone(row) {
                            Image(systemName: "bell")
                                .font(.system(size: 9, weight: .medium))
                                .foregroundStyle(.secondary)
                                .help("You'll get a banner when this run ends")
                                .accessibilityLabel("Notify when done is on")
                        }
                        if let quiet = store.quietFeedText(for: row) {
                            // The provider's hook feed stopped arriving
                            // while the row still claims to be live: the
                            // daemon's `health.sources` fact, once per
                            // provider.
                            Text(quiet).font(.system(size: 10)).foregroundStyle(.tertiary).lineLimit(1)
                                .help("\(row.style.name)'s hook feed has not delivered — this row may be behind")
                        }
                    }
                    HStack(spacing: 4) {
                        // The model the run is on ("Opus 4.5") once its
                        // transcript was read — the tile already names the
                        // provider, so the model is the better use of the
                        // words.
                        Text(row.usage?.modelName ?? row.style.name).foregroundStyle(.secondary).lineLimit(1).fixedSize()
                        if let fact = row.activityFact {
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
                    .font(.system(size: 11))
                }
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
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(Self.wordColor(row.activity))
                            .lineLimit(1)
                            .contentTransition(.opacity)
                        ActivityMark(activity: row.activity, accent: row.style.accent, reduced: store.reduceMotion, active: store.isOpen)
                    }
                    Text(row.elapsedText(now: store.now) ?? " ")
                        .font(.system(size: 11)).monospacedDigit().foregroundStyle(.tertiary).lineLimit(1)
                }
                .frame(width: Self.trailingWidth, alignment: .trailing)
            }
        }
        .animation(PanelMotion.crossfade(reduced: store.reduceMotion, armed: store.animationsArmed), value: row.activity)
        // A keyboard pick gets an accent stroke on top of the fill; a
        // pointer pick keeps the fill alone.
        .overlay {
            if store.selectionByKeyboard, store.selectedID == row.id {
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .inset(by: 1)
                    .strokeBorder(Color.accentColor.opacity(0.55), lineWidth: 1)
                    .padding(.horizontal, 6)
                    .allowsHitTesting(false)
            }
        }
        .help(row.help(now: store.now) ?? "")
        .contextMenu { SessionContextMenu(row: row, store: store) }
        .accessibilityElement(children: .combine)
        .accessibilityLabel([
            row.label, row.style.name, row.activity.word,
            PanelStore.elapsed(since: row.since, now: store.now) ?? "just started",
            row.isRemote
                ? "on \(row.remoteMachine ?? "a peer")"
                : (row.cwdTail.map { "in \($0)" } ?? "no folder on record"),
        ].joined(separator: ", "))
        .accessibilityHint(row.isRemote
            ? "Remote session — manage it on \(row.remoteMachine ?? "the machine it runs on")"
            : "Opens the session in its terminal")
        .accessibilityAddTraits(.isButton)
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

    var body: some View {
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
            if let ask = row.ask, ask.session != nil, AskVerbs.chooses(ask) {
                Menu(AskChoiceLayout.menuTitle(ask.decision?.choices ?? [], picks: store.picks(for: ask))) {
                    AskChoiceMenuItems(choices: ask.decision?.choices ?? [], picks: store.picks(for: ask),
                                       pick: { store.pick($0, in: $1, of: ask) },
                                       send: { store.sendPicks(ask) })
                }
                Button("Deny") { store.deny(ask) }
                Divider()
            } else if let ask = row.ask, ask.canAnswer, !ask.wantsTextReply, ask.session != nil {
                Button("Approve") { store.approve(ask) }
                if AskVerbs.alwaysAllows(ask) {
                    Button("Always Allow") { store.alwaysAllow(ask) }
                }
                Button("Deny") { store.deny(ask) }
                Divider()
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

struct AskRow: View {
    let row: SessionRow
    @Bindable var store: PanelStore
    /// The reply draft rides the store: a half-typed answer survives the
    /// panel closing and a relaunch, and a refused send keeps the text.
    private var replyText: Binding<String> {
        Binding(
            get: { self.row.ask.map { self.store.replyDraft(for: $0) } ?? "" },
            set: { text in if let ask = self.row.ask { self.store.setReplyDraft(text, for: ask) } }
        )
    }

    /// The whole card goes quiet while the family mailbox is snoozed —
    /// dim, still, and stamped "snoozed until", never dressed as a fresh ask.
    private var snoozed: Bool { row.isSnoozed(now: store.now) }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .top, spacing: 9) {
                ProviderTile(style: row.style)
                VStack(alignment: .leading, spacing: 1) {
                    titleLine
                    question
                }
                Spacer(minLength: 6)
                VStack(alignment: .trailing, spacing: 1) {
                    ActivityMark(activity: .waiting, accent: row.style.accent, reduced: store.reduceMotion, active: store.isOpen && !snoozed)
                        .padding(.top, 3)
                    Text(PanelStore.elapsed(since: row.ask?.openedAt.map { Date(timeIntervalSince1970: $0) } ?? row.since, now: store.now) ?? " ")
                        .font(.system(size: 11)).monospacedDigit().foregroundStyle(.tertiary).lineLimit(1)
                }
            }
            verbRow
        }
        .opacity(snoozed ? 0.55 : 1)
        .padding(.horizontal, 8)
        .frame(height: CGFloat(PanelLayout.askRowHeight))
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color.orange.opacity(store.selectedID == row.id ? 0.14 : 0.08))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .strokeBorder(Color.orange.opacity(0.22), lineWidth: 0.5)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .inset(by: 1)
                .strokeBorder(Color.accentColor.opacity(0.55), lineWidth: 1)
                .opacity(store.selectionByKeyboard && store.selectedID == row.id ? 1 : 0)
        )
        .padding(.horizontal, 6)
        .contentShape(Rectangle())
        .onTapGesture { store.open(row) }
        .help(row.help(now: store.now) ?? "")
        .contextMenu { SessionContextMenu(row: row, store: store) }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(accessibilityLabel)
        .accessibilityHint(accessibilityHint)
    }

    /// What VoiceOver reads for the row: who asks, what, the command it
    /// would run and whether it is destructive. Built apart from the
    /// modifier chain — inline, the concatenation of optionals left a
    /// slower CI runner's type checker timing out on the whole body.
    private var accessibilityLabel: String {
        var label = "\(row.label) asks: \(row.ask?.summary ?? "")"
        if let preview = row.ask?.previewLine { label += ", runs \(preview)" }
        if row.ask?.isDestructive == true { label += ", destructive" }
        return label
    }

    /// Who asks and what kind of ask, the destructive mark, and the
    /// row's quiet states.
    private var titleLine: some View {
        HStack(spacing: 6) {
            Text(row.label).fontWeight(.medium).lineLimit(1).truncationMode(.tail)
            Text(row.ask?.kind?.replacingOccurrences(of: "_", with: " ").capitalized ?? "Ask")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(Color.orange)
                .lineLimit(1)
                .padding(.horizontal, 5).padding(.vertical, 1.5)
                .background(Capsule().fill(Color.orange.opacity(0.14)))
            if row.ask?.isDestructive == true {
                AskRiskMark(size: 10)
            }
            if snoozed, let until = row.snoozedUntil {
                Text("snoozed until \(PanelStore.clockTime(Date(timeIntervalSince1970: until)))")
                    .font(.system(size: 10)).foregroundStyle(.tertiary).lineLimit(1)
            } else if snoozed {
                Text("snoozed").font(.system(size: 10)).foregroundStyle(.tertiary).lineLimit(1)
            }
            if let quiet = store.quietFeedText(for: row) {
                // Same once-per-provider marker as the plain
                // rows: an ask can be the provider's topmost
                // live row.
                Text(quiet).font(.system(size: 10)).foregroundStyle(.tertiary).lineLimit(1)
                    .help("\(row.style.name)'s hook feed has not delivered — this row may be behind")
            }
        }
    }

    /// The question, and under it what would run — a line each when
    /// there is a preview, so the card keeps its height.
    private var question: some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(row.ask?.summary ?? "Needs your answer")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .lineLimit(row.ask?.previewLine == nil ? 2 : 1)
            if let preview = row.ask?.previewLine {
                AskPreviewLine(text: preview, size: 11,
                               tint: row.ask?.isDestructive == true ? Color.red.opacity(0.85) : .secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .frame(height: 30, alignment: .topLeading)
    }

    /// When the hook's hold on this ask lapses: the verbs are drawn again
    /// at that moment, not a clock tick later, so Always and the choices
    /// leave with the hold.
    private var holdEnd: Date? { row.ask.flatMap { AskHold.end($0, at: store.now) } }

    /// The card's verbs, re-drawn once more at the hold's end.
    private var verbRow: some View {
        TimelineView(.explicit(holdEnd.map { [$0] } ?? [])) { context in
            verbs(now: max(store.now, context.date))
        }
    }

    /// The card's verbs: a reply field, a held question's options, or
    /// Deny · Always Allow · Approve — each only where the daemon says
    /// it can land — else the honest way to the session's own window.
    /// A held ask's verbs sit beside a ring draining with its hold.
    private func verbs(now: Date) -> some View {
        HStack(spacing: 6) {
            Spacer()
            if let ask = row.ask, !row.isRemote, let left = AskHold.remaining(ask, at: now) {
                AskHoldRing(fraction: left, reduced: store.reduceMotion)
                    .help(AskHold.help(ask, at: now) ?? "")
                    .accessibilityLabel(AskHold.help(ask, at: now) ?? "")
            }
            if let ask = row.ask, ask.wantsTextReply, ask.canAnswer, ask.session != nil, !row.isRemote {
                // A reply-kind ask wants words, not a verdict: a field
                // and Send; `reply_text` rides the same answer_ask. A
                // daemon that cannot take text for it says so, and the
                // toast carries that.
                TextField("Reply…", text: replyText)
                    .textFieldStyle(.plain)
                    .font(.system(size: 12))
                    .padding(.horizontal, 9).padding(.vertical, 3.5)
                    .background(Capsule().fill(Color.primary.opacity(0.08)))
                    .overlay(Capsule().strokeBorder(Color.primary.opacity(0.10), lineWidth: 0.5))
                    .frame(maxWidth: 200)
                    .disabled(store.isAnswerPending(ask))
                    .onSubmit { send(ask) }
                Button("Send") { send(ask) }
                    .buttonStyle(PillButtonStyle(prominent: true))
                    .disabled(replyText.wrappedValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || store.isAnswerPending(ask))
                    .help("Type this reply into \(row.terminalApp ?? "the session's terminal")")
            } else if let ask = row.ask, ask.session != nil, !row.isRemote, AskVerbs.chooses(ask, at: now) {
                // A held question: its options are the answer, sent
                // through the agent's own hook — Deny declines it.
                Button("Deny") { store.deny(ask) }
                    .buttonStyle(PillButtonStyle(prominent: false))
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
                Button("Deny") { store.deny(ask) }
                    .buttonStyle(PillButtonStyle(prominent: false))
                    .disabled(store.isAnswerPending(ask))
                    .help("Answer no (⌘D)")
                if AskVerbs.alwaysAllows(ask, at: now) {
                    // Its own button, never a chord: the agent will
                    // remember this rule and stop asking.
                    Button("Always Allow") { store.alwaysAllow(ask) }
                        .buttonStyle(PillButtonStyle(prominent: false))
                        .disabled(store.isAnswerPending(ask))
                        .help("Approve, and let \(row.style.name) remember the rule it offered")
                }
                Button("Approve") { store.approve(ask) }
                    .buttonStyle(PillButtonStyle(prominent: true))
                    .disabled(store.isAnswerPending(ask))
                    .help(approveHelp(ask, now: now))
            } else if row.isRemote {
                // A peer's ask: nothing local can type into it.
                Text("on \(row.remoteMachine ?? "a peer")")
                    .font(.system(size: 11)).foregroundStyle(.tertiary).lineLimit(1)
            } else if row.ask?.session != nil {
                // Not answerable from the panel (the daemon said so, or
                // it wants a reply this core will not take): the honest
                // action is the session's own window.
                Button(row.terminalApp.map { "Open in \($0)" } ?? "Open session") { store.open(row) }
                    .buttonStyle(PillButtonStyle(prominent: false))
                    .help(row.ask?.wantsTextReply == true
                          ? "This ask wants a typed reply — answer it in the session's window"
                          : "The panel cannot answer this one — answer it in the session's window")
            } else {
                // No session left to open or answer: just say so.
                Text("answer it in its own window")
                    .font(.system(size: 11)).foregroundStyle(.tertiary).lineLimit(1)
            }
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
                Button(label) {
                    if let choice = choices.first { store.pick(label, in: choice, of: ask) }
                }
                .buttonStyle(PillButtonStyle(prominent: index == 0))
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
                Button("Send") { store.sendPicks(ask) }
                    .buttonStyle(PillButtonStyle(prominent: true))
                    .disabled(store.isAnswerPending(ask))
            }
        }
    }
}

struct PillButtonStyle: ButtonStyle {
    let prominent: Bool

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 12, weight: .medium))
            .lineLimit(1)
            .foregroundStyle(prominent ? Color.white : Color.primary)
            .padding(.horizontal, 11)
            .padding(.vertical, 3.5)
            .background(
                Capsule().fill(prominent ? Color.orange.opacity(configuration.isPressed ? 0.75 : 0.95)
                                         : Color.primary.opacity(configuration.isPressed ? 0.16 : 0.08))
            )
            .overlay(Capsule().strokeBorder(Color.primary.opacity(prominent ? 0 : 0.10), lineWidth: 0.5))
            .contentShape(Capsule())
    }
}

// MARK: - Usage

struct UsageSection: View {
    @Bindable var store: PanelStore
    let layout: PanelLayout

    var body: some View {
        VStack(spacing: 0) {
            SectionLabel(text: "Usage", trailing: refreshed, detailTitle: store.isLive ? "Usage Center" : nil, onDetail: { store.openUsageCenter() })
            if store.usage.isEmpty && store.quietUsage.isEmpty {
                Text(store.isLive ? "No usage reported yet." : "Usage comes from the monitor.")
                    .font(.system(size: 12))
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 14)
                    .frame(height: CGFloat(PanelLayout.emptyUsageHeight), alignment: .top)
            } else {
                ScrollView(.vertical) {
                    VStack(spacing: CGFloat(PanelLayout.usageRowSpacing)) {
                        // `identity` (id|instance), not `id`: two accounts
                        // of one provider are two rows here.
                        ForEach(store.usage, id: \.identity) { usage in
                            UsageRow(usage: usage, store: store)
                                .transition(PanelMotion.rowTransition(reduced: store.reduceMotion))
                        }
                        // The providers with nothing to say share one
                        // trailing row that names them.
                        if !store.quietUsage.isEmpty {
                            UsageQuietRow(providers: store.quietUsage, store: store)
                                .transition(PanelMotion.rowTransition(reduced: store.reduceMotion))
                        }
                    }
                    .padding(.horizontal, 6)
                    .animation(PanelMotion.contents(reduced: store.reduceMotion, armed: store.animationsArmed),
                               value: store.usage.map(\.identity) + store.quietUsage.map(\.identity))
                }
                .scrollBounceBehavior(.basedOnSize)
                .frame(height: CGFloat(layout.usageHeight))
                .clipped()
                .modifier(ScrollEdgeFade(active: layout.usageScroll))
            }
        }
        .padding(.bottom, CGFloat(PanelLayout.usageBottomPadding))
    }

    private var refreshed: String? {
        guard let at = store.core.state?.usage?.refreshedAt else { return nil }
        guard let elapsed = PanelStore.elapsed(since: Date(timeIntervalSince1970: at), now: store.now) else { return nil }
        return "\(elapsed) ago"
    }
}

/// The providers with nothing to say — every window at 0 %, no window
/// at all, the source not found or off — as one row: their tiles, their
/// names and why ("2 at 0% · 1 not found"). A click opens the Usage
/// Center, on the provider when there is only one.
struct UsageQuietRow: View {
    let providers: [CoreProviderUsage]
    @Bindable var store: PanelStore
    @ViewState private var hovering = false

    /// Tiles past this many would crowd the names out.
    static let maxTiles = 4

    private var styles: [ProviderStyle] {
        providers.map { ProviderStyle.style(for: $0.id, document: store.settingsDocument) }
    }

    var body: some View {
        let styles = styles
        HStack(spacing: 9) {
            HStack(spacing: -6) {
                ForEach(Array(styles.prefix(Self.maxTiles).enumerated()), id: \.offset) { _, style in
                    ProviderTile(style: style, size: 20)
                        .saturation(0.35)
                        .opacity(0.8)
                }
            }
            VStack(alignment: .leading, spacing: 3) {
                Text(styles.map(\.name).joined(separator: ", "))
                    .fontWeight(.medium)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                Text(PanelStore.quietSummary(providers))
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            Spacer(minLength: 4)
            Image(systemName: "chevron.right")
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(.tertiary)
                .opacity(hovering && store.isOpen ? 1 : 0.5)
        }
        .padding(.horizontal, 8)
        .frame(height: CGFloat(PanelLayout.usageRowHeight))
        .background(
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .fill(Color.primary.opacity(hovering && store.isOpen ? 0.05 : 0))
        )
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .onTapGesture { store.openUsageCenter(provider: providers.count == 1 ? providers.first?.id : nil) }
        .help(tooltip(styles))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(tooltip(styles))
        .accessibilityHint("Opens the Usage Center")
        .accessibilityAddTraits(.isButton)
    }

    /// "Gemini: at 0%", one line per provider.
    private func tooltip(_ styles: [ProviderStyle]) -> String {
        zip(styles, providers).map { "\($0.name): \(PanelStore.quietWord($1))" }.joined(separator: "\n")
    }
}

struct UsageRow: View {
    let usage: CoreProviderUsage
    @Bindable var store: PanelStore
    @ViewState private var hovering = false

    /// The percent column: `~100%` fits with room to spare.
    static let percentWidth: CGFloat = 46

    private var style: ProviderStyle { ProviderStyle.style(for: usage.id, document: store.settingsDocument) }
    private var windows: (primary: CoreUsageWindow?, secondary: CoreUsageWindow?) { PanelStore.windows(of: usage) }
    /// The leading window's session-aware forecast — the Usage Center's
    /// own, so the row and the card never disagree about "holding".
    private var paceForecast: UsageForecast? {
        windows.primary.map { UsageCenterStore.forecast(for: usage, window: $0, core: store.core, now: store.now) }
    }

    var body: some View {
        let (primary, secondary) = windows
        HStack(alignment: .center, spacing: 9) {
            ProviderTile(style: style, size: 20)
            VStack(alignment: .leading, spacing: 3) {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(style.name).fontWeight(.medium).lineLimit(1).truncationMode(.tail)
                    if let tag {
                        UsageTagText(tag: tag)
                            .help(tagHelp(tag))
                    }
                    Spacer(minLength: 4)
                    Text(primary?.percentText ?? "")
                        .font(.system(size: 12, weight: .medium))
                        .monospacedDigit()
                        .lineLimit(1)
                        .foregroundStyle(barColor(primary?.usedPct))
                        .contentTransition(.numericText())
                        .frame(width: Self.percentWidth, alignment: .trailing)
                        .help(primary?.isUnknown == true
                              ? "\(style.name) reports this window without a number"
                              : (usage.isDerived ? "Derived estimate (\(usage.fidelity ?? "derived"))" : "Official figure"))
                }
                HStack(spacing: 8) {
                    if let primary { QuotaBar(window: primary, accent: style.accent, reduced: store.reduceMotion, armed: store.animationsArmed) }
                    if let secondary { QuotaBar(window: secondary, accent: style.accent, reduced: store.reduceMotion, armed: store.animationsArmed) }
                }
                HStack(spacing: 6) {
                    Text(resetLine(primary: primary, secondary: secondary))
                        .font(.system(size: 10))
                        .monospacedDigit()
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                    Spacer(minLength: 2)
                    if let values = store.sparkline(for: usage.id) {
                        UsageSparklineView(values: values, accent: style.accent)
                            .transition(.opacity)
                    }
                }
            }
        }
        .padding(.horizontal, 8)
        .frame(height: CGFloat(PanelLayout.usageRowHeight))
        .background(
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .fill(Color.primary.opacity(hovering ? 0.05 : 0))
        )
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .onTapGesture { store.openUsageCenter(provider: usage.id) }
        .help("Open \(style.name) in the Usage Center")
        .animation(PanelMotion.crossfade(reduced: store.reduceMotion, armed: store.animationsArmed), value: primary?.usedPct)
        .accessibilityElement(children: .combine)
        .accessibilityHint("Opens \(style.name) in the Usage Center")
        .accessibilityAddTraits(.isButton)
    }

    /// The one thing the row's tag says: Stale, Used up, Runs out in X
    /// (or a vendor incident); nothing when the provider is on track.
    private var tag: PanelStore.UsageTag? {
        PanelStore.usageTag(for: usage, primary: windows.primary,
                            heldIdle: paceForecast?.heldIdle == true, now: store.now)
    }

    private func tagHelp(_ tag: PanelStore.UsageTag) -> String {
        switch tag {
        case .stale: return "This reading is old — the last refresh did not land"
        case .usedUp: return "The \(windows.primary?.longName ?? "leading") window is used up until it resets"
        case .runsOut: return paceForecast.map { $0.headline(now: store.now) } ?? "The forecast runs dry before the reset"
        case .incident(let text): return text
        }
    }

    /// "5h resets in 1h 02m · 7d resets in 3d 5h", one line: the resets
    /// only, plus "no room for +1" when one more agent would not fit
    /// before the reset. With no reset to name, the daemon's own fix-it
    /// (`action`, "Retry later", "Run grok login") beats the bare state word.
    private func resetLine(primary: CoreUsageWindow?, secondary: CoreUsageWindow?) -> String {
        var parts: [String] = []
        if let primary, let text = PanelStore.countdown(to: primary.resetsAt, now: store.now) { parts.append("\(primary.shortName) \(text)") }
        if let secondary, let text = PanelStore.countdown(to: secondary.resetsAt, now: store.now) { parts.append("\(secondary.shortName) \(text)") }
        // The decision the panel is opened for, said only when the answer
        // is no: one more agent at today's burn would not fit.
        if let forecast = paceForecast, SessionAwarePace.roomForOneMore(forecast, now: store.now.timeIntervalSince1970) == false {
            parts.append("no room for +1")
        }
        if parts.isEmpty {
            if let action = usage.action, !action.isEmpty { return action }
            if let state = usage.state, !state.isEmpty, state != "ready" { return state.replacingOccurrences(of: "_", with: " ") }
            return "no reset time"
        }
        return parts.joined(separator: " · ")
    }

    /// A window with no reading is grey: not calm, not spent -- unread.
    private func barColor(_ pct: Double?) -> Color {
        guard let pct else { return .secondary }
        if pct >= 95 { return .red }
        if pct >= 80 { return .orange }
        return .primary
    }
}

/// A usage row's tag: red when the window is used up, amber otherwise.
struct UsageTagText: View {
    let tag: PanelStore.UsageTag

    var body: some View {
        Text(tag.text)
            .font(.system(size: 10, weight: .semibold))
            .monospacedDigit()
            .foregroundStyle(tag == .usedUp ? Color.red : Color.orange)
            .lineLimit(1)
    }
}

/// Seven days of tokens as seven bars, oldest at the left. No axes, no
/// labels, no numbers: it is there to say "busy Tuesday, quiet weekend"
/// in the corner of a 50 pt row, and the Usage Center has the real graph.
struct UsageSparklineView: View {
    /// Tokens per day, oldest first (`UsageSparkline.tokensPerDay`).
    let values: [Double]
    let accent: Color

    static let barWidth: CGFloat = 3.5
    static let gap: CGFloat = 1.5
    static let height: CGFloat = 11

    private var normalised: [Double] { UsageSparkline.normalised(values) }

    var body: some View {
        HStack(alignment: .bottom, spacing: Self.gap) {
            ForEach(Array(normalised.enumerated()), id: \.offset) { index, value in
                // A day with nothing in it keeps its place as a hairline at
                // the baseline, dimmer than any real bar, so a quiet
                // weekend never reads as a day that was not counted.
                RoundedRectangle(cornerRadius: 0.8, style: .continuous)
                    .fill(accent.opacity(value <= 0.001 ? 0.18 : (index == normalised.count - 1 ? 0.85 : 0.42)))
                    .frame(width: Self.barWidth, height: max(1, Self.height * CGFloat(value)))
            }
        }
        .frame(height: Self.height, alignment: .bottom)
        .help(Self.summary(values))
        .accessibilityLabel("Last 7 days of tokens")
        .accessibilityValue(Self.summary(values))
    }

    /// "7 days · 41.2M tokens · today 6.1M".
    static func summary(_ values: [Double]) -> String {
        let total = values.reduce(0, +)
        let today = values.last ?? 0
        return "Last 7 days · \(UsageFormat.tokens(Int(total))) tokens · today \(UsageFormat.tokens(Int(today)))"
    }
}

struct QuotaBar: View {
    let window: CoreUsageWindow
    let accent: Color
    let reduced: Bool
    var armed: Bool = true

    /// `Monthly` and `Credits` at 10 pt fit this column; the bar takes the rest.
    static let labelWidth: CGFloat = 42

    var body: some View {
        HStack(spacing: 5) {
            Text(window.shortName)
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.tail)
                .frame(width: Self.labelWidth, alignment: .leading)
            GeometryReader { proxy in
                ZStack(alignment: .leading) {
                    Capsule().fill(.primary.opacity(0.08))
                    if let used = window.usedPct {
                        Capsule()
                            .fill(fill)
                            .frame(width: max(3, proxy.size.width * CGFloat(min(100, max(0, used)) / 100)))
                            .animation(PanelMotion.contents(reduced: reduced, armed: armed), value: window.usedPct)
                    } else {
                        // No reading: a dashed outline over the whole track.
                        // An empty bar would read as a window barely used.
                        Capsule()
                            .strokeBorder(Color.secondary.opacity(0.55), style: StrokeStyle(lineWidth: 1, dash: [2, 2]))
                    }
                }
            }
            .frame(height: 4)
        }
        .help(window.isUnknown
              ? "\(window.name): the provider reports this window without a number"
              : "\(window.name): \(window.spokenPercent)")
        .accessibilityLabel("\(window.name) \(window.spokenPercent)")
    }

    private var fill: Color {
        guard let used = window.usedPct else { return .secondary }
        if used >= 95 { return .red }
        if used >= 80 { return .orange }
        return accent
    }
}

/// A session's context fill as one continuous hairline: the provider's
/// accent at rest, amber past 80 %, red past 95 % — the same thresholds
/// the quota bars use, so "nearly full" reads the same everywhere.
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
        case .critical: return .red
        case .warning: return .orange
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

struct DevicesSection: View {
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
        case "failed": return ("exclamationmark.triangle", AnyShapeStyle(Color.orange))
        default: return nil
        }
    }

    /// `state` is the word VoiceOver says after the name: "connected" for
    /// hardware, "shown"/"hidden"/"not reported" for the Screen Bar chip,
    /// which announces visibility rather than connectivity.
    private var chips: [(id: String, name: String, present: Bool, help: String, state: String?)] {
        var result: [(String, String, Bool, String, String?)] = []
        let pro = store.devices.first { $0.kind == "pro" }
        let dot = store.devices.first { $0.kind == "dot" }
        let bar = store.devices.first { $0.kind == "screen_bar" }
        let pairNote: String? = switch dotLink?.state {
        case "linked": "linked as one"
        case "no_strip": "Dot has nothing to extend"
        case "failed": dotLink?.error.map { "linked write failed: \($0)" } ?? "linked write failed"
        default: nil
        }
        let pairHelp = { (device: CoreDevice?, fallback: String) in
            ([device.map { self.deviceHelp($0) } ?? fallback, pairNote].compactMap { $0 } + ["click for Devices settings"])
                .joined(separator: " · ")
        }
        result.append(("pro", "Pro", pro?.isPresent ?? false, pairHelp(pro, "SidePulse Pro: not reported"), nil))
        result.append(("dot", "Dot", dot?.isPresent ?? false, pairHelp(dot, "PulseDot: not reported"), nil))
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
            SectionLabel(text: "Devices", trailing: store.isLive ? nil : "from files")
                .overlay(alignment: .bottomTrailing) { KeepAwakeFooter(power: store.isLive ? store.core.state?.power : nil) }
            HStack(spacing: 6) {
                ForEach(chips, id: \.id) { chip in
                    if chip.id == "dot", let glyph = linkGlyph {
                        Image(systemName: glyph.name)
                            .font(.system(size: 10))
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
            .padding(.horizontal, 14)
            .frame(height: 20)
            .padding(.bottom, 8)
            HStack(spacing: 8) {
                // The bar is a brightness target too — with no strip
                // attached this slider still dims it (`set_brightness
                // "all"` reaches the virtual device), so "no hardware"
                // is not a reason to grey it out.
                let hasTarget = store.hasHardware
                    || store.devices.contains { $0.kind == "screen_bar" && $0.isPresent }
                Image(systemName: "sun.min").font(.system(size: 10)).foregroundStyle(.tertiary)
                Slider(value: Binding(
                    get: { store.brightness },
                    set: { store.setBrightness($0, final: false) }
                ), in: 0...1) { editing in
                    if !editing { store.setBrightness(store.brightness, final: true) }
                }
                .controlSize(.mini)
                .disabled(!store.isLive || !hasTarget)
                .accessibilityLabel("Brightness")
                .accessibilityValue("\(Int((store.brightness * 100).rounded())) percent")
                Image(systemName: "sun.max").font(.system(size: 11)).foregroundStyle(.tertiary)
                Text("\(Int((store.brightness * 100).rounded()))%")
                    .font(.system(size: 11)).monospacedDigit().foregroundStyle(.secondary).lineLimit(1)
                    .frame(width: 34, alignment: .trailing)
                    .contentTransition(.numericText())
            }
            .padding(.horizontal, 14)
            .frame(height: 18)
            .padding(.bottom, 10)
            .help(store.isLive
                  ? (store.hasHardware ? "Brightness — strip, Dot and Screen Bar"
                                       : "Screen Bar brightness — no strip connected")
                  : "Brightness needs the monitor")
        }
        .frame(height: CGFloat(PanelLayout.devicesHeight), alignment: .top)
        .clipped()
    }

    private func deviceHelp(_ device: CoreDevice) -> String {
        var parts: [String] = [device.name ?? device.kind]
        parts.append(device.isPresent ? "connected" : "disconnected")
        if let leds = device.leds { parts.append("\(leds) LEDs") }
        if let error = device.error, !error.isEmpty { parts.append(error) }
        return parts.joined(separator: " · ")
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

    var body: some View {
        HStack(spacing: 5) {
            Circle()
                .fill(present ? Color.green : Color.secondary.opacity(0.35))
                .frame(width: 5, height: 5)
            Text(name).font(.system(size: 11, weight: .medium))
                .foregroundStyle(present ? .primary : .secondary)
                .lineLimit(1)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 3.5)
        .background(Capsule().fill(.primary.opacity(0.06)))
        .overlay(Capsule().strokeBorder(.primary.opacity(0.08), lineWidth: 0.5))
        .opacity(dimmed ? 0.55 : 1)
        .contentShape(Capsule())
        .accessibilityLabel("\(name) \(state ?? (present ? "connected" : "not connected"))" + (action.map { " · \($0)" } ?? ""))
        .accessibilityAddTraits(.isButton)
    }
}

// MARK: - Footer

/// The panel's footer: the verbs that act on the list on the left —
/// Clear finished (with its Undo) and Quiet — and the ways out on the
/// right, as marks with tooltips: the awake hold, History, More and
/// Settings. Quit lives at the bottom of More; ⌘Q still works while the
/// panel is key. When the left side runs long the whole row tightens
/// rather than clip, so the footer fits `PanelLayout.width` with every
/// optional piece showing.
struct PanelFooter: View {
    @Bindable var store: PanelStore

    var body: some View {
        ViewThatFits(in: .horizontal) {
            PanelFooterRow(store: store, compact: false)
            PanelFooterRow(store: store, compact: true)
        }
        .padding(.horizontal, 8)
        .frame(height: CGFloat(PanelLayout.footerHeight))
        .animation(PanelMotion.crossfade(reduced: store.reduceMotion, armed: store.animationsArmed), value: store.undoCountdown == nil)
    }
}

/// One way to lay the footer out: `compact` trims every button's padding
/// and the Undo link to its word — its countdown stays in the tooltip.
struct PanelFooterRow: View {
    @Bindable var store: PanelStore
    let compact: Bool

    var body: some View {
        HStack(spacing: compact ? 0 : 2) {
            PanelFooterLeading(store: store, compact: compact)
            Spacer(minLength: 4)
            PanelFooterTrailing(store: store, compact: compact)
        }
    }
}

/// Clear finished, its Undo while the offer stands, and the Quiet menu.
struct PanelFooterLeading: View {
    @Bindable var store: PanelStore
    var compact = false

    private var padding: CGFloat { compact ? 4 : 7 }

    var body: some View {
        HStack(spacing: compact ? 0 : 2) {
            // "Clear finished" never leaves: while an undo offer stands it
            // shrinks to a small inline link beside the button rather than
            // replacing it — a footer that swaps its verb out from under
            // the pointer is a trap.
            FooterButton(title: "Clear finished", dimmed: store.completedCount == 0, active: store.isOpen,
                         horizontalPadding: padding) { store.clearCompleted() }
                .help(store.completedCount == 0
                      ? "Nothing finished to acknowledge"
                      : "Acknowledge the \(store.completedCount) finished, ended and stale sessions; Undo stays here for 5 minutes")
            if let countdown = store.undoCountdown {
                Button(compact ? "Undo" : "Undo \(countdown)") { store.undoClear() }
                    .buttonStyle(.plain)
                    .font(.system(size: 11, weight: .medium))
                    .monospacedDigit()
                    .foregroundStyle(Color.accentColor)
                    .lineLimit(1)
                    .fixedSize()
                    .padding(.horizontal, 3)
                    .help("Put the sessions you just cleared back (\(countdown) left)")
                    .transition(.opacity)
            }
            Menu {
                Button("30 minutes") { store.quietFor(seconds: 30 * 60) }
                Button("1 hour") { store.quietFor(seconds: 60 * 60) }
                Button("4 hours") { store.quietFor(seconds: 240 * 60) }
                Button(PanelStore.morningLabel(verb: "Until", target: store.morningTarget)) {
                    store.quietFor(seconds: PanelStore.secondsUntilMorning())
                }
                Divider()
                Menu("Mode") {
                    ForEach(PanelStore.quietModes, id: \.id) { mode in
                        Button {
                            store.quietMode = mode.id
                        } label: {
                            if store.quietMode == mode.id {
                                Label(mode.label, systemImage: "checkmark")
                            } else {
                                Text(mode.label)
                            }
                        }
                    }
                }
                if store.quietIsOurs {
                    Divider()
                    Button("End quiet") { store.endQuiet() }
                }
            } label: {
                // "Quiet…" idle; "Paused 42m" while the daemon's focus
                // says a quiet is in effect, in the waiting amber.
                Text(store.quietLabel ?? "Quiet…")
                    .lineLimit(1)
                    .foregroundStyle(store.quiet != nil ? SessionActivity.waiting.tint : .primary)
            }
            .menuStyle(.button)
            .buttonStyle(FooterButtonStyle(dimmed: !store.isLive, active: store.isOpen, horizontalPadding: padding))
            .menuIndicator(.hidden)
            .fixedSize()
            .help(quietHelp)
            .accessibilityLabel(store.quietLabel.map { "Quiet: \($0)" } ?? "Quiet")
        }
    }

    private var quietHelp: String {
        guard let label = store.quietLabel else { return "Quiet the lights and sounds for a while" }
        let source = (store.quiet?.source).map { PanelStore.quietSourceWord($0) } ?? "this menu"
        return "Quiet: \(label) · from \(source)"
    }
}

/// The footer's marks: the awake hold, History, More and Settings, each
/// an icon whose words are its tooltip.
struct PanelFooterTrailing: View {
    @Bindable var store: PanelStore
    var compact = false

    private var padding: CGFloat { compact ? 4 : 7 }

    var body: some View {
        HStack(spacing: compact ? 0 : 2) {
            if let hold = store.awakeHold {
                // The hold on sleep is a mark, not a sentence: the words
                // live in the tooltip, and a click opens the Power rows.
                Button { store.openSettings(page: .notifications) } label: {
                    Image(systemName: hold.symbol).font(.system(size: 11, weight: .medium))
                }
                .buttonStyle(FooterButtonStyle(dimmed: false, active: store.isOpen, horizontalPadding: padding))
                .help(hold.text)
                .accessibilityLabel(hold.text)
            }
            Button { store.openHistory() } label: {
                Image(systemName: "clock.arrow.circlepath").font(.system(size: 12, weight: .medium))
            }
            .buttonStyle(FooterButtonStyle(dimmed: !store.isLive, active: store.isOpen, horizontalPadding: padding))
            .help("History (⌘Y)")
            .accessibilityLabel("History")
            Menu {
                PanelMoreMenuItems(store: store)
            } label: {
                Image(systemName: "ellipsis.circle").font(.system(size: 12, weight: .medium))
            }
            .menuStyle(.button)
            .buttonStyle(FooterButtonStyle(dimmed: !store.isLive, active: store.isOpen, horizontalPadding: padding))
            .menuIndicator(.hidden)
            .fixedSize()
            .help("More: Control Center (⌘K), Effects, History (⌘Y), Usage Center (⌘U), Check for Updates, Settings (⌘,), Quit (⌘Q)")
            .accessibilityLabel("More")
            Button { store.openSettings() } label: {
                Image(systemName: "gearshape").font(.system(size: 12, weight: .medium))
            }
            .buttonStyle(FooterButtonStyle(dimmed: false, active: store.isOpen, horizontalPadding: padding))
            .help("Settings… (⌘,)")
            .accessibilityLabel("Settings")
        }
        .fixedSize()
    }
}

/// The footer's More menu.
struct PanelMoreMenuItems: View {
    @Bindable var store: PanelStore

    var body: some View {
        Button { store.openControlCenter() } label: { Text("Control Center…") }
            .keyboardShortcut("k", modifiers: .command)
        Button { store.openEffects() } label: { Text("Effect Studio…") }
        Button { store.openHistory() } label: { Text("History…") }
            .keyboardShortcut("y", modifiers: .command)
        Button { store.openOverview() } label: { Text("Overview…") }
            .keyboardShortcut("o", modifiers: .command)
        Button { store.openUsageCenter() } label: { Text("Usage Center…") }
            .keyboardShortcut("u", modifiers: .command)
        Divider()
        Button { store.checkForUpdates() } label: { Text("Check for Updates…") }
        Button { store.openSettings() } label: { Text("Settings…") }
            .keyboardShortcut(",", modifiers: .command)
        Divider()
        Button { store.quit() } label: { Text("Quit JR-Bar") }
            .keyboardShortcut("q", modifiers: .command)
    }
}

struct FooterButton: View {
    let title: String
    let dimmed: Bool
    var active: Bool = true
    var horizontalPadding: CGFloat = 7
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(title)
                .lineLimit(1)
                .fixedSize()
        }
        .buttonStyle(FooterButtonStyle(dimmed: dimmed, active: active, horizontalPadding: horizontalPadding))
    }
}

struct FooterButtonStyle: ButtonStyle {
    let dimmed: Bool
    var active: Bool = true
    var horizontalPadding: CGFloat = 7
    @ViewState private var hovering = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 12))
            .foregroundStyle(dimmed ? Color.secondary.opacity(0.7) : Color.primary.opacity(0.85))
            .padding(.horizontal, horizontalPadding)
            .padding(.vertical, 4)
            .background(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(Color.primary.opacity(configuration.isPressed ? 0.12 : (hovering && active ? 0.06 : 0)))
            )
            .contentShape(Rectangle())
            .onHover { hovering = $0 }
            .onChange(of: active) { _, isActive in if !isActive { hovering = false } }
    }
}

// MARK: - Toast

struct ToastView: View {
    let text: String?
    /// An optional button inside the capsule (the refused-answer "Open
    /// Settings"); when set, the toast takes clicks for it.
    var action: (title: String, run: () -> Void)? = nil
    let reduced: Bool
    var armed: Bool = true

    var body: some View {
        ZStack {
            if let text {
                HStack(spacing: 8) {
                    Text(text)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                    if let action {
                        Button(action.title) { action.run() }
                            .buttonStyle(.plain)
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(Color.accentColor)
                            .lineLimit(1)
                    }
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .background(Capsule().fill(.regularMaterial))
                .overlay(Capsule().strokeBorder(.primary.opacity(0.10), lineWidth: 0.5))
                .padding(.bottom, 40)
                .transition(reduced ? .opacity : .opacity.combined(with: .offset(y: 6)))
                .id(text)
            }
        }
        .animation(PanelMotion.contents(reduced: reduced, armed: armed), value: text)
        // Click-through unless a button is on the capsule to click.
        .allowsHitTesting(action != nil)
    }
}
