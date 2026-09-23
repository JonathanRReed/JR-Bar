import JRBarCore
import SwiftUI

/// The History window: an away banner, a filter bar, and the rows grouped
/// by day with a monospaced elapsed column — each row able to open its
/// session's timeline in place — and, one tab over, the daemon's event
/// journal (Event Replay's list, now filterable and clickable).
struct HistoryView: View {
    @Bindable var store: HistoryStore

    var body: some View {
        Group {
            switch store.mode {
            case .activity: activity
            case .events: EventLogView(store: store)
            }
        }
        .frame(minWidth: 560, minHeight: 360)
        .font(.system(size: 13))
        .toolbar {
            ToolbarItem(placement: .principal) {
                Picker("View", selection: $store.mode) {
                    ForEach(HistoryStore.Mode.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                .help("Activity: what happened to sessions · Events: the monitor's event journal for this run")
            }
        }
    }

    @ViewBuilder
    private var activity: some View {
        VStack(spacing: 0) {
            if let away = store.away {
                AwayBanner(summary: away, store: store)
            }
            HistoryFilterBar(store: store)
            if let error = store.error, !store.rows.isEmpty {
                // A failed refresh keeps the stale rows and says so in one
                // line, rather than only in the empty state nobody sees.
                HStack(spacing: 8) {
                    Image(systemName: "exclamationmark.triangle").foregroundStyle(.orange)
                    Text(error).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1).truncationMode(.tail)
                    Spacer()
                    Button("Retry") { store.reload() }
                        .buttonStyle(.link)
                        .font(.system(size: 11))
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 5)
                .accessibilityElement(children: .combine)
            }
            Divider()
            if store.rows.isEmpty {
                HistoryEmptyState(store: store)
            } else if store.filtered.isEmpty {
                VStack(spacing: 6) {
                    Text("Nothing matches").font(.system(size: 13, weight: .medium)).foregroundStyle(.secondary)
                    Button("Clear search") { store.clearFilter() }.buttonStyle(.link).font(.system(size: 12))
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0, pinnedViews: [.sectionHeaders]) {
                        ForEach(store.days) { day in
                            Section {
                                ForEach(Array(day.rows.enumerated()), id: \.element.id) { index, row in
                                    HistoryRowView(row: row, store: store, isLast: index == day.rows.count - 1)
                                }
                            } header: {
                                DayHeader(title: day.title, count: day.rows.count)
                            }
                        }
                    }
                    .padding(.bottom, 12)
                }
            }
        }
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    store.undo()
                } label: {
                    Label(store.undoRemaining.map { "Undo (\($0))" } ?? "Undo", systemImage: "arrow.uturn.backward")
                        .labelStyle(.titleAndIcon)
                }
                .help(store.canUndo ? "Put the last cleared completions back" : "Nothing to undo")
                .disabled(!store.canUndo)
            }
            ToolbarItem(placement: .primaryAction) {
                Button {
                    store.clearCompleted()
                } label: {
                    Label("Clear completed", systemImage: "checkmark.circle")
                        .labelStyle(.titleAndIcon)
                }
                .help("Acknowledge every finished session (undo within 5 minutes)")
                .disabled(!store.isLive || store.completedCount == 0)
            }
            ToolbarItem(placement: .automatic) {
                Button {
                    store.reload()
                } label: {
                    Label("Refresh", systemImage: "arrow.clockwise")
                }
                .help("Fetch the latest rows")
                .disabled(!store.isLive || store.loading)
            }
        }
    }
}

struct AwayBanner: View {
    let summary: AwaySummary
    @Bindable var store: HistoryStore

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Image(systemName: "moon.stars.fill")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(Color.accentColor)
            VStack(alignment: .leading, spacing: 2) {
                Text(summary.text).font(.system(size: 13, weight: .medium))
                Text("Since \(HistoryStore.clock(summary.since)) · newer than your last visit here")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
            }
            Spacer()
            if let first = summary.rows.first(where: { $0.kind == "asked" && store.isLiveSession($0.session) })
                ?? summary.rows.first(where: { store.isLiveSession($0.session) }) {
                Button("Open latest") { store.open(first) }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(Color.accentColor.opacity(0.08))
        .overlay(alignment: .bottom) { Divider() }
    }
}

