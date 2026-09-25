import CoreGraphics
import Foundation
import SwiftUI
import Testing
import JRBarCore
@testable import JRBarApp

/// The buddy never changes its mind in one frame: a heading change on a
/// walk eases over `BuddyTurn.duration` (the lean passing through upright,
/// the eyes crossing ahead of the body), stepping onto an edge and back
/// off it blends the patrol into the walk, a mood change hands its pose
/// over, and the carried dangle swings instead of flipping. Frames are
/// read off the figure's own pose, the numbers it draws.
@Suite("Buddy turn")
@MainActor
struct BuddyTurnTests {
    private static let frame: TimeInterval = 1.0 / 60.0

    /// The figure as the free panel draws it mid-walk; `stride` pins the
    /// patrol's clock so only what is under test moves.
    private func figure(mood: NotchBuddyToy.Mood = .pacing, stride: TimeInterval = 0,
                        hopProgress: Double? = nil, turn: BuddyTurn.Frame? = nil,
                        handoff: BuddyHandoff? = nil, still: Bool = false,
                        care: BuddyCare.Mood = .content) -> BuddyFigure {
        BuddyFigure(character: .dot, mood: mood, tint: .accentColor, phase: 2.35,
                    hopProgress: hopProgress, waveAge: nil, slumpAge: nil, leans: false,
                    still: still, askCount: 0, care: care, trick: nil,
                    treatAge: nil, crumbAge: nil, stride: stride, turn: turn, handoff: handoff)
    }

    @Test("a reversal moves the lean at most 2° and the eyes at most 0.2 a frame")
    func reversalIsGentle() {
        var last: BuddyFigure.Pose?
        var steps = 0
        var t = -Self.frame
        while t <= BuddyTurn.duration + 0.1 {
            let turn = t < 0 ? BuddyTurn.eased(from: 1, to: 1, elapsed: 1)
                : BuddyTurn.eased(from: 1, to: -1, elapsed: t)
            let pose = figure(turn: turn).pose
            if let last {
                #expect(abs(pose.lean - last.lean) <= 2, "lean jumped at \(t)s")
                #expect(abs(pose.look.width - last.look.width) <= 0.2, "eyes jumped at \(t)s")
                #expect(abs(pose.offset.width - last.offset.width) <= 0.5)
            }
            last = pose
            steps += 1
            t += Self.frame
        }
        #expect(steps > 20)
    }

    @Test("the old one-frame flip would have failed the same bound")
    func regressionPin() {
        // Before: `lean = heading * 5`, `look.width = heading * 0.9`, in
        // one frame at the leg change.
        let before = BuddyTurn.eased(from: 1, to: 1, elapsed: 1)
        let snapped = BuddyTurn.eased(from: -1, to: -1, elapsed: 1)
        #expect(abs(snapped.lean - before.lean) > 2)
        #expect(abs(snapped.lookWidth - before.lookWidth) > 0.2)
    }

    @Test("the turn lands on the new heading within 0.4 s")
    func landsInTime() {
        let done = BuddyTurn.eased(from: 1, to: -1, elapsed: 0.4)
        #expect(done.settled)
        #expect(done.facing == -1 && done.look == -1)
        #expect(done.squash == CGSize(width: 1, height: 1))
        let pose = figure(turn: done).pose
        #expect(pose.lean == -BuddyTurn.leanDegrees)
        #expect(abs(pose.look.width + BuddyTurn.lookReach) < 1e-9)
    }

    @Test("the lean passes through upright, the body narrows at the midpoint, the eyes lead")
    func midpoint() {
        let mid = BuddyTurn.eased(from: 1, to: -1, elapsed: BuddyTurn.duration / 2)
        #expect(abs(mid.facing) < 1e-9, "upright halfway")
        #expect(abs(mid.squash.width - (1 - BuddyTurn.narrowing)) < 1e-9)
        #expect(mid.squash.height > 1)
        #expect(mid.look < mid.facing, "the eyes are already past the middle")
        let early = BuddyTurn.eased(from: 1, to: -1, elapsed: 0.1)
        #expect(early.look < early.facing)
    }

    @Test("Reduce Motion takes the new heading in one step")
    func reduceMotion() {
        let snapped = BuddyTurn.eased(from: 1, to: -1, elapsed: 0, still: true)
        #expect(snapped.settled && snapped.facing == -1 && snapped.look == -1)
        var turn = BuddyTurn()
        let t0 = Date(timeIntervalSince1970: 1_000)
        turn.retarget(1, at: t0, still: true)
        #expect(turn.frame(at: t0, still: true).weight == 1)
        turn.retarget(-1, at: t0, still: true)
        #expect(turn.frame(at: t0, still: true).facing == -1)
    }

