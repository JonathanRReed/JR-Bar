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
                    element: hit.element, windowID: row.windowID))
            } else if resolution != .ambiguous {
                items.append(SwitcherItem(
                    id: "w\(row.windowID)", pid: row.pid,
                    appName: appName(row.pid), icon: icon(row.pid),
                    title: row.title.isEmpty ? appName(row.pid) : row.title,
                    minimized: false, onScreen: true,
                    element: nil, windowID: row.windowID))
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
                    element: hit?.element, windowID: row.windowID))
            }
            for window in leftover {
                items.append(SwitcherItem(
                    id: "a\(pid)-\(window.id)", pid: pid,
                    appName: appName(pid), icon: icon(pid),
                    title: window.title, minimized: window.minimized,
                    onScreen: false, element: window.element, windowID: window.windowID))
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

    /// The owning pid of a minimized-window Dock tile: the tile carries
    /// no `AXURL`, so its title is matched against the off-screen
    /// window list — exactly one claimant pid is trusted; zero or
    /// several means the card stays tile-backed rather than guessing.
    static func minimizedOwnerPID(title: String, rows: [SwitcherWindowRow]) -> pid_t? {
        let claimants = Set(rows.filter { $0.title == title }.map(\.pid))
        return claimants.count == 1 ? claimants.first : nil
    }

    // MARK: Agents

    /// Stamp each window row with the agent session it exclusively
    /// hosts. Only rows of a session's host app are candidates, so a
    /// Safari tab titled like a session never claims it.
    static func annotate(_ items: [SwitcherItem], marks: [DockAgentMark],
                         bundleID: (pid_t) -> String?) -> [SwitcherItem] {
        guard !marks.isEmpty else { return items }
        let hosts = marks.reduce(into: Set<String>()) { $0.formUnion($1.hosts) }
        let candidates = items.compactMap { item -> DockAgentMatch.Candidate? in
            guard let bundle = bundleID(item.pid), hosts.contains(bundle) else { return nil }
            return .init(key: item.id, bundleID: bundle, title: item.title)
        }
        let map = DockAgentMatch.match(marks: marks, candidates: candidates)
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
        self.items = Self.ranked(items, query: query)
        if let keep, let index = self.items.firstIndex(where: { $0.id == keep.id }) {
            selection = index
        } else {
            selection = min(selection, max(0, self.items.count - 1))
        }
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
        items = Self.ranked(allItems, query: query)
        if let keep, let index = items.firstIndex(where: { $0.id == keep.id }) {
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
        return pool.enumerated()
            .compactMap { index, item in
                score(item, query: query).map { (item, $0, index) }
            }
            .sorted { $0.1 != $1.1 ? $0.1 > $1.1 : $0.2 < $1.2 }
            .map(\.0)
    }

    var selected: SwitcherItem? {
        items.indices.contains(selection) ? items[selection] : nil
    }
}

// MARK: - The key tap

/// The switcher's chord, ⌥⇥: a session event tap — the same shape as
/// the media-key monitor — that eats option-Tab while held and
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
    /// The preview panel's keys — Esc/arrows/Return — while its flag is
    /// set. The events are eaten either way: the panel can't take key
    /// status, so a pass-through would land them in the front app too.
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
    /// The dock preview's flag — while its panel is up the tap eats
    /// the keys the panel reads.
    nonisolated(unsafe) private var previewOpen = false
    /// The commit arm for each chord: an eaten Tab arms it and the
    /// watched modifier's 1→0 edge fires it. Tracked here, not via
    /// `open`, because `open` lands through an async hop and a quick
    /// tap's release can pass through before it — the unarmed edge is
    /// the lost commit that once left the strip eating keystrokes.
    nonisolated(unsafe) private var pendingOptionCommit = false
    nonisolated(unsafe) private var pendingCmdCommit = false
    /// The modifier state at the last event — edges are computed here
    /// so a release that races the async open still resolves.
    nonisolated(unsafe) private var prevOption = false
    nonisolated(unsafe) private var prevCmd = false

    func setEnabled(_ value: Bool) {
        lock.lock(); enabled = value; lock.unlock()
    }

    func setCmdEnabled(_ value: Bool) {
        lock.lock(); cmdEnabled = value; lock.unlock()
    }

    private var tap: CFMachPort?
    private var source: CFRunLoopSource?

    static let log = Logger(subsystem: "devin.jrbar", category: "switcher")

    func setOpen(_ value: Bool) {
        lock.lock()
        open = value
        if !value { cmdOpen = false; pendingOptionCommit = false; pendingCmdCommit = false }
        lock.unlock()
    }

    /// The ⌘⇥ panel's flag — `open` too, plus which chord to watch.
    func setCmdOpen(_ value: Bool) {
        lock.lock()
        open = value; cmdOpen = value
        if !value { pendingOptionCommit = false; pendingCmdCommit = false }
        lock.unlock()
    }

    /// The preview panel's flag — its keys are the tap's while it's up.
    func setPreviewOpen(_ value: Bool) {
        lock.lock(); previewOpen = value; lock.unlock()
    }

    func start() {
        guard tap == nil else { return }
        let mask: CGEventMask = (1 << CGEventType.keyDown.rawValue)
            | (1 << CGEventType.flagsChanged.rawValue)
        tap = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap,
                                options: .defaultTap, eventsOfInterest: mask,
                                callback: { _, type, event, refcon in
            guard let refcon else { return Unmanaged.passRetained(event) }
            return Unmanaged<SwitcherKeyTap>.fromOpaque(refcon)
                .takeUnretainedValue().handle(type: type, event: event)
        }, userInfo: Unmanaged.passUnretained(self).toOpaque())
        guard let tap else {
            Self.log.notice("switcher tap unavailable — accessibility permission missing")
            return
        }
        source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
    }

    func stop() {
        if let tap { CGEvent.tapEnable(tap: tap, enable: false) }
        if let source { CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes) }
        source = nil
        tap = nil
    }

    /// nil return eats the event; passRetained hands it on. Internal
    /// for the tests, which drive it with synthetic CGEvents.
    func handle(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
            return Unmanaged.passRetained(event)
        }
        lock.lock()
        let isOpen = open, isCmdOpen = cmdOpen
        let isEnabled = enabled, isCmdEnabled = cmdEnabled
        let isPreviewOpen = previewOpen
        lock.unlock()
        let code = event.getIntegerValueField(.keyboardEventKeycode)
        let flags = event.flags

        if type == .keyDown {
            // 48 is Tab. Option alone is the window switcher; command
            // (which the system switcher owns) is eaten only when the
            // app switcher is on — off, ⌘⇥ passes through untouched.
            if code == 48, flags.contains(.maskAlternate),
               !flags.contains(.maskCommand), isEnabled {
                let shifted = flags.contains(.maskShift)
                DispatchQueue.main.async { [weak self] in self?.onTab(shifted) }
                return nil
            }
            if code == 48, flags.contains(.maskCommand), isCmdEnabled {
                let shifted = flags.contains(.maskShift)
                DispatchQueue.main.async { [weak self] in self?.onCmdTab(shifted) }
                return nil
            }
            if isOpen {
                switch code {
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
                default:
                    // ⌘-modified keys are verbs on the highlighted row
                    // (stock ⌘⇥ semantics) — and they never leak to the
                    // front app: the tap owns the keyboard while the
                    // strip is up, so a bare pass-through would fire
                    // ⌘Q on the app being switched *away from*. The
                    // letter is the one the layout types under ⌘.
                    if flags.contains(.maskCommand) {
                        if let char = keyboard.character(for: code, command: true)?.lowercased(),
                           Self.verbKeys.contains(char) {
                            return swallow { self.onVerb(char) }
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
            // lands, and nothing leaks into the front app. The strip's
            // own keys are all consumed above, so an open strip keeps
            // precedence.
            if isPreviewOpen, Self.previewKeyCodes.contains(code) {
                return swallow { self.onPreviewKey(code) }
            }
            return Unmanaged.passRetained(event)
        }

        if type == .flagsChanged, isOpen {
            if isCmdOpen, !flags.contains(.maskCommand) {
                // Command lifted — the app switcher's commit.
                DispatchQueue.main.async { [weak self] in self?.onCmdCommit() }
            } else if !isCmdOpen, !flags.contains(.maskAlternate) {
                // Option lifted — the window switcher's commit,
                // AltTab-style.
                DispatchQueue.main.async { [weak self] in self?.onCommit() }
            }
        }
        return Unmanaged.passRetained(event)
    }

    private var isCmdOpenNow: Bool {
        lock.lock(); defer { lock.unlock() }
        return cmdOpen
    }

    /// The keys the floating dock preview owns — Esc closes it, the
    /// arrows walk its cards, Return raises the pick.
    nonisolated static let previewKeyCodes: Set<Int64> = [53, 123, 124, 125, 126, 36, 76]

    /// The ⌘-verb letters — the row of actions stock ⌘⇥ and AltTab
    /// share. Type-ahead keeps every other key.
    nonisolated static let verbKeys: Set<String> = ["q", "w", "m", "h", "f"]

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
    /// The dock preview's keys while its panel floats — Esc closes,
    /// arrows walk the cards, Return raises. The tap eats them either
    /// way: the panel can't take key status, so a pass-through would
    /// type them into the front app.
    var onPreviewKey: ((Int64) -> Void)?
    /// Mirrors the preview panel's visibility into the tap — the
    /// enhance controller's show/hide drives it.
    func setPreviewOpen(_ value: Bool) { tap.setPreviewOpen(value) }
    /// An open can land while the last open's captures still run —
    /// the generation tells a stale async batch from the live strip.
    private var thumbGeneration = 0

    private(set) var running = false

    /// The tap can't read a main-actor setting mid-callback — mirror
    /// it into the tap's own flag so a disabled switcher passes ⌥⇥
    /// through instead of eating the chord.
    func syncSettings() {
        tap.setEnabled(isAllowed())
        tap.setCmdEnabled(isCmdAllowed())
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
        // The layout the type-ahead spells through — read now on the
        // main thread and again on every input-source switch.
        tap.keyboard.startWatching()
        tap.start()
    }

    func stop() {
        guard running else { return }
        running = false
        tap.stop()
        cancel()
    }

    private func tab(shifted: Bool) {
        guard isAllowed() else { return }
        if panel?.isVisible == true {
            advance(by: shifted ? -1 : 1)
        } else {
            open()
        }
    }

    private func open() {
        let built = buildItems()
        guard !built.isEmpty else { return }
        // A waiting agent's window leads and takes the first pick.
        let lane = DockSwitcherList.needsYouFirst(built)
        model.open(with: lane.items, selection: lane.selection)
        appMode = false
        drilledApp = nil
        tap.setOpen(true)
        if panel == nil { panel = DockSwitcherPanel(controller: self) }
        hoverGate.open(at: NSEvent.mouseLocation)
        panel?.present(model: model)
        loadThumbnails()
    }

    /// The ⌥⇥ strip's rows: on-screen windows in z-order, then
    /// minimized and other-Space windows grouped by app — the whole
    /// set a verb can rebuild under the open panel.
    private func buildItems() -> [SwitcherItem] {
        let rows = DockSwitcherList.onScreenRows()
        let apps = Dictionary(uniqueKeysWithValues:
            NSWorkspace.shared.runningApplications.map { ($0.processIdentifier, $0) })
        let items = DockSwitcherList.order(
            rows: rows,
            offRows: DockSwitcherList.offScreenRows(),
            windowsForApp: { pid in
                guard apps[pid] != nil, pid != ProcessInfo.processInfo.processIdentifier
                else { return [] }
                return AppleDockReader.windows(pid: pid)
            },
            appName: { apps[$0]?.localizedName ?? "App" },
            icon: { apps[$0]?.icon })
        return DockSwitcherList.annotate(items, marks: agentMarks(),
                                         bundleID: { apps[$0]?.bundleIdentifier })
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
        let items = buildAppItems()
        guard !items.isEmpty else { return }
        model.open(with: items)
        appMode = true
        drilledApp = nil
        tap.setCmdOpen(true)
        if panel == nil { panel = DockSwitcherPanel(controller: self) }
        hoverGate.open(at: NSEvent.mouseLocation)
        panel?.present(model: model)
        loadThumbnails()
    }

    private func buildAppItems() -> [SwitcherItem] {
        let apps = NSWorkspace.shared.runningApplications.filter {
            $0.activationPolicy == .regular && !$0.isTerminated
                && $0.processIdentifier != ProcessInfo.processInfo.processIdentifier
        }
        let byPID = Dictionary(uniqueKeysWithValues: apps.map { ($0.processIdentifier, $0) })
        var ordered: [pid_t] = []
        var seen = Set<pid_t>()
        for row in DockSwitcherList.onScreenRows() where seen.insert(row.pid).inserted {
            ordered.append(row.pid)
        }
        for app in apps where seen.insert(app.processIdentifier).inserted {
            ordered.append(app.processIdentifier)
        }
        // The unread counts live on the Dock's tiles — one AX walk maps
        // bundle path → badge, the same walk the previews do per tick.
        var badges: [String: String] = [:]
        if let pid = AppleDockReader.dockPID(), let list = AppleDockReader.dockList(pid: pid) {
            for tile in AppleDockReader.items(list: list)
            where tile.kind == .app {
                if let badge = tile.badge, let path = tile.url?.path {
                    badges[path] = badge
                }
            }
        }
        let marks = agentMarks()
        return ordered.compactMap { pid -> SwitcherItem? in
            guard let app = byPID[pid] else { return nil }
            return SwitcherItem(id: "app\(pid)", pid: pid,
                                appName: app.localizedName ?? "App",
                                icon: app.icon,
                                title: app.localizedName ?? "App",
                                minimized: false, onScreen: true,
                                element: nil, windowID: nil,
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
        drilledApp = app.pid
        appMode = false
        model.open(with: items, selection: 0)
        hoverGate.open(at: NSEvent.mouseLocation)
        panel?.present(model: model)
        loadThumbnails()
    }

    /// The app strip's commit: activate the pick — the app's own
    /// front-window behaviour decides which window lands. A drilled
    /// strip commits the window instead, like the ⌥⇥ path.
    func cmdCommit() {
        let item = model.selected
        let drilled = drilledApp != nil
        appMode = false
        drilledApp = nil
        tap.setCmdOpen(false)
        panel?.dismiss()
        guard let item else { return }
        if drilled, let element = item.element {
            let window = DockPreviewWindow(id: 0, title: item.title,
                                         minimized: item.minimized,
                                         fullScreen: nil, frame: nil,
                                         thumbnail: nil, element: element)
            AppleDockReader.raise(window, app: NSRunningApplication(processIdentifier: item.pid))
        } else {
            NSRunningApplication(processIdentifier: item.pid)?.activate()
        }
    }

    func advance(by step: Int) {
        model.advance(by: step)
        panel?.present(model: model)
    }

    /// The pointer's gate for hover-selects — re-armed on every open.
    private var hoverGate = SwitcherHoverGate()

    /// The pointer entered a card: that card becomes the pick, so the
    /// zoom pane, the ring and ⌥'s release all agree. The keyboard takes
    /// over again on the next Tab, from here.
    func hover(index: Int) {
        guard panel?.isVisible == true, hoverGate.allows(NSEvent.mouseLocation),
              index != model.selection else { return }
        model.select(index: index)
        panel?.present(model: model)
    }

    /// A card click: land the selection on it and commit at once.
    func pick(index: Int) {
        model.select(index: index)
        if appMode { cmdCommit() } else { commit() }
    }

    func commit() {
        guard let item = model.selected else { return cancel() }
        appMode = false
        drilledApp = nil
        tap.setOpen(false)
        panel?.dismiss()
        if let element = item.element {
            let window = DockPreviewWindow(id: 0, title: item.title,
                                         minimized: item.minimized,
                                         fullScreen: nil, frame: nil,
                                         thumbnail: nil, element: element)
            let app = NSRunningApplication(processIdentifier: item.pid)
            AppleDockReader.raise(window, app: app)
        } else {
            NSRunningApplication(processIdentifier: item.pid)?.activate()
        }
    }

    func cancel() {
        appMode = false
        drilledApp = nil
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
        switch char {
        case "q": app?.terminate()
        case "h": app?.hide()
        case "w", "m", "f":
            guard let element = item.element else { return }
            let window = DockPreviewWindow(id: 0, title: item.title,
                                         minimized: item.minimized,
                                         fullScreen: nil, frame: nil,
                                         thumbnail: nil, element: element)
            switch char {
            case "w": AppleDockReader.close(window)
            case "m": AppleDockReader.setMinimized(window, !item.minimized)
            default:
                // f toggles, not forces: a fullscreen window comes
                // back, not a second write of true.
                let current = AppleDockReader.fullScreenState(of: element) ?? false
                AppleDockReader.setFullScreen(window, !current)
            }
        default: return
        }
        // The AX write lands before the window/app state does — a beat
        // later the strip rebuilds so the closed or quit row is gone.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { [weak self] in
            self?.rebuild()
        }
    }

    /// Re-list the rows under the open panel, keeping the selection —
    /// the verb path's refresh.
    private func rebuild() {
        guard panel?.isVisible == true else { return }
        if appMode {
            model.refresh(with: buildAppItems())
        } else if let drilledApp {
            let rows = DockSwitcherList.waitingFirst(buildItems().filter { $0.pid == drilledApp })
            if rows.isEmpty {
                // The drilled app lost its last window under the panel —
                // pop back to the strip rather than show a blank card.
                self.drilledApp = nil
                appMode = true
                model.refresh(with: buildAppItems())
            } else {
                model.refresh(with: rows)
            }
        } else {
            model.refresh(with: DockSwitcherList.needsYouFirst(buildItems()).items)
        }
        panel?.present(model: model)
        loadThumbnails()
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
        let items = model.allItems
        Task { [weak self] in
            let thumbs = await DockSwitcherThumbs.stills(
                for: items, offscreen: offscreen) { [weak self] in
                    guard let self else { return true }
                    return self.thumbGeneration != generation
                        || self.panel?.isVisible != true
                }
            guard let self, self.thumbGeneration == generation else { return }
            self.panel?.apply(thumbnails: thumbs)
        }
    }
}

/// The switcher's capture pass: one `SCShareableContent` fetch maps
/// each row's CG window id to its `SCWindow`, then the shared preview
/// capture (cache + trim + transparency probe) does the still.
enum DockSwitcherThumbs {
    /// `item.id` → still. `isStale` mirrors the preview's contract —
    /// a closed or re-opened strip drops the in-flight batch.
    @MainActor
    static func stills(for items: [SwitcherItem], offscreen: Bool,
                       isStale: @MainActor () -> Bool) async -> [String: NSImage] {
        guard let shareable = try? await SCShareableContent.excludingDesktopWindows(
            false, onScreenWindowsOnly: !offscreen) else { return [:] }
        guard !isStale() else { return [:] }
        let byID = Dictionary(uniqueKeysWithValues:
            shareable.windows.map { ($0.windowID, $0) })
        let scale = NSScreen.main?.backingScaleFactor ?? 2
        var stills: [String: NSImage] = [:]
        for item in items {
            guard !isStale() else { return [:] }
            guard let windowID = item.windowID, let scWindow = byID[windowID],
                  let image = await DockThumbnailer.capture(
                    scWindow: scWindow, pid: item.pid, scale: scale) else { continue }
            stills[item.id] = image
        }
        return stills
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
        alphaValue = 0
        orderOut(nil)
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
                if !model.query.isEmpty {
                    // The buffer's own label — a filtered strip should
                    // never read as dropped rows.
                    HStack(spacing: 4) {
                        // A leading "!" is the waiting-agents filter —
                        // named, so the narrowed strip explains itself.
                        let waiting = model.query.first == SwitcherModel.waitingFilter
                        let rest = waiting ? String(model.query.dropFirst()) : model.query
                        Image(systemName: waiting ? "exclamationmark.bubble" : "magnifyingglass")
                            .font(.system(size: 9, weight: .medium))
                        Text(waiting && rest.isEmpty ? "Waiting on you" : rest)
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

    private func card(_ item: SwitcherItem, selected: Bool) -> some View {
        VStack(spacing: 5) {
            if let still = model.thumbnails[item.id] {
                // AltTab's card: the window's own pixels, its app
                // badged in the corner.
                Image(nsImage: still)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(maxWidth: 128, maxHeight: 76)
                    .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                    .overlay(alignment: .bottomLeading) {
                        Image(nsImage: item.icon ?? NSImage())
                            .resizable()
                            .frame(width: 18, height: 18)
                            .padding(3)
                    }
                    .frame(height: 76)
            } else {
                Image(nsImage: item.icon ?? NSImage())
                    .resizable()
                    .frame(width: 44, height: 44)
                    .overlay(alignment: .topTrailing) {
                        // The Dock tile's badge — Witch draws the same
                        // unread pill on its app cards.
                        if let badge = item.badge {
                            Text(badge)
                                .font(.system(size: 10, weight: .bold))
                                .foregroundStyle(.white)
                                .padding(.horizontal, 4)
                                .padding(.vertical, 1)
                                .background(.red, in: Capsule())
                                .offset(x: 8, y: -6)
                        }
                    }
                    .frame(height: 76, alignment: .center)
            }
            Text(AppNameChannel.split(item.title).base)
                .font(.caption2)
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(maxWidth: 96)
        }
        .padding(8)
        .opacity(item.onScreen ? 1 : 0.65)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(selected ? AnyShapeStyle(.tint.opacity(0.3))
                               : AnyShapeStyle(.quaternary.opacity(0.4))))
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(selected ? Color.accentColor : .clear, lineWidth: 2))
        // The "needs you" ring: a waiting agent's card is outlined in
        // its provider's colour, inside the selection ring so both read.
        .overlay {
            if let agent = item.agent, agent.isWaiting {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .strokeBorder(agent.accent.opacity(0.9), lineWidth: 1.5)
                    .padding(selected ? 3 : 0)
            }
        }
        .overlay(alignment: .topLeading) {
            if let agent = item.agent {
                DockAgentDot(mark: agent)
                    .padding(6)
            }
        }
        .help(help(for: item))
    }

    private func help(for item: SwitcherItem) -> String {
        var text = item.minimized ? "\(item.appName) — \(item.title) (minimized)" : "\(item.appName) — \(item.title)"
        if let agent = item.agent {
            text += "\n\(agent.providerName) · \(agent.label) — \(agent.statusLine)"
        }
        return text
    }
}


