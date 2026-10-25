import AppKit
import Foundation
import SwiftUI
import Testing
import JRBarCore
@testable import JRBarApp

@Suite("Aquarium Live and Still")
@MainActor
struct AquariumMotionTests {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)
    private let size = CGSize(width: 900, height: 520)

    private func fish(_ id: String, state: FishState = .swimming) -> Fish {
        Fish(id: id, label: id, providerID: "claude", state: state,
             lane: 0.4, speed: 0.1, direction: 1,
             stateSince: now, enteredAt: now)
    }

    private func stillView(_ roster: [Fish]) -> AquariumView {
        var settings = AquariumSettings()
        settings.motion = .still
        return AquariumView(fixture: .init(fish: roster, night: 0, settings: settings))
    }

    @Test("departed status fish release their state even without a swimming body")
    func statusRosterReplacementClearsOldMotion() {
        let old = fish("departed", state: .surfacing)
        let replacement = fish("replacement", state: .sinking)
        let view = stillView([old])
        view.stepSwim([old], in: size, t: 100, now: now)
        #expect(view.motion.bodies.isEmpty)
        #expect(view.motion.anchors[old.id] != nil)
        view.motion.stages[old.id] = 2
        view.motion.smileUntil[old.id] = now.addingTimeInterval(20)
        view.motion.bounceUntil[old.id] = now.addingTimeInterval(20)
        view.motion.curiousID = old.id

        view.stepSwim([replacement], in: size, t: 100, now: now)
        #expect(view.motion.anchors[old.id] == nil)
        #expect(view.motion.stages[old.id] == nil)
        #expect(view.motion.smileUntil[old.id] == nil)
        #expect(view.motion.bounceUntil[old.id] == nil)
        #expect(view.motion.curiousID == nil)
        #expect(view.motion.anchors[replacement.id] != nil)
    }

    @Test func visualTimeFreezesAndResumesWithoutFreezingTheSessionClock() {
        let clock = AquariumMotionClock()
        #expect(clock.time(at: 100, still: false) == 100)
        #expect(clock.time(at: 110, still: true) == 100)
        #expect(clock.time(at: 900, still: true) == 100)
        #expect(clock.time(at: 901, still: false) == 901)
        #expect(clock.time(at: .nan, still: false) == 901)
        let leaver = fish("finished", state: .leaving)
        let later = now.addingTimeInterval(AquariumModel.leaveDuration + 1)
        #expect(AquariumInspection.visibleFish([leaver], at: later).isEmpty)
        #expect(clock.time(at: 1000, still: true) == 901)
    }

    @Test func swimmersAndDecorativePhaseHoldAcrossSemanticHeartbeats() throws {
        let swimmer = fish("working")
        let view = stillView([swimmer])
        let t = view.visualTime(at: now)
        view.stepSwim([swimmer], in: size, t: t, now: now)
        let before = try #require(view.motion.bodies[swimmer.id])
        let pose = view.layout(of: swimmer, in: size, at: t, now: now)
        let later = now.addingTimeInterval(600)
        #expect(view.visualTime(at: later) == t)
        view.stepSwim([swimmer], in: size, t: t, now: later)
        #expect(view.motion.bodies[swimmer.id] == before)
        let held = view.layout(of: swimmer, in: size, at: t, now: later)
        #expect(held.x == pose.x && held.y == pose.y)
        #expect(view.seaTurtlePose(size: size, t: t).pose
                == view.seaTurtlePose(size: size, t: view.visualTime(at: later)).pose)
    }

    @Test func freshAsksAndFailuresSettleWhileCompletionRetiresOnRealTime() {
        for state in [FishState.surfacing, .sinking, .leaving] {
            let selected = fish("status", state: state)
            let view = stillView([selected])
            let t = view.visualTime(at: now)
            view.stepSwim([selected], in: size, t: t, now: now)
            let first = view.layout(of: selected, in: size, at: t, now: now)
            let second = view.layout(of: selected, in: size, at: t,
                                      now: now.addingTimeInterval(3))
            #expect(first.x == second.x && first.y == second.y)
            if state == .surfacing { #expect(first.y < size.height * 0.2) }
            if state == .sinking { #expect(first.y > size.height * 0.7) }
        }
    }

    @Test func stillPinchesFeedImmediatelyAndKeepTheDailyCap() {
        let core = CoreModel()
        core.apply(.state(CoreState(sessions: [
            CoreSession(id: "adult", provider: "claude", mode: "idle_ready", lifecycle: "active"),
            CoreSession(id: "worker", provider: "claude", kind: "worker", parent: "adult",
                        mode: "tool_running", lifecycle: "active"),
            CoreSession(id: "failed", provider: "claude", lifecycle: "failed"),
        ])))
        var state = ToysState()
        state.aquarium.motion = .still
        state.aquarium.enabled = true
        let store = ToysStore(core: core, settings: SettingsStore(core: core), state: state,
                              cardModel: makeTestCardModel(), notchRuntimeEnabled: false)
        let file = AquariumToy.scratchSave()
        let toy = AquariumToy(core: core, store: store, saveFile: file)
        defer {
            toy.shutdown()
            toy.flushSave()
            try? FileManager.default.removeItem(at: file.url.deletingLastPathComponent())
        }
        let view = AquariumView(toy: toy)
        view.motion.size = size
        let point = CGPoint(x: size.width / 2, y: size.height / 2)
        view.feed(at: point)
        #expect(toy.game.pets["adult"]?.feedings == 3)
        #expect(toy.game.pets["worker"] == nil)
        #expect(toy.game.pets["failed"] == nil)
        #expect(view.motion.pellets.isEmpty)
        for _ in 0..<AquariumRules.feedingsPerFishPerDay { view.feed(at: point) }
        #expect(toy.game.pets["adult"]?.feedings == AquariumRules.feedingsPerFishPerDay)
        withExtendedLifetime(store) {}
    }

    @Test func switchingStillSettlesExistingDropsOntoTheSand() {
        let view = stillView([])
        let t = view.visualTime(at: now)
        let drop = PearlDrop(id: "drop", fishID: "fish", at: t, value: 1)
        view.motion.dropSpots[drop.id] = .init(x: 0.5, fromY: 0.4, seenAt: t)
        let placed = view.dropPoint(drop, size: size, t: t, layouts: [:])
        #expect(placed.fall == 1)
        #expect(placed.point == view.dropRest(drop, size: size, layouts: [:], t: t))
    }

    @Test func motionIsSearchable() {
        #expect(ToySearchCatalog.rows["aquarium"]?.contains { $0.title == "Motion" } == true)
    }
}
