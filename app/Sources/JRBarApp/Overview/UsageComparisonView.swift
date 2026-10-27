import JRBarUI
import Foundation
import JRBarCore
import SwiftUI

struct UsageComparisonView: View {
    let graph: CoreUsageGraph
    let comparison: UsageComparison

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(graph.readingFiles > 0 ? comparison.title + " so far" : comparison.title)
                .font(.system(size: 12, weight: .medium)).foregroundStyle(.secondary)
            Text(comparison.total.map { UsageGraphView.valueLabel($0, metric: graph.metric) } ?? "No known amount")
                .font(.system(size: 28, weight: .semibold)).monospacedDigit()
            Text(graph.periodLabel.isEmpty ? "\(graph.days) days" : graph.periodLabel)
                .font(.system(size: 11)).foregroundStyle(.secondary)
            if graph.metric == "cost" {
                Text(graph.costCoverage.map { "Priced records: \($0.pricedRecords.formatted()) of \($0.observedRecords.formatted())" }
                     ?? "Pricing coverage unavailable")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
            }
            Text("Share of \(comparison.denominator)")
                .jrbarType(.caption).foregroundStyle(.tertiary)
            ForEach(comparison.providers) { provider in
                HStack(spacing: 10) {
                    Circle().fill(ProviderStyle.style(for: provider.id).accent).frame(width: 6, height: 6)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(ProviderStyle.style(for: provider.id).name).font(.system(size: 11, weight: .medium))
                        if provider.partial { Text("Partial history").jrbarType(.caption).foregroundStyle(.secondary) }
                    }.frame(width: 82, alignment: .leading)
                    Text(amountLabel(provider.amount)).font(.system(size: 11)).monospacedDigit()
                        .frame(width: 84, alignment: .trailing)
                    Text(provider.share.map { String(format: "%.1f%%", $0 * 100) } ?? "Unavailable")
                        .jrbarType(.caption).foregroundStyle(.secondary).monospacedDigit()
                        .frame(width: 66, alignment: .trailing)
                    GeometryReader { geometry in
                        if let share = provider.share {
                            Capsule().fill(ProviderStyle.style(for: provider.id).accent.opacity(0.75))
                                .frame(width: geometry.size.width * share, height: 5)
                        }
                    }.frame(minWidth: 20).frame(height: 5).accessibilityHidden(true)
                }
                .accessibilityElement(children: .combine)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func amountLabel(_ amount: UsageComparison.Amount) -> String {
        switch amount {
        case .known(let value): return UsageGraphView.valueLabel(value, metric: graph.metric)
        case .unpriced: return "Unpriced"
        case .missing: return "No local history"
        }
    }
}
