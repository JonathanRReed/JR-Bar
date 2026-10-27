import JRBarUI
import Foundation
import JRBarCore
import SwiftUI

/// Source readings never contribute a second copy to provider totals.
enum UsageSourceReading {
    nonisolated static func providerGraph(_ document: CoreUsageGraph) -> CoreUsageGraph {
        var graph = document
        graph.providers.removeAll { $0 == "t3code" }
        graph.partialProviderIds.removeAll { $0 == "t3code" }
        graph.series.removeAll { $0.providerId == "t3code" }
        if document.series.contains(where: { $0.providerId == "t3code" })
            || document.heatmap?.providers["t3code"] != nil {
            // Its aggregate may include unattributed imports. Keep the
            // original source totals below rather than relabel that aggregate.
            graph.heatmap = nil
        }
        return graph
    }

    nonisolated static func legacyAmount(_ graph: CoreUsageGraph) -> Double? {
        let rows = graph.series.filter { $0.providerId == "t3code" }
        let eligible = rows.filter { graph.metric != "cost" || $0.hasPricedUsage != false }
        let values = eligible.flatMap { Array($0.values.prefix(max(0, graph.days))) }
            .filter { $0.isFinite && $0 >= 0 }
        if graph.metric == "percent" { return nil }
        return values.isEmpty ? nil : values.reduce(0, +)
    }
}

struct UsageIntegrationSourcesView: View {
    let graph: CoreUsageGraph

    var body: some View {
        let sources = graph.sourceStatistics.filter { $0.sourceId == "t3code" }
        let legacy = graph.series.contains { $0.providerId == "t3code" }
            || graph.heatmap?.providers["t3code"] != nil
        if !sources.isEmpty || legacy {
            VStack(alignment: .leading, spacing: 6) {
                Text("From T3 Code").font(.system(size: 11, weight: .semibold))
                ForEach(Array(sources.enumerated()), id: \.offset) { _, source in
                    Text(observed(source)).monospacedDigit()
                    Text(included(source)).monospacedDigit()
                    if source.attributionStatus == "mixed" || source.attributionStatus == "unattributed" {
                        Text("Some imported activity has no proven provider. Those counts stay separate.")
                    }
                    if source.dataStatus != "available" {
                        Text(source.dataStatus == "partial" ? "Partial source history" : "Source reading unavailable")
                    }
                    if !source.detail.isEmpty { Text(source.detail) }
                }
                if legacy {
                    Text("Legacy imported reading. Provider identity is unavailable.")
                    if let imported = graph.heatmap?.providers["t3code"] {
                        Text("Imported source history: \(UsageFormat.tokens(imported.totals.tokens)) tokens · \(imported.totals.sessions.formatted()) \(imported.totals.sessions == 1 ? "session" : "sessions")")
                            .monospacedDigit()
                    }
                    if let amount = UsageSourceReading.legacyAmount(graph) {
                        Text("Imported \(metricName): \(UsageGraphView.valueLabel(amount, metric: graph.metric))")
                            .monospacedDigit()
                    } else if graph.metric == "percent" {
                        Text("Legacy percentage readings cannot be attributed to a provider quota.")
                    } else {
                        Text(graph.metric == "cost" ? "Imported cost is unpriced or unavailable." : "Imported reading unavailable.")
                    }
                }
                Text("Native provider history takes precedence. Source counts are shown separately and are not added again to the comparison.")
            }
            .jrbarType(.caption).foregroundStyle(.secondary)
            .padding(10).frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 8))
            .accessibilityElement(children: .combine)
            .textSelection(.enabled)
        }
    }

    private var metricName: String {
        switch graph.metric {
        case "cost": return "API-equivalent estimate"
        case "sessions": return "sessions"
        case "percent": return "last quota reading"
        default: return "tokens"
        }
    }

    private func threadCount(_ count: Int) -> String {
        count == 1 ? "1 thread" : "\(count.formatted()) threads"
    }

    private func observed(_ source: CoreUsageSourceStatistic) -> String {
        let tokens = source.tokens.map { "\(UsageFormat.tokens($0)) observed tokens" } ?? "Tokens unavailable"
        let threads = source.sessions.map(threadCount) ?? "Threads unavailable"
        return tokens + " · " + threads
    }

    private func included(_ source: CoreUsageSourceStatistic) -> String {
        let tokens = source.includedTokens.map { "\(UsageFormat.tokens($0)) tokens" } ?? "token contribution unavailable"
        let threads = source.includedSessions.map(threadCount) ?? "thread contribution unavailable"
        return "Included in provider history: " + tokens + " · " + threads
    }
}
