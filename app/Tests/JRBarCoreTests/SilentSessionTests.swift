import Foundation
import Testing
@testable import JRBarCore

@Suite("Silent sessions")
struct SilentSessionTests {
    private static let now = Date(timeIntervalSince1970: 1_800_000_000)

    private static func session(_ id: String = "claude:run", mode: String = "working", event: String? = "PostToolUse",
                                quietFor seconds: Double, stale: Bool = false, kind: String = "main",
                                parent: String? = nil) -> CoreSession {
        let signal = now.timeIntervalSince1970 - seconds
        return CoreSession(id: id, provider: "claude", kind: kind, parent: parent, label: id, mode: mode,
                           since: signal, updatedAt: signal, stale: stale, event: event)
    }

    @Test("ten minutes of silence with no tool open is silent; less is not")
    func threshold() {
        #expect(SilentSession.threshold == 600)
        #expect(SilentSession.silence(of: Self.session(quietFor: 599), now: Self.now) == nil)
        #expect(SilentSession.silence(of: Self.session(quietFor: 600), now: Self.now) == 600)
        #expect(SilentSession.silence(of: Self.session(quietFor: 3600), now: Self.now) == 3600)
    }

    @Test("a tool started and not finished is a long build, not silence")
    func openToolCall() {
        let building = Self.session(mode: "tool_running", event: "PreToolUse", quietFor: 3600)
        #expect(SilentSession.hasOpenToolCall(building))
        #expect(SilentSession.silence(of: building, now: Self.now) == nil)
        let longTask = Self.session(mode: "long_task_progress", event: nil, quietFor: 3600)
        #expect(SilentSession.silence(of: longTask, now: Self.now) == nil)
        // The finish of the call hands the row back to the clock.
        let finished = Self.session(mode: "working", event: "PostToolUse", quietFor: 3600)
        #expect(!SilentSession.hasOpenToolCall(finished))
        #expect(SilentSession.silence(of: finished, now: Self.now) == 3600)
    }

    @Test("only a live working row can be silent")
    func onlyWorking() {
        #expect(SilentSession.silence(of: Self.session(mode: "idle", quietFor: 3600), now: Self.now) == nil)
        #expect(SilentSession.silence(of: Self.session(mode: "completed", quietFor: 3600), now: Self.now) == nil)
        #expect(SilentSession.silence(of: Self.session(quietFor: 3600, stale: true), now: Self.now) == nil)
        #expect(SilentSession.silence(activity: .working, stale: false, openToolCall: false, lastSignal: nil, now: Self.now) == nil)
        #expect(SilentSession.silence(activity: .waiting, stale: false, openToolCall: false,
                                      lastSignal: Self.now.addingTimeInterval(-3600), now: Self.now) == nil)
    }

    @Test("each quiet stretch is said once, and again only after the session speaks")
    func watcherSaysEachStretchOnce() {
        var watcher = SilentSessionWatcher()
        let quiet = Self.session(quietFor: 700)
        let first = watcher.observe([quiet], now: Self.now)
        #expect(first.count == 1)
        #expect(first.first?.session == "claude:run")
        #expect(SilentSessionWatcher.title(first[0]) == "Claude session in Unknown project has been quiet for 11m 40s")
        // Same stretch (the same last signal), a minute later: nothing more.
        #expect(watcher.observe([quiet], now: Self.now.addingTimeInterval(60)).isEmpty)
        // It speaks (a fresh last signal), then goes quiet again: a new stretch.
        let spoke = Self.session(quietFor: 0)
        #expect(watcher.observe([spoke], now: Self.now).isEmpty)
        #expect(watcher.observe([spoke], now: Self.now.addingTimeInterval(2000)).count == 1)
    }

    @Test("workers, remote rows and open tools are never announced")
    func watcherSkips() {
        var watcher = SilentSessionWatcher()
        let worker = Self.session("claude:w", quietFor: 3600, kind: "worker", parent: "claude:run")
        let building = Self.session("claude:b", mode: "tool_running", event: "PreToolUse", quietFor: 3600)
        let remote = Self.session("remote:studio:claude:x", quietFor: 3600)
        #expect(watcher.observe([worker, building, remote], now: Self.now).isEmpty)
    }

    @Test("a muted session is left unsaid and is said once the mute ends")
    func watcherHoldsForMuted() {
        var watcher = SilentSessionWatcher()
        let quiet = Self.session(quietFor: 900)
        #expect(watcher.observe([quiet], now: Self.now, muted: { _ in true }).isEmpty)
        #expect(watcher.observe([quiet], now: Self.now.addingTimeInterval(30), muted: { _ in false }).count == 1)
    }

    @Test("a session that goes away is forgotten")
    func watcherForgets() {
        var watcher = SilentSessionWatcher()
        _ = watcher.observe([Self.session(quietFor: 900)], now: Self.now)
        _ = watcher.observe([], now: Self.now.addingTimeInterval(10))
        #expect(watcher.observe([Self.session(quietFor: 900)], now: Self.now.addingTimeInterval(20)).count == 1)
    }

    @Test("quiet's hold applies: only an everything level admits the banner")
    func bannerHeldByQuiet() {
        let notice = SilentSessionWatcher.Notice(session: "claude:run", label: "jr-bar", seconds: 720)
        #expect(SilentSessionWatcher.banner(for: notice, focus: nil)?.title == "jr-bar has been quiet for 12m")
        #expect(SilentSessionWatcher.banner(for: notice, focus: CoreFocus(mode: "normal"))?.session == "claude:run")
        #expect(SilentSessionWatcher.banner(for: notice, focus: CoreFocus(mode: "mute")) == nil)
        #expect(SilentSessionWatcher.banner(for: notice, focus: CoreFocus(mode: "dark")) == nil)
    }
}
