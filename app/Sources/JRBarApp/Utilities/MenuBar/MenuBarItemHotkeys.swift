import AppKit
import JRBarCore
import Observation

@MainActor
@Observable
final class MenuBarItemHotkeys {
    enum State: Equatable, Sendable {
        case ready, disabled, utilityOff, missing, ambiguous, invalid, permission, refused
        case conflict(String)

        var sentence: String {
            switch self {
            case .ready: return "Ready. Opens this menu bar item."
            case .disabled: return "Shortcut disabled."
            case .utilityOff: return "The Menu Bar utility is off."
            case .missing: return "This item is unavailable. Its key is not held."
            case .ambiguous: return "More than one item or owner matches. Its key is not held."
            case .invalid: return "This shortcut or item identity is invalid."
            case .permission: return "Accessibility permission is needed. Its key is not held."
            case .refused: return "The app or macOS refused this shortcut."
            case .conflict(let title): return "This key is also assigned to \(title)."
            }
        }
    }

    var center: HotkeyCenter
    private(set) var states: [String: State] = [:]
    @ObservationIgnored private var attemptedIDs: Set<String> = []
    @ObservationIgnored private var generation = 0
    @ObservationIgnored private(set) var activationTask: Task<Void, Never>?
    @ObservationIgnored private var snapshot: Snapshot?
    @ObservationIgnored private var lease = MenuBarItemShortcutLease()
    @ObservationIgnored private var latestInventory: [MenuBarItem] = []
    @ObservationIgnored var activate: (MenuBarItemShortcutTarget, MenuBarItemShortcutLease) async -> State = { _, _ in .refused }

    private struct Snapshot: Equatable {
        var bindings: [MenuBarItemHotkeyBinding]
        var inventory: [InventoryIdentity: Int]
        var running: Bool
        var permission: Bool
    }

    private struct InventoryIdentity: Hashable {
        var bundle: String?
        var identifier: String?
        var pid: Int32
        var protected: Bool
    }

    @ObservationIgnored private var externalEntries: [String: HotkeyCenter.Entry] = [:]

    init(center: HotkeyCenter = .shared) {
        self.center = center
        watchRegistry()
    }

    private func watchRegistry() {
        let outside = withObservationTracking {
            _ = center.refusals
            return center.entries.filter { !$0.key.hasPrefix("menubar.item.") }
        } onChange: { [weak self] in
            _ = Task { @MainActor [weak self] in
                guard let self else { return }
                let outside = self.center.entries.filter { !$0.key.hasPrefix("menubar.item.") }
                let changed = outside != self.externalEntries
                if let snapshot = self.snapshot {
                    self.reconcile(bindings: snapshot.bindings, inventory: self.latestInventory,
                                   running: snapshot.running, permission: snapshot.permission, force: changed)
                }
                self.watchRegistry()
            }
        }
        externalEntries = outside
    }

    nonisolated static func protected(_ item: MenuBarItem) -> Bool {
        if item.isNativeOverflowControl || item.ownerPID == ProcessInfo.processInfo.processIdentifier { return true }
        guard let bundle = item.bundleID, let own = Bundle.main.bundleIdentifier else { return false }
        return bundle == own || bundle.hasPrefix(own + ".")
    }

    nonisolated static func availability(_ target: MenuBarItemShortcutTarget,
                                         in inventory: [MenuBarItem]) -> State {
        let owners = inventory.filter { $0.bundleID == target.bundleID }
        guard !owners.isEmpty else { return .missing }
        guard Set(owners.map(\.ownerPID)).count == 1 else { return .ambiguous }
        let matches: [MenuBarItem]
        switch target.selector {
        case .soleItem: matches = owners
        case .identifier(let identifier): matches = owners.filter { $0.identifier == identifier }
        }
        guard !matches.isEmpty else { return .missing }
        guard matches.count == 1 else { return .ambiguous }
        return protected(matches[0]) ? .invalid : .ready
    }

    nonisolated static func target(for item: MenuBarItem, in inventory: [MenuBarItem]) -> MenuBarItemShortcutTarget? {
        guard !protected(item), let bundle = item.bundleID else { return nil }
        if let identifier = item.identifier,
           let target = MenuBarItemShortcutTarget(bundleID: bundle, selector: .identifier(identifier)),
           availability(target, in: inventory) == .ready { return target }
        guard let target = MenuBarItemShortcutTarget(bundleID: bundle, selector: .soleItem),
              availability(target, in: inventory) == .ready else { return nil }
        return target
    }

