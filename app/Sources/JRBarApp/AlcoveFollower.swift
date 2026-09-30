import AppKit
import ApplicationServices
import JRBarCore
import QuartzCore

/// What one poll sees of the screen and Alcove's windows. Gathered on the
/// main actor in one place so a test can stand in for the window server.
struct AlcovePollContext {
    var rows: [AlcoveWindowRow]
    var screenFrame: CGRect
    var primaryHeight: CGFloat
    /// Whether this process may read Alcove's accessibility tree. Never
    /// asked for here.
    var trusted: Bool
}

/// An accessibility element that would not answer in time.
struct AlcoveReadStalled: Error {}

/// Keeps the Screen Bar on Alcove's capsule (`screen_bar_follow_alcove`).
///
/// Nothing is captured: the window list's bounds for Alcove's top-hugging
/// window are the capsule (`AlcoveGeometry.select`). Alcove 1.7.9 draws the
/// capsule inside one fixed 624×320 window instead, so when the top window
/// is such a container and this process already has accessibility access
/// (never asked for here), the capsule is estimated from the controls Alcove
/// lays out inside it (`AlcoveGeometry.capsule(fromContentFrames:)`). That
/// read runs off the main thread, one at a time, under a short messaging
/// timeout and a total budget, so an Alcove that is slow to answer costs a
/// late update and never a stalled JR-Bar; the poll re-arms when the read
/// lands. The list is read at 2 Hz for a few seconds after an Alcove
/// launch/terminate ping or a capsule change -- a live activity opening or
/// growing -- then at 0.5 Hz once the width is stable, and only while Alcove
/// is running; with Alcove gone, or the setting off, the poll stops and the
/// band goes back to the notch.
///
/// Following is opt-in: it runs only while the Notch utility names Alcove
/// as the notch's renderer (`rendererChosen`, published by `NotchToy`).
/// JR-Bar's own island is the daily driver and Alcove's last build is
/// 1.7.9, so a Mac that merely has Alcove installed and running no longer
/// gets a window-list poll it never asked for.
@MainActor
final class AlcoveFollower {
    /// While the capsule may be moving.
    static let pollInterval: TimeInterval = 0.5
    /// Once its width has been still for `activePollWindow`.
    static let idlePollInterval: TimeInterval = 2.0
    /// How long after activity the fast cadence holds.
    static let activePollWindow: TimeInterval = 3.0

    /// How long one accessibility call may wait for Alcove.
    nonisolated static let messagingTimeout: Float = 0.4
    /// How long the whole content read may take before Alcove counts as
    /// slow to answer.
    nonisolated static let readBudget: TimeInterval = 0.75
    /// The most elements one read visits, and how deep it goes.
    nonisolated static let maxContentNodes = 96
    nonisolated static let maxContentDepth = 6

    /// Whether the Notch utility is on with Alcove picked to draw the
    /// notch — the follower's opt-in. `NotchToy` writes it and posts
    /// `rendererChangedNotification`; off until it says otherwise.
    static var rendererChosen = false
    static let rendererChangedNotification = Notification.Name("JRBarNotchRendererChanged")

    /// Publish the renderer pick; a change re-reconciles every follower.
    static func noteRenderer(chosen: Bool) {
        guard chosen != rendererChosen else { return }
        rendererChosen = chosen
        NotificationCenter.default.post(name: rendererChangedNotification, object: nil)
    }

    /// Called on the main actor whenever the capsule changes (nil: stop following).
    var onChange: (@MainActor (AlcoveCapsule?) -> Void)?
    private(set) var capsule: AlcoveCapsule?
    private var timer: Timer?
    private var fastPollUntil: CFTimeInterval = 0
    private var observers: [NSObjectProtocol] = []

