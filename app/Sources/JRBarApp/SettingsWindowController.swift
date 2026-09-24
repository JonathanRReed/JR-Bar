import AppKit
import SwiftUI

/// The "JR-Bar Settings" window: a standard titled, resizable window that
/// remembers its frame, hosting the SwiftUI split view. One per app; the
/// accessory app activates itself only while this window is up.
@MainActor
final class SettingsWindowController: NSObject, NSWindowDelegate {
    /// Room for a card's head and its switch column side by side and a
    /// page header above the fold; the frame is remembered after that.
    static let defaultSize = NSSize(width: 820, height: 620)

    let store: SettingsStore
    private var window: NSWindow?

    init(store: SettingsStore) {
        self.store = store
        super.init()
    }

    func show(page: SettingsStore.Page? = nil) {
        if let page { store.page = page }
        let window = self.window ?? makeWindow()
        self.window = window
        attachSettingsContent(to: window)
        // An accessory app is never frontmost on its own; the window needs the
        // app active to draw its controls as key. The double activate is the
        // pairing that reliably forces it on macOS 26/27.
        NSRunningApplication.current.activate()
        NSApp.activate()
        window.makeKeyAndOrderFront(nil)
        window.makeKey()
        // Focus starts on the sidebar, as in System Settings, not on whichever
        // text field happens to come first in the key loop.
        DispatchQueue.main.async {
            window.makeFirstResponder(Self.sidebarTable(in: window.contentView) ?? nil)
        }
        // Activation is cooperative on macOS 14+: when the frontmost app does
        // not yield, the request above is dropped and the window opens
        // inactive (grey controls, no key focus). Asking Launch Services to
        // "open" ourselves is the sanctioned way to get it anyway.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
            guard !NSApp.isActive else { return }
            let configuration = NSWorkspace.OpenConfiguration()
            configuration.activates = true
            configuration.createsNewApplicationInstance = false
            NSWorkspace.shared.openApplication(at: Bundle.main.bundleURL, configuration: configuration) { _, _ in }
        }
        store.refreshLaunchAtLogin()
    }

    var isVisible: Bool { window?.isVisible ?? false }

    private func makeWindow() -> NSWindow {
        let window = NSWindow(
            contentRect: NSRect(origin: .zero, size: Self.defaultSize),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false)
        attachSettingsContent(to: window)
        window.title = "JR-Bar Settings"
        window.toolbarStyle = .unified
        window.titlebarSeparatorStyle = .automatic
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.setContentSize(Self.defaultSize)
        window.minSize = NSSize(width: 640, height: 420)
        window.center()
        // Remember the frame across launches; the first launch keeps the default size.
        window.setFrameAutosaveName("JRBarSettings")
        if !window.setFrameUsingName("JRBarSettings") {
            window.setContentSize(Self.defaultSize)
            window.center()
        }
        window.identifier = NSUserInterfaceItemIdentifier("settings")
        // Developer switch: a tall window shows whole pages in one screenshot.
        if let tall = ProcessInfo.processInfo.environment["JRBAR_SETTINGS_HEIGHT"].flatMap(Double.init) {
            window.setContentSize(NSSize(width: Self.defaultSize.width, height: tall))
            window.center()
        }
        // A toolbar gives the unified title bar its height; the split view
        // supplies the sidebar toggle and the page title.
        let toolbar = NSToolbar(identifier: "settings-toolbar")
        toolbar.displayMode = .iconOnly
        window.toolbar = toolbar
        observePage(window)
        return window
    }

    /// A closed Settings window keeps its AppKit shell so its frame and
    /// toolbar survive the next open. Its SwiftUI graph does not
    /// (`WindowContentLifecycle`). Internal for the lifecycle test, which
    /// exercises this without showing or activating a desktop window.
    @discardableResult
    func attachSettingsContent(to window: NSWindow) -> NSViewController {
        // The subtitle is the current page; `observePage` continues to own
        // later page changes while the window stays open.
        WindowContentLifecycle.attach(to: window, title: "JR-Bar Settings", subtitle: store.page.title) {
            WindowContentLifecycle.hosting(SettingsRootView(store: store))
        }
    }

    func detachSettingsContent(from window: NSWindow) {
        WindowContentLifecycle.detach(from: window)
    }

    /// The window title stays "JR-Bar Settings"; the page name rides in the
    /// subtitle.
    private func observePage(_ window: NSWindow) {
        withObservationTracking {
            window.title = "JR-Bar Settings"
            window.subtitle = store.page.title
        } onChange: { [weak self, weak window] in
            Task { @MainActor [weak self, weak window] in
                guard let self, let window else { return }
                self.observePage(window)
            }
        }
    }

    /// SwiftUI's sidebar `List` is backed by an `NSTableView`; the first one
    /// in the hierarchy is the sidebar.
    private static func sidebarTable(in view: NSView?) -> NSTableView? {
        guard let view else { return nil }
        if let table = view as? NSTableView { return table }
        for subview in view.subviews {
            if let table = sidebarTable(in: subview) { return table }
        }
        return nil
    }

    func windowWillClose(_ notification: Notification) {
        if let closing = notification.object as? NSWindow, closing === window {
            detachSettingsContent(from: closing)
        }
        WindowContentLifecycle.retractWhenLastWindowCloses()
    }
}
