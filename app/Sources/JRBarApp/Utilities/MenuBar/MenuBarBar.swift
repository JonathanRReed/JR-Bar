import AppKit
import Carbon
import JRBarCore
import QuartzCore
import SwiftUI

/// The Item Bar's geometry, pure so a test can pin it: one row of tiles
/// hung under the menu bar's right end. A tile carrying a real glyph
/// takes the item's own width, so "72°" or a VPN's name reads whole; an
/// app-icon fallback stays square. The bar floats, so the material rule
/// lets it be glass.
enum MenuBarBarLayout {
    /// A tile's square edge — big enough to read a menu bar glyph, small
    /// enough that a packed bar stays a strip. Also the tile's height.
    static let tileSize: CGFloat = 30
    /// A glyph tile's width range: the item's own width, clamped.
    static let minTileWidth: CGFloat = 22
    static let maxTileWidth: CGFloat = 120
    /// Air between tiles.
    static let tileGap: CGFloat = 4
    /// Breathing room inside the glass, around the row.
    static let padding: CGFloat = 8
    /// The air between the panel and the menu bar it hangs from — the
    /// gap is what makes it a floating surface.
    static let barGap: CGFloat = 6
    /// Right-edge margin from the screen's edge.
    static let edgeMargin: CGFloat = 6
    /// The viewport shows at most this many tiles; the rest remain scrollable.
    static let maxTiles = 24

    static let scrollIndicatorHeight: CGFloat = 16

    /// A row of `itemCount` square tiles. Arithmetic, never an array of
    /// widths: a caller may ask about any count at all.
    static func rowWidth(itemCount: Int) -> CGFloat {
        let count = CGFloat(max(0, itemCount))
        return count * tileSize + max(0, count - 1) * tileGap
    }

    /// A row of tiles of these widths, with the gaps between.
    static func rowWidth(widths: [CGFloat]) -> CGFloat {
        widths.reduce(0, +) + CGFloat(max(0, widths.count - 1)) * tileGap
    }

    /// Limit the viewport, never the items. Reserve scrollbar room only
    /// when content overflows, including on screens narrower than 24 tiles.
    static func contentSize(itemCount: Int, availableWidth: CGFloat = .greatestFiniteMagnitude) -> NSSize {
        contentSize(rowWidth: itemCount > 0 ? rowWidth(itemCount: itemCount) : nil,
                    availableWidth: availableWidth)
    }

    /// The same for tiles of their own widths. The viewport cap stays
    /// the width of `maxTiles` square tiles, so wide glyphs scroll
    /// rather than stretch the glass across the screen.
    static func contentSize(widths: [CGFloat], availableWidth: CGFloat = .greatestFiniteMagnitude) -> NSSize {
        contentSize(rowWidth: widths.isEmpty ? nil : rowWidth(widths: widths),
                    availableWidth: availableWidth)
    }

    /// The glass around a row this wide — nil for the empty bar's note.
    private static func contentSize(rowWidth row: CGFloat?, availableWidth: CGFloat) -> NSSize {
        let fullWidth = row.map { $0 + 2 * padding } ?? 128
        let width = min(fullWidth, rowWidth(itemCount: maxTiles) + 2 * padding,
                        max(0, availableWidth))
        let overflow = row != nil && fullWidth > width
        return NSSize(width: width,
                      height: tileSize + 2 * padding + (overflow ? scrollIndicatorHeight : 0))
    }

    /// The panel's frame: `barGap` under the menu bar's band, right
    /// edge `edgeMargin` in from the screen's. `menuBarDepth` is the
    /// row's thickness — the status bar's, or the notch's where it
    /// reaches deeper.
    static func frame(itemCount: Int, menuBarDepth: CGFloat, on screenFrame: NSRect) -> NSRect {
        frame(size: contentSize(itemCount: itemCount,
                                availableWidth: screenFrame.width - 2 * edgeMargin),
              menuBarDepth: menuBarDepth, on: screenFrame, anchorMaxX: nil)
    }