    /// Stand-ins for the window server, accessibility, the running-apps
    /// list and the renderer pick, so a test can drive the poll without
    /// any of them. The defaults are the real thing.
    var context: @MainActor () -> AlcovePollContext? = { AlcoveFollower.liveContext() }
    var readFrames: @Sendable (pid_t, CGRect) -> [CGRect]? = { pid, window in
        AlcoveFollower.accessibilityContentFrames(pid: pid, window: window)
    }
    var alcoveRunning: @MainActor () -> Bool = {
        RunningApps.shared.isRunning(bundleID: AlcoveGeometry.bundleIdentifier)
    }
    var rendererIsChosen: @MainActor () -> Bool = { AlcoveFollower.rendererChosen }

    /// Bumped whenever the follower stops or starts a read, so a read that
    /// lands late can tell it was overtaken and change nothing.
    private(set) var generation = 0
    /// The content read in flight, if any. Only one runs at a time; its
    /// landing is what re-arms the poll.
    private(set) var pendingRead: Task<Void, Never>?

    /// The setting, and whether the bar is shown at all.
    var enabled = false {
        didSet { if enabled != oldValue { reconcile() } }
    }

    init() {
        let center = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.didLaunchApplicationNotification, NSWorkspace.didTerminateApplicationNotification] {
            observers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] note in
                let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
                guard app?.bundleIdentifier == AlcoveGeometry.bundleIdentifier else { return }
                MainActor.assumeIsolated { self?.reconcile() }
            })
        }
        observers.append(NotificationCenter.default.addObserver(
            forName: Self.rendererChangedNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.reconcile() }
        })
    }

    /// The setting, the bar, and the renderer pick all say follow.
    private var following: Bool { enabled && rendererIsChosen() }

    var isAlcoveRunning: Bool { alcoveRunning() }

    /// A poll is armed, or a read is out and will arm the next one.
    var isPolling: Bool { timer != nil || pendingRead != nil }

    /// Whether the next poll is waiting on its timer.
    var hasArmedTimer: Bool { timer != nil }

    /// "following the capsule (212 pt)", "Alcove not running", "off", for the status menu.
    var statusDescription: String {
        guard enabled else { return "off" }
        guard rendererIsChosen() else { return "off (JR-Bar draws the notch)" }
        guard isAlcoveRunning else { return "Alcove not running" }
        if let capsule { return "following the capsule (\(Int(capsule.width.rounded())) pt, \(source))" }
        return "Alcove running, \(source)"
    }

    func reconcile() {
        if following, isAlcoveRunning {
            noteActivity()
            poll()
        } else {
            // A read still out is overtaken: it lands into nothing.
            generation += 1
            timer?.invalidate()
            timer = nil
            update(nil)
        }
    }

    /// A workspace ping or a changed capsule buys another few seconds of
    /// 2 Hz sampling; a still capsule drops to the idle cadence.
    private func noteActivity() {
        fastPollUntil = CACurrentMediaTime() + Self.activePollWindow
    }

    /// One-shot re-arm: the interval is chosen fresh each tick so the
    /// cadence can fall back without the timer being rebuilt anywhere else.
    private func schedulePoll() {
        timer?.invalidate()
        timer = nil
        guard following, isAlcoveRunning else { return }
        let interval = CACurrentMediaTime() < fastPollUntil ? Self.pollInterval : Self.idlePollInterval
        let timer = Timer(timeInterval: interval, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { self?.poll() }
        }
        timer.tolerance = 0.1
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    /// How the last capsule was found, for the status menu.
    private(set) var source = "none"

    func poll() {
        // One read at a time: while it is out, its landing re-arms the poll.
        guard pendingRead == nil else { return }
        defer { if pendingRead == nil { schedulePoll() } }
        guard let world = context() else { update(nil); return }
        if let found = AlcoveGeometry.select(rows: world.rows, screenFrame: world.screenFrame, primaryHeight: world.primaryHeight) {
            source = "window bounds"
            update(found)
            return
        }
        guard let container = AlcoveGeometry.containerWindow(rows: world.rows, screenFrame: world.screenFrame, primaryHeight: world.primaryHeight) else {
            source = "no capsule window"
            update(nil)
            return
        }
        guard world.trusted else {
            source = "container window, no accessibility access"
            update(nil)
            return
        }
        readContent(of: container, in: world)
    }

    /// The accessibility read, off the main thread. Only the window's
    /// bounds and the screen's numbers cross over; the capsule is worked
    /// out back on the main actor when the frames land.
    private func readContent(of container: AlcoveWindowRow, in world: AlcovePollContext) {
        generation += 1
        let token = generation
        let read = readFrames
        let pid = pid_t(container.ownerPID)
        let window = container.bounds
        let screenFrame = world.screenFrame
        let primaryHeight = world.primaryHeight
        pendingRead = Task.detached(priority: .utility) { [weak self] in
            let frames = read(pid, window)
            await self?.landed(frames, token: token, container: window, screenFrame: screenFrame, primaryHeight: primaryHeight)
        }
    }

    /// A content read finished. nil frames mean Alcove did not answer in
    /// time: the last capsule is kept and the status menu says why, rather
    /// than the band snapping to the notch for a moment's stall. An empty
    /// list is a real answer (nothing is laid out), and a read that was
    /// overtaken by a stop changes nothing. Either way the poll re-arms,
    /// and `schedulePoll` itself declines once following has stopped.
    func landed(_ frames: [CGRect]?, token: Int, container: CGRect, screenFrame: CGRect, primaryHeight: CGFloat) {
        pendingRead = nil
        defer { schedulePoll() }
        guard token == generation else { return }
        guard let frames else {
            source = "accessibility, Alcove is slow to answer"
            return
        }
        source = "accessibility"
        update(AlcoveGeometry.capsule(fromContentFrames: frames, container: container, screenFrame: screenFrame, primaryHeight: primaryHeight))
    }

    /// The frames of everything Alcove lays out in `window` (a few levels
    /// deep, a bounded number of elements), in window-list coordinates.
    /// nil when Alcove did not answer within the messaging timeout or the
    /// read budget; an empty list when it answered and had nothing there.
    nonisolated static func accessibilityContentFrames(pid: pid_t, window: CGRect) -> [CGRect]? {
        let clock: @Sendable () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }
        let deadline = clock() + readBudget
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, messagingTimeout)
        var windowsValue: AnyObject?
        let status = AXUIElementCopyAttributeValue(app, kAXWindowsAttribute as CFString, &windowsValue)
        if status == .cannotComplete { return nil }
        guard status == .success, let windows = windowsValue as? [AXUIElement] else { return [] }
        return walkContent(roots: windows, window: window, maxNodes: maxContentNodes, maxDepth: maxContentDepth,
                           deadline: deadline, now: clock,
                           frame: { try axFrame(of: $0) }, children: { try axChildren(of: $0) })
    }

    /// The walk behind `accessibilityContentFrames`, over any tree: the
    /// frames of every element under the root that is Alcove's container
    /// (`window`), depth first, at most `maxNodes` of them and `maxDepth`
    /// deep. nil once `now()` reaches `deadline` or a read throws
    /// `AlcoveReadStalled`: a read that cannot be finished says so rather
    /// than passing off a part of the tree as all of it.
    nonisolated static func walkContent<Node>(roots: [Node], window: CGRect, maxNodes: Int, maxDepth: Int,
                                              deadline: TimeInterval, now: () -> TimeInterval,
                                              frame: (Node) throws -> CGRect?,
                                              children: (Node) throws -> [Node]) -> [CGRect]? {
        var frames: [CGRect] = []
        var budget = maxNodes
        func walk(_ node: Node, depth: Int, rect: CGRect?) throws {
            if let rect { frames.append(rect) }
            guard depth + 1 < maxDepth else { return }
            for child in try children(node) {
                guard budget > 0 else { return }
                guard now() < deadline else { throw AlcoveReadStalled() }
                budget -= 1
                try walk(child, depth: depth + 1, rect: try frame(child))
            }
        }
        do {
            for root in roots {
                guard budget > 0 else { break }
                guard now() < deadline else { return nil }
                guard let rect = try frame(root),
                      abs(rect.minX - window.minX) < 2, abs(rect.minY - window.minY) < 2,
                      abs(rect.width - window.width) < 2 else { continue }
                budget -= 1
                try walk(root, depth: 0, rect: rect)
            }
        } catch {
            return nil
        }
        return frames
    }

    private nonisolated static func axFrame(of element: AXUIElement) throws -> CGRect? {
        AXUIElementSetMessagingTimeout(element, messagingTimeout)
        var positionValue: AnyObject?
        var sizeValue: AnyObject?
        let positionStatus = AXUIElementCopyAttributeValue(element, kAXPositionAttribute as CFString, &positionValue)
        if positionStatus == .cannotComplete { throw AlcoveReadStalled() }
        guard positionStatus == .success else { return nil }
        let sizeStatus = AXUIElementCopyAttributeValue(element, kAXSizeAttribute as CFString, &sizeValue)
        if sizeStatus == .cannotComplete { throw AlcoveReadStalled() }
        guard sizeStatus == .success,
              let position = positionValue, let size = sizeValue,
              CFGetTypeID(position) == AXValueGetTypeID(), CFGetTypeID(size) == AXValueGetTypeID() else { return nil }
        var point = CGPoint.zero
        var dimensions = CGSize.zero
        // swiftlint:disable force_cast
        guard AXValueGetValue(position as! AXValue, .cgPoint, &point), AXValueGetValue(size as! AXValue, .cgSize, &dimensions) else { return nil }
        // swiftlint:enable force_cast
        return CGRect(origin: point, size: dimensions)
    }

    private nonisolated static func axChildren(of element: AXUIElement) throws -> [AXUIElement] {
        AXUIElementSetMessagingTimeout(element, messagingTimeout)
        var childrenValue: AnyObject?
        let status = AXUIElementCopyAttributeValue(element, kAXChildrenAttribute as CFString, &childrenValue)
        if status == .cannotComplete { throw AlcoveReadStalled() }
        guard status == .success, let children = childrenValue as? [AXUIElement] else { return [] }
        return children
    }

    private func update(_ new: AlcoveCapsule?) {
        guard new != capsule else { return }
        capsule = new
        // A change the poll just saw keeps the fast window alive, so an
        // expanding live activity is tracked at 2 Hz through the animation.
        noteActivity()
        onChange?(new)
    }

    /// The screen, its Alcove windows and whether accessibility is
    /// granted, read once for a poll. Bounds only: no capture, no Screen
    /// Recording permission involved.
    static func liveContext() -> AlcovePollContext? {
        guard let screen = ScreenBarGeometry.preferredScreen() else { return nil }
        let primaryHeight = NSScreen.screens.first?.frame.height ?? screen.frame.maxY
        return AlcovePollContext(rows: windowRows(), screenFrame: screen.frame,
                                 primaryHeight: primaryHeight, trusted: AXIsProcessTrusted())
    }

    /// Alcove's on-screen windows as plain rows. Bounds only: no capture,
    /// no Screen Recording permission involved.
    static func windowRows() -> [AlcoveWindowRow] {
        guard let info = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] else { return [] }
        var rows: [AlcoveWindowRow] = []
        for entry in info {
            guard let owner = entry[kCGWindowOwnerName as String] as? String, owner == AlcoveGeometry.ownerName,
                  let boundsDict = entry[kCGWindowBounds as String] as? NSDictionary,
                  let bounds = CGRect(dictionaryRepresentation: boundsDict) else { continue }
            rows.append(AlcoveWindowRow(
                ownerName: owner,
                ownerPID: entry[kCGWindowOwnerPID as String] as? Int ?? 0,
                number: entry[kCGWindowNumber as String] as? Int ?? 0,
                layer: entry[kCGWindowLayer as String] as? Int ?? 0,
                alpha: entry[kCGWindowAlpha as String] as? Double ?? 1,
                bounds: bounds
            ))
        }
        return rows
    }
}
