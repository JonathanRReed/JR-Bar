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
    let usageLimit: Int
    let agentsHeight: CGFloat
    let totalHeight: CGFloat

    init(store: PanelStore) {
        let agents = store.currentPanelAgents + (store.earlierExpanded ? store.earlierPanelAgents : [])
        let memberCount = agents.filter { store.expandedAgentGroups.contains($0.id) }.reduce(0) { $0 + $1.members.count }
        let naturalAgents = max(Self.rowHeight, CGFloat(agents.count) * Self.rowHeight + CGFloat(memberCount) * Self.memberHeight)
        agentsHeight = min(naturalAgents, Self.rowHeight * 5)
        let asks = store.visibleAskRows + [store.demoRow].compactMap { $0 }
        let naturalAsksHeight = asks.reduce(CGFloat.zero) { height, row in
            height + CGFloat(PanelLayout.askRowHeight) + (AskExpansion.shared.isShowing(row.ask) ? CGFloat(PanelLayout.askDetailHeight) : 0)
        }
        asksHeight = min(naturalAsksHeight, max(CGFloat(PanelLayout.askRowHeight), CGFloat(store.screenHeight) * 0.35))
        let earlier = store.earlierPanelAgents.isEmpty && store.hiddenCount == 0 ? 0 : Self.sectionHeight
        let banner: CGFloat = store.coreCrashed || !store.isLive || store.providerList.failure != nil ? 70 : 0
        let askSection = asksHeight + (asks.isEmpty ? 0 : Self.sectionHeight)
        let agentSection = Self.sectionHeight + agentsHeight + earlier
        let chrome = Self.rowHeight + banner + Self.footerHeight + 4
        let fixed = chrome + askSection + agentSection + Self.sectionHeight
        let rows = store.editingProviders ? store.panelEditProviders.count : store.panelUsage.count
        let header: CGFloat = store.editingProviders || !store.panelWindowNames.isEmpty ? 20 : 0
        let capacity = max(1, min(4, Int((CGFloat(store.screenHeight) * 0.85 - fixed - header - Self.sectionHeight) / 90)))
        usageLimit = capacity
        let heights = store.editingProviders
            ? CGFloat(min(rows, capacity)) * Self.rowHeight
            : store.panelUsage.prefix(capacity).reduce(CGFloat.zero) { $0 + Self.usageHeight($1) }
        let overflow = rows > capacity ? Self.sectionHeight : 0
        totalHeight = fixed + header + max(Self.rowHeight, heights) + overflow
    }

    static func usageHeight(_ usage: CoreProviderUsage) -> CGFloat {
        if usage.availability == "not_found" { return rowHeight }
        let action = usage.action?.isEmpty == false
        return action || usage.availability == "failing" ? 90 : 62
    }
}

struct PanelAgentsSection: View {
    @Bindable var store: PanelStore
    let composition: PanelComposition

    private var hasEarlier: Bool { !store.earlierPanelAgents.isEmpty || store.hiddenCount > 0 }

    var body: some View {
        VStack(spacing: 0) {
            panelSectionTitle("Agents")
            SnapshotScrollView {
                VStack(spacing: 0) {
                    if store.currentPanelAgents.isEmpty && (!store.earlierExpanded || store.earlierPanelAgents.isEmpty) {
                        Text(store.findQuery.isEmpty ? "No agents to show" : "No matching agents")
                            .font(JRBarTokens.TypeStyle.body.font).foregroundStyle(JRBarTokens.Ink.secondary)
                            .frame(maxWidth: .infinity, minHeight: PanelComposition.rowHeight)
                    }
                    ForEach(store.currentPanelAgents) { agent in PanelAgentView(agent: agent, store: store) }
                    if hasEarlier { earlierDisclosure }
                    if store.earlierExpanded {
                        ForEach(store.earlierPanelAgents) { agent in PanelAgentView(agent: agent, store: store) }
                    }
                }
            }
            .frame(height: composition.agentsHeight + (hasEarlier ? PanelComposition.sectionHeight : 0))
        }
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
    }
}

struct PanelAgentView: View {
    let agent: PanelAgent
    @Bindable var store: PanelStore

