import AppKit
import SwiftUI

/// A standard titled window for the Overview roster (⌘O from the panel).
@MainActor
final class OverviewWindowController: NSObject, NSWindowDelegate {
    private let store: OverviewStore
    private var window: NSWindow?
    /// ↑/↓ and Return for the row table; scoped to this window so a stray
    /// key in another window never moves the selection.
    private var keyMonitor: Any?

    init(store: OverviewStore) {
        self.store = store
        super.init()
    }

    func show() {
        let window = self.window ?? makeWindow()
        self.window = window
        store.windowDidOpen()
        // An accessory app is never frontmost on its own; the window needs
        // the app active to draw as key. `activate(ignoringOtherApps:)` is
        // the deprecated call that used to open the Overview behind the
        // frontmost app — the "nothing happens" report — so this runs the
        // same dance Settings does.
        NSRunningApplication.current.activate()
        NSApp.activate()
        if window.isMiniaturized { window.deminiaturize(nil) }
        // A window left on another Space orders front there and reads as
        // nothing happening; moveToActiveSpace pulls it onto this one for
        // the order-in, then comes straight off so it stays put.
        if !window.isOnActiveSpace {
            window.collectionBehavior.insert(.moveToActiveSpace)
        }
        window.makeKeyAndOrderFront(nil)
        window.makeKey()
        window.collectionBehavior.remove(.moveToActiveSpace)
        installKeyMonitor()
        // Activation is cooperative on macOS 14+: when the frontmost app
        // does not yield, the request above is dropped. Opening ourselves
        // through Launch Services is the sanctioned way through anyway.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
            guard !NSApp.isActive else { return }
            let configuration = NSWorkspace.OpenConfiguration()
            configuration.activates = true
            configuration.createsNewApplicationInstance = false
            NSWorkspace.shared.openApplication(at: Bundle.main.bundleURL, configuration: configuration) { _, _ in }
        }
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
        let controller = NSHostingController(rootView: OverviewView(store: store))
        let window = NSWindow(contentViewController: controller)
        window.title = "Overview"
        window.subtitle = "JR-Bar"
        window.styleMask = [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView]
        window.toolbarStyle = .unified
        window.titlebarAppearsTransparent = false
        window.setContentSize(NSSize(width: 960, height: 540))
        window.minSize = NSSize(width: 720, height: 380)
        window.setFrameAutosaveName("JRBarOverview")
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.center()
        window.identifier = NSUserInterfaceItemIdentifier("jrbar.overview")
        return window
    }

    func windowWillClose(_ notification: Notification) {
        // A local monitor outlives its window; remove it with the window
        // and let show() install a fresh one next time.
        if let keyMonitor {
            NSEvent.removeMonitor(keyMonitor)
            self.keyMonitor = nil
        }
        store.windowDidClose()
    }
}
