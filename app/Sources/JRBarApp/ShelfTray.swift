import AppKit
import Darwin
import JRBarCore
import os
import Quartz
import QuickLookThumbnailing
import UniformTypeIdentifiers

/// W12's file tray: a bounded strip of file references on the pinned
/// card. Entries are paths, not copies — nothing here duplicates or
/// deletes user files. Revalidation happens at read and at show (T49):
/// a moved or deleted file renders as missing, never silently dropped
/// and never still claimed as usable.
@MainActor
@Observable
final class ShelfTrayModel {
    /// The tray is a glance surface, not a filesystem — past this many
    /// FILES the oldest references drop off. The bound counts items,
    /// not chips — a stack of eight costs eight.
    static let maxItems = 40
    /// Largest file "Attach" will offer to a draft without a confirm —
    /// anything bigger stays a path reference only.
    static let attachCopyBound: Int64 = 8 * 1024 * 1024

    private static let defaultsKey = "jrbar.shelfTray.paths"
    private static let pasteFailureNotice = "Couldn't save this copy. Try Paste again."

    /// One file in the tray — the unit stacks are made of.
    struct Entry: Identifiable, Equatable {
        let path: String
        /// Recomputed on every load/show — a file that moved or was
        /// deleted is `missing`, not removed (the user decides).
        var missing: Bool
        var id: String { path }
        var url: URL { URL(fileURLWithPath: path) }
        var name: String { url.lastPathComponent }
        /// The containing folder — the stack-grouping key.
        var folder: String { url.deletingLastPathComponent().path }
    }

    /// A chip in the strip: one loose file, or a stack — a group of
    /// items dropped together or gathered from the same folder,
    /// fanned into a single tile until it's split.
    enum ShelfEntry: Identifiable, Equatable {
        case item(Entry)
        case stack(Stack)

        struct Stack: Identifiable, Equatable {
            /// Stable identity — persisted, so a reload restores the
            /// same stack rather than inventing one.
            var id: String
            var name: String
            var items: [Entry]
            /// The folder the stack was born from, kept while every
            /// member still lives there — the same-folder merge key.
            var folder: String?

            /// A stack's own name: the shared folder's name when the
            /// items all sit together ("Screenshots"), else a count.
            static func name(for items: [Entry]) -> String {
                let folders = Set(items.map(\.folder))
                if folders.count == 1, let folder = folders.first {
                    let name = URL(fileURLWithPath: folder).lastPathComponent
                    if !name.isEmpty { return name }
                }
                return "\(items.count) items"
            }

            /// The folder every member shares, or nil once the stack
            /// mixes locations — drives the same-folder merge rule.
            static func commonFolder(of items: [Entry]) -> String? {
                let folders = Set(items.map(\.folder))
                return folders.count == 1 ? folders.first : nil
            }
        }

        var id: String {
            switch self {
            case .item(let entry): return entry.id
            case .stack(let stack): return stack.id
            }
        }

        /// The files this chip answers for — one for a loose item, the
        /// stack's whole contents for a stack.
        var items: [Entry] {
            switch self {
            case .item(let entry): return [entry]
            case .stack(let stack): return stack.items
            }
        }

        /// What the chip's label reads.
        var displayName: String {
            switch self {
            case .item(let entry): return entry.name
            case .stack(let stack): return stack.name
            }
        }

        /// A chip is missing only when it holds nothing that resolves.
        var missing: Bool { items.allSatisfy(\.missing) }
    }

    private(set) var entries: [ShelfEntry] = []

    // MARK: Session homes

    /// A live local session's working folder — files under it belong
    /// with that session, not with whichever subfolder they sit in.
    struct SessionHome: Equatable {
        let id: String
        let label: String
        let root: String
    }

    /// The card's live local sessions and where they work — fed with the
    /// card's rows. A session ending takes its name off its stack; the
    /// files stay where they are.
    var sessionHomes: [SessionHome] = []

    /// The session whose folder holds `path` — the deepest one when
    /// folders nest. A session working in the home folder or at the
    /// root would claim every file there, so those never count.
    nonisolated static func home(for path: String, in homes: [SessionHome],
                                 userHome: String = NSHomeDirectory()) -> SessionHome? {
        func trimmed(_ root: String) -> String {
            root.count > 1 && root.hasSuffix("/") ? String(root.dropLast()) : root
        }
        let broad: Set<String> = ["/", trimmed(userHome), ""]
        return homes
            .filter { !broad.contains(trimmed($0.root)) }
            .filter { path == trimmed($0.root) || path.hasPrefix(trimmed($0.root) + "/") }
            .max { trimmed($0.root).count < trimmed($1.root).count }
    }

    /// The one session every file in `items` belongs to, or nil.
    func commonHome(_ items: [Entry]) -> SessionHome? {
        guard let first = items.first,
              let home = Self.home(for: first.path, in: sessionHomes) else { return nil }
        return items.allSatisfy({ Self.home(for: $0.path, in: sessionHomes)?.id == home.id }) ? home : nil
    }

    /// What a stack's chip is called now: the session it belongs to
    /// while that session lives ("rename-the-fish"), its folder or
    /// count otherwise.
    func stackName(_ stack: ShelfEntry.Stack) -> String {
        commonHome(stack.items)?.label ?? stack.name
    }

    /// Every item across every chip — the verbs and the bound work on
    /// files, not tiles.
    var items: [Entry] { entries.flatMap(\.items) }

    // MARK: The notch's shelf settings

    /// Read through closures the notch wires once (`NotchToy`), so the
    /// glass card and the island's card — one tray between them — both
    /// follow the Notch card's rows. The defaults are today's shelf.
    @ObservationIgnored var newestFirst: @MainActor () -> Bool = { false }
    @ObservationIgnored var dragOutPolicy: @MainActor () -> ShelfDragOut = { .copy }
    @ObservationIgnored var removeAfterDragOut: @MainActor () -> Bool = { false }
    /// The shelf itself; off, the card's Shelf page shows no file strip
    /// and the tray takes no files.
    @ObservationIgnored var shelfEnabled: @MainActor () -> Bool = { true }

