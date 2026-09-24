import AppKit
import ApplicationServices
import JRBarCore
import Observation

// MARK: - Preview content

/// One card in the preview panel: a title, the window's frame (the
/// thumbnail match key), an AX handle the verbs act on, and an
/// optional thumbnail filled in asynchronously.
struct DockPreviewWindow: Identifiable {
    let id: Int
    var title: String
    var minimized: Bool
    /// `AXFullScreen` state; nil where the window doesn't offer the
    /// write (Finder et al.) — the card hides the verb.
    var fullScreen: Bool?
    /// The window's frame in Quartz coordinates, when AX reports one.
    var frame: CGRect?
    /// The file the window shows (`AXDocument`), when it declares one —
    /// a card carrying a document drags it onto another app's Dock tile.
    var documentURL: URL? = nil
    var thumbnail: NSImage?
    /// The AX window element — the raise/close/minimize target. A card
    /// lives on the main actor; the switcher's commits carry the bare
    /// handle to `DockAXWorker` (`DockAXElement`) instead of the card.
    let element: AXUIElement?
    /// Native capture identity, when the OS exposes it.
    var windowID: CGWindowID? = nil
}

/// One entry in a folder pop (DockDoor's Folder Pop): the name, the
/// type icon and the URL a click opens. Ids are indices — a folder
/// fill is synchronous, there is no in-flight write to mis-land.
struct DockFolderEntry: Identifiable {
    let id: Int
    let name: String
    let url: URL
    let icon: NSImage
    let isDirectory: Bool
}

/// How a Dock folder tile is arranged — the stack's own Sort By, stored
/// as `arrangement` in the tile's `com.apple.dock` `persistent-others`
/// entry (1 Name, 2 Date Added, 3 Date Modified, 4 Date Created,
/// 5 Kind). The pop follows it, so Downloads leads with today's file.
enum DockFolderSort: Int, Equatable, Sendable {
    case name = 1, dateAdded = 2, dateModified = 3, dateCreated = 4, kind = 5

    /// The resource key a sort reads per entry — nil for Name, which
    /// needs nothing past `readdir`.
    var resourceKey: URLResourceKey? {
        switch self {
        case .name: return nil
        case .dateAdded: return .addedToDirectoryDateKey
        case .dateModified: return .contentModificationDateKey
        case .dateCreated: return .creationDateKey
        case .kind: return .localizedTypeDescriptionKey
        }
    }

    /// The tile's arrangement, read out of the Dock's `persistent-others`
    /// (read-only — nothing here writes `com.apple.dock`). A folder the
    /// list doesn't hold, or an arrangement it doesn't know, is Name.
    static func of(folder: URL, persistentOthers: [Any]?) -> DockFolderSort {
        let wanted = standardizedPath(folder)
        for case let tile as [String: Any] in persistentOthers ?? [] {
            guard let data = tile["tile-data"] as? [String: Any],
                  let file = data["file-data"] as? [String: Any],
                  let string = file["_CFURLString"] as? String else { continue }
            let url = URL(string: string) ?? URL(fileURLWithPath: string)
            guard standardizedPath(url) == wanted else { continue }
            let raw = (data["arrangement"] as? NSNumber)?.intValue ?? 1
            return DockFolderSort(rawValue: raw) ?? .name
        }
        return .name
    }

    private static func standardizedPath(_ url: URL) -> String {
        let path = url.standardizedFileURL.path
        return path.count > 1 && path.hasSuffix("/") ? String(path.dropLast()) : path
    }

    /// One folder row as the sort sees it.
    struct Row {
        let name: String
        let url: URL
        let isDir: Bool
    }

    /// Order rows the way the stack does: Name keeps directories first
    /// then Finder's name order; the date sorts run newest first; Kind
    /// groups by the type's description, then name. An entry the read
    /// couldn't date sinks to the end rather than guessing a place.
    func arrange(_ rows: [Row], date: (URL) -> Date?, kind: (URL) -> String?) -> [Row] {
        func byName(_ a: Row, _ b: Row) -> Bool {
            a.name.localizedStandardCompare(b.name) == .orderedAscending
        }
        switch self {
        case .name:
            return rows.sorted {
                if $0.isDir != $1.isDir { return $0.isDir }
                return byName($0, $1)
            }
        case .kind:
            let kinds = Dictionary(rows.map { ($0.url, kind($0.url) ?? "") }, uniquingKeysWith: { a, _ in a })
            return rows.sorted {
                let a = kinds[$0.url] ?? "", b = kinds[$1.url] ?? ""
                if a != b { return a.localizedStandardCompare(b) == .orderedAscending }
                return byName($0, $1)
            }
        case .dateAdded, .dateModified, .dateCreated:
            let dates = Dictionary(rows.map { ($0.url, date($0.url)) }, uniquingKeysWith: { a, _ in a })
            return rows.sorted {
                switch (dates[$0.url] ?? nil, dates[$1.url] ?? nil) {
                case let (a?, b?): return a != b ? a > b : byName($0, $1)
                case (.some, nil): return true
                case (nil, .some): return false
                case (nil, nil): return byName($0, $1)
                }
            }
        }
    }
}