    @Test("a second turn mid-turn carries on from where the pose is drawn")
    func retargetIsContinuous() {
        let t0 = Date(timeIntervalSince1970: 1_000)
        var turn = BuddyTurn()
        turn.retarget(1, at: t0)
        let walking = t0.addingTimeInterval(1)
        #expect(turn.frame(at: walking).weight == 1)
        turn.retarget(-1, at: walking)
        let mid = walking.addingTimeInterval(0.12)
        let before = turn.frame(at: mid)
        turn.retarget(1, at: mid)
        let after = turn.frame(at: mid)
        #expect(abs(after.facing - before.facing) < 1e-9)
        #expect(abs(after.look - before.look) < 1e-9)
        #expect(turn.retarget(1, at: mid) == false, "the same target keeps the turn in flight")
        #expect(turn.frame(at: mid.addingTimeInterval(0.4)).facing == 1)
    }

    @Test("onto the edge and back off it: the patrol blends into the walk, never snaps")
    func patrolBlends() {
        let t0 = Date(timeIntervalSince1970: 1_000)
        var turn = BuddyTurn()
        // The pacing patrol at its right-hand end: 3 pt off centre, the
        // widest a snap to the walk could jump.
        let stride0 = 0.45 * 3.4
        var last: BuddyFigure.Pose?
        var t = 0.0
        var worstLean = 0.0
        var worstX = 0.0
        while t < 2.0 {
            let now = t0.addingTimeInterval(t)
            if t >= 0.3, t < 1.2 { turn.retarget(-1, at: now) }   // onto the edge, walking left
            if t >= 1.2 { turn.retarget(nil, at: now) }          // hop home: back to the patrol
            let drawn = turn.isResting(at: now) ? nil : turn.frame(at: now)
            let pose = figure(stride: stride0 + t * 0.2, turn: drawn).pose
            if let last {
                worstLean = max(worstLean, abs(pose.lean - last.lean))
                worstX = max(worstX, abs(pose.offset.width - last.offset.width))
            }
            last = pose
            t += Self.frame
        }
        #expect(worstLean <= 2)
        #expect(worstX <= 0.5, "the patrol's 3 pt swing hands over in steps, not at once")
        #expect(turn.isResting(at: t0.addingTimeInterval(2)))
    }

    @Test("the patrol's own turn at each end swings the lean through upright, never a flip")
    func patrolEndsAreGentle() {
        // No walk at all: the mood's own pacing, stepped at the sprint's
        // cadence (the fastest the stride runs) through both ends, c = 0.5
        // and the wrap at c = 1. The pause used to end 3° short of the
        // next leg's lean and make up the rest in one frame.
        let cycle = 3.4
        let step = Self.frame * BuddyTempo.sprintCadence
        for end in [0.5, 1.0] {
            var last: BuddyFigure.Pose?
            var stride = (end - 0.15) * cycle
            while stride <= (end + 0.1) * cycle {
                let pose = figure(stride: stride).pose
                if let last {
                    #expect(abs(pose.lean - last.lean) <= 2, "lean jumped at stride \(stride)")
                    #expect(abs(pose.offset.width - last.offset.width) <= 0.5)
                }
                last = pose
                stride += step
            }
        }
    }

