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