    private let defaults: UserDefaults
    private struct ClearedShelf {
        var entries: [ShelfEntry]
        var selectedIDs: Set<String>
        var selectionAnchor: String?
        var keyboardSelectionID: String?
    }
    private var clearedShelf: ClearedShelf?
    var canUndoClear: Bool { clearedShelf != nil }
    var clearedItemCount: Int { clearedShelf?.entries.flatMap(\.items).count ?? 0 }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        load()
    }

    /// Drop-in or explicit add: dedupes, bounds the strip, persists.
    /// `before` aims the landing at a chip — a drop on a chip lands
    /// where it dropped, Yoink-style, not at the tail. `onto` aims at
    /// a stack: a drop on a stack tile joins it.
    ///
    /// Stack formation: a drop carrying two or more NEW files becomes
    /// one stack (the same-drop rule); a single new file joins an
    /// existing stack sharing its folder, or stacks with an existing
    /// loose item from the same folder (the same-folder rule).
    /// Symlinks resolve at read time — a link whose target moved is
    /// `missing` on the next pass. With the shelf switched off nothing
    /// lands, whichever way the files came: the island, the Dock's Send
    /// to Shelf, a paste or an action's result.
    func add(_ urls: [URL], before target: ShelfEntry? = nil,
             onto stackTarget: ShelfEntry? = nil) {
        guard shelfEnabled() else { return }
        var known = entries
        let held = known.flatMap(\.items).map(\.path)
        let fresh = urls.map(\.path).reduce(into: [Entry]()) { out, path in
            if !held.contains(path), !out.contains(where: { $0.path == path }) {
                out.append(Entry(path: path, missing: false))
            }
        }
        guard !fresh.isEmpty else { return }
        clearedShelf = nil
        evictionNotice = nil
        let landed = Set(fresh.map(\.path))

        if let stackTarget,
           case .stack(let stack) = stackTarget,
           let at = known.firstIndex(where: { $0.id == stack.id }) {
            // A drop onto a stack adds to it — the folder key only
            // survives while the stack still lives in one place.
            var stack = stack
            stack.items.append(contentsOf: fresh)
            stack.folder = ShelfEntry.Stack.commonFolder(of: stack.items)
            stack.name = ShelfEntry.Stack.name(for: stack.items)
            known[at] = .stack(stack)
            finish(&known, landed: landed)
            return
        }

        if fresh.count >= 2 {
            // Dropped together: one stack, named for the folder the
            // files share or by their count.
            let stack = ShelfEntry.Stack(
                id: "stack-\(UUID().uuidString)",
                name: ShelfEntry.Stack.name(for: fresh),
                items: fresh,
                folder: ShelfEntry.Stack.commonFolder(of: fresh))
            let at = target.flatMap { t in known.firstIndex(where: { $0.id == t.id }) }
                ?? landingIndex(in: known)
            known.insert(.stack(stack), at: at)
            finish(&known, landed: landed)
            return
        }

        // A single new file: a live session's own files gather first —
        // join the stack that is all that session's, or stack up with a
        // loose file from its folder tree.
        let item = fresh[0]
        if let home = Self.home(for: item.path, in: sessionHomes) {
            if let at = known.firstIndex(where: {
                if case .stack(let stack) = $0 { return commonHome(stack.items)?.id == home.id }
                return false
            }), case .stack(var stack) = known[at] {
                stack.items.append(item)
                stack.folder = ShelfEntry.Stack.commonFolder(of: stack.items)
                stack.name = ShelfEntry.Stack.name(for: stack.items)
                known[at] = .stack(stack)
                finish(&known, landed: landed)
                return
            }
            if let at = known.firstIndex(where: {
                if case .item(let other) = $0 { return Self.home(for: other.path, in: sessionHomes)?.id == home.id }
                return false
            }), case .item(let other) = known[at] {
                let items = [other, item]
                known[at] = .stack(ShelfEntry.Stack(
                    id: "stack-\(UUID().uuidString)",
                    name: ShelfEntry.Stack.name(for: items),
                    items: items,
                    folder: ShelfEntry.Stack.commonFolder(of: items)))
                finish(&known, landed: landed)
                return
            }
        }
        // Then same-folder rules — join a stack living in its folder,
        // or stack up with a loose item from it.
        if let at = known.firstIndex(where: {
            if case .stack(let stack) = $0 {
                return stack.folder == item.folder
            }
            return false
        }), case .stack(var stack) = known[at] {
            stack.items.append(item)
            stack.folder = ShelfEntry.Stack.commonFolder(of: stack.items)
            stack.name = ShelfEntry.Stack.name(for: stack.items)
            known[at] = .stack(stack)
            finish(&known, landed: landed)
            return
        }
        if let at = known.firstIndex(where: {
            if case .item(let other) = $0 {
                return other.folder == item.folder
            }
            return false
        }), case .item(let other) = known[at] {
            let stack = ShelfEntry.Stack(
                id: "stack-\(UUID().uuidString)",
                name: ShelfEntry.Stack.name(for: [other, item]),
                items: [other, item],
                folder: item.folder)
            known[at] = .stack(stack)
            finish(&known, landed: landed)
            return
        }

        let at = target.flatMap { t in known.firstIndex(where: { $0.id == t.id }) }
            ?? landingIndex(in: known)
        known.insert(.item(item), at: at)
        finish(&known, landed: landed)
    }

    /// Where a new chip with no aimed drop lands: the end, or the front
    /// with "Newest first" (boring.notch's reverse order).
    private func landingIndex(in known: [ShelfEntry]) -> Int {
        newestFirst() ? 0 : known.count
    }

    /// Bound, revalidate, persist — the add paths' shared tail.
    /// `landed` is what this add just put on the shelf: eviction takes
    /// the oldest chips that hold none of it first, so a drop is never
    /// the thing that gets forgotten.
    private func finish(_ known: inout [ShelfEntry], landed: Set<String> = []) {
        let total = known.reduce(0) { $0 + $1.items.count }
        if total > Self.maxItems {
            // The strip is bounded: the oldest chips drop their
            // REFERENCES (the files themselves are never touched — the
            // tray only tracks paths). That must be said out loud: a
            // shelf that silently forgets reads as data loss.
            var over = total - Self.maxItems
            var names: [String] = []
            var droppedItems = 0
            // The oldest chips sit at the far end from where new ones land.
            let fromFront = !newestFirst()
            func isNew(_ chip: ShelfEntry) -> Bool { chip.items.contains { landed.contains($0.path) } }
            while over > 0 {
                let order = fromFront ? Array(known.indices) : Array(known.indices.reversed())
                guard let at = order.first(where: { !isNew(known[$0]) }) else { break }
                let oldest = known.remove(at: at)
                droppedItems += oldest.items.count
                names.append(oldest.displayName)
                over -= oldest.items.count
            }
            // Only the new files' own chips are left and they are still
            // too many (a drop of fifty into a stack): the stack gives up
            // its oldest members, not the whole chip.
            if over > 0 {
                for at in known.indices where over > 0 {
                    guard case .stack(var stack) = known[at] else { continue }
                    let give = min(over, stack.items.count - 1)
                    guard give > 0 else { continue }
                    stack.items.removeFirst(give)
                    stack.folder = ShelfEntry.Stack.commonFolder(of: stack.items)
                    stack.name = ShelfEntry.Stack.name(for: stack.items)
                    known[at] = .stack(stack)
                    droppedItems += give
                    names.append(stack.name)
                    over -= give
                }
            }
            if droppedItems > 0 {
                evictionNotice = droppedItems == 1
                    ? "Shelf full — \u{201C}\(names[0])\u{201D} dropped off (file untouched)"
                    : "Shelf full — \(droppedItems) oldest items dropped off (files untouched)"
            }
        }
        entries = known
        let paths = Set(known.flatMap(\.items).map(\.path))
        icons = icons.filter { paths.contains($0.key) }
        pendingThumbs = pendingThumbs.filter { paths.contains($0.key) }
        revalidate()
        persist()
    }

    /// Set when a bounded add pushed the oldest chips off — the strip
    /// shows the sentence so a quiet eviction never reads as data
    /// loss. Cleared by the next add/remove, or the row's fade.
    private(set) var evictionNotice: String?

    func clearEvictionNotice() { evictionNotice = nil }

    func remove(_ entry: ShelfEntry) {
        guard let current = entries.first(where: { $0.id == entry.id }) else { return }
        entries.removeAll { $0.id == entry.id }
        for item in current.items {
            icons.removeValue(forKey: item.path)
            pendingThumbs.removeValue(forKey: item.path)
        }
        remapSelection(from: [entry.id], to: [])
        evictionNotice = nil
        persist()
    }

    /// Clear Shelf: every reference goes; the files stay where they are.
    func removeAll() {
        guard !entries.isEmpty else { return }
        clearedShelf = ClearedShelf(entries: entries, selectedIDs: selectedIDs,
                                    selectionAnchor: selectionAnchor, keyboardSelectionID: keyboardSelectionID)
        entries.removeAll()
        icons.removeAll()
        pendingThumbs.removeAll()
        selectedIDs.removeAll()
        selectionAnchor = nil
        keyboardSelectionID = nil
        evictionNotice = nil
        persist()
    }

    /// Restore the last cleared references until another file lands.
    func undoClear() {
        guard shelfEnabled(), let snapshot = clearedShelf else { return }
        clearedShelf = nil
        entries = snapshot.entries
        selectedIDs = snapshot.selectedIDs
        selectionAnchor = snapshot.selectionAnchor
        keyboardSelectionID = snapshot.keyboardSelectionID
        revalidate()
        persist()
    }

    // MARK: Selection

    /// The chips picked with ⌘- and ⇧-click; a verb on one of them acts
    /// on them all.
    private(set) var selectedIDs: Set<String> = []
    private(set) var keyboardSelectionID: String?
    static let pasteKeyboardID = "shelf-paste-action"
    private var keyboardTileIDs: [String] {
        (pasteOffered ? [Self.pasteKeyboardID] : []) + entries.map(\.id)
    }
    /// Where a ⇧-click range starts: the last chip ⌘-clicked or ⇧-clicked.
    @ObservationIgnored private var selectionAnchor: String?
    @ObservationIgnored var openURL: @MainActor (URL) -> Bool = { NSWorkspace.shared.open($0) }

    private func remapSelection(from oldIDs: Set<String>, to newIDs: [String]) {
        let wasSelected = !selectedIDs.isDisjoint(with: oldIDs)
        selectedIDs.subtract(oldIDs)
        if wasSelected { selectedIDs.formUnion(newIDs) }
        if let cursor = keyboardSelectionID, oldIDs.contains(cursor) {
            keyboardSelectionID = newIDs.first
        }
        if let anchor = selectionAnchor, oldIDs.contains(anchor) {
            selectionAnchor = newIDs.first
        }
    }

    /// Keep the current pick, or start with the first chip in tray order.
    func beginKeyboardSelection() {
        revalidate()
        selectedIDs.formIntersection(Set(entries.map(\.id)))
        if pasteOffered, keyboardSelectionID == Self.pasteKeyboardID { return }
        guard let first = entries.first else {
            selectionAnchor = nil
            keyboardSelectionID = pasteOffered ? Self.pasteKeyboardID : nil
            return
        }
        if selectedIDs.isEmpty { selectedIDs = [first.id] }
        if let cursor = keyboardSelectionID, selectedIDs.contains(cursor) { return }
        keyboardSelectionID = selectionAnchor.flatMap { selectedIDs.contains($0) ? $0 : nil }
            ?? entries.first { selectedIDs.contains($0.id) }?.id
        selectionAnchor = keyboardSelectionID
    }

    func endKeyboardSelection() { keyboardSelectionID = nil }

    /// Arrows stop at the ends, matching Finder's selection behavior.
    func moveKeyboardSelection(by delta: Int) {
        beginKeyboardSelection()
        let ids = keyboardTileIDs
        guard !ids.isEmpty else { return }
        let current = keyboardSelectionID.flatMap { ids.firstIndex(of: $0) } ?? 0
        let offset = delta > 0 ? min(delta, ids.count - 1 - current) : max(delta, -current)
        selectKeyboardTile(ids[current + offset])
    }

    func moveKeyboardSelection(column: Int, row: Int) {
        beginKeyboardSelection()
        let ids = keyboardTileIDs
        guard let cursor = keyboardSelectionID, let current = ids.firstIndex(of: cursor) else { return }
        let rows = Self.stripRows(tiles: ids.count)
        let targetColumn = current / rows + column
        let targetRow = current % rows + row
        guard targetColumn >= 0, (0..<rows).contains(targetRow) else { return }
        let target = targetColumn * rows + targetRow
        guard ids.indices.contains(target) else { return }
        selectKeyboardTile(ids[target])
    }

    private func selectKeyboardTile(_ id: String) {
        keyboardSelectionID = id
        selectedIDs = id == Self.pasteKeyboardID ? [] : [id]
        selectionAnchor = id == Self.pasteKeyboardID ? nil : id
    }

    /// Open live files in the pick, including a selected stack's members.
    /// A missing file or refused opener says why instead of claiming success.
    func openKeyboardSelection() -> String? {
        guard shelfEnabled() else { return keyboardOpenRefusal("The Shelf is turned off.") }
        revalidate()
        selectedIDs.formIntersection(Set(entries.map(\.id)))
        if let cursor = keyboardSelectionID, !selectedIDs.contains(cursor) { keyboardSelectionID = nil }
        let picked = entries.filter { selectedIDs.contains($0.id) }
        guard !picked.isEmpty else {
            return keyboardOpenRefusal(entries.isEmpty ? "The Shelf has no files to open." : "No Shelf files are selected.")
        }
        let urls = presentURLs(of: picked)
        guard !urls.isEmpty else { return keyboardOpenRefusal("The selected files moved or were deleted.") }
        let missing = picked.flatMap(\.items).contains(where: \.missing)
        var failed = false
        for url in urls { if !openURL(url) { failed = true } }
        if missing {
            return keyboardOpenRefusal(failed
                ? "Some selected files moved, were deleted, or could not be opened."
                : "Some selected files moved or were deleted.")
        }
        if failed { return keyboardOpenRefusal("Some selected files could not be opened.") }
        actionNotice = nil
        return nil
    }

    private func keyboardOpenRefusal(_ words: String) -> String {
        actionNotice = words
        return words
    }

    /// ⌘-click: this chip joins or leaves the selection.
    func toggleSelection(_ entry: ShelfEntry) {
        if selectedIDs.contains(entry.id) {
            selectedIDs.remove(entry.id)
        } else {
            selectedIDs.insert(entry.id)
        }
        selectionAnchor = entry.id
    }

    /// ⇧-click: every chip from the anchor to this one, in strip order,
    /// joins the selection.
    func extendSelection(to entry: ShelfEntry) {
        guard let end = entries.firstIndex(where: { $0.id == entry.id }) else { return }
        let start = selectionAnchor.flatMap { anchor in entries.firstIndex { $0.id == anchor } } ?? end
        for index in min(start, end)...max(start, end) {
            selectedIDs.insert(entries[index].id)
        }
        selectionAnchor = entry.id
    }

    func clearSelection() {
        selectedIDs.removeAll()
        selectionAnchor = nil
        clearedShelf?.selectedIDs.removeAll()
        clearedShelf?.selectionAnchor = nil
        clearedShelf?.keyboardSelectionID = nil
    }

    /// What a verb on `entry` acts on: the whole selection when `entry`
    /// is part of one, else `entry` alone — in strip order.
    func targets(for entry: ShelfEntry) -> [ShelfEntry] {
        guard selectedIDs.contains(entry.id), selectedIDs.count > 1 else { return [entry] }
        return entries.filter { selectedIDs.contains($0.id) }
    }

    /// The files of `entries` that still resolve, each once — what a drag
    /// out, the share menu and every verb carry. A moved file is never
    /// offered, and a canceled share claims nothing (T50).
    func presentURLs(of entries: [ShelfEntry]) -> [URL] {
        revalidate()
        let ids = Set(entries.map(\.id))
        var seen = Set<String>()
        return self.entries.filter { ids.contains($0.id) }
            .flatMap(\.items)
            .filter { !$0.missing && seen.insert($0.path).inserted }
            .map(\.url)
    }

    // MARK: Verbs on a pick

    /// Remove from Tray on a picked chip: the whole pick leaves the
    /// shelf. The files stay where they are.
    func remove(_ picked: [ShelfEntry]) {
        for entry in picked { remove(entry) }
    }

    /// Reveal in Finder: the pick's files that still resolve, selected
    /// together in Finder. A moved file is never revealed.
    func reveal(_ picked: [ShelfEntry]) {
        let live = presentURLs(of: picked)
        guard !live.isEmpty else { return }
        NSWorkspace.shared.activateFileViewerSelecting(live)
    }

    /// The dedicated one-click path: straight to AirDrop, no picker —
    /// Alcove's headline shelf verb — with every file of the pick that
    /// still resolves. Returns whether the service ran.
    @discardableResult
    func sendViaAirDrop(_ picked: [ShelfEntry]) -> Bool {
        let urls = presentURLs(of: picked)
        guard !urls.isEmpty,
              let service = NSSharingService(named: .sendViaAirDrop) else { return false }
        service.perform(withItems: urls)
        return true
    }

    /// Quick Look from a chip. A chip in a pick previews the pick, opened
    /// on that chip; a lone chip previews the whole shelf, opened on it.
    func quickLook(_ entry: ShelfEntry, among picked: [ShelfEntry]) {
        guard picked.count > 1 else {
            quickLook(entry)
            return
        }
        let urls = presentURLs(of: picked)
        guard !urls.isEmpty else { return }
        let paths = Set(entry.items.map(\.path))
        ShelfQuickLook.shared.show(urls: urls, at: urls.firstIndex { paths.contains($0.path) } ?? 0)
    }

    /// Hand the pick to an agent: every present file's `@path` goes on
    /// the pasteboard as text beside the file URLs, and a single small
    /// image rides along as image data. Nothing is typed anywhere — the
    /// person pastes it into the session this opens. False when no file
    /// of the pick is present.
    @discardableResult
    func copyForAgent(_ picked: [ShelfEntry], to board: NSPasteboard = .general) -> Bool {
        let urls = presentURLs(of: picked)
        guard !urls.isEmpty else { return false }
        let attach = picked.count == 1 && canAttachCopy(picked[0])
        copyForAgent(urls, attachImage: attach, to: board)
        return true
    }

    // MARK: Drag out

    /// A drag out of the shelf ended. With "Remove after dragging out"
    /// on, a drop that landed outside JR-Bar takes the dragged chip off
    /// the shelf — only that chip, and never for a drag that was
    /// refused, cancelled or only rearranged the strip.
    func finishDragOut(_ entry: ShelfEntry, operation: NSDragOperation, outside: Bool) {
        guard ShelfDragOutRule.removes(operation: operation, outside: outside,
                                       removeAfter: removeAfterDragOut()),
              entries.contains(where: { $0.id == entry.id }) else { return }
        remove(entry)
    }

    @ObservationIgnored var latestCopyTextToken: UUID?

    /// A line under the strip for what a verb just did — "Copied the
    /// text of 2 files". It fades on its own like the eviction line.
    var actionNotice: String?

    /// A file the shelf itself moved (Move to…): its chip follows it,
    /// in a stack or loose, rather than turning up missing.
    func relocate(from old: String, to new: String) {
        guard old != new else { return }
        var isDirectory: ObjCBool = false
        let movedDirectory = FileManager.default.fileExists(atPath: new, isDirectory: &isDirectory)
            && isDirectory.boolValue
        let prefix = old == "/" ? old : old + "/"
        func relocatedEntries(_ source: [ShelfEntry])
            -> (entries: [ShelfEntry], owners: [String: [String]], invalidated: Set<String>) {
            var invalidated = Set<String>()
            var existingOwners: [String: Int] = [:]
            for (index, entry) in source.enumerated() {
                for item in entry.items where item.path != old
                    && !(movedDirectory && item.path.hasPrefix(prefix)) {
                    if existingOwners[item.path] == nil { existingOwners[item.path] = index }
                }
            }
            func relocated(_ item: Entry) -> Entry {
                let path: String
                if item.path == old {
                    path = new
                } else if movedDirectory && item.path.hasPrefix(prefix) {
                    path = URL(fileURLWithPath: new)
                        .appendingPathComponent(String(item.path.dropFirst(prefix.count))).path
                } else {
                    return Entry(path: item.path, missing: !FileManager.default.fileExists(atPath: item.path))
                }
                invalidated.insert(item.path)
                invalidated.insert(path)
                return Entry(path: path, missing: !FileManager.default.fileExists(atPath: path))
            }
            let mapped = source.map { entry in
                switch entry {
                case .item(let item):
                    return ShelfEntry.item(relocated(item))
                case .stack(var stack):
                    stack.items = stack.items.map(relocated)
                    stack.folder = ShelfEntry.Stack.commonFolder(of: stack.items)
                    return ShelfEntry.stack(stack)
                }
            }
            let normalized = Self.uniqueEntries(mapped, preferredOwners: existingOwners)
            var pathOwners: [String: String] = [:]
            for entry in normalized {
                for item in entry.items { pathOwners[item.path] = entry.id }
            }
            var owners: [String: [String]] = [:]
            for (original, mappedEntry) in zip(source, mapped) {
                var ids: [String] = []
                for item in mappedEntry.items {
                    if let owner = pathOwners[item.path], !ids.contains(owner) { ids.append(owner) }
                }
                owners[original.id] = ids
            }
            return (normalized, owners, invalidated)
        }
        func remapped(_ ids: Set<String>, owners: [String: [String]]) -> Set<String> {
            Set(ids.flatMap { owners[$0] ?? [$0] })
        }
        let active = relocatedEntries(entries)
        entries = active.entries
        selectedIDs = remapped(selectedIDs, owners: active.owners)
        keyboardSelectionID = keyboardSelectionID.flatMap { active.owners[$0]?.first ?? $0 }
        selectionAnchor = selectionAnchor.flatMap { active.owners[$0]?.first ?? $0 }
        for path in active.invalidated {
            icons.removeValue(forKey: path)
            pendingThumbs.removeValue(forKey: path)
        }
        if var snapshot = clearedShelf {
            let restored = relocatedEntries(snapshot.entries)
            snapshot.entries = restored.entries
            for path in restored.invalidated {
                icons.removeValue(forKey: path)
                pendingThumbs.removeValue(forKey: path)
            }
            snapshot.selectedIDs = remapped(snapshot.selectedIDs, owners: restored.owners)
            snapshot.selectionAnchor = snapshot.selectionAnchor.flatMap { restored.owners[$0]?.first ?? $0 }
            snapshot.keyboardSelectionID = snapshot.keyboardSelectionID.flatMap { restored.owners[$0]?.first ?? $0 }
            clearedShelf = snapshot
        }
        persist()
    }

    /// The chip's face: the file's own icon from the workspace — a
    /// screenshot in Finder livery, not a generic `doc`. Previewable
    /// files then upgrade to a real thumbnail when Quick Look answers
    /// off-actor; the generic face shows until it lands.
    private var icons: [String: NSImage] = [:]
    private var pendingThumbs: [String: UUID] = [:]
    @ObservationIgnored var loadThumbnail: @MainActor (
        String, @escaping @MainActor @Sendable (NSImage?) -> Void
    ) -> Void = { path, completion in
        let request = QLThumbnailGenerator.Request(
            fileAt: URL(fileURLWithPath: path), size: CGSize(width: 32, height: 32),
            scale: NSScreen.main?.backingScaleFactor ?? 2, representationTypes: .thumbnail)
        QLThumbnailGenerator.shared.generateBestRepresentation(for: request) { representation, _ in
            let image = representation?.nsImage
            Task { @MainActor in completion(image) }
        }
    }

    func icon(for entry: Entry) -> NSImage {
        if let cached = icons[entry.path] { return cached }
        // `icon(forFile:)` hands back a shared cached NSImage for
        // generic types — resize a copy so every other consumer in
        // the process keeps the size it asked for.
        let image = (NSWorkspace.shared.icon(forFile: entry.path).copy()
                     as? NSImage) ?? NSImage()
        image.size = NSSize(width: 11, height: 11)
        icons[entry.path] = image
        if !entry.missing { upgradeThumbnail(for: entry.path) }
        return image
    }

    /// The async half of `icon(for:)`: one Quick Look ask per path,
    /// kept out of the render path. A file that yields no thumbnail
    /// (folders, binaries) simply keeps its type icon — nothing
    /// reverts, nothing retries in a loop.
    private func upgradeThumbnail(for path: String) {
        guard pendingThumbs[path] == nil else { return }
        let token = UUID()
        pendingThumbs[path] = token
        loadThumbnail(path) { [weak self] image in
            guard let self, self.pendingThumbs[path] == token else { return }
            self.pendingThumbs.removeValue(forKey: path)
            guard let image else { return }
            image.size = NSSize(width: 11, height: 11)
            self.icons[path] = image
        }
    }

    /// A tray-internal drag: `moved` lands ahead of `target`. The
    /// strip's order is the user's arrangement — it persists like
    /// the entries do. Chips move whole — a stack's internal order is
    /// its own.
    func move(_ moved: ShelfEntry, before target: ShelfEntry) {
        guard moved.id != target.id,
              let from = entries.firstIndex(where: { $0.id == moved.id }),
              var to = entries.firstIndex(where: { $0.id == target.id })
        else { return }
        let item = entries.remove(at: from)
        if from < to { to -= 1 }
        entries.insert(item, at: to)
        persist()
    }

    /// A stack taken apart — the ⌥-click / Split verb. Members land
    /// as loose chips where the stack stood.
    func dissolve(_ entry: ShelfEntry) {
        guard let at = entries.firstIndex(where: { $0.id == entry.id }),
              case .stack(let stack) = entries[at]
        else { return }
        entries.replaceSubrange(at...at, with: stack.items.map { .item($0) })
        remapSelection(from: [entry.id], to: stack.items.map(\.id))
        persist()
    }

    /// The chip merges with the one after it — the Merge verb. The
    /// pair keeps the folder key only if they truly sit together.
    func mergeWithNext(_ entry: ShelfEntry) {
        guard let at = entries.firstIndex(where: { $0.id == entry.id }),
              at + 1 < entries.count else { return }
        let oldIDs = Set([entries[at].id, entries[at + 1].id])
        let members = entries[at].items + entries[at + 1].items
        guard members.count >= 2 else { return }
        let stack = ShelfEntry.Stack(
            id: "stack-\(UUID().uuidString)",
            name: ShelfEntry.Stack.name(for: members),
            items: members,
            folder: ShelfEntry.Stack.commonFolder(of: members))
        entries.replaceSubrange(at...(at + 1), with: [.stack(stack)])
        remapSelection(from: oldIDs, to: [stack.id])
        persist()
    }

    /// One file out of a stack — the popover's remove. A stack
    /// thinned to one member dissolves into that loose chip.
    func removeItem(_ item: Entry, from stackID: String) {
        guard let at = entries.firstIndex(where: { $0.id == stackID }),
              case .stack(var stack) = entries[at],
              stack.items.contains(where: { $0.id == item.id }) else { return }
        stack.items.removeAll { $0.id == item.id }
        icons.removeValue(forKey: item.path)
        pendingThumbs.removeValue(forKey: item.path)
        if stack.items.isEmpty {
            entries.remove(at: at)
            remapSelection(from: [stackID], to: [])
        } else if stack.items.count == 1 {
            entries[at] = .item(stack.items[0])
            remapSelection(from: [stackID], to: [stack.items[0].id])
        } else {
            stack.folder = ShelfEntry.Stack.commonFolder(of: stack.items)
            stack.name = ShelfEntry.Stack.name(for: stack.items)
            entries[at] = .stack(stack)
        }
        persist()
    }

    /// Reveal in Finder — only for entries that still resolve. A
    /// stack reveals its live members.
    func reveal(_ entry: ShelfEntry) {
        reveal([entry])
    }

    /// File size for the attach bound — nil when unresolvable.
    func size(of entry: Entry) -> Int64? {
        guard let values = try? entry.url.resourceValues(forKeys: [.fileSizeKey]),
              let size = values.fileSize else { return nil }
        return Int64(size)
    }

    /// Whether a hand-off may carry this file's bytes as well as its
    /// path (bounded copies) — a single image under the bound also goes
    /// on the pasteboard as image data, which agents like Claude Code
    /// take with their own image paste. A stack never attaches as a
    /// copy — the agent takes the paths.
    func canAttachCopy(_ entry: ShelfEntry) -> Bool {
        guard case .item(let item) = entry,
              let size = size(of: item) else { return false }
        return size <= Self.attachCopyBound
    }

    /// The agent's file-mention form of the entry's present files —
    /// `@/abs/path`, spaces escaped, one per file — the text an agent
    /// CLI reads as "look at this file". Missing files are left out.
    static func agentReferences(_ paths: [String]) -> String {
        paths.map { path in
            "@" + path.replacingOccurrences(of: "\\", with: "\\\\")
                .replacingOccurrences(of: " ", with: "\\ ")
        }.joined(separator: " ")
    }

    /// The hand-off for files, shared with a file dropped straight onto
    /// a session row. What JR-Bar just wrote is its own, not a copy to
    /// offer back as the Paste chip on the next open — its change count
    /// counts as pasted.
    func copyForAgent(_ urls: [URL], attachImage: Bool, to board: NSPasteboard = .general) {
        guard let written = Self.copyForAgent(urls, attachImage: attachImage, to: board) else { return }
        pastedChangeCount = written
        pasteOffered = false
    }

    /// The pasteboard write: the `@path` text first, a small single
    /// image as image data beside it, then the file URLs for a GUI app.
    /// The board's change count after the write; nil when nothing was.
    static func copyForAgent(_ urls: [URL], attachImage: Bool, to board: NSPasteboard) -> Int? {
        guard !urls.isEmpty else { return nil }
        board.clearContents()
        var objects: [NSPasteboardWriting] = [agentReferences(urls.map(\.path)) as NSString]
        if attachImage, urls.count == 1, let url = urls.first,
           let type = UTType(filenameExtension: url.pathExtension), type.conforms(to: .image),
           let image = NSImage(contentsOf: url) {
            objects.append(image)
        }
        board.writeObjects(objects)
        board.writeObjects(urls.map { $0 as NSURL })
        return board.changeCount
    }

    /// Whether a dropped file is small enough to ride along as bytes.
    static func withinAttachBound(_ url: URL) -> Bool {
        guard let size = (try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize else { return false }
        return Int64(size) <= attachCopyBound
    }

    /// Mark missing entries by re-reading the filesystem — the same
    /// check the read path makes, so the strip and reads never disagree.
    /// Rows the shelf page's strip lays its tiles in: one while a row
    /// holds them all, two once the shelf fills, scrolling sideways.
    nonisolated static func stripRows(tiles: Int) -> Int { tiles > 4 ? 2 : 1 }

    // MARK: Paste

    /// Something copied the shelf could take, not yet pasted here — the
    /// strip offers a Paste chip. Read off the pasteboard's types and
    /// change count only; its contents are read on the click.
    private(set) var pasteOffered = false {
        didSet {
            if !pasteOffered, keyboardSelectionID == Self.pasteKeyboardID {
                keyboardSelectionID = nil
            }
        }
    }
    /// The pasteboard generation last pasted — or written by a hand-off
    /// to an agent — so the same copy is not offered twice.
    private(set) var pastedChangeCount: Int?

    /// Look at the pasteboard as the card opens — types only.
    func notePasteboard(_ pasteboard: NSPasteboard = .general) {
        pasteOffered = pasteboard.changeCount != pastedChangeCount
            && ShelfTrayDrop.hasShelfable(pasteboard.types ?? [])
    }

    /// The Paste chip: what was copied lands on the shelf the way a drop
    /// does — files as themselves, links as `.webloc`s, text as a clip.
    func paste(from pasteboard: NSPasteboard = .general, directory: URL? = nil,
               reader: (NSPasteboard, URL?) -> ShelfTrayDrop.PasteResult = ShelfTrayDrop.pasteResult) {
        guard shelfEnabled() else { return }
        let copiedGeneration = pasteboard.changeCount
        let keyboardPaste = keyboardSelectionID == Self.pasteKeyboardID
        switch reader(pasteboard, directory) {
        case .files(let urls): add(urls)
        case .empty: break
        case .failed:
            actionNotice = Self.pasteFailureNotice
            notePasteboard(pasteboard)
            return
        }
        pastedChangeCount = copiedGeneration
        notePasteboard(pasteboard)
        if actionNotice == Self.pasteFailureNotice { actionNotice = nil }
        if keyboardPaste {
            keyboardSelectionID = nil
            beginKeyboardSelection()
        }
    }

    func revalidate() {
        entries = entries.map { entry in
            switch entry {
            case .item(var item):
                item.missing = !FileManager.default.fileExists(atPath: item.path)
                return .item(item)
            case .stack(var stack):
                stack.items = stack.items.map {
                    var item = $0
                    item.missing = !FileManager.default.fileExists(atPath: item.path)
                    return item
                }
                return .stack(stack)
            }
        }
    }

    /// The chip's Quick Look — the system preview panel over the
    /// tray's still-resolving entries, opened on this one's first
    /// live member.
    func quickLook(_ entry: ShelfEntry) {
        revalidate()
        let live = entries.flatMap(\.items).filter { !$0.missing }
        guard let index = live.firstIndex(where: {
            entry.items.contains($0)
        }) else { return }
        ShelfQuickLook.shared.show(urls: live.map(\.url), at: index)
    }

    /// Keep each path with its existing owner during a move, or its first
    /// stored owner on load. Only references change, never the files.
    private static func uniqueEntries(_ source: [ShelfEntry],
                                      preferredOwners: [String: Int] = [:]) -> [ShelfEntry] {
        var owners = preferredOwners
        for (index, entry) in source.enumerated() {
            for item in entry.items where owners[item.path] == nil { owners[item.path] = index }
        }
        var seen = Set<String>()
        return source.enumerated().compactMap { index, entry in
            let items = entry.items.filter { owners[$0.path] == index && seen.insert($0.path).inserted }
            guard let first = items.first else { return nil }
            if items.count == 1 { return .item(first) }
            guard case .stack(var stack) = entry else { return .item(first) }
            stack.items = items
            stack.folder = ShelfEntry.Stack.commonFolder(of: items)
            return .stack(stack)
        }
    }

    private func load() {
        // Two stores share the key's history: the flat [String] the
        // tray wrote before stacks, and the plist-dict list it writes
        // now. Anything unrecognized decodes to nothing — the shelf
        // never refuses to open over one bad record.
        if let stored = defaults.array(
            forKey: Self.defaultsKey) as? [[String: Any]] {
            entries = stored.compactMap(Self.entry(from:))
        } else {
            let paths = defaults.stringArray(
                forKey: Self.defaultsKey) ?? []
            entries = paths.map { .item(Entry(path: $0, missing: false)) }
        }
        let decoded = entries
        entries = Self.uniqueEntries(decoded)
        let repaired = entries != decoded
        var total = 0
        entries = entries.reversed().filter { entry in
            total += entry.items.count
            return total <= Self.maxItems
        }.reversed()
        revalidate()
        if repaired { persist() }
    }

    /// One persisted record → an entry, tolerantly. A stack with no
    /// usable paths is no record at all; a stack left holding one
    /// path decodes as the loose item it now is.
    private static func entry(from record: [String: Any]) -> ShelfEntry? {
        if let path = record["path"] as? String {
            return .item(Entry(path: path, missing: false))
        }
        let paths = (record["paths"] as? [String]) ?? []
        let items = paths.map { Entry(path: $0, missing: false) }
        guard !items.isEmpty else { return nil }
        if items.count == 1 { return .item(items[0]) }
        var stack = ShelfEntry.Stack(
            id: (record["id"] as? String) ?? "stack-\(UUID().uuidString)",
            name: (record["name"] as? String)
                ?? ShelfEntry.Stack.name(for: items),
            items: items,
            folder: ShelfEntry.Stack.commonFolder(of: items))
        if stack.name.isEmpty {
            stack.name = ShelfEntry.Stack.name(for: items)
        }
        return .stack(stack)
    }

    private func persist() {
        let stored: [[String: Any]] = entries.map { entry in
            switch entry {
            case .item(let item):
                return ["path": item.path]
            case .stack(let stack):
                return ["id": stack.id,
                        "name": stack.name,
                        "paths": stack.items.map(\.path)]
            }
        }
        defaults.set(stored, forKey: Self.defaultsKey)
    }
}

