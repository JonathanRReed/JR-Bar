import JRBarTestSupport
import AppKit
import Foundation
import Testing
@testable import JRBarApp
@testable import JRBarCore

/// Quit JR-Bar and open it again: the menu bar item must be there, every
/// time. The pure decisions behind that, with fakes for everything that
/// would touch the real bar, the real agent or the real lock.
@Suite("Menu bar — relaunch keeps the icon", .temporaryDirectory)
struct MenuBarRelaunchTests {
    private let t0 = Date(timeIntervalSince1970: 1_000_000)

    // MARK: The item's saved placement

    @MainActor
    @Test("a saved 'not visible' and an insane slot are cleared before the item registers; a ⌘-drag slot is kept")
    func healsPersistedPlacement() throws {
        let suite = ScratchDefaults.suiteName("relaunchHeal")
        let defaults = ScratchDefaults.open(suite)
        defer { ScratchDefaults.remove(suite) }
        let name = StatusItemController.autosaveName
        let visible = "NSStatusItem Visible \(name)"
        let position = StatusItemController.preferredPositionKey
        defaults.set(false, forKey: visible)
        defaults.set(-40.0, forKey: position)
        defaults.set(99_999.0, forKey: position + "-r2")
        defaults.set(false, forKey: "NSStatusItem Visible com.apple.someoneElse")
        let removed = StatusItemController.healPersistedPlacement(defaults: defaults)
        #expect(Set(removed) == [visible, position, position + "-r2"], "\(removed)")
        #expect(defaults.object(forKey: visible) == nil)
        #expect(defaults.object(forKey: position) == nil)
        #expect(defaults.object(forKey: "NSStatusItem Visible com.apple.someoneElse") != nil,
                "other items' records are not ours to touch")
        // A person's own placement, and a visible flag, stay.
        defaults.set(true, forKey: visible)
        defaults.set(512.0, forKey: position)
        #expect(StatusItemController.healPersistedPlacement(defaults: defaults).isEmpty)
        #expect(defaults.double(forKey: position) == 512)
        // A key that is not a number at all is junk.
        defaults.set("left", forKey: position)
        #expect(StatusItemController.healPersistedPlacement(defaults: defaults) == [position])
    }

    @Test("the real item counts as on the bar only with a window on a screen's top row")
    func onBarRowTable() {
        let screen = CGRect(x: 0, y: 0, width: 1512, height: 982)
        func frame(x: CGFloat, top: CGFloat, w: CGFloat = 28) -> CGRect {
            CGRect(x: x, y: 982 - top - 24, width: w, height: 24)
        }
        #expect(StatusItemController.looksOnBarRow(windowFrame: frame(x: 1100, top: 4), screens: [screen]))
        #expect(!StatusItemController.looksOnBarRow(windowFrame: nil, screens: [screen]), "no window: pending")
        #expect(!StatusItemController.looksOnBarRow(
            windowFrame: CGRect(x: 1100, y: -33, width: 28, height: 24), screens: [screen]), "parked below")
        #expect(StatusItemController.looksOnBarRow(windowFrame: frame(x: 1100, top: -30), screens: [screen]),
                "an auto-hidden bar slid the window up past the top: still the bar's row")
        #expect(!StatusItemController.looksOnBarRow(windowFrame: frame(x: 2000, top: 4), screens: [screen]),
                "off every screen")
        #expect(!StatusItemController.looksOnBarRow(windowFrame: frame(x: 1100, top: 4, w: 0), screens: [screen]))
        #expect(StatusItemController.looksOnBarRow(
            windowFrame: frame(x: -4000, top: 4, w: 5200), screens: [screen]),
                "a hiding spacer can put the midpoint offscreen while its right-edge icon stays visible")
        #expect(!StatusItemController.looksOnBarRow(
            windowFrame: frame(x: -4000, top: 4, w: 4000), screens: [screen]),
                "a spacer with its icon wholly offscreen is still parked")
        #expect(StatusItemController.looksOnBarRow(
            windowFrame: CGRect(x: 1700, y: 1100 - 4 - 24, width: 28, height: 24),
            screens: [screen, CGRect(x: 1512, y: 0, width: 1920, height: 1100)]), "a second display's bar")
    }

    // MARK: The watchdog

    private func proof(visible: Bool = true, onRow: Bool = false, draws: Bool = true) -> StatusIconProof {
        StatusIconProof(itemVisibleFlag: visible, itemOnRow: onRow, styleDrawsIcon: draws)
    }

    @Test("a drawn real item is proof; an item that is not on the row is not")
    func proofTable() {
        #expect(proof(onRow: true).proven)
        #expect(!proof().proven)
        #expect(proof(draws: false).proven, "a style that draws nothing has nothing to prove")
    }

    @Test("an icon that cannot be proven: shown if flagged hidden, else recreated after the patience, with the placement reset on the second try")
    func watchdogEscalation() {
        var state = StatusIconWatchdogState(launchedAt: t0)
        #expect(state.evaluate(proof(visible: false), now: t0) == .showItem)
        #expect(state.evaluate(proof(), now: t0) == .none, "patience first")
        #expect(state.evaluate(proof(), now: t0.addingTimeInterval(5.9)) == .none)
        let first = state.evaluate(proof(), now: t0.addingTimeInterval(6))
        guard case .recreateItem(let reset1, _) = first else { Issue.record("expected a recreate: \(first)"); return }
        #expect(!reset1)
        #expect(state.evaluate(proof(), now: t0.addingTimeInterval(10)) == .none, "the fresh item gets time to register")
        let second = state.evaluate(proof(), now: t0.addingTimeInterval(14))
        guard case .recreateItem(let reset2, _) = second else { Issue.record("expected a recreate: \(second)"); return }
        #expect(reset2, "twice means the saved slot may be the trouble")
        // Proven: the clock clears.
        #expect(state.evaluate(proof(onRow: true), now: t0.addingTimeInterval(16)) == .none)
        #expect(state.evaluate(proof(), now: t0.addingTimeInterval(17)) == .none)
    }

    @Test("recreating is for the launch window and for a person asking; a reopen acts at once")
    func watchdogWindowAndReopen() {
        var state = StatusIconWatchdogState(launchedAt: t0)
        let late = t0.addingTimeInterval(StatusIconWatchdogState.launchWindow + 60)
        _ = state.evaluate(proof(), now: late)
        #expect(state.evaluate(proof(), now: late.addingTimeInterval(10)) == .none,
                "a fullscreen app's hidden bar long after launch must not churn the item")
        state.reopened(now: late.addingTimeInterval(11))
        let step = state.evaluate(proof(), now: late.addingTimeInterval(11))
        guard case .recreateItem = step else { Issue.record("a reopen with no icon acts at once: \(step)"); return }
        // A reopen with the icon proven does nothing.
        var healthy = StatusIconWatchdogState(launchedAt: t0)
        healthy.reopened(now: t0)
        #expect(healthy.evaluate(proof(onRow: true), now: t0) == .none)
        // At most three fresh items for one launch.
        var capped = StatusIconWatchdogState(launchedAt: t0)
        var recreated = 0
        for step in 0..<12 {
            if case .recreateItem = capped.evaluate(proof(), now: t0.addingTimeInterval(Double(step) * 9)) {
                recreated += 1
            }
        }
        #expect(recreated == StatusIconWatchdogState.maxRecreations)
    }

    // MARK: The single-instance lock and a fast reopen

    private func lockDirectory() -> String {
        (TestTemporaryDirectory.currentURL.path + "/") + "jrbar-relaunch-lock-\(UUID().uuidString)"
    }

    @Test("a predecessor that is quitting is waited for, then the new launch takes the lock")
    func waitsForAQuittingPredecessor() throws {
        let dir = lockDirectory()
        defer { try? FileManager.default.removeItem(atPath: dir) }
        let old = try #require(SingleInstanceLock.acquire(stateDirectory: dir, environment: [:]))
        #expect(SingleInstanceLock.holderState(stateDirectory: dir) == .running)
        SingleInstanceLock.markQuitting(old)
        #expect(SingleInstanceLock.holderState(stateDirectory: dir) == .quitting)
        var polls = 0
        let wait = SingleInstanceLock.Wait(quitting: 10, unknown: 4, poll: 0.1, sleep: { _ in
            polls += 1
            // The old instance finishes quitting on the third poll.
            if polls == 3 { SingleInstanceLock.release(old) }
        })
        let fresh = SingleInstanceLock.acquire(stateDirectory: dir, environment: [:], wait: wait)
        #expect(fresh != nil && fresh! >= 0, "the relaunch got its lock")
        #expect(polls == 3)
        #expect(SingleInstanceLock.holderState(stateDirectory: dir) == .running)
        if let fresh { SingleInstanceLock.release(fresh) }
    }

    @Test("a live instance yields at once — no waiting for a holder that says it is running")
    func runningHolderYieldsWithoutWaiting() throws {
        let dir = lockDirectory()
        defer { try? FileManager.default.removeItem(atPath: dir) }
        let live = try #require(SingleInstanceLock.acquire(stateDirectory: dir, environment: [:]))
        var polls = 0
        let wait = SingleInstanceLock.Wait(quitting: 10, unknown: 4, poll: 0.1, sleep: { _ in polls += 1 })
        #expect(SingleInstanceLock.acquire(stateDirectory: dir, environment: [:], wait: wait) == nil)
        #expect(polls == 0)
        SingleInstanceLock.release(live)
    }

    @Test("a holder that is quitting but never lets go is waited on for a bound, then the newcomer yields")
    func quittingHolderThatHangsIsBounded() throws {
        let dir = lockDirectory()
        defer { try? FileManager.default.removeItem(atPath: dir) }
        let stuck = try #require(SingleInstanceLock.acquire(stateDirectory: dir, environment: [:]))
        SingleInstanceLock.markQuitting(stuck)
        var polls = 0
        let wait = SingleInstanceLock.Wait(quitting: 1, unknown: 4, poll: 0.1, sleep: { _ in polls += 1 })
        #expect(SingleInstanceLock.acquire(stateDirectory: dir, environment: [:], wait: wait) == nil)
        #expect(polls >= 9 && polls <= 11, "about ten polls of 0.1 s: \(polls)")
        SingleInstanceLock.release(stuck)
    }

    @Test("a holder that says nothing (an older build quitting) gets the shorter wait")
    func silentHolderGetsTheUnknownWait() throws {
        let dir = lockDirectory()
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: dir) }
        // An older build: it flocks the file and writes nothing.
        let fd = open(dir + "/app.lock", O_RDWR | O_CREAT, 0o644)
        try #require(fd >= 0)
        try #require(flock(fd, LOCK_EX | LOCK_NB) == 0)
        defer { close(fd) }
        var polls = 0
        let wait = SingleInstanceLock.Wait(quitting: 10, unknown: 0.5, poll: 0.1, sleep: { _ in polls += 1 })
        #expect(SingleInstanceLock.acquire(stateDirectory: dir, environment: [:], wait: wait) == nil)
        #expect(polls >= 4 && polls <= 6, "\(polls)")
    }

    // MARK: The launch and quit sources

    private func source(_ name: String) throws -> String {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appending(path: "Sources/JRBarApp/\(name)")
        return try String(contentsOf: url, encoding: .utf8)
    }

    @Test("the quit says it is quitting first, stops the utility and the item before the daemon's grace, and the lock last")
    func quitOrder() throws {
        let text = try source("AppDelegate.swift")
        let quit = try #require(text.range(of: "func applicationWillTerminate"))
        let shouldQuit = try #require(text.range(of: "func applicationShouldTerminate"))
        let deferredBody = String(text[shouldQuit.lowerBound..<quit.lowerBound])
        let earlyMarker = try #require(deferredBody.range(of: "SingleInstanceLock.markQuitting(instanceLockFD)"))
        let deferredGrace = try #require(deferredBody.range(of: "supervisor.stop(gracePeriod: 3.0)"))
        #expect(earlyMarker.lowerBound < deferredGrace.lowerBound,
                "a relaunch must see the quitting lock before the daemon's deferred stop")
        let body = String(text[quit.lowerBound...])
        func at(_ needle: String) throws -> String.Index {
            try #require(body.range(of: needle), "\(needle) is missing from the quit").lowerBound
        }
        let marked = try at("SingleInstanceLock.markQuitting")
        let utility = try at("menuBar.stop(forQuit: true)")
        let item = try at("statusItem?.tearDown()")
        let grace = try at("supervisor?.stop(gracePeriod: 3.0)")
        let lock = try at("SingleInstanceLock.release(instanceLockFD)")
        #expect(marked < utility)
        #expect(utility < item)
        #expect(item < grace, "the icon leaves with the quit, not behind the daemon's three seconds")
        #expect(grace < lock)
    }

    @Test("the launch waits out a quitting predecessor, and opening the running app again brings it up")
    func launchAndReopenWiring() throws {
        let text = try source("AppDelegate.swift")
        #expect(text.contains("SingleInstanceLock.acquire(wait: .launch"))
        #expect(text.contains("func applicationShouldHandleReopen"))
        #expect(text.contains("startStatusIconWatchdog(statusItem)"))
        let launch = try #require(text.range(of: "func applicationDidFinishLaunching"))
        let item = try #require(text.range(of: "StatusItemController()"))
        let watch = try #require(text.range(of: "startStatusIconWatchdog(statusItem)"))
        #expect(launch.lowerBound < item.lowerBound && item.lowerBound < watch.lowerBound)
    }
}
