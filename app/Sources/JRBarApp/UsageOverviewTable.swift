import Charts
import JRBarCore
import JRBarUI
import SwiftUI

struct UsageOverviewTable: View {
    @Bindable var store: UsageCenterStore
    let showCost: Bool
    let select: (String) -> Void
    private var windows: [String] { UsageGaugeRow.orderedWindowNames(store.providers.flatMap { $0.windows.map(\.name) }) }
    private var quotaWidth: CGFloat { max(360, 200 + CGFloat(windows.count) * (UsageGaugeRow.columnWidth + JRBarTokens.Space.sm)) }

    var body: some View {
        VStack(alignment: .leading, spacing: JRBarTokens.Space.xl) {
            Text("Overview").font(JRBarTokens.TypeStyle.title1.font)
            ScrollView(.horizontal) {
                Grid(alignment: .leading, horizontalSpacing: JRBarTokens.Space.lg, verticalSpacing: JRBarTokens.Space.lg) {
                    GridRow {
                        HStack {
                            Text("Provider")
                            UsageGaugeHeader(windowNames: windows)
                        }.frame(width: quotaWidth)
                        Text("Today's tokens incl. cache reads")
                        if showCost { Text("Estimated cost") }
                    }.font(JRBarTokens.TypeStyle.section.font).foregroundStyle(JRBarTokens.Ink.secondary)
                    Divider().gridCellUnsizedAxes(.horizontal)
                    ForEach(store.providers, id: \.identity) { provider in
                        GridRow {
                            Button { select(provider.identity) } label: {
                                UsageGaugeRow(provider: provider, name: store.providerTitle(provider),
                                    now: store.now.timeIntervalSince1970, connected: store.isLive, style: .compact,
                                    windowNames: windows, snapshotReceivedAt: store.usageSnapshotReceivedAt,
                                    suppressDisconnectedStatus: true)
                                    .frame(width: quotaWidth)
                            }.buttonStyle(.plain)
                            let today = today(for: provider)
                            Text(today.map { UsageFormat.tokens($0.totalTokens) } ?? "—").monospacedDigit()
                            if showCost { Text(today.map(Self.costLabel) ?? "—").monospacedDigit() }
                        }
                    }
                }
            }.fixedSize(horizontal: false, vertical: true)
            if store.providers.isEmpty { Text("No provider readings yet").foregroundStyle(JRBarTokens.Ink.secondary) }
            Divider()
            Text("30-day tokens incl. cache reads").font(JRBarTokens.TypeStyle.heading.font)
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
                    }.buttonStyle(.plain).accessibilityValue(hidden.contains(provider) ? "Hidden" : "Shown")
                }
            }
            ForEach(providers.filter { stale($0) }, id: \.self) { provider in
                Text(ProviderPalette.displayName(for: provider) + " · " + (states[provider] ?? "unknown").replacingOccurrences(of: "_", with: " ") + ". Showing last totals.")
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
