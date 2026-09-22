import Foundation
import Testing
@testable import JRBarCore

/// Archived-session reconstruction: the claude/codex row→item ports,
/// ordering, caps, honest gaps, consent-redacted content, and the
/// FailureStory derived from the items. All fixtures are synthetic.
@Suite("Session reconstruction")
struct SessionReconstructionTests {

    // MARK: Claude rows

    @Test("claude rows project every item kind with python field semantics")
    func claudeItems() {
        let lines = [
            #"{"type":"user","uuid":"u1","parentUuid":null,"isSidechain":false,"timestamp":"2026-09-19T10:00:00Z","sessionId":"s1","message":{"role":"user","content":"Fix the flaky test"}}"#,
            #"{"type":"assistant","uuid":"a1","parentUuid":"u1","timestamp":"2026-09-19T10:01:00Z","message":{"role":"assistant","model":"claude-test","content":[{"type":"tool_use","id":"toolu_1","name":"Bash","input":{"command":"swift test"}}]}}"#,
            #"{"type":"user","uuid":"u2","parentUuid":"a1","isSidechain":true,"timestamp":"2026-09-19T10:02:00Z","message":{"role":"user","content":[{"type":"tool_result","tool_use_id":"toolu_1","is_error":true,"content":"exit 1"}]}}"#,
            #"{"type":"assistant","uuid":"a2","parentUuid":"u2","timestamp":"2026-09-19T10:03:00Z","message":{"role":"assistant","model":"claude-test","content":[{"type":"text","text":"Done."}],"stop_reason":"end_turn"}}"#,
            #"{"type":"user","uuid":"u9","timestamp":"2026-09-19T10:04:00Z","isMeta":true,"message":{"role":"user","content":"meta row yields nothing"}}"#,
            #"{"type":"user","uuid":"u10","timestamp":"2026-09-19T10:05:00Z","message":{"role":"user","content":[]},"toolUseResult":{"status":"failed","content":"it broke"},"sourceToolAssistantUUID":"a9"}"#,
            "this is not json",
            "42",
            "\"bare string\"",
            #"{"unrelated":true}"#,
        ]
        let result = SessionReconstructor.reconstruct(
            segments: [Data(lines.joined(separator: "\n").utf8)], provider: "claude")

        #expect(result.items.map(\.kind) == [
            .message, .toolUse, .toolResult, .message, .turnEnd, .toolResult,
        ])
        #expect(result.items.map(\.seq) == [0, 1, 2, 3, 4, 5])
        let user = result.items[0]
        #expect(user.role == "user" && user.uuid == "u1" && user.text == "Fix the flaky test")
        #expect(user.untrusted == false && user.sidechain == false)
        let tool = result.items[1]
        #expect(tool.name == "Bash" && tool.toolUseID == "toolu_1" && tool.role == "assistant")
        #expect(tool.untrusted == false)
        #expect(tool.text?.contains("swift test") == true)
        let failed = result.items[2]
        #expect(failed.toolUseID == "toolu_1" && failed.isError && failed.untrusted)
        #expect(failed.sidechain == true && failed.text == "exit 1")
        let reply = result.items[3]
        #expect(reply.role == "assistant" && reply.model == "claude-test" && reply.untrusted)
        let end = result.items[4]
        #expect(end.name == "end_turn" && end.text == nil)
        let fallback = result.items[5]
        // toolUseResult fallback: the durable result marker when content
        // blocks were compacted away — error from status, id from the row.
        #expect(fallback.toolUseID == "a9" && fallback.isError && fallback.text == "it broke")
        #expect(fallback.untrusted)

        #expect(result.gaps == ["malformed_lines:3"])
        #expect(result.totalLines == 10)
        #expect(result.redactedLines == 0)
        // The failing tool pair is named; the session failed mid-story.
        #expect(result.story.failed)
        #expect(result.story.errorCount == 2)
        #expect(result.story.failedToolNames == ["Bash"])
        #expect(result.story.lastErrorSummary == "tool call failed")
        #expect(result.story.lastUserIntent == "Fix the flaky test")
        #expect(result.story.diedMidTurn)   // ends on a tool_result, not a turn end
    }

    @Test("claude ordering sorts by timestamp and renumbers seq; a stamp-less row inherits the previous")
    func claudeOrderingAndFallback() {
        let lines = [
            #"{"type":"user","timestamp":"2026-09-19T10:05:00Z","message":{"role":"user","content":"later"}}"#,
            #"{"type":"user","message":{"role":"user","content":"inherits previous stamp"}}"#,
            #"{"type":"assistant","timestamp":"2026-09-19T10:01:00Z","message":{"role":"assistant","content":[{"type":"text","text":"earlier"}],"stop_reason":"end_turn"}}"#,
        ]
        let result = SessionReconstructor.reconstruct(
            segments: [Data(lines.joined(separator: "\n").utf8)], provider: "claude")
        // Sorted by at: the 10:01 assistant pair first, then the 10:05 rows
        // (the stamp-less row inherits 10:05 and keeps its sequence order).
        #expect(result.items.map(\.text) == ["earlier", nil, "later", "inherits previous stamp"])
        #expect(result.items.map(\.kind) == [.message, .turnEnd, .message, .message])
        #expect(result.items.map(\.seq) == [0, 1, 2, 3])
        #expect(result.items[2].at == result.items[3].at)
    }

    // MARK: Codex rows

    @Test("codex rows project messages, three call kinds, output error heuristic, task_complete, turn_aborted")
    func codexItems() {
        let lines = [
            #"{"timestamp":"2026-09-19T09:00:00Z","type":"session_meta","payload":{"id":"rollout-1","cwd":"/src"}}"#,
            #"{"timestamp":"2026-09-19T09:00:01Z","type":"turn_context","payload":{"turn_id":"turn-1","model":"gpt-x"}}"#,
            #"{"timestamp":"2026-09-19T09:00:02Z","type":"response_item","payload":{"type":"message","role":"user","content":[{"type":"input_text","text":"deploy the thing"}]}}"#,
            #"{"timestamp":"2026-09-19T09:00:03Z","type":"response_item","payload":{"type":"function_call","name":"shell","call_id":"c1","arguments":"{\"cmd\":\"ls\"}"}}"#,
            #"{"timestamp":"2026-09-19T09:00:04Z","type":"response_item","payload":{"type":"function_call_output","call_id":"c1","output":"Error: command failed"}}"#,
            #"{"timestamp":"2026-09-19T09:00:05Z","type":"response_item","payload":{"type":"local_shell_call","name":"run","call_id":"c2","arguments":"ls -la"}}"#,
            #"{"timestamp":"2026-09-19T09:00:06Z","type":"response_item","payload":{"type":"custom_tool_call","name":"apply_patch","id":"c3","arguments":"patch text"}}"#,
            #"{"timestamp":"2026-09-19T09:00:07Z","type":"response_item","payload":{"type":"message","role":"assistant","content":[{"type":"output_text","text":"all done"}]}}"#,
            #"{"timestamp":"2026-09-19T09:00:08Z","type":"response_item","payload":{"type":"task_complete","last_agent_message":"turn done"}}"#,
            #"{"timestamp":"2026-09-19T09:00:09Z","type":"turn_context","payload":{"turn_id":"turn-2"}}"#,
            #"{"timestamp":"2026-09-19T09:00:10Z","type":"response_item","payload":{"type":"message","role":"user","content":[{"type":"input_text","text":"next turn"}]}}"#,
            #"{"timestamp":"2026-09-19T09:00:11Z","type":"response_item","payload":{"type":"turn_aborted"}}"#,
        ]
        let result = SessionReconstructor.reconstruct(
            segments: [Data(lines.joined(separator: "\n").utf8)], provider: "codex")

        #expect(result.items.map(\.kind) == [
            .message, .toolUse, .toolResult, .toolUse, .toolUse,
            .message, .turnEnd, .message, .turnEnd,
        ])
        let user = result.items[0]
        #expect(user.role == "user" && user.name == "turn-1" && user.untrusted == false)
        let call = result.items[1]
        #expect(call.name == "shell" && call.toolUseID == "c1" && call.role == "assistant")
        #expect(call.text == #"{"cmd":"ls"}"#)
        let output = result.items[2]
        // The "error"-in-first-64-chars heuristic flags string output.
        #expect(output.isError && output.toolUseID == "c1" && output.untrusted)
        let shell = result.items[3]
        #expect(shell.name == "run" && shell.toolUseID == "c2")
        let custom = result.items[4]
        #expect(custom.name == "apply_patch" && custom.toolUseID == "c3")  // id fallback
        let reply = result.items[5]
        #expect(reply.role == "assistant" && reply.untrusted && reply.name == "turn-1")
        let complete = result.items[6]
        #expect(complete.name == "task_complete" && complete.text == "turn done")
        let second = result.items[7]
        #expect(second.name == "turn-2")  // turn_context carried the new id
        let aborted = result.items[8]
        #expect(aborted.name == "turn_aborted" && aborted.isError)

        #expect(result.story.failed)
        #expect(result.story.errorCount == 2)
        #expect(result.story.lastErrorSummary == "turn aborted")
        #expect(result.story.diedMidTurn == false)   // ends on a turn end
        #expect(result.story.lastUserIntent == "next turn")
        #expect(result.story.failedToolNames == ["shell"])
        #expect(result.gaps.isEmpty)
        #expect(result.totalLines == 12)
    }

    // MARK: Bounds and gaps

    @Test("the item cap keeps the newest 5000 with a named gap")
    func itemCap() {
        var blocks: [String] = []
        for index in 0..<5100 {
            blocks.append(#"{"type":"tool_use","id":"t\#(index)","name":"T\#(index)","input":null}"#)
        }
        let row = #"{"type":"assistant","timestamp":"2026-09-19T10:00:00Z","message":{"role":"assistant","content":[\#(blocks.joined(separator: ","))]}}"#
        let lines = [row, #"{"type":"user","timestamp":"2026-09-19T10:01:00Z","message":{"role":"user","content":"tail"}}"#]
        let result = SessionReconstructor.reconstruct(
            segments: [Data(lines.joined(separator: "\n").utf8)], provider: "claude")
        #expect(result.items.count == 5_000)
        #expect(result.gaps == ["item_cap:5000"])
        // The tail anchors the window: the last event in the file survives.
        #expect(result.items.last?.text == "tail")
        #expect(result.items.contains { $0.name == "T5099" })
        #expect(!result.items.contains { $0.name == "T0" })
    }

    @Test("an unsupported provider names its gap and yields no items")
    func unsupportedProvider() {
        let result = SessionReconstructor.reconstruct(
            segments: [Data(#"{"type":"user","message":{"role":"user","content":"hi"}}"#.utf8)],
            provider: "cliproxy")
        #expect(result.items.isEmpty)
        #expect(result.gaps == ["unsupported_provider"])
        #expect(result.story.failed == false)
    }

    // MARK: FailureStory

    @Test("a clean session reports failed=false")
    func cleanStory() {
        let lines = [
            #"{"type":"user","timestamp":"2026-09-19T10:00:00Z","message":{"role":"user","content":"do the work"}}"#,
            #"{"type":"assistant","timestamp":"2026-09-19T10:01:00Z","message":{"role":"assistant","content":[{"type":"text","text":"done"}],"stop_reason":"end_turn"}}"#,
        ]
        let result = SessionReconstructor.reconstruct(
            segments: [Data(lines.joined(separator: "\n").utf8)], provider: "claude")
        #expect(result.story.failed == false)
        #expect(result.story.errorCount == 0)
        #expect(result.story.diedMidTurn == false)
        #expect(result.story.lastErrorSummary == nil)
        #expect(result.story.failedToolNames.isEmpty)
        #expect(result.story.lastUserIntent == "do the work")
    }

    @Test("a transcript ending on tool_use died mid-turn")
    func diedMidTurn() {
        let lines = [
            #"{"type":"user","timestamp":"2026-09-19T10:00:00Z","message":{"role":"user","content":"run it"}}"#,
            #"{"type":"assistant","timestamp":"2026-09-19T10:01:00Z","message":{"role":"assistant","content":[{"type":"tool_use","id":"t1","name":"Bash","input":null}]}}"#,
        ]
        let result = SessionReconstructor.reconstruct(
            segments: [Data(lines.joined(separator: "\n").utf8)], provider: "claude")
        #expect(result.story.failed)
        #expect(result.story.diedMidTurn)
        #expect(result.story.errorCount == 0)
    }

    // MARK: Consent-redacted content

    @Test("redacted segments still yield items — redacted=true, text=nil, no content leaks")
    func redactedConsent() {
        let lines = [
            #"{"type":"user","uuid":"u1","timestamp":"2026-09-19T10:00:00Z","message":{"role":"user","content":"Fix the flaky test"}}"#,
            #"{"type":"assistant","uuid":"a1","timestamp":"2026-09-19T10:01:00Z","message":{"role":"assistant","model":"claude-test","content":[{"type":"tool_use","id":"toolu_1","name":"Bash","input":{"command":"swift test"}}]}}"#,
            #"{"type":"assistant","uuid":"a2","timestamp":"2026-09-19T10:02:00Z","message":{"role":"assistant","model":"claude-test","content":[{"type":"text","text":"Done."}],"stop_reason":"end_turn"}}"#,
        ]
        let stored = TranscriptRedactor.redact(Data(lines.joined(separator: "\n").utf8))
        let result = SessionReconstructor.reconstruct(segments: [stored], provider: "claude")

        #expect(result.items.map(\.kind) == [.message, .toolUse, .message, .turnEnd])
        let user = result.items[0]
        #expect(user.redacted && user.text == nil)
        let tool = result.items[1]
        // Structure survives: the summarized input shows the masked value.
        #expect(tool.name == "Bash" && tool.text?.contains("command") == true)
        #expect(tool.text?.contains("swift test") == false)
        let reply = result.items[2]
        #expect(reply.redacted && reply.text == nil && reply.model == "claude-test")
        // Nothing the consent mode withheld can leak through.
        for item in result.items {
            #expect(item.text?.contains("Fix the flaky") != true)
            #expect(item.text?.contains("Done.") != true)
        }
        #expect(result.redactedLines == 3)
        #expect(result.story.lastUserIntent == nil)  // withheld, not fabricated
    }

    @Test("a whole-line unparsed sentinel counts as redacted and malformed")
    func unparsedSentinel() {
        let stored = TranscriptRedactor.redact(Data("garbage line {\n".utf8))
        let result = SessionReconstructor.reconstruct(segments: [stored], provider: "claude")
        #expect(result.items.isEmpty)
        #expect(result.redactedLines == 1)
        #expect(result.gaps == ["malformed_lines:1"])
    }

    // MARK: Archive plumbing

    @Test("segmentData returns verified payloads and relatedRecords links a session across providers")
    func relatedRecordsAndSegmentData() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("jrbar-recon-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: root) }
        let archive = DataHoarderArchive(root: root.appendingPathComponent("archive"))

        let transcript = try await archive.createLiveRecord(
            name: "session.jsonl", sourcePath: "/tmp/session.jsonl")
        try await archive.updateRecordMetadata(
            id: transcript.id, provider: "claude", sessionID: "sess-shared")
        _ = try await archive.appendSegment(
            recordID: transcript.id, data: Data("first\n".utf8), byteOffset: 0)
        _ = try await archive.appendSegment(
            recordID: transcript.id, data: Data("second\n".utf8), byteOffset: 6)

        let proxy = try await archive.createLiveRecord(
            name: "error-v1-messages.log", sourcePath: "/tmp/error.log")
        try await archive.updateRecordMetadata(
            id: proxy.id, provider: "cliproxy", sessionID: "sess-shared")
        _ = try await archive.appendSegment(
            recordID: proxy.id, data: Data("log bytes".utf8), byteOffset: 0)

        let other = try await archive.createLiveRecord(
            name: "other.jsonl", sourcePath: "/tmp/other.jsonl")
        try await archive.updateRecordMetadata(
            id: other.id, provider: "claude", sessionID: "sess-other")

        let related = try await archive.relatedRecords(sessionID: "sess-shared")
        #expect(Set(related.map(\.id)) == [transcript.id, proxy.id])
        let excluding = try await archive.relatedRecords(
            sessionID: "sess-shared", excluding: transcript.id)
        #expect(excluding.map(\.id) == [proxy.id])

        let payloads = try await archive.segmentData(id: transcript.id)
        #expect(payloads == [Data("first\n".utf8), Data("second\n".utf8)])
    }
}
