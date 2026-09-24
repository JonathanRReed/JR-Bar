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