    private var expanded: Binding<Bool> {
        Binding(get: { store.expandedAgentGroups.contains(agent.id) }, set: { value in
            if value { store.expandedAgentGroups.insert(agent.id) }
            else { store.expandedAgentGroups.remove(agent.id) }
        })
    }

    var body: some View {
        Group {
            if agent.workerCount > 0 || agent.unlinked {
                AgentGroupRow(provider: agent.row.style.id, name: agent.row.style.name,
                              project: agent.row.cwdTail, subtitle: agent.row.label,
                              elapsed: agent.row.elapsedText(now: store.now), state: agent.row.panelState,
                              memberMarks: Array(Set(agent.members.map { $0.style.id })).sorted(),
                              workerCount: agent.workerCount, unlinked: agent.unlinked, expanded: expanded) {
                    ForEach(Array(agent.members.enumerated()), id: \.element.id) { index, member in
                        Button { store.open(member) } label: {
                            AgentMemberRow(provider: member.style.id, name: member.label,
                                           elapsed: member.elapsedText(now: store.now), state: member.panelState,
                                           isLast: index == agent.members.count - 1)
                        }
                        .buttonStyle(.plain)
                        .background(store.selectedID == member.id ? JRBarTokens.Ink.accentSoft : .clear,
                                    in: RoundedRectangle(cornerRadius: JRBarTokens.Radius.control))
                    }
                }
                .contextMenu { SessionContextMenu(row: agent.row, store: store) }
            } else {
                Button { store.open(agent.row) } label: {
                    HStack(spacing: JRBarTokens.Space.sm) {
                        ProviderLogoTile(provider: agent.row.style.id, accent: agent.row.style.accent)
                        VStack(alignment: .leading, spacing: 0) {
                            Text(agent.row.label).font(JRBarTokens.TypeStyle.headline.font).lineLimit(1)
                            if let folder = agent.row.cwdTail {
                                Text(folder).font(JRBarTokens.TypeStyle.caption.font).foregroundStyle(JRBarTokens.Ink.secondary).lineLimit(1)
                            }
                        }
                        Spacer(minLength: 0)
                        if agent.row.activity == .done || agent.row.activity == .failed {
                            Text(agent.row.activity.word).font(JRBarTokens.TypeStyle.caption.font)
                                .foregroundStyle(agent.row.activity == .failed ? JRBarTokens.Ink.failure : JRBarTokens.Ink.done)
                        }
                        if let elapsed = agent.row.elapsedText(now: store.now) {
                            Text(elapsed).font(JRBarTokens.TypeStyle.callout.font).foregroundStyle(JRBarTokens.Ink.secondary).monospacedDigit()
                        }
                        StateDot(agent.row.panelState)
                    }
                    .padding(.horizontal, JRBarTokens.Space.md)
                    .frame(height: PanelComposition.rowHeight)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .contextMenu { SessionContextMenu(row: agent.row, store: store) }
            }
        }
        .background(store.selectedID == agent.row.id ? JRBarTokens.Ink.accentSoft : .clear,
                    in: RoundedRectangle(cornerRadius: JRBarTokens.Radius.control))
        .help(agent.row.help(now: store.now) ?? "")
    }
}

struct PanelProviderSection: View {
    @Bindable var store: PanelStore
    let composition: PanelComposition
    @ViewState private var draggedProvider: String?
    @ViewState private var editPage = 0

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Usage").font(JRBarTokens.TypeStyle.section.font).foregroundStyle(JRBarTokens.Ink.secondary)
                Spacer()
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
                ForEach(Array(store.panelUsage.prefix(composition.usageLimit).enumerated()), id: \.offset) { _, usage in
                    gauge(usage)
                        .frame(height: PanelComposition.usageHeight(usage))
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

    private func gauge(_ usage: CoreProviderUsage) -> some View {
        let style = ProviderStyle.style(for: usage.id, document: store.settingsDocument)
        let retry: (() -> Void)? = usage.availability == "failing" && usage.action != "Retry"
            ? { store.retryPanelUsage(usage) } : nil
        let name = usage.instanceLabel ?? ProviderPalette.displayName(for: usage.id)
        return UsageGaugeRow(provider: usage, name: name, now: store.now.timeIntervalSince1970,
                             connected: store.isLive, accent: style.accent, style: .compact,
                             windowNames: store.panelWindowNames, snapshotReceivedAt: store.usageSnapshotReceivedAt,
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
                HStack(spacing: JRBarTokens.Space.sm) {
                    Image(systemName: "line.3.horizontal").foregroundStyle(JRBarTokens.Ink.tertiary)
                        .onDrag { draggedProvider = row.id; return NSItemProvider(object: row.id as NSString) }
                        .accessibilityLabel("Reorder \(row.label)")
                    ProviderLogoTile(provider: row.id, dim: !row.enabled)
                    Text(ProviderPalette.displayName(for: row.id)).font(JRBarTokens.TypeStyle.headline.font).lineLimit(1)
                    Spacer(minLength: 0)
                    eye(store.providerList.showsInMenuBar(row.id), label: "\(row.label) in menu bar", width: 58) {
                        try? await store.providerList.setMenuBarVisible(row.id, !store.providerList.showsInMenuBar(row.id))
                    }
                    eye(store.providerList.showsInPanel(row), label: "\(row.label) in panel", width: 48) {
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
                    Button("Move up") {
                        guard let index = providers.firstIndex(where: { $0.identity == row.identity }), index > 0 else { return }
                        Task { await store.movePanelProvider(row.id, before: providers[index - 1].id) }
                    }
                }
            }
            if providers.isEmpty {
                Button("Add providers…") { store.openSettings(page: .agents) }
                    .frame(height: PanelComposition.rowHeight)
            }
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
            Image(systemName: visible ? "eye" : "eye.slash").foregroundStyle(visible ? JRBarTokens.Ink.label : JRBarTokens.Ink.tertiary)
                .frame(width: width)
        }
        .buttonStyle(.plain).accessibilityLabel(label).accessibilityValue(visible ? "Shown" : "Hidden")
    }
}

struct PanelActionsFooter: View {
    @Bindable var store: PanelStore
    var body: some View {
        HStack(spacing: JRBarTokens.Space.sm) {
            Button { store.openEffects() } label: {
                Text("Studio").frame(height: JRBarTokens.Space.lg)
            }.help("Studio (⌥⌘L)")
            Button { store.openUsageCenter() } label: {
                Text("Usage Center").frame(height: JRBarTokens.Space.lg)
            }.help("Usage Center (⌘U)")
            Spacer(minLength: 0)
            Button { store.openSettings() } label: {
                Image(systemName: "gearshape").frame(width: JRBarTokens.Space.lg, height: JRBarTokens.Space.lg)
            }
                .help("Settings… (⌘,)").accessibilityLabel("Settings")
            Menu {
                Button("Clear finished") { store.clearCompleted() }.disabled(store.completedCount == 0)
                if store.undoCountdown != nil { Button("Undo clear") { store.undoClear() } }
                Divider()
                Menu("Quiet…") {
                    Button("30 minutes") { store.quietFor(seconds: 30 * 60) }
                    Button("1 hour") { store.quietFor(seconds: 60 * 60) }
                    if store.quietIsOurs { Button("End quiet") { store.endQuiet() } }
                }
                Divider()
                PanelMoreMenuItems(store: store)
            } label: {
                Image(systemName: "ellipsis").frame(width: JRBarTokens.Space.lg, height: JRBarTokens.Space.lg)
            }
            .menuStyle(.button)
            .menuIndicator(.hidden).help("More…").accessibilityLabel("More")
        }
        .buttonStyle(.bordered).controlSize(.small).font(JRBarTokens.TypeStyle.callout.font)
        .padding(.horizontal, JRBarTokens.Space.md).frame(height: PanelComposition.footerHeight)
    }
}

@MainActor
func panelSectionTitle(_ title: String) -> some View {
    HStack {
        Text(title).font(JRBarTokens.TypeStyle.section.font).foregroundStyle(JRBarTokens.Ink.secondary)
        Spacer()
    }.padding(.horizontal, JRBarTokens.Space.md).frame(height: PanelComposition.sectionHeight)
}
