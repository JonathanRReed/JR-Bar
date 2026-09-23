import Foundation
import Testing
import JRBarCore
@testable import JRBarApp

/// The Overview's Model and Cost columns: sorting by what `session_usage`
/// read, and re-sorting when a reading lands — without re-sorting on
/// every tick when the order does not depend on it.
@MainActor
@Suite struct OverviewUsageTests {
    private static func entry(_ id: String) -> CoreRosterEntry {
        CoreRosterEntry(session: CoreSession(id: id, provider: "claude", mode: "working", lifecycle: "active"),
                        schema: 1, visibility: "live")
    }

    @Test("a Cost column click orders by the estimate, unread rows last")
    func sortsByCost() {
        let store = OverviewStore(core: CoreModel())
        store.filter = OverviewFilter(preset: .all)
        store.roster = [Self.entry("ov-cheap"), Self.entry("ov-unread"), Self.entry("ov-dear")]
        store.sortOrder = [KeyPathComparator(\CoreRosterEntry.costSortKey, order: .reverse)]
        store.sessionUsage.apply(SessionUsageDocument(sessions: [
            "ov-cheap": SessionUsage(model: "claude-haiku-4-5", estimatedCostUSD: 0.2),
            "ov-dear": SessionUsage(model: "claude-opus-4-5", estimatedCostUSD: 9.5),
        ]), asked: ["ov-cheap", "ov-dear"])
        #expect(store.rows.map(\.id) == ["ov-dear", "ov-cheap", "ov-unread"])
    }

    @Test("the export carries the rows on screen and names the cut; two selected rows export as themselves")
    func exportFollowsTheView() {
        let store = OverviewStore(core: CoreModel())
        store.roster = [Self.entry("ov-a"), Self.entry("ov-b"), Self.entry("ov-c")]
        store.filter = OverviewFilter(preset: .working)
        store.search = "ov-"
        let scope = store.exportScope
        #expect(scope.label == "Working · search “ov-”")
        #expect(scope.args["ids"] == .array(["ov-a", "ov-b", "ov-c"].map(JSONValue.string)))
        #expect(scope.args["view"] == .string("Working · search “ov-”"))

        store.selectionChanged(to: ["ov-a", "ov-c"])
        #expect(store.exportScope.args["ids"] == .array(["ov-a", "ov-c"].map(JSONValue.string)))
        #expect(store.exportScope.label.hasPrefix("2 selected rows of Working"))

        #expect(OverviewStore.exportArgs(ids: nil, view: nil) == ["scope": .string("all")])
    }

    @Test("branches are offered when they tell rows apart, and a branch cut keeps only its rows")
    func branchCut() {
        let store = OverviewStore(core: CoreModel())
        let main = CoreRosterEntry(session: CoreSession(id: "ov-main", provider: "claude", cwd: "/r/JR-Bar", mode: "working"))
        let tree = CoreRosterEntry(session: CoreSession(id: "ov-tree", provider: "claude", cwd: "/r/JR-Bar/.claude/worktrees/a", mode: "working"))
        store.roster = [main, tree]
        #expect(store.branches.isEmpty)
        store.mergeGitWorkspaces([
            "/r/JR-Bar": GitWorkspace(root: "/r/JR-Bar", branch: "main"),
            "/r/JR-Bar/.claude/worktrees/a": GitWorkspace(root: "/r/JR-Bar/.claude/worktrees/a", branch: "wave1/agentsui",
                                                         isLinkedWorktree: true, mainRoot: "/r/JR-Bar"),
        ], looked: ["/r/JR-Bar", "/r/JR-Bar/.claude/worktrees/a"])
        #expect(store.branches == ["JR-Bar · main", "JR-Bar · wave1/agentsui"])

        store.filter = OverviewFilter(preset: .thisBranch, branch: "JR-Bar · wave1/agentsui")
        #expect(store.rows.map(\.id) == ["ov-tree"])
        #expect(store.viewLabel == "branch JR-Bar · wave1/agentsui")
    }

    @Test("the previous run here is the newest finished run in the same folder, before this one")
    func previousRun() {
        let store = OverviewStore(core: CoreModel())
        func entry(_ id: String, cwd: String, mode: String, lifecycle: String, since: Double, remote: Bool = false) -> CoreRosterEntry {
            CoreRosterEntry(session: CoreSession(id: id, provider: "claude", cwd: cwd, mode: mode, lifecycle: lifecycle,
                                                 since: since, remote: remote))
        }
        let current = entry("now", cwd: "/r/app", mode: "working", lifecycle: "active", since: 500)
        store.roster = [
            current,
            entry("old", cwd: "/r/app", mode: "completed", lifecycle: "completed", since: 100),
            entry("newer", cwd: "/r/app", mode: "failed", lifecycle: "failed", since: 300),
            entry("later", cwd: "/r/app", mode: "completed", lifecycle: "completed", since: 900),
            entry("elsewhere", cwd: "/r/other", mode: "completed", lifecycle: "completed", since: 400),
            entry("live", cwd: "/r/app", mode: "working", lifecycle: "active", since: 450),
        ]
        #expect(store.previousRun(for: current)?.id == "newer")
        #expect(store.previousRun(for: entry("x", cwd: "/r/none", mode: "working", lifecycle: "active", since: 1)) == nil)
    }

