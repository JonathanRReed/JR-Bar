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
                    .help("Launch the core again")
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
            .accessibilityLabel(state == .live ? "Core connected" : (state == .connecting ? "Connecting to core" : (state == .crashed ? "Core crashed" : "Using file feeds")))
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
            SectionLabel(text: "Sessions", trailing: store.rows.isEmpty ? nil : "\(store.rows.count)")
            if store.rows.isEmpty {
                SessionsEmptyState(store: store)
            } else {
                ScrollView(.vertical) {
                    VStack(spacing: CGFloat(PanelLayout.rowSpacing)) {
                        ForEach(store.askRows) { row in
                            AskRow(row: row, store: store)
                                .transition(PanelMotion.rowTransition(reduced: store.reduceMotion))
                        }
                        ForEach(store.plainRows) { row in
                            SessionRowView(row: row, store: store)
                                .transition(PanelMotion.rowTransition(reduced: store.reduceMotion))
                        }
                    }
                    .padding(.bottom, CGFloat(PanelLayout.listBottomPadding))
                    .animation(PanelMotion.contents(reduced: store.reduceMotion, armed: store.animationsArmed), value: store.rows.map(\.id))
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
/// and quiet reads differently from "the core is not there".
struct SessionsEmptyState: View {
    @Bindable var store: PanelStore

    private var live: Bool { store.isLive }

    private var symbol: String {
        live ? "moon.stars" : "antenna.radiowaves.left.and.right.slash"
    }

    private var headline: String {
        if live { return store.hiddenCount > 0 ? "All clear" : "No agents right now" }
        return store.coreMayBeStarting ? "Core is starting" : "Core not connected"
    }

    private var detail: String {
        if live {
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
            if live && !store.missingHooks.isEmpty {
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
                        if row.isSnoozed(now: store.now) {
                            // The family mailbox is muted until the time in
                            // the tooltip: say so, or the quiet row reads
                            // as a session nobody is answering.
                            Text("snoozed").font(.system(size: 10)).foregroundStyle(.tertiary).lineLimit(1)
                        }
                        if row.stale { Text("stale").font(.system(size: 10)).foregroundStyle(.tertiary).lineLimit(1) }
                    }
                    HStack(spacing: 4) {
                        Text(row.style.name).foregroundStyle(.secondary).lineLimit(1).fixedSize()
                        if row.isRemote {
                            // A peer's session: name the machine, never a
                            // path this Mac cannot open.
                            Text("·").foregroundStyle(.quaternary)
                            Text("on \(row.remoteMachine ?? "a peer")").foregroundStyle(.tertiary).lineLimit(1).truncationMode(.tail)
                        } else if let tail = row.cwdTail {
                            Text("·").foregroundStyle(.quaternary)
                            Text(tail).foregroundStyle(.tertiary).lineLimit(1).truncationMode(.head)
                        }
                    }
                    .font(.system(size: 11))
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
            if row.activity.isClearable || row.stale {
                Divider()
                Button("Clear") { store.clear(row) }
            }
        } else {
            // The card's buttons, also on the menu — behind the daemon's
            // own answerability gate, never an offer it would refuse.
            if let ask = row.ask, ask.canAnswer, !ask.wantsTextReply, ask.session != nil {
                Button("Approve") { store.approve(ask) }
                Button("Deny") { store.deny(ask) }
                Divider()
            }
            Button(row.terminalApp.map { "Open in \($0)" } ?? "Open session") { store.open(row) }
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
    /// The reply draft, for a `replyable` ask; cleared once sent.
    @ViewState private var replyText = ""

    /// The whole card goes quiet while the family mailbox is snoozed —
    /// dim, still, and stamped "snoozed until", never dressed as a fresh ask.
    private var snoozed: Bool { row.isSnoozed(now: store.now) }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .top, spacing: 9) {
                ProviderTile(style: row.style)
                VStack(alignment: .leading, spacing: 1) {
                    HStack(spacing: 6) {
                        Text(row.label).fontWeight(.medium).lineLimit(1).truncationMode(.tail)
                        Text(row.ask?.kind?.capitalized ?? "Ask")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(Color.orange)
                            .lineLimit(1)
                            .padding(.horizontal, 5).padding(.vertical, 1.5)
                            .background(Capsule().fill(Color.orange.opacity(0.14)))
                        if snoozed, let until = row.snoozedUntil {
                            Text("snoozed until \(PanelStore.clockTime(Date(timeIntervalSince1970: until)))")
                                .font(.system(size: 10)).foregroundStyle(.tertiary).lineLimit(1)
                        } else if snoozed {
                            Text("snoozed").font(.system(size: 10)).foregroundStyle(.tertiary).lineLimit(1)
                        }
                    }
                    Text(row.ask?.summary ?? "Needs your answer")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .frame(height: 30, alignment: .topLeading)
                }
                Spacer(minLength: 6)
                VStack(alignment: .trailing, spacing: 1) {
                    ActivityMark(activity: .waiting, accent: row.style.accent, reduced: store.reduceMotion, active: store.isOpen && !snoozed)
                        .padding(.top, 3)
                    Text(PanelStore.elapsed(since: row.ask?.openedAt.map { Date(timeIntervalSince1970: $0) } ?? row.since, now: store.now) ?? " ")
                        .font(.system(size: 11)).monospacedDigit().foregroundStyle(.tertiary).lineLimit(1)
                }
            }
            HStack(spacing: 6) {
                Spacer()
                if let ask = row.ask, ask.wantsTextReply, ask.canAnswer, ask.session != nil, !row.isRemote {
                    // A reply-kind ask wants words, not a verdict: a field
                    // and Send; `reply_text` rides the same answer_ask. A
                    // daemon that cannot take text for it says so, and the
                    // toast carries that.
                    TextField("Reply…", text: $replyText)
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
                        .disabled(replyText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || store.isAnswerPending(ask))
                        .help("Type this reply into \(row.terminalApp ?? "the session's terminal")")
                } else if let ask = row.ask, ask.canAnswer, !ask.wantsTextReply, ask.session != nil, !row.isRemote {
                    // Approve/Deny type the answer into the session's own
                    // terminal (the daemon raises it first); the refusal —
                    // not a guess — is what the toast then shows. Both go
                    // quiet while the answer is on the wire so a double
                    // click cannot post twice.
                    Button("Deny") { store.deny(ask) }
                        .buttonStyle(PillButtonStyle(prominent: false))
                        .disabled(store.isAnswerPending(ask))
                        .help("Answer no (⌘D)")
                    Button("Approve") { store.approve(ask) }
                        .buttonStyle(PillButtonStyle(prominent: true))
                        .disabled(store.isAnswerPending(ask))
                        .help("Bring \(row.terminalApp ?? "the terminal") forward and approve there (⌘↩)")
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
        .accessibilityLabel("\(row.label) asks: \(row.ask?.summary ?? "")")
    }

    private func send(_ ask: CoreAsk) {
        let text = replyText
        replyText = ""
        store.reply(ask, text: text)
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
            SectionLabel(text: "Usage", trailing: refreshed, detailTitle: store.isLive ? "Details" : nil, onDetail: { store.openUsageCenter() })
            if store.usage.isEmpty && store.windowlessUsage.isEmpty {
                Text(store.isLive ? "No usage reported yet." : "Usage comes from the core.")
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
                        // A provider that reports in with no window is a
                        // setup state, not a quiet zero: it gets a row that
                        // says so and opens the Usage Center on it.
                        ForEach(store.windowlessUsage, id: \.identity) { usage in
                            UsageSetupRow(usage: usage, store: store)
                                .transition(PanelMotion.rowTransition(reduced: store.reduceMotion))
                        }
                    }
                    .padding(.horizontal, 6)
                    .animation(PanelMotion.contents(reduced: store.reduceMotion, armed: store.animationsArmed),
                               value: store.usage.map(\.identity) + store.windowlessUsage.map(\.identity))
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

/// A provider that reports in but carries no window — signed out, or no
/// reader configured. One compact row (name + the daemon's state word +
/// chevron) that opens the Usage Center on it; a silent absence used to
/// pass for "not tracked".
struct UsageSetupRow: View {
    let usage: CoreProviderUsage
    @Bindable var store: PanelStore
    @ViewState private var hovering = false

    private var style: ProviderStyle { ProviderStyle.style(for: usage.id, document: store.settingsDocument) }

    var body: some View {
        HStack(spacing: 9) {
            ProviderTile(style: style, size: 20)
            Text(style.name).fontWeight(.medium).lineLimit(1).truncationMode(.tail)
            Text(usage.state?.replacingOccurrences(of: "_", with: " ") ?? "setup needed")
                .font(.system(size: 10))
                .foregroundStyle(.tertiary)
                .lineLimit(1)
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
        .onTapGesture { store.openUsageCenter(provider: usage.id) }
        .help("\(style.name) reports no usage windows — the Usage Center can set it up")
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isButton)
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

    var body: some View {
        let (primary, secondary) = windows
        HStack(alignment: .center, spacing: 9) {
            ProviderTile(style: style, size: 20)
            VStack(alignment: .leading, spacing: 3) {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(style.name).fontWeight(.medium).lineLimit(1).truncationMode(.tail)
                    if isStale {
                        // The reading is old, not current: "Stale", the
                        // Usage Center's own word, beside the name — never
                        // a number quietly trusted anyway.
                        Text("Stale")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(Color.orange)
                            .lineLimit(1)
                            .help("This reading is old — the last refresh did not land")
                    } else if usage.isDerived {
                        // `derived`/`estimated` fidelity spelled out; the
                        // bare "~" it used to hide behind was invisible.
                        Text("est.")
                            .font(.system(size: 10))
                            .foregroundStyle(.tertiary)
                            .lineLimit(1)
                            .help("Derived estimate (\(usage.fidelity ?? "derived")), not the provider's own figure")
                    }
                    if let hint = PanelStore.paceHint(usage.forecast?.pace,
                                                    exhaustsAt: usage.forecast?.exhaustsAt,
                                                    resetsAt: primary?.resetsAt, now: store.now) {
                        Text(hint).font(.system(size: 10)).foregroundStyle(paceColor(usage.forecast?.pace)).lineLimit(1)
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
        .accessibilityAddTraits(.isButton)
    }

    /// The daemon's `state`/`fidelity` say the reading is old — what the
    /// row's "Stale" tag shows.
    private var isStale: Bool {
        usage.state?.lowercased() == "stale" || usage.fidelity?.lowercased() == "stale"
    }

    /// "5h resets in 1h 02m · 7d resets in 3d 5h · runs out in 2h", one
    /// line. With no reset to name, the daemon's own fix-it (`action`,
    /// "Retry later", "Run grok login") beats the bare state word.
    private func resetLine(primary: CoreUsageWindow?, secondary: CoreUsageWindow?) -> String {
        var parts: [String] = []
        if let primary, let text = PanelStore.countdown(to: primary.resetsAt, now: store.now) { parts.append("\(primary.shortName) \(text)") }
        if let secondary, let text = PanelStore.countdown(to: secondary.resetsAt, now: store.now) { parts.append("\(secondary.shortName) \(text)") }
        if let exhaustsAt = usage.forecast?.exhaustsAt, exhaustsAt > store.now.timeIntervalSince1970 {
            parts.append("runs out \(UsageForecast.relative(to: exhaustsAt, now: store.now))")
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

    private func paceColor(_ pace: String?) -> Color {
        switch pace?.lowercased() {
        case "ahead": return .orange
        case "exhausted": return .red
        case "behind", "under": return .secondary
        default: return Color.secondary.opacity(0.7)
        }
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

    private var chips: [(id: String, name: String, present: Bool, help: String)] {
        var result: [(String, String, Bool, String)] = []
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
        result.append(("pro", "Pro", pro?.isPresent ?? false, pairHelp(pro, "SidePulse Pro: not reported")))
        result.append(("dot", "Dot", dot?.isPresent ?? false, pairHelp(dot, "PulseDot: not reported")))
        let barShown = store.screenBarShown && (bar?.isPresent ?? true)
        var barHelp = barShown ? "Screen Bar shown under the notch · click to hide" : "Screen Bar hidden · click to show"
        if store.core.lights?.linked == true, store.core.lights?.hardware != nil {
            barHelp += " · in step with the strip"
        }
        result.append(("screen_bar", "Screen Bar", barShown, barHelp))
        return result.map { (id: $0.0, name: $0.1, present: $0.2, help: $0.3) }
    }

    var body: some View {
        VStack(spacing: 0) {
            SectionLabel(text: "Devices", trailing: store.isLive ? nil : "from files")
            HStack(spacing: 6) {
                ForEach(chips, id: \.id) { chip in
                    if chip.id == "dot", let glyph = linkGlyph {
                        Image(systemName: glyph.name)
                            .font(.system(size: 10))
                            .foregroundStyle(glyph.style)
                            .accessibilityHidden(true)
                    }
                    DeviceChip(name: chip.name, present: chip.present, dimmed: !store.isLive && chip.id != "screen_bar",
                               action: chip.id == "screen_bar" ? nil : "opens Devices settings")
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
                Image(systemName: "sun.min").font(.system(size: 10)).foregroundStyle(.tertiary)
                Slider(value: Binding(
                    get: { store.brightness },
                    set: { store.setBrightness($0, final: false) }
                ), in: 0...1) { editing in
                    if !editing { store.setBrightness(store.brightness, final: true) }
                }
                .controlSize(.mini)
                .disabled(!store.isLive || !store.hasHardware)
                Image(systemName: "sun.max").font(.system(size: 11)).foregroundStyle(.tertiary)
                Text("\(Int((store.brightness * 100).rounded()))%")
                    .font(.system(size: 11)).monospacedDigit().foregroundStyle(.secondary).lineLimit(1)
                    .frame(width: 34, alignment: .trailing)
                    .contentTransition(.numericText())
            }
            .padding(.horizontal, 14)
            .frame(height: 18)
            .padding(.bottom, 10)
            .help(store.isLive ? "Strip brightness (sends set_brightness)" : "Brightness needs the core")
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
    /// What a tap does, for VoiceOver ("opens Devices settings"); nil for
    /// the Screen Bar chip, whose tap toggles the band rather than opening
    /// a page.
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
        .accessibilityLabel("\(name) \(present ? "connected" : "not connected")" + (action.map { " · \($0)" } ?? ""))
        .accessibilityAddTraits(action == nil ? [] : .isButton)
    }
}

// MARK: - Footer

struct PanelFooter: View {
    @Bindable var store: PanelStore

    var body: some View {
        HStack(spacing: 2) {
            // "Clear finished" never leaves: while an undo offer stands it
            // shrinks to a small inline link beside the button rather than
            // replacing it — a footer that swaps its verb out from under
            // the pointer is a trap.
            FooterButton(title: "Clear finished", dimmed: store.completedCount == 0, active: store.isOpen) { store.clearCompleted() }
                .help(store.completedCount == 0
                      ? "Nothing finished to acknowledge"
                      : "Acknowledge the \(store.completedCount) finished, ended and stale sessions; Undo stays here for 5 minutes")
            if let countdown = store.undoCountdown {
                Button("Undo (\(countdown))") { store.undoClear() }
                    .buttonStyle(.plain)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(Color.accentColor)
                    .lineLimit(1)
                    .padding(.leading, 4)
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
            .buttonStyle(FooterButtonStyle(dimmed: !store.isLive, active: store.isOpen))
            .menuIndicator(.hidden)
            .fixedSize()
            .help(store.quietLabel.map { "Quiet: \($0) · from \((store.quiet?.source).map { PanelStore.quietSourceWord($0) } ?? "this menu")" }
                  ?? "Quiet the lights and sounds for a while")
            .accessibilityLabel(store.quietLabel.map { "Quiet: \($0)" } ?? "Quiet")
            Spacer()
            // While a quiet is in effect its label needs the room the
            // shortcut hints take; the shortcuts themselves still work
            // and the .help texts keep naming them.
            FooterButton(title: "History", dimmed: !store.isLive,
                         shortcut: store.quiet == nil ? "⌘Y" : nil, active: store.isOpen) { store.openHistory() }
                .help("Activity history (⌘Y)")
            Menu {
                Button { store.openControlCenter() } label: { Text("Control Center…") }
                    .keyboardShortcut("k", modifiers: .command)
                Button { store.openEffects() } label: { Text("Effects…") }
                Button { store.openHistory() } label: { Text("History…") }
                    .keyboardShortcut("y", modifiers: .command)
                Button { store.openUsageCenter() } label: { Text("Usage Center…") }
                    .keyboardShortcut("u", modifiers: .command)
                Divider()
                Button { store.checkForUpdates() } label: { Text("Check for Updates…") }
                Button { store.openSettings() } label: { Text("Settings…") }
                    .keyboardShortcut(",", modifiers: .command)
            } label: {
                Image(systemName: "ellipsis.circle").font(.system(size: 12, weight: .medium))
            }
            .menuStyle(.button)
            .buttonStyle(FooterButtonStyle(dimmed: !store.isLive, active: store.isOpen))
            .menuIndicator(.hidden)
            .fixedSize()
            .help("More: Control Center (⌘K), Effects, History (⌘Y), Usage Center (⌘U), Check for Updates, Settings (⌘,)")
            .accessibilityLabel("More")
            Button { store.openSettings() } label: {
                Image(systemName: "gearshape").font(.system(size: 12, weight: .medium))
            }
            .buttonStyle(FooterButtonStyle(dimmed: false, active: store.isOpen))
            .help("Settings… (⌘,)")
            .accessibilityLabel("Settings")
            FooterButton(title: "Quit", dimmed: false,
                         shortcut: store.quiet == nil ? "⌘Q" : nil, active: store.isOpen) { store.quit() }
        }
        .padding(.horizontal, 8)
        .frame(height: CGFloat(PanelLayout.footerHeight))
        .animation(PanelMotion.crossfade(reduced: store.reduceMotion, armed: store.animationsArmed), value: store.undoCountdown == nil)
    }
}

struct FooterButton: View {
    let title: String
    let dimmed: Bool
    var shortcut: String? = nil
    var active: Bool = true
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 4) {
                Text(title)
                if let shortcut {
                    Text(shortcut).font(.system(size: 10)).foregroundStyle(.tertiary)
                }
            }
            .lineLimit(1)
            .fixedSize()
        }
        .buttonStyle(FooterButtonStyle(dimmed: dimmed, active: active))
    }
}

struct FooterButtonStyle: ButtonStyle {
    let dimmed: Bool
    var active: Bool = true
    @ViewState private var hovering = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 12))
            .foregroundStyle(dimmed ? Color.secondary.opacity(0.7) : Color.primary.opacity(0.85))
            .padding(.horizontal, 7)
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
