import Charts
import JRBarCore
import SwiftUI

/// Calendar identity belongs to the loaded document, even when its
/// aggregate cannot safely be displayed as provider activity.
struct UsageChartCalendar: Equatable {
    let days: [String]
    let labels: [String]

    nonisolated init(_ graph: CoreUsageGraph) {
        days = graph.heatmap?.days ?? []
        labels = graph.labels
    }

    func label(_ index: Int) -> String {
        if index >= 0, index < days.count { return days[index] }
        if index >= 0, index < labels.count, !labels[index].isEmpty { return labels[index] }
        return "Day \(index + 1)"
    }

    func drilldownDay(_ index: Int) -> String? {
        guard index >= 0, index < days.count, HistoryDayParse.date(days[index]) != nil else { return nil }
        return days[index]
    }
}

/// Daily recorded amounts. Missing portions stay missing in the readout.
struct UsageCompositionView: View {
    let graph: CoreUsageGraph
    let comparison: UsageComparison
    let calendar: UsageChartCalendar
    var onSelectDay: (String) -> Void
    @ViewState private var selectedDay: Int?

    private var day: UsageComparison.Day? {
        comparison.days.first { $0.id == selectedDay } ?? comparison.days.last
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Daily provider composition").font(.system(size: 11, weight: .medium)).foregroundStyle(.secondary)
            Chart {
                ForEach(comparison.days) { day in
                    ForEach(day.portions) { portion in
                        BarMark(x: .value("Day", day.id), yStart: .value("Amount", portion.lower),
                                yEnd: .value("Amount", portion.upper))
                            .foregroundStyle(ProviderStyle.style(for: portion.provider).accent)
                            .accessibilityLabel("\(label(day.id)), \(ProviderStyle.style(for: portion.provider).name)")
                            .accessibilityValue(UsageGraphView.valueLabel(portion.value, metric: graph.metric))
                    }
                    if day.incomplete {
                        PointMark(x: .value("Day", day.id), y: .value("Known total", day.total))
                            .symbol(.triangle).symbolSize(18).foregroundStyle(.secondary)
                            .accessibilityLabel("\(label(day.id)), incomplete coverage")
                    }
                }
                if let day {
                    RuleMark(x: .value("Day", day.id)).foregroundStyle(.secondary.opacity(0.3))
                }
            }
            .chartXScale(domain: UsageGraphView.xDomain(days: graph.days))
            .chartYScale(domain: 0...max(1, comparison.days.map(\.total).max() ?? 0))
            .chartYAxis {
                AxisMarks(position: .leading, values: .automatic(desiredCount: 4)) { value in
                    AxisGridLine()
                    AxisValueLabel {
                        if let number = value.as(Double.self),
                           let text = UsageGraphView.axisLabel(number, metric: graph.metric) {
                            Text(text).font(.system(size: 9))
                        }
                    }
                }
            }
            .chartXAxis {
                AxisMarks(values: Array(graph.labels.indices)) { value in
                    if let index = value.as(Int.self), index < graph.labels.count, !graph.labels[index].isEmpty {
                        AxisValueLabel { Text(graph.labels[index]).font(.system(size: 9)) }
                    }
                }
            }
            .chartOverlay { proxy in
                GeometryReader { geometry in
                    Rectangle().fill(.clear).contentShape(Rectangle())
                        .onContinuousHover { phase in
                            if case .active(let location) = phase, let frame = proxy.plotFrame,
                               geometry[frame].contains(location) {
                                let x = location.x - geometry[frame].origin.x
                                selectedDay = UsageGraphView.selectedDay(proxy.value(atX: x, as: Double.self), days: graph.days)
                            }
                        }
                }
            }
            .frame(height: 220)
            if let day {
                HStack {
                    Picker("Day", selection: Binding(get: { day.id }, set: { selectedDay = $0 })) {
                        ForEach(comparison.days) { item in Text(label(item.id)).tag(item.id) }
                    }
                    .frame(maxWidth: 220)
                    if calendar.drilldownDay(day.id) != nil {
                        Button("Show runs") { showRuns(day.id) }.controlSize(.small)
                    }
                    Spacer(minLength: 0)
                }
                Text(day.portions.isEmpty ? "No known amount for this day"
                     : "Known total: \(UsageGraphView.valueLabel(day.total, metric: graph.metric))")
                    .font(.system(size: 11, weight: .medium)).monospacedDigit()
                ForEach(day.portions) { portion in
                    Text("\(ProviderStyle.style(for: portion.provider).name): \(UsageGraphView.valueLabel(portion.value, metric: graph.metric))")
                        .font(.system(size: 10)).foregroundStyle(.secondary).monospacedDigit()
                }
                if !day.missing.isEmpty { disclosure("Missing", providers: day.missing) }
                if !day.unpriced.isEmpty { disclosure("Unpriced", providers: day.unpriced) }
                if day.incomplete {
                    Text("Daily coverage incomplete. Missing and unpriced usage is excluded.")
                        .font(.system(size: 10)).foregroundStyle(.secondary)
                }
            }
        }
        .onChange(of: graph) { selectedDay = nil }
        .onChange(of: calendar) { selectedDay = nil }
    }

    func showRuns(_ index: Int) {
        guard let iso = calendar.drilldownDay(index) else { return }
        onSelectDay(iso)
    }

    private func label(_ index: Int) -> String { calendar.label(index) }

    private func disclosure(_ word: String, providers: [String]) -> some View {
        Text(word + ": " + providers.map { ProviderStyle.style(for: $0).name }.joined(separator: ", "))
            .font(.system(size: 10)).foregroundStyle(.secondary)
    }
}
