import AppKit
import Foundation
import Testing
import JRBarCore
@testable import JRBarApp

/// The card's content clock where the island uses it: the stage model the
/// window reports to, the switch that puts the old rule back, Reduce
/// Motion, and the window handing its tick length through. Every clock is
/// an argument; nothing here waits.
@Suite("Notch content clock on the stage")
@MainActor
struct NotchContentClockStageTests {
    private let idle = CGRect(x: 0, y: 0, width: 185, height: 32)
    private let card = CGRect(x: 0, y: 0, width: 320, height: 422)
    private var morph: NotchMorph {
        NotchMorph(rest: idle.height, open: card.height, restWidth: idle.width, openWidth: card.width)
    }

    /// The window's report for one move, played onto a stage model.
    private func drive(_ stage: NotchStageModel, opening: Bool, ticks: Int, dt: Double = 1.0 / 120,
                       _ body: (_ tick: Int) -> Void = { _ in }) {
        var spring = NotchFrameSpring(at: opening ? idle : card)
        let to = opening ? card : idle
        spring.retarget(to, motion: NotchMotion.frameMotion(from: spring.frame, to: to))
        stage.noteFace(expanded: opening, settled: false)
        for tick in 1...ticks {
            spring.integrate(dt: dt)
            stage.setOpenness(morph.openness(size: spring.frame.size), expanded: opening, dt: dt)
            body(tick)
        }
    }

    @Test("a grow's first frames already carry the content, which the old rule left dark")
    func contentArrivesWithTheShape() {
        let directional = NotchStageModel(directional: true)
        let legacy = NotchStageModel(directional: false)
        drive(directional, opening: true, ticks: 5)
        drive(legacy, opening: true, ticks: 5)
        // 5 ticks at 120 Hz = 42 ms: the shape is about 14% open.
        #expect(directional.openness < 0.2)
        #expect(directional.sheet.opacity > 0.3, "content resolving: \(directional.sheet.opacity)")
        #expect(directional.sheet.blur < NotchReveal.sheetBlur * 0.75)
        #expect(legacy.sheet.opacity < 0.02, "the old rule: nothing yet (\(legacy.sheet.opacity))")
        #expect(directional.row(step: 0) > legacy.row(step: 0))
    }

    @Test("a fold's content is out before the shape is half home")
    func foldLeavesFirst() {
        let stage = NotchStageModel(directional: true)
        stage.noteFace(expanded: true, settled: true)
        #expect(stage.sheet == .settled && stage.row(step: 3) == 1)
        var atHalf: CGFloat?
        drive(stage, opening: false, ticks: 40) { _ in
            if atHalf == nil, stage.openness <= 0.5 { atHalf = stage.sheet.opacity }
        }
        #expect((atHalf ?? 1) < 0.3, "at half open the content is at \(atHalf ?? -1)")
        #expect(stage.sheet.opacity < 0.001, "and the empty shape falls on its own")
    }

    @Test("the fold keeps visible detail in its first frames instead of a tall blank body")
    func foldDoesNotBlankImmediately() {
        let stage = NotchStageModel(directional: true)
        stage.noteFace(expanded: true, settled: true)
        drive(stage, opening: false, ticks: 5)
        #expect(stage.openness > 0.6)
        #expect(stage.sheet.opacity > 0.2)
    }

    @Test("settled is settled: the end of a move puts the content whole or gone, never between")
    func settlingSnaps() {
        let stage = NotchStageModel(directional: true)
        drive(stage, opening: true, ticks: 4)
        #expect(stage.sheet.opacity > 0 && stage.sheet.opacity < 1)
        stage.noteFace(expanded: true, settled: true)
        #expect(stage.sheet == .settled && stage.openness == 1)
        stage.noteFace(expanded: false, settled: true)
        #expect(stage.sheet.opacity == 0 && stage.openness == 0)
        #expect(stage.content?.settled == true)
    }

    @Test("a turn-around mid-grow takes the content back from where it was, with no step")
    func reversalHasNoPop() {
        let stage = NotchStageModel(directional: true)
        drive(stage, opening: true, ticks: 6)
        let before = stage.sheet
        stage.noteFace(expanded: false, settled: false)
        #expect(stage.sheet == before, "the aim changed; nothing was drawn differently")
        stage.setOpenness(stage.openness, expanded: false, dt: 1.0 / 120)
        #expect(abs(stage.sheet.opacity - before.opacity) < 0.15, "one frame later: \(stage.sheet.opacity)")
    }

