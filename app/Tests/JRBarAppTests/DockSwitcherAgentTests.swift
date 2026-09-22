import Foundation
import Testing
@testable import JRBarApp
@testable import JRBarCore

/// The switcher's agent half: the "needs you" lane, the marks, and the
/// type-ahead that finds a window by the session it hosts.
struct DockSwitcherAgentTests {
    static let ghostty = "com.mitchellh.ghostty"

    private func mark(_ id: String, label: String, waiting: Bool = false,
                      openedAt: Double? = nil, cwd: String? = nil,
                      provider: String = "claude") -> DockAgentMark {
        let session = CoreSession(
            id: "\(provider):session:\(id)", provider: provider, label: label, cwd: cwd,
            mode: waiting ? "waiting" : "working",
            ask: waiting ? CoreAsk(openedAt: openedAt, summary: "Allow Bash?") : nil,
            terminal: CoreTerminal(app: "Ghostty", bundleId: Self.ghostty))
        return DockAgentMark.marks(from: [session])[0]
    }

    private func item(_ id: String, title: String, app: String = "Ghostty", pid: pid_t = 1,
                      agent: DockAgentMark? = nil) -> SwitcherItem {
        SwitcherItem(id: id, pid: pid, appName: app, icon: nil, title: title,
                     minimized: false, onScreen: true, element: nil, windowID: nil,
                     agent: agent)
    }

    @Test("a waiting agent's window leads the strip and takes the first pick")
    func laneLeads() {
        let asker = mark("a", label: "Ship it", waiting: true, openedAt: 100)
        let lane = DockSwitcherList.needsYouFirst([
            item("front", title: "Editor", app: "Xcode"),
            item("second", title: "Safari", app: "Safari"),
            item("term", title: "Ship it", agent: asker),
        ])
        #expect(lane.items.map(\.id) == ["term", "front", "second"])
        #expect(lane.selection == 0, "⌥⇥ once lands on the blocked agent")
    }

    @Test("no waiting agent keeps plain recency and the second-window start")
    func noLane() {
        let worker = mark("b", label: "Build", waiting: false)
        let lane = DockSwitcherList.needsYouFirst([
            item("front", title: "Editor"), item("term", title: "Build", agent: worker),
        ])
        #expect(lane.items.map(\.id) == ["front", "term"])
        #expect(lane.selection == 1)
    }

    @Test("the frontmost window never joins the lane; the longest wait leads")
    func laneOrder() {
        let old = mark("a", label: "Old ask", waiting: true, openedAt: 10)
        let new = mark("b", label: "New ask", waiting: true, openedAt: 50)
        let here = mark("c", label: "Here", waiting: true, openedAt: 1)
        let lane = DockSwitcherList.needsYouFirst([
            item("front", title: "Here", agent: here),
            item("n", title: "New ask", agent: new),
            item("o", title: "Old ask", agent: old),
        ])
        #expect(lane.items.map(\.id) == ["o", "n", "front"])
    }

    @Test("annotate marks only exclusive host windows")
    func annotate() {
        let marks = [mark("a", label: "Fix the dock")]
        let items = DockSwitcherList.annotate([
            item("t1", title: "✳ Fix the dock", pid: 1),
            item("t2", title: "zsh", pid: 1),
            item("s1", title: "Fix the dock — notes", app: "Safari", pid: 2),
        ], marks: marks, bundleID: { $0 == 1 ? Self.ghostty : "com.apple.Safari" })
        #expect(items.map { $0.agent?.label } == ["Fix the dock", nil, nil])
    }

    @Test("an app card carries its most urgent live session")
    func appCardMark() {
        let marks = [mark("a", label: "Working"), mark("b", label: "Asking", waiting: true)]
        #expect(DockSwitcherList.appMark(bundleID: Self.ghostty, marks: marks)?.label == "Asking")
        #expect(DockSwitcherList.appMark(bundleID: "com.apple.Safari", marks: marks) == nil)
        #expect(DockSwitcherList.appMark(bundleID: nil, marks: marks) == nil)
    }

    @Test("a drilled app puts its waiting window first")
    func drillOrder() {
        let asker = mark("a", label: "Asking", waiting: true)
        let rows = DockSwitcherList.waitingFirst([
            item("1", title: "zsh"), item("2", title: "Asking", agent: asker), item("3", title: "vim"),
        ])
        #expect(rows.map(\.id) == ["2", "1", "3"])
    }

