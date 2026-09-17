import AppKit
import ApplicationServices
import JRBarCore
import OSLog
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
}

/// One on-screen window out of `CGWindowListCopyWindowInfo`, already
/// filtered to layer 0 and a real app.
struct SwitcherWindowRow {
    let pid: pid_t
    let windowID: CGWindowID
    let title: String
    let bounds: CGRect
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
                                     bounds: bounds)
        }
    }

    /// Merge the z-ordered CGWindow rows with each app's AX windows.
    /// On-screen windows lead in recency order, matched to their AX
    /// element by frame then title (the thumbnail matcher's rule);
    /// AX-only windows — minimized, other Spaces — follow grouped by
    /// their app's best z position.
    static func order(rows: [SwitcherWindowRow],
                      windowsForApp: (pid_t) -> [DockPreviewWindow],
                      appName: (pid_t) -> String,
                      icon: (pid_t) -> NSImage?) -> [SwitcherItem] {
        var items: [SwitcherItem] = []
        /// pid → AX windows still unmatched, so a second window with
        /// the same frame takes a different element.
        var unmatched: [pid_t: [DockPreviewWindow]] = [:]
        var appRank: [pid_t: Int] = [:]

        func axWindows(for pid: pid_t) -> [DockPreviewWindow] {
            if let cached = unmatched[pid] { return cached }
            let list = windowsForApp(pid)
            unmatched[pid] = list
            return list
        }

        for row in rows {
            if appRank[row.pid] == nil { appRank[row.pid] = items.count }
            let candidates = axWindows(for: row.pid)
            if let hit = match(row: row, in: candidates) {
                unmatched[row.pid]?.removeAll { $0.id == hit.id }
                items.append(SwitcherItem(
                    id: "w\(row.windowID)", pid: row.pid,
                    appName: appName(row.pid), icon: icon(row.pid),
                    title: hit.title, minimized: false, onScreen: true,
                    element: hit.element, windowID: row.windowID))
            } else {
                items.append(SwitcherItem(
                    id: "w\(row.windowID)", pid: row.pid,
                    appName: appName(row.pid), icon: icon(row.pid),
                    title: row.title.isEmpty ? appName(row.pid) : row.title,
                    minimized: false, onScreen: true,
                    element: nil, windowID: row.windowID))
            }
        }

        // Off-screen and minimized windows, app by app in recency.
        let pids = unmatched.keys.sorted { (appRank[$0] ?? .max) < (appRank[$1] ?? .max) }
        for pid in pids {
            for window in unmatched[pid] ?? [] {
                items.append(SwitcherItem(
                    id: "a\(pid)-\(window.id)", pid: pid,
                    appName: appName(pid), icon: icon(pid),
                    title: window.title, minimized: window.minimized,
                    onScreen: false, element: window.element, windowID: nil))
            }
        }
        return items
    }

    /// Frame first — it is the honest key — then title, the same rule
    /// the thumbnail matcher follows.
    static func match(row: SwitcherWindowRow,
                      in windows: [DockPreviewWindow]) -> DockPreviewWindow? {
        if let byFrame = windows.first(where: {
            guard let f = $0.frame else { return false }
            return abs(f.minX - row.bounds.minX) < 2 && abs(f.minY - row.bounds.minY) < 2
                && abs(f.width - row.bounds.width) < 2 && abs(f.height - row.bounds.height) < 2
        }) { return byFrame }
        return windows.first { $0.title == row.title }
    }
}

// MARK: - The model (pure, tested)

/// The open switcher's state: the row order and the highlighted
/// index. Selection starts on the *second* window — ⌥⇥ means "back to
/// what I was in" — and wraps in both directions.
struct SwitcherModel {
    /// The unfiltered list — the type-ahead always narrows from this.
    private var allItems: [SwitcherItem] = []
    private(set) var items: [SwitcherItem] = []
    private(set) var selection = 0
    /// The type-ahead buffer: letters narrow the strip to windows and
    /// apps whose names carry them. Empty means every item shows.
    private(set) var query = ""

