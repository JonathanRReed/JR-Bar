import AppKit
import Foundation
import Testing
@testable import JRBarApp
@testable import JRBarCore

// MARK: - Test doubles

/// A lane the test steps by hand: a job waits until `runNext`, so "the
/// read is still out" is a fact the test holds, never a race. No thread,
/// no timer, no sleep.
@MainActor
private final class HandLane: DockPreviewLane {
    private var jobs: [() -> (@MainActor () -> Void)] = []
    var waiting: Int { jobs.count }

    func run<Answer: Sendable>(_ work: @escaping @Sendable () -> Answer,
                               then: @escaping @MainActor @Sendable (Answer) -> Void) {
        jobs.append {
            let answer = work()
            return { then(answer) }
        }
    }

    func startNext() -> (@MainActor () -> Void) { jobs.removeFirst()() }

    /// Run the oldest job and land its answer on main.
    func runNext() { startNext()() }
    func runAll() { while !jobs.isEmpty { runNext() } }
}

/// What the stand-in Accessibility answers, and every call it was asked
/// for. The real calls run on a worker thread, so the log is locked.
private final class FakeAX: @unchecked Sendable {
    private let lock = NSLock()
    private var windowsByPID: [pid_t: [DockPreviewWindow]] = [:]
    private var hungPIDs: Set<pid_t> = []
    private var readPIDs: [pid_t] = []
    private var closedIDs: [Int] = []
    private var raisedIDs: [Int] = []
    private var minimizedCalls: [(id: Int, to: Bool)] = []
    private var fullScreenCalls: [(id: Int, to: Bool)] = []
    private var failingCloses: Set<Int> = []
    private var refusingMinimize: Set<Int> = []
    private var fullScreenStates: [Int: Bool] = [:]
    private var frameCalls: [Int] = []
    private var frames: [Int: CGRect] = [:]
    private var refusingFrames: Set<Int> = []

    func answer(pid: pid_t, _ windows: [DockPreviewWindow]) { lock.withLock { windowsByPID[pid] = windows } }
    func hang(_ pid: pid_t, _ hung: Bool = true) {
        lock.withLock { if hung { hungPIDs.insert(pid) } else { hungPIDs.remove(pid) } }
    }
    func failClose(of id: Int) { lock.withLock { _ = failingCloses.insert(id) } }
    func refuseMinimize(of id: Int) { lock.withLock { _ = refusingMinimize.insert(id) } }
    func setFullScreenState(of id: Int, _ on: Bool) { lock.withLock { fullScreenStates[id] = on } }
    func refuseFrame(of id: Int) { lock.withLock { _ = refusingFrames.insert(id) } }
    var positioned: [Int] { lock.withLock { frameCalls } }

    func setFrame(_ window: DockPreviewWindow, _ frame: CGRect) -> Bool {
        lock.withLock {
            frameCalls.append(window.id)
            guard !refusingFrames.contains(window.id) else { return false }
            // The fake app accepts the request but constrains the width.
            frames[window.id] = CGRect(origin: frame.origin, size: CGSize(width: frame.width - 8, height: frame.height))
            return true
        }
    }

    func frame(_ window: DockPreviewWindow) -> CGRect? {
        lock.withLock { window.frame ?? frames[window.id] }
    }

    var reads: [pid_t] { lock.withLock { readPIDs } }
    var closed: [Int] { lock.withLock { closedIDs } }
    var raised: [Int] { lock.withLock { raisedIDs } }
    var minimized: [(id: Int, to: Bool)] { lock.withLock { minimizedCalls } }
    var fullScreened: [(id: Int, to: Bool)] { lock.withLock { fullScreenCalls } }

    func read(_ pid: pid_t, _ stamp: Int) -> DockPreviewAX.Reading {
        lock.withLock {
            readPIDs.append(pid)
            if hungPIDs.contains(pid) { return ([], true) }
            return (windowsByPID[pid] ?? [], false)
        }
    }

    func close(_ window: DockPreviewWindow) -> Bool {
        lock.withLock {
            closedIDs.append(window.id)
            return !failingCloses.contains(window.id)
        }
    }

    func raise(_ window: DockPreviewWindow) { lock.withLock { raisedIDs.append(window.id) } }

    func setMinimized(_ window: DockPreviewWindow, _ on: Bool) -> Bool {
        lock.withLock {
            minimizedCalls.append((window.id, on))
            return !refusingMinimize.contains(window.id)
        }
    }

    func fullScreen(_ window: DockPreviewWindow) -> Bool? {
        lock.withLock { fullScreenStates[window.id] }
    }

    /// The Dock's tiles, as the lane would walk them; nil is a Dock that
    /// does not answer.
    private var tiles: DockTileReading?
    private var tileWalks: [pid_t] = []
    func setTiles(_ reading: DockTileReading?) { lock.withLock { tiles = reading } }
    var walks: [pid_t] { lock.withLock { tileWalks } }
    func dockTiles(_ pid: pid_t) -> DockTileReading? {
        lock.withLock {
            tileWalks.append(pid)
            return tiles
        }
    }

    func setFullScreen(_ window: DockPreviewWindow, _ on: Bool) -> Bool {
        lock.withLock {
            fullScreenCalls.append((window.id, on))
            return true
        }
    }
}

/// One controller wired to a hand-stepped lane, a fake Accessibility and a
/// fake clock: nothing here touches an app, a window, a timer or the Dock.
@MainActor
private final class Bench {
    static let alphaPID: pid_t = 4100
    static let betaPID: pid_t = 4200

    let lane = HandLane()
    let ax = FakeAX()
    var clock: TimeInterval = 1_000
    /// The tiles the controller presented, in order.
    var presented: [String] = []
    let controller: DockEnhanceController

    init(agents: [DockAgentMark] = []) {
        let defaults = UserDefaults(suiteName: ScratchDefaults.suiteName("jrbar-dock-preview-async"))!
        // No driver: releasing or taking the hold can never touch the
        // real Dock's autohide.
        let hold = DockAutohideHold(driver: nil, persistence: defaults, fallbackWrite: { _ in })
        let switcher = DockSwitcherController(tap: SwitcherKeyTap())
        controller = DockEnhanceController(autohideHold: hold, switcher: switcher)
        controller.preferences.read = { DockEnhanceSettings(showThumbnails: false) }
        controller.agentMarks = { agents }
        let ax = self.ax
        controller.ax = DockPreviewAX(
            lane: lane,
            read: { ax.read($0, $1) },
            raise: { ax.raise($0) },
            close: { ax.close($0) },
            setMinimized: { ax.setMinimized($0, $1) },
            fullScreen: { ax.fullScreen($0) },
            setFullScreen: { ax.setFullScreen($0, $1) },
            setFrame: { ax.setFrame($0, $1) },
            frame: { ax.frame($0) },
            dockTiles: { ax.dockTiles($0) },
            newWindow: { _ in })
        controller.dockPID = { 777 }
        controller.mediaNow = { [unowned self] in self.clock }
        controller.accessibilityTrusted = true
        controller.running = true
        controller.uptime = { [unowned self] in self.clock }
        controller.apps = DockTileApps(
            forTile: { item, _ in
                switch item.title {
                case "Alpha": return DockTileApp(pid: Self.alphaPID, name: "Alpha", bundleID: "test.alpha",
                                                 bundleURL: nil, icon: nil, isTerminated: false)
                case "Beta": return DockTileApp(pid: Self.betaPID, name: "Beta", bundleID: "test.beta",
                                                bundleURL: nil, icon: nil, isTerminated: false)
                case "Ghost": return DockTileApp(pid: Self.alphaPID, name: "Ghost", bundleID: Self.ghostty,
                                                 bundleURL: nil, icon: nil, isTerminated: false)
                default: return nil
                }
            },
            forPID: { _ in nil })
        // The show's panel work is the one thing that would order a real
        // window front; the test records that it was asked instead.
        controller.presenter = { [unowned self] item, _ in self.presented.append(item.title ?? "") }
    }

