import AppKit
import JRBarCore
import SwiftUI

/// What the folder-stack popover renders — an observable box so the
/// view can sit inside the panel before a folder is picked. The cell
/// click rides `onOpen` rather than a captured view closure, the way
/// `DockPreviewActions` carries the preview panel's picks.
@MainActor
@Observable
final class DockFolderContent {
    var name = ""
    var folderPath = ""
    var entries: [DockFolderEntry] = []
    /// A grid cell's click — the panel fills this in.
    var onOpen: (@MainActor (DockFolderEntry) -> Void)?
    var folderURL: URL? {
        folderPath.isEmpty ? nil : URL(fileURLWithPath: folderPath)
    }
}

/// A folder stack's popover (P2): the folder's contents in a grid
/// above the bar — `DockFolderListing` rows, workspace icons at
/// Retina density, click opens, drag-out hands the file to whatever
/// accepts it, Esc or a click anywhere outside dismisses. Anchored
/// to the tile exactly the way the enhance preview anchors to a Dock
/// icon (`DockEnhanceMath.panelFrame`).
@MainActor
final class DockFolderPanel: NSPanel {
    let content: DockFolderContent
    private let hosting: NSHostingView<DockFolderGridView>
    private let watchers = DockPanelWatchers()

    /// The live listing — injectable for tests.
    var lister: @MainActor (URL) -> [DockFolderEntry] = {
        DockFolderListing.contents(of: $0)
    }
    /// An entry's click — opens it. Injectable.
    var opener: @MainActor (URL) -> Void = { NSWorkspace.shared.open($0) }

    init() {
        let content = DockFolderContent()
        self.content = content
        hosting = NSHostingView(rootView: DockFolderGridView(content: content))
        super.init(contentRect: NSRect(x: 0, y: 0, width: 320, height: 200),
                   styleMask: [.borderless, .nonactivatingPanel], backing: .buffered,
                   defer: false)
        contentView = hosting
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        ignoresMouseEvents = false
        hidesOnDeactivate = false
        isReleasedWhenClosed = false
        isExcludedFromWindowsMenu = true
        isMovable = false
        becomesKeyOnlyIfNeeded = true
        animationBehavior = .none
        collectionBehavior = [.canJoinAllSpaces, .stationary,
                              .fullScreenAuxiliary, .ignoresCycle]
        title = "JR-Bar Dock Folder"
        // Same tier as the preview panel — just over the Dock's own
        // level so the bar can't draw across the popover.
        level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.dockWindow)) + 1)
        content.onOpen = { [weak self] entry in self?.pick(entry) }
        watchers.onEscape = { [weak self] in self?.dismiss() }
        watchers.onOutside = { [weak self] in self?.dismiss() }
        watchers.isInside = { [weak self] in
            guard let self, isVisible else { return true }
            return frame.insetBy(dx: -4, dy: -4).contains(NSEvent.mouseLocation)
        }
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    /// Show `item`'s contents anchored to its tile on `edge` of
    /// `screen`. Re-showing the same folder is a reload; a different
    /// one retargets — either way there's only ever one popover.
    func show(folder item: DockItem, anchor: CGRect, edge: DockEdge,
              screen: NSScreen, gap: CGFloat) {
        content.folderPath = item.bundleURL?.path ?? ""
        content.name = item.name
        reload()
        let size = fittingSize()
        setFrame(DockEnhanceMath.panelFrame(anchor: anchor, edge: edge,
                                            size: size, screen: screen.frame,
                                            gap: gap), display: false)
        present()
        watchers.start(escape: true, clickAway: true)
    }

    /// The size the grid wants, clamped so a fat folder can't sprawl
    /// the popover across the screen — `DockFolderGridView`'s own
    /// width is deterministic, so only the height needs the cap.
    func fittingSize() -> CGSize {
        hosting.layoutSubtreeIfNeeded()
        let fit = hosting.fittingSize
        return CGSize(width: fit.width, height: min(fit.height, 360))
    }

    func present() {
        if isVisible, alphaValue > 0.5 {
            orderFrontRegardless()
            return
        }
        alphaValue = 0
        orderFrontRegardless()
        let reduced = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        NSAnimationContext.runAnimationGroup { context in
            context.duration = reduced ? 0.03 : 0.16
            animator().alphaValue = 1
        }
    }

    func dismiss() {
        watchers.stop()
        alphaValue = 0
        orderOut(nil)
    }

    /// Re-read the folder — a drop into the tile lands here next
    /// time the popover opens.
    func reload() {
        guard let url = content.folderURL else {
            content.entries = []
            return
        }
        content.entries = lister(url)
    }

    private func pick(_ entry: DockFolderEntry) {
        opener(entry.url)
        dismiss()
    }
}

/// The popover's body: a header (folder name + count), then the grid
/// — fixed-width cells, a column count sized to the contents so a
/// small folder doesn't sprawl a mostly-empty row, and a scroll view
/// so a large one stays inside the cap. Clicks report through
/// `content.onOpen`.
struct DockFolderGridView: View {
    let content: DockFolderContent

    /// A cell's footprint — icon plus a two-line name.
    static let cellWidth: CGFloat = 84
    /// The grid never grows past this many columns.
    static let maxColumns = 6

    /// Columns for `entries` items: clamped 2…`maxColumns` so the
    /// panel's width is deterministic (`fittingSize` leans on it) and
    /// a two-item folder doesn't get a six-column stage.
    static func columnCount(for entries: Int) -> Int {
        min(maxColumns, max(2, entries))
    }

    /// The popover's fixed content width — columns plus padding.
    static func contentWidth(for entries: Int) -> CGFloat {
        CGFloat(columnCount(for: entries)) * (cellWidth + 6) - 6 + 24
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: "folder.fill")
                    .foregroundStyle(.secondary)
                Text(content.name)
                    .font(.headline)
                    .lineLimit(1)
                Spacer(minLength: 4)
                Text("\(content.entries.count)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Divider()
            if content.entries.isEmpty {
                Text("Empty folder")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 20)
            } else {
                ScrollView(showsIndicators: false) {
                    LazyVGrid(
                        columns: Array(
                            repeating: GridItem(.fixed(Self.cellWidth), spacing: 6),
                            count: Self.columnCount(for: content.entries.count)),
                        spacing: 6
                    ) {
                        ForEach(content.entries) { entry in
                            cell(entry)
                        }
                    }
                }
                .frame(maxHeight: 300)
            }
        }
        .padding(12)
        .frame(width: Self.contentWidth(for: content.entries.count))
        .background(.regularMaterial,
                    in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    private func cell(_ entry: DockFolderEntry) -> some View {
        Button { content.onOpen?(entry) } label: {
            VStack(spacing: 4) {
                Image(nsImage: DockIconResolver.icon(
                    fileURL: entry.url, pointSize: 40, scale: 2))
                    .resizable()
                    .interpolation(.high)
                    .frame(width: 40, height: 40)
                Text(entry.name)
                    .font(.caption2)
                    .lineLimit(2)
                    .truncationMode(.middle)
                    .multilineTextAlignment(.center)
                    .frame(width: Self.cellWidth - 8, height: 26)
            }
            .padding(4)
            .frame(width: Self.cellWidth)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(entry.name)
        // Dragging an entry out hands the real file URL to whatever
        // accepts it — Finder, another folder, an app.
        .onDrag { NSItemProvider(object: entry.url as NSURL) }
    }
}