/// Resolves dropped files, web links and text clips in provider order.
struct ShelfTrayDrop {
    enum PasteResult: Equatable {
        case files([URL])
        case empty
        case failed
    }

    static func urls(from providers: [NSItemProvider], directory: URL? = nil,
                     completion: @escaping @MainActor ([URL]) -> Void) {
        let urls = OSAllocatedUnfairLock<[URL?]>(
            initialState: Array(repeating: nil, count: providers.count))
        let group = DispatchGroup()
        for (index, provider) in providers.enumerated() {
            if provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) {
                group.enter()
                provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { item, _ in
                    defer { group.leave() }
                    let url = (item as? URL)
                        ?? (item as? Data).flatMap { URL(dataRepresentation: $0, relativeTo: nil) }
                    if let url {
                        urls.withLock { $0[index] = url }
                    }
                }
            } else if provider.hasItemConformingToTypeIdentifier(UTType.url.identifier) {
                group.enter()
                provider.loadItem(forTypeIdentifier: UTType.url.identifier, options: nil) { item, _ in
                    defer { group.leave() }
                    let url = (item as? URL)
                        ?? (item as? Data).flatMap { URL(dataRepresentation: $0, relativeTo: nil) }
                    if let url, let loc = webLoc(for: url, directory: directory) {
                        urls.withLock { $0[index] = loc }
                    }
                }
            } else if provider.hasItemConformingToTypeIdentifier(UTType.plainText.identifier) {
                // A text clipping — Yoink's third drop kind: the string
                // materializes as a real `.txt` so every verb answers it.
                group.enter()
                provider.loadItem(forTypeIdentifier: UTType.plainText.identifier, options: nil) { item, _ in
                    defer { group.leave() }
                    let text = (item as? String)
                        ?? (item as? Data).flatMap { String(data: $0, encoding: .utf8) }
                    if let text, let loc = textLoc(for: text, directory: directory) {
                        urls.withLock { $0[index] = loc }
                    }
                }
            }
        }
        group.notify(queue: .main) {
            MainActor.assumeIsolated { completion(urls.withLock { $0.compactMap { $0 } }) }
        }
    }

    /// Whether a pasteboard holding `types` has anything for the shelf:
    /// files, a link, or text.
    static func hasShelfable(_ types: [NSPasteboard.PasteboardType]) -> Bool {
        types.contains(.fileURL) || types.contains(.URL) || types.contains(.string)
    }

    /// A pasteboard's shelf-able contents as tray-ready file URLs:
    /// copied files first, else links (as `.webloc`s), else text (as a
    /// `.txt` clip). Read only when the person asks for the paste.
    static func pasteResult(_ pasteboard: NSPasteboard, directory: URL? = nil) -> PasteResult {
        let fileOnly: [NSPasteboard.ReadingOptionKey: Any] = [.urlReadingFileURLsOnly: true]
        if let files = pasteboard.readObjects(forClasses: [NSURL.self], options: fileOnly) as? [URL],
           !files.isEmpty {
            return .files(files)
        }
        if pasteboard.types?.contains(.URL) == true,
           let links = pasteboard.readObjects(forClasses: [NSURL.self]) as? [URL], !links.isEmpty {
            var files: [URL] = []
            for link in links {
                if link.isFileURL {
                    files.append(link)
                } else if link.scheme?.hasPrefix("http") == true {
                    guard let loc = webLoc(for: link, directory: directory) else { return .failed }
                    files.append(loc)
                }
            }
            return files.isEmpty ? .empty : .files(files)
        }
        if let text = pasteboard.string(forType: .string) {
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return .empty }
            if let link = URL(string: trimmed), link.scheme?.hasPrefix("http") == true {
                return webLoc(for: link, directory: directory).map { .files([$0]) } ?? .failed
            }
            return textLoc(for: text, directory: directory).map { .files([$0]) } ?? .failed
        }
        return .empty
    }

    /// Pasteboard-read URLs → tray-ready file URLs: files pass
    /// through, web links become `.webloc`s (the island's drop path,
    /// where the pasteboard is already open).
    static func trayURLs(from urls: [URL], directory: URL? = nil) -> [URL] {
        urls.compactMap { $0.isFileURL ? $0 : webLoc(for: $0, directory: directory) }
    }

    /// Reuses a matching link file and preserves occupied or edited files.
    static func webLoc(for url: URL, directory: URL? = nil) -> URL? {
        guard url.scheme?.hasPrefix("http") == true,
              let dir = directory ?? clipDirectory() else { return nil }
        let hash = stableHash(url.absoluteString)
        let host = (url.host ?? "Link")
            .replacingOccurrences(of: "/", with: "-")
            .replacingOccurrences(of: ":", with: "-")
        guard let data = try? PropertyListSerialization.data(
            fromPropertyList: ["URL": url.absoluteString], format: .xml, options: 0) else { return nil }
        return materialize(data, in: dir, base: "\(host)-\(hash)", ext: "webloc",
                           maximumMatchBytes: max(data.count, 65_536)) { existing in
            let plist = try? PropertyListSerialization.propertyList(from: existing, options: [], format: nil)
            return (plist as? [String: Any])?["URL"] as? String == url.absoluteString
        }
    }

    /// Reuses an exact text clip, taking a numbered name after a collision.
    static func textLoc(for text: String, directory: URL? = nil) -> URL? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              let dir = directory ?? clipDirectory() else { return nil }
        let hash = stableHash(text)
        let head = String(trimmed.components(separatedBy: .newlines).first?.prefix(24) ?? "Clip")
        let safe = head.components(separatedBy: CharacterSet.alphanumerics.inverted)
            .joined()
        let data = Data(text.utf8)
        return materialize(data, in: dir, base: "\(safe.isEmpty ? "Clip" : safe)-\(hash)", ext: "txt",
                           maximumMatchBytes: data.count) { $0 == data }
    }

    private static func materialize(_ data: Data, in directory: URL, base: String, ext: String,
                                    maximumMatchBytes: Int, matches: (Data) -> Bool) -> URL? {
        let manager = FileManager.default
        do {
            try manager.createDirectory(at: directory, withIntermediateDirectories: true)
            let occupied = Set(try manager.contentsOfDirectory(atPath: directory.path))
            let candidates = (1...500).map {
                directory.appendingPathComponent(ShelfActions.candidate(base, ext: ext, attempt: $0))
            }
            for candidate in candidates where occupied.contains(candidate.lastPathComponent) {
                if let existing = regularClipData(at: candidate, maximumBytes: maximumMatchBytes),
                   matches(existing) { return candidate }
            }

            let staging = directory.appendingPathComponent(".jrbar-clip-\(UUID().uuidString)")
            let descriptor = open(staging.path, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC,
                                  mode_t(S_IRUSR | S_IWUSR))
            guard descriptor >= 0 else { return nil }
            let writer = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
            defer {
                try? writer.close()
                try? manager.removeItem(at: staging)
            }
            try writer.write(contentsOf: data)
            try writer.close()
            for candidate in candidates where !occupied.contains(candidate.lastPathComponent) {
                do {
                    // A hard link publishes the complete file and cannot replace a racing writer.
                    try manager.linkItem(at: staging, to: candidate)
                    return candidate
                } catch CocoaError.fileWriteFileExists {
                    if let existing = regularClipData(at: candidate, maximumBytes: maximumMatchBytes),
                       matches(existing) { return candidate }
                }
            }
        } catch {
            return nil
        }
        return nil
    }

    private static func regularClipData(at url: URL, maximumBytes: Int) -> Data? {
        let descriptor = open(url.path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        guard descriptor >= 0 else { return nil }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        defer { try? handle.close() }
        var info = stat()
        guard fstat(descriptor, &info) == 0, info.st_mode & S_IFMT == S_IFREG,
              info.st_size >= 0, info.st_size <= maximumBytes,
              let data = try? handle.read(upToCount: maximumBytes + 1),
              data.count <= maximumBytes else { return nil }
        return data
    }

    private static func clipDirectory() -> URL? {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first?
            .appendingPathComponent("JR-Bar/Shelf", isDirectory: true)
    }

    /// FNV-1a over the string's UTF-8 — deterministic across launches,
    /// unlike `Hasher` (seeded per-process), so a re-dropped link or
    /// clip always lands on the same file and dedupes to one entry.
    static func stableHash(_ string: String) -> String {
        var hash: UInt32 = 0x811C9DC5
        for byte in string.utf8 {
            hash = (hash ^ UInt32(byte)) &* 0x01000193
        }
        return String(format: "%08x", hash)
    }
}

