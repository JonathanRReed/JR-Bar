import AppKit
import Testing
import JRBarCore
@testable import JRBarApp

@MainActor
@Suite("Settings window lifecycle")
struct SettingsWindowLifecycleTests {
    @Test func closeReleasesHostingGraphAndReopenPreservesStorePage() async {
        let store = SettingsStore(core: CoreModel())
        store.page = .utilities
        let controller = SettingsWindowController(store: store)
        let window = NSWindow(
            contentRect: NSRect(x: 80, y: 120, width: 680, height: 460),
            styleMask: [.titled], backing: .buffered, defer: false)

        weak var firstHost: NSViewController?
        weak var firstHostingView: NSView?
        autoreleasepool {
            let host = controller.attachSettingsContent(to: window)
            firstHost = host
            firstHostingView = host.view
            #expect(window.contentViewController === host)
            #expect(window.title == "JR-Bar Settings")
            #expect(window.subtitle == "Utilities")
        }
        // Record the live window's effective constraints after SwiftUI has
        // supplied its own minimum content size, as production does.
        window.minSize = NSSize(width: 640, height: 520)
        window.maxSize = NSSize(width: 920, height: 740)
        window.setFrame(NSRect(x: 80, y: 120, width: 680, height: 560), display: false)
        let originalFrame = window.frame
        let originalMinSize = window.minSize
        let originalMaxSize = window.maxSize

        autoreleasepool {
            controller.detachSettingsContent(from: window)
        }
        for _ in 0..<3 { await Task.yield() }
        try? await Task.sleep(for: .milliseconds(20))
        #expect(window.contentViewController == nil)
        #expect(firstHost == nil,
                "closing Settings must release the hidden SwiftUI graph and its timelines")
        #expect(firstHostingView == nil,
                "closing Settings must remove the NSHostingView, not only its controller")
        #expect(window.frame == originalFrame)
        #expect(window.minSize == originalMinSize)
        #expect(window.maxSize == originalMaxSize)
        #expect(store.page == .utilities)

        let reopenedHost = controller.attachSettingsContent(to: window)
        #expect(window.contentViewController === reopenedHost)
        #expect(store.page == .utilities)
        #expect(controller.store === store)
        #expect(window.title == "JR-Bar Settings")
        #expect(window.subtitle == "Utilities")
        #expect(window.frame == originalFrame)
        #expect(window.minSize == originalMinSize)
        #expect(window.maxSize == originalMaxSize)

        controller.detachSettingsContent(from: window)
        let secondReopenedHost = controller.attachSettingsContent(to: window)
        #expect(window.contentViewController === secondReopenedHost)
        #expect(window.title == "JR-Bar Settings")
        #expect(window.subtitle == "Utilities")
        #expect(window.frame == originalFrame)
        #expect(window.minSize == originalMinSize)
        #expect(window.maxSize == originalMaxSize,
                "repeated close and reopen cycles must not accumulate titlebar offsets")
    }
}
