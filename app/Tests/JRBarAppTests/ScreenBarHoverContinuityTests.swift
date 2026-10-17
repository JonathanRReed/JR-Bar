import AppKit
import JRBarCore
import Testing
@testable import JRBarApp

@Suite("Notch hover continuity")
@MainActor
struct ScreenBarHoverContinuityTests {
    @Test("a menu popup opens and closes without folding its grown notch parent")
    func menuWingDoesNotFoldGrownNotch() {
        let presenter = NotchCardPresenter(model: makeTestCardModel())
        presenter.presentationEnabled = false
        var point = CGPoint(x: 150, y: 120)
        var menuWing = false
        var edges: [Bool] = []
        var collapses = 0
        var menuShown = false
        var intents: [ScreenBarPeekIntent] = []
        let interaction = ScreenBarInteraction(card: presenter,
            hitRects: { [CGRect(x: 100, y: 100, width: 100, height: 40)] }, focus: { nil })
        interaction.pointerLocation = { point }
        interaction.islandOwnsNotch = { true }
        interaction.islandExpanded = { true }
        interaction.peekZoneAt = { _ in menuWing }
        interaction.rightWingOpensPeek = { true }
        interaction.peekState = { (shown: menuShown, pinned: menuShown) }
        interaction.peekCorridorAt = { menuShown && CGRect(x: 100, y: 40, width: 100, height: 48).contains($0) }
        interaction.onIslandHover = { active, _ in edges.append(active) }
        interaction.onIslandCollapse = { collapses += 1 }
        interaction.onPeek = { intent in
            intents.append(intent)
            if intent == .toggle { menuShown.toggle() }
            if intent == .close { menuShown = false }
        }
        defer { interaction.stop() }
        interaction.pointerMoved()
        menuWing = true
        interaction.geometryChanged()
        point.x += 1
        interaction.pointerMoved()
        #expect(edges == [true])
        #expect(interaction.hovering)
        #expect(!interaction.peekHoverArmed)
        #expect(collapses == 0)
        #expect(interaction.accessibilityActivateWing(.right))
        #expect(collapses == 0)
        #expect(intents == [.toggle])
        point = CGPoint(x: 150, y: 70)
        interaction.pointerMoved()
        #expect(edges == [true])
        #expect(interaction.hovering)
        point = CGPoint(x: 150, y: 120)
        interaction.pointerMoved()
        #expect(interaction.accessibilityActivateWing(.right))
        interaction.geometryChanged()
        #expect(!menuShown)
        #expect(collapses == 0)
        #expect(edges == [true])
        point = CGPoint(x: 300, y: 50)
        interaction.pointerMoved()
        #expect(edges == [true, false])
    }

    @Test("a wide popup does not take hover from the notch above it")
    func popupCorridorDoesNotCoverNotch() {
        let popup = CGRect(x: 100, y: 100, width: 440, height: 48)
        let ear = CGRect(x: 508, y: 158, width: 32, height: 32)
        var shown = false
        let point = CGPoint(x: 320, y: 174)
        var edges: [Bool] = []
        let presenter = NotchCardPresenter(model: makeTestCardModel())
        presenter.presentationEnabled = false
        let interaction = ScreenBarInteraction(card: presenter,
            hitRects: { [CGRect(x: 240, y: 158, width: 160, height: 32)] }, focus: { nil })
        interaction.pointerLocation = { point }
        interaction.islandOwnsNotch = { true }
        interaction.peekCorridorAt = { shown && ScreenBarPeekLayout.corridorContains($0, popup: popup, ear: ear) }
        interaction.onIslandHover = { active, _ in edges.append(active) }
        defer { interaction.stop() }
        interaction.pointerMoved()
        shown = true
        interaction.geometryChanged()
        interaction.pointerMoved()
        #expect(edges == [true])
        #expect(interaction.hovering)
        #expect(ScreenBarPeekLayout.corridorContains(CGPoint(x: 524, y: 153), popup: popup, ear: ear))
        #expect(ScreenBarPeekLayout.corridorContains(CGPoint(x: 320, y: 120), popup: popup, ear: ear))
        #expect(!ScreenBarPeekLayout.corridorContains(CGPoint(x: 320, y: 153), popup: popup, ear: ear))
    }

    @Test("ownership loss releases the toy before its continuity check reads the band")
    func ownershipLossReleasesToy() {
        var state = ToysState()
        state.notch = NotchSettings(enabled: true, provider: .jrbar, islandEnabled: true)
        let core = CoreModel()
        let store = ToysStore(core: core, settings: SettingsStore(core: core), state: state,
                              cardModel: makeTestCardModel(), notchRuntimeEnabled: false)
        let toy: NotchToy = store.notch
        let timers = ManualTimers()
        toy.hoverTimer = { delay, work in timers.arm(delay, work) }
        var owner = true
        let presenter = NotchCardPresenter(model: makeTestCardModel())
        presenter.presentationEnabled = false
        let interaction = ScreenBarInteraction(card: presenter,
            hitRects: { [NSRect(x: 100, y: 100, width: 100, height: 40)] }, focus: { nil })
        interaction.pointerLocation = { NSPoint(x: 150, y: 120) }
        interaction.islandOwnsNotch = { owner }
        toy.pointerOnBand = { interaction.hovering }
        interaction.onIslandHover = { active, fromBar in toy.bandHover(active, fromBar: fromBar) }
        defer { interaction.stop(); withExtendedLifetime(store) {} }
        interaction.pointerMoved()
        #expect(toy.hoverHeld)
        owner = false
        interaction.geometryChanged()
        #expect(!interaction.hovering)
        #expect(!toy.hoverHeld)
        timers.advance(by: 1)
        #expect(!toy.islandExpanded)
    }

