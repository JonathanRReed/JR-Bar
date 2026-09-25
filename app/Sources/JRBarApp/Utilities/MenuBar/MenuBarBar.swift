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

    /// The same, centred under `anchorMidX` — the pointer's x when the
    /// bar hangs at the pointer, the icon's middle for a drop's note.
    static func frame(widths: [CGFloat], menuBarDepth: CGFloat, on screenFrame: NSRect,
                      anchorMidX: CGFloat) -> NSRect {
        let size = contentSize(widths: widths, availableWidth: screenFrame.width - 2 * edgeMargin)
        return frame(size: size, menuBarDepth: menuBarDepth, on: screenFrame,
                     anchorMaxX: anchorMidX + size.width / 2)
    }

    /// A drop's note: one line of text beside its mark, in glass.
    static let noteHeight: CGFloat = 32
    static let noteMaxWidth: CGFloat = 640

    /// The note's glass for `text`: the text at the note's font, its
    /// mark and the padding, never wider than `noteMaxWidth`.
    static func noteSize(_ text: String) -> NSSize {
        let font = NSFont.systemFont(ofSize: 12, weight: .medium)
        let width = (text as NSString).size(withAttributes: [.font: font]).width
        // The text, its mark and the gap beside it (22), the row's own
        // inset (8), the glass's padding each side, and a few points of
        // slack so a measured line never truncates.
        return NSSize(width: min(noteMaxWidth, ceil(width) + 2 * padding + 36), height: noteHeight)
    }

    /// Where a note of `size` hangs: centred under `anchorMidX`, else at
    /// the screen's right end, kept on the screen.
    static func noteFrame(size: NSSize, menuBarDepth: CGFloat, on screenFrame: NSRect,
                          anchorMidX: CGFloat?) -> NSRect {
        frame(size: size, menuBarDepth: menuBarDepth, on: screenFrame,
              anchorMaxX: anchorMidX.map { $0 + size.width / 2 })
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

    /// Whether the bar's local key monitor takes a key-down. The
    /// keyboard's bar claims every key aimed at its own window — it
    /// answers its own and swallows the rest, so a stray ⌘Q or ⌘W never
    /// reaches JR-Bar's menus from under it — and leaves a key aimed at
    /// another JR-Bar window, the palette's field, to that window. The
    /// pointer's bar takes Esc alone, to fold.
    nonisolated static func claims(keyCode: UInt16, keyboard: Bool, inBar: Bool) -> Bool {
        keyboard ? inBar : Int(keyCode) == kVK_Escape
    }

    /// The typed filter's chip width — measured in the chip's own font,
    /// with room for its magnifier, so the glass grows by what the chip
    /// draws.
    nonisolated static func chipWidth(_ query: String) -> CGFloat {
        guard !query.isEmpty else { return 0 }
        let font = NSFont.systemFont(ofSize: 12, weight: .semibold)
        let text = (query as NSString).size(withAttributes: [.font: font]).width
        return min(170, max(40, ceil(text) + 36))
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
    /// A drop's one-line note — why a ⌘-drag across the icon did what it
    /// did, or nothing. The note's glass shows it alone.
    var note: String?

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

/// What the menu bar tells the Screen Bar's right ear — its reveal,
/// update and newcomer surface, the one spot beside the notch that never
/// moves with the bar's reflow. `MenuBarUtility` publishes it while it
/// renders the bar; `ScreenBarController` draws it: marks on the ear,
/// and a black peek of the hidden glyphs hanging from the notch, where
/// the words live. nil while the utility is parked or another manager
/// renders.
struct MenuBarEarFeed: Equatable {
    /// One hidden item as the peek tiles it: the item, its photographed
    /// face when the cache has one, and whether its picture or title
    /// changed since the Item Bar last closed.
    struct Tile: Equatable, Identifiable {
        var item: MenuBarItem
        var face: MenuBarGlyphCache.Face?
        var changed = false

        var id: String { item.id }
        /// The Item Bar's rule: a glyph's own width, clamped; the square
        /// for an app icon.
        var width: CGFloat { MenuBarBarLayout.tileWidth(glyphWidth: face?.width) }
        /// The tooltip's and VoiceOver's name for it.
        var name: String {
            guard let title = item.title, !title.isEmpty else { return item.ownerName }
            return "\(item.ownerName) · \(title)"
        }
    }

    /// Something on the bar worth a glance: an app whose item is new to
    /// the menu bar, or a hidden item that changed while tucked away. The
    /// ear shows its glyph; the peek offers Keep / Tuck away / Always.
    /// Ignoring it changes nothing — nothing joins a section on its own.
    struct Nudge: Equatable, Identifiable {
        enum Kind: Equatable {
            case newcomer, update
        }

        /// Unique per nudge — a second change of the same item is a new
        /// subject for the ear.
        var id: String
        var kind: Kind
        /// The item, and the face the cache holds for it.
        var tile: Tile
        /// The owner's icon, for an item never photographed.
        var icon: NSImage?
        /// The changed item's new title, when it has one.
        var detail: String?
        /// Where the item sits now — the choice already made.
        var section: MenuBarItemSection

        /// The peek's heading for it.
        var heading: String {
            kind == .newcomer ? "New in your menu bar" : "Changed while tucked away"
        }

        /// VoiceOver's words for the ear's mark.
        var words: String {
            switch kind {
            case .newcomer:
                return "\(tile.item.ownerName) is new in the menu bar"
            case .update:
                return "\(tile.item.ownerName) changed while tucked away"
                    + (detail.map { $0.isEmpty ? "" : ": \($0)" } ?? "")
            }
        }
    }

    /// The hidden and always-hidden runs, in the Item Bar's order.
    var hidden: [Tile] = []
    /// Why hiding stopped, in the peek's words — the ear's alert mark
    /// stands while it is set. nil while the engine is healthy.
    var failure: String?
    /// The nudge standing now, if any — one at a time.
    var nudge: Nudge?

    /// Whether there is anything of the menu bar's for the ear to show.
    var isEmpty: Bool { hidden.isEmpty && failure == nil && nudge == nil }

    /// The failure worth an alert on the ear, or nil. Only two states
    /// are one: macOS refusing every assertion (nothing is hidden, the
    /// real icon is back), and the concealer's framework missing on a
    /// macOS that ships it — a point release that renamed it. On macOS
    /// 26 the spacer engine is simply the engine, and a forced or
    /// unnotarized spacer is the person's own choice: no alert.
    nonisolated static func failure(for health: MenuBarEngineHealth, osMajor: Int) -> String? {
        switch health {
        case .concealerFailing:
            return health.line()
        case .spacer(.frameworkMissing) where osMajor >= 27:
            return "macOS's concealer didn't load on this Mac, so hiding fell back to the spacer engine — a macOS update may have moved it."
        default:
            return nil
        }
    }

    /// The feed for `items` — the Item Bar's own tiles, each wearing the
    /// face the cache holds for it.
    @MainActor
    static func tiles(_ items: [MenuBarItem], face: (MenuBarItem) -> MenuBarGlyphCache.Face?,
                      changed: Set<String>) -> [Tile] {
        items.map { Tile(item: $0, face: face($0), changed: changed.contains($0.id)) }
    }
}

/// A nudge's three answers — the three sections, in the words the peek
/// offers them. Choosing the section the item already sits in is an
/// acknowledgement: the nudge goes and the pick is recorded explicitly.
enum MenuBarEarChoice: CaseIterable, Sendable {
    case keep, tuckAway, always

    var section: MenuBarItemSection {
        switch self {
        case .keep: return .shown
        case .tuckAway: return .hidden
        case .always: return .alwaysHidden
        }
    }

    var title: String {
        switch self {
        case .keep: return "Keep"
        case .tuckAway: return "Tuck away"
        case .always: return "Always"
        }
    }

    var help: String {
        switch self {
        case .keep: return "Keep it on the menu bar"
        case .tuckAway: return "Hide it behind the icon — a hover or the peek brings it back"
        case .always: return "Always hidden — only the Item Bar and this peek reach it"
        }
    }
}

/// Which apps are new to the menu bar — pure, so a test pins the rules.
/// The first time an app's item appears on the bar the ear nudges; once,
/// ever. The first listing JR-Bar reads is the baseline, learned in
/// silence, so turning this on never nudges about the whole bar.
enum MenuBarNewcomers {
    /// The apps in `items` a nudge can speak for, in bar order, once
    /// each: someone else's, concealable per app (Apple's own extras and
    /// bare helpers are not), never our own family.
    nonisolated static func candidates(_ items: [MenuBarItem], ownBundleID: String?) -> [String] {
        var seen = Set<String>()
        var out: [String] = []
        for item in items where !item.isNativeOverflowControl
            && !MenuBarItemLister.isProtected(ownerName: item.ownerName) {
            guard let id = item.bundleID, MenuBarConcealPlan.canConcealApp(id),
                  !(ownBundleID.map { id == $0 || id.hasPrefix($0 + ".") } ?? false),
                  seen.insert(id).inserted else { continue }
            out.append(id)
        }
        return out
    }

    /// One listing against the memory: what to remember (nil: nothing
    /// new to write) and which apps arrived. An empty listing teaches
    /// nothing — the grant may be missing. No memory yet is the
    /// baseline: everything listed, and everything already given a
    /// section, is remembered without a word. So is every listing while
    /// `settling` — the first seconds of a run, while the listing fills
    /// in and login items put their icons up. After that an arrival is
    /// an app never seen and never placed — one the person already
    /// sorted (a profile, the card) is not news.
    nonisolated static func step(candidates: [String], seen: Set<String>?, mapped: Set<String>,
                                 settling: Bool = false) -> (remember: Set<String>?, arrivals: [String]) {
        guard !candidates.isEmpty else { return (nil, []) }
        guard let seen else { return (Set(candidates).union(mapped), []) }
        let arrivals = candidates.filter { !seen.contains($0) && !mapped.contains($0) }
        guard !arrivals.isEmpty else { return (nil, []) }
        return (seen.union(arrivals), settling ? [] : arrivals)
    }
}

/// The apps the menu bar has ever shown — the newcomer nudge's memory,
/// kept in the app's own defaults (bundle identifiers only, on this Mac).
/// The app delegate gives the utility one; a test utility has none, so no
/// test learns a bar or writes the defaults.
@MainActor
final class MenuBarNewcomerMemory {
    private let load: () -> [String]?
    private let save: ([String]) -> Void
    private var cached: Set<String>??

    init(load: @escaping () -> [String]?, save: @escaping ([String]) -> Void) {
        self.load = load
        self.save = save
    }

    /// Backed by `defaults` under `key`.
    convenience init(defaults: UserDefaults = .standard, key: String = "jrbar.menubar.seenMenuBarApps") {
        self.init(load: { defaults.stringArray(forKey: key) },
                  save: { defaults.set($0, forKey: key) })
    }

    /// Every app remembered, or nil before the baseline is learned.
    var seen: Set<String>? {
        if let cached { return cached }
        let loaded = load().map(Set.init)
        cached = .some(loaded)
        return loaded
    }

    /// Remember `apps` — the whole set, written in one go.
    func remember(_ apps: Set<String>) {
        cached = .some(apps)
        save(apps.sorted())
    }
}

/// Where an open Item Bar hangs from. Under the icon it follows the icon
/// on every re-frame. Under the pointer it keeps the spot the pointer had
/// when the bar opened: photos landing, an item coming or going, or a
/// tile dragged out all re-frame the bar, and a bar that re-centred on
/// the pointer each time would slide its tiles away from the hand
/// reaching for one.
struct MenuBarBarAnchor {
    /// The pointer's spot at open, while the bar stands under it.
    private(set) var pinned: NSRect?

    /// The bar opened with `spot` as its anchor: under the pointer it is
    /// the pointer's spot, kept until the bar folds.
    mutating func opened(underPointer: Bool, spot: NSRect?) {
        pinned = underPointer ? spot : nil
    }

    /// The bar folded: the next open reads the pointer again.
    mutating func closed() {
        pinned = nil
    }

    /// The anchor a frame hangs from, and whether the bar centres on it:
    /// the kept spot while there is one, else `icon`, the ‹ as it stands.
    func current(icon: NSRect?) -> (rect: NSRect?, centred: Bool) {
        if let pinned { return (pinned, true) }
        return (icon, false)
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
         onMoveItem: @escaping @MainActor (MenuBarItem, MenuBarItemSection) -> Void,
         updateWatch: @escaping @MainActor (MenuBarItem) -> Bool? = { _ in nil },
         onUpdateWatch: @escaping @MainActor (MenuBarItem, Bool) -> Void = { _, _ in },
         beginDrag: @escaping @MainActor (MenuBarItem, NSImage?) -> Void = { _, _ in }) {
        let hosting = NSHostingView(rootView: MenuBarBarView(
            model: model, tiles: tiles,
            onTrigger: onTrigger, onRevealItem: onRevealItem,
            itemSection: itemSection, onMoveItem: onMoveItem,
            updateWatch: updateWatch, onUpdateWatch: onUpdateWatch,
            beginDrag: beginDrag))
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
    /// Whether show for updates watches the item by name — nil while the
    /// feature is off, and the menu leaves the row out.
    var updateWatch: @MainActor (MenuBarItem) -> Bool? = { _ in nil }
    var onUpdateWatch: @MainActor (MenuBarItem, Bool) -> Void = { _, _ in }
    /// A tile dragged past a few points: the bar starts its own drag
    /// session with the tile's face, so the tile can be dropped on the
    /// menu bar right of the icon to show its app.
    var beginDrag: @MainActor (MenuBarItem, NSImage?) -> Void = { _, _ in }
    /// The tile under the pointer, for its plate.
    @ViewState private var hoveredID: String?
    /// Reduce Motion keeps a pressed tile still; its plate still darkens.
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var items: [MenuBarItem] { model.visibleItems }

    var body: some View {
        let widths = model.tileWidths(liveWidths: tiles.imageWidths)
        let query = model.keys?.query ?? ""
        let selectedID = model.selectedID
        Group {
            if let note = model.note {
                MenuBarDropNoteRow(text: note)
            } else if items.isEmpty && query.isEmpty {
                Text("No hidden items")
                    .font(.system(size: 12, weight: .medium))
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
                                    }
                                    .buttonStyle(MenuBarTileStyle(selected: item.id == selectedID,
                                                                  hovered: item.id == hoveredID,
                                                                  dips: !reduceMotion))
                                    .onHover { inside in
                                        if inside {
                                            hoveredID = item.id
                                        } else if hoveredID == item.id {
                                            hoveredID = nil
                                        }
                                    }
                                    .id(item.id)
                                    .simultaneousGesture(DragGesture(minimumDistance: 6).onChanged { _ in
                                        beginDrag(item, dragImage(for: item))
                                    })
                                    .accessibilityLabel(itemLabel(for: item))
                                    .accessibilityAddTraits(item.id == selectedID ? .isSelected : [])
                                    .help(tooltip(for: item))
                                    .contextMenu { moveMenu(for: item) }
                                }
                            }
                            // A point of slack each side, taken back from
                            // the glass's padding: the clip view never
                            // shaves a chip's or a plate's edge.
                            .padding(.horizontal, 1)
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
        .padding(.vertical, model.note == nil ? MenuBarBarLayout.padding : 0)
        .padding(.horizontal, MenuBarBarLayout.padding - 1)
    }

    /// The face a tile's drag carries: the live capture, the photograph,
    /// or the app's icon.
    private func dragImage(for item: MenuBarItem) -> NSImage? {
        tiles.images[item.id] ?? model.glyphs[item.id]?.image ?? MenuBarAppIcons.icon(for: item)
    }

    /// What the keyboard has typed — the filter the row stands under,
    /// in the accent the keyboard's pick wears.
    private func queryChip(_ query: String) -> some View {
        HStack(spacing: 4) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 9.5, weight: .bold))
                .foregroundStyle(Color.accentColor)
            Text(query)
                .font(.system(size: 12, weight: .semibold))
                .lineLimit(1)
                .truncationMode(.head)
        }
        .padding(.horizontal, 9)
        .frame(width: MenuBarBarKeys.chipWidth(query), height: 24, alignment: .leading)
        .background(Capsule().fill(Color.accentColor.opacity(0.14)))
        .overlay(Capsule().strokeBorder(Color.accentColor.opacity(0.3), lineWidth: 0.5))
        .frame(height: MenuBarBarLayout.tileSize)
        .accessibilityLabel("Filter: \(query)")
    }

    private func itemLabel(for item: MenuBarItem) -> String {
        guard let title = item.title, !title.isEmpty else { return item.ownerName }
        return "\(item.ownerName) · \(title)"
    }

    /// The tile face, best first: the live capture of an item standing
    /// on the row; its photographed glyph (a template tinted in the bar's
    /// own label colour); the owner app's icon (`MenuBarAppFace`). A
    /// parked item with no glyph carries the parked mark; an item whose
    /// picture changed since the bar last closed carries a dot.
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
                MenuBarAppFace(item: item, size: 20)
            }
        }
        .frame(width: width, height: MenuBarBarLayout.tileSize)
        .contentShape(Rectangle())
        .overlay(alignment: .bottomTrailing) {
            if model.parkedIDs.contains(item.id), model.glyphs[item.id] == nil,
               tiles.images[item.id] == nil {
                Image(systemName: "arrow.down.forward.and.arrow.up.backward")
                    .font(.system(size: 7, weight: .heavy))
                    .foregroundStyle(.white)
                    .frame(width: 13, height: 13)
                    .background(Circle().fill(Color.black.opacity(0.55)))
                    .offset(x: 1, y: 1)
                    .help("Parked off the menu bar by macOS")
            }
        }
        .overlay(alignment: .topTrailing) {
            if model.updatedIDs.contains(item.id) {
                Circle()
                    .fill(Color.accentColor)
                    .frame(width: 6, height: 6)
                    .shadow(color: Color.accentColor.opacity(0.6), radius: 2)
                    .offset(x: -1, y: 2)
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
        if let watched = updateWatch(item) {
            Divider()
            Toggle("Show When It Changes", isOn: Binding(
                get: { watched },
                set: { onUpdateWatch(item, $0) }))
        }
    }

    private func tooltip(for item: MenuBarItem) -> String {
        var name = item.ownerName
        if let title = item.title { name += " · \(title)" }
        return name + " — click to open, ⌘-click to keep it out, drag it onto the bar right of the icon to show it, right-click to move it"
    }
}

