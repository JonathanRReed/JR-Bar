import AppKit
import JRBarCore
import UniformTypeIdentifiers

/// Which of the bar's sections a tile belongs to: the app run (pins
/// then running), the file group (widgets, folder stacks, parked tray
/// items), or the Trash. The separator math reads this — a boundary
/// draws wherever the section changes.
enum DockItemSection: Int, Sendable {
    case apps = 0
    case files = 1
    case trash = 2
}

/// Which dock widget a tile renders. The widget tiles are ordinary
/// `DockItem`s so ordering, magnification, hit-testing and the
/// panel's length math all treat them like anything else — only the
/// tile's renderer differs.
enum DockWidgetKind: String, Equatable, Sendable {
    case clock
    case battery

    var title: String {
        switch self {
        case .clock: return "Clock"
        case .battery: return "Battery"
        }
    }
}

extension DockItem {
    /// The file-group marker — folder stacks, tray items and widgets
    /// all draw between the app run and the Trash.
    var isFileItem: Bool { isFolder || isTrayItem || widget != nil }

    /// The tile's section — separators draw where it changes.
    var section: DockItemSection {
        if isTrash { return .trash }
        return isFileItem ? .files : .apps
    }

    /// A folder-stack tile for `path`. The path is the pin's identity
    /// (it's what `DockSettings.folders` stores), so the tile's
    /// `bundleID` slot carries a namespaced form — it can never
    /// collide with a real bundle id.
    static func folder(path: String) -> DockItem {
        let url = URL(fileURLWithPath: path)
        return DockItem(bundleID: "jrbar.folder|\(path)",
                        name: url.lastPathComponent,
                        bundleURL: url,
                        isRunning: false, isPinned: false,
                        processIdentifier: nil,
                        isFolder: true)
    }

    /// A parked tray file — same identity trick as the folder tile.
    static func trayItem(path: String) -> DockItem {
        let url = URL(fileURLWithPath: path)
        return DockItem(bundleID: "jrbar.tray|\(path)",
                        name: FileManager.default.displayName(atPath: path),
                        bundleURL: url,
                        isRunning: false, isPinned: false,
                        processIdentifier: nil,
                        isTrayItem: true)
    }

    /// A widget tile — the renderer reads `widget` for the kind.
    static func widget(_ kind: DockWidgetKind) -> DockItem {
        DockItem(bundleID: "jrbar.dock-widget.\(kind.rawValue)",
                 name: kind.title, bundleURL: nil,
                 isRunning: false, isPinned: false,
                 processIdentifier: nil,
                 widget: kind)
    }
}

// MARK: - Folder stack contents

/// One entry in a folder stack's grid — what the popover lists. The
/// icon is resolved by the view (`DockIconResolver.icon(fileURL:)`),
/// never carried here.
struct DockFolderEntry: Identifiable, Equatable {
    var id: String { url.path }
    let url: URL
    let name: String
    let isDirectory: Bool
}

/// A folder tile's contents: the directory's visible children in
/// display-name order, capped — Apple's stacks hide dotfiles and so
/// do we. The listing itself is two `FileManager` reads; both sit
/// behind seams so the sort/filter/cap contract is testable without
/// touching the disk.
enum DockFolderListing {
    /// Hard cap — a runaway folder can't sprawl the popover (or hang
    /// the bar enumerating it).
    static let maxEntries = 200
    /// `.`-prefixed names count as hidden even where the filesystem
    /// flag isn't set — Apple's stacks skip them too.
    static let skipHidden = true

    /// The live read — what the popover calls.
    static func contents(of url: URL) -> [DockFolderEntry] {
        contents(
            of: url,
            lister: {
                try? FileManager.default.contentsOfDirectory(
                    at: $0, includingPropertiesForKeys: [.isDirectoryKey],
                    options: skipHidden ? [.skipsHiddenFiles] : [])
            },
            isDirectory: {
                (try? $0.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory ?? false
            })
    }

    /// The seam-friendly core: hidden names out, display-name order,
    /// cap applied after sorting so the cut is the tail, not a
    /// random slice.
    static func contents(of base: URL,
                         lister: (URL) -> [URL]?,
                         isDirectory: (URL) -> Bool,
                         displayName: (URL) -> String = {
                             FileManager.default.displayName(atPath: $0.path)
                         }) -> [DockFolderEntry] {
        guard let urls = lister(base) else { return [] }
        let visible = urls.filter {
            !skipHidden || !$0.lastPathComponent.hasPrefix(".")
        }
        let sorted = visible.sorted {
            displayName($0).localizedStandardCompare(displayName($1)) == .orderedAscending
        }
        return sorted.prefix(maxEntries).map {
            DockFolderEntry(url: $0, name: displayName($0), isDirectory: isDirectory($0))
        }
    }
}

// MARK: - Drops onto the bar

/// What a drag onto the bar becomes: a directory pins a folder stack,
/// anything else parks in the tray. Pure — the drop handler feeds it
/// file URLs plus a directory lookup (`DockModel.directoryCheck`), so
/// the classification is testable without a drag session.
enum DockDropPlan {
    static func classify(urls: [URL],
                         isDirectory: (URL) -> Bool) -> (folders: [String], tray: [String]) {
        var folders: [String] = []
        var tray: [String] = []
        for url in urls where url.isFileURL {
            if isDirectory(url) {
                folders.append(url.path)
            } else {
                tray.append(url.path)
            }
        }
        return (folders, tray)
    }
}

/// `public.file-url` providers → file URLs. Provider loads are always
/// async, so the drop delegates hand over the providers and get the
/// URLs back on the main queue.
enum DockDropSupport {
    static func loadURLs(_ providers: [NSItemProvider],
                         completion: @escaping ([URL]) -> Void) {
        let group = DispatchGroup()
        let collected = CollectedURLs()
        for provider in providers {
            group.enter()
            provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier,
                              options: nil) { item, _ in
                defer { group.leave() }
                let url = (item as? URL)
                    ?? (item as? NSURL).map { $0 as URL }
                    ?? (item as? Data).flatMap {
                        URL(dataRepresentation: $0, relativeTo: nil)
                    }
                if let url, url.isFileURL {
                    collected.append(url)
                }
            }
        }
        group.notify(queue: .main) { completion(collected.urls) }
    }

    /// The providers' results, gathered off whatever threads the
    /// loads complete on.
    private final class CollectedURLs: @unchecked Sendable {
        private let lock = NSLock()
        private var collected: [URL] = []
        var urls: [URL] { lock.lock(); defer { lock.unlock() }; return collected }
        func append(_ url: URL) {
            lock.lock()
            collected.append(url)
            lock.unlock()
        }
    }
}
