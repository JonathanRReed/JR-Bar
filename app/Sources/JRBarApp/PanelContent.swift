import JRBarCore
import JRBarUI
import SwiftUI
import UniformTypeIdentifiers

/// The panel uses complete usage rows. Extra providers open in Usage Center.
@MainActor
struct PanelComposition {
    static let width: CGFloat = 372
    static let rowHeight: CGFloat = 44
    static let memberHeight: CGFloat = 28
    static let sectionHeight: CGFloat = 28
    static let footerHeight: CGFloat = 44
    let asksHeight: CGFloat
    let askDetailHeight: CGFloat
    let usageLimit: Int
    let agentsHeight: CGFloat
    let totalHeight: CGFloat

    init(store: PanelStore) {
        let agents = store.currentPanelAgents + (store.earlierExpanded ? store.earlierPanelAgents : [])
        let memberCount = agents.filter { store.expandedAgentGroups.contains($0.id) }.reduce(0) { $0 + $1.displayMembers.count }
        let naturalAgents = max(Self.rowHeight, CGFloat(agents.count) * Self.rowHeight + CGFloat(memberCount) * Self.memberHeight)
        var agentHeight = min(naturalAgents, Self.rowHeight * 5)
        let asks = [store.demoRow].compactMap { $0 } + store.visibleAskRows
        var detailHeight = CGFloat(PanelLayout.askDetailHeight)
        var naturalAsks = asks.reduce(CGFloat.zero) { height, row in
            height + CGFloat(PanelLayout.askRowHeight) + (AskExpansion.shared.isShowing(row.ask) ? detailHeight : 0)
        }
        var askHeight = min(naturalAsks, CGFloat(store.screenHeight) * 0.35)
        var minimumAsks = asks.first.map {
            CGFloat(PanelLayout.askRowHeight) + (AskExpansion.shared.isShowing($0.ask) ? detailHeight : 0)
        } ?? 0
        let earlier = store.earlierPanelAgents.isEmpty && store.hiddenCount == 0 ? 0 : Self.sectionHeight
        let banner: CGFloat = store.coreCrashed || !store.isLive || store.providerList.failure != nil ? 70 : 0
        let rows = store.editingProviders ? store.panelEditProviders.count : store.panelUsage.count
        let header: CGFloat = store.editingProviders || !store.panelWindowNames.isEmpty ? 20 : 0
        let live = store.isLive
        let usageHeights = store.panelUsage.map { Self.usageHeight($0, connected: live) }
        let minimumUsage = store.editingProviders ? Self.rowHeight : usageHeights.first ?? Self.rowHeight
        let moreRoom: CGFloat = rows > 1 ? Self.sectionHeight : 0
        let sectionLabels = Self.sectionHeight * 2 + (asks.isEmpty ? 0 : Self.sectionHeight)
        let editHint: CGFloat = store.editingProviders ? 56 : 0
        let chrome = Self.rowHeight + banner + Self.footerHeight + editHint + sectionLabels + earlier + 3
        let minimum = chrome + header + minimumUsage + moreRoom + minimumAsks + Self.rowHeight
        let target = max(CGFloat(store.screenHeight) * 0.85, minimum)
        let cap = min(CGFloat(store.screenHeight) - JRBarTokens.Space.md, target)
        if let first = asks.first, AskExpansion.shared.isShowing(first.ask) {
            let fixed = chrome + header + minimumUsage + moreRoom + Self.rowHeight + CGFloat(PanelLayout.askRowHeight)
            detailHeight = min(detailHeight, max(JRBarTokens.Space.xl, cap - fixed))
            minimumAsks = CGFloat(PanelLayout.askRowHeight) + detailHeight
            naturalAsks = asks.reduce(CGFloat.zero) { height, row in
                height + CGFloat(PanelLayout.askRowHeight) + (AskExpansion.shared.isShowing(row.ask) ? detailHeight : 0)
            }
            askHeight = min(naturalAsks, CGFloat(store.screenHeight) * 0.35)
        }
        askDetailHeight = detailHeight
        var excess = max(0, chrome + header + minimumUsage + moreRoom + askHeight + agentHeight - cap)
        let agentReduction = min(excess, agentHeight - Self.rowHeight)
        agentHeight -= agentReduction
        excess -= agentReduction
        askHeight -= min(excess, askHeight - minimumAsks)
        // A scroll viewport ends after a whole card, including its open detail.
        var wholeAsks: CGFloat = 0
        for row in asks {
            let height = CGFloat(PanelLayout.askRowHeight) + (AskExpansion.shared.isShowing(row.ask) ? detailHeight : 0)
            if wholeAsks + height > askHeight { break }
            wholeAsks += height
        }
        askHeight = asks.isEmpty ? 0 : max(minimumAsks, wholeAsks)
        // The agents viewport also ends after a whole row, so the last
        // worker in view is never cut through its text.
        if naturalAgents > agentHeight {
            let rows = Self.agentRowHeights(store: store, earlier: earlier)
            agentHeight = max(Self.rowHeight, Self.wholeRows(rows, within: agentHeight + earlier) - earlier)
        }
        agentsHeight = agentHeight
        asksHeight = askHeight
        let fixed = chrome + agentHeight + askHeight
        let room = cap - fixed - header - moreRoom
        let candidates = store.editingProviders
            ? Array(repeating: Self.rowHeight, count: rows)
            : usageHeights
        var used: CGFloat = 0
        var capacity = 0
        for height in candidates.prefix(4) {
            if used + height > room { break }
            used += height
            capacity += 1
        }
        capacity = max(1, capacity)
        usageLimit = capacity
        let heights = store.editingProviders
            ? CGFloat(min(rows, capacity)) * Self.rowHeight
            : usageHeights.prefix(capacity).reduce(CGFloat.zero, +)
        let overflow = rows > capacity ? Self.sectionHeight : 0
        totalHeight = fixed + header + max(Self.rowHeight, heights) + overflow
    }

