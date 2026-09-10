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
        let controller = NSHostingController(rootView: UsageCenterView(store: store))
        let window = NSWindow(contentViewController: controller)
        window.title = "Usage Center"
        window.subtitle = "JR-Bar"
        window.styleMask = [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView]
        window.toolbarStyle = .unified
        window.setContentSize(NSSize(width: 760, height: 720))
        window.minSize = NSSize(width: 640, height: 440)
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.center()
        window.setFrameAutosaveName("JRBarUsageCenter")
        if let tall = ProcessInfo.processInfo.environment["JRBAR_USAGE_HEIGHT"].flatMap(Double.init) {
            window.setContentSize(NSSize(width: 760, height: tall))
            window.center()
        }
        window.identifier = NSUserInterfaceItemIdentifier("jrbar.usage")
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
