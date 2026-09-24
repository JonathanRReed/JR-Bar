import AppKit
import SwiftUI

/// The Creator Micro window: the pad drawn as it is, its session keys,
/// banks and bindings. Opened from the panel's More menu, the status
/// menu, the app menu, Settings › Devices, the rail's "…" key and
/// `jrbar://window/creator-micro` (`control-center` still works). It is
/// named for the pad it drives; it has no chord of its own.
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
        WindowFront.bring(window)
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
        WindowContentLifecycle.attach(to: window, title: Self.title) {
            WindowContentLifecycle.hosting(ControlCenterView(store: store))
        }
    }

    /// The window's name: the pad's, not a second "Control Center" beside
    /// macOS's own.
    static let title = "Creator Micro"

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