    static let ghostty = "com.mitchellh.ghostty"

    func tile(_ title: String) -> DockAXItem {
        DockAXItem(element: AXUIElementCreateSystemWide(),
                   frame: CGRect(x: 100, y: 900, width: 60, height: 60),
                   title: title, url: nil, kind: .app)
    }

    /// Show `title`'s tile and let its read land.
    func showAndLand(_ title: String) {
        controller.showPreview(for: tile(title))
        lane.runAll()
    }
}

private func card(_ id: Int, _ title: String, minimized: Bool = false) -> DockPreviewWindow {
    DockPreviewWindow(id: id, title: title, minimized: minimized, fullScreen: nil,
                      frame: CGRect(x: 0, y: 0, width: 400, height: 300),
                      thumbnail: nil, element: nil, windowID: CGWindowID(id))
}

// MARK: - The show, split in two

extension DockSharedWorkerTests {
/// A hover preview's window read runs on the preview lane; the card lands
/// on main when it answers, or is dropped when the pointer has moved on.
@MainActor
@Suite("Dock preview, off the main thread")
struct DockPreviewAsyncTests {
    @Test("a show returns before the read finishes, and presents nothing until it lands")
    func showDoesNotWaitOnTheRead() {
        let bench = Bench()
        bench.ax.answer(pid: Bench.alphaPID, [card(1, "One"), card(2, "Two")])
        bench.controller.showPreview(for: bench.tile("Alpha"))
        #expect(bench.lane.waiting == 1, "the read is queued, not run")
        #expect(bench.ax.reads.isEmpty, "showPreview did not wait for the reader")
        #expect(bench.presented.isEmpty)
        #expect(!bench.controller.previewUp, "no header-only card while the read is out")
        #expect(bench.controller.preview.windows.isEmpty)

        bench.lane.runNext()
        #expect(bench.ax.reads == [Bench.alphaPID])
        #expect(bench.controller.preview.windows.map(\.title) == ["One", "Two"])
        #expect(bench.controller.preview.appName == "Alpha")
        #expect(bench.presented == ["Alpha"], "the panel is shown once, when the cards land")
        #expect(bench.controller.previewUp)
    }

    @Test("hiding before the answer drops it: the preview is untouched and no panel appears")
    func hideBeforeLandingDropsTheAnswer() {
        let bench = Bench()
        bench.ax.answer(pid: Bench.alphaPID, [card(1, "One")])
        bench.controller.showPreview(for: bench.tile("Alpha"))
        bench.controller.hidePreview()
        bench.lane.runNext()
        #expect(bench.controller.preview.windows.isEmpty, "the stale answer never reached the cards")
        #expect(bench.controller.preview.appName.isEmpty)
        #expect(bench.presented.isEmpty)
        #expect(!bench.controller.previewUp)
    }

    @Test("a retarget keeps the old panel's cards until the new list lands, and only the new one presents")
    func retargetSwapsAtLanding() {
        let bench = Bench()
        bench.ax.answer(pid: Bench.alphaPID, [card(1, "Alpha one")])
        bench.ax.answer(pid: Bench.betaPID, [card(11, "Beta one"), card(12, "Beta two")])
        bench.showAndLand("Alpha")
        #expect(bench.controller.preview.windows.map(\.title) == ["Alpha one"])

        bench.controller.showPreview(for: bench.tile("Beta"))
        #expect(bench.controller.preview.appName == "Alpha", "nothing is torn down while Beta reads")
        #expect(bench.controller.preview.windows.map(\.title) == ["Alpha one"])
        #expect(bench.presented == ["Alpha"])

        bench.lane.runNext()
        #expect(bench.controller.preview.appName == "Beta")
        #expect(bench.controller.preview.windows.map(\.title) == ["Beta one", "Beta two"])
        #expect(bench.presented == ["Alpha", "Beta"])
    }

    @Test("two shows in a row: the first answer is stale, only the second lands")
    func staleAnswerIsDropped() {
        let bench = Bench()
        bench.ax.answer(pid: Bench.alphaPID, [card(1, "Alpha one")])
        bench.ax.answer(pid: Bench.betaPID, [card(11, "Beta one")])
        bench.controller.showPreview(for: bench.tile("Alpha"))
        bench.controller.showPreview(for: bench.tile("Beta"))
        #expect(bench.lane.waiting == 2, "both jobs are queued, in order")
        bench.lane.runNext()
        #expect(bench.presented.isEmpty, "Alpha's retired job cannot populate the preview")
        #expect(bench.controller.preview.windows.isEmpty)
        bench.lane.runNext()
        #expect(bench.presented == ["Beta"])
        #expect(bench.controller.preview.windows.map(\.title) == ["Beta one"])
    }

    @Test("a burst of retargets reads only the latest app")
    func retiredQueuedReadsNeverReachAX() {
        let bench = Bench()
        bench.ax.answer(pid: Bench.alphaPID, [card(1, "Alpha one")])
        bench.ax.answer(pid: Bench.betaPID, [card(11, "Beta one")])
        for index in 0..<20 {
            bench.controller.showPreview(for: bench.tile(index.isMultiple(of: 2) ? "Alpha" : "Beta"))
        }
        #expect(bench.ax.reads.isEmpty)
        bench.lane.runAll()
        #expect(bench.ax.reads == [Bench.betaPID])
        #expect(bench.presented == ["Beta"])
        #expect(bench.controller.preview.windows.map(\.title) == ["Beta one"])
    }

    @Test("hiding cancels a queued read before Accessibility is called")
    func hiddenQueuedReadNeverReachesAX() {
        let bench = Bench()
        bench.controller.showPreview(for: bench.tile("Alpha"))
        bench.controller.hidePreview()
        bench.lane.runAll()
        #expect(bench.ax.reads.isEmpty)
        #expect(bench.presented.isEmpty)
    }

    @Test("releasing the controller retires its queued read")
    func releasedQueuedReadNeverReachesAX() {
        var bench: Bench? = Bench()
        let lane = bench!.lane
        let ax = bench!.ax
        bench!.controller.showPreview(for: bench!.tile("Alpha"))
        bench = nil
        lane.runAll()
        #expect(ax.reads.isEmpty)
    }

    @Test("an already started read records real backoff while the newest preview still lands")
    func startedReadKeepsItsRealResult() {
        let bench = Bench()
        bench.ax.hang(Bench.alphaPID)
        bench.ax.answer(pid: Bench.betaPID, [card(11, "Beta one")])
        bench.controller.showPreview(for: bench.tile("Alpha"))
        let deliver = bench.lane.startNext()
        #expect(bench.ax.reads == [Bench.alphaPID])
        bench.controller.showPreview(for: bench.tile("Beta"))
        deliver()
        #expect(bench.controller.switcher.axSkips(Bench.alphaPID, now: bench.clock))
        #expect(bench.presented.isEmpty)
        bench.lane.runAll()
        #expect(bench.ax.reads == [Bench.alphaPID, Bench.betaPID])
        #expect(bench.presented == ["Beta"])
    }

