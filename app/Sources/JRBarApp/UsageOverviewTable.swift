import AppKit
import Charts
import JRBarCore
import JRBarUI
import SwiftUI

struct UsageOverviewTable: View {
    @Bindable var store: UsageCenterStore
    let showCost: Bool
    let select: (String) -> Void
    private var windows: [String] {
        Self.windowNames(providers: store.providers, now: store.now.timeIntervalSince1970, connected: store.isLive)
    }

    static func windowNames(providers: [CoreProviderUsage], now: Double, connected: Bool) -> [String] {
        UsageGaugeRow.compactWindowNames(providers: providers, now: now, connected: connected)
    }

    var body: some View {
        let columnWidth = UsageOverviewHeader.columnWidth(for: windows)
        let quotaWidth = max(360, 200 + CGFloat(windows.count) * (columnWidth + 10))
        return VStack(alignment: .leading, spacing: JRBarTokens.Space.xl) {
            Text("Overview").font(JRBarTokens.TypeStyle.title1.font)
            if let tightest = tightestLine { Text(tightest).font(JRBarTokens.TypeStyle.callout.font) }
            if let totals = quotaTotalsLine { Text(totals).font(JRBarTokens.TypeStyle.callout.font).foregroundStyle(JRBarTokens.Ink.secondary) }
            ScrollView(.horizontal) {
                Grid(alignment: .leading, horizontalSpacing: JRBarTokens.Space.lg, verticalSpacing: JRBarTokens.Space.lg) {
                    GridRow {
                        HStack {
                            Text("Provider")
                            UsageOverviewHeader(windowNames: windows)
                        }.frame(width: quotaWidth)
                        Text("Today's tokens incl. cache reads")
                        if showCost { Text("Estimated cost") }
                    }.font(JRBarTokens.TypeStyle.section.font).foregroundStyle(JRBarTokens.Ink.secondary)
                    Divider().gridCellUnsizedAxes(.horizontal)
                    ForEach(store.providers, id: \.identity) { provider in
                        GridRow {
                            let today = today(for: provider)
                            UsageOverviewProviderRow(provider: provider, name: store.providerTitle(provider),
                                now: store.now.timeIntervalSince1970, connected: store.isLive,
                                windowNames: windows, columnWidth: columnWidth,
                                snapshotReceivedAt: store.usageSnapshotReceivedAt, today: today, showCost: showCost) { select(provider.identity) }
                                .frame(width: quotaWidth)
                            Text(today.map { UsageFormat.tokens($0.totalTokens) } ?? "—").monospacedDigit()
                            if showCost { Text(today.map(Self.costLabel) ?? "—").monospacedDigit() }
                        }
                    }
                }
            }.fixedSize(horizontal: false, vertical: true)
            if store.providers.isEmpty { Text("No provider readings yet").foregroundStyle(JRBarTokens.Ink.secondary) }
            Divider()
            SectionHeader("30-day tokens incl. cache reads")
            if store.tokenHistoryOff {
                StatusBanner("Token history is off") { Button("Turn on") { store.enableTokenHistory() } }
            } else if let graph = store.overviewGraph {
                if graph.series.isEmpty { Text("No token history yet").foregroundStyle(JRBarTokens.Ink.secondary) }
                else { UsageOverviewChart(graph: graph, states: historyStates, cache: store.chartCache) }
                if !graph.partialProviderIds.isEmpty || graph.readingFiles > 0 {
                    Text("Scanning local history. Showing records read so far.")
                        .font(JRBarTokens.TypeStyle.caption.font).foregroundStyle(JRBarTokens.Ink.secondary)
                }
                if let error = store.overviewGraphError { StatusBanner("Chart is stale", detail: error) }
            } else if let error = store.overviewGraphError {
                StatusBanner("Token history unavailable", detail: error) { Button("Retry") { store.loadOverviewGraph() } }
            } else {
                Text("Reading local token history…").foregroundStyle(JRBarTokens.Ink.secondary)
            }
        }
    }

    var tightestLine: String? {
        let candidates = store.providers.filter { $0.quotaSource && !$0.usageIsOff && !$0.isSignedOut }.flatMap { provider in
            provider.windows.filter { $0.bindable && !$0.detail && $0.usedPct != nil && !$0.elapsed && ($0.resetsAt ?? .infinity) > store.now.timeIntervalSince1970 }
                .map { (provider, $0) }
        }
        guard let (provider, window) = candidates.max(by: { ($0.1.usedPct ?? 0) < ($1.1.usedPct ?? 0) }) else { return nil }
        let stale = !store.isLive || provider.isStale ? " · last reading" : ""
        return "Tightest: \(store.providerTitle(provider)) \(window.longName) \(window.percentText) used\(stale)"
    }

