import JRBarUI
import SwiftUI
import JRBarCore

/// Mutable UI state for `ReconstructedTimelineView`, owned by whoever mounts
/// it (the Overview store, a History row) so the kind filter
/// and disclosure survive redraws. It is an `@Observable` object rather than
/// `@State` because this toolchain lacks the SwiftUIMacros plugin — `@State`
/// is a macro in the macOS 27 SDK and cannot expand here.
@Observable
final class ReconstructedTimelineViewState {
    var kind: ReconstructedTimelineView.KindFilter = .all
    var gapsExpanded = false
}

/// The one session timeline every pane mounts: the Overview inspector's
/// live transcript (`SessionReconstructor.reconstruction(from:running:)`)
/// and History's expanded rows. It takes a `SessionReconstruction`
/// (produced off-main) and stays provider-agnostic, so a fix to how a tool
/// call or a failure reads lands everywhere at once.
struct ReconstructedTimelineView: View {
    let reconstruction: SessionReconstruction
    @Bindable var viewState: ReconstructedTimelineViewState
    /// Inside a pane that already scrolls (the Overview inspector): the
    /// rows lay out inline instead of in a scroll view of their own.
    var embedded = false
    /// Open scrolled to the first failure, the tool calls that led to it
    /// just above — for panes whose job is reconstructing what went wrong
    /// (a failed History row). Only inside its own scroll.
    var landOnFailure = false
    /// What a working run is doing right now, from its hook ("running
    /// Bash") — drawn as the last row, below everything the transcript
    /// has written so far; nil for a run that is not working.
    var liveTail: String? = nil

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
        let entries = reconstruction.items
        VStack(alignment: .leading, spacing: 10) {
            storyCard
            if !reconstruction.gaps.isEmpty {
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
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Tone.neutral.color)
                    .frame(width: 24, height: 24)
                    .background(Circle().fill(Tone.neutral.color.opacity(0.16)))
                VStack(alignment: .leading, spacing: 3) {
                    Text("What happened")
                        .font(.system(size: 11.5, weight: .semibold))
                        .foregroundStyle(Tone.neutral.color)
                    Text(Self.storyText(reconstruction.story))
                        .font(.system(size: 12))
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Tone.neutral.color.opacity(0.08)))
            .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(Tone.neutral.color.opacity(0.22), lineWidth: 0.5))
        } else {
            Label("No failures in these rows", systemImage: "checkmark.circle.fill")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .symbolRenderingMode(.multicolor)
        }
    }

    /// Compose only what the story actually knows: intent, the last error,
    /// mid-turn death, and the failed tool names — nils drop out silently.
    /// The Markdown export reads the same sentence.
    static func storyText(_ story: FailureStory) -> String { story.sentence }

    // MARK: Honest gaps

    private var gapsDisclosure: some View {
        DisclosureGroup(isExpanded: $viewState.gapsExpanded) {
            VStack(alignment: .leading, spacing: 2) {
                ForEach(reconstruction.gaps, id: \.self) { gap in
                    Text("· \(Self.gapText(gap))")
                }
                Text("· \(reconstruction.totalLines) transcript \(reconstruction.totalLines == 1 ? "row" : "rows") read")
            }
            .jrbarType(.caption)
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.top, 2)
        } label: {
            Text(gapSummary)
                .font(.system(size: 11))
                .foregroundStyle(Tone.neutral.color)
        }
    }

    private var gapSummary: String {
        reconstruction.gaps.map(Self.gapText).joined(separator: " · ")
    }

    /// Named-gap strings → plain words (shared with the Markdown export).
    /// Unknown gaps pass through — honesty beats a swallowed label.
    static func gapText(_ gap: String) -> String { ReconstructionGap.text(gap) }

    // MARK: Kind chips + jump

    static func filtered(_ items: [ReconstructedItem], by kind: KindFilter) -> [ReconstructedItem] {
        switch kind {
        case .all: return items
        case .errors: return items.filter(\.isError)
        case .messages: return items.filter { $0.kind == .message }
        case .tools: return items.filter { $0.kind == .toolUse || $0.kind == .toolResult }
        }
    }

    private static func kindCounts(_ items: [ReconstructedItem]) -> (messages: Int, tools: Int, errors: Int) {
        var messages = 0, tools = 0, errors = 0
        for item in items {
            switch item.kind {
            case .message: messages += 1
            case .toolUse, .toolResult: tools += 1
            case .turnEnd: break
            }
            if item.isError { errors += 1 }
        }
        return (messages, tools, errors)
    }

    private func filterChips(_ items: [ReconstructedItem]) -> some View {
        let counts = Self.kindCounts(items)
        return HStack(spacing: 4) {
            ForEach(KindFilter.allCases, id: \.self) { filter in
                let count: Int = switch filter {
                case .all: items.count
                case .messages: counts.messages
                case .tools: counts.tools
                case .errors: counts.errors
                }
                chip(filter, count: count, alarm: filter == .errors && counts.errors > 0)
            }
        }
    }

    /// One kind chip: its word and count; the picked one sits on a
    /// neutral plate, and Errors turns red once there are any.
    private func chip(_ filter: KindFilter, count: Int, alarm: Bool) -> some View {
        let picked = kind == filter
        let ink: Color = alarm ? Tone.failure.color : (picked ? .primary : .secondary)
        return Button {
            kind = filter
        } label: {
            HStack(spacing: 4) {
                Text(filter.rawValue)
                    .jrbarType(.caption).fontWeight(picked ? .semibold : .medium)
                Text("\(count)")
                    .jrbarType(.caption).fontWeight(.semibold).monospacedDigit()
                    .opacity(0.7)
            }
            .foregroundStyle(ink)
            .padding(.horizontal, 8)
            .frame(height: 22)
            .background(Capsule().fill(picked ? Color.primary.opacity(0.11) : Color.primary.opacity(0.04)))
            .overlay(Capsule().strokeBorder(Color.primary.opacity(picked ? 0.14 : 0), lineWidth: 0.5))
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Show \(filter.rawValue.lowercased()) timeline rows")
    }

    @ViewBuilder private func listArea(_ entries: [ReconstructedItem]) -> some View {
        let shown = Self.filtered(entries, by: kind)
        if shown.isEmpty {
            Text(entries.isEmpty
                 ? "No timeline rows could be rebuilt from the stored segments."
                 : "No \(kind.rawValue.lowercased()) rows.")
                .font(.system(size: 11))
                .foregroundStyle(.tertiary)
        } else {
            let firstError = entries.first(where: \.isError).map(Self.rowID)
            ScrollViewReader { proxy in
                VStack(alignment: .leading, spacing: 8) {
                    if let firstError {
                        Button {
                            // A kind filter can leave the error row
                            // unrendered — scrollTo needs a live
                            // target, so switch first.
                            if kind != .all && kind != .errors { kind = .errors }
                            withAnimation { proxy.scrollTo(firstError, anchor: .top) }
                        } label: {
                            Label("Jump to error", systemImage: "arrow.down.to.line")
                                .jrbarType(.caption).fontWeight(.medium)
                                .padding(.horizontal, 8)
                                .frame(height: 20)
                                .background(Capsule().fill(Tone.failure.color.opacity(0.1)))
                        }
                        .buttonStyle(.plain).foregroundStyle(Tone.failure.color)
                    }
                    if embedded {
                        rows(shown)
                    } else {
                        ScrollView {
                            rows(shown).padding(.bottom, 4)
                        }
                        // Keyed on the rebuild, so a new record lands on
                        // its own failure and a chip change never yanks.
                        .task(id: "\(reconstruction.totalLines)|\(entries.count)|\(firstError ?? "")") {
                            guard landOnFailure, kind == .all, let firstError else { return }
                            proxy.scrollTo(firstError, anchor: .center)
                        }
                    }
                }
            }
        }
    }

    /// A row's scroll target, stable across filters.
    private static func rowID(_ item: ReconstructedItem) -> String { "item:\(item.seq)" }

    private func rows(_ shown: [ReconstructedItem]) -> some View {
        let tail = liveTail.flatMap { kind == .all ? $0 : nil }
        let lastID = tail == nil ? shown.last.map(Self.rowID) : nil
        return LazyVStack(alignment: .leading, spacing: 0) {
            ForEach(shown, id: \.seq) { item in
                row(item, last: Self.rowID(item) == lastID)
                    .id(Self.rowID(item))
            }
            if let tail {
                liveTailRow(tail)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: The spine

    /// The clock column's width — "HH:mm:ss" whole at its size.
    static let clockWidth: CGFloat = 50
    /// A node's slot on the spine.
    static let nodeSize: CGFloat = 18
    static let gutter: CGFloat = 8
    /// The air under a row before the next node.
    static let rowGap: CGFloat = 10
    /// The node's drop from its row's top — the spine breaks this much
    /// either side of it.
    static let nodeInset: CGFloat = 2
    /// The spine's x, through the nodes' centres.
    static let spineX: CGFloat = clockWidth + gutter + nodeSize / 2 - 0.5
    /// Where the spine resumes under a node, and under a result's dot.
    static let spineTop: CGFloat = nodeInset * 2 + nodeSize + 2
    static let spineTopUnderDot: CGFloat = nodeInset + nodeSize / 2 + 7

    /// One row on the spine: its clock, its node, its body, and the
    /// spine running on from under the node to the next one — unless it
    /// is the last row. A `small` node (a result's dot) lets the spine
    /// start closer under it.
    private func spineRow<Node: View, Content: View>(
        clock: String, last: Bool, small: Bool = false,
        @ViewBuilder node: () -> Node, @ViewBuilder content: () -> Content) -> some View {
        HStack(alignment: .top, spacing: Self.gutter) {
            Text(clock)
                .jrbarType(.caption).fontWeight(.medium).monospacedDigit()
                .foregroundStyle(.tertiary)
                .lineLimit(1)
                .fixedSize()
                .frame(width: Self.clockWidth, alignment: .leading)
                .padding(.top, Self.nodeInset + 3)
            node()
                .frame(width: Self.nodeSize, height: Self.nodeSize)
                .padding(.top, Self.nodeInset)
            content()
                .padding(.top, Self.nodeInset + 1)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.bottom, Self.rowGap)
        .background(alignment: .topLeading) {
            if !last {
                Rectangle()
                    .fill(Color.primary.opacity(0.1))
                    .frame(width: 1)
                    .padding(.top, small ? Self.spineTopUnderDot : Self.spineTop)
                    .offset(x: Self.spineX)
            }
        }
        .accessibilityElement(children: .combine)
    }

    /// A node: the row's glyph on a disc of its own tint.
    private func node(_ symbol: String, tint: Color) -> some View {
        Image(systemName: symbol)
            .jrbarType(.caption).fontWeight(.bold)
            .foregroundStyle(tint)
            .frame(width: Self.nodeSize, height: Self.nodeSize)
            .background(Circle().fill(tint.opacity(0.16)))
            .overlay(Circle().strokeBorder(tint.opacity(0.3), lineWidth: 0.5))
    }

    /// A result's node: a small dot on the spine under its call.
    private func dot(_ tint: Color) -> some View {
        Circle()
            .fill(tint)
            .frame(width: 7, height: 7)
    }

    /// The hook's word for what is happening now — the transcript only
    /// writes a tool call once it is done, so the run's present moment
    /// lives here until it does.
    private func liveTailRow(_ text: String) -> some View {
        spineRow(clock: "now", last: true) {
            UnseenDot()
        } content: {
            Text(text)
                .font(.system(size: 11.5))
                .italic()
                .foregroundStyle(.secondary)
        }
        .accessibilityLabel("Now: \(text)")
    }

    private func tag(_ text: String, tint: Color) -> some View {
        Text(text)
            .jrbarType(.caption).fontWeight(.semibold)
            .padding(.horizontal, 5)
            .padding(.vertical, 1.5)
            .background(tint.opacity(0.14), in: .capsule)
            .foregroundStyle(tint)
    }

    // MARK: Rows

    private func row(_ item: ReconstructedItem, last: Bool) -> some View {
        spineRow(clock: item.at.map { Self.clock.string(from: Date(timeIntervalSince1970: $0)) } ?? "—",
                 last: last, small: item.kind == .toolResult) {
            if item.kind == .toolResult {
                dot(Self.tint(item))
            } else {
                node(Self.symbol(item), tint: Self.tint(item))
            }
        } content: {
            rowBody(item)
                .padding(.leading, item.sidechain ? 10 : 0)
                .overlay(alignment: .leading) {
                    if item.sidechain {
                        Capsule().fill(Color.purple.opacity(0.35)).frame(width: 2)
                    }
                }
        }
    }

    /// A subagent's row wears its tag on its first line, beside the name
    /// or the text — never out past a tool call's block.
    @ViewBuilder
    private func subagentTag(_ item: ReconstructedItem) -> some View {
        if item.sidechain {
            tag("subagent", tint: .purple)
        }
    }

    @ViewBuilder
    private func rowBody(_ item: ReconstructedItem) -> some View {
        switch item.kind {
        case .message:
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 5) {
                    if let role = item.role {
                        Text(Self.roleName(role))
                            .jrbarType(.caption).fontWeight(.semibold)
                            .foregroundStyle(Self.roleTint(role))
                    }
                    if let model = item.model {
                        Text(model)
                            .jrbarType(.caption)
                            .foregroundStyle(.tertiary)
                    }
                    subagentTag(item)
                }
                itemText(item)
            }
        case .toolUse:
            VStack(alignment: .leading, spacing: 4) {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(item.name ?? "tool")
                        .font(.system(size: 11, weight: .semibold, design: .monospaced))
                        .foregroundStyle(item.isError ? Tone.failure.color : Self.toolTint)
                    subagentTag(item)
                }
                if item.redacted {
                    redactedText
                } else if let text = item.text {
                    Text(text)
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .lineLimit(3)
                        .textSelection(.enabled)
                        .padding(.horizontal, 7)
                        .padding(.vertical, 4)
                        .background(RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .fill(Color.primary.opacity(0.05)))
                }
            }
        case .toolResult:
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                resultText(item)
                subagentTag(item)
            }
        case .turnEnd:
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(item.name.map { "Turn ended · \($0)" } ?? "Turn ended")
                    .font(.system(size: 11))
                    .foregroundStyle(item.isError ? Tone.failure.color : Color.secondary)
                subagentTag(item)
            }
        }
    }

    /// A result's words: its text (an error's on a red wash), else just
    /// "done" or "failed".
    @ViewBuilder
    private func resultText(_ item: ReconstructedItem) -> some View {
        if item.redacted {
            redactedText
        } else if let text = item.text {
            Text(text)
                .font(.system(size: 11, design: item.isError ? .monospaced : .default))
                .foregroundStyle(item.isError ? Tone.failure.color : Color.secondary)
                .lineLimit(4)
                .textSelection(.enabled)
                .padding(.horizontal, item.isError ? 7 : 0)
                .padding(.vertical, item.isError ? 4 : 0)
                .background {
                    if item.isError {
                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .fill(Tone.failure.color.opacity(0.08))
                    }
                }
        } else {
            Text(item.isError ? "failed" : "done")
                .font(.system(size: 11))
                .foregroundStyle(item.isError ? Tone.failure.color : Color.secondary)
        }
    }

    @ViewBuilder
    private func itemText(_ item: ReconstructedItem) -> some View {
        if item.redacted {
            redactedText
        } else if let text = item.text {
            Text(text)
                .font(.system(size: 12))
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var redactedText: some View {
        Label("Text withheld", systemImage: "eye.slash")
            .font(.system(size: 11))
            .italic()
            .foregroundStyle(.secondary)
    }

    /// Tool calls wear one calm colour of their own — the accent is the
    /// person's, and on a red-accent Mac a tool must not read as a fault.
    static let toolTint = Color.teal

    private static func symbol(_ item: ReconstructedItem) -> String {
        switch item.kind {
        case .message: item.role == "user" ? "person.fill" : "sparkle"
        case .toolUse: toolSymbol(item.name)
        case .toolResult: item.isError ? "xmark" : "checkmark"
        case .turnEnd: "flag.checkered"
        }
    }

    /// A tool's own glyph where its name says what it does.
    nonisolated static func toolSymbol(_ name: String?) -> String {
        switch name?.lowercased() ?? "" {
        case "bash", "shell", "exec", "exec_command", "local_shell": "terminal.fill"
        case "read", "view", "read_file": "doc.text.fill"
        case "edit", "multiedit", "write", "apply_patch", "str_replace_editor": "pencil"
        case "grep", "glob", "search", "ls": "magnifyingglass"
        case "task", "agent": "person.2.fill"
        case "webfetch", "websearch", "web_search": "globe"
        case "todowrite", "update_plan": "checklist"
        default: "wrench.and.screwdriver.fill"
        }
    }

    private static func tint(_ item: ReconstructedItem) -> Color {
        if item.isError { return Tone.failure.color }
        switch item.kind {
        case .message: return roleTint(item.role)
        case .toolUse: return toolTint
        case .toolResult: return Tone.done.color
        case .turnEnd: return .secondary
        }
    }

    private static func roleName(_ role: String) -> String {
        switch role {
        case "user": return "You"
        case "assistant": return "Assistant"
        default: return role.prefix(1).uppercased() + role.dropFirst()
        }
    }

    private static func roleTint(_ role: String?) -> Color {
        switch role {
        case "user": return .blue
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
