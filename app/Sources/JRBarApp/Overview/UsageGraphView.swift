import JRBarUI
import Charts
import JRBarCore
import SwiftUI

/// The Overview's Usage pane: the shared-axis multi-provider activity
/// chart the daemon builds from local transcripts (`usage_graph`).
/// The old Settings-window graph reborn as a utility — range, metric
/// and provider picks are per-request; the stored settings stay put.
///
/// Honesty rules the chart keeps from the daemon's model:
///  - a series value `< 0` is a gap day — the line breaks there rather
///    than pretend a flat zero (runs split, same colour),
///  - `cost` is an API-equivalent estimate and says so,
///  - `partialProviderIds` names incomplete local history,
///  - the summary line is the daemon's own sentence, not ours.
struct UsageGraphView: View {
    @Bindable var store: OverviewStore
    /// Hovered day index within `0..<graph.days`; drives the rule mark
    /// and the readout. `ViewState` not `@State` — no SwiftUIMacros
    /// plugin on the Command Line Tools toolchain.
    @ViewState private var hoverDay: Int?

    private var document: CoreUsageGraphDocument? { store.graph }
    private var graph: CoreUsageGraph? { document.map { UsageSourceReading.providerGraph($0.graph) } }
    private var calendar: UsageChartCalendar { UsageChartCalendar(document?.graph ?? CoreUsageGraph()) }

    nonisolated static func xDomain(days: Int) -> ClosedRange<Double> {
        days > 1 ? 0...Double(days - 1) : -0.5...0.5
    }

    nonisolated static func chartMaximum(_ graph: CoreUsageGraph) -> Double {
        let observed = graph.series.flatMap { $0.values.prefix(max(0, graph.days)) }
            .filter { $0.isFinite && $0 >= 0 }.max() ?? 0
        let supplied = graph.scaleMax.isFinite ? graph.scaleMax : 0
        return max(graph.metric == "percent" ? 100 : 1, max(supplied, observed))
    }