    /// The same for tiles of their own widths. `anchorMaxX`, when given,
    /// hangs the bar's right edge under that x — the icon's ‹ — kept on
    /// the screen.
    static func frame(widths: [CGFloat], menuBarDepth: CGFloat, on screenFrame: NSRect,
                      anchorMaxX: CGFloat? = nil) -> NSRect {
        frame(size: contentSize(widths: widths,
                                availableWidth: screenFrame.width - 2 * edgeMargin),
              menuBarDepth: menuBarDepth, on: screenFrame, anchorMaxX: anchorMaxX)
    }

    private static func frame(size: NSSize, menuBarDepth: CGFloat, on screenFrame: NSRect,
                              anchorMaxX: CGFloat?) -> NSRect {
        let rightmost = screenFrame.maxX - edgeMargin
        let leftmost = screenFrame.minX + edgeMargin
        let maxX = anchorMaxX.map { min(rightmost, max(leftmost + size.width, $0)) } ?? rightmost
        return NSRect(x: maxX - size.width,
                      y: screenFrame.maxY - menuBarDepth - barGap - size.height,
                      width: size.width, height: size.height)
    }

    /// A tile's width: a glyph's own width, clamped; the square for an
    /// app icon.
    static func tileWidth(glyphWidth: CGFloat?) -> CGFloat {
        glyphWidth.map(MenuBarGlyphProcessing.tileWidth(pointWidth:)) ?? tileSize
    }
}

/// The Item Bar's keyboard, pure so a test can pin it — Bartender 7's
/// mouse-free bar. Opened from the hotkey the bar takes key: ← → (or
/// Tab) walk the tiles, typing filters them by app and title, Return
/// presses the selected one, ⌘1–⌘9 press the ninth-or-nearer directly,
/// and Esc clears the filter before it folds the bar.
enum MenuBarBarKeys {
    enum Key: Equatable, Sendable {
        case left, right, first, last, submit, cancel, backspace
        case text(String)
        /// ⌘1…⌘9 — the tile at that place in the (filtered) row.
        case jump(Int)
    }

    enum Effect: Equatable, Sendable {
        case none
        case trigger(itemID: String)
        case close
    }

    struct State: Equatable, Sendable {
        var query = ""
        var selection = 0
    }

    /// The tiles a query leaves, in bar order: every word of the query
    /// found in the owner's name or the item's title, ignoring case and
    /// diacritics. An empty query leaves them all.
    nonisolated static func filter(_ items: [MenuBarItem], query: String) -> [MenuBarItem] {
        let words = query.split(whereSeparator: \.isWhitespace).map(String.init)
        guard !words.isEmpty else { return items }
        return items.filter { item in
            let haystack = item.ownerName + " " + (item.title ?? "")
            return words.allSatisfy { haystack.localizedStandardContains($0) }
        }
    }

    /// The selection kept inside a row of `count` tiles.
    nonisolated static func clamped(_ selection: Int, count: Int) -> Int {
        count == 0 ? 0 : min(max(0, selection), count - 1)
    }

    /// One key against the bar: the next state and what the bar does.
    nonisolated static func reduce(_ state: State, key: Key,
                                   items: [MenuBarItem]) -> (State, Effect) {
        var next = state
        let visible = filter(items, query: state.query)
        let selected = clamped(state.selection, count: visible.count)
        switch key {
        case .left:
            next.selection = clamped(selected - 1, count: visible.count)
        case .right:
            next.selection = clamped(selected + 1, count: visible.count)
        case .first:
            next.selection = 0
        case .last:
            next.selection = clamped(visible.count - 1, count: visible.count)
        case .text(let typed):
            next.query += typed
            next.selection = 0
        case .backspace:
            guard !next.query.isEmpty else { return (state, .none) }
            next.query.removeLast()
            next.selection = 0
        case .submit:
            guard visible.indices.contains(selected) else { return (state, .none) }
            return (state, .trigger(itemID: visible[selected].id))
        case .jump(let place):
            guard visible.indices.contains(place - 1) else { return (state, .none) }
            return (state, .trigger(itemID: visible[place - 1].id))
        case .cancel:
            guard !state.query.isEmpty else { return (state, .close) }
            next = State()
        }
        return (next, .none)
    }

