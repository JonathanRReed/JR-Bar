import AppKit
import ApplicationServices
import EventKit
import JRBarCore
import Observation
import OSLog
import QuartzCore

// MARK: - Parking (pure, tested)

/// When nobody can point at the Dock — the displays asleep, the screen
/// locked, the session switched to another user — the preview tick has
/// nothing to watch, and it parked nothing: it woke main eight times a
/// second all night. Each notice flips its own fact; the tick parks when
/// the first one holds and resumes when the last one lets go.
struct DockTickPark: Equatable {
    enum Event: Equatable, Sendable {
        case displaysSlept, displaysWoke, locked, unlocked, sessionLeft, sessionReturned
    }

    enum Change: Equatable { case park, resume }

    static let lockedNotification = Notification.Name("com.apple.screenIsLocked")
    static let unlockedNotification = Notification.Name("com.apple.screenIsUnlocked")

    private(set) var displaysAsleep = false
    private(set) var locked = false
    private(set) var sessionInactive = false

    var parked: Bool { displaysAsleep || locked || sessionInactive }

    /// Apply a notice; the change it makes to the tick, if any.
    mutating func note(_ event: Event) -> Change? {
        let before = parked
        switch event {
        case .displaysSlept: displaysAsleep = true
        case .displaysWoke: displaysAsleep = false
        case .locked: locked = true
        case .unlocked: locked = false
        case .sessionLeft: sessionInactive = true
        case .sessionReturned: sessionInactive = false
        }
        guard parked != before else { return nil }
        return parked ? .park : .resume
    }
}

// MARK: - Controller

/// Enhance mode: Apple's Dock stays; we watch the pointer over it
/// through Accessibility and float a window-preview panel above a
/// rested icon (docs/TOY-PARITY.md: "Hover a Dock icon → live window
/// previews … AX to hit-test the Dock, SCScreenshotManager one-shots
/// per window, no stream so no purple indicator").
///
/// The watch is a 20 Hz timer, not an event tap. Per tick it reads the
/// pointer and compares it against a *cached* dock-list frame — the AX
/// walk to the Dock process runs at most once a second while the
/// pointer is away, and per-item hit-testing only while it is inside.
/// The TCC probes are cached: `AXIsProcessTrusted` for
/// `permissionTTL`, the Screen Recording preflight — a tccd round
/// trip on every call — through `FoldCapturePermission`'s shared
/// 30 s cache (see `refreshPermissions`). With the displays asleep, the
/// screen locked or the session switched away the timer parks
/// (`DockTickPark`).
@MainActor
@Observable
final class DockEnhanceController {
    let preferences: DockEnhancePreferences
    /// What the panel shows right now — the view binds to it.
    let preview = DockPreviewContent()

    private(set) var running = false
    /// Cached TCC answers; `refreshPermissions()` re-reads when stale.
    private(set) var accessibilityTrusted = false
    private(set) var screenCaptureGranted = false
    @ObservationIgnored private var permissionsCheckedAt = Date.distantPast
    /// The minimum gap between Accessibility and magnification
    /// re-reads. Screen Recording keeps its own 30 s cache — see
    /// `refreshPermissions`.
    nonisolated static let permissionTTL: TimeInterval = 3

    static let pollInterval: TimeInterval = 0.05
    /// The cadence while the pointer is far from every screen edge a
    /// Dock could live on — 8 Hz keeps the idle read near-free (the
    /// AX walk stays TTL-bound, not poll-bound) while halving the
    /// worst-case wait before a dock-ward pointer is noticed.
    nonisolated static let farPollInterval: TimeInterval = 0.125
    /// How long a dock-list frame stays trusted while the pointer is
    /// away from it — and a much shorter trust while the pointer is
    /// near a screen edge, where an auto-hidden Dock slides in and its
    /// frame moves on screen.
    nonisolated static let listFrameTTL: TimeInterval = 1.0
    nonisolated static let edgeListFrameTTL: TimeInterval = 0.2
    /// How long the tiles read from the list stay trusted while the
    /// pointer is over it — the tick hit-tests these in memory instead
    /// of walking the Dock's tree twenty times a second.
    nonisolated static let itemsTTL: TimeInterval = 0.25
    /// How close to a screen edge counts as "near" for the fast refresh.
    nonisolated static let edgeReach: CGFloat = 120
    /// The dock list's frame, inflated toward the screen so a
    /// magnified icon's overflow still counts as "over the dock".
    nonisolated static let listSlop: CGSize = CGSize(width: 20, height: 96)
    /// The list frame inflated by `listSlop` — the "over the dock"
    /// reach the tick's hit-test, the frame cache's freshness rule,
    /// the quick-quit hit-test and the poll cadence all share.
    nonisolated static func listReach(of frame: CGRect) -> CGRect {
        frame.insetBy(dx: -listSlop.width, dy: -listSlop.height)
    }

    @ObservationIgnored private var timer: Timer?
    /// Displays asleep, locked, switched away: the tick stops until the
    /// matching wake (`DockTickPark`).
    @ObservationIgnored private(set) var presence = DockTickPark()
    @ObservationIgnored private var presenceObservers: [NSObjectProtocol] = []
    @ObservationIgnored private var lockObservers: [NSObjectProtocol] = []
    @ObservationIgnored private var panelWarmupTimer: Timer?
    @ObservationIgnored private var tracker = DockHoverTracker()
    @ObservationIgnored private var panel: DockPreviewPanel?
    /// Esc and a click anywhere else close the preview even though it
    /// can't take key status.
    @ObservationIgnored private let watchers = DockPanelWatchers()
    /// Bumped per show so a slow thumbnail batch can't land on a
    /// preview that has since retargeted.
    @ObservationIgnored private var generation = 0
    /// The dock list element and its AX frame, with the time read.
    @ObservationIgnored private var cachedList: (element: AXUIElement, frame: CGRect, at: TimeInterval)?
    /// Apple's Dock magnification, re-read with the permission probe.
    /// Under magnification the tiles' Accessibility frames are the
    /// unmagnified layout while the icons slide under the pointer: a
    /// panel centred on the frame sat 200 pt off the icon (measured:
    /// tile 288–325, pointer 542). The pointer is where the icon is.
    @ObservationIgnored private var magnificationOn = false
    /// The Dock's magnified icon size (`largesize`), read with the flag;
    /// nil when it was never set — the Dock then swells to 128.
    @ObservationIgnored private var magnifiedSize: CGFloat?
    /// The list's app tiles, read once per `itemsTTL` for the list
    /// frame they were read under.
    @ObservationIgnored private var cachedItems: (listFrame: CGRect, items: [DockAXItem], at: TimeInterval)?
    /// The tile the visible panel is anchored to and the edge it opens
    /// from — re-anchored every tick while the pointer stays on the
    /// tile, so a Dock still sliding in carries the panel with it and
    /// a size measured before the content settled is corrected a beat
    /// later.
    @ObservationIgnored private var anchor: (item: DockAXItem, edge: DockEdge, screen: CGRect)?

    /// The hold that keeps an auto-hiding Dock out while the panel is
    /// up — injectable; the default resolves the CoreDock verbs.
    @ObservationIgnored let autohideHold: DockAutohideHold
    /// ⌥⇥ — the utility's window switcher, DockDoor's other half. The
    /// Dock utility owns its lifecycle (it runs with the previews parked
    /// too); the watcher only borrows its key tap for the preview's keys.
    @ObservationIgnored let switcher: DockSwitcherController
    /// The quick-quit watch: ⌘+right-click on a Dock tile. A global
    /// monitor (observe-only — the Dock's own menu still opens).
    @ObservationIgnored private var quickQuitMonitor: Any?
    /// The Middle Click trigger's watch — only while that trigger is picked.
    @ObservationIgnored private var middleClickMonitor: Any?
    /// Scroll on a Dock icon — only while scroll gestures are on.
    @ObservationIgnored private var scrollMonitor: Any?
    /// Click the front app's icon — only while click-to-minimize is on.
    @ObservationIgnored private var clickMonitor: Any?
    /// The last app activation seen, stamped in system uptime — the
    /// click-to-minimize rule's "was it already in front".
    @ObservationIgnored private var lastActivation: (pid: pid_t, at: TimeInterval)?
    @ObservationIgnored private var activationObserver: NSObjectProtocol?
    /// The scroll gesture's running total, per tile.
    @ObservationIgnored private var scrollFlick = DockEnhanceMath.SwipeAccumulator()
    @ObservationIgnored private var scrollTile: String?
    /// The `MediaFeed` reader a player tile's preview holds — started
    /// on show, released on hide, so the perl helper only lives while
    /// a media card is actually up.
    @ObservationIgnored private var mediaToken: UUID?
    /// The daemon's live sessions as marks — wired by `DockUtility`.
    @ObservationIgnored var agentMarks: @MainActor () -> [DockAgentMark] = { [] }
    /// The notch Shelf's tray — wired by the app delegate. A folder
    /// chip or a document card's "Send to Shelf" stages the file there.
    @ObservationIgnored var sendToShelf: (@MainActor ([URL]) -> Void)? {
        didSet { wireShelf() }
    }

    private func wireShelf() {
        guard let panel else { return }
        guard let send = sendToShelf else {
            panel.actions.onSendToShelf = nil
            return
        }
        panel.actions.onSendToShelf = { url in send([url]) }
    }

    /// The notch Shelf's synced lyrics for the playing track — wired by
    /// the app delegate; the player row shows its current line.
    @ObservationIgnored var lyrics: @MainActor () -> SyncedLyrics? = { nil } {
        didSet { panel?.actions.lyrics = lyrics }
    }
    /// × / Quit on a window or app hosting a live agent needs a second press.
    @ObservationIgnored private var agentGuard = DockAgentGuard()
    /// The open panel's live list — the previewed app's window events.
    @ObservationIgnored private let windowObserver = DockWindowObserver()
    /// The quick-quit tiles last mirrored into the switcher's tap, and
    /// the tile read they came from.
    @ObservationIgnored private var mirroredQuitTargets: [CGRect] = []
    @ObservationIgnored private var quitTargetsStamp: (at: TimeInterval, listFrame: CGRect)?
    /// Tile URL → bundle id, so the mirror never re-opens a bundle it
    /// already read. A tile no bundle answers for stays nil.
    @ObservationIgnored private var tileBundleIDs: [URL: String?] = [:]
    /// The preview action keys last mirrored into the tap.
    @ObservationIgnored private var mirroredChars: Set<String> = []
    /// Windows whose hovered still is being re-taken — one capture each.
    @ObservationIgnored private var freshening = Set<CGWindowID>()
    /// The opt-in live card's stream — at most one window at a time.
    @ObservationIgnored private let liveStill = DockLiveStill()
    /// A preview ⌥` opened from the keyboard: the pointer never rested
    /// on its tile, so the rest-and-grace rules don't close it — Esc,
    /// Return, a click away or resting on another tile do.
    @ObservationIgnored private var keyboardPinned = false

