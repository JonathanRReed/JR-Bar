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
                                       : "No row fits this view. Try another preset or clear the search.")
            } else {
                Table(store.rows, selection: Binding(
                    get: { store.selectedID.map { Set([$0]) } ?? Set<String>() },
                    set: { store.selectedID = $0.first }
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
                        Text(currentActivity(entry))
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

    private func currentActivity(_ entry: CoreRosterEntry) -> String {
        let session = entry.session
        if let ask = session.ask { return ask.summary ?? "Waiting on you" }
        if let message = session.message, !message.isEmpty { return message }
        if let event = session.event { return event }
        if let tool = session.tool { return tool }
        return session.mode?.replacingOccurrences(of: "_", with: " ") ?? "—"
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
        } else {
            Text("Select a row").foregroundStyle(.tertiary).frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private func inspectorFacts(_ entry: CoreRosterEntry) -> some View {
        let session = entry.session
        return Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 5) {
            fact("State", SessionActivity.reduce(session).word)
            fact("Outcome", entry.axes?.outcome ?? "—")
            fact("Review", entry.axes?.review ?? "—")
            fact("Freshness", entry.axes?.freshness ?? (session.stale ? "stale" : "live"))
            fact("Harness", session.provider)
            if let origin = session.origin?.label { fact("Origin", origin) }
            if let project = OverviewFilter.projectName(of: session.cwd) { fact("Project", project) }
            if let tool = session.tool { fact("Tool", tool) }
            if session.workers > 0 { fact("Workers", "\(session.workers)") }
            if session.stale { fact("Stale", "yes") }
            fact("Model", "not reported")
        }
        .font(.system(size: 11))
        .foregroundStyle(.secondary)
    }

    private func fact(_ name: String, _ value: String) -> some View {
        GridRow {
            Text(name).foregroundStyle(.tertiary)
            Text(value).textSelection(.enabled)
        }
    }

    private func inspectorSection(_ title: String, text: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.system(size: 10, weight: .semibold)).foregroundStyle(.tertiary)
            Text(text).font(.system(size: 12)).textSelection(.enabled)
        }
    }
}

/// The Overview's own empty-state label set (the Usage Center's
/// `UsageEmptyState` is fileprivate there).
private struct OverviewEmptyState: View {
    let symbol: String
    let title: String
    let text: String

    var body: some View {
        VStack(spacing: 8) {
            Image(systemName: symbol).font(.system(size: 30)).foregroundStyle(.quaternary)
            Text(title).font(.system(size: 13, weight: .medium)).foregroundStyle(.secondary)
            Text(text).font(.system(size: 11)).foregroundStyle(.tertiary)
                .multilineTextAlignment(.center).frame(maxWidth: 320)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityElement(children: .combine)
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
