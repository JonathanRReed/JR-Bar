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
    /// The inspector's Advanced disclosure (static topology), closed
    /// until opened and remembered once it is.
    @AppStorage("overview.advancedExpanded") private var advancedExpanded = false

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
                            ProgressView().controlSize(.mini)
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
            if let entry = store.selected {
                Task { await store.loadRadarReport(for: entry) }
            }
        }
    }

    // MARK: Sidebar

    @ViewBuilder
    private var sidebar: some View {
        List(selection: Binding(
            // The Usage tag carries `saved: nil` — emit it that way while
            // the usage pane is up or a live saved filter makes the
            // selection match nothing and the sidebar shows no highlight.
            get: { SidebarSelection(filter: store.filter, saved: store.pane == .usage ? nil : store.activeSavedFilter, pane: store.pane) },
            set: { selection in
                guard let selection else { return }
                if selection.pane == .usage {
                    store.showUsage()
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
        if store.pane == .usage {
            UsageGraphView(store: store)
        } else {
            rosterContent
        }
    }

    @ViewBuilder
    private var rosterContent: some View {
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
            if let status = store.actionStatus {
                HStack(spacing: 8) {
                    Image(systemName: store.actionIsError ? "xmark.octagon" : "checkmark.circle")
                        .foregroundStyle(store.actionIsError ? .red : .green)
                    Text(status).font(.system(size: 11))
                        .foregroundStyle(store.actionIsError ? .red : .secondary)
                        .lineLimit(1).truncationMode(.tail).textSelection(.enabled)
                    Spacer()
                    Button { store.actionStatus = nil } label: {
                        Image(systemName: "xmark").font(.system(size: 9))
                    }
                    .buttonStyle(.plain).foregroundStyle(.tertiary)
                    .accessibilityLabel("Dismiss status")
                }
                .padding(.horizontal, 12).padding(.vertical, 5)
                .accessibilityElement(children: .combine)
            }
            if let day = store.dayFilter {
                HStack(spacing: 8) {
                    Image(systemName: "calendar").foregroundStyle(.secondary)
                    Text("Last active \(HistoryDayParse.title(day.day))" + (day.provider.map { " · \(ProviderStyle.style(for: $0).name)" } ?? ""))
                        .font(.system(size: 11)).foregroundStyle(.secondary)
                    Spacer()
                    if store.onOpenHistoryDay != nil {
                        Button("That day in History") { store.onOpenHistoryDay?(day.day) }
                            .buttonStyle(.link).font(.system(size: 11))
                            .help("Every started, finished, asked and failed row of that day")
                    }
                    Button { store.dayFilter = nil } label: {
                        Image(systemName: "xmark.circle.fill").font(.system(size: 11))
                    }
                    .buttonStyle(.plain).foregroundStyle(.tertiary)
                    .accessibilityLabel("Show every day")
                }
                .padding(.horizontal, 12).padding(.vertical, 5)
                .accessibilityElement(children: .combine)
            }
            if let parent = store.workerFilter {
                HStack(spacing: 8) {
                    Image(systemName: "person.2").foregroundStyle(.secondary)
                    // The raw agent id ("claude:session:9f3a…") is noise —
                    // the parent row's label or short id is the name a
                    // user actually recognises.
                    let parentName = store.roster.first { $0.id == parent }
                        .map { $0.session.label ?? $0.session.shortId ?? parent } ?? parent
                    Text("Workers of \(parentName)").font(.system(size: 11)).foregroundStyle(.secondary)
                    Spacer()
                    Button { store.workerFilter = nil } label: {
                        Image(systemName: "xmark.circle.fill").font(.system(size: 11))
                    }
                    .buttonStyle(.plain).foregroundStyle(.tertiary)
                    .accessibilityLabel("Show all sessions")
                }
                .padding(.horizontal, 12).padding(.vertical, 5)
                .accessibilityElement(children: .combine)
            }
            Divider()
            if !store.isLive, store.roster.isEmpty {
                OverviewEmptyState(symbol: "bolt.horizontal.circle", title: "Monitor not connected",
                                   text: "The roster comes from the monitor. Rows appear as soon as the socket is live.")
            } else if !store.isLive {
                // The window is the record of what happened — a dead
                // socket must not erase it. Show the last roster, dimmed
                // and disclaimed, with live actions gated by `canOpen`/
                // `askAction` which already refuse remote/dead work.
                HStack(spacing: 6) {
                    Image(systemName: "bolt.horizontal.circle")
                        .foregroundStyle(.orange)
                    Text("Monitor not connected — showing the last roster it reported.")
                        .font(.system(size: 10)).foregroundStyle(.secondary)
                    Spacer()
                }
                .padding(.horizontal, 12).padding(.vertical, 5)
                .background(.orange.opacity(0.07))
                rosterTable.opacity(0.55)
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
                rosterTable
            }
            if let note = store.coverageNote {
                Divider()
                Text(note)
                    .font(.system(size: 10)).foregroundStyle(.tertiary)
                    .padding(.horizontal, 12).padding(.vertical, 4)
                    .frame(maxWidth: .infinity, alignment: .leading)
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
                                // accent dot the panel gives the row.
                                Circle().fill(Color.accentColor).frame(width: 5, height: 5)
                                    .help("Finished since you last looked")
                            }
                            if OverviewStore.isSnoozed(entry, now: store.now) {
                                Text("snoozed").font(.system(size: 10))
                                    .foregroundStyle(.tertiary).lineLimit(1)
                                    .help(OverviewStore.snoozeWakeText(entry) ?? "Snoozed")
                            }
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
                    } else if let entry, store.askAction(for: entry) == .actionable {
                        Divider()
                        Button("Approve ask") { Task { await store.answerAsk(entry: entry, approve: true) } }
                        if let ask = entry.session.ask, AskVerbs.alwaysAllows(ask) {
                            Button("Always allow") { Task { await store.alwaysAllow(entry: entry) } }
                        }
                        Button("Deny ask") { Task { await store.answerAsk(entry: entry, approve: false) } }
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
                    }
                    if store.canCompare {
                        Divider()
                        Button("Compare selected runs") { store.compareSelected() }
                    }
                }
    }

    /// "2 live · 1 needs you · 1 failed · 1 unreviewed · 3 hidden" —
    /// over the filtered rows, so the strip and the table can never
    /// disagree. Failed gets its own red word: a dead run is not a
    /// question and must not read as one anywhere in the window.
    @ViewBuilder
    private var summaryStrip: some View {
        let counts = store.stripCounts
        HStack(spacing: 10) {
            Text("\(counts.live) live")
            if counts.attention > 0 {
                Text("· \(counts.attention) need\(counts.attention == 1 ? "s" : "") you").foregroundStyle(.orange)
            }
            if counts.failed > 0 {
                Text("· \(counts.failed) failed").foregroundStyle(.red)
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
        .accessibilityLabel(Self.chipLabel(link))
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

    /// The "Quiet" column: how long since the session last spoke —
    /// `since` is the last-event stamp, not a start time.
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
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Freshness: \(word)")
    }

    @ViewBuilder
    private func attentionCell(_ entry: CoreRosterEntry) -> some View {
        HStack(spacing: 5) {
            if entry.pinned || entry.session.ask != nil {
                Image(systemName: "exclamationmark.bubble.fill").foregroundStyle(.orange)
                    .help(entry.session.ask?.summary ?? "Waiting on you")
            }
            if entry.axes?.outcome == "failed" {
                Image(systemName: "xmark.octagon.fill").foregroundStyle(.red)
                    .help("Run failed — outcome reported by the monitor")
            }
            if let waiting = OverviewStore.waitingText(entry, now: store.now) {
                Text(waiting).font(.system(size: 9))
                    .foregroundStyle(.orange).lineLimit(1)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(Self.attentionLabel(entry, now: store.now))
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
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    Text(entry.session.label ?? entry.session.shortId ?? "Session")
                        .font(.system(size: 15, weight: .semibold))
                        .lineLimit(2)
                    inspectorFacts(entry)
                    if let ask = entry.session.ask {
                        waitingSection(entry: entry, ask: ask)
                    }
                    if let message = entry.session.message, !message.isEmpty {
                        inspectorSection("Last message", text: message)
                    }
                    if let coverage = store.coverageNote, entry.visibility == "hidden" {
                        Text(coverage).font(.system(size: 10)).foregroundStyle(.tertiary)
                    }
                    timelineSection(for: entry)
                    observedToolsSection(for: entry)
                    if let previous = store.previousRun(for: entry) {
                        Button {
                            store.compareWithPreviousRun(entry)
                        } label: {
                            Label("Compare with the previous run here", systemImage: "arrow.left.arrow.right")
                                .font(.system(size: 11))
                        }
                        .buttonStyle(.link)
                        .disabled(store.comparing)
                        .help("Side by side with \(previous.session.label ?? previous.session.shortId ?? "the last finished run") in the same folder")
                    }
                    advancedSection(for: entry)
                    if entry.session.remote {
                        Label("Remote row — open it on \(entry.session.origin?.label ?? "that Mac").", systemImage: "network")
                            .font(.system(size: 11)).foregroundStyle(.secondary)
                    } else {
                        // The button names its target: the terminal app
                        // the daemon says hosts the session — "Open in
                        // iTerm", never a bare promise.
                        let app = entry.session.terminal?.app
                        Button(app.map { "Open in \($0)" } ?? "Open session") { store.openSelected() }
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
            if let usage = store.usage(for: entry) {
                // `session_usage`: the run's own transcript, read for
                // model and tokens — reported by the provider; the cost is
                // the daemon's list-price arithmetic, so derived.
                if let model = usage.modelName {
                    fact("Model (transcript)", model, evidence: .reported)
                }
                if usage.models.count > 1 {
                    fact("Models", usage.models.sorted { $0.value > $1.value }
                        .map { "\(ModelName.display($0.key) ?? $0.key) \(UsageFormat.tokens($0.value))" }
                        .joined(separator: ", "), evidence: .reported)
                }
                if usage.tokens.total > 0 {
                    fact("Tokens", Self.tokensFact(usage), evidence: .reported)
                }
                if let cost = usage.costText {
                    fact("Cost", cost + (usage.costEstimated ? " (stand-in rate)" : ""), evidence: .derived)
                }
                if let context = usage.contextText {
                    fact("Context", context, evidence: usage.contextWindowSource == "reported" ? .reported : .derived)
                }
            } else if let model = store.transcriptModel, store.timelineSessionID == entry.id {
                // The transcript's own word for the model — the label
                // names the source so it never reads as a roster fact.
                fact("Model (transcript)", model, evidence: .reported)
            } else {
                fact("Model", store.sessionUsage.gap(for: entry.id).map(SessionUsageDocument.gapText) ?? "not read yet",
                     evidence: .unavailable)
            }
        }
        .font(.system(size: 11))
        .foregroundStyle(.secondary)
    }

    /// "1.2M in 48 turns · 84% cached".
    static func tokensFact(_ usage: SessionUsage) -> String {
        var text = "\(UsageFormat.tokens(usage.tokens.total)) in \(usage.turns) turn\(usage.turns == 1 ? "" : "s")"
        if let share = usage.tokens.cacheShare, share >= 0.01 {
            text += " · \(Int((share * 100).rounded()))% cached"
        }
        return text
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

    /// The "Waiting on you" section: the ask's summary and age, then the
    /// explicit actions — Approve / Deny / Reply…. Every button sends
    /// through `answerAskNow` with the ask's `request` pinned, so the
    /// daemon itself refuses a stale card (`stale_request`) or an ask
    /// that moved on. Nothing here ever auto-answers; disabled buttons
    /// carry the reason as a tooltip rather than silently greying.
    @ViewBuilder
    private func waitingSection(entry: CoreRosterEntry, ask: CoreAsk) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Text("Waiting on you")
                    .font(.system(size: 10, weight: .semibold)).foregroundStyle(.tertiary)
                if let waiting = OverviewStore.waitingText(entry, now: store.now) {
                    Text(waiting).font(.system(size: 10)).foregroundStyle(.orange)
                }
            }
            Text(ask.summary ?? "This session has an open question.")
                .font(.system(size: 12)).textSelection(.enabled)
            if let preview = ask.previewLine {
                HStack(spacing: 5) {
                    if ask.isDestructive { AskRiskMark(size: 10) }
                    Text(preview)
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(ask.isDestructive ? AnyShapeStyle(Color.red) : AnyShapeStyle(.secondary))
                        .textSelection(.enabled)
                        .lineLimit(3)
                }
            } else if ask.isDestructive {
                Label("Destructive — it can lose work if it runs by mistake", systemImage: "exclamationmark.triangle.fill")
                    .font(.system(size: 10)).foregroundStyle(.red)
            }
            if !entry.session.remote, AskVerbs.chooses(ask) {
                // A held question: its options are the answer, through
                // the agent's own hook, from whatever terminal hosts it.
                choiceSection(entry: entry, ask: ask)
            } else {
                let reason = store.askDisabledReason(for: entry)
                HStack(spacing: 8) {
                    Button("Approve") {
                        Task { await store.answerAsk(entry: entry, approve: true) }
                    }
                    .buttonStyle(.borderedProminent).controlSize(.small).tint(.green)
                    if AskVerbs.alwaysAllows(ask) {
                        // Its own button: the agent remembers the rule.
                        Button("Always Allow") {
                            Task { await store.alwaysAllow(entry: entry) }
                        }
                        .buttonStyle(.bordered).controlSize(.small)
                        .help("Approve, and let the agent remember the rule it offered")
                    }
                    Button("Deny") {
                        Task { await store.answerAsk(entry: entry, approve: false) }
                    }
                    .buttonStyle(.bordered).controlSize(.small).tint(.red)
                    if store.canReply(entry) {
                        Button("Reply…") { replyEntry = entry }
                            .buttonStyle(.bordered).controlSize(.small)
                    }
                }
                .disabled(reason != nil)
                .help(reason ?? (ask.isHeldForDecision
                    ? "Answered through the agent's own permission hook — the monitor's verdict is shown on the status line"
                    : "Send the answer to the session's terminal — the monitor's verdict is shown on the status line"))
                if let reason {
                    Label(reason, systemImage: "info.circle")
                        .font(.system(size: 10)).foregroundStyle(.tertiary)
                }
            }
        }
    }

    /// A held question in the inspector: every question with its options
    /// as buttons — one click answers a single-pick question; several
    /// parts pick first and then Send — and Deny, which declines it.
    @ViewBuilder
    private func choiceSection(entry: CoreRosterEntry, ask: CoreAsk) -> some View {
        let choices = ask.decision?.choices ?? []
        let picks = store.askDesk.picks(for: ask)
        let oneClick = choices.count == 1 && choices.first?.multi == false
        let busy = store.askDesk.isPending(entry.id)
        VStack(alignment: .leading, spacing: 6) {
            ForEach(choices, id: \.question) { choice in
                VStack(alignment: .leading, spacing: 3) {
                    Text(choice.header.map { "\($0) — \(choice.question)" } ?? choice.question)
                        .font(.system(size: 11, weight: .medium))
                    WrapRow {
                        ForEach(choice.options, id: \.self) { label in
                            if picks.isPicked(label, in: choice) {
                                optionButton(label, choice: choice, entry: entry)
                                    .buttonStyle(.borderedProminent)
                            } else {
                                optionButton(label, choice: choice, entry: entry)
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

    private func optionButton(_ label: String, choice: CoreAskChoice, entry: CoreRosterEntry) -> some View {
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
    private func timelineSection(for entry: CoreRosterEntry) -> some View {
        if entry.session.remote {
            // The transcript lives on the peer Mac — a local fetch can
            // only answer "not found", which reads as broken.
            VStack(alignment: .leading, spacing: 5) {
                Text("Timeline")
                    .font(.system(size: 10, weight: .semibold)).foregroundStyle(.tertiary)
                Text("The transcript is on \(entry.session.origin?.label ?? "the remote Mac") — open the session there to read it.")
                    .font(.system(size: 10)).foregroundStyle(.secondary)
            }
        } else {
        VStack(alignment: .leading, spacing: 5) {
            HStack {
                Text("Timeline").font(.system(size: 10, weight: .semibold)).foregroundStyle(.tertiary)
                Spacer()
                if store.timelineLoading { ProgressView().controlSize(.mini) }
                Button {
                    Task { await store.refreshTimeline() }
                } label: {
                    Image(systemName: "arrow.clockwise").font(.system(size: 9))
                }
                .buttonStyle(.plain).foregroundStyle(.tertiary)
                .disabled(store.timelineLoading || store.timelinePage == nil)
                .help("Reload the newest page")
                .accessibilityLabel("Refresh timeline")
                Button {
                    store.prepareRunExport(entry)
                } label: {
                    Image(systemName: "square.and.arrow.up").font(.system(size: 9))
                }
                .buttonStyle(.plain).foregroundStyle(.tertiary)
                .disabled(store.timelinePage == nil || store.timelineSessionID != entry.id)
                .help("Export this run as Markdown: its facts, what happened and the timeline")
                .accessibilityLabel("Export this run as Markdown")
                if let page = store.timelinePage, store.timelineSessionID == entry.id, page.hasMore {
                    Button("Load earlier") { Task { await store.loadEarlierTimeline() } }
                        .controlSize(.mini)
                }
            }
            if store.timelineSessionID == entry.id {
                if let page = store.timelinePage {
                    // The one timeline view History and the Data Hoarder
                    // mount too: the story card, the honest gaps, the
                    // kind chips, jump to error and the rows.
                    if let archived = store.archivedTimeline, archived.id == entry.id {
                        // The live transcript is gone but the Data Hoarder
                        // kept it: the same view, labelled as the archive's.
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
                                .font(.system(size: 10))
                        }
                        .buttonStyle(.plain).foregroundStyle(.orange)
                        .help("Open Data Hoarder seeded with this session's id")
                    }
                    if let file = page.file {
                        archiveSourceLine(file: file, total: page.total)
                    }
                } else if store.timelineLoading {
                    Text("Reading transcript…").font(.system(size: 11)).foregroundStyle(.tertiary)
                }
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
                .font(.system(size: 9)).foregroundStyle(.quaternary)
                .textSelection(.enabled)
            if let state = store.archiveStates[file], let row = state {
                HStack(spacing: 6) {
                    Text("Archived")
                        .font(.system(size: 8, weight: .medium))
                        .padding(.horizontal, 5).padding(.vertical, 1)
                        .background(Color.green.opacity(0.15), in: .capsule)
                        .foregroundStyle(.green)
                    Button("Reveal") {
                        NSWorkspace.shared.activateFileViewerSelecting(
                            [URL(fileURLWithPath: row.path)])
                    }
                    .buttonStyle(.plain).font(.system(size: 9))
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
    private func observedToolsSection(for entry: CoreRosterEntry) -> some View {
        let map = store.observedTools
        if store.timelineSessionID == entry.id, !map.isEmpty {
            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 6) {
                    Text("Tools used")
                        .font(.system(size: 10, weight: .semibold)).foregroundStyle(.tertiary)
                    Text("observed")
                        .font(.system(size: 8, weight: .medium))
                        .padding(.horizontal, 4).padding(.vertical, 1)
                        .background(Color.accentColor.opacity(0.15), in: .capsule)
                        .foregroundStyle(Color.accentColor)
                    Spacer()
                    Text("\(map.totalCalls) calls in the loaded transcript")
                        .font(.system(size: 9)).foregroundStyle(.quaternary)
                }
                if !map.tools.isEmpty {
                    Text(map.tools.prefix(10).map(Self.toolText).joined(separator: " · "))
                        .font(.system(size: 10)).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .textSelection(.enabled)
                }
                ForEach(map.servers) { server in
                    HStack(alignment: .firstTextBaseline, spacing: 5) {
                        Image(systemName: "server.rack")
                            .font(.system(size: 8)).foregroundStyle(.tertiary)
                        Text(server.name).font(.system(size: 10, weight: .medium)).foregroundStyle(.secondary)
                        Text(server.tools.prefix(6).map(Self.toolText).joined(separator: " · "))
                            .font(.system(size: 10)).foregroundStyle(.tertiary)
                            .lineLimit(2)
                    }
                    .help("MCP server \(server.name): \(server.calls) calls")
                }
            }
        }
    }

    /// "Bash ×12 (2 failed)".
    private static func toolText(_ tool: ObservedToolMap.Tool) -> String {
        tool.failures > 0 ? "\(tool.name) ×\(tool.calls) (\(tool.failures) failed)" : "\(tool.name) ×\(tool.calls)"
    }

    // MARK: Advanced (static topology)

    /// The Agentic Radar lens, behind a disclosure that stays closed
    /// until opened: Radar scans agent frameworks (LangGraph, CrewAI…),
    /// not Claude Code or Codex sessions, so it is a specialist's tool,
    /// not a fact every row should carry. When open it shows only a
    /// report imported for this row's repository — never the newest
    /// report of another project. Every edge is labeled "static", never
    /// an observed call; it feeds nothing (T38).
    @ViewBuilder
    private func advancedSection(for entry: CoreRosterEntry) -> some View {
        DisclosureGroup(isExpanded: $advancedExpanded) {
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
                        .help("Import an Agentic Radar JSON report — its edges are listed for the repository it names")
                }
                if let report = store.radarReport(for: entry) {
                    let edges = report.edges
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
                        Text("The report for this repository has no edges.")
                            .font(.system(size: 10)).foregroundStyle(.quaternary)
                    }
                    Text("\(report.repository ?? "report") · \(report.nodes.count) nodes · \(report.edges.count) edges")
                        .font(.system(size: 9)).foregroundStyle(.quaternary)
                } else {
                    Text(store.radarReports.isEmpty
                         ? "No Radar reports imported."
                         : "No imported report names \(store.repositoryName(for: entry) ?? "this repository").")
                        .font(.system(size: 10)).foregroundStyle(.quaternary)
                }
            }
            .padding(.top, 4)
        } label: {
            Text("Advanced")
                .font(.system(size: 10, weight: .semibold)).foregroundStyle(.tertiary)
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

    private static func durationText(_ seconds: Double) -> String {
        if seconds < 90 { return String(format: "%.0fs", seconds) }
        if seconds < 5400 { return String(format: "%.0fm %.0fs", seconds / 60, seconds.truncatingRemainder(dividingBy: 60)) }
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

/// The shared empty-state label set (Replay uses it too; the Usage
/// Center's `UsageEmptyState` is fileprivate there).
struct OverviewEmptyState: View {
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
                if sending { ProgressView().controlSize(.mini) }
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
            await store.answerAsk(entry: entry, approve: true, replyText: reply)
            sending = false
            // The daemon's verdict lands on the store's status line;
            // close only on a delivered answer — a refusal keeps the
            // draft open so the text isn't lost.
            if store.actionIsError == false { dismiss() }
        }
    }
}
