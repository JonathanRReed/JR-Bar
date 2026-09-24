import Foundation
import Testing
@testable import JRBarApp
@testable import JRBarCore

/// Which window hosts which agent session: the Dock's no-guess rule,
/// applied to the daemon's sessions.
struct DockAgentMatchTests {
    static let ghostty = "com.mitchellh.ghostty"
    static let home = NSHomeDirectory()

    private func session(_ id: String, label: String? = nil, cwd: String? = nil,
                         mode: String = "working", ask: CoreAsk? = nil,
                         host: String? = ghostty, tty: String? = nil,
                         provider: String = "claude", remote: Bool = false,
                         parent: String? = nil, lifecycle: String? = nil) -> CoreSession {
        CoreSession(id: remote ? "remote:mac:\(provider):\(id)" : "\(provider):session:\(id)",
                    provider: provider, parent: parent, label: label, cwd: cwd,
                    mode: mode, lifecycle: lifecycle, ask: ask,
                    terminal: host.map { CoreTerminal(app: "Ghostty", bundleId: $0, tty: tty) })
    }

    private func candidate(_ key: String, _ title: String,
                           bundle: String? = ghostty) -> DockAgentMatch.Candidate {
        .init(key: key, bundleID: bundle, title: title)
    }

    @Test("a window titled with the session's label is its sole claimant")
    func labelClaims() {
        let marks = DockAgentMark.marks(from: [
            session("a", label: "Fix dock switcher", cwd: "\(Self.home)/Downloads/JR-Bar"),
        ])
        let map = DockAgentMatch.match(marks: marks, candidates: [
            candidate("w1", "✳ Fix dock switcher"),
            candidate("w2", "zsh"),
        ])
        #expect(map["w1"]?.label == "Fix dock switcher")
        #expect(map["w2"] == nil)
    }

    @Test("two windows naming the same directory claim nothing — no guessing")
    func ambiguousCwd() {
        let marks = DockAgentMark.marks(from: [
            session("a", label: "Refactor", cwd: "/work/JR-Bar"),
        ])
        let map = DockAgentMatch.match(marks: marks, candidates: [
            candidate("w1", "JR-Bar"),
            candidate("w2", "~/JR-Bar — JR-Bar"),
        ])
        #expect(map.isEmpty)
    }

