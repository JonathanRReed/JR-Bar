import Foundation
import Testing
@testable import JRBarCore

/// `AgentOrganizerSettings` is the Agent Overview card's persisted half
/// (docs/UTILITIES.md): tolerant `Codable` like the rest of
/// `UtilitiesState`, plus the pure filter/order/group/count logic the
/// card enumerates — the panel's precedence, so the utility and the
/// panel never disagree about who is on top.
@Suite("Agent organizer")
struct AgentOrganizerTests {
    private func decode<T: Decodable>(_ type: T.Type, _ json: String) throws -> T {
        try JSONDecoder().decode(T.self, from: Data(json.utf8))
    }

    private func encode<T: Encodable>(_ value: T) throws -> String {
        String(decoding: try JSONEncoder().encode(value), as: UTF8.self)
    }

    private func session(_ id: String, provider: String = "claude",
                         lifecycle: String? = "active", mode: String? = nil,
                         since: Double? = nil, ask: CoreAsk? = nil,
                         stale: Bool = false) -> CoreSession {
        CoreSession(id: id, provider: provider, mode: mode, lifecycle: lifecycle,
                    since: since, stale: stale, ask: ask)
    }

    // MARK: Persisted state

    @Test("defaults: on, grouped by state, idle rows hidden")
    func defaults() {
        let s = AgentOrganizerSettings()
        #expect(s.enabled == true)
        #expect(s.grouping == .state)
        #expect(s.showRemote == true)
        #expect(s.showEnded == true)
        #expect(s.showIdle == false)
        #expect(s.showElapsed == true)
        #expect(s.rowLimit == AgentOrganizerSettings.defaultRowLimit)
        #expect(UtilitiesState().agents == s)
    }

    @Test("encode then decode returns the same settings")
    func roundTrip() throws {
        var state = UtilitiesState()
        state.agents = AgentOrganizerSettings(enabled: false, grouping: .provider,
                                            showRemote: false, showEnded: false, showIdle: true,
                                            showElapsed: false, rowLimit: 15)
        #expect(try decode(UtilitiesState.self, encode(state)) == state)
    }

    @Test("an empty document reads as the defaults")
    func emptyDocument() throws {
        #expect(try decode(AgentOrganizerSettings.self, "{}") == AgentOrganizerSettings())
    }

    @Test("missing and mistyped keys fall back, unknown keys are ignored")
    func tolerantDecode() throws {
        let json = #"{"enabled": "sure", "grouping": "by-vibes", "showIdle": "yes", "rowLimit": "lots", "futureKnob": 3}"#
        let s = try decode(AgentOrganizerSettings.self, json)
        #expect(s.enabled == true, "a string is not a flag")
        #expect(s.grouping == .state, "an unknown grouping is not a grouping")
        #expect(s.showIdle == false)
        #expect(s.rowLimit == AgentOrganizerSettings.defaultRowLimit)
    }

    @Test("the row cap clamps to its range")
    func rowLimitClamp() throws {
        #expect(try decode(AgentOrganizerSettings.self, #"{"rowLimit": 1}"#).rowLimit == 3)
        #expect(try decode(AgentOrganizerSettings.self, #"{"rowLimit": 99}"#).rowLimit == 20)
        #expect(AgentOrganizerSettings(rowLimit: 0).rowLimit == 3)
        #expect(AgentOrganizerSettings(rowLimit: 12).rowLimit == 12)
    }

