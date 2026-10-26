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
        let minimumUsage = store.editingProviders ? Self.rowHeight : store.panelUsage.first.map(Self.usageHeight) ?? Self.rowHeight
        let moreRoom: CGFloat = rows > 1 ? Self.sectionHeight : 0
        let sectionLabels = Self.sectionHeight * 2 + (asks.isEmpty ? 0 : Self.sectionHeight)
        let editHint: CGFloat = store.editingProviders ? 56 : 0
        let undoHeight = store.undoCountdown == nil ? 0 : Self.sectionHeight
        let chrome = Self.rowHeight + banner + Self.footerHeight + undoHeight + editHint + sectionLabels + earlier + 3
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
        agentsHeight = agentHeight
        asksHeight = askHeight
        let fixed = chrome + agentHeight + askHeight
        let room = cap - fixed - header - moreRoom
        let candidates = store.editingProviders
            ? Array(repeating: Self.rowHeight, count: rows)
            : store.panelUsage.map(Self.usageHeight)
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
            : store.panelUsage.prefix(capacity).reduce(CGFloat.zero) { $0 + Self.usageHeight($1) }
        let overflow = rows > capacity ? Self.sectionHeight : 0
        totalHeight = fixed + header + max(Self.rowHeight, heights) + overflow
    }

    static func usageHeight(_ usage: CoreProviderUsage) -> CGFloat {
        if usage.availability == "not_found" { return rowHeight }
        let action = usage.action?.isEmpty == false
        return action || usage.availability == "failing" ? 72 : (usage.isStale || ["missing_recent", "source_idle"].contains(usage.availability) ? 58 : 44)
    }
}

struct PanelAgentsSection: View {
    @Bindable var store: PanelStore
    let composition: PanelComposition

    private var hasEarlier: Bool { !store.earlierPanelAgents.isEmpty || store.hiddenCount > 0 }

