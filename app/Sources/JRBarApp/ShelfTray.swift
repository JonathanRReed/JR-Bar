import AppKit
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
    /// receivers through their delivered URL, plain file URLs directly.
    static func urls(from providers: [NSItemProvider],
                     completion: @escaping @MainActor ([URL]) -> Void) {
        var urls: [URL] = []
        let group = DispatchGroup()
        for provider in providers {
            if provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) {
                group.enter()
                provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { item, _ in
                    defer { group.leave() }
                    if let url = item as? URL {
                        urls.append(url)
                    } else if let data = item as? Data,
                              let url = URL(dataRepresentation: data, relativeTo: nil) {
                        urls.append(url)
                    }
                }
            }
        }
        group.notify(queue: .main) {
            MainActor.assumeIsolated { completion(urls) }
        }
    }
}
