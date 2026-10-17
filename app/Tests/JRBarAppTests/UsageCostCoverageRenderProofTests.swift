import Foundation
import SwiftUI
import Testing
@testable import JRBarApp
@testable import JRBarCore

@Suite("Cost coverage render proof", .serialized)
@MainActor
struct UsageCostCoverageRenderProofTests {
    @Test(.enabled(if: WindowsRenderProofTests.enabled))
    func unpricedUsage() throws {
        let data = Data(#"{"observed_records":125,"priced_records":92,"unpriced_records":33,"unpriced_sessions":7,"token_categories":{"input":240000,"cached_input":810000,"cache_creation":45000,"output":78000}}"#.utf8)
        let coverage = try JSONDecoder().decode(CoreUsageCostCoverage.self, from: data)
        try WindowsRenderProofTests.write("usage-cost-coverage", size: CGSize(width: 440, height: 150)) {
            UsageCostCoverageView(coverage: coverage).padding(14)
        }
    }
}
