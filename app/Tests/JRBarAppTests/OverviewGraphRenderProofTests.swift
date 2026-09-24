import AppKit
import Foundation
import SwiftUI
import Testing
@testable import JRBarApp
@testable import JRBarCore

/// Render proof for the Overview's Graph: a busy fleet (sixteen sessions
/// across Claude, Codex, Gemini and JR-Bar's own background agents, three
/// projects, workers, every state) and a sparse one, in light and dark,
/// hovered, asked and selected, in the default window's narrow column,
/// and a sixty-session fleet with a busy hub hovered, at 2×, so a human
/// can eyeball the map the way a screenshot would show it. Off by
/// default; set `JRBAR_RENDER_PROOF=1` to write `overview-graph-*.png`
/// into `JRBAR_RENDER_PROOF_DIR` (default `/tmp/jrbar-audit`).
@Suite("Overview graph render proof")
@MainActor
struct OverviewGraphRenderProofTests {
    private static func session(_ id: String, _ provider: String, _ label: String, cwd: String?,
                                mode: String, lifecycle: String = "active", parent: String? = nil,
                                ago: Double, workers: Int = 0, tool: String? = nil, ask: CoreAsk? = nil,
                                now: Date) -> CoreRosterEntry {
        let at = now.timeIntervalSince1970 - ago
        return CoreRosterEntry(session: CoreSession(
            id: id, provider: provider, kind: parent == nil ? "main" : "worker", parent: parent,
            label: label, cwd: cwd, mode: mode, lifecycle: lifecycle, since: at, updatedAt: at,
            ask: ask, workers: workers, tool: tool))
    }

    /// Sixteen sessions in three projects: an overnight pass with three
    /// workers, a Codex run asking to run the tests, a failed refactor,
    /// a port with two workers, JR-Bar's background agents idling, and a
    /// site with an illustration, an ended copy edit and a finished audit.
    static func busyRoster(now: Date) -> [CoreRosterEntry] {
        let bar = "/Users/jr/Code/jr-bar"
        let pulse = "/Users/jr/Code/sidepulse"
        let site = "/Users/jr/Sites/jrreed.dev"
        let ask = CoreAsk(session: "codex:ci", kind: "permission", openedAt: now.timeIntervalSince1970 - 95,
                          summary: "Bash: swift test --filter LEDS", answerable: true, request: "r1")
        return [
            session("claude:night", "claude", "Overnight quality pass", cwd: bar, mode: "working",
                    ago: 42 * 60, workers: 3, tool: "Edit", now: now),
            session("claude:graph", "claude", "Graph lane", cwd: bar + "/.claude/worktrees/q-graph",
                    mode: "working", parent: "claude:night", ago: 38 * 60, tool: "Write", now: now),
            session("claude:tank", "claude", "Aquarium art", cwd: bar + "/.claude/worktrees/q-tank",
                    mode: "tool_running", parent: "claude:night", ago: 35 * 60, tool: "Bash", now: now),
            session("claude:cards", "claude", "Settings polish", cwd: bar + "/.claude/worktrees/q-cards",
                    mode: "completed", lifecycle: "completed", parent: "claude:night", ago: 9 * 60, now: now),
            session("codex:ci", "codex", "Fix CI flake", cwd: bar, mode: "waiting",
                    ago: 95, ask: ask, now: now),
            session("gemini:docs", "gemini", "Docs sweep", cwd: bar, mode: "completed",
                    lifecycle: "completed", ago: 12 * 60, now: now),
            session("claude:sampler", "claude", "Refactor LED sampler", cwd: pulse, mode: "failed",
                    lifecycle: "failed", ago: 6 * 60, now: now),
            session("codex:colors", "codex", "Port colour table", cwd: pulse, mode: "working",
                    ago: 18 * 60, workers: 2, tool: "Read", now: now),
            session("codex:palette", "codex", "Palette tests", cwd: pulse, mode: "working",
                    parent: "codex:colors", ago: 14 * 60, tool: "Bash", now: now),
            session("codex:hex", "codex", "Hex parser", cwd: pulse, mode: "idle",
                    parent: "codex:colors", ago: 16 * 60, now: now),
            session("jrbar:background", "jrbar", "Background agents", cwd: pulse, mode: "idle",
                    ago: 27 * 60, now: now),
            session("gemini:hero", "gemini", "Hero illustration", cwd: site, mode: "thinking",
                    ago: 7 * 60, workers: 1, now: now),
            session("gemini:svg", "gemini", "SVG pass", cwd: site, mode: "working",
                    parent: "gemini:hero", ago: 5 * 60, tool: "Write", now: now),
            session("claude:copy", "claude", "Copy edits", cwd: site, mode: "ended",
                    lifecycle: "ended", ago: 22 * 60, now: now),
            session("codex:perf", "codex", "Perf audit", cwd: site, mode: "completed",
                    lifecycle: "completed", ago: 31 * 60, workers: 1, now: now),
            session("codex:lighthouse", "codex", "Lighthouse run", cwd: site, mode: "completed",
                    lifecycle: "completed", parent: "codex:perf", ago: 33 * 60, now: now),
        ]
    }

