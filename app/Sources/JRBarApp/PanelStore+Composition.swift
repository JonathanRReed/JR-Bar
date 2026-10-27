import Foundation
import JRBarCore
import JRBarUI
import SwiftUI

struct PanelAgent: Identifiable {
    let row: SessionRow
    let members: [SessionRow]
    let unlinked: Bool
    /// The daemon's count of workers working or waiting now (`workers`).
    let workerCount: Int
    var askingCount: Int = 0
    var id: String { row.id }
    var displayMembers: [SessionRow] { (row.ask == nil ? [row] : []) + members }

    /// The workers the panel shows: the listed ones and the ones asking
    /// in their own cards. The title counts these, so "0 workers" never
    /// sits above three finished ones.
    var listedWorkers: Int { max(members.count + askingCount, workerCount) }

    /// "1 working", "2 failed": the group's subtitle, said only when the
    /// title's count is not the whole story.
    var workerSummary: String? {
        var parts: [String] = []
        if workerCount > 0, workerCount != listedWorkers { parts.append("\(workerCount) working") }
        let failed = members.filter { $0.activity == .failed }.count
        if failed > 0 { parts.append("\(failed) failed") }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    func isEarlier(at now: Date) -> Bool {
        ([row] + members).allSatisfy {
            $0.ask == nil && $0.activity.isClearable && $0.since.map { now.timeIntervalSince($0) >= 600 } == true
        }
    }
}

struct PanelAgentsInputs: Equatable {
    let sessions: [CoreSession]
    let groups: [CoreAgentGroup]
    let settings: CoreSettings?
    let usage: [String: SessionUsage]
    let asks: [CoreAsk]
    let query: String
}

struct PanelAgentsMemo {
    let inputs: PanelAgentsInputs
    let agents: [PanelAgent]
}

extension PanelStore {
    var panelSelectableRows: [SessionRow] {
        let agents = currentPanelAgents + (earlierExpanded ? earlierPanelAgents : [])
        return visibleAskRows + agents.flatMap { agent in
            let root = agent.row.ask == nil ? [agent.row] : []
            return root + (expandedAgentGroups.contains(agent.id) ? agent.members : [])
        }
    }

    static let earlierSelectionID = "panel:earlier"
    var trimmedFindQuery: String { findQuery.trimmingCharacters(in: .whitespacesAndNewlines) }
    var panelHasEarlier: Bool { !earlierPanelAgents.isEmpty || hiddenCount > 0 }
    var panelSelectionIDs: [String] {
        let current = visibleAskRows.map(\.id) + currentPanelAgents.flatMap(selectionIDs)
        return current + (panelHasEarlier ? [Self.earlierSelectionID] : [])
            + (earlierExpanded ? earlierPanelAgents.flatMap(selectionIDs) : [])
    }
    private func selectionIDs(_ agent: PanelAgent) -> [String] {
        (agent.row.ask == nil ? [agent.id] : []) + (expandedAgentGroups.contains(agent.id) ? agent.members.map(\.id) : [])
    }
    var findSummary: String? {
        guard !trimmedFindQuery.isEmpty else { return nil }
        let matched = visibleRows.count
        return "“\(trimmedFindQuery)” · \(matched) of \(rows.count)"
    }

    @discardableResult
    func handleDisclosureKey(_ keyCode: UInt16) -> Bool {
        guard keyCode == 123 || keyCode == 124 else { return false }
        return setSelectedDisclosure(expanded: keyCode == 124)
    }

    @discardableResult
    func setSelectedDisclosure(expanded: Bool) -> Bool {
        if selectedID == Self.earlierSelectionID {
            earlierExpanded = expanded
            return true
        }
        guard let agent = panelAgents.first(where: { $0.id == selectedID }), !agent.unlinked,
              agent.workerCount > 0 || !agent.members.isEmpty else { return false }
        if expanded { expandedAgentGroups.insert(agent.id) }
        else { expandedAgentGroups.remove(agent.id) }
        return true
    }

    func shiftPanelProvider(_ row: ProviderRow, by delta: Int) async {
        var ids: [String] = []
        for provider in panelEditProviders where !ids.contains(provider.id) { ids.append(provider.id) }
        guard let index = ids.firstIndex(of: row.id), ids.indices.contains(index + delta) else { return }
        let neighbor = ids[index + delta]
        if delta < 0 { await movePanelProvider(row.id, before: neighbor) }
        else { await movePanelProvider(neighbor, before: row.id) }
    }