    /// The agents list's rows top to bottom as the scroll view stacks
    /// them: each agent and its open members, the Earlier disclosure, then
    /// the earlier agents while they are shown.
    static func agentRowHeights(store: PanelStore, earlier: CGFloat) -> [CGFloat] {
        func heights(_ agents: [PanelAgent]) -> [CGFloat] {
            agents.flatMap { agent -> [CGFloat] in
                let open = store.expandedAgentGroups.contains(agent.id)
                let members = open ? Array(repeating: memberHeight, count: agent.displayMembers.count) : []
                return [rowHeight] + members
            }
        }
        var rows = heights(store.currentPanelAgents)
        if earlier > 0 { rows.append(earlier) }
        if store.earlierExpanded { rows += heights(store.earlierPanelAgents) }
        return rows
    }

    /// The tallest run of whole rows from the top that fits `height`.
    static func wholeRows(_ rows: [CGFloat], within height: CGFloat) -> CGFloat {
        var used: CGFloat = 0
        for row in rows {
            if used + row > height + 0.5 { break }
            used += row
        }
        return used
    }

    /// A row's height. With the monitor down every reading is stale and its
    /// row adds a "Stale · Read 41m ago" line, so `connected: false` gives
    /// it the stale row's room.
    static func usageHeight(_ usage: CoreProviderUsage, connected: Bool = true) -> CGFloat {
        let additional = UsageGaugeRow.panelAdditionalHeight(usage)
        if usage.availability == "not_found" { return UsageGaugeRow.compactRowHeight }
        let action = usage.action?.isEmpty == false
        // A neutral row with a button (a sign-in) has its status, the age
        // line the monitor's absence adds, and the button on three lines.
        if action, !connected, usage.availability != "failing" { return 96 + additional }
        if action || usage.availability == "failing" { return 88 + additional }
        let stale = !connected || usage.isStale || ["missing_recent", "source_idle"].contains(usage.availability)
        return (stale ? 64 : UsageGaugeRow.compactRowHeight) + additional
    }
}

struct PanelAgentsSection: View {
    @Bindable var store: PanelStore
    let composition: PanelComposition

    private var hasEarlier: Bool { !store.earlierPanelAgents.isEmpty || store.hiddenCount > 0 }