    @Test("a completion hop starts and ends where the patrol had the body")
    func moodHandoff() {
        // Pacing at its right-hand end (3 pt off centre); the hop's own
        // pose is centred. Before the handoff that was a 3 pt jump at
        // both ends.
        let pace = 0.45 * 3.4
        let pacing = figure(stride: pace).pose
        let hopStart = figure(mood: .celebrating, stride: pace, hopProgress: 0,
                              handoff: BuddyHandoff(from: .pacing, age: 0)).pose
        #expect(abs(hopStart.offset.width - pacing.offset.width) < 1e-9)
        let bare = figure(mood: .celebrating, stride: pace, hopProgress: 0).pose
        #expect(abs(bare.offset.width - pacing.offset.width) >= 2.9, "the old cut jumped")

        var last: BuddyFigure.Pose?
        var age = 0.0
        while age <= BuddyHandoff.duration + Self.frame {
            let pose = figure(stride: pace, handoff: BuddyHandoff(from: .celebrating, age: age)).pose
            if let last { #expect(abs(pose.offset.width - last.offset.width) <= 0.5) }
            last = pose
            age += Self.frame
        }
        #expect(BuddyHandoff(from: .pacing, age: BuddyHandoff.duration).isOver)
    }

    @Test("the parts a body shapes by mood swing over the handoff, never in one frame")
    func bodyPartsEaseThroughHandoff() {
        // The crab's claws ride up for an ask, the axolotl's fronds drop
        // for sleep, the mushroom keels into a slump. Each part is every
        // mood's own value by its share, so it starts from exactly the
        // old value and its tip moves under 2/3 pt a frame at 1×, under
        // 2 pt at the floating buddy's 3×. Before, the crab's claws
        // jumped 3.3 pt in one frame at 1× on every ask.
        let clawReach = 2.4 + 4.4 * 26 * .pi / 180     // offset + finger swing, pt per unit lift
        let frondReach = 4.4 * .pi / 180                // pt per degree
        let capReach = 7.0 * 7.0 * .pi / 180            // pt per unit of the slump's 7° keel
        let changes: [(from: NotchBuddyToy.Mood, to: NotchBuddyToy.Mood)] = [
            (.pacing, .waving), (.waving, .asleep), (.pacing, .slumped), (.celebrating, .pacing),
            (.slumped, .asleep),
        ]
        for change in changes {
            let start = BuddyMoodShares(change.to, handoff: BuddyHandoff(from: change.from, age: 0))
            #expect(start.mix(CrabBody.clawLift) == CrabBody.clawLift(change.from), "no jump at the change")
            #expect(start.mix(AxolotlBody.frillSwing) == AxolotlBody.frillSwing(change.from))
            var last = start
            var age = Self.frame
            while age <= BuddyHandoff.duration + Self.frame {
                let now = BuddyMoodShares(change.to, handoff: BuddyHandoff(from: change.from, age: age))
                let lift = abs(now.mix(CrabBody.clawLift) - last.mix(CrabBody.clawLift))
                let gape = abs(now.mix { CrabBody.gape($0, phase: 0, still: true) }
                               - last.mix { CrabBody.gape($0, phase: 0, still: true) })
                let swing = abs(now.mix(AxolotlBody.frillSwing) - last.mix(AxolotlBody.frillSwing))
                let keel = abs(now.share(of: .slumped) - last.share(of: .slumped))
                #expect(lift * clawReach <= 2.0 / 3, "claws jumped \(change.from) → \(change.to) at \(age)")
                #expect(gape * 24 <= 2, "pincers snapped at \(age)")
                #expect(swing * frondReach <= 2.0 / 3, "fronds jumped at \(age)")
                #expect(keel * capReach <= 2.0 / 3, "the cap tipped at \(age)")
                last = now
                age += Self.frame
            }
            #expect(last == BuddyMoodShares(change.to), "lands on the new mood whole")
            #expect(last.mix(UFOBody.beam) == UFOBody.beam(change.to))
        }
        let snapped = abs(CrabBody.clawLift(.waving) - CrabBody.clawLift(.pacing)) * clawReach
        #expect(snapped > 3, "the old cut moved the claws this far in one frame")
    }

    @Test("a feeling eases in and out with the moods that wear it")
    func careFollowsTheHandoff() {
        // Missing you rides on the patrol and sleep but not on an ask. At
        // the change to an ask the droop is still all there, and it lets
        // go over the handoff instead of in one frame.
        let pacing = figure(care: .missing).pose
        let start = figure(mood: .waving, handoff: BuddyHandoff(from: .pacing, age: 0), care: .missing).pose
        #expect(abs(start.offset.height - pacing.offset.height) < 1e-9)
        #expect(abs(start.lid - pacing.lid) < 1e-9)
        #expect(abs(start.squash.height - pacing.squash.height) < 1e-9)
        let asked = figure(mood: .waving, care: .missing).pose
        #expect(asked.lid == 0, "an ask outranks the feeling once it has handed over")
        // Reduce Motion takes the new mood whole, feelings and all.
        #expect(figure(mood: .waving, handoff: BuddyHandoff(from: .pacing, age: 0), still: true).moods
                == BuddyMoodShares(.waving))
    }

