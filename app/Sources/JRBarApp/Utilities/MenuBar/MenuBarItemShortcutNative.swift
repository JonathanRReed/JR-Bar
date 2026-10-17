import AppKit
import ApplicationServices
import JRBarCore

final class MenuBarItemShortcutLease: @unchecked Sendable {
    private let lock = NSLock()
    private var valid = true

    func cancel() {
        lock.lock()
        valid = false
        lock.unlock()
    }

    var isValid: Bool {
        lock.lock()
        defer { lock.unlock() }
        return valid
    }

    func admitPress() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return valid
    }
}

struct MenuBarItemShortcutNative: Sendable {
    struct Element: @unchecked Sendable {
        var identifier: String?
        var protected: Bool
        var press: () -> Bool
    }
    struct Inventory: Sendable {
        var elements: [Element]
        var complete: Bool
        var identifiersComplete = true
    }
    var processes: @Sendable (String) -> [Int32]
    var enumerate: @Sendable (Int32) -> Inventory

    func open(_ target: MenuBarItemShortcutTarget,
              lease: MenuBarItemShortcutLease = MenuBarItemShortcutLease()) -> MenuBarItemHotkeys.State {
        guard lease.isValid else { return .utilityOff }
        if let own = Bundle.main.bundleIdentifier,
           target.bundleID == own || target.bundleID.hasPrefix(own + ".") { return .invalid }
        let owners = processes(target.bundleID)
        guard lease.isValid else { return .utilityOff }
        guard !owners.contains(ProcessInfo.processInfo.processIdentifier) else { return .invalid }
        guard !owners.isEmpty else { return .missing }
        guard owners.count == 1 else { return .ambiguous }
        guard lease.isValid else { return .utilityOff }
        let inventory = enumerate(owners[0])
        guard lease.isValid else { return .utilityOff }
        guard inventory.complete else { return .refused }
        let matches: [Element]
        switch target.selector {
        case .soleItem: matches = inventory.elements
        case .identifier(let value):
            guard inventory.identifiersComplete else { return .refused }
            matches = inventory.elements.filter { $0.identifier == value }
        }
        guard !matches.isEmpty else { return .missing }
        guard matches.count == 1 else { return .ambiguous }
        guard !matches[0].protected else { return .invalid }
        guard lease.isValid else { return .utilityOff }
        let currentOwners = processes(target.bundleID)
        guard lease.isValid else { return .utilityOff }
        guard !currentOwners.isEmpty else { return .missing }
        guard currentOwners.count == 1 else { return .ambiguous }
        guard currentOwners[0] == owners[0] else { return .missing }
        guard lease.admitPress() else { return .utilityOff }
        return matches[0].press() ? .ready : .refused
    }

    static let live = MenuBarItemShortcutNative(processes: { bundle in
        NSRunningApplication.runningApplications(withBundleIdentifier: bundle).map(\.processIdentifier)
    }, enumerate: { pid in MenuBarAX.shortcutInventory(of: pid) })
}
