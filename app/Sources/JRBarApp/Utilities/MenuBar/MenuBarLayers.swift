import Foundation
import JRBarCore

/// The live map — what the engines converge to — built in layers over
/// the curated one. The persisted `sections` and `concealedApps` are the
/// person's choices and only ever change when the person changes them;
/// everything transient (Hide all, Show all) is a layer applied on read.
/// The engines — the concealer's target, the concealed plan, the hider,
/// the ear limits — read the layered copy; every write still lands on
/// the curated one. Pure so a test pins each layer.
enum MenuBarLayers {
    /// The maps with an overlay laid over them.
    ///
    /// `.showEverything` hides nothing: every app reads shown and no
    /// item is covered. `.hideEverything` tucks away every app in
    /// `apps` and covers every item in `itemIDs` — the universe the
    /// caller knows has something on the bar — keeping anything the map
    /// already puts in the deeper always-hidden run there, so the
    /// always-hidden gesture still means what it meant.
    nonisolated static func overlaid(
        sections: [String: MenuBarItemSection],
        concealedApps: [String: MenuBarItemSection],
        overlay: MenuBarOverlay.Kind?,
        apps: Set<String>,
        itemIDs: Set<String>
    ) -> (sections: [String: MenuBarItemSection], concealedApps: [String: MenuBarItemSection]) {
        switch overlay {
        case nil:
            return (sections, concealedApps)
        case .showEverything:
            return ([:], concealedApps.mapValues { _ in .shown })
        case .hideEverything:
            var appsOut = concealedApps
            for id in apps.union(concealedApps.keys) {
                appsOut[id] = concealedApps[id] == .alwaysHidden ? .alwaysHidden : .hidden
            }
            var sectionsOut = sections
            for id in itemIDs {
                sectionsOut[id] = sections[id] == .alwaysHidden ? .alwaysHidden : .hidden
            }
            return (sectionsOut, appsOut)
        }
    }

    /// `settings` with its maps layered — every other field untouched.
    nonisolated static func live(_ settings: MenuBarSettings,
                                 overlay: MenuBarOverlay.Kind?,
                                 apps: Set<String>,
                                 itemIDs: Set<String>) -> MenuBarSettings {
        guard overlay != nil else { return settings }
        var live = settings
        let maps = overlaid(sections: settings.sections, concealedApps: settings.concealedApps,
                            overlay: overlay, apps: apps, itemIDs: itemIDs)
        live.sections = maps.sections
        live.concealedApps = maps.concealedApps
        return live
    }

    /// The card's line for a standing overlay; nil when none stands.
    nonisolated static func overlayNote(_ overlay: MenuBarOverlay?, now: Date = Date(),
                                        calendar: Calendar = .current) -> String? {
        guard let overlay, overlay.isLive(at: now) else { return nil }
        let what = overlay.kind == .hideEverything
            ? "Everything is tucked away" : "Everything is showing"
        guard let until = overlay.untilEpoch else {
            return "\(what) — your picks are kept for when you restore."
        }
        let date = Date(timeIntervalSince1970: until)
        let parts = calendar.dateComponents([.hour, .minute], from: date)
        let clock = String(format: "%02d:%02d", parts.hour ?? 0, parts.minute ?? 0)
        return "\(what) until \(clock) — your picks come back then."
    }
}
