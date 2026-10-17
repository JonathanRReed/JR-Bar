import Foundation
import JRBarCore

/// Recorded amounts from one loaded chart. Quota readings cannot be added.
struct UsageComparison: Equatable {
    enum Amount: Equatable {
        case known(Double), unpriced, missing
        var value: Double? {
            if case .known(let value) = self { return value }
            return nil
        }
    }

    struct Provider: Identifiable, Equatable {
        let id: String
        let amount: Amount
        let share: Double?
        let partial: Bool
    }

    struct Portion: Identifiable, Equatable {
        let provider: String
        let lower: Double
        let upper: Double
        var id: String { provider }
        var value: Double { upper - lower }
    }

    struct Day: Identifiable, Equatable {
        let id: Int
        let portions: [Portion]
        let missing: [String]
        let unpriced: [String]
        var total: Double { portions.last?.upper ?? 0 }
        var incomplete: Bool { !missing.isEmpty || !unpriced.isEmpty }
    }

    let metric: String
    let providers: [Provider]
    let days: [Day]
    let total: Double?
    var denominator: String {
        switch metric {
        case "cost": return "known estimate"
        case "sessions": return "recorded sessions"
        default: return "recorded tokens"
        }
    }
    var title: String {
        switch metric {
        case "cost": return "Known API-equivalent estimate"
        case "sessions": return "Recorded sessions"
        default: return "Recorded tokens"
        }
    }

    nonisolated static func make(_ document: CoreUsageGraph) -> UsageComparison? {
        let graph = UsageSourceReading.providerGraph(document)
        guard ["tokens", "sessions", "cost"].contains(graph.metric) else { return nil }
        let ids = Set(graph.providers + graph.series.map(\.providerId)).sorted()
        let groups = Dictionary(grouping: graph.series, by: \.providerId)
        func usable(_ series: CoreUsageGraph.Series) -> [Double] {
            Array(series.values.prefix(max(0, graph.days))).filter { $0.isFinite && $0 >= 0 }
        }
        let amounts: [String: Amount] = Dictionary(uniqueKeysWithValues: ids.map { id in
            let rows = groups[id] ?? []
            let eligible = rows.filter { graph.metric != "cost" || $0.hasPricedUsage != false }
            let values = eligible.flatMap(usable)
            let amount: Amount
            if !values.isEmpty {
                amount = .known(values.reduce(0, +))
            } else if graph.metric == "cost", rows.contains(where: { $0.hasPricedUsage == false }) {
                amount = .unpriced
            } else {
                amount = .missing
            }
            return (id, amount)
        })
        let known = amounts.values.compactMap(\.value)
        let total = known.isEmpty ? nil : known.reduce(0, +)
        let providers = ids.map { id in
            let amount = amounts[id] ?? .missing
            let share = amount.value.flatMap { value in
                total.flatMap { $0 > 0 ? value / $0 : nil }
            }
            return Provider(id: id, amount: amount, share: share,
                            partial: graph.partialProviderIds.contains(id))
        }.sorted { a, b in
            let left = a.amount.value ?? -1
            let right = b.amount.value ?? -1
            return left == right ? a.id < b.id : left > right
        }
        let days = (0..<max(0, graph.days)).map { day in
            var portions: [Portion] = []
            var missing: [String] = []
            var unpriced: [String] = []
            var running = 0.0
            for id in ids {
                let rows = groups[id] ?? []
                if graph.metric == "cost", !rows.isEmpty,
                   rows.allSatisfy({ $0.hasPricedUsage == false }) {
                    unpriced.append(id)
                    continue
                }
                let eligible = rows.filter { graph.metric != "cost" || $0.hasPricedUsage != false }
                let values = eligible.compactMap { row -> Double? in
                    guard day < row.values.count else { return nil }
                    let value = row.values[day]
                    return value.isFinite && value >= 0 ? value : nil
                }
                if values.count != rows.count || rows.isEmpty { missing.append(id) }
                guard !values.isEmpty else { continue }
                let next = running + values.reduce(0, +)
                portions.append(Portion(provider: id, lower: running, upper: next))
                running = next
            }
            return Day(id: day, portions: portions, missing: missing, unpriced: unpriced)
        }
        return UsageComparison(metric: graph.metric, providers: providers, days: days, total: total)
    }
}
