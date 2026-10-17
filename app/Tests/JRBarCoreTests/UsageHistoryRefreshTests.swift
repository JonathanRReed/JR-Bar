import Foundation
import Testing
@testable import JRBarCore

@Suite("Usage history refresh metadata")
struct UsageHistoryRefreshTests {
    private func wire(_ flag: String?, partial: Bool = false, tokens: Int = 100, records: Int = 1) -> Data {
        let field = flag.map { ",\"stale\":\($0)" } ?? ""
        let json = "{\"provider\":\"claude\",\"range\":\"7d\",\"records\":\(records),\"partial\":\(partial),\"days\":[{\"date\":\"2026-10-10\",\"tokens_in\":\(tokens)}]\(field)}"
        return Data(json.utf8)
    }

    private func encodedStale(_ history: UsageHistory) throws -> Bool {
        let data = try JSONEncoder().encode(history)
        let object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        return object["stale"] as? Bool ?? false
    }

    @Test("completed cached readings retain stale without becoming partial", arguments: [false, true])
    func completeReading(stale: Bool) throws {
        let history = try JSONDecoder().decode(UsageHistory.self, from: wire(String(stale)))
        #expect(try encodedStale(history) == stale)
        #expect(!history.partial)
        #expect(history.totalTokens == 100 && history.records == 1)
        #expect(history.readingFiles == 0)
    }

    @Test("stale metadata stays separate from incomplete scan progress")
    func incompleteReading() throws {
        let history = try JSONDecoder().decode(UsageHistory.self, from: wire("true", partial: true))
        #expect(try encodedStale(history))
        #expect(history.partial && history.totalTokens == 100)
    }

    @Test("missing or null stale metadata preserves older replies", arguments: [nil, "null"] as [String?])
    func legacyReading(flag: String?) throws {
        let history = try JSONDecoder().decode(UsageHistory.self, from: wire(flag))
        #expect(try !encodedStale(history))
        #expect(history.totalTokens == 100 && !history.partial)
    }

    @Test("an old empty reading does not confirm current absence")
    func staleEmptyReading() throws {
        let stale = try JSONDecoder().decode(UsageHistory.self, from: wire("true", tokens: 0, records: 0))
        #expect(!stale.hasNoLocalRecords)
        let fresh = try JSONDecoder().decode(UsageHistory.self, from: wire("false", tokens: 0, records: 0))
        #expect(fresh.hasNoLocalRecords)
    }

    @Test("malformed stale metadata cannot silently present a fresh reading", arguments: ["1", "\"true\"", "{}"])
    func invalidReading(flag: String) {
        #expect(throws: DecodingError.self) {
            try JSONDecoder().decode(UsageHistory.self, from: wire(flag))
        }
    }
}
