import AppKit
import JRBarCore
import SwiftUI

/// The Agent Overview utility's card on the Utilities page —
/// `ToyCard`'s shell (docs/UTILITIES.md: one visual language, two
/// registries) over an `AgentUtility`. The Overview window is the
/// canvas; this is the management seat — the counts, the compact
/// roster, and the session verbs.
struct AgentUtilityCard: View {
    let utility: AgentUtility
    let tint: Color

    var body: some View {
        ToyCard(toy: utility, tint: tint)
    }
}

/// The card's disclosure body: the live roster (state-tinted rows in
/// the organizer's grouping), the counts line and batch actions, then
/// the organizer settings. Every row is a `SessionRow` — the panel's
/// shape — and every action runs through `CoreModel`'s commands, so
/// the card and the panel can never disagree about a row's state or
/// what a button does.
struct AgentUtilityControls: View {
    let utility: AgentUtility
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            rosterSection

            Divider()
                .padding(.vertical, 4)

            SettingLabel(title: "Organize",
                         subtitle: "What the card lists and how it groups. The roster itself is the monitor's — this is only the card's cut of it.")

            LabeledContent {
                Picker(selection: utility.bind(\.grouping)) {
                    Text("By state").tag(AgentGrouping.state)
                    Text("By provider").tag(AgentGrouping.provider)
                    Text("Flat").tag(AgentGrouping.flat)
                } label: { EmptyView() }
                .labelsHidden()
                .pickerStyle(.segmented)
                .fixedSize()
            } label: {
                SettingLabel(title: "Group by",
                             subtitle: "By state leads with whoever needs you; by provider keeps each agent's rows together.")
            }

