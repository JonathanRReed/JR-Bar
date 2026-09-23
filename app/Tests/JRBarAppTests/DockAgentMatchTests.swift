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
}
