import AppKit
import SwiftUI

/// A standard titled window for the activity history (⌘Y from the panel).
@MainActor
final class HistoryWindowController: NSObject, NSWindowDelegate {
    private let store: HistoryStore
    private var window: NSWindow?

    init(store: HistoryStore) {
        self.store = store
        super.init()
    }

    func show() {
        let window = self.window ?? makeWindow()
        self.window = window
        store.windowDidOpen()
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }

    func toggle() {
        if let window, window.isVisible, window.isKeyWindow { window.performClose(nil) } else { show() }
    }

    private func makeWindow() -> NSWindow {
        let controller = NSHostingController(rootView: HistoryView(store: store))
        let window = NSWindow(contentViewController: controller)
        window.title = "History"
        window.subtitle = "JR-Bar"
        window.styleMask = [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView]
        window.toolbarStyle = .unified
        window.titlebarAppearsTransparent = false
        window.setContentSize(NSSize(width: 680, height: 520))
        window.minSize = NSSize(width: 560, height: 360)
        window.setFrameAutosaveName("JRBarHistory")
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.center()
        window.identifier = NSUserInterfaceItemIdentifier("jrbar.history")
        return window
    }

    func windowWillClose(_ notification: Notification) {
        store.windowDidClose()
    }
}
