import Foundation
import JRBarCore

/// Named presets for the Menu Bar utility: a captured section map plus
/// the cover's appearance and control layout, persisted inside
/// `MenuBarSettings.profiles`. The logic is pure — profiles are values
/// — so save/apply/rename/delete round-trips are testable without the
/// card. Applying one lands through the utility's normal settings
/// write, so the reconcile path restyles and re-covers exactly as a
/// hand edit would.
enum MenuBarProfiles {
    /// The built-in state the card lists first: no sections assigned,
    /// default appearance. It is not a `Profile` — there is nothing to
    /// rename or delete.
    nonisolated static let noneID = "none"
    /// The name the built-in state shows.
    nonisolated static let noneName = "None"

    /// Snapshot the settings a profile keeps: sections plus the cover
    /// appearance and control layout.
    nonisolated static func capture(name: String, from settings: MenuBarSettings,
                                    id: String = UUID().uuidString) -> MenuBarSettings.Profile {
        MenuBarSettings.Profile(
            id: id, name: name, sections: settings.sections,
            coverMaterial: settings.coverMaterial, coverTint: settings.coverTint,
            coverTintOpacity: settings.coverTintOpacity,
            coverRoundness: settings.coverRoundness,
            showCoverSeparator: settings.showCoverSeparator,
            combinedStatusItem: settings.combinedStatusItem)
    }

    /// Apply a profile wholesale: its sections and appearance replace
    /// the live ones. `nil` is the "None" state — every section back
    /// to shown, the plain `.menu` cover, the two separate controls.
    /// The reveal gestures and `enabled` are not the profile's
    /// business and survive either way.
    nonisolated static func apply(_ profile: MenuBarSettings.Profile?,
                                  to settings: inout MenuBarSettings) {
        guard let profile else {
            settings.sections = [:]
            settings.coverMaterial = .menu
            settings.coverTint = ""
            settings.coverTintOpacity = MenuBarSettings.defaultCoverTintOpacity
            settings.coverRoundness = 0
            settings.showCoverSeparator = false
            settings.combinedStatusItem = false
            return
        }
        settings.sections = profile.sections
        settings.coverMaterial = profile.coverMaterial
        settings.coverTint = profile.coverTint
        settings.coverTintOpacity = profile.coverTintOpacity
        settings.coverRoundness = profile.coverRoundness
        settings.showCoverSeparator = profile.showCoverSeparator
        settings.combinedStatusItem = profile.combinedStatusItem
    }

    /// A usable name: trimmed, non-empty, and not the reserved
    /// built-in's. Returns the trimmed name, or nil.
    nonisolated static func validName(_ name: String) -> String? {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty,
              trimmed.localizedCaseInsensitiveCompare(noneName) != .orderedSame
        else { return nil }
        return trimmed
    }

    /// Save the current settings under `name`: a same-named profile is
    /// overwritten in place (its id survives), otherwise a new one is
    /// appended. Returns the saved profile's id, or nil on an unusable
    /// name — the card's field disables its button on the same rule.
    @discardableResult
    nonisolated static func saveCurrent(as name: String,
                                        in settings: inout MenuBarSettings) -> String? {
        guard let name = validName(name) else { return nil }
        if let index = settings.profiles.firstIndex(where: {
            $0.name.localizedCaseInsensitiveCompare(name) == .orderedSame
        }) {
            let saved = capture(name: name, from: settings, id: settings.profiles[index].id)
            settings.profiles[index] = saved
            return saved.id
        }
        let saved = capture(name: name, from: settings)
        settings.profiles.append(saved)
        return saved.id
    }

    /// Rename, keeping the id and contents. A bad name is a no-op.
    nonisolated static func rename(id: String, to name: String,
                                   in settings: inout MenuBarSettings) {
        guard let name = validName(name),
              let index = settings.profiles.firstIndex(where: { $0.id == id }) else { return }
        settings.profiles[index].name = name
    }

    /// Delete by id. The built-in "None" is not in `profiles`, so it
    /// can never be deleted.
    nonisolated static func delete(id: String, in settings: inout MenuBarSettings) {
        settings.profiles.removeAll { $0.id == id }
    }
}
