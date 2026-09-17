import JRBarCore
import SwiftUI

/// The Overview window: the professional Now/Needs You workspace (S7).
/// A sidebar of presets and saved views, a sortable roster table whose
/// counts are the daemon's own, and an inspector shell that shows the
/// row's canonical facts — state, outcome, review, freshness — rather
/// than a panel-only summary.
struct OverviewView: View {
    @Bindable var store: OverviewStore
    /// `ViewState` not `@State`: the Command Line Tools ship no
    /// `SwiftUIMacros` plugin, so state goes through the alias.
    @ViewState private var saveName = ""

    var body: some View {
        NavigationSplitView {
            sidebar
        } content: {
            content
        } detail: {
            inspector
        }
        .frame(minWidth: 720, minHeight: 380)
        .font(.system(size: 13))
        .searchable(text: $store.search, placement: .sidebar, prompt: "Search titles, projects, tools")
        .toolbar {
            ToolbarItem(placement: .principal) {
                Picker("View", selection: Binding(
                    get: { store.viewMode },
                    set: { store.setViewMode($0) }
                )) {
                    ForEach(OverviewViewMode.allCases, id: \.self) { mode in
                        Label(mode.label, systemImage: mode.symbol).tag(mode)
                    }
                }
                .pickerStyle(.segmented)
                .frame(width: 170)
                .help("Switch between the roster table and the session graph")
                .accessibilityLabel("Overview mode")
            }
            if store.canCompare {
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        store.compareSelected()
                    } label: {
                        Label("Compare", systemImage: "arrow.left.arrow.right")
                    }
                    .help("Compare the two selected runs")
                }
            }
            ToolbarItem(placement: .primaryAction) {
                Button {
                    Task { await store.prepareExport() }
                } label: {
                    Image(systemName: "square.and.arrow.up")
                }
                .help("Export audit bundle")
                .accessibilityLabel("Export audit bundle")
            }
            ToolbarItem(placement: .primaryAction) {
                Button {
                    Task { await store.load() }
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .help("Refresh")
                .accessibilityLabel("Refresh")
            }
        }
        .sheet(isPresented: Binding(
            get: { store.exportPreview != nil },
            set: { if !$0 { store.exportPreview = nil } }
        )) {
            ExportPreviewSheet(store: store)
        }
        .sheet(isPresented: Binding(
            get: { store.comparison != nil },
            set: { if !$0 { store.comparison = nil } }
        )) {
            if let comparison = store.comparison {
                CompareRunsSheet(comparison: comparison)
            }
        }
        .onChange(of: store.selectedID) { _, id in
            guard let id else { return }
            Task { await store.loadTimeline(for: id) }
            Task { await store.loadRadarIfNeeded() }
        }
    }

    // MARK: Sidebar

    @ViewBuilder
    private var sidebar: some View {
        List(selection: Binding(
            get: { SidebarSelection(filter: store.filter, saved: store.activeSavedFilter) },
            set: { selection in
                guard let selection else { return }
                store.filter = selection.filter
                store.activeSavedFilter = selection.saved
            }
        )) {
            Section("Views") {
                ForEach(OverviewPreset.allCases, id: \.self) { preset in
                    presetRow(preset)
                        .tag(SidebarSelection(filter: OverviewFilter(preset: preset), saved: nil))
                }
            }
            if !store.projects.isEmpty {
                Section("Projects") {
                    ForEach(store.projects, id: \.self) { project in
                        Label(project, systemImage: "folder")
                            .tag(SidebarSelection(filter: OverviewFilter(preset: .thisProject, project: project), saved: nil))
                    }
                }
            }
            Section {
                ForEach(store.savedFilters) { saved in
                    Label(saved.name, systemImage: "line.3.horizontal.decrease.circle")
                        .tag(SidebarSelection(filter: saved.filter, saved: saved.name))
                        .contextMenu {
                            Button("Delete", role: .destructive) { store.deleteSavedFilter(saved.name) }
                        }
                }
            } header: {
                HStack {
                    Text("Saved")
                    Spacer()
                    Menu {
                        TextField("Name", text: $saveName)
                        Button("Save current view") {
                            store.saveCurrentFilter(named: saveName)
                            saveName = ""
                        }
                        .disabled(saveName.trimmingCharacters(in: .whitespaces).isEmpty)
                    } label: {
                        Image(systemName: "plus")
                    }
                    .menuStyle(.borderlessButton)
                    .menuIndicator(.hidden)
                    .frame(width: 16)
                    .help("Save the current view as a filter")
                    .accessibilityLabel("Save current view")
                }
            }
        }
        .listStyle(.sidebar)
        .navigationTitle("Overview")
        .frame(minWidth: 180)
    }

    private func presetRow(_ preset: OverviewPreset) -> some View {
        // Only `needsMe` gets a badge — it is the one count the daemon
        // reports that the preset means exactly (live asks). The other
        // daemon counts (workers, finished) measure different things
        // than their like-named presets, so showing them would lie.
        return Label(preset.label, systemImage: preset.symbol)
            .badge(preset == .needsMe && store.counts.attention > 0
                   ? Text("\(store.counts.attention)") : nil)
    }

    /// A sidebar selection is a filter definition + the saved name it came
    /// from — selecting a preset drops the saved highlight.
    struct SidebarSelection: Hashable {
        var filter: OverviewFilter
        var saved: String?
    }

    // MARK: Content

    @ViewBuilder
    private var content: some View {
        VStack(spacing: 0) {
            summaryStrip
            connectionsStrip
            if let error = store.error, !store.roster.isEmpty {
                HStack(spacing: 8) {
                    Image(systemName: "exclamationmark.triangle").foregroundStyle(.orange)
                    Text(error).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1).truncationMode(.tail)
                    Spacer()
                }
                .padding(.horizontal, 12).padding(.vertical, 5)
                .accessibilityElement(children: .combine)
            }
            Divider()
            if !store.isLive {
                OverviewEmptyState(symbol: "bolt.horizontal.circle", title: "Monitor not connected",
                                   text: "The roster comes from the monitor. Rows appear as soon as the socket is live.")
            } else if let error = store.error, store.roster.isEmpty {
                OverviewEmptyState(symbol: "exclamationmark.triangle", title: "Couldn't load the roster",
                                   text: error)
            } else if store.rows.isEmpty {
                OverviewEmptyState(symbol: store.roster.isEmpty ? "tray" : "line.3.horizontal.decrease.circle",
                                   title: store.roster.isEmpty ? "Nothing on record" : "Nothing matches",
                                   text: store.roster.isEmpty
                                       ? "The monitor has no sessions on record yet."
                                       : "No row fits this view. Try another preset or clear the search.",
                                   hint: store.viewMode == .graph
                                       ? "The graph draws itself as soon as a session matches — or flip back to List."
                                       : nil)
            } else if store.viewMode == .graph {
                OverviewGraphPane(store: store)
            } else {
                Table(store.rows, selection: Binding(
                    get: { store.selectedIDs },
                    set: { store.selectionChanged(to: $0) }
                ), sortOrder: $store.sortOrder) {
                    TableColumn("Task", value: \.labelSortKey) { entry in
                        HStack(spacing: 6) {
                            Text(entry.session.label ?? entry.session.shortId ?? "Session")
                                .lineLimit(1)
                            if entry.session.workers > 0 {
                                Text("+\(entry.session.workers)").foregroundStyle(.secondary).font(.system(size: 10))
                            }
                        }
                    }
                    .width(min: 120, ideal: 180)
                    TableColumn("Project", value: \.projectSortKey) { entry in
                        Text(OverviewFilter.projectName(of: entry.session.cwd) ?? "—")
                            .foregroundStyle(.secondary).lineLimit(1)
                    }
                    .width(min: 70, ideal: 90)
                    TableColumn("Harness", value: \.session.provider) { entry in
                        HStack(spacing: 5) {
                            ProviderTile(style: ProviderStyle.style(for: entry.session.provider), size: 14)
                            Text(ProviderStyle.style(for: entry.session.provider).name).foregroundStyle(.secondary)
                            if entry.session.remote {
                                Image(systemName: "network").foregroundStyle(.tertiary)
                                    .help("Remote Mac")
                            }
                        }
                    }
                    .width(min: 80, ideal: 100)
                    TableColumn("Model", value: \.modelSortKey) { _ in
                        // The roster does not track per-session model —
                        // an honest blank, not a guess.
                        Text("—").foregroundStyle(.tertiary)
                            .help("Model is not reported for sessions")
                    }
                    .width(min: 44, ideal: 56)
                    TableColumn("State", value: \.stateSortKey) { entry in
                        stateCell(entry)
                    }
                    .width(min: 76, ideal: 96)
                    TableColumn("Current activity", value: \.activitySortKey) { entry in
                        Text(entry.session.activityCaption)
                            .foregroundStyle(.secondary).lineLimit(1).truncationMode(.tail)
                    }
                    .width(min: 120, ideal: 200)
                    TableColumn("Elapsed", value: \.elapsedSortKey) { entry in
                        Text(elapsedText(entry))
                            .monospacedDigit().foregroundStyle(.secondary)
                    }
                    .width(min: 48, ideal: 56)
                    TableColumn("Freshness", value: \.freshnessSortKey) { entry in
                        freshnessCell(entry)
                    }
                    .width(min: 64, ideal: 80)
                    TableColumn("Attention", value: \.attentionSortKey) { entry in
                        attentionCell(entry)
                    }
                    .width(min: 44, ideal: 52)
                }
                .contextMenu(forSelectionType: String.self) { _ in
                    Button("Open session") { store.openSelected() }
                    if store.canCompare {
                        Button("Compare selected runs") { store.compareSelected() }
                    }
                }
            }
            if let note = store.coverageNote {
                Divider()
                Text(note)
                    .font(.system(size: 10)).foregroundStyle(.tertiary)
                    .padding(.horizontal, 12).padding(.vertical, 4)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    /// "2 live · 1 needs you · 1 unreviewed · 3 hidden" — over the filtered
    /// rows, so the strip and the table can never disagree.
    @ViewBuilder
    private var summaryStrip: some View {
        let counts = store.stripCounts
        HStack(spacing: 10) {
            Text("\(counts.live) live")
            if counts.attention > 0 {
                Text("· \(counts.attention) need\(counts.attention == 1 ? "s" : "") you").foregroundStyle(.orange)
            }
            if counts.unreviewed > 0 {
                Text("· \(counts.unreviewed) unreviewed").foregroundStyle(.secondary)
            }
            if counts.hidden > 0 {
                Text("· \(counts.hidden) hidden").foregroundStyle(.tertiary)
            }
            Spacer()
            if store.loading {
                ProgressView().controlSize(.mini)
            } else if let loadedAt = store.loadedAt {
                Text("Updated \(loadedAt, style: .time)").foregroundStyle(.tertiary).font(.system(size: 10))
            }
        }
        .padding(.horizontal, 12).padding(.vertical, 6)
        .font(.system(size: 11))
        .accessibilityElement(children: .combine)
    }

    // MARK: Connections

    /// The wiring row: core link, this Mac, each peer, each device,
    /// each provider — the live connections the roster runs on, visible
    /// even when no session is. A chip focuses the same link's facts in
    /// the inspector.
    @ViewBuilder
    private var connectionsStrip: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                ForEach(store.links) { link in
                    connectionChip(link)
                }
            }
            .padding(.horizontal, 12)
        }
        .fixedSize(horizontal: false, vertical: true)
        .padding(.bottom, 5)
    }

    private func connectionChip(_ link: OverviewLink) -> some View {
        let selected = store.selectedLinkID == link.id
        return Button {
            store.selectLink(selected ? nil : link.id)
        } label: {
            HStack(spacing: 5) {
                Circle()
                    .fill(link.tone.color)
                    .frame(width: 5, height: 5)
                connectionGlyph(link)
                Text(link.title)
                    .font(.system(size: 11, weight: .medium))
                    .lineLimit(1)
                if let subtitle = link.subtitle {
                    Text(subtitle)
                        .font(.system(size: 10))
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                }
            }
            .padding(.horizontal, 8).padding(.vertical, 3.5)
            .background(Capsule().fill(.primary.opacity(selected ? 0.14 : 0.06)))
            .overlay(Capsule().strokeBorder(
                selected ? Color.accentColor.opacity(0.6) : .primary.opacity(0.08),
                lineWidth: 0.5))
        }
        .buttonStyle(.plain)
        .help(link.helpText)
        .accessibilityLabel("\(link.group.title): \(link.title)")
    }

    /// Providers draw their brand tile; everything else takes the link's
    /// SF Symbol.
    @ViewBuilder
    private func connectionGlyph(_ link: OverviewLink) -> some View {
        if link.group == .providers {
            let raw = String(link.id.dropFirst("provider:".count))
            let pid = raw.split(separator: "|").first.map(String.init) ?? raw
            ProviderTile(style: ProviderStyle.style(for: pid), size: 12)
        } else {
            Image(systemName: link.symbol)
                .font(.system(size: 9))
                .foregroundStyle(.secondary)
        }
    }

    /// A focused chip's facts — the same labelled grid the session
    /// inspector uses, every line carrying the daemon's own words.
    private func connectionInspector(_ link: OverviewLink) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                HStack(spacing: 8) {
                    connectionGlyph(link)
                    Text(link.title)
                        .font(.system(size: 15, weight: .semibold))
                        .lineLimit(2)
                    Circle().fill(link.tone.color).frame(width: 7, height: 7)
                }
                Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 5) {
                    ForEach(link.facts, id: \.label) { item in
                        fact(item.label, item.value, evidence: .reported)
                    }
                }
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(minWidth: 220)
    }

    /// The inspector's idle state: the whole wiring, grouped — core,
    /// nodes, devices, providers — so an empty roster still answers
    /// "what is connected". A row focuses that link.
    private var connectionsBrowser: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                Text("Connections")
                    .font(.system(size: 15, weight: .semibold))
                ForEach(OverviewLink.Group.allCases, id: \.self) { group in
                    let links = store.links.filter { $0.group == group }
                    if !links.isEmpty {
                        VStack(alignment: .leading, spacing: 6) {
                            Text(group.title)
                                .font(.system(size: 10, weight: .semibold))
                                .foregroundStyle(.tertiary)
                            ForEach(links) { link in
                                Button { store.selectLink(link.id) } label: {
                                    HStack(spacing: 7) {
                                        Circle().fill(link.tone.color).frame(width: 6, height: 6)
                                        connectionGlyph(link)
                                        Text(link.title)
                                            .font(.system(size: 12, weight: .medium))
                                            .lineLimit(1)
                                        if let subtitle = link.subtitle {
                                            Text(subtitle)
                                                .font(.system(size: 11))
                                                .foregroundStyle(.secondary)
                                                .lineLimit(1)
                                        }
                                        Spacer(minLength: 4)
                                    }
                                    .contentShape(Rectangle())
                                }
                                .buttonStyle(.plain)
                                .help(link.helpText)
                            }
                        }
                    }
                }
                Text("Select a session row for its inspector.")
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(minWidth: 220)
    }

    @ViewBuilder
    private func stateCell(_ entry: CoreRosterEntry) -> some View {
        let activity = SessionActivity.reduce(entry.session)
        HStack(spacing: 5) {
            Circle().fill(activity.tint).frame(width: 7, height: 7)
            Text(activity.word).foregroundStyle(activity.wordColor)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("State: \(activity.word)")
    }

    private func elapsedText(_ entry: CoreRosterEntry) -> String {
        guard let since = entry.session.since else { return "—" }
        let seconds = max(0, store.now.timeIntervalSince1970 - since)
        return AgentMonitorFeed.ageText(seconds)
    }

    @ViewBuilder
    private func freshnessCell(_ entry: CoreRosterEntry) -> some View {
        let word = entry.axes?.freshness ?? (entry.session.stale ? "stale" : "live")
        HStack(spacing: 4) {
            if word != "live" {
                Image(systemName: "clock.badge.exclamationmark").font(.system(size: 9))
            }
            Text(word).foregroundStyle(word == "live" ? Color.secondary : Color.orange)
        }
    }

    @ViewBuilder
    private func attentionCell(_ entry: CoreRosterEntry) -> some View {
        if entry.pinned || entry.session.ask != nil {
            Image(systemName: "exclamationmark.bubble.fill").foregroundStyle(.orange)
                .help(entry.session.ask?.summary ?? "Waiting on you")
        }
    }

    // MARK: Inspector

    @ViewBuilder
    private var inspector: some View {
        if let entry = store.selected {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    Text(entry.session.label ?? entry.session.shortId ?? "Session")
                        .font(.system(size: 15, weight: .semibold))
                        .lineLimit(2)
                    inspectorFacts(entry)
                    if let ask = entry.session.ask {
                        inspectorSection("Waiting on you", text: ask.summary ?? "This session has an open question.")
                    }
                    if let message = entry.session.message, !message.isEmpty {
                        inspectorSection("Last message", text: message)
                    }
                    if let coverage = store.coverageNote, entry.visibility == "hidden" {
                        Text(coverage).font(.system(size: 10)).foregroundStyle(.tertiary)
                    }
                    timelineSection(for: entry)
                    topologySection(for: entry)
                    if entry.session.remote {
                        Label("Remote row — open it on \(entry.session.origin?.label ?? "that Mac").", systemImage: "network")
                            .font(.system(size: 11)).foregroundStyle(.secondary)
                    } else {
                        Button("Open session") { store.openSelected() }
                            .buttonStyle(.borderedProminent).controlSize(.small)
                    }
                }
                .padding(16)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(minWidth: 220)
        } else if let link = store.selectedLink {
            connectionInspector(link)
        } else {
            connectionsBrowser
        }
    }

    private func inspectorFacts(_ entry: CoreRosterEntry) -> some View {
        let session = entry.session
        return Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 5) {
            // S7.3: every fact names its evidence class — what the provider
            // reported vs what the daemon derived vs what nobody can say.
            fact("State", SessionActivity.reduce(session).word, evidence: .derived)
            fact("Outcome", entry.axes?.outcome ?? "—", evidence: .derived)
            fact("Review", entry.axes?.review ?? "—", evidence: .derived)
            fact("Freshness", entry.axes?.freshness ?? (session.stale ? "stale" : "live"), evidence: .derived)
            fact("Harness", session.provider, evidence: .reported)
            if let origin = session.origin?.label { fact("Origin", origin, evidence: .reported) }
            if let project = OverviewFilter.projectName(of: session.cwd) {
                fact("Project", project, evidence: .derived)
            }
            if let tool = session.tool { fact("Tool", tool, evidence: .reported) }
            if session.workers > 0 { fact("Workers", "\(session.workers)", evidence: .reported) }
            if session.stale { fact("Stale", "yes", evidence: .reported) }
            fact("Model", "not reported", evidence: .unavailable)
        }
        .font(.system(size: 11))
        .foregroundStyle(.secondary)
    }

    /// S7.3's evidence vocabulary: reported (the source said it), derived
    /// (the daemon computed it from reported inputs), unavailable.
    private enum Evidence: String {
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

    private func fact(_ name: String, _ value: String, evidence: Evidence) -> some View {
        GridRow {
            Text(name).foregroundStyle(.tertiary)
            HStack(spacing: 5) {
                Text(value).textSelection(.enabled)
                Text(evidence.rawValue)
                    .font(.system(size: 8, weight: .medium))
                    .padding(.horizontal, 4).padding(.vertical, 1)
                    .background(evidence.tint.opacity(0.15), in: .capsule)
                    .foregroundStyle(evidence.tint)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(name): \(value) (\(evidence.rawValue))")
    }

    private func inspectorSection(_ title: String, text: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.system(size: 10, weight: .semibold)).foregroundStyle(.tertiary)
            Text(text).font(.system(size: 12)).textSelection(.enabled)
        }
    }

    // MARK: Timeline

    /// S7.2 Timeline: the session's transcript rows — messages, tool
    /// pairs, turn ends — occurrence time on the left. "Load earlier"
    /// is the only way deeper history enters; nothing is virtualised
    /// silently past the daemon's page bound.
    @ViewBuilder
    private func timelineSection(for entry: CoreRosterEntry) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack {
                Text("Timeline").font(.system(size: 10, weight: .semibold)).foregroundStyle(.tertiary)
                Spacer()
                if store.timelineLoading { ProgressView().controlSize(.mini) }
                if let page = store.timelinePage, store.timelineSessionID == entry.id, page.hasMore {
                    Button("Load earlier") { Task { await store.loadEarlierTimeline() } }
                        .controlSize(.mini)
                }
            }
            if store.timelineSessionID == entry.id {
                if let page = store.timelinePage {
                    ForEach(store.timeline) { item in
                        timelineRow(item)
                    }
                    ForEach(page.gaps, id: \.self) { gap in
                        Text(Self.gapText(gap))
                            .font(.system(size: 10)).foregroundStyle(.orange)
                    }
                    if let file = page.file {
                        Text("Source: \(file) · \(page.total) items")
                            .font(.system(size: 9)).foregroundStyle(.quaternary)
                            .textSelection(.enabled)
                    }
                } else if store.timelineLoading {
                    Text("Reading transcript…").font(.system(size: 11)).foregroundStyle(.tertiary)
                }
            }
        }
    }

    private func timelineRow(_ item: CoreTimelineItem) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Text(item.at.map { Self.clock.string(from: Date(timeIntervalSince1970: $0)) } ?? "—")
                .font(.system(size: 9, design: .monospaced))
                .foregroundStyle(.quaternary)
                .frame(width: 40, alignment: .leading)
            Image(systemName: Self.timelineSymbol(item))
                .font(.system(size: 9))
                .foregroundStyle(Self.timelineTint(item))
                .frame(width: 12)
            VStack(alignment: .leading, spacing: 1) {
                if let name = item.name, item.kind != "message" {
                    Text(name + (item.isError == true ? " · failed" : ""))
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(item.isError == true ? Color.red : Color.secondary)
                }
                if let text = item.text {
                    Text(text).font(.system(size: 11)).lineLimit(4).textSelection(.enabled)
                }
            }
        }
        .accessibilityElement(children: .combine)
    }

    private static func timelineSymbol(_ item: CoreTimelineItem) -> String {
        switch item.kind {
        case "message": item.role == "user" ? "person" : "sparkle"
        case "tool_use": "wrench.and.screwdriver"
        case "tool_result": item.isError == true ? "xmark.octagon" : "checkmark.circle"
        case "turn_end": "flag.checkered"
        default: "circle"
        }
    }

    private static func timelineTint(_ item: CoreTimelineItem) -> Color {
        if item.isError == true { return .red }
        switch item.kind {
        case "tool_use": return .accentColor
        case "tool_result": return .green
        case "turn_end": return .secondary
        default: return .secondary
        }
    }

    private static func gapText(_ gap: String) -> String {
        switch gap {
        case "transcript_not_found": "No transcript found for this session."
        case "unsupported_provider": "This provider's transcript format is not read yet."
        case "transcript_unreadable": "The transcript file could not be read."
        default: gap.hasPrefix("timeline_item_cap") ? "Transcript exceeds the item cap — earliest rows omitted." : gap
        }
    }

    private static let clock: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss"
        return formatter
    }()

    // MARK: Topology

    /// S7.5 relationship lens: the selected run's one-hop neighborhood
    /// in the newest imported Radar report. Every edge is labeled
    /// "static" — a statically detected relationship, never an observed
    /// call; it feeds nothing (T38).
    @ViewBuilder
    private func topologySection(for entry: CoreRosterEntry) -> some View {
        let edges = store.staticEdges(for: entry)
        if !edges.isEmpty || store.radarReport != nil {
            VStack(alignment: .leading, spacing: 5) {
                HStack {
                    Text("Static topology")
                        .font(.system(size: 10, weight: .semibold)).foregroundStyle(.tertiary)
                    Text("static")
                        .font(.system(size: 8, weight: .medium))
                        .padding(.horizontal, 4).padding(.vertical, 1)
                        .background(Color.purple.opacity(0.15), in: .capsule)
                        .foregroundStyle(.purple)
                    Spacer()
                    Button("Import…") { importRadarReport() }
                        .controlSize(.mini)
                }
                if let report = store.radarReport {
                    ForEach(Array(edges.prefix(12).enumerated()), id: \.offset) { _, edge in
                        HStack(spacing: 5) {
                            Image(systemName: "arrow.right")
                                .font(.system(size: 8)).foregroundStyle(.quaternary)
                            Text("\(edge.source) → \(edge.target)")
                                .font(.system(size: 10)).foregroundStyle(.secondary)
                                .lineLimit(1).truncationMode(.middle)
                            if let kind = edge.kind {
                                Text(kind).font(.system(size: 8)).foregroundStyle(.quaternary)
                            }
                        }
                    }
                    if edges.isEmpty {
                        Text("No static edges near this session's provider.")
                            .font(.system(size: 10)).foregroundStyle(.quaternary)
                    }
                    Text("\(report.repository ?? "report") · \(report.nodes.count) nodes · \(report.edges.count) edges")
                        .font(.system(size: 9)).foregroundStyle(.quaternary)
                }
            }
        }
    }

    private func importRadarReport() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.json]
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        Task { await store.importRadarReport(path: url.path) }
    }
}

