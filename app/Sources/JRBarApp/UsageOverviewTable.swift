import Charts
import JRBarCore
import JRBarUI
import SwiftUI

struct UsageOverviewTable: View {
    @Bindable var store: UsageCenterStore
    let showCost: Bool
    let select: (String) -> Void
    private var windows: [String] { UsageGaugeRow.orderedWindowNames(store.providers.flatMap { $0.windows.map(\.name) }) }

    var body: some View {
        VStack(alignment: .leading, spacing: JRBarTokens.Space.xl) {
            Text("Overview").font(JRBarTokens.TypeStyle.title1.font)
            ScrollView(.horizontal) {
                Grid(alignment: .leading, horizontalSpacing: JRBarTokens.Space.lg, verticalSpacing: JRBarTokens.Space.lg) {
                    GridRow {
                        Text("Provider")
                        ForEach(windows, id: \.self) { Text($0) }
                        Text("Today's tokens")
                        if showCost { Text("Estimated cost") }
                    }.font(JRBarTokens.TypeStyle.section.font).foregroundStyle(JRBarTokens.Ink.secondary)
                    Divider().gridCellUnsizedAxes(.horizontal)
                    ForEach(store.providers, id: \.identity) { provider in
                        GridRow {
                            Button { select(provider.identity) } label: {
                                HStack(spacing: JRBarTokens.Space.sm) {
                                    ProviderLogoTile(provider: provider.id)
                                    Text(store.providerTitle(provider))
                                }
                            }.buttonStyle(.plain)
                            ForEach(windows, id: \.self) { name in
                                if let window = provider.windows.first(where: { $0.name == name }) {
                                    let reading = UsageGaugeReading(window: window, provider: provider,
                                        now: store.now.timeIntervalSince1970, connected: store.isLive)
                                    VStack(alignment: .leading, spacing: JRBarTokens.Space.xs) {
                                        Text(reading.percentUsed.map { "\(Int($0.rounded()))%" } ?? "—")
                                            .monospacedDigit().foregroundStyle(reading.stale ? JRBarTokens.Ink.stale : JRBarTokens.Ink.label)
                                        JRBarGauge(value: reading.percentUsed, tint: ProviderPalette.color(for: provider.id),
                                            stale: reading.stale, height: 6, pace: store.quotaPace(for: provider)[window.name])
                                        Text(reading.footnote).font(JRBarTokens.TypeStyle.caption.font)
                                            .foregroundStyle(JRBarTokens.Ink.secondary)
                                    }.frame(minWidth: 56)
                                } else { Text("—").foregroundStyle(JRBarTokens.Ink.secondary) }
                            }
                            let today = today(for: provider)
                            Text(today.map { UsageFormat.tokens($0.totalTokens) } ?? "—").monospacedDigit()
                            if showCost { Text(today.map { UsageFormat.cost($0.costUsd, currency: "USD") } ?? "—").monospacedDigit() }
                        }
                    }
                }
            }.fixedSize(horizontal: false, vertical: true)
            if store.providers.isEmpty { Text("No provider readings yet").foregroundStyle(JRBarTokens.Ink.secondary) }
            Divider()
            Text("30-day token history").font(JRBarTokens.TypeStyle.heading.font)
            if store.tokenHistoryOff {
                StatusBanner("Token history is off") { Button("Turn on") { store.enableTokenHistory() } }
            } else if let graph = store.overviewGraph {
                if graph.series.isEmpty { Text("No token history yet").foregroundStyle(JRBarTokens.Ink.secondary) }
                else { UsageOverviewChart(graph: graph) }
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

    private func today(for provider: CoreProviderUsage) -> UsageHistoryDay? {
        guard !store.tokenHistoryOff, store.ownsLocalHistory(provider) else { return nil }
        return store.history(for: provider)?.days.first { day in
            day.day.map { Calendar.current.isDate($0, inSameDayAs: store.now) } ?? false
        }
    }
}

struct UsageOverviewChart: View {
    let graph: CoreUsageGraph
    @ViewState private var hidden: Set<String> = []
    @ViewState private var selected: Int?
    private var points: [UsageGraphView.Point] { UsageGraphView.splitPoints(graph).filter { !hidden.contains($0.providerId) } }
    private var axis: UsageChartAxis { UsageChartAxis(maximum: points.map(\.value).max() ?? 0) }
    private var providers: [String] { Array(Set(graph.series.map(\.providerId))).sorted() }
    private var runs: [String] { Array(Set(points.map(\.seriesId))).sorted() }

    var body: some View {
        VStack(alignment: .leading, spacing: JRBarTokens.Space.lg) {
            HStack(spacing: JRBarTokens.Space.lg) {
                ForEach(providers, id: \.self) { provider in
                    let total = graph.series.filter { $0.providerId == provider }.flatMap(\.values).filter { $0 >= 0 }.reduce(0, +)
                    Button {
                        if hidden.contains(provider) { hidden.remove(provider) } else { hidden.insert(provider) }
                    } label: {
                        VStack(alignment: .leading, spacing: JRBarTokens.Space.xs) {
                            Text(ProviderPalette.displayName(for: provider)).font(JRBarTokens.TypeStyle.caption.font)
                            Text(UsageFormat.tokens(Int(total))).font(JRBarTokens.TypeStyle.heading.font).monospacedDigit()
                        }.foregroundStyle(hidden.contains(provider) ? JRBarTokens.Ink.stale : ProviderPalette.color(for: provider))
                    }.buttonStyle(.plain).accessibilityValue(hidden.contains(provider) ? "Hidden" : "Shown")
                }
            }
            Chart {
                ForEach(points, id: \.self) { point in
                    AreaMark(x: .value("Day", point.day), y: .value("Tokens", point.value), stacking: .unstacked)
                        .foregroundStyle(by: .value("Run", point.seriesId)).opacity(0.08).interpolationMethod(.monotone)
                    LineMark(x: .value("Day", point.day), y: .value("Tokens", point.value), series: .value("Run", point.seriesId))
                        .interpolationMethod(.monotone).foregroundStyle(ProviderPalette.color(for: point.providerId))
                }
                if let selected { RuleMark(x: .value("Selected", selected)).foregroundStyle(JRBarTokens.Ink.tertiary) }
            }
            .chartForegroundStyleScale(domain: runs, range: runs.map { run in ProviderPalette.color(for: points.first { $0.seriesId == run }?.providerId ?? "") })
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
                                if let value = points.first(where: { $0.day == selected && $0.providerId == provider })?.value {
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
            .chartPlotStyle { $0.clipped() }
        }
    }
}
