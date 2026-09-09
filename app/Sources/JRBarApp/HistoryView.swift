import JRBarCore
import SwiftUI

/// The History window: an away banner, a filter bar, and the rows grouped
/// by day with a monospaced elapsed column.
struct HistoryView: View {
    @Bindable var store: HistoryStore

    var body: some View {
        VStack(spacing: 0) {
            if let away = store.away {
                AwayBanner(summary: away, store: store)
            }
            HistoryFilterBar(store: store)
            Divider()
            if store.rows.isEmpty {
                HistoryEmptyState(store: store)
            } else if store.filtered.isEmpty {
                VStack(spacing: 6) {
                    Text("Nothing matches").font(.system(size: 13, weight: .medium)).foregroundStyle(.secondary)
                    Button("Clear filter") { store.clearFilter() }.buttonStyle(.link).font(.system(size: 12))
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
        .frame(minWidth: 560, minHeight: 360)
        .font(.system(size: 13))
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
                Text("Since \(HistoryStore.clock(summary.since)) · the Mac was asleep or locked")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
            }
            Spacer()
            if let first = summary.rows.first(where: { $0.kind == "asked" }) ?? summary.rows.first, first.session != nil {
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
                    let style = ProviderStyle.style(for: provider)
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
        default: return "circle.fill"
        }
    }

    static func color(_ kind: String) -> Color {
        switch kind {
        case "completed": return .green
        case "asked": return .orange
        case "answered": return .blue
        case "failed": return .red
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

    private var style: ProviderStyle { ProviderStyle.style(for: row.provider ?? "") }
    private var selected: Bool { store.selectedID == row.id }

    var body: some View {
        VStack(spacing: 0) {
            HStack(alignment: .center, spacing: 10) {
                Text(HistoryStore.clock(row.date))
                    .font(.system(size: 11)).monospacedDigit().foregroundStyle(.tertiary)
                    .frame(width: 38, alignment: .trailing)
                ProviderTile(style: style, size: 22)
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(row.label ?? style.name).fontWeight(.medium).lineLimit(1)
                        KindBadge(kind: row.kind)
                        if row.unseen {
                            Circle().fill(Color.accentColor).frame(width: 5, height: 5).help("Happened while you were away")
                        }
                    }
                    if let detail = row.detail, !detail.isEmpty {
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
                    .opacity(hovering && row.session != nil ? 1 : 0)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 7)
            .background(
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(selected ? Color.accentColor.opacity(0.12) : (hovering ? Color.primary.opacity(0.05) : Color.clear))
            )
            .padding(.horizontal, 8)
            if !isLast {
                Rectangle().fill(.primary.opacity(0.06)).frame(height: 1).padding(.leading, 78).padding(.trailing, 16)
            }
        }
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .onTapGesture { store.open(row) }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(row.label ?? style.name) \(row.kindWord) at \(HistoryStore.clock(row.date))")
    }
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
            Text(store.isLive ? (store.loading ? "Loading history…" : "Nothing yet") : "Core not connected")
                .font(.system(size: 13, weight: .medium)).foregroundStyle(.secondary)
            if let error = store.error {
                Text(error).font(.system(size: 11)).foregroundStyle(.tertiary).multilineTextAlignment(.center).frame(maxWidth: 360)
            } else if store.isLive {
                Text("Sessions that start, finish, fail or ask for you show up here.")
                    .font(.system(size: 11)).foregroundStyle(.tertiary)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
