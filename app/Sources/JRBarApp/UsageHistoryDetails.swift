import JRBarCore
import JRBarUI
import SwiftUI

/// Exact totals remain available below the chart without repeating its curves.
struct UsageHistoryDetails: View {
    let history: UsageHistory
    let showCost: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: JRBarTokens.Space.md) {
            if !history.models.isEmpty {
                DisclosureGroup("By model") {
                    Grid(alignment: .trailing, horizontalSpacing: JRBarTokens.Space.lg, verticalSpacing: JRBarTokens.Space.sm) {
                        GridRow {
                            Text("Model").gridColumnAlignment(.leading)
                            Text("Tokens")
                            if showCost { Text("Estimated cost") }
                        }.font(JRBarTokens.TypeStyle.section.font)
                        ForEach(history.models.sorted { $0.tokens > $1.tokens }) { model in
                            GridRow {
                                Text(model.displayName).gridColumnAlignment(.leading).help(model.model)
                                Text(UsageFormat.tokens(model.tokens))
                                if showCost {
                                    Text(model.priced ? (model.estimated ? "≈ " : "") + UsageFormat.cost(model.costUsd, currency: currency) : "No price")
                                }
                            }
                        }
                    }.padding(.top, JRBarTokens.Space.sm)
                }
            }
            if !history.activeDaysNewestFirst.isEmpty {
                DisclosureGroup("By day") {
                    Grid(alignment: .trailing, horizontalSpacing: JRBarTokens.Space.lg, verticalSpacing: JRBarTokens.Space.sm) {
                        GridRow {
                            Text("Day").gridColumnAlignment(.leading)
                            Text("Input")
                            Text("Output")
                            Text("Cache reads")
                            Text("Total")
                            if showCost { Text("Estimated cost") }
                        }.font(JRBarTokens.TypeStyle.section.font)
                        ForEach(history.activeDaysNewestFirst) { day in
                            GridRow {
                                Text(day.date).gridColumnAlignment(.leading)
                                Text(UsageFormat.tokens(day.tokensIn))
                                Text(UsageFormat.tokens(day.tokensOut))
                                Text(UsageFormat.tokens(day.cacheRead))
                                Text(UsageFormat.tokens(day.totalTokens))
                                if showCost {
                                    Text((history.costsApproximate ? "≈ " : "") + UsageFormat.cost(day.costUsd, currency: currency))
                                }
                            }
                        }
                    }.padding(.top, JRBarTokens.Space.sm)
                }
            }
        }
        .font(JRBarTokens.TypeStyle.callout.font).monospacedDigit().textSelection(.enabled)
    }

    private var currency: String { history.pricing?.currency ?? "USD" }
}
