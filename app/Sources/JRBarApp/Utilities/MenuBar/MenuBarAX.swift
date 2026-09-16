import AppKit
import ApplicationServices
import JRBarCore

/// The Accessibility half of the menu bar: on macOS 26 the extras
/// region's items are no longer per-item windows, so every app that
/// fields one answers it through its `AXExtrasMenuBar` — an
/// `AXMenuBarItem` child per item, carrying `AXPosition`/`AXSize`
/// (Quartz points), `AXIdentifier`, `AXTitle`, and an `AXPress`
/// action that still works while the item is parked in the system's
/// own overflow.
///
/// Two jobs:
///   * `items(targets:row:)` — the listing `MenuBarItemLister` caches,
///     one bounded AX query per running app, run concurrently because a
///     slow app must never stall the whole scan.
///   * `press(_:)` — the Item Bar tile's click-through: re-resolve the
///     item's element and `AXPress` it, which reaches covered *and*
///     system-parked items a synthetic click could not.
///
/// Every element gets a messaging timeout: an app that never answers
/// AX would otherwise hang the call site for seconds.
enum MenuBarAX {
    /// One scannable process: pid plus the display name used for the
    /// item's owner — both Sendable, so the scan runs off the actor.
    struct Target: Sendable {
        let pid: pid_t
        let name: String
    }

    /// How long one app may take to answer an AX query before the scan
    /// gives up on it.
    nonisolated static let messagingTimeout: TimeInterval = 1.0

    // MARK: Scanning

    /// A value copied off an `AXUIElement`.
    private nonisolated static func value(_ element: AXUIElement,
                                          _ attribute: String) -> CFTypeRef? {
        var value: CFTypeRef?
        AXUIElementCopyAttributeValue(element, attribute as CFString, &value)
        return value
    }

    private nonisolated static func string(_ element: AXUIElement,
                                           _ attribute: String) -> String? {
        (value(element, attribute) as? String).flatMap { $0.isEmpty ? nil : $0 }
    }

    private nonisolated static func point(_ element: AXUIElement,
                                          _ attribute: String) -> CGPoint {
        var point = CGPoint.zero
        if let v = value(element, attribute), CFGetTypeID(v) == AXValueGetTypeID() {
            AXValueGetValue(v as! AXValue, .cgPoint, &point)
        }
        return point
    }

    private nonisolated static func size(_ element: AXUIElement,
                                         _ attribute: String) -> CGSize {
        var size = CGSize.zero
        if let v = value(element, attribute), CFGetTypeID(v) == AXValueGetTypeID() {
            AXValueGetValue(v as! AXValue, .cgSize, &size)
        }
        return size
    }

    private nonisolated static func role(_ element: AXUIElement) -> String? {
        value(element, kAXRoleAttribute) as? String
    }

