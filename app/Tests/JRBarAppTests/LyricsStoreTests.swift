import Foundation
import Testing
import JRBarCore
@testable import JRBarApp

/// The LRCLIB wire record: the decode is lenient on `duration`
/// (a record that omits it or serves a string can't sink the whole
/// `/api/search` array) and `durationSeconds` never traps on a
/// server-supplied absurdity.
@Suite struct LyricsStoreTests {

    @Test func aRecordWithoutDurationStillDecodes() throws {
        let json = #"{"syncedLyrics":"[00:01.00] hi","plainLyrics":null}"#
            .data(using: .utf8)!
        let record = try JSONDecoder().decode(LRCLIBRecord.self, from: json)
        #expect(record.duration == nil)
        #expect(record.durationSeconds == nil)
        #expect(record.synced?.line(at: 1.5) == "hi")
    }

    @Test func aStringDurationFieldYieldsNilNotThrow() throws {
        // One bad field must not sink the decode — `try?` coalesces.
        let json = #"{"syncedLyrics":"[00:01.00] hi","duration":"200"}"#
            .data(using: .utf8)!
        let record = try JSONDecoder().decode(LRCLIBRecord.self, from: json)
        #expect(record.duration == nil)
        #expect(record.synced != nil)
    }

    @Test func anAbsentSyncedLyricsYieldsNoSync() throws {
        let json = #"{"duration":200,"syncedLyrics":null}"#.data(using: .utf8)!
        let record = try JSONDecoder().decode(LRCLIBRecord.self, from: json)
        #expect(record.synced == nil)
    }

    @Test func absurdServerDurationClampsAndNeverTraps() throws {
        let huge = #"{"duration":1e30}"#.data(using: .utf8)!
        let record = try JSONDecoder().decode(LRCLIBRecord.self, from: huge)
        #expect(record.durationSeconds == 86_400)
    }
}