    /// A key event as a bar key — nil for anything the bar leaves alone
    /// (⌃ and ⌥ chords, ⌘ with anything but a digit, bare modifiers).
    nonisolated static func key(keyCode: UInt16, characters: String?,
                                modifiers: NSEvent.ModifierFlags) -> Key? {
        let flags = modifiers.intersection([.command, .control, .option, .shift])
        switch Int(keyCode) {
        case kVK_LeftArrow: return .left
        case kVK_RightArrow: return .right
        case kVK_Home: return .first
        case kVK_End: return .last
        case kVK_Tab: return flags.contains(.shift) ? .left : .right
        case kVK_Return, kVK_ANSI_KeypadEnter: return .submit
        case kVK_Escape: return .cancel
        case kVK_Delete: return .backspace
        default: break
        }
        guard let characters, !characters.isEmpty else { return nil }
        if flags == .command {
            if let digit = Int(characters), (1...9).contains(digit) { return .jump(digit) }
            return nil
        }
        guard flags.isSubset(of: [.shift]),
              characters.unicodeScalars.allSatisfy({ !CharacterSet.controlCharacters.contains($0)
                                                      && $0.value < 0xF700 }) else { return nil }
        return .text(characters)
    }

    /// The typed filter's chip width — measured in the chip's own font,
    /// so the glass grows by what the chip draws.
    nonisolated static func chipWidth(_ query: String) -> CGFloat {
        guard !query.isEmpty else { return 0 }
        let font = NSFont.systemFont(ofSize: 12, weight: .medium)
        let text = (query as NSString).size(withAttributes: [.font: font]).width
        return min(160, max(28, ceil(text) + 20))
    }
}

/// The bar's live contents — an `@Observable` model rather than a
/// `let` snapshot so the open panel follows the reconcile: items that
/// come and go under the pointer re-tile instead of listing ghosts.
@MainActor
@Observable
final class MenuBarBarModel {
    var items: [MenuBarItem] = []
    /// Items macOS parked off the row — no pixels to capture, so their
    /// tiles carry the state glyph instead of pretending otherwise.
    var parkedIDs: Set<String> = []
    /// Photographed glyphs by item id — the real face a concealed item
    /// has no pixels for right now.
    var glyphs: [String: MenuBarGlyphCache.Face] = [:]
    /// Items whose picture changed since the bar last closed — a sync
    /// badge, a VPN's state — marked with a dot.
    var updatedIDs: Set<String> = []
    /// The keyboard's state while the bar was opened from the keyboard;
    /// nil for a pointer's bar, which never takes key.
    var keys: MenuBarBarKeys.State?

    /// The tiles standing: all of them, or what the typed filter leaves.
    var visibleItems: [MenuBarItem] {
        keys.map { MenuBarBarKeys.filter(items, query: $0.query) } ?? items
    }

    /// The selected tile's id while the keyboard drives the bar.
    var selectedID: String? {
        guard let keys else { return nil }
        let visible = visibleItems
        guard !visible.isEmpty else { return nil }
        return visible[MenuBarBarKeys.clamped(keys.selection, count: visible.count)].id
    }

    /// Each visible tile's width, in order: a live capture's or a
    /// glyph's own width, clamped; the square otherwise.
    func tileWidths(liveWidths: [String: CGFloat]) -> [CGFloat] {
        visibleItems.map { item in
            MenuBarBarLayout.tileWidth(glyphWidth: liveWidths[item.id] ?? glyphs[item.id]?.width)
        }
    }

