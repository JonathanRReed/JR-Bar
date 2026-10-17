import JRBarCore
import SwiftUI

struct UsageCostCoverageView: View {
    let coverage: CoreUsageCostCoverage

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            Label("Priced records: \(coverage.pricedRecords.formatted()) of \(coverage.observedRecords.formatted())",
                  systemImage: coverage.observedRecords > 0 && coverage.unpricedRecords == 0
                    ? "checkmark.circle" : "info.circle")
                .fontWeight(.medium)
            if coverage.unpricedRecords > 0 {
                Text("\(coverage.unpricedRecords.formatted()) unpriced records · \(coverage.unpricedSessions.formatted()) affected sessions. This usage is excluded from the cost estimate.")
                Text(tokenBreakdown)
                    .monospacedDigit()
            }
        }
        .font(.system(size: 11))
        .foregroundStyle(.secondary)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(10)
        .background(Color.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 8))
        .textSelection(.enabled)
        .accessibilityElement(children: .combine)
    }

    private var tokenBreakdown: String {
        let tokens = coverage.tokenCategories
        return "Unpriced tokens: input \(tokens.input.formatted()) · cache read \(tokens.cachedInput.formatted()) · cache write \(tokens.cacheCreation.formatted()) · output \(tokens.output.formatted())"
    }
}
