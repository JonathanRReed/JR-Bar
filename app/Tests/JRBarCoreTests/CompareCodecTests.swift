import Foundation
import Testing
@testable import JRBarCore

/// `compare_sessions` decoding: both sides' aggregates and axes, the
/// shared-facts block, and the always-present benchmark warning (S7.4).
@Suite struct CompareCodecTests {

    private static var document: [String: Any] { [
        "t": "compare_runs",
        "schema": 1,
        "generated_at": 1_800_000_100.0,
        "a": [
            "id": "claude:1", "label": "Fix flake", "provider": "claude",
            "cwd": "/work/a", "lifecycle": "completed", "mode": "completed",
            "axes": ["outcome": "succeeded", "review": "unreviewed",
                     "freshness": "live"],
            "remote": false,
            "activity": [
                "counts": ["user_messages": 2, "assistant_messages": 4,
                           "tool_uses": 7, "tool_failures": 1,
                           "retried_tools": 1, "turn_ends": 2,
                           "sidechain_rows": 3],
                "tools": ["Bash": 5, "Edit": 2],
                "span": ["first_at": 1_800_000_000.0,
                         "last_at": 1_800_000_090.0,
                         "duration_s": 90.0],
                "file": "/t/a.jsonl",
            ],
            "interruptions": ["asked": 1, "blocked": 0, "completed": 1],
            "artifacts": NSNull(), "model": NSNull(),
            "gaps": [],
        ],
        "b": [
            "id": "codex:2", "label": "Ship it", "provider": "codex",
            "cwd": "/work/b", "lifecycle": "active", "mode": "working",
            "remote": true,
            "activity": NSNull(),
            "interruptions": ["asked": 0, "blocked": 1, "completed": 0],
            "gaps": ["transcript_not_found"],
        ],
        "shared": ["provider": false, "workspace": false, "model": NSNull()],
        "warnings": ["not_a_controlled_benchmark", "different_providers",
                     "different_workspaces"],
        "gaps": ["artifacts_not_tracked", "model_not_tracked"],
    ] }

    private func decode() throws -> CoreRunComparison {
        let data = try JSONSerialization.data(withJSONObject: Self.document)
        return try JSONDecoder().decode(CoreRunComparison.self, from: data)
    }

    @Test func sidesAndSharedFactsDecode() throws {
        let doc = try decode()
        #expect(doc.a.id == "claude:1")
        #expect(doc.a.axes?.outcome == "succeeded")
        #expect(doc.a.activity?.toolUses == 7)
        #expect(doc.a.activity?.retriedTools == 1)
        #expect(doc.a.activity?.tools["Bash"] == 5)
        #expect(doc.a.activity?.span?.durationS == 90)
        #expect(doc.a.interruptions.asked == 1)
        #expect(doc.b.activity == nil)
        #expect(doc.b.gaps == ["transcript_not_found"])
        #expect(doc.b.remote)
        #expect(doc.sharedProvider == false && doc.sharedWorkspace == false)
        #expect(doc.sharedModel == nil)  // not tracked — not equal
    }

    @Test func warningsAndGapsAreCarried() throws {
        let doc = try decode()
        #expect(doc.warnings.contains("not_a_controlled_benchmark"))
        #expect(doc.warnings.contains("different_providers"))
        #expect(doc.gaps.contains("artifacts_not_tracked"))
    }
}
