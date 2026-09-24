import AppKit
import JRBarCore
import SwiftUI

// The Overview's right-hand pane: a session's inspector, a connection's
// facts, and — with nothing selected — every connection the roster runs
// on. Each is a header, then sections in wells, the same shapes the rest
// of the windows use.

/// A section of the inspector: a small title, an optional trailing
/// control, and its content under it.
struct OverviewInspectorSection<Trailing: View, Content: View>: View {
    let title: String
    @ViewBuilder var trailing: () -> Trailing
    @ViewBuilder var content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 6) {
                Text(title)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .accessibilityAddTraits(.isHeader)
                Spacer(minLength: 4)
                trailing()
            }
            content()
        }
    }
}

extension OverviewInspectorSection where Trailing == EmptyView {
    init(_ title: String, @ViewBuilder content: @escaping () -> Content) {
        self.init(title: title, trailing: { EmptyView() }, content: content)
    }
}

/// S7.3's evidence vocabulary: reported (the source said it), derived
/// (the daemon computed it from reported inputs), unavailable.
enum OverviewEvidence: String {
    case reported = "Reported"
    case derived = "Derived"
    case unavailable = "Unavailable"

    var tint: Color {
        switch self {
        case .reported: return .accentColor
        case .derived: return .secondary
        case .unavailable: return .orange
        }
    }
}

/// One labelled fact in an inspector grid: the name, the value, and the
/// evidence class it rests on.
struct OverviewFactRow: View {
    let name: String
    let value: String
    var evidence: OverviewEvidence? = nil

    var body: some View {
        GridRow(alignment: .firstTextBaseline) {
            Text(name)
                .foregroundStyle(.secondary)
                .gridColumnAlignment(.leading)
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(value)
                    .foregroundStyle(.primary)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
                if let evidence {
                    Text(evidence.rawValue)
                        .font(.system(size: 8.5, weight: .semibold))
                        .padding(.horizontal, 5).padding(.vertical, 1.5)
                        .background(evidence.tint.opacity(0.14), in: .capsule)
                        .foregroundStyle(evidence.tint)
                }
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(evidence.map { "\(name): \(value) (\($0.rawValue))" } ?? "\(name): \(value)")
    }
}

extension OverviewLink.Tone {
    /// The status dot's colour — the same green-means-live vocabulary
    /// the panel's device chips already speak.
    var color: Color {
        switch self {
        case .good: return .green
        case .busy: return .blue
        case .warn: return .orange
        case .down: return .red
        case .idle: return .secondary.opacity(0.35)
        }
    }
}

/// A link's mark: providers draw their brand tile; everything else takes
/// the link's SF Symbol, framed to the same size so the titles line up.
struct OverviewLinkGlyph: View {
    let link: OverviewLink
    var size: CGFloat = 12

    var body: some View {
        if link.group == .providers {
            let raw = String(link.id.dropFirst("provider:".count))
            let provider = raw.split(separator: "|").first.map(String.init) ?? raw
            ProviderTile(style: ProviderStyle.style(for: provider), size: size)
        } else {
            Image(systemName: link.symbol)
                .font(.system(size: size * 0.62, weight: .medium))
                .foregroundStyle(.secondary)
                .frame(width: size, height: size)
        }
    }
}

// MARK: - A session

/// The selected row's inspector: who and what state, the ask waiting on
/// you with its explicit answers, the canonical facts with their evidence,
/// the last message, the timeline and the tools the run called.
struct OverviewSessionInspector: View {
    @Bindable var store: OverviewStore
    let entry: CoreRosterEntry
    /// Opens the Reply… prompt for this row.
    let reply: (CoreRosterEntry) -> Void

    private var style: ProviderStyle { ProviderStyle.style(for: entry.session.provider) }
    private var activity: SessionActivity { SessionActivity.reduce(entry.session) }

