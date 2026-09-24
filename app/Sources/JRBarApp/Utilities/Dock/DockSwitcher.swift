import AppKit
import ApplicationServices
import JRBarCore
import OSLog
import ScreenCaptureKit
import SwiftUI

// MARK: - The list (pure, tested)

/// One row in the ⌥⇥ switcher: a real window of a real app — its AX
/// handle for the raise, its CGWindow id for a later thumbnail, and
/// the display bits the card draws.
struct SwitcherItem: Identifiable {
    /// Stable identity across a rebuild is the CGWindow number when
    /// the window is on-screen, else the AX index namespaced by pid.
    let id: String
    let pid: pid_t
    let appName: String
    let icon: NSImage?
    let title: String
    let minimized: Bool
    let onScreen: Bool
    /// The AX window the commit raises; nil is a CGWindow-only row —
    /// activating the app is all that can reach it.
    let element: AXUIElement?
    /// The CGWindow number when on-screen — the thumbnail key.
    let windowID: CGWindowID?
    /// The window's frame in Quartz space (CG bounds, else the AX
    /// frame) — the "only this display" filter reads it.
    var frame: CGRect? = nil
    /// The Dock tile's `AXStatusLabel` — the unread count the ⌘⇥ card
    /// draws on the icon like Witch's strip. nil when there is none.
    var badge: String? = nil
    /// The agent session this window hosts — set only when
    /// `DockAgentMatch` found an exclusive pair (an app card takes the
    /// most urgent session its app hosts). Drives the "needs you" lane,
    /// the provider mark and the type-ahead's session search.
    var agent: DockAgentMark? = nil
}

/// One window out of `CGWindowListCopyWindowInfo`, already filtered to
/// layer 0 and a real app. `onScreen` splits the on-screen rows the
/// z-order ranks from the off-screen ones (minimized, other Spaces)
/// that list without a recency.
struct SwitcherWindowRow {
    let pid: pid_t
    let windowID: CGWindowID
    let title: String
    let bounds: CGRect
    var onScreen: Bool = true
}

/// The switcher's memory of apps that didn't answer Accessibility: one
/// hung app cost every ⌥⇥ its half-second AX timeout. An app that times
/// out is skipped for `backoff` — its windows still list from the window
/// server, just without an AX handle (a commit activates the app) — and
/// asked again after, so a busy moment isn't a permanent exile.
struct DockAXBackoff {
    static let backoff: TimeInterval = 10
    private(set) var until: [pid_t: TimeInterval] = [:]

    func skips(_ pid: pid_t, now: TimeInterval) -> Bool {
        (until[pid] ?? 0) > now
    }

    mutating func note(_ pid: pid_t, unresponsive: Bool, now: TimeInterval) {
        if unresponsive { until[pid] = now + Self.backoff } else { until[pid] = nil }
    }
}

enum DockSwitcherList {
    /// The z-order `CGWindowList` reports (front to back) cut to
    /// normal windows of regular apps — the switcher's recency.
    static func onScreenRows(
        running: [pid_t] = NSWorkspace.shared.runningApplications
            .filter { $0.activationPolicy == .regular && !$0.isTerminated }
            .map(\.processIdentifier)
    ) -> [SwitcherWindowRow] {
        var owners = Set(running)
        // The switcher is not a target of itself.
        owners.remove(ProcessInfo.processInfo.processIdentifier)
        let options: CGWindowListOption = [.optionOnScreenOnly, .excludeDesktopElements]
        guard let info = CGWindowListCopyWindowInfo(options, kCGNullWindowID) as? [[String: Any]]
        else { return [] }
        return info.compactMap { dict in
            guard let pid = dict[kCGWindowOwnerPID as String] as? Int32,
                  owners.contains(pid),
                  let wid = dict[kCGWindowNumber as String] as? CGWindowID,
                  (dict[kCGWindowLayer as String] as? Int) == 0,
                  let boundsDict = dict[kCGWindowBounds as String] as? [String: Any],
                  let bounds = CGRect(dictionaryRepresentation: boundsDict as CFDictionary),
                  bounds.width >= 40, bounds.height >= 40
            else { return nil }
            return SwitcherWindowRow(pid: pid, windowID: wid,
                                     title: dict[kCGWindowName as String] as? String ?? "",
                                     bounds: bounds, onScreen: true)
        }
    }

    /// Minimized windows of regular apps — `.optionOnScreenOnly` hides
    /// them, so an app whose windows are all in the Dock never made the
    /// strip at all (AltTab/Witch list it). One extra window-list pass;
    /// no AX walk needed.
    static func offScreenRows(
        running: [pid_t] = NSWorkspace.shared.runningApplications
            .filter { $0.activationPolicy == .regular && !$0.isTerminated }
            .map(\.processIdentifier)
    ) -> [SwitcherWindowRow] {
        var owners = Set(running)
        owners.remove(ProcessInfo.processInfo.processIdentifier)
        guard let info = CGWindowListCopyWindowInfo([.optionAll, .excludeDesktopElements],
                                                    kCGNullWindowID) as? [[String: Any]]
        else { return [] }
        return info.compactMap { dict in
            guard let pid = dict[kCGWindowOwnerPID as String] as? Int32,
                  owners.contains(pid),
                  let wid = dict[kCGWindowNumber as String] as? CGWindowID,
                  (dict[kCGWindowLayer as String] as? Int) == 0,
                  (dict[kCGWindowIsOnscreen as String] as? NSNumber)?.boolValue == false,
                  let boundsDict = dict[kCGWindowBounds as String] as? [String: Any],
                  let bounds = CGRect(dictionaryRepresentation: boundsDict as CFDictionary),
                  bounds.width >= 40, bounds.height >= 40
            else { return nil }
            return SwitcherWindowRow(pid: pid, windowID: wid,
                                     title: dict[kCGWindowName as String] as? String ?? "",
                                     bounds: bounds, onScreen: false)
        }
    }

    /// Merge the z-ordered CGWindow rows with each app's AX windows.
    /// On-screen windows lead in recency order, matched to their AX
    /// element by native ID, with unique frame/title fallbacks;
    /// off-screen rows (minimized) and AX-only windows — other Spaces —
    /// follow grouped by their app's best z position.
    static func order(rows: [SwitcherWindowRow],
                      offRows: [SwitcherWindowRow] = [],
                      windowsForApp: (pid_t) -> [DockPreviewWindow],
                      appName: (pid_t) -> String,
                      icon: (pid_t) -> NSImage?) -> [SwitcherItem] {
        var items: [SwitcherItem] = []
        /// pid → AX windows still unmatched. Ambiguous metadata stays
        /// in this pool so each real AX window can appear without a guessed image.
        var unmatched: [pid_t: [DockPreviewWindow]] = [:]
        var appRank: [pid_t: Int] = [:]

        func axWindows(for pid: pid_t) -> [DockPreviewWindow] {
            if let cached = unmatched[pid] { return cached }
            let list = windowsForApp(pid)
            unmatched[pid] = list
            return list
        }

        for (rank, row) in rows.enumerated() {
            if appRank[row.pid] == nil { appRank[row.pid] = rank }
            let candidates = axWindows(for: row.pid)
            let resolution = matchResult(row: row, in: candidates)
            if case .matched(let index) = resolution {
                let hit = candidates[index]
                unmatched[row.pid]?.removeAll { $0.id == hit.id }
                items.append(SwitcherItem(
                    id: "w\(row.windowID)", pid: row.pid,
                    appName: appName(row.pid), icon: icon(row.pid),
                    title: hit.title, minimized: false, onScreen: true,
                    element: hit.element, windowID: row.windowID, frame: row.bounds))
            } else if resolution != .ambiguous {
                items.append(SwitcherItem(
                    id: "w\(row.windowID)", pid: row.pid,
                    appName: appName(row.pid), icon: icon(row.pid),
                    title: row.title.isEmpty ? appName(row.pid) : row.title,
                    minimized: false, onScreen: true,
                    element: nil, windowID: row.windowID, frame: row.bounds))
            }
        }

        // Off-screen rows — minimized windows — app by app, matched to
        // the same unmatched AX pool so a row that finds its element
        // takes it (and the AX leftover below skips it).
        var offByPID: [pid_t: [SwitcherWindowRow]] = [:]
        for row in offRows { offByPID[row.pid, default: []].append(row) }

        // Off-screen and minimized windows, app by app in recency.
        let pids = Set(unmatched.keys).union(offByPID.keys)
            .sorted { (appRank[$0] ?? .max) < (appRank[$1] ?? .max) }
        for pid in pids {
            // An app with nothing on-screen never touched the pool —
            // fetch now or every minimized row lands elementless and
            // commit can only activate, never restore its window.
            var leftover = unmatched[pid] ?? axWindows(for: pid)
            for row in offByPID[pid] ?? [] {
                let resolution = matchResult(row: row, in: leftover)
                if resolution == .ambiguous { continue }
                let hit: DockPreviewWindow?
                if case .matched(let index) = resolution { hit = leftover[index] } else { hit = nil }
                if let hit { leftover.removeAll { $0.id == hit.id } }
                items.append(SwitcherItem(
                    id: "w\(row.windowID)", pid: pid,
                    appName: appName(pid), icon: icon(pid),
                    title: hit?.title ?? (row.title.isEmpty ? appName(pid) : row.title),
                    minimized: hit?.minimized ?? true, onScreen: false,
                    element: hit?.element, windowID: row.windowID, frame: row.bounds))
            }
            for window in leftover {
                items.append(SwitcherItem(
                    id: "a\(pid)-\(window.id)", pid: pid,
                    appName: appName(pid), icon: icon(pid),
                    title: window.title, minimized: window.minimized,
                    onScreen: false, element: window.element, windowID: window.windowID,
                    frame: window.frame))
            }
        }
        return items
    }

    private static func matchResult(row: SwitcherWindowRow,
                                    in windows: [DockPreviewWindow]) -> DockEnhanceMath.WindowMatch {
        DockEnhanceMath.matchResult(
            scFrame: row.bounds, scTitle: row.title,
            rows: windows.map { (frame: $0.frame, title: $0.title) },
            scWindowID: row.windowID, rowWindowIDs: windows.map(\.windowID))
    }

    static func match(row: SwitcherWindowRow,
                      in windows: [DockPreviewWindow]) -> DockPreviewWindow? {
        guard case .matched(let index) = matchResult(row: row, in: windows) else { return nil }
        return windows[index]
    }

    // MARK: Reading

    /// One app whose AX windows a build reads, and the stamp its rows'
    /// ids carry (`AppleDockReader.nextStamp`).
    struct WindowRead: Sendable {
        let pid: pid_t
        let stamp: Int
    }

    /// What `readWindows` brings back: each app's rows, and the apps that
    /// let the half-second timeout lapse. The AX handles cross from the
    /// reading threads to main — sound, as `DockAXElement` explains; the
    /// rows carry no thumbnail yet.
    struct WindowReadings: @unchecked Sendable {
        var windows: [pid_t: [DockPreviewWindow]] = [:]
        var unresponsive: Set<pid_t> = []
    }

    /// Every app's AX window list, read side by side — one app element
    /// each, the reader's own half-second timeout — so a build costs
    /// about its slowest app instead of the sum of them all (measured
    /// 160–256 ms in a row for seven windowed apps). Each read gets its
    /// own thread: `concurrentPerform` runs its iterations one after
    /// another when the pool is busy, and a blocked AX read would then
    /// cost the whole sum again. The caller waits; `order` matches the
    /// rows once every list is in.
    static func readWindows(
        _ reads: [WindowRead],
        reader: @escaping @Sendable (pid_t, Int) -> (windows: [DockPreviewWindow], unresponsive: Bool)
            = AppleDockReader.windowsReading(pid:stamp:)
    ) -> WindowReadings {
        final class Gathered: @unchecked Sendable {
            let lock = NSLock()
            var readings = WindowReadings()
        }
        let gathered = Gathered()
        let done = DispatchGroup()
        for read in reads {
            done.enter()
            let thread = Thread {
                let reading = reader(read.pid, read.stamp)
                gathered.lock.withLock {
                    gathered.readings.windows[read.pid] = reading.windows
                    if reading.unresponsive { gathered.readings.unresponsive.insert(read.pid) }
                }
                done.leave()
            }
            thread.qualityOfService = .userInteractive
            thread.start()
        }
        done.wait()
        return gathered.readings
    }