    @Test("type-ahead finds a window by its session's label, directory or provider")
    func agentSearch() {
        var model = SwitcherModel()
        let codex = mark("c", label: "Refactor parser", cwd: "/work/JR-Bar", provider: "codex")
        model.open(with: [item("a", title: "Inbox", app: "Mail"),
                          item("b", title: "zsh", agent: codex)])
        for ch in "jrbar" { model.type(String(ch)) }
        #expect(model.items.map(\.id) == ["b"], "the cwd tail finds the terminal titled zsh")
        var byProvider = SwitcherModel()
        byProvider.open(with: [item("a", title: "Inbox", app: "Mail"),
                               item("b", title: "zsh", agent: codex)])
        for ch in "codex" { byProvider.type(String(ch)) }
        #expect(byProvider.items.map(\.id) == ["b"])
    }

    @Test("a lone ! narrows to waiting agents; more letters rank inside them")
    func waitingFilter() {
        var model = SwitcherModel()
        model.open(with: [
            item("a", title: "Inbox", app: "Mail"),
            item("b", title: "Tests", agent: mark("b", label: "Tests", waiting: true)),
            item("c", title: "Docs", agent: mark("c", label: "Docs", waiting: true)),
            item("d", title: "Build", agent: mark("d", label: "Build")),
        ])
        model.type("!")
        #expect(model.items.map(\.id) == ["b", "c"])
        model.type("d")
        model.type("o")
        #expect(model.items.map(\.id) == ["c"])
        model.backspace()
        model.backspace()
        model.backspace()
        #expect(model.items.count == 4)
    }

    @Test("⌘W guards a live agent's window, ⌘Q any window of an app hosting one")
    func guardedVerbs() {
        let working = mark("a", label: "Build")
        let other = mark("b", label: "Tests", waiting: true)
        let hosting = item("t", title: "Build", agent: working)
        let plain = item("p", title: "zsh")
        let marks = [working, other]
        #expect(DockSwitcherList.guardMark(verb: "w", item: hosting, marks: marks, bundleID: Self.ghostty)?.label == "Build")
        #expect(DockSwitcherList.guardMark(verb: "w", item: plain, marks: marks, bundleID: Self.ghostty) == nil,
                "closing a bare shell window harms no agent")
        #expect(DockSwitcherList.guardMark(verb: "q", item: plain, marks: marks, bundleID: Self.ghostty)?.label == "Tests",
                "quitting Ghostty ends every session in it — the most urgent one names the guard")
        #expect(DockSwitcherList.guardMark(verb: "q", item: plain, marks: marks, bundleID: "com.apple.Safari") == nil)
        for verb in ["m", "h", "f"] {
            #expect(DockSwitcherList.guardMark(verb: verb, item: hosting, marks: marks, bundleID: Self.ghostty) == nil)
        }
    }

    @Test("a guarded verb needs the same press twice within the window")
    func secondPress() {
        var guardState = DockAgentGuard()
        var presses: [Bool] = []
        presses.append(guardState.confirm("w:1", guarded: true, now: 0))
        #expect(guardState.isArmed("w:1", now: 1))
        presses.append(guardState.confirm("w:1", guarded: true, now: 1.5))
        #expect(!guardState.isArmed("w:1", now: 1.6), "the confirmed press disarms")
        presses.append(guardState.confirm("w:1", guarded: true, now: 10))
        presses.append(guardState.confirm("w:1", guarded: true, now: 12.5))
        presses.append(guardState.confirm("q:1", guarded: true, now: 12.6))
        presses.append(guardState.confirm("m:1", guarded: false, now: 12.7))
        // arm, confirm, arm, too slow (re-arm), another verb (re-arm), unguarded runs.
        #expect(presses == [false, true, false, false, false, true])
        #expect(guardState.armedKey == nil)
        #expect(DockAgentGuard.note(for: mark("z", label: "X", waiting: true), again: "⌘W again to close")
                == "Claude is waiting on you here — ⌘W again to close")
    }

    @Test("open honours the lane's start and clamps a bad one")
    func openSelection() {
        var model = SwitcherModel()
        model.open(with: [item("a", title: "A"), item("b", title: "B")], selection: 0)
        #expect(model.selection == 0)
        model.open(with: [item("a", title: "A")], selection: 5)
        #expect(model.selection == 0)
    }
}
