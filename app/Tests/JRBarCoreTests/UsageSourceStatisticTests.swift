import Foundation
import Testing
@testable import JRBarCore

@Suite struct UsageSourceStatisticTests {
    @Test func compatibilitySourceDoesNotBecomeAProvider() throws {
        let payload = #"{"days":7,"metric":"tokens","providers":["claude"],"series":[{"provider_id":"claude","source_id":"t3code","values":[35]}],"source_statistics":[{"source_id":"t3code","label":"T3 Code","attribution_status":"mixed","tokens":105,"sessions":3,"included_tokens":35,"included_sessions":1,"data_status":"available","provider_ids":["claude","codex"],"detail":"Native history takes precedence."}]}"#
        let graph = try JSONDecoder().decode(CoreUsageGraph.self, from: Data(payload.utf8))
        #expect(graph.providers == ["claude"])
        #expect(graph.series.first?.providerId == "claude")
        #expect(graph.series.first?.sourceId == "t3code")
        let source = try #require(graph.sourceStatistics.first)
        #expect(source.tokens == 105)
        #expect(source.includedTokens == 35)
        #expect(source.providerIds == ["claude", "codex"])
        let roundTrip = try JSONDecoder().decode(CoreUsageGraph.self, from: JSONEncoder().encode(graph))
        #expect(roundTrip == graph)
    }

    @Test func missingOrInvalidCountsRemainUnavailable() throws {
        let payload = #"{"source_id":"t3code","label":"T3 Code","tokens":-1,"sessions":true,"data_status":"available"}"#
        let source = try JSONDecoder().decode(CoreUsageSourceStatistic.self, from: Data(payload.utf8))
        #expect(source.tokens == nil)
        #expect(source.sessions == nil)
        #expect(source.includedTokens == nil)
        #expect(source.dataStatus == "unavailable")
    }

    @Test func oneMalformedSourceCannotEraseKnownSourceReadings() throws {
        let payload = #"{"metric":"tokens","source_statistics":[{"source_id":"","tokens":50},{"source_id":"t3code","label":"T3 Code","tokens":0,"sessions":0,"data_status":"available"}]}"#
        let graph = try JSONDecoder().decode(CoreUsageGraph.self, from: Data(payload.utf8))
        #expect(graph.sourceStatistics.count == 1)
        #expect(graph.sourceStatistics.first?.tokens == 0)
        #expect(graph.sourceStatistics.first?.dataStatus == "available")
    }

    @Test func retryablePartialReadingKeepsUnknownCountsAndItsStatus() throws {
        let payload = #"{"source_id":"t3code","tokens":null,"sessions":null,"data_status":"partial"}"#
        let source = try JSONDecoder().decode(CoreUsageSourceStatistic.self, from: Data(payload.utf8))
        #expect(source.tokens == nil)
        #expect(source.sessions == nil)
        #expect(source.dataStatus == "partial")
    }

    @Test func oldDocumentsKeepTheirProvidersAndHaveNoInventedSourceReading() throws {
        let payload = #"{"metric":"tokens","providers":["codex"],"series":[{"provider_id":"codex","values":[10]}]}"#
        let graph = try JSONDecoder().decode(CoreUsageGraph.self, from: Data(payload.utf8))
        #expect(graph.providers == ["codex"])
        #expect(graph.sourceStatistics.isEmpty)
        #expect(graph.series.first?.sourceId == nil)
    }

    @Test func sessionProvenanceDoesNotReplaceItsProvider() throws {
        let payload = #"{"id":"fixture","provider":"codex","source_integration":"t3code"}"#
        let session = try JSONDecoder().decode(CoreSession.self, from: Data(payload.utf8))
        #expect(session.provider == "codex")
        #expect(session.sourceIntegration == "t3code")
        let legacy = try JSONDecoder().decode(CoreSession.self, from: Data(#"{"id":"fixture","provider":"codex"}"#.utf8))
        #expect(legacy.sourceIntegration == nil)
    }
}