    /// The unread counts on the Dock's app tiles — bundle path → label.
    static func badges(of tiles: [DockAXItem]) -> [String: String] {
        var badges: [String: String] = [:]
        for tile in tiles where tile.kind == .app {
            if let badge = tile.badge, let path = tile.url?.path {
                badges[path] = badge
            }
        }
        return badges
    }

    /// The owning pid of a minimized-window Dock tile: the tile carries
    /// no `AXURL`, so its title is matched against the off-screen
    /// window list — exactly one claimant pid is trusted; zero or
    /// several means the card stays tile-backed rather than guessing.
    ///
    /// A title two apps share ("Untitled") is narrowed before giving up:
    /// the off-screen list also holds windows parked on other Spaces,
    /// which have no Dock tile. With `axWindows`, a claimant only stands
    /// when its app's own AX list holds that exact row (native id, else
    /// an unambiguous frame + title) minimized — the one window a tile
    /// can be. Still several after that is real ambiguity.
    static func minimizedOwnerPID(title: String, rows: [SwitcherWindowRow],
                                  axWindows: ((pid_t) -> [DockPreviewWindow])? = nil) -> pid_t? {
        let claiming = rows.filter { $0.title == title }
        let claimants = Set(claiming.map(\.pid))
        if claimants.count <= 1 { return claimants.first }
        guard let axWindows else { return nil }
        var listed: [pid_t: [DockPreviewWindow]] = [:]
        let minimized = Set(claiming.filter { row in
            let windows = listed[row.pid] ?? axWindows(row.pid)
            listed[row.pid] = windows
            return match(row: row, in: windows)?.minimized == true
        }.map(\.pid))
        return minimized.count == 1 ? minimized.first : nil
    }

    // MARK: Agents

    /// Stamp each window row with the agent session it exclusively
    /// hosts. Only rows of a session's host app are candidates, so a
    /// Safari tab titled like a session never claims it. The rows are
    /// the app's whole set, before any scope or display filter: a
    /// window's claim is judged against every window it competes with.
    /// `soleAppWindows` is `DockAgentMatch.match`'s.
    static func annotate(_ items: [SwitcherItem], marks: [DockAgentMark],
                         bundleID: (pid_t) -> String?,
                         soleAppWindows: Bool = true) -> [SwitcherItem] {
        guard !marks.isEmpty else { return items }
        let hosts = marks.reduce(into: Set<String>()) { $0.formUnion($1.hosts) }
        let candidates = items.compactMap { item -> DockAgentMatch.Candidate? in
            guard let bundle = bundleID(item.pid), hosts.contains(bundle) else { return nil }
            return .init(key: item.id, bundleID: bundle, title: item.title)
        }
        let map = DockAgentMatch.match(marks: marks, candidates: candidates,
                                       soleAppWindows: soleAppWindows)
        return items.map { item in
            var item = item
            item.agent = map[item.id]
            return item
        }
    }

    /// An app card's mark: the most urgent live session its app hosts —
    /// no window match needed, the app is the whole card.
    static func appMark(bundleID: String?, marks: [DockAgentMark]) -> DockAgentMark? {
        guard let bundleID else { return nil }
        return marks.filter { $0.hosts.contains(bundleID) && $0.isLive }
            .min { $0.urgency < $1.urgency }
    }

    /// The "needs you" lane: windows whose agent waits on you lead the
    /// strip, longest-waiting first, and the pick starts on the first of
    /// them — ⌥⇥ once lands on the blocked agent. The frontmost window
    /// never joins the lane (you are already there); with no lane the
    /// strip is plain recency and the pick starts on the second window.
    static func needsYouFirst(_ items: [SwitcherItem]) -> (items: [SwitcherItem], selection: Int) {
        let plain = (items, items.count > 1 ? 1 : 0)
        guard items.count > 1 else { return plain }
        let lane = items.dropFirst().enumerated()
            .filter { $0.element.agent?.isWaiting == true }
            .sorted { lhs, rhs in
                let a = lhs.element.agent?.ask?.openedAt ?? .infinity
                let b = rhs.element.agent?.ask?.openedAt ?? .infinity
                return a != b ? a < b : lhs.offset < rhs.offset
            }
            .map(\.element)
        guard !lane.isEmpty else { return plain }
        let laneIDs = Set(lane.map(\.id))
        return (lane + items.filter { !laneIDs.contains($0.id) }, 0)
    }

    /// The live session a ⌘-verb on `item` would kill, if any: ⌘W on a
    /// window hosting a working or waiting agent, ⌘Q on any window or
    /// card of an app hosting one (quitting Ghostty ends every session
    /// in it). Minimize, hide and full screen harm nothing.
    static func guardMark(verb: String, item: SwitcherItem, marks: [DockAgentMark],
                          bundleID: String?) -> DockAgentMark? {
        switch verb {
        case "w":
            return item.agent.flatMap { $0.isLive ? $0 : nil }
        case "q":
            if let agent = item.agent, agent.isLive { return agent }
            return appMark(bundleID: bundleID, marks: marks)
        default:
            return nil
        }
    }

    // MARK: Scope

    /// "Only this display": rows whose window sits on `display` (a
    /// Quartz-space screen frame, judged by the window's centre). A
    /// minimized window belongs to no display and stays, as does a row
    /// with no frame to judge — the filter narrows, it never hides
    /// what it can't place.
    static func onDisplay(_ items: [SwitcherItem], display: CGRect) -> [SwitcherItem] {
        items.filter { item in
            guard !item.minimized, let frame = item.frame else { return true }
            return display.contains(CGPoint(x: frame.midX, y: frame.midY))
        }
    }

    /// What a live strip watches for between rebuilds: which windows
    /// exist and what each agent is doing — cheap to read every second
    /// (two window-list passes, no AX), and titles are left out because
    /// a terminal's spinner retitles it several times a second.
    static func signature(rows: [SwitcherWindowRow], offRows: [SwitcherWindowRow],
                          marks: [DockAgentMark]) -> Set<String> {
        var parts = Set((rows + offRows).map { "w\($0.windowID)" })
        for mark in marks { parts.insert("s\(mark.sessionID):\(mark.activity.rawValue)") }
        return parts
    }

    /// The verb row shown while ⌘ is held — the keys the strip answers
    /// right now, so nobody has to read docs to find them.
    static func verbHints(appMode: Bool, drilled: Bool) -> String {
        if appMode { return "Q quit · H hide · ↓ windows · / search" }
        if drilled { return "W close · M minimize · F full screen · Q quit · H hide · ↑ apps" }
        return "W close · M minimize · F full screen · Q quit · H hide · ←→↑↓ tile"
    }

    /// The window a plain ⌘⇥ commit restores: when every window the app
    /// has is minimized, the first (most recent) one — activation alone
    /// would land on no window at all. nil when any window is up.
    static func restoreTarget(_ windows: [DockPreviewWindow]) -> DockPreviewWindow? {
        guard let first = windows.first, windows.allSatisfy(\.minimized) else { return nil }
        return first
    }

    /// A drilled app's windows: the waiting agent's window first, so
    /// ⌘⇥ ↓ release lands on it, the rest in their recency.
    static func waitingFirst(_ items: [SwitcherItem]) -> [SwitcherItem] {
        let waiting = items.filter { $0.agent?.isWaiting == true }
        guard !waiting.isEmpty else { return items }
        return waiting + items.filter { $0.agent?.isWaiting != true }
    }
}

// MARK: - The model (pure, tested)

/// The open switcher's state: the row order and the highlighted
/// index. Selection starts on the *second* window — ⌥⇥ means "back to
/// what I was in" — and wraps in both directions.
struct SwitcherModel {
    /// The unfiltered list — the type-ahead always narrows from this.
    /// The unfiltered set — the strip's thumbnail pass reads it so a
    /// typed filter can't drop stills already captured.
    private(set) var allItems: [SwitcherItem] = []
    private(set) var items: [SwitcherItem] = []
    private(set) var selection = 0
    /// The type-ahead buffer: letters narrow the strip to windows and
    /// apps whose names carry them. Empty means every item shows.
    private(set) var query = ""
    /// What short queries last landed on — the learned pick leads (and
    /// takes the selection) when the same query is typed again.
    var learned: [DockLearnedPick] = []

    /// `selection` overrides the second-window start — the "needs you"
    /// lane opens on its first entry.
    mutating func open(with items: [SwitcherItem], selection: Int? = nil) {
        allItems = items
        self.items = items
        query = ""
        let start = selection ?? (items.count > 1 ? 1 : 0)
        self.selection = items.indices.contains(start) ? start : 0
    }

    /// A verb's aftermath: the list rebuilds under the strip (a closed
    /// window leaves, a quit app vanishes) while the selection keeps
    /// its row when it survives.
    mutating func refresh(with items: [SwitcherItem]) {
        let keep = selected
        allItems = items
        self.items = Self.learnedFirst(Self.ranked(items, query: query), query: query, learned: learned)
        if let keep, let index = self.items.firstIndex(where: { $0.id == keep.id }) {
            selection = index
        } else {
            selection = min(selection, max(0, self.items.count - 1))
        }
    }

    /// Badges that land after the strip shows: every row takes its
    /// app's label; the order, the filter and the pick stay.
    mutating func setBadges(_ badge: (SwitcherItem) -> String?) {
        func badged(_ rows: [SwitcherItem]) -> [SwitcherItem] {
            rows.map { row in
                var row = row
                row.badge = badge(row)
                return row
            }
        }
        allItems = badged(allItems)
        items = badged(items)
    }

    mutating func advance(by step: Int) {
        guard !items.isEmpty else { return }
        let count = items.count
        selection = ((selection + step) % count + count) % count
    }

    mutating func select(index: Int) {
        guard items.indices.contains(index) else { return }
        selection = index
    }

    /// A typed character joins the filter; the selection keeps the
    /// row it was on when that row still matches.
    mutating func type(_ char: String) {
        query.append(char)
        refilter()
    }

    mutating func backspace() {
        guard !query.isEmpty else { return }
        query.removeLast()
        refilter()
    }

    private mutating func refilter() {
        let keep = selected
        items = Self.learnedFirst(Self.ranked(allItems, query: query), query: query, learned: learned)
        if let first = items.first, Self.isLearnedPick(first, query: query, learned: learned) {
            // The query was taught: its window leads and is the pick, so
            // "g" then release lands where it did last time.
            selection = 0
        } else if let keep, let index = items.firstIndex(where: { $0.id == keep.id }) {
            selection = index
        } else {
            selection = items.isEmpty ? 0 : min(selection, items.count - 1)
        }
    }

    /// The item's rank under `query`: the window title at full score,
    /// the app name halved like the command bar's detail fallback so
    /// a real title hit always beats an app-only one. A window hosting
    /// an agent is also found by what the agent is working on — the
    /// session's label and its directory at full weight, the provider's
    /// name at half — so "jrbar" or "codex" lands the terminal titled
    /// "zsh". nil = no match.
    static func score(_ item: SwitcherItem, query: String) -> Int? {
        let title = MenuBarCommands.score(query, item.title)
        let app = MenuBarCommands.score(query, item.appName).map { $0 / 2 }
        var scores = [title, app]
        if let agent = item.agent {
            scores.append(MenuBarCommands.score(query, agent.label))
            scores.append(agent.cwdTail.flatMap { MenuBarCommands.score(query, $0) })
            scores.append(MenuBarCommands.score(query, agent.providerName).map { $0 / 2 })
        }
        return scores.compactMap { $0 }.max()
    }

    /// The query prefix that narrows the strip to windows whose agent
    /// waits on you — a lone "!" is the whole "needs you" lane.
    static let waitingFilter: Character = "!"

    // MARK: Learning (Contexts' Fast Search)

    /// Only short queries are learned — "g", "gh", "code" — the ones a
    /// hand types to jump, not the ones that spell a title out.
    static let learnLimit = 4
    /// How many queries are remembered, most recent first.
    static let learnCap = 48

    /// The query as it is remembered: lowercased, short, never the
    /// waiting filter. nil means this query isn't one to learn.
    static func learnQuery(_ query: String) -> String? {
        let q = query.lowercased()
        guard !q.isEmpty, q.count <= learnLimit, q.first != waitingFilter else { return nil }
        return q
    }

    /// A window as a learned pick names it: the app and a stem of the
    /// title — enough to tell two Ghostty windows apart, never a whole
    /// path-long title.
    static func learnKey(_ item: SwitcherItem) -> String {
        "\(item.appName)\u{1F}\(item.title.prefix(40))"
    }

