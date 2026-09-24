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

    /// Opens on the Graph pane, the way its sidebar row does:
    /// `jrbar://overview/graph` and What's New's Try it land on the map
    /// whether the window was open or not.
    func showGraph() {
        store.showGraph()
        show()
    }

    func show() {
        let window = self.window ?? makeWindow()
        self.window = window
        attachContent(to: window)
        store.windowDidOpen()
        WindowFront.bring(window)
        installKeyMonitor()
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

    /// Builds the window without showing it. Internal for the lifecycle
    /// test.
    func makeWindow() -> NSWindow {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 960, height: 540),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered, defer: false)
        // The titlebar's style, the size and its limits are settled before
        // the content goes in, so the SwiftUI toolbar is laid out once, in
        // the titlebar it will live in.
        window.toolbarStyle = .unified
        window.titlebarAppearsTransparent = false
        window.setContentSize(NSSize(width: 960, height: 540))
        window.minSize = NSSize(width: 720, height: 380)
        attachContent(to: window)
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
