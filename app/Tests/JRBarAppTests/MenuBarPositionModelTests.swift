import AppKit
import CoreGraphics
import Foundation
import Testing
@testable import JRBarApp
import JRBarCore

/// Position is the setting: the read-out, the words, the saved list's
/// migration, the positional record, and the guaranteed exits under the
/// divider. Every case runs on synthetic items, a fake host and clocks
/// cranked by hand.
@Suite("Menu Bar — position is the setting")
struct MenuBarPositionModelTests {
    private let row = CGRect(x: 0, y: 0, width: 1512, height: 33)

    private func item(_ id: String, app: String? = nil, x: Double, w: Double = 28,
                      owner: String? = nil, y: Double = 4) -> MenuBarItem {
        var item = MenuBarItem(id: id, ownerPID: 500, ownerName: owner ?? id,
                               bounds: CGRect(x: x, y: y, width: w, height: 24),
                               title: nil, windowID: 1)
        item.bundleID = app ?? "app.\(id.lowercased())"
        return item
    }

    // MARK: The read-out

    @Test("the diagram reads the plan: one tile per app, Apple's own items and ours left out")
    func contentFromPlan() {
        var plan = MenuBarHidePlan()
        plan.hidden = [item("Shottr", x: 900), item("Shottr2", app: "app.shottr", x: 930),
                       item("Parked", x: 975, y: 970)]
        plan.shown = [item("Weather", x: 1100), item("Control Center", x: 1300)]
        plan.alwaysHidden = [item("Defender", x: 880)]
        let content = MenuBarPositionContent.make(plan: plan, rows: [row])
        #expect(content.hidden.map(\.name) == ["Shottr", "Parked"], "Shottr's two items are one tile")
        #expect(content.shown.map(\.name) == ["Weather"], "Control Center is macOS's, not an app to arrange")
        #expect(content.always.map(\.name) == ["Defender"])
        #expect(content.parked == 1, "the item off every row is parked beyond what the bar draws")
        #expect(!content.isEmpty)
        #expect(MenuBarPositionContent().isEmpty)
    }

    // MARK: The words