    @Test("retiring a queued minimized-window lookup skips its owner reads")
    func retiredMinimizedLookupNeverReachesAX() {
        for retarget in [false, true] {
            let bench = Bench()
            bench.ax.answer(pid: Bench.alphaPID, [card(1, "Hidden", minimized: true)])
            bench.ax.answer(pid: Bench.betaPID, [card(11, "Beta one")])
            bench.controller.minimizedRows = {
                [SwitcherWindowRow(pid: Bench.alphaPID, windowID: 1, title: "Hidden",
                                   bounds: CGRect(x: 0, y: 0, width: 400, height: 300), onScreen: false)]
            }
            let tile = DockAXItem(element: AXUIElementCreateSystemWide(),
                                  frame: CGRect(x: 100, y: 900, width: 60, height: 60),
                                  title: "Hidden", url: nil, kind: .minimizedWindow)
            bench.controller.showPreview(for: tile)
            if retarget {
                bench.controller.showPreview(for: bench.tile("Beta"))
            } else {
                bench.controller.hidePreview()
            }
            bench.lane.runAll()
            #expect(bench.ax.reads == (retarget ? [Bench.betaPID] : []))
            #expect(bench.presented == (retarget ? ["Beta"] : []))
        }
    }

    @Test("a current minimized-window lookup reads its owner and lands its card")
    func currentMinimizedLookupStillReads() {
        let bench = Bench()
        bench.ax.answer(pid: Bench.alphaPID, [card(1, "Hidden", minimized: true)])
        bench.controller.minimizedRows = {
            [SwitcherWindowRow(pid: Bench.alphaPID, windowID: 1, title: "Hidden",
                               bounds: CGRect(x: 0, y: 0, width: 400, height: 300), onScreen: false)]
        }
        bench.controller.apps.forPID = { pid in
            DockTileApp(pid: pid, name: "Alpha", bundleID: "test.alpha",
                        bundleURL: nil, icon: nil, isTerminated: false)
        }
        let tile = DockAXItem(element: AXUIElementCreateSystemWide(),
                              frame: CGRect(x: 100, y: 900, width: 60, height: 60),
                              title: "Hidden", url: nil, kind: .minimizedWindow)
        bench.controller.showPreview(for: tile)
        bench.lane.runAll()
        #expect(bench.ax.reads == [Bench.alphaPID])
        #expect(bench.presented == ["Hidden"])
        #expect(bench.controller.preview.windows.map(\.title) == ["Hidden"])
        #expect(bench.controller.preview.processIdentifier == Bench.alphaPID)
    }

    @Test("an app with no windows presents nothing, and never a header-only card")
    func windowlessAnswerPresentsNothing() {
        let bench = Bench()
        bench.ax.answer(pid: Bench.alphaPID, [])
        bench.showAndLand("Alpha")
        #expect(bench.presented.isEmpty)
        #expect(!bench.controller.previewUp)
        #expect(bench.controller.preview.windows.isEmpty)
    }

    @Test("a tile that is no running app needs no read at all")
    func unrunningTileReadsNothing() {
        let bench = Bench()
        bench.controller.showPreview(for: bench.tile("Nobody"))
        #expect(bench.lane.waiting == 0, "nothing to read, so nothing is queued")
        #expect(bench.ax.reads.isEmpty)
        #expect(bench.presented.isEmpty)
    }

    @Test("an app that did not answer rests: a second show inside the backoff never calls the reader")
    func unresponsiveAnswerRests() {
        let bench = Bench()
        bench.ax.hang(Bench.alphaPID)
        bench.showAndLand("Alpha")
        #expect(bench.ax.reads == [Bench.alphaPID])
        #expect(bench.presented.isEmpty, "a hung app earns no panel")
        #expect(bench.controller.switcher.axSkips(Bench.alphaPID, now: bench.clock))

        bench.clock += 5
        bench.controller.showPreview(for: bench.tile("Alpha"))
        #expect(bench.lane.waiting == 0, "resting: no job is queued")
        #expect(bench.ax.reads == [Bench.alphaPID], "the reader stays at one call")

        bench.clock += DockAXBackoff.backoff
        bench.ax.hang(Bench.alphaPID, false)
        bench.ax.answer(pid: Bench.alphaPID, [card(1, "One")])
        bench.controller.showPreview(for: bench.tile("Alpha"))
        #expect(bench.lane.waiting == 1, "after the backoff it is asked again")
        bench.lane.runNext()
        #expect(bench.ax.reads == [Bench.alphaPID, Bench.alphaPID])
        #expect(bench.presented == ["Alpha"])
    }

    @Test("a hang the ⌥⇥ strip saw spares the hover, and only that pid rests")
    func switcherHangSparesTheHover() {
        let bench = Bench()
        bench.ax.answer(pid: Bench.betaPID, [card(11, "Beta one")])
        bench.controller.switcher.noteAX(Bench.alphaPID, unresponsive: true, now: bench.clock)
        bench.controller.showPreview(for: bench.tile("Alpha"))
        #expect(bench.lane.waiting == 0)
        #expect(bench.ax.reads.isEmpty)
        bench.showAndLand("Beta")
        #expect(bench.presented == ["Beta"], "another app is asked as usual")
    }

    @Test("an answer clears the rest: a recovered app is asked on every show again")
    func answerClearsTheRest() {
        let bench = Bench()
        bench.ax.hang(Bench.alphaPID)
        bench.showAndLand("Alpha")
        bench.clock += DockAXBackoff.backoff + 1
        bench.ax.hang(Bench.alphaPID, false)
        bench.ax.answer(pid: Bench.alphaPID, [card(1, "One")])
        bench.showAndLand("Alpha")
        #expect(!bench.controller.switcher.axSkips(Bench.alphaPID, now: bench.clock), "it answered, so it no longer rests")
        bench.clock += 0.1
        bench.controller.showPreview(for: bench.tile("Alpha"))
        #expect(bench.lane.waiting == 1, "asked again at once: nothing rests it")
        bench.lane.runNext()
        #expect(bench.ax.reads.count == 3)
    }

    @Test("⌥`'s walk starts on the list that landed, not before")
    func frontWalkWaitsForTheList() {
        let bench = Bench()
        bench.ax.answer(pid: Bench.alphaPID, [card(1, "Front"), card(2, "Next")])
        bench.controller.showPreview(for: bench.tile("Alpha"), keyboardOpened: true)
        #expect(bench.controller.preview.selectedWindowID == nil, "no list yet: no walked card")
        bench.lane.runNext()
        #expect(bench.controller.preview.selectedWindowID == 2, "the app's next window, as ⌥⇥ lands")
    }

    @Test("⌥`'s walk is dropped with the show when the list never lands")
    func frontWalkDroppedWithTheShow() {
        let bench = Bench()
        bench.ax.answer(pid: Bench.alphaPID, [card(1, "Front"), card(2, "Next")])
        bench.controller.showPreview(for: bench.tile("Alpha"), keyboardOpened: true)
        bench.controller.hidePreview()
        bench.lane.runNext()
        #expect(bench.controller.preview.selectedWindowID == nil)
    }

