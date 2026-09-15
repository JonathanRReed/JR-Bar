import AppKit
import JRBarCore
import QuartzCore
import SwiftUI

/// The Item Bar's geometry, pure so a test can pin it: one row of fixed
/// tiles hung under the menu bar's right end. The bar floats, so the
/// material rule lets it be glass.
enum MenuBarBarLayout {
    /// A tile's square edge — big enough to read a menu bar glyph, small
    /// enough that a packed bar stays a strip.
    static let tileSize: CGFloat = 30
    /// Air between tiles.
    static let tileGap: CGFloat = 4
    /// Breathing room inside the glass, around the row.
    static let padding: CGFloat = 8
    /// The air between the panel and the menu bar it hangs from — the
    /// gap is what makes it a floating surface.
    static let barGap: CGFloat = 6
    /// Right-edge margin from the screen's edge.
    static let edgeMargin: CGFloat = 6
    /// A packed bar clips past this many tiles rather than run off the
    /// screen — the tail end is a later phase's overflow row.
    static let maxTiles = 24

    /// The panel's content size for `count` tiles (one empty-state slot
    /// when the run is empty).
    static func contentSize(itemCount: Int) -> NSSize {
        let tiles = CGFloat(min(max(itemCount, 1), maxTiles))
        return NSSize(width: tiles * tileSize + max(0, tiles - 1) * tileGap + padding * 2,
                      height: tileSize + padding * 2)
    }

    /// The panel's frame: `barGap` under the menu bar's band, right
    /// edge `edgeMargin` in from the screen's. `menuBarDepth` is the
    /// row's thickness — the status bar's, or the notch's where it
    /// reaches deeper.
    static func frame(itemCount: Int, menuBarDepth: CGFloat, on screenFrame: NSRect) -> NSRect {
        let size = contentSize(itemCount: itemCount)
        return NSRect(x: screenFrame.maxX - size.width - edgeMargin,
                      y: screenFrame.maxY - menuBarDepth - barGap - size.height,
                      width: size.width, height: size.height)
    }
}

/// The floating panel itself: borderless, nonactivating, glass-backed,
/// a row of icon tiles — one per hidden or always-hidden item. The
/// tile's click is reposted at the real item's frame (Accessibility
/// required — the gate lives in `MenuBarUtility.trigger`); ⌘-click
/// pulls the item up a section instead.
@MainActor
final class MenuBarBarPanel: NSPanel {
    static let cornerRadius: CGFloat = 14

    private let hosting: NSHostingView<MenuBarBarView>