    var quotaTotalsLine: String? {
        let tokens = store.providers.reduce(0) { $0 + ($1.tokens?.total ?? 0) }
        let cost = store.providers.reduce(0.0) { $0 + ($1.estimatedCostUSD ?? 0) }
        var parts: [String] = []
        if tokens > 0 { parts.append("\(UsageFormat.tokens(tokens)) tokens") }
        if showCost, cost > 0 { parts.append("≈ \(UsageFormat.cost(cost)) estimated") }
        return parts.isEmpty ? nil : parts.joined(separator: " · ") + " across providers at last readings"
    }

    static func costLabel(_ day: UsageHistoryDay) -> String {
        day.totalTokens > 0 && day.costUsd <= 0 ? "No price" : UsageFormat.cost(day.costUsd, currency: "USD")
    }

    private var historyStates: [String: String] {
        Dictionary(grouping: store.providers, by: \.id).mapValues { providers in
            guard store.isLive else { return "stale" }
            if let stale = providers.first(where: { !["ready", "building"].contains($0.tokenHistoryState ?? "unknown") }) {
                return stale.tokenHistoryState ?? "unknown"
            }
            return providers.first?.tokenHistoryState ?? "unknown"
        }
    }

    private func today(for provider: CoreProviderUsage) -> UsageHistoryDay? {
        guard !store.tokenHistoryOff, store.ownsLocalHistory(provider) else { return nil }
        let components = Calendar.current.dateComponents([.year, .month, .day], from: store.now)
        let date = String(format: "%04d-%02d-%02d", components.year ?? 0, components.month ?? 0, components.day ?? 0)
        return store.history(for: provider)?.days.first { $0.date == date }
    }
}

/// Overview includes token history even when a provider has no current quota source.
struct UsageOverviewProviderRow: View {
    let provider: CoreProviderUsage
    let name: String
    let now: Double
    let connected: Bool
    let windowNames: [String]
    let columnWidth: CGFloat
    let snapshotReceivedAt: Double?
    var today: UsageHistoryDay? = nil
    var showCost = false
    let select: () -> Void

    var spokenValue: String {
        var parts = [UsageGaugeRow(provider: provider, name: name, now: now, connected: connected,
            snapshotReceivedAt: snapshotReceivedAt, suppressDisconnectedStatus: true, includeAbsent: true).accessibilityValue]
        if let today {
            parts.append("Today's tokens including cache reads: \(today.totalTokens)")
            if showCost { parts.append("Estimated cost: \(UsageOverviewTable.costLabel(today))") }
        } else {
            parts.append("Today's tokens unavailable")
        }
        return parts.joined(separator: ". ")
    }

    var body: some View {
        Button(action: select) {
            UsageGaugeRow(provider: provider, name: name, now: now, connected: connected, style: .compact,
                windowNames: windowNames, snapshotReceivedAt: snapshotReceivedAt,
                suppressDisconnectedStatus: true, compactColumnWidth: columnWidth, includeAbsent: true)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(name)
        .accessibilityValue(spokenValue)
        .accessibilityHint("Show provider usage")
    }
}

struct UsageOverviewHeader: View {
    let windowNames: [String]

    static func titleLines(for name: String) -> [String] {
        let title = "\(UsageWindowLabel.column(name)) used"
        let words = title.split(separator: " ")
        guard words.count > 1 else { return [title] }
        return (1..<words.count).map { cut in
            [words[..<cut].joined(separator: " "), words[cut...].joined(separator: " ")]
        }.min { width(of: $0) < width(of: $1) } ?? [title]
    }

    private static func width(of lines: [String]) -> CGFloat {
        let font = NSFont.systemFont(ofSize: JRBarTokens.TypeStyle.caption.size)
        return lines.map { ($0 as NSString).size(withAttributes: [.font: font]).width }.max() ?? 0
    }

    static func columnWidth(for names: [String]) -> CGFloat {
        max(UsageGaugeRow.columnWidth, ceil(names.map { width(of: titleLines(for: $0)) }.max() ?? 0))
    }

    var body: some View {
        let columnWidth = Self.columnWidth(for: windowNames)
        return HStack(spacing: 10) {
            Spacer(minLength: 0)
            ForEach(windowNames, id: \.self) { name in
                Text(Self.titleLines(for: name).joined(separator: "\n")).font(JRBarTokens.TypeStyle.caption.font)
                    .foregroundStyle(JRBarTokens.Ink.secondary)
                    .multilineTextAlignment(.trailing)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(width: columnWidth, alignment: .trailing)
                    .help("\(name) used")
                    .accessibilityLabel("\(name) used")
            }
        }
        .padding(.horizontal, JRBarTokens.Space.md)
        .padding(.bottom, JRBarTokens.Space.xs)
    }
}

struct UsageOverviewChart: View {
    let graph: CoreUsageGraph
    @ViewState private var hidden: Set<String> = []
    @ViewState private var selected: Int?
    var states: [String: String] = [:]
    var cache = UsageChartCache()

    private func stale(_ provider: String) -> Bool { !["ready", "building"].contains(states[provider] ?? "unknown") }
    private func color(_ provider: String, index: Int) -> Color {
        stale(provider) ? JRBarTokens.Ink.stale.opacity(max(0.4, 1 - Double(index) * 0.12)) : ProviderPalette.color(for: provider)
    }