/// The shake recognizer for summon-by-shake: a pure pass over the
/// drag's recent x samples. A shake is at least four direction
/// reversals inside a 600 ms window where every completed leg
/// travelled at least the amplitude — a straight drag has no
/// reversals, a jitter or a slow wiggle has legs too small to count.
enum ShelfShakeDetector {
    /// One pointer sample during a drag: screen x at a moment.
    struct Sample: Equatable {
        var x: CGFloat
        var at: TimeInterval
    }

    /// The recognizer's thresholds for a sensitivity, 0…1 (Dropover's
    /// slider): the middle is Alcove's four 30-point swings; all the way
    /// up, three 20-point swings are enough; all the way down it takes
    /// six of 45. Both fall as the sensitivity rises, so a shake that
    /// counts at one setting counts at every setting above it.
    static func thresholds(sensitivity: Double) -> (reversals: Int, amplitude: CGFloat) {
        let s = sensitivity.isFinite ? min(1, max(0, sensitivity)) : 0.5
        if s <= 0.5 {
            let t = s / 0.5
            return (Int((6 - 2 * t).rounded()), CGFloat(45 - 15 * t))
        }
        let t = (s - 0.5) / 0.5
        return (Int((4 - t).rounded()), CGFloat(30 - 10 * t))
    }