struct HistoryFilterBar: View {
    @Bindable var store: HistoryStore

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                HStack(spacing: 6) {
                    Image(systemName: "magnifyingglass").foregroundStyle(.tertiary).font(.system(size: 12))
                    TextField("Search sessions, details…", text: $store.filter.text)
                        .textFieldStyle(.plain)
                        .font(.system(size: 12))
                    if !store.filter.text.isEmpty {
                        Button { store.filter.text = "" } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(.tertiary) }
                            .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 5)
                .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(.primary.opacity(0.06)))
                .frame(maxWidth: 280)
                Spacer()
                if let loadedAt = store.loadedAt {
                    Text(store.loading ? "Refreshing…" : "\(store.filtered.count) of \(store.rows.count) · \(PanelStore.elapsed(since: loadedAt, now: store.now) ?? "0s") ago")
                        .font(.system(size: 11)).monospacedDigit().foregroundStyle(.tertiary)
                }
            }
            ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                ForEach(store.providers, id: \.self) { provider in
                    let style = ProviderStyle.style(for: provider, document: store.document)
                    FilterChip(selected: store.filter.providers.contains(provider), accent: style.accent) {
                        HStack(spacing: 5) {
                            ProviderTile(style: style, size: 14)
                            Text(style.name)
                        }
                    } action: { store.toggleProvider(provider) }
                }
                if !store.providers.isEmpty, !store.kinds.isEmpty {
                    Rectangle().fill(.primary.opacity(0.12)).frame(width: 1, height: 14).padding(.horizontal, 2)
                }
                ForEach(store.kinds, id: \.self) { kind in
                    FilterChip(selected: store.filter.kinds.contains(kind), accent: HistoryKindStyle.color(kind)) {
                        HStack(spacing: 4) {
                            Image(systemName: HistoryKindStyle.symbol(kind)).font(.system(size: 9, weight: .bold))
                            Text(HistoryKindStyle.word(kind))
                        }
                    } action: { store.toggleKind(kind) }
                }
                if !store.filter.isEmpty {
                    Button("Clear") { store.clearFilter() }.buttonStyle(.link).font(.system(size: 11))
                }
            }
            .padding(.vertical, 1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .clipped()
    }
}

struct FilterChip<Label: View>: View {
    let selected: Bool
    let accent: Color
    @ViewBuilder let label: () -> Label
    let action: () -> Void
    @ViewState private var hovering = false

    var body: some View {
        Button(action: action) {
            label()
                .font(.system(size: 11, weight: .medium))
                .lineLimit(1)
                .fixedSize()
                .foregroundStyle(selected ? accent : .primary.opacity(0.8))
                .padding(.horizontal, 8)
                .padding(.vertical, 3.5)
                .background(Capsule().fill(selected ? accent.opacity(0.16) : Color.primary.opacity(hovering ? 0.08 : 0.05)))
                .overlay(Capsule().strokeBorder(selected ? accent.opacity(0.4) : Color.primary.opacity(0.08), lineWidth: 0.5))
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}

struct DayHeader: View {
    let title: String
    let count: Int

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(title).font(.system(size: 11, weight: .semibold)).foregroundStyle(.secondary).tracking(0.2)
            Spacer()
            Text("\(count)").font(.system(size: 11)).monospacedDigit().foregroundStyle(.tertiary)
        }
        .padding(.horizontal, 16)
        .padding(.top, 12)
        .padding(.bottom, 5)
        .background(.bar)
    }
}

enum HistoryKindStyle {
    static func symbol(_ kind: String) -> String {
        switch kind {
        case "started": return "play.fill"
        case "completed": return "checkmark"
        case "asked": return "questionmark"
        case "answered": return "arrowshape.turn.up.left.fill"
        case "failed": return "xmark"
        case "ended": return "stop.fill"
        case "quota_crossed": return "percent"
        default: return "circle.fill"
        }
    }

    static func color(_ kind: String) -> Color {
        switch kind {
        case "completed": return .green
        case "asked": return .orange
        case "answered": return .blue
        case "failed": return .red
        case "quota_crossed": return .purple
        case "started": return .secondary
        default: return .secondary
        }
    }

