import AppKit
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

    @Test("a live refresh keeps surviving cards' ids and stills and adds newcomers")
    func liveMerge() {
        let still = NSImage(size: NSSize(width: 4, height: 4))
        var a = DockPreviewWindow(id: 101, title: "Old title", minimized: false, fullScreen: nil,
                                  frame: nil, thumbnail: still, element: nil, windowID: 1)
        a.thumbnail = still
        let b = DockPreviewWindow(id: 102, title: "Closed", minimized: false, fullScreen: nil,
                                  frame: nil, thumbnail: nil, element: nil, windowID: 2)
        let fresh = [
            DockPreviewWindow(id: 900, title: "New title", minimized: true, fullScreen: nil,
                              frame: nil, thumbnail: nil, element: nil, windowID: 1),
            DockPreviewWindow(id: 901, title: "Brand new", minimized: false, fullScreen: nil,
                              frame: nil, thumbnail: nil, element: nil, windowID: 3),
        ]
        let merged = DockEnhanceMath.mergeWindows(old: [a, b], new: fresh)
        #expect(merged.map(\.id) == [101, 901], "the survivor keeps its card id; the closed one leaves")
        #expect(merged[0].title == "New title" && merged[0].minimized, "its state is the new truth")
        #expect(merged[0].thumbnail === still, "its still survives the refresh")
        #expect(DockEnhanceMath.cardsDiffer([a, b], merged))
        #expect(!DockEnhanceMath.cardsDiffer(merged, merged), "a no-op burst re-lays out nothing")
        let titleless = DockPreviewWindow(id: 5, title: "x", minimized: false, fullScreen: nil,
                                          frame: nil, thumbnail: nil, element: nil)
        #expect(!DockEnhanceMath.sameWindow(titleless, titleless),
                "with no id and no element, nothing proves two rows are one window")
    }

    @Test("a retitle alone asks for no stills; a newcomer or a window back from the Dock does")
    func liveStills() {
        let still = NSImage(size: NSSize(width: 4, height: 4))
        func card(_ id: Int, _ title: String, minimized: Bool = false, still: NSImage? = nil) -> DockPreviewWindow {
            DockPreviewWindow(id: id, title: title, minimized: minimized, fullScreen: nil,
                              frame: nil, thumbnail: still, element: nil, windowID: CGWindowID(id))
        }
        let parked = card(2, "Notes", minimized: true)
        let old = [card(1, "⠂ Claude", still: still), parked]
        #expect(!DockEnhanceMath.wantsStills(old: old, new: [card(1, "⠐ Claude", still: still), parked]),
                "a spinner retitle is a re-list, not a capture")
        #expect(!DockEnhanceMath.wantsStills(old: old, new: [card(1, "⠐ Claude", still: still),
                                                            card(2, "Notes (edited)", minimized: true)]),
                "a minimized card with no still already had its pass")
        #expect(DockEnhanceMath.wantsStills(old: old, new: old + [card(3, "New")]))
        #expect(DockEnhanceMath.wantsStills(old: old, new: [old[0], card(2, "Notes")]),
                "a window back from the Dock can be captured now")
    }

    @Test("a burst's refresh waits for the settle but never past the max wait")
    func observerMaxWait() {
        let debounce = DockWindowObserver.debounce, maxWait = DockWindowObserver.maxWait
        #expect(DockWindowObserver.delay(now: 10, burstStart: 10) == debounce)
        #expect(DockWindowObserver.delay(now: 10.2, burstStart: 10) == debounce)
        #expect(abs(DockWindowObserver.delay(now: 10.4, burstStart: 10) - (maxWait - 0.4)) < 1e-9,
                "the settle is cut short so the burst refreshes by its max wait")
        #expect(DockWindowObserver.delay(now: 10.9, burstStart: 10) == 0)
        #expect(maxWait > debounce && maxWait <= 0.5)
    }

    @Test("a spinner's retitles, faster than the settle, still refresh while they keep coming")
    func observerBurstRefreshes() async throws {
        let observer = DockWindowObserver()
        var changes: [TimeInterval] = []
        observer.onChange = { changes.append(ProcessInfo.processInfo.systemUptime) }
        let start = ProcessInfo.processInfo.systemUptime
        let burst = DockWindowObserver.maxWait * 3
        while ProcessInfo.processInfo.systemUptime - start < burst {
            observer.fire()
            try await Task.sleep(for: .milliseconds(40))
        }
        #expect(!changes.isEmpty, "a trailing-only settle never fired while the title kept spinning")
        observer.stop()
    }

    @Test("stopping the live watch forgets the app")
    func observerStops() {
        let observer = DockWindowObserver()
        observer.observe(pid: ProcessInfo.processInfo.processIdentifier, windows: [])
        observer.stop()
        #expect(observer.pid == nil)
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

    @Test("a still taken before the agent asked or moved on is stale — the daemon sets the cadence")
    func stillTagFollowsTheAgent() {
        let working = DockAgentMark.marks(from: [session("a", label: "Build")])[0]
        let waiting = DockAgentMark.marks(from: [session("a", label: "Build", waiting: true)])[0]
        let again = DockAgentMark.marks(from: [session("a", label: "Build")])[0]
        #expect(working.stillTag != waiting.stillTag, "an ask opening re-takes the still")
        #expect(working.stillTag == again.stillTag, "the same state keeps the cache")
        #expect(DockThumbnailer.cacheServes(age: 10, maxAge: DockThumbnailer.captureLifetime,
                                            cachedTag: working.stillTag, tag: working.stillTag))
        #expect(!DockThumbnailer.cacheServes(age: 10, maxAge: DockThumbnailer.captureLifetime,
                                             cachedTag: working.stillTag, tag: waiting.stillTag))
        #expect(!DockThumbnailer.cacheServes(age: 31, maxAge: DockThumbnailer.captureLifetime,
                                             cachedTag: nil, tag: nil), "past the half minute, always")
        #expect(DockThumbnailer.cacheServes(age: 3, maxAge: DockThumbnailer.captureLifetime,
                                            cachedTag: nil, tag: nil))
    }

    @Test("the live card plays only when asked for, on a card that carries stills")
    func liveCardGate() {
        func live(_ liveCard: Bool = true, thumbnails: Bool = true, granted: Bool = true,
                  compact: Bool = false, minimized: Bool = false, offscreen: Bool = false) -> Bool {
            DockEnhanceMath.streamsLive(liveCard: liveCard, thumbnails: thumbnails, granted: granted,
                                        compact: compact, minimized: minimized, offscreen: offscreen)
        }
        #expect(live())
        #expect(!live(false), "off by default — the recording dot stays off")
        #expect(!live(thumbnails: false))
        #expect(!live(granted: false))
        #expect(!live(compact: true), "the compact list never captures")
        #expect(!live(minimized: true), "a minimized window only when every window is captured")
        #expect(live(minimized: true, offscreen: true))
        #expect(DockLiveStill.framesPerSecond <= 10, "a thumbnail, not a video call")
    }

    @Test("a live card that couldn't start forgets its window, so the next hover tries again")
    func liveStillRetries() async throws {
        let live = DockLiveStill()
        var asked = 0
        live.lookup = { _, _ in
            asked += 1
            return nil
        }
        live.start(windowID: 42, pid: 1)
        #expect(live.windowID == 42, "the window is claimed while the start resolves")
        for _ in 0..<200 where live.windowID != nil { try await Task.sleep(for: .milliseconds(10)) }
        #expect(live.windowID == nil, "no such window: nothing is streaming")
        live.start(windowID: 42, pid: 1)
        for _ in 0..<200 where asked < 2 { try await Task.sleep(for: .milliseconds(10)) }
        #expect(asked == 2, "the same card hovered again asks again")
        live.stop()
    }

    @Test("a hovered card re-takes only an aged or out-of-date still, never a missing one")
    func hoverRefresh() {
        #expect(!DockThumbnailer.wantsHoverRefresh(hasStill: false, age: nil, cachedTag: nil, tag: nil),
                "a card with no still is the first pass's job")
        #expect(!DockThumbnailer.wantsHoverRefresh(hasStill: true, age: 2, cachedTag: nil, tag: nil),
                "a fresh glance keeps its still — no extra recording-dot blink")
        #expect(DockThumbnailer.wantsHoverRefresh(hasStill: true, age: 6, cachedTag: nil, tag: nil))
        #expect(DockThumbnailer.wantsHoverRefresh(hasStill: true, age: nil, cachedTag: nil, tag: nil),
                "a still whose cache entry lapsed is at least half a minute old")
        #expect(DockThumbnailer.wantsHoverRefresh(hasStill: true, age: 1, cachedTag: "a|working", tag: "a|waiting"))
    }
}
