import AppKit
import JRBarCore
import OSLog
import UniformTypeIdentifiers

/// macOS 27's menu-bar layout table — the one protected file where
/// MenuBarAgent keeps every status item's place
/// (`~/Library/Group Containers/com.apple.MenuBar/Library/Preferences/
/// com.apple.MenuBar.plist`, key `TrailingItemPreferredPositions`). Thaw
/// 3 reads and writes it; JR-Bar only ever reads it, and only after the
/// person grants the one file through an open panel. With it the bar's
/// true order is known, concealed apps included: a ⌘-drag is confirmed
/// without Accessibility, the Item Bar and the layout editor follow the
/// agent's own order, and the card can flag an app whose section and
/// place disagree — with a one-click section fix, never a move.
///
/// The file's shape is private and unverified here (the folder is
/// TCC-protected and no grant existed while this was built), so the
/// parser takes the likely forms: a map of item keys to positions
/// (larger sorts further left, as a status item's own Preferred
/// Position does), a list of keys from the trailing edge, or a list of
/// records. The first real file settles which.
enum MenuBarLayoutTable {
    /// Where the table lives.
    static var defaultURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Group Containers/com.apple.MenuBar/Library/Preferences/com.apple.MenuBar.plist")
    }
    /// The key the positions sit under.
    nonisolated static let positionsKey = "TrailingItemPreferredPositions"

    /// One item's record: its key in the table and its position, when
    /// the table gives one.
    struct Entry: Equatable, Sendable {
        var key: String
        var position: Double?
    }

    /// The table, left to right.
    struct Table: Equatable, Sendable {
        var entries: [Entry]

        /// The leftmost index of any entry `bundleID` owns.
        func rank(of bundleID: String, known: Set<String>) -> Int? {
            entries.firstIndex { MenuBarLayoutTable.bundleID(forKey: $0.key, known: known) == bundleID }
        }
    }

    // MARK: Parsing

    /// The table from the plist's bytes, binary or XML; nil when the file
    /// carries no positions this parser knows.
    nonisolated static func parse(_ data: Data) -> Table? {
        guard let root = try? PropertyListSerialization.propertyList(from: data, format: nil) else {
            return nil
        }
        let value = (root as? [String: Any])?[positionsKey] ?? root
        return table(from: value)
    }

    nonisolated private static func table(from value: Any) -> Table? {
        // A map of keys to positions: larger sorts further left.
        if let map = value as? [String: Any] {
            let positioned = map.compactMap { key, raw -> Entry? in
                if let number = raw as? NSNumber { return Entry(key: key, position: number.doubleValue) }
                if let record = raw as? [String: Any], let number = position(in: record) {
                    return Entry(key: key, position: number)
                }
                return nil
            }
            guard !positioned.isEmpty else { return nil }
            return Table(entries: positioned.sorted { lhs, rhs in
                let l = lhs.position ?? 0, r = rhs.position ?? 0
                return l == r ? lhs.key < rhs.key : l > r
            })
        }
        // A list of keys from the trailing edge: read right to left.
        if let keys = value as? [String] {
            guard !keys.isEmpty else { return nil }
            return Table(entries: keys.reversed().map { Entry(key: $0, position: nil) })
        }
        // A list of records, each naming its item and its position.
        if let records = value as? [[String: Any]] {
            let entries = records.compactMap { record -> Entry? in
                guard let key = ["identifier", "bundleIdentifier", "key", "id"]
                        .lazy.compactMap({ record[$0] as? String }).first else { return nil }
                return Entry(key: key, position: position(in: record))
            }
            guard !entries.isEmpty else { return nil }
            let positioned = entries.allSatisfy { $0.position != nil }
            return Table(entries: positioned
                         ? entries.sorted { ($0.position ?? 0) > ($1.position ?? 0) }
                         : entries.reversed())
        }
        return nil
    }

    nonisolated private static func position(in record: [String: Any]) -> Double? {
        for key in ["position", "preferredPosition", "Position", "value"] {
            if let number = record[key] as? NSNumber { return number.doubleValue }
        }
        return nil
    }

    // MARK: Reading it

    /// The bundle identifier a table key belongs to, among `known` ones:
    /// the key itself, or the longest known identifier the key starts
    /// with before a separator ("com.app.id.Item-0", "com.app.id:main").
    nonisolated static func bundleID(forKey key: String, known: Set<String>) -> String? {
        if known.contains(key) { return key }
        let separators: Set<Character> = [".", ":", "-", "/", " ", "_", "#"]
        let hits = known.filter { id in
            guard key.count > id.count, key.hasPrefix(id) else { return false }
            return separators.contains(key[key.index(key.startIndex, offsetBy: id.count)])
        }
        return hits.max { $0.count < $1.count }
    }

    /// Which side of JR-Bar's own slot the table puts an app on.
    enum Side: Equatable, Sendable { case left, right }

    nonisolated static func side(of app: String, ours: String, table: Table, known: Set<String>) -> Side? {
        let all = known.union([app, ours])
        guard let mine = table.rank(of: ours, known: all),
              let theirs = table.rank(of: app, known: all), mine != theirs else { return nil }
        return theirs < mine ? .left : .right
    }

    /// Whether the table, read after a drop, backs the drop's section:
    /// a hide lands the app left of our slot, a show right of it. What a
    /// ⌘-drag's confirm falls back on when Accessibility does not answer.
    nonisolated static func confirms(app: String, section: MenuBarItemSection, ours: String,
                                     table: Table, known: Set<String>) -> Bool {
        guard let side = side(of: app, ours: ours, table: table, known: known) else { return false }
        return section == .shown ? side == .right : side == .left
    }

    /// The agent's order as ranks the Item Bar and the editor sort by;
    /// an app the table does not name has none.
    nonisolated static func ranks(apps: Set<String>, table: Table) -> [String: Int] {
        var ranks: [String: Int] = [:]
        for app in apps {
            if let rank = table.rank(of: app, known: apps) { ranks[app] = rank }
        }
        return ranks
    }

    /// An app whose section and place disagree.
    struct Mismatch: Equatable, Sendable, Identifiable {
        var app: String
        /// Its section today.
        var section: MenuBarItemSection
        /// Where the table puts it.
        var side: Side
        var id: String { app }
        /// The one-click fix: the section its place says.
        var fix: MenuBarItemSection { side == .left ? .hidden : .shown }
    }

    /// Apps whose section and place disagree: hidden right of our slot
    /// (an inline reveal brings them back right of the icon), or shown
    /// left of it. Only apps the agent takes whole — `sections` is the
    /// per-app map, absent keys read shown — and only apps the table
    /// names beside ours. Only under the `.slot` seat, where the icon
    /// stands on our slot and its sides are macOS's order: under `.gap`
    /// the icon stands flush left of the drawn run, wherever our slot
    /// is (macOS puts it at the leftmost visible place), so a side of
    /// the slot is no side of the icon and every flag would be wrong.
    nonisolated static func mismatches(table: Table, sections: [String: MenuBarItemSection],
                                       apps: Set<String>, ours: String,
                                       seat: MenuBarMirrorSeat) -> [Mismatch] {
        guard seat == .slot else { return [] }
        return apps.sorted().compactMap { app in
            guard app != ours, let side = side(of: app, ours: ours, table: table, known: apps) else { return nil }
            let section = sections[app] ?? .shown
            switch (section, side) {
            case (.shown, .left), (.hidden, .right), (.alwaysHidden, .right):
                return Mismatch(app: app, section: section, side: side)
            default:
                return nil
            }
        }
    }
}