    @Test("a notice's face runs on the same clock: in with the shape, out ahead of it")
    func noticeClock() {
        let stage = NotchStageModel(directional: true)
        stage.noticeMorph = NotchMorph(rest: 32, open: 56, restWidth: 185, openWidth: 290)
        // The lip barely down: the clock is running but the gate holds the line back.
        stage.shape = CGRect(x: 0, y: 0, width: 190, height: 34)
        for _ in 0..<5 { stage.tickNotice(dt: 1.0 / 120, shown: true) }
        #expect(stage.noticeSheet(shown: true).opacity == 0, "the lower edge would cut it")
        #expect(stage.noticeFit < 0.7, "the line is held inside the shape's width: \(stage.noticeFit)")
        // A little further down (a third of the way, 42 ms in), it is already coming in.
        stage.shape = CGRect(x: 0, y: 0, width: 232, height: 40)
        #expect(stage.noticeSheet(shown: true).opacity > 0.1, "\(stage.noticeSheet(shown: true).opacity)")
        #expect(stage.noticeSheet(shown: true).opacity < 0.5)
        for _ in 0..<40 { stage.tickNotice(dt: 1.0 / 120, shown: true) }
        stage.shape = CGRect(x: 0, y: 0, width: 290, height: 56)
        #expect(stage.noticeSheet(shown: true) == .settled)
        stage.shape = CGRect(x: 0, y: 0, width: 232, height: 40)
        // A fold: aimed at gone, it is out in a few frames.
        for _ in 0..<8 { stage.tickNotice(dt: 1.0 / 120, shown: false) }
        #expect(stage.noticeSheet(shown: true).opacity < 0.2)
        stage.settleNotice(shown: true)
        stage.shape = CGRect(x: 0, y: 0, width: 290, height: 56)
        #expect(stage.noticeSheet(shown: false) == .settled, "settled is whole, whatever the face says on stage")
        stage.shape = nil
        #expect(stage.noticeSheet(shown: false).opacity == 0, "at rest it is the face's own word")
        #expect(stage.noticeFit == 1)
    }

    @Test("jrbar.notchStagedMotion off puts the content back on the shape's travel")
    func revertSwitch() {
        let stage = NotchStageModel(directional: false)
        #expect(stage.content == nil)
        drive(stage, opening: true, ticks: 12)
        #expect(stage.sheet == NotchReveal.sheet(openness: stage.openness))
        #expect(stage.row(step: 2) == NotchReveal.row(step: 2, openness: stage.openness))
        stage.showContent(level: 1, expanded: true)
        #expect(stage.content == nil, "a still cannot turn the old rule into the new one")
        stage.noteFace(expanded: true, settled: true)
        #expect(stage.sheet == .settled)
    }

    @Test("a toy builds its stage from the switch")
    func toyFollowsTheSwitch() {
        let key = "jrbar.notchStagedMotion"
        let defaults = UserDefaults.standard
        let saved = defaults.object(forKey: key)
        defer { saved.map { defaults.set($0, forKey: key) } ?? defaults.removeObject(forKey: key) }
        defaults.removeObject(forKey: key)
        #expect(NotchStageModel(directional: NotchIslandWindow.stagedMotion).content != nil, "on by default")
        defaults.set(false, forKey: key)
        #expect(NotchStageModel(directional: NotchIslandWindow.stagedMotion).content == nil)
    }

    @Test("Reduce Motion: the card is simply there and simply gone, no clock in between")
    func reduceMotionHasNoClock() {
        var state = ToysState()
        state.notch = NotchSettings(enabled: true, provider: .jrbar, islandEnabled: true)
        let core = CoreModel()
        let store = ToysStore(core: core, settings: SettingsStore(core: core), state: state,
                              cardModel: makeTestCardModel(), notchRuntimeEnabled: false)
        defer { withExtendedLifetime(store) {} }
        let toy: NotchToy = store.notch
        toy.islandVisible = true
        toy.reduceMotion = { true }
        toy.expand(held: true)
        #expect(toy.stage.sheet == .settled, "no blur, no scale, no lift")
        #expect(toy.stage.content?.settled == true)
        toy.collapseIsland()
        #expect(toy.stage.sheet.opacity == 0 && toy.stage.content?.settled == true)
    }

    @Test("the window hands its tick length through, so the content clock keeps real time")
    func windowReportsTheTick() {
        var state = ToysState()
        state.notch = NotchSettings(enabled: true, provider: .jrbar, islandEnabled: true)
        let core = CoreModel()
        let store = ToysStore(core: core, settings: SettingsStore(core: core), state: state,
                              cardModel: makeTestCardModel(), notchRuntimeEnabled: false)
        defer { withExtendedLifetime(store) {} }
        let toy: NotchToy = store.notch
        toy.islandVisible = true
        let window = NotchIslandWindow(toy: toy)
        window.drivesSpringByHand = true
        window.surroundingsOverride = .init(bounds: CGRect(x: 0, y: 0, width: 10_000, height: 10_000), floor: nil)
        let rest = CGRect(x: 5663, y: 5950, width: 185, height: 32)
        window.setFrame(rest, display: false)
        window.orderFrontRegardless()
        defer { window.orderOut(nil) }
        var seen: [(CGFloat, TimeInterval)] = []
        window.onOpenness = { openness, dt in seen.append((openness, dt)) }
        window.applyFrame(CGRect(x: 5596, y: 5560, width: 320, height: 422), animated: true,
                          flip: NotchMorph(rest: 32, open: 422, restWidth: 185, openWidth: 320))
        window.advanceSpring(by: 1.0 / 120)
        window.advanceSpring(by: 1.0 / 60)
        #expect(seen.count == 2)
        #expect(seen.map(\.1) == [1.0 / 120, 1.0 / 60])
        #expect(seen[1].0 > seen[0].0)
    }
}