    @Test("the carried dangle swings through upright instead of flipping")
    func dangleFollows() throws {
        let core = CoreModel()
        let store = ToysStore(core: core, settings: SettingsStore(core: core),
                              state: ToysState(), cardModel: makeTestCardModel(),
                              notchRuntimeEnabled: false)
        let toy = store.notchBuddy
        let t0 = Date(timeIntervalSince1970: 1_000)
        toy.dragStarted()
        var now = t0
        for _ in 0..<30 {
            now = now.addingTimeInterval(Self.frame)
            toy.dragMoved(dx: 40, at: now)
        }
        #expect(abs(toy.dragTilt - 14) < 0.5, "a steady carry leans all the way")
        let before = toy.dragTilt
        now = now.addingTimeInterval(Self.frame)
        toy.dragMoved(dx: -40, at: now)
        #expect(abs(toy.dragTilt - before) < 8, "one event no longer flips 28°")
        for _ in 0..<30 {
            now = now.addingTimeInterval(Self.frame)
            toy.dragMoved(dx: -40, at: now)
        }
        #expect(abs(toy.dragTilt + 14) < 0.5)
        toy.dragEnded(at: now)
        #expect(abs(toy.landingTilt + 14) < 0.5, "the landing lets go of the lean it had")
        #expect(toy.dragTilt == 0)
        withExtendedLifetime(store) {}
    }

    @Test("a stale reader can't replay a landed hop or start an ask in the past")
    func staleReaders() {
        let core = CoreModel()
        let store = ToysStore(core: core, settings: SettingsStore(core: core),
                              state: ToysState(), cardModel: makeTestCardModel(),
                              notchRuntimeEnabled: false)
        defer { withExtendedLifetime(store) {} }
        let toy = store.notchBuddy
        let t0 = Date(timeIntervalSince1970: 1_000)
        toy.giveTreat(at: t0)
        let hops = !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        #expect(toy.summary(at: t0.addingTimeInterval(0.5)).mood == (hops ? .celebrating : .asleep))
        #expect(toy.summary(at: t0.addingTimeInterval(2)).mood == .asleep, "landed")
        // The caption's slow timeline answers with a date from before the
        // hop; it gets the latest time instead, so the mood doesn't flip back.
        #expect(toy.summary(at: t0.addingTimeInterval(-3)).mood == .asleep)
        #expect(toy.handoff(at: t0.addingTimeInterval(2.5)) == nil)

        // An ask lands; the first reader to see it is a stale one.
        core.apply(.state(CoreState(sessions: [
            CoreSession(id: "ask", provider: "claude", mode: "waiting_for_input", lifecycle: "active"),
        ])))
        #expect(toy.summary(at: t0).mood == .waving)
        #expect(toy.wavingSince == t0.addingTimeInterval(2), "stamped at the latest time seen, not the stale one")
    }

    @Test("a second mood change mid-handoff carries on from the blend drawn, not the old mood whole")
    func handoffChains() {
        // Pacing at its right-hand end (3 pt off centre) against the
        // gathering's centred hops: a quick pacing → gathering → pacing
        // flicker, the second change 0.1 s into the first.
        let pace = 0.45 * 3.4
        let first = BuddyHandoff(from: .pacing, age: 0.1)
        let drawn = figure(mood: .gathering, stride: pace, handoff: first).pose
        let second = BuddyHandoff(from: .gathering, age: 0, blend: first.shares(into: .gathering))
        let after = figure(stride: pace, handoff: second).pose
        #expect(abs(after.offset.width - drawn.offset.width) < 1e-9)
        #expect(abs(after.offset.height - drawn.offset.height) < 1e-9)
        #expect(abs(after.lean - drawn.lean) < 1e-9)
        let restart = figure(stride: pace, handoff: BuddyHandoff(from: .gathering, age: 0)).pose
        #expect(abs(restart.offset.width - drawn.offset.width) > 1, "starting from gathering whole jumped")

        var last = after
        var age = Self.frame
        while age <= BuddyHandoff.duration + Self.frame {
            let pose = figure(stride: pace, handoff: BuddyHandoff(from: .gathering, age: age,
                                                                   blend: second.blend)).pose
            #expect(abs(pose.offset.width - last.offset.width) <= 0.5)
            last = pose
            age += Self.frame
        }
        #expect(abs(last.offset.width - figure(stride: pace).pose.offset.width) < 1e-9, "lands on pacing")
    }

