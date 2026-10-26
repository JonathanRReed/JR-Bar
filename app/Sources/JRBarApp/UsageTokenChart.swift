import Charts
import JRBarCore
import JRBarUI
import SwiftUI

/// Independent curves share a zero baseline. Monotone interpolation stays in each segment's bounds.
struct UsageTokenChart: View {
    let history: UsageHistory
    let range: UsageHistoryRange
    let accent: Color
    var metric: UsageCenterStore.Metric = .tokens
    @ViewState private var hidden: Set<String> = ["Cache reads"]
    @ViewState private var selected: Date?

    private var hourly: Bool { UsageChartPreparation.usesHours(history, range: range) }
    private var points: [UsagePoint] { UsageChartPreparation.points(history, range: range, metric: metric == .tokens ? .tokens : .cost) }
    private var visible: [UsagePoint] { points.filter { !hidden.contains($0.kind) } }
    private var axis: UsageChartAxis { UsageChartAxis(maximum: visible.map(\.value).max() ?? 0, minimumStep: metric == .tokens ? 1 : 0.01) }
    private func color(_ kind: String) -> Color {
        if history.stale { return JRBarTokens.Ink.stale }
        return switch kind {
        case "Output": JRBarTokens.Ink.live
        case "Cache reads": JRBarTokens.Ink.tertiary
        default: accent
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: JRBarTokens.Space.lg) {
            HStack(spacing: JRBarTokens.Space.xxl) {
                ForEach(metric == .tokens ? ["Input", "Output", "Cache reads"] : ["Cost"], id: \.self) { kind in
                    let total = points.filter { $0.kind == kind }.reduce(0) { $0 + $1.value }
                    Button {
                        if hidden.contains(kind) { hidden.remove(kind) } else { hidden.insert(kind) }
                    } label: {
                        VStack(alignment: .leading, spacing: JRBarTokens.Space.xs) {
                            Label(kind, systemImage: hidden.contains(kind) ? "circle" : "circle.fill")
                                .font(JRBarTokens.TypeStyle.caption.font)
                            Text(formatted(total)).font(JRBarTokens.TypeStyle.heading.font)
                                .monospacedDigit()
                        }.foregroundStyle(hidden.contains(kind) ? JRBarTokens.Ink.stale : color(kind))
                    }
                    .buttonStyle(.plain)
                    .accessibilityValue(hidden.contains(kind) ? "Hidden" : "Shown")
                    .help("Show or hide \(kind.lowercased())")
                }
                Spacer(minLength: 0)
            }
            Chart {
                ForEach(visible) { point in
                    AreaMark(x: .value("Date", point.date), y: .value("Tokens", max(0, point.value)),
                             stacking: .unstacked)
                        .foregroundStyle(by: .value("Kind", point.kind))
                        .opacity(0.08).interpolationMethod(.monotone)
                    LineMark(x: .value("Date", point.date), y: .value("Tokens", max(0, point.value)))
                        .foregroundStyle(by: .value("Kind", point.kind)).interpolationMethod(.monotone)
                }
                ForEach(singletons) { point in
                    PointMark(x: .value("Date", point.date), y: .value("Tokens", max(0, point.value)))
                        .foregroundStyle(color(point.kind))
                }
                if let date = nearestSelection {
                    RuleMark(x: .value("Selected", date)).foregroundStyle(JRBarTokens.Ink.tertiary)
                }
            }
            .chartYScale(domain: 0...axis.maximum)
            .chartYAxis {
                AxisMarks(position: .leading, values: axis.ticks) { value in
                    AxisGridLine().foregroundStyle(JRBarTokens.Ink.separator)
                    AxisValueLabel {
                        if let number = value.as(Double.self) { Text(formatted(number)) }
                    }.font(JRBarTokens.TypeStyle.caption.font)
                }
            }
            .chartXAxis { AxisMarks(values: .automatic(desiredCount: 5)) { _ in
                AxisValueLabel(format: hourly ? .dateTime.weekday(.abbreviated).hour() : .dateTime.month(.abbreviated).day())
                    .font(JRBarTokens.TypeStyle.caption.font)
            } }
            .chartForegroundStyleScale(domain: ["Input", "Output", "Cache reads", "Cost"],
                                       range: [color("Input"), color("Output"), color("Cache reads"), color("Cost")])
            .chartLegend(.hidden)
            .chartXSelection(value: $selected)
            .chartOverlay { proxy in
                GeometryReader { geometry in
                    if let date = nearestSelection, let frame = proxy.plotFrame,
                       let x = proxy.position(forX: date) {
                        let plot = geometry[frame]
                        let width = min(200.0, plot.width)
                        let center = UsageChartAxis.tooltipCenter(x: plot.minX + x, width: width,
                                                                 bounds: plot.minX...plot.maxX)
                        VStack(alignment: .leading, spacing: JRBarTokens.Space.xs) {
                            Text(date.formatted(date: .abbreviated, time: hourly ? .shortened : .omitted))
                                .font(JRBarTokens.TypeStyle.headline.font)
                            ForEach(visible.filter { $0.date == date }) { point in
                                HStack {
                                    Text(point.kind)
                                    Spacer()
                                    Text(formatted(point.value)).monospacedDigit()
                                }.foregroundStyle(color(point.kind))
                            }
                        }
                        .font(JRBarTokens.TypeStyle.caption.font)
                        .padding(JRBarTokens.Space.sm)
                        .frame(width: width)
                        .background(JRBarTokens.Ink.content, in: RoundedRectangle(cornerRadius: JRBarTokens.Radius.control))
                        .overlay(RoundedRectangle(cornerRadius: JRBarTokens.Radius.control).strokeBorder(JRBarTokens.Ink.separator))
                        .position(x: center, y: plot.minY + 52)
                        .allowsHitTesting(false)
                    }
                }
            }
            .chartPlotStyle { $0.clipped() }
            .frame(height: 220)
            .accessibilityLabel("Tokens over \(range.days) days")
        }
    }

