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
    private var jobs: [() -> Void] = []
    var waiting: Int { jobs.count }

    func run<Answer: Sendable>(_ work: @escaping @Sendable () -> Answer,
                               then: @escaping @MainActor @Sendable (Answer) -> Void) {
        jobs.append {
            let answer = work()
            then(answer)
        }
    }

    /// Run the oldest job and land its answer on main.
    func runNext() { jobs.removeFirst()() }
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

    func answer(pid: pid_t, _ windows: [DockPreviewWindow]) { lock.withLock { windowsByPID[pid] = windows } }
    func hang(_ pid: pid_t, _ hung: Bool = true) {
        lock.withLock { if hung { hungPIDs.insert(pid) } else { hungPIDs.remove(pid) } }
    }
    func failClose(of id: Int) { lock.withLock { _ = failingCloses.insert(id) } }
    func refuseMinimize(of id: Int) { lock.withLock { _ = refusingMinimize.insert(id) } }
    func setFullScreenState(of id: Int, _ on: Bool) { lock.withLock { fullScreenStates[id] = on } }

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
        let defaults = UserDefaults(suiteName: "jrbar-dock-preview-async-\(UUID().uuidString)")!
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
            setFrame: { _, _ in true },
            frame: { $0.frame },
            newWindow: { _ in })
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
        #expect(bench.lane.waiting == 2, "both reads are asked, in order")
        bench.lane.runNext()
        #expect(bench.presented.isEmpty, "Alpha's answer arrives after Beta's show: dropped")
        #expect(bench.controller.preview.windows.isEmpty)
        bench.lane.runNext()
        #expect(bench.presented == ["Beta"])
        #expect(bench.controller.preview.windows.map(\.title) == ["Beta one"])
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

    @Test("through the real preview lane the show returns while the reader is blocked, then lands")
    func realLaneDoesNotBlockMain() async {
        final class Held: @unchecked Sendable {
            let entered = DispatchSemaphore(value: 0)
            let release = DispatchSemaphore(value: 0)
            let landed = DispatchSemaphore(value: 0)
        }
        let held = Held()
        let bench = Bench()
        bench.controller.ax.lane = DockAXPreviewLane()
        bench.controller.ax.read = { pid, _ in
            held.entered.signal()
            // A bound, so a failing run releases itself.
            _ = held.release.wait(timeout: .now() + 20)
            return ([card(1, "One")], false)
        }
        bench.controller.presenter = { _, _ in held.landed.signal() }
        bench.controller.showPreview(for: bench.tile("Alpha"))
        // Here, and not blocked: the reader is on the worker's thread.
        #expect(await Self.signalled(held.entered), "the worker took the read")
        #expect(bench.controller.preview.windows.isEmpty, "still nothing while it is blocked")
        held.release.signal()
        #expect(await Self.signalled(held.landed), "the answer lands on main once it is released")
        #expect(bench.controller.preview.windows.map(\.title) == ["One"])
    }

    private static func signalled(_ semaphore: DispatchSemaphore, within seconds: Double = 10) async -> Bool {
        await Task.detached { waitForSignal(semaphore, seconds: seconds) }.value
    }

    private nonisolated static func waitForSignal(_ semaphore: DispatchSemaphore, seconds: Double) -> Bool {
        semaphore.wait(timeout: .now() + seconds) == .success
    }
}
