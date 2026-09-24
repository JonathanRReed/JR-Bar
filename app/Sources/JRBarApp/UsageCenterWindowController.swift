import AppKit
import SwiftUI

/// A standard titled window for the Usage Center (⌘U from the panel, the
/// Usage header's Details chevron, the status menu and the app menu).
@MainActor
final class UsageCenterWindowController: NSObject, NSWindowDelegate {
    private let store: UsageCenterStore
    private var window: NSWindow?

    init(store: UsageCenterStore) {
        self.store = store
        super.init()
    }

    /// `focusedProvider` is the panel's per-provider drill: scroll to that
    /// card and flash it. A plain open carries no provider and must not
    /// re-scroll to the last drilled one, so a stale focus is dropped here.
    func show(focusedProvider: String? = nil) {
        if let focusedProvider {
            store.focus(provider: focusedProvider)
        } else {
            store.focusProvider = nil
        }
        let window = self.window ?? makeWindow()
        self.window = window
        attachContent(to: window)
        store.windowDidOpen()
        WindowFront.bring(window)
    }

    func toggle() {
        if let window, window.isVisible, window.isKeyWindow { window.performClose(nil) } else { show() }
    }

    var isVisible: Bool { window?.isVisible ?? false }

    /// The Usage Center's SwiftUI graph lives only while the window is
    /// open (`WindowContentLifecycle`); the range, metric and focus live
    /// in the store. Internal for the lifecycle test.
    @discardableResult
    func attachContent(to window: NSWindow) -> NSViewController {
        WindowContentLifecycle.attach(to: window, title: "Usage Center", subtitle: "JR-Bar") {
            WindowContentLifecycle.hosting(UsageCenterView(store: store))
        }
    }

    private func makeWindow() -> NSWindow {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 760, height: 720),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered, defer: false)
        attachContent(to: window)
        window.toolbarStyle = .unified
        window.setContentSize(NSSize(width: 760, height: 720))
        window.minSize = NSSize(width: 640, height: 440)
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.center()
        window.setFrameAutosaveName("JRBarUsageCenter")
        // Developer switch, as in Settings: a tall window puts a whole
        // provider card (rings, forecast, graph) in one screenshot.
        if let tall = ProcessInfo.processInfo.environment["JRBAR_USAGE_HEIGHT"].flatMap(Double.init) {
            window.setContentSize(NSSize(width: 760, height: tall))
            window.center()
        }
        window.identifier = NSUserInterfaceItemIdentifier("jrbar.usage")
        return window
    }

    func windowWillClose(_ notification: Notification) {
        if let closing = notification.object as? NSWindow { WindowContentLifecycle.detach(from: closing) }
        store.windowDidClose()
        WindowContentLifecycle.retractWhenLastWindowCloses()
    }
}