    /// `isShake` at a sensitivity's thresholds.
    static func isShake(_ samples: [Sample], sensitivity: Double) -> Bool {
        let limits = thresholds(sensitivity: sensitivity)
        return isShake(samples, reversals: limits.reversals, amplitude: limits.amplitude)
    }

    /// Whether `samples` hold a shake. `reversals` completed legs of
    /// at least `amplitude` points inside any `window`-second span —
    /// the defaults are Alcove's: 4 reversals, 600 ms, 30 pt.
    static func isShake(_ samples: [Sample],
                        reversals: Int = 4,
                        window: TimeInterval = 0.6,
                        amplitude: CGFloat = 30) -> Bool {
        guard samples.count > 2 else { return false }
        // Under a 2 pt deadband a stalled pointer doesn't keep
        // flipping direction on sub-pixel noise.
        let deadband: CGFloat = 2
        for end in samples.indices {
            let tEnd = samples[end].at
            var start = end
            while start > 0, tEnd - samples[start - 1].at <= window {
                start -= 1
            }
            guard end > start else { continue }
            var counted = 0
            var direction = 0
            var travel: CGFloat = 0
            var previous = samples[start].x
            for index in (start + 1)...end {
                let dx = samples[index].x - previous
                previous = samples[index].x
                guard abs(dx) >= deadband else { continue }
                let sign = dx > 0 ? 1 : -1
                if sign == direction {
                    travel += abs(dx)
                } else {
                    // The leg just ended — it only earns a reversal
                    // if it carried the full amplitude.
                    if travel >= amplitude { counted += 1 }
                    direction = sign
                    travel = abs(dx)
                }
            }
            if counted >= reversals { return true }
        }
        return false
    }
}