    @Test("Export this run writes the loaded timeline with the row's facts, and only for that row")
    func runExport() throws {
        let store = OverviewStore(core: CoreModel())
        let entry = CoreRosterEntry(session: CoreSession(id: "claude:session:run-1", provider: "claude", label: "Fix the build",
                                                         cwd: "/tmp/jr-bar", mode: "completed", lifecycle: "completed", since: 100),
                                    schema: 1, visibility: "live")
        store.roster = [entry]
        #expect(store.runMarkdown(for: entry) == nil)
        store.sessionUsage.apply(SessionUsageDocument(sessions: [
            entry.id: SessionUsage(model: "claude-opus-4-5", estimatedCostUSD: 1.25),
        ]), asked: [entry.id])
        store.timelineSessionID = entry.id
        store.timeline = [
            CoreTimelineItem(seq: 1, at: 100, kind: "message", role: "user", text: "make it green"),
            CoreTimelineItem(seq: 2, at: 101, kind: "tool_use", name: "Bash", text: "swift test"),
            CoreTimelineItem(seq: 3, at: 102, kind: "turn_end", name: "end_turn"),
        ]
        store.timelinePage = CoreTimelinePage(events: store.timeline, hasMore: true, total: 9)
        let text = try #require(store.runMarkdown(for: entry))
        #expect(text.hasPrefix("# Fix the build\n"))
        #expect(text.contains("- **Provider:** Claude"))
        #expect(text.contains("- **State:** Done"))
        #expect(text.contains("- **Model:** Opus 4.5"))
        #expect(text.contains("- **Session:** claude:session:run-1"))
        #expect(text.contains("> make it green"))
        #expect(text.contains("tool `Bash`"))
        #expect(text.contains("Load earlier"))
        store.prepareRunExport(entry)
        #expect(store.runExportPreview?.name == "fix-the-build.md")
        #expect(store.runExportPreview?.markdown.contains("## Timeline") == true)

        let other = CoreRosterEntry(session: CoreSession(id: "claude:session:run-2", provider: "claude"), schema: 1, visibility: "live")
        #expect(store.runMarkdown(for: other) == nil)
    }

    @Test("a working run's timeline ends on what its hook says it is doing now")
    func liveTail() {
        func entry(mode: String, event: String?, tool: String?, id: String = "claude:session:t") -> CoreRosterEntry {
            CoreRosterEntry(session: CoreSession(id: id, provider: "claude", mode: mode, lifecycle: "active",
                                                 event: event, tool: tool), schema: 1, visibility: "live")
        }
        #expect(OverviewStore.liveTail(for: entry(mode: "working", event: "PreToolUse", tool: "Bash")) == "running Bash")
        #expect(OverviewStore.liveTail(for: entry(mode: "working", event: "PostToolUse", tool: "Edit")) == "ran Edit")
        #expect(OverviewStore.liveTail(for: entry(mode: "working", event: "PreCompact", tool: nil)) == "compacting")
        #expect(OverviewStore.liveTail(for: entry(mode: "completed", event: "PreToolUse", tool: "Bash")) == nil)
        #expect(OverviewStore.liveTail(for: entry(mode: "working", event: "PreToolUse", tool: "Bash",
                                                  id: "remote:studio:claude:session:t")) == nil)
    }

    @Test("a heatmap day lists the rows last active that day, from a provider's row only its own")
    func heatmapDay() throws {
        let store = OverviewStore(core: CoreModel())
        let day = try #require(HistoryDayParse.date("2026-09-16"))
        let noon = day.timeIntervalSince1970 + 12 * 3600
        store.roster = [
            CoreRosterEntry(session: CoreSession(id: "d-claude", provider: "claude", mode: "completed", lifecycle: "completed", since: noon)),
            CoreRosterEntry(session: CoreSession(id: "d-codex", provider: "codex", mode: "completed", lifecycle: "completed", since: noon)),
            CoreRosterEntry(session: CoreSession(id: "d-other", provider: "claude", mode: "completed", lifecycle: "completed", since: noon + 86_400)),
        ]
        store.showDay("2026-09-16", provider: "all")
        #expect(Set(store.rows.map(\.id)) == ["d-claude", "d-codex"])
        store.showDay("2026-09-16", provider: "codex")
        #expect(store.rows.map(\.id) == ["d-codex"])
        #expect(store.viewLabel.contains("active"))
        store.reveal("d-other")
        #expect(store.dayFilter == nil)
    }

    @Test("a reading that lands re-sorts a usage column, and only a usage column")
    func generationInvalidatesOnlyUsageSorts() {
        let store = OverviewStore(core: CoreModel())
        store.filter = OverviewFilter(preset: .all)
        store.roster = [Self.entry("ov-a"), Self.entry("ov-b")]
        store.sortOrder = [KeyPathComparator(\CoreRosterEntry.labelSortKey)]
        _ = store.rows
        let before = store.derivedComputations
        store.sessionUsage.apply(SessionUsageDocument(sessions: [
            "ov-a": SessionUsage(model: "claude-opus-4-5", estimatedCostUSD: 1),
        ]), asked: ["ov-a"])
        _ = store.rows
        #expect(store.derivedComputations == before)

        store.sortOrder = [KeyPathComparator(\CoreRosterEntry.modelSortKey)]
        _ = store.rows
        let sorted = store.derivedComputations
        store.sessionUsage.apply(SessionUsageDocument(sessions: [
            "ov-b": SessionUsage(model: "claude-haiku-4-5", estimatedCostUSD: 0.1),
        ]), asked: ["ov-b"])
        #expect(store.rows.map(\.id) == ["ov-b", "ov-a"])
        #expect(store.derivedComputations == sorted + 1)
    }
}