    nonisolated static func selectedDay(_ raw: Double?, days: Int) -> Int? {
        guard let raw, raw.isFinite, days > 0 else { return nil }
        let day = raw.rounded()
        guard day >= 0, day < Double(days) else { return nil }
        return Int(day)
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            if store.tokenHistoryOff {
                HStack {
                    Text(CoreReplyError.tokenHistoryOffMessage)
                    Button("Turn on") { store.enableTokenHistory() }.disabled(!store.isLive)
                }.padding()
            } else if !store.isLive {
                OverviewEmptyState(symbol: "bolt.horizontal.circle", title: "Monitor not connected",
                                   text: "The chart comes from the monitor's local transcript scan.")
            } else if let error = store.graphError, graph == nil {
                errorState(error)
            } else if let graph {
                if graph.readingFiles > 0 {
                    HStack(spacing: 6) {
                        Image(systemName: "clock").foregroundStyle(.secondary)
                        Text("Reading \(graph.readingFiles.formatted()) \(graph.readingFiles == 1 ? "file" : "files"). Local history is still incomplete.")
                            .font(.system(size: 11)).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                        Spacer(minLength: 0)
                    }
                    .padding(.horizontal, 12).padding(.vertical, 6)
                    .background(Color.primary.opacity(0.035))
                }
                // A failed refresh keeps the last document but says so —
                // otherwise the header's new picks sit over the old chart
                // with nothing admitting the desync.
                if let error = store.graphError {
                    HStack(spacing: 6) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundStyle(.yellow)
                        Text("Refresh failed — showing the previous chart. \(error)")
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                        Spacer()
                        Button("Retry") { Task { await store.loadGraph() } }
                            .controlSize(.small)
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .background(.yellow.opacity(0.08))
                }
                ScrollView {
                    VStack(alignment: .leading, spacing: 14) {
                        if let comparison = UsageComparison.make(graph) {
                            UsageComparisonView(graph: graph, comparison: comparison)
                            Picker("Presentation", selection: $store.graphComposition) {
                                Text("Trends").tag(false)
                                Text("Composition").tag(true)
                            }
                            .pickerStyle(.segmented)
                            .labelsHidden()
                            .accessibilityLabel("Chart presentation")
                            .frame(maxWidth: 240)
                            if store.graphComposition {
                                UsageCompositionView(graph: graph, comparison: comparison, calendar: calendar) { day in
                                    store.showDay(day, provider: "all")
                                }
                                .opacity(store.graphLoading ? 0.45 : 1)
                            } else {
                                chart(graph).opacity(store.graphLoading ? 0.45 : 1)
                            }
                        } else {
                            chart(graph).opacity(store.graphLoading ? 0.45 : 1)
                            legend(graph)
                        }
                        if let summary = document?.summary, !summary.isEmpty {
                            Text(summary)
                                .font(.system(size: 11))
                                .foregroundStyle(.secondary)
                                .textSelection(.enabled)
                        }
                        disclosures(graph)
                        if let coverage = graph.costCoverage {
                            UsageCostCoverageView(coverage: coverage)
                        }
                        if let imported = document?.graph {
                            UsageIntegrationSourcesView(graph: imported)
                        }
                        if let heatmap = graph.heatmap {
                            UsageHeatmapGrid(heatmap: heatmap, providers: graph.providers) { day, provider in
                                store.showDay(day, provider: provider)
                            }
                        }
                    }
                    .padding(14)
                }
                .overlay(alignment: .topTrailing) {
                    if store.graphLoading {
                        DelayedWait().padding(18)
                    }
                }
            } else {
                loadingState
            }
        }
        .onChange(of: store.graphPickKey) { hoverDay = nil }
        .onChange(of: graph?.periodLabel) { hoverDay = nil }
    }

    // MARK: Header

    @ViewBuilder
    private var header: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                Text("Usage").font(.system(size: 13, weight: .semibold))
                    .lineLimit(1).fixedSize(horizontal: true, vertical: false)
                Picker("Metric", selection: Binding(
                    get: { store.graphMetric }, set: { store.setGraphMetric($0) }
                )) {
                    Text("Tokens").tag("tokens")
                    Text("Cost").tag("cost")
                    Text("Sessions").tag("sessions")
                    Text("Quota").tag("percent")
                }
                .pickerStyle(.segmented).frame(maxWidth: 300).labelsHidden()
                Spacer(minLength: 0)
                Button { Task { await store.loadGraph() } } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .buttonStyle(.borderless)
                .accessibilityLabel("Refresh usage chart")
                .disabled(store.graphLoading)
                .help("Rescan the transcripts and redraw")
            }
            HStack(spacing: 10) {
                providerMenu
                Picker("Range", selection: Binding(
                    get: { store.graphDays }, set: { store.setGraphDays($0) }
                )) {
                    Text("7D").tag(7)
                    Text("30D").tag(30)
                    Text("90D").tag(90)
                    Text("1Y").tag(365)
                }
                .pickerStyle(.segmented).frame(width: 190).labelsHidden()
                Spacer(minLength: 0)
                if let loaded = store.graphLoadedAt {
                    ViewThatFits(in: .horizontal) {
                        Text("Updated \(loaded.formatted(date: .omitted, time: .shortened))")
                            .font(.system(size: 10)).foregroundStyle(.tertiary).fixedSize()
                        Color.clear.frame(width: 0, height: 0)
                    }
                }
            }
        }
        .padding(.horizontal, 12).padding(.vertical, 8)
    }

    /// The provider checklist — options are the daemon's registry plus
    /// any series-only source a reply named; checks come from the
    /// resolved set the last reply charted.
    @ViewBuilder
    private var providerMenu: some View {
        let checked = store.graphCheckedProviders
        Menu {
            ForEach(store.graphProviderOptions, id: \.self) { id in
                let style = ProviderStyle.style(for: id)
                Toggle(isOn: Binding(
                    get: { checked.contains(id) },
                    set: { _ in store.toggleGraphProvider(id) }
                )) {
                    Label {
                        Text(style.name)
                    } icon: {
                        Image(systemName: "circle.fill")
                            .foregroundStyle(style.accent)
                    }
                }
            }
            if store.graphProviderOptions.isEmpty {
                Text("No providers on record")
            }
        } label: {
            Label("Providers", systemImage: "checklist")
                .font(.system(size: 11))
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .help("Choose which providers the chart covers — the daemon's stored set stays untouched")
        .disabled(store.graphProviderOptions.isEmpty)
    }

    // MARK: Chart

    /// One plotted point — a single (day, series-row, run) slot.
    /// Internal not private so the run-splitting is testable.
    struct Point: Hashable {
        var day: Int
        var value: Double
        var providerId: String
        /// Contiguous non-negative run index — part of the id that
        /// keeps the line broken across gap days.
        var run: Int
        /// Unique per series ROW — `seriesKey` alone is not enough
        /// (percent mode can emit the same provider for two accounts),
        /// so the row's position salts the id too.
        var seriesIndex: Int
        var seriesId: String { "\(seriesIndex)#\(run)" }
    }

    /// Split each series into its non-negative runs: negative slots are
    /// gap days (before the provider had samples), and a line that
    /// bridged them would claim data the scan never saw. `nonisolated`
    /// — pure, and the View's MainActor isolation would trap a
    /// non-actor caller (tests).
    nonisolated static func splitPoints(_ graph: CoreUsageGraph) -> [Point] {
        var out: [Point] = []
        for (seriesIndex, series) in graph.series.enumerated() {
            if graph.metric == "cost", series.hasPricedUsage == false { continue }
            var run = 0
            var open = false
            for (index, value) in series.values.enumerated() where index < graph.days {
                if value < 0 {
                    if open { run += 1; open = false }
                    continue
                }
                open = true
                out.append(Point(day: index, value: value, providerId: series.providerId,
                                 run: run, seriesIndex: seriesIndex))
            }
        }
        return out
    }

    /// Percent mode's quota overlay: each day a series stood at its limit,
    /// with the provider it belongs to. The daemon's percent series is the
    /// day's lowest remaining percent, so a spent quota is the floor (0 %
    /// left) and a full one is the top of the chart; the chart marks the
    /// floor days so spend lines up with the limits it ran into.
    /// Empty for every other metric, whose numbers have no ceiling.
    nonisolated static func limitDays(_ graph: CoreUsageGraph) -> [(day: Int, providerId: String)] {
        guard graph.metric == "percent" else { return [] }
        var out: [(day: Int, providerId: String)] = []
        var seen = Set<String>()
        for series in graph.series {
            for (index, value) in series.values.enumerated() where index < graph.days && value >= 0 && value <= 0.5 {
                if seen.insert("\(index)|\(series.providerId)").inserted {
                    out.append((index, series.providerId))
                }
            }
        }
        return out.sorted { $0.day == $1.day ? $0.providerId < $1.providerId : $0.day < $1.day }
    }

    /// A series that exists only as isolated days still needs a mark —
    /// a one-point run draws no line.
    private func runLengths(_ points: [Point]) -> [String: Int] {
        var counts: [String: Int] = [:]
        for point in points { counts[point.seriesId, default: 0] += 1 }
        return counts
    }

    @ViewBuilder
    private func chart(_ graph: CoreUsageGraph) -> some View {
        let points = Self.splitPoints(graph)
        let singletons = Set(runLengths(points).filter { $0.value == 1 }.map(\.key))
        VStack(alignment: .leading, spacing: 4) {
            Text(graph.periodLabel.isEmpty ? "Local activity" : graph.periodLabel)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.secondary)
            Chart {
                // The floor a spent quota sits on, under the lines.
                if graph.metric == "percent" {
                    RuleMark(y: .value("Limit", 0))
                        .foregroundStyle(.secondary.opacity(0.45))
                        .lineStyle(StrokeStyle(lineWidth: 1, dash: [3, 3]))
                        .annotation(position: .top, alignment: .leading, spacing: 1) {
                            Text("limit").font(.system(size: 8)).foregroundStyle(.tertiary)
                        }
                }
                ForEach(points, id: \.self) { point in
                    let accent = ProviderStyle.style(for: point.providerId).accent
                    LineMark(x: .value("Day", point.day), y: .value("Value", point.value),
                             series: .value("Series", point.seriesId))
                        .foregroundStyle(accent)
                        .lineStyle(StrokeStyle(lineWidth: 1.8))
                    AreaMark(x: .value("Day", point.day), y: .value("Value", point.value),
                             series: .value("Series", point.seriesId), stacking: .unstacked)
                        .foregroundStyle(accent.opacity(0.10))
                    if singletons.contains(point.seriesId) {
                        PointMark(x: .value("Day", point.day), y: .value("Value", point.value))
                            .foregroundStyle(accent)
                            .symbolSize(14)
                    }
                }
                // The days a provider stood at its limit: a small mark on
                // the floor in its colour, over the lines.
                ForEach(Array(Self.limitDays(graph).enumerated()), id: \.offset) { _, hit in
                    PointMark(x: .value("Day", hit.day), y: .value("Value", 0))
                        .foregroundStyle(ProviderStyle.style(for: hit.providerId).accent)
                        .symbol(.triangle)
                        .symbolSize(22)
                        .accessibilityLabel("\(ProviderStyle.style(for: hit.providerId).name) at its limit")
                }
                if let day = Self.selectedDay(hoverDay.map { Double($0) }, days: graph.days) {
                    RuleMark(x: .value("Day", day))
                        .foregroundStyle(.secondary.opacity(0.35))
                        .lineStyle(StrokeStyle(lineWidth: 1))
                }
            }
            // Percent mode always shows its whole 0...100 range, even on a quiet one.
            .chartYScale(domain: 0...Self.chartMaximum(graph))
            .chartXScale(domain: Self.xDomain(days: graph.days))
            .chartYAxis {
                AxisMarks(position: .leading, values: .automatic(desiredCount: 4)) { value in
                    AxisGridLine()
                    AxisValueLabel {
                        if let v = value.as(Double.self) {
                            if let label = Self.axisLabel(v, metric: graph.metric) {
                                Text(label)
                                    .font(.system(size: 9))
                                    .foregroundStyle(Color.secondary)
                            }
                        }
                    }
                }
            }
            .chartXAxis {
                // The daemon's own strided labels — empty slots draw no
                // tick, so the axis shows exactly the days it named.
                AxisMarks(values: Array(graph.labels.indices)) { value in
                    if let index = value.as(Int.self), index < graph.labels.count,
                       !graph.labels[index].isEmpty {
                        AxisGridLine()
                        AxisValueLabel {
                            Text(graph.labels[index])
                                .font(.system(size: 9))
                                .foregroundStyle(Color.secondary)
                        }
                    }
                }
            }
            .chartOverlay { proxy in
                GeometryReader { geometry in
                    Rectangle().fill(.clear).contentShape(Rectangle())
                        .onContinuousHover { phase in
                            switch phase {
                            case .active(let location):
                                guard let frame = proxy.plotFrame,
                                      geometry[frame].contains(location) else {
                                    hoverDay = nil
                                    return
                                }
                                let x = location.x - geometry[frame].origin.x
                                hoverDay = Self.selectedDay(proxy.value(atX: x, as: Double.self),
                                                            days: graph.days)
                            case .ended:
                                hoverDay = nil
                            }
                        }
                }
            }
            .chartOverlay { proxy in
                readout(graph, proxy: proxy)
            }
            .frame(height: 220)
        }
    }

    /// The hover readout — the day's date and each provider's value at
    /// that slot, pinned above the plot.
    @ViewBuilder
    private func readout(_ graph: CoreUsageGraph, proxy: ChartProxy) -> some View {
        if let day = Self.selectedDay(hoverDay.map { Double($0) }, days: graph.days) {
            GeometryReader { geometry in
                if let frame = proxy.plotFrame,
                   let x = proxy.position(forX: day) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(dayLabel(day, graph: graph))
                            .font(.system(size: 10, weight: .semibold))
                        ForEach(Array(graph.series.enumerated()), id: \.offset) { _, series in
                            UsageGraphReadoutRow(series: series, day: day, metric: graph.metric)
                        }
                    }
                    .padding(.horizontal, 8).padding(.vertical, 6)
                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 6))
                    .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(.primary.opacity(0.12)))
                    .frame(width: 150)
                    // The card floats over the hover-tracking overlay —
                    // swallowing the pointer would end the hover it
                    // answers to.
                    .allowsHitTesting(false)
                    .position(x: min(max(x + geometry[frame].origin.x, 75), geometry.size.width - 75),
                              y: geometry[frame].origin.y + 34)
                }
            }
        }
    }

    /// ISO date for a day slot — the heatmap's calendar is canonical;
    /// the strided axis label is the fallback.
    private func dayLabel(_ day: Int, graph: CoreUsageGraph) -> String {
        let iso = calendar.days
        if day >= 0, day < iso.count {
            if let date = Self.isoDay.date(from: iso[day]) {
                return Self.readoutDay.string(from: date)
            }
            return iso[day]
        }
        return day < graph.labels.count && !graph.labels[day].isEmpty
            ? graph.labels[day]
            : "Day \(day + 1)"
    }

    private static let isoDay: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        formatter.locale = Locale(identifier: "en_US_POSIX")
        return formatter
    }()

    private static let readoutDay: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "EEE, MMM d"
        return formatter
    }()

    // MARK: Legend + disclosures

    /// Per-series chips — colour, name, the range total on the chart's
    /// own metric, and the partial-coverage badge when the daemon says
    /// the local history is incomplete. Percent mode can emit several
    /// series for one provider (one per account instance): collapsing
    /// them into the provider's first row would draw an account the
    /// legend never names, so each series earns its own chip.
    @ViewBuilder
    private func legend(_ graph: CoreUsageGraph) -> some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 130), spacing: 6)], spacing: 6) {
            ForEach(Self.legendRows(graph), id: \.key) { row in
                let style = ProviderStyle.style(for: row.id)
                HStack(spacing: 6) {
                    Circle().fill(style.accent).frame(width: 7, height: 7)
                    Text(row.label).font(.system(size: 10, weight: .medium))
                        .lineLimit(1)
                    Spacer(minLength: 2)
                    if let series = row.series {
                        Text(Self.legendValueLabel(series, metric: graph.metric))
                            .font(.system(size: 10)).monospacedDigit()
                            .foregroundStyle(.secondary)
                    } else {
                        Text(Self.noHistoryText(metric: graph.metric))
                            .font(.system(size: 9))
                            .foregroundStyle(.tertiary)
                    }
                    if graph.partialProviderIds.contains(row.id) {
                        Image(systemName: "exclamationmark.triangle")
                            .font(.system(size: 8))
                            .foregroundStyle(Tone.neutral.color)
                            .help("Partial local history in this range")
                    }
                }
                .padding(.horizontal, 8).padding(.vertical, 4)
                .background(.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 6))
            }
        }
    }

    /// One legend row per charted series — a provider with several
    /// instance rows (percent mode) expands into one chip each so the
    /// legend names every line the chart draws.
    nonisolated static func legendRows(_ graph: CoreUsageGraph)
        -> [(key: String, id: String, label: String, series: CoreUsageGraph.Series?)] {
        var rows: [(key: String, id: String, label: String, series: CoreUsageGraph.Series?)] = []
        for id in graph.providers {
            let providerSeries = graph.series.filter { $0.providerId == id }
            if providerSeries.count <= 1 {
                rows.append((id, id, ProviderStyle.style(for: id).name, providerSeries.first))
            } else {
                for series in providerSeries {
                    rows.append((series.seriesKey, id, seriesName(series), series))
                }
            }
        }
        return rows
    }

    /// A series' name as the legend and the readout say it: the provider's
    /// own name, with the account after it when the daemon split one. The
    /// daemon's `label` is the bare provider id for a default account and
    /// `provider · instance` for another, so it is never shown raw.
    nonisolated static func seriesName(_ series: CoreUsageGraph.Series) -> String {
        let name = ProviderStyle.style(for: series.providerId).name
        guard let label = series.label, !label.isEmpty, label != series.providerId else { return name }
        let prefix = series.providerId + " · "
        if label.hasPrefix(prefix) { return name + " · " + label.dropFirst(prefix.count) }
        return label
    }

    @ViewBuilder
    private func disclosures(_ graph: CoreUsageGraph) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            if graph.costSemantics == "api_equivalent_estimate" {
                Label("Cost is an API-equivalent estimate — transcript tokens priced at list rates, not subscription spend.",
                      systemImage: "info.circle")
            }
            if !graph.partialProviderIds.isEmpty {
                Label("Partial local history: " + graph.partialProviderIds
                        .map { ProviderStyle.style(for: $0).name }.joined(separator: ", "),
                      systemImage: "exclamationmark.triangle")
            }
            if graph.series.isEmpty {
                Label(Self.emptyExplanation(metric: graph.metric), systemImage: "tray")
            }
        }
        .font(.system(size: 10))
        .foregroundStyle(.tertiary)
    }

    // MARK: States

    private var loadingState: some View {
        VStack(spacing: 10) {
            ProgressView()
            Text("Scanning local activity…")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
            Text("The transcript scan can take a moment on first load.")
                .font(.system(size: 10))
                .foregroundStyle(.tertiary)
        }
        .delayedReveal()
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func errorState(_ error: String) -> some View {
        VStack(spacing: 10) {
            Image(systemName: "exclamationmark.triangle")
                .font(.system(size: 22))
                .foregroundStyle(Tone.neutral.color)
            Text("Couldn't load the chart")
                .font(.system(size: 13, weight: .medium))
            Text(error)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 320)
            Button("Try again") { Task { await store.loadGraph() } }
                .controlSize(.small)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: Formatting

    /// The chip's glance number on the chart's own metric: a range
    /// total for the countable metrics, the freshest remaining-quota
    /// reading for percent — summing daily percents would claim
    /// thousands of percent, not a figure anyone can read.
    nonisolated static func legendFigure(_ series: CoreUsageGraph.Series, metric: String) -> Double {
        if metric == "percent" {
            return series.values.last(where: { $0 >= 0 }) ?? 0
        }
        return series.values.filter { $0 > 0 }.reduce(0, +)
    }

    nonisolated static func legendValueLabel(_ series: CoreUsageGraph.Series, metric: String) -> String {
        if metric == "cost" {
            if series.hasPricedUsage == false { return "Unpriced" }
            if !series.values.contains(where: { $0 >= 0 }) { return "No estimate" }
        }
        return valueLabel(legendFigure(series, metric: metric), metric: metric)
    }

    nonisolated static func readoutValueLabel(_ series: CoreUsageGraph.Series, day: Int, metric: String) -> String? {
        guard series.values.indices.contains(day), series.values[day] >= 0 else { return nil }
        if metric == "cost", series.hasPricedUsage == false { return "Unpriced" }
        return valueLabel(series.values[day], metric: metric)
    }

    /// Axis labels ride the metric: compact tokens, estimate dollars,
    /// grouped counts, bare percents. A tick between two whole sessions or
    /// tokens has no honest label (it would round into its neighbour), so
    /// it has none.
    nonisolated static func axisLabel(_ value: Double, metric: String) -> String? {
        switch metric {
        case "cost": return UsageFormat.cost(value)
        case "sessions":
            return value == value.rounded() ? UsageFormat.grouped(value) : nil
        case "percent": return "\(UsageWindowLabel.wholeUsed(value))%"
        default:
            return value == value.rounded() ? UsageFormat.tokens(Int(saturating: value)) : nil
        }
    }

    /// What a provider chip says when it has no series for the metric.
    nonisolated static func noHistoryText(metric: String) -> String {
        metric == "percent" ? "no quota history" : "no local history"
    }

    /// Why the chart is empty. Quota history is the monitor's own record of
    /// each provider's remaining quota; every other metric is a scan of
    /// on-disk transcripts.
    nonisolated static func emptyExplanation(metric: String) -> String {
        if metric == "percent" {
            return "No quota readings in this range — the monitor records each provider's remaining quota as it reads it, so the line fills in as days pass."
        }
        return "No local activity in this range — the scan reads on-disk transcripts (Claude, Codex, opencode, Gemini, T3) plus the ledger."
    }

    /// Readout/legend values get the fuller form.
    nonisolated static func valueLabel(_ value: Double, metric: String) -> String {
        switch metric {
        case "cost": return UsageFormat.cost(value)
        case "sessions": return UsageFormat.grouped(value)
        case "percent": return String(format: "%.1f%%", value)
        default: return UsageFormat.tokens(Int(saturating: value))
        }
    }
}

struct UsageGraphReadoutRow: View {
    let series: CoreUsageGraph.Series
    let day: Int
    let metric: String

    var body: some View {
        if let label = UsageGraphView.readoutValueLabel(series, day: day, metric: metric) {
            HStack(spacing: 4) {
                Circle()
                    .fill(ProviderStyle.style(for: series.providerId).accent)
                    .frame(width: 5, height: 5)
                Text(UsageGraphView.seriesName(series))
                Spacer(minLength: 6)
                Text(label).monospacedDigit()
            }
            .font(.system(size: 9))
        }
    }
}

/// The heatmap half of the document: one row per provider plus the
/// aggregate, cells painted in the daemon's own intensity colours.
/// Rows scroll horizontally for the long ranges — the grid is the
/// chart's calendar, not a decoration.
struct UsageHeatmapGrid: View {
    let heatmap: CoreUsageHeatmap
    /// Provider ids in the reply's resolved order.
    let providers: [String]
    /// A cell click: the day (ISO) and the row's provider id ("all" for
    /// the aggregate) — the grid as a way into the past, not decoration.
    var onSelectDay: ((String, String) -> Void)? = nil

    private var rows: [(id: String, label: String, provider: CoreUsageHeatmap.Provider)] {
        var out: [(String, String, CoreUsageHeatmap.Provider)] =
            [("all", "All", heatmap.aggregate)]
        for id in providers where id != "all" {
            guard let provider = heatmap.providers[id] else { continue }
            out.append((id, ProviderStyle.style(for: id).name, provider))
        }
        // A provider in the heatmap but not the resolved set still
        // earned its row — the reply asked for it once.
        for (id, provider) in heatmap.providers
        where id != "all" && !providers.contains(id) {
            out.append((id, ProviderStyle.style(for: id).name, provider))
        }
        return out
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            // Cells are painted from token counts regardless of the
            // chart's metric — name the unit or a Cost/Quota pick reads
            // as if the grid switched units with it.
            Text("Daily activity · token intensity")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.secondary)
            ScrollView(.horizontal, showsIndicators: false) {
                Grid(alignment: .leading, horizontalSpacing: 2, verticalSpacing: 3) {
                    ForEach(rows, id: \.id) { row in
                        GridRow {
                            Text(row.label)
                                .font(.system(size: 9))
                                .foregroundStyle(row.provider.dataStatus == "available" ? .secondary : .tertiary)
                                .frame(width: 64, alignment: .trailing)
                                .lineLimit(1)
                            ForEach(Array(row.provider.cells.enumerated()), id: \.offset) { _, cell in
                                RoundedRectangle(cornerRadius: 1.5)
                                    .fill(Self.color(cell.color))
                                    .frame(width: 9, height: 9)
                                    .contentShape(Rectangle())
                                    .onTapGesture { onSelectDay?(cell.day, row.id) }
                                    .help(cell.accessibilityLabel + (onSelectDay == nil ? "" : " · click for that day's runs"))
                                    // Each cell is its own AX element
                                    // with the daemon's own day+value
                                    // label — the grid is data, not
                                    // decoration.
                                    .accessibilityElement()
                                    .accessibilityLabel("\(row.label): \(cell.accessibilityLabel)")
                                    .accessibilityAddTraits(onSelectDay == nil ? [] : .isButton)
                            }
                        }
                    }
                }
            }
            HStack(spacing: 4) {
                Text("Less").font(.system(size: 8)).foregroundStyle(.tertiary)
                ForEach(["#E5E7EB", "#DDD6FE", "#C4B5FD", "#A78BFA", "#7C3AED"], id: \.self) { hex in
                    RoundedRectangle(cornerRadius: 1.5).fill(Self.color(hex)).frame(width: 8, height: 8)
                }
                Text("More").font(.system(size: 8)).foregroundStyle(.tertiary)
                if !heatmap.timezone.isEmpty {
                    Text("· \(heatmap.timezone)").font(.system(size: 8)).foregroundStyle(.tertiary)
                }
            }
        }
    }

    private static func color(_ hex: String) -> Color {
        Color(nsColor: NSColor(hex: hex) ?? .clear)
    }
}

