import Foundation

// Pure pieces of the Overview that do not need a window: where a session's
// working directory sits in git (for the Branch column and the "By
// branch" cut), which tools a run actually touched (the observed map a
// Radar report can never draw for Claude Code or Codex), and which
// imported Radar report belongs to the session's repository at all.

/// A working directory's place in git, read from the `.git` files
/// themselves — no `git` process, so a roster of forty rows costs forty
/// small reads, not forty spawns.
public struct GitWorkspace: Hashable, Sendable {
    /// The worktree's top directory (the one holding `.git`).
    public var root: String
    /// `main`, `feature/x`; nil when HEAD is detached.
    public var branch: String?
    /// The first 7 characters of a detached HEAD's commit.
    public var detachedAt: String?
    /// A linked worktree (`.git` is a `gitdir:` file), not the main one.
    public var isLinkedWorktree: Bool

    public init(root: String, branch: String? = nil, detachedAt: String? = nil,
                isLinkedWorktree: Bool = false, mainRoot: String? = nil) {
        self.root = root
        self.branch = branch
        self.detachedAt = detachedAt
        self.isLinkedWorktree = isLinkedWorktree
        self.mainRoot = mainRoot ?? root
    }

    /// The repository's name as a person says it: the main worktree's
    /// folder. A linked worktree names the repository it belongs to, not
    /// its own `.claude/worktrees/agent-3` folder.
    public var repositoryName: String {
        (mainRoot as NSString).lastPathComponent
    }

    /// For a linked worktree the main worktree's top directory, else `root`.
    public var mainRoot: String

    /// "main", "feature/x", or "@1a2b3c4" when detached.
    public var headLabel: String? {
        if let branch { return branch }
        return detachedAt.map { "@" + $0 }
    }

    /// "JR-Bar · feature/x" — the key the Overview's branch cut stores:
    /// the repository and the branch, so two repos' `main` stay apart.
    public var branchKey: String {
        "\(repositoryName) · \(headLabel ?? "no HEAD")"
    }

    /// Walks up from `cwd` to the first directory holding `.git`, at most
    /// `maxDepth` levels, and reads HEAD. Nil outside a repository or when
    /// the files cannot be read.
    public static func resolve(cwd: String, maxDepth: Int = 24,
                               fileManager: FileManager = .default) -> GitWorkspace? {
        var directory = URL(fileURLWithPath: cwd).standardizedFileURL
        for _ in 0..<maxDepth {
            let dotGit = directory.appendingPathComponent(".git")
            var isDirectory: ObjCBool = false
            if fileManager.fileExists(atPath: dotGit.path, isDirectory: &isDirectory) {
                if isDirectory.boolValue {
                    return read(root: directory.path, gitDir: dotGit, linked: false)
                }
                // A linked worktree: `.git` is "gitdir: <path>".
                guard let text = try? String(contentsOf: dotGit, encoding: .utf8),
                      let line = text.split(separator: "\n").first,
                      line.hasPrefix("gitdir:") else { return nil }
                let raw = line.dropFirst("gitdir:".count).trimmingCharacters(in: .whitespaces)
                let gitDir = raw.hasPrefix("/") ? URL(fileURLWithPath: raw)
                    : directory.appendingPathComponent(raw).standardizedFileURL
                return read(root: directory.path, gitDir: gitDir, linked: true)
            }
            let parent = directory.deletingLastPathComponent()
            if parent.path == directory.path { return nil }
            directory = parent
        }
        return nil
    }

    private static func read(root: String, gitDir: URL, linked: Bool) -> GitWorkspace? {
        guard let head = try? String(contentsOf: gitDir.appendingPathComponent("HEAD"), encoding: .utf8) else {
            return nil
        }
        var workspace = GitWorkspace(root: root, isLinkedWorktree: linked)
        let parsed = parseHead(head)
        workspace.branch = parsed.branch
        workspace.detachedAt = parsed.detached
        if linked {
            // <main>/.git/worktrees/<name> → <main>
            let common = gitDir.deletingLastPathComponent().deletingLastPathComponent()
            if common.lastPathComponent == ".git" {
                workspace.mainRoot = common.deletingLastPathComponent().path
            }
        }
        return workspace
    }

    /// `ref: refs/heads/main` → branch "main"; a bare hash → detached.
    public static func parseHead(_ text: String) -> (branch: String?, detached: String?) {
        let line = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if line.hasPrefix("ref:") {
            let ref = line.dropFirst(4).trimmingCharacters(in: .whitespaces)
            let prefix = "refs/heads/"
            return (ref.hasPrefix(prefix) ? String(ref.dropFirst(prefix.count)) : ref, nil)
        }
        let hex = line.prefix(40)
        guard hex.count >= 7, hex.allSatisfy(\.isHexDigit) else { return (nil, nil) }
        return (nil, String(hex.prefix(7)))
    }
}

/// The tools one run actually called, from its transcript's `tool_use`
/// rows: built-in tools by name, MCP tools (`mcp__<server>__<tool>`)
/// grouped under their server. This is the observed half of the
/// Overview's relationship lens — it works for Claude Code and Codex,
/// which a static analyzer like Agentic Radar does not scan.
public struct ObservedToolMap: Hashable, Sendable {
    public struct Tool: Hashable, Sendable, Identifiable {
        public var name: String
        public var calls: Int
        public var failures: Int
        public var id: String { name }
    }

    public struct Server: Hashable, Sendable, Identifiable {
        public var name: String
        public var tools: [Tool]
        public var id: String { name }
        public var calls: Int { tools.reduce(0) { $0 + $1.calls } }
    }