    /// The extras-bar children of one app that are menu bar items —
    /// `AXMenuBarItem`s directly, or grouped one level under an
    /// `AXGroup` (some apps wrap theirs) — plus any `AXButton` the bar
    /// fields directly: that is how MenuBarAgent exposes its overflow
    /// control, and the plan needs its frame.
    private nonisolated static func extrasItems(of pid: pid_t) -> [AXUIElement] {
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, Float(messagingTimeout))
        var extras: CFTypeRef?
        guard AXUIElementCopyAttributeValue(app, "AXExtrasMenuBar" as CFString, &extras) == .success,
              let extras, CFGetTypeID(extras) == AXUIElementGetTypeID() else { return [] }
        let bar = extras as! AXUIElement
        AXUIElementSetMessagingTimeout(bar, Float(messagingTimeout))
        guard let children = value(bar, kAXChildrenAttribute) as? [AXUIElement] else { return [] }
        var items: [AXUIElement] = []
        for child in children {
            AXUIElementSetMessagingTimeout(child, Float(messagingTimeout))
            let childRole = role(child)
            if childRole == "AXMenuBarItem" || childRole == "AXButton" {
                items.append(child)
            } else if childRole == "AXGroup",
                      let sub = value(child, kAXChildrenAttribute) as? [AXUIElement] {
                items.append(contentsOf: sub.filter { role($0) == "AXMenuBarItem" })
            }
        }
        return items
    }

    /// One app's extras items → `MenuBarItem`s (identities not yet
    /// assigned — that happens in `items(from:)`, which sees all
    /// owners at once).
    private nonisolated static func rawItems(of target: Target,
                                             row: CGRect) -> [MenuBarItem] {
        extrasItems(of: target.pid).enumerated().compactMap { index, element in
            let position = point(element, kAXPositionAttribute)
            let size = size(element, kAXSizeAttribute)
            guard size.width >= MenuBarItemLister.minItemWidth,
                  size.height > 0 else { return nil }
            let bounds = CGRect(origin: position, size: size)
            // An item reports either on the row or parked below it;
            // anything else is a transient non-item (mid-teardown).
            guard bounds.minY < row.maxY + 2 || bounds.minY > row.maxY + 100 else { return nil }
            return MenuBarItem(id: "", ownerPID: target.pid, ownerName: target.name,
                               bounds: bounds, title: string(element, kAXTitleAttribute),
                               windowID: 0,
                               identifier: string(element, "AXIdentifier"),
                               extrasIndex: index,
                               isNativeOverflowControl: role(element) == "AXButton")
        }
    }

    /// Every target's extras items, identities assigned, sorted left to
    /// right (parked items sort last — their offscreen positions are
    /// not bar order). Runs a bounded query per app concurrently so a
    /// hung app costs `messagingTimeout`, not the whole scan.
    nonisolated static func items(targets: [Target], row: CGRect) -> [MenuBarItem] {
        /// Lock-guarded accumulation for the concurrent per-app queries.
        final class Box: @unchecked Sendable {
            let lock = NSLock()
            var items: [MenuBarItem] = []
        }
        let box = Box()
        DispatchQueue.concurrentPerform(iterations: targets.count) { i in
            let items = rawItems(of: targets[i], row: row)
            guard !items.isEmpty else { return }
            box.lock.lock()
            box.items.append(contentsOf: items)
            box.lock.unlock()
        }
        let collected = box.items
        let onRow = collected.filter { $0.bounds.intersects(row) }
            .sorted { $0.bounds.minX < $1.bounds.minX }
        let parked = collected.filter { !$0.bounds.intersects(row) }
            .sorted { $0.ownerName.localizedCompare($1.ownerName) == .orderedAscending }
        let ordered = onRow + parked
        var totals: [String: Int] = [:]
        for item in ordered { totals[MenuBarItemLister.base(of: item), default: 0] += 1 }
        var seen: [String: Int] = [:]
        return ordered.map { item in
            let base = MenuBarItemLister.base(of: item)
            var id = base
            if totals[base, default: 0] > 1 {
                let n = seen[base, default: 0]
                seen[base] = n + 1
                id = "\(base)#\(n)"
            }
            return MenuBarItem(id: id, ownerPID: item.ownerPID, ownerName: item.ownerName,
                               bounds: item.bounds, title: item.title, windowID: item.windowID,
                               identifier: item.identifier, extrasIndex: item.extrasIndex,
                               isNativeOverflowControl: item.isNativeOverflowControl)
        }
    }

    // MARK: Pressing

    /// Re-resolve a listed item's `AXUIElement`: same owner, matching
    /// identifier or title when it has one, else the extras index.
    /// Returns nil when the owner is gone or the item moved beyond
    /// recognition.
    private nonisolated static func resolve(_ item: MenuBarItem) -> AXUIElement? {
        let elements = extrasItems(of: item.ownerPID)
        if let identifier = item.identifier,
           let match = elements.first(where: { string($0, "AXIdentifier") == identifier }) {
            return match
        }
        if let title = item.title,
           let match = elements.first(where: { string($0, kAXTitleAttribute) == title }) {
            return match
        }
        return elements.indices.contains(item.extrasIndex) ? elements[item.extrasIndex] : elements.first
    }

    /// The tile's click-through: `AXPress` the item's element. Works on
    /// covered items and on items macOS has parked off the row — both
    /// places a reposted click cannot reach. Falls back to
    /// `AXShowMenu` (the menu-extras action name) when a press is not
    /// offered.
    nonisolated static func press(_ item: MenuBarItem) -> Bool {
        guard let element = resolve(item) else { return false }
        if AXUIElementPerformAction(element, kAXPressAction as CFString) == .success { return true }
        return AXUIElementPerformAction(element, "AXShowMenu" as CFString) == .success
    }
}