/// The Usage pane's detail column — the chart's facts rather than a
/// session inspector: the daemon's summary, what was asked for, what
/// it covered, and the per-provider totals the heatmap carries.
struct UsageGraphFacts: View {
    let store: OverviewStore

    private var document: CoreUsageGraphDocument? { store.graph }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                Text("About this chart")
                    .font(.system(size: 15, weight: .semibold))
                if let document {
                    let graph = UsageSourceReading.providerGraph(document.graph)
                    if !document.summary.isEmpty {
                        fact("Summary", document.summary)
                    }
                    fact("Range", graph.periodLabel.isEmpty ? "\(graph.days) days" : graph.periodLabel)
                    fact("Metric", metricName(graph.metric))
                    if !graph.providers.isEmpty {
                        fact("Providers", graph.providers
                            .map { ProviderStyle.style(for: $0).name }.joined(separator: ", "))
                    }
                    if let heatmap = graph.heatmap {
                        sectionTitle("Totals")
                        Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 4) {
                            ForEach(heatmap.providers.sorted(by: { $0.key < $1.key }), id: \.key) { id, provider in
                                GridRow {
                                    Text(ProviderStyle.style(for: id).name)
                                        .frame(width: 70, alignment: .trailing)
                                    Text("\(UsageFormat.tokens(provider.totals.tokens)) tokens · \(provider.totals.sessions) sessions")
                                        .foregroundStyle(.secondary)
                                        .lineLimit(2)
                                }
                            }
                            GridRow {
                                Text("All")
                                    .frame(width: 70, alignment: .trailing)
                                    .fontWeight(.medium)
                                Text("\(UsageFormat.tokens(heatmap.aggregate.totals.tokens)) tokens · \(heatmap.aggregate.totals.sessions) sessions")
                                    .fontWeight(.medium)
                            }
                        }
                        .font(.system(size: 10))
                        if !heatmap.timezone.isEmpty {
                            fact("Calendar", heatmap.timezone)
                        }
                    }
                    if graph.costSemantics == "api_equivalent_estimate" {
                        sectionTitle("Cost")
                        Text("API-equivalent estimate — transcript tokens priced at list rates. It is not subscription spend.")
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                    }
                    if !graph.partialProviderIds.isEmpty {
                        sectionTitle("Coverage")
                        Text("Partial local history: " + graph.partialProviderIds
                            .map { ProviderStyle.style(for: $0).name }.joined(separator: ", "))
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                    }
                    UsageIntegrationSourcesView(graph: document.graph)
                    sectionTitle("Source")
                    Text("On-disk transcripts (Claude, Codex, opencode, Gemini, T3) plus the session ledger. Nothing leaves the Mac.")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                } else if store.graphLoading {
                    Label("Scanning local activity…", systemImage: "chart.xyaxis.line")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                } else if let error = store.graphError {
                    Text(error)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                } else {
                    Text("Pick Usage in the sidebar to load the chart.")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(minWidth: 220)
    }

    private func fact(_ label: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label)
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(.tertiary)
            Text(value)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
        }
    }

    private func sectionTitle(_ title: String) -> some View {
        Text(title)
            .font(.system(size: 10, weight: .semibold))
            .foregroundStyle(.tertiary)
            .padding(.top, 4)
    }

    private func metricName(_ metric: String) -> String {
        switch metric {
        case "cost": return "Cost (API-equivalent estimate)"
        case "sessions": return "Sessions"
        case "percent": return "Remaining quota"
        default: return "Tokens"
        }
    }
}