    var body: some View {
        SnapshotScrollView {
            VStack(alignment: .leading, spacing: 18) {
                header
                if let ask = entry.session.ask {
                    waitingSection(ask: ask)
                }
                OverviewInspectorSection("Facts") {
                    facts
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .windowWell(padding: 12)
                }
                if let message = entry.session.message, !message.isEmpty {
                    OverviewInspectorSection("Last message") {
                        Text(message)
                            .font(.system(size: 12))
                            .textSelection(.enabled)
                            .fixedSize(horizontal: false, vertical: true)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .windowWell(padding: 12)
                    }
                }
                if let coverage = store.coverageNote, entry.visibility == "hidden" {
                    Text(coverage).font(.system(size: 10.5)).foregroundStyle(.tertiary)
                }
                timelineSection
                observedToolsSection
                if let previous = store.previousRun(for: entry) {
                    Button {
                        store.compareWithPreviousRun(entry)
                    } label: {
                        Label("Compare with the previous run here", systemImage: "arrow.left.arrow.right")
                            .font(.system(size: 11.5))
                    }
                    .buttonStyle(.link)
                    .disabled(store.comparing)
                    .help("Side by side with \(previous.session.label ?? previous.session.shortId ?? "the last finished run") in the same folder")
                }
                actions
            }
            .padding(18)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(minWidth: 220)
    }

    /// The tile, the name, and a line of who and where under it.
    private var header: some View {
        HStack(alignment: .top, spacing: 11) {
            ProviderTile(style: style, size: 32)
            VStack(alignment: .leading, spacing: 4) {
                Text(entry.session.label ?? entry.session.shortId ?? "Session")
                    .font(.system(size: 15, weight: .semibold))
                    .lineLimit(2)
                    .textSelection(.enabled)
                HStack(spacing: 6) {
                    OverviewStatePill(activity: activity)
                    Text(subtitle)
                        .font(.system(size: 11.5))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }
        }
    }

    /// "Claude · jr-bar" or "Codex · on Studio".
    private var subtitle: String {
        var parts = [style.name]
        if entry.session.remote, let origin = entry.session.origin?.label {
            parts.append("on \(origin)")
        } else if let project = OverviewFilter.projectName(of: entry.session.cwd) {
            parts.append(project)
        }
        return parts.joined(separator: " · ")
    }

    private var facts: some View {
        let session = entry.session
        return Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 6) {
            // S7.3: every fact names its evidence class — what the provider
            // reported vs what the daemon derived vs what nobody can say.
            OverviewFactRow(name: "State", value: activity.word, evidence: .derived)
            OverviewFactRow(name: "Outcome", value: entry.axes?.outcome ?? "—", evidence: .derived)
            OverviewFactRow(name: "Review", value: entry.axes?.review ?? "—", evidence: .derived)
            OverviewFactRow(name: "Freshness", value: entry.axes?.freshness ?? (session.stale ? "stale" : "live"), evidence: .derived)
            OverviewFactRow(name: "Harness", value: session.provider, evidence: .reported)
            if let origin = session.origin?.label { OverviewFactRow(name: "Origin", value: origin, evidence: .reported) }
            if let project = OverviewFilter.projectName(of: session.cwd) {
                OverviewFactRow(name: "Project", value: project, evidence: .derived)
            }
            if let tool = session.tool { OverviewFactRow(name: "Tool", value: tool, evidence: .reported) }
            if session.workers > 0 { OverviewFactRow(name: "Workers", value: "\(session.workers)", evidence: .reported) }
            if session.stale { OverviewFactRow(name: "Stale", value: "yes", evidence: .reported) }
            usageFacts
        }
        .font(.system(size: 11.5))
    }

    @ViewBuilder
    private var usageFacts: some View {
        if let usage = store.usage(for: entry) {
            // `session_usage`: the run's own transcript, read for model and
            // tokens — reported by the provider; the cost is the daemon's
            // list-price arithmetic, so derived.
            if let model = usage.modelName {
                OverviewFactRow(name: "Model (transcript)", value: model, evidence: .reported)
            }
            if usage.models.count > 1 {
                OverviewFactRow(name: "Models", value: usage.models.sorted { $0.value > $1.value }
                    .map { "\(ModelName.display($0.key) ?? $0.key) \(UsageFormat.tokens($0.value))" }
                    .joined(separator: ", "), evidence: .reported)
            }
            if usage.tokens.total > 0 {
                OverviewFactRow(name: "Tokens", value: Self.tokensFact(usage), evidence: .reported)
            }
            if let cost = usage.costText {
                OverviewFactRow(name: "Cost", value: cost + (usage.costEstimated ? " (stand-in rate)" : ""), evidence: .derived)
            }
            if let context = usage.contextText {
                OverviewFactRow(name: "Context", value: context,
                                evidence: usage.contextWindowSource == "reported" ? .reported : .derived)
            }
            if let share = OverviewWindowShare.fact(for: usage, provider: entry.session.provider,
                                                    readings: Array(store.sessionUsage.usage.values)) {
                OverviewFactRow(name: share.name, value: share.value, evidence: .derived)
                    .help(OverviewWindowShare.explanation)
            }
        } else if let model = store.transcriptModel, store.timelineSessionID == entry.id {
            // The transcript's own word for the model — the label names the
            // source so it never reads as a roster fact.
            OverviewFactRow(name: "Model (transcript)", value: model, evidence: .reported)
        } else {
            OverviewFactRow(name: "Model",
                            value: store.sessionUsage.gap(for: entry.id).map(SessionUsageDocument.gapText) ?? "not read yet",
                            evidence: .unavailable)
        }
    }

    /// "1.2M in 48 turns · 84% cached".
    static func tokensFact(_ usage: SessionUsage) -> String {
        var text = "\(UsageFormat.tokens(usage.tokens.total)) in \(usage.turns) turn\(usage.turns == 1 ? "" : "s")"
        if let share = usage.tokens.cacheShare, share >= 0.01 {
            text += " · \(Int((share * 100).rounded()))% cached"
        }
        return text
    }

    // MARK: The ask

    /// The "Waiting on you" section: the ask's summary and age, then the
    /// explicit actions — Approve / Deny / Reply…. Every button sends
    /// with the ask's `request` pinned, so the daemon itself refuses a
    /// stale card (`stale_request`) or an ask that moved on; Approve and
    /// Deny go through the shared desk and are drawn only where it would
    /// send them. Nothing here ever auto-answers; disabled buttons carry
    /// the reason as a tooltip rather than silently greying.
    @ViewBuilder
    private func waitingSection(ask: CoreAsk) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: "hand.raised.fill")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(SessionActivity.waiting.tint)
                Text("Waiting on you")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(SessionActivity.waiting.tint)
                Spacer(minLength: 4)
                if let waiting = OverviewStore.waitingText(entry, now: store.now) {
                    Text(waiting).font(.system(size: 10.5)).monospacedDigit().foregroundStyle(.secondary)
                }
            }
            Text(ask.summary ?? "This session has an open question.")
                .font(.system(size: 12.5, weight: .medium))
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
            if let preview = ask.previewLine {
                HStack(alignment: .firstTextBaseline, spacing: 5) {
                    if ask.isDestructive { AskRiskMark(size: 10) }
                    Text(preview)
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(ask.isDestructive ? AnyShapeStyle(Color.red) : AnyShapeStyle(.primary.opacity(0.8)))
                        .textSelection(.enabled)
                        .lineLimit(3)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 8)
                .padding(.vertical, 5)
                .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(Color.primary.opacity(0.06)))
            } else if ask.isDestructive {
                Label("Destructive — it can lose work if it runs by mistake", systemImage: "exclamationmark.triangle.fill")
                    .font(.system(size: 10.5)).foregroundStyle(.red)
            }
            if !entry.session.remote, AskVerbs.chooses(ask) {
                // A held question: its options are the answer, through the
                // agent's own hook, from whatever terminal hosts it.
                choiceSection(ask: ask)
            } else {
                answerButtons(ask: ask)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .windowWell(padding: 12, tint: SessionActivity.waiting.tint)
    }

    @ViewBuilder
    private func answerButtons(ask: CoreAsk) -> some View {
        let reason = store.askDisabledReason(for: entry)
        HStack(spacing: 8) {
            if reason != nil || AskVerbs.approves(ask) {
                Button("Approve") {
                    Task { await store.answerAsk(entry: entry, approve: true) }
                }
                .buttonStyle(.borderedProminent).controlSize(.small).tint(.green)
            }
            if AskVerbs.alwaysAllows(ask) {
                // Its own button: the agent remembers the rule.
                Button("Always Allow") {
                    Task { await store.alwaysAllow(entry: entry) }
                }
                .buttonStyle(.bordered).controlSize(.small)
                .help("Approve, and let the agent remember the rule it offered")
            }
            if reason != nil || AskVerbs.denies(ask) {
                Button("Deny") {
                    Task { await store.answerAsk(entry: entry, approve: false) }
                }
                .buttonStyle(.bordered).controlSize(.small).tint(.red)
            }
            if store.canReply(entry) {
                Button("Reply…") { reply(entry) }
                    .buttonStyle(.bordered).controlSize(.small)
            }
        }
        .disabled(reason != nil || store.askDesk.isPending(entry.id))
        .help(reason ?? (ask.isHeldForDecision
            ? "Answered through the agent's own permission hook — the monitor's verdict is shown on the status line"
            : "Send the answer to the session's terminal — the monitor's verdict is shown on the status line"))
        if let reason {
            Label(reason, systemImage: "info.circle")
                .font(.system(size: 10.5)).foregroundStyle(.secondary)
        }
    }

    /// A held question in the inspector: every question with its options
    /// as buttons — one click answers a single-pick question; several
    /// parts pick first and then Send — and Deny, which declines it.
    @ViewBuilder
    private func choiceSection(ask: CoreAsk) -> some View {
        let choices = ask.decision?.choices ?? []
        let picks = store.askDesk.picks(for: ask)
        let oneClick = choices.count == 1 && choices.first?.multi == false
        let busy = store.askDesk.isPending(entry.id)
        VStack(alignment: .leading, spacing: 8) {
            ForEach(choices, id: \.question) { choice in
                VStack(alignment: .leading, spacing: 4) {
                    Text(choice.header.map { "\($0) — \(choice.question)" } ?? choice.question)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.secondary)
                    WrapRow {
                        ForEach(choice.options, id: \.self) { label in
                            if picks.isPicked(label, in: choice) {
                                optionButton(label, choice: choice)
                                    .buttonStyle(.borderedProminent)
                            } else {
                                optionButton(label, choice: choice)
                                    .buttonStyle(.bordered)
                            }
                        }
                    }
                }
            }
            HStack(spacing: 8) {
                if !oneClick {
                    Button("Send Answers") { Task { await store.sendPicks(entry: entry) } }
                        .buttonStyle(.borderedProminent).controlSize(.small)
                        .disabled(!picks.isComplete(choices))
                }
                Button("Deny") { Task { await store.declineQuestion(entry: entry) } }
                    .buttonStyle(.bordered).controlSize(.small).tint(.red)
            }
        }
        .disabled(busy)
    }

    private func optionButton(_ label: String, choice: CoreAskChoice) -> some View {
        Button(label) { Task { await store.pick(label, in: choice, entry: entry) } }
            .controlSize(.small)
            .help(choice.multi ? "Pick or unpick “\(label)”" : "Answer “\(label)”")
    }

    // MARK: Timeline

    /// S7.2 Timeline: the session's transcript rows — messages, tool
    /// pairs, turn ends — occurrence time on the left. "Load earlier"
    /// is the only way deeper history enters; nothing is virtualised
    /// silently past the daemon's page bound. Kind chips and "Jump to
    /// error" are display cuts over the loaded items, never new fetches.
    @ViewBuilder
    private var timelineSection: some View {
        if entry.session.remote {
            // The transcript lives on the peer Mac — a local fetch can only
            // answer "not found", which reads as broken.
            OverviewInspectorSection("Timeline") {
                Text("The transcript is on \(entry.session.origin?.label ?? "the remote Mac") — open the session there to read it.")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .windowWell(padding: 10)
            }
        } else {
            OverviewInspectorSection(title: "Timeline") {
                timelineControls
            } content: {
                timelineBody
            }
        }
    }

    private var timelineControls: some View {
        HStack(spacing: 10) {
            if store.timelineLoading { ProgressView().controlSize(.mini) }
            Button {
                Task { await store.refreshTimeline() }
            } label: {
                Image(systemName: "arrow.clockwise").font(.system(size: 10, weight: .medium))
            }
            .buttonStyle(.plain).foregroundStyle(.secondary)
            .disabled(store.timelineLoading || store.timelinePage == nil)
            .help("Reload the newest page")
            .accessibilityLabel("Refresh timeline")
            Button {
                store.prepareRunExport(entry)
            } label: {
                Image(systemName: "square.and.arrow.up").font(.system(size: 10, weight: .medium))
            }
            .buttonStyle(.plain).foregroundStyle(.secondary)
            .disabled(store.timelinePage == nil || store.timelineSessionID != entry.id)
            .help("Export this run as Markdown: its facts, what happened and the timeline")
            .accessibilityLabel("Export this run as Markdown")
            if let page = store.timelinePage, store.timelineSessionID == entry.id, page.hasMore {
                Button("Load earlier") { Task { await store.loadEarlierTimeline() } }
                    .controlSize(.mini)
            }
        }
    }

    @ViewBuilder
    private var timelineBody: some View {
        if store.timelineSessionID == entry.id {
            if let page = store.timelinePage {
                // The one timeline view History and the Data Hoarder mount
                // too: the story card, the honest gaps, the kind chips, jump
                // to error and the rows.
                if let archived = store.archivedTimeline, archived.id == entry.id {
                    // The live transcript is gone but the Data Hoarder kept
                    // it: the same view, labelled as the archive's.
                    ReconstructedTimelineView(
                        reconstruction: archived.reconstruction,
                        viewState: store.timelineViewState, embedded: true,
                        sourceNote: "Archived copy · \(archived.record.name) — the live transcript is gone")
                } else {
                    ReconstructedTimelineView(reconstruction: store.timelineReconstruction,
                                              viewState: store.timelineViewState, embedded: true,
                                              liveTail: OverviewStore.liveTail(for: entry))
                }
                if page.gaps.contains("transcript_not_found"), store.onOpenArchive != nil {
                    Button {
                        store.onOpenArchive?(OverviewStore.archiveSearchTerm(for: entry))
                    } label: {
                        Label("Search archive for this session", systemImage: "archivebox")
                            .font(.system(size: 10.5))
                    }
                    .buttonStyle(.plain).foregroundStyle(.orange)
                    .help("Open Data Hoarder seeded with this session's id")
                }
                if let file = page.file {
                    archiveSourceLine(file: file, total: page.total)
                }
            } else if store.timelineLoading {
                HStack(spacing: 6) {
                    ProgressView().controlSize(.mini)
                    Text("Reading transcript…").font(.system(size: 11)).foregroundStyle(.tertiary)
                }
            }
        }
    }

    /// The transcript's source line: path + item count, plus the Data
    /// Hoarder's verdict when the archive probe answered — "Archived"
    /// with a Reveal affordance, or nothing when the archive can't say.
    @ViewBuilder
    private func archiveSourceLine(file: String, total: Int) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text("Source: \(file) · \(total) items")
                .font(.system(size: 9.5)).foregroundStyle(.tertiary)
                .textSelection(.enabled)
            if let state = store.archiveStates[file], let row = state {
                HStack(spacing: 6) {
                    Text("Archived")
                        .font(.system(size: 8.5, weight: .semibold))
                        .padding(.horizontal, 5).padding(.vertical, 1.5)
                        .background(Color.green.opacity(0.15), in: .capsule)
                        .foregroundStyle(.green)
                    Button("Reveal") {
                        NSWorkspace.shared.activateFileViewerSelecting(
                            [URL(fileURLWithPath: row.path)])
                    }
                    .buttonStyle(.plain).font(.system(size: 9.5))
                    .foregroundStyle(.secondary)
                    .help("Show the transcript in Finder")
                }
            }
        }
        .task { await store.probeArchive(file: file) }
    }

    // MARK: Observed tools

    /// The tools and MCP servers this run actually called, from the
    /// transcript already loaded for the Timeline — observed, not static,
    /// and it works for Claude Code and Codex, which no static analyzer
    /// scans. Failures ride beside the counts.
    @ViewBuilder
    private var observedToolsSection: some View {
        let map = store.observedTools
        if store.timelineSessionID == entry.id, !map.isEmpty {
            OverviewInspectorSection(title: "Tools used") {
                HStack(spacing: 6) {
                    Text("observed")
                        .font(.system(size: 8.5, weight: .semibold))
                        .padding(.horizontal, 5).padding(.vertical, 1.5)
                        .background(Color.accentColor.opacity(0.14), in: .capsule)
                        .foregroundStyle(Color.accentColor)
                    Text("\(map.totalCalls) calls in the loaded transcript")
                        .font(.system(size: 10)).foregroundStyle(.tertiary)
                }
            } content: {
                VStack(alignment: .leading, spacing: 6) {
                    if !map.tools.isEmpty {
                        Text(map.tools.prefix(10).map(Self.toolText).joined(separator: " · "))
                            .font(.system(size: 11)).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                            .textSelection(.enabled)
                    }
                    ForEach(map.servers) { server in
                        HStack(alignment: .firstTextBaseline, spacing: 5) {
                            Image(systemName: "server.rack")
                                .font(.system(size: 9)).foregroundStyle(.tertiary)
                            Text(server.name).font(.system(size: 11, weight: .medium)).foregroundStyle(.secondary)
                            Text(server.tools.prefix(6).map(Self.toolText).joined(separator: " · "))
                                .font(.system(size: 11)).foregroundStyle(.tertiary)
                                .lineLimit(2)
                        }
                        .help("MCP server \(server.name): \(server.calls) calls")
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .windowWell(padding: 10)
            }
        }
    }

    /// "Bash ×12 (2 failed)".
    private static func toolText(_ tool: ObservedToolMap.Tool) -> String {
        tool.failures > 0 ? "\(tool.name) ×\(tool.calls) (\(tool.failures) failed)" : "\(tool.name) ×\(tool.calls)"
    }

    // MARK: Actions

    /// The way to the session: its terminal, named — "Open in iTerm",
    /// never a bare promise — and a fresh run in the same folder.
    @ViewBuilder
    private var actions: some View {
        if entry.session.remote {
            Label("Remote row — open it on \(entry.session.origin?.label ?? "that Mac").", systemImage: "network")
                .font(.system(size: 11)).foregroundStyle(.secondary)
        } else {
            let app = entry.session.terminal?.app
            HStack(spacing: 8) {
                Button(app.map { "Open in \($0)" } ?? "Open session") { store.openSelected() }
                    .buttonStyle(.borderedProminent).controlSize(.small)
                if store.canStartHere(entry) {
                    // A fresh run in the same folder, in your own
                    // terminal — the first prompt is yours.
                    Button("New Session Here") { Task { await store.startSessionHere(entry) } }
                        .buttonStyle(.bordered).controlSize(.small)
                        .help("Start \(style.name) in your terminal at \(entry.session.cwd ?? "this folder")")
                }
            }
        }
    }
}

/// A session's state as a small tinted capsule: its dot and its word.
struct OverviewStatePill: View {
    let activity: SessionActivity

    private var calm: Bool { activity == .idle || activity == .ended }

    var body: some View {
        HStack(spacing: 4) {
            Circle().fill(activity.tint).frame(width: 6, height: 6)
            Text(activity.word)
                .font(.system(size: 10.5, weight: .semibold))
                .foregroundStyle(activity.wordIsLoud ? activity.tint : Color.primary.opacity(0.8))
        }
        .padding(.horizontal, 7)
        .padding(.vertical, 2)
        .background(Capsule().fill(activity.tint.opacity(calm ? 0.10 : 0.14)))
        .accessibilityElement(children: .combine)
        .accessibilityLabel("State: \(activity.word)")
    }
}

// MARK: - Connections

/// A focused chip's facts — the same labelled grid the session inspector
/// uses, every line carrying the daemon's own words.
struct OverviewConnectionInspector: View {
    let link: OverviewLink

    var body: some View {
        SnapshotScrollView {
            VStack(alignment: .leading, spacing: 18) {
                HStack(alignment: .center, spacing: 11) {
                    OverviewLinkGlyph(link: link, size: 30)
                        .frame(width: 32, height: 32)
                        .background(RoundedRectangle(cornerRadius: 9, style: .continuous)
                            .fill(link.group == .providers ? Color.clear : Color.primary.opacity(0.06)))
                    VStack(alignment: .leading, spacing: 3) {
                        Text(link.title)
                            .font(.system(size: 15, weight: .semibold))
                            .lineLimit(2)
                        HStack(spacing: 5) {
                            Circle().fill(link.tone.color).frame(width: 6, height: 6)
                            Text(link.subtitle ?? link.group.title)
                                .font(.system(size: 11.5))
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                OverviewInspectorSection(link.group.title) {
                    Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 6) {
                        ForEach(link.facts, id: \.label) { item in
                            OverviewFactRow(name: item.label, value: item.value, evidence: .reported)
                        }
                    }
                    .font(.system(size: 11.5))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .windowWell(padding: 12)
                }
            }
            .padding(18)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(minWidth: 220)
    }
}

/// The inspector's idle state: the whole wiring, grouped — core, nodes,
/// devices, providers — so an empty roster still answers "what is
/// connected". A row focuses that link.
struct OverviewConnectionsBrowser: View {
    @Bindable var store: OverviewStore

    var body: some View {
        SnapshotScrollView {
            VStack(alignment: .leading, spacing: 16) {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Connections")
                        .font(.system(size: 15, weight: .semibold))
                    Text("Select a session row for its inspector.")
                        .font(.system(size: 11.5))
                        .foregroundStyle(.secondary)
                }
                ForEach(OverviewLink.Group.allCases, id: \.self) { group in
                    let links = store.links.filter { $0.group == group }
                    if !links.isEmpty {
                        OverviewInspectorSection(group.title) {
                            VStack(spacing: 0) {
                                ForEach(Array(links.enumerated()), id: \.element.id) { index, link in
                                    if index > 0 { Divider().padding(.leading, 34) }
                                    OverviewConnectionRow(link: link) { store.selectLink(link.id) }
                                }
                            }
                            .windowWell(padding: 4)
                        }
                    }
                }
            }
            .padding(18)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(minWidth: 220)
    }
}

/// One connection in the browser: its mark, its name, what it says, and
/// its status dot at the end.
struct OverviewConnectionRow: View {
    let link: OverviewLink
    let action: () -> Void
    @ViewState private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 9) {
                OverviewLinkGlyph(link: link, size: 16)
                    .frame(width: 18)
                Text(link.title)
                    .font(.system(size: 12, weight: .medium))
                    .lineLimit(1)
                Spacer(minLength: 6)
                if let subtitle = link.subtitle {
                    Text(subtitle)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Circle().fill(link.tone.color).frame(width: 6, height: 6)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 7)
            .background(RoundedRectangle(cornerRadius: 7, style: .continuous)
                .fill(Color.primary.opacity(hovering ? 0.05 : 0)))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help(link.helpText)
        .accessibilityLabel(OverviewView.chipLabel(link))
    }
}

/// "5 h window share" — which session is spending the quota
/// (Agent Sessions' Quota Meter), as one inspector fact. The session's
/// tokens since its provider's primary window opened (`window_tokens`,
/// the daemon's) over every session of that provider JR-Bar has read in
/// the same window: derived, never reported, so it wears ≈ and hides
/// entirely while the daemon gives no window tokens.
enum OverviewWindowShare {
    static let explanation = "Derived: this session's tokens since the provider's usage window opened, over every session of that provider JR-Bar has read in the window."

    /// The session's fraction of its provider's window, 0…1; nil while
    /// its window tokens are unknown or nothing was spent.
    static func share(tokens: Int?, provider: String, readings: [SessionUsage]) -> Double? {
        guard let tokens, tokens >= 0 else { return nil }
        let total = readings
            .filter { $0.provider == provider }
            .compactMap(\.windowTokens)
            .reduce(0) { $0 + max(0, $1) }
        let whole = max(total, tokens)
        guard whole > 0 else { return nil }
        return Double(tokens) / Double(whole)
    }

    /// The fact's name and value: "5 h window share", "≈ 34 %".
    static func fact(for usage: SessionUsage, provider: String,
                     readings: [SessionUsage]) -> (name: String, value: String)? {
        guard let fraction = share(tokens: usage.windowTokens, provider: provider, readings: readings) else {
            return nil
        }
        let percent = fraction * 100
        let value = percent > 0 && percent < 1 ? "≈ <1 %" : "≈ \(Int(percent.rounded())) %"
        // Claude's and Codex's primary windows are five hours; the rest
        // are named only as the window. Short enough for the facts'
        // name column, with the "5 h" kept on one line.
        let name = ["claude", "codex"].contains(provider) ? "5\u{00A0}h window share" : "Window share"
        return (name, value)
    }
}