    /// Built-in tools, most-called first.
    public var tools: [Tool]
    /// MCP servers the run touched, most-called first.
    public var servers: [Server]

    public var isEmpty: Bool { tools.isEmpty && servers.isEmpty }
    public var totalCalls: Int { tools.reduce(0) { $0 + $1.calls } + servers.reduce(0) { $0 + $1.calls } }

    /// `mcp__github__create_issue` → ("github", "create_issue").
    public static func splitMCP(_ name: String) -> (server: String, tool: String)? {
        guard name.hasPrefix("mcp__") else { return nil }
        let rest = name.dropFirst(5)
        guard let separator = rest.range(of: "__") else { return nil }
        let server = String(rest[..<separator.lowerBound])
        let tool = String(rest[separator.upperBound...])
        guard !server.isEmpty, !tool.isEmpty else { return nil }
        return (server, tool)
    }

    public static func build(from items: [CoreTimelineItem]) -> ObservedToolMap {
        var calls: [String: Int] = [:]
        var failures: [String: Int] = [:]
        var nameByUse: [String: String] = [:]
        for item in items where item.kind == "tool_use" {
            let name = item.name?.trimmingCharacters(in: .whitespaces).nonEmpty ?? "unknown"
            calls[name, default: 0] += 1
            if let use = item.toolUseId { nameByUse[use] = name }
        }
        for item in items where item.kind == "tool_result" && item.isError == true {
            if let use = item.toolUseId, let name = nameByUse[use] { failures[name, default: 0] += 1 }
        }
        var tools: [Tool] = []
        var servers: [String: [Tool]] = [:]
        for (name, count) in calls {
            if let (server, tool) = splitMCP(name) {
                servers[server, default: []].append(Tool(name: tool, calls: count, failures: failures[name] ?? 0))
            } else {
                tools.append(Tool(name: name, calls: count, failures: failures[name] ?? 0))
            }
        }
        let byCalls: (Tool, Tool) -> Bool = { $0.calls != $1.calls ? $0.calls > $1.calls : $0.name < $1.name }
        return ObservedToolMap(
            tools: tools.sorted(by: byCalls),
            servers: servers.map { Server(name: $0.key, tools: $0.value.sorted(by: byCalls)) }
                .sorted { $0.calls != $1.calls ? $0.calls > $1.calls : $0.name < $1.name })
    }
}

/// Which imported Radar report speaks for a session: the one whose
/// `repository` names the session's repository. The newest-report-wins
/// rule it replaces showed one project's edges on every other project's
/// rows.
public enum RadarReportMatch {
    /// The repository's last path component, lowercased, from a URL
    /// (`https://github.com/o/JR-Bar.git`), an `owner/name` pair, or a
    /// plain path.
    public static func repositoryKey(_ repository: String?) -> String? {
        guard var text = repository?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else { return nil }
        while text.hasSuffix("/") { text.removeLast() }
        if text.hasSuffix(".git") { text.removeLast(4) }
        let last = text.split(whereSeparator: { $0 == "/" || $0 == ":" }).last.map(String.init) ?? text
        return last.isEmpty ? nil : last.lowercased()
    }

    /// The newest report for the session's repository, or nil — never a
    /// report for some other repository.
    public static func pick(_ reports: [CoreRadarSummary], repository: String?) -> CoreRadarSummary? {
        guard let key = repositoryKey(repository) else { return nil }
        return reports
            .filter { repositoryKey($0.repository) == key }
            .max { ($0.importedAt ?? 0) < ($1.importedAt ?? 0) }
    }
}

/// `compare_sessions` side `artifacts`: the files a run's edit tools
/// named (Claude Edit/Write/MultiEdit/NotebookEdit, Codex patch
/// headers), each with how many edits it took, most-edited first;
/// `total` counts every file even past the daemon's cap.
public struct CoreRunArtifacts: Codable, Hashable, Sendable {
    public struct File: Codable, Hashable, Sendable {
        public var path: String
        public var edits: Int

        public init(path: String, edits: Int = 1) {
            self.path = path
            self.edits = edits
        }
    }

    public var files: [File]
    public var total: Int
    public var truncated: Bool

    public init(files: [File] = [], total: Int? = nil, truncated: Bool = false) {
        self.files = files
        self.total = total ?? files.count
        self.truncated = truncated
    }

    enum CodingKeys: String, CodingKey { case files, total, truncated }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        files = (try? c.decodeIfPresent([File].self, forKey: .files)) ?? []
        total = (try? c.decodeIfPresent(Int.self, forKey: .total)) ?? files.count
        truncated = (try? c.decodeIfPresent(Bool.self, forKey: .truncated)) ?? false
    }
}

/// Where two runs' file sets meet and differ — Compare's "what did each
/// one actually change", by path.
public struct RunFileDiff: Equatable, Sendable {
    public var both: [String]
    public var onlyA: [String]
    public var onlyB: [String]

    public init(a: CoreRunArtifacts, b: CoreRunArtifacts) {
        let left = Set(a.files.map(\.path)), right = Set(b.files.map(\.path))
        // Each list keeps its side's most-edited-first order.
        both = a.files.map(\.path).filter(right.contains)
        onlyA = a.files.map(\.path).filter { !right.contains($0) }
        onlyB = b.files.map(\.path).filter { !left.contains($0) }
    }
}

private extension String {
    var nonEmpty: String? { isEmpty ? nil : self }
}