    static func learnedPick(for query: String, in learned: [DockLearnedPick]) -> String? {
        guard let key = learnQuery(query) else { return nil }
        return learned.first { $0.query == key }?.pick
    }

    static func learnedApp(for query: String, in learned: [DockLearnedPick]) -> String? {
        learnedPick(for: query, in: learned)?.split(separator: "\u{1F}", maxSplits: 1).first.map(String.init)
    }

    /// Whether `item` is what `query` was taught — the exact window, or
    /// (its title changed since) a window of the same app.
    static func isLearnedPick(_ item: SwitcherItem, query: String, learned: [DockLearnedPick]) -> Bool {
        guard let pick = learnedPick(for: query, in: learned) else { return false }
        return learnKey(item) == pick || item.appName == learnedApp(for: query, in: learned)
    }

    /// The ranked matches with the query's learned pick moved to the
    /// front: the exact window when it's still there, else a window of
    /// the same app (a terminal retitled itself since). Only among
    /// what the query already matched — learning reorders, never adds.
    static func learnedFirst(_ ranked: [SwitcherItem], query: String,
                             learned: [DockLearnedPick]) -> [SwitcherItem] {
        guard let pick = learnedPick(for: query, in: learned) else { return ranked }
        let app = learnedApp(for: query, in: learned)
        guard let index = ranked.firstIndex(where: { learnKey($0) == pick })
                ?? ranked.firstIndex(where: { $0.appName == app }),
              index > 0 else { return ranked }
        var out = ranked
        out.insert(out.remove(at: index), at: 0)
        return out
    }

    /// The list after a commit on `item` under `query`: that pick first,
    /// the query's older pick dropped, capped. nil when the query isn't
    /// one to learn or the list already says exactly this.
    static func remembering(_ query: String, pick item: SwitcherItem,
                            in list: [DockLearnedPick]) -> [DockLearnedPick]? {
        guard let key = learnQuery(query) else { return nil }
        let entry = DockLearnedPick(query: key, pick: learnKey(item))
        guard list.first != entry else { return nil }
        return Array(([entry] + list.filter { $0.query != key }).prefix(learnCap))
    }

    /// The filtered set, best score first — Witch's ranked type-ahead
    /// over the plain subsequence filter. Ties keep the incoming
    /// order, which is recency: equal matches still read most-recent
    /// first, so ranking never invents a new shuffle.
    static func ranked(_ items: [SwitcherItem], query: String) -> [SwitcherItem] {
        guard !query.isEmpty else { return items }
        var query = query
        var pool = items
        if query.first == waitingFilter {
            query.removeFirst()
            pool = items.filter { $0.agent?.isWaiting == true }
        }
        guard !query.isEmpty else { return pool }
        // Typed and spelled out: the one-line tuple chain cost the type
        // checker several seconds here and timed out on a slower runner.
        var scored: [(item: SwitcherItem, score: Int, index: Int)] = []
        for (index, item) in pool.enumerated() {
            if let points = score(item, query: query) { scored.append((item, points, index)) }
        }
        scored.sort { a, b in a.score != b.score ? a.score > b.score : a.index < b.index }
        return scored.map { $0.item }
    }

    var selected: SwitcherItem? {
        items.indices.contains(selection) ? items[selection] : nil
    }
}

// MARK: - The key tap

/// The switcher's chord, ⌥⇥: a session event tap, serviced on a thread
/// of its own (`DockTapThread`), that eats option-Tab while held and
/// commits when option lifts. Tab+option is free (it only types a
/// rare ⇥), so eating it costs the user nothing; every other key
/// passes through untouched. While the switcher is open the tap also
/// drives the arrows/esc/return row.
final class SwitcherKeyTap: @unchecked Sendable {
    var onTab: (_ shifted: Bool) -> Void = { _ in }
    var onCommit: () -> Void = {}
    var onCancel: () -> Void = {}
    var onArrow: (_ delta: Int) -> Void = { _ in }
    /// Type-ahead while the strip is up: a character narrows it,
    /// delete widens it back.
    var onType: (_ char: String) -> Void = { _ in }
    var onBackspace: () -> Void = {}
    /// A ⌘-modified verb on the highlighted row: q quits the app,
    /// w closes the window, m minimizes, h hides, f toggles
    /// fullscreen — the stock ⌘⇥/AltTab verb row.
    var onVerb: (_ char: String) -> Void = { _ in }
    /// The ⌘⇥ app switcher — the same tap's second chord, a level per
    /// app and a commit when command lifts. Off by default; eating the
    /// system's own chord is a bigger promise than ⌥⇥.
    var onCmdTab: (_ shifted: Bool) -> Void = { _ in }
    var onCmdCommit: () -> Void = {}
    /// Witch's drill-down: ↓ on an app card opens that app's windows
    /// under the same strip — command's release then commits the window.
    var onDrill: () -> Void = {}
    /// ` under the ⌥⇥ strip — the one-app scope toggle.
    var onScope: () -> Void = {}
    /// ↑ on a drilled ⌘⇥ strip — back out to the app row.
    var onUndrill: () -> Void = {}
    /// ⌘/ or ⌘S on the ⌘⇥ strip: search pins it open past ⌘'s release.
    var onLatch: () -> Void = {}
    /// ⌥⌘ + an arrow on the ⌥⇥ strip: tile the pick into that half.
    var onTile: (_ code: Int64) -> Void = { _ in }
    /// ⌘ went down or up while a strip is open — the verb hints' cue.
    var onCommandHeld: (_ held: Bool) -> Void = { _ in }
    /// ⌘-right-click on a tile quick quit can act on (Quartz point,
    /// force with ⌥): eaten here so Apple's Dock menu never pops over
    /// the quit.
    var onQuickQuit: (_ point: CGPoint, _ force: Bool) -> Void = { _, _ in }
    /// ⌥` with no strip up and the card's opt-in on: preview the front
    /// app's windows on its Dock tile.
    var onFrontPreview: () -> Void = {}
    /// A preview action key — a letter the floating preview asked for
    /// right now (W/M/F once a card is walked, Space over a player), or
    /// ⌥← / ⌥→ as "tile left" / "tile right".
    var onPreviewAction: (_ action: String) -> Void = { _ in }
    /// The preview panel's keys while its flag is set — bare Esc and
    /// arrows, and Return once a card is walked. Those are eaten: the
    /// panel can't take key status, so a pass-through would land them
    /// in the front app too. A modified arrow is the front app's.
    var onPreviewKey: (_ code: Int64) -> Void = { _ in }
    /// Set from the main actor whenever the panel opens or closes;
    /// read on the tap thread.
    private let lock = NSLock()
    nonisolated(unsafe) private var open = false
    /// Which chord opened the panel — option or command — so the right
    /// modifier's release commits. `open` stays the shared flag.
    nonisolated(unsafe) private var cmdOpen = false
    /// The card's switch, mirrored for the tap thread: off, option-Tab
    /// passes through untouched — some apps bind it themselves.
    nonisolated(unsafe) private var enabled = true
    /// The ⌘⇥ switch, mirrored the same way; off means command-Tab
    /// reaches the system untouched.
    nonisolated(unsafe) private var cmdEnabled = false
    /// The front-app preview chord's opt-in, mirrored; off, ⌥` stays
    /// the dead key it types everywhere.
    nonisolated(unsafe) private var frontEnabled = false
    /// The dock preview's flag — while its panel is up the tap eats
    /// the keys the panel reads.
    nonisolated(unsafe) private var previewOpen = false
    /// The commit arm for each chord: an eaten Tab arms it and the
    /// watched modifier's release fires it. Tracked here, not via
    /// `open`, because `open` lands through an async hop and a quick
    /// tap's release can pass through before it — the unarmed release
    /// is the lost commit that once left the strip eating keystrokes.
    nonisolated(unsafe) private var pendingOptionCommit = false
    nonisolated(unsafe) private var pendingCmdCommit = false
    /// ⌘'s state at the last modifier change — the edge the verb hints
    /// (`onCommandHeld`) follow.
    nonisolated(unsafe) private var prevCmd = false
    /// The ⌘⇥ search latch — set on the tap thread the moment ⌘/ lands,
    /// so a ⌘ release racing the async hop still finds the strip pinned.
    nonisolated(unsafe) private var latched = false

    /// Whether the open strip is pinned for typing (tests read it).
    var isLatched: Bool {
        lock.lock(); defer { lock.unlock() }
        return latched
    }
    /// The Dock tiles quick quit can act on — running apps' tile frames
    /// in Quartz space, mirrored from the preview watcher's cache; empty
    /// while it isn't watching (no quick quit).
    nonisolated(unsafe) private var quitTargets: [CGRect] = []
    /// An eaten ⌘-right-click's up edge is eaten too — the Dock must
    /// never see half a click.
    nonisolated(unsafe) private var eatRightUp = false

    func setQuickQuitTargets(_ targets: [CGRect]) {
        lock.lock(); quitTargets = targets; lock.unlock()
    }

    /// The letters the floating preview wants beyond its arrows — empty
    /// unless a card is walked (W/M/F, and `walkedMarker` for ⌥←/⌥→
    /// tiling and Return) or the pointer rests on a player's row
    /// (Space). Mirrored by the watcher; every other key keeps reaching
    /// the front app.
    nonisolated(unsafe) private var previewChars: Set<String> = []

    func setPreviewChars(_ chars: Set<String>) {
        lock.lock(); previewChars = chars; lock.unlock()
    }

    func setEnabled(_ value: Bool) {
        lock.lock(); enabled = value; lock.unlock()
    }

    func setCmdEnabled(_ value: Bool) {
        lock.lock(); cmdEnabled = value; lock.unlock()
    }

    func setFrontEnabled(_ value: Bool) {
        lock.lock(); frontEnabled = value; lock.unlock()
    }

    /// The tap, under the lock: written by `start`/`stop` on main, read
    /// by the callback's re-enable on the tap's own thread.
    private var tap: CFMachPort?
    /// The thread servicing the tap (`DockTapThread`) — main only.
    private var thread: DockTapThread?

    static let log = Logger(subsystem: "devin.jrbar", category: "switcher")

    func setOpen(_ value: Bool) {
        lock.lock()
        open = value
        latched = false
        if !value { cmdOpen = false; pendingOptionCommit = false; pendingCmdCommit = false }
        lock.unlock()
    }

    /// The ⌘⇥ panel's flag — `open` too, plus which chord to watch.
    func setCmdOpen(_ value: Bool) {
        lock.lock()
        open = value; cmdOpen = value
        latched = false
        if !value { pendingOptionCommit = false; pendingCmdCommit = false }
        lock.unlock()
    }

    /// The preview panel's flag — its keys are the tap's while it's up.
    func setPreviewOpen(_ value: Bool) {
        lock.lock(); previewOpen = value; lock.unlock()
    }

