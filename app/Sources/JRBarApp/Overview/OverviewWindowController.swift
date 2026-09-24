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

    /// Opens on one session: History's event rows and timelines point
    /// here for the inspector's model, cost and full timeline.
    func show(selecting id: String) {
        store.reveal(id)
        show()
    }

    func show() {
        let window = self.window ?? makeWindow()
        self.window = window
        attachContent(to: window)
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
            // Typing in the search field keeps its arrows, Return and
            // Escape — the map below only fires off the field.
            if event.window?.firstResponder is NSTextView { return event }
            // A focused table (roster Table or sidebar List) owns its
            // arrows natively — scroll-to-selection and Shift-extend come
            // from AppKit, not this monitor. Only non-arrow keys fall
            // through to the roster shortcuts.
            let tableOwnsKeys = event.window?.firstResponder is NSTableView
            let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
            // ⌘-shortcuts first: preset picks, refresh, export, compare,
            // first/last row.
            if flags.contains(.command) {
                if flags.contains(.shift), event.keyCode == 8 {          // ⇧⌘C
                    self.store.compareSelected()
                    return nil
                }
                switch event.keyCode {
                case 18, 19, 20, 21, 23, 22:                            // ⌘1…⌘6
                    let presets = OverviewPreset.sidebarPresets
                    let index = [18, 19, 20, 21, 23, 22].firstIndex(of: Int(event.keyCode)) ?? 0
                    if index < presets.count {
                        self.store.pane = .roster
                        self.store.workerFilter = nil
                        self.store.filter = OverviewFilter(preset: presets[index])
                        self.store.activeSavedFilter = nil
                    }
                    return nil
                case 15:                                                // ⌘R
                    if self.store.pane == .usage {
                        Task { await self.store.loadGraph() }
                    } else {
                        Task { await self.store.load(userInitiated: true) }
                    }
                    return nil
                case 14:                                                // ⌘E
                    Task { await self.store.prepareExport() }
                    return nil
                case 126:                                               // ⌘↑ first row
                    self.store.selectEdge(first: true)
                    return nil
                case 125:                                               // ⌘↓ last row
                    self.store.selectEdge(first: false)
                    return nil
                default: return event
                }
            }
            // Roster-only keys: on the usage pane there is no visible
            // selection to move, and Return must not fire openSelected
            // against a roster row the user cannot see.
            if tableOwnsKeys || self.store.pane != .roster { return event }
            switch event.keyCode {
            case 125: self.store.moveSelection(by: 1); return nil   // Down
            case 126: self.store.moveSelection(by: -1); return nil  // Up
            case 36, 76:                                            // Return / keypad Enter
                guard flags.isEmpty else { return event }
                self.store.openSelected()
                return nil
            case 53:                                                // Escape
                // First press drops the selection; a second clears the
                // search — the field itself keeps its own Esc.
                if !self.store.selectedIDs.isEmpty {
                    self.store.selectionChanged(to: [])
                } else if !self.store.search.isEmpty {
                    self.store.search = ""
                } else {
                    return event
                }
                return nil
            default: return event
            }
        }
    }

    func toggle() {
        if let window, window.isVisible, window.isKeyWindow { window.performClose(nil) } else { show() }
    }

    /// The Overview's SwiftUI graph lives only while the window is open
    /// (`WindowContentLifecycle`); the preset, search and selection live
    /// in the store. Internal for the lifecycle test.
    @discardableResult
    func attachContent(to window: NSWindow) -> NSViewController {
        WindowContentLifecycle.attach(to: window, title: "Overview", subtitle: "JR-Bar") {
            WindowContentLifecycle.hosting(OverviewView(store: store))
        }
    }

    private func makeWindow() -> NSWindow {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 960, height: 540),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered, defer: false)
        attachContent(to: window)
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