    static func word(_ kind: String) -> String {
        CoreHistoryRow(at: 0, kind: kind).kindWord
    }
}

struct HistoryRowView: View {
    let row: CoreHistoryRow
    @Bindable var store: HistoryStore
    let isLast: Bool
    @ViewState private var hovering = false

    private var style: ProviderStyle { ProviderStyle.style(for: row.provider ?? "", document: store.document) }
    private var selected: Bool { store.selectedID == row.id }
    /// Only a session still live in the daemon's state can be opened; an
    /// ended row keeps its history but loses the affordance.
    private var openable: Bool { store.isLiveSession(row.session) }
    /// The row can open its session's transcript timeline in place.
    private var expandable: Bool { store.canExpand(row) }
    private var expanded: Bool { store.expandedID == row.id }

    var body: some View {
        VStack(spacing: 0) {
            header
            if expanded {
                timeline
                    .padding(.leading, 78)
                    .padding(.trailing, 20)
                    .padding(.vertical, 6)
                    .transition(.opacity)
            }
            if !isLast {
                Rectangle().fill(.primary.opacity(0.06)).frame(height: 1).padding(.leading, 78).padding(.trailing, 16)
            }
        }
    }

    /// The row's session timeline — the same view the Overview inspector
    /// and the Data Hoarder mount — capped in height with its own scroll,
    /// so one long run never pushes the rest of the day out of reach.
    @ViewBuilder
    private var timeline: some View {
        if let reconstruction = store.timeline(for: row) {
            VStack(alignment: .leading, spacing: 6) {
                ReconstructedTimelineView(reconstruction: reconstruction, viewState: store.expandedViewState)
                    .frame(height: 280)
                if let session = row.session, store.onRevealSession != nil {
                    Button("Open in Overview") { store.onRevealSession?(session) }
                        .buttonStyle(.link)
                        .font(.system(size: 11))
                        .help("The session's inspector: model, tokens, cost, the full timeline with older pages")
                }
            }
        } else if store.isLoadingTimeline(row) {
            HStack(spacing: 6) {
                ProgressView().controlSize(.mini)
                Text("Reading the transcript…").font(.system(size: 11)).foregroundStyle(.tertiary)
            }
        }
    }

    private var header: some View {
        VStack(spacing: 0) {
            HStack(alignment: .center, spacing: 10) {
                Text(HistoryStore.clock(row.date))
                    .font(.system(size: 11)).monospacedDigit().foregroundStyle(.tertiary)
                    .frame(width: 38, alignment: .trailing)
                ProviderTile(style: style, size: 22)
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(row.displayTitle).fontWeight(.medium).lineLimit(1)
                        KindBadge(kind: row.kind)
                        if row.kind == "started", store.isLiveSession(row.session) {
                            Text("still running")
                                .font(.system(size: 10, weight: .semibold))
                                .foregroundStyle(.secondary)
                        }
                        if row.unseen {
                            Circle().fill(Color.accentColor).frame(width: 5, height: 5).help("Newer than your last visit here")
                        }
                    }
                    if let detail = row.detail, !detail.isEmpty, !row.detailIsTitle {
                        Text(detail).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                    } else {
                        Text(style.name).font(.system(size: 11)).foregroundStyle(.tertiary)
                    }
                }
                Spacer(minLength: 8)
                Text(HistoryStore.duration(row.duration) ?? "")
                    .font(.system(size: 11, design: .monospaced)).foregroundStyle(.secondary)
                    .frame(width: 58, alignment: .trailing)
                    .help(row.duration.map { "Took \(Int($0.rounded())) s" } ?? "")
                Image(systemName: "arrow.up.forward.square")
                    .font(.system(size: 11)).foregroundStyle(.tertiary)
                    .opacity(hovering && openable ? 1 : 0)
                if expandable {
                    Button {
                        store.toggleExpanded(row)
                    } label: {
                        Image(systemName: "chevron.right")
                            .font(.system(size: 10, weight: .semibold))
                            .rotationEffect(.degrees(expanded ? 90 : 0))
                            .foregroundStyle(expanded ? .secondary : .tertiary)
                            .frame(width: 16, height: 16)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .help(expanded ? "Close the timeline (←)" : "Show what the session did (→ or Space)")
                    .accessibilityLabel(expanded ? "Hide timeline" : "Show timeline")
                } else {
                    Color.clear.frame(width: 16, height: 16)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 7)
            .background(
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(selected ? Color.accentColor.opacity(0.12)
                                   : (hovering && (openable || expandable) ? Color.primary.opacity(0.05) : Color.clear))
            )
            .padding(.horizontal, 8)
        }
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        // A live session opens in its terminal; an ended one that kept a
        // transcript opens its timeline in place instead of doing nothing.
        .onTapGesture {
            if openable { store.open(row) } else if expandable { store.toggleExpanded(row) }
        }
        .help(openable
              ? "Open the session"
              : (expandable ? "Ended — click to see what it did"
                            : "Ended; the session is gone from the daemon so there is nothing to open"))
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(row.displayTitle) \(row.kindWord) at \(HistoryStore.clock(row.date))")
    }
}

