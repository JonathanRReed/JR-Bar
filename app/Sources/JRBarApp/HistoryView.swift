import Charts
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
                WindowNoticeRow(symbol: "exclamationmark.triangle.fill", tint: .orange, text: error) {
                    Button("Retry") { store.reload() }
                        .buttonStyle(.link)
                }
                .padding(.horizontal, 12)
                .padding(.bottom, 6)
            }
            if let notice = store.notice {
                // Resume's or Open's outcome, in the monitor's words.
                WindowNoticeRow(symbol: notice.isError ? "exclamationmark.triangle.fill" : "arrow.uturn.forward.circle.fill",
                                tint: notice.isError ? .orange : .accentColor, text: notice.text)
                    .padding(.horizontal, 12)
                    .padding(.bottom, 6)
                    .transition(.opacity)
            }
            Divider()
            if store.rows.isEmpty {
                HistoryEmptyState(store: store)
            } else if store.filtered.isEmpty {
                VStack(spacing: 0) {
                    WindowEmptyState(symbol: "magnifyingglass", title: "Nothing matches",
                                     text: "No row fits this search and these filters.",
                                     actionTitle: "Clear search", action: { store.clearFilter() })
                        .frame(maxHeight: 260)
                    if store.offersHoarder {
                        HoarderOfferLine { store.offerHoarder() }
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                SnapshotScrollView {
                    LazyVStack(alignment: .leading, spacing: 0, pinnedViews: [.sectionHeaders]) {
                        ForEach(store.days) { day in
                            Section {
                                ForEach(Array(day.rows.enumerated()), id: \.element.id) { index, row in
                                    HistoryRowView(row: row, folded: day.folded[row.id] ?? [], store: store,
                                                   isLast: index == day.rows.count - 1)
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
        .sheet(item: $store.hoarderOffer) { offer in
            DataHoarderOfferSheet(offer: offer) { store.hoarderOffer = nil }
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

/// The empty search's one line: History searched only its rows, and the
/// Data Hoarder could keep the transcripts behind them.
struct HoarderOfferLine: View {
    let action: () -> Void

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "archivebox").foregroundStyle(.tertiary)
            Text("Only these rows were searched.").foregroundStyle(.secondary)
            Button("Keep a searchable copy of your sessions…", action: action)
                .buttonStyle(.link)
        }
        .font(.system(size: 11))
        .accessibilityElement(children: .combine)
    }
}

/// "While you were away": what happened since the last visit, as a
/// card across the top, with a way straight to the newest thing still
/// live.
struct AwayBanner: View {
    let summary: AwaySummary
    @Bindable var store: HistoryStore

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            Image(systemName: "moon.stars.fill")
                .font(.system(size: 15, weight: .semibold))
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(Color.accentColor)
                .frame(width: 34, height: 34)
                .background(Circle().fill(Color.accentColor.opacity(0.14)))
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(summary.text).font(.system(size: 13, weight: .semibold))
                    .lineLimit(2)
                Text("Since \(HistoryStore.clock(summary.since)) · newer than your last visit here")
                    .font(.system(size: 11.5)).foregroundStyle(.secondary)
            }
            Spacer(minLength: 8)
            if let first = summary.rows.first(where: { $0.kind == "asked" && store.isLiveSession($0.session) })
                ?? summary.rows.first(where: { store.isLiveSession($0.session) }) {
                Button("Open latest") { store.open(first) }
                    .controlSize(.small)
            }
        }
        .windowWell(padding: 12, tint: .accentColor)
        .padding(.horizontal, 12)
        .padding(.top, 12)
        .accessibilityElement(children: .combine)
    }
}

struct HistoryFilterBar: View {
    @Bindable var store: HistoryStore
    /// The rhythm's day under the pointer: while there is one, the caption
    /// beside the strip reads it instead of the counts.
    @ViewState private var hoveredDay: HistoryRhythm.Day?

    private var today: Date { Calendar.current.startOfDay(for: store.now) }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .center, spacing: 12) {
                WindowSearchField(prompt: store.canSearchTranscripts ? "Search sessions, details, transcripts…" : "Search sessions, details…",
                                  text: $store.filter.text)
                    .frame(maxWidth: 300)
                Spacer(minLength: 8)
                if let hoveredDay {
                    caption(hoveredDay.title, hoveredDay.detail)
                } else if let loadedAt = store.loadedAt {
                    caption("\(store.filtered.count) of \(store.rows.count)", freshness(loadedAt))
                }
                if HistoryRhythm.draws(store.rows, today: today) {
                    HistoryRhythm(store: store, today: today, hovered: $hoveredDay)
                        .frame(width: 190, height: 34)
                }
            }
            SnapshotScrollView(axes: .horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                if let day = store.filter.day {
                    // A day the Overview's heatmap or the rhythm sent here:
                    // one chip, and clicking it lets every day back in.
                    FilterChip(selected: true, accent: .accentColor) {
                        HStack(spacing: 4) {
                            Image(systemName: "calendar").font(.system(size: 9, weight: .bold))
                            Text(HistoryDayParse.title(day))
                            Image(systemName: "xmark").font(.system(size: 8, weight: .bold))
                        }
                    } action: { store.filter.day = nil }
                    .help("Showing one day — click to show every day")
                }
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
        .padding(.top, 12)
        .padding(.bottom, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .clipped()
    }

    /// Two right-aligned lines beside the rhythm: the counts and their
    /// age, or the hovered day and what happened in it.
    private func caption(_ title: String, _ detail: String) -> some View {
        VStack(alignment: .trailing, spacing: 1) {
            Text(title)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.secondary)
            Text(detail)
                .font(.system(size: 10))
                .foregroundStyle(.tertiary)
        }
        .monospacedDigit()
    }

    /// "updated 12s ago", or "Refreshing…" while a load is out.
    private func freshness(_ loadedAt: Date) -> String {
        if store.loading { return "Refreshing…" }
        let age = PanelStore.elapsed(since: loadedAt, now: store.now) ?? "0s"
        return "updated \(age) ago"
    }
}

/// Up to the last two weeks of History as one smooth line: how busy
/// each day was across the rows the chips let through, today a dot at
/// its end and a red dot on a day with a failure. It starts no earlier
/// than the oldest row History loaded, so a day it never read never
/// passes for a quiet one, and it waits for three days of rows before it
/// draws at all: a line through two points says nothing the day headers
/// do not. Hover a day to read it beside the strip; click it to show
/// only that day, and again to show every day.
struct HistoryRhythm: View {
    @Bindable var store: HistoryStore
    /// The start of today. The strip moves with the date, never with the
    /// window's one-second clock.
    let today: Date
    /// The day under the pointer, read out beside the strip.
    @Binding var hovered: Day?

    /// One day of the strip.
    struct Day: Identifiable, Equatable {
        let date: Date
        let rows: Int
        let failed: Int
        var id: Date { date }

        private static let titleFormat: DateFormatter = {
            let formatter = DateFormatter()
            formatter.setLocalizedDateFormatFromTemplate("EEE d MMM")
            return formatter
        }()

        /// "Tue 22 Sep".
        var title: String { Self.titleFormat.string(from: date) }

        /// "12 rows · 1 failed".
        var detail: String {
            let count = "\(rows) row\(rows == 1 ? "" : "s")"
            return failed > 0 ? "\(count) · \(failed) failed" : count
        }
    }

    static let span = 14
    /// The fewest days the strip draws.
    static let minimumDays = 3

    /// Rows per local day from the day of `loadedFrom` (the oldest row
    /// loaded) to today — at most `span` days — oldest first. Empty days
    /// inside that range count as zero, so a quiet weekend stays on the
    /// floor.
    static func days(_ rows: [CoreHistoryRow], loadedFrom: Date?, now: Date, span: Int = HistoryRhythm.span,
                     calendar: Calendar = .current) -> [Day] {
        let today = calendar.startOfDay(for: now)
        let back = min(span - 1, reach(from: loadedFrom, to: today, calendar: calendar))
        var counts: [Date: (rows: Int, failed: Int)] = [:]
        for row in rows {
            let day = calendar.startOfDay(for: row.date)
            var count = counts[day] ?? (0, 0)
            count.rows += 1
            if row.kind == "failed" { count.failed += 1 }
            counts[day] = count
        }
        return (0...back).reversed().compactMap { offset in
            guard let day = calendar.date(byAdding: .day, value: -offset, to: today) else { return nil }
            let count = counts[day] ?? (0, 0)
            return Day(date: day, rows: count.rows, failed: count.failed)
        }
    }

    /// Whole days from the oldest loaded row's day to today.
    private static func reach(from oldest: Date?, to today: Date, calendar: Calendar) -> Int {
        guard let oldest else { return 0 }
        let first = calendar.startOfDay(for: oldest)
        return max(0, calendar.dateComponents([.day], from: first, to: today).day ?? 0)
    }

    /// True once the loaded rows reach back the strip's fewest days.
    static func draws(_ rows: [CoreHistoryRow], today: Date, calendar: Calendar = .current) -> Bool {
        reach(from: rows.map(\.date).min(), to: calendar.startOfDay(for: today), calendar: calendar) >= minimumDays - 1
    }

    /// The rows the chips let through, whatever day is picked: the strip
    /// is the map the day filter is chosen from.
    private var days: [Day] {
        var filter = store.filter
        filter.day = nil
        filter.text = ""
        return Self.days(filter.apply(store.rows), loadedFrom: store.rows.map(\.date).min(), now: today)
    }

    /// The day whose point is nearest `date`: the points sit at each
    /// day's start, so the pointer snaps to the closer of two.
    static func nearestDay(_ date: Date) -> Date {
        Calendar.current.startOfDay(for: date.addingTimeInterval(12 * 3600))
    }

    /// First day to today, edge to edge.
    static func span(_ days: [Day]) -> ClosedRange<Date> {
        let first = days.first?.date ?? Date()
        return first...max(first, days.last?.date ?? first)
    }

    /// The day under `location` in the chart's overlay.
    private static func day(at location: CGPoint, in days: [Day], proxy: ChartProxy, geometry: GeometryProxy) -> Day? {
        guard let plot = proxy.plotFrame.map({ geometry[$0] }),
              let date: Date = proxy.value(atX: location.x - plot.origin.x) else { return nil }
        let nearest = nearestDay(date)
        return days.first { $0.date == nearest }
    }

    /// A failure's mark on the line: a red dot ringed in the window's
    /// colour so it sits on the line rather than in it.
    private static var failureDot: some View {
        Circle()
            .fill(Color.red)
            .frame(width: 5, height: 5)
            .padding(1.25)
            .background(Circle().fill(Color(nsColor: .windowBackgroundColor)))
    }

    var body: some View {
        let days = self.days
        let peak = Double(max(1, days.map(\.rows).max() ?? 1))
        Chart {
            ForEach(days) { day in
                AreaMark(x: .value("Day", day.date), y: .value("Rows", day.rows))
                    .foregroundStyle(LinearGradient(colors: [Color.accentColor.opacity(0.30), Color.accentColor.opacity(0.02)],
                                                    startPoint: .top, endPoint: .bottom))
                    .interpolationMethod(.monotone)
                LineMark(x: .value("Day", day.date), y: .value("Rows", day.rows))
                    .foregroundStyle(Color.accentColor)
                    .lineStyle(StrokeStyle(lineWidth: 1.4, lineCap: .round, lineJoin: .round))
                    .interpolationMethod(.monotone)
            }
            if let picked = store.filter.day ?? hovered?.date {
                RuleMark(x: .value("Day", picked))
                    .foregroundStyle(Color.primary.opacity(store.filter.day == nil ? 0.2 : 0.45))
                    .lineStyle(StrokeStyle(lineWidth: 1))
            }
            if let last = days.last {
                PointMark(x: .value("Day", last.date), y: .value("Rows", last.rows))
                    .symbolSize(18)
                    .foregroundStyle(Color.accentColor)
            }
            ForEach(days.filter { $0.failed > 0 }) { day in
                PointMark(x: .value("Day", day.date), y: .value("Rows", day.rows))
                    .symbol { Self.failureDot }
            }
        }
        .chartXAxis(.hidden)
        .chartYAxis(.hidden)
        .chartYScale(domain: 0...(peak * 1.25), range: .plotDimension(startPadding: 4, endPadding: 4))
        .chartXScale(domain: Self.span(days), range: .plotDimension(padding: 6))
        .chartLegend(.hidden)
        .chartOverlay { proxy in
            GeometryReader { geometry in
                Rectangle().fill(.clear).contentShape(Rectangle())
                    .onContinuousHover { phase in
                        var day: Day?
                        if case .active(let location) = phase {
                            day = Self.day(at: location, in: days, proxy: proxy, geometry: geometry)
                        }
                        if hovered != day { hovered = day }
                    }
                    .onTapGesture { location in
                        guard let day = Self.day(at: location, in: days, proxy: proxy, geometry: geometry) else { return }
                        let picked = store.filter.day.map { Calendar.current.isDate($0, inSameDayAs: day.date) } ?? false
                        store.filter.day = picked ? nil : day.date
                    }
            }
        }
        .background(RoundedRectangle(cornerRadius: WindowMetrics.controlRadius, style: .continuous)
            .fill(Color.primary.opacity(0.03)))
        .help("Click a day to show only that day")
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Activity over the last \(days.count) days")
        .accessibilityValue(summary(days))
    }

    private func summary(_ days: [Day]) -> String {
        let total = days.reduce(0) { $0 + $1.rows }
        let busiest = days.max { $0.rows < $1.rows }
        return "\(total) rows" + (busiest.map { $0.rows > 0 ? ", busiest \($0.title)" : "" } ?? "")
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
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Text(title).font(.system(size: 12, weight: .semibold))
            Text("\(count)")
                .font(.system(size: 10.5, weight: .semibold))
                .monospacedDigit()
                .foregroundStyle(.secondary)
                .padding(.horizontal, 6)
                .padding(.vertical, 1)
                .background(Capsule().fill(Color.primary.opacity(0.07)))
            Spacer()
        }
        .padding(.horizontal, 20)
        .padding(.top, 14)
        .padding(.bottom, 6)
        .background(Color(nsColor: .windowBackgroundColor))
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isHeader)
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
    /// The session's older rows folded under this one, newest first.
    var folded: [CoreHistoryRow] = []
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
    /// An ended run whose agent can pick it back up.
    private var resumable: Bool { store.canResume(row) }
    private var expanded: Bool { store.expandedID == row.id }

    var body: some View {
        VStack(spacing: 0) {
            header
            if expanded {
                timeline
                    .padding(.leading, 96)
                    .padding(.trailing, 20)
                    .padding(.vertical, 6)
                    .transition(.opacity)
            }
            if !isLast {
                Rectangle().fill(.primary.opacity(0.06)).frame(height: 1).padding(.leading, 96).padding(.trailing, 16)
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
                ReconstructedTimelineView(reconstruction: reconstruction, viewState: store.expandedViewState,
                                          landOnFailure: row.kind == "failed")
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

    /// The snippet with the index's « » markers turned into emphasis.
    static func marked(_ snippet: String) -> AttributedString {
        var out = AttributedString()
        var emphasised = false
        var run = ""
        func flush() {
            var piece = AttributedString(run)
            if emphasised { piece.inlinePresentationIntent = .stronglyEmphasized; piece.foregroundColor = .primary }
            out.append(piece)
            run = ""
        }
        for character in snippet {
            if character == "«" { flush(); emphasised = true } else if character == "»" { flush(); emphasised = false } else { run.append(character) }
        }
        flush()
        return out
    }

    private var header: some View {
        VStack(spacing: 0) {
            HStack(alignment: .center, spacing: 10) {
                Text(HistoryStore.clock(row.date))
                    .font(.system(size: 11)).monospacedDigit().foregroundStyle(.tertiary)
                    .lineLimit(1)
                    // Room for "12:35 PM" on a 12-hour clock.
                    .frame(width: 56, alignment: .trailing)
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
                        if !folded.isEmpty {
                            Text("+\(folded.count)")
                                .font(.system(size: 10, weight: .medium)).monospacedDigit()
                                .foregroundStyle(.tertiary)
                                .help(Self.foldedHelp(folded))
                        }
                        if row.unseen {
                            UnseenDot().help("Newer than your last visit here")
                        }
                    }
                    if let snippet = store.transcriptSnippet(for: row) {
                        // Found in what was said, not in the row's own
                        // words: the archive's snippet, matches marked.
                        HStack(spacing: 4) {
                            Image(systemName: "text.magnifyingglass").font(.system(size: 9))
                            Text(Self.marked(snippet)).lineLimit(1).truncationMode(.tail)
                        }
                        .font(.system(size: 11)).foregroundStyle(.secondary)
                        .help("Said in the archived transcript")
                    } else if let detail = row.detail, !detail.isEmpty, !row.detailIsTitle {
                        Text(detail).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                    } else {
                        Text(style.name).font(.system(size: 11)).foregroundStyle(.tertiary)
                    }
                }
                Spacer(minLength: 8)
                Text(HistoryStore.duration(row.duration) ?? "")
                    .font(.system(size: 11.5, weight: .medium)).monospacedDigit().foregroundStyle(.secondary)
                    .frame(width: 58, alignment: .trailing)
                    .help(row.duration.map { "Took \(Int($0.rounded())) s" } ?? "")
                if resumable, hovering || selected {
                    // An ended run picks back up where it ran.
                    Button("Resume") { store.resume(row) }
                        .controlSize(.mini)
                        .help("Resume this session in the terminal it ran in")
                } else {
                    Image(systemName: "arrow.up.forward.square")
                        .font(.system(size: 11)).foregroundStyle(.tertiary)
                        .opacity(hovering && openable ? 1 : 0)
                }
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
        .contextMenu {
            if openable {
                Button("Open Session") { store.open(row) }
            }
            if resumable {
                Button("Resume Session") { store.resume(row) }
            }
            if expandable {
                Button(expanded ? "Hide Timeline" : "Show Timeline") { store.toggleExpanded(row) }
            }
            if let session = row.session, store.onRevealSession != nil {
                Button("Open in Overview") { store.onRevealSession?(session) }
            }
        }
        .help(openable
              ? "Open the session"
              : (expandable ? "Ended — click to see what it did"
                            : (resumable ? "Ended — Resume picks it back up where it ran"
                                         : "Ended; the session is gone from the daemon so there is nothing to open")))
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(row.displayTitle) \(row.kindWord) at \(HistoryStore.clock(row.date))"
                            + (folded.isEmpty ? "" : ", and \(folded.count) earlier"))
    }

    /// "3 earlier: Finished ×2 · Started".
    static func foldedHelp(_ folded: [CoreHistoryRow]) -> String {
        "\(folded.count) earlier: \(HistoryGrouping.foldedSummary(folded))"
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
                WindowEmptyState(
                    symbol: store.isLive ? "list.bullet.rectangle" : "antenna.radiowaves.left.and.right.slash",
                    title: store.isLive ? (store.replay.loading ? "Reading the journal…" : "No events yet") : "Monitor not connected",
                    text: store.isLive
                        ? "The journal holds the events the monitor published since it started."
                        : "The event journal lives in the monitor. It appears when the socket is live.",
                    tint: store.isLive ? .secondary : .orange)
            } else if store.events.isEmpty {
                WindowEmptyState(symbol: "magnifyingglass", title: "Nothing matches",
                                 text: "No event in the journal fits this search and these categories.",
                                 actionTitle: "Clear filter", action: { store.eventFilter = EventLogFilter() })
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
            Label("Read only", systemImage: "lock.fill")
                .font(.system(size: 10, weight: .semibold))
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
        .padding(.top, 12)
        .padding(.bottom, 8)
    }

    private var chips: some View {
        HStack(spacing: 10) {
            WindowSearchField(prompt: "Search events…", text: $store.eventFilter.text)
                .frame(maxWidth: 240)
            SnapshotScrollView(axes: .horizontal, showsIndicators: false) {
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
        .padding(.bottom, 10)
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
        if !store.isLive {
            WindowEmptyState(symbol: "antenna.radiowaves.left.and.right.slash", title: "Monitor not connected",
                             text: store.error ?? "History lives in the monitor. The rows come back as soon as the socket is live.",
                             tint: .orange)
        } else if store.loading {
            WindowEmptyState(symbol: "clock.arrow.circlepath", title: "Loading history…",
                             text: "Reading what finished, failed and asked for you.")
        } else {
            WindowEmptyState(symbol: "clock.arrow.circlepath", title: "Nothing yet",
                             text: store.error ?? "Sessions that finish, fail or ask for you show up here.")
        }
    }
}
