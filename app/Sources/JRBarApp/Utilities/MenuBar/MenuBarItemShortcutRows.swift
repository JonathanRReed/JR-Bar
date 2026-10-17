import JRBarCore
import SwiftUI

struct MenuBarItemShortcutSavedRow: View {
    let binding: MenuBarItemHotkeyBinding
    let state: MenuBarItemHotkeys.State
    let center: HotkeyCenter
    let onChange: (HotkeyChord?) -> Void
    let onEnabled: (Bool) -> Void
    let onTakeOver: (String) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            ShortcutRow(title: binding.displayName, subtitle: state.sentence,
                        id: binding.id,
                        chord: HotkeyChord(keyCode: binding.keyCode, modifiers: binding.modifiers),
                        isOn: Binding(get: { binding.enabled }, set: onEnabled),
                        center: center, onChange: onChange, onTakeOver: onTakeOver)
            Button("Remove item shortcut", role: .destructive) { onChange(nil) }
                .buttonStyle(.plain)
                .font(.caption)
                .padding(.bottom, 6)
        }
    }
}

struct MenuBarItemShortcutRows: View {
    let menuBar: MenuBarUtility
    let center: HotkeyCenter
    let onTakeOver: (String) -> Void
    @ViewState private var adding = false
    @ViewState private var draft: MenuBarItemShortcutTarget?
    @ViewState private var draftName = ""

    private var bindings: [MenuBarItemHotkeyBinding] { menuBar.settings().itemHotkeyBindings }
    private struct Candidate: Identifiable {
        let item: MenuBarItem
        let target: MenuBarItemShortcutTarget
        var id: String { target.registryID }
    }
    private var candidates: [Candidate] {
        menuBar.listedItems.compactMap { item in
            guard let target = MenuBarItemHotkeys.target(for: item, in: menuBar.listedItems),
                  !bindings.contains(where: { $0.target == target }) else { return nil }
            return Candidate(item: item, target: target)
        }
    }

    private var unavailableItems: [MenuBarItem] {
        menuBar.listedItems.filter { item in
            guard !MenuBarItemHotkeys.protected(item) else { return false }
            let assigned = bindings.contains { binding in
                guard binding.target.bundleID == item.bundleID else { return false }
                switch binding.target.selector {
                case .identifier(let value): return value == item.identifier
                case .soleItem: return true
                }
            }
            guard !assigned else { return false }
            return MenuBarItemHotkeys.target(for: item, in: menuBar.listedItems) == nil
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(bindings) { binding in
                MenuBarItemShortcutSavedRow(
                    binding: binding,
                    state: menuBar.actions.itemHotkeys.states[binding.id] ?? .utilityOff,
                    center: center,
                    onChange: { menuBar.setItemHotkeyChord($0, for: binding.target) },
                    onEnabled: { menuBar.setItemHotkeyEnabled($0, for: binding.target) },
                    onTakeOver: onTakeOver)
            }
            Button(adding ? "Cancel adding item" : "Add item…") {
                adding.toggle()
                draft = nil
                if adding { menuBar.refreshListing() }
            }
            if adding {
                Text("Choose an item, then record its shortcut. Items without an identifier can be assigned only when their app has one menu bar item. If it adds another, the shortcut pauses.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if !menuBar.accessibilityGranted {
                    Text("Accessibility permission is needed to identify menu bar items.")
                        .foregroundStyle(.secondary)
                } else if candidates.isEmpty {
                    Text("No unassigned item has a unique identity. Refresh after its app is running.")
                        .foregroundStyle(.secondary)
                }
                ForEach(candidates) { candidate in
                    Button {
                        draft = candidate.target
                        draftName = candidate.item.searchName ?? candidate.item.title ?? candidate.item.ownerName
                    } label: {
                        HStack {
                            Text(candidate.item.searchName ?? candidate.item.title ?? candidate.item.ownerName)
                            Spacer()
                            Text(candidate.item.ownerName).foregroundStyle(.secondary)
                            if case .soleItem = candidate.target.selector {
                                Text("Only item").font(.caption).foregroundStyle(.secondary)
                            }
                        }
                    }
                    .buttonStyle(.plain)
                }
                ForEach(Array(unavailableItems.enumerated()), id: \.offset) { _, item in
                    Button {} label: {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(item.searchName ?? item.title ?? item.ownerName)
                            Text(MenuBarItemHotkeys.selectionProblem(for: item, in: menuBar.listedItems))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .buttonStyle(.plain)
                    .disabled(true)
                }
                if let draft {
                    ShortcutRow(title: draftName, subtitle: "Record a key to save this item.",
                                id: draft.registryID, chord: nil, center: center,
                                onChange: { chord in
                                    guard let chord else { return }
                                    menuBar.setItemHotkeyChord(chord, for: draft, displayName: draftName)
                                    self.draft = nil
                                    adding = false
                                }, onTakeOver: onTakeOver)
                }
                Button("Refresh items") { menuBar.refreshShortcutItems() }
            }
        }
        .onAppear { menuBar.reconcileItemHotkeys() }
    }
}

extension MenuBarUtility {
    func refreshShortcutItems() {
        if !running { refreshListing(); return }
        _ = Task { @MainActor [weak self] in
            _ = await MenuBarItemLister.refreshAXItems()
            guard let self, self.running else { return }
            self.hider.reconcile()
            self.reconcileItemHotkeys(force: true)
        }
    }
}
