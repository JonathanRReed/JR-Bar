import Foundation
import JRBarCore

/// Named presets for the Menu Bar utility, persisted inside
/// `MenuBarSettings.profiles`. A profile is a delta over the base map —
/// only the apps (and covered items) it says differently — plus the
/// cover's look, the reveal's style and clock, the spacing and the
/// spacer items. `curation.activeProfileID` names the one laid over the
/// base right now, so switching swaps a layer instead of replacing the
/// map: an app you hide after a profile was saved stays hidden in every
/// profile that does not say otherwise.
///
/// The logic is pure — profiles are values — so save, apply, rename,
/// delete and the one-time snapshot migration are testable without the
/// card. Applying one lands through the utility's normal settings
/// write, so the reconcile path restyles and re-covers exactly as a
/// hand edit would.
enum MenuBarProfiles {
    /// The built-in state the card lists first: the base map alone,
    /// default appearance. It is not a `Profile` — there is nothing to
    /// rename or delete.
    nonisolated static let noneID = "none"
    /// The name the built-in state shows.
    nonisolated static let noneName = "None"

    /// Snapshot what a profile keeps of the live settings: the cover
    /// appearance, the reveal's style and clock, the item spacing and
    /// the spacer items — and the active profile's deltas, so "save as"
    /// over a profile duplicates it. With no profile active the new one
    /// starts as "your bar, this look": its differences are picked in
    /// the card's profile editor, one app at a time.
    nonisolated static func capture(name: String, from settings: MenuBarSettings,
                                    id: String = UUID().uuidString) -> MenuBarSettings.Profile {
        let active = activeProfile(in: settings)
        return MenuBarSettings.Profile(
            id: id, name: name, sections: active?.sections ?? [:],
            concealedApps: active?.concealedApps ?? [:],
            coverMaterial: settings.coverMaterial, coverTint: settings.coverTint,
            coverTintOpacity: settings.coverTintOpacity,
            coverRoundness: settings.coverRoundness,
            showCoverSeparator: settings.showCoverSeparator,
            revealStyle: settings.revealStyle,
            rehideMode: settings.rehideMode,
            rehideSeconds: settings.rehideSeconds,
            itemSpacing: settings.itemSpacing,
            spacers: settings.spacers)
    }

    /// Switch to a profile: it becomes the active layer and its look,
    /// reveal, spacing and spacers replace the live ones. The maps are
    /// never written — the base stays yours. `nil` is the built-in
    /// "None": the base map alone, with the look a fresh install has
    /// (the Blend In cover, the timed default reveal, the system's own
    /// spacing, no spacers). The reveal gestures, `enabled`, the hotkeys
    /// and the rules are not the profile's business and survive either
    /// way.
    nonisolated static func apply(_ profile: MenuBarSettings.Profile?,
                                  to settings: inout MenuBarSettings) {
        guard let profile else {
            settings.curation.activeProfileID = nil
            settings.coverMaterial = .blend
            settings.coverTint = ""
            settings.coverTintOpacity = MenuBarSettings.defaultCoverTintOpacity
            settings.coverRoundness = 0
            settings.showCoverSeparator = false
            settings.revealStyle = .bar
            settings.rehideMode = .timed
            settings.rehideSeconds = MenuBarSettings.defaultRehideSeconds
            settings.itemSpacing = 0
            settings.spacers = []
            return
        }
        settings.curation.activeProfileID = profile.id
        settings.coverMaterial = profile.coverMaterial
        settings.coverTint = profile.coverTint
        settings.coverTintOpacity = profile.coverTintOpacity
        settings.coverRoundness = profile.coverRoundness
        settings.showCoverSeparator = profile.showCoverSeparator
        settings.revealStyle = profile.revealStyle
        settings.rehideMode = profile.rehideMode
        settings.rehideSeconds = profile.rehideSeconds
        settings.itemSpacing = profile.itemSpacing
        settings.spacers = profile.spacers
    }

    /// The active profile, when its id still resolves.
    nonisolated static func activeProfile(in settings: MenuBarSettings) -> MenuBarSettings.Profile? {
        guard let id = settings.curation.activeProfileID else { return nil }
        return settings.profiles.first { $0.id == id }
    }

    /// The curated maps: the base with the active profile's deltas laid
    /// over it — `profile` stands in for the active one when a rule
    /// holds another for now.
    nonisolated static func curatedMaps(
        _ settings: MenuBarSettings, profile: MenuBarSettings.Profile? = nil
    ) -> (sections: [String: MenuBarItemSection], concealedApps: [String: MenuBarItemSection]) {
        guard let layer = profile ?? activeProfile(in: settings) else {
            return (settings.sections, settings.concealedApps)
        }
        return (settings.sections.merging(layer.sections) { _, delta in delta },
                settings.concealedApps.merging(layer.concealedApps) { _, delta in delta })
    }