    var body: some View {
        VStack(spacing: 0) {
            panelSectionTitle("Agents", trailing: store.findSummary)
            ScrollViewReader { proxy in
                SnapshotScrollView {
                    VStack(spacing: 0) {
                        if store.currentPanelAgents.isEmpty && (!store.earlierExpanded || store.earlierPanelAgents.isEmpty) {
                            Text(!store.isLive ? "Agents appear when the monitor connects" : (store.trimmedFindQuery.isEmpty ? "No agents to show" : "No matching agents"))
                                .font(JRBarTokens.TypeStyle.body.font).foregroundStyle(JRBarTokens.Ink.secondary)
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
                    AgentGroupRow(provider: agent.row.style.id, name: agent.row.style.name,
                        workerCount: 0, unlinked: true, expanded: .constant(false)) { EmptyView() }
                }
                .buttonStyle(.plain)
                .contextMenu { SessionContextMenu(row: agent.row, store: store) }
            } else if !agent.members.isEmpty || agent.workerCount > 0 {
                AgentGroupRow(provider: agent.row.style.id, name: agent.row.style.name,
                              project: agent.row.cwdTail, subtitle: agent.row.label,
                              elapsed: agent.row.elapsedText(now: store.now), state: agent.row.panelState,
                              memberMarks: Array(Set(agent.members.map { $0.style.id })).sorted(),
                              workerCount: agent.workerCount, askingCount: agent.askingCount, unlinked: agent.unlinked, expanded: expanded) {
                    ForEach(Array(agent.displayMembers.enumerated()), id: \.element.id) { index, member in
                        Button { store.open(member) } label: {
                            AgentMemberRow(provider: member.style.id, name: member.label, role: member.id == agent.id ? "Lead" : "Worker",
                                           elapsed: member.elapsedText(now: store.now), state: member.panelState,
                                           isLast: index == agent.displayMembers.count - 1)
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
                        ProviderLogoTile(provider: agent.row.style.id, accent: agent.row.style.accent, dim: agent.unlinked)
                        VStack(alignment: .leading, spacing: 0) {
                            Text(agent.unlinked ? "\(agent.row.style.name) · Unlinked worker" : "\(agent.row.style.name) · \(agent.row.label)").font(JRBarTokens.TypeStyle.headline.font).lineLimit(1)
                            if let folder = agent.unlinked ? "No parent found · no share of the strip" : agent.row.cwdTail {
                                Text(folder).font(JRBarTokens.TypeStyle.caption.font).foregroundStyle(JRBarTokens.Ink.secondary).lineLimit(1)
                            }
                        }
                        Spacer(minLength: 0)
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
                            Text(elapsed).font(JRBarTokens.TypeStyle.callout.font).foregroundStyle(JRBarTokens.Ink.secondary).monospacedDigit()
                        }
                        StateDot(agent.row.panelState)
                    }
                    .padding(.horizontal, JRBarTokens.Space.md)
                    .frame(height: PanelComposition.rowHeight)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .opacity(agent.unlinked ? 0.55 : 1)
                .contextMenu { SessionContextMenu(row: agent.row, store: store) }
            }
        }
        .background(store.selectedID == agent.row.id ? JRBarTokens.Ink.accentSoft : .clear,
                    in: RoundedRectangle(cornerRadius: JRBarTokens.Radius.control))
        .animation(store.reduceMotion ? nil : JRBarTokens.Motion.panelEntrance.animation, value: store.expandedAgentGroups.contains(agent.id))
        .help(agent.row.help(now: store.now) ?? "")
        .onHover { hovering = $0 }
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
                ForEach(Array(store.panelUsage.prefix(composition.usageLimit)), id: \.identity) { usage in
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
        let retry: (() -> Void)? = usage.availability == "failing" && !(["Retry", "Retry later"].contains(usage.action ?? ""))
            ? { store.retryPanelUsage(usage) } : nil
        let name = usage.instanceLabel ?? ProviderPalette.displayName(for: usage.id)
        return UsageGaugeRow(provider: usage, name: name, now: store.now.timeIntervalSince1970,
                             connected: store.isLive, accent: style.accent, style: .compact,
                             windowNames: store.panelWindowNames, snapshotReceivedAt: store.usageSnapshotReceivedAt, suppressDisconnectedStatus: true,
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
                    VStack(alignment: .leading, spacing: 0) {
                        Text(row.label).font(JRBarTokens.TypeStyle.headline.font).lineLimit(1)
                        if !row.enabled {
                            Text("Track is off in Settings › Providers").font(JRBarTokens.TypeStyle.caption.font)
                                .foregroundStyle(JRBarTokens.Ink.secondary).lineLimit(2)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
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
        VStack(spacing: 0) {
            HStack(spacing: JRBarTokens.Space.sm) {
                Button { store.openEffects() } label: {
                    HStack(spacing: JRBarTokens.Space.sm) {
                        Text("Studio")
                        PanelStudioMirror(store: store)
                    }
                }
                .help(studioHelp)
                .contextMenu {
                    Button("Why this light") { store.whyHover(true, frame: store.whyRowFrame) }
                        .disabled(store.lightExplanation == nil)
                }
                Button("Usage Center") { store.openUsageCenter() }.help("Usage Center (⌘U)")
                Spacer(minLength: 0)
                Button { devicesShown.toggle() } label: { Image(systemName: "slider.horizontal.3") }
                    .help("Devices").accessibilityLabel("Devices")
                    .popover(isPresented: WindowPresenter.presentation($devicesShown)) {
                        PanelDevicesRow(store: store)
                            .frame(width: PanelComposition.width - JRBarTokens.Space.xl)
                            .padding(.vertical, JRBarTokens.Space.sm)
                    }
                Button { store.openSettings() } label: { Image(systemName: "gearshape") }
                    .help("Settings… (⌘,)").accessibilityLabel("Settings")
                Menu {
                    Button("Clear finished") { store.clearCompleted() }.disabled(store.completedCount == 0)
                    Divider()
                    Menu("Quiet…") {
                        Button("30 minutes") { store.quietFor(seconds: 30 * 60) }
                        Button("1 hour") { store.quietFor(seconds: 60 * 60) }
                        if store.quietIsOurs { Button("End quiet") { store.endQuiet() } }
                    }
                    Divider()
                    PanelMoreMenuItems(store: store)
                } label: { Image(systemName: "ellipsis") }
                .menuStyle(.button).menuIndicator(.hidden).help("More…").accessibilityLabel("More")
            }
            .buttonStyle(.plain).controlSize(.small)
            .frame(height: PanelComposition.footerHeight)
            if let countdown = store.undoCountdown {
                Button("Undo \(countdown)") { store.undoClear() }
                    .buttonStyle(.plain).help("Undo clear (⌘Z)")
                    .frame(maxWidth: .infinity, minHeight: PanelComposition.sectionHeight, alignment: .trailing)
            }
        }
        .font(JRBarTokens.TypeStyle.callout.font)
        .padding(.horizontal, JRBarTokens.Space.md)
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
                Text("Agents").font(JRBarTokens.TypeStyle.headline.font)
                Text(store.headerCounts).font(JRBarTokens.TypeStyle.callout.font)
                    .foregroundStyle(JRBarTokens.Ink.secondary).lineLimit(1)
            }
            Spacer(minLength: 0)
            if let hold = store.awakeHold {
                Button { store.openKeepAwakeSettings() } label: {
                    Image(systemName: hold.symbol).font(JRBarTokens.TypeStyle.caption.font)
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

struct PanelStudioMirror: View {
    @Bindable var store: PanelStore
    var body: some View {
        Group {
            if let surface = store.core.lights?.hardware ?? store.core.lights?.screenBar, !surface.program.isEmpty {
                LEDStripPreview(program: surface.program, ledCount: surface.ledCount ?? 8, dotSize: 4, spacing: 2,
                                paused: !store.isOpen || !store.isLive || store.reduceMotion,
                                showsBackground: false, phase: max(0, store.now.timeIntervalSince1970 - (surface.anchor ?? store.now.timeIntervalSince1970)), displayLEDCount: 8)
            } else {
                HStack(spacing: 2) {
                    ForEach(0..<8) { _ in Circle().fill(JRBarTokens.Ink.tertiary).frame(width: 4, height: 4) }
                }
            }
        }
        .frame(width: 48, height: JRBarTokens.Space.lg)
        .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { store.whyRowFrame = $0 }
        .onHover { store.whyHover($0, frame: store.whyRowFrame) }
        .help(store.lightExplanation.map { "Why this light: \($0.headline)" } ?? "No light reading")
        .accessibilityLabel("Why this light")
    }
}

@MainActor
func panelSectionTitle(_ title: String, trailing: String? = nil) -> some View {
    HStack {
        Text(title).font(JRBarTokens.TypeStyle.section.font).foregroundStyle(JRBarTokens.Ink.secondary)
        Spacer()
        if let trailing {
            Text(trailing).font(JRBarTokens.TypeStyle.caption.font).foregroundStyle(JRBarTokens.Ink.secondary).lineLimit(1)
        }
    }.padding(.horizontal, JRBarTokens.Space.md).frame(height: PanelComposition.sectionHeight)
}