    /// The one test that runs the real lane. It asks nothing of the main
    /// queue's turnaround — other suites hold main for seconds at a time in
    /// a full run — so it proves the two facts that need none: the show
    /// has returned while the read is still blocked on the worker, and the
    /// worker's read is what finishes once released. That the answer then
    /// lands on main, in order, is `DockAXWorkerTests`'s.
    @Test("through the real preview lane the show returns while the reader is blocked on the worker")
    func realLaneDoesNotBlockMain() async {
        final class Held: @unchecked Sendable {
            let entered = DispatchSemaphore(value: 0)
            let release = DispatchSemaphore(value: 0)
            let finished = DispatchSemaphore(value: 0)
            let ranOnMain = NSLock()
            var onMain = false
        }
        let held = Held()
        let bench = Bench()
        bench.controller.ax.lane = DockAXPreviewLane()
        bench.controller.ax.read = { _, _ in
            held.ranOnMain.withLock { held.onMain = Thread.isMainThread }
            held.entered.signal()
            // A bound, so a failing run releases itself.
            _ = held.release.wait(timeout: .now() + 20)
            held.finished.signal()
            return ([card(1, "One")], false)
        }
        bench.controller.showPreview(for: bench.tile("Alpha"))
        // This line is reached with the reader still blocked: the show did not wait for it.
        #expect(await Self.signalled(held.entered), "the worker took the read")
        #expect(bench.controller.preview.windows.isEmpty, "nothing has landed while it is blocked")
        #expect(bench.presented.isEmpty)
        // The answer that follows is stale by then: it is dropped when it reaches main.
        bench.controller.hidePreview()
        held.release.signal()
        #expect(await Self.signalled(held.finished), "released, the reader finishes")
        #expect(held.ranOnMain.withLock { held.onMain } == false, "the read ran on the worker, never on main")
    }

    private static func signalled(_ semaphore: DispatchSemaphore, within seconds: Double = 10) async -> Bool {
        await Task.detached { waitForSignal(semaphore, seconds: seconds) }.value
    }

    private nonisolated static func waitForSignal(_ semaphore: DispatchSemaphore, seconds: Double) -> Bool {
        semaphore.wait(timeout: .now() + seconds) == .success
    }
}

}

// MARK: - The live refresh

@MainActor
@Suite("Dock preview live refresh, off the main thread")
struct DockPreviewLiveRefreshTests {
    /// A preview that has landed with two windows, the lane idle.
    private func landed() -> Bench {
        let bench = Bench()
        bench.ax.answer(pid: Bench.alphaPID, [card(1, "One"), card(2, "Two")])
        bench.showAndLand("Alpha")
        bench.ax.answer(pid: Bench.alphaPID, [])
        return bench
    }

    @Test("bursts while a refresh reads cost exactly one extra read, never one each")
    func burstsFoldIntoOneRerun() {
        let bench = landed()
        bench.ax.answer(pid: Bench.alphaPID, [card(1, "One"), card(2, "Two")])
        let before = bench.ax.reads.count
        for _ in 0..<6 { bench.controller.refreshLiveWindows(force: true) }
        #expect(bench.lane.waiting == 1, "one read in flight, the other five folded into a re-run")
        bench.lane.runNext()
        #expect(bench.lane.waiting == 1, "the re-run is queued when the first lands")
        bench.lane.runNext()
        #expect(bench.lane.waiting == 0)
        #expect(bench.ax.reads.count - before == 2, "the read, and one more for the whole burst")
    }

    @Test("a refresh that hears nothing keeps the cards, and a burst that follows can read again")
    func unresponsiveRefreshKeepsTheCards() {
        let bench = landed()
        bench.ax.hang(Bench.alphaPID)
        bench.controller.refreshLiveWindows(force: true)
        bench.lane.runNext()
        #expect(bench.controller.preview.windows.map(\.title) == ["One", "Two"], "no news is not an empty list")
        #expect(bench.controller.previewUp, "a busy app does not close its own open preview")

        bench.controller.refreshLiveWindows(force: true)
        #expect(bench.lane.waiting == 0, "it rests now: the burst is skipped, not asked")
    }

    @Test("a genuinely empty answer still hides the preview: the last window closed elsewhere")
    func emptyAnswerHides() {
        let bench = landed()
        bench.ax.answer(pid: Bench.alphaPID, [])
        bench.controller.refreshLiveWindows(force: true)
        bench.lane.runNext()
        #expect(bench.controller.preview.windows.isEmpty)
        #expect(!bench.controller.previewUp)
    }

    @Test("an answer that changes the list lands on the cards, keeping survivors' ids")
    func answerMergesIntoTheCards() {
        let bench = landed()
        bench.ax.answer(pid: Bench.alphaPID, [card(2, "Two, retitled"), card(3, "Three")])
        bench.controller.refreshLiveWindows(force: true)
        bench.lane.runNext()
        #expect(bench.controller.preview.windows.map(\.title) == ["Two, retitled", "Three"])
        #expect(bench.controller.preview.windows.first?.id == 2)
    }

    @Test("a refresh in flight when the preview hides is dropped")
    func staleRefreshIsDropped() {
        let bench = landed()
        bench.ax.answer(pid: Bench.alphaPID, [card(9, "Nine")])
        bench.controller.refreshLiveWindows(force: true)
        bench.controller.hidePreview()
        bench.lane.runNext()
        #expect(bench.controller.preview.windows.map(\.title) == ["One", "Two"], "the stale list never landed")
    }

    @Test("no refresh runs while a retarget's list is still out")
    func noRefreshDuringARetarget() {
        let bench = landed()
        bench.ax.answer(pid: Bench.betaPID, [card(11, "Beta one")])
        bench.controller.showPreview(for: bench.tile("Beta"))
        let before = bench.lane.waiting
        bench.controller.refreshLiveWindows(force: true)
        #expect(bench.lane.waiting == before, "Alpha's burst is not read against Beta's show")
    }
}

// MARK: - The card verbs

/// Every card verb writes through the preview lane and lands its result
/// by the card's id, on the generation it was pressed under.
@MainActor
@Suite("Dock preview verbs, off the main thread")
struct DockPreviewVerbAsyncTests {
    private static let liveTitle = "✳ Build the thing"

    /// A live agent's session, hosted by Ghostty.
    private func liveMarks() -> [DockAgentMark] {
        DockAgentMark.marks(from: [
            CoreSession(id: "claude:session:a", provider: "claude", label: "Build the thing", mode: "working",
                        terminal: CoreTerminal(app: "Ghostty", bundleId: Bench.ghostty)),
        ])
    }

    /// A landed preview of Alpha with cards 1 and 2, and its panel's
    /// wiring (never shown) to press the verbs through.
    private func landed(titles: [String] = ["One", "Two"]) -> (Bench, DockPreviewActions) {
        let bench = Bench()
        bench.ax.answer(pid: Bench.alphaPID, titles.enumerated().map { card($0.offset + 1, $0.element) })
        bench.showAndLand("Alpha")
        return (bench, bench.controller.ensurePanel().actions)
    }

