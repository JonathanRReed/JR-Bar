import AppKit
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

    /// Every item across every chip — the verbs and the bound work on
    /// files, not tiles.
    var items: [Entry] { entries.flatMap(\.items) }

    init() {
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
    /// `missing` on the next pass.
    func add(_ urls: [URL], before target: ShelfEntry? = nil,
             onto stackTarget: ShelfEntry? = nil) {
        var known = entries
        let held = known.flatMap(\.items).map(\.path)
        let fresh = urls.map(\.path).reduce(into: [Entry]()) { out, path in
            if !held.contains(path), !out.contains(where: { $0.path == path }) {
                out.append(Entry(path: path, missing: false))
            }
        }
        guard !fresh.isEmpty else { return }
        evictionNotice = nil

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
            finish(&known)
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
                ?? known.count
            known.insert(.stack(stack), at: at)
            finish(&known)
            return
        }

        // A single new file: same-folder rules — join a stack living
        // in its folder, or stack up with a loose item from it.
        let item = fresh[0]
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
            finish(&known)
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
            finish(&known)
            return
        }

        let at = target.flatMap { t in known.firstIndex(where: { $0.id == t.id }) }
            ?? known.count
        known.insert(.item(item), at: at)
        finish(&known)
    }

    /// Bound, revalidate, persist — the add paths' shared tail.
    private func finish(_ known: inout [ShelfEntry]) {
        let total = known.reduce(0) { $0 + $1.items.count }
        if total > Self.maxItems {
            // The strip is bounded: the oldest chips drop their
            // REFERENCES (the files themselves are never touched — the
            // tray only tracks paths). That must be said out loud: a
            // shelf that silently forgets reads as data loss.
            var over = total - Self.maxItems
            var names: [String] = []
            var droppedItems = 0
            while over > 0, let first = known.first {
                let count = first.items.count
                droppedItems += count
                names.append(first.displayName)
                known.removeFirst()
                over -= count
            }
            evictionNotice = droppedItems == 1
                ? "Shelf full — \u{201C}\(names[0])\u{201D} dropped off (file untouched)"
                : "Shelf full — \(droppedItems) oldest items dropped off (files untouched)"
        }
        entries = known
        revalidate()
        persist()
    }

    /// Set when a bounded add pushed the oldest chips off — the strip
    /// shows the sentence so a quiet eviction never reads as data
    /// loss. Cleared by the next add/remove, or the row's fade.
    private(set) var evictionNotice: String?

    func clearEvictionNotice() { evictionNotice = nil }

    func remove(_ entry: ShelfEntry) {
        entries.removeAll { $0.id == entry.id }
        for item in entry.items {
            icons.removeValue(forKey: item.path)
            pendingThumbs.remove(item.path)
        }
        evictionNotice = nil
        persist()
    }

    /// The chip's face: the file's own icon from the workspace — a
    /// screenshot in Finder livery, not a generic `doc`. Previewable
    /// files then upgrade to a real thumbnail when Quick Look answers
    /// off-actor; the generic face shows until it lands.
    private var icons: [String: NSImage] = [:]
    private var pendingThumbs: Set<String> = []

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
        guard pendingThumbs.insert(path).inserted else { return }
        let request = QLThumbnailGenerator.Request(
            fileAt: URL(fileURLWithPath: path),
            size: CGSize(width: 22, height: 22),
            scale: NSScreen.main?.backingScaleFactor ?? 2,
            representationTypes: .thumbnail)
        QLThumbnailGenerator.shared.generateBestRepresentation(
            for: request) { [weak self] rep, _ in
                // Read the image on the completion queue — the
                // representation itself isn't Sendable, the image is.
                guard let image = rep?.nsImage else { return }
                image.size = NSSize(width: 11, height: 11)
                Task { @MainActor in
                    // The entry may have left the tray while the ask
                    // was out — caching for a removed path is harmless,
                    // the entry's re-add reads the warm slot.
                    self?.icons[path] = image
                }
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

    /// A stack taken apart — the ⌘-click / Split verb. Members land
    /// as loose chips where the stack stood.
    func dissolve(_ entry: ShelfEntry) {
        guard case .stack(let stack) = entry,
              let at = entries.firstIndex(where: { $0.id == entry.id })
        else { return }
        entries.replaceSubrange(at...at, with: stack.items.map { .item($0) })
        persist()
    }

    /// The chip merges with the one after it — the Merge verb. The
    /// pair keeps the folder key only if they truly sit together.
    func mergeWithNext(_ entry: ShelfEntry) {
        guard let at = entries.firstIndex(where: { $0.id == entry.id }),
              at + 1 < entries.count else { return }
        let members = entries[at].items + entries[at + 1].items
        guard members.count >= 2 else { return }
        let stack = ShelfEntry.Stack(
            id: "stack-\(UUID().uuidString)",
            name: ShelfEntry.Stack.name(for: members),
            items: members,
            folder: ShelfEntry.Stack.commonFolder(of: members))
        entries.replaceSubrange(at...(at + 1), with: [.stack(stack)])
        persist()
    }

    /// One file out of a stack — the popover's remove. A stack
    /// thinned to one member dissolves into that loose chip.
    func removeItem(_ item: Entry, from stackID: String) {
        guard let at = entries.firstIndex(where: { $0.id == stackID }),
              case .stack(var stack) = entries[at] else { return }
        stack.items.removeAll { $0.id == item.id }
        if stack.items.isEmpty {
            entries.remove(at: at)
        } else if stack.items.count == 1 {
            entries[at] = .item(stack.items[0])
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
        revalidate()
        let live = entries.first(where: { $0.id == entry.id })?
            .items.filter { !$0.missing }.map(\.url) ?? []
        guard !live.isEmpty else { return }
        NSWorkspace.shared.activateFileViewerSelecting(live)
    }

    /// Drag-out / share payload for an entry that still resolves. A
    /// stack drags out as a multi-item provider — the whole pile.
    func provider(for entry: ShelfEntry) -> NSItemProvider? {
        revalidate()
        let urls = entries.first(where: { $0.id == entry.id })?
            .items.filter { !$0.missing }.map { $0.url as NSURL } ?? []
        guard !urls.isEmpty else { return nil }
        if urls.count == 1, let url = urls.first {
            return NSItemProvider(object: url)
        }
        let provider = NSItemProvider()
        provider.suggestedName = entry.displayName
        for url in urls {
            provider.registerObject(url, visibility: .all)
        }
        return provider
    }

    /// Native share: returns the services that can send this entry's
    /// files so the caller can present them. A canceled picker claims
    /// nothing (T50).
    func sharingServices(for entry: ShelfEntry) -> [NSSharingService] {
        revalidate()
        let urls = entries.first(where: { $0.id == entry.id })?
            .items.filter { !$0.missing }.map(\.url) ?? []
        guard !urls.isEmpty else { return [] }
        return NSSharingService.sharingServices(forItems: urls)
    }

    /// The dedicated one-click path: straight to AirDrop, no picker —
    /// Alcove's headline shelf verb. Returns whether the service ran.
    @discardableResult
    func sendViaAirDrop(_ entry: ShelfEntry) -> Bool {
        revalidate()
        let urls = entries.first(where: { $0.id == entry.id })?
            .items.filter { !$0.missing }.map(\.url) ?? []
        guard !urls.isEmpty,
              let service = NSSharingService(named: .sendViaAirDrop) else { return false }
        service.perform(withItems: urls)
        return true
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

    /// Hand the entry to an agent: its `@path` references go on the
    /// pasteboard as text beside the file URLs, and a single small
    /// image rides along as image data. Nothing is typed anywhere —
    /// the person pastes it into the session this opens. False when no
    /// file of the entry is present.
    @discardableResult
    func copyForAgent(_ entry: ShelfEntry) -> Bool {
        let present = entries.first(where: { $0.id == entry.id })?.items.filter { !$0.missing } ?? []
        guard !present.isEmpty else { return false }
        Self.copyForAgent(present.map(\.url), attachImage: canAttachCopy(entry))
        return true
    }

    /// The pasteboard half, shared with a file dropped straight onto a
    /// session row: the `@path` text first, a small single image as
    /// image data beside it, then the file URLs for a GUI app.
    static func copyForAgent(_ urls: [URL], attachImage: Bool) {
        guard !urls.isEmpty else { return }
        let board = NSPasteboard.general
        board.clearContents()
        var objects: [NSPasteboardWriting] = [agentReferences(urls.map(\.path)) as NSString]
        if attachImage, urls.count == 1, let url = urls.first,
           let type = UTType(filenameExtension: url.pathExtension), type.conforms(to: .image),
           let image = NSImage(contentsOf: url) {
            objects.append(image)
        }
        board.writeObjects(objects)
        board.writeObjects(urls.map { $0 as NSURL })
    }

    /// Whether a dropped file is small enough to ride along as bytes.
    static func withinAttachBound(_ url: URL) -> Bool {
        guard let size = (try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize else { return false }
        return Int64(size) <= attachCopyBound
    }

    /// Mark missing entries by re-reading the filesystem — the same
    /// check the read path makes, so the strip and reads never disagree.
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

    private func load() {
        // Two stores share the key's history: the flat [String] the
        // tray wrote before stacks, and the plist-dict list it writes
        // now. Anything unrecognized decodes to nothing — the shelf
        // never refuses to open over one bad record.
        if let stored = UserDefaults.standard.array(
            forKey: Self.defaultsKey) as? [[String: Any]] {
            entries = stored.compactMap(Self.entry(from:))
        } else {
            let paths = UserDefaults.standard.stringArray(
                forKey: Self.defaultsKey) ?? []
            entries = paths.map { .item(Entry(path: $0, missing: false)) }
        }
        var total = 0
        entries = entries.reversed().filter { entry in
            total += entry.items.count
            return total <= Self.maxItems
        }.reversed()
        revalidate()
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
        UserDefaults.standard.set(stored, forKey: Self.defaultsKey)
    }
}

/// The tray's drop handling: file URLs and promised files. A promised
/// drop lands as the delivered file; one that fails delivery is simply
/// never added — the strip doesn't invent an entry (T49).
struct ShelfTrayDrop {
    /// URL extraction for `onDrop` providers — resolves promised file
    /// receivers through their delivered URL, plain file URLs directly,
    /// and web links through a `.webloc` the shelf writes itself (a
    /// link stays a real file, so reveal/share/AirDrop all answer it).
    static func urls(from providers: [NSItemProvider],
                     completion: @escaping @MainActor ([URL]) -> Void) {
        // `loadItem` completions can run on different queues — the
        // collection lives behind a lock so the appends can't race.
        let urls = OSAllocatedUnfairLock<[URL]>(initialState: [])
        let group = DispatchGroup()
        for provider in providers {
            if provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) {
                group.enter()
                provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { item, _ in
                    defer { group.leave() }
                    let url = (item as? URL)
                        ?? (item as? Data).flatMap { URL(dataRepresentation: $0, relativeTo: nil) }
                    if let url {
                        urls.withLock { $0.append(url) }
                    }
                }
            } else if provider.hasItemConformingToTypeIdentifier(UTType.url.identifier) {
                group.enter()
                provider.loadItem(forTypeIdentifier: UTType.url.identifier, options: nil) { item, _ in
                    defer { group.leave() }
                    let url = (item as? URL)
                        ?? (item as? Data).flatMap { URL(dataRepresentation: $0, relativeTo: nil) }
                    if let url, let loc = webLoc(for: url) {
                        urls.withLock { $0.append(loc) }
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
                    if let text, let loc = textLoc(for: text) {
                        urls.withLock { $0.append(loc) }
                    }
                }
            }
        }
        group.notify(queue: .main) {
            MainActor.assumeIsolated { completion(urls.withLock { $0 }) }
        }
    }

    /// Pasteboard-read URLs → tray-ready file URLs: files pass
    /// through, web links become `.webloc`s (the island's drop path,
    /// where the pasteboard is already open).
    static func trayURLs(from urls: [URL]) -> [URL] {
        urls.compactMap { $0.isFileURL ? $0 : webLoc(for: $0) }
    }

    /// A dropped web link as a `.webloc` file under the shelf's own
    /// folder — Yoink's same move. The name is a hash of the link, so
    /// re-dropping the same page lands on the same file and the tray's
    /// path dedupe keeps it one entry. nil when the folder can't be
    /// made or written — the drop then adds nothing (T49's rule).
    static func webLoc(for url: URL) -> URL? {
        guard url.scheme?.hasPrefix("http") == true,
              let base = FileManager.default.urls(
                for: .applicationSupportDirectory, in: .userDomainMask).first
        else { return nil }
        let dir = base.appendingPathComponent("JR-Bar/Shelf", isDirectory: true)
        // A stable, filesystem-safe name: the host plus a short hash
        // of the whole link (two links on one host still differ).
        let hash = stableHash(url.absoluteString)
        let host = (url.host ?? "Link")
            .replacingOccurrences(of: "/", with: "-")
            .replacingOccurrences(of: ":", with: "-")
        let loc = dir.appendingPathComponent("\(host)-\(hash).webloc")
        let plist = ["URL": url.absoluteString] as NSDictionary
        do {
            try FileManager.default.createDirectory(
                at: dir, withIntermediateDirectories: true)
            try plist.write(to: loc)
            return loc
        } catch {
            return nil
        }
    }

    /// A dropped text clipping as a `.txt` under the shelf's own folder —
    /// the `.webloc` move for plain strings: the clip stays a real file,
    /// so reveal/share/AirDrop/QuickLook all answer it. The name is the
    /// first line's head plus a hash of the whole text — re-dropping the
    /// same clip lands on the same file and dedupes to one entry.
    static func textLoc(for text: String) -> URL? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              let base = FileManager.default.urls(
                for: .applicationSupportDirectory, in: .userDomainMask).first
        else { return nil }
        let dir = base.appendingPathComponent("JR-Bar/Shelf", isDirectory: true)
        let hash = stableHash(text)
        let head = String(trimmed.components(separatedBy: .newlines).first?.prefix(24) ?? "Clip")
        let safe = head.components(separatedBy: CharacterSet.alphanumerics.inverted)
            .joined()
        let loc = dir.appendingPathComponent("\(safe.isEmpty ? "Clip" : safe)-\(hash).txt")
        do {
            try FileManager.default.createDirectory(
                at: dir, withIntermediateDirectories: true)
            try text.write(to: loc, atomically: true, encoding: .utf8)
            return loc
        } catch {
            return nil
        }
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
            panel.makeKeyAndOrderFront(nil)
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
