import SwiftUI
import JRBarCore

/// Mutable UI state for `ReconstructedTimelineView`, owned by whoever mounts
/// it (the archive model, the Overview store, a History row) so the kind filter
/// and disclosure survive redraws. It is an `@Observable` object rather than
/// `@State` because this toolchain lacks the SwiftUIMacros plugin — `@State`
/// is a macro in the macOS 27 SDK and cannot expand here.
@Observable
final class ReconstructedTimelineViewState {
    var kind: ReconstructedTimelineView.KindFilter = .all
    var gapsExpanded = false
}

/// The one session timeline every pane mounts: the Data Hoarder's archived
/// records, the Overview inspector's live transcript
/// (`SessionReconstructor.reconstruction(from:running:)`), and History's
/// expanded rows. It takes a `SessionReconstruction` (produced off-main)
/// and stays provider-agnostic, so a fix to how a tool call or a failure
/// reads lands everywhere at once. When a CLIProxyAPI proxy logged the
/// session's requests, they sit between the turns as evidence rows.
struct ReconstructedTimelineView: View {
    let reconstruction: SessionReconstruction
    @Bindable var viewState: ReconstructedTimelineViewState
    /// Inside a pane that already scrolls (the Overview inspector): the
    /// rows lay out inline instead of in a scroll view of their own.
    var embedded = false
    /// Where the rows came from, when it is worth a word ("archived
    /// copy"); nil says nothing.
    var sourceNote: String? = nil

    enum KindFilter: String, CaseIterable {
        case all = "All"
        case messages = "Messages"
        case tools = "Tools"
        case errors = "Errors"
        /// The proxy's requests alone; offered only when there are some.
        case requests = "Requests"
    }

    private var kind: KindFilter {
        get { viewState.kind }
        nonmutating set { viewState.kind = newValue }
    }