    /// The tap runs on a thread of its own (`DockTapThread`): it is
    /// active, so every key and right click on the Mac waits on its
    /// callback, and on the main run loop that meant waiting on whatever
    /// JR-Bar's main thread was doing. The callback reads the copies
    /// under `lock` and hops to main for everything it acts on.
    func start() {
        guard lock.withLock({ self.tap == nil }) else { return }
        let mask: CGEventMask = (1 << CGEventType.keyDown.rawValue)
            | (1 << CGEventType.flagsChanged.rawValue)
            | (1 << CGEventType.rightMouseDown.rawValue)
            | (1 << CGEventType.rightMouseUp.rawValue)
        guard let created = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap,
                                              options: .defaultTap, eventsOfInterest: mask,
                                              callback: { _, type, event, refcon in
            guard let refcon else { return Unmanaged.passUnretained(event) }
            return Unmanaged<SwitcherKeyTap>.fromOpaque(refcon)
                .takeUnretainedValue().handle(type: type, event: event)
        }, userInfo: Unmanaged.passUnretained(self).toOpaque()) else {
            Self.log.notice("switcher tap unavailable — accessibility permission missing")
            return
        }
        // An active tap nobody services holds every key until the system
        // times it out — never leave one standing.
        guard let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, created, 0) else {
            CFMachPortInvalidate(created)
            Self.log.error("switcher tap has no run loop source — the chords stay the system's")
            return
        }
        lock.withLock { tap = created }
        let thread = DockTapThread(source: source, name: "JR-Bar dock keys")
        thread.start()
        self.thread = thread
        CGEvent.tapEnable(tap: created, enable: true)
    }

    func stop() {
        let tap = lock.withLock { () -> CFMachPort? in
            defer { self.tap = nil }
            return self.tap
        }
        guard let tap else { return }
        CGEvent.tapEnable(tap: tap, enable: false)
        // Once the thread has returned no callback can still hold the
        // tap's unretained pointer to this object.
        thread?.stop()
        thread = nil
        CFMachPortInvalidate(tap)
    }

    /// A tap dropped without `stop` must not leave a callback pointing
    /// at freed memory.
    deinit { stop() }

    /// nil return eats the event; passUnretained hands it on. The event
    /// is the system's: a tap returns the one it was given at +0, and a
    /// passRetained here was a retain nobody released, one leaked event
    /// per key and click on the Mac. Internal for the tests, which drive
    /// it with synthetic CGEvents. Runs on the tap's thread: nothing
    /// here may wait on the main thread.
    func handle(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let tap = lock.withLock({ tap }) { CGEvent.tapEnable(tap: tap, enable: true) }
            return Unmanaged.passUnretained(event)
        }
        lock.lock()
        let isOpen = open, isCmdOpen = cmdOpen
        let isEnabled = enabled, isCmdEnabled = cmdEnabled
        let isPreviewOpen = previewOpen, isFrontEnabled = frontEnabled
        lock.unlock()
        let code = event.getIntegerValueField(.keyboardEventKeycode)
        let flags = event.flags

        if type == .rightMouseDown || type == .rightMouseUp {
            return handleRightMouse(type: type, event: event)
        }

        if type == .keyDown {
            // 48 is Tab. Option alone is the window switcher; command
            // (which the system switcher owns) is eaten only when the
            // app switcher is on — off, ⌘⇥ passes through untouched.
            if code == 48, flags.contains(.maskAlternate),
               !flags.contains(.maskCommand), isEnabled {
                let shifted = flags.contains(.maskShift)
                // Armed here and now: option can lift before main has
                // opened the strip, and that release is still its commit.
                lock.withLock { pendingOptionCommit = true }
                DispatchQueue.main.async { [weak self] in self?.onTab(shifted) }
                return nil
            }
            if code == 48, flags.contains(.maskCommand), isCmdEnabled {
                let shifted = flags.contains(.maskShift)
                // The app strip takes over from a held ⌥⇥ one: command's
                // release commits it, option's no longer does.
                lock.withLock { pendingCmdCommit = true; pendingOptionCommit = false }
                DispatchQueue.main.async { [weak self] in self?.onCmdTab(shifted) }
                return nil
            }
            // ⌥` — the front app's preview, walked from the keyboard.
            // Opt-in: off, it stays the accent key. Never under a strip,
            // where ` is the one-app scope.
            if code == 50, !isOpen, isFrontEnabled, flags.contains(.maskAlternate),
               flags.intersection([.maskCommand, .maskControl, .maskShift]).isEmpty {
                return swallow { self.onFrontPreview() }
            }
            if isOpen, !isCmdOpen, flags.contains(.maskCommand), (123...126).contains(code) {
                // ⌥⌘ + arrow: put the pick in that half of its screen —
                // switch to a window and place it at once.
                return swallow { self.onTile(code) }
            }
            if isOpen {
                switch code {
                case 126:                                       // ↑
                    // Back out of a drilled app to the app row.
                    return swallow { if isCmdOpen { self.onUndrill() } }
                case 123: return swallow { self.onArrow(-1) }   // ←
                case 124: return swallow { self.onArrow(1) }    // →
                case 125: return swallow {                    // ↓
                    // The app strip drills into the pick's windows;
                    // the window strip is one level already.
                    if isCmdOpen { self.onDrill() }
                }
                case 36, 76:
                    return swallow { self.isCmdOpenNow ? self.onCmdCommit() : self.onCommit() }
                case 51: return swallow { self.onBackspace() }  // ⌫
                case 53: return swallow { self.onCancel() }     // esc
                case 50 where !isCmdOpen && !flags.contains(.maskCommand):
                    // ` — narrow to the picked app's windows, or widen
                    // back. Only while the strip is up: ⌥` alone stays
                    // the dead key it types everywhere else.
                    return swallow { self.onScope() }
                default:
                    // ⌘-modified keys are verbs on the highlighted row
                    // (stock ⌘⇥ semantics) — and they never leak to the
                    // front app: the tap owns the keyboard while the
                    // strip is up, so a bare pass-through would fire
                    // ⌘Q on the app being switched *away from*. The
                    // letter is the one the layout types under ⌘.
                    if flags.contains(.maskCommand) {
                        let char = keyboard.character(for: code, command: true)?.lowercased()
                        if let char, Self.verbKeys.contains(char) {
                            return swallow { self.onVerb(char) }
                        }
                        if isCmdOpen, let char, Self.latchKeys.contains(char) {
                            // ⌘/ — the search latch, set here and now:
                            // the ⌘ release may beat the main-thread hop.
                            lock.lock(); latched = true; lock.unlock()
                            return swallow { self.onLatch() }
                        }
                        return nil
                    }
                    // Type-ahead: what the key prints on the user's own
                    // layout, shift included ("!" is the waiting
                    // filter); option is the held chord, not a letter.
                    if !flags.contains(.maskControl),
                       let char = keyboard.character(for: code, shift: flags.contains(.maskShift)) {
                        return swallow { self.onType(char) }
                    }
                    // Anything else — ⌥↑, a function key, a control
                    // chord — is still the strip's: nothing typed while
                    // switching may land in the app being left.
                    return nil
                }
            }
            // The dock preview floats but can't take key status — while
            // it's up the tap owns its keys wherever the pointer sits:
            // a card walk with the pointer parked on the Dock still
            // lands, and nothing leaks into the front app. Only the bare
            // keys are the preview's: ⇧→ selects, ⌘← goes to the line's
            // start and ⌥→ jumps a word in the front app, and Return is
            // the front app's until a card is walked. The strip's own
            // keys are all consumed above, so an open strip keeps
            // precedence.
            if isPreviewOpen {
                lock.lock(); let wanted = previewChars; lock.unlock()
                let walked = wanted.contains(Self.walkedMarker)
                let plain = !flags.contains(.maskCommand) && !flags.contains(.maskControl)
                if plain, !flags.contains(.maskShift), flags.contains(.maskAlternate), walked,
                   code == 123 || code == 124 {
                    return swallow { self.onPreviewAction(code == 123 ? "tile-left" : "tile-right") }
                }
                let bare = flags.intersection([.maskCommand, .maskControl, .maskShift, .maskAlternate]).isEmpty
                if Self.previewKeyCodes.contains(code), bare,
                   walked || !Self.returnKeyCodes.contains(code) {
                    return swallow { self.onPreviewKey(code) }
                }
                // W/M/F and Space bare too: ⇧W types a capital into the
                // front app, it never closes the walked card.
                if bare, !wanted.isEmpty,
                   let char = keyboard.character(for: code)?.lowercased(), wanted.contains(char) {
                    return swallow { self.onPreviewAction(char) }
                }
            }
            return Unmanaged.passUnretained(event)
        }

        guard type == .flagsChanged else { return Unmanaged.passUnretained(event) }
        // ⌘'s edge is tracked on every modifier change, open or not, so
        // the first change after an open compares against the truth.
        let commandDown = flags.contains(.maskCommand)
        let optionDown = flags.contains(.maskAlternate)
        // A release commits the strip that is up or the one its chord's
        // eaten Tab armed: a quick tap's release can reach this thread
        // before main has opened anything, and main's queue is FIFO, so
        // the commit still lands after the open. The arm is spent here.
        lock.lock()
        let commandChanged = commandDown != prevCmd
        prevCmd = commandDown
        let (openNow, cmdOpenNow) = (open, cmdOpen)
        var commitCmd = false, commitOption = false
        if !commandDown, cmdOpenNow || pendingCmdCommit {
            // Command lifted — the app switcher's commit, unless the
            // search latch pinned the strip for typing (↩ commits).
            if !latched { pendingCmdCommit = false; commitCmd = true }
        } else if !optionDown, !cmdOpenNow, !pendingCmdCommit, openNow || pendingOptionCommit {
            // Option lifted — the window switcher's commit,
            // AltTab-style.
            pendingOptionCommit = false
            commitOption = true
        }
        lock.unlock()
        if commandChanged, openNow {
            DispatchQueue.main.async { [weak self] in self?.onCommandHeld(commandDown) }
        }
        if commitCmd {
            DispatchQueue.main.async { [weak self] in self?.onCmdCommit() }
        } else if commitOption {
            DispatchQueue.main.async { [weak self] in self?.onCommit() }
        }
        return Unmanaged.passUnretained(event)
    }

    /// DockDoor's quick quit without Apple's menu flashing over it: a
    /// ⌘-right-click on a running app's tile is consumed (down and its
    /// up) and handed to the quit; every other right click — the air
    /// above the Dock, a folder, the Trash, a window's own — passes
    /// untouched. Nothing is synthesized — a real event is just not
    /// delivered.
    private func handleRightMouse(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        lock.lock()
        let targets = quitTargets
        let eatUp = eatRightUp
        if type == .rightMouseUp { eatRightUp = false }
        lock.unlock()
        if type == .rightMouseUp {
            return eatUp ? nil : Unmanaged.passUnretained(event)
        }
        let point = event.location
        guard event.flags.contains(.maskCommand), targets.contains(where: { $0.contains(point) }) else {
            return Unmanaged.passUnretained(event)
        }
        let force = event.flags.contains(.maskAlternate)
        lock.lock(); eatRightUp = true; lock.unlock()
        DispatchQueue.main.async { [weak self] in self?.onQuickQuit(point, force) }
        return nil
    }

    private var isCmdOpenNow: Bool {
        lock.lock(); defer { lock.unlock() }
        return cmdOpen
    }

    /// The keys the floating dock preview owns, bare — Esc closes it,
    /// the arrows walk its cards, Return raises the pick.
    nonisolated static let previewKeyCodes: Set<Int64> = [53, 123, 124, 125, 126, 36, 76]
    /// Return and keypad Enter — the preview's only once a card is
    /// walked, since with none there is nothing for them to raise.
    nonisolated static let returnKeyCodes: Set<Int64> = [36, 76]
    /// Stands for the walked card in the preview's wanted keys: what
    /// earns Return and ⌥←/⌥→ tiling.
    nonisolated static let walkedMarker = "walked"

    /// The ⌘-verb letters — the row of actions stock ⌘⇥ and AltTab
    /// share. Type-ahead keeps every other key.
    nonisolated static let verbKeys: Set<String> = ["q", "w", "m", "h", "f"]

    /// ⌘/ or ⌘S on the ⌘⇥ strip — Witch's and Contexts' search field.
    nonisolated static let latchKeys: Set<String> = ["/", "s"]

    /// Keycode → character through the user's keyboard layout —
    /// injectable so a test can type through Dvorak or AZERTY.
    var keyboard: DockKeyboardLayout = .shared

    private func swallow(_ action: @escaping @MainActor () -> Void) -> Unmanaged<CGEvent>? {
        DispatchQueue.main.async { Task { @MainActor in action() } }
        return nil
    }
}

// MARK: - The controller

/// ⌥⇥ raises a centered strip of every app's windows in recency
/// order; Tab (or ⇧Tab) walks it, option lifting commits the pick,
/// esc cancels. Owned by `DockUtility` — the dock utility's other
/// half, DockDoor's window switcher — so it keeps running while the
/// hover previews are parked or handed to DockDoor; the preview
/// watcher borrows its key tap.
@MainActor
final class DockSwitcherController {
    static let log = Logger(subsystem: "devin.jrbar", category: "switcher")