    @Test("spring geometry does not re-enter an island under the same pointer")
    func geometryKeepsHover() {
        let presenter = NotchCardPresenter(model: makeTestCardModel())
        var frame = NSRect(x: 100, y: 100, width: 100, height: 40)
        var point = NSPoint(x: 150, y: 120)
        var edges: [Bool] = []
        let interaction = ScreenBarInteraction(card: presenter, hitRects: { [frame] }, focus: { nil })
        interaction.pointerLocation = { point }
        interaction.islandOwnsNotch = { true }
        interaction.onIslandHover = { active, _ in edges.append(active) }
        defer { interaction.stop() }
        interaction.pointerMoved()
        frame.size.width = 140
        interaction.geometryChanged()
        frame.size.width = 180
        interaction.geometryChanged()
        #expect(edges == [true])
        point.y = 210
        interaction.geometryChanged()
        interaction.geometryChanged()
        #expect(edges == [true, false])
        #expect(!presenter.isShown)
    }

    @Test("an assigned menu peek zone outranks island hover and keeps its open corridor")
    func rightWingContinuity() {
        #expect(ScreenBarInteraction.pointerRegion(onPeekZone: true, onPeek: false, inHitRegion: true) == .peek)
        #expect(ScreenBarInteraction.pointerRegion(onPeekZone: false, onPeek: true, inHitRegion: false) == .peek)
        #expect(ScreenBarInteraction.pointerRegion(onPeekZone: false, onPeek: false, inHitRegion: true) == .band)
    }

    @Test("new band geometry under a stationary pointer does not start hover; real motion does")
    func stationaryGeometryDoesNotEnter() {
        let presenter = NotchCardPresenter(model: makeTestCardModel())
        presenter.presentationEnabled = false
        var frame = NSRect(x: 300, y: 100, width: 100, height: 40)
        var point = NSPoint(x: 150, y: 120)
        var edges: [Bool] = []
        let interaction = ScreenBarInteraction(card: presenter, hitRects: { [frame] }, focus: { nil })
        interaction.pointerLocation = { point }
        interaction.islandOwnsNotch = { true }
        interaction.onIslandHover = { active, _ in edges.append(active) }
        defer { interaction.stop() }
        interaction.pointerMoved()
        frame.origin.x = 100
        interaction.geometryChanged()
        interaction.pointerMoved()
        #expect(edges.isEmpty)
        #expect(!interaction.hovering)
        point.x += 1
        interaction.pointerMoved()
        #expect(edges == [true])
        #expect(interaction.hovering)
        frame.origin.x = 300
        interaction.geometryChanged()
        interaction.geometryChanged()
        #expect(edges == [true, false])
        #expect(!interaction.hovering)
    }

    @Test("an assigned peek starts only on pointer motion, not a stationary menu geometry change")
    func stationaryPeekDoesNotEnter() {
        let presenter = NotchCardPresenter(model: makeTestCardModel())
        presenter.presentationEnabled = false
        var point = NSPoint(x: 150, y: 120)
        var assignedPeek = false
        var edges: [Bool] = []
        let interaction = ScreenBarInteraction(card: presenter, hitRects: { [] }, focus: { nil })
        interaction.pointerLocation = { point }
        interaction.islandOwnsNotch = { true }
        interaction.peekZoneAt = { _ in assignedPeek }
        interaction.onIslandHover = { active, _ in edges.append(active) }
        defer { interaction.stop() }
        interaction.pointerMoved()
        assignedPeek = true
        interaction.geometryChanged()
        interaction.pointerMoved()
        #expect(!interaction.peekHoverArmed)
        #expect(edges.isEmpty)
        point.x += 1
        interaction.pointerMoved()
        #expect(interaction.peekHoverArmed)
        #expect(edges.isEmpty)
        assignedPeek = false
        interaction.geometryChanged()
        #expect(!interaction.peekHoverArmed)
    }

    @Test("a geometry-only ownership change releases the island but does not enter its replacement")
    func changedOwnerWaitsForMotion() {
        let presenter = NotchCardPresenter(model: makeTestCardModel())
        presenter.presentationEnabled = false
        var owner = true
        var point = NSPoint(x: 150, y: 120)
        var edges: [Bool] = []
        let interaction = ScreenBarInteraction(card: presenter,
            hitRects: { [NSRect(x: 100, y: 100, width: 100, height: 40)] }, focus: { nil })
        interaction.pointerLocation = { point }
        interaction.islandOwnsNotch = { owner }
        interaction.onIslandHover = { active, _ in edges.append(active) }
        defer { interaction.stop() }
        interaction.pointerMoved()
        owner = false
        interaction.geometryChanged()
        #expect(edges == [true, false])
        #expect(!interaction.hovering)
        point.x += 1
        owner = true
        interaction.pointerMoved()
        #expect(edges == [true, false, true])
    }
}