    private var emptyLabel: String {
        if !store.isLive { return "Agents appear when the monitor connects" }
        if !store.trimmedFindQuery.isEmpty { return "No matching agents" }
        if !store.visibleAskRows.isEmpty { return "No other agents running" }
        return store.hooksConnected ? "Start an agent" : "Connect a provider to see its agents"
    }

    var body: some View {
        VStack(spacing: 0) {
            panelSectionTitle("Agents", trailing: store.findSummary)
            ScrollViewReader { proxy in
                SnapshotScrollView {
                    VStack(spacing: 0) {
                        if store.currentPanelAgents.isEmpty && (!store.earlierExpanded || store.earlierPanelAgents.isEmpty) {
                            HStack(spacing: JRBarTokens.Space.sm) {
                                Text(emptyLabel)
                                    .font(JRBarTokens.TypeStyle.body.font).foregroundStyle(JRBarTokens.Ink.secondary)
                                if store.isLive && !store.hooksConnected && store.trimmedFindQuery.isEmpty {
                                    Button("Open Providers…") { store.openSettings(page: .agents) }
                                        .buttonStyle(.plain).font(JRBarTokens.TypeStyle.body.font)
                                        .foregroundStyle(JRBarTokens.Ink.accent)
                                }
                            }
                            .frame(maxWidth: .infinity, minHeight: PanelComposition.rowHeight)
                        }
                        ForEach(store.currentPanelAgents) { agent in PanelAgentView(agent: agent, store: store).id(agent.id) }
                        if hasEarlier { earlierDisclosure.id(PanelStore.earlierSelectionID) }
                        if store.earlierExpanded {
                            ForEach(store.earlierPanelAgents) { agent in PanelAgentView(agent: agent, store: store).id(agent.id) }
                        }
                    }
                }
                .frame(height: composition.agentsHeight + (hasEarlier ? PanelComposition.sectionHeight : 0))
                .onChange(of: store.selectedID) { _, selected in
                    if let selected { proxy.scrollTo(selected, anchor: .center) }
                }
            }
        }
        .animation(store.reduceMotion ? nil : JRBarTokens.Motion.panelEntrance.animation, value: store.earlierExpanded)
    }

    private var earlierDisclosure: some View {
        HStack {
            Button {
                store.earlierExpanded.toggle()
            } label: {
                Label("Earlier · \(store.earlierPanelAgents.count + store.hiddenCount)",
                      systemImage: store.earlierExpanded ? "chevron.down" : "chevron.right")
            }
            .buttonStyle(.plain)
            Spacer()
            if store.earlierExpanded && store.hiddenCount > 0 {
                Button("History…") { store.openHistory() }.buttonStyle(.plain)
            }
        }
        .font(JRBarTokens.TypeStyle.caption.font).foregroundStyle(JRBarTokens.Ink.secondary)
        .padding(.horizontal, JRBarTokens.Space.md).frame(height: PanelComposition.sectionHeight)
        .background(store.selectedID == PanelStore.earlierSelectionID ? JRBarTokens.Ink.accentSoft : .clear)
    }
}

struct PanelAgentView: View {
    let agent: PanelAgent
    @Bindable var store: PanelStore
    @ViewState private var hovering = false
    @ViewState private var contextFrame = CGRect.zero

    private var expanded: Binding<Bool> {
        Binding(get: { store.expandedAgentGroups.contains(agent.id) }, set: { value in
            if value { store.expandedAgentGroups.insert(agent.id) }
            else { store.expandedAgentGroups.remove(agent.id) }
        })
    }