    private func window(_ bench: Bench, _ id: Int) -> DockPreviewWindow {
        bench.controller.preview.windows.first { $0.id == id }!
    }

    @Test("× writes off main and drops the card only once the close was made")
    func closeLandsByID() {
        let (bench, actions) = landed()
        actions.onClose?(window(bench, 1))
        #expect(bench.ax.closed.isEmpty, "the press returned before the AX write ran")
        #expect(bench.controller.preview.windows.map(\.id) == [1, 2], "the card waits for the answer")
        bench.lane.runNext()
        #expect(bench.ax.closed == [1])
        #expect(bench.controller.preview.windows.map(\.id) == [2])
    }

    @Test("a close the window refused keeps its card")
    func refusedCloseKeepsTheCard() {
        let (bench, actions) = landed()
        bench.ax.failClose(of: 1)
        actions.onClose?(window(bench, 1))
        bench.lane.runNext()
        #expect(bench.controller.preview.windows.map(\.id) == [1, 2])
    }

    @Test("closing the last card hides the preview")
    func closingTheLastCardHides() {
        let (bench, actions) = landed(titles: ["Only"])
        actions.onClose?(window(bench, 1))
        bench.lane.runNext()
        #expect(bench.controller.preview.windows.isEmpty)
        #expect(!bench.controller.previewUp)
    }

    @Test("a card that left the list before the answer drops the result")
    func closeOfAGoneCardIsDropped() {
        let (bench, actions) = landed()
        actions.onClose?(window(bench, 1))
        bench.controller.preview.windows.removeAll { $0.id == 1 }
        bench.lane.runNext()
        #expect(bench.controller.preview.windows.map(\.id) == [2], "card 2 is not touched")
        #expect(bench.controller.previewUp)
    }

    @Test("– sets the card's state from the write's answer, by id")
    func minimizeLandsByID() {
        let (bench, actions) = landed()
        actions.onMinimize?(window(bench, 2))
        #expect(bench.ax.minimized.isEmpty)
        bench.lane.runNext()
        #expect(bench.ax.minimized.map(\.id) == [2] && bench.ax.minimized.first?.to == true)
        #expect(bench.controller.preview.windows.first { $0.id == 2 }?.minimized == true)
        #expect(bench.controller.preview.windows.first { $0.id == 1 }?.minimized == false)
    }

    @Test("a refused minimize leaves the card as it was")
    func refusedMinimizeIsNotShown() {
        let (bench, actions) = landed()
        bench.ax.refuseMinimize(of: 2)
        actions.onMinimize?(window(bench, 2))
        bench.lane.runNext()
        #expect(bench.controller.preview.windows.first { $0.id == 2 }?.minimized == false)
        #expect(bench.controller.preview.actionFailure == "Could not minimize this window. Try again.")
    }

    @Test("fullscreen reads the window's state and writes the opposite, both off main")
    func fullScreenFlips() {
        let (bench, actions) = landed()
        bench.ax.setFullScreenState(of: 1, false)
        actions.onFullScreen?(window(bench, 1))
        #expect(bench.ax.fullScreened.isEmpty)
        bench.lane.runNext()
        #expect(bench.ax.fullScreened.map(\.id) == [1] && bench.ax.fullScreened.first?.to == true)
        #expect(bench.controller.preview.windows.first { $0.id == 1 }?.fullScreen == true)
    }

    @Test("a window that offers no fullscreen write is left alone")
    func fullScreenUnsupported() {
        let (bench, actions) = landed()
        actions.onFullScreen?(window(bench, 1))
        bench.lane.runNext()
        #expect(bench.ax.fullScreened.isEmpty)
        #expect(bench.controller.preview.windows.first { $0.id == 1 }?.fullScreen == nil)
        #expect(bench.controller.preview.actionFailure == "Could not change full screen. Try again.")
    }

    @Test("a successful action clears the last failure without changing an agent warning")
    func successfulRetryClearsFailure() {
        let (bench, actions) = landed()
        bench.ax.failClose(of: 1)
        bench.controller.preview.headerNote = "Kept the window an agent is running in"
        actions.onClose?(window(bench, 1))
        bench.lane.runNext()
        #expect(bench.controller.preview.actionFailure == "Could not close this window. Try again.")
        actions.onMinimize?(window(bench, 1))
        bench.lane.runNext()
        #expect(bench.controller.preview.actionFailure == nil)
        #expect(bench.controller.preview.headerNote == "Kept the window an agent is running in")
    }

    @Test("a refused restore stops positioning and leaves the card minimized")
    func positionStopsAtRefusedRestore() {
        let (bench, _) = landed()
        bench.controller.preview.windows[0].minimized = true
        bench.ax.refuseMinimize(of: 1)
        bench.controller.position(window(bench, 1), failure: "Could not tile this window. Try again.") {
            _ in CGRect(x: 100, y: 200, width: 300, height: 400)
        }
        bench.lane.runNext()
        #expect(bench.ax.positioned.isEmpty)
        #expect(bench.controller.preview.windows[0].minimized)
        #expect(bench.controller.preview.actionFailure == "Could not tile this window. Try again.")
    }

    @Test("a refused move records the restore it accepted but keeps the original frame")
    func partialPositionRecordsOnlyAcceptedWrites() {
        let (bench, _) = landed()
        let original = bench.controller.preview.windows[0].frame
        bench.controller.preview.windows[0].minimized = true
        bench.ax.refuseFrame(of: 1)
        bench.controller.position(window(bench, 1), failure: "Could not move this window. Try again.") {
            _ in CGRect(x: 100, y: 200, width: 300, height: 400)
        }
        bench.lane.runNext()
        #expect(!bench.controller.preview.windows[0].minimized)
        #expect(bench.controller.preview.windows[0].frame == original)
        #expect(bench.controller.preview.actionFailure == "Could not move this window. Try again.")
    }

    @Test("positioning reads the app's resulting frame rather than assuming the requested size")
    func positionUsesReportedFrame() {
        let (bench, _) = landed()
        bench.controller.preview.windows[0].minimized = true
        bench.controller.preview.actionFailure = "Earlier failure"
        bench.controller.position(window(bench, 1), failure: "Could not tile this window. Try again.") {
            _ in CGRect(x: 100, y: 200, width: 300, height: 400)
        }
        #expect(bench.controller.preview.windows[0].minimized)
        bench.lane.runNext()
        #expect(bench.controller.preview.windows[0].frame == CGRect(x: 100, y: 200, width: 292, height: 400))
        #expect(!bench.controller.preview.windows[0].minimized)
        #expect(bench.controller.preview.actionFailure == nil)
    }

    @Test("a stale positioning failure cannot change a hidden preview")
    func stalePositionFailureIsDropped() {
        let (bench, _) = landed()
        bench.ax.refuseFrame(of: 1)
        bench.controller.position(window(bench, 1), failure: "Could not tile this window. Try again.") {
            _ in CGRect(x: 100, y: 200, width: 300, height: 400)
        }
        bench.controller.hidePreview()
        bench.lane.runNext()
        #expect(bench.controller.preview.actionFailure == nil)
    }