    func proofSelection(_ date: Date?, cacheVisible: Bool = false) -> Self {
        var copy = self
        copy._selected = ViewState(initialValue: date)
        copy._hidden = ViewState(initialValue: cacheVisible ? [] : ["Cache reads"])
        return copy
    }

    private func formatted(_ value: Double) -> String {
        metric == .tokens ? UsageFormat.tokens(Int(value)) : UsageFormat.cost(value, currency: history.pricing?.currency ?? "USD")
    }

    private var singletons: [UsagePoint] {
        Dictionary(grouping: visible, by: \.kind).values.filter { $0.count == 1 }.compactMap(\.first)
    }

    private var nearestSelection: Date? {
        guard let selected else { return nil }
        return visible.min { abs($0.date.timeIntervalSince(selected)) < abs($1.date.timeIntervalSince(selected)) }?.date
    }
}

struct UsageChartAxis: Equatable {
    let step: Double
    let maximum: Double
    var ticks: [Double] { stride(from: 0, through: maximum, by: step).map { $0 } }

    init(maximum observed: Double, minimumStep: Double = 1) {
        let safe = observed.isFinite ? max(minimumStep, observed) : minimumStep
        let rough = safe / 4
        let magnitude = pow(10, floor(log10(rough)))
        let normalized = rough / magnitude
        let factor = normalized <= 1 ? 1.0 : normalized <= 2 ? 2 : normalized <= 5 ? 5 : 10
        step = max(minimumStep, factor * magnitude)
        maximum = ceil(safe / step) * step
    }

    static func tooltipCenter(x: Double, width: Double, bounds: ClosedRange<Double>) -> Double {
        let half = min(width, bounds.upperBound - bounds.lowerBound) / 2
        return min(bounds.upperBound - half, max(bounds.lowerBound + half, x))
    }
}
