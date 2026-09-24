import AppKit
import SwiftUI

/// A standard titled window for the Control Center (⌘K from the panel, the
/// footer's overflow menu, the status menu, the app menu and Settings ›
/// Devices).
@MainActor
final class ControlCenterWindowController: NSObject, NSWindowDelegate {
    private let store: DeckStore
    private var window: NSWindow?

    init(store: DeckStore) {
        self.store = store
        super.init()
    }

    func show() {
        let window = self.window ?? makeWindow()
        self.window = window
        attachContent(to: window)
        store.windowDidOpen()
        NSRunningApplication.current.activate()
        NSApp.activate()
        window.makeKeyAndOrderFront(nil)
    }

    func toggle() {
        if let window, window.isVisible, window.isKeyWindow { window.performClose(nil) } else { show() }
    }

    var isVisible: Bool { window?.isVisible ?? false }

    /// The pad's SwiftUI graph lives only while the window is open
    /// (`WindowContentLifecycle`): a closed window no longer re-renders
    /// the grid on every deck state. Internal for the lifecycle test.
    @discardableResult
    func attachContent(to window: NSWindow) -> NSViewController {
        WindowContentLifecycle.attach(to: window, title: "Control Center", subtitle: "Creator Micro 2") {
            WindowContentLifecycle.hosting(ControlCenterView(store: store))
        }
    }

    private func makeWindow() -> NSWindow {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1000, height: 740),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered, defer: false)
        attachContent(to: window)
        window.setContentSize(NSSize(width: 1000, height: 740))
        // The pad's own minimum is a content size, and this window's title
        // bar sits above its content; with no limits coming from SwiftUI,
        // the window carries it as one.
        window.contentMinSize = NSSize(width: ControlCenterView.minSize.width, height: ControlCenterView.minSize.height)
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.center()
        window.setFrameAutosaveName("JRBarControlCenter")
        window.identifier = NSUserInterfaceItemIdentifier("jrbar.control-center")
        return window
    }

    func windowWillClose(_ notification: Notification) {
        if let closing = notification.object as? NSWindow { WindowContentLifecycle.detach(from: closing) }
        store.windowDidClose()
        WindowContentLifecycle.retractWhenLastWindowCloses()
    }
}
