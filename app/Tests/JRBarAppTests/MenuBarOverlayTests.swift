import Foundation
import Testing
@testable import JRBarApp
import JRBarCore

/// Hide all and Show all as an overlay over the curated map — the map
/// is the person's and only their picks change it.
@Suite("Menu Bar — the overlay over your curation")
struct MenuBarOverlayTests {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    // MARK: Transitions

    @Test("hide all sets the quiet bar; over show-everything it restores instead — never a toggle")
    func hideAllTransitions() {
        let hidden = MenuBarOverlay.afterHideAll(nil, now: now)
        #expect(hidden?.kind == .hideEverything)
        #expect(hidden?.sinceEpoch == now.timeIntervalSince1970)
        // Twice is still hidden — a rule that fires twice cannot undo itself.
        #expect(MenuBarOverlay.afterHideAll(hidden, now: now)?.kind == .hideEverything)
        let shown = MenuBarOverlay(kind: .showEverything, sinceEpoch: 0)
        #expect(MenuBarOverlay.afterHideAll(shown, now: now) == nil)
    }

    @Test("show all mirrors it: over the quiet bar it gives the curated bar back")
    func showAllTransitions() {
        #expect(MenuBarOverlay.afterShowAll(nil, now: now)?.kind == .showEverything)
        let quiet = MenuBarOverlay(kind: .hideEverything, sinceEpoch: 0)
        #expect(MenuBarOverlay.afterShowAll(quiet, now: now) == nil)
        // A lapsed quiet bar is no quiet bar: show all shows everything.
        let lapsed = MenuBarOverlay(kind: .hideEverything, sinceEpoch: 0,
                                    untilEpoch: now.timeIntervalSince1970 - 1)
        #expect(MenuBarOverlay.afterShowAll(lapsed, now: now)?.kind == .showEverything)
    }

    @Test("a timed overlay lapses at its clock")
    func timedOverlay() {
        let until = now.addingTimeInterval(300)
        let overlay = MenuBarOverlay.afterHideAll(nil, now: now, until: until)
        #expect(overlay?.untilEpoch == until.timeIntervalSince1970)
        #expect(overlay?.isLive(at: now) == true)
        #expect(overlay?.isLive(at: until) == false)
    }

    // MARK: Layers

    @Test("show everything hides nothing and covers nothing")
    func showEverythingLayer() {
        let maps = MenuBarLayers.overlaid(
            sections: ["WeatherMenu": .hidden],
            concealedApps: ["a.app": .hidden, "b.app": .alwaysHidden, "c.app": .shown],
            overlay: .showEverything, apps: ["d.app"], itemIDs: ["x"])
        #expect(maps.sections.isEmpty)
        #expect(maps.concealedApps == ["a.app": .shown, "b.app": .shown, "c.app": .shown])
    }

    @Test("the quiet bar tucks every known app away and keeps the always-hidden run deep")
    func hideEverythingLayer() {
        let maps = MenuBarLayers.overlaid(
            sections: ["Passwords": .alwaysHidden],
            concealedApps: ["a.app": .shown, "b.app": .alwaysHidden],
            overlay: .hideEverything, apps: ["a.app", "c.app"],
            itemIDs: ["Passwords", "Weather"])
        #expect(maps.concealedApps == ["a.app": .hidden, "b.app": .alwaysHidden, "c.app": .hidden])
        #expect(maps.sections == ["Passwords": .alwaysHidden, "Weather": .hidden])
    }

    @Test("no overlay is the curated map, untouched")
    func noOverlay() {
        var settings = MenuBarSettings()
        settings.concealedApps = ["a.app": .hidden]
        #expect(MenuBarLayers.live(settings, overlay: nil, apps: ["z"], itemIDs: ["y"]) == settings)
    }

