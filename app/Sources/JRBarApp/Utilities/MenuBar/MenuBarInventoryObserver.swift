import AppKit
import ApplicationServices

/// Watches menu extras only. Geometry changes belong to the hider's 1 Hz
/// pass; unsupported notifications retain the thirty-second safety scan.
final class MenuBarInventoryObserver: @unchecked Sendable {
    private let queue = DispatchQueue(label: "jrbar.menu-inventory-observer", qos: .utility)
    private var observers: [pid_t: AXObserver] = [:]
    private var elements: [pid_t: [AXUIElement]] = [:]
    static let notifications = [kAXCreatedNotification, kAXUIElementDestroyedNotification]

    static func changes(from old: [AXUIElement], to new: [AXUIElement])
        -> (removed: [AXUIElement], added: [AXUIElement]) {
        (old.filter { element in !new.contains { CFEqual(element, $0) } },
         new.filter { element in !old.contains { CFEqual(element, $0) } })
    }

    func watch(pids: Set<pid_t>) {
        queue.async { [self] in
            for pid in Array(observers.keys) where !pids.contains(pid) { remove(pid) }
            for pid in pids {
                if observers[pid] == nil {
                    var observer: AXObserver?
                    let callback: AXObserverCallback = { _, _, name, _ in
                        guard MenuBarInventoryObserver.notifications.contains(name as String) else { return }
                        DispatchQueue.main.async { MenuBarItemLister.noteBarActivity() }
                    }
                    guard AXObserverCreate(pid, callback, &observer) == .success, let observer else { continue }
                    observers[pid] = observer
                    CFRunLoopAddSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), .commonModes)
                }
                guard let observer = observers[pid] else { continue }
                let app = AXUIElementCreateApplication(pid)
                AXUIElementSetMessagingTimeout(app, 0.1)
                var current: [AXUIElement] = []
                var value: CFTypeRef?
                if AXUIElementCopyAttributeValue(app, "AXExtrasMenuBar" as CFString, &value) == .success,
                   let value, CFGetTypeID(value) == AXUIElementGetTypeID() {
                    let bar = value as! AXUIElement
                    current.append(bar)
                    var children: CFTypeRef?
                    if AXUIElementCopyAttributeValue(bar, kAXChildrenAttribute as CFString, &children) == .success,
                       let items = children as? [AXUIElement] { current += items }
                }
                let delta = Self.changes(from: elements[pid] ?? [], to: current)
                for element in delta.removed {
                    for name in Self.notifications {
                        _ = AXObserverRemoveNotification(observer, element, name as CFString)
                    }
                }
                for element in delta.added {
                    for name in Self.notifications {
                        _ = AXObserverAddNotification(observer, element, name as CFString, nil)
                    }
                }
                elements[pid] = current
            }
        }
    }

    func stop() {
        queue.async { [self] in
            for pid in Array(observers.keys) { remove(pid) }
        }
    }

    private func remove(_ pid: pid_t) {
        elements.removeValue(forKey: pid)
        guard let observer = observers.removeValue(forKey: pid) else { return }
        CFRunLoopRemoveSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), .commonModes)
    }
}