    private let tap = SwitcherKeyTap()
    private var panel: DockSwitcherPanel?
    /// Click-away for a latched strip: with no held modifier left to
    /// release, the latch would otherwise keep every keystroke on the
    /// Mac until esc or ↩. A click anywhere off the strip cancels it.
    private let latchWatchers = DockPanelWatchers()
    private(set) var model = SwitcherModel()
    /// Which strip is up — the ⌥⇥ window cards or the ⌘⇥ app row.
    private(set) var appMode = false
    /// The drill-down's mark: set when ↓ turned the ⌘⇥ app row into
    /// that app's window strip, so command's release commits a window
    /// instead of an app.
    private(set) var drilledApp: pid_t?
    /// Settings read — the card's switch decides per open whether the
    /// chord is live.
    var isAllowed: () -> Bool = { true }
    /// The ⌘⇥ switch — off by default, so the system's own switcher
    /// keeps its chord until the card opts in.
    var isCmdAllowed: () -> Bool = { false }
    /// Window stills on the strip — the preview's thumbnail switch
    /// answers for both, since the grant is the same Screen Recording
    /// one and a user who declined it declines it everywhere.
    var thumbsAllowed: () -> Bool = { false }
    /// The preview's off-screen switch: minimized and other-Space
    /// windows only attempt captures when it's on.
    var offscreenAllowed: () -> Bool = { false }
    /// The daemon's live agent sessions, reduced to marks — the Dock
    /// utility wires it to `state.sessions`. Empty means no lane.
    var agentMarks: () -> [DockAgentMark] = { [] }
    /// "Only this display": the ⌥⇥ strip lists the windows on the
    /// pointer's screen (DockDoor 1.37, AltTab's screen filter).
    var thisDisplayOnly: () -> Bool = { false }
    /// The learned type-ahead, read at each open, and its write path —
    /// a commit made under a short query teaches it.
    var learnedPicks: () -> [DockLearnedPick] = { [] }
    var onLearn: (([DockLearnedPick]) -> Void)?
    /// ` while the strip is up narrows it to the picked app's windows
    /// (Contexts' ⌘`); a second ` widens back. nil lists every app.
    private(set) var scopePID: pid_t?
    /// The live strip: a one-second look at the window list (and the
    /// agents) while the panel is up, rebuilding only when it changed —
    /// a window opened with ⌘N elsewhere appears under a held ⌥.
    private var liveTimer: Timer?
    private var liveSignature: Set<String> = []
    private var workspaceObservers: [NSObjectProtocol] = []
    static let liveInterval: TimeInterval = 1
    /// The dock preview's keys while its panel floats — Esc closes,
    /// arrows walk the cards, Return raises the walked one. The tap
    /// eats them bare: the panel can't take key status, so a
    /// pass-through would type them into the front app.
    var onPreviewKey: ((Int64) -> Void)?
    /// Mirrors the preview panel's visibility into the tap — the
    /// enhance controller's show/hide drives it.
    func setPreviewOpen(_ value: Bool) { tap.setPreviewOpen(value) }
    /// The preview watcher's quick quit — the tap eats a ⌘-right-click
    /// inside one of `setQuickQuitTargets`' tiles and hands it here.
    var onQuickQuit: ((CGPoint, Bool) -> Void)?
    /// ⌥` — the watcher previews the front app from its Dock tile.
    var onFrontPreview: (() -> Void)?
    /// The front-app chord's opt-in, read on every settings apply.
    var isFrontAllowed: () -> Bool = { false }
    /// The tiles quick quit can act on (Quartz), mirrored into the tap
    /// by the watcher.
    func setQuickQuitTargets(_ targets: [CGRect]) { tap.setQuickQuitTargets(targets) }
    /// The preview's action keys (W/M/F/Space/⌥-arrow tiling) — what
    /// the watcher wants the tap to eat right now, and where they go.
    var onPreviewAction: ((String) -> Void)?
    func setPreviewChars(_ chars: Set<String>) { tap.setPreviewChars(chars) }
    /// An open can land while the last open's captures still run —
    /// the generation tells a stale async batch from the live strip.
    private var thumbGeneration = 0
    /// The Dock's badges from the preview watcher's tile read while it
    /// is fresh — bundle path → label. nil sends the strip up without
    /// them, and `fillBadges` walks the Dock after it shows.
    var cachedBadges: () -> [String: String]? = { nil }
    /// The badges this strip's cards carry — bundle path → label.
    private var badges: [String: String] = [:]
    /// Bumped by every build and by the close: an AX half that lands
    /// after a newer build, or on a closed strip, is dropped.
    private var listGeneration = 0
    /// The main-side read of the rebuild whose AX half is on the worker.
    private var pendingRead: ListRead?

    private(set) var running = false

    /// The tap can't read a main-actor setting mid-callback — mirror
    /// it into the tap's own flag so a disabled switcher passes ⌥⇥
    /// through instead of eating the chord.
    func syncSettings() {
        tap.setEnabled(isAllowed())
        tap.setCmdEnabled(isCmdAllowed())
        tap.setFrontEnabled(isFrontAllowed())
    }