    @Test("a refused action is dropped after retargeting and failures clear on the new tile")
    func retargetDropsFailures() {
        let (bench, actions) = landed()
        bench.controller.preview.actionFailure = "Earlier failure"
        bench.ax.failClose(of: 1)
        bench.ax.answer(pid: Bench.betaPID, [card(11, "Beta one")])
        actions.onClose?(window(bench, 1))
        bench.controller.showPreview(for: bench.tile("Beta"))
        bench.lane.runAll()
        #expect(bench.controller.preview.actionFailure == nil)
        #expect(bench.controller.preview.appName == "Beta")
    }

    @Test("a click raises off main and closes the panel at once; ⌥-click keeps it and walks the card")
    func pickRaisesOffMain() {
        let (bench, actions) = landed()
        actions.onPick?(window(bench, 2))
        #expect(bench.ax.raised.isEmpty, "the press returned before the AX raise ran")
        #expect(!bench.controller.previewUp, "the panel goes at the press, as it did")
        bench.lane.runNext()
        #expect(bench.ax.raised == [2], "the raise still happens after the panel is gone")

        let (keep, keepActions) = landed()
        keepActions.onPickKeepOpen?(keep.controller.preview.windows[1])
        #expect(keep.controller.previewUp)
        #expect(keep.controller.preview.selectedWindowID == 2)
        keep.lane.runNext()
        #expect(keep.ax.raised == [2])
    }

    @Test("a live agent's × arms on the first press and closes on the second, once")
    func liveAgentNeedsASecondPress() {
        let bench = Bench(agents: liveMarks())
        bench.ax.answer(pid: Bench.alphaPID, [card(1, "zsh"), card(2, Self.liveTitle), card(3, "vim")])
        bench.showAndLand("Ghost")
        #expect(bench.controller.preview.agents.keys.contains(2), "the agent's window is marked")
        let actions = bench.controller.ensurePanel().actions
        let live = window(bench, 2)
        actions.onClose?(live)
        #expect(bench.lane.waiting == 0, "the first press only arms: no writer call")
        #expect(bench.controller.preview.armedWindowID == 2)
        #expect(bench.ax.closed.isEmpty)

        actions.onClose?(live)
        #expect(bench.lane.waiting == 1, "the second press inside the guard's window goes through")
        bench.lane.runNext()
        #expect(bench.ax.closed == [2], "one close, sent once")
        #expect(bench.controller.preview.windows.map(\.id) == [1, 3])
    }

    @Test("a verb's result is dropped when the preview hid before it landed")
    func staleGenerationDropsTheResult() {
        let verbs: [(String, (Bench, DockPreviewActions) -> Void)] = [
            ("close", { bench, actions in actions.onClose?(bench.controller.preview.windows[0]) }),
            ("minimize", { bench, actions in actions.onMinimize?(bench.controller.preview.windows[0]) }),
            ("fullscreen", { bench, actions in actions.onFullScreen?(bench.controller.preview.windows[0]) }),
        ]
        for (name, press) in verbs {
            let (bench, actions) = landed()
            bench.ax.setFullScreenState(of: 1, false)
            press(bench, actions)
            #expect(bench.lane.waiting == 1, "\(name): one job")
            bench.controller.hidePreview()
            bench.lane.runNext()
            #expect(bench.controller.preview.windows.map(\.id) == [1, 2], "\(name): the cards are untouched")
            #expect(bench.controller.preview.windows.allSatisfy { !$0.minimized && $0.fullScreen == nil },
                    "\(name): no flag landed")
        }
    }

    @Test("a verb's result is dropped when the preview retargeted before it landed")
    func retargetDropsTheResult() {
        let (bench, actions) = landed()
        bench.ax.answer(pid: Bench.betaPID, [card(11, "Beta one")])
        actions.onMinimize?(window(bench, 1))
        bench.controller.showPreview(for: bench.tile("Beta"))
        bench.lane.runAll()
        #expect(bench.controller.preview.appName == "Beta")
        #expect(bench.controller.preview.windows.map(\.minimized) == [false], "Alpha's minimize never reached Beta's cards")
    }
}

// MARK: - The verbs that touch several cards

/// Minimize all, close all, shake and the swipe each run as one job on
/// the preview lane and land their marks by card id.
@MainActor
@Suite("Dock preview bulk verbs, off the main thread")
struct DockPreviewBulkVerbTests {
    private func landed(titles: [String]) -> (Bench, DockPreviewActions) {
        let bench = Bench()
        bench.ax.answer(pid: Bench.alphaPID, titles.enumerated().map { card($0.offset + 1, $0.element) })
        bench.showAndLand("Alpha")
        return (bench, bench.controller.ensurePanel().actions)
    }

    @Test("minimize all writes each open card in one job and marks the ones that took it")
    func minimizeAllIsOneJob() {
        let (bench, actions) = landed(titles: ["One", "Two", "Three"])
        bench.ax.refuseMinimize(of: 3)
        actions.onMinimizeAll?()
        #expect(bench.lane.waiting == 1, "one job for the whole verb")
        #expect(bench.ax.minimized.isEmpty)
        bench.lane.runNext()
        #expect(Set(bench.ax.minimized.map(\.id)) == [1, 2, 3])
        #expect(bench.controller.preview.windows.map(\.minimized) == [true, true, false])
        #expect(bench.controller.preview.actionFailure == "Could not minimize 1 window. Try again.")
    }

    @Test("minimize all with nothing open asks for no job")
    func minimizeAllWithNothingOpen() {
        let bench = Bench()
        bench.ax.answer(pid: Bench.alphaPID, [card(1, "One", minimized: true)])
        bench.showAndLand("Alpha")
        bench.controller.ensurePanel().actions.onMinimizeAll?()
        #expect(bench.lane.waiting == 0)
    }

    @Test("shake minimizes the siblings in one job and leaves the shaken card up")
    func shakeIsOneJob() {
        let (bench, actions) = landed(titles: ["One", "Two", "Three"])
        actions.onShake?(bench.controller.preview.windows[1])
        #expect(bench.lane.waiting == 1)
        bench.lane.runNext()
        #expect(Set(bench.ax.minimized.map(\.id)) == [1, 3])
        #expect(bench.controller.preview.windows.map(\.minimized) == [true, false, true])
    }

    @Test("a swipe down minimizes the card once the write lands, and a swipe that changes nothing asks for nothing")
    func swipeMinimizes() {
        let (bench, actions) = landed(titles: ["One", "Two"])
        actions.onSwipeMinimize?(bench.controller.preview.windows[0], true)
        #expect(bench.ax.minimized.isEmpty)
        bench.lane.runNext()
        #expect(bench.controller.preview.windows.first?.minimized == true)
        actions.onSwipeMinimize?(bench.controller.preview.windows[0], true)
        #expect(bench.lane.waiting == 0, "already minimized: no write")
    }

    @Test("every bulk verb's result is dropped when the preview hid before it landed")
    func staleGenerationDropsEachVerb() {
        let verbs: [(String, (Bench, DockPreviewActions) -> Void)] = [
            ("minimize all", { _, actions in actions.onMinimizeAll?() }),
            ("close all", { _, actions in actions.onCloseAll?() }),
            ("shake", { bench, actions in actions.onShake?(bench.controller.preview.windows[0]) }),
            ("swipe", { bench, actions in actions.onSwipeMinimize?(bench.controller.preview.windows[0], true) }),
        ]
        for (name, press) in verbs {
            let (bench, actions) = landed(titles: ["One", "Two"])
            press(bench, actions)
            #expect(bench.lane.waiting == 1, "\(name): one job")
            bench.controller.hidePreview()
            bench.lane.runNext()
            #expect(bench.controller.preview.windows.map(\.id) == [1, 2], "\(name): the cards are untouched")
            #expect(bench.controller.preview.windows.allSatisfy { !$0.minimized }, "\(name): no flag landed")
        }
    }

