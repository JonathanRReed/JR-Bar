import AppKit
import SwiftUI
import JRBarCore
import Testing
@testable import JRBarApp

/// The shared attach/detach every titled window uses. Nothing here is
/// shown or activated: each test builds its own offscreen window.
@MainActor
@Suite("Window content lifecycle")
struct WindowContentLifecycleTests {
    static func window(resizable: Bool = true) -> NSWindow {
        var style: NSWindow.StyleMask = [.titled, .closable, .fullSizeContentView]
        if resizable { style.insert(.resizable) }
        let window = NSWindow(contentRect: NSRect(x: 80, y: 120, width: 700, height: 480),
                              styleMask: style, backing: .buffered, defer: false)
        window.toolbarStyle = .unified
        window.toolbar = NSToolbar(identifier: "lifecycle-test")
        return window
    }

    @Test func detachReleasesTheGraphAndKeepsTheGeometry() async {
        let window = Self.window()
        weak var firstHost: NSViewController?
        weak var firstView: NSView?
        autoreleasepool {
            let host = WindowContentLifecycle.attach(to: window, title: "Effect Studio", subtitle: "JR-Bar") {
                WindowContentLifecycle.hosting(Text("studio").frame(width: 300, height: 200))
            }
            firstHost = host
            firstView = host.view
            #expect(window.contentViewController === host)
        }
        #expect(window.title == "Effect Studio")
        #expect(window.subtitle == "JR-Bar")
        window.minSize = NSSize(width: 600, height: 400)
        window.setFrame(NSRect(x: 80, y: 120, width: 760, height: 560), display: false)
        let frame = window.frame
        let minSize = window.minSize
        let maxSize = window.maxSize

        autoreleasepool { WindowContentLifecycle.detach(from: window) }
        for _ in 0..<3 { await Task.yield() }
        try? await Task.sleep(for: .milliseconds(20))
        #expect(window.contentViewController == nil)
        #expect(firstHost == nil, "a closed window must not keep its SwiftUI graph")
        #expect(firstView == nil, "the NSHostingView goes too, not only its controller")
        #expect(window.frame == frame)
        #expect(window.minSize == minSize)
        #expect(window.maxSize == maxSize)

        for _ in 0..<2 {
            let host = WindowContentLifecycle.attach(to: window, title: "Effect Studio", subtitle: "JR-Bar") {
                WindowContentLifecycle.hosting(Text("studio").frame(width: 300, height: 200))
            }
            #expect(window.contentViewController === host)
            #expect(window.subtitle == "JR-Bar")
            #expect(window.frame == frame, "reopening must not resize the window to its content")
            #expect(window.minSize == minSize)
            #expect(window.maxSize == maxSize)
            WindowContentLifecycle.detach(from: window)
        }
    }

    @Test func attachingTwiceKeepsTheLiveContent() {
        let window = Self.window()
        var built = 0
        let first = WindowContentLifecycle.attach(to: window, title: "History") {
            built += 1
            return WindowContentLifecycle.hosting(Text("history"))
        }
        let second = WindowContentLifecycle.attach(to: window, title: "History") {
            built += 1
            return WindowContentLifecycle.hosting(Text("history"))
        }
        #expect(first === second)
        #expect(built == 1, "an open window keeps its graph; only a closed one rebuilds")
    }

    @Test func theHostingControllerLeavesTheLimitsToTheWindow() {
        let hosting = WindowContentLifecycle.hosting(Text("x"))
        #expect(hosting.sizingOptions == [])
    }

    // MARK: The content's size on the way in

    /// Every size a window passes through while it is watched. Resize
    /// notifications are posted on the main thread as the frame changes,
    /// so the list is complete when the watched call returns.
    final class ResizeLog: @unchecked Sendable {
        var sizes: [NSSize] = []
        private var observer: NSObjectProtocol?

        @MainActor
        func watch(_ window: NSWindow?) {
            observer = NotificationCenter.default.addObserver(
                forName: NSWindow.didResizeNotification, object: window, queue: nil
            ) { [weak self] note in
                nonisolated(unsafe) let resized = note.object as? NSWindow
                MainActor.assumeIsolated {
                    guard let resized else { return }
                    self?.sizes.append(resized.frame.size)
                }
            }
        }

        func stop() {
            if let observer { NotificationCenter.default.removeObserver(observer) }
            observer = nil
        }
    }

    /// A window takes the size of the view it is handed, and a hosting
    /// view that owns no size is zero by zero. The content goes in already
    /// at the window's content size, so the window never folds to a
    /// sliver on the way: that fold squeezed the toolbar's title into
    /// conflicting constraints when the Overview was built.
    @Test(arguments: [true, false])
    func contentArrivesAtTheWindowsContentSize(fullSizeContent: Bool) {
        var style: NSWindow.StyleMask = [.titled, .closable, .resizable]
        if fullSizeContent { style.insert(.fullSizeContentView) }
        let window = NSWindow(contentRect: NSRect(x: 80, y: 120, width: 700, height: 480),
                              styleMask: style, backing: .buffered, defer: false)
        window.toolbarStyle = .unified
        window.toolbar = NSToolbar(identifier: "lifecycle-size-test")
        let frame = window.frame
        let contentSize = window.contentRect(forFrameRect: frame).size
        let log = ResizeLog()
        log.watch(window)
        let host = WindowContentLifecycle.attach(to: window, title: "Overview", subtitle: "JR-Bar") {
            WindowContentLifecycle.hosting(Text("overview").frame(maxWidth: .infinity, maxHeight: .infinity))
        }
        log.stop()
        defer { WindowContentLifecycle.detach(from: window) }

        #expect(!window.isVisible, "built, not shown")
        #expect(host.view.frame.size == contentSize, "the hosting view is the window's content size")
        #expect(window.contentView?.frame.size == contentSize)
        #expect(log.sizes.isEmpty, "the window never changes size on the way: \(log.sizes)")
        #expect(window.frame == frame)
        #expect(window.title == "Overview")
        #expect(window.subtitle == "JR-Bar")
    }