/// The granted table, read and watched. Opt-in: nothing is read before
/// the person picks the file in the open panel, and nothing is ever
/// written. The grant is a security-scoped bookmark kept in
/// `curation.layoutTableBookmark`; with Full Disk Access the path itself
/// is read when the bookmark no longer resolves.
@MainActor
final class MenuBarLayoutTableReader {
    nonisolated static let log = Logger(subsystem: "devin.jrbar", category: "menubar")

    /// The last good read, left to right.
    private(set) var table: MenuBarLayoutTable.Table?
    /// When it was read.
    private(set) var readAt: Date?
    /// Why the last read failed, in the card's words.
    private(set) var failure: String?
    /// A read landed or failed.
    var onChange: (@MainActor () -> Void)?
    /// Whether a grant is being read and followed.
    var isActive: Bool { url != nil }

    private var bookmark: Data?
    private var url: URL?
    private var scoped = false
    private var source: DispatchSourceFileSystemObject?
    private var rewatch: Task<Void, Never>?

    /// Read the table the bookmark grants, and follow it. A second start
    /// with the same grant changes nothing.
    func start(bookmark: Data) {
        guard bookmark != self.bookmark || url == nil else { return }
        stop()
        self.bookmark = bookmark
        var stale = false
        var resolved = try? URL(resolvingBookmarkData: bookmark, options: [.withSecurityScope, .withoutUI],
                                relativeTo: nil, bookmarkDataIsStale: &stale)
        if resolved == nil {
            resolved = try? URL(resolvingBookmarkData: bookmark, options: [.withoutUI],
                                relativeTo: nil, bookmarkDataIsStale: &stale)
        }
        let target = resolved ?? MenuBarLayoutTable.defaultURL
        scoped = target.startAccessingSecurityScopedResource()
        url = target
        read()
        watch()
    }

