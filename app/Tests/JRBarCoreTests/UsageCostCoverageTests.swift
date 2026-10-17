import Foundation
import Testing
@testable import JRBarCore

@Suite struct UsageCostCoverageTests {
    private var payload: [String: Any] {
        ["observed_records": 5, "priced_records": 2, "unpriced_records": 3,
         "unpriced_sessions": 2,
         "token_categories": ["input": 400, "cached_input": 100,
                              "cache_creation": 20, "output": 80]]
    }

    private func graph(_ coverage: [String: Any], metric: String = "cost") throws -> CoreUsageGraph {
        let data = try JSONSerialization.data(withJSONObject: ["metric": metric, "cost_coverage": coverage])
        return try JSONDecoder().decode(CoreUsageGraph.self, from: data)
    }

    @Test func decodesCoverageAndAllUnpricedTokenCategories() throws {
        let coverage = try #require(graph(payload).costCoverage)
        #expect(coverage.observedRecords == 5 && coverage.pricedRecords == 2)
        #expect(coverage.unpricedRecords == 3 && coverage.unpricedSessions == 2)
        #expect(coverage.tokenCategories.input == 400)
        #expect(coverage.tokenCategories.cachedInput == 100)
        #expect(coverage.tokenCategories.cacheCreation == 20)
        #expect(coverage.tokenCategories.output == 80)
        let roundTrip = try JSONDecoder().decode(CoreUsageCostCoverage.self,
            from: JSONEncoder().encode(coverage))
        #expect(roundTrip == coverage)
    }

    @Test func malformedCoverageDoesNotDestroyTheChart() throws {
        for (key, value) in [("priced_records", 6), ("unpriced_records", -1),
                             ("unpriced_sessions", 4), ("observed_records", 4)] {
            var invalid = payload
            invalid[key] = value
            #expect(try graph(invalid).costCoverage == nil)
        }
        var invalid = payload
        invalid["token_categories"] = ["input": -1, "cached_input": 0,
                                        "cache_creation": 0, "output": 0]
        #expect(try graph(invalid).costCoverage == nil)
        invalid = payload
        invalid["priced_records"] = true
        #expect(try graph(invalid).costCoverage == nil)
    }

    @Test func olderGraphsAndOtherMetricsStayCompatible() throws {
        let data = Data(#"{"metric":"cost","labels":["Mon"],"series":[]}"#.utf8)
        let legacy = try JSONDecoder().decode(CoreUsageGraph.self, from: data)
        #expect(legacy.costCoverage == nil && legacy.labels == ["Mon"])
        #expect(try graph(payload, metric: "tokens").costCoverage == nil)
    }

    @Test func seriesDistinguishesMissingPricesFromKnownZeroRates() throws {
        for priced in [false, true] {
            let data = try JSONSerialization.data(withJSONObject: ["provider_id": "codex",
                "values": [-1, 0], "has_priced_usage": priced])
            let series = try JSONDecoder().decode(CoreUsageGraph.Series.self, from: data)
            #expect(series.hasPricedUsage == priced)
        }
        let old = Data(#"{"provider_id":"codex","values":[0]}"#.utf8)
        #expect(try JSONDecoder().decode(CoreUsageGraph.Series.self, from: old).hasPricedUsage == nil)
    }
}