    nonisolated static func selectionProblem(for item: MenuBarItem, in inventory: [MenuBarItem]) -> String {
        guard let bundle = item.bundleID,
              !bundle.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return "This owner has no bundle identifier."
        }
        let owners = inventory.filter { $0.bundleID == bundle }
        if Set(owners.map(\.ownerPID)).count > 1 { return "More than one running app owns this item." }
        if let identifier = item.identifier, !identifier.isEmpty,
           owners.filter({ $0.identifier == identifier }).count > 1 {
            return "This Accessibility identifier is shared by multiple items."
        }
        return "This app has multiple items and this item has no unique Accessibility identifier."
    }

    func reconcile(bindings: [MenuBarItemHotkeyBinding], inventory: [MenuBarItem],
                   running: Bool, permission: Bool, force: Bool = false) {
        latestInventory = inventory
        let bundles = Set(bindings.map { $0.target.bundleID })
        let identities = inventory.filter { bundles.contains($0.bundleID ?? "") }.map {
            InventoryIdentity(bundle: $0.bundleID, identifier: $0.identifier,
                              pid: $0.ownerPID, protected: Self.protected($0))
        }
        let counts = Dictionary(grouping: identities, by: { $0 }).mapValues(\.count)
        let next = Snapshot(bindings: bindings, inventory: counts, running: running, permission: permission)
        if !force, snapshot == next {
            // A recorder's suspension can expose a system refusal on resume.
            for id in attemptedIDs where center.refusals[id] != nil { states[id] = .refused }
            return
        }
        lease.cancel()
        lease = MenuBarItemShortcutLease()
        generation += 1
        let currentGeneration = generation
        removeRegistrations()
        snapshot = next
        states = [:]
        let enabled = bindings.filter(\.enabled)
        let chords = Dictionary(grouping: enabled) { HotkeyChord(keyCode: $0.keyCode, modifiers: $0.modifiers) }
        let targets = Dictionary(grouping: bindings, by: \.target)
        for binding in bindings {
            let id = binding.id
            let chord = HotkeyChord(keyCode: binding.keyCode, modifiers: binding.modifiers)
            let state: State
            if targets[binding.target, default: []].count != 1 { state = .invalid }
            else if !binding.enabled { state = .disabled }
            else if !running { state = .utilityOff }
            else if !permission { state = .permission }
            else if binding.keyCode >= 256 || chord.problem != nil || binding.modifiers & ~UInt32(0x1B00) != 0 { state = .invalid }
            else if chords[chord, default: []].count > 1 {
                let names = chords[chord, default: []].filter { $0.id != id }.map(\.displayName)
                state = .conflict(names.joined(separator: ", "))
            }
            else { state = Self.availability(binding.target, in: inventory) }
            states[id] = state
            guard state == .ready else { continue }
            attemptedIDs.insert(id)
            let outcome = center.register(id, title: binding.displayName, chord: chord) { [weak self] in
                guard let self, self.generation == currentGeneration else { return }
                self.activationTask = Task { @MainActor [weak self] in
                    guard let self, !Task.isCancelled, self.generation == currentGeneration,
                          self.snapshot?.running == true else { return }
                    await self.activateBinding(binding)
                }
            }
            switch outcome {
            case .registered: break
            case .refused: states[id] = .refused
            case .conflict(let holder): states[id] = .conflict(holder.title)
            }
        }
    }

    func activateBinding(_ binding: MenuBarItemHotkeyBinding) async {
        guard snapshot?.bindings.contains(binding) == true,
              snapshot?.running == true, states[binding.id] == .ready else { return }
        let currentGeneration = generation
        let result = await activate(binding.target, lease)
        guard generation == currentGeneration else { return }
        states[binding.id] = result
        if result != .ready { center.unregister(binding.id) }
    }

    func stop() {
        activationTask?.cancel()
        activationTask = nil
        lease.cancel()
        generation += 1
        removeRegistrations()
        if let snapshot {
            for binding in snapshot.bindings { states[binding.id] = binding.enabled ? .utilityOff : .disabled }
        }
        snapshot = nil
    }

    private func removeRegistrations() {
        for id in attemptedIDs { center.unregister(id) }
        attemptedIDs = []
    }

    isolated deinit {
        lease.cancel()
        for id in attemptedIDs { center.unregister(id) }
    }
}

extension MenuBarUtility {
    func reconcileItemHotkeys(force: Bool = false) {
        actions.itemHotkeys.reconcile(bindings: settings().itemHotkeyBindings,
                                      inventory: listedItems, running: running,
                                      permission: accessibilityGranted, force: force)
    }

    func setItemHotkeyChord(_ chord: HotkeyChord?, for target: MenuBarItemShortcutTarget,
                            displayName: String? = nil) {
        if let chord {
            guard chord.problem == nil, chord.keyCode < 256,
                  chord.modifiers & ~UInt32(0x1B00) == 0 else { return }
        }
        var draft = settings()
        if let chord {
            if let index = draft.itemHotkeyBindings.firstIndex(where: { $0.target == target }) {
                draft.itemHotkeyBindings[index].keyCode = chord.keyCode
                draft.itemHotkeyBindings[index].modifiers = chord.modifiers
                draft.itemHotkeyBindings[index].enabled = true
            } else {
                draft.itemHotkeyBindings.append(MenuBarItemHotkeyBinding(
                    target: target, displayName: displayName ?? target.bundleID,
                    keyCode: chord.keyCode, modifiers: chord.modifiers))
            }
        } else {
            draft.itemHotkeyBindings.removeAll { $0.target == target }
        }
        onSettingsChange?(draft)
    }

    func setItemHotkeyEnabled(_ enabled: Bool, for target: MenuBarItemShortcutTarget) {
        var draft = settings()
        guard let index = draft.itemHotkeyBindings.firstIndex(where: { $0.target == target }) else { return }
        draft.itemHotkeyBindings[index].enabled = enabled
        onSettingsChange?(draft)
    }

    func openShortcutTarget(_ target: MenuBarItemShortcutTarget,
                            lease: MenuBarItemShortcutLease) async -> MenuBarItemHotkeys.State {
        guard running else { return .utilityOff }
        guard probeAccessibility() else { return .permission }
        let client = itemShortcutNative
        return await Task.detached(priority: .userInitiated) { client.open(target, lease: lease) }.value
    }
}