    /// Default-argument expressions are evaluated in the caller's
    /// (nonisolated) context under Swift 6, so the main-actor
    /// `DockEnhancePreferences()` can't be a default value — callers
    /// pass nil and the main-actor body builds it.
    init(preferences: DockEnhancePreferences? = nil,
         autohideHold: DockAutohideHold? = nil,
         switcher: DockSwitcherController? = nil) {
        self.preferences = preferences ?? DockEnhancePreferences()
        self.autohideHold = autohideHold ?? DockAutohideHold()
        self.switcher = switcher ?? DockSwitcherController()
        watchers.onEscape = { [weak self] in
            self?.tracker.reset()
            self?.hidePreview()
        }
        watchers.onOutside = { [weak self] in
            self?.tracker.reset()
            self?.hidePreview()
        }
        watchers.isInside = { [weak self] in
            guard let self, let panel, panel.isVisible else { return true }
            return panel.frame.insetBy(dx: -4, dy: -4).contains(NSEvent.mouseLocation)
        }
        watchers.onKey = { [weak self] keyCode in
            self?.panelKey(keyCode) ?? false
        }
        // The switcher's event tap eats the preview's keys while the
        // panel floats — the watchers only fire with the pointer on
        // the panel, the tap fires with it parked on the Dock too.
        self.switcher.onPreviewKey = { [weak self] code in
            self?.previewTapKey(code)
        }
        self.switcher.onQuickQuit = { [weak self] point, force in
            self?.quickQuit(axPoint: point, force: force)
        }
        self.switcher.onPreviewAction = { [weak self] action in
            self?.previewAction(action)
        }
        self.switcher.onFrontPreview = { [weak self] in self?.previewFrontApp() }
        self.switcher.cachedBadges = { [weak self] in self?.freshBadges() }
        windowObserver.onChange = { [weak self] in self?.refreshLiveWindows() }
        liveStill.onFrame = { [weak self] windowID, image in
            guard let self, let row = self.preview.windows.firstIndex(where: { $0.windowID == windowID })
            else { return }
            self.preview.windows[row].thumbnail = image
        }
    }

    isolated deinit {
        timer?.invalidate()
        panelWarmupTimer?.invalidate()
        unwatchPresence()
    }

    // MARK: Lifecycle

    func start() {
        guard !running else { return }
        running = true
        refreshPermissions(force: true)
        if !accessibilityTrusted {
            // Register + prompt once: nothing else ever calls the
            // prompting API, so a stale or missing TCC entry (a
            // re-signed reinstall loses the grant silently) used to
            // leave the preview dead with no path back but manual
            // pane surgery. With an entry already decided this is a
            // cheap no-op — the system prompts only on an undecided one.
            _ = AXIsProcessTrustedWithOptions(
                ["AXTrustedCheckOptionPrompt": true] as CFDictionary)
        }
        if !screenCaptureGranted && preferences.showThumbnails {
            // The same registration gap: CGPreflightScreenCaptureAccess
            // never creates the pane entry, so a missing grant left the
            // thumbnails on "No preview" with nothing for the user to
            // toggle. Requesting once registers JR-Bar and prompts only
            // while the answer is still undecided.
            screenCaptureGranted = FoldCapturePermission.request()
        }
        Self.log.notice("enhance start: accessibility \(self.accessibilityTrusted, privacy: .public), screen recording \(self.screenCaptureGranted, privacy: .public), dock list \(AppleDockReader.dockPID().flatMap { AppleDockReader.dockList(pid: $0) } != nil, privacy: .public)")
        quickQuitMonitor = NSEvent.addGlobalMonitorForEvents(matching: .rightMouseDown) { [weak self] event in
            guard event.modifierFlags.contains(.command) else { return }
            let force = event.modifierFlags.contains(.option)
            let point = NSEvent.mouseLocation
            Task { @MainActor [weak self] in self?.quickQuit(at: point, force: force) }
        }
        installGestureMonitors()
        watchPresence()
        scheduleTick(after: Self.pollInterval)
        schedulePanelWarmup(layoutOnly: panel != nil)
    }

