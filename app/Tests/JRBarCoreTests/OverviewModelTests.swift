import Foundation
import Testing
@testable import JRBarCore

@Suite("Overview model")
struct OverviewModelTests {
    private static func tempDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("jrbar-overview-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private static func write(_ text: String, to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try text.write(to: url, atomically: true, encoding: .utf8)
    }

    @Test("a nested cwd finds its repository and branch by reading .git, no process")
    func mainWorktree() throws {
        let base = try Self.tempDirectory()
        defer { try? FileManager.default.removeItem(at: base) }
        let repo = base.appendingPathComponent("JR-Bar")
        try Self.write("ref: refs/heads/feature/rail\n", to: repo.appendingPathComponent(".git/HEAD"))
        let nested = repo.appendingPathComponent("app/Sources")
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)

        let workspace = try #require(GitWorkspace.resolve(cwd: nested.path))
        #expect(workspace.branch == "feature/rail")
        #expect(workspace.repositoryName == "JR-Bar")
        #expect(!workspace.isLinkedWorktree)
        #expect(workspace.branchKey == "JR-Bar · feature/rail")
    }

    @Test("a linked worktree names the repository it belongs to, not its own folder")
    func linkedWorktree() throws {
        let base = try Self.tempDirectory()
        defer { try? FileManager.default.removeItem(at: base) }
        let repo = base.appendingPathComponent("JR-Bar")
        let gitDir = repo.appendingPathComponent(".git/worktrees/agent-3")
        try Self.write("ref: refs/heads/wave1/agentsui\n", to: gitDir.appendingPathComponent("HEAD"))
        try Self.write("ref: refs/heads/main\n", to: repo.appendingPathComponent(".git/HEAD"))
        let worktree = repo.appendingPathComponent(".claude/worktrees/agent-3")
        try Self.write("gitdir: \(gitDir.path)\n", to: worktree.appendingPathComponent(".git"))

        let workspace = try #require(GitWorkspace.resolve(cwd: worktree.path))
        #expect(workspace.isLinkedWorktree)
        #expect(workspace.branch == "wave1/agentsui")
        #expect(workspace.repositoryName == "JR-Bar")
    }

    @Test("HEAD parses to a branch, a detached commit, or nothing")
    func head() {
        #expect(GitWorkspace.parseHead("ref: refs/heads/main\n").branch == "main")
        #expect(GitWorkspace.parseHead("1a2b3c4d5e6f7a8b9c0d1a2b3c4d5e6f7a8b9c0d\n").detached == "1a2b3c4")
        let junk = GitWorkspace.parseHead("not a head")
        #expect(junk.branch == nil && junk.detached == nil)
        #expect(GitWorkspace(root: "/r", detachedAt: "1a2b3c4").headLabel == "@1a2b3c4")
    }

    @Test("outside a repository there is no workspace")
    func noRepository() throws {
        let base = try Self.tempDirectory()
        defer { try? FileManager.default.removeItem(at: base) }
        #expect(GitWorkspace.resolve(cwd: base.path, maxDepth: 1) == nil)
    }

    private static func item(_ seq: Int, _ kind: String, name: String? = nil, use: String? = nil, error: Bool? = nil) -> CoreTimelineItem {
        CoreTimelineItem(seq: seq, kind: kind, name: name, toolUseId: use, isError: error)
    }

    @Test("observed tools count calls and failures, and group MCP tools by server")
    func observedTools() {
        let map = ObservedToolMap.build(from: [
            Self.item(0, "tool_use", name: "Bash", use: "a"),
            Self.item(1, "tool_result", use: "a", error: true),
            Self.item(2, "tool_use", name: "Bash", use: "b"),
            Self.item(3, "tool_use", name: "Edit", use: "c"),
            Self.item(4, "tool_use", name: "mcp__github__create_issue", use: "d"),
            Self.item(5, "tool_use", name: "mcp__github__list_prs", use: "e"),
            Self.item(6, "tool_use", name: "mcp__github__list_prs", use: "f"),
            Self.item(7, "message"),
        ])
        #expect(map.tools.map(\.name) == ["Bash", "Edit"])
        #expect(map.tools.first?.calls == 2)
        #expect(map.tools.first?.failures == 1)
        #expect(map.servers.map(\.name) == ["github"])
        #expect(map.servers.first?.tools.map(\.name) == ["list_prs", "create_issue"])
        #expect(map.totalCalls == 6)
        #expect(ObservedToolMap.splitMCP("mcp__bad") == nil)
    }

    @Test("a Radar report speaks only for its own repository")
    func radarMatch() {
        let reports = [
            CoreRadarSummary(id: "old", repository: "https://github.com/jr/JR-Bar.git", importedAt: 1, nodes: 3, edges: 2),
            CoreRadarSummary(id: "new", repository: "jr/JR-Bar", importedAt: 5, nodes: 3, edges: 2),
            CoreRadarSummary(id: "other", repository: "jr/crew-demo", importedAt: 9, nodes: 3, edges: 2),
        ]
        #expect(RadarReportMatch.pick(reports, repository: "JR-Bar")?.id == "new")
        #expect(RadarReportMatch.pick(reports, repository: "sidepulse") == nil)
        #expect(RadarReportMatch.pick(reports, repository: nil) == nil)
        #expect(RadarReportMatch.repositoryKey("git@github.com:jr/JR-Bar.git") == "jr-bar")
    }
}
