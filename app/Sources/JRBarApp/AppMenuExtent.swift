import AppKit
import ApplicationServices

/// The frontmost app's menu titles, which the status-item listing never
/// sees even though they sit on the notch's flanks too. A long menu bar
/// runs its last titles under the left ear. An app with more menus than
/// fit left of the notch continues them on its right, where the right
/// ear painted over "Window" and "Help". The band merges these frames
/// with the item limits (`ScreenBarGeometry.earLimits`), so an ear with
/// no room collapses instead.
///
/// Read only when the menu bar changes hands: on
/// `didActivateApplicationNotification`, plus one re-read a beat later,
/// because an app that just activated can still be building its menus.
/// Never polled. AX scans on a timer were the 2026-09-16 energy
/// regression. The read runs off the main thread under a messaging
/// timeout, so an app that never answers cannot stall the bar.
@MainActor
final class AppMenuExtent {
    /// The menu titles' frames in AppKit screen coordinates. Empty
    /// while stopped, unread, or refused (no Accessibility).
    private(set) var titles: [CGRect] = []
    /// Called when `titles` changes: the band re-sizes its ears.
    var onChange: (@MainActor () -> Void)?

    /// How long after an activation the titles are read again.
    static let settleDelay: TimeInterval = 0.6
    /// How long the owning app may take to answer one AX query.
    nonisolated static let messagingTimeout: Float = 0.5

    private var observer: NSObjectProtocol?
    private var settleWork: DispatchWorkItem?
    /// Bumped per read and on stop, so a slow read that lands after a
    /// newer one, or after `stop`, is dropped.
    private var generation = 0

    func start() {
        guard observer == nil else { return }
        observer = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.menuBarChangedHands() }
        }
        menuBarChangedHands()
    }

    func stop() {
        guard let observer else { return }
        NSWorkspace.shared.notificationCenter.removeObserver(observer)
        self.observer = nil
        settleWork?.cancel()
        settleWork = nil
        generation += 1
        publish([])
    }

    /// A one-off re-read while running, for when the screens changed and
    /// the titles moved with them.
    func refresh() {
        guard observer != nil else { return }
        read()
    }

    private func menuBarChangedHands() {
        read()
        settleWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated { self?.read() }
        }
        settleWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.settleDelay, execute: work)
    }

    private func read() {
        generation += 1
        let token = generation
        let workspace = NSWorkspace.shared
        guard AXIsProcessTrusted(),
              let app = workspace.menuBarOwningApplication ?? workspace.frontmostApplication else {
            publish([])
            return
        }
        let pid = app.processIdentifier
        Task.detached(priority: .utility) { [weak self] in
            let frames = AppMenuExtent.titleFrames(pid: pid)
            await self?.landed(frames, token: token)
        }
    }

    private func landed(_ quartzFrames: [CGRect], token: Int) {
        guard token == generation else { return }
        publish(Self.appKitFrames(quartzFrames))
    }

    private func publish(_ frames: [CGRect]) {
        guard frames != titles else { return }
        titles = frames
        onChange?()
    }

    /// AX answers in Quartz points (origin at the menu-bar screen's top
    /// left, y down); the band works in AppKit's (bottom left, y up).
    /// The x axis is shared.
    private static func appKitFrames(_ quartz: [CGRect]) -> [CGRect] {
        guard let primary = NSScreen.screens.first?.frame else { return [] }
        return quartz.map { CGRect(x: $0.minX, y: primary.maxY - $0.maxY, width: $0.width, height: $0.height) }
    }

    /// The `AXMenuBarItem` children of `pid`'s `AXMenuBar` (the Apple
    /// menu, the app's name, File, …) in Quartz points. The status items
    /// live on `AXExtrasMenuBar` instead and are not read here.
    nonisolated static func titleFrames(pid: pid_t) -> [CGRect] {
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, messagingTimeout)
        guard let bar = element(app, kAXMenuBarAttribute),
              let items = copy(bar, kAXChildrenAttribute) as? [AXUIElement] else { return [] }
        return items.compactMap { item in
            AXUIElementSetMessagingTimeout(item, messagingTimeout)
            guard copy(item, kAXRoleAttribute) as? String == kAXMenuBarItemRole,
                  let origin = axValue(item, kAXPositionAttribute),
                  let size = axValue(item, kAXSizeAttribute) else { return nil }
            var point = CGPoint.zero
            var extent = CGSize.zero
            guard AXValueGetValue(origin, .cgPoint, &point),
                  AXValueGetValue(size, .cgSize, &extent),
                  extent.width > 0 else { return nil }
            return CGRect(origin: point, size: extent)
        }
    }

    private nonisolated static func copy(_ element: AXUIElement, _ attribute: String) -> CFTypeRef? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success else { return nil }
        return value
    }

    private nonisolated static func element(_ element: AXUIElement, _ attribute: String) -> AXUIElement? {
        guard let value = copy(element, attribute), CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
        let child = value as! AXUIElement
        AXUIElementSetMessagingTimeout(child, messagingTimeout)
        return child
    }

    private nonisolated static func axValue(_ element: AXUIElement, _ attribute: String) -> AXValue? {
        guard let raw = copy(element, attribute), CFGetTypeID(raw) == AXValueGetTypeID() else { return nil }
        return (raw as! AXValue)
    }
}