    /// Only the daemon's published membership joins sessions. Asks keep their own cards.
    var panelAgents: [PanelAgent] {
        guard isLive else { return [] }
        let sessions = core.sessions
        let inputs = PanelAgentsInputs(sessions: core.allSessions, groups: core.agentGroups,
                                       settings: core.settings, usage: sessionUsage.usage,
                                       asks: askRows.compactMap(\.ask), query: trimmedFindQuery)
        if let memo = panelAgentsMemo, memo.inputs == inputs { return memo.agents }
        let byID = Dictionary(inputs.sessions.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let askingRows = Dictionary(askRows.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let asks = Set(askingRows.keys)
        var claimed = Set<String>()
        var result: [PanelAgent] = []
        func row(_ session: CoreSession) -> SessionRow {
            var value = SessionRow(session: session, pinnedAsk: askingRows[session.id]?.ask, document: settingsDocument)
            value.usage = sessionUsage.usage[session.id]
            return value
        }
        for group in inputs.groups {
            guard let root = byID[group.rootWorkKey], root.groupId == group.id else { continue }
            let proven = group.members.compactMap { byID[$0] }.filter { $0.groupId == group.id }
            let members = proven.filter { $0.id != root.id && !asks.contains($0.id) }.map(row)
            claimed.formUnion(proven.map(\.id))
            // An asking root is already visible. Its non-asking workers remain expandable.
            if !asks.contains(root.id) || !members.isEmpty {
                result.append(PanelAgent(row: row(root), members: members, unlinked: false, workerCount: max(0, root.workers),
                                          askingCount: proven.filter { asks.contains($0.id) }.count))
            }
        }
        for session in sessions where !claimed.contains(session.id) && !asks.contains(session.id) {
            result.append(PanelAgent(row: row(session), members: [], unlinked: session.unlinkedWorker, workerCount: 0))
        }
        if !trimmedFindQuery.isEmpty {
            result = result.filter { $0.row.matches(trimmedFindQuery) || $0.members.contains { $0.matches(trimmedFindQuery) } }
        }
        let sorted = result.sorted {
            if $0.row.activity.sortRank != $1.row.activity.sortRank { return $0.row.activity.sortRank < $1.row.activity.sortRank }
            return ($0.row.since ?? .distantPast) > ($1.row.since ?? .distantPast)
        }
        panelAgentsMemo = PanelAgentsMemo(inputs: inputs, agents: sorted)
        return sorted
    }

    var currentPanelAgents: [PanelAgent] { panelAgents.filter { !$0.isEarlier(at: now) } }
    var earlierPanelAgents: [PanelAgent] { panelAgents.filter { $0.isEarlier(at: now) } }
    var panelHasRunningAgents: Bool {
        guard isLive else { return false }
        return !askRows.isEmpty || core.sessions.contains {
            let activity = SessionActivity.reduce($0)
            return !$0.stale && (activity == .working || activity == .waiting)
        }
    }

    /// Keep zero readings and failures visible. Availability and visibility are separate facts.
    var panelUsage: [CoreProviderUsage] {
        let readings = isLive ? core.usage : cachedPanelUsage
        return providerList.arranged(readings.filter { usage in
            guard usage.availability != "absent", usage.panelVisible else { return false }
            let row = providerList.rows.first { $0.id == usage.id && $0.instance == (usage.instance ?? "default") }
            return row.map(providerList.showsInPanel) ?? true
        }, provider: { $0.id }, surface: .panel)
    }

    var panelEditProviders: [ProviderRow] {
        let rows = providerList.rows.filter { row in
            core.usage.first { $0.id == row.id && ($0.instance ?? "default") == row.instance }?.availability != "absent"
        }
        return providerList.arranged(rows, provider: { $0.id }, surface: .all)
    }

    var panelWindowNames: [String] {
        let measured = panelUsage.filter { $0.quotaSource && !$0.usageIsOff && $0.availability != "not_found" }
        return Array(UsageGaugeRow.orderedWindowNames(measured.flatMap { $0.windows.map(\.name) }).prefix(2))
    }

    func movePanelProvider(_ source: String, before destination: String) async {
        var ids = providerList.providers.map(\.id)
        guard source != destination, ids.contains(source), ids.contains(destination) else { return }
        ids.removeAll { $0 == source }
        guard let index = ids.firstIndex(of: destination) else { return }
        ids.insert(source, at: index)
        try? await providerList.setOrder(ids)
    }

    func panelUsageAction(_ usage: CoreProviderUsage) {
        if usage.action == "Retry" || usage.action == "Retry later" { retryPanelUsage(usage) }
        else { runUsageAction(usage, action: usage.actionKind) }
    }

    /// "Updated 2m ago" beside the Usage title: when the monitor last
    /// finished a usage refresh. Nil while the monitor is down, where each
    /// row already says how old its reading is.
    var usageUpdatedText: String? {
        guard isLive, let at = core.state?.usage?.refreshedAt else { return nil }
        let date = Date(timeIntervalSince1970: at)
        guard now.timeIntervalSince(date) >= 60, let age = Self.elapsed(since: date, now: now) else { return "Updated just now" }
        return "Updated \(age) ago"
    }

    /// ⌘R in the panel: ask every provider the person turned on for a new
    /// reading. Nothing new leaves the Mac; a provider without consent is
    /// not asked.
    func refreshAllUsage() {
        Task { [weak self] in
            guard let self else { return }
            do {
                let reply = try await self.requestUsageRefresh([])
                guard reply.ok else { throw reply.error ?? CoreReplyError(code: "refused") }
            } catch { self.show(toast: MonitorWords.reason(error)) }
        }
    }

    func retryPanelUsage(_ usage: CoreProviderUsage) {
        Task { [weak self] in
            guard let self else { return }
            do {
                let reply = try await self.requestUsageRefresh([usage.id])
                guard reply.ok else { throw reply.error ?? CoreReplyError(code: "refused") }
            } catch { self.show(toast: MonitorWords.reason(error)) }
        }
    }
}

extension SessionRow {
    /// What VoiceOver says for the row's dot. Stale, idle and ended rows
    /// share a grey dot, so the word tells them apart.
    var dotLabel: String { stale ? "Stale" : activity.word }

    /// The one quiet line under a row's title. A warning a stuck or muted
    /// row needs (stale, snoozed, its hook feed quiet, ended) comes first;
    /// then what the agent is doing, else its model, else its folder.
    struct Caption: Equatable {
        let text: String
        /// Said in the quiet-warning tint rather than secondary ink.
        let warning: Bool
    }

    /// The folder, unless the title already ends with it ("Claude session
    /// in sample-app" over "sample-app").
    var distinctFolder: String? {
        guard let cwdTail, !cwdTail.isEmpty, !label.hasSuffix(cwdTail) else { return nil }
        return cwdTail
    }

    /// `feedQuiet` is the panel's "feed quiet 15m" for this row, if any.
    func caption(now: Date, feedQuiet: String? = nil) -> Caption? {
        if stale { return Caption(text: "Stale · no signal in a while", warning: true) }
        if isSnoozed(now: now), let until = snoozedUntil {
            return Caption(text: "Snoozed until \(PanelStore.clockTime(Date(timeIntervalSince1970: until)))", warning: true)
        }
        if let feedQuiet { return Caption(text: Self.sentenceCase(feedQuiet), warning: true) }
        if activity == .ended { return Caption(text: "Ended without saying it finished", warning: true) }
        if let waiting = workersWaitingText { return Caption(text: Self.sentenceCase(waiting), warning: false) }
        if let activityFact { return Caption(text: Self.sentenceCase(activityFact), warning: false) }
        if let model = usage?.modelName, !model.isEmpty { return Caption(text: model, warning: false) }
        if isRemote { return Caption(text: "On \(remoteMachine ?? "a peer")", warning: false) }
        return distinctFolder.map { Caption(text: $0, warning: false) }
    }

    /// A context window this full gets the bar under the row.
    static let contextBarFloor = 0.7

    /// How full the run's context is, once it is worth the bar.
    var contextBarFraction: Double? {
        guard let fraction = liveContextFraction, fraction > Self.contextBarFloor else { return nil }
        return fraction
    }

    /// The tint of a warning caption and a quiet row's elapsed time:
    /// amber-leaning and softer than an ask's, so a stuck run reads
    /// differently from a healthy one without claiming it needs you.
    static let warningTint = Tone.neutral.color.opacity(0.85)

    static func sentenceCase(_ text: String) -> String {
        text.prefix(1).uppercased() + text.dropFirst()
    }

    var panelState: StateDot.State {
        if stale { return .stale }
        switch activity {
        case .working: return .working
        case .waiting: return .asking
        case .done: return .done
        case .failed: return .failed
        case .idle, .ended: return .stale
        }
    }
}