    func start() {
        guard !running else { return }
        running = true
        tap.onTab = { [weak self] shifted in self?.tab(shifted: shifted) }
        tap.onCommit = { [weak self] in self?.commit() }
        tap.onCancel = { [weak self] in self?.cancel() }
        tap.onArrow = { [weak self] delta in self?.advance(by: delta) }
        tap.onCmdTab = { [weak self] shifted in self?.cmdTab(shifted: shifted) }
        tap.onCmdCommit = { [weak self] in self?.cmdCommit() }
        tap.onDrill = { [weak self] in self?.drill() }
        tap.onType = { [weak self] char in
            self?.model.type(char)
            self?.panel?.present(model: self?.model ?? SwitcherModel())
        }
        tap.onBackspace = { [weak self] in
            self?.model.backspace()
            self?.panel?.present(model: self?.model ?? SwitcherModel())
        }
        tap.onVerb = { [weak self] char in self?.verb(char) }
        tap.onPreviewKey = { [weak self] code in self?.onPreviewKey?(code) }
        tap.onScope = { [weak self] in self?.toggleScope() }
        tap.onUndrill = { [weak self] in self?.undrill() }
        tap.onLatch = { [weak self] in self?.latch() }
        tap.onTile = { [weak self] code in self?.tile(code) }
        tap.onCommandHeld = { [weak self] held in self?.commandHeld(held) }
        tap.onQuickQuit = { [weak self] point, force in self?.onQuickQuit?(point, force) }
        tap.onFrontPreview = { [weak self] in self?.onFrontPreview?() }
        tap.onPreviewAction = { [weak self] action in self?.onPreviewAction?(action) }
        // The layout the type-ahead spells through — read now on the
        // main thread and again on every input-source switch.
        tap.keyboard.startWatching()
        tap.start()
        // An app launching or quitting under a held strip re-lists it
        // at once rather than on the next live tick.
        let center = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.didLaunchApplicationNotification,
                     NSWorkspace.didTerminateApplicationNotification] {
            workspaceObservers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.rebuild() }
            })
        }
    }

    func stop() {
        guard running else { return }
        running = false
        tap.stop()
        for observer in workspaceObservers {
            NSWorkspace.shared.notificationCenter.removeObserver(observer)
        }
        workspaceObservers = []
        cancel()
    }

    /// Start watching for list changes under the open strip.
    private func startLive() {
        liveTimer?.invalidate()
        liveSignature = currentSignature()
        let timer = Timer(timeInterval: Self.liveInterval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.liveTick() }
        }
        timer.tolerance = 0.2
        RunLoop.main.add(timer, forMode: .common)
        liveTimer = timer
    }

    private func stopLive() {
        liveTimer?.invalidate()
        liveTimer = nil
    }

    private func liveTick() {
        guard panel?.isVisible == true else { return stopLive() }
        let signature = currentSignature()
        guard signature != liveSignature else { return }
        liveSignature = signature
        rebuild()
    }

    private func currentSignature() -> Set<String> {
        var signature = DockSwitcherList.signature(rows: DockSwitcherList.onScreenRows(),
                                                   offRows: DockSwitcherList.offScreenRows(),
                                                   marks: agentMarks())
        if appMode {
            for app in NSWorkspace.shared.runningApplications where app.activationPolicy == .regular {
                signature.insert("p\(app.processIdentifier)")
            }
        }
        return signature
    }

    /// ` under the strip: narrow to the picked card's app, or widen back.
    /// The strip is already up, so the re-list's AX half runs on the
    /// worker and the narrowed rows land a beat later.
    private func toggleScope() {
        guard panel?.isVisible == true, !appMode, drilledApp == nil else { return }
        scopePID = scopePID == nil ? model.selected?.pid : nil
        let keep = model.selected?.id
        rebuildLater(windows: true) { [weak self] built in
            guard let self else { return }
            guard !built.isEmpty else { self.scopePID = nil; return }
            let lane = DockSwitcherList.needsYouFirst(built)
            self.model.open(with: lane.items,
                            selection: lane.items.firstIndex { $0.id == keep } ?? lane.selection)
            self.panel?.present(model: self.model)
            self.loadThumbnails()
        }
    }

    /// ↑ on a drilled strip: back to the app row, on the app drilled.
    func undrill() {
        guard panel?.isVisible == true, let pid = drilledApp else { return }
        let apps = buildAppItems()
        guard !apps.isEmpty else { return }
        listGeneration += 1
        drilledApp = nil
        appMode = true
        model.open(with: apps, selection: apps.firstIndex { $0.pid == pid } ?? 0)
        hoverGate.open(at: NSEvent.mouseLocation)
        panel?.setHints(DockSwitcherList.verbHints(appMode: true, drilled: false))
        panel?.present(model: model)
        loadThumbnails()
    }

    /// ⌘/ on the app strip: pinned for typing past ⌘'s release — the
    /// type-ahead ranks the apps, ↩ switches, esc cancels. The tap has
    /// already set its own latch; this is the strip's face for it.
    func latch() {
        guard panel?.isVisible == true else { return }
        panel?.setLatched(true)
        latchWatchers.isInside = { [weak self] in
            self?.panel?.frame.contains(NSEvent.mouseLocation) ?? false
        }
        latchWatchers.onOutside = { [weak self] in
            guard let self, self.tap.isLatched else { return }
            self.cancel()
        }
        latchWatchers.start(escape: false, clickAway: true)
    }

    /// ⌥⌘ + arrow: the pick goes to that half of the screen it's on
    /// (a minimized one stands up first); the strip stays up and
    /// rebuilds around it, like the ⌘-verbs.
    func tile(_ code: Int64) {
        guard let item = model.selected, !appMode else { return }
        let tile: DockTile
        switch code {
        case 123: tile = .leftHalf
        case 124: tile = .rightHalf
        case 126: tile = .topHalf
        default: tile = .bottomHalf
        }
        guard let visible = Self.visibleQuartz(around: item.frame) else { return }
        let frame = DockEnhanceMath.tileFrame(tile, in: visible)
        // The screen is read here; the window's writes (and, for a row
        // on another Space, the walk that finds it) run on the worker.
        let target = SwitcherCommitTarget(item)
        DockAXWorker.run({ () -> Bool in
            guard let element = target.resolve() else { return false }
            let window = target.window(element)
            if target.minimized { _ = AppleDockReader.setMinimized(window, false) }
            _ = AppleDockReader.setFrame(window, frame)
            return true
        }, then: { [weak self] acted in
            if acted { self?.rebuildSoon() }
        })
    }

    /// The visible frame (Quartz space) of the screen a window sits on —
    /// by its centre — else the pointer's screen.
    private static func visibleQuartz(around frame: CGRect?) -> CGRect? {
        let primaryHeight = DockDisplays.primaryHeight()
        let screen = frame.flatMap { frame -> NSScreen? in
            let centre = CGPoint(x: frame.midX, y: primaryHeight - frame.midY)
            return NSScreen.screens.first { $0.frame.contains(centre) }
        } ?? NSScreen.screens.first { $0.frame.contains(NSEvent.mouseLocation) } ?? NSScreen.main
        guard let screen else { return nil }
        // The flip is its own inverse: AppKit → Quartz is the same map.
        return DockEnhanceMath.appKitRect(screen.visibleFrame, mainScreenHeight: primaryHeight)
    }

    /// ⌘ held with a strip up: after a beat the verb row appears (a
    /// quick ⌘⇥ tap never flashes it); ⌘ lifting takes it down.
    private var hintWork: DispatchWorkItem?
    func commandHeld(_ held: Bool) {
        hintWork?.cancel()
        guard held, panel?.isVisible == true else {
            panel?.setHints(nil)
            return
        }
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated {
                guard let self, self.panel?.isVisible == true else { return }
                self.panel?.setHints(DockSwitcherList.verbHints(appMode: self.appMode,
                                                                drilled: self.drilledApp != nil))
            }
        }
        hintWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.hintDelay, execute: work)
    }

    static let hintDelay: TimeInterval = 0.45

    /// The pointer resting on an app card drills into its windows —
    /// Witch's spring-loading, on the pointer only, so a keyboard-only
    /// ⌘⇥ never changes under a held ⌘.
    private var springWork: DispatchWorkItem?
    static let springDelay: TimeInterval = 0.5

    private func armSpring(for index: Int) {
        springWork?.cancel()
        guard appMode else { return }
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated {
                guard let self, self.appMode, self.panel?.isVisible == true,
                      self.model.selection == index else { return }
                self.drill()
            }
        }
        springWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.springDelay, execute: work)
    }

    private func tab(shifted: Bool) {
        guard isAllowed() else { return }
        if panel?.isVisible == true {
            advance(by: shifted ? -1 : 1)
        } else {
            open()
        }
    }

    /// ⌥⇥'s open. The strip must be up before the tap's commit can
    /// reach it, so the list is built here and now — but each app's AX
    /// windows are read side by side, and the badges come from the
    /// preview watcher's fresh tile read or land from the worker after
    /// the strip shows, so the open costs about its slowest app.
    private func open() {
        scopePID = nil
        listGeneration += 1
        let start = ProcessInfo.processInfo.systemUptime
        let fresh = cachedBadges()
        badges = fresh ?? [:]
        let built = buildItems()
        guard !built.isEmpty else { return }
        // A waiting agent's window leads and takes the first pick.
        let lane = DockSwitcherList.needsYouFirst(built)
        model.learned = learnedPicks()
        model.open(with: lane.items, selection: lane.selection)
        appMode = false
        drilledApp = nil
        tap.setOpen(true)
        if panel == nil { panel = DockSwitcherPanel(controller: self) }
        hoverGate.open(at: NSEvent.mouseLocation)
        panel?.present(model: model)
        let milliseconds = (ProcessInfo.processInfo.systemUptime - start) * 1000
        Self.log.debug("switcher open: \(built.count, privacy: .public) windows in \(milliseconds, privacy: .public) ms")
        if fresh == nil { fillBadges() }
        loadThumbnails()
        startLive()
    }

    /// A build's main-side read, before any AX call: the window server's
    /// rows, the running apps, and the apps to ask Accessibility for —
    /// every app a row belongs to, less JR-Bar and the apps `axBackoff`
    /// is resting (a hung app's rows still list from the window server;
    /// only the AX wait is skipped for a while).
    private struct ListRead {
        let rows: [SwitcherWindowRow]
        let offRows: [SwitcherWindowRow]
        let apps: [pid_t: NSRunningApplication]
        let reads: [DockSwitcherList.WindowRead]
        let at: TimeInterval
    }

    private func readList() -> ListRead {
        let rows = DockSwitcherList.onScreenRows()
        let offRows = DockSwitcherList.offScreenRows()
        let apps = Dictionary(uniqueKeysWithValues:
            NSWorkspace.shared.runningApplications.map { ($0.processIdentifier, $0) })
        let now = ProcessInfo.processInfo.systemUptime
        let own = ProcessInfo.processInfo.processIdentifier
        var asked = Set<pid_t>()
        var reads: [DockSwitcherList.WindowRead] = []
        for pid in (rows + offRows).map(\.pid) where asked.insert(pid).inserted {
            guard apps[pid] != nil, pid != own, !axBackoff.skips(pid, now: now) else { continue }
            reads.append(DockSwitcherList.WindowRead(pid: pid, stamp: AppleDockReader.nextStamp()))
        }
        return ListRead(rows: rows, offRows: offRows, apps: apps, reads: reads, at: now)
    }

    /// The ⌥⇥ strip's rows: on-screen windows in z-order, then
    /// minimized and other-Space windows grouped by app — the whole
    /// set a verb can rebuild under the open panel. Here and now, with
    /// the AX reads side by side; a rebuild under an open strip takes
    /// `rebuildLater` instead.
    private func buildItems() -> [SwitcherItem] {
        let read = readList()
        return assemble(read, windows: DockSwitcherList.readWindows(read.reads))
    }

    /// The rows from a read and the AX windows it asked for — matched
    /// only now that every list is in. Apps that let the timeout lapse
    /// rest for `DockAXBackoff.backoff`.
    private func assemble(_ read: ListRead, windows: DockSwitcherList.WindowReadings) -> [SwitcherItem] {
        for ask in read.reads {
            let unresponsive = windows.unresponsive.contains(ask.pid)
            axBackoff.note(ask.pid, unresponsive: unresponsive, now: read.at)
            if unresponsive {
                Self.log.notice("switcher: pid \(ask.pid, privacy: .public) didn't answer AX — skipped for \(DockAXBackoff.backoff, privacy: .public) s")
            }
        }
        let apps = read.apps
        let items = DockSwitcherList.order(
            rows: read.rows,
            offRows: read.offRows,
            windowsForApp: { windows.windows[$0] ?? [] },
            appName: { apps[$0]?.localizedName ?? "App" },
            icon: { apps[$0]?.icon })
        // The Dock's unread badges ride the window cards too — Mail's 3
        // shows on each Mail window, the way the tile shows it.
        let badged = badges.isEmpty ? items : items.map { item in
            var item = item
            item.badge = apps[item.pid]?.bundleURL.flatMap { badges[$0.path] }
            return item
        }
        // Marked before the scope and the display narrow the rows: a
        // window's claim is weighed against all its app's windows.
        var scoped = DockSwitcherList.annotate(badged, marks: agentMarks(),
                                               bundleID: { apps[$0]?.bundleIdentifier })
        if let scopePID { scoped = scoped.filter { $0.pid == scopePID } }
        if thisDisplayOnly(), let display = DockDisplays.pointerDisplayQuartz() {
            scoped = DockSwitcherList.onDisplay(scoped, display: display)
        }
        return scoped
    }

    /// A rebuild under the open strip: the AX half — the window lists
    /// (none for the ⌘⇥ app row, which reads no windows) and the Dock's
    /// badges — runs on `DockAXWorker`, and `apply` gets the rows on
    /// main. Dropped when a newer build, an open or a close came first.
    private func rebuildLater(windows: Bool,
                              apply: @escaping @MainActor @Sendable ([SwitcherItem]) -> Void) {
        listGeneration += 1
        let generation = listGeneration
        let read = windows ? readList() : nil
        pendingRead = read
        let reads = read?.reads ?? []
        let dock = AppleDockReader.dockPID()
        DockAXWorker.run({ () -> (windows: DockSwitcherList.WindowReadings, badges: [String: String]) in
            (DockSwitcherList.readWindows(reads), dock.map(Self.dockBadges(dockPID:)) ?? [:])
        }, then: { [weak self] answer in
            guard let self, self.listGeneration == generation, self.panel?.isVisible == true else { return }
            let landed = self.pendingRead
            self.pendingRead = nil
            self.badges = answer.badges
            apply(landed.map { self.assemble($0, windows: answer.windows) } ?? [])
        })
    }

    /// The badges an open didn't find fresh, walked on `DockAXWorker`
    /// after the strip shows and set on its cards as they land — unless
    /// the strip has closed or been rebuilt (which walks its own) since.
    private func fillBadges() {
        let generation = listGeneration
        guard let dock = AppleDockReader.dockPID() else { return }
        DockAXWorker.run({ Self.dockBadges(dockPID: dock) }, then: { [weak self] badges in
            guard let self, self.listGeneration == generation, self.panel?.isVisible == true,
                  !badges.isEmpty else { return }
            self.badges = badges
            self.model.setBadges { item in
                NSRunningApplication(processIdentifier: item.pid)?.bundleURL.flatMap { badges[$0.path] }
            }
            self.panel?.present(model: self.model)
        })
    }

    /// The unread counts live on the Dock's tiles — one AX walk maps
    /// bundle path → badge, the same walk the previews do per tick.
    /// The worker's: the Dock answers within its own timeout.
    nonisolated static func dockBadges(dockPID: pid_t) -> [String: String] {
        guard let list = AppleDockReader.dockList(pid: dockPID) else { return [:] }
        return DockSwitcherList.badges(of: AppleDockReader.items(list: list))
    }

    // MARK: ⌘⇥ — the app strip

    private func cmdTab(shifted: Bool) {
        guard isCmdAllowed() else { return }
        if panel?.isVisible == true, appMode {
            advance(by: shifted ? -1 : 1)
        } else {
            openApps()
        }
    }

    /// One card per app, recency-ordered: the CGWindow z-order ranks
    /// every app with a visible window, then the rest of the regular
    /// apps follow — ⌘⇥'s whole list, not just the windowed half.
    private func openApps() {
        listGeneration += 1
        let fresh = cachedBadges()
        badges = fresh ?? [:]
        let items = buildAppItems()
        guard !items.isEmpty else { return }
        model.learned = learnedPicks()
        model.open(with: items)
        appMode = true
        drilledApp = nil
        tap.setCmdOpen(true)
        if panel == nil { panel = DockSwitcherPanel(controller: self) }
        hoverGate.open(at: NSEvent.mouseLocation)
        panel?.present(model: model)
        if fresh == nil { fillBadges() }
        loadThumbnails()
        startLive()
        // ⌘ is already down — the verb row follows after the usual beat.
        commandHeld(true)
    }

    private func buildAppItems() -> [SwitcherItem] {
        let apps = NSWorkspace.shared.runningApplications.filter {
            $0.activationPolicy == .regular && !$0.isTerminated
                && $0.processIdentifier != ProcessInfo.processInfo.processIdentifier
        }
        let byPID = Dictionary(uniqueKeysWithValues: apps.map { ($0.processIdentifier, $0) })
        var ordered: [pid_t] = []
        var seen = Set<pid_t>()
        /// Each app's front window — its card's still, so the ⌘⇥ strip
        /// shows which window you'll land on (DockDoor's Cmd+Tab), not
        /// just whose icon.
        var frontWindow: [pid_t: CGWindowID] = [:]
        for row in DockSwitcherList.onScreenRows() where seen.insert(row.pid).inserted {
            ordered.append(row.pid)
            frontWindow[row.pid] = row.windowID
        }
        for app in apps where seen.insert(app.processIdentifier).inserted {
            ordered.append(app.processIdentifier)
        }
        let marks = agentMarks()
        return ordered.compactMap { pid -> SwitcherItem? in
            guard let app = byPID[pid] else { return nil }
            return SwitcherItem(id: "app\(pid)", pid: pid,
                                appName: app.localizedName ?? "App",
                                icon: app.icon,
                                title: app.localizedName ?? "App",
                                minimized: false, onScreen: true,
                                element: nil, windowID: frontWindow[pid],
                                badge: app.bundleURL.flatMap { badges[$0.path] },
                                agent: DockSwitcherList.appMark(bundleID: app.bundleIdentifier,
                                                                marks: marks))
        }
    }

    /// ↓ on an app card: the strip becomes that app's windows —
    /// Witch's drill-down. The tap keeps the command chord, so its
    /// release commits the highlighted window through `cmdCommit`.
    func drill() {
        guard appMode, let app = model.selected else { return }
        // The waiting agent's window first — ↓ then release lands on it.
        let items = DockSwitcherList.waitingFirst(buildItems().filter { $0.pid == app.pid })
        // No reachable windows: keep the app row — a blank strip is
        // worse than the card that was under the finger.
        guard !items.isEmpty else { return }
        listGeneration += 1
        drilledApp = app.pid
        appMode = false
        model.open(with: items, selection: 0)
        hoverGate.open(at: NSEvent.mouseLocation)
        springWork?.cancel()
        if panel?.hasHints == true {
            panel?.setHints(DockSwitcherList.verbHints(appMode: false, drilled: true))
        }
        panel?.present(model: model)
        loadThumbnails()
    }

    /// The app strip's commit: activate the pick — the app's own
    /// front-window behaviour decides which window lands. A drilled
    /// strip commits the window instead, like the ⌥⇥ path.
    func cmdCommit() {
        // An armed release can follow an open that found nothing or was
        // refused: no strip up, nothing to land — the model still holds
        // the last strip's pick.
        guard panel?.isVisible == true else { return cancel() }
        let item = model.selected
        let drilled = drilledApp != nil
        learn(item)
        closeStrip()
        guard let item else { return }
        Self.land(SwitcherCommitTarget(item), window: drilled)
    }

    /// A commit's landing. The AX half — finding a window on another
    /// Space, reading an app's windows to see whether every one is in
    /// the Dock, the raise's writes — runs on `DockAXWorker`: a hung app
    /// costs it half a second, and on main that stalled the strip's
    /// close and every surface after it. Activation follows on main, as
    /// it always did after the raise. `window` lands the row's own
    /// window; otherwise the app, and when every window it has is in the
    /// Dock its most recent one comes back — stock ⌘⇥ lands on nothing.
    private static func land(_ target: SwitcherCommitTarget, window: Bool) {
        DockAXWorker.run({
            if window {
                if let element = target.resolve() {
                    AppleDockReader.raiseWindow(target.window(element))
                }
            } else if let parked = DockSwitcherList.restoreTarget(
                AppleDockReader.windowsReading(pid: target.pid, stamp: 0).windows) {
                AppleDockReader.raiseWindow(parked)
            }
        }, then: {
            // Plain activate: `.activateAllWindows` brought every window
            // of the app forward and buried the one that was picked.
            NSRunningApplication(processIdentifier: target.pid)?.activate()
        })
    }

    func advance(by step: Int) {
        springWork?.cancel()
        model.advance(by: step)
        panel?.present(model: model)
    }

    /// The pointer's gate for hover-selects — re-armed on every open.
    private var hoverGate = SwitcherHoverGate()
    /// Apps that didn't answer AX lately — skipped instead of waited on.
    private var axBackoff = DockAXBackoff()

    /// The pointer entered a card: that card becomes the pick, so the
    /// zoom pane, the ring and ⌥'s release all agree. The keyboard takes
    /// over again on the next Tab, from here.
    func hover(index: Int) {
        guard panel?.isVisible == true, hoverGate.allows(NSEvent.mouseLocation),
              index != model.selection else { return }
        model.select(index: index)
        panel?.present(model: model)
        armSpring(for: index)
    }

    /// A card click: land the selection on it and commit at once.
    func pick(index: Int) {
        model.select(index: index)
        if appMode { cmdCommit() } else { commit() }
    }

    func commit() {
        // No strip up (see `cmdCommit`): the old pick is not this tap's.
        guard panel?.isVisible == true, let item = model.selected else { return cancel() }
        learn(item)
        closeStrip()
        Self.land(SwitcherCommitTarget(item), window: true)
    }

    func cancel() {
        closeStrip()
    }

    /// A commit under a short typed query teaches it: next time the same
    /// query ranks this window first.
    private func learn(_ item: SwitcherItem?) {
        guard let item, let updated = SwitcherModel.remembering(model.query, pick: item, in: learnedPicks())
        else { return }
        onLearn?(updated)
    }

    /// Every way the strip goes away — commit, a card click, esc — lands
    /// here: the tap stops owning the keyboard, the live watch and the
    /// scope end, and a half-armed guard is forgotten.
    private func closeStrip() {
        listGeneration += 1
        pendingRead = nil
        latchWatchers.stop()
        agentGuard.reset()
        appMode = false
        drilledApp = nil
        scopePID = nil
        stopLive()
        springWork?.cancel()
        hintWork?.cancel()
        tap.setOpen(false)
        panel?.dismiss()
    }

    /// A ⌘-verb on the highlighted row — the stock ⌘⇥/AltTab action
    /// set: q quits the app, h hides it, w closes the window, m
    /// minimizes it, f toggles fullscreen. App rows answer q/h; the
    /// window verbs need the row's element. The strip stays up and
    /// rebuilds around the pick once the target settles.
    func verb(_ char: String) {
        guard let item = model.selected else { return }
        let app = NSRunningApplication(processIdentifier: item.pid)
        // ⌥⇥ ⌘W is the fastest way to kill an agent — a verb that would
        // end a working or waiting session needs the same press twice.
        let danger = DockSwitcherList.guardMark(verb: char, item: item, marks: agentMarks(),
                                                bundleID: app?.bundleIdentifier)
        let now = CACurrentMediaTime()
        guard agentGuard.confirm("\(char):\(item.id)", guarded: danger != nil, now: now) else {
            if let danger { arm(item: item, mark: danger, verb: char) }
            return
        }
        panel?.disarm()
        switch char {
        case "q": app?.terminate()
        case "h": app?.hide()
        case "w", "m", "f":
            // The window verbs are AX writes (and, for a row on another
            // Space, the walk that finds it): the worker's, like a commit.
            let target = SwitcherCommitTarget(item)
            DockAXWorker.run({ () -> Bool in
                guard let element = target.resolve() else { return false }
                let window = target.window(element)
                switch char {
                case "w": AppleDockReader.close(window)
                case "m": AppleDockReader.setMinimized(window, !target.minimized)
                default:
                    // f toggles, not forces: a fullscreen window comes
                    // back, not a second write of true.
                    let current = AppleDockReader.fullScreenState(of: element) ?? false
                    AppleDockReader.setFullScreen(window, !current)
                }
                return true
            }, then: { [weak self] acted in
                if acted { self?.rebuildSoon() }
            })
            return
        default: return
        }
        rebuildSoon()
    }

    /// The AX write lands before the window/app state does — a beat
    /// later the strip rebuilds so the closed or quit row is gone.
    private func rebuildSoon() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { [weak self] in
            self?.rebuild()
        }
    }

    /// The second-press guard for ⌘W / ⌘Q on a live agent's row.
    private var agentGuard = DockAgentGuard()

    /// First press on a guarded verb: ring the card in the provider's
    /// colour and say what the second press does; the ring lapses with
    /// the guard's window.
    private func arm(item: SwitcherItem, mark: DockAgentMark, verb: String) {
        let again = verb == "q" ? "⌘Q again to quit \(item.appName)" : "⌘W again to close"
        panel?.arm(itemID: item.id, mark: mark,
                   note: DockAgentGuard.note(for: mark, again: again))
        let key = "\(verb):\(item.id)"
        DispatchQueue.main.asyncAfter(deadline: .now() + DockAgentGuard.window) { [weak self] in
            guard let self, !self.agentGuard.isArmed(key, now: CACurrentMediaTime()) else { return }
            self.panel?.disarm()
        }
    }

    /// Re-list the rows under the open panel, keeping the selection —
    /// the verb path's refresh, the live tick's and a launch or quit's.
    /// The strip is already up, so the AX half runs on the worker and
    /// the rows land a beat later (`rebuildLater`).
    private func rebuild() {
        guard panel?.isVisible == true else { return }
        rebuildLater(windows: !appMode) { [weak self] built in
            guard let self else { return }
            if self.appMode {
                self.model.refresh(with: self.buildAppItems())
            } else if let drilled = self.drilledApp {
                let rows = DockSwitcherList.waitingFirst(built.filter { $0.pid == drilled })
                if rows.isEmpty {
                    // The drilled app lost its last window under the
                    // panel — pop back to the strip rather than show a
                    // blank card.
                    self.drilledApp = nil
                    self.appMode = true
                    self.model.refresh(with: self.buildAppItems())
                } else {
                    self.model.refresh(with: rows)
                }
            } else {
                self.model.refresh(with: DockSwitcherList.needsYouFirst(built).items)
            }
            self.panel?.present(model: self.model)
            self.loadThumbnails()
        }
    }

    /// Fill the strip's cards in behind the icons: every row with a
    /// CG window id gets the shared preview capture, app rows keep
    /// their icon. No grant or the toggle off — the strip stays icons,
    /// exactly like the preview's "No preview" cards.
    private func loadThumbnails() {
        thumbGeneration += 1
        let generation = thumbGeneration
        guard thumbsAllowed() else { panel?.apply(thumbnails: [:]); return }
        let offscreen = offscreenAllowed()
        // The unfiltered list: typing a letter shouldn't lose stills
        // already on the card.
        // Selection first, then the strip's own order: the card being
        // looked at fills before the far end of the row.
        let items = DockSwitcherThumbs.captureOrder(model.allItems, selectedID: model.selected?.id)
        Task { [weak self] in
            await DockSwitcherThumbs.stills(
                for: items, offscreen: offscreen,
                isStale: { [weak self] in
                    guard let self else { return true }
                    return self.thumbGeneration != generation
                        || self.panel?.isVisible != true
                },
                onStill: { [weak self] id, image in
                    // Each still lands as it's captured — the strip fills
                    // card by card instead of after the slowest window.
                    guard let self, self.thumbGeneration == generation else { return }
                    self.panel?.apply(thumbnails: [id: image])
                })
        }
    }
}