    /// `settings` with its maps curated — every other field untouched.
    nonisolated static func curated(_ settings: MenuBarSettings,
                                    profile: MenuBarSettings.Profile? = nil) -> MenuBarSettings {
        guard profile != nil || settings.curation.activeProfileID != nil else { return settings }
        var out = settings
        let maps = curatedMaps(settings, profile: profile)
        out.sections = maps.sections
        out.concealedApps = maps.concealedApps
        return out
    }

    /// What a snapshot says that the base does not: every key either
    /// side knows whose section differs (absent reads as shown). Laid
    /// over the base, the delta reproduces the snapshot exactly.
    nonisolated static func delta(of snapshot: [String: MenuBarItemSection],
                                  over base: [String: MenuBarItemSection]) -> [String: MenuBarItemSection] {
        var out: [String: MenuBarItemSection] = [:]
        for key in Set(snapshot.keys).union(base.keys) {
            let wanted = snapshot[key] ?? .shown
            if wanted != base[key] ?? .shown { out[key] = wanted }
        }
        return out
    }

    /// The one-time move from snapshots to deltas: each profile keeps
    /// exactly the layout it had against today's base, and nothing is
    /// active, so the bar does not move. Idempotent.
    nonisolated static func migrateToDeltas(_ settings: inout MenuBarSettings) {
        guard settings.curation.profileModel < MenuBarCuration.currentProfileModel else { return }
        for index in settings.profiles.indices {
            settings.profiles[index].concealedApps = delta(
                of: settings.profiles[index].concealedApps, over: settings.concealedApps)
            settings.profiles[index].sections = delta(
                of: settings.profiles[index].sections, over: settings.sections)
        }
        settings.curation.profileModel = MenuBarCuration.currentProfileModel
    }

    /// Where a pick for an app lands while a profile is active: the
    /// profile's delta when it already speaks for the app — a pick is
    /// never silently overridden — else the base, so it holds in every
    /// profile.
    nonisolated static func pickTargetsProfile(appID: String, in settings: MenuBarSettings) -> Bool {
        activeProfile(in: settings)?.concealedApps[appID] != nil
    }

    /// The same question for a covered item's positional entry.
    nonisolated static func pickTargetsProfile(itemID: String, in settings: MenuBarSettings) -> Bool {
        activeProfile(in: settings)?.sections[itemID] != nil
    }

    /// The profile editor's write: what `profileID` says about one app —
    /// nil drops the delta, so the app follows the base again.
    nonisolated static func setDelta(appID: String, to section: MenuBarItemSection?,
                                     profileID: String, in settings: inout MenuBarSettings) {
        guard let index = settings.profiles.firstIndex(where: { $0.id == profileID }) else { return }
        settings.profiles[index].concealedApps[appID] = section
    }

    /// The same for a covered item.
    nonisolated static func setDelta(itemID: String, to section: MenuBarItemSection?,
                                     profileID: String, in settings: inout MenuBarSettings) {
        guard let index = settings.profiles.firstIndex(where: { $0.id == profileID }) else { return }
        settings.profiles[index].sections[itemID] = section
    }

    /// The hotkeys' step through the list — None, then each profile in
    /// order, wrapping — from whichever one is active.
    nonisolated static func cycled(from activeID: String?, profiles: [MenuBarSettings.Profile],
                                   direction: Int) -> String {
        let ids = [noneID] + profiles.map(\.id)
        let current = activeID.flatMap { id in ids.firstIndex(of: id) } ?? 0
        let count = ids.count
        return ids[((current + direction) % count + count) % count]
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

    /// Save the current look under `name`: a same-named profile keeps
    /// its id and its own deltas and takes the look; otherwise a new
    /// one is appended. Returns the saved profile's id, or nil on an
    /// unusable name — the card's field disables its button on the
    /// same rule.
    @discardableResult
    nonisolated static func saveCurrent(as name: String,
                                        in settings: inout MenuBarSettings) -> String? {
        guard let name = validName(name) else { return nil }
        if let index = settings.profiles.firstIndex(where: {
            $0.name.localizedCaseInsensitiveCompare(name) == .orderedSame
        }) {
            let existing = settings.profiles[index]
            var saved = capture(name: name, from: settings, id: existing.id)
            saved.sections = existing.sections
            saved.concealedApps = existing.concealedApps
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
    /// can never be deleted; deleting the active one leaves the base.
    nonisolated static func delete(id: String, in settings: inout MenuBarSettings) {
        settings.profiles.removeAll { $0.id == id }
        if settings.curation.activeProfileID == id { settings.curation.activeProfileID = nil }
    }
}