    init(items: [MenuBarItem],
         tiles: MenuBarLiveTiles,
         parkedIDs: Set<String>,
         onTrigger: @escaping @MainActor (MenuBarItem) -> Void,
         onRevealItem: @escaping @MainActor (MenuBarItem) -> Void) {
        let hosting = NSHostingView(rootView: MenuBarBarView(
            items: items, tiles: tiles, parkedIDs: parkedIDs,
            onTrigger: onTrigger, onRevealItem: onRevealItem))
        self.hosting = hosting
        let glass = NSGlassEffectView(frame: NSRect(x: 0, y: 0, width: 120, height: 26))
        glass.cornerRadius = Self.cornerRadius
        glass.style = .regular
        glass.contentView = hosting
        super.init(contentRect: NSRect(x: 0, y: 0, width: 120, height: 26),
                   styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        contentView = glass
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        ignoresMouseEvents = false
        hidesOnDeactivate = false
        isReleasedWhenClosed = false
        isExcludedFromWindowsMenu = true
        animationBehavior = .none
        isMovable = false
        becomesKeyOnlyIfNeeded = true
        collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
        // Above the menu bar's own level — the tiles hang under it and
        // must take their clicks.
        level = NSWindow.Level(rawValue: NSWindow.Level.statusBar.rawValue + 1)
        title = "JR-Bar Menu Bar"
        // Fold's warp captures the desktop — the bar must not be in it,
        // the same exclusion the notch card claims. JRBAR_CAPTURE_CARD
        // is the dev-only escape for screenshots.
        if ProcessInfo.processInfo.environment["JRBAR_CAPTURE_CARD"] == nil {
            sharingType = .none
        }
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

/// The tiles' SwiftUI half: a row of live captures — each tile shows a
/// `SCScreenshotManager` one-shot of the item's real on-screen rect
/// while the bar is up, falling back to the owner app's icon when
/// capture has nothing honest to show (no Screen Recording, a parked
/// item). Click triggers the item, ⌘-click reveals it.
private struct MenuBarBarView: View {
    let items: [MenuBarItem]
    let tiles: MenuBarLiveTiles
    /// Items macOS parked off the row — no pixels to capture, so their
    /// tiles carry the state glyph instead of pretending otherwise.
    let parkedIDs: Set<String>
    let onTrigger: @MainActor (MenuBarItem) -> Void
    let onRevealItem: @MainActor (MenuBarItem) -> Void

    var body: some View {
        HStack(spacing: MenuBarBarLayout.tileGap) {
            if items.isEmpty {
                Text("No hidden items")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .frame(height: MenuBarBarLayout.tileSize)
            }
            ForEach(items.prefix(MenuBarBarLayout.maxTiles), id: \.id) { item in
                Button {
                    if NSEvent.modifierFlags.contains(.command) {
                        onRevealItem(item)
                    } else {
                        onTrigger(item)
                    }
                } label: {
                    tileLabel(for: item)
                }
                .buttonStyle(.plain)
                .help(tooltip(for: item))
            }
        }
        .padding(MenuBarBarLayout.padding)
    }

    /// The tile face: the live capture when one exists, else the owner
    /// app's icon — with the parked glyph when the item has no
    /// on-screen pixels to capture at all.
    @ViewBuilder
    private func tileLabel(for item: MenuBarItem) -> some View {
        Image(nsImage: tiles.images[item.id]
              ?? item.owner?.icon
              ?? NSImage(systemSymbolName: "questionmark.square.dashed",
                         variableValue: 0,
                         accessibilityDescription: nil)
              ?? NSImage())
            .resizable()
            .aspectRatio(contentMode: .fit)
            .frame(width: 22, height: 22)
            .frame(width: MenuBarBarLayout.tileSize, height: MenuBarBarLayout.tileSize)
            .contentShape(Rectangle())
            .overlay(alignment: .bottomTrailing) {
                if parkedIDs.contains(item.id) {
                    Image(systemName: "arrow.down.forward.and.arrow.up.backward")
                        .font(.system(size: 8, weight: .bold))
                        .foregroundStyle(.secondary)
                        .padding(1)
                        .background(.regularMaterial, in: Circle())
                }
            }
    }

    private func tooltip(for item: MenuBarItem) -> String {
        var name = item.ownerName
        if let title = item.title { name += " · \(title)" }
        return name + " — click to open, ⌘-click to keep it out"
    }
}

/// The coordinator: owns the panel, answers `toggle`, and watches for
/// the click outside that dismisses it. `MenuBarUtility` wires the
/// callbacks; the card's "Open Item Bar" button and the chevron's
/// right-click land here.
@MainActor
final class MenuBarBar {
    /// The tiles' contents: the plan's hidden and always-hidden runs.
    var items: @MainActor () -> [MenuBarItem] = { [] }
    /// A plain click on a tile — repost the click at the real item.
    var onTrigger: @MainActor (MenuBarItem) -> Void = { _ in }
    /// A ⌘-click on a tile — pull the item up a section.
    var onRevealItem: @MainActor (MenuBarItem) -> Void = { _ in }
    /// Open changes, so the reveal can hold while the pointer is on it
    /// and start a short clock when it folds.
    var onOpenChange: @MainActor (Bool) -> Void = { _ in }

    /// The live thumbnails — the capture loop exists only while the
    /// bar is up, so a hidden menu bar pays nothing.
    let tiles = MenuBarLiveTiles()

    private(set) var isOpen = false
    private var panel: MenuBarBarPanel?
    private var dismissMonitors: [Any] = []
    /// The system uptime at open — a click event that predates it is
    /// the click that opened the bar, not one that should fold it.
    private var openedAtUptime: TimeInterval = 0

    /// The reveal's "is the pointer on the bar" answer.
    var panelFrame: NSRect? { isOpen ? panel?.frame : nil }

    func toggle() {
        if isOpen { close() } else { open() }
    }

    /// Opens the bar under the menu bar's right end — or refreshes it
    /// when it is already up (the tiles are a snapshot of the moment).
    func open() {
        if isOpen { close() }
        guard let screen = NSScreen.main else { return }
        let listed = items()
        let row = MenuBarItemLister.menuBarRow()
        let panel = MenuBarBarPanel(
            items: listed,
            tiles: tiles,
            parkedIDs: Set(listed.filter { !$0.bounds.intersects(row) }.map(\.id)),
            onTrigger: { [weak self] item in self?.onTrigger(item) },
            onRevealItem: { [weak self] item in self?.onRevealItem(item) })
        let depth = max(NSStatusBar.system.thickness, ScreenBarGeometry.notchDepth(of: screen))
        panel.setFrame(MenuBarBarLayout.frame(itemCount: listed.count,
                                              menuBarDepth: depth,
                                              on: screen.frame),
                       display: false)
        panel.orderFrontRegardless()
        self.panel = panel
        isOpen = true
        openedAtUptime = ProcessInfo.processInfo.systemUptime
        onOpenChange(true)
        installDismissMonitors()
        // The capture loop's whole lifetime is the bar's: items come
        // from the same provider the tiles were built from, and close()
        // stops it outright.
        tiles.itemsProvider = items
        tiles.rowRect = { MenuBarItemLister.menuBarRow() }
        tiles.start()
    }

    func close() {
        guard isOpen else { return }
        for monitor in dismissMonitors { NSEvent.removeMonitor(monitor) }
        dismissMonitors = []
        tiles.stop()
        panel?.orderOut(nil)
        panel = nil
        isOpen = false
        onOpenChange(false)
    }

    isolated deinit {
        for monitor in dismissMonitors { NSEvent.removeMonitor(monitor) }
        panel?.orderOut(nil)
    }

    /// A click anywhere but the bar folds it — the panel never takes
    /// focus, so "outside" is a monitor's call, not a resign event.
    private func installDismissMonitors() {
        let mask: NSEvent.EventTypeMask = [.leftMouseDown, .rightMouseDown]
        if let global = NSEvent.addGlobalMonitorForEvents(
            matching: mask,
            handler: { [weak self] event in self?.noteOutsideClick(event) }) {
            dismissMonitors.append(global)
        }
        if let local = NSEvent.addLocalMonitorForEvents(
            matching: mask,
            handler: { [weak self] event in
                self?.noteOutsideClick(event)
                return event
            }) {
            dismissMonitors.append(local)
        }
    }

    nonisolated private func noteOutsideClick(_ event: NSEvent) {
        let point = NSEvent.mouseLocation
        let timestamp = event.timestamp
        Task { @MainActor [weak self] in
            guard let self else { return }
            // The click that opened the bar must not fold it — its
            // event predates `openedAtUptime`.
            guard timestamp > self.openedAtUptime else { return }
            guard let frame = self.panelFrame, !frame.contains(point) else { return }
            self.close()
        }
    }
}