    @Test("a stronger claim on a window beats a weaker rival; a tie leaves it unmarked")
    func rivalsOnOneWindow() {
        // Both sessions run in JR-Bar; only one window carries a label.
        let marks = DockAgentMark.marks(from: [
            session("a", label: "Ship the dock", cwd: "/work/JR-Bar"),
            session("b", label: "Write docs", cwd: "/work/JR-Bar"),
        ])
        let map = DockAgentMatch.match(marks: marks, candidates: [
            candidate("w1", "Ship the dock — JR-Bar"),
            candidate("w2", "JR-Bar"),
        ])
        #expect(map["w1"]?.sessionID.hasSuffix("a") == true,
                "the label outranks b's directory claim on the same window")
        #expect(map["w2"] == nil,
                "both sessions claim w2 only by directory — a tie, so no mark")
    }

    @Test("only the session's host app can claim it")
    func hostFilter() {
        let marks = DockAgentMark.marks(from: [session("a", label: "Deploy fix")])
        let map = DockAgentMatch.match(marks: marks, candidates: [
            candidate("safari", "Deploy fix — Notes", bundle: "com.apple.Safari"),
            candidate("orphan", "Deploy fix", bundle: nil),
        ])
        #expect(map.isEmpty)
    }

    @Test("the tty is the strongest evidence a title can carry")
    func ttyWins() {
        let marks = DockAgentMark.marks(from: [
            session("a", label: "Tests", cwd: "/work/JR-Bar", tty: "/dev/ttys004"),
        ])
        let map = DockAgentMatch.match(marks: marks, candidates: [
            candidate("w1", "Tests — JR-Bar"),
            candidate("w2", "zsh — ttys004"),
        ])
        #expect(map["w2"] != nil)
        #expect(map["w1"] == nil)
    }

    @Test("history, workers, remote rows and host-less rows never mark a window")
    func onlyLiveLocalMainSessions() {
        let marks = DockAgentMark.marks(from: [
            session("done", label: "Finished", lifecycle: "completed"),
            session("worker", label: "Worker", parent: "claude:session:x"),
            session("remote", label: "Elsewhere", remote: true),
            session("nohost", label: "Nowhere", host: nil),
            session("live", label: "Live one"),
        ])
        #expect(marks.map(\.label) == ["Live one"])
    }

    @Test("an ask makes the mark waiting — the lane's sort key")
    func waitingMark() {
        let marks = DockAgentMark.marks(from: [
            session("a", label: "Asker", mode: "waiting",
                    ask: CoreAsk(kind: "permission", summary: "Run   rm -rf build?")),
            session("b", label: "Worker bee", mode: "tool_running"),
        ])
        #expect(marks[0].isWaiting && marks[0].isLive && marks[0].urgency == 0)
        #expect(marks[0].statusLine == "Run rm -rf build?")
        #expect(!marks[1].isWaiting && marks[1].isLive)
    }

    @Test("a fallback label — the directory's own name — does not outrank a directory claim")
    func fallbackLabelIsNotALabel() {
        let mark = DockAgentMark.marks(from: [session("a", label: "JR-Bar", cwd: "/work/JR-Bar")])[0]
        #expect(DockAgentMatch.evidence(title: "JR-Bar", for: mark) == .cwdLeaf)
        let tilde = DockAgentMark.marks(from: [
            session("b", label: "Other", cwd: "\(Self.home)/Code/app"),
        ])[0]
        #expect(DockAgentMatch.evidence(title: "zsh ~/Code/app", for: tilde) == .cwdPath)
    }

    @Test("needles match on token boundaries, never inside a longer word")
    func tokenBoundaries() {
        #expect(DockAgentMatch.containsToken("jr-bar — zsh", "jr-bar"))
        #expect(!DockAgentMatch.containsToken("jr-bar-old", "jr-bar"))
        #expect(!DockAgentMatch.containsToken("apple", "app"))
        #expect(DockAgentMatch.containsToken("✳ ship it", "ship it"))
        #expect(DockAgentMatch.containsToken("apple app", "app"))
    }

    @Test("the header counts the most urgent state only")
    func headerSummary() {
        let marks = DockAgentMark.marks(from: [
            session("a", label: "One", mode: "waiting", ask: CoreAsk(summary: "?")),
            session("b", label: "Two", mode: "working"),
            session("c", label: "Three", mode: "working"),
        ])
        #expect(DockAgentMatch.headerSummary(marks) == "1 agent waiting")
        #expect(DockAgentMatch.headerSummary(Array(marks.dropFirst())) == "2 agents working")
        #expect(DockAgentMatch.headerSummary([]) == nil)
    }

    @Test("the locator direction inverts the exclusive pairs")
    func sessionToWindow() {
        let marks = DockAgentMark.marks(from: [
            session("a", label: "Alpha task"), session("b", label: "Beta task"),
        ])
        let windows = DockAgentMatch.windows(for: marks, candidates: [
            candidate("w1", "Beta task"), candidate("w2", "Alpha task"),
        ])
        #expect(windows["claude:session:a"] == "w2")
        #expect(windows["claude:session:b"] == "w1")
    }

    // MARK: App-hosted agents

    static let claudeApp = "com.anthropic.claudefordesktop"
    static let codexApp = "com.openai.codex"

    @Test("Claude's only window carries its waiting session over nine working ones, and leads ⌥⇥")
    func soleAppWindow() {
        var sessions = (1...9).map { session("w\($0)", label: "Working \($0)", host: Self.claudeApp) }
        sessions.insert(session("ask", label: "Asker", mode: "waiting",
                                ask: CoreAsk(openedAt: 100, summary: "Allow Bash?"), host: Self.claudeApp),
                        at: 4)
        let marks = DockAgentMark.marks(from: sessions)
        let map = DockAgentMatch.match(marks: marks, candidates: [
            candidate("front", "zsh"),
            candidate("claude", "Claude", bundle: Self.claudeApp),
        ])
        #expect(map["claude"]?.sessionID == "claude:session:ask")
        #expect(map["front"] == nil)
        // The switcher: the waiting agent's window leads and takes the pick.
        func item(_ id: String, pid: pid_t, title: String) -> SwitcherItem {
            SwitcherItem(id: id, pid: pid, appName: title, icon: nil, title: title,
                         minimized: false, onScreen: true, element: nil, windowID: nil)
        }
        let items = DockSwitcherList.annotate(
            [item("front", pid: 1, title: "zsh"), item("claude", pid: 2, title: "Claude")],
            marks: marks, bundleID: { $0 == 1 ? Self.ghostty : Self.claudeApp })
        let lane = DockSwitcherList.needsYouFirst(items)
        #expect(lane.items.first?.id == "claude" && lane.selection == 0)
        // The locator only raises a window that is the session's own.
        #expect(SessionWindowLocator.locate(sessionID: "claude:session:ask", marks: marks, items: items,
                                            bundleID: { $0 == 1 ? Self.ghostty : Self.claudeApp }) == nil)
        #expect(DockAgentMatch.windows(for: marks, candidates: [
            candidate("claude", "Claude", bundle: Self.claudeApp)]).isEmpty)
    }

    @Test("of several waiting sessions, the sole window carries the one that has waited longest")
    func soleWindowOldestAsk() {
        let marks = DockAgentMark.marks(from: [
            session("new", label: "Newer", mode: "waiting", ask: CoreAsk(openedAt: 300, summary: "?"),
                    host: Self.codexApp, provider: "codex"),
            session("old", label: "Older", mode: "waiting", ask: CoreAsk(openedAt: 200, summary: "?"),
                    host: Self.codexApp, provider: "codex"),
        ])
        let map = DockAgentMatch.match(marks: marks, candidates: [
            candidate("chatgpt", "ChatGPT", bundle: Self.codexApp),
        ])
        #expect(map["chatgpt"]?.sessionID == "codex:session:old")
    }

    @Test("two ChatGPT windows: nothing says which holds what, so neither is marked")
    func twoAppWindowsNoGuess() {
        let marks = DockAgentMark.marks(from: [
            session("a", label: "Asker", mode: "waiting", ask: CoreAsk(openedAt: 100, summary: "?"),
                    host: Self.codexApp, provider: "codex"),
            session("b", label: "Worker", host: Self.codexApp, provider: "codex"),
        ])
        let map = DockAgentMatch.match(marks: marks, candidates: [
            candidate("one", "ChatGPT", bundle: Self.codexApp),
            candidate("two", "ChatGPT", bundle: Self.codexApp),
        ])
        #expect(map.isEmpty)
        let idle = DockAgentMark.marks(from: [
            session("c", label: "Resting", mode: "idle", host: Self.codexApp, provider: "codex"),
        ])
        #expect(DockAgentMatch.match(marks: idle, candidates: [
            candidate("one", "ChatGPT", bundle: Self.codexApp)]).isEmpty,
                "an idle session is no live mark")
    }
}
