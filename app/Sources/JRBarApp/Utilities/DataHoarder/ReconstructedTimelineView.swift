import SwiftUI
import JRBarCore

/// Mutable UI state for `ReconstructedTimelineView`, owned by whoever mounts
/// it (the archive model today, an Overview store later) so the kind filter
/// and disclosure survive redraws. It is an `@Observable` object rather than
/// `@State` because this toolchain lacks the SwiftUIMacros plugin — `@State`
/// is a macro in the macOS 27 SDK and cannot expand here.
@Observable
final class ReconstructedTimelineViewState {
    var kind: ReconstructedTimelineView.KindFilter = .all
    var gapsExpanded = false
}

/// A rebuilt session timeline — the archived-record twin of the Overview's
/// live transcript rows. Takes a `SessionReconstruction` (produced off-main)
/// and stays provider-agnostic so any pane can mount it: the Data Hoarder
/// detail today, the Overview later.
struct ReconstructedTimelineView: View {
    let reconstruction: SessionReconstruction
    @Bindable var viewState: ReconstructedTimelineViewState

    enum KindFilter: String, CaseIterable {
        case all = "All"
        case messages = "Messages"
        case tools = "Tools"
        case errors = "Errors"
    }

    private var kind: KindFilter {
        get { viewState.kind }
        nonmutating set { viewState.kind = newValue }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            storyCard
            if !reconstruction.gaps.isEmpty || reconstruction.redactedLines > 0 {
                gapsDisclosure
            }
            if !reconstruction.items.isEmpty {
                filterChips
            }
            listArea
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
            Text("No failures in the captured portion")
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
            parts.append("\(story.errorCount) \(story.errorCount == 1 ? "error" : "errors") in the captured portion")
        }
        if story.diedMidTurn {
            parts.append("The session ended mid-turn")
        }
        if !story.failedToolNames.isEmpty {
            parts.append("Failed tools: \(story.failedToolNames.joined(separator: ", "))")
        }
        guard !parts.isEmpty else { return "The captured portion shows a failure." }
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
                Text("· \(reconstruction.totalLines) transcript \(reconstruction.totalLines == 1 ? "line" : "lines") read")
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
        switch gap {
        case "unsupported_provider":
            return "this provider's transcript format is not read yet"
        default:
            return gap.hasPrefix("gap:") ? "capture gap: \(gap.dropFirst(4))" : gap
        }
    }

    // MARK: Kind chips + jump

    private var filteredItems: [ReconstructedItem] {
        switch kind {
        case .all: return reconstruction.items
        case .messages: return reconstruction.items.filter { $0.kind == .message }
        case .tools: return reconstruction.items.filter { $0.kind == .toolUse || $0.kind == .toolResult }
        case .errors: return reconstruction.items.filter(\.isError)
        }
    }

    private var kindCounts: (messages: Int, tools: Int, errors: Int) {
        var messages = 0, tools = 0, errors = 0
        for item in reconstruction.items {
            switch item.kind {
            case .message: messages += 1
            case .toolUse, .toolResult: tools += 1
            case .turnEnd: break
            }
            if item.isError { errors += 1 }
        }
        return (messages, tools, errors)
    }

    private var firstErrorSeq: Int? {
        reconstruction.items.first(where: \.isError)?.seq
    }

    private var filterChips: some View {
        HStack(spacing: 5) {
            let counts = kindCounts
            ForEach(KindFilter.allCases, id: \.self) { filter in
                let label: String = switch filter {
                case .all: "All \(reconstruction.items.count)"
                case .messages: "Messages \(counts.messages)"
                case .tools: "Tools \(counts.tools)"
                case .errors: "Errors \(counts.errors)"
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

    @ViewBuilder private var listArea: some View {
        if filteredItems.isEmpty {
            Text(reconstruction.items.isEmpty
                 ? "No timeline rows could be rebuilt from the stored segments."
                 : "No \(kind.rawValue.lowercased()) rows.")
                .font(.system(size: 11))
                .foregroundStyle(.tertiary)
        } else {
            ScrollViewReader { proxy in
                VStack(alignment: .leading, spacing: 5) {
                    if firstErrorSeq != nil {
                        Button {
                            if let seq = firstErrorSeq {
                                withAnimation { proxy.scrollTo(seq, anchor: .top) }
                            }
                        } label: {
                            Label("Jump to error", systemImage: "arrow.down.to.line")
                                .font(.system(size: 10))
                        }
                        .buttonStyle(.plain).foregroundStyle(.red)
                    }
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 5) {
                            ForEach(filteredItems, id: \.seq) { item in
                                row(item).id(item.seq)
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.bottom, 4)
                    }
                }
            }
        }
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