/// A tile's plate: the keyboard's selection in the accent, the pointer's
/// hover and press in a quiet fill, so a click on the glass answers
/// before the item's own menu opens.
private struct MenuBarTileStyle: ButtonStyle {
    var selected: Bool
    var hovered: Bool
    /// A press dips the tile a touch — off under Reduce Motion.
    var dips = true

    func makeBody(configuration: Configuration) -> some View {
        let shape = RoundedRectangle(cornerRadius: 7, style: .continuous)
        configuration.label
            .background {
                shape.fill(Self.fill(selected: selected, hovered: hovered, pressed: configuration.isPressed))
            }
            .overlay {
                if selected {
                    shape.strokeBorder(Color.accentColor.opacity(0.55), lineWidth: 1)
                }
            }
            .scaleEffect(configuration.isPressed && dips ? 0.94 : 1)
            .animation(.easeOut(duration: 0.12), value: hovered)
            .animation(.easeOut(duration: 0.08), value: configuration.isPressed)
    }

    static func fill(selected: Bool, hovered: Bool, pressed: Bool) -> Color {
        if selected { return Color.accentColor.opacity(pressed ? 0.3 : 0.2) }
        if pressed { return Color.primary.opacity(0.14) }
        return hovered ? Color.primary.opacity(0.09) : .clear
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
    /// The tile menu's "Show When It Changes": nil hides the row.
    var updateWatch: @MainActor (MenuBarItem) -> Bool? = { _ in nil }
    var onUpdateWatch: @MainActor (MenuBarItem, Bool) -> Void = { _, _ in }
    /// Open changes, so the reveal can hold while the pointer is on it
    /// and start a short clock when it folds.
    var onOpenChange: @MainActor (Bool) -> Void = { _ in }
    /// A photographed glyph for an item, when the cache has one.
    var glyphFace: @MainActor (MenuBarItem) -> MenuBarGlyphCache.Face? = { _ in nil }
    /// Where the bar hangs: the icon's ‹ in AppKit screen coordinates —
    /// the bar's right edge under its right edge — nil hangs it at the
    /// screen's edge.
    var anchorFrame: @MainActor () -> NSRect? = { nil }
    /// Whether the bar hangs centred under the anchor instead — the
    /// pointer's spot (`MenuBarItemBarAnchor.pointer`).
    var centersOnAnchor: @MainActor () -> Bool = { false }
    /// A tile dropped off the bar, at an AppKit screen point.
    var onDragOut: @MainActor (MenuBarItem, NSPoint) -> Void = { _, _ in }
    /// What a drop's note hangs under — the icon; nil hangs it at the
    /// screen's right end.
    var noteAnchorFrame: @MainActor () -> NSRect? = { nil }
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
    /// Where the open bar hangs — the pointer's spot is read once, at open.
    private var hang = MenuBarBarAnchor()
    private var panel: MenuBarBarPanel?
    /// A drop's note, standing in the bar's glass on its own — no tiles,
    /// no capture, no clicks.
    private var notePanel: MenuBarBarPanel?
    private let noteModel = MenuBarBarModel()
    private var noteExpiry: Task<Void, Never>?
    /// The tile drag in flight — one session at a time.
    private var dragSource: MenuBarTileDragSource?
    private var dismissMonitors: [Any] = []
    /// The system uptime at open — a click event that predates it is
    /// the click that opened the bar, not one that should fold it.
    private var openedAtUptime: TimeInterval = 0

    /// The reveal's "is the pointer on the bar" answer.
    var panelFrame: NSRect? { isOpen ? panel?.frame : nil }

    func toggle() {
        if isOpen { close() } else { open() }
    }

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
            },
            updateWatch: { [weak self] item in self?.updateWatch(item) ?? nil },
            onUpdateWatch: { [weak self] item, on in self?.onUpdateWatch(item, on) },
            beginDrag: { [weak self] item, image in self?.beginTileDrag(item, image: image) })
        closeNote()
        hang.opened(underPointer: centersOnAnchor(), spot: anchorFrame())
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
    /// it stands on this screen (or centred on the pointer's spot from
    /// the open), else at the screen's right end.
    private func frame(on screen: NSScreen) -> NSRect {
        let depth = max(NSStatusBar.system.thickness, ScreenBarGeometry.notchDepth(of: screen))
        let widths = model.rowWidths(liveWidths: tiles.imageWidths)
        let anchor = hang.current(icon: anchorFrame())
        let anchorRect = anchor.rect.flatMap { frame in
            screen.frame.contains(NSPoint(x: frame.midX, y: frame.midY)) ? frame : nil
        }
        if let anchorRect, anchor.centred {
            return MenuBarBarLayout.frame(widths: widths, menuBarDepth: depth, on: screen.frame,
                                          anchorMidX: anchorRect.midX)
        }
        return MenuBarBarLayout.frame(widths: widths, menuBarDepth: depth, on: screen.frame,
                                      anchorMaxX: anchorRect?.maxX)
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
        hang.closed()
        // Seen: the change marks clear with the bar, and the keyboard's
        // filter with it.
        updatedIDs = []
        model.keys = nil
        onOpenChange(false)
    }

    isolated deinit {
        for monitor in dismissMonitors { NSEvent.removeMonitor(monitor) }
        panel?.orderOut(nil)
        notePanel?.orderOut(nil)
        noteExpiry?.cancel()
    }

    // MARK: A drop's note

    /// Stand `text` under the icon for `seconds` in the bar's own glass —
    /// the same panel at the same level, holding one line and nothing
    /// else. It takes no clicks and captures nothing; an open bar folds
    /// first, so there is only ever one surface under the icon.
    func showNote(_ text: String, for seconds: TimeInterval) {
        closeNote()
        if isOpen { close() }
        let anchor = noteAnchorFrame()
        let screen = anchor.flatMap { frame in
            NSScreen.screens.first { $0.frame.contains(NSPoint(x: frame.midX, y: frame.midY)) }
        } ?? NSScreen.screens.first
        guard let screen else { return }
        noteModel.note = text
        let glass = MenuBarBarPanel(model: noteModel, tiles: tiles, onTrigger: { _ in },
                                    onRevealItem: { _ in }, itemSection: { _ in .hidden },
                                    onMoveItem: { _, _ in })
        glass.ignoresMouseEvents = true
        let depth = max(NSStatusBar.system.thickness, ScreenBarGeometry.notchDepth(of: screen))
        glass.setFrame(MenuBarBarLayout.noteFrame(size: MenuBarBarLayout.noteSize(text), menuBarDepth: depth,
                                                  on: screen.frame, anchorMidX: anchor?.midX),
                       display: false)
        glass.orderFrontRegardless()
        notePanel = glass
        noteExpiry = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(max(0.5, seconds) * 1e9))
            guard !Task.isCancelled else { return }
            self?.closeNote()
        }
    }

    /// The note, gone.
    func closeNote() {
        noteExpiry?.cancel()
        noteExpiry = nil
        notePanel?.orderOut(nil)
        notePanel = nil
        noteModel.note = nil
    }

    // MARK: A tile dragged out

    /// Start the bar's own drag session for a tile — the tile's face under
    /// the pointer, nothing posted. Where it ends is `onDragOut`'s to
    /// judge; the bar never moves anything itself.
    func beginTileDrag(_ item: MenuBarItem, image: NSImage?) {
        guard dragSource == nil, let view = panel?.contentView,
              let event = NSApp.currentEvent, event.type == .leftMouseDragged else { return }
        let source = MenuBarTileDragSource { [weak self] point in
            self?.dragSource = nil
            self?.onDragOut(item, point)
        }
        let pasteboardItem = NSPasteboardItem()
        pasteboardItem.setString(item.id, forType: MenuBarTileDragSource.pasteboardType)
        let dragging = NSDraggingItem(pasteboardWriter: pasteboardItem)
        let local = view.convert(event.locationInWindow, from: nil)
        let side: CGFloat = 22
        dragging.setDraggingFrame(NSRect(x: local.x - side / 2, y: local.y - side / 2, width: side, height: side),
                                  contents: image ?? NSImage(systemSymbolName: "app.dashed",
                                                             accessibilityDescription: nil))
        dragSource = source
        let session = view.beginDraggingSession(with: [dragging], event: event, source: source)
        session.animatesToStartingPositionsOnCancelOrFail = false
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
                let keyboard = self.model.keys != nil
                guard MenuBarBarKeys.claims(keyCode: event.keyCode, keyboard: keyboard,
                                            inBar: event.window === self.panel) else { return event }
                guard keyboard else {
                    self.close()
                    return nil
                }
                if let key = MenuBarBarKeys.key(keyCode: event.keyCode,
                                                characters: event.charactersIgnoringModifiers,
                                                modifiers: event.modifierFlags) {
                    self.press(key)
                }
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

/// An item's owner as a face when nothing better stands: the running
/// app's icon, else the icon its bundle has on disk (an app mid-relaunch,
/// a helper whose process name moved on), else its initial on a quiet
/// tile — never a question mark. Disk lookups are remembered per bundle.
struct MenuBarAppFace: View {
    let item: MenuBarItem
    var size: CGFloat = 20

    var body: some View {
        if let icon = MenuBarAppIcons.icon(for: item) {
            Image(nsImage: icon)
                .resizable()
                .interpolation(.high)
                .aspectRatio(contentMode: .fit)
                .frame(width: size, height: size)
        } else {
            Text(String(item.ownerName.prefix(1)).uppercased())
                .font(.system(size: size * 0.5, weight: .semibold, design: .rounded))
                .foregroundStyle(.secondary)
                .frame(width: size, height: size)
                .background(RoundedRectangle(cornerRadius: size * 0.26, style: .continuous)
                    .fill(Color.primary.opacity(0.1)))
        }
    }
}

/// The owner icons `MenuBarAppFace` resolves from disk, by bundle — a
/// LaunchServices lookup once per app, not once per redraw.
@MainActor
enum MenuBarAppIcons {
    private static var cache: [String: NSImage?] = [:]
    /// `item.owner` is itself a LaunchServices lookup (~26 µs a read), so
    /// a running app's icon is remembered per (pid, name) too — the name
    /// rides along so a reused pid can never serve the dead app's icon.
    private static var pidCache: [String: NSImage?] = [:]

    static func icon(for item: MenuBarItem) -> NSImage? {
        let pidKey = "\(item.ownerPID)|\(item.ownerName)"
        if let known = pidCache[pidKey] { return known }
        if let running = item.owner?.icon {
            pidCache[pidKey] = running
            return running
        }
        guard let bundleID = item.bundleID else { return nil }
        if let known = cache[bundleID] { return known }
        let icon = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID)
            .map { NSWorkspace.shared.icon(forFile: $0.path) }
        cache[bundleID] = icon
        return icon
    }
}

