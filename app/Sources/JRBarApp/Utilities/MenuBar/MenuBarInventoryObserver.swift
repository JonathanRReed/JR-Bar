import AppKit
import ApplicationServices

/// Watches known owners without querying every owner on a timer. Unsupported
/// notifications are harmless; the thirty-second inventory scan remains.
final class MenuBarInventoryObserver: @unchecked Sendable {
    private let queue = DispatchQueue(label: "jrbar.menu-inventory-observer", qos: .utility)
    private var observers: [pid_t: AXObserver] = [:]

    func watch(pids: Set<pid_t>) {
        queue.async { [self] in
            for pid in Array(observers.keys) where !pids.contains(pid) {
                remove(pid)
            }
            for pid in pids where observers[pid] == nil {
                var observer: AXObserver?
                let callback: AXObserverCallback = { _, _, _, _ in
                    DispatchQueue.main.async { MenuBarItemLister.noteBarActivity() }
                }
                guard AXObserverCreate(pid, callback, &observer) == .success, let observer else { continue }
                let app = AXUIElementCreateApplication(pid)
                AXUIElementSetMessagingTimeout(app, 0.1)
                _ = AXObserverAddNotification(observer, app, kAXCreatedNotification as CFString, nil)
                _ = AXObserverAddNotification(observer, app, kAXWindowCreatedNotification as CFString, nil)
                var value: CFTypeRef?
                if AXUIElementCopyAttributeValue(app, "AXExtrasMenuBar" as CFString, &value) == .success,
                   let value, CFGetTypeID(value) == AXUIElementGetTypeID() {
                    let bar = value as! AXUIElement
                    var elements = [bar]
                    var children: CFTypeRef?
                    if AXUIElementCopyAttributeValue(bar, kAXChildrenAttribute as CFString, &children) == .success,
                       let items = children as? [AXUIElement] { elements += items }
                    for element in elements {
                        for name in [kAXCreatedNotification, kAXUIElementDestroyedNotification,
                                     kAXMovedNotification, kAXResizedNotification] {
                            _ = AXObserverAddNotification(observer, element, name as CFString, nil)
                        }
                    }
                }
                observers[pid] = observer
                CFRunLoopAddSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), .commonModes)
            }
        }
    }

    func stop() {
        queue.async { [self] in
            for pid in Array(observers.keys) { remove(pid) }
        }
    }

    private func remove(_ pid: pid_t) {
        guard let observer = observers.removeValue(forKey: pid) else { return }
        CFRunLoopRemoveSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), .commonModes)
    }
}
