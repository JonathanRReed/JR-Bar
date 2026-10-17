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
///   * `scan(targets:rows:)` — the listing `MenuBarItemLister` caches,
///     one bounded AX query per running app, a few at a time because a
///     slow app must never stall the whole scan.
///   * `press(_:)` — the Item Bar tile's click-through: re-resolve the
///     item's element and `AXPress` it, which reaches covered *and*
///     system-parked items a synthetic click could not.
///
/// Every element gets a messaging timeout: an app that never answers
/// AX would otherwise hang the call site for seconds.
enum MenuBarAX {
    /// One scannable process: pid plus the display name used for the
    /// item's owner and its bundle identifier, read off the workspace's
    /// `NSRunningApplication` — all Sendable, so the scan runs off the
    /// actor.
    struct Target: Sendable {
        let pid: pid_t
        let name: String
        var bundleID: String? = nil
        /// How long this app may take to answer: `messagingTimeout` for
        /// an app known to own items, `quickTimeout` for the rest of a
        /// full walk.
        var timeout: TimeInterval = MenuBarAX.messagingTimeout
    }

    /// How long one app may take to answer an AX query before the scan
    /// gives up on it.
    nonisolated static let messagingTimeout: TimeInterval = 1.0
    /// The wait for an app not known to own an item — most of a full
    /// walk. A slow one that runs out is asked again on the next scan
    /// with `messagingTimeout` (`Scan.timedOut`), so an owner that was
    /// merely busy is late by one scan, not missed.
    nonisolated static let quickTimeout: TimeInterval = 0.25
    /// How many apps a scan asks at once. Each query blocks a thread in
    /// IPC until its app answers; a pool as wide as the CPUs woke a
    /// dozen threads for 150 apps, where four keep a hung app from
    /// stalling the scan just as well.
    nonisolated static let maxConcurrentQueries = 4

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

    /// One extras-bar child with the attributes the listing reads.
    struct ExtrasElement {
        let element: AXUIElement
        let role: String?
        let position: CGPoint
        let size: CGSize
        let title: String?
        let identifier: String?
        var identifierComplete = true
        var status = InventoryStatus()
    }

    struct InventoryStatus {
        var incomplete = false
        var timedOut = false

        mutating func include(_ other: Self) {
            incomplete = incomplete || other.incomplete
            timedOut = timedOut || other.timedOut
        }
    }

    struct AttributeRead {
        var value: CFTypeRef?
        var error: AXError
    }

    /// Batch copies encode per-attribute errors as AXValues.
    nonisolated static func batchAttribute(_ value: CFTypeRef) -> AttributeRead {
        if CFGetTypeID(value) == AXValueGetTypeID(), AXValueGetType(value as! AXValue) == .axError {
            var error = AXError.failure
            AXValueGetValue(value as! AXValue, .axError, &error)
            return AttributeRead(value: nil, error: error)
        }
        return AttributeRead(value: value, error: .success)
    }

    private nonisolated static func copyAttribute(_ element: AXUIElement, _ attribute: String) -> AttributeRead {
        var value: CFTypeRef?
        let error = AXUIElementCopyAttributeValue(element, attribute as CFString, &value)
        return AttributeRead(value: value, error: error)
    }

    nonisolated static func extrasStatus(_ read: AttributeRead) -> InventoryStatus {
        if read.error == .attributeUnsupported || read.error == .noValue { return InventoryStatus() }
        let valid = read.error == .success && read.value.map { CFGetTypeID($0) == AXUIElementGetTypeID() } == true
        return InventoryStatus(incomplete: !valid, timedOut: read.error == .cannotComplete)
    }

    nonisolated static func childrenStatus(error: AXError, hasChildren: Bool) -> InventoryStatus {
        InventoryStatus(incomplete: error != .success || !hasChildren, timedOut: error == .cannotComplete)
    }

    /// Geometry is required for item roles; groups only need their role
    /// and a separate successful children read. Labels are optional.
    nonisolated static func elementStatus(_ reads: [AttributeRead], includeButtons: Bool = true) -> InventoryStatus {
        guard reads.count == elementAttributes.count else { return InventoryStatus(incomplete: true) }
        let role = reads[0], position = reads[1], size = reads[2]
        guard role.error == .success, let name = role.value as? String else {
            return InventoryStatus(incomplete: true, timedOut: role.error == .cannotComplete)
        }
        guard name == "AXMenuBarItem" || (includeButtons && name == "AXButton") else { return InventoryStatus() }
        let geometry = [(position, AXValueType.cgPoint), (size, AXValueType.cgSize)]
        let invalid = geometry.contains { read, type in
            read.error != .success || read.value.map {
                CFGetTypeID($0) != AXValueGetTypeID() || AXValueGetType($0 as! AXValue) != type
            } != false
        }
        return InventoryStatus(incomplete: invalid,
                               timedOut: geometry.contains { $0.0.error == .cannotComplete })
    }