/// S7.4 run comparison: two sides on retained facts — roster axes,
/// transcript aggregates, ledger interruptions — with the benchmark
/// warning and named gaps always visible, never a verdict the facts
/// cannot carry.
private struct CompareRunsSheet: View {
    let comparison: CoreRunComparison

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text("Compare runs").font(.system(size: 15, weight: .semibold))
                Spacer()
                if comparison.generatedAt != nil {
                    Text("Replay-free · live facts")
                        .font(.system(size: 10)).foregroundStyle(.tertiary)
                }
            }
            if comparison.warnings.contains("not_a_controlled_benchmark") {
                Label("Uncontrolled runs — not a fair model benchmark.",
                      systemImage: "exclamationmark.triangle")
                    .font(.system(size: 11)).foregroundStyle(.orange)
            }
            Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 6) {
                GridRow {
                    Text("").frame(width: 90, alignment: .leading)
                    sideHeader(comparison.a)
                    sideHeader(comparison.b)
                }
                Divider().gridCellUnsizedAxes([.horizontal])
                compareRow("Provider") { side in
                    ProviderStyle.style(for: side.provider ?? "unknown").name
                }
                compareRow("Workspace") { side in
                    side.cwd.map { OverviewFilter.projectName(of: $0) ?? $0 } ?? "—"
                }
                compareRow("Lifecycle") { $0.lifecycle ?? "—" }
                compareRow("Outcome") { $0.axes?.outcome ?? "—" }
                compareRow("Review") { $0.axes?.review ?? "—" }
                compareRow("Model") { _ in "not tracked" }
                Divider().gridCellUnsizedAxes([.horizontal])
                compareRow("Span") { side in
                    side.activity?.span?.durationS.map(Self.durationText) ?? "—"
                }
                compareRow("Messages") { side in
                    side.activity.map { "\($0.userMessages)↑ \($0.assistantMessages)↓" } ?? "—"
                }
                compareRow("Tool calls") { side in
                    side.activity.map { "\($0.toolUses)" } ?? "—"
                }
                compareRow("Failures") { side in
                    side.activity.map { "\($0.toolFailures)" } ?? "—"
                }
                compareRow("Retries") { side in
                    side.activity.map { "\($0.retriedTools)" } ?? "—"
                }
                compareRow("Asked you") { "\($0.interruptions.asked)" }
                compareRow("Top tools") { side in
                    side.activity.map { activity in
                        activity.tools.prefix(3)
                            .map { "\($0.key) ×\($0.value)" }
                            .joined(separator: ", ")
                    }.flatMap { $0.isEmpty ? nil : $0 } ?? "—"
                }
            }
            .font(.system(size: 12))
            ForEach(comparison.gaps, id: \.self) { gap in
                Text(Self.gapText(gap)).font(.system(size: 10)).foregroundStyle(.orange)
            }
        }
        .padding(20)
        .frame(minWidth: 560)
    }

    private func sideHeader(_ side: CoreRunSide) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(side.label ?? side.id).font(.system(size: 12, weight: .semibold)).lineLimit(1)
            Text(side.id).font(.system(size: 9, design: .monospaced)).foregroundStyle(.tertiary).lineLimit(1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func compareRow(_ name: String,
                            _ value: (CoreRunSide) -> String) -> some View {
        GridRow {
            Text(name).foregroundStyle(.tertiary).frame(width: 90, alignment: .leading)
            Text(value(comparison.a)).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
            Text(value(comparison.b)).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private static func durationText(_ seconds: Double) -> String {
        if seconds < 90 { return String(format: "%.0fs", seconds) }
        if seconds < 5400 { return String(format: "%.0fm %.0fs", seconds / 60, seconds.truncatingRemainder(dividingBy: 60)) }
        return String(format: "%.1fh", seconds / 3600)
    }

    private static func gapText(_ gap: String) -> String {
        switch gap {
        case "artifacts_not_tracked": "Artifacts are not tracked per session — nothing to compare."
        case "model_not_tracked": "Model is not tracked per session — differences are unknown, not equal."
        default: gap
        }
    }
}

/// The shared empty-state label set (Replay uses it too; the Usage
/// Center's `UsageEmptyState` is fileprivate there).
struct OverviewEmptyState: View {
    let symbol: String
    let title: String
    let text: String
    /// Optional extra line (the graph's "flip back to List" nudge).
    var hint: String? = nil

    var body: some View {
        VStack(spacing: 8) {
            Image(systemName: symbol).font(.system(size: 30)).foregroundStyle(.quaternary)
            Text(title).font(.system(size: 13, weight: .medium)).foregroundStyle(.secondary)
            Text(text).font(.system(size: 11)).foregroundStyle(.tertiary)
                .multilineTextAlignment(.center).frame(maxWidth: 320)
            if let hint {
                Text(hint).font(.system(size: 10)).foregroundStyle(.quaternary)
                    .multilineTextAlignment(.center).frame(maxWidth: 320)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityElement(children: .combine)
    }
}

/// The export preview: scope, counts, gaps, and the markdown rendering —
/// what Save writes is what this sheet showed (S7.4).
private struct ExportPreviewSheet: View {
    @Bindable var store: OverviewStore

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Audit export").font(.system(size: 15, weight: .semibold))
            if let preview = store.exportPreview {
                let gaps = preview.document["gaps"]?.arrayValue?.compactMap(\.stringValue) ?? []
                if !gaps.isEmpty {
                    VStack(alignment: .leading, spacing: 3) {
                        Text("Gaps").font(.system(size: 10, weight: .semibold)).foregroundStyle(.tertiary)
                        ForEach(gaps, id: \.self) { gap in
                            Text("· \(gap)").font(.system(size: 11)).foregroundStyle(.secondary)
                        }
                    }
                }
                ScrollView {
                    Text(preview.markdown)
                        .font(.system(size: 11, design: .monospaced))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(minHeight: 220)
                .padding(8)
                .background(.quaternary.opacity(0.4), in: .rect(cornerRadius: 8))
            }
            HStack {
                Spacer()
                Button("Cancel") { store.exportPreview = nil }
                Button("Save Markdown…") { save(markdown: true) }
                Button("Save JSON…") { save(markdown: false) }
                    .buttonStyle(.borderedProminent)
            }
        }
        .padding(16)
        .frame(width: 480, height: 420)
    }

    private func save(markdown: Bool) {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = markdown ? "jrbar-audit.md" : "jrbar-audit.json"
        panel.allowedContentTypes = markdown ? [.plainText] : [.json]
        panel.message = "The previewed bundle is written as-is."
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try store.saveExport(to: url, markdown: markdown)
            store.exportPreview = nil
        } catch {
            store.error = error.localizedDescription
        }
    }
}

private extension OverviewPreset {
    var symbol: String {
        switch self {
        case .needsMe: return "exclamationmark.bubble"
        case .working: return "gearshape"
        case .unreviewed: return "checkmark.circle.badge.questionmark"
        case .thisProject: return "folder"
        case .thisMac: return "desktopcomputer"
        case .all: return "globe"
        }
    }
}

private extension OverviewLink.Tone {
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
