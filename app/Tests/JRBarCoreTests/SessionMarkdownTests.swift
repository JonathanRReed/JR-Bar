import Foundation
import Testing
@testable import JRBarCore

@Suite("A session as readable Markdown")
struct SessionMarkdownTests {
    static let utc = TimeZone(identifier: "UTC")!

    private func reconstruction(proxy: [CLIProxyRequest] = [], gaps: [String] = []) -> SessionReconstruction {
        let items = [
            ReconstructedItem(seq: 0, at: 100, kind: .message, role: "user", untrusted: false,
                              text: "fix the build in /Users/tester/src/app"),
            ReconstructedItem(seq: 1, at: 101, kind: .toolUse, role: "assistant", name: "Bash", toolUseID: "t1",
                              text: "{\"command\":\"make ```oops```\"}"),
            ReconstructedItem(seq: 2, at: 102, kind: .toolResult, toolUseID: "t1", isError: true, untrusted: true,
                              text: "boom"),
            ReconstructedItem(seq: 3, at: 103, kind: .message, role: "assistant", untrusted: true,
                              text: "# not a heading\nsecret sk-ant-api03-ABCDEFGHIJKLMNOPQRSTUVWXYZ", model: "claude-opus-4-5"),
            ReconstructedItem(seq: 4, at: 104, kind: .toolUse, role: "assistant", name: "Read", redacted: true),
        ]
        return SessionReconstruction(items: items, story: SessionReconstructor.story(for: items), gaps: gaps,
                                     totalLines: 5, redactedLines: 1).withProxyRequests(proxy)
    }

    private func render(_ reconstruction: SessionReconstruction, notes: [String] = []) -> String {
        SessionMarkdown.render(title: "Fix the build", facts: [.init("Provider", "Claude"), .init("Folder", "/Users/tester/src/app"), .init("Empty", "")],
                               reconstruction: reconstruction, notes: notes, home: "/Users/tester",
                               generatedAt: Date(timeIntervalSince1970: 0), timeZone: Self.utc)
    }

    @Test("header, facts, the story and every row, in order")
    func layout() {
        let text = render(reconstruction(gaps: ["malformed_lines:2"]), notes: ["From the archived copy"])
        #expect(text.hasPrefix("# Fix the build\n\n- **Provider:** Claude\n- **Folder:** ~/src/app\n"))
        #expect(!text.contains("**Empty:**"))
        #expect(text.contains("> Exported by JR-Bar on 1970-01-01 00:00."))
        #expect(text.contains("> From the archived copy"))
        #expect(text.contains("## What happened\n\nLast asked: fix the build in ~/src/app. Then tool `Bash` failed."))
        #expect(text.contains("## Gaps\n\n- 2 malformed lines\n- 1 line stored with text withheld"))
        let order = ["### 00:01:40 · You", "- 00:01:41 · tool `Bash`", "- 00:01:42 · result · **failed**",
                     "### 00:01:43 · Assistant (claude-opus-4-5)", "- 00:01:44 · tool `Read`"]
        let positions = order.compactMap { text.range(of: $0)?.lowerBound }
        #expect(positions.count == order.count)
        #expect(positions == positions.sorted())
        #expect(text.contains("_input redacted_"))
    }

    @Test("model output is fenced, what you typed is quoted, and secrets stay masked")
    func hygiene() {
        let text = render(reconstruction())
        #expect(text.contains("> fix the build in ~/src/app"))
        // A heading inside model output never becomes the document's own:
        // its one appearance opens a fence.
        #expect(text.components(separatedBy: "\n# not a heading").count == 2)
        #expect(text.contains("```text\n# not a heading"))
        #expect(!text.contains("sk-ant-api03"))
        #expect(text.contains("[redacted]"))
        // Content with a triple backtick gets a longer fence.
        #expect(text.contains("  ````text\n  {\"command\":\"make ```oops```\"}\n  ````"))
        #expect(!text.contains("/Users/tester"))
    }

    @Test("the proxy's requests appear between the turns with the upstream line")
    func proxy() {
        let request = CLIProxyRequest(timestamp: Date(timeIntervalSince1970: 101.5), method: "POST", path: "localhost/v1/messages",
                                      status: 529, attemptCount: 3, errorSummary: "HTTP 529: overloaded")
        let text = render(reconstruction(proxy: [request]))
        #expect(text.contains("Upstream: 1 × HTTP 529, and the last one failed."))
        let line = "- 00:01:41 · proxy · `POST localhost/v1/messages → 529 · 3 attempts` — HTTP 529: overloaded"
        #expect(text.contains(line))
        let proxyAt = text.range(of: line)!.lowerBound
        #expect(text.range(of: "- 00:01:41 · tool `Bash`")!.lowerBound < proxyAt)
        #expect(proxyAt < text.range(of: "- 00:01:42 · result")!.lowerBound)
    }

    @Test("a clean run says so, and an empty one says nothing was rebuilt")
    func clean() {
        let items = [ReconstructedItem(seq: 0, at: 1, kind: .turnEnd, name: "end_turn")]
        let quiet = SessionReconstruction(items: items, story: SessionReconstructor.story(for: items), gaps: [],
                                          totalLines: 1, redactedLines: 0)
        let text = render(quiet)
        #expect(text.contains("No failures in these rows."))
        #expect(text.contains("- 00:00:01 · turn end · end_turn"))
        #expect(!text.contains("## Gaps"))
        let empty = SessionReconstruction(items: [], story: SessionReconstructor.story(for: []), gaps: [],
                                          totalLines: 0, redactedLines: 0)
        #expect(render(empty).contains("No rows could be rebuilt."))
    }

    @Test("the story sentence and gap words are the timeline view's")
    func wording() {
        let story = FailureStory(failed: true, errorCount: 2, lastErrorSummary: nil, diedMidTurn: true,
                                 lastUserIntent: nil, failedToolNames: ["Edit"])
        #expect(story.sentence == "2 errors in these rows. The session ended mid-turn. Failed tools: Edit.")
        #expect(ReconstructionGap.text("transcript_not_found") == "no transcript found for this session")
        #expect(ReconstructionGap.text("gap:source rewritten") == "capture gap: source rewritten")
        #expect(ReconstructionGap.text("something_new") == "something_new")
    }
}