/// The switcher's capture pass: one `SCShareableContent` fetch maps
/// each row's CG window id to its `SCWindow`, then the shared preview
/// capture (cache + trim + transparency probe) does the still.
enum DockSwitcherThumbs {
    /// Captures stream through `onStill` (`item.id`, still) as each one
    /// lands. `isStale` mirrors the preview's contract — a closed or
    /// re-opened strip stops the pass mid-flight.
    @MainActor
    static func stills(for items: [SwitcherItem], offscreen: Bool,
                       isStale: @MainActor () -> Bool,
                       onStill: @MainActor (String, NSImage) -> Void) async {
        guard let shareable = try? await SCShareableContent.excludingDesktopWindows(
            false, onScreenWindowsOnly: !offscreen) else { return }
        guard !isStale() else { return }
        let byID = Dictionary(uniqueKeysWithValues:
            shareable.windows.map { ($0.windowID, $0) })
        let scale = NSScreen.main?.backingScaleFactor ?? 2
        for item in items {
            guard !isStale() else { return }
            guard let windowID = item.windowID, let scWindow = byID[windowID],
                  let image = await DockThumbnailer.capture(
                    scWindow: scWindow, pid: item.pid, scale: scale,
                    tag: item.agent?.stillTag) else { continue }
            guard !isStale() else { return }
            onStill(item.id, image)
        }
    }

    /// The capture queue: the selected card first, the rest in strip
    /// order — the pick is what the zoom pane shows at once.
    static func captureOrder(_ items: [SwitcherItem], selectedID: String?) -> [SwitcherItem] {
        guard let selectedID, let index = items.firstIndex(where: { $0.id == selectedID }) else {
            return items
        }
        var ordered = items
        let pick = ordered.remove(at: index)
        ordered.insert(pick, at: 0)
        return ordered
    }
}

// MARK: - The panel

/// The switcher's face: a centered glass strip, one card per window —
/// the app icon over the title, the pick ringed. Nonactivating; the
/// key tap drives it and a card click commits.
@MainActor
final class DockSwitcherPanel: NSPanel {
    private let model = DockSwitcherModel()
    private let hosting: NSHostingView<DockSwitcherView>

    init(controller: DockSwitcherController) {
        model.onPick = { [weak controller] index in
            controller?.pick(index: index)
        }
        model.onHover = { [weak controller] index in
            controller?.hover(index: index)
        }
        hosting = NSHostingView(rootView: DockSwitcherView(model: model))
        hosting.sizingOptions = [.intrinsicContentSize]
        let glass = NSGlassEffectView(frame: NSRect(x: 0, y: 0, width: 420, height: 120))
        glass.cornerRadius = 18
        glass.style = .regular
        hosting.frame = glass.bounds
        hosting.autoresizingMask = [.width, .height]
        glass.contentView = hosting
        super.init(contentRect: NSRect(x: 0, y: 0, width: 420, height: 120),
                   styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        contentView = GlassBackdrop.rounded(glass, cornerRadius: 18)
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        ignoresMouseEvents = false
        hidesOnDeactivate = false
        isReleasedWhenClosed = false
        isExcludedFromWindowsMenu = true
        isMovable = false
        animationBehavior = .none
        // The strip keeps itself out of screenshots and other apps'
        // window lists — the preview panel does the same.
        sharingType = .none
        collectionBehavior = [.canJoinAllSpaces, .stationary, .transient, .fullScreenAuxiliary, .ignoresCycle]
        level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.dockWindow)) + 10)
        title = "JR-Bar Window Switcher"
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    func present(model source: SwitcherModel) {
        model.items = source.items
        model.selection = source.selection
        model.query = source.query
        // A closed or rebuilt window's still is dead weight — the
        // card falls back to its icon without it.
        let live = Set(source.allItems.map(\.id))
        model.thumbnails = model.thumbnails.filter { live.contains($0.key) }
        refit()
        if !isVisible {
            alphaValue = 0
            orderFrontRegardless()
            let reduced = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
            NSAnimationContext.runAnimationGroup { context in
                context.duration = reduced ? 0.03 : 0.14
                animator().alphaValue = 1
            }
        }
    }

    /// The async capture pass hands its batch over — merge and grow
    /// the cards around the arriving stills.
    func apply(thumbnails: [String: NSImage]) {
        model.thumbnails.merge(thumbnails) { _, new in new }
        if !thumbnails.isEmpty { refit() }
    }

    /// Resize around whatever the cards are now — icons or stills —
    /// keeping the strip centered on the pointer's screen.
    private func refit() {
        hosting.invalidateIntrinsicContentSize()
        hosting.layoutSubtreeIfNeeded()
        let fit = hosting.intrinsicContentSize
        let screen = (NSScreen.screens.first { $0.frame.contains(NSEvent.mouseLocation) }
                      ?? NSScreen.main ?? NSScreen.screens[0])
        let width = min(max(fit.width, 240), screen.visibleFrame.width - 60)
        let height = max(fit.height, 96)
        let origin = NSPoint(x: screen.visibleFrame.midX - width / 2,
                             y: screen.visibleFrame.midY - height / 2)
        setFrame(NSRect(origin: origin, size: NSSize(width: width, height: height)), display: true)
    }

    func dismiss() {
        disarm()
        model.hints = nil
        model.latched = false
        alphaValue = 0
        orderOut(nil)
    }

    var hasHints: Bool { model.hints != nil }

    /// The ⌘-held verb row — nil takes it down.
    func setHints(_ hints: String?) {
        guard model.hints != hints else { return }
        model.hints = hints
        if isVisible { refit() }
    }

    /// The ⌘⇥ search latch's face: the query row stays up and invites typing.
    func setLatched(_ latched: Bool) {
        guard model.latched != latched else { return }
        model.latched = latched
        if isVisible { refit() }
    }

    /// A guarded verb's first press: the card rings, the footer explains.
    func arm(itemID: String, mark: DockAgentMark, note: String) {
        model.armedID = itemID
        model.armedAccent = mark.accent
        model.armedNote = note
        refit()
    }

    func disarm() {
        guard model.armedID != nil else { return }
        model.armedID = nil
        model.armedAccent = nil
        model.armedNote = nil
        if isVisible { refit() }
    }
}