    var body: some View {
        let entries = reconstruction.entries
        VStack(alignment: .leading, spacing: 8) {
            if let sourceNote {
                Label(sourceNote, systemImage: "archivebox")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
            }
            storyCard
            if let upstream = SessionProxyEvidence.summary(reconstruction.proxyRequests) {
                // The proxy's side of the story: retries and refusals
                // the transcript never records.
                Label("Upstream: \(upstream)", systemImage: "network")
                    .font(.system(size: 10))
                    .foregroundStyle(.orange)
                    .help("From the CLIProxyAPI request logs filed under this session")
            }
            if !reconstruction.gaps.isEmpty || reconstruction.redactedLines > 0 {
                gapsDisclosure
            }
            if !entries.isEmpty {
                filterChips(entries)
            }
            listArea(entries)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    // MARK: "What happened"

    @ViewBuilder private var storyCard: some View {
        if reconstruction.story.failed {
            VStack(alignment: .leading, spacing: 4) {
                Label("What happened", systemImage: "exclamationmark.triangle.fill")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.orange)
                Text(Self.storyText(reconstruction.story))
                    .font(.system(size: 12))
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.orange.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
        } else {
            Text("No failures in these rows")
                .font(.system(size: 10))
                .foregroundStyle(.tertiary)
        }
    }

    /// Compose only what the story actually knows: intent, the last error,
    /// mid-turn death, and the failed tool names — nils drop out silently.
    static func storyText(_ story: FailureStory) -> String {
        var parts: [String] = []
        if let intent = story.lastUserIntent, !intent.isEmpty {
            parts.append("Last asked: \(intent)")
        }
        if let summary = story.lastErrorSummary, !summary.isEmpty {
            parts.append("Then \(summary)")
        } else if story.errorCount > 0 {
            parts.append("\(story.errorCount) \(story.errorCount == 1 ? "error" : "errors") in these rows")
        }
        if story.diedMidTurn {
            parts.append("The session ended mid-turn")
        }
        if !story.failedToolNames.isEmpty {
            parts.append("Failed tools: \(story.failedToolNames.joined(separator: ", "))")
        }
        guard !parts.isEmpty else { return "These rows show a failure." }
        return parts.joined(separator: ". ") + "."
    }

    // MARK: Honest gaps

    private var gapsDisclosure: some View {
        DisclosureGroup(isExpanded: $viewState.gapsExpanded) {
            VStack(alignment: .leading, spacing: 2) {
                ForEach(reconstruction.gaps, id: \.self) { gap in
                    Text("· \(Self.gapText(gap))")
                }
                if reconstruction.redactedLines > 0 {
                    Text("· \(reconstruction.redactedLines) \(reconstruction.redactedLines == 1 ? "line" : "lines") stored with text withheld (metadata-only capture)")
                }
                Text("· \(reconstruction.totalLines) transcript \(reconstruction.totalLines == 1 ? "row" : "rows") read")
            }
            .font(.system(size: 10))
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.top, 2)
        } label: {
            Text(gapSummary)
                .font(.system(size: 10))
                .foregroundStyle(.orange)
        }
    }

    private var gapSummary: String {
        var parts = reconstruction.gaps.map(Self.gapText)
        if reconstruction.redactedLines > 0 {
            parts.append("\(reconstruction.redactedLines) redacted")
        }
        return parts.joined(separator: " · ")
    }

    /// Named-gap strings → plain words. Unknown gaps pass through — honesty
    /// beats a swallowed label.
    static func gapText(_ gap: String) -> String {
        if gap.hasPrefix("malformed_lines:") {
            let count = gap.dropFirst("malformed_lines:".count)
            return "\(count) malformed \(count == "1" ? "line" : "lines")"
        }
        if gap.hasPrefix("item_cap:") {
            return "item cap reached (\(gap.dropFirst("item_cap:".count))) — later rows omitted"
        }
        if gap.hasPrefix("transcript_too_large:") {
            return "transcript too large to rebuild (\(gap.dropFirst("transcript_too_large:".count)) bytes)"
        }
        if gap.hasPrefix("timeline_item_cap:") {
            return "transcript exceeds the item cap — earliest rows omitted"
        }
        switch gap {
        case "unsupported_provider":
            return "this provider's transcript format is not read yet"
        case "transcript_not_found":
            return "no transcript found for this session"
        case "transcript_unreadable":
            return "the transcript file could not be read"
        default:
            return gap.hasPrefix("gap:") ? "capture gap: \(gap.dropFirst(4))" : gap
        }
    }

    // MARK: Kind chips + jump

    static func filtered(_ entries: [SessionProxyEvidence.Entry],
                         by kind: KindFilter) -> [SessionProxyEvidence.Entry] {
        switch kind {
        case .all: return entries
        case .errors: return entries.filter(\.isError)
        case .messages, .tools, .requests:
            return entries.filter { entry in
                switch entry {
                case .item(let item):
                    return kind == .messages ? item.kind == .message
                        : kind == .tools && (item.kind == .toolUse || item.kind == .toolResult)
                case .request:
                    return kind == .requests
                }
            }
        }
    }

    private static func kindCounts(_ entries: [SessionProxyEvidence.Entry])
        -> (messages: Int, tools: Int, errors: Int, requests: Int) {
        var messages = 0, tools = 0, errors = 0, requests = 0
        for entry in entries {
            switch entry {
            case .item(let item):
                switch item.kind {
                case .message: messages += 1
                case .toolUse, .toolResult: tools += 1
                case .turnEnd: break
                }
            case .request:
                requests += 1
            }
            if entry.isError { errors += 1 }
        }
        return (messages, tools, errors, requests)
    }

    private func filterChips(_ entries: [SessionProxyEvidence.Entry]) -> some View {
        HStack(spacing: 5) {
            let counts = Self.kindCounts(entries)
            ForEach(KindFilter.allCases.filter { $0 != .requests || counts.requests > 0 }, id: \.self) { filter in
                let label: String = switch filter {
                case .all: "All \(entries.count)"
                case .messages: "Messages \(counts.messages)"
                case .tools: "Tools \(counts.tools)"
                case .errors: "Errors \(counts.errors)"
                case .requests: "Requests \(counts.requests)"
                }
                Button {
                    kind = filter
                } label: {
                    Text(label)
                        .font(.system(size: 9, weight: kind == filter ? .semibold : .regular))
                        .padding(.horizontal, 6).padding(.vertical, 2)
                        .background(
                            Capsule().fill(kind == filter
                                ? Color.accentColor.opacity(0.18) : .primary.opacity(0.06)))
                }
                .buttonStyle(.plain)
                .foregroundStyle(filter == .errors && counts.errors > 0 ? .red : .secondary)
                .accessibilityLabel("Show \(filter.rawValue.lowercased()) timeline rows")
            }
        }
    }

    @ViewBuilder private func listArea(_ entries: [SessionProxyEvidence.Entry]) -> some View {
        let shown = Self.filtered(entries, by: kind)
        if shown.isEmpty {
            Text(entries.isEmpty
                 ? "No timeline rows could be rebuilt from the stored segments."
                 : "No \(kind.rawValue.lowercased()) rows.")
                .font(.system(size: 11))
                .foregroundStyle(.tertiary)
        } else {
            let firstError = entries.first(where: \.isError)?.id
            ScrollViewReader { proxy in
                VStack(alignment: .leading, spacing: 5) {
                    if let firstError {
                        Button {
                            // A kind filter can leave the error row
                            // unrendered — scrollTo needs a live
                            // target, so switch first.
                            if kind != .all && kind != .errors { kind = .errors }
                            withAnimation { proxy.scrollTo(firstError, anchor: .top) }
                        } label: {
                            Label("Jump to error", systemImage: "arrow.down.to.line")
                                .font(.system(size: 10))
                        }
                        .buttonStyle(.plain).foregroundStyle(.red)
                    }
                    if embedded {
                        rows(shown)
                    } else {
                        ScrollView {
                            rows(shown).padding(.bottom, 4)
                        }
                    }
                }
            }
        }
    }

    private func rows(_ shown: [SessionProxyEvidence.Entry]) -> some View {
        LazyVStack(alignment: .leading, spacing: 5) {
            ForEach(shown) { entry in
                Group {
                    switch entry {
                    case .item(let item): row(item)
                    case .request(_, let request): requestRow(request)
                    }
                }
                .id(entry.id)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// A proxied request between the turns: the request line, the model,
    /// retries, and the upstream's error text when it refused.
    private func requestRow(_ request: CLIProxyRequest) -> some View {
        let failed = SessionProxyEvidence.failed(request)
        return HStack(alignment: .firstTextBaseline, spacing: 6) {
            Text(request.timestamp.map { Self.clock.string(from: $0) } ?? "—")
                .font(.system(size: 9, design: .monospaced))
                .foregroundStyle(.quaternary)
                .frame(width: 40, alignment: .leading)
            Image(systemName: "network")
                .font(.system(size: 9))
                .foregroundStyle(failed ? Color.red : Color.secondary)
                .frame(width: 12)
            VStack(alignment: .leading, spacing: 1) {
                Text(SessionProxyEvidence.line(request))
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(failed ? Color.red : Color.secondary)
                    .lineLimit(1)
                    .textSelection(.enabled)
                if failed, let summary = request.errorSummary {
                    Text(summary)
                        .font(.system(size: 10))
                        .foregroundStyle(.red)
                        .lineLimit(2)
                        .textSelection(.enabled)
                }
            }
            Text("proxy")
                .font(.system(size: 8, weight: .medium))
                .padding(.horizontal, 4).padding(.vertical, 1)
                .background(Color.secondary.opacity(0.12), in: .capsule)
                .foregroundStyle(.secondary)
        }
        .accessibilityElement(children: .combine)
    }

    // MARK: Rows

    private func row(_ item: ReconstructedItem) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Text(item.at.map { Self.clock.string(from: Date(timeIntervalSince1970: $0)) } ?? "—")
                .font(.system(size: 9, design: .monospaced))
                .foregroundStyle(.quaternary)
                .frame(width: 40, alignment: .leading)
            Image(systemName: Self.symbol(item))
                .font(.system(size: 9))
                .foregroundStyle(Self.tint(item))
                .frame(width: 12)
            rowBody(item)
            if item.sidechain {
                Text("subagent")
                    .font(.system(size: 8, weight: .medium))
                    .padding(.horizontal, 4).padding(.vertical, 1)
                    .background(Color.purple.opacity(0.15), in: .capsule)
                    .foregroundStyle(.purple)
            }
        }
        .padding(.leading, (item.kind == .toolResult ? 12 : 0) + (item.sidechain ? 10 : 0))
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder
    private func rowBody(_ item: ReconstructedItem) -> some View {
        switch item.kind {
        case .message:
            VStack(alignment: .leading, spacing: 1) {
                if let role = item.role {
                    Text(role == "user" ? "you" : role)
                        .font(.system(size: 9, weight: .medium))
                        .foregroundStyle(Self.roleTint(role))
                }
                itemText(item)
                if let model = item.model {
                    Text(model)
                        .font(.system(size: 8))
                        .foregroundStyle(.quaternary)
                }
            }
        case .toolUse:
            VStack(alignment: .leading, spacing: 2) {
                Text(item.name ?? "tool")
                    .font(.system(size: 9, weight: .medium))
                    .padding(.horizontal, 5).padding(.vertical, 1)
                    .background(
                        (item.isError ? Color.red : Color.accentColor).opacity(0.15),
                        in: .capsule)
                    .foregroundStyle(item.isError ? .red : .accentColor)
                if item.redacted {
                    redactedText
                } else if let text = item.text {
                    Text(text)
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                        .lineLimit(3)
                        .textSelection(.enabled)
                }
            }
        case .toolResult:
            if item.redacted {
                redactedText
            } else if let text = item.text {
                Text(text)
                    .font(.system(size: 10))
                    .foregroundStyle(item.isError ? .red : .secondary)
                    .lineLimit(4)
                    .textSelection(.enabled)
            } else {
                Text(item.isError ? "failed" : "done")
                    .font(.system(size: 10))
                    .foregroundStyle(item.isError ? Color.red : Color.secondary)
            }
        case .turnEnd:
            Text(item.name.map { "turn end · \($0)" } ?? "turn end")
                .font(.system(size: 10))
                .foregroundStyle(item.isError ? Color.orange : Color.secondary)
        }
    }

    @ViewBuilder
    private func itemText(_ item: ReconstructedItem) -> some View {
        if item.redacted {
            redactedText
        } else if let text = item.text {
            Text(text)
                .font(.system(size: 11))
                .textSelection(.enabled)
        }
    }

    private var redactedText: some View {
        Text("redacted")
            .font(.system(size: 10))
            .italic()
            .foregroundStyle(.secondary)
    }

    private static func symbol(_ item: ReconstructedItem) -> String {
        switch item.kind {
        case .message: item.role == "user" ? "person" : "sparkle"
        case .toolUse: "wrench.and.screwdriver"
        case .toolResult: item.isError ? "xmark.octagon" : "checkmark.circle"
        case .turnEnd: "flag.checkered"
        }
    }

    private static func tint(_ item: ReconstructedItem) -> Color {
        if item.isError { return .red }
        switch item.kind {
        case .message: return roleTint(item.role)
        case .toolUse: return .accentColor
        case .toolResult: return .green
        case .turnEnd: return .secondary
        }
    }

    private static func roleTint(_ role: String?) -> Color {
        switch role {
        case "user": return .accentColor
        case "assistant": return .purple
        default: return .secondary
        }
    }

    private static let clock: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss"
        return formatter
    }()
}
