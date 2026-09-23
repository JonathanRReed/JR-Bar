import AppKit
import ApplicationServices

// MARK: - The key tap's thread

/// A session event tap's own thread. An active tap holds every event it
/// filters until its callback returns, so the switcher's tap, serviced
/// by the main run loop, made every keystroke and right-click on the Mac
/// wait on whatever JR-Bar's main thread was doing: a hung app's AX
/// timeout, a SwiftUI layout, a burst of daemon documents. A long enough
/// stall got the tap disabled outright. On a thread of its own the
/// callback reads its lock-guarded copies and answers in microseconds,
/// and everything else it does is an async hop to the main actor. The
/// concealer's click bridge (`MenuBarSystemClickBridge`) has the same
/// shape.
final class DockTapThread: @unchecked Sendable {
    /// What the thread and `stop` share: the source to take off, the
    /// loop to stop, and a signal that the thread has returned. The
    /// thread holds this, never the owner, so an owner dropped without
    /// `stop` still reaches `deinit`.
    private final class Loop: @unchecked Sendable {
        let source: CFRunLoopSource
        /// Written by the thread before `ready` fires; read after.
        var runLoop: CFRunLoop?
        let ready = DispatchSemaphore(value: 0)
        let finished = DispatchSemaphore(value: 0)
        init(source: CFRunLoopSource) { self.source = source }
    }

    private let source: CFRunLoopSource
    private let name: String
    private let lock = NSLock()
    private var loop: Loop?

    init(source: CFRunLoopSource, name: String) {
        self.source = source
        self.name = name
    }

    /// The loop servicing the source while it runs — the tests wake it.
    var runLoop: CFRunLoop? { lock.withLock { loop?.runLoop } }

    /// Put the source on a fresh thread's run loop; returns once that
    /// loop is servicing it. A second start while running does nothing.
    func start() {
        guard lock.withLock({ loop == nil }) else { return }
        let loop = Loop(source: source)
        let thread = Thread {
            let current = CFRunLoopGetCurrent()
            CFRunLoopAddSource(current, loop.source, .commonModes)
            loop.runLoop = current
            loop.ready.signal()
            // Returns once `stop` takes the source off and stops the loop.
            CFRunLoopRun()
            loop.finished.signal()
        }
        thread.name = name
        thread.qualityOfService = .userInteractive
        thread.start()
        loop.ready.wait()
        lock.withLock { self.loop = loop }
    }

    /// Take the source off and let the thread return. When this returns
    /// no callback is still running — a tap's unretained pointer to its
    /// owner is safe to drop.
    func stop() {
        let loop = lock.withLock { () -> Loop? in
            defer { self.loop = nil }
            return self.loop
        }
        guard let loop, let runLoop = loop.runLoop else { return }
        CFRunLoopRemoveSource(runLoop, loop.source, .commonModes)
        CFRunLoopStop(runLoop)
        // The callback never waits on the main thread, so the loop
        // returns within one callback's length.
        _ = loop.finished.wait(timeout: .now() + 1)
    }

    deinit { stop() }
}

// MARK: - Accessibility off the main thread

/// An AX handle carried to the worker. The Accessibility client API may
/// be called from any thread — each call is a message to the target app
/// — and the element is an immutable reference, so handing one across
/// is sound though the SDK does not mark it `Sendable`.
struct DockAXElement: @unchecked Sendable {
    let element: AXUIElement
}

/// The Dock utility's slow Accessibility work, off the main thread. A
/// hung app answers every AX call with its full timeout — half a second
/// for a window list or a menu walk, 0.2 s for the remote-token walk —
/// and on main that wait froze the strip, the previews and every surface
/// JR-Bar draws. One serial queue keeps the work in the order it was
/// asked for: a second ⌘⇥ never lands before the first.
enum DockAXWorker {
    private static let queue = DispatchQueue(label: "JR-Bar dock AX", qos: .userInitiated)

    static func run(_ work: @escaping @Sendable () -> Void) {
        queue.async(execute: work)
    }

    /// `work` on the worker, then `then` with its answer on the main
    /// actor — through the main queue, so it lands in order with the
    /// blocks already waiting there.
    static func run<Answer: Sendable>(_ work: @escaping @Sendable () -> Answer,
                                      then: @escaping @MainActor @Sendable (Answer) -> Void) {
        queue.async {
            let answer = work()
            DispatchQueue.main.async { MainActor.assumeIsolated { then(answer) } }
        }
    }
}

/// A switcher row as the AX worker needs it: which app and window, and
/// the handle when the list already matched one. The icon and the agent
/// mark stay on main.
struct SwitcherCommitTarget: Sendable {
    let pid: pid_t
    let title: String
    let minimized: Bool
    let onScreen: Bool
    let windowID: CGWindowID?
    let element: DockAXElement?

    init(_ item: SwitcherItem) {
        pid = item.pid
        title = item.title
        minimized = item.minimized
        onScreen = item.onScreen
        windowID = item.windowID
        element = item.element.map(DockAXElement.init)
    }

    /// The row's AX window: the one the list matched, else — for a row
    /// on another Space, which `AXWindows` never lists — the element the
    /// remote-token walk finds by its native id. nil leaves activation
    /// as the only reach. Worker side: the walk can take its 0.2 s.
    func resolve() -> AXUIElement? {
        resolve { DockRemoteWindows.element(pid: $0, windowID: $1) }
    }

    /// The seam: `remote` stands in for the walk.
    func resolve(remote: (pid_t, CGWindowID) -> AXUIElement?) -> AXUIElement? {
        if let element { return element.element }
        guard let windowID, !onScreen else { return nil }
        return remote(pid, windowID)
    }

    /// A card-shaped handle for `AppleDockReader`'s verbs.
    func window(_ element: AXUIElement) -> DockPreviewWindow {
        DockPreviewWindow(id: 0, title: title, minimized: minimized, fullScreen: nil,
                          frame: nil, thumbnail: nil, element: element)
    }
}
