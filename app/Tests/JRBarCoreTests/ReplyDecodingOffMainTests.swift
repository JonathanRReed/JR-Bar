import Foundation
import Testing
@testable import JRBarCore

/// Large daemon replies are decoded off the main actor: `list_roster` and
/// `session_timeline` re-encode their `JSONValue` tree and decode it again,
/// which costs tens of milliseconds for a few hundred rows. The decode runs
/// on a detached task and the value that comes back is exactly what the
/// synchronous decode returns, errors included.
@Suite("Reply decoding off the main actor")
struct ReplyDecodingOffMainTests {
    /// A model that records which thread decoded it.
    struct ThreadProbe: Decodable, Sendable {
        let onMain: Bool
        init(from decoder: Decoder) throws { onMain = Thread.isMainThread }
    }

    struct NeedsID: Decodable, Sendable { let id: String }

    @MainActor
    @Test("the plain decode runs on whichever thread asks: the main one, for the model")
    func plainDecodeRunsWhereItIsCalled() throws {
        #expect(try ReplyDecoding.decode(ThreadProbe.self, from: .object([:])).onMain)
    }

    @MainActor
    @Test("the off-main decode leaves the main thread, however it is asked from the model")
    func decodeOffMainLeavesTheMainThread() async throws {
        let probe = try await ReplyDecoding.decodeOffMain(ThreadProbe.self, from: .object([:]))
        #expect(!probe.onMain)
    }

    private static func rosterValue(count: Int) throws -> JSONValue {
        var rows: [[String: Any]] = (0..<count).map { index in
            ["id": "claude:synthetic-\(index)", "provider": "claude", "mode": "working",
             "label": "synthetic session \(index)", "schema": 1, "pinned": index == 0,
             "visibility": "live", "axes": ["outcome": "none", "review": "pending", "freshness": "live"]]
        }
        // One row the decoder cannot read: the tolerant list drops it
        // instead of failing the document.
        rows.append(["provider": "claude", "label": "a row with no id"])
        let object: [String: Any] = [
            "sessions": rows,
            "counts": ["total": count, "workers": 0, "attention": 0, "live": count,
                       "finished": 0, "hidden_from_panel": 0, "listed": count],
            "coverage": ["retained": count],
        ]
        return try JSONDecoder().decode(JSONValue.self, from: JSONSerialization.data(withJSONObject: object))
    }

    @Test("a roster decodes to the same value either way, malformed row dropped as before")
    func rosterIsTheSameValue() async throws {
        let value = try Self.rosterValue(count: 40)
        let plain = try ReplyDecoding.decode(CoreRoster.self, from: value)
        let offMain = try await ReplyDecoding.decodeOffMain(CoreRoster.self, from: value)
        #expect(plain == offMain)
        #expect(offMain.sessions.count == 40, "the tolerant list still drops the row it cannot read")
        #expect(offMain.sessions.first?.pinned == true)
        #expect(offMain.counts.total == 40)
    }

    @Test("a timeline page decodes to the same value either way")
    func timelineIsTheSameValue() async throws {
        let items: [[String: Any]] = (0..<25).map { index in
            ["seq": index, "at": 1_790_000_000.0 + Double(index), "kind": "message",
             "role": index.isMultiple(of: 2) ? "assistant" : "user", "text": "synthetic text \(index)"]
        }
        let object: [String: Any] = ["events": items, "has_more": true, "next_before": 3, "total": 90,
                                     "gaps": ["timeline_item_cap:25"]]
        let value = try JSONDecoder().decode(JSONValue.self, from: JSONSerialization.data(withJSONObject: object))
        let plain = try ReplyDecoding.decode(CoreTimelinePage.self, from: value)
        let offMain = try await ReplyDecoding.decodeOffMain(CoreTimelinePage.self, from: value)
        #expect(plain == offMain)
        #expect(offMain.events.count == 25 && offMain.hasMore && offMain.nextBefore == 3)
    }

    @Test("a missing result decodes as the empty object, and a refusal throws the same error")
    func nilAndErrorsMatch() async throws {
        #expect(try await ReplyDecoding.decodeOffMain(CoreRoster.self, from: nil).sessions.isEmpty)
        func failure(_ operation: () async throws -> NeedsID) async -> String {
            do { _ = try await operation(); return "no error" } catch { return String(describing: error) }
        }
        let plain = await failure { try ReplyDecoding.decode(NeedsID.self, from: .object([:])) }
        let offMain = await failure { try await ReplyDecoding.decodeOffMain(NeedsID.self, from: .object([:])) }
        #expect(plain == offMain)
        #expect(plain.contains("keyNotFound"), "the same DecodingError, not a wrapper")
    }

    /// Opt-in: how long the typed decode of a large reply takes. Run with
    /// `JRBAR_REPLY_DECODE_BENCHMARK=1 swift test --filter ReplyDecodingOffMainTests`.
    /// The rows here are small; a release build over fuller rows (a label,
    /// a folder, a last message, an origin, a terminal, the record axes)
    /// measured 41 ms for 500 roster rows and 164 ms for 2000.
    @Test("measures the decode cost of a large roster and a timeline page",
          .enabled(if: ProcessInfo.processInfo.environment["JRBAR_REPLY_DECODE_BENCHMARK"] == "1"))
    func measureLargeReplies() throws {
        for count in [500, 2000] {
            let value = try Self.rosterValue(count: count)
            let clock = ContinuousClock()
            let elapsed = try clock.measure { _ = try ReplyDecoding.decode(CoreRoster.self, from: value) }
            print("list_roster, \(count) rows: \(elapsed)")
        }
    }
}
