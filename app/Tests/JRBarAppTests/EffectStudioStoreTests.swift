import CoreGraphics
import Foundation
import JRBarCore
import Testing
@testable import JRBarApp

/// The Effect Studio store's pure decisions: how the library groups,
/// filters and orders effects; the Reduce Motion substitution the
/// preview plays; and the math that keeps every LED of a wide device on
/// screen.
@MainActor
@Suite struct EffectStudioLibraryTests {
    static func makeEffect(_ id: String, label: String? = nil, meaning: String = "general",
                           pack: String? = nil, fallback: String? = nil,
                           parameters: [EffectParameter] = [],
                           program: String? = nil, ledCount: Int = 8) -> EffectDefinition {
        EffectDefinition(id: id, label: label ?? id, meaning: meaning, parameters: parameters,
                         reduceMotionFallback: fallback, pack: pack,
                         preview: program.map { EffectPreview(program: $0, ledCount: ledCount) })
    }

    // MARK: Grouping and order

    @Test func effectsSortAlphabeticallyWithinAGroup() {
        let catalog = EffectCatalog(effects: [
            Self.makeEffect("b", label: "Beta", meaning: "steady color"),
            Self.makeEffect("a", label: "Alpha", meaning: "steady color"),
        ])
        let groups = EffectStudioStore.libraryGroups(from: catalog, matching: "", filter: .all) { _ in false }
        #expect(groups.count == 1)
        #expect(groups[0].effects.map(\.id) == ["a", "b"])
    }

    @Test func groupsKeepFirstSeenOrderAndEmptyOnesDropOut() {
        let catalog = EffectCatalog(effects: [
            Self.makeEffect("x", meaning: "first group"),
            Self.makeEffect("y", meaning: "second group"),
            Self.makeEffect("z", meaning: "first group"),
        ])
        // "In use" with nothing used empties every group.
        let none = EffectStudioStore.libraryGroups(from: catalog, matching: "", filter: .inUse) { _ in false }
        #expect(none.isEmpty)
        // With only "z" used, its group survives alone, in first-seen order.
        let used = EffectStudioStore.libraryGroups(from: catalog, matching: "", filter: .inUse) { $0.id == "z" }
        #expect(used.map(\.title) == ["First group"])
        #expect(used[0].effects.map(\.id) == ["z"])
        // Unfiltered: both groups, in first-seen order.
        let all = EffectStudioStore.libraryGroups(from: catalog, matching: "", filter: .all) { _ in false }
        #expect(all.map(\.title) == ["First group", "Second group"])
    }

    @Test func packFilterKeepsOnlyPackInstalledEffects() {
        let catalog = EffectCatalog(effects: [
            Self.makeEffect("builtin", meaning: "steady color"),
            Self.makeEffect("pack:p1:extra", meaning: "steady color", pack: "p1"),
        ])
        let groups = EffectStudioStore.libraryGroups(from: catalog, matching: "", filter: .packs) { _ in false }
        #expect(groups.flatMap(\.effects).map(\.id) == ["pack:p1:extra"])
    }

    @Test func searchNarrowsBeforeGrouping() {
        let catalog = EffectCatalog(effects: [
            Self.makeEffect("rain", label: "Rain", meaning: "weather"),
            Self.makeEffect("shine", label: "Shine", meaning: "weather"),
        ])
        let groups = EffectStudioStore.libraryGroups(from: catalog, matching: "rain", filter: .all) { _ in false }
        #expect(groups.flatMap(\.effects).map(\.id) == ["rain"])
    }

    @Test func orderFallsBackToTheIDForTies() {
        let a = Self.makeEffect("x.b", label: "Same")
        let b = Self.makeEffect("x.a", label: "Same")
        #expect(EffectStudioStore.libraryOrder(b, a))
        #expect(!EffectStudioStore.libraryOrder(a, b))
    }

    // MARK: Reduce Motion substitution

    @Test func displayedEffectSubstitutesTheFallbackOnlyUnderReduceMotion() {
        let target = Self.makeEffect("calm", program: "#112233")
        let effect = Self.makeEffect("busy", fallback: "calm", program: "#FF0000 100ms none\nrepeat")
        let catalog = EffectCatalog(effects: [target, effect])
        #expect(EffectStudioStore.displayedEffect(for: effect, catalog: catalog, reduceMotion: true).id == "calm")
        #expect(EffectStudioStore.displayedEffect(for: effect, catalog: catalog, reduceMotion: false).id == "busy")
    }

