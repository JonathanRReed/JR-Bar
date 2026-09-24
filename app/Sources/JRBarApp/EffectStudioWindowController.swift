import AppKit
import SwiftUI

/// The Effect Studio window (Settings › Lighting › Effects…, the panel's
/// overflow menu, the status menu and the app menu).
@MainActor
final class EffectStudioWindowController: NSObject, NSWindowDelegate {
    private let store: EffectStudioStore
    private var window: NSWindow?

    init(store: EffectStudioStore) {
        self.store = store
        super.init()
    }

    func show(effect: String? = nil) {
        let window = self.window ?? makeWindow()
        self.window = window
        attachContent(to: window)
        if let effect { store.selectedID = effect }
        store.windowDidOpen()
        NSRunningApplication.current.activate()
        NSApp.activate()
        window.makeKeyAndOrderFront(nil)
    }

    var isVisible: Bool { window?.isVisible ?? false }

    /// The studio's SwiftUI graph lives only while the window is open
    /// (`WindowContentLifecycle`); the selection lives in the store.
    /// Internal for the lifecycle test.
    @discardableResult
    func attachContent(to window: NSWindow) -> NSViewController {
        WindowContentLifecycle.attach(to: window, title: "Effect Studio", subtitle: "JR-Bar") {
            WindowContentLifecycle.hosting(EffectStudioView(store: store))
        }
    }

    private func makeWindow() -> NSWindow {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1060, height: 680),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered, defer: false)
        attachContent(to: window)
        window.toolbarStyle = .unified
        window.setContentSize(NSSize(width: 1060, height: 680))
        window.minSize = NSSize(width: 900, height: 540)
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.center()
        window.setFrameAutosaveName("JRBarEffectStudio")
        window.identifier = NSUserInterfaceItemIdentifier("jrbar.effects")
        let toolbar = NSToolbar(identifier: "effects-toolbar")
        toolbar.displayMode = .iconAndLabel
        window.toolbar = toolbar
        return window
    }

    func windowWillClose(_ notification: Notification) {
        if let closing = notification.object as? NSWindow { WindowContentLifecycle.detach(from: closing) }
        store.windowDidClose()
        WindowContentLifecycle.retractWhenLastWindowCloses()
    }
}