    // MARK: Close all and the agent guard

    private static let liveTitle = "✳ Build the thing"

    private func liveMarks() -> [DockAgentMark] {
        DockAgentMark.marks(from: [
            CoreSession(id: "claude:session:a", provider: "claude", label: "Build the thing", mode: "working",
                        terminal: CoreTerminal(app: "Ghostty", bundleId: Bench.ghostty)),
        ])
    }

    /// Ghostty's tile with a live agent's window (id 2) and two plain ones.
    private func landedWithAgent() -> (Bench, DockPreviewActions) {
        let bench = Bench(agents: liveMarks())
        bench.ax.answer(pid: Bench.alphaPID, [card(1, "zsh"), card(2, Self.liveTitle), card(3, "vim")])
        bench.showAndLand("Ghost")
        #expect(bench.controller.preview.agents.keys.contains(2), "the agent's window is marked")
        return (bench, bench.controller.ensurePanel().actions)
    }

    @Test("close all sends the writer only the windows no live agent runs in, in one job")
    func closeAllSparesLiveAgents() {
        let (bench, actions) = landedWithAgent()
        actions.onCloseAll?()
        #expect(bench.lane.waiting == 1)
        #expect(bench.ax.closed.isEmpty)
        bench.lane.runNext()
        #expect(Set(bench.ax.closed) == [1, 3], "the agent's window is never passed to the writer")
        #expect(bench.controller.preview.windows.map(\.id) == [2])
        #expect(bench.controller.preview.headerNote == "Kept the window an agent is running in")
    }

    @Test("close all keeps a card whose close failed")
    func closeAllKeepsFailures() {
        let (bench, actions) = landedWithAgent()
        bench.ax.failClose(of: 3)
        actions.onCloseAll?()
        bench.lane.runNext()
        #expect(bench.controller.preview.windows.map(\.id) == [2, 3])
        #expect(bench.controller.preview.actionFailure == "Could not close 1 window. Try again.")
        #expect(bench.controller.preview.headerNote == "Kept the window an agent is running in")
    }

    @Test("bulk failures ignore cards that left the live list before the answer")
    func bulkFailureForGoneCardIsDropped() {
        let (bench, actions) = landed(titles: ["One", "Two"])
        bench.ax.refuseMinimize(of: 2)
        actions.onMinimizeAll?()
        bench.controller.preview.windows.removeAll { $0.id == 2 }
        bench.lane.runNext()
        #expect(bench.controller.preview.actionFailure == nil)
        #expect(bench.controller.preview.windows.map(\.minimized) == [true])
    }

    @Test("a refused swipe keeps the card's state and reports the action")
    func refusedSwipeReportsFailure() {
        let (bench, actions) = landed(titles: ["One", "Two"])
        bench.ax.refuseMinimize(of: 1)
        actions.onSwipeMinimize?(bench.controller.preview.windows[0], true)
        bench.lane.runNext()
        #expect(!bench.controller.preview.windows[0].minimized)
        #expect(bench.controller.preview.actionFailure == "Could not minimize this window. Try again.")
    }

    @Test("close all removes what closed by id even when the list changed under it")
    func closeAllRemovesByID() {
        let (bench, actions) = landedWithAgent()
        actions.onCloseAll?()
        // A live refresh landed a new window while the writes ran.
        bench.controller.preview.windows.append(card(4, "new"))
        bench.lane.runNext()
        #expect(bench.controller.preview.windows.map(\.id) == [2, 4], "the newcomer was never asked to close")
    }

    @Test("close all on plain windows empties the list and hides the preview")
    func closeAllHidesWhenNothingIsLeft() {
        let (bench, actions) = landed(titles: ["One", "Two"])
        actions.onCloseAll?()
        bench.lane.runNext()
        #expect(Set(bench.ax.closed) == [1, 2])
        #expect(bench.controller.preview.windows.isEmpty)
        #expect(!bench.controller.previewUp)
        #expect(bench.controller.preview.headerNote == nil)
    }
}


// MARK: - The Dock's own tiles

@MainActor
@Suite("Dock tile reads, off the main thread")
struct DockTileReadTests {
    /// A Dock list of two tiles at the screen's AX top-left, wide enough
    /// that a point on either is inside the list's reach.
    private func reading(_ bench: Bench) -> DockTileReading {
        let alpha = bench.tile("Alpha")
        let beta = DockAXItem(element: AXUIElementCreateSystemWide(),
                              frame: CGRect(x: 170, y: 900, width: 60, height: 60),
                              title: "Beta", url: nil, kind: .app)
        return DockTileReading(
            list: DockAXElement(element: AXUIElementCreateSystemWide()),
            frame: CGRect(x: 90, y: 890, width: 160, height: 80),
            items: [alpha, beta])
    }

    /// An AppKit point whose AX flip lands inside the Alpha tile
    /// (x 100…160, y 900…960 in AX space).
    private func appKitPoint(over tile: CGRect) -> NSPoint {
        let height = DockDisplays.primaryHeight()
        return NSPoint(x: tile.midX, y: height - tile.midY)
    }

    @Test("a gesture's tile read is queued on the lane, never walked on the main thread")
    func gestureReadIsOffMain() {
        let bench = Bench()
        bench.ax.setTiles(reading(bench))
        var hit: String?
        bench.controller.withTile(at: appKitPoint(over: CGRect(x: 100, y: 900, width: 60, height: 60))) {
            hit = $0.title
        }
        #expect(bench.lane.waiting == 1, "the walk is queued")
        #expect(bench.ax.walks.isEmpty, "nothing asked the Dock on main")
        #expect(hit == nil)
        bench.lane.runNext()
        #expect(bench.ax.walks == [777])
        #expect(hit == "Alpha")
    }

    @Test("a point on no tile, or a Dock that does not answer, is a miss")
    func missesAreMisses() {
        let bench = Bench()
        bench.ax.setTiles(reading(bench))
        var misses = 0
        var hits = 0
        let between = appKitPoint(over: CGRect(x: 100, y: 970, width: 10, height: 5))
        bench.controller.withTile(at: between, miss: { misses += 1 }, then: { _ in hits += 1 })
        bench.lane.runAll()
        #expect(hits == 0)

        let silent = Bench()
        silent.ax.setTiles(nil)
        silent.controller.withTile(at: appKitPoint(over: CGRect(x: 100, y: 900, width: 60, height: 60)),
                                   miss: { misses += 1 }, then: { _ in hits += 1 })
        silent.lane.runAll()
        #expect(hits == 0)
        #expect(misses == 2)
    }

    @Test("a toy switched off while the walk is out gets no gesture")
    func answerAfterStopIsDropped() {
        let bench = Bench()
        bench.ax.setTiles(reading(bench))
        var hits = 0
        bench.controller.withTile(at: appKitPoint(over: CGRect(x: 100, y: 900, width: 60, height: 60))) { _ in hits += 1 }
        bench.controller.running = false
        bench.lane.runAll()
        #expect(hits == 0)
    }

