import Foundation
import Testing
@testable import JRBarApp
@testable import JRBarCore

/// The Dock preview's agent half: which card hosts which session, what
/// Close all may touch, and the answer path's refusals.
@MainActor
struct DockPreviewAgentTests {
    static let ghostty = "com.mitchellh.ghostty"

    private func session(_ id: String, label: String, waiting: Bool = false,
                         answerable: Bool? = nil, host: String = ghostty) -> CoreSession {
        CoreSession(id: "claude:session:\(id)", provider: "claude", label: label,
                    mode: waiting ? "waiting" : "working",
                    ask: waiting ? CoreAsk(summary: "Allow Bash?", answerable: answerable) : nil,
                    terminal: CoreTerminal(app: "Ghostty", bundleId: host))
    }

    private func window(_ id: Int, _ title: String) -> DockPreviewWindow {
        DockPreviewWindow(id: id, title: title, minimized: false, fullScreen: nil,
                          frame: nil, thumbnail: nil, element: nil)
    }

    @Test("cards take their exclusive session; the app lists every live one, waiting first")
    func agentMap() {
        let marks = DockAgentMark.marks(from: [
            session("a", label: "Build the thing"),
            session("b", label: "Answer me", waiting: true),
            session("c", label: "Elsewhere", host: "com.apple.Terminal"),
        ])
        let map = DockEnhanceMath.agentMap(
            windows: [window(1, "✳ Build the thing"), window(2, "zsh")],
            bundleID: Self.ghostty, marks: marks)
        #expect(map.cards[1]?.label == "Build the thing")
        #expect(map.cards[2] == nil)
        #expect(map.app.map(\.label) == ["Answer me", "Build the thing"],
                "the unmatched waiting session still counts for the header and its ask row")
        let none = DockEnhanceMath.agentMap(windows: [window(1, "x")], bundleID: nil, marks: marks)
        #expect(none.cards.isEmpty && none.app.isEmpty)
    }

    @Test("close all keeps the windows a live agent runs in")
    func closeAllSkipsAgents() {
        let marks = DockAgentMark.marks(from: [session("a", label: "Build the thing")])
        let windows = [window(1, "Build the thing"), window(2, "zsh"), window(3, "vim")]
        let agents = DockEnhanceMath.agentMap(windows: windows, bundleID: Self.ghostty, marks: marks).cards
        let split = DockEnhanceMath.closable(windows, agents: agents)
        #expect(split.close.map(\.id) == [2, 3])
        #expect(split.keep.map(\.id) == [1])
    }

    @Test("an embedded ask learns its session; a pinned one wins for its episode id")
    func asksKnowTheirSession() {
        let embedded = DockAgentMark.marks(from: [session("a", label: "Asker", waiting: true)])[0]
        #expect(embedded.ask?.session == "claude:session:a")
        let pinned = CoreAsk(session: "claude:session:a", summary: "Pinned", request: "request:v1:x")
        let withPin = DockAgentMark.marks(from: [session("a", label: "Asker", waiting: true)],
                                          asks: [pinned])[0]
        #expect(withPin.ask?.request == "request:v1:x")
    }

    @Test("Approve reports the daemon's verdict, never a guessed success")
    func answerPath() async {
        let ask = CoreAsk(session: "claude:session:a", summary: "?", request: "r1")
        var sent: [(String, Bool, String?)] = []
        let ok = await DockUtility.answer(ask, approve: true) { session, approve, request in
            sent.append((session, approve, request))
            return CoreReply(id: "1", ok: true)
        }
        #expect(ok == "Approved")
        #expect(sent.count == 1 && sent[0].0 == "claude:session:a" && sent[0].2 == "r1")
        let refused = await DockUtility.answer(ask, approve: false) { _, _, _ in
            CoreReply(id: "2", ok: false, error: CoreReplyError(code: "stale_request", message: "The ask moved on"))
        }
        #expect(refused == "Couldn't answer: The ask moved on")
        let down = await DockUtility.answer(ask, approve: true) { _, _, _ in
            throw CoreClientError.notConnected
        }
        #expect(down == "No answer from the monitor — the ask is still open")
        #expect(await DockUtility.answer(ask, approve: true, send: nil) == "The monitor is not answering")
    }

    @Test("the locator finds the one window hosting a session, and nothing when two claim it")
    func locator() {
        let marks = DockAgentMark.marks(from: [
            session("a", label: "Ship the dock"), session("b", label: "Write docs"),
        ])
        func item(_ id: String, _ title: String) -> SwitcherItem {
            SwitcherItem(id: id, pid: 7, appName: "Ghostty", icon: nil, title: title,
                         minimized: false, onScreen: id != "off", element: nil, windowID: 1)
        }
        let items = [item("w1", "zsh"), item("off", "✳ Ship the dock"), item("w3", "Write docs")]
        let hit = SessionWindowLocator.locate(sessionID: "claude:session:a", marks: marks,
                                              items: items, bundleID: { _ in Self.ghostty })
        #expect(hit?.id == "off", "a window on another Space is still found by its title")
        #expect(SessionWindowLocator.locate(sessionID: "claude:session:b", marks: marks,
                                            items: items, bundleID: { _ in Self.ghostty })?.id == "w3")
        let twins = [item("x", "Write docs"), item("y", "Write docs")]
        #expect(SessionWindowLocator.locate(sessionID: "claude:session:b", marks: marks,
                                            items: twins, bundleID: { _ in Self.ghostty }) == nil,
                "two windows claim it — the caller falls back to open_session")
        #expect(SessionWindowLocator.locate(sessionID: "claude:session:zzz", marks: marks,
                                            items: items, bundleID: { _ in Self.ghostty }) == nil)
    }

    @Test("an ask the daemon can't type into, or one with no session, never sends")
    func answerRefusals() async {
        var calls = 0
        let send: @MainActor (String, Bool, String?) async throws -> CoreReply = { _, _, _ in
            calls += 1
            return CoreReply(id: "x", ok: true)
        }
        let sealed = CoreAsk(session: "claude:session:a", answerable: false)
        #expect(await DockUtility.answer(sealed, approve: true, send: send) == "Answer this one in the session's window")
        #expect(await DockUtility.answer(CoreAsk(), approve: true, send: send) == "This ask has no session left to answer")
        let remote = CoreAsk(session: "remote:studio:claude:session:a")
        #expect(await DockUtility.answer(remote, approve: true, send: send) == "Runs on studio — answer it there")
        #expect(calls == 0)
    }
}