    @Test func displayedEffectKeepsTheEffectWhenTheFallbackIsMissingOrItself() {
        let lone = Self.makeEffect("busy", fallback: "gone")
        let catalog = EffectCatalog(effects: [lone])
        #expect(EffectStudioStore.displayedEffect(for: lone, catalog: catalog, reduceMotion: true).id == "busy")
        let selfFallback = Self.makeEffect("loop", fallback: "loop")
        let catalog2 = EffectCatalog(effects: [selfFallback])
        #expect(EffectStudioStore.displayedEffect(for: selfFallback, catalog: catalog2, reduceMotion: true).id == "loop")
    }

    // MARK: Strip fit math

    @Test func dotMetricsKeepsTheAskedSizesWhenTheRowFits() {
        let metrics = LEDStripPreview.dotMetrics(ledCount: 8, width: 336, dotSize: 20, spacing: 14, padded: true)
        #expect(metrics.dotSize == 20)
        #expect(metrics.spacing == 14)
    }

    @Test func dotMetricsShrinksInProportionWhenTheRowOverflows() {
        let metrics = LEDStripPreview.dotMetrics(ledCount: 8, width: 100, dotSize: 20, spacing: 14, padded: true)
        #expect(metrics.dotSize < 20)
        // The fitted row (dots + gaps + the card's padding) lands on the width.
        let n = CGFloat(8)
        let width = n * metrics.dotSize + (n - 1) * metrics.spacing + 1.8 * metrics.dotSize
        #expect(abs(width - 100) < 0.01)
    }

    @Test func dotMetricsNeverDropsBelowAReadableFloor() {
        let metrics = LEDStripPreview.dotMetrics(ledCount: 200, width: 54, dotSize: 5, spacing: 2, padded: false)
        #expect(metrics.dotSize >= 2)
        #expect(metrics.spacing >= 1)
    }
}

/// The store against a dead socket: parameter edits, the selection the
/// sheet writes, and the preview fallbacks never touch the wire.
@MainActor
@Suite struct EffectStudioStoreTests {
    static func makeStore() -> EffectStudioStore {
        UserDefaults.standard.removeObject(forKey: "effectStudioSelection")
        return EffectStudioStore(core: CoreModel(socketPath: "/nonexistent.sock"))
    }

    @Test func editsNormaliseIntoValuesAndResetClearsThem() {
        let store = Self.makeStore()
        let parameter = EffectParameter(name: "speed", type: .number, defaultValue: .number(1), minimum: 0, maximum: 2)
        let effect = EffectStudioLibraryTests.makeEffect("e", parameters: [parameter])
        #expect(!store.hasEdits(effect))
        store.setValue(.number(1.5), for: parameter, of: effect)
        #expect(store.values(for: effect)["speed"] == .number(1.5))
        #expect(store.hasEdits(effect))
        // Out-of-range writes clamp through the parameter's own rules.
        store.setValue(.number(9), for: parameter, of: effect)
        #expect(store.values(for: effect)["speed"] == .number(2))
        store.resetParameters(effect)
        #expect(!store.hasEdits(effect))
        #expect(store.values(for: effect)["speed"] == .number(1))
    }

    @Test func beginAssigningSelectsTheEffectAndHydratesDefaults() {
        let store = Self.makeStore()
        let parameter = EffectParameter(name: "speed", type: .number, defaultValue: .number(1), minimum: 0, maximum: 2)
        let effect = EffectStudioLibraryTests.makeEffect("e", parameters: [parameter])
        store.beginAssigning(effect, scope: .semantic, target: "completion")
        #expect(store.selectedID == "e")
        #expect(store.assigning)
        #expect(store.draftScope == .semantic)
        #expect(store.draftTarget == "completion")
        // No stored assignment: the draft is the catalog defaults.
        #expect(store.draftParameters["speed"] == .number(1))
        store.windowDidClose()
        #expect(!store.assigning)
    }

    @Test func previewFallsBackToTheCatalogProgramWithoutARender() {
        let store = Self.makeStore()
        let effect = EffectStudioLibraryTests.makeEffect("e", program: "#FF0000", ledCount: 8)
        #expect(store.previewProgram(for: effect) == "#FF0000")
        // No hardware: the count is the effect's authored preview count.
        #expect(store.previewLedCount(for: effect) == 8)
        let bare = EffectStudioLibraryTests.makeEffect("bare")
        #expect(store.previewProgram(for: bare) == "off")
        #expect(store.previewLedCount(for: bare) == 8)
    }
}
