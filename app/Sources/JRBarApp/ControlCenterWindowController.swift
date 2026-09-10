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
        store.windowDidOpen()
        NSRunningApplication.current.activate(options: [.activateIgnoringOtherApps])
        NSApp.activate()
        window.makeKeyAndOrderFront(nil)
    }

    func toggle() {
        if let window, window.isVisible, window.isKeyWindow { window.performClose(nil) } else { show() }
    }

    var isVisible: Bool { window?.isVisible ?? false }

    private func makeWindow() -> NSWindow {
        let controller = NSHostingController(rootView: ControlCenterView(store: store))
        let window = NSWindow(contentViewController: controller)
        window.title = "Control Center"
        window.subtitle = "Creator Micro 2"
        window.styleMask = [.titled, .closable, .miniaturizable, .resizable]
        window.setContentSize(NSSize(width: 1000, height: 740))
        window.minSize = NSSize(width: ControlCenterView.minSize.width, height: ControlCenterView.minSize.height)
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.center()
        window.setFrameAutosaveName("JRBarControlCenter")
        window.identifier = NSUserInterfaceItemIdentifier("jrbar.control-center")
        return window
    }

    func windowWillClose(_ notification: Notification) {
        store.windowDidClose()
        DispatchQueue.main.async {
            if NSApp.windows.allSatisfy({ !$0.isVisible || $0 is NSPanel }) {
                NSApp.hide(nil)
                NSApp.unhide(nil)
            }
        }
    }
}