    @Test("the toy records the blend a change lands on, and a finished one starts clean")
    func toyRecordsBlend() {
        let core = CoreModel()
        let store = ToysStore(core: core, settings: SettingsStore(core: core),
                              state: ToysState(), cardModel: makeTestCardModel(),
                              notchRuntimeEnabled: false)
        defer { withExtendedLifetime(store) {} }
        let toy = store.notchBuddy
        let t0 = Date(timeIntervalSince1970: 1_000)
        func working(_ count: Int) -> CoreState {
            CoreState(sessions: (0..<count).map {
                CoreSession(id: "s\($0)", provider: "claude", mode: "tool_running", lifecycle: "active")
            })
        }
        core.apply(.state(working(1)))
        #expect(toy.summary(at: t0).mood == .pacing)
        core.apply(.state(working(3)))
        #expect(toy.summary(at: t0.addingTimeInterval(1)).mood == .gathering)
        #expect(toy.handoff(at: t0.addingTimeInterval(1))?.leaving == [.pacing: 1])
        core.apply(.state(working(1)))
        let flicker = t0.addingTimeInterval(1.1)
        #expect(toy.summary(at: flicker).mood == .pacing)
        // Dates this far from 2001 carry about a tenth of a microsecond.
        let w = BuddyHandoff(from: .pacing, age: 0.1).weight
        let leaving = toy.handoff(at: flicker)?.leaving ?? [:]
        #expect(abs((leaving[.pacing] ?? 0) - (1 - w)) < 1e-5)
        #expect(abs((leaving[.gathering] ?? 0) - w) < 1e-5)
        // Long after, a change starts from the mood it leaves, whole.
        core.apply(.state(working(3)))
        let later = t0.addingTimeInterval(5)
        #expect(toy.summary(at: later).mood == .gathering)
        #expect(toy.handoff(at: later)?.leaving == [.pacing: 1])
    }

    @Test("a wall clock set back moves the mood's clocks with it")
    func clockSetBack() {
        let core = CoreModel()
        let store = ToysStore(core: core, settings: SettingsStore(core: core),
                              state: ToysState(), cardModel: makeTestCardModel(),
                              notchRuntimeEnabled: false)
        defer { withExtendedLifetime(store) {} }
        let toy = store.notchBuddy
        let t0 = Date(timeIntervalSince1970: 100_000)
        var wall = t0
        toy.wallClock = { wall }
        core.apply(.state(CoreState(sessions: [
            CoreSession(id: "ask", provider: "claude", mode: "waiting_for_input", lifecycle: "active"),
        ])))
        #expect(toy.summary(at: t0).mood == .waving)
        wall = t0.addingTimeInterval(2)
        _ = toy.summary(at: wall)

        // Two seconds into the ask the clock is set back an hour.
        wall = t0.addingTimeInterval(2 + Self.frame - 3600)
        _ = toy.summary(at: wall)
        let since = toy.wavingSince ?? .distantFuture
        #expect(abs(wall.timeIntervalSince(since) - 2) < 0.1, "the ask keeps its age, its entrance long played")

        // The ask is answered; the handoff plays on the new clock at once.
        core.apply(.state(CoreState(sessions: [])))
        let answered = wall.addingTimeInterval(1)
        #expect(toy.summary(at: answered).mood == .asleep)
        let handoff = toy.handoff(at: answered.addingTimeInterval(0.1))
        #expect(abs((handoff?.age ?? -1) - 0.1) < 1e-5, "not held at the old pose until real time catches up")

        // A reader seconds stale is not a clock step: nothing moves.
        wall = answered.addingTimeInterval(0.05)
        _ = toy.summary(at: answered.addingTimeInterval(-10))
        let still = toy.handoff(at: answered.addingTimeInterval(0.1))
        #expect(abs((still?.age ?? -1) - 0.1) < 1e-5)
    }

    @Test("the dangle's lag is finite-safe")
    func followIsSafe() {
        #expect(BuddyTurn.follow(3, toward: 10, dt: 0) == 3)
        #expect(BuddyTurn.follow(.nan, toward: 10, dt: 0.1) == 10)
        #expect(BuddyTurn.follow(3, toward: .infinity, dt: 0.1) == 3)
        let afterPause = BuddyTurn.follow(3, toward: 10, dt: 10)
        #expect(afterPause > 3 && afterPause < 6, "a pause is no licence to jump")
        #expect(afterPause == BuddyTurn.follow(3, toward: 10, dt: BuddyTurn.longestStep))
    }

    @Test("an arrival grows and drifts in, then is over")
    func arrival() {
        let start = BuddyArrival(fromScale: 0.5, drift: CGSize(width: 10, height: -4), age: 0)
        #expect(start.scale == 0.5 && start.offset == CGSize(width: 10, height: -4))
        let end = BuddyArrival(fromScale: 0.5, drift: CGSize(width: 10, height: -4),
                               age: BuddyArrival.duration)
        #expect(end.isOver && end.scale == 1 && end.offset == .zero)
    }
}
