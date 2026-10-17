import Foundation
import SwiftUI
import Testing
import JRBarCore
@testable import JRBarApp

@Suite("Usage hover readout render proof", .serialized)
@MainActor
struct UsageGraphReadoutRenderProofTests {
    @Test(.enabled(if: WindowsRenderProofTests.enabled))
    func unknownCostAndKnownFreeCost() throws {
        var unknown = CoreUsageGraph.Series(providerId: "claude", values: [0], hasPricedUsage: false)
        unknown.label = "Unknown price"
        var free = CoreUsageGraph.Series(providerId: "codex", values: [0], hasPricedUsage: true)
        free.label = "Free"
        #expect(UsageGraphView.readoutValueLabel(unknown, day: 0, metric: "cost") == "Unpriced")
        #expect(UsageGraphView.readoutValueLabel(free, day: 0, metric: "cost") == UsageFormat.cost(0))
        try WindowsRenderProofTests.write("usage-hover-cost-readout", size: CGSize(width: 190, height: 100), plate: .glass) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Oct 14").font(.system(size: 10, weight: .semibold))
                UsageGraphReadoutRow(series: unknown, day: 0, metric: "cost")
                UsageGraphReadoutRow(series: free, day: 0, metric: "cost")
            }
            .padding(.horizontal, 8).padding(.vertical, 6)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 6))
            .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(.primary.opacity(0.12)))
            .frame(width: 150)
        }
    }
}
