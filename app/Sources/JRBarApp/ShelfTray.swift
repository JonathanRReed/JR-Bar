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
    /// The tray is a glance surface, not a filesystem — past this the
    /// oldest entries drop off.
    static let maxItems = 12
    /// Largest file "Attach" will offer to a draft without a confirm —
    /// anything bigger stays a path reference only.
    static let attachCopyBound: Int64 = 8 * 1024 * 1024

    private static let defaultsKey = "jrbar.shelfTray.paths"

    struct Entry: Identifiable, Equatable {
        let path: String
        /// Recomputed on every load/show — a file that moved or was
        /// deleted is `missing`, not removed (the user decides).
        var missing: Bool
        var id: String { path }
        var url: URL { URL(fileURLWithPath: path) }
        var name: String { url.lastPathComponent }
    }

    private(set) var entries: [Entry] = []

    init() {
        load()
    }

    /// Drop-in or explicit add: dedupes, bounds the strip, persists.
    /// `before` aims the landing at a chip — a drop on a chip lands
    /// where it dropped, Yoink-style, not at the tail. Symlinks
    /// resolve at read time — a link whose target moved is `missing`
    /// on the next pass.
    func add(_ urls: [URL], before target: Entry? = nil) {
        var known = entries
        let fresh = urls.map(\.path).reduce(into: [Entry]()) { out, path in
            if !known.contains(where: { $0.path == path }),
               !out.contains(where: { $0.path == path }) {
                out.append(Entry(path: path, missing: false))
            }
        }
        guard !fresh.isEmpty else { return }
        let at = target.flatMap { t in known.firstIndex(where: { $0.id == t.id }) }
            ?? known.count
        known.insert(contentsOf: fresh, at: at)
        evictionNotice = nil
        if known.count > Self.maxItems {
            // The strip is bounded: the oldest chips drop their
            // REFERENCE (the file itself is never touched — the tray
            // only tracks paths). That must be said out loud: a shelf
            // that silently forgets reads as data loss.
            let dropped = known.prefix(known.count - Self.maxItems)
            known = Array(known.suffix(Self.maxItems))
            let names = dropped.map { URL(fileURLWithPath: $0.path).lastPathComponent }
            evictionNotice = names.count == 1
                ? "Shelf full — \u{201C}\(names[0])\u{201D} dropped off (file untouched)"
                : "Shelf full — \(names.count) oldest items dropped off (files untouched)"
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

    func remove(_ entry: Entry) {
        entries.removeAll { $0.id == entry.id }
        icons.removeValue(forKey: entry.path)
        pendingThumbs.remove(entry.path)
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
    /// the entries do.
    func move(_ moved: Entry, before target: Entry) {
        guard moved.id != target.id,
              let from = entries.firstIndex(where: { $0.id == moved.id }),
              var to = entries.firstIndex(where: { $0.id == target.id })
        else { return }
        let item = entries.remove(at: from)
        if from < to { to -= 1 }
        entries.insert(item, at: to)
        persist()
    }

    /// Reveal in Finder — only for entries that still resolve.
    func reveal(_ entry: Entry) {
        revalidate()
        guard let fresh = entries.first(where: { $0.id == entry.id }),
              !fresh.missing else { return }
        NSWorkspace.shared.activateFileViewerSelecting([fresh.url])
    }

    /// Drag-out / share payload for an entry that still resolves.
    func provider(for entry: Entry) -> NSItemProvider? {
        revalidate()
        guard let fresh = entries.first(where: { $0.id == entry.id }),
              !fresh.missing else { return nil }
        return NSItemProvider(object: fresh.url as NSURL)
    }

    /// Native share: returns the services that can send this file so the
    /// caller can present them. A canceled picker claims nothing (T50).
    func sharingServices(for entry: Entry) -> [NSSharingService] {
        revalidate()
        guard let fresh = entries.first(where: { $0.id == entry.id }),
              !fresh.missing else { return [] }
        return NSSharingService.sharingServices(forItems: [fresh.url])
    }

    /// The dedicated one-click path: straight to AirDrop, no picker —
    /// Alcove's headline shelf verb. Returns whether the service ran.
    @discardableResult
    func sendViaAirDrop(_ entry: Entry) -> Bool {
        revalidate()
        guard let fresh = entries.first(where: { $0.id == entry.id }),
              !fresh.missing,
              let service = NSSharingService(named: .sendViaAirDrop) else { return false }
        service.perform(withItems: [fresh.url])
        return true
    }

    /// File size for the attach bound — nil when unresolvable.
    func size(of entry: Entry) -> Int64? {
        guard let values = try? entry.url.resourceValues(forKeys: [.fileSizeKey]),
              let size = values.fileSize else { return nil }
        return Int64(size)
    }

    /// Whether "Attach to draft" may inline this file's bytes or must
    /// stay a path reference (bounded copies).
    func canAttachCopy(_ entry: Entry) -> Bool {
        guard let size = size(of: entry) else { return false }
        return size <= Self.attachCopyBound
    }

    /// Mark missing entries by re-reading the filesystem — the same
    /// check the read path makes, so the strip and reads never disagree.
    func revalidate() {
        entries = entries.map { entry in
            var fresh = entry
            fresh.missing = !FileManager.default.fileExists(atPath: entry.path)
            return fresh
        }
    }

    /// The chip's Quick Look — the system preview panel over every
    /// entry that still resolves, opened on this one.
    func quickLook(_ entry: Entry) {
        revalidate()
        let live = entries.filter { !$0.missing }
        guard let index = live.firstIndex(where: { $0.id == entry.id }) else { return }
        ShelfQuickLook.shared.show(urls: live.map(\.url), at: index)
    }

    private func load() {
        let paths = UserDefaults.standard.stringArray(forKey: Self.defaultsKey) ?? []
        entries = paths.suffix(Self.maxItems).map { Entry(path: $0, missing: false) }
        revalidate()
    }

    private func persist() {
        UserDefaults.standard.set(entries.map(\.path), forKey: Self.defaultsKey)
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
