import AppKit
import SwiftUI

/// A standard titled window for the event Replay surface.
@MainActor
final class ReplayWindowController: NSObject, NSWindowDelegate {
    private let store: ReplayStore
    private var window: NSWindow?

    init(store: ReplayStore) {
        self.store = store
        super.init()
    }

    func show() {
        let window = self.window ?? makeWindow()
        self.window = window
        store.isOpen = true
        Task { await store.load() }
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }

    func toggle() {
        if let window, window.isVisible, window.isKeyWindow { window.performClose(nil) } else { show() }
    }

    private func makeWindow() -> NSWindow {
        let controller = NSHostingController(rootView: ReplayView(store: store))
        let window = NSWindow(contentViewController: controller)
        window.title = "Event Replay"
        window.subtitle = "JR-Bar"
        window.styleMask = [.titled, .closable, .miniaturizable, .resizable]
        window.setContentSize(NSSize(width: 620, height: 480))
        window.minSize = NSSize(width: 480, height: 320)
        window.setFrameAutosaveName("JRBarReplay")
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.center()
        window.identifier = NSUserInterfaceItemIdentifier("jrbar.replay")
        return window
    }

    func windowWillClose(_ notification: Notification) {
        // Closed, the live-frame reloads stop; the next `show()` reads
        // the journal fresh anyway.
        store.isOpen = false
    }
}
