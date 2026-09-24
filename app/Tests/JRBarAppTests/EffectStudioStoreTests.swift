import AppKit
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

    @Test func theClockRunsOnlyWhileSomeOfTheOpenWindowShows() {
        let store = Self.makeStore()
        #expect(!store.clockRunning)
        store.windowDidOpen()
        #expect(store.clockRunning)
        store.covered = true
        #expect(!store.clockRunning, "a covered studio stops its clock")
        store.covered = false
        #expect(store.clockRunning)
        store.windowDidClose()
        #expect(!store.clockRunning)
        // Uncovered while closed: still nothing to tick for.
        store.covered = true
        store.covered = false
        #expect(!store.clockRunning)
    }

    @Test func anOffscreenWindowCountsAsCovered() {
        let store = Self.makeStore()
        let controller = EffectStudioWindowController(store: store)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 300),
                              styleMask: [.titled], backing: .buffered, defer: false)
        controller.noteOcclusion(of: window)
        #expect(store.covered, "a window that was never ordered in shows nothing")
    }
}

/// Knobs that re-render: a slider change asks the daemon for a new
/// program and the preview shows it, and a provider's draft previews in
/// that provider's own colour. The daemon is stood in for by a renderer
/// that draws the values it is given, so the store's plumbing is what is
/// under test (`tests/test_effect_parameters_live.py` holds the daemon to
/// the knobs themselves).
@MainActor
@Suite struct EffectStudioRenderTests {
    /// Waits, bounded, for the store's debounced render to land.
    static func settle(_ condition: @MainActor () -> Bool) async -> Bool {
        for _ in 0..<200 {
            if condition() { return true }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return condition()
    }

    static func comet() -> EffectDefinition {
        let head = EffectParameter(name: "head_width", type: .integer, defaultValue: .number(1), minimum: 1, maximum: 4)
        return EffectStudioLibraryTests.makeEffect("comet", parameters: [head],
                                                   program: "roll-right 1320ms linear\nrepeat", ledCount: 8)
    }

    @Test func aSliderChangeRerendersToADifferentProgram() async {
        let store = EffectStudioStoreTests.makeStore()
        var asked: [(String, [String: JSONValue], String?)] = []
        store.renderer = { id, values, leds, color in
            asked.append((id, values, color))
            let width = values["head_width"]?.doubleValue ?? 0
            return EffectPreview(program: "head \(Int(width)) on \(leds)\nrepeat", ledCount: leds)
        }
        let effect = Self.comet()
        let before = store.previewProgram(for: effect)
        let head = effect.parameters[0]
        store.setValue(.number(3), for: head, of: effect)
        let rendered = await Self.settle { store.previewProgram(for: effect) != before }
        #expect(rendered, "the preview never took the new render")
        #expect(store.previewProgram(for: effect) == "head 3 on 8\nrepeat")
        #expect(asked.last?.0 == "comet")
        #expect(asked.last?.1["head_width"] == .number(3))
        #expect(asked.last?.2 == nil, "the inspector previews in the working cyan")
        // Back to the default: the catalog's own program, no new request.
        let count = asked.count
        store.setValue(.number(1), for: head, of: effect)
        try? await Task.sleep(for: .milliseconds(250))
        #expect(store.previewProgram(for: effect) == before)
        #expect(asked.count == count)
    }

    @Test func aProviderDraftPreviewsInTheProvidersColour() async {
        let store = EffectStudioStoreTests.makeStore()
        var colors: [String?] = []
        store.renderer = { _, _, leds, color in
            colors.append(color)
            return EffectPreview(program: "\(color ?? "cyan") 1s pulse\nrepeat", ledCount: leds)
        }
        let effect = Self.comet()
        store.beginAssigning(effect, scope: .provider, target: "opencode")
        let purple = await Self.settle { store.draftPreviewProgram(for: effect).hasPrefix("#AF52DE") }
        #expect(purple, "OpenCode's draft should preview in its own purple, not the working cyan")
        #expect(store.draftColor == "#AF52DE")
        #expect(colors.contains("#AF52DE"))
        store.draftScope = .semantic
        #expect(store.draftColor == nil)
        store.windowDidClose()
    }
}
