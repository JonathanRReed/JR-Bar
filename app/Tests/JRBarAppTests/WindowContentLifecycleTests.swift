import AppKit
import SwiftUI
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
}