    /// The row's widths as the frame measures them: the typed filter's
    /// chip, when there is one, leads the tiles.
    func rowWidths(liveWidths: [String: CGFloat]) -> [CGFloat] {
        let chip = MenuBarBarKeys.chipWidth(keys?.query ?? "")
        return (chip > 0 ? [chip] : []) + tileWidths(liveWidths: liveWidths)
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

    init(model: MenuBarBarModel,
         tiles: MenuBarLiveTiles,
         onTrigger: @escaping @MainActor (MenuBarItem) -> Void,
         onRevealItem: @escaping @MainActor (MenuBarItem) -> Void,
         itemSection: @escaping @MainActor (MenuBarItem) -> MenuBarItemSection,
         onMoveItem: @escaping @MainActor (MenuBarItem, MenuBarItemSection) -> Void) {
        let hosting = NSHostingView(rootView: MenuBarBarView(
            model: model, tiles: tiles,
            onTrigger: onTrigger, onRevealItem: onRevealItem,
            itemSection: itemSection, onMoveItem: onMoveItem))
        self.hosting = hosting
        let glass = NSGlassEffectView(frame: NSRect(x: 0, y: 0, width: 120, height: 26))
        glass.cornerRadius = Self.cornerRadius
        glass.style = .regular
        glass.contentView = hosting
        super.init(contentRect: NSRect(x: 0, y: 0, width: 120, height: 26),
                   styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        contentView = GlassBackdrop.rounded(glass, cornerRadius: Self.cornerRadius)
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

    /// Opened from the keyboard the bar takes key — nonactivating, so the
    /// frontmost app keeps its focus, as the command bar does. A
    /// pointer's bar never does.
    var takesKeys = false
    override var canBecomeKey: Bool { takesKeys }
    override var canBecomeMain: Bool { false }
}

/// The tiles' SwiftUI half: each tile shows the item's own face — a
/// `SCScreenshotManager` one-shot of its on-screen rect when it stands
/// on the row, else the glyph photographed while it last did — falling
/// back to the owner app's icon only when neither is honest to show (no
/// Screen Recording, never photographed). Click triggers the item,
/// ⌘-click reveals it, right-click offers the section moves.
struct MenuBarBarView: View {
    let model: MenuBarBarModel
    let tiles: MenuBarLiveTiles
    let onTrigger: @MainActor (MenuBarItem) -> Void
    let onRevealItem: @MainActor (MenuBarItem) -> Void
    /// The tile's right-click menu reads the live section through this
    /// so the "Move to…" rows always offer the other two homes.
    let itemSection: @MainActor (MenuBarItem) -> MenuBarItemSection
    /// A context-menu move — the same section write the card's pickers
    /// make; the tile itself never drags anything.
    let onMoveItem: @MainActor (MenuBarItem, MenuBarItemSection) -> Void

    private var items: [MenuBarItem] { model.visibleItems }

    var body: some View {
        let widths = model.tileWidths(liveWidths: tiles.imageWidths)
        let query = model.keys?.query ?? ""
        let selectedID = model.selectedID
        Group {
            if items.isEmpty && query.isEmpty {
                Text("No hidden items")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity)
                    .frame(height: MenuBarBarLayout.tileSize)
            } else {
                GeometryReader { geometry in
                    let overflow = MenuBarBarLayout.rowWidth(
                        widths: model.rowWidths(liveWidths: tiles.imageWidths)) > geometry.size.width
                    ScrollViewReader { proxy in
                        ScrollView(.horizontal) {
                            HStack(spacing: MenuBarBarLayout.tileGap) {
                                if !query.isEmpty {
                                    queryChip(query)
                                }
                                ForEach(Array(zip(items, widths)), id: \.0.id) { item, width in
                                    Button {
                                        if NSEvent.modifierFlags.contains(.command) {
                                            onRevealItem(item)
                                        } else {
                                            onTrigger(item)
                                        }
                                    } label: {
                                        tileLabel(for: item, width: width)
                                            .background {
                                                if item.id == selectedID {
                                                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                                                        .fill(Color.accentColor.opacity(0.22))
                                                }
                                            }
                                    }
                                    .buttonStyle(.plain)
                                    .id(item.id)
                                    .accessibilityLabel(itemLabel(for: item))
                                    .accessibilityAddTraits(item.id == selectedID ? .isSelected : [])
                                    .help(tooltip(for: item))
                                    .contextMenu { moveMenu(for: item) }
                                }
                            }
                        }
                        .scrollIndicators(overflow ? .visible : .hidden)
                        .accessibilityLabel("Hidden menu bar items")
                        .onChange(of: selectedID) { _, id in
                            if let id { proxy.scrollTo(id, anchor: .center) }
                        }
                    }
                }
            }
        }
        .padding(MenuBarBarLayout.padding)
    }

    /// What the keyboard has typed — the filter the row stands under.
    private func queryChip(_ query: String) -> some View {
        Text(query)
            .font(.system(size: 12, weight: .medium))
            .lineLimit(1)
            .truncationMode(.head)
            .foregroundStyle(.secondary)
            .frame(width: MenuBarBarKeys.chipWidth(query), height: 22)
            .background(.quaternary, in: Capsule())
            .frame(height: MenuBarBarLayout.tileSize)
            .accessibilityLabel("Filter: \(query)")
    }

    private func itemLabel(for item: MenuBarItem) -> String {
        guard let title = item.title, !title.isEmpty else { return item.ownerName }
        return "\(item.ownerName) · \(title)"
    }

    /// The tile face, best first: the live capture of an item standing
    /// on the row; its photographed glyph (a template tinted in the bar's
    /// own label colour); the owner app's icon. A parked item with no
    /// glyph carries the parked mark; an item whose picture changed since
    /// the bar last closed carries a dot.
    @ViewBuilder
    private func tileLabel(for item: MenuBarItem, width: CGFloat) -> some View {
        Group {
            if let live = tiles.images[item.id] {
                Image(nsImage: live)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(height: 22)
            } else if let glyph = model.glyphs[item.id] {
                Image(nsImage: glyph.image)
                    .renderingMode(glyph.template ? .template : .original)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .foregroundStyle(.primary)
                    .frame(height: 22)
            } else {
                Image(nsImage: item.owner?.icon
                      ?? NSImage(systemSymbolName: "questionmark.square.dashed",
                                 variableValue: 0,
                                 accessibilityDescription: nil)
                      ?? NSImage())
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(width: 22, height: 22)
            }
        }
        .frame(width: width, height: MenuBarBarLayout.tileSize)
        .contentShape(Rectangle())
        .overlay(alignment: .bottomTrailing) {
            if model.parkedIDs.contains(item.id), model.glyphs[item.id] == nil,
               tiles.images[item.id] == nil {
                Image(systemName: "arrow.down.forward.and.arrow.up.backward")
                    .font(.system(size: 8, weight: .bold))
                    .foregroundStyle(.secondary)
                    .padding(1)
                    .background(.regularMaterial, in: Circle())
            }
        }
        .overlay(alignment: .topTrailing) {
            if model.updatedIDs.contains(item.id) {
                Circle()
                    .fill(Color.accentColor)
                    .frame(width: 5, height: 5)
                    .accessibilityLabel("Changed")
            }
        }
    }

    /// The right-click menu: re-home the item to whichever sections it
    /// is not already in — the same writes the card's pickers make.
    @ViewBuilder
    private func moveMenu(for item: MenuBarItem) -> some View {
        let section = itemSection(item)
        if section != .hidden {
            Button("Move to Hidden") { onMoveItem(item, .hidden) }
        }
        if section != .alwaysHidden {
            Button("Move to Always Hidden") { onMoveItem(item, .alwaysHidden) }
        }
        if section != .shown {
            Button("Move to Shown") { onMoveItem(item, .shown) }
        }
    }

    private func tooltip(for item: MenuBarItem) -> String {
        var name = item.ownerName
        if let title = item.title { name += " · \(title)" }
        return name + " — click to open, ⌘-click to keep it out, right-click to move it"
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
    /// The tile's context menu: which section it sits in, and the
    /// write a "Move to…" row makes.
    var itemSection: @MainActor (MenuBarItem) -> MenuBarItemSection = { _ in .hidden }
    var onMoveItem: @MainActor (MenuBarItem, MenuBarItemSection) -> Void = { _, _ in }
    /// Open changes, so the reveal can hold while the pointer is on it
    /// and start a short clock when it folds.
    var onOpenChange: @MainActor (Bool) -> Void = { _ in }
    /// A photographed glyph for an item, when the cache has one.
    var glyphFace: @MainActor (MenuBarItem) -> MenuBarGlyphCache.Face? = { _ in nil }
    /// Where the bar hangs: the icon's frame in AppKit screen coordinates
    /// (its ‹ sits at the left edge) — nil hangs it at the screen's edge.
    var anchorFrame: @MainActor () -> NSRect? = { nil }
    /// Ids whose picture changed since the bar last closed.
    var updatedIDs: Set<String> = [] {
        didSet { model.updatedIDs = updatedIDs }
    }

    /// The live thumbnails — one pass when the bar opens, never a loop:
    /// every capture lights the screen-recording indicator, which shifts
    /// the whole bar.
    let tiles = MenuBarLiveTiles()
    /// What the open panel lists — refreshed on every reconcile while
    /// the bar is up, so the tiles are never a frozen snapshot.
    private let model = MenuBarBarModel()

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

    /// Whether the open bar is the keyboard's.
    var isKeyboardDriven: Bool { isOpen && model.keys != nil }

    /// The screen the bar hangs from — the pointer's, so a multi-
    /// display setup opens it where the hand is, falling back to the
    /// display carrying the menu bar.
    private var pointerScreen: NSScreen? {
        NSScreen.screens.first { $0.frame.contains(NSEvent.mouseLocation) } ?? NSScreen.main
    }

    /// Opens the bar under the icon's ‹ (or the menu bar's right end) —
    /// or refreshes it when it is already up. The tiles track the
    /// provider through `model` for as long as the bar stands.
    /// `keyboard` is the hotkey's bar: it takes key and answers the
    /// keys `MenuBarBarKeys` reads.
    func open(keyboard: Bool = false) {
        if isOpen { close() }
        guard let screen = pointerScreen else { return }
        let listed = items()
        let rows = MenuBarItemLister.menuBarRows()
        model.items = listed
        // Parked means off every display's bar — a secondary-row item
        // is standing, not parked.
        model.parkedIDs = Set(listed.filter { item in
            !rows.contains { $0.intersects(item.bounds) }
        }.map(\.id))
        model.glyphs = glyphs(for: listed)
        model.keys = keyboard ? MenuBarBarKeys.State() : nil
        let panel = MenuBarBarPanel(
            model: model,
            tiles: tiles,
            onTrigger: { [weak self] item in self?.onTrigger(item) },
            onRevealItem: { [weak self] item in self?.onRevealItem(item) },
            itemSection: { [weak self] item in
                self.map { $0.itemSection(item) } ?? .hidden
            },
            onMoveItem: { [weak self] item, section in
                self?.onMoveItem(item, section)
            })
        panel.setFrame(frame(on: screen), display: false)
        if keyboard {
            panel.takesKeys = true
            panel.makeKeyAndOrderFront(nil)
        } else {
            panel.orderFrontRegardless()
        }
        self.panel = panel
        isOpen = true
        openedAtUptime = ProcessInfo.processInfo.systemUptime
        onOpenChange(true)
        installDismissMonitors()
        // One capture pass for whatever stands on the row now; the
        // photographed glyphs carry the rest.
        tiles.itemsProvider = items
        tiles.rowRects = { MenuBarItemLister.menuBarRows() }
        tiles.start()
    }

    /// The photographed faces for `items`.
    private func glyphs(for items: [MenuBarItem]) -> [String: MenuBarGlyphCache.Face] {
        var faces: [String: MenuBarGlyphCache.Face] = [:]
        for item in items {
            if let face = glyphFace(item) { faces[item.id] = face }
        }
        return faces
    }

    /// The panel's frame for the current tiles: under the icon's ‹ when
    /// it stands on this screen, else at the screen's right end.
    private func frame(on screen: NSScreen) -> NSRect {
        let depth = max(NSStatusBar.system.thickness, ScreenBarGeometry.notchDepth(of: screen))
        let anchor = anchorFrame().flatMap { frame in
            screen.frame.contains(NSPoint(x: frame.midX, y: frame.midY)) ? frame.maxX : nil
        }
        return MenuBarBarLayout.frame(widths: model.rowWidths(liveWidths: tiles.imageWidths),
                                      menuBarDepth: depth, on: screen.frame, anchorMaxX: anchor)
    }

    /// The glyph cache filed new photographs — the open bar wears them.
    func glyphsChanged() {
        guard isOpen, let panel else { return }
        let faces = glyphs(for: model.items)
        guard faces.mapValues(\.width) != model.glyphs.mapValues(\.width)
                || Set(faces.keys) != Set(model.glyphs.keys) else {
            model.glyphs = faces
            return
        }
        model.glyphs = faces
        guard let screen = panel.screen ?? pointerScreen else { return }
        panel.setFrame(frame(on: screen), display: true)
    }

    /// Push the provider's current list into the open bar — called on
    /// every reconcile so the panel follows items coming and going
    /// under the pointer. A changed count re-frames the panel against
    /// its own screen.
    func syncItems() {
        guard isOpen, let panel else { return }
        let listed = items()
        let rows = MenuBarItemLister.menuBarRows()
        let parked = Set(listed.filter { item in
            !rows.contains { $0.intersects(item.bounds) }
        }.map(\.id))
        guard listed != model.items || parked != model.parkedIDs else { return }
        model.items = listed
        model.parkedIDs = parked
        model.glyphs = glyphs(for: listed)
        guard let screen = panel.screen ?? pointerScreen else { return }
        panel.setFrame(frame(on: screen), display: true)
    }

    /// One key against the keyboard's bar.
    func press(_ key: MenuBarBarKeys.Key) {
        guard isOpen, let state = model.keys else { return }
        let (next, effect) = MenuBarBarKeys.reduce(state, key: key, items: model.items)
        switch effect {
        case .none:
            model.keys = next
            // The filter changed the row: the glass follows it.
            if next.query != state.query, let panel,
               let screen = panel.screen ?? pointerScreen {
                panel.setFrame(frame(on: screen), display: true)
            }
        case .trigger(let id):
            if let item = model.items.first(where: { $0.id == id }) { onTrigger(item) }
        case .close:
            close()
        }
    }

    func close() {
        guard isOpen else { return }
        for monitor in dismissMonitors { NSEvent.removeMonitor(monitor) }
        dismissMonitors = []
        tiles.stop()
        panel?.orderOut(nil)
        panel = nil
        isOpen = false
        // Seen: the change marks clear with the bar, and the keyboard's
        // filter with it.
        updatedIDs = []
        model.keys = nil
        onOpenChange(false)
    }

    isolated deinit {
        for monitor in dismissMonitors { NSEvent.removeMonitor(monitor) }
        panel?.orderOut(nil)
    }

    /// A click anywhere but the bar folds it — the panel never takes
    /// focus, so "outside" is a monitor's call, not a resign event.
    /// Escape folds it too: the panel never becomes key, so the key
    /// arrives through the same monitors, whichever app is frontmost.
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
        if let keys = NSEvent.addGlobalMonitorForEvents(
            matching: .keyDown,
            handler: { [weak self] event in
                guard event.keyCode == UInt16(kVK_Escape) else { return }
                Task { @MainActor [weak self] in self?.close() }
            }) {
            dismissMonitors.append(keys)
        }
        if let localKeys = NSEvent.addLocalMonitorForEvents(
            matching: .keyDown,
            handler: { [weak self] event in
                guard let self else { return event }
                // The keyboard's bar answers its keys; a pointer's bar
                // only folds on Esc.
                if self.model.keys != nil {
                    guard let key = MenuBarBarKeys.key(keyCode: event.keyCode,
                                                       characters: event.charactersIgnoringModifiers,
                                                       modifiers: event.modifierFlags)
                    else { return event }
                    self.press(key)
                    return nil
                }
                guard event.keyCode == UInt16(kVK_Escape) else { return event }
                self.close()
                return nil
            }) {
            dismissMonitors.append(localKeys)
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