/// The Item Bar's tile drag: an in-app session, so the drop's screen
/// point is the bar's to read — nothing is posted, nothing else accepts
/// it, and it ends where the person lets go.
@MainActor
final class MenuBarTileDragSource: NSObject, NSDraggingSource {
    /// The pasteboard type a tile carries — its item id, JR-Bar's own.
    static let pasteboardType = NSPasteboard.PasteboardType("com.jonathanreed.jrbar.menubar-tile")

    private let onEnded: @MainActor (NSPoint) -> Void

    init(onEnded: @escaping @MainActor (NSPoint) -> Void) {
        self.onEnded = onEnded
    }

    nonisolated func draggingSession(_ session: NSDraggingSession,
                                     sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation {
        .move
    }

    nonisolated func draggingSession(_ session: NSDraggingSession, endedAt screenPoint: NSPoint,
                                     operation: NSDragOperation) {
        MainActor.assumeIsolated { onEnded(screenPoint) }
    }
}

/// A drop's note in the Item Bar's glass: a mark and one line.
struct MenuBarDropNoteRow: View {
    let text: String

    var body: some View {
        HStack(spacing: 7) {
            Image(systemName: "info.circle")
                .font(.system(size: 11.5, weight: .semibold))
                .foregroundStyle(.secondary)
            Text(text)
                .font(.system(size: 12, weight: .medium))
                .lineLimit(1)
                .truncationMode(.tail)
        }
        .padding(.horizontal, 4)
        .frame(maxWidth: .infinity)
        .frame(height: MenuBarBarLayout.noteHeight)
        .accessibilityElement(children: .combine)
    }
}
