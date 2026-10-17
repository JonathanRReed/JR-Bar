import Foundation

/// Local search labels use only the identity an app explicitly supplies.
enum MenuBarSearchNames {
    nonisolated static func key(for item: MenuBarItem) -> String? {
        guard let bundle = item.bundleID, !bundle.isEmpty,
              let identifier = item.identifier, !identifier.isEmpty else { return nil }
        return "v1:\(bundle.utf8.count):\(bundle)\(identifier.utf8.count):\(identifier)"
    }

    nonisolated static func uniqueKey(for item: MenuBarItem, inventory: [MenuBarItem]) -> String? {
        guard let key = key(for: item),
              inventory.lazy.filter({ self.key(for: $0) == key }).count == 1 else { return nil }
        return key
    }

    nonisolated static func normalized(_ name: String) -> String? {
        guard !name.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else {
            return nil
        }
        return String(name.trimmingCharacters(in: .whitespacesAndNewlines).prefix(96))
    }

    nonisolated static func applying(_ names: [String: String], to items: [MenuBarItem],
                                     inventory: [MenuBarItem]? = nil) -> [MenuBarItem] {
        let counts = Dictionary((inventory ?? items).compactMap { key(for: $0) }
            .map { ($0, 1) }, uniquingKeysWith: +)
        return items.map { item in
            var labeled = item
            labeled.searchName = nil
            if let key = key(for: item), counts[key] == 1,
               let stored = names[key], let name = normalized(stored), !name.isEmpty {
                labeled.searchName = name
            }
            return labeled
        }
    }
}