/// Where a folder pop's listing stands. `denied` is the TCC case —
/// the app lacks Files-and-Folders consent for Downloads/Desktop/
/// Documents, so the panel can offer the Settings shortcut rather
/// than pretending the folder is empty.
enum DockFolderState {
    case loading, ready, denied, failed
}

/// The off-main result of reading one folder: the capped entries,
/// the folder's own icon (resolved where a stall can't reach the UI)
/// and whether the read was refused outright.
struct DockFolderListing {
    var entries: [DockFolderEntry] = []
    var folderIcon: NSImage?
    var denied = false
}

/// Everything the panel renders for one hovered dock icon — an
/// observable box so late-arriving thumbnails re-render the view.
@MainActor
@Observable
final class DockPreviewContent {
    var appName = ""
    var icon: NSImage?
    var bundleID: String?
    var appURL: URL?
    var processIdentifier: pid_t?
    var isRunning = false
    var windows: [DockPreviewWindow] = []
    /// The tile's `AXStatusLabel` — the Dock's own unread badge, drawn
    /// on the header icon the way the tile draws it.
    var badge: String?
    /// Non-nil when the hovered tile is a folder: the panel pops the
    /// directory's entries instead of window cards.
    var folderURL: URL?
    /// The folders drilled into below `folderURL`, outermost first — the
    /// pop browses in place like Apple's Grid stack. Empty at the tile's
    /// own folder.
    var folderTrail: [URL] = []
    /// The folder the pop shows now: the deepest drilled one, else the
    /// tile's.
    var folderShown: URL? { folderTrail.last ?? folderURL }
    var folderEntries: [DockFolderEntry] = []
    /// The entries load off the main actor — a directory can stall
    /// (file provider, dead mount, a pending TCC consent) and the pop
    /// shows "Loading…" until they land or fail. Only read when
    /// `folderURL` is non-nil.
    var folderState: DockFolderState = .loading
    /// DockDoor's player row: while a media app's preview is up the
    /// panel subscribes to `MediaFeed` and shows what the system says
    /// that app is playing. nil until a track lands.
    var media: AlcoveMedia?
    /// The Calendar tile's glance (the rest of today, up to three), or a
    /// meeting app's one event whose link is its own — read only when
    /// JR-Bar already holds Full Calendar Access; a hover never prompts.
    var calendarEvents: [ShelfCalendarModel.Event] = []
    /// "Free until 3:30" — nothing on now, something later today.
    var calendarFreeUntil: Date?
    /// Calendar access was never asked: the row offers an explicit
    /// "Show events" button rather than reading unprompted.
    var calendarNeedsAuth = false
    var largeCards = false
    /// True when the window count passed `compactListLimit` — the
    /// panel lists titles instead of thumbnails and skips captures.
    var compact = false
    /// The keyboard-walked card — arrows move it, Return raises it.
    var selectedWindowID: Int?
    /// card id → the agent session that window exclusively hosts
    /// (`DockAgentMatch`) — the card's mark, ring and status line.
    var agents: [Int: DockAgentMark] = [:]
    /// Every live session this app hosts, matched to a card or not — the
    /// header's count, the ask rows and Quit's guard read it.
    var appAgents: [DockAgentMark] = []
    /// Cards a shake or flick just moved — they dip for a beat.
    var pulsedWindowIDs: Set<Int> = []
    /// A guarded close's first press: the card that rings and its line.
    var armedWindowID: Int?
    var armedNote: String?
    /// The header's one-line note: a guarded Quit's first press, or the
    /// windows Close all kept because an agent runs in them.
    var headerNote: String?
    /// Quit was asked and the app is still here a beat later — the
    /// header's power disc becomes Force Quit.
    var stillRunning = false

    /// The waiting sessions the ask rows offer, most urgent first,
    /// capped so a busy terminal can't grow the panel into a list.
    var askRows: [DockAgentMark] {
        Array(appAgents.filter { $0.isWaiting && $0.ask != nil }.prefix(3))
    }
}