    /// Let the file go.
    func stop() {
        rewatch?.cancel()
        rewatch = nil
        source?.cancel()
        source = nil
        if scoped, let url { url.stopAccessingSecurityScopedResource() }
        scoped = false
        url = nil
        bookmark = nil
        table = nil
        readAt = nil
        failure = nil
    }

    private func read() {
        guard let url else { return }
        do {
            let data = try Data(contentsOf: url)
            if let parsed = MenuBarLayoutTable.parse(data) {
                table = parsed
                failure = nil
            } else {
                failure = "The table's format isn't one JR-Bar knows yet"
            }
            readAt = Date()
        } catch {
            failure = "Couldn't read the table — grant it again"
        }
        onChange?()
    }

    /// Follow the file: MenuBarAgent writes it atomically (a rename), so
    /// a rename or a delete re-opens the watch on the new file a beat
    /// later.
    private func watch() {
        source?.cancel()
        source = nil
        guard let url else { return }
        let descriptor = open(url.path, O_EVTONLY)
        guard descriptor >= 0 else { return }
        let watcher = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: descriptor, eventMask: [.write, .rename, .delete, .extend], queue: .main)
        watcher.setEventHandler { [weak self] in
            MainActor.assumeIsolated {
                guard let self, let live = self.source else { return }
                let replaced = !live.data.isDisjoint(with: [.rename, .delete])
                self.read()
                if replaced { self.rewatchSoon() }
            }
        }
        watcher.setCancelHandler { close(descriptor) }
        self.source = watcher
        watcher.resume()
    }

    private func rewatchSoon() {
        rewatch?.cancel()
        rewatch = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 300_000_000)
            guard !Task.isCancelled, let self else { return }
            self.read()
            self.watch()
        }
    }

    /// The open panel, pointed at the table: the person picks the one
    /// file and JR-Bar keeps a read-only bookmark to it. With Full Disk
    /// Access already granted the file reads as it is, so the click
    /// keeps a plain bookmark to it and no panel opens. nil when the
    /// panel was cancelled or the pick could not be kept.
    static func requestGrant() -> Data? {
        let table = MenuBarLayoutTable.defaultURL
        if (try? Data(contentsOf: table)) != nil,
           let plain = try? table.bookmarkData(options: [], includingResourceValuesForKeys: nil, relativeTo: nil) {
            log.notice("layout table: read through Full Disk Access — no panel")
            return plain
        }
        let panel = NSOpenPanel()
        panel.message = "Select com.apple.MenuBar.plist so JR-Bar can read your menu bar's order. JR-Bar only reads it."
        panel.prompt = "Grant Access"
        panel.directoryURL = MenuBarLayoutTable.defaultURL.deletingLastPathComponent()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.showsHiddenFiles = true
        panel.allowedContentTypes = [.propertyList]
        NSApp.activate()
        guard panel.runModal() == .OK, let url = panel.url else { return nil }
        if let scoped = try? url.bookmarkData(options: [.withSecurityScope, .securityScopeAllowOnlyReadAccess],
                                              includingResourceValuesForKeys: nil, relativeTo: nil) {
            return scoped
        }
        return try? url.bookmarkData(options: [], includingResourceValuesForKeys: nil, relativeTo: nil)
    }
}
