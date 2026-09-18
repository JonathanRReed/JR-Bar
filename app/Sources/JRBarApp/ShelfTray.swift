import AppKit
import os
import Quartz
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
    /// Symlinks resolve at read time — a link whose target moved is
    /// `missing` on the next pass.
    func add(_ urls: [URL]) {
        let paths = urls.map { $0.path }
        var known = entries
        for path in paths where !known.contains(where: { $0.path == path }) {
            known.append(Entry(path: path, missing: false))
        }
        if known.count > Self.maxItems {
            known = Array(known.suffix(Self.maxItems))
        }
        entries = known
        revalidate()
        persist()
    }

    func remove(_ entry: Entry) {
        entries.removeAll { $0.id == entry.id }
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
        var hasher = Hasher()
        hasher.combine(url.absoluteString)
        let hash = String(format: "%08x", UInt32(truncatingIfNeeded: hasher.finalize()))
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