    @Test("the model is said in one breath, and a drag pick gets the gesture that does it")
    func copy() {
        #expect(MenuBarPositionCopy.model.contains("Position is the setting"))
        #expect(MenuBarPositionCopy.model.contains("left of the JR-Bar icon is hidden"))
        #expect(MenuBarPositionCopy.model.contains("right of it stays"))
        #expect(MenuBarPositionCopy.guide(name: "Shottr", to: .hidden, parked: false)
                == "Hold ⌘ and drag Shottr left of the JR-Bar icon to hide it.")
        #expect(MenuBarPositionCopy.guide(name: "Shottr", to: .shown, parked: false)
                .contains("right of the JR-Bar icon to keep it shown"))
        #expect(MenuBarPositionCopy.guide(name: "Shottr", to: .shown, parked: true)
                .contains("Item Bar"))
        #expect(MenuBarPositionCopy.cannotMove.contains("can't move another app's icon"))
        #expect(MenuBarPositionCopy.remainder(count: 1).contains("1 hidden item doesn't fit"))
        #expect(MenuBarPositionCopy.remainder(count: 3).contains("3 hidden items don't fit"))
    }

    @Test("the engine sentence says the real icon is always drawn")
    func engineExplanation() {
        #expect(MenuBarPositionCopy.engineExplanation.contains("the real icon is always drawn"))
    }

    // MARK: The status lines

    private func status(_ edit: (inout MenuBarHidingStatus.Inputs) -> Void) -> MenuBarHidingStatus {
        var inputs = MenuBarHidingStatus.Inputs()
        inputs.engine = .divider
        inputs.recovery = .clear
        edit(&inputs)
        return MenuBarHidingStatus.assess(inputs)
    }

    @Test("under the divider the page says what is left of the icon, or how to put something there")
    func dividerStatus() {
        let empty = status { $0.dividerHidden = 0 }
        #expect(empty.headline == "No hidden items reported")
        #expect(empty.detail.contains("Hold ⌘ and drag an item left of the JR-Bar icon"))
        let some = status { $0.dividerHidden = 3 }
        #expect(some.tone == .ok)
        #expect(some.headline == "Hiding 3 items left of the icon")
        #expect(some.offersShowEverything)
        #expect(status { $0.dividerHidden = 1 }.headline == "Hiding 1 item left of the icon")
    }

    @Test("an icon at the left end of the bar says to drag the icon itself")
    func iconLeftmost() {
        let empty = status { $0.dividerHidden = 0; $0.iconLeftmost = true }
        #expect(empty.detail.contains("Hold ⌘ and drag the icon right"))
        #expect(!status { $0.dividerHidden = 0 }.detail.contains("drag the icon right"))
        let icon = CGRect(x: 975, y: 0, width: 39, height: 24)
        var plan = MenuBarHidePlan()
        plan.shown = [item("A", x: 1030), item("B", x: 1070)]
        #expect(MenuBarUtility.iconIsLeftmost(icon: icon, plan: plan, row: row))
        plan.hidden = [item("H", x: 930)]
        #expect(!MenuBarUtility.iconIsLeftmost(icon: icon, plan: plan, row: row), "an app stands left of it")
        plan.hidden = []
        plan.shown = []
        #expect(!MenuBarUtility.iconIsLeftmost(icon: icon, plan: plan, row: row), "nothing to drag it past")
    }

    @Test("a bar with no room for the divider says so and counts what to remove")
    func dividerNoRoom() {
        let crowded = status {
            $0.noRoom = true
            $0.dividerHidden = 2
            $0.noRoomHelp = "macOS is holding 5 items in its « overflow. Quit or switch off at least 1 menu bar item to give the JR-Bar icon a place."
        }
        #expect(crowded.tone == .warning)
        #expect(crowded.headline == "The bar is too full for the JR-Bar icon")
        #expect(crowded.detail.contains("macOS is holding 5 items in its « overflow"))
        #expect(crowded.detail.contains("at least 1 menu bar item"))
        #expect(crowded.detail.contains("Control Center"))
        #expect(crowded.fix == nil)
        #expect(crowded.offersShowEverything)
        // Without a count it still says what to do.
        #expect(status { $0.noRoom = true }.detail.contains("Quit or switch off a menu bar item"))
    }

    @Test("the engine line describes which items JR-Bar hides")
    func engineLine() {
        #expect(MenuBarEngineHealth.divider.line()
                == "Items left of JR-Bar are hidden")
    }

    // MARK: Migration

    @MainActor
    private func makeUtility(_ settings: MenuBarSettings) -> (MenuBarUtility, Box) {
        let utility = MenuBarUtility()
        let box = Box(settings)
        utility.settings = { box.settings }
        utility.onSettingsChange = { box.settings = $0 }
        utility.hider.listingIsComplete = { true }
        utility.hider.listItems = { [] }
        utility.hider.onPlan = nil
        utility.presentDropNote = { _ in }
        return (utility, box)
    }

    @MainActor
    final class Box {
        var settings: MenuBarSettings
        init(_ settings: MenuBarSettings) { self.settings = settings }
    }

    private func legacy(_ apps: [String: MenuBarItemSection] = [:],
                        reveal: MenuBarSettings.RevealStyle = .bar) -> MenuBarSettings {
        var settings = MenuBarSettings(enabled: true, revealStyle: reveal, concealedApps: apps)
        settings.curation.positionModel = 0
        return settings
    }

    @MainActor
    @Test("a file with a hidden list keeps every pick, keeps the list as suggestions, and the reveal draws on the bar")
    func migrateWithList() {
        let (utility, box) = makeUtility(legacy(["z.app": .alwaysHidden, "h.app": .hidden, "s.app": .shown]))
        utility.migratePositionModel()
        #expect(box.settings.curation.positionModel == MenuBarCuration.currentPositionModel)
        #expect(box.settings.concealedApps == ["z.app": .alwaysHidden, "h.app": .hidden, "s.app": .shown],
                "no pick is cleared")
        #expect(box.settings.curation.dividerSuggestions == ["h.app", "z.app"],
                "what the old list hid, and nothing it showed")
        #expect(!box.settings.curation.dividerHintDismissed)
        #expect(box.settings.revealStyle == .inline)
        // Once is enough.
        box.settings.revealStyle = .bar
        box.settings.curation.dividerSuggestions = ["h.app"]
        utility.migratePositionModel()
        #expect(box.settings.revealStyle == .bar)
        #expect(box.settings.curation.dividerSuggestions == ["h.app"])
    }

    @MainActor
    @Test("a pre-0.10 document preserves hidden picks before retiring its cover map", arguments: [false, true])
    func migratePre010Document(coverMap: Bool) throws {
        let source = #"{"enabled":false,"revealStyle":"bar","concealedApps":{"app.hidden":"hidden","app.always":"alwaysHidden","app.visible":"shown"}}"#
        var document = try #require(JSONSerialization.jsonObject(with: Data(source.utf8)) as? [String: Any])
        if coverMap { document["sections"] = ["Old item": "hidden"] }
        let decoded = try JSONDecoder().decode(MenuBarSettings.self,
            from: JSONSerialization.data(withJSONObject: document))
        let (utility, box) = makeUtility(decoded)
        utility.migrateSectionsIfNeeded()
        utility.migratePositionModel()
        #expect(box.settings.concealedApps == decoded.concealedApps)
        #expect(box.settings.sections.isEmpty)
        #expect(box.settings.curation.dividerSuggestions == ["app.always", "app.hidden"])
        let persisted = try JSONEncoder().encode(box.settings)
        let reloaded = try JSONDecoder().decode(MenuBarSettings.self, from: persisted)
        #expect(reloaded == box.settings)
        // A dismissed suggestion stays dismissed on the next apply.
        utility.forgetSuggestion("app.hidden")
        utility.migrateSectionsIfNeeded()
        utility.migratePositionModel()
        #expect(box.settings.curation.dividerSuggestions == ["app.always"])
        #expect(box.settings.concealedApps == decoded.concealedApps)
    }

    @Test("an unreported saved item has unknown visibility")
    func absentSuggestionIsUnverified() {
        let content = MenuBarSuggestionsContent.make(suggestions: ["app.missing"], plan: MenuBarHidePlan()) { _ in "Example" }
        #expect(content.rows.first?.state == .absent)
        #expect(content.lead == "1 saved pick needs a placement check.")
        #expect(MenuBarPositionCopy.suggestionLine(name: "Example", state: .absent)
            == "macOS hasn't reported Example's item. Its visibility is unverified.")
    }

    @MainActor
    @Test("retiring an old cover map does not restore suggestions the person already dismissed")
    func legacyMapKeepsDismissals() {
        var settings = MenuBarSettings(enabled: false, layoutModel: 0,
                                       concealedApps: ["app.old": .hidden])
        settings.curation.dividerHintDismissed = true
        let (utility, box) = makeUtility(settings)
        utility.migrateSectionsIfNeeded()
        utility.migratePositionModel()
        #expect(box.settings.curation.dividerSuggestions.isEmpty)
        #expect(box.settings.curation.dividerHintDismissed)
        #expect(box.settings.concealedApps == settings.concealedApps)
    }

    @MainActor
    @Test("an older document with only shown picks keeps its reveal style")
    func shownOnlyDocument() throws {
        let source = #"{"enabled":false,"revealStyle":"bar","concealedApps":{"app.visible":"shown"}}"#
        let decoded = try JSONDecoder().decode(MenuBarSettings.self, from: Data(source.utf8))
        let (utility, box) = makeUtility(decoded)
        utility.migrateSectionsIfNeeded()
        utility.migratePositionModel()
        #expect(box.settings.revealStyle == .bar)
        #expect(box.settings.concealedApps == decoded.concealedApps)
        #expect(box.settings.curation.dividerSuggestions.isEmpty)
    }

    @MainActor
    @Test("the step from the first position model keeps the person's reveal style and takes the list's apps as suggestions")
    func migrateFromModelOne() {
        var settings = legacy(["a.app": .hidden], reveal: .bar)
        settings.curation.positionModel = 1
        let (utility, box) = makeUtility(settings)
        utility.migratePositionModel()
        #expect(box.settings.revealStyle == .bar, "model 1 already chose; it is not chosen again")
        #expect(box.settings.curation.dividerSuggestions == ["a.app"])
        #expect(box.settings.curation.positionModel == 2)
    }

    @MainActor
    @Test("a file with nothing hidden has nothing to suggest")
    func migrateEmpty() {
        let (utility, box) = makeUtility(legacy())
        utility.migratePositionModel()
        #expect(box.settings.curation.dividerSuggestions.isEmpty)
    }

    @MainActor
    @Test("a saved list gates nothing: fourteen listed apps are only a record")
    func listDoesNotGate() {
        var apps: [String: MenuBarItemSection] = [:]
        for index in 0..<14 { apps["app.listed\(index)"] = .hidden }
        var settings = legacy(apps)
        settings.curation.positionModel = 1
        let (utility, _) = makeUtility(settings)
        #expect(utility.savedHiddenList().count == 14)
    }

    @MainActor
    @Test("a display change gives the divider's room a fresh look")
    func displayChange() {
        let (utility, _) = makeUtility(MenuBarSettings(enabled: true))
        for t in [0.0, 1, 2] { utility.dividerRoom.noteParkedLesson(now: t) }
        #expect(utility.dividerRoom.room == .noRoom)
        utility.displaysChanged()
        #expect(utility.dividerRoom.room == .unknown)
    }

    @MainActor
    @Test("the hint and a suggestion are the person's to close, and closing one hides nothing")
    func hintAndSuggestions() {
        var settings = legacy(["a.app": .hidden, "b.app": .hidden])
        settings.curation.positionModel = 2
        settings.curation.dividerSuggestions = ["a.app", "b.app"]
        let (utility, box) = makeUtility(settings)
        utility.forgetSuggestion("a.app")
        #expect(box.settings.curation.dividerSuggestions == ["b.app"])
        #expect(box.settings.concealedApps.count == 2)
        utility.dismissDividerHint()
        #expect(box.settings.curation.dividerHintDismissed)
    }

    @MainActor
    @Test("the Overrides rows still write a cover where the item sits; the icon's menu and tiles guide instead")
    func coverOverrideVersusGuide() {
        let utility = MenuBarUtility()
        let box = Box(MenuBarSettings(enabled: true))
        utility.settings = { box.settings }
        utility.onSettingsChange = { box.settings = $0 }
        var notes: [String] = []
        utility.presentDropNote = { notes.append($0) }
        utility.hider.listingIsComplete = { true }
        utility.hider.obscuredFrames = { [] }
        utility.hider.listItems = { [self.item("A", x: 100), self.item("B", x: 200)] }
        utility.hider.rowRect = { self.row }
        utility.hider.shuttersSuppressed = true
        utility.hider.reconcile()
        #expect(utility.lastPlan.shown.map(\.id) == ["A", "B"])
        #expect(utility.lastPlan.hidden.isEmpty)
        utility.setCoverOverride(.hidden, for: "A")
        #expect(box.settings.sections == ["A": .hidden], "the person asked for a cover in place")
        #expect(notes.isEmpty)
        utility.setSection(.hidden, for: "B")
        #expect(box.settings.sections == ["A": .hidden], "a plain hide pick never writes a cover under the divider")
        #expect(notes.count == 1)
        // Clearing an override is a pick the app can make: no note.
        utility.setSection(.shown, for: "A")
        #expect(box.settings.sections.isEmpty)
        #expect(notes.count == 1)
    }

    // MARK: The positional record

    @Test("the record follows the bar: apps left of the icon join, apps right of it leave, unseen apps stay")
    func positionalRecord() {
        var plan = MenuBarHidePlan()
        plan.hidden = [item("A", x: 900)]
        plan.alwaysHidden = [item("B", x: 880)]
        plan.shown = [item("C", x: 1100)]
        let current: [String: MenuBarItemSection] = ["app.c": .hidden, "away.app": .hidden]
        let next = MenuBarUtility.positionalRecord(current: current, raw: plan)
        #expect(next == ["app.a": .hidden, "app.b": .alwaysHidden, "away.app": .hidden],
                "C moved right and left the list; an app that is not on the bar keeps its entry")
    }

    @Test("an app split across the icon, and Apple's own, are not recorded")
    func recordLimits() {
        var plan = MenuBarHidePlan()
        plan.hidden = [item("A1", app: "app.a", x: 900), item("X", app: "com.apple.x", x: 920)]
        plan.shown = [item("A2", app: "app.a", x: 1100)]
        let next = MenuBarUtility.positionalRecord(current: [:], raw: plan)
        #expect(next.isEmpty)
    }

    @MainActor
    @Test("the record is written only after the same answer holds for three passes over three seconds")
    func recordIsDebounced() {
        var settings = legacy()
        settings.curation.positionModel = 1
        let (utility, box) = makeUtility(settings)
        var clock: TimeInterval = 1_000
        utility.engineClock = { clock }
        var plan = MenuBarHidePlan()
        plan.hidden = [item("A", x: 900)]
        plan.shown = [item("C", x: 1100)]
        utility.notePositions(in: plan)
        clock += 1
        utility.notePositions(in: plan)
        clock += 1
        utility.notePositions(in: plan)
        #expect(box.settings.concealedApps.isEmpty, "three passes but only two seconds")
        clock += 1.5
        utility.notePositions(in: plan)
        #expect(box.settings.concealedApps == ["app.a": .hidden])
        // A bar that changes between passes never writes.
        var other = plan
        other.hidden = []
        other.shown.append(item("A", x: 900))
        for _ in 0..<5 {
            clock += 2
            utility.notePositions(in: plan)
            clock += 2
            utility.notePositions(in: other)
        }
        #expect(box.settings.concealedApps == ["app.a": .hidden])
    }

    @MainActor
    @Test("nothing is recorded while a reveal, an overlay or a drag moves things")
    func recordStandsDown() {
        var settings = legacy()
        settings.curation.positionModel = 1
        let (utility, box) = makeUtility(settings)
        var clock: TimeInterval = 1_000
        utility.engineClock = { clock }
        var plan = MenuBarHidePlan()
        plan.hidden = [item("A", x: 900)]
        box.settings.curation.overlay = MenuBarOverlay(kind: .showEverything)
        for _ in 0..<6 { clock += 2; utility.notePositions(in: plan) }
        #expect(box.settings.concealedApps.isEmpty, "a standing Show everything draws everything")
        box.settings.curation.overlay = nil
        // A ⌘-drag in progress, and the beat after it, record nothing.
        utility.pointerGate.press(now: clock)
        for _ in 0..<6 { clock += 0.05; utility.notePositions(in: plan) }
        #expect(box.settings.concealedApps.isEmpty, "the bar is mid-move")
    }

    // MARK: The way out

    @MainActor
    private final class Host: MenuBarBoundaryHost {
        var frame: CGRect? = CGRect(x: 1084, y: 0, width: 39, height: 24)
        var boundaryFrame: CGRect? { frame }
        var boundaryGlyphLength: CGFloat = 39
        var spacers: [CGFloat] = []
        func setBoundarySpacer(_ length: CGFloat) { spacers.append(length) }
        var onBoundaryClick: (@MainActor () -> Void)?
        var hiddenItemsMenu: (@MainActor () -> NSMenu?)?
        var hiddenCount = 0
        var hiddenRevealed = false
        var barAppearance: NSAppearance? { nil }
    }

    @MainActor
    private func dividerRig(overlay: MenuBarOverlay.Kind? = nil) -> (MenuBarUtility, Host, Box) {
        var settings = MenuBarSettings(enabled: true)
        settings.curation.overlay = overlay.map { MenuBarOverlay(kind: $0) }
        let (utility, box) = makeUtility(settings)
        let host = Host()
        utility.host = host
        utility.hider.rowRect = { self.row }
        utility.hider.guessedFitEdge = { 902 }
        utility.hider.edgeStore = MenuBarMemoryFitEdgeStore()
        utility.hider.edgeKey = { "test" }
        utility.hider.shuttersSuppressed = true
        utility.hider.spacerCeiling = { .infinity }
        utility.hider.listingIsComplete = { true }
        utility.hider.listItems = { [self.item("Left", x: 1000), self.item("Right", x: 1130)] }
        var t = Date()
        utility.hider.now = { t += MenuBarItemHider.writeCooldown * 2; return t }
        return (utility, host, box)
    }

    @MainActor
    @Test("the divider hides what is left of the icon; a standing Show everything folds it away at once")
    func showEverythingCollapsesTheDivider() {
        let (hiding, hostA, _) = dividerRig()
        hiding.hider.reconcile()
        hiding.hider.reconcile()
        #expect(hostA.spacers.last == 182, "1123 − 902 = 221, less the 39-point icon")
        #expect(hiding.hider.lastPlan.hidden.map(\.id) == ["Left"])
        let (showing, hostB, _) = dividerRig(overlay: .showEverything)
        showing.hider.reconcile()
        #expect(hostB.spacers.last == 0, "Show everything folds the native spacer on the first pass")
    }

    @MainActor
    @Test("Show everything arriving over a standing divider collapses it on the very next pass")
    func showEverythingArrives() {
        let (utility, host, box) = dividerRig()
        utility.hider.reconcile()
        utility.hider.reconcile()
        #expect(host.spacers.last == 182)
        box.settings.curation.overlay = MenuBarOverlay(kind: .showEverything)
        utility.hider.reconcile()
        #expect(host.spacers.last == 0)
        box.settings.curation.overlay = nil
        utility.hider.reconcile()
        utility.hider.reconcile()
        #expect(host.spacers.last == 182, "restoring puts the divider back")
    }

    @Test("a spacer never reaches the width where the system drops the item")
    func spacerCeiling() {
        #expect(MenuBarItemHider.spacerCeiling(screenWidth: 1512) == 732)
        #expect(MenuBarItemHider.spacerCeiling(screenWidth: 1728) == 840)
        #expect(MenuBarItemHider.spacerCeiling(screenWidth: 20) == MenuBarControlFrames.glyphLength)
    }

    @MainActor
    @Test("the cap holds the spacer under the ceiling")
    func ceilingCapsTheLength() {
        let (utility, host, _) = dividerRig()
        utility.hider.spacerCeiling = { 100 }
        utility.hider.reconcile()
        utility.hider.reconcile()
        #expect(host.spacers.last == 61, "the item may not pass 100 points: icon 39 plus 61 of spacer")
    }

    // MARK: A reveal that cannot draw everything

    @Test("hidden items off every row are the remainder; the overflow control and Apple's items are not")
    func remainder() {
        var plan = MenuBarHidePlan()
        var control = item("«", x: 970)
        control.isNativeOverflowControl = true
        plan.hidden = [item("OnRow", x: 900), item("Parked", x: 950, y: 970), control,
                       item("Control Center", x: 960, y: 970)]
        plan.alwaysHidden = [item("AlsoParked", x: 940, y: 990)]
        let left = MenuBarUtility.parkedRemainder(plan: plan, rows: [row])
        #expect(left.map(\.id) == ["Parked", "AlsoParked"])
        #expect(MenuBarUtility.parkedRemainder(plan: MenuBarHidePlan(), rows: [row]).isEmpty)
    }

    @Test("a fresh listing replaces the stale frames, so a reveal that did draw an item does not count it parked")
    func refreshedFrames() {
        var plan = MenuBarHidePlan()
        plan.hidden = [item("Drawn", x: 900, y: 970), item("Parked", x: 950, y: 970)]
        plan.shown = [item("Shown", x: 1100)]
        // After the reveal the first one is on the row; the second is still stacked under the «.
        let fresh = [item("Drawn", x: 905), item("Parked", x: 950, y: 970), item("Other", x: 1)]
        let now = MenuBarUtility.refreshed(plan, with: fresh)
        #expect(now.hidden.map(\.bounds.minY) == [4, 970])
        #expect(MenuBarUtility.parkedRemainder(plan: plan, rows: [row]).map(\.id) == ["Drawn", "Parked"])
        #expect(MenuBarUtility.parkedRemainder(plan: now, rows: [row]).map(\.id) == ["Parked"])
        #expect(now.shown == plan.shown)
        // An item the listing does not name keeps what it had.
        #expect(MenuBarUtility.refreshed(plan, with: []).hidden == plan.hidden)
    }
}