    mutating func open(with items: [SwitcherItem]) {
        allItems = items
        self.items = items
        query = ""
        selection = items.count > 1 ? 1 : 0
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
        items = query.isEmpty ? allItems : allItems.filter { Self.matches($0, query: query) }
        if let keep, let index = items.firstIndex(where: { $0.id == keep.id }) {
            selection = index
        } else {
            selection = items.isEmpty ? 0 : min(selection, items.count - 1)
        }
    }

    /// Case-insensitive substring on the window title or the app —
    /// "saf" lands Safari, "ter" the Terminal window.
    static func matches(_ item: SwitcherItem, query: String) -> Bool {
        let needle = query.lowercased()
        return item.title.range(of: needle, options: .caseInsensitive) != nil
            || item.appName.range(of: needle, options: .caseInsensitive) != nil
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
    /// The ⌘⇥ app switcher — the same tap's second chord, a level per
    /// app and a commit when command lifts. Off by default; eating the
    /// system's own chord is a bigger promise than ⌥⇥.
    var onCmdTab: (_ shifted: Bool) -> Void = { _ in }
    var onCmdCommit: () -> Void = {}
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
        lock.lock(); open = value; if !value { cmdOpen = false }; lock.unlock()
    }

    /// The ⌘⇥ panel's flag — `open` too, plus which chord to watch.
    func setCmdOpen(_ value: Bool) {
        lock.lock(); open = value; cmdOpen = value; lock.unlock()
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

    /// nil return eats the event; passRetained hands it on.
    private func handle(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
            return Unmanaged.passRetained(event)
        }
        lock.lock()
        let isOpen = open, isCmdOpen = cmdOpen
        let isEnabled = enabled, isCmdEnabled = cmdEnabled
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
                case 36, 76:
                    return swallow { self.isCmdOpenNow ? self.onCmdCommit() : self.onCommit() }
                case 51: return swallow { self.onBackspace() }  // ⌫
                case 53: return swallow { self.onCancel() }     // esc
                default:
                    // Type-ahead: bare characters filter the strip;
                    // modified keys pass through untouched.
                    if !flags.contains(.maskCommand), !flags.contains(.maskControl),
                       let char = Self.charForKeycode[code] {
                        return swallow { self.onType(char) }
                    }
                }
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

    /// Keycode → character for the type-ahead — letters, digits and
    /// space. The US layout is the only one the buffer pretends to
    /// spell; everything else is a no-match, not a wrong letter.
    nonisolated static let charForKeycode: [Int64: String] = [
        0: "a", 11: "b", 8: "c", 2: "d", 14: "e", 3: "f", 5: "g", 4: "h",
        34: "i", 38: "j", 40: "k", 37: "l", 46: "m", 45: "n", 31: "o",
        35: "p", 12: "q", 15: "r", 1: "s", 17: "t", 32: "u", 9: "v",
        13: "w", 7: "x", 16: "y", 6: "z",
        18: "1", 19: "2", 20: "3", 21: "4", 23: "5", 22: "6", 26: "7",
        28: "8", 25: "9", 29: "0", 49: " ",
    ]

    private func swallow(_ action: @escaping @MainActor () -> Void) -> Unmanaged<CGEvent>? {
        DispatchQueue.main.async { Task { @MainActor in action() } }
        return nil
    }
}

// MARK: - The controller

/// ⌥⇥ raises a centered strip of every app's windows in recency
/// order; Tab (or ⇧Tab) walks it, option lifting commits the pick,
/// esc cancels. Owned by `DockEnhanceController` — it is the dock
/// utility's other half, DockDoor's window switcher.
@MainActor
final class DockSwitcherController {
    static let log = Logger(subsystem: "devin.jrbar", category: "switcher")