    /// A quiet evening: one Claude session with a worker, and a Codex run
    /// waiting on you.
    static func sparseRoster(now: Date) -> [CoreRosterEntry] {
        let bar = "/Users/jr/Code/jr-bar"
        let ask = CoreAsk(session: "codex:notes", kind: "question", openedAt: now.timeIntervalSince1970 - 40,
                          summary: "Which branch should the notes cover?", answerable: true, request: "r2")
        return [
            session("claude:night", "claude", "Overnight quality pass", cwd: bar, mode: "working",
                    ago: 42 * 60, workers: 1, tool: "Edit", now: now),
            session("claude:graph", "claude", "Graph lane", cwd: bar, mode: "working",
                    parent: "claude:night", ago: 38 * 60, tool: "Write", now: now),
            session("codex:notes", "codex", "Release notes", cwd: bar, mode: "waiting",
                    ago: 40, ask: ask, now: now),
        ]
    }

    /// Model, tokens and cost for the sessions that have a transcript, so
    /// the nodes' second line reads the way a real fleet's would.
    static func usage(for roster: [CoreRosterEntry]) -> SessionUsageDocument {
        var sessions: [String: SessionUsage] = [:]
        for (index, entry) in roster.enumerated() {
            let tokens = 40_000 + index * 57_300 + (index % 3) * 210_000
            sessions[entry.id] = SessionUsage(provider: entry.session.provider,
                                              tokens: SessionUsageTokens(input: tokens / 3, cachedInput: tokens / 2,
                                                                         output: tokens / 6),
                                              turns: 6 + index * 3,
                                              estimatedCostUSD: Double(tokens) / 180_000)
        }
        return SessionUsageDocument(sessions: sessions)
    }

    static func store(_ roster: [CoreRosterEntry], now: Date) -> OverviewStore {
        let core = CoreModel()
        core.handle(.connected)
        core.apply(.state(CoreState(sessions: roster.map(\.session))))
        let store = OverviewStore(core: core)
        store.roster = roster
        store.now = now
        store.pane = .graph
        store.sessionUsage.apply(usage(for: roster), asked: roster.map(\.id), now: now)
        return store
    }

    /// Sixty sessions in five projects — the size the Graph must stay
    /// smooth at — every provider and state in rotation, a worker or two
    /// on every third.
    static func fleetRoster(now: Date) -> [CoreRosterEntry] {
        let projects = ["jr-bar", "sidepulse", "jrreed.dev", "notes", "infra"]
        let providers = ["claude", "codex", "gemini", "jrbar", "devin"]
        let states: [(mode: String, lifecycle: String)] = [
            ("working", "active"), ("working", "active"), ("waiting", "active"), ("completed", "completed"),
            ("idle", "active"), ("failed", "failed"), ("working", "active"), ("ended", "ended"),
        ]
        var roster: [CoreRosterEntry] = []
        var index = 0
        while roster.count < 60 {
            let state = states[index % states.count]
            let id = "s\(index)"
            let workers = index % 3 == 0 ? 1 + index % 2 : 0
            let provider = providers[(index * 3 + index / 5) % providers.count]
            roster.append(session(id, provider, "Session \(index)",
                                  cwd: "/Users/jr/Code/" + projects[index % projects.count], mode: state.mode,
                                  lifecycle: state.lifecycle, ago: Double(60 + index * 97), workers: workers,
                                  now: now))
            for worker in 0..<workers where roster.count < 60 {
                let workerState = states[(index + worker + 1) % states.count]
                roster.append(session("\(id)-w\(worker)", provider, "Worker \(worker + 1)",
                                      cwd: "/Users/jr/Code/" + projects[index % projects.count],
                                      mode: workerState.mode, lifecycle: workerState.lifecycle, parent: id,
                                      ago: Double(40 + worker * 60), now: now))
            }
            index += 1
        }
        return roster
    }