    /// The Overview is built with its titlebar settled first: the window
    /// never passes through a size under its own minimum, and it comes out
    /// at its size and minimum, titled, with the content filling it.
    @Test func theOverviewIsBuiltAtItsSize() {
        let controller = OverviewWindowController(store: OverviewStore(core: CoreModel()))
        let log = ResizeLog()
        log.watch(nil)
        let window = controller.makeWindow()
        log.stop()
        defer { WindowContentLifecycle.detach(from: window) }

        let minimum = NSSize(width: 720, height: 380)
        let undersized = log.sizes.filter { $0.width < minimum.width || $0.height < minimum.height }
        #expect(undersized.isEmpty, "no window folds below the Overview's minimum while it is built: \(undersized)")
        #expect(!window.isVisible, "built, not shown")
        // AppKit keeps the limit under the titlebar, so the toolbar's
        // height can come on top of it (it read 720 × 400 before and after
        // the reorder); it never comes out below the Overview's own.
        #expect(window.minSize.width == minimum.width)
        #expect(window.minSize.height >= minimum.height)
        #expect(window.toolbarStyle == .unified)
        #expect(window.title == "Overview")
        #expect(window.subtitle == "JR-Bar")
        let contentSize = window.contentRect(forFrameRect: window.frame).size
        #expect(window.contentViewController?.view.frame.size == contentSize)
    }

    // MARK: Every titled window

    /// Attaches a controller's content to a plain window, lays it out so
    /// the SwiftUI graph is really built, closes it through the
    /// controller's own delegate method, and checks the graph went.
    private func expectCloseReleasesContent(
        of delegate: NSWindowDelegate, window: NSWindow = window(),
        attach: (NSWindow) -> NSViewController,
        sourceLocation: SourceLocation = #_sourceLocation
    ) async {
        weak var host: NSViewController?
        weak var view: NSView?
        autoreleasepool {
            let attached = attach(window)
            attached.view.layoutSubtreeIfNeeded()
            host = attached
            view = attached.view
            #expect(window.contentViewController === attached, sourceLocation: sourceLocation)
        }
        autoreleasepool {
            delegate.windowWillClose?(Notification(name: NSWindow.willCloseNotification, object: window))
        }
        for _ in 0..<3 { await Task.yield() }
        try? await Task.sleep(for: .milliseconds(20))
        #expect(window.contentViewController == nil, sourceLocation: sourceLocation)
        #expect(host == nil, "a closed window must not keep its SwiftUI graph", sourceLocation: sourceLocation)
        #expect(view == nil, "the hosting view goes with its controller", sourceLocation: sourceLocation)
    }

    @Test func effectStudioDropsItsGraphOnClose() async {
        let store = EffectStudioStore(core: CoreModel())
        store.search = "aurora"
        let controller = EffectStudioWindowController(store: store)
        await expectCloseReleasesContent(of: controller) { controller.attachContent(to: $0) }
        #expect(store.search == "aurora")
    }

    @Test func controlCenterDropsItsGraphOnClose() async {
        let store = DeckStore(core: CoreModel())
        store.applyAuxiliary = true
        let controller = ControlCenterWindowController(store: store)
        await expectCloseReleasesContent(of: controller) { controller.attachContent(to: $0) }
        #expect(store.applyAuxiliary)
        #expect(!store.isWindowOpen)
    }

    @Test func creatorMicroIsNamedForThePad() {
        let controller = ControlCenterWindowController(store: DeckStore(core: CoreModel()))
        let window = Self.window(resizable: true)
        controller.attachContent(to: window)
        #expect(window.title == "Creator Micro")
        #expect(window.subtitle.isEmpty, "the name says it; no second line repeats it")
        WindowContentLifecycle.detach(from: window)
    }

    @Test func historyDropsItsGraphOnClose() async {
        let store = HistoryStore(core: CoreModel())
        store.mode = .events
        let controller = HistoryWindowController(store: store)
        await expectCloseReleasesContent(of: controller) { controller.attachContent(to: $0) }
        #expect(store.mode == .events)
    }

    @Test func usageCenterDropsItsGraphOnClose() async {
        let store = UsageCenterStore(core: CoreModel())
        store.focusProvider = "codex"
        let controller = UsageCenterWindowController(store: store)
        await expectCloseReleasesContent(of: controller) { controller.attachContent(to: $0) }
        #expect(store.focusProvider == "codex")
    }

    @Test func overviewDropsItsGraphOnClose() async {
        let store = OverviewStore(core: CoreModel())
        store.search = "ship"
        let controller = OverviewWindowController(store: store)
        await expectCloseReleasesContent(of: controller) { controller.attachContent(to: $0) }
        #expect(store.search == "ship")
    }

    @Test func setupDropsItsGlassCardOnClose() async {
        let store = SetupStore(model: SetupModel(), load: { SetupState() }, persist: { _ in })
        store.jump(to: .agents)
        let controller = SetupWindowController(store: store)
        await expectCloseReleasesContent(of: controller, window: Self.window(resizable: false)) {
            controller.attachContent(to: $0)
        }
        #expect(store.step == .agents)
    }
}
