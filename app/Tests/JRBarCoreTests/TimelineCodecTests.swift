import Foundation
import Testing
@testable import JRBarCore

/// `session_timeline` decoding: the page envelope (cursor, total, gaps,
/// flattened source), item fields including the untrusted-content flag
/// (T44), and tolerance for items a newer daemon adds fields to.
@Suite struct TimelineCodecTests {

    private static var page: [String: Any] { [
        "schema": 1,
        "has_more": true,
        "next_before": 3,
        "total": 42,
        "source": ["provider": "claude", "file": "/Users/x/.claude/projects/-p/sid.jsonl"],
        "gaps": ["timeline_item_cap:5000"],
        "events": [
            [
                "seq": 3, "at": 1_800_000_000.0, "kind": "message",
                "role": "user", "text": "fix it", "uuid": "u1",
                "origin": "transcript", "recorded_at": NSNull(),
                "untrusted": false,
            ],
            [
                "seq": 4, "at": 1_800_000_005.0, "kind": "tool_use",
                "name": "Bash", "tool_use_id": "tu1",
                "text": #"{"command":"pytest"}"#, "untrusted": false,
                // A field a newer daemon adds: must still decode.
                "future_field": ["x": 1],
            ],
            [
                "seq": 5, "at": 1_800_000_009.0, "kind": "tool_result",
                "tool_use_id": "tu1", "is_error": true,
                "text": "1 failed", "untrusted": true,
            ],
            // Malformed: no seq/kind — skipped, not fatal.
            ["kind": "message"],
        ],
    ] }

    private func decode() throws -> CoreTimelinePage {
        let data = try JSONSerialization.data(withJSONObject: Self.page)
        return try JSONDecoder().decode(CoreTimelinePage.self, from: data)
    }

    @Test func pageEnvelopeDecodes() throws {
        let page = try decode()
        #expect(page.hasMore)
        #expect(page.nextBefore == 3)
        #expect(page.total == 42)
        #expect(page.provider == "claude")
        #expect(page.file?.hasSuffix("sid.jsonl") == true)
        #expect(page.gaps == ["timeline_item_cap:5000"])
    }

    @Test func itemsDecodeWithToolPairingAndTrustFlags() throws {
        let page = try decode()
        #expect(page.events.count == 3)  // malformed item skipped
        let use = page.events[1]
        #expect(use.kind == "tool_use" && use.name == "Bash")
        #expect(use.toolUseId == "tu1" && use.untrusted == false)
        let result = page.events[2]
        #expect(result.kind == "tool_result" && result.isError == true)
        #expect(result.untrusted == true)  // tool output is never a command
        #expect(page.events[0].recordedAt == nil)  // ingestion time unrecorded
    }

    @Test func pageRoundTripsThroughEncode() throws {
        let page = try decode()
        let data = try JSONEncoder().encode(page)
        let again = try JSONDecoder().decode(CoreTimelinePage.self, from: data)
        #expect(again.events.count == 3 && again.provider == "claude")
        #expect(again.nextBefore == 3 && again.hasMore)
    }
}