    @Test("the card says what stands and when it ends")
    func overlayNote() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        #expect(MenuBarLayers.overlayNote(nil, now: now) == nil)
        let forever = MenuBarOverlay(kind: .showEverything, sinceEpoch: 0)
        #expect(MenuBarLayers.overlayNote(forever, now: now, calendar: calendar)
                == "Everything is showing — your picks are kept for when you restore.")
        let timed = MenuBarOverlay(kind: .hideEverything, sinceEpoch: 0,
                                   untilEpoch: now.addingTimeInterval(3600).timeIntervalSince1970)
        #expect(MenuBarLayers.overlayNote(timed, now: now, calendar: calendar)
                == "Everything is tucked away until 09:00 — your picks come back then.")
        let lapsed = MenuBarOverlay(kind: .hideEverything, sinceEpoch: 0,
                                    untilEpoch: now.timeIntervalSince1970 - 1)
        #expect(MenuBarLayers.overlayNote(lapsed, now: now) == nil)
    }

    // MARK: Through the utility

    @MainActor
    private func utility(_ settings: MenuBarSettings) -> (MenuBarUtility, () -> MenuBarSettings) {
        let utility = MenuBarUtility()
        var state = settings
        utility.settings = { state }
        utility.onSettingsChange = { state = $0 }
        utility.hider.listItems = { [] }
        utility.hider.onPlan = nil
        return (utility, { state })
    }

    @MainActor
    @Test("the classic lock → hide / unlock → show pair ends on the curated bar, not an empty one")
    func rulePairRestores() {
        var base = MenuBarSettings(enabled: false)
        base.concealedApps = ["slack": .hidden, "zoom": .shown]
        let (utility, state) = utility(base)
        utility.menuBarActionsHideAll(utility.actions)
        #expect(state().curation.overlay?.kind == .hideEverything)
        #expect(state().concealedApps == base.concealedApps, "the map is never rewritten")
        utility.menuBarActionsShowAll(utility.actions)
        #expect(state().curation.overlay == nil)
        #expect(utility.liveSettings().concealedApps == ["slack": .hidden, "zoom": .shown])
    }

    @MainActor
    @Test("keep makes the overlay the curation, on the explicit ask only")
    func keepWritesTheMap() {
        var base = MenuBarSettings(enabled: false)
        base.concealedApps = ["slack": .hidden, "zoom": .alwaysHidden]
        base.sections = ["Weather": .hidden]
        let (utility, state) = utility(base)
        utility.showAllListed()
        #expect(state().concealedApps == base.concealedApps)
        utility.keepOverlay()
        #expect(state().curation.overlay == nil)
        #expect(state().concealedApps == ["slack": .shown, "zoom": .shown])
        #expect(state().sections.isEmpty)
    }

    @MainActor
    @Test("a timed show-all expires at its clock and hands the curated bar back")
    func timedExpiry() {
        var base = MenuBarSettings(enabled: false)
        base.concealedApps = ["slack": .hidden]
        let (utility, state) = utility(base)
        utility.showAllListed(for: 60)
        #expect(state().curation.overlay?.kind == .showEverything)
        // Not yet due: nothing moves.
        utility.expireOverlayIfDue()
        #expect(state().curation.overlay?.kind == .showEverything)
        utility.expireOverlayIfDue(now: Date().addingTimeInterval(61))
        #expect(state().curation.overlay == nil)
        #expect(state().concealedApps == ["slack": .hidden])
        // An overlay without a clock never expires.
        utility.showAllListed()
        utility.expireOverlayIfDue(now: Date().addingTimeInterval(86_400))
        #expect(state().curation.overlay?.kind == .showEverything)
    }

    @Test("a file from before the overlay decodes with none standing")
    func legacyDecode() throws {
        let json = #"{"enabled":true,"concealedApps":{"a.app":"hidden"}}"#
        let settings = try JSONDecoder().decode(MenuBarSettings.self, from: Data(json.utf8))
        #expect(settings.curation.overlay == nil)
        #expect(settings.concealedApps == ["a.app": .hidden])
        var withOverlay = settings
        withOverlay.curation.overlay = MenuBarOverlay(kind: .hideEverything, sinceEpoch: 5,
                                                      untilEpoch: 10)
        let back = try JSONDecoder().decode(MenuBarSettings.self,
                                            from: JSONEncoder().encode(withOverlay))
        #expect(back == withOverlay)
    }
}
