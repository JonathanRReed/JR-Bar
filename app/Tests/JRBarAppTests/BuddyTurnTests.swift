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
                        handoff: BuddyHandoff? = nil, still: Bool = false) -> BuddyFigure {
        BuddyFigure(character: .dot, mood: mood, tint: .accentColor, phase: 2.35,
                    hopProgress: hopProgress, waveAge: nil, slumpAge: nil, leans: false,
                    still: still, askCount: 0, care: .content, trick: nil,
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