            Toggle(isOn: utility.bind(\.showRemote)) {
                SettingLabel(title: "Peer sessions",
                             subtitle: "Rows mirrored from your other Macs — informational only; they answer where they run.")
            }
            Toggle(isOn: utility.bind(\.showEnded)) {
                SettingLabel(title: "Ended sessions",
                             subtitle: "Runs that went away without a completion word.")
            }
            Toggle(isOn: utility.bind(\.showIdle)) {
                SettingLabel(title: "Idle sessions",
                             subtitle: "Sessions with nothing to report.")
            }
            Toggle(isOn: utility.bind(\.showElapsed)) {
                SettingLabel(title: "Elapsed time",
                             subtitle: "The trailing \"12m\" column.")
            }
            Toggle(isOn: utility.bind(\.quietWhenPaneFrontmost)) {
                SettingLabel(title: "Quiet while you watch",
                             subtitle: "An ask whose terminal pane is already in front gets no pulse, chime or sound — the banner still lands for the record.")
            }
            LabeledContent {
                HStack(spacing: 10) {
                    Slider(value: rowLimit, in: Self.rowLimitRange, step: 1)
                        .frame(width: 140)
                    ValueText(text: "\(utility.settings().rowLimit)")
                }
            } label: {
                SettingLabel(title: "Rows",
                             subtitle: "The most the card lists before the rest fold into \"+N more\".")
            }
        }
    }

    private static let rowLimitRange: ClosedRange<Double> =
        Double(AgentOrganizerSettings.rowLimitRange.lowerBound)...Double(AgentOrganizerSettings.rowLimitRange.upperBound)

    private var rowLimit: Binding<Double> {
        Binding(get: { Double(utility.settings().rowLimit) },
                set: { value in utility.update { $0.rowLimit = Int(value) } })
    }

    // MARK: The roster

    @ViewBuilder
    private var rosterSection: some View {
        SettingLabel(title: "Sessions",
                     subtitle: "The live roster, in the panel's precedence — whoever needs you leads.")

        if !utility.isOn {
            Text("Off — the roster still lives in the panel and the Overview.")
                .font(.callout)
                .foregroundStyle(.secondary)
        } else if !utility.core.isLive {
            Text("The monitor is not connected — the card lists sessions once the daemon answers.")
                .font(.callout)
                .foregroundStyle(.secondary)
        } else {
            if !utility.countParts.isEmpty {
                Text(utility.countParts.joined(separator: " · "))
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            if utility.groups.isEmpty {
                Text("No sessions — nothing live.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(utility.groups, id: \.key) { group in
                    if !group.title.isEmpty {
                        Text(group.title)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .padding(.top, 2)
                    }
                    ForEach(group.rows) { row in
                        rowView(row)
                    }
                }
                if utility.overflowCount > 0 {
                    Text("+\(utility.overflowCount) more — the Overview window lists everything.")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
            }

            HStack(spacing: 10) {
                if utility.completedCount > 0 {
                    Button("Clear finished") { utility.clearFinished() }
                        .controlSize(.small)
                }
                if utility.core.canUndoClear {
                    Button("Undo clear") { utility.undoClear() }
                        .controlSize(.small)
                }
                Spacer(minLength: 0)
                if utility.onOpenOverview != nil {
                    Button("Full overview…") { utility.openFullOverview() }
                        .controlSize(.small)
                }
            }
            .padding(.top, 2)

            if let notice = utility.notice {
                Text(notice)
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        }
    }

    // MARK: One session row

    /// The compact row: the provider tile, the label with its badges, a
    /// quiet subtitle (provider · last hook fact · folder or machine),
    /// then the state word and mark in `SessionActivity`'s colours.
    /// An open ask shows its summary and the Approve/Deny pair.
    private func rowView(_ row: SessionRow) -> some View {
        let now = Date()
        return HStack(alignment: .top, spacing: 8) {
            ProviderTile(style: row.style, size: 18)
                .padding(.top, 1)
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 5) {
                    Text(row.label)
                        .fontWeight(.medium)
                        .lineLimit(1)
                        .truncationMode(.tail)
                    if row.workers > 0 {
                        CountBadge(text: "\(row.workers)")
                            .help("\(row.workers) workers")
                    }
                    if row.stale {
                        Text("stale").font(.caption2).foregroundStyle(.tertiary)
                    }
                    if row.isSnoozed(now: now) {
                        Text("snoozed").font(.caption2).foregroundStyle(.tertiary)
                    }
                }
                HStack(spacing: 4) {
                    Text(row.style.name)
                    if let fact = row.activityFact {
                        Text("·").foregroundStyle(.quaternary)
                        Text(fact)
                    }
                    if row.isRemote {
                        Text("·").foregroundStyle(.quaternary)
                        Text("on \(row.remoteMachine ?? "a peer")")
                    } else if let tail = row.cwdTail {
                        Text("·").foregroundStyle(.quaternary)
                        Text(tail)
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                if let ask = row.ask {
                    if let summary = SessionRow.shortFact(ask.summary, limit: 90) {
                        Text(summary)
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                    }
                    if !row.isRemote, ask.canAnswer, !ask.wantsTextReply, ask.session != nil {
                        HStack(spacing: 8) {
                            Button("Approve") { utility.approve(ask) }
                            Button("Deny") { utility.deny(ask) }
                        }
                        .controlSize(.small)
                        .disabled(utility.pendingAnswers.contains(ask.id))
                        .padding(.top, 1)
                    }
                }
            }
            Spacer(minLength: 6)
            VStack(alignment: .trailing, spacing: 1) {
                HStack(spacing: 5) {
                    Text(row.activity.word)
                        .font(.caption.weight(.medium))
                        .foregroundStyle(row.activity.wordColor)
                        .lineLimit(1)
                    ActivityMark(activity: row.activity, accent: row.style.accent,
                                 reduced: reduceMotion)
                }
                if utility.settings().showElapsed {
                    Text(row.elapsedText(now: now) ?? " ")
                        .font(.caption)
                        .monospacedDigit()
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                }
            }
            Menu { rowMenu(row) } label: {
                Image(systemName: "ellipsis")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .frame(width: 16, height: 16)
                    .contentShape(Rectangle())
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .padding(.top, 2)
        }
        .help(row.help(now: now).map(Text.init) ?? Text(""))
        .contextMenu { rowMenu(row) }
    }

    /// The row's verbs — `SessionContextMenu`'s set: answer an open
    /// ask, open the session's own terminal, snooze the family, copy or
    /// reveal the working directory, dismiss a stuck row, clear a
    /// finished one. A remote row gets none of the local verbs — it has
    /// no window here to open and no local path to copy.
    @ViewBuilder
    private func rowMenu(_ row: SessionRow) -> some View {
        let now = Date()
        if row.isRemote {
            Text(row.remoteMachine.map { "Runs on \($0)" } ?? "Runs on a peer Mac")
            if row.activity.isClearable || row.stale {
                Divider()
                Button("Clear") { utility.clear(row) }
            }
        } else {
            if let ask = row.ask, ask.canAnswer, !ask.wantsTextReply, ask.session != nil {
                Button("Approve") { utility.approve(ask) }
                Button("Deny") { utility.deny(ask) }
                Divider()
            }
            Button(row.terminalApp.map { "Open in \($0)" } ?? "Open session") { utility.open(row) }
            if row.isSnoozed(now: now) {
                Button("Unsnooze") { utility.snooze(row, seconds: 0) }
            } else {
                Button(PanelStore.morningLabel(verb: "Snooze until",
                                               target: now.addingTimeInterval(TimeInterval(PanelStore.secondsUntilMorning(from: now))))) {
                    utility.snoozeUntilMorning(row)
                }
            }
            if let cwd = row.cwd, !cwd.isEmpty {
                Divider()
                Button("Copy path") { utility.copyPath(row) }
                Button("Reveal in Finder") { utility.reveal(row) }
            }
            if row.isDismissible || (row.ask == nil && (row.activity.isClearable || row.stale)) {
                Divider()
            }
            if row.isDismissible {
                Button("Dismiss") { utility.dismiss(row) }
            }
            if row.ask == nil && (row.activity.isClearable || row.stale) {
                Button("Clear") { utility.clear(row) }
            }
        }
    }
}
