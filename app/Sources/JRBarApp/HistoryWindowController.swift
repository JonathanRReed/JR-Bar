import AppKit
import JRBarCore
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
        attachContent(to: window)
        store.windowDidOpen()
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        installKeyMonitor()
    }

    /// History on its Events tab — what the Event Replay window was; the
    /// status menu's Event Replay item (⌘R) and the palette's land here.
    func showEvents() {
        store.mode = .events
        show()
    }

    /// History on one day — the Overview heatmap's "that day in History".
    func show(day: Date) {
        store.mode = .activity
        store.filter = HistoryFilter(day: day)
        show()
    }

    private func installKeyMonitor() {
        guard keyMonitor == nil else { return }
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, event.window === self.window else { return event }
            // Typing in the search field keeps its arrows and Return.
            if event.window?.firstResponder is NSTextView { return event }
            // The Events tab is a native list: it owns its own keys.
            guard self.store.mode == .activity else { return event }
            switch event.keyCode {
            case 125: self.store.moveSelection(by: 1); return nil   // Down
            case 126: self.store.moveSelection(by: -1); return nil  // Up
            case 124, 49:                                           // Right / Space: open the timeline
                guard event.modifierFlags.intersection(.deviceIndependentFlagsMask).isEmpty else { return event }
                self.store.expandSelected(true)
                return nil
            case 123:                                               // Left: close it
                self.store.expandSelected(false)
                return nil
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

    /// History's SwiftUI graph lives only while the window is open
    /// (`WindowContentLifecycle`); the tab, filter and selection live in
    /// the store. Internal for the lifecycle test.
    @discardableResult
    func attachContent(to window: NSWindow) -> NSViewController {
        WindowContentLifecycle.attach(to: window, title: "History", subtitle: "JR-Bar") {
            WindowContentLifecycle.hosting(HistoryView(store: store))
        }
    }

    private func makeWindow() -> NSWindow {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 680, height: 520),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered, defer: false)
        attachContent(to: window)
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
        if let closing = notification.object as? NSWindow { WindowContentLifecycle.detach(from: closing) }
        // A local monitor outlives its window; remove it with the window
        // and let show() install a fresh one next time.
        if let keyMonitor {
            NSEvent.removeMonitor(keyMonitor)
            self.keyMonitor = nil
        }
        store.windowDidClose()
    }
}