    /// The attributes an extras child is read for, in one request.
    private nonisolated static let elementAttributes: [String] = [
        kAXRoleAttribute, kAXPositionAttribute, kAXSizeAttribute, kAXTitleAttribute, "AXIdentifier",
    ]

    /// Role, position, size, title and identifier of one element in a
    /// single round trip — five separate copies were five, each one a
    /// Mach message pair and a wake of the owner's main thread. Falls
    /// back to the separate copies if the owner refuses the batch.
    private nonisolated static func read(_ element: AXUIElement, includeButtons: Bool = true) -> ExtrasElement {
        var values: CFArray?
        let reads: [AttributeRead]
        if AXUIElementCopyMultipleAttributeValues(element, elementAttributes as CFArray, AXCopyMultipleAttributeOptions(),
                                                  &values) == .success,
           let list = values as? [AnyObject], list.count == 5 {
            reads = list.map { batchAttribute($0 as CFTypeRef) }
        } else {
            reads = elementAttributes.map { copyAttribute(element, $0) }
        }
        return extrasElement(element, reads: reads, includeButtons: includeButtons)
    }

    nonisolated static func identifierReadComplete(_ read: AttributeRead) -> Bool {
        if read.error == .attributeUnsupported || read.error == .noValue { return true }
        guard read.error == .success, let value = read.value else { return false }
        return CFGetTypeID(value) == CFStringGetTypeID()
    }

    nonisolated static func extrasElement(_ element: AXUIElement, reads: [AttributeRead],
                                         includeButtons: Bool = true) -> ExtrasElement {
        guard reads.count == elementAttributes.count else {
            return ExtrasElement(element: element, role: nil, position: .zero,
                                 size: .zero, title: nil, identifier: nil,
                                 identifierComplete: false, status: InventoryStatus(incomplete: true))
        }
        var position = CGPoint.zero
        if let value = reads[1].value, CFGetTypeID(value) == AXValueGetTypeID(),
           AXValueGetType(value as! AXValue) == .cgPoint {
            AXValueGetValue(value as! AXValue, .cgPoint, &position)
        }
        var size = CGSize.zero
        if let value = reads[2].value, CFGetTypeID(value) == AXValueGetTypeID(),
           AXValueGetType(value as! AXValue) == .cgSize {
            AXValueGetValue(value as! AXValue, .cgSize, &size)
        }
        return ExtrasElement(element: element, role: reads[0].value as? String,
                             position: position, size: size,
                             title: (reads[3].value as? String).flatMap { $0.isEmpty ? nil : $0 },
                             identifier: reads[4].error == .success
                                ? (reads[4].value as? String).flatMap { $0.isEmpty ? nil : $0 } : nil,
                             identifierComplete: identifierReadComplete(reads[4]),
                             status: elementStatus(reads, includeButtons: includeButtons))
    }