    private let tap = SwitcherKeyTap()
    private var panel: DockSwitcherPanel?
    private(set) var model = SwitcherModel()
    /// Which strip is up — the ⌥⇥ window cards or the ⌘⇥ app row.
    private(set) var appMode = false
    /// Settings read — the card's switch decides per open whether the
    /// chord is live.
    var isAllowed: () -> Bool = { true }
    /// The ⌘⇥ switch — off by default, so the system's own switcher
    /// keeps its chord until the card opts in.
    var isCmdAllowed: () -> Bool = { false }

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
        tap.onType = { [weak self] char in
            self?.model.type(char)
            self?.panel?.present(model: self?.model ?? SwitcherModel())
        }
        tap.onBackspace = { [weak self] in
            self?.model.backspace()
            self?.panel?.present(model: self?.model ?? SwitcherModel())
        }
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
        let rows = DockSwitcherList.onScreenRows()
        let apps = Dictionary(uniqueKeysWithValues:
            NSWorkspace.shared.runningApplications.map { ($0.processIdentifier, $0) })
        let items = DockSwitcherList.order(
            rows: rows,
            windowsForApp: { pid in
                guard apps[pid] != nil, pid != ProcessInfo.processInfo.processIdentifier
                else { return [] }
                return AppleDockReader.windows(pid: pid)
            },
            appName: { apps[$0]?.localizedName ?? "App" },
            icon: { apps[$0]?.icon })
        guard !items.isEmpty else { return }
        model.open(with: items)
        appMode = false
        tap.setOpen(true)
        if panel == nil { panel = DockSwitcherPanel(controller: self) }
        panel?.present(model: model)
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
        let items = ordered.compactMap { pid -> SwitcherItem? in
            guard let app = byPID[pid] else { return nil }
            return SwitcherItem(id: "app\(pid)", pid: pid,
                                appName: app.localizedName ?? "App",
                                icon: app.icon,
                                title: app.localizedName ?? "App",
                                minimized: false, onScreen: true,
                                element: nil, windowID: nil)
        }
        guard !items.isEmpty else { return }
        model.open(with: items)
        appMode = true
        tap.setCmdOpen(true)
        if panel == nil { panel = DockSwitcherPanel(controller: self) }
        panel?.present(model: model)
    }

    /// The app strip's commit: activate the pick — the app's own
    /// front-window behaviour decides which window lands.
    func cmdCommit() {
        let item = model.selected
        appMode = false
        tap.setCmdOpen(false)
        panel?.dismiss()
        guard let item else { return }
        NSRunningApplication(processIdentifier: item.pid)?.activate()
    }

    func advance(by step: Int) {
        model.advance(by: step)
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
        tap.setOpen(false)
        panel?.dismiss()
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
        contentView = glass
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        ignoresMouseEvents = false
        hidesOnDeactivate = false
        isReleasedWhenClosed = false
        isExcludedFromWindowsMenu = true
        isMovable = false
        animationBehavior = .none
        collectionBehavior = [.canJoinAllSpaces, .stationary, .transient, .ignoresCycle]
        level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.dockWindow)) + 10)
        title = "JR-Bar Window Switcher"
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    func present(model source: SwitcherModel) {
        model.items = source.items
        model.selection = source.selection
        model.query = source.query
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
    var onPick: (Int) -> Void = { _ in }
}

struct DockSwitcherView: View {
    let model: DockSwitcherModel

    var body: some View {
        ScrollViewReader { proxy in
            VStack(spacing: 0) {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 6) {
                        ForEach(Array(model.items.enumerated()), id: \.element.id) { index, item in
                            card(item, selected: index == model.selection)
                                .id(item.id)
                                .onTapGesture { model.onPick(index) }
                        }
                    }
                    .padding(10)
                }
                if !model.query.isEmpty {
                    // The buffer's own label — a filtered strip should
                    // never read as dropped rows.
                    HStack(spacing: 4) {
                        Image(systemName: "magnifyingglass")
                            .font(.system(size: 9, weight: .medium))
                        Text(model.query)
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

    private func card(_ item: SwitcherItem, selected: Bool) -> some View {
        VStack(spacing: 5) {
            Image(nsImage: item.icon ?? NSImage())
                .resizable()
                .frame(width: 44, height: 44)
            Text(item.title)
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
        .help(item.minimized ? "\(item.appName) — \(item.title) (minimized)" : "\(item.appName) — \(item.title)")
    }
}