    var body: some View {
        Group {
            if agent.unlinked {
                Button { store.open(agent.row) } label: {
                    AgentGroupRow(provider: agent.row.style.id, name: agent.row.label,
                        workerCount: 0, unlinked: true, expanded: .constant(false)) { EmptyView() }
                }
                .buttonStyle(.plain)
                .contextMenu { SessionContextMenu(row: agent.row, store: store, anchor: contextFrame) }
            } else if !agent.members.isEmpty || agent.workerCount > 0 {
                AgentGroupRow(provider: agent.row.style.id, name: agent.row.label,
                              project: agent.row.distinctFolder, subtitle: groupSubtitle,
                              elapsed: agent.row.elapsedText(now: store.now), state: agent.row.panelState,
                              stateLabel: agent.row.dotLabel,
                              memberMarks: Array(Set(agent.members.map { $0.style.id })).sorted(),
                              workerCount: agent.listedWorkers, askingCount: agent.askingCount, unlinked: agent.unlinked, expanded: expanded) {
                    ForEach(Array(agent.displayMembers.enumerated()), id: \.element.id) { index, member in
                        Button { store.open(member) } label: {
                            AgentMemberRow(provider: member.style.id, name: member.label, role: memberRole(member),
                                           elapsed: member.elapsedText(now: store.now), state: member.panelState,
                                           stateLabel: member.dotLabel, isLast: index == agent.displayMembers.count - 1)
                        }
                        .buttonStyle(.plain)
                        .background(store.selectedID == member.id ? JRBarTokens.Ink.accentSoft : .clear,
                                    in: RoundedRectangle(cornerRadius: JRBarTokens.Radius.control))
                    }
                }
                .contextMenu { SessionContextMenu(row: agent.row, store: store, anchor: contextFrame) }
            } else {
                Button { store.open(agent.row) } label: {
                    HStack(spacing: JRBarTokens.Space.sm) {
                        ProviderLogoTile(provider: agent.row.style.id, accent: agent.row.style.accent, dim: agent.unlinked)
                        VStack(alignment: .leading, spacing: 0) {
                            HStack(spacing: JRBarTokens.Space.xs) {
                                Text(agent.row.label).font(JRBarTokens.TypeStyle.headline.font).lineLimit(1)
                                if agent.row.activity == .done, store.unseenCompletionIDs.contains(agent.row.id) {
                                    UnseenDot().help("Finished since you last looked")
                                }
                            }
                            if agent.unlinked {
                                captionText("No parent found · no share of the strip", warning: false)
                            } else if let caption = rowCaption {
                                captionText(caption.text, warning: caption.warning)
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .overlay(alignment: .bottom) {
                            if let fraction = agent.row.contextBarFraction {
                                ContextHairline(fraction: fraction, accent: agent.row.style.accent).offset(y: 5)
                            }
                        }
                        if !agent.row.activity.isClearable && !agent.row.isRemote {
                            DoneBell(watched: store.isWatchedForDone(agent.row), revealed: hovering || store.selectedID == agent.id) {
                                store.toggleDoneWatch(agent.row)
                            }
                        }
                        if agent.row.activity == .done || agent.row.activity == .failed {
                            Text(agent.row.activity.word).font(JRBarTokens.TypeStyle.caption.font)
                                .foregroundStyle(agent.row.activity == .failed ? JRBarTokens.Ink.failure : JRBarTokens.Ink.done)
                        }
                        if let elapsed = agent.row.elapsedText(now: store.now) {
                            Text(elapsed).font(JRBarTokens.TypeStyle.callout.font).monospacedDigit()
                                .foregroundStyle(agent.row.isQuiet(now: store.now) ? AnyShapeStyle(SessionRow.warningTint)
                                                                                   : AnyShapeStyle(JRBarTokens.Ink.secondary))
                        }
                        StateDot(agent.row.panelState, label: agent.row.dotLabel)
                    }
                    .padding(.horizontal, JRBarTokens.Space.md)
                    .frame(height: PanelComposition.rowHeight)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .opacity(agent.unlinked ? 0.55 : 1)
                .contextMenu { SessionContextMenu(row: agent.row, store: store, anchor: contextFrame) }
            }
        }
        .background(store.selectedID == agent.row.id ? JRBarTokens.Ink.accentSoft : .clear,
                    in: RoundedRectangle(cornerRadius: JRBarTokens.Radius.control))
        .animation(store.reduceMotion ? nil : JRBarTokens.Motion.panelEntrance.animation, value: store.expandedAgentGroups.contains(agent.id))
        .help(agent.row.help(now: store.now) ?? "")
        .onHover { hovering = $0 }
        .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { contextFrame = $0 }
    }

    private var rowCaption: SessionRow.Caption? {
        agent.row.caption(now: store.now, feedQuiet: store.quietFeedText(for: agent.row))
    }

    /// The group's second line: the lead's own caption (its folder is
    /// already beside the title), then the workers' story when the count
    /// alone is not it ("1 working", "1 failed").
    private var groupSubtitle: String? {
        let caption = agent.row.caption(now: store.now, feedQuiet: store.quietFeedText(for: agent.row))
        let lead = caption?.text == agent.row.distinctFolder ? nil : caption?.text
        let parts = [lead, agent.workerSummary].compactMap { $0 }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    /// A worker's role, or what it is doing when there is something to say.
    private func memberRole(_ member: SessionRow) -> String {
        if member.id == agent.id { return "Lead" }
        let caption = member.caption(now: store.now, feedQuiet: store.quietFeedText(for: member))
        guard let caption, caption.text != member.distinctFolder else { return "Worker" }
        return caption.text
    }

    private func captionText(_ text: String, warning: Bool) -> some View {
        Text(text).font(JRBarTokens.TypeStyle.caption.font)
            .foregroundStyle(warning ? AnyShapeStyle(SessionRow.warningTint) : AnyShapeStyle(JRBarTokens.Ink.secondary))
            .lineLimit(1).truncationMode(.tail)
    }
}

struct PanelProviderSection: View {
    @Bindable var store: PanelStore
    let composition: PanelComposition
    @ViewState private var draggedProvider: String?
    @ViewState private var editPage = 0

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: JRBarTokens.Space.sm) {
                SectionHeader("Usage")
                if !store.editingProviders, let updated = store.usageUpdatedText {
                    Text(updated).font(JRBarTokens.TypeStyle.caption.font).foregroundStyle(JRBarTokens.Ink.tertiary)
                        .lineLimit(1).monospacedDigit()
                }
                Spacer()
                if !store.editingProviders && store.isLive {
                    Button { store.refreshAllUsage() } label: {
                        Image(systemName: "arrow.clockwise").font(JRBarTokens.TypeStyle.caption.font)
                    }
                    .buttonStyle(.plain).foregroundStyle(JRBarTokens.Ink.secondary)
                    .keyboardShortcut("r", modifiers: .command)
                    .help("Refresh usage (⌘R)").accessibilityLabel("Refresh usage")
                }
                Button(store.editingProviders ? "Done" : "Edit") { store.editingProviders.toggle(); editPage = 0 }
                    .buttonStyle(.plain).font(JRBarTokens.TypeStyle.caption.font)
            }
            .padding(.horizontal, JRBarTokens.Space.md).frame(height: PanelComposition.sectionHeight)
            if store.editingProviders { editor }
            else {
                if !store.panelWindowNames.isEmpty {
                    UsageGaugeHeader(windowNames: store.panelWindowNames).frame(height: 20)
                }
                if store.panelUsage.isEmpty {
                    Button("Add providers…") { store.openSettings(page: .agents) }
                        .buttonStyle(.plain).font(JRBarTokens.TypeStyle.body.font)
                        .frame(height: PanelComposition.rowHeight)
                }
                ForEach(Array(store.panelUsage.prefix(composition.usageLimit)), id: \.identity) { usage in
                    gauge(usage)
                        .frame(height: PanelComposition.usageHeight(usage, connected: store.isLive))
                }
                let more = store.panelUsage.count - composition.usageLimit
                if more > 0 {
                    Button("+\(more) more") { store.openUsageCenter() }
                        .buttonStyle(.plain).font(JRBarTokens.TypeStyle.caption.font)
                        .frame(maxWidth: .infinity, minHeight: PanelComposition.sectionHeight)
                }
            }
        }
    }

    func gauge(_ usage: CoreProviderUsage) -> UsageGaugeRow {
        let style = ProviderStyle.style(for: usage.id, document: store.settingsDocument)
        let retry: (() -> Void)? = usage.availability == "failing" && !(["Retry", "Retry later"].contains(usage.action ?? ""))
            ? { store.retryPanelUsage(usage) } : nil
        let name = usage.instanceLabel ?? ProviderPalette.displayName(for: usage.id)
        return UsageGaugeRow(provider: usage, name: name, now: store.now.timeIntervalSince1970,
                             connected: store.isLive, accent: style.accent, style: .panel,
                             windowNames: store.panelWindowNames, snapshotReceivedAt: store.usageSnapshotReceivedAt, suppressDisconnectedStatus: true,
                             forecasts: Dictionary(usage.windows.map { window in
                                 (window.id, UsageCenterStore.forecast(for: usage, window: window, core: store.core, now: store.now))
                             }, uniquingKeysWith: { first, _ in first }),
                             onOpen: { store.openUsageCenter(provider: usage.identity) },
                             onAction: { store.panelUsageAction(usage) }, onRetry: retry)
    }

    private var editor: some View {
        VStack(spacing: 0) {
            HStack {
                Spacer()
                Text("Menu bar").frame(width: 58)
                Text("Panel").frame(width: 48)
            }
            .font(JRBarTokens.TypeStyle.caption.font).foregroundStyle(JRBarTokens.Ink.secondary)
            .padding(.horizontal, JRBarTokens.Space.md).frame(height: 20)
            let providers = store.panelEditProviders
            let start = min(editPage * composition.usageLimit, max(0, providers.count - 1))
            ForEach(Array(providers.dropFirst(start).prefix(composition.usageLimit)), id: \.identity) { row in
                let name = row.label == row.id ? ProviderPalette.displayName(for: row.id) : row.label
                HStack(spacing: JRBarTokens.Space.sm) {
                    Image(systemName: "line.3.horizontal").foregroundStyle(JRBarTokens.Ink.tertiary)
                        .onDrag { draggedProvider = row.id; return NSItemProvider(object: row.id as NSString) }
                        .accessibilityLabel("Reorder \(name)")
                    ProviderLogoTile(provider: row.id, dim: !row.enabled)
                    VStack(alignment: .leading, spacing: 0) {
                        Text(name).font(JRBarTokens.TypeStyle.headline.font).lineLimit(1)
                        if !row.enabled {
                            Text("Track is off in Settings › Providers").font(JRBarTokens.TypeStyle.caption.font)
                                .foregroundStyle(JRBarTokens.Ink.secondary).lineLimit(2)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    Spacer(minLength: 0)
                    eye(store.providerList.showsInMenuBar(row.id), label: "\(name) in menu bar", width: 58) {
                        try? await store.providerList.setMenuBarVisible(row.id, !store.providerList.showsInMenuBar(row.id))
                    }
                    eye(store.providerList.showsInPanel(row), label: "\(name) in panel", width: 48) {
                        try? await store.providerList.setPanelVisible(row, !store.providerList.showsInPanel(row))
                    }
                }
                .padding(.horizontal, JRBarTokens.Space.md).frame(height: PanelComposition.rowHeight)
                .disabled(!row.enabled || store.providerList.busy.contains(row.identity) || store.providerList.writingPresentation)
                .onDrop(of: [UTType.text], isTargeted: nil) { _ in
                    guard let source = draggedProvider else { return false }
                    draggedProvider = nil
                    Task { await store.movePanelProvider(source, before: row.id) }
                    return true
                }
                .contextMenu {
                    Button("Move up") { _ = Task { await store.shiftPanelProvider(row, by: -1) } }
                    Button("Move down") { _ = Task { await store.shiftPanelProvider(row, by: 1) } }
                }
                .accessibilityAction(named: "Move up") { _ = Task { await store.shiftPanelProvider(row, by: -1) } }
                .accessibilityAction(named: "Move down") { _ = Task { await store.shiftPanelProvider(row, by: 1) } }
            }
            if providers.isEmpty {
                Button("Add providers…") { store.openSettings(page: .agents) }
                    .frame(height: PanelComposition.rowHeight)
            }
            Text("Drag to change the order everywhere. To stop collecting, turn off Track in Settings › Providers.")
                .font(JRBarTokens.TypeStyle.caption.font).foregroundStyle(JRBarTokens.Ink.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, JRBarTokens.Space.md).frame(height: 56)
            if providers.count > composition.usageLimit {
                Button(start + composition.usageLimit < providers.count ? "+\(providers.count - start - composition.usageLimit) more" : "Back to first") {
                    editPage = start + composition.usageLimit < providers.count ? editPage + 1 : 0
                }
                .buttonStyle(.plain).font(JRBarTokens.TypeStyle.caption.font)
                .frame(height: PanelComposition.sectionHeight)
            }
        }
    }

    private func eye(_ visible: Bool, label: String, width: CGFloat, action: @escaping @MainActor () async -> Void) -> some View {
        Button { _ = Task { await action() } } label: {
            Image(systemName: visible ? "eye" : "eye.slash").foregroundStyle(visible ? JRBarTokens.Ink.accent : JRBarTokens.Ink.tertiary)
                .frame(width: width)
        }
        .buttonStyle(.plain).accessibilityLabel(label).accessibilityValue(visible ? "Shown" : "Hidden")
    }
}

struct PanelActionsFooter: View {
    @Bindable var store: PanelStore
    @ViewState private var devicesShown = false

    var body: some View {
        ViewThatFits(in: .horizontal) {
            controls(compactUsage: false)
            controls(compactUsage: true)
        }
        .font(JRBarTokens.TypeStyle.callout.font)
        .foregroundStyle(JRBarTokens.Ink.label)
        .buttonStyle(PanelFooterButtonStyle())
        .controlSize(.small)
        .frame(height: PanelComposition.footerHeight)
        .padding(.horizontal, JRBarTokens.Space.md)
    }

    private func controls(compactUsage: Bool) -> some View {
        HStack(spacing: JRBarTokens.Space.xs) {
            Button("Studio") { store.openEffects() }
                .fixedSize().help(studioHelp)
            Button { store.openUsageCenter() } label: {
                if compactUsage { Image(systemName: "chart.bar") }
                else { Text("Usage Center") }
            }
            .fixedSize().help("Usage Center (⌘U)").accessibilityLabel("Usage Center")
            Spacer(minLength: JRBarTokens.Space.xs)
            HStack(spacing: JRBarTokens.Space.xs) {
                Menu {
                    Button("30 minutes") { store.quietFor(seconds: 30 * 60) }
                    Button("1 hour") { store.quietFor(seconds: 60 * 60) }
                    Button("4 hours") { store.quietFor(seconds: 4 * 60 * 60) }
                    Button(PanelStore.morningLabel(verb: "Until", target: store.morningTarget)) {
                        store.quietFor(seconds: PanelStore.secondsUntilMorning(from: store.now))
                    }
                    Menu("Mode") {
                        ForEach(PanelStore.quietModes, id: \.id) { mode in
                            Toggle(mode.label, isOn: Binding(
                                get: { store.quietMode == mode.id },
                                set: { if $0 { store.quietMode = mode.id } }
                            ))
                        }
                    }
                    if store.quietIsOurs { Button("End quiet") { store.endQuiet() } }
                } label: {
                    Image(systemName: store.quiet == nil ? "moon" : "moon.fill")
                        .foregroundStyle(store.quiet == nil ? JRBarTokens.Ink.label : Color.accentColor)
                }
                .menuStyle(.button).menuIndicator(.hidden)
                .help(store.quietLabel.map { "Quiet: \($0)" } ?? "Quiet")
                .accessibilityLabel("Quiet").accessibilityValue(store.quietLabel ?? "Off")
                if let countdown = store.undoCountdown {
                    Button("Undo \(countdown)") { store.undoClear() }
                        .monospacedDigit().fixedSize()
                        .keyboardShortcut("z", modifiers: .command)
                        .help("Undo clear (⌘Z)").accessibilityLabel("Undo clear, \(countdown) remaining")
                } else {
                    Button { store.clearCompleted() } label: { Image(systemName: "checkmark.circle") }
                        .help("Clear finished").accessibilityLabel("Clear finished")
                        .disabled(store.completedCount == 0)
                }
                Button { devicesShown.toggle() } label: { Image(systemName: "slider.horizontal.3") }
                    .help("Devices").accessibilityLabel("Devices")
                    .popover(isPresented: WindowPresenter.presentation($devicesShown)) {
                        PanelDevicesRow(store: store)
                            .frame(width: PanelComposition.width - JRBarTokens.Space.xl)
                            .padding(.vertical, JRBarTokens.Space.sm)
                    }
                Button { store.openSettings() } label: { Image(systemName: "gearshape") }
                    .help("Settings… (⌘,)").accessibilityLabel("Settings")
                Menu { PanelMoreMenuItems(store: store) } label: { Image(systemName: "ellipsis") }
                    .menuStyle(.button).menuIndicator(.hidden).help("More…").accessibilityLabel("More")
            }
            .fixedSize()
        }
    }

    private var studioHelp: String {
        guard UserDefaults.standard.object(forKey: SettingsStore.studioHotkeyDefaultsKey) as? Bool ?? true,
              let chord = HotkeyChordDefaults.chord(for: PanelHotkey.studioID, fallback: PanelHotkey.studioDefault)
        else { return "Studio" }
        return "Studio (\(chord.displayString))"
    }
}

struct PanelTitleBar: View {
    @Bindable var store: PanelStore
    var body: some View {
        HStack(spacing: JRBarTokens.Space.sm) {
            VStack(alignment: .leading, spacing: 0) {
                Text("JR-Bar").font(JRBarTokens.TypeStyle.headline.font)
                Text(store.headerCounts).font(JRBarTokens.TypeStyle.callout.font)
                    .foregroundStyle(JRBarTokens.Ink.secondary).lineLimit(1)
            }
            Spacer(minLength: 0)
            if let hold = store.awakeHold {
                Button { store.openKeepAwakeSettings() } label: {
                    AwakeMark(symbol: hold.symbol, steam: store.awakeSteam, ink: JRBarTokens.Ink.label)
                        .font(JRBarTokens.TypeStyle.caption.font)
                }
                .buttonStyle(.plain).help(hold.text).accessibilityLabel(hold.text)
                .contextMenu { KeepAwakeMenuItems() }
            }
            if let quiet = store.quietLabel {
                Image(systemName: "moon.zzz.fill").font(JRBarTokens.TypeStyle.caption.font)
                    .foregroundStyle(JRBarTokens.Ink.secondary).help(quiet).accessibilityLabel("Quiet: \(quiet)")
            }
            ConnectionDot(state: store.connectionDot, reduced: store.reduceMotion, active: store.marksMove)
                .help(store.connectionDescription)
        }
        .padding(.horizontal, JRBarTokens.Space.md).frame(height: PanelComposition.rowHeight)
    }
}

private struct PanelFooterButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled
    @ViewState private var hovering = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .padding(.horizontal, JRBarTokens.Space.xs)
            .frame(minWidth: JRBarTokens.Space.xxl, minHeight: JRBarTokens.Space.xxl)
            .background {
                RoundedRectangle(cornerRadius: JRBarTokens.Radius.control)
                    .fill(isEnabled && (hovering || configuration.isPressed) ? JRBarTokens.Ink.hover : .clear)
            }
            .contentShape(RoundedRectangle(cornerRadius: JRBarTokens.Radius.control))
            .opacity(isEnabled ? 1 : 0.4)
            .onHover { hovering = $0 }
    }
}

@MainActor
func panelSectionTitle(_ title: String, trailing: String? = nil) -> some View {
    HStack {
        SectionHeader(title)
        Spacer()
        if let trailing {
            Text(trailing).font(JRBarTokens.TypeStyle.caption.font).foregroundStyle(JRBarTokens.Ink.secondary).lineLimit(1)
        }
    }.padding(.horizontal, JRBarTokens.Space.md).frame(height: PanelComposition.sectionHeight)
}

/// The awake hold's glyph: the cup steams while it holds, and only the
/// steam thins as a countdown runs out. Any other mark (the battery, the
/// closed lid) is drawn as it is.
struct AwakeMark<Ink: ShapeStyle>: View {
    let symbol: String
    let steam: KeepAwakeSteam
    let ink: Ink

    var body: some View {
        if symbol == KeepAwakeSteam.none.symbol, steam != .none {
            Image(systemName: steam.symbol)
                .symbolRenderingMode(.palette)
                .foregroundStyle(ink, ink.opacity(steam.opacity))
        } else {
            Image(systemName: symbol).foregroundStyle(ink)
        }
    }
}