/// The chip's Quick Look: the system's own preview panel over the
/// tray's still-resolving entries — Dropover's space-bar preview,
/// minus the custom window. A shared singleton because the panel is
/// shared too: `QLPreviewPanel` reads its items through the data
/// source it is handed, and re-showing retargets the same instance.
@MainActor
final class ShelfQuickLook: NSObject {
    static let shared = ShelfQuickLook()

    /// The data source the panel is given — QLPreviewPanel talks to a
    /// plain object with no actor home, so it owns the item list and
    /// this model only writes it.
    private let source = Source()

    /// Open the panel on `index` of `urls` — missing entries were
    /// filtered by the caller, so every item previews.
    func show(urls: [URL], at index: Int) {
        guard !urls.isEmpty, let panel = QLPreviewPanel.shared() else { return }
        source.items = urls.map { $0 as NSURL }
        panel.dataSource = source
        panel.delegate = source
        panel.currentPreviewItemIndex = min(max(0, index), urls.count - 1)
        panel.reloadData()
        if panel.isVisible {
            panel.orderOut(nil)
        } else {
            WindowPresenter.automatic.order(panel, as: .key)
        }
    }

    /// The `QLPreviewPanelDataSource`/`Delegate` face — kept separate
    /// so the model stays a plain class the tests can drive.
    private final class Source: NSObject, QLPreviewPanelDataSource, QLPreviewPanelDelegate {
        var items: [QLPreviewItem] = []

        func numberOfPreviewItems(in panel: QLPreviewPanel) -> Int {
            items.count
        }

        func previewPanel(_ panel: QLPreviewPanel,
                          previewItemAt index: Int) -> QLPreviewItem {
            // An out-of-range ask can only be the panel's own probe —
            // answer the first item rather than crash the share.
            items[safe: index] ?? items.first ?? NSURL()
        }
    }
}
