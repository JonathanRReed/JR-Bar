import ApplicationServices
import Foundation
import Testing
@testable import JRBarApp

/// The Dock's work off the main thread: the switcher's key tap on a
/// thread of its own, and the commits' Accessibility calls on one serial
/// worker. Nothing here creates a real event tap — a live session tap in
/// a test run could swallow the keyboard — so the thread is proven with
/// a plain run-loop source standing in for the tap's.
@Suite("Dock off the main thread")
struct DockAXWorkerTests {
    /// What the stand-in source saw: which thread ran it, and a signal
    /// per run. Written on the tap thread, read after the signal.
    private final class Runs: @unchecked Sendable {
        let lock = NSLock()
        var threads: [String] = []
        var onMain: [Bool] = []
        let ran = DispatchSemaphore(value: 0)

        func record() {
            lock.withLock {
                threads.append(Thread.current.name ?? "")
                onMain.append(Thread.isMainThread)
            }
            ran.signal()
        }
    }

    /// A version-0 source whose perform records into `runs`.
    private func source(_ runs: Runs) -> CFRunLoopSource? {
        var context = CFRunLoopSourceContext()
        context.info = Unmanaged.passUnretained(runs).toOpaque()
        context.perform = { info in
            guard let info else { return }
            Unmanaged<Runs>.fromOpaque(info).takeUnretainedValue().record()
        }
        return CFRunLoopSourceCreate(kCFAllocatorDefault, 0, &context)
    }

    private func fire(_ source: CFRunLoopSource, on thread: DockTapThread) throws {
        let loop = try #require(thread.runLoop, "the thread publishes its loop before start returns")
        CFRunLoopSourceSignal(source)
        CFRunLoopWakeUp(loop)
    }

    @Test("the tap's source is serviced on its own named thread, never main")
    func tapThreadServicesOffMain() throws {
        let runs = Runs()
        let tapSource = try #require(source(runs))
        let thread = DockTapThread(source: tapSource, name: "JR-Bar dock keys")
        thread.start()
        defer { thread.stop() }
        try fire(tapSource, on: thread)
        // A signal, not a sleep: the bound only ends a broken thread.
        #expect(runs.ran.wait(timeout: .now() + 10) == .success)
        runs.lock.withLock {
            #expect(runs.threads == ["JR-Bar dock keys"])
            #expect(runs.onMain == [false])
        }
    }

    @Test("stop takes the source off and lets the thread return; start again serves anew")
    func tapThreadStopsAndRestarts() throws {
        let runs = Runs()
        let tapSource = try #require(source(runs))
        let thread = DockTapThread(source: tapSource, name: "JR-Bar dock keys")
        thread.start()
        let first = try #require(thread.runLoop)
        thread.stop()
        #expect(thread.runLoop == nil, "stopped: no loop left to wake")
        thread.stop()   // a second stop is a no-op, as `deinit`'s is
        thread.start()
        let second = try #require(thread.runLoop)
        #expect(second !== first, "a fresh thread, a fresh loop")
        try fire(tapSource, on: thread)
        #expect(runs.ran.wait(timeout: .now() + 10) == .success)
        thread.stop()
    }

    @Test("a tap that never started stops cleanly")
    func idleTapStops() {
        let tap = SwitcherKeyTap()
        tap.stop()
        tap.stop()
    }

    /// The worker's work, in the order it ran and where.
    private final class Order: @unchecked Sendable {
        let lock = NSLock()
        var ran: [Int] = []
        var onMain = false

        func note(_ step: Int) {
            lock.withLock {
                ran.append(step)
                if Thread.isMainThread { onMain = true }
            }
        }
    }

    @Test("AX work runs off main, one job at a time, in the order it was asked for")
    func workerKeepsOrder() async {
        let order = Order()
        await withCheckedContinuation { (done: CheckedContinuation<Void, Never>) in
            for step in 0..<32 { DockAXWorker.run { order.note(step) } }
            DockAXWorker.run { done.resume() }
        }
        order.lock.withLock {
            #expect(order.ran == Array(0..<32), "a second ⌘⇥ never lands before the first")
            #expect(!order.onMain)
        }
    }

    /// Main-actor answers, in the order they landed.
    @MainActor
    private final class Answers {
        var values: [Int] = []
        var onMain = true
    }

    @Test("an answer comes back on the main actor, in order")
    @MainActor
    func workerAnswersOnMain() async {
        let answers = Answers()
        await withCheckedContinuation { (done: CheckedContinuation<Void, Never>) in
            for step in 0..<8 {
                DockAXWorker.run({ () -> Int in
                    precondition(!Thread.isMainThread, "the work itself is the worker's")
                    return step
                }, then: { value in
                    answers.onMain = answers.onMain && Thread.isMainThread
                    answers.values.append(value)
                    if value == 7 { done.resume() }
                })
            }
        }
        #expect(answers.values == Array(0..<8))
        #expect(answers.onMain)
    }

    private func item(element: AXUIElement? = nil, windowID: CGWindowID? = 77,
                      onScreen: Bool) -> SwitcherItem {
        SwitcherItem(id: "w", pid: 4242, appName: "App", icon: nil, title: "Doc",
                     minimized: false, onScreen: onScreen, element: element, windowID: windowID)
    }

    @Test("a commit's target keeps the matched handle, and walks only for a row on another Space")
    func commitTargetResolves() {
        var walks: [(pid_t, CGWindowID)] = []
        let walk: (pid_t, CGWindowID) -> AXUIElement? = { pid, id in
            walks.append((pid, id))
            return AXUIElementCreateApplication(900_001)
        }
        let matched = AXUIElementCreateApplication(900_002)
        #expect(SwitcherCommitTarget(item(element: matched, onScreen: false)).resolve(remote: walk) == matched)
        #expect(walks.isEmpty, "the list's own handle needs no walk")

        #expect(SwitcherCommitTarget(item(onScreen: true)).resolve(remote: walk) == nil,
                "an on-screen row AX never matched is activation's — `AXWindows` would have listed it")
        #expect(SwitcherCommitTarget(item(windowID: nil, onScreen: false)).resolve(remote: walk) == nil)
        #expect(walks.isEmpty)

        let found = SwitcherCommitTarget(item(onScreen: false)).resolve(remote: walk)
        #expect(found != nil)
        #expect(walks.count == 1 && walks.first?.0 == 4242 && walks.first?.1 == 77)
    }

    @Test("the card a target hands the verbs carries the row's handle and state")
    func commitTargetWindow() {
        let element = AXUIElementCreateApplication(900_003)
        var row = item(element: element, onScreen: true)
        row = SwitcherItem(id: row.id, pid: row.pid, appName: row.appName, icon: nil, title: "Notes",
                           minimized: true, onScreen: true, element: element, windowID: 5)
        let window = SwitcherCommitTarget(row).window(element)
        #expect(window.element == element)
        #expect(window.minimized, "a minimized pick stands up before the raise")
        #expect(window.title == "Notes")
    }
}