    var body: some View {
        let data = cache.overview(graph, hidden: hidden)
        let points = data.points
        let axis = data.axis
        let providers = data.providers
        let runs = data.runs
        return VStack(alignment: .leading, spacing: JRBarTokens.Space.lg) {
            HStack(spacing: JRBarTokens.Space.lg) {
                ForEach(providers, id: \.self) { provider in
                    let total = data.totals[provider] ?? 0
                    Button {
                        if hidden.contains(provider) { hidden.remove(provider) } else { hidden.insert(provider) }
                    } label: {
                        VStack(alignment: .leading, spacing: JRBarTokens.Space.xs) {
                            Text(ProviderPalette.displayName(for: provider)).font(JRBarTokens.TypeStyle.caption.font)
                            Text(UsageFormat.tokens(Int(total))).font(JRBarTokens.TypeStyle.heading.font).monospacedDigit()
                        }.foregroundStyle(hidden.contains(provider) ? JRBarTokens.Ink.stale : color(provider, index: providers.firstIndex(of: provider) ?? 0))
                    }.buttonStyle(.plain)
                    .accessibilityLabel("\(ProviderPalette.displayName(for: provider)), \(Int(total)) tokens")
                    .accessibilityValue(hidden.contains(provider) ? "Hidden" : "Shown")
                }
            }
            ForEach(providers.filter { stale($0) }, id: \.self) { provider in
                Text(ProviderPalette.displayName(for: provider) + " · " + TokenHistoryWords.title(states[provider]) + ". Showing last totals.")
                    .font(JRBarTokens.TypeStyle.caption.font).foregroundStyle(JRBarTokens.Ink.stale).lineLimit(1)
            }
            Chart {
                ForEach(points, id: \.self) { point in
                    AreaMark(x: .value("Day", point.day), y: .value("Tokens", point.value), stacking: .unstacked)
                        .foregroundStyle(by: .value("Run", point.seriesId)).opacity(0.08).interpolationMethod(.monotone)
                    let index = providers.firstIndex(of: point.providerId) ?? 0
                    LineMark(x: .value("Day", point.day), y: .value("Tokens", point.value), series: .value("Run", point.seriesId))
                        .interpolationMethod(.monotone).foregroundStyle(color(point.providerId, index: index))
                        .lineStyle(StrokeStyle(lineWidth: 2, dash: stale(point.providerId) ? [CGFloat(index + 2), 3] : []))
                }
                if let selected { RuleMark(x: .value("Selected", selected)).foregroundStyle(JRBarTokens.Ink.tertiary) }
            }
            .chartForegroundStyleScale(domain: runs, range: data.colors.map { color($0, index: providers.firstIndex(of: $0) ?? 0) })
            .chartLegend(.hidden)
            .chartYScale(domain: 0...axis.maximum)
            .chartXSelection(value: $selected)
            .chartYAxis { AxisMarks(position: .leading, values: axis.ticks) { value in
                AxisGridLine().foregroundStyle(JRBarTokens.Ink.separator)
                AxisValueLabel { if let number = value.as(Double.self) { Text(UsageFormat.tokens(Int(number))) } }
                    .font(JRBarTokens.TypeStyle.caption.font)
            } }
            .chartXAxis { AxisMarks(values: .automatic(desiredCount: 5)) { value in
                AxisValueLabel {
                    if let day = value.as(Int.self), graph.labels.indices.contains(day) { Text(graph.labels[day]) }
                }.font(JRBarTokens.TypeStyle.caption.font)
            } }
            .chartOverlay { proxy in
                GeometryReader { geometry in
                    if let selected, let frame = proxy.plotFrame, let x = proxy.position(forX: selected) {
                        let plot = geometry[frame]
                        let width = min(200.0, plot.width)
                        let center = UsageChartAxis.tooltipCenter(x: plot.minX + x, width: width, bounds: plot.minX...plot.maxX)
                        VStack(alignment: .leading, spacing: JRBarTokens.Space.xs) {
                            if graph.labels.indices.contains(selected) { Text(graph.labels[selected]).fontWeight(.semibold) }
                            ForEach(providers.filter { !hidden.contains($0) }, id: \.self) { provider in
                                if let value = data.byDay[selected]?.first(where: { $0.providerId == provider })?.value {
                                    Text(ProviderPalette.displayName(for: provider) + " · " + UsageFormat.tokens(Int(value)))
                                }
                            }
                        }.font(JRBarTokens.TypeStyle.caption.font).padding(JRBarTokens.Space.sm).frame(width: width)
                            .background(JRBarTokens.Ink.content, in: RoundedRectangle(cornerRadius: JRBarTokens.Radius.control))
                            .position(x: center, y: plot.minY + 64).allowsHitTesting(false)
                    }
                }
            }
            .frame(height: 220)
            .accessibilityLabel("Tokens including cache reads over 30 days")
            .chartPlotStyle { $0.clipped() }
        }
    }
}