    @Test("a second gesture inside the tile cache's life reuses the read and queues nothing")
    func freshReadAnswersFromMemory() {
        let bench = Bench()
        bench.ax.setTiles(reading(bench))
        let point = appKitPoint(over: CGRect(x: 100, y: 900, width: 60, height: 60))
        var hits: [String] = []
        bench.controller.withTile(at: point) { hits.append($0.title ?? "") }
        bench.lane.runAll()
        bench.clock += DockEnhanceController.itemsTTL / 2
        bench.controller.withTile(at: point) { hits.append($0.title ?? "") }
        #expect(bench.lane.waiting == 0, "the cache is fresh: no second walk")
        #expect(hits == ["Alpha", "Alpha"])
        #expect(bench.ax.walks.count == 1)
        // Past the cache's life the Dock is asked again, on the lane.
        bench.clock += DockEnhanceController.itemsTTL
        bench.controller.withTile(at: point) { hits.append($0.title ?? "") }
        #expect(bench.lane.waiting == 1)
        bench.lane.runAll()
        #expect(bench.ax.walks.count == 2)
        #expect(hits == ["Alpha", "Alpha", "Alpha"])
    }

    @Test("⌥` asks the Dock on the lane, and the card lands when the read does")
    func frontAppPreviewIsOffMain() {
        let bench = Bench()
        bench.ax.setTiles(reading(bench))
        bench.ax.answer(pid: Bench.alphaPID, [card(1, "One")])
        bench.controller.frontApp = { (pid: Bench.alphaPID, bundleURL: nil, name: "Alpha") }
        bench.controller.previewFrontApp()
        #expect(bench.lane.waiting == 1)
        #expect(bench.ax.walks.isEmpty, "the keystroke did not wait on the Dock")
        #expect(bench.presented.isEmpty)
        bench.lane.runNext()
        #expect(bench.ax.walks == [777])
        // The tile's own window read is the next job on the lane.
        bench.lane.runAll()
        #expect(bench.presented == ["Alpha"])
    }

    @Test("a delayed front-app tile read cannot reopen a dismissed preview")
    func frontAppReadAfterDismissal() {
        let bench = Bench()
        bench.ax.setTiles(reading(bench))
        bench.ax.answer(pid: Bench.alphaPID, [card(1, "One")])
        bench.controller.frontApp = { (pid: Bench.alphaPID, bundleURL: nil, name: "Alpha") }
        bench.controller.previewFrontApp()
        bench.controller.hidePreview()
        bench.lane.runAll()
        #expect(bench.presented.isEmpty)
        #expect(bench.controller.preview.windows.isEmpty)
    }

    @Test("pressing the front-app preview hotkey twice cancels its pending read")
    func pendingFrontAppPreviewTogglesOff() {
        let bench = Bench()
        bench.ax.setTiles(reading(bench))
        bench.ax.answer(pid: Bench.alphaPID, [card(1, "One")])
        bench.controller.frontApp = { (pid: Bench.alphaPID, bundleURL: nil, name: "Alpha") }
        bench.controller.previewFrontApp()
        bench.controller.previewFrontApp()
        #expect(bench.lane.waiting == 1)
        bench.lane.runAll()
        #expect(bench.presented.isEmpty)
        #expect(!bench.controller.previewUp)
    }

    @Test("a fresh front-app request survives the canceled request's late callback")
    func pendingFrontAppPreviewCanRestart() {
        let bench = Bench()
        bench.ax.setTiles(reading(bench))
        bench.ax.answer(pid: Bench.alphaPID, [card(1, "One")])
        bench.controller.frontApp = { (pid: Bench.alphaPID, bundleURL: nil, name: "Alpha") }
        bench.controller.previewFrontApp()
        bench.controller.previewFrontApp()
        bench.controller.previewFrontApp()
        #expect(bench.lane.waiting == 2)
        bench.lane.runAll()
        #expect(bench.presented == ["Alpha"])
        #expect(bench.controller.previewUp)
    }

    @Test("permission loss retires a pending hotkey request even if access returns before its reply")
    func pendingFrontAppPreviewAfterPermissionLoss() {
        let bench = Bench()
        bench.ax.setTiles(reading(bench))
        bench.ax.answer(pid: Bench.alphaPID, [card(1, "One")])
        bench.controller.frontApp = { (pid: Bench.alphaPID, bundleURL: nil, name: "Alpha") }
        bench.controller.previewFrontApp()
        bench.controller.accessibilityTrusted = false
        bench.controller.accessibilityTrusted = true
        bench.lane.runAll()
        #expect(bench.presented.isEmpty)
        bench.controller.previewFrontApp()
        bench.lane.runAll()
        #expect(bench.presented == ["Alpha"])
    }

    @Test("a delayed front-app tile read cannot replace a newer preview")
    func frontAppReadAfterRetarget() {
        let bench = Bench()
        bench.ax.setTiles(reading(bench))
        bench.ax.answer(pid: Bench.alphaPID, [card(1, "One")])
        bench.ax.answer(pid: Bench.betaPID, [card(2, "Two")])
        bench.controller.frontApp = { (pid: Bench.alphaPID, bundleURL: nil, name: "Alpha") }
        bench.controller.previewFrontApp()
        bench.controller.showPreview(for: bench.tile("Beta"))
        bench.lane.runAll()
        #expect(bench.presented == ["Beta"])
        #expect(bench.controller.preview.appName == "Beta")
    }

    @Test("⌥` with JR-Bar in front, or with the toy off, reads nothing")
    func frontAppGuards() {
        let bench = Bench()
        bench.ax.setTiles(reading(bench))
        bench.controller.frontApp = { (pid: ProcessInfo.processInfo.processIdentifier, bundleURL: nil, name: "JR-Bar") }
        bench.controller.previewFrontApp()
        #expect(bench.lane.waiting == 0)
        bench.controller.frontApp = { (pid: Bench.alphaPID, bundleURL: nil, name: "Alpha") }
        bench.controller.running = false
        bench.controller.previewFrontApp()
        #expect(bench.lane.waiting == 0)
    }

    @Test("a failed folder can retry in place and a pending retry cannot start twice")
    func folderRetryRecoversInPlace() async throws {
        let bench = Bench()
        bench.ax.answer(pid: Bench.alphaPID, [card(1, "One")])
        bench.showAndLand("Alpha")
        bench.controller.preview.folderURL = URL(fileURLWithPath: "/synthetic/folder")
        bench.controller.preview.folderState = .failed
        bench.controller.folderReader = { _, _ in DockFolderListing(denied: true) }
        let denied = try #require(bench.controller.retryFolderListing())
        #expect(bench.controller.preview.folderState == .loading)
        #expect(bench.controller.retryFolderListing() == nil)
        await denied.value
        #expect(bench.controller.preview.folderState == .denied)

        bench.controller.folderReader = { _, _ in DockFolderListing() }
        let recovered = try #require(bench.controller.retryFolderListing())
        await recovered.value
        #expect(bench.controller.preview.folderState == .ready)
        #expect(bench.controller.preview.folderEntries.isEmpty)
        #expect(bench.controller.previewUp)
        bench.controller.hidePreview()
        #expect(bench.controller.retryFolderListing() == nil)
    }
}
