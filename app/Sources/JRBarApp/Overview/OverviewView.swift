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
    /// The row whose ask gets a free-text reply — the Reply… prompt's
    /// target. nil hides the sheet.
    @ViewState private var replyEntry: CoreRosterEntry?

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
            if store.canCompare || store.comparing {
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        store.compareSelected()
                    } label: {
                        if store.comparing {
                            DelayedWait(size: 12) { Label("Compare", systemImage: "arrow.left.arrow.right") }
                        } else {
                            Label("Compare", systemImage: "arrow.left.arrow.right")
                        }
                    }
                    .disabled(store.comparing || !store.canCompare)
                    .help("Compare the two selected runs")
                }
            }
            ToolbarItem(placement: .primaryAction) {
                Menu {
                    Button("Clear completed") { Task { await store.clearCompleted() } }
                    Button("Undo clear") { Task { await store.undoClear() } }
                        .disabled(!store.core.canUndoClear)
                } label: {
                    Image(systemName: "checkmark.circle")
                }
                .help("Completion actions — clear acknowledged runs, or undo the last clear")
                .accessibilityLabel("Completion actions")
            }
            ToolbarItem(placement: .primaryAction) {
                Menu {
                    // What is on screen first: the export matches the view
                    // it was asked from, not the whole fleet.
                    Button("Export \(store.exportScope.label)…") { Task { await store.prepareExport() } }
                    Button("Export everything on record…") { Task { await store.prepareExport(everything: true) } }
                } label: {
                    Image(systemName: "square.and.arrow.up")
                }
                .help("Export an audit bundle of this view (or everything on record)")
                .accessibilityLabel("Export audit bundle")
            }
            ToolbarItem(placement: .primaryAction) {
                Button {
                    // Pane-aware: on Usage the refresh re-scans the chart,
                    // on the roster it reloads sessions.
                    if store.pane == .usage {
                        Task { await store.loadGraph() }
                    } else {
                        Task { await store.load(userInitiated: true) }
                    }
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .help(store.pane == .usage ? "Rescan the usage chart" : "Refresh")
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
            get: { store.runExportPreview != nil },
            set: { if !$0 { store.runExportPreview = nil } }
        )) {
            RunExportSheet(store: store)
        }
        .sheet(isPresented: Binding(
            get: { store.comparison != nil },
            set: { if !$0 { store.comparison = nil } }
        )) {
            if let comparison = store.comparison {
                CompareRunsSheet(comparison: comparison, usage: store.sessionUsage)
            }
        }
        .sheet(item: $replyEntry) { entry in
            ReplyPromptSheet(store: store, entry: entry)
        }
        .onChange(of: store.selectedID) { _, id in
            guard let id else { return }
            Task { await store.loadTimeline(for: id) }
        }
    }

    // MARK: Sidebar

    @ViewBuilder
    private var sidebar: some View {
        List(selection: Binding(
            // The Usage tag carries `saved: nil` — emit it that way while
            // the usage pane is up or a live saved filter makes the
            // selection match nothing and the sidebar shows no highlight.
            get: { SidebarSelection(filter: store.filter, saved: store.pane == .roster ? store.activeSavedFilter : nil, pane: store.pane) },
            set: { selection in
                guard let selection else { return }
                if selection.pane == .usage {
                    store.showUsage()
                } else if selection.pane == .graph {
                    store.showGraph()
                } else {
                    store.pane = .roster
                    store.workerFilter = nil
                    store.dayFilter = nil
                    // A saved view is applied as a definition: the filter
                    // it stored, the highlight on its name, and a cleared
                    // search — same semantics as `apply(_:)`, never a
                    // half-copied state the strip could disagree with.
                    if let name = selection.saved,
                       let saved = store.savedFilters.first(where: { $0.name == name }) {
                        store.apply(saved)
                    } else {
                        store.filter = selection.filter
                        store.activeSavedFilter = selection.saved
                    }
                }
            }
        )) {
            Section("Views") {
                // `thisProject` is deliberately absent: without a project
                // it matches nothing, and the real entry points are the
                // per-project rows under Projects below.
                ForEach(OverviewPreset.sidebarPresets, id: \.self) { preset in
                    presetRow(preset)
                        .tag(SidebarSelection(filter: OverviewFilter(preset: preset), saved: nil, pane: .roster))
                }
            }
            Section("Insights") {
                Label("Graph", systemImage: "point.3.connected.trianglepath.dotted")
                    .tag(SidebarSelection(filter: store.filter, saved: nil, pane: .graph))
                Label("Usage", systemImage: "chart.xyaxis.line")
                    .tag(SidebarSelection(filter: store.filter, saved: nil, pane: .usage))
            }
            if !store.projects.isEmpty {
                Section("Projects") {
                    ForEach(store.projects, id: \.self) { project in
                        Label(project, systemImage: "folder")
                            .tag(SidebarSelection(filter: OverviewFilter(preset: .thisProject, project: project), saved: nil, pane: .roster))
                    }
                }
            }
            let branches = store.branches
            if !branches.isEmpty {
                // Only when branches tell rows apart: one repository on
                // two branches, or a linked worktree.
                Section("Branches") {
                    ForEach(branches, id: \.self) { branch in
                        Label(branch, systemImage: "arrow.triangle.branch")
                            .tag(SidebarSelection(filter: OverviewFilter(preset: .thisBranch, branch: branch), saved: nil, pane: .roster))
                    }
                }
            }
            Section {
                ForEach(store.savedFilters) { saved in
                    Label(saved.name, systemImage: "line.3.horizontal.decrease.circle")
                        .tag(SidebarSelection(filter: saved.filter, saved: saved.name, pane: .roster))
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

    /// A sidebar selection is a pane + the roster cut it implies —
    /// the Usage row carries the current filter untouched so leaving
    /// the pane never loses the roster's cut.
    struct SidebarSelection: Hashable {
        var filter: OverviewFilter
        var saved: String?
        var pane: OverviewStore.Pane
    }

    // MARK: Content

    @ViewBuilder
    private var content: some View {
        switch store.pane {
        case .usage: UsageGraphView(store: store)
        case .graph: OverviewGraphView(store: store)
        case .roster: rosterContent
        }
    }

    @ViewBuilder
    private var rosterContent: some View {
        VStack(spacing: 0) {
            OverviewSummaryStrip(store: store)
            OverviewConnectionsStrip(store: store)
            if let error = store.error, !store.roster.isEmpty {
                WindowNoticeRow(symbol: "exclamationmark.triangle.fill", tint: .orange, text: error)
                    .padding(.horizontal, 10).padding(.bottom, 6)
            }
            if let status = store.actionStatus {
                WindowNoticeRow(symbol: store.actionIsError ? "xmark.octagon.fill" : "checkmark.circle.fill",
                                tint: store.actionIsError ? .red : .green, text: status) {
                    Button { store.actionStatus = nil } label: {
                        Image(systemName: "xmark").font(.system(size: 9, weight: .semibold))
                    }
                    .buttonStyle(.plain).foregroundStyle(.tertiary)
                    .accessibilityLabel("Dismiss status")
                }
                .textSelection(.enabled)
                .padding(.horizontal, 10).padding(.bottom, 6)
            }
            if let day = store.dayFilter {
                WindowNoticeRow(symbol: "calendar", tint: .accentColor,
                                text: "Last active \(HistoryDayParse.title(day.day))" + (day.provider.map { " · \(ProviderStyle.style(for: $0).name)" } ?? "")) {
                    if store.onOpenHistoryDay != nil {
                        Button("That day in History") { store.onOpenHistoryDay?(day.day) }
                            .buttonStyle(.link)
                            .help("Every started, finished, asked and failed row of that day")
                    }
                    Button { store.dayFilter = nil } label: {
                        Image(systemName: "xmark.circle.fill").font(.system(size: 11))
                    }
                    .buttonStyle(.plain).foregroundStyle(.tertiary)
                    .accessibilityLabel("Show every day")
                }
                .padding(.horizontal, 10).padding(.bottom, 6)
            }
            if let parent = store.workerFilter {
                // The raw agent id ("claude:session:9f3a…") is noise — the
                // parent row's label or short id is the name a user
                // actually recognises.
                let parentName = store.roster.first { $0.id == parent }
                    .map { $0.session.label ?? $0.session.shortId ?? parent } ?? parent
                WindowNoticeRow(symbol: "person.2.fill", tint: .accentColor, text: "Workers of \(parentName)") {
                    Button { store.workerFilter = nil } label: {
                        Image(systemName: "xmark.circle.fill").font(.system(size: 11))
                    }
                    .buttonStyle(.plain).foregroundStyle(.tertiary)
                    .accessibilityLabel("Show all sessions")
                }
                .padding(.horizontal, 10).padding(.bottom, 6)
            }
            Divider()
            if !store.isLive, store.roster.isEmpty {
                OverviewEmptyState(symbol: "bolt.horizontal.circle", title: "Monitor not connected",
                                   text: "The roster comes from the monitor. Rows appear as soon as the socket is live.",
                                   tint: .orange)
            } else if !store.isLive {
                // The window is the record of what happened — a dead
                // socket must not erase it. Show the last roster, dimmed
                // and disclaimed, with live actions gated by `canOpen`/
                // `askAction` which already refuse remote/dead work.
                WindowNoticeRow(symbol: "bolt.horizontal.circle.fill", tint: .orange,
                                text: "Monitor not connected — showing the last roster it reported.")
                    .padding(.horizontal, 10).padding(.vertical, 6)
                rosterTable.opacity(0.55)
            } else if let error = store.error, store.roster.isEmpty {
                OverviewEmptyState(symbol: "exclamationmark.triangle", title: "Couldn't load the roster",
                                   text: error, tint: .orange)
            } else if store.nobodyWaiting {
                // The default view with nothing to answer is good news,
                // not a filter that failed.
                let working = store.workingOverall
                OverviewEmptyState(symbol: "checkmark", title: "Nobody's waiting on you",
                                   text: "When an agent asks for you, it lands here.",
                                   tint: .green,
                                   actionTitle: working > 0 ? "Show \(working) working" : nil,
                                   action: { store.showWorking() })
            } else if store.rows.isEmpty {
                OverviewEmptyState(symbol: store.roster.isEmpty ? "tray" : "line.3.horizontal.decrease.circle",
                                   title: store.roster.isEmpty ? "Nothing on record" : "Nothing matches",
                                   text: store.roster.isEmpty
                                       ? "The monitor has no sessions on record yet."
                                       : "No row fits this view. Try another preset or clear the search.")
            } else {
                rosterTable
            }
            if store.coverageNote != nil {
                // The daemon's note says the roster keeps statuses, not
                // every run; where the rest are is what the reader needs.
                Divider()
                Text("Older runs live in History (⌘Y)")
                    .font(.system(size: 10)).foregroundStyle(.tertiary)
                    .padding(.horizontal, 12).padding(.vertical, 4)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .help(store.coverageNote ?? "")
            }
            if store.counts.listed < store.counts.total {
                Divider()
                // The honest bound: the roster retained more than this
                // scoped answer carried — say so rather than let the
                // table read as the whole record.
                Text("Showing \(store.counts.listed) of \(store.counts.total) sessions on record")
                    .font(.system(size: 10)).foregroundStyle(.tertiary)
                    .padding(.horizontal, 12).padding(.vertical, 4)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    /// The session table — shared by the live branch and the dimmed
    /// offline replay, so both render the identical record.
    @ViewBuilder
    private var rosterTable: some View {
        Table(store.rows, selection: Binding(
            get: { store.selectedIDs },
            set: { store.selectionChanged(to: $0) }
        ), sortOrder: $store.sortOrder) {
                    TableColumn("Task", value: \.labelSortKey) { entry in
                        HStack(spacing: 6) {
                            Text(entry.session.label ?? entry.session.shortId ?? "Session")
                                .lineLimit(1)
                                // A row the panel's aging would hide is a
                                // record, not a live session — muted so
                                // it never reads as current work.
                                .foregroundStyle(entry.visibility == "hidden" ? .tertiary : .primary)
                            if entry.session.workers > 0 {
                                Button {
                                    store.workerFilter = entry.id
                                } label: {
                                    Text("+\(entry.session.workers)")
                                        .foregroundStyle(.secondary).font(.system(size: 10))
                                }
                                .buttonStyle(.plain)
                                .help("\(entry.session.workers) workers — show only this session's workers")
                            }
                            if store.showsUnseenDot(entry) {
                                // `state.unseen_completions`: finished
                                // since the user last looked — the same
                                // unseen dot the panel gives the row.
                                UnseenDot()
                                    .help("Finished since you last looked")
                            }
                            OverviewSnoozedTag(entry: entry, store: store)
                        }
                    }
                    .width(min: 120, ideal: 180)
                    TableColumn("Project", value: \.projectSortKey) { entry in
                        HStack(spacing: 4) {
                            Text(OverviewFilter.projectName(of: entry.session.cwd) ?? "—")
                                .foregroundStyle(.secondary).lineLimit(1)
                            if let workspace = store.workspace(for: entry), let head = workspace.headLabel {
                                // The branch (and a worktree mark) the run
                                // works on: agents in worktrees of one repo
                                // read apart without opening the inspector.
                                if workspace.isLinkedWorktree {
                                    Image(systemName: "square.split.2x1")
                                        .font(.system(size: 8)).foregroundStyle(.tertiary)
                                }
                                Text(head).foregroundStyle(.tertiary).lineLimit(1).truncationMode(.middle)
                            }
                        }
                        .help(store.workspace(for: entry).map { workspace in
                            "\(workspace.repositoryName) · \(workspace.headLabel ?? "no HEAD")"
                                + (workspace.isLinkedWorktree ? " · linked worktree at \(workspace.root)" : "")
                        } ?? (entry.session.cwd ?? ""))
                    }
                    .width(min: 70, ideal: 120)
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
                    TableColumn("Model", value: \.modelSortKey) { entry in
                        // The model the run's own transcript names; a row
                        // not read (or a provider whose transcripts are
                        // not read) is an honest blank, not a guess.
                        if let usage = store.usage(for: entry), let model = usage.modelName {
                            Text(model).foregroundStyle(.secondary).lineLimit(1)
                                .help(usage.summary)
                        } else {
                            Text("—").foregroundStyle(.tertiary)
                                .help(store.sessionUsage.gap(for: entry.id).map(SessionUsageDocument.gapText)
                                      ?? "Not read yet")
                        }
                    }
                    .width(min: 56, ideal: 76)
                    TableColumn("Cost", value: \.costSortKey) { entry in
                        if let usage = store.usage(for: entry), let cost = usage.costText {
                            Text(cost).monospacedDigit().foregroundStyle(.secondary).lineLimit(1)
                                .help("\(usage.summary)\nAPI-equivalent estimate from list prices, not an invoice")
                        } else {
                            Text("—").foregroundStyle(.tertiary)
                        }
                    }
                    .width(min: 44, ideal: 58)
                    TableColumn("State", value: \.stateSortKey) { entry in
                        stateCell(entry)
                    }
                    .width(min: 76, ideal: 96)
                    TableColumn("Current activity", value: \.activitySortKey) { entry in
                        Text(entry.session.activityCaption)
                            .foregroundStyle(.secondary).lineLimit(1).truncationMode(.tail)
                    }
                    .width(min: 120, ideal: 200)
                    TableColumn("Quiet", value: \.elapsedSortKey) { entry in
                        OverviewQuietCell(entry: entry, store: store)
                    }
                    .width(min: 48, ideal: 56)
                    TableColumn("Freshness", value: \.freshnessSortKey) { entry in
                        freshnessCell(entry)
                    }
                    .width(min: 64, ideal: 80)
                    TableColumn("Attention", value: \.attentionSortKey) { entry in
                        OverviewAttentionCell(entry: entry, store: store)
                    }
                    .width(min: 44, ideal: 60)
                }
                .contextMenu(forSelectionType: String.self) { ids in
                    let entry = store.rows.first { ids.contains($0.id) }
                    // The menu acts on the CLICKED row — `openSelected`
                    // fires on the primary selection, which can diverge
                    // when the right-clicked row isn't it.
                    Button("Open session") { if let entry { Task { await store.openSession(entry.id) } } }
                        .disabled(entry.map { !store.canOpen($0) } ?? true)
                        .help(entry.map { e in store.canOpen(e)
                            ? "Open the session's terminal"
                            : "A remote session — open it on \(e.session.origin?.label ?? "that Mac")" } ?? "")
                    if let entry, !entry.session.remote, let ask = store.deskAsk(for: entry), AskVerbs.chooses(ask) {
                        // A held question: its options, through the hook.
                        Divider()
                        Menu(AskChoiceLayout.menuTitle(ask.decision?.choices ?? [],
                                                       picks: store.askDesk.picks(for: ask))) {
                            AskChoiceMenuItems(choices: ask.decision?.choices ?? [],
                                               picks: store.askDesk.picks(for: ask),
                                               pick: { label, choice in
                                                   Task { await store.pick(label, in: choice, entry: entry) }
                                               },
                                               send: { Task { await store.sendPicks(entry: entry) } })
                        }
                        Button("Deny ask") { Task { await store.declineQuestion(entry: entry) } }
                    } else if let entry, store.askAction(for: entry) == .actionable, let ask = entry.session.ask {
                        Divider()
                        if AskVerbs.approves(ask) {
                            Button("Approve ask") { Task { await store.answerAsk(entry: entry, approve: true) } }
                        }
                        if AskVerbs.alwaysAllows(ask) {
                            Button("Always allow") { Task { await store.alwaysAllow(entry: entry) } }
                        }
                        if AskVerbs.denies(ask) {
                            Button("Deny ask") { Task { await store.answerAsk(entry: entry, approve: false) } }
                        }
                        if store.canReply(entry) {
                            Button("Reply…") { replyEntry = entry }
                        }
                    } else if let entry, let reason = store.askDisabledReason(for: entry),
                              entry.session.ask != nil {
                        Text(reason)
                    }
                    if let entry {
                        Divider()
                        Button("Mark reviewed") { Task { await store.markReviewed(entry: entry) } }
                            .disabled(entry.session.remote || entry.session.ask != nil)
                            .help(entry.session.ask != nil
                                ? "A row pinned by an open ask cannot be dismissed — answer it first"
                                : (entry.session.remote
                                    ? "A remote session is the peer's to manage"
                                    : "Acknowledge until the session next speaks"))
                        Button("Snooze 1h") { Task { await store.snooze(entry: entry) } }
                            .disabled(entry.session.remote)
                            .help(entry.session.remote
                                ? "A remote session is the peer's to snooze"
                                : "Mute this session's family mailbox for an hour")
                        if store.canStartHere(entry) {
                            Divider()
                            Button("New \(ProviderStyle.style(for: entry.session.provider).name) Session Here") {
                                Task { await store.startSessionHere(entry) }
                            }
                            .help("Start \(ProviderStyle.style(for: entry.session.provider).name) in your terminal at \(entry.session.cwd ?? "this folder")")
                        }
                    }
                    if store.canCompare {
                        Divider()
                        Button("Compare selected runs") { store.compareSelected() }
                    }
                }
    }

    /// A chip's spoken form: group, title, tone and subtitle — the same
    /// words the tooltip says, so VoiceOver hears the link's status,
    /// not just its name.
    static func chipLabel(_ link: OverviewLink) -> String {
        var parts = ["\(link.group.title): \(link.title)"]
        if let subtitle = link.subtitle { parts.append(subtitle) }
        parts.append(link.tone.rawValue)
        return parts.joined(separator: ", ")
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


    @ViewBuilder
    private func freshnessCell(_ entry: CoreRosterEntry) -> some View {
        let word = entry.axes?.freshness ?? (entry.session.stale ? "stale" : "live")
        HStack(spacing: 4) {
            if word != "live" {
                Image(systemName: "clock.badge.exclamationmark").font(.system(size: 9))
            }
            Text(word).foregroundStyle(word == "live" ? Color.secondary : Color.orange)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Freshness: \(word)")
    }

    /// The attention cell's spoken form — extracted so tests can assert
    /// the exact string VoiceOver reads.
    static func attentionLabel(_ entry: CoreRosterEntry, now: Date) -> String {
        var parts: [String] = []
        if entry.pinned || entry.session.ask != nil {
            parts.append("Waiting on you")
            if let waiting = OverviewStore.waitingText(entry, now: now) {
                parts.append(waiting)
            }
        }
        if entry.axes?.outcome == "failed" { parts.append("Failed") }
        return parts.isEmpty ? "No attention needed" : parts.joined(separator: ", ")
    }

    // MARK: Inspector

    @ViewBuilder
    private var inspector: some View {
        if store.pane == .usage {
            UsageGraphFacts(store: store)
        } else if let entry = store.selected {
            OverviewSessionInspector(store: store, entry: entry) { replyEntry = $0 }
        } else if let link = store.selectedLink {
            OverviewConnectionInspector(link: link)
        } else {
            OverviewConnectionsBrowser(store: store)
        }
    }
}

// MARK: - The table's clock cells

// The cells that draw the one-second clock, each its own view: a tick
// re-renders these and nothing else, where reading `store.now` in the
// table's column builders re-rendered the whole window every second.

/// "snoozed" beside a title while the family mailbox is muted.
struct OverviewSnoozedTag: View {
    let entry: CoreRosterEntry
    let store: OverviewStore

    var body: some View {
        if OverviewStore.isSnoozed(entry, now: store.now) {
            Text("snoozed").font(.system(size: 10))
                .foregroundStyle(.tertiary).lineLimit(1)
                .help(OverviewStore.snoozeWakeText(entry) ?? "Snoozed")
        }
    }
}

/// The "Quiet" column: how long since the session last spoke — `since`
/// is the last-event stamp, not a start time.
struct OverviewQuietCell: View {
    let entry: CoreRosterEntry
    let store: OverviewStore

    static func text(_ entry: CoreRosterEntry, now: Date) -> String {
        guard let since = entry.session.since else { return "—" }
        return AgentMonitorFeed.ageText(max(0, now.timeIntervalSince1970 - since))
    }

    var body: some View {
        Text(Self.text(entry, now: store.now))
            .monospacedDigit().foregroundStyle(.secondary)
    }
}

/// The "Attention" column: an open ask, a failure, and how long the ask
/// has waited.
struct OverviewAttentionCell: View {
    let entry: CoreRosterEntry
    let store: OverviewStore

    var body: some View {
        let now = store.now
        HStack(spacing: 5) {
            if entry.pinned || entry.session.ask != nil {
                Image(systemName: "exclamationmark.bubble.fill").foregroundStyle(.orange)
                    .help(entry.session.ask?.summary ?? "Waiting on you")
            }
            if entry.axes?.outcome == "failed" {
                Image(systemName: "xmark.octagon.fill").foregroundStyle(.red)
                    .help("Run failed — outcome reported by the monitor")
            }
            if let waiting = OverviewStore.waitingText(entry, now: now) {
                Text(waiting).font(.system(size: 9))
                    .foregroundStyle(.orange).lineLimit(1)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(OverviewView.attentionLabel(entry, now: now))
    }
}

/// S7.4 run comparison: two sides on retained facts — roster axes,
/// transcript aggregates, ledger interruptions — with the benchmark
/// warning and named gaps always visible, never a verdict the facts
/// cannot carry.
struct CompareRunsSheet: View {
    let comparison: CoreRunComparison
    /// Both sides' `session_usage` — model, tokens, cost — which the
    /// daemon's comparison names as untracked; read here, per side.
    let usage: SessionUsageStore

    private func usage(_ side: CoreRunSide) -> SessionUsage? { usage.usage(for: side.id) }

    /// The comparison's gaps, minus the one this sheet fills: once both
    /// sides' transcripts named their model, "model not tracked" is no
    /// longer true of what is on screen.
    private var gaps: [String] {
        let modelsKnown = usage(comparison.a)?.model != nil && usage(comparison.b)?.model != nil
        return comparison.gaps.filter { !(modelsKnown && $0 == "model_not_tracked") }
    }

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
                compareRow("Model") { side in
                    usage(side)?.modelName ?? "not read"
                }
                compareRow("Tokens") { side in
                    guard let tokens = usage(side)?.tokens, tokens.total > 0 else { return "—" }
                    let cached = tokens.cacheShare.map { " · \(Int(($0 * 100).rounded()))% cached" } ?? ""
                    return UsageFormat.tokens(tokens.total) + cached
                }
                compareRow("Cost (est.)") { side in
                    usage(side)?.costText ?? "—"
                }
                compareRow("Context") { side in
                    usage(side)?.contextText ?? "—"
                }
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
                compareRow("Files changed") { side in
                    guard let artifacts = side.artifacts else { return "—" }
                    let edits = artifacts.files.reduce(0) { $0 + $1.edits }
                    return artifacts.total == 0 ? "none"
                        : "\(artifacts.total) · \(edits) edit\(edits == 1 ? "" : "s")\(artifacts.truncated ? "+" : "")"
                }
                compareRow("Top tools") { side in
                    side.activity.map { activity in
                        activity.tools.prefix(3)
                            .map { "\($0.key) ×\($0.value)" }
                            .joined(separator: ", ")
                    }.flatMap { $0.isEmpty ? nil : $0 } ?? "—"
                }
            }
            .font(.system(size: 12))
            if let a = comparison.a.artifacts, let b = comparison.b.artifacts, a.total + b.total > 0 {
                filesSection(RunFileDiff(a: a, b: b))
            }
            ForEach(gaps, id: \.self) { gap in
                Text(Self.gapText(gap)).font(.system(size: 10)).foregroundStyle(.orange)
            }
            if usage(comparison.a)?.estimatedCostUSD != nil || usage(comparison.b)?.estimatedCostUSD != nil {
                Text("Costs are API-equivalent estimates from list prices — not invoices, and not a verdict on which model is better.")
                    .font(.system(size: 10)).foregroundStyle(.tertiary)
            }
        }
        .padding(20)
        .frame(minWidth: 560)
    }

    /// The files each run's edits named: those both touched, then each
    /// side's own — the "what did it actually change" the counts cannot say.
    private func filesSection(_ diff: RunFileDiff) -> some View {
        Grid(alignment: .topLeading, horizontalSpacing: 16, verticalSpacing: 4) {
            if !diff.both.isEmpty {
                GridRow {
                    Text("Both").foregroundStyle(.tertiary).frame(width: 90, alignment: .leading)
                    fileList(diff.both).gridCellColumns(2)
                }
            }
            GridRow {
                Text("Only here").foregroundStyle(.tertiary).frame(width: 90, alignment: .leading)
                fileList(diff.onlyA)
                fileList(diff.onlyB)
            }
        }
        .font(.system(size: 11))
    }

    private func fileList(_ paths: [String]) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            if paths.isEmpty {
                Text("—").foregroundStyle(.quaternary)
            }
            ForEach(paths.prefix(8), id: \.self) { path in
                Text(path).font(.system(size: 10, design: .monospaced))
                    .lineLimit(1).truncationMode(.head).textSelection(.enabled)
                    .help(path)
            }
            if paths.count > 8 {
                Text("+\(paths.count - 8) more").font(.system(size: 10)).foregroundStyle(.tertiary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
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

    /// Whole minutes and seconds under an hour and a half: a formatted
    /// `seconds / 60` rounds, so 119 s would read "2m 59s".
    static func durationText(_ seconds: Double) -> String {
        if seconds < 90 { return String(format: "%.0fs", seconds) }
        if seconds < 5400 {
            let whole = Int(seconds)
            return "\(whole / 60)m \(whole % 60)s"
        }
        return String(format: "%.1fh", seconds / 3600)
    }

    private static func gapText(_ gap: String) -> String {
        switch gap {
        case "artifacts_not_tracked": "Files changed are unknown for a run whose transcript was not read."
        case "model_not_tracked": "Model is not tracked per session — differences are unknown, not equal."
        default: gap
        }
    }
}

/// The Overview's empty states — the roster's, the graph's and the usage
/// pane's (and the Event Replay's) — in the windows' shared look.
struct OverviewEmptyState: View {
    let symbol: String
    let title: String
    let text: String
    var tint: Color = .secondary
    /// One way on from the empty state, when there is an obvious one.
    var actionTitle: String? = nil
    var action: (() -> Void)? = nil

    var body: some View {
        WindowEmptyState(symbol: symbol, title: title, text: text, tint: tint,
                         actionTitle: actionTitle, action: action)
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
            store.error = OverviewStore.describe(error)
        }
    }
}

/// "Export this run": the Markdown previewed, then saved as-is.
private struct RunExportSheet: View {
    @Bindable var store: OverviewStore

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Export this run").font(.system(size: 15, weight: .semibold))
            if let preview = store.runExportPreview {
                ScrollView {
                    Text(preview.markdown)
                        .font(.system(size: 11, design: .monospaced))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(minHeight: 260)
                .padding(8)
                .background(.quaternary.opacity(0.4), in: .rect(cornerRadius: 8))
            }
            HStack {
                Text("What you see is what is saved.").font(.system(size: 11)).foregroundStyle(.tertiary)
                Spacer()
                Button("Cancel") { store.runExportPreview = nil }
                    .keyboardShortcut(.cancelAction)
                Button("Save Markdown…") { save() }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(16)
        .frame(width: 560, height: 480)
    }

    private func save() {
        guard let preview = store.runExportPreview else { return }
        let panel = NSSavePanel()
        panel.nameFieldStringValue = preview.name
        panel.allowedContentTypes = [.plainText]
        panel.message = "The previewed run is written as-is."
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try store.saveRunExport(to: url)
            store.runExportPreview = nil
        } catch {
            store.error = OverviewStore.describe(error)
        }
    }
}

private extension OverviewPreset {
    var symbol: String {
        switch self {
        case .needsMe: return "exclamationmark.bubble"
        case .failed: return "xmark.octagon"
        case .working: return "gearshape"
        case .unreviewed: return "checkmark.circle.badge.questionmark"
        case .thisProject: return "folder"
        case .thisMac: return "desktopcomputer"
        case .thisBranch: return "arrow.triangle.branch"
        case .all: return "globe"
        }
    }
}

/// The Reply… prompt: a small sheet with a multiline editor, Send and
/// Cancel — the one explicit free-text action the daemon accepts on a
/// `replyable` ask. Send stays disabled on empty text (the daemon would
/// refuse `reply_text` that normalizes to nothing anyway); the reply
/// goes through `answerAskNow` with the ask's `request` pinned, so a
/// stale card gets the daemon's refusal, not a silent send. Nothing
/// here ever fires on its own.
private struct ReplyPromptSheet: View {
    @Bindable var store: OverviewStore
    let entry: CoreRosterEntry
    @ViewState private var text = ""
    @ViewState private var sending = false
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Reply to \(entry.session.label ?? entry.session.shortId ?? "session")")
                .font(.system(size: 14, weight: .semibold))
            if let summary = entry.session.ask?.summary {
                Text(summary).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(3)
            }
            TextEditor(text: $text)
                .font(.system(size: 12))
                .frame(minHeight: 110)
                .padding(6)
                .background(.quaternary.opacity(0.35), in: .rect(cornerRadius: 8))
                .accessibilityLabel("Reply text")
            HStack {
                if sending { DelayedWait(size: 12) }
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                    .disabled(sending)
                Button("Send") { send() }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
                    .disabled(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || sending)
            }
        }
        .padding(16)
        .frame(width: 380)
    }

    private func send() {
        let reply = text
        sending = true
        Task {
            await store.reply(entry: entry, text: reply)
            sending = false
            // The daemon's verdict lands on the store's status line;
            // close only on a delivered answer — a refusal keeps the
            // draft open so the text isn't lost.
            if store.actionIsError == false { dismiss() }
        }
    }
}