/// The observable box the view binds to — items, the pick, and the
/// click a card reports.
@MainActor
@Observable
final class DockSwitcherModel {
    var items: [SwitcherItem] = []
    var selection = 0
    /// The live type-ahead buffer — shown so the filter never feels
    /// like the strip dropped rows.
    var query = ""
    /// Window stills keyed by item id, filled in behind the strip —
    /// AltTab's card: the window's own pixels over its app icon.
    var thumbnails: [String: NSImage] = [:]
    var onPick: (Int) -> Void = { _ in }
    /// The pointer entered a card — the controller moves the selection
    /// there once the pointer has really moved.
    var onHover: (Int) -> Void = { _ in }
    /// A guarded verb's first press: which card rings, in whose colour,
    /// and the footer line that says a second press goes through.
    var armedID: String?
    var armedAccent: Color?
    var armedNote: String?
    /// The verb row while ⌘ is held.
    var hints: String?
    /// ⌘⇥'s search latch: the query row shows even before a letter.
    var latched = false
}

/// Hover selects only after the pointer has moved since the strip
/// opened: a pointer that merely rests where the strip appears must not
/// steal the first pick (the "needs you" lane's, or the second window).
/// Once it has moved, every card it enters takes the selection until
/// the next open.
struct SwitcherHoverGate {
    private var origin: CGPoint?
    private var moved = false
    /// Points of travel that count as a real move, not sensor jitter.
    static let slop: CGFloat = 3

    mutating func open(at point: CGPoint) {
        origin = point
        moved = false
    }

    mutating func allows(_ point: CGPoint) -> Bool {
        if moved { return true }
        guard let origin else { return true }
        if hypot(point.x - origin.x, point.y - origin.y) > Self.slop { moved = true }
        return moved
    }
}

struct DockSwitcherView: View {
    let model: DockSwitcherModel

    /// The card the preview pane reads: the selection, always. Hover
    /// moves the selection itself (AltTab's behaviour), so the big look,
    /// the ring and what releasing ⌥ commits are one card — the pane
    /// once followed the pointer while the release committed the
    /// keyboard's pick.
    private var zoomed: SwitcherItem? {
        model.items[safe: model.selection]
    }

    var body: some View {
        ScrollViewReader { proxy in
            VStack(spacing: 0) {
                // The preview pane — a fixed slot so the panel never
                // reflows mid-gesture; what it shows follows
                // hover/selection.
                if let item = zoomed {
                    zoom(item)
                        .frame(maxWidth: 340, minHeight: 216)
                        .padding(.top, 10)
                        .id(item.id)
                        .transition(.opacity)
                        .animation(.easeOut(duration: 0.12), value: item.id)
                }
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 6) {
                        ForEach(Array(model.items.enumerated()), id: \.element.id) { index, item in
                            card(item, selected: index == model.selection)
                                .id(item.id)
                                .onTapGesture { model.onPick(index) }
                                .onHover { inside in
                                    if inside { model.onHover(index) }
                                }
                        }
                    }
                    .padding(10)
                }
                if !model.query.isEmpty || model.latched {
                    // The buffer's own label — a filtered strip should
                    // never read as dropped rows. ⌘⇥'s latch shows it
                    // before the first letter, as an invitation.
                    HStack(spacing: 4) {
                        // A leading "!" is the waiting-agents filter —
                        // named, so the narrowed strip explains itself.
                        let waiting = model.query.first == SwitcherModel.waitingFilter
                        let rest = waiting ? String(model.query.dropFirst()) : model.query
                        Image(systemName: waiting ? "exclamationmark.bubble" : "magnifyingglass")
                            .font(.system(size: 9, weight: .medium))
                        Text(waiting && rest.isEmpty ? "Waiting on you"
                             : (rest.isEmpty ? "Type an app's name — ↩ switches, esc cancels" : rest))
                            .font(.system(size: 11, weight: .medium))
                            .lineLimit(1)
                        if model.items.isEmpty {
                            Text("— no match")
                                .font(.system(size: 11))
                                .foregroundStyle(.secondary)
                        }
                    }
                    .foregroundStyle(.secondary)
                    .padding(.bottom, 8)
                    .padding(.horizontal, 12)
                }
                if let hints = model.hints, model.armedNote == nil {
                    Text(hints)
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .padding(.bottom, 8)
                        .padding(.horizontal, 12)
                        .transition(.opacity)
                }
                if let note = model.armedNote {
                    HStack(spacing: 5) {
                        Circle()
                            .fill(model.armedAccent ?? .accentColor)
                            .frame(width: 7, height: 7)
                        Text(note)
                            .font(.system(size: 11, weight: .medium))
                            .lineLimit(1)
                    }
                    .padding(.bottom, 8)
                    .padding(.horizontal, 12)
                    .transition(.opacity)
                }
            }
            .onChange(of: model.selection) { _, _ in
                guard let item = model.items[safe: model.selection] else { return }
                withAnimation(.easeOut(duration: 0.08)) { proxy.scrollTo(item.id) }
            }
        }
    }

    /// The preview pane's contents — the hovered (or selected) card at
    /// full size: the window still when the thumbnail pass granted
    /// one, the app icon otherwise, plus the title the strip
    /// truncates. Offscreen windows say so under the title.
    @ViewBuilder
    private func zoom(_ item: SwitcherItem) -> some View {
        VStack(spacing: 5) {
            Group {
                if let still = model.thumbnails[item.id] {
                    Image(nsImage: still)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                        .shadow(radius: 6, y: 2)
                } else {
                    Image(nsImage: item.icon ?? NSImage())
                        .resizable()
                        .frame(width: 84, height: 84)
                }
            }
            .frame(maxWidth: 320, maxHeight: 168)
            Text("\(item.appName) — \(AppNameChannel.split(item.title).base)")
                .font(.system(size: 11, weight: .medium))
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(maxWidth: 320)
            if item.minimized || !item.onScreen {
                Text(item.minimized ? "Minimized" : (item.windowID == nil ? "Preview unavailable" : "Off screen"))
                    .font(.system(size: 9))
                    .foregroundStyle(.secondary)
            }
            if let agent = item.agent {
                // Which session this window holds and what it wants —
                // the line the switcher exists to answer.
                HStack(spacing: 5) {
                    DockAgentDot(mark: agent, size: 7)
                    Text("\(agent.label) — \(agent.statusLine)")
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
                .font(.system(size: 10, weight: agent.isWaiting ? .semibold : .regular))
                .foregroundStyle(agent.isWaiting ? .primary : .secondary)
                .frame(maxWidth: 320)
            }
        }
    }

    /// Every card in a strip shares one slot, so a row of windows reads
    /// as a row, not a ragged line sized by each title: the still's
    /// width once any card has one, an icon card's narrower slot while
    /// none has.
    static func slotWidth(hasStills: Bool) -> CGFloat { hasStills ? 128 : 96 }
    static let slotHeight: CGFloat = 76
    static let cardRadius: CGFloat = 12

    /// A ring drawn `inset` inside a card keeps the card's curve — the
    /// same centre, a radius smaller by the inset.
    static func ringRadius(inset: CGFloat) -> CGFloat { max(cardRadius - inset, 0) }

    private func card(_ item: SwitcherItem, selected: Bool) -> some View {
        let slot = Self.slotWidth(hasStills: !model.thumbnails.isEmpty)
        return VStack(spacing: 5) {
            if let still = model.thumbnails[item.id] {
                // AltTab's card: the window's own pixels, its app
                // badged in the corner.
                Image(nsImage: still)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(maxWidth: slot, maxHeight: Self.slotHeight)
                    .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                    .overlay(alignment: .bottomLeading) {
                        Image(nsImage: item.icon ?? NSImage())
                            .resizable()
                            .frame(width: 18, height: 18)
                            .overlay(alignment: .topTrailing) {
                                // The corner icon keeps the Dock's badge —
                                // a still must not hide Mail's unread.
                                if let badge = item.badge {
                                    badgePill(badge, size: 8)
                                        .offset(x: 6, y: -5)
                                }
                            }
                            .padding(3)
                    }
                    // The agent's mark rides the still's own corner, where
                    // the preview card draws it.
                    .overlay(alignment: .topTrailing) { agentDot(item).padding(5) }
                    .frame(width: slot, height: Self.slotHeight)
            } else {
                Image(nsImage: item.icon ?? NSImage())
                    .resizable()
                    .frame(width: 44, height: 44)
                    .overlay(alignment: .topTrailing) {
                        // The Dock tile's badge — Witch draws the same
                        // unread pill on its app cards.
                        if let badge = item.badge {
                            badgePill(badge, size: 10)
                                .offset(x: 8, y: -6)
                        }
                    }
                    .frame(width: slot, height: Self.slotHeight)
                    .overlay(alignment: .topTrailing) { agentDot(item).padding(4) }
            }
            Text(AppNameChannel.split(item.title).base)
                .font(.caption2)
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(width: slot)
        }
        .padding(8)
        .opacity(item.onScreen ? 1 : 0.65)
        .background(
            RoundedRectangle(cornerRadius: Self.cardRadius, style: .continuous)
                .fill(selected ? AnyShapeStyle(.tint.opacity(0.3))
                               : AnyShapeStyle(.quaternary.opacity(0.4))))
        .overlay(
            RoundedRectangle(cornerRadius: Self.cardRadius, style: .continuous)
                .strokeBorder(selected ? Color.accentColor : .clear, lineWidth: 2))
        // The "needs you" ring: a waiting agent's card is outlined in
        // its provider's colour, inside the selection ring so both read.
        .overlay {
            if let agent = item.agent, agent.isWaiting {
                let inset: CGFloat = selected ? 3 : 0
                RoundedRectangle(cornerRadius: Self.ringRadius(inset: inset), style: .continuous)
                    .strokeBorder(agent.accent.opacity(0.9), lineWidth: 1.5)
                    .padding(inset)
            }
        }
        // A guarded ⌘W/⌘Q's first press: the card rings in the agent's
        // colour until the second press or the guard's window lapses.
        .overlay {
            if model.armedID == item.id {
                RoundedRectangle(cornerRadius: Self.cardRadius, style: .continuous)
                    .strokeBorder(model.armedAccent ?? .accentColor, lineWidth: 3)
            }
        }
        .help(help(for: item))
    }

    @ViewBuilder
    private func agentDot(_ item: SwitcherItem) -> some View {
        if let agent = item.agent {
            DockAgentDot(mark: agent)
        }
    }

    /// The Dock tile's unread pill, verbatim.
    private func badgePill(_ badge: String, size: CGFloat) -> some View {
        Text(badge)
            .font(.system(size: size, weight: .bold))
            .foregroundStyle(.white)
            .padding(.horizontal, size * 0.4)
            .padding(.vertical, 1)
            .background(.red, in: Capsule())
    }

    private func help(for item: SwitcherItem) -> String {
        var text = item.minimized ? "\(item.appName) — \(item.title) (minimized)" : "\(item.appName) — \(item.title)"
        if let agent = item.agent {
            text += "\n\(agent.providerName) · \(agent.label) — \(agent.statusLine)"
        }
        return text
    }
}


