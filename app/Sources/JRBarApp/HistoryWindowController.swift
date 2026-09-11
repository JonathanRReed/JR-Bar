import AppKit
import SwiftUI

/// A standard titled window for the activity history (⌘Y from the panel).
@MainActor
final class HistoryWindowController: NSObject, NSWindowDelegate {
    private let store: HistoryStore
    private var window: NSWindow?
    /// ↑/↓ and Return for the row list; scoped to this window so a stray
    /// key in another window never moves the selection.
    private var keyMonitor: Any?

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
        installKeyMonitor()
    }

    private func installKeyMonitor() {
        guard keyMonitor == nil else { return }
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, event.window === self.window else { return event }
            // Typing in the search field keeps its arrows and Return.
            if event.window?.firstResponder is NSTextView { return event }
            switch event.keyCode {
            case 125: self.store.moveSelection(by: 1); return nil   // Down
            case 126: self.store.moveSelection(by: -1); return nil  // Up
            case 36, 76:                                            // Return / keypad Enter
                guard event.modifierFlags.intersection(.deviceIndependentFlagsMask).isEmpty else { return event }
                self.store.openSelected()
                return nil
            default: return event
            }
        }
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
