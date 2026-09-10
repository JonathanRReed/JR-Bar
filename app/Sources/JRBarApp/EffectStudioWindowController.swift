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
        if let effect { store.selectedID = effect }
        store.windowDidOpen()
        NSRunningApplication.current.activate(options: [.activateIgnoringOtherApps])
        NSApp.activate()
        window.makeKeyAndOrderFront(nil)
    }

    var isVisible: Bool { window?.isVisible ?? false }

    private func makeWindow() -> NSWindow {
        let controller = NSHostingController(rootView: EffectStudioView(store: store))
        let window = NSWindow(contentViewController: controller)
        window.title = "Effect Studio"
        window.subtitle = "JR-Bar"
        window.styleMask = [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView]
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
        store.windowDidClose()
        DispatchQueue.main.async {
            if NSApp.windows.allSatisfy({ !$0.isVisible || $0 is NSPanel }) {
                NSApp.hide(nil)
                NSApp.unhide(nil)
            }
        }
    }
}
