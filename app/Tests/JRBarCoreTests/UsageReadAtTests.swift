import Foundation
import Testing
@testable import JRBarCore

/// `read_at` is when a usage row's numbers were read, apart from
/// `observed_at`, when the daemon last asked. A stale card that kept its
/// last good numbers through failed polls names the first, so its "read ...
/// ago" is the numbers' age and not the failed poll's.
@Suite("Usage read_at")
struct UsageReadAtTests {
    private func provider(_ json: String) throws -> CoreProviderUsage {
        try JSONDecoder().decode(CoreProviderUsage.self, from: Data(json.utf8))
    }

    @Test("a row with both times reads from read_at")
    func bothTimes() throws {
        let row = try provider(#"{"id":"claude","state":"stale","observed_at":1800000000,"read_at":1799982000}"#)
        #expect(row.observedAt == 1_800_000_000)
        #expect(row.readAt == 1_799_982_000)
        #expect(row.readingAt == 1_799_982_000)
    }

    @Test("a daemon that sends no read_at reads from observed_at")
    func onlyObservedAt() throws {
        let row = try provider(#"{"id":"claude","observed_at":1800000000}"#)
        #expect(row.readAt == nil)
        #expect(row.readingAt == 1_800_000_000)
    }

    @Test("a row with neither time has no reading age")
    func neither() throws {
        let row = try provider(#"{"id":"claude"}"#)
        #expect(row.readingAt == nil)
    }

    @Test("a read_at that is not a number is dropped, and the row keeps its observed_at")
    func tolerantOfJunk() throws {
        let row = try provider(#"{"id":"claude","observed_at":1800000000,"read_at":"soon"}"#)
        #expect(row.readAt == nil)
        #expect(row.readingAt == 1_800_000_000)
        let null = try provider(#"{"id":"claude","observed_at":1800000000,"read_at":null}"#)
        #expect(null.readAt == nil)
        #expect(null.readingAt == 1_800_000_000)
    }

    @Test("the daemon's own state frame carries read_at, older than observed_at on the stale row")
    func theDaemonsOwnFrame() throws {
        guard case .state(let state) = try CoreFixtures.message("python-state.json") else {
            struct NotAState: Error {}
            throw NotAState()
        }
        let usage = try #require(state.usage)
        let claude = try #require(usage.providers.first { $0.id == "claude" })
        #expect(claude.readAt == claude.observedAt, "a live reading was read when it was observed")
        let codex = try #require(usage.providers.first { $0.id == "codex" })
        let read = try #require(codex.readAt)
        let observed = try #require(codex.observedAt)
        #expect(codex.isStale)
        #expect(read < observed, "the stale card's numbers are older than its last attempt")
        #expect(codex.readingAt == read)
    }

    @Test("the init takes read_at last and leaves it out by default")
    func initDefault() {
        let live = CoreProviderUsage(id: "claude", observedAt: 100)
        #expect(live.readAt == nil)
        #expect(live.readingAt == 100)
        let stale = CoreProviderUsage(id: "claude", observedAt: 100, readAt: 40)
        #expect(stale.readingAt == 40)
    }
}