/// The daemon's event journal for this run — Event Replay's list, folded
/// into History: category chips (asks, runs, failures, escalation, quota,
/// devices), a search, and click-through to the session in the Overview.
/// It stays read-only and says so: nothing here re-fires an event, and the
/// live attention count is its own labeled fact, never implied by a row.
struct EventLogView: View {
    @Bindable var store: HistoryStore

    var body: some View {
        VStack(spacing: 0) {
            banner
            chips
            Divider()
            if store.replay.events.isEmpty {
                OverviewEmptyState(
                    symbol: "clock.arrow.circlepath",
                    title: store.isLive ? (store.replay.loading ? "Reading the journal…" : "No events yet") : "Monitor not connected",
                    text: store.isLive
                        ? "The journal holds the events the monitor published since it started."
                        : "The event journal lives in the monitor. It appears when the socket is live.")
            } else if store.events.isEmpty {
                VStack(spacing: 6) {
                    Text("Nothing matches").font(.system(size: 13, weight: .medium)).foregroundStyle(.secondary)
                    Button("Clear filter") { store.eventFilter = EventLogFilter() }.buttonStyle(.link).font(.system(size: 12))
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List(store.events) { event in
                    EventLogRow(event: event, store: store)
                }
                .listStyle(.inset)
            }
        }
        .toolbar {
            ToolbarItem(placement: .automatic) {
                Button {
                    Task { await store.replay.load() }
                } label: {
                    Label("Refresh", systemImage: "arrow.clockwise")
                }
                .help("Re-read the journal")
                .disabled(!store.isLive || store.replay.loading)
            }
        }
    }

    private var banner: some View {
        HStack(spacing: 10) {
            Label("Events", systemImage: "clock.arrow.circlepath")
                .font(.system(size: 10, weight: .bold))
                .padding(.horizontal, 7).padding(.vertical, 3)
                .background(Color.secondary.opacity(0.14), in: .capsule)
                .foregroundStyle(.secondary)
                .accessibilityLabel("Events: historical, read only")
            Text("This run's journal · \(store.replay.retained) retained" +
                 (store.replay.dropped > 0 ? " · \(store.replay.dropped) dropped" : "") +
                 (store.replay.resyncRequired ? " · resync required" : ""))
                .font(.system(size: 11)).foregroundStyle(.secondary)
            Spacer()
            if store.replay.liveAttention > 0 {
                Label("\(store.replay.liveAttention) need you now — live", systemImage: "exclamationmark.bubble")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(.orange)
            }
            if let error = store.replay.error {
                Text(error).font(.system(size: 10)).foregroundStyle(.red).lineLimit(1)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
    }

    private var chips: some View {
        HStack(spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass").foregroundStyle(.tertiary).font(.system(size: 12))
                TextField("Search events…", text: $store.eventFilter.text)
                    .textFieldStyle(.plain)
                    .font(.system(size: 12))
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(.primary.opacity(0.06)))
            .frame(maxWidth: 220)
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    ForEach(store.eventCategories) { category in
                        FilterChip(selected: store.eventFilter.categories.contains(category),
                                   accent: EventLogStyle.color(category)) {
                            HStack(spacing: 4) {
                                Image(systemName: EventLogStyle.symbol(category)).font(.system(size: 9, weight: .bold))
                                Text("\(category.word) \(store.eventCount(category))").monospacedDigit()
                            }
                        } action: { store.toggleEventCategory(category) }
                    }
                    if !store.eventFilter.isEmpty {
                        Button("Clear") { store.eventFilter = EventLogFilter() }.buttonStyle(.link).font(.system(size: 11))
                    }
                }
                .padding(.vertical, 1)
            }
        }
        .padding(.horizontal, 16)
        .padding(.bottom, 8)
    }
}