    @Test("a file without `agents` reads as the defaults")
    func stateWithoutAgents() throws {
        let state = try decode(UtilitiesState.self, #"{"menuBar": {"enabled": true}}"#)
        #expect(state.agents == AgentOrganizerSettings())
        #expect(state.menuBar.enabled == true)
    }

    // MARK: What's shown

    @Test("the visibility toggles gate remote, ended and idle rows")
    func includes() {
        var s = AgentOrganizerSettings()
        let remote = session("remote:mac2:claude:abc", mode: "working")
        let ended = session("e1", lifecycle: "ended")
        let idle = session("i1", mode: "idle")
        let working = session("w1", mode: "working")
        #expect(s.includes(remote) && s.includes(ended) && !s.includes(idle) && s.includes(working))
        s.showRemote = false
        s.showEnded = false
        s.showIdle = true
        #expect(!s.includes(remote) && !s.includes(ended) && s.includes(idle))
    }

    @Test("a state.asks pin makes an otherwise-idle row waiting, so hiding idle cannot hide a question")
    func pinnedAskCountsAsWaiting() {
        let s = AgentOrganizerSettings(showIdle: false)
        let quiet = session("q1", mode: "idle")
        let ask = CoreAsk(session: "q1", openedAt: 10)
        #expect(!s.includes(quiet))
        #expect(s.includes(quiet, pinnedAsk: ask))
        #expect(AgentOrganizerSettings.activity(of: quiet, pinnedAsk: ask) == .waiting)
    }

    // MARK: Ordering — the panel's precedence

    @Test("asks lead, longest-unanswered first; then waiting, failed, working, done, ended, idle")
    func ordering() {
        let s = AgentOrganizerSettings(showIdle: true)
        let waiting = session("w", mode: "waiting", since: 100)
        let failed = session("f", lifecycle: "failed", since: 200)
        let working = session("k", mode: "working", since: 300)
        let done = session("d", lifecycle: "completed", since: 400)
        let ended = session("e", lifecycle: "ended", since: 500)
        let idle = session("i", mode: "idle", since: 600)
        let newerAsk = session("a2", mode: "working", since: 700)
        let olderAsk = session("a1", mode: "working", since: 800)
        let asks = [CoreAsk(session: "a2", openedAt: 50), CoreAsk(session: "a1", openedAt: 10)]
        let rows = s.filtered([idle, done, ended, working, failed, waiting, newerAsk, olderAsk], asks: asks)
        #expect(rows.map(\.id) == ["a1", "a2", "w", "f", "k", "d", "e", "i"])
    }

    @Test("inside a rank the most recent leads")
    func recencyWithinRank() {
        let s = AgentOrganizerSettings()
        let older = session("old", mode: "working", since: 100)
        let newer = session("new", mode: "working", since: 200)
        #expect(s.filtered([older, newer], asks: []).map(\.id) == ["new", "old"])
    }

    @Test("a session's own ask pins it without a state.asks entry")
    func embeddedAskPins() {
        let s = AgentOrganizerSettings()
        let working = session("k", mode: "working", since: 900)
        let asked = session("a", mode: "working", since: 100,
                            ask: CoreAsk(session: "a", openedAt: 30))
        #expect(s.filtered([working, asked], asks: []).map(\.id) == ["a", "k"])
    }

    // MARK: Grouping

    @Test("by state: one section per activity in precedence order")
    func groupByState() {
        let s = AgentOrganizerSettings(grouping: .state)
        let rows = s.grouped([session("d", lifecycle: "completed"),
                              session("k1", mode: "working", since: 1),
                              session("k2", mode: "working", since: 2),
                              session("w", mode: "waiting")], asks: [])
        #expect(rows.map(\.key) == ["waiting", "working", "done"])
        #expect(rows.map(\.title) == ["Waiting on you", "Working", "Done"])
        #expect(rows[1].sessions.map(\.id) == ["k2", "k1"])
    }

    @Test("by provider: sections order by the best rank they contain")
    func groupByProvider() {
        let s = AgentOrganizerSettings(grouping: .provider)
        let rows = s.grouped([session("c1", provider: "claude", mode: "working"),
                              session("x1", provider: "codex", mode: "waiting"),
                              session("c2", provider: "claude", lifecycle: "completed")], asks: [])
        #expect(rows.map(\.key) == ["codex", "claude"], "Codex leads — it holds the waiting row")
        #expect(rows[1].sessions.map(\.id) == ["c1", "c2"])
        #expect(rows[0].title == "Codex")
    }

    @Test("by project: a repository's worktrees fold into one section, ranked like providers")
    func groupByProject() {
        func at(_ id: String, _ cwd: String?, mode: String? = "working", lifecycle: String? = "active") -> CoreSession {
            CoreSession(id: id, provider: "claude", cwd: cwd, mode: mode, lifecycle: lifecycle)
        }
        let s = AgentOrganizerSettings(grouping: .project)
        let rows = s.grouped([
            at("a", "/Users/j/JR-Bar"),
            at("b", "/Users/j/JR-Bar/.claude/worktrees/agent-3"),
            at("c", "/Users/j/site", mode: "waiting"),
            at("d", nil, lifecycle: "completed"),
        ], asks: [])
        #expect(rows.map(\.title) == ["site", "JR-Bar", "No folder"], "site leads — it holds the waiting row")
        #expect(rows[1].sessions.map(\.id).sorted() == ["a", "b"])
        #expect(Set(rows.map(\.key)).count == rows.count)
        // An injected resolver (git's answer in the app) wins.
        let named = s.grouped([at("a", "/x/one"), at("b", "/x/two")], asks: [], project: { _ in "Mono" })
        #expect(named.map(\.title) == ["Mono"])
    }

    @Test("a folder names its project; a linked worktree names its repository")
    func projectNames() {
        #expect(AgentProject.name(of: "/Users/j/JR-Bar") == "JR-Bar")
        #expect(AgentProject.name(of: "/Users/j/JR-Bar/.claude/worktrees/wf-1/app") == "JR-Bar")
        #expect(AgentProject.name(of: "/src/api/.worktrees/fix-auth") == "api")
        #expect(AgentProject.name(of: "") == nil)
        #expect(AgentProject.name(of: nil) == nil)
        let workspace = GitWorkspace(root: "/w/feature", branch: "feature", isLinkedWorktree: true, mainRoot: "/w/Mono")
        #expect(AgentProject.name(of: "/w/feature/sub", workspace: workspace) == "Mono")
    }

    @Test("flat: one untitled section keeps the precedence order")
    func groupFlat() {
        let s = AgentOrganizerSettings(grouping: .flat)
        let rows = s.grouped([session("d", lifecycle: "completed"),
                              session("w", mode: "waiting")], asks: [])
        #expect(rows.count == 1)
        #expect(rows[0].key == "all" && rows[0].title.isEmpty)
        #expect(rows[0].sessions.map(\.id) == ["w", "d"])
        #expect(AgentOrganizerSettings(grouping: .state).grouped([], asks: []).isEmpty)
    }

    // MARK: Counts

    @Test("counts run over the filtered set in precedence order")
    func counts() {
        let s = AgentOrganizerSettings()
        let counts = s.counts(of: [session("w", mode: "waiting"),
                                   session("k1", mode: "working"),
                                   session("k2", mode: "working"),
                                   session("i", mode: "idle"),       // filtered: showIdle off
                                   session("d", lifecycle: "completed")], asks: [])
        #expect(counts.map(\.activity) == [.waiting, .working, .done])
        #expect(counts.map(\.count) == [1, 2, 1])
    }
}
