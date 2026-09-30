import Foundation
@testable import JRBarCore

extension SettingsKey {
    /// Resolves the catalogue path against a document: a plain path must
    /// exist; a `devices[]` path must exist in every device entry (and
    /// there must be at least one). The app asks the store instead
    /// (`SettingsStore.isProvided`); the catalogue tests ask the document.
    func isProvided(in document: SettingsDocument) -> Bool {
        if path.hasPrefix("devices[].") {
            let leaf = String(path.dropFirst("devices[].".count))
            let entries = document.deviceEntries
            guard !entries.isEmpty else { return false }
            return entries.allSatisfy { $0.entry[leaf] != nil }
        }
        return document.contains(SettingsPath(path))
    }
}