    /// The sleep, lock and session notices the tick parks on — for as
    /// long as the watcher runs.
    private func watchPresence() {
        guard presenceObservers.isEmpty, lockObservers.isEmpty else { return }
        let workspace = NSWorkspace.shared.notificationCenter
        let notices: [(Notification.Name, DockTickPark.Event)] = [
            (NSWorkspace.screensDidSleepNotification, .displaysSlept),
            (NSWorkspace.screensDidWakeNotification, .displaysWoke),
            (NSWorkspace.sessionDidResignActiveNotification, .sessionLeft),
            (NSWorkspace.sessionDidBecomeActiveNotification, .sessionReturned),
        ]
        for (name, event) in notices {
            presenceObservers.append(workspace.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.notePresence(event) }
            })
        }
        let distributed = DistributedNotificationCenter.default()
        let lockNotices: [(Notification.Name, DockTickPark.Event)] = [
            (DockTickPark.lockedNotification, .locked),
            (DockTickPark.unlockedNotification, .unlocked),
        ]
        for (name, event) in lockNotices {
            lockObservers.append(distributed.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.notePresence(event) }
            })
        }
    }

    private func unwatchPresence() {
        for observer in presenceObservers { NSWorkspace.shared.notificationCenter.removeObserver(observer) }
        for observer in lockObservers { DistributedNotificationCenter.default().removeObserver(observer) }
        presenceObservers = []
        lockObservers = []
        presence = DockTickPark()
    }

    /// A sleep, lock or session notice: the tick parks when the first
    /// reason holds — an open preview closes with it and lets the Dock
    /// go — and comes back at its near rate when the last one lifts.
    func notePresence(_ event: DockTickPark.Event) {
        switch presence.note(event) {
        case .park?:
            timer?.invalidate()
            timer = nil
            if tracker.shown != nil {
                tracker.reset()
                hidePreview()
            }
            Self.log.notice("preview tick parked: \(String(describing: event), privacy: .public)")
        case .resume?:
            guard running else { return }
            Self.log.notice("preview tick resumed: \(String(describing: event), privacy: .public)")
            scheduleTick(after: Self.pollInterval)
        case nil:
            break
        }
    }

    /// Whether the pointer poll is armed — the tests read it.
    var isTicking: Bool { timer != nil }

    /// The Dock-icon gestures the card asks for: a middle-click monitor
    /// under the Middle Click trigger, a scroll monitor with scroll
    /// gestures on. Observe-only global monitors — Apple's Dock ignores
    /// both, nothing is eaten or synthesized — re-seated on every
    /// settings apply so a card edit lands without a restart.
    func installGestureMonitors() {
        let wantsClick = running && preferences.previewTrigger == .middleClick
        if wantsClick, middleClickMonitor == nil {
            middleClickMonitor = NSEvent.addGlobalMonitorForEvents(matching: .otherMouseDown) { [weak self] event in
                guard event.buttonNumber == 2 else { return }
                let point = NSEvent.mouseLocation
                Task { @MainActor [weak self] in self?.middleClick(at: point) }
            }
        } else if !wantsClick, let monitor = middleClickMonitor {
            NSEvent.removeMonitor(monitor)
            middleClickMonitor = nil
        }
        let wantsScroll = running && preferences.scrollGestures
        if wantsScroll, scrollMonitor == nil {
            scrollMonitor = NSEvent.addGlobalMonitorForEvents(matching: .scrollWheel) { [weak self] event in
                guard event.momentumPhase == [] else { return }
                let deltaY = DockEnhanceMath.scrollAmount(event.scrollingDeltaY,
                                                          precise: event.hasPreciseScrollingDeltas)
                let inverted = event.isDirectionInvertedFromDevice
                let now = event.timestamp
                let point = NSEvent.mouseLocation
                Task { @MainActor [weak self] in
                    self?.scroll(at: point, deltaY: deltaY, inverted: inverted, now: now)
                }
            }
        } else if !wantsScroll, let monitor = scrollMonitor {
            NSEvent.removeMonitor(monitor)
            scrollMonitor = nil
        }
        let wantsMinimize = running && preferences.clickToMinimize
        if wantsMinimize, clickMonitor == nil {
            activationObserver = NSWorkspace.shared.notificationCenter.addObserver(
                forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main
            ) { [weak self] note in
                let pid = (note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication)?
                    .processIdentifier
                let at = ProcessInfo.processInfo.systemUptime
                MainActor.assumeIsolated {
                    if let pid { self?.lastActivation = (pid, at) }
                }
            }
            clickMonitor = NSEvent.addGlobalMonitorForEvents(matching: .leftMouseDown) { [weak self] event in
                guard event.modifierFlags.intersection([.command, .option, .control, .shift]).isEmpty else { return }
                let point = NSEvent.mouseLocation
                let at = event.timestamp
                Task { @MainActor [weak self] in self?.clickToMinimize(at: point, clickAt: at) }
            }
        } else if !wantsMinimize, let monitor = clickMonitor {
            NSEvent.removeMonitor(monitor)
            clickMonitor = nil
            if let activationObserver { NSWorkspace.shared.notificationCenter.removeObserver(activationObserver) }
            activationObserver = nil
            lastActivation = nil
        }
    }

    func stop() {
        guard running else { return }
        running = false
        timer?.invalidate()
        timer = nil
        unwatchPresence()
        panelWarmupTimer?.invalidate()
        panelWarmupTimer = nil
        tracker.reset()
        cachedList = nil
        mirroredQuitTargets = []
        quitTargetsStamp = nil
        switcher.setQuickQuitTargets([])
        if let quickQuitMonitor { NSEvent.removeMonitor(quickQuitMonitor) }
        quickQuitMonitor = nil
        installGestureMonitors()
        hidePreview()
    }

    /// The card's appear hook and the tick's gate: re-read TCC only
    /// when the cache is stale (or `force`). Accessibility and the
    /// magnification flag ride the tick's TTL — neither costs an IPC
    /// after the first call. The Screen Recording preflight costs one
    /// every call (2026-09-22: a TCCAccessRequest line on the main
    /// thread every 3.02 s for as long as the app ran), and nothing on
    /// the tick needs it — only thumbnails and the card's row do. So
    /// the tick takes the shared 30 s cache — dropped on re-activate,
    /// when a new grant lands — and only `force` (start, the card
    /// appearing) asks TCC outright.
    func refreshPermissions(force: Bool = false) {
        guard force || Date().timeIntervalSince(permissionsCheckedAt) > Self.permissionTTL else { return }
        permissionsCheckedAt = Date()
        let wasTrusted = accessibilityTrusted
        accessibilityTrusted = AXIsProcessTrusted()
        screenCaptureGranted = force ? FoldCapturePermission.recheck() : FoldCapturePermission.granted
        let dockDefaults = UserDefaults(suiteName: "com.apple.dock")
        magnificationOn = dockDefaults?.bool(forKey: "magnification") ?? false
        magnifiedSize = (dockDefaults?.object(forKey: "largesize") as? NSNumber).map { CGFloat($0.doubleValue) }
        if running, !wasTrusted, accessibilityTrusted {
            schedulePanelWarmup(layoutOnly: panel != nil)
        }
    }

    /// Prepare the retained, empty panel before the first hover. Default
    /// run-loop mode avoids doing this while a menu or drag is tracking.
    /// Separate turns keep construction and first layout from forming one
    /// long synchronous operation. Nothing is shown or captured here.
    private func schedulePanelWarmup(layoutOnly: Bool) {
        panelWarmupTimer?.invalidate()
        let timer = Timer(timeInterval: layoutOnly ? 0.1 : 1.0, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.panelWarmupTimer = nil
                guard self.running, self.accessibilityTrusted else { return }
                let start = ProcessInfo.processInfo.systemUptime
                if layoutOnly {
                    guard let panel = self.panel, !panel.isVisible else { return }
                    _ = panel.fittingSize()
                } else {
                    guard self.panel == nil else { return }
                    _ = self.ensurePanel()
                    self.schedulePanelWarmup(layoutOnly: true)
                }
                let milliseconds = (ProcessInfo.processInfo.systemUptime - start) * 1000
                Self.log.notice("preview warmup \(layoutOnly ? "layout" : "construction", privacy: .public): \(milliseconds, privacy: .public) ms")
            }
        }
        panelWarmupTimer = timer
        RunLoop.main.add(timer, forMode: .default)
    }

    /// The frame a panel anchors on: the tile's, or under magnification
    /// the tile's size at the pointer along the dock's run — x for a
    /// bottom Dock, y for a side one.
    private func anchorFrame(for item: DockAXItem, edge: DockEdge, pointer: NSPoint) -> CGRect {
        let tile = DockEnhanceMath.appKitRect(item.frame, mainScreenHeight: DockDisplays.primaryHeight())
        // A keyboard-opened preview: the pointer isn't on the Dock, so
        // nothing is magnified and the tile's own frame is the icon.
        guard magnificationOn, !keyboardPinned else { return tile }
        return DockEnhanceMath.magnifiedAnchor(tile: tile, edge: edge, pointer: pointer)
    }

    // MARK: The tick

    /// One-shot, re-armed at the cadence the pointer's position earns:
    /// 20 Hz near a screen edge, inside the dock's own reach, or while
    /// a panel is up — the band a first hover can land in — 8 Hz
    /// elsewhere. In-reach polling pays the same per-tick cost the
    /// pointer already costs while resting on the Dock; the far band
    /// stays cheap. Parked (`presence`), nothing is re-armed.
    private func scheduleTick(after interval: TimeInterval) {
        self.timer?.invalidate()
        let timer = Timer.scheduledTimer(withTimeInterval: interval, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.running, !self.presence.parked else { return }
                self.tick()
                let axPoint = DockEnhanceMath.axPoint(NSEvent.mouseLocation,
                                                      mainScreenHeight: DockDisplays.primaryHeight())
                let overDock = self.cachedList.map { Self.listReach(of: $0.frame).contains(axPoint) } ?? false
                let near = Self.nearScreenEdge(axPoint) || overDock
                    || self.tracker.shown != nil || self.pointerInPanel()
                self.scheduleTick(after: near ? Self.pollInterval : Self.farPollInterval)
            }
        }
        // A tenth of the period (5 ms near, 12.5 ms far) lets these
        // wakes coalesce with the system's own; a hover never feels it.
        timer.tolerance = interval / 10
        self.timer = timer
    }

    private func tick() {
        refreshPermissions()
        let inPanel = pointerInPanel()
        guard accessibilityTrusted else {
            if tracker.shown != nil { tracker.reset(); hidePreview() }
            return
        }
        let axPoint = DockEnhanceMath.axPoint(
            NSEvent.mouseLocation, mainScreenHeight: DockDisplays.primaryHeight())
        var hovered: DockAXItem?
        if let list = dockList(near: axPoint) {
            if Self.listReach(of: list.frame).contains(axPoint) {
                hovered = tiles(of: list).first { $0.frame.contains(axPoint) }
            }
        }
        // The tap decides synchronously whether a ⌘-right-click is a
        // quick quit — it reads this mirror, not the main-actor cache.
        mirrorQuickQuitTargets()
        mirrorPreviewChars(pointerInPanel: inPanel)
        let tracked = DockHoverTracker.trackedItem(
            hovered?.hoverID, shown: tracker.shown, trigger: preferences.previewTrigger,
            optionHeld: NSEvent.modifierFlags.contains(.option))
        // A keyboard-opened preview holds like one with the pointer on it.
        let action = tracker.note(hovered: tracked, pointerInPanel: inPanel || keyboardPinned,
                                  now: CACurrentMediaTime(), delay: preferences.previewDelay)
        switch action {
        case .show:
            if let hovered {
                keyboardPinned = false
                showPreview(for: hovered)
            }
        case .hide:
            hidePreview()
        case .none:
            if let hovered, hovered.hoverID == tracker.shown { anchorPanel(to: hovered) }
        }
    }

    /// Mirror the tiles quick quit can act on into the tap, re-derived
    /// only when the tile read or the list's frame changed: the tick
    /// re-reads the tiles whenever the pointer is in the Dock's reach,
    /// so a ⌘-right-click on a tile always meets a fresh mirror. A list
    /// that moved or hid since its tiles were read mirrors nothing.
    private func mirrorQuickQuitTargets() {
        var targets: [CGRect] = []
        if let list = cachedList, let cached = cachedItems, cached.listFrame == list.frame {
            if let stamp = quitTargetsStamp, stamp.at == cached.at, stamp.listFrame == list.frame {
                return
            }
            quitTargetsStamp = (cached.at, list.frame)
            let running = RunningApps.shared.bundleIDs
            targets = Self.quickQuitTargets(
                cached.items.map { ($0.frame, $0.kind, $0.url.flatMap(bundleID(forTile:))) },
                running: running)
        } else {
            quitTargetsStamp = nil
        }
        guard targets != mirroredQuitTargets else { return }
        mirroredQuitTargets = targets
        switcher.setQuickQuitTargets(targets)
    }

    /// The frames a ⌘-right-click is eaten over: the tiles quick quit
    /// acts on — a running app that isn't JR-Bar. Folders, the Trash, a
    /// pinned app that isn't running and the air above the tiles all
    /// keep their click, and so does the window under them.
    static func quickQuitTargets(_ tiles: [(frame: CGRect, kind: DockAXItem.Kind, bundleID: String?)],
                                 running: Set<String>) -> [CGRect] {
        tiles.compactMap { tile in
            guard tile.kind == .app, let id = tile.bundleID, running.contains(id),
                  !MenuBarUtility.isOwnFamily(id) else { return nil }
            return tile.frame
        }
    }

    private func bundleID(forTile url: URL) -> String? {
        if let known = tileBundleIDs[url] { return known }
        let id = Bundle(url: url)?.bundleIdentifier
        tileBundleIDs[url] = .some(id)
        return id
    }

    /// The list's app tiles — the cached read while it is fresh and the
    /// list has not moved, else one walk.
    private func tiles(of list: (element: AXUIElement, frame: CGRect)) -> [DockAXItem] {
        let now = CACurrentMediaTime()
        // Fresh frames while a panel is up: under magnification the
        // tiles move with the pointer, and a panel anchored on a
        // quarter-second-old frame sat visibly off its icon.
        let live = tracker.shown != nil
        if !live, let cached = cachedItems, cached.listFrame == list.frame, now - cached.at < Self.itemsTTL {
            return cached.items
        }
        let items = AppleDockReader.items(list: list.element)
        cachedItems = (list.frame, items, now)
        return items
    }

    /// The Dock's unread badges from the tile read the tick keeps, while
    /// it is inside `itemsTTL` — the ⌥⇥ strip's cards take them without
    /// a walk of their own. nil once the read has aged.
    func freshBadges(now: TimeInterval = CACurrentMediaTime()) -> [String: String]? {
        guard let cached = cachedItems, now - cached.at < Self.itemsTTL else { return nil }
        return DockSwitcherList.badges(of: cached.items)
    }

    static let log = Logger(subsystem: "devin.jrbar", category: "dock")

    /// The dock list, re-read from AX when the cache is stale or the
    /// pointer is inside the last known frame (a magnified or moved
    /// Dock reflows its list, and only a live read follows it).
    private func dockList(near point: CGPoint) -> (element: AXUIElement, frame: CGRect)? {
        let now = CACurrentMediaTime()
        if let cached = cachedList {
            let inside = Self.listReach(of: cached.frame).contains(point)
            let ttl = Self.nearScreenEdge(point) ? Self.edgeListFrameTTL : Self.listFrameTTL
            if !inside, now - cached.at < ttl {
                return (cached.element, cached.frame)
            }
        }
        guard let pid = AppleDockReader.dockPID(),
              let list = AppleDockReader.dockList(pid: pid),
              let frame = AppleDockReader.frame(of: list) else {
            // A Dock that relaunched unannounced answers nothing at the
            // pid kept for it — the next read asks the workspace again.
            AppleDockReader.forgetDockPID()
            cachedList = nil
            return nil
        }
        cachedList = (list, frame, now)
        return (list, frame)
    }

    /// Whether an AX-space point is within `edgeReach` of the bottom,
    /// left or right edge of the screen that holds it — where an
    /// auto-hidden Dock lives.
    private static func nearScreenEdge(_ axPoint: CGPoint) -> Bool {
        let height = DockDisplays.primaryHeight()
        let appKit = CGPoint(x: axPoint.x, y: height - axPoint.y)
        guard let screen = NSScreen.screens.first(where: { $0.frame.contains(appKit) }) else { return false }
        let f = screen.frame
        return appKit.y - f.minY < Self.edgeReach || appKit.x - f.minX < Self.edgeReach
            || f.maxX - appKit.x < Self.edgeReach
    }

    private func pointerInPanel() -> Bool {
        guard let panel, panel.isVisible else { return false }
        let pointer = NSEvent.mouseLocation
        if panel.frame.insetBy(dx: -4, dy: -4).contains(pointer) { return true }
        // The panel owns the screen's centre now — the road from the
        // tile to it crosses open desk, and a pointer on that road is
        // travelling, not leaving.
        guard let anchor else { return false }
        let itemFrame = anchorFrame(for: anchor.item, edge: anchor.edge, pointer: pointer)
        return DockEnhanceMath.inCorridor(item: itemFrame, panel: panel.frame,
                                          edge: anchor.edge, point: pointer, slop: 6)
    }

    // MARK: Show / hide

    private func showPreview(for item: DockAXItem) {
        generation += 1
        liveStill.stop()
        let generationAtShow = generation
        if let mediaToken { MediaFeed.shared.unsubscribe(mediaToken) }
        mediaToken = nil
        preview.largeCards = preferences.largePreviews
        preview.metrics = preferences.metrics
        preview.hugWindows = preferences.cardsHugWindows
        fill(preview, for: item)

        // Nothing to preview — no windows to raise — is no panel. A
        // running app with no windows earned a header-only chip on
        // every pass before; an app not running has the Dock's own
        // click to open it. A folder tile pops even when empty — the
        // pop is the point of the hover — and a player or the Calendar
        // tile earns its row even without a window. The tracker keeps
        // the tile as shown, so this does not retry on every tick.
        let earnsRow = preview.bundleID.map {
            DockEnhanceMath.playerBundleIDs.contains($0)
                || $0 == DockEnhanceMath.calendarBundleID
        } ?? false
        guard !preview.windows.isEmpty || preview.folderURL != nil || earnsRow else {
            hidePreview()
            return
        }
        preview.compact = DockEnhanceMath.compactList(
            windowCount: preview.windows.count, limit: preferences.compactListLimit)

        // Hold an auto-hiding Dock out for the life of the panel —
        // without it the Dock slides away the moment the pointer steps
        // from an icon onto the cards.
        if preferences.holdDockOpen { autohideHold.hold() }

        let mainHeight = DockDisplays.primaryHeight()
        // The screen under the pointer: a sliding Dock's tiles report
        // below the screen, where no screen contains them.
        let pointer = NSEvent.mouseLocation
        let tile = DockEnhanceMath.appKitRect(item.frame, mainScreenHeight: mainHeight)
        // A keyboard-opened preview belongs to the tile's screen, not the
        // pointer's — an auto-hidden Dock's tile sits below it, so its
        // run along the screen's width decides.
        let tileScreen = keyboardPinned
            ? NSScreen.screens.first { $0.frame.contains(CGPoint(x: tile.midX, y: tile.midY)) }
                ?? NSScreen.screens.first { $0.frame.minX <= tile.midX && tile.midX < $0.frame.maxX }
            : nil
        let screen = tileScreen
            ?? NSScreen.screens.first { $0.frame.contains(pointer) }
            ?? NSScreen.screens.first { $0.frame.contains(tile.origin) }
            ?? NSScreen.main ?? NSScreen.screens.first
        let screenFrame = screen?.frame ?? .zero
        let listFrame = cachedList.map {
            DockEnhanceMath.appKitRect($0.frame, mainScreenHeight: mainHeight)
        } ?? tile
        let edge = DockEnhanceMath.dockEdge(listFrame: listFrame, screen: screenFrame)
        let itemFrame = anchorFrame(for: item, edge: edge, pointer: pointer)
        anchor = (item, edge, screenFrame)

        let panel = ensurePanel()
        panel.apply(preview.metrics)
        let place = placement
        let target = targetFrame(item: itemFrame, edge: edge, screen: screenFrame,
                                 size: panel.fittingSize(), placement: place)
        panel.present(frame: target, dockedAt: edge, placement: place)
        watchers.start(escape: true, clickAway: true)
        switcher.setPreviewOpen(true)
        // An app tile's cards follow the app while the panel is up — a
        // window opened or closed elsewhere lands without a re-hover. A
        // minimized-window tile previews its one window, never the list.
        if item.kind == .app, let pid = preview.processIdentifier {
            windowObserver.observe(pid: pid, windows: preview.windows.compactMap(\.element))
        } else {
            windowObserver.stop()
        }

        // A folder's entries list on a background queue — one stall
        // inside the directory must never reach the main thread. The
        // generation check is the same stale-guard the thumbnails use.
        // The sleep races the read: a TCC consent that cannot prompt
        // (~5s auth pend) or a stuck vnode resolves to `failed` rather
        // than an eternal spinner; the abandoned read's write-back is
        // generation-guarded away.
        if let folderURL = preview.folderURL {
            // The tile's own Sort By — a read of the Dock's preferences,
            // never a write — so the pop leads where the stack does, and
            // so does every folder drilled into from it.
            folderSort = DockFolderSort.of(
                folder: folderURL,
                persistentOthers: UserDefaults(suiteName: AppleDockReader.dockBundleID)?
                    .array(forKey: "persistent-others"))
            loadFolder(folderURL, generation: generationAtShow)
        }

        // A player tile subscribes to the shared Now Playing feed for
        // the life of its panel — any app tile too while another surface
        // already runs the feed; the reader applies the bundle match —
        // a track from a different app never lands on this one.
        if let bundleID = preview.bundleID,
           DockEnhanceMath.readsMedia(appBundleID: bundleID, feedRunning: MediaFeed.shared.isRunning) {
            mediaToken = MediaFeed.shared.subscribe { [weak self] media in
                guard let self, self.generation == generationAtShow else { return }
                self.preview.media = media.flatMap {
                    DockEnhanceMath.showsMediaRow(
                        mediaBundleID: $0.bundleIdentifier,
                        appBundleID: bundleID) ? $0 : nil
                }
                self.reframe()
            }
        }

        // The Calendar tile: read the rest of today only when the grant
        // already exists — a hover never prompts, it offers. A meeting
        // app's tile reads too, but only under an existing grant: it
        // never offers one.
        if let bundleID = preview.bundleID, DockEnhanceMath.isMeetingApp(bundleID),
           EKEventStore.authorizationStatus(for: .event) == .fullAccess {
            loadCalendarRow(generation: generationAtShow, meetingApp: bundleID)
        }
        if preview.bundleID == DockEnhanceMath.calendarBundleID {
            switch EKEventStore.authorizationStatus(for: .event) {
            case .fullAccess:
                loadCalendarRow(generation: generationAtShow)
            case .notDetermined, .writeOnly:
                preview.calendarNeedsAuth = true
            case .denied, .restricted:
                break
            @unknown default:
                break
            }
        }

        if preferences.showThumbnails, !preview.compact, screenCaptureGranted,
           let pid = preview.processIdentifier {
            let bundleID = preview.bundleID
            // A minimized-window tile is one window the pointer chose —
            // its single still is taken even with "Capture every
            // window" off, so the card shows what's inside, not an icon.
            let offscreen = preferences.includeOffscreenWindows || item.kind == .minimizedWindow
            Task { @MainActor [weak self] in
                guard let self else { return }
                await DockThumbnailer.attach(
                    to: preview, bundleID: bundleID, pid: pid,
                    includeOffscreen: offscreen,
                    isStale: { [weak self] in self?.generation != generationAtShow })
            }
        }
    }

    private func hidePreview() {
        generation += 1
        keyboardPinned = false
        liveStill.stop()
        anchor = nil
        windowObserver.stop()
        if let mediaToken { MediaFeed.shared.unsubscribe(mediaToken) }
        mediaToken = nil
        watchers.stop()
        switcher.setPreviewOpen(false)
        panel?.dismiss()
        autohideHold.release()
    }

    /// The open pop's sort — the tile's, read at show.
    @ObservationIgnored private var folderSort: DockFolderSort = .name

    /// List one folder into the pop. The generation check is the stale
    /// guard the thumbnails use, and the folder check drops a listing
    /// the pop has since drilled or backed away from. The sleep races
    /// the read: a TCC consent that cannot prompt (~5s auth pend) or a
    /// stuck vnode resolves to `failed` rather than an eternal spinner.
    private func loadFolder(_ url: URL, generation generationAtLoad: Int) {
        preview.folderState = .loading
        preview.folderEntries = []
        preview.folderLoadStarted = Date()
        let sort = folderSort
        Task { @MainActor [weak self] in
            let work = Task.detached(priority: .userInitiated) {
                Self.folderListing(of: url, sort: sort)
            }
            let listing = await withTaskGroup(
                of: DockFolderListing?.self,
                returning: DockFolderListing?.self
            ) { group in
                group.addTask { await work.value }
                group.addTask {
                    try? await Task.sleep(for: .seconds(6))
                    return nil
                }
                let first = await group.next() ?? nil
                group.cancelAll()
                return first
            }
            guard let self, self.generation == generationAtLoad,
                  self.preview.folderShown == url else { return }
            if let listing {
                self.preview.folderEntries = listing.entries
                if let icon = listing.folderIcon { self.preview.icon = icon }
                self.preview.folderState = listing.denied ? .denied : .ready
            } else {
                self.preview.folderState = .failed
            }
            // The pointer is on the grid, not the tile, so the tick's
            // re-anchor won't refit it — the new size lands here.
            self.reframe()
        }
    }

    /// A folder chip's click: browse into it in place — Apple's Grid
    /// stack, one level at a time, with the header's chevron back out.
    private func drillFolder(_ url: URL) {
        guard let root = preview.folderURL,
              let trail = DockEnhanceMath.drilledTrail(preview.folderTrail, root: root, into: url) else { return }
        preview.folderTrail = trail
        loadFolder(url, generation: generation)
        reframe()
    }

    /// The header's chevron: one folder back up the trail.
    private func folderBack() {
        guard !preview.folderTrail.isEmpty else { return }
        preview.folderTrail.removeLast()
        guard let shown = preview.folderShown else { return }
        loadFolder(shown, generation: generation)
        reframe()
    }

    /// The previewed app's windows changed under the open panel — a new
    /// one, a closed one, a retitle, a minimize. Re-list, keep every
    /// surviving card's id and still, and watch the newcomers. The panel
    /// moves only when its size changed, and stills are fetched only for
    /// newcomers and windows just back from the Dock: a retitle is a
    /// re-list and nothing more.
    private func refreshLiveWindows(force: Bool = false) {
        guard let panel, panel.isVisible, let pid = preview.processIdentifier,
              force || windowObserver.pid == pid, preview.folderURL == nil else { return }
        let old = preview.windows
        let merged = DockEnhanceMath.mergeWindows(old: old, new: listWindows(pid: pid))
        guard DockEnhanceMath.cardsDiffer(old, merged) else { return }
        preview.windows = merged
        windowObserver.watch(merged.compactMap(\.element))
        if let selected = preview.selectedWindowID, !merged.contains(where: { $0.id == selected }) {
            preview.selectedWindowID = nil
        }
        applyAgents(to: preview)
        let earnsRow = preview.bundleID.map {
            DockEnhanceMath.playerBundleIDs.contains($0) || $0 == DockEnhanceMath.calendarBundleID
        } ?? false
        if merged.isEmpty, !earnsRow {
            // The app's last window closed elsewhere — nothing left to raise.
            tracker.reset()
            hidePreview()
            return
        }
        preview.compact = DockEnhanceMath.compactList(
            windowCount: merged.count, limit: preferences.compactListLimit)
        reframe(onlyIfResized: true)
        guard preferences.showThumbnails, !preview.compact, screenCaptureGranted,
              DockEnhanceMath.wantsStills(old: old, new: merged) else { return }
        let generationAtRefresh = generation
        let bundleID = preview.bundleID
        let offscreen = preferences.includeOffscreenWindows
        Task { @MainActor [weak self] in
            guard let self else { return }
            await DockThumbnailer.attach(
                to: self.preview, bundleID: bundleID, pid: pid,
                includeOffscreen: offscreen,
                isStale: { [weak self] in self?.generation != generationAtRefresh })
        }
    }

    /// The pointer landed on a card: with the live card on, that window
    /// streams while the pointer stays; otherwise its still is freshened
    /// if it has aged past a glance.
    private func hoverCard(_ window: DockPreviewWindow) {
        guard DockEnhanceMath.streamsLive(liveCard: preferences.liveCard,
                                          thumbnails: preferences.showThumbnails,
                                          granted: screenCaptureGranted, compact: preview.compact,
                                          minimized: window.minimized,
                                          offscreen: preferences.includeOffscreenWindows),
              let pid = preview.processIdentifier, let windowID = window.windowID else {
            freshenStill(window)
            return
        }
        liveStill.start(windowID: windowID, pid: pid)
    }

    /// The pointer left a card: its stream stops, the last frame stays.
    private func leaveCard(_ window: DockPreviewWindow) {
        guard let windowID = window.windowID, liveStill.windowID == windowID else { return }
        liveStill.stop()
    }

    /// A hovered card whose still has aged past a glance, or predates
    /// its agent's current state, re-takes that one window; the other
    /// cards keep the cache. Minimized and other-Space windows only when
    /// the card captures those at all.
    private func freshenStill(_ window: DockPreviewWindow) {
        guard preferences.showThumbnails, screenCaptureGranted, !preview.compact,
              let pid = preview.processIdentifier, let windowID = window.windowID,
              !window.minimized || preferences.includeOffscreenWindows,
              !freshening.contains(windowID) else { return }
        let tag = preview.agents[window.id]?.stillTag
        let cached = DockThumbnailer.cached(pid: pid, windowID: windowID)
        guard DockThumbnailer.wantsHoverRefresh(hasStill: window.thumbnail != nil, age: cached?.age,
                                                cachedTag: cached?.tag, tag: tag) else { return }
        freshening.insert(windowID)
        let generationAtHover = generation
        let cardID = window.id
        Task { @MainActor [weak self] in
            let image = await DockThumbnailer.fresh(windowID: windowID, pid: pid, tag: tag)
            guard let self else { return }
            self.freshening.remove(windowID)
            guard let image, self.generation == generationAtHover, self.preview.processIdentifier == pid,
                  let row = self.preview.windows.firstIndex(where: { $0.id == cardID }) else { return }
            self.preview.windows[row].thumbnail = image
        }
    }

    /// Keep the visible panel on its tile: the tile's frame moves while
    /// an auto-hidden Dock slides in, and the content's fitting size
    /// settles a beat after it was first measured. Only a real change
    /// moves the frame, without animation — it is a correction, not a
    /// retarget.
    private func anchorPanel(to item: DockAXItem) {
        guard let panel, panel.isVisible, let anchor else { return }
        let itemFrame = anchorFrame(for: item, edge: anchor.edge, pointer: NSEvent.mouseLocation)
        let place = placement
        let target = targetFrame(item: itemFrame, edge: anchor.edge, screen: anchor.screen,
                                 size: panel.fittingSize(), placement: place)
        panel.hold(place)
        self.anchor = (item, anchor.edge, anchor.screen)
        if abs(target.minX - panel.frame.minX) > 1 || abs(target.minY - panel.frame.minY) > 1
            || abs(target.width - panel.frame.width) > 1 || abs(target.height - panel.frame.height) > 1 {
            panel.setFrame(target, display: true)
        }
    }

    /// How far off the Dock the panel opens, from the card as it stands:
    /// read at every show, re-anchor and refit, so a knob changed in
    /// Settings lands on the next move.
    private var placement: DockPlacement {
        DockPlacement(gap: CGFloat(preferences.dockGap), coversLabel: preferences.coverDockLabel,
                      magnifying: magnificationOn && !keyboardPinned, largesize: magnifiedSize)
    }

    /// The one frame the show, the re-anchor and the refit share: the
    /// panel of `size` off the tile `item` (the anchor — under
    /// magnification the icon at the pointer) toward the screen's middle.
    private func targetFrame(item itemFrame: CGRect, edge: DockEdge, screen: CGRect, size: CGSize,
                             placement place: DockPlacement) -> CGRect {
        place.frame(anchor: itemFrame, edge: edge, size: size, screen: screen, title: preview.appName)
    }

    /// The retained panel, built once with its actions wired — internal
    /// (not private) so a test can read the wiring without a hover.
    func ensurePanel() -> DockPreviewPanel {
        if let panel { return panel }
        let panel = DockPreviewPanel(content: preview)
        panel.actions.onPick = { [weak self] window in self?.pick(window) }
        panel.actions.onPickKeepOpen = { [weak self] window in self?.pick(window, keepOpen: true) }
        panel.actions.onClose = { [weak self] window in self?.close(window) }
        panel.actions.onMinimize = { [weak self] window in self?.toggleMinimized(window) }
        panel.actions.onFullScreen = { [weak self] window in self?.toggleFullScreen(window) }
        panel.actions.onTile = { [weak self] window, tile in self?.tile(window, tile) }
        panel.actions.onNewWindow = { [weak self] in self?.newWindow() }
        panel.actions.onQuitApp = { [weak self] in self?.quitApp() }
        panel.actions.onHideApp = { [weak self] in self?.hideApp() }
        panel.actions.onMinimizeAll = { [weak self] in self?.minimizeAll() }
        panel.actions.onCloseAll = { [weak self] in self?.closeAll() }
        panel.actions.onOpen = { [weak self] url in self?.openItem(url) }
        panel.actions.onMediaCommand = { MediaFeed.shared.send($0) }
        panel.actions.onMediaSeek = { MediaFeed.shared.seek(to: $0) }
        panel.actions.lyrics = lyrics
        panel.actions.onReveal = { url in NSWorkspace.shared.activateFileViewerSelecting([url]) }
        panel.actions.onDrillFolder = { [weak self] url in self?.drillFolder(url) }
        panel.actions.onFolderBack = { [weak self] in self?.folderBack() }
        panel.actions.onShake = { [weak self] window in self?.shakeOthers(window) }
        panel.actions.onSwipeMinimize = { [weak self] window, minimize in
            self?.swipeMinimize(window, minimize)
        }
        panel.actions.onCalendarAuth = { [weak self] in self?.authorizeCalendar() }
        panel.actions.onCalendarJoin = { url in
            guard let url else { return }
            NSWorkspace.shared.open(url)
        }
        panel.actions.onDocumentDrop = { [weak self] url in self?.openDocumentInPreview(url) ?? false }
        panel.actions.onAnswered = { [weak self] in self?.reframe(onlyIfResized: true) }
        panel.actions.onMoveToDisplay = { [weak self] window, display in
            self?.move(window, toDisplay: display)
        }
        panel.actions.onHoverCard = { [weak self] window in self?.hoverCard(window) }
        panel.actions.onHoverCardEnd = { [weak self] window in self?.leaveCard(window) }
        panel.actions.onExcludeApp = { [weak self] in self?.excludePreviewedApp() }
        self.panel = panel
        wireShelf()
        return panel
    }

    /// A document card dropped on this preview: the previewed app
    /// opens the file — the same verb as dropping the document on the
    /// app's Dock tile, one panel nearer.
    private func openDocumentInPreview(_ url: URL) -> Bool {
        guard url.isFileURL, FileManager.default.fileExists(atPath: url.path),
              let bundleID = preview.bundleID,
              let appURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID)
        else { return false }
        NSWorkspace.shared.open([url], withApplicationAt: appURL,
                                configuration: NSWorkspace.OpenConfiguration())
        Self.log.notice("document handoff: \(url.lastPathComponent, privacy: .public) → \(bundleID, privacy: .public)")
        return true
    }

    /// What a hovered tile resolves to: a running app via the tile's
    /// `AXURL`/bundle id or a title match, else a bare "open me" card.
    /// A folder tile skips all of it and pops the directory's entries.
    private func fill(_ content: DockPreviewContent, for item: DockAXItem) {
        defer { applyAgents(to: content) }
        let appURL = item.url
        content.folderURL = nil
        content.folderTrail = []
        content.folderEntries = []
        content.media = nil
        content.calendarEvents = []
        content.calendarFreeUntil = nil
        content.calendarNeedsAuth = false
        content.badge = item.badge
        content.armedWindowID = nil
        content.armedNote = nil
        content.pulsedWindowIDs = []
        content.headerNote = nil
        content.stillRunning = false
        agentGuard.reset()
        if item.kind == .folder {
            content.folderURL = appURL
            content.appName = appURL?.lastPathComponent ?? item.title ?? "Folder"
            // The generic folder glyph comes from LaunchServices — no
            // file access. `icon(forFile:)` would open the folder and,
            // on a TCC-gated path like Downloads, stall the main
            // thread seconds while the consent check pends. The real
            // icon upgrades with the entries off-actor.
            content.icon = NSWorkspace.shared.icon(for: .folder)
            content.folderEntries = []
            content.folderState = .loading
            content.bundleID = nil
            content.appURL = appURL
            content.processIdentifier = nil
            content.isRunning = false
            content.windows = []
            return
        }
        if item.kind == .minimizedWindow {
            fillMinimizedWindow(content, for: item)
            return
        }
        let bundleID = appURL.flatMap { Bundle(url: $0)?.bundleIdentifier }
        // An excluded app rests and earns nothing — DockDoor's app
        // filter. The tile reads as shown so the tick never retries.
        if let bundleID, preferences.excludedBundleIDs.contains(bundleID) {
            content.appName = item.title
                ?? appURL?.deletingPathExtension().lastPathComponent ?? "Dock item"
            content.icon = nil
            content.bundleID = nil
            content.appURL = nil
            content.processIdentifier = nil
            content.isRunning = false
            content.windows = []
            return
        }
        let running = bundleID.flatMap {
            NSRunningApplication.runningApplications(withBundleIdentifier: $0).first
        } ?? NSWorkspace.shared.runningApplications.first {
            $0.localizedName == item.title && $0.activationPolicy == .regular
        }
        content.appName = running?.localizedName ?? item.title
            ?? appURL?.deletingPathExtension().lastPathComponent ?? "Dock item"
        content.bundleID = running?.bundleIdentifier ?? bundleID
        content.appURL = running?.bundleURL ?? appURL
        content.processIdentifier = running?.processIdentifier
        content.isRunning = running != nil && !(running?.isTerminated ?? true)
        content.icon = running?.icon
            ?? appURL.map { DockIconResolver.icon(appURL: $0, pointSize: 64, scale: 2) }
        content.windows = running.map { listWindows(pid: $0.processIdentifier) } ?? []
        content.selectedWindowID = nil
    }

    /// One app's cards: its AX windows, narrowed to the Dock's display
    /// when the card asks — DockDoor's per-monitor filter; the Dock is
    /// on the pointer's screen, and so are the windows worth previewing
    /// from it.
    private func listWindows(pid: pid_t) -> [DockPreviewWindow] {
        let windows = AppleDockReader.windows(pid: pid)
        guard preferences.previewThisDisplay, let display = DockDisplays.pointerDisplayQuartz() else { return windows }
        return DockEnhanceMath.onDisplay(windows, display: display)
    }

    /// Mark the cards whose windows host an agent session, and collect
    /// every live session the previewed app hosts for the header count,
    /// the ask rows and Quit's guard. Re-run whenever the card list
    /// changes under the panel.
    private func applyAgents(to content: DockPreviewContent) {
        let marks = agentMarks()
        let mapped = DockEnhanceMath.agentMap(windows: content.windows,
                                              bundleID: content.bundleID,
                                              marks: marks,
                                              soleAppWindows: isSoleAppWindow(content, marks: marks))
        content.agents = mapped.cards
        content.appAgents = mapped.app
    }

    /// Whether the previewed app-hosted agent's one card is its only
    /// window anywhere — the sole-window rule weighed as ⌥⇥ weighs it,
    /// against every window the window server lists for the app: other
    /// displays, other Spaces and the Dock count, though the display
    /// filter, AX and a minimized tile's own card leave them out.
    /// Asked only when the answer could mark a card.
    private func isSoleAppWindow(_ content: DockPreviewContent, marks: [DockAgentMark]) -> Bool {
        guard content.windows.count == 1, let pid = content.processIdentifier,
              let bundleID = content.bundleID, DockAgentMatch.appHostedBundleIDs.contains(bundleID),
              marks.contains(where: { $0.hosts.contains(bundleID) }) else { return false }
        let listed = DockSwitcherList.onScreenRows(running: [pid]).count
            + DockSwitcherList.offScreenRows(running: [pid]).count
        return listed <= 1
    }

    /// A minimized-window tile: the Dock gives the tile the window's
    /// title and frame but no `AXURL`, so the owning app resolves
    /// through the off-screen window list — the same read the ⌥⇥
    /// switcher does for its minimized rows. The preview shows just
    /// that window: the AX row when it matches (the card's verbs then
    /// act on the real window), else the tile itself — its `AXPress`
    /// IS the system's restore.
    private func fillMinimizedWindow(_ content: DockPreviewContent, for item: DockAXItem) {
        let title = item.title ?? "Window"
        content.appName = title
        content.bundleID = nil
        content.appURL = nil
        content.processIdentifier = nil
        content.isRunning = false
        content.icon = nil
        content.selectedWindowID = nil
        var card = DockPreviewWindow(id: 0, title: title, minimized: true,
                                     fullScreen: nil, frame: nil, element: item.element)
        // A tile with no usable title can't be matched to an owner —
        // the tile-backed card still previews and restores.
        guard let itemTitle = item.title, !itemTitle.isEmpty else {
            content.windows = [card]
            return
        }
        let offRows = DockSwitcherList.offScreenRows()
        guard let pid = DockSwitcherList.minimizedOwnerPID(
            title: itemTitle, rows: offRows, axWindows: { AppleDockReader.windows(pid: $0) }),
              let app = NSRunningApplication(processIdentifier: pid),
              app.activationPolicy == .regular else {
            content.windows = [card]
            return
        }
        if let bundleID = app.bundleIdentifier,
           preferences.excludedBundleIDs.contains(bundleID) {
            // An excluded app rests and earns nothing — same rule the
            // app tiles follow.
            content.windows = []
            return
        }
        content.appName = app.localizedName ?? title
        content.bundleID = app.bundleIdentifier
        content.appURL = app.bundleURL
        content.processIdentifier = pid
        content.isRunning = true
        content.icon = app.icon
        let rows = offRows.filter { $0.pid == pid && $0.title == itemTitle }
        let axWindows = AppleDockReader.windows(pid: pid)
        // A same-titled window parked on another Space shares the
        // off-screen list; only a minimized one can be this tile.
        let matched = rows.compactMap { DockSwitcherList.match(row: $0, in: axWindows) }
        let minimizedHits = matched.filter(\.minimized)
        let hits = minimizedHits.isEmpty ? matched : minimizedHits
        if hits.count == 1 {
            content.windows = [hits[0]]
        } else {
            // Zero or several AX claimants — the tile-backed card keeps
            // the CG id and bounds so its thumbnail can still land.
            card.frame = rows.first?.bounds
            card.windowID = rows.first?.windowID
            content.windows = [card]
        }
    }

    // MARK: Verbs

    /// A window card's click — raise it and bring the app forward. With
    /// `keepOpen` (⌥-click) the panel stays and the raised card becomes
    /// the walked one, so the next ⌥-click, arrow or W carries on from it.
    private func pick(_ window: DockPreviewWindow, keepOpen: Bool = false) {
        let app = preview.processIdentifier.flatMap { NSRunningApplication(processIdentifier: $0) }
        AppleDockReader.raise(window, app: app)
        guard keepOpen else {
            tracker.reset()
            hidePreview()
            return
        }
        preview.selectedWindowID = window.id
        mirrorPreviewChars()
        if let index = preview.windows.firstIndex(where: { $0.id == window.id }) {
            preview.windows[index].minimized = false
        }
    }

    /// ⌥`: the front app's windows on its own Dock tile, the next window
    /// already walked — a visual ⌘` that needs no pointer. Return raises
    /// the walked card, the arrows walk, W/M/F act; ⌥` again closes it.
    func previewFrontApp() {
        guard running, accessibilityTrusted,
              let front = NSWorkspace.shared.frontmostApplication,
              front.processIdentifier != ProcessInfo.processInfo.processIdentifier,
              let dock = AppleDockReader.dockPID(), let list = AppleDockReader.dockList(pid: dock),
              let frame = AppleDockReader.frame(of: list) else { return }
        let now = CACurrentMediaTime()
        cachedList = (list, frame, now)
        let items = AppleDockReader.items(list: list)
        guard let index = DockEnhanceMath.frontTileIndex(
            bundleURL: front.bundleURL, name: front.localizedName,
            tiles: items.map { ($0.url, $0.title, $0.kind == .app) }) else { return }
        let item = items[index]
        if keyboardPinned, tracker.shown == item.hoverID {
            tracker.reset()
            hidePreview()
            return
        }
        tracker.reset()
        tracker.summon(item.hoverID, now: now)
        keyboardPinned = true
        showPreview(for: item)
        guard keyboardPinned else { return }  // nothing to preview
        preview.selectedWindowID = DockEnhanceMath.frontWalkStart(preview.windows)
        mirrorPreviewChars()
    }

    /// A key the switcher's tap ate for the floating preview — Esc
    /// closes it, the rest feed the same card walk the watchers'
    /// `onKey` runs. Unlike that path this needs no pointer on the
    /// panel: a preview resting open over the Dock still answers.
    private func previewTapKey(_ code: Int64) {
        if code == 53 {
            tracker.reset()
            hidePreview()
        } else {
            _ = panelKey(UInt16(code))
        }
    }

    /// An action key the tap ate for the preview: W closes the walked
    /// card (agent-guarded like ×), M minimizes or restores it, F flips
    /// full screen, ⌥←/⌥→ tile it into a half, Space plays or pauses
    /// the player row.
    private func previewAction(_ action: String) {
        if action == " " {
            MediaFeed.shared.send(.togglePlayPause)
            return
        }
        guard let id = preview.selectedWindowID,
              let window = preview.windows.first(where: { $0.id == id }) else { return }
        switch action {
        case "w": close(window)
        case "m": toggleMinimized(window)
        case "f": toggleFullScreen(window)
        case "tile-left": tile(window, .leftHalf)
        case "tile-right": tile(window, .rightHalf)
        default: break
        }
    }

    /// The action keys to ask the tap for: the window verbs, tiling and
    /// Return only once a card is walked (the bare arrows are already
    /// the preview's), Space only while the pointer rests on a panel
    /// showing a player. Anything else keeps typing into the front app.
    static func previewChars(walked: Bool, media: Bool, pointerInPanel: Bool) -> Set<String> {
        var chars: Set<String> = walked ? ["w", "m", "f", SwitcherKeyTap.walkedMarker] : []
        if media && pointerInPanel { chars.insert(" ") }
        return chars
    }

    /// Hand the tap the keys the preview wants now — on every tick, and
    /// at once when a walk starts, so a Return pressed straight after
    /// the arrow is already the preview's.
    private func mirrorPreviewChars(pointerInPanel inPanel: Bool? = nil) {
        let chars = tracker.shown == nil ? [] : Self.previewChars(
            walked: preview.selectedWindowID != nil, media: preview.media != nil,
            pointerInPanel: inPanel ?? pointerInPanel())
        guard chars != mirroredChars else { return }
        mirroredChars = chars
        switcher.setPreviewChars(chars)
    }

    /// Arrows walk the window cards while the pointer rests on the
    /// panel — ←/→ between cards, ↓/↑ in the compact list — and Return
    /// raises the walked one. DockDoor's keyboard path over the same
    /// non-activating surface.
    private func panelKey(_ keyCode: UInt16) -> Bool {
        let windows = preview.windows
        guard !windows.isEmpty else { return false }
        switch keyCode {
        case 123, 124, 125, 126: // ← → ↓ ↑
            let current = windows.firstIndex { $0.id == preview.selectedWindowID }
            let delta = (keyCode == 123 || keyCode == 126) ? -1 : 1
            let next = current.map {
                ($0 + delta + windows.count) % windows.count
            } ?? (delta > 0 ? 0 : windows.count - 1)
            preview.selectedWindowID = windows[next].id
            mirrorPreviewChars()
            return true
        case 36, 76: // Return / keypad Enter
            guard let id = preview.selectedWindowID,
                  let window = windows.first(where: { $0.id == id }) else { return false }
            pick(window)
            return true
        default:
            return false
        }
    }

    /// The card's ×: close the window and drop its card; the panel
    /// stays so a person can close several in a row. A window hosting a
    /// working or waiting agent needs the press twice — a mis-click on a
    /// thumbnail must not end a mid-task session.
    private func close(_ window: DockPreviewWindow) {
        let live = preview.agents[window.id].flatMap { $0.isLive ? $0 : nil }
        let key = "close:\(window.id)"
        guard agentGuard.confirm(key, guarded: live != nil, now: CACurrentMediaTime()) else {
            if let live {
                preview.armedWindowID = window.id
                preview.armedNote = DockAgentGuard.note(for: live, again: "× again to close")
                disarmLater(key)
            }
            return
        }
        preview.armedWindowID = nil
        preview.armedNote = nil
        guard AppleDockReader.close(window) else { return }
        preview.windows.removeAll { $0.id == window.id }
        if preview.windows.isEmpty {
            tracker.reset()
            hidePreview()
        } else {
            reframe()
        }
    }

    /// The card's –: minimize, or bring a minimized window back.
    private func toggleMinimized(_ window: DockPreviewWindow) {
        let target = !window.minimized
        guard AppleDockReader.setMinimized(window, target),
              let index = preview.windows.firstIndex(where: { $0.id == window.id }) else { return }
        preview.windows[index].minimized = target
    }

    /// The card's fullscreen verb — toggles the window's own
    /// `AXFullScreen` and keeps the panel up so several windows can
    /// be flipped in a row.
    private func toggleFullScreen(_ window: DockPreviewWindow) {
        guard let element = window.element,
              let current = AppleDockReader.fullScreenState(of: element) else { return }
        guard AppleDockReader.setFullScreen(window, !current) else { return }
        if let index = preview.windows.firstIndex(where: { $0.id == window.id }) {
            preview.windows[index].fullScreen = !current
        }
    }

    /// The context menu's tile: snap the window into a half or quarter
    /// of the screen the preview is over — DockDoor's grid, minus the
    /// drag. A minimized window stands back up first, and the panel
    /// stays so the rest of the set can still be worked.
    private func tile(_ window: DockPreviewWindow, _ tile: DockTile) {
        let screen = (NSScreen.screens.first { $0.frame.contains(NSEvent.mouseLocation) }
                      ?? NSScreen.main ?? NSScreen.screens[0])
        let visible = screen.visibleFrame
        // visibleFrame is AppKit — flip it into the Quartz space the
        // AX writes expect before carving it.
        let quartz = CGRect(x: visible.minX,
                            y: DockDisplays.primaryHeight() - visible.maxY,
                            width: visible.width, height: visible.height)
        if window.minimized { _ = AppleDockReader.setMinimized(window, false) }
        _ = AppleDockReader.setFrame(window, DockEnhanceMath.tileFrame(tile, in: quartz))
    }

    /// The context menu's Move To: the window keeps its size (clamped
    /// to fit) and lands centred on the other display's visible frame.
    private func move(_ window: DockPreviewWindow, toDisplay id: CGDirectDisplayID) {
        guard let display = DockDisplays.all().first(where: { $0.id == id }) else { return }
        let visible = DockEnhanceMath.appKitRect(display.screen.visibleFrame,
                                                 mainScreenHeight: DockDisplays.primaryHeight())
        let current = window.frame ?? window.element.flatMap { AppleDockReader.frame(of: $0) }
            ?? CGRect(origin: .zero, size: visible.size)
        if window.minimized { _ = AppleDockReader.setMinimized(window, false) }
        _ = AppleDockReader.setFrame(window, DockEnhanceMath.moveFrame(current, to: visible))
    }

    /// The header's "New" — the app's New Window. The live list usually lands
    /// the new card by itself; a beat later the same refresh runs once
    /// more for apps that post no window-created notification.
    private func newWindow() {
        let app = preview.processIdentifier
            .flatMap { NSRunningApplication(processIdentifier: $0) }
        AppleDockReader.newWindow(app: app)
        let generationAtNew = generation
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(600))
            guard let self, self.generation == generationAtNew else { return }
            self.refreshLiveWindows(force: true)
        }
    }

    /// The header's "Quit" — a plain terminate. An app still running a
    /// beat later turns the disc into Force Quit, and the next press
    /// force-terminates. An app hosting a working or waiting agent asks
    /// first: quitting Ghostty ends every session in it.
    private func quitApp() {
        let key = "quit:\(preview.processIdentifier ?? 0)"
        let live = preview.appAgents.first(where: \.isLive)
        guard agentGuard.confirm(key, guarded: live != nil, now: CACurrentMediaTime()) else {
            if let live {
                preview.headerNote = DockAgentGuard.note(
                    for: live, again: "Quit again to quit \(preview.appName)")
                disarmLater(key)
                reframe()
            }
            return
        }
        guard let app = preview.processIdentifier
            .flatMap({ NSRunningApplication(processIdentifier: $0) }) else { return }
        if preview.stillRunning {
            // The second Quit on an app that ignored the first is the
            // force the header now offers.
            app.forceTerminate()
            tracker.reset()
            hidePreview()
            return
        }
        app.terminate()
        // Quit is a request. The panel stays a beat: an app that goes
        // takes its cards with it (the live list hides the panel); one
        // that blocks the quit, or keeps running in the background —
        // macOS 27's gray dot — gets an honest "still running" and a
        // Force Quit instead of a panel that closed as if it worked.
        preview.headerNote = "Quitting…"
        reframe()
        let generationAtQuit = generation
        let name = preview.appName
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.quitFollowThrough) { [weak self] in
            guard let self, self.generation == generationAtQuit else { return }
            if app.isTerminated {
                self.tracker.reset()
                self.hidePreview()
            } else {
                self.preview.stillRunning = true
                self.preview.headerNote = "\(name) is still running — Quit again to force it"
                self.reframe()
            }
        }
    }

    /// A guarded verb's first press lapses with the guard's window —
    /// the ring and the note go with it unless the press was repeated.
    private func disarmLater(_ key: String) {
        let generationAtArm = generation
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(DockAgentGuard.window))
            guard let self, self.generation == generationAtArm,
                  !self.agentGuard.isArmed(key, now: CACurrentMediaTime()) else { return }
            if key.hasPrefix("close:") {
                self.preview.armedWindowID = nil
                self.preview.armedNote = nil
            } else {
                self.preview.headerNote = nil
                self.reframe()
            }
        }
    }

    /// DockDoor's minimise-all: every open window of the previewed app
    /// goes to the Dock in one verb. Minimized rows are left alone.
    private func minimizeAll() {
        var changed = false
        for index in preview.windows.indices where !preview.windows[index].minimized {
            if AppleDockReader.setMinimized(preview.windows[index], true) {
                preview.windows[index].minimized = true
                changed = true
            }
        }
        if changed { reframe() }
    }

    /// Close-all: every window of the previewed app closes in one verb
    /// — quit's gentler sibling, the app stays running windowless.
    /// Closed cards drop; the panel stays while windows remain so a
    /// person can keep working the set. Windows hosting a working or
    /// waiting agent are skipped, and the header says so.
    private func closeAll() {
        let split = DockEnhanceMath.closable(preview.windows, agents: preview.agents)
        var keptIDs = Set(split.keep.map(\.id))
        for window in split.close where !AppleDockReader.close(window) {
            keptIDs.insert(window.id)
        }
        preview.windows = preview.windows.filter { keptIDs.contains($0.id) }
        if !split.keep.isEmpty {
            preview.headerNote = split.keep.count == 1
                ? "Kept the window an agent is running in"
                : "Kept \(split.keep.count) windows agents are running in"
        }
        if preview.windows.isEmpty {
            tracker.reset()
            hidePreview()
        } else {
            reframe()
        }
    }

    /// Aero shake — minimise the rest of the app's windows, or bring
    /// them all back when the shaken card is the only one left up.
    private func shakeOthers(_ window: DockPreviewWindow) {
        guard let plan = DockEnhanceMath.shakePlan(preview.windows, shaken: window.id) else { return }
        var changed = Set<Int>()
        for other in plan.targets {
            guard AppleDockReader.setMinimized(other, plan.minimize),
                  let index = preview.windows.firstIndex(where: { $0.id == other.id })
            else { continue }
            preview.windows[index].minimized = plan.minimize
            changed.insert(other.id)
        }
        acknowledge(changed)
        if !changed.isEmpty { reframe() }
    }

    /// A vertical flick on a card — down minimises, up restores.
    private func swipeMinimize(_ window: DockPreviewWindow, _ minimize: Bool) {
        guard window.minimized != minimize,
              AppleDockReader.setMinimized(window, minimize),
              let index = preview.windows.firstIndex(where: { $0.id == window.id })
        else { return }
        preview.windows[index].minimized = minimize
        acknowledge([window.id])
    }

    /// A shake or flick landed: a level-change tick under the trackpad
    /// and a brief dip on the cards it moved — a hidden gesture says it
    /// worked, and on which windows, without a word on screen.
    private func acknowledge(_ ids: Set<Int>) {
        guard !ids.isEmpty else { return }
        NSHapticFeedbackManager.defaultPerformer.perform(.levelChange, performanceTime: .now)
        pulseToken &+= 1
        let token = pulseToken
        preview.pulsedWindowIDs = ids
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.pulseLength) { [weak self] in
            guard let self, self.pulseToken == token else { return }
            self.preview.pulsedWindowIDs = []
        }
    }

    static let pulseLength: TimeInterval = 0.3
    @ObservationIgnored private var pulseToken = 0

    /// A folder pop click — the entry (or the folder itself) opens.
    private func openItem(_ url: URL) {
        NSWorkspace.shared.open(url)
        tracker.reset()
        hidePreview()
    }

    /// The calendar row — the shelf's own read (24 h, not all-day,
    /// earliest first) done off-main; an EventKit query is a synchronous
    /// IPC to `calendard` and a hover never waits on it. The Calendar
    /// tile gets today's glance; a meeting app gets the one event whose
    /// link it opens, or no row.
    private func loadCalendarRow(generation: Int, meetingApp: String? = nil) {
        Task { @MainActor [weak self] in
            let events = await Task.detached(priority: .userInitiated) {
                Self.upcomingCalendarEvents()
            }.value
            guard let self, self.generation == generation else { return }
            let now = Date()
            if let meetingApp {
                self.preview.calendarEvents = DockEnhanceMath.meetingEvent(
                    for: meetingApp, in: events, now: now).map { [$0] } ?? []
                self.preview.calendarFreeUntil = nil
            } else {
                let glance = DockEnhanceMath.calendarGlance(events, now: now)
                self.preview.calendarEvents = glance.events
                self.preview.calendarFreeUntil = glance.freeUntil
            }
            self.reframe()
        }
    }

    /// One EventKit store for every hover — building one per hover paid
    /// its database open each time. Created on the first read, which
    /// only ever runs under an existing Full Calendar grant.
    nonisolated(unsafe) private static var calendarStore: EKEventStore?
    nonisolated private static let calendarStoreLock = NSLock()

    /// The EventKit half of the calendar row — pure enough to run on a
    /// worker: the grant is already checked, and `project`/`joinableURL`
    /// are nonisolated. Empty reads as "nothing upcoming".
    nonisolated static func upcomingCalendarEvents() -> [ShelfCalendarModel.Event] {
        let store: EKEventStore = calendarStoreLock.withLock {
            if let calendarStore { return calendarStore }
            let made = EKEventStore()
            calendarStore = made
            return made
        }
        let now = Date()
        let predicate = store.predicateForEvents(
            withStart: now, end: now.addingTimeInterval(24 * 3600), calendars: nil)
        return store.events(matching: predicate)
            .filter { !$0.isAllDay }
            .sorted { $0.startDate < $1.startDate }
            .map { ShelfCalendarModel.project($0) }
    }

    /// The calendar row's explicit ask — "Show events" requests the
    /// Full Calendar grant, then fills the row when it's given.
    private func authorizeCalendar() {
        let store = EKEventStore()
        let generationAtAuth = generation
        store.requestFullAccessToEvents { [weak self] granted, _ in
            Task { @MainActor [weak self] in
                guard let self, self.generation == generationAtAuth else { return }
                self.preview.calendarNeedsAuth = false
                if granted { self.loadCalendarRow(generation: generationAtAuth) }
            }
        }
    }

    /// A folder pop's contents: top-level entries in the tile's own
    /// arrangement (`DockFolderSort` — Name is directories first, then
    /// Finder's name order). Hidden files are skipped, like Finder's
    /// default view. A date or kind sort reads one attribute per entry
    /// (`getattrlist`, no file is opened) before the cap, so the newest
    /// file is never the one cut.
    ///
    /// Runs OFF the main actor (the pop shows Loading… until it
    /// lands). The listing uses `atPath:` — a bare readdir — because
    /// the URL variant's resource prefetch opens every file, and one
    /// Reads names via POSIX `opendir`/`readdir` rather than
    /// `contentsOfDirectory`: the Foundation enumerator's `DirEnumRead`
    /// holds a syscall open in a way an EndpointSecurity client (e.g.
    /// Defender) or a pending TCC consent can stall for seconds.
    /// `readdir` needs one `opendir` and `d_type` carries the
    /// directory flag for free — still one `open` per call, so this
    /// must stay off the caller's thread.
    ///
    /// Capped at 60: the pop is a quick-open surface, not Finder.
    nonisolated static func folderListing(of url: URL, sort: DockFolderSort = .name) -> DockFolderListing {
        guard let dir = opendir(url.path) else {
            // Downloads/Desktop/Documents gate behind Files-and-Folders
            // consent — the denial surfaces as EACCES/EPERM, or EINTR
            // when the auth upcall can't present its prompt.
            let e = errno
            return DockFolderListing(denied: e == EACCES || e == EPERM || e == EINTR)
        }
        defer { closedir(dir) }
        var rows: [DockFolderSort.Row] = []
        while let ent = readdir(dir) {
            let name = withUnsafePointer(to: &ent.pointee.d_name) {
                $0.withMemoryRebound(to: CChar.self, capacity: 256) {
                    String(cString: $0)
                }
            }
            guard name != ".", name != "..", !name.hasPrefix(".") else { continue }
            rows.append(.init(name: name, url: url.appendingPathComponent(name),
                              isDir: ent.pointee.d_type == DT_DIR))
        }
        let key = sort.resourceKey
        func value(_ entry: URL) -> URLResourceValues? {
            guard let key else { return nil }
            return try? entry.resourceValues(forKeys: [key])
        }
        let capped = sort.arrange(
            rows,
            date: { entry in
                let values = value(entry)
                switch sort {
                case .dateAdded: return values?.addedToDirectoryDate
                case .dateModified: return values?.contentModificationDate
                case .dateCreated: return values?.creationDate
                default: return nil
                }
            },
            kind: { value($0)?.localizedTypeDescription }).prefix(60)
        return DockFolderListing(
            entries: capped.enumerated().map { index, row in
                DockFolderEntry(id: index, name: row.name, url: row.url,
                                icon: NSWorkspace.shared.icon(forFile: row.url.path),
                                isDirectory: row.isDir)
            },
            folderIcon: NSWorkspace.shared.icon(forFile: url.path))
    }

    /// The test seam — the entries half of `folderListing`.
    nonisolated static func folderEntries(of url: URL) -> [DockFolderEntry] {
        folderListing(of: url).entries
    }

    /// DockDoor's quick-quit: ⌘+right-click a Dock icon terminates the
    /// app, ⌘⌥+right-click force-quits it. The switcher's tap eats the
    /// click on a running app's tile so Apple's menu never pops over
    /// the quit; this global monitor path (AppKit point) is the
    /// fallback while the tap's mirrored tiles are stale.
    private func quickQuit(at point: NSPoint, force: Bool) {
        quickQuit(axPoint: DockEnhanceMath.axPoint(point, mainScreenHeight: DockDisplays.primaryHeight()),
                  force: force)
    }

    private func quickQuit(axPoint: CGPoint, force: Bool) {
        // The tap and the fallback monitor can both see one click; the
        // second report of the same press is the same press — never the
        // confirming second click an agent guard waits for.
        let now = CACurrentMediaTime()
        if let last = lastQuickQuit, now - last.at < 0.3,
           hypot(last.point.x - axPoint.x, last.point.y - axPoint.y) < 3 { return }
        lastQuickQuit = (axPoint, now)
        guard let list = dockList(near: axPoint),
              Self.listReach(of: list.frame).contains(axPoint),
              let item = tiles(of: list).first(where: { $0.frame.contains(axPoint) }),
              let appURL = item.url,
              let bundleID = Bundle(url: appURL)?.bundleIdentifier,
              let app = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).first
        else { return }
        // Never let the verb reach our own family — a ⌘-click on our
        // own tile would self-terminate.
        guard app.processIdentifier != ProcessInfo.processInfo.processIdentifier,
              !MenuBarUtility.isOwnFamily(bundleID) else { return }
        let name = app.localizedName ?? "the app"
        // A reflexive quit must not end a mid-task agent run: a terminal
        // or IDE hosting a working or waiting session asks for the same
        // click twice.
        let live = agentMarks().first { $0.hosts.contains(bundleID) && $0.isLive }
        let key = "quickquit:\(app.processIdentifier)"
        guard agentGuard.confirm(key, guarded: live != nil, now: CACurrentMediaTime()) else {
            if let live {
                showToast(DockAgentGuard.note(for: live, again: "⌘-right-click again to quit"),
                          over: item, duration: DockAgentGuard.window)
            }
            return
        }
        Self.log.notice("quick quit: \(bundleID, privacy: .public) force=\(force, privacy: .public)")
        if force { app.forceTerminate() } else { app.terminate() }
        tracker.reset()
        hidePreview()
        showToast(force ? "Force quit \(name)" : "Quit \(name)", over: item)
        // Quit is a request: an app that blocks it, or keeps running in
        // the background (macOS 27's gray dot), says so rather than the
        // toast claiming a quit that never happened.
        guard !force else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.quitFollowThrough) { [weak self] in
            guard let self, !app.isTerminated else { return }
            self.showToast("\(name) is still running — ⌘⌥-right-click to force quit", over: item,
                           duration: 2.4)
        }
    }

    /// The tile under an AppKit point, when it's over the Dock. The
    /// gesture monitors call this for every click or scroll anywhere, so
    /// a point outside the cached reach answers at once — the tick keeps
    /// that frame fresh wherever the pointer nears a Dock edge — and
    /// only a point over the Dock pays the AX read.
    private func tile(at point: NSPoint) -> DockAXItem? {
        let axPoint = DockEnhanceMath.axPoint(point, mainScreenHeight: DockDisplays.primaryHeight())
        guard accessibilityTrusted else { return nil }
        if let cached = cachedList, !Self.listReach(of: cached.frame).contains(axPoint) { return nil }
        guard let list = dockList(near: axPoint),
              Self.listReach(of: list.frame).contains(axPoint) else { return nil }
        return tiles(of: list).first { $0.frame.contains(axPoint) }
    }

    /// The Middle Click trigger: a middle click on a tile opens its
    /// preview at once; the same click on the tile already shown closes it.
    private func middleClick(at point: NSPoint) {
        guard running, preferences.previewTrigger == .middleClick, let item = tile(at: point) else { return }
        if tracker.shown == item.hoverID {
            tracker.reset()
            hidePreview()
            return
        }
        if case .show = tracker.summon(item.hoverID, now: CACurrentMediaTime()) {
            showPreview(for: item)
        }
    }

    /// Scroll on a Dock icon — HyperDock's classic: a deliberate scroll
    /// up opens that app's preview without the rest, a scroll down hides
    /// the app. The flick threshold is the cards' own, so a brush of the
    /// wheel on the way past does nothing.
    private func scroll(at point: NSPoint, deltaY: CGFloat, inverted: Bool, now: TimeInterval) {
        guard running, preferences.scrollGestures, let item = tile(at: point), item.kind == .app else {
            scrollTile = nil
            return
        }
        if scrollTile != item.hoverID {
            scrollTile = item.hoverID
            scrollFlick = DockEnhanceMath.SwipeAccumulator()
        }
        switch scrollFlick.note(deltaY: deltaY, inverted: inverted, now: now) {
        case .up:
            if case .show = tracker.summon(item.hoverID, now: CACurrentMediaTime()) {
                showPreview(for: item)
            }
        case .down:
            guard let url = item.url, let bundleID = Bundle(url: url)?.bundleIdentifier,
                  !MenuBarUtility.isOwnFamily(bundleID),
                  let app = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).first,
                  app.processIdentifier != ProcessInfo.processInfo.processIdentifier else { return }
            if tracker.shown == item.hoverID {
                tracker.reset()
                hidePreview()
            }
            app.hide()
        case nil:
            break
        }
    }

    /// Click the front app's own Dock icon: its visible windows minimize
    /// through AX — the Windows-taskbar habit, on the Dock you already
    /// use. A click on a background app is the Dock's own activation; an
    /// app with nothing visible left is the Dock's own restore; neither
    /// is touched. Only plain clicks — a modified click is the Dock's.
    private func clickToMinimize(at point: NSPoint, clickAt: TimeInterval) {
        guard running, preferences.clickToMinimize, let item = tile(at: point), item.kind == .app,
              let url = item.url, let bundleID = Bundle(url: url)?.bundleIdentifier,
              !MenuBarUtility.isOwnFamily(bundleID),
              let app = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).first,
              DockEnhanceMath.clickMinimizes(
                appPID: app.processIdentifier,
                frontmostPID: NSWorkspace.shared.frontmostApplication?.processIdentifier,
                lastActivation: lastActivation, clickAt: clickAt) else { return }
        let visible = AppleDockReader.windows(pid: app.processIdentifier).filter { !$0.minimized }
        guard !visible.isEmpty else { return }
        for window in visible { AppleDockReader.setMinimized(window, true) }
        if tracker.shown == item.hoverID {
            tracker.reset()
            hidePreview()
        }
    }

    /// How long a plain quit gets before "still running" is the truth.
    static let quitFollowThrough: TimeInterval = 1.2
    @ObservationIgnored private var lastQuickQuit: (point: CGPoint, at: TimeInterval)?

    /// The glass line above a tile — what a gesture did, or why it waited.
    @ObservationIgnored private var toast: DockToastPanel?

    private func showToast(_ text: String, over item: DockAXItem, duration: TimeInterval = 1.4) {
        let mainHeight = DockDisplays.primaryHeight()
        let tile = DockEnhanceMath.appKitRect(item.frame, mainScreenHeight: mainHeight)
        let pointer = NSEvent.mouseLocation
        guard let screen = NSScreen.screens.first(where: { $0.frame.contains(pointer) })
                ?? NSScreen.screens.first(where: { $0.frame.contains(tile.origin) }) ?? NSScreen.main
        else { return }
        let listFrame = cachedList.map { DockEnhanceMath.appKitRect($0.frame, mainScreenHeight: mainHeight) } ?? tile
        let edge = DockEnhanceMath.dockEdge(listFrame: listFrame, screen: screen.frame)
        let anchor = magnificationOn
            ? DockEnhanceMath.magnifiedAnchor(tile: tile, edge: edge, pointer: pointer) : tile
        let panel = toast ?? DockToastPanel()
        toast = panel
        // Every toast follows a gesture on a Dock icon, so the swollen
        // icon counts even while a ⌥`-pinned preview is up.
        let place = placement.onDock(magnifying: magnificationOn)
        panel.show(text, over: anchor, edge: edge, screen: screen.frame, placement: place,
                   title: item.title ?? "", duration: duration)
    }

    /// The header's "Never Preview <App>": the app joins the exclusion
    /// list and the panel goes. The tracker keeps the tile as shown, so
    /// the resting pointer doesn't reopen what was just excluded.
    private func excludePreviewedApp() {
        guard let bundleID = preview.bundleID else { return }
        preferences.excludedBundleIDs = DockEnhanceMath.excluding(bundleID, from: preferences.excludedBundleIDs)
        hidePreview()
    }

    /// The header's "Hide" — the app's own ⌘H.
    private func hideApp() {
        preview.processIdentifier
            .flatMap { NSRunningApplication(processIdentifier: $0) }?
            .hide()
        tracker.reset()
        hidePreview()
    }

    /// The panel's content changed size (a card left): re-fit on the
    /// same tile, from the same edge, clamped to the same screen.
    /// `onlyIfResized` leaves a panel whose content still fits its frame
    /// where it is — a live retitle usually changes nothing it sizes by.
    private func reframe(onlyIfResized: Bool = false) {
        guard let panel, panel.isVisible else { return }
        let size = panel.fittingSize()
        if onlyIfResized, size == panel.frame.size { return }
        guard let anchor else {
            var frame = panel.frame
            frame.origin.x += (frame.width - size.width) / 2
            frame.size = size
            panel.setFrame(frame, display: true)
            return
        }
        // The same anchor the show/hover path uses — under magnification
        // the AX frame is the unmagnified layout and the tile sits at
        // the pointer, so refitting on it jumped the panel off the icon.
        let itemFrame = anchorFrame(for: anchor.item, edge: anchor.edge,
                                    pointer: NSEvent.mouseLocation)
        let place = placement
        panel.hold(place)
        panel.setFrame(targetFrame(item: itemFrame, edge: anchor.edge, screen: anchor.screen, size: size,
                                   placement: place),
                       display: true)
    }
}