struct EventLogRow: View {
    let event: CoreEvent
    @Bindable var store: HistoryStore

    private var category: EventLogCategory { EventLogCategory.of(event.kind) }

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(event.at.map { EventLogStyle.clock.string(from: Date(timeIntervalSince1970: $0)) } ?? "—")
                .font(.system(size: 10, design: .monospaced))
                .foregroundStyle(.tertiary)
                .frame(width: 64, alignment: .leading)
            Image(systemName: EventLogStyle.symbol(category))
                .font(.system(size: 10))
                .foregroundStyle(EventLogStyle.color(category))
                .frame(width: 14)
            VStack(alignment: .leading, spacing: 1) {
                Text(LightLog.text(for: event))
                    .font(.system(size: 12, weight: .medium))
                    .lineLimit(1)
                if let detail = event.detail ?? event.message, !detail.isEmpty, detail != event.label {
                    Text(detail).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(2)
                }
            }
            Spacer()
            Text(event.kind).font(.system(size: 9, design: .monospaced)).foregroundStyle(.quaternary).lineLimit(1)
            if store.canReveal(event) {
                Button {
                    store.reveal(event)
                } label: {
                    Image(systemName: "arrow.up.forward.square").font(.system(size: 11))
                }
                .buttonStyle(.plain)
                .foregroundStyle(.tertiary)
                .help("Show this session in the Overview")
                .accessibilityLabel("Show in Overview")
            }
        }
        .accessibilityElement(children: .combine)
    }
}

enum EventLogStyle {
    static func symbol(_ category: EventLogCategory) -> String {
        switch category {
        case .asks: return "questionmark.bubble"
        case .runs: return "checkmark.circle"
        case .failures: return "xmark.octagon"
        case .escalation: return "bell.badge"
        case .quota: return "gauge.with.dots.needle.67percent"
        case .devices: return "cable.connector"
        case .other: return "circle"
        }
    }

    static func color(_ category: EventLogCategory) -> Color {
        switch category {
        case .asks: return .orange
        case .runs: return .green
        case .failures: return .red
        case .escalation: return .orange
        case .quota: return .purple
        case .devices: return .blue
        case .other: return .secondary
        }
    }

    static let clock: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "MM-dd HH:mm:ss"
        return formatter
    }()
}

struct KindBadge: View {
    let kind: String

    var body: some View {
        HStack(spacing: 3) {
            Image(systemName: HistoryKindStyle.symbol(kind)).font(.system(size: 7.5, weight: .bold))
            Text(HistoryKindStyle.word(kind)).font(.system(size: 10, weight: .semibold))
        }
        .foregroundStyle(HistoryKindStyle.color(kind))
        .padding(.horizontal, 5).padding(.vertical, 1.5)
        .background(Capsule().fill(HistoryKindStyle.color(kind).opacity(0.13)))
    }
}

struct HistoryEmptyState: View {
    @Bindable var store: HistoryStore

    var body: some View {
        VStack(spacing: 8) {
            Image(systemName: store.isLive ? "clock.arrow.circlepath" : "antenna.radiowaves.left.and.right.slash")
                .font(.system(size: 26, weight: .light)).foregroundStyle(.tertiary)
            Text(store.isLive ? (store.loading ? "Loading history…" : "Nothing yet") : "Monitor not connected")
                .font(.system(size: 13, weight: .medium)).foregroundStyle(.secondary)
            if let error = store.error {
                Text(error).font(.system(size: 11)).foregroundStyle(.tertiary).multilineTextAlignment(.center).frame(maxWidth: 360)
            } else if store.isLive {
                Text("Sessions that finish, fail or ask for you show up here")
                    .font(.system(size: 11)).foregroundStyle(.tertiary)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