    /// The extras-bar children of one app that are menu bar items —
    /// `AXMenuBarItem`s directly, or grouped one level under an
    /// `AXGroup` (some apps wrap theirs) — plus any `AXButton` the bar
    /// fields directly: that is how MenuBarAgent exposes its overflow
    /// control, and the plan needs its frame. `timedOut` says the app
    /// did not answer the first question in time.
    private nonisolated static func extrasElements(of pid: pid_t,
                                                   timeout: TimeInterval = messagingTimeout)
        -> (elements: [ExtrasElement], status: InventoryStatus) {
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, Float(timeout))
        let extrasRead = copyAttribute(app, "AXExtrasMenuBar")
        guard extrasRead.error == .success, let extras = extrasRead.value,
              CFGetTypeID(extras) == AXUIElementGetTypeID()
        else { return ([], extrasStatus(extrasRead)) }
        let bar = extras as! AXUIElement
        AXUIElementSetMessagingTimeout(bar, Float(timeout))
        var childrenValue: CFTypeRef?
        let childrenError = AXUIElementCopyAttributeValue(bar, kAXChildrenAttribute as CFString, &childrenValue)
        // A stall on the children copy earns the retry as much as one
        // on the extras question — a would-be owner that only ever ran
        // out the quick wait would otherwise be skipped every walk.
        guard childrenError == .success, let children = childrenValue as? [AXUIElement]
        else { return ([], childrenStatus(error: childrenError, hasChildren: false)) }
        var items: [ExtrasElement] = []
        var status = InventoryStatus()
        for child in children {
            AXUIElementSetMessagingTimeout(child, Float(timeout))
            let entry = Self.read(child)
            status.include(entry.status)
            if entry.role == "AXMenuBarItem" || entry.role == "AXButton" {
                items.append(entry)
            } else if entry.role == "AXGroup" {
                let copied = copyAttribute(child, kAXChildrenAttribute)
                let children = copied.value as? [AXUIElement]
                status.include(childrenStatus(error: copied.error, hasChildren: children != nil))
                guard copied.error == .success, let sub = children else { continue }
                for element in sub {
                    AXUIElementSetMessagingTimeout(element, Float(timeout))
                    let item = Self.read(element, includeButtons: false)
                    status.include(item.status)
                    if item.role == "AXMenuBarItem" { items.append(item) }
                }
            }
        }
        return (items, status)
    }

    /// One app's extras items → `MenuBarItem`s (identities not yet
    /// assigned — that happens in `items(from:)`, which sees all
    /// owners at once).
    private nonisolated static func rawItems(of target: Target,
                                             rows: [CGRect]) -> (items: [MenuBarItem], status: InventoryStatus) {
        let answer = extrasElements(of: target.pid, timeout: target.timeout)
        let items = answer.elements.enumerated().compactMap { index, element -> MenuBarItem? in
            let size = element.size
            guard size.width >= MenuBarItemLister.minItemWidth,
                  size.height > 0 else { return nil }
            let bounds = CGRect(origin: element.position, size: size)
            // An item reports either on a row or parked below it;
            // anything else is a transient non-item (mid-teardown).
            // Multi-display: the check holds against every bar's strip —
            // an item on a secondary row must not read as torn down.
            guard rows.contains(where: {
                bounds.minY < $0.maxY + 2 || bounds.minY > $0.maxY + 100
            }) else { return nil }
            return MenuBarItem(id: "", ownerPID: target.pid, ownerName: target.name,
                               bounds: bounds, title: element.title,
                               windowID: 0,
                               identifier: element.identifier,
                               extrasIndex: index,
                               isNativeOverflowControl: element.role == "AXButton",
                               bundleID: target.bundleID)
        }
        return (items, answer.status)
    }

    /// A scan's answer: the items, and the apps that ran out of time.
    struct Scan: Sendable {
        var items: [MenuBarItem]
        var timedOut: Set<pid_t>
        var incomplete: Set<pid_t> = []
    }

    /// Every target's extras items, identities assigned, sorted left to
    /// right (parked items sort last — their offscreen positions are
    /// not bar order), with the apps that ran out of time. Asks
    /// `maxConcurrentQueries` apps at once, each bounded by its target's
    /// timeout, so a hung app costs its timeout, not the whole scan.
    nonisolated static func scan(targets: [Target], rows: [CGRect]) -> Scan {
        /// Lock-guarded work queue and accumulation for the workers.
        final class Box: @unchecked Sendable {
            let lock = NSLock()
            var next = 0
            var items: [MenuBarItem] = []
            var timedOut: Set<pid_t> = []
            var incomplete: Set<pid_t> = []
        }
        let box = Box()
        let workers = min(maxConcurrentQueries, targets.count)
        DispatchQueue.concurrentPerform(iterations: workers) { _ in
            while true {
                box.lock.lock()
                let i = box.next
                box.next += 1
                box.lock.unlock()
                guard i < targets.count else { return }
                let answer = rawItems(of: targets[i], rows: rows)
                guard !answer.items.isEmpty || answer.status.incomplete else { continue }
                box.lock.lock()
                box.items.append(contentsOf: answer.items)
                if answer.status.timedOut { box.timedOut.insert(targets[i].pid) }
                if answer.status.incomplete { box.incomplete.insert(targets[i].pid) }
                box.lock.unlock()
            }
        }
        let collected = box.items
        let onRow = collected.filter { item in rows.contains { $0.intersects(item.bounds) } }
            .sorted { $0.bounds.minX < $1.bounds.minX }
        let parked = collected.filter { item in !rows.contains { $0.intersects(item.bounds) } }
            .sorted { $0.ownerName.localizedCompare($1.ownerName) == .orderedAscending }
        let ordered = onRow + parked
        var totals: [String: Int] = [:]
        for item in ordered { totals[MenuBarItemLister.base(of: item), default: 0] += 1 }
        var seen: [String: Int] = [:]
        let items = ordered.map { item in
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
                               isNativeOverflowControl: item.isNativeOverflowControl,
                               bundleID: item.bundleID)
        }
        return Scan(items: items, timedOut: box.timedOut, incomplete: box.incomplete)
    }

    /// The front app's menu extras' right edge — where its menus stop
    /// in Quartz points. `AXMenuBar`'s `AXMenuBarItem` children are
    /// the menus (Apple, app name, File…); the extras live on
    /// `AXExtrasMenuBar` instead, so the rightmost menu item is the
    /// far edge of the zone where a status item draws under menu text.
    /// nil when the front app answers no AXMenuBar or Accessibility is
    /// refused.
    nonisolated static func frontMenuRightEdge(pid: pid_t) -> CGFloat? {
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, Float(messagingTimeout))
        var bar: CFTypeRef?
        guard AXUIElementCopyAttributeValue(app, "AXMenuBar" as CFString, &bar) == .success,
              let bar, CFGetTypeID(bar) == AXUIElementGetTypeID() else { return nil }
        let barElement = bar as! AXUIElement
        AXUIElementSetMessagingTimeout(barElement, Float(messagingTimeout))
        guard let children = value(barElement, kAXChildrenAttribute) as? [AXUIElement]
        else { return nil }
        var edge: CGFloat = 0
        var found = false
        for child in children {
            AXUIElementSetMessagingTimeout(child, Float(messagingTimeout))
            guard role(child) == "AXMenuBarItem" else { continue }
            let frame = CGRect(origin: point(child, kAXPositionAttribute),
                               size: size(child, kAXSizeAttribute))
            guard frame.width > 0 else { continue }
            edge = max(edge, frame.maxX)
            found = true
        }
        return found ? edge : nil
    }

    nonisolated static func shortcutInventory(of pid: pid_t) -> MenuBarItemShortcutNative.Inventory {
        let answer = extrasElements(of: pid)
        return shortcutInventory(elements: answer.elements, status: answer.status)
    }

    nonisolated static func shortcutInventory(
        elements: [ExtrasElement], status: InventoryStatus,
        perform: @escaping (AXUIElement, CFString) -> AXError = AXUIElementPerformAction
    ) -> MenuBarItemShortcutNative.Inventory {
        let rows = elements.map { entry in
            MenuBarItemShortcutNative.Element(identifier: entry.identifier,
                                               protected: entry.role != "AXMenuBarItem",
                                               press: { pressShortcutElement(entry.element, perform: perform) })
        }
        return MenuBarItemShortcutNative.Inventory(elements: rows, complete: !status.incomplete,
                                                    identifiersComplete: elements.allSatisfy(\.identifierComplete))
    }

    nonisolated static func pressShortcutElement(
        _ element: AXUIElement,
        perform: (AXUIElement, CFString) -> AXError = AXUIElementPerformAction
    ) -> Bool {
        if delivered(perform(element, kAXPressAction as CFString)) { return true }
        return delivered(perform(element, kAXShowMenuAction as CFString))
    }

    // MARK: Pressing

    /// Re-resolve a listed item's `AXUIElement`: same owner, matching
    /// identifier or title when it has one, else the extras index.
    /// Returns nil when the owner is gone or the item moved beyond
    /// recognition.
    private nonisolated static func resolve(_ item: MenuBarItem) -> AXUIElement? {
        let elements = extrasElements(of: item.ownerPID).elements
        if let identifier = item.identifier,
           let match = elements.first(where: { $0.identifier == identifier }) {
            return match.element
        }
        if let title = item.title,
           let match = elements.first(where: { $0.title == title }) {
            return match.element
        }
        return elements.indices.contains(item.extrasIndex) ? elements[item.extrasIndex].element
            : elements.first?.element
    }

    /// The tile's click-through: `AXPress` the item's element. Works on
    /// covered items and on items macOS has parked off the row — both
    /// places a reposted click cannot reach. Falls back to
    /// `AXShowMenu` (the menu-extras action name) when a press is not
    /// offered.
    nonisolated static func press(_ item: MenuBarItem) -> Bool {
        guard let element = resolve(item) else { return false }
        if delivered(AXUIElementPerformAction(element, kAXPressAction as CFString)) { return true }
        return delivered(AXUIElementPerformAction(element, "AXShowMenu" as CFString))
    }

    /// Whether an action's result means the app got it. An app that
    /// opens its menu on the press is tracking that menu when the reply
    /// is due, so the press times out as `cannotComplete` although it
    /// landed — a fallback then would show the menu twice, or raise the
    /// owner over the menu it just opened.
    nonisolated static func delivered(_ result: AXError) -> Bool {
        result == .success || result == .cannotComplete
    }
}