    private struct Shot {
        let name: String
        let roster: [CoreRosterEntry]
        let scheme: ColorScheme
        let size: CGSize
        var hover: OverviewGraphLayout.Target?
        var selected: String?
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["JRBAR_RENDER_PROOF"] == "1",
                   "set JRBAR_RENDER_PROOF=1 to write overview-graph PNGs"))
    func snapshots() throws {
        let env = ProcessInfo.processInfo.environment
        let dir = URL(fileURLWithPath: env["JRBAR_RENDER_PROOF_DIR"] ?? "/tmp/jrbar-audit", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let now = Date()
        let busy = Self.busyRoster(now: now)
        let sparse = Self.sparseRoster(now: now)
        let wide = CGSize(width: 1100, height: 720)
        let shots = [
            Shot(name: "overview-graph-busy-light", roster: busy, scheme: .light, size: wide),
            Shot(name: "overview-graph-busy-dark", roster: busy, scheme: .dark, size: wide),
            Shot(name: "overview-graph-busy-light-hover", roster: busy, scheme: .light, size: wide,
                 hover: .node("claude:night"), selected: "codex:ci"),
            Shot(name: "overview-graph-busy-dark-hub", roster: busy, scheme: .dark, size: wide,
                 hover: .hub("codex"), selected: "claude:sampler"),
            Shot(name: "overview-graph-busy-dark-ask", roster: busy, scheme: .dark, size: wide,
                 hover: .node("codex:ci")),
            Shot(name: "overview-graph-sparse-light", roster: sparse, scheme: .light, size: CGSize(width: 900, height: 560)),
            Shot(name: "overview-graph-sparse-dark", roster: sparse, scheme: .dark, size: CGSize(width: 900, height: 560)),
            // The Overview's default window leaves the content column about
            // this big: the Graph opens readable on its middle.
            Shot(name: "overview-graph-compact-light", roster: busy, scheme: .light, size: CGSize(width: 560, height: 470)),
            Shot(name: "overview-graph-fleet-dark", roster: Self.fleetRoster(now: now), scheme: .dark,
                 size: CGSize(width: 1400, height: 900)),
            Shot(name: "overview-graph-fleet-light-hub", roster: Self.fleetRoster(now: now), scheme: .light,
                 size: CGSize(width: 1400, height: 900), hover: .hub("gemini")),
        ]
        var written: [String] = []
        for shot in shots {
            let store = Self.store(shot.roster, now: now)
            if let selected = shot.selected { store.selectInGraph(selected) }
            let backdrop = shot.scheme == .dark ? Color(white: 0.12) : Color(white: 0.98)
            let view = OverviewGraphView(store: store, frozenTime: 1.35, pinnedHover: shot.hover)
                .frame(width: shot.size.width, height: shot.size.height)
                .background(backdrop)
                .environment(\.colorScheme, shot.scheme)
            let renderer = ImageRenderer(content: view)
            renderer.scale = 2
            guard let image = renderer.cgImage,
                  let png = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]) else {
                Issue.record("render failed for \(shot.name)")
                continue
            }
            try png.write(to: dir.appendingPathComponent("\(shot.name).png"))
            written.append(shot.name)
        }
        #expect(written.count == shots.count)

        // Two frames of the scene alone: halfway through settling after two
        // sessions arrive and one leaves, and the resting forms Reduce
        // Motion draws instead of the moving layer.
        let before = sparse.map(OverviewGraphNode.init)
        let arriving = [
            OverviewGraphNode(id: "gemini:docs", project: "jr-bar", provider: "gemini", activity: .working,
                              label: "Docs sweep"),
            OverviewGraphNode(id: "claude:tests", parentID: "claude:night", project: "jr-bar", provider: "claude",
                              activity: .working, label: "Test lane"),
        ]
        let after = before.filter { $0.id != "codex:notes" } + arriving
        let scenes: [(String, OverviewGraphLayout?, [OverviewGraphNode], Double, Bool)] = [
            ("overview-graph-settling-light", OverviewGraphLayout.make(before), after, 0.5, true),
            ("overview-graph-still-dark", nil, busy.map(OverviewGraphNode.init), 1, false),
        ]
        for (name, previous, nodes, settle, motion) in scenes {
            let layout = OverviewGraphLayout.make(nodes)
            var all = Dictionary(uniqueKeysWithValues: nodes.map { ($0.id, $0) })
            for node in before where all[node.id] == nil { all[node.id] = node }
            let model = GraphSceneModel(layout: layout, previous: previous, nodes: all,
                                        captions: [:], hubCaptions: [:], unseen: [], selectedID: nil, lit: nil,
                                        now: now.timeIntervalSince1970)
            let size = CGSize(width: 900, height: 560)
            let scheme: ColorScheme = name.hasSuffix("dark") ? .dark : .light
            let view = GraphScene(model: model, camera: GraphCamera.fit(layout.bounds, in: size),
                                  settle: settle, dim: 0, generation: 1, motion: motion, running: false,
                                  frozenTime: 1.35)
                .frame(width: size.width, height: size.height)
                .environment(\.colorScheme, scheme)
            let renderer = ImageRenderer(content: view)
            renderer.scale = 2
            let image = try #require(renderer.cgImage)
            let png = try #require(NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]))
            try png.write(to: dir.appendingPathComponent("\(name).png"))
        }
    }
}
