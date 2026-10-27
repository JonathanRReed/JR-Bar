import AppKit
import Foundation
import Testing
@testable import JRBarApp

/// The buddy's eyes follow the pointer: a little, inside the eye, eased,
/// and only while the shared pointer watch has something to say.
@Suite("Buddy gaze")
@MainActor
struct BuddyGazeTests {
    /// A pointer watch that counts and lets the test deliver moves.
    private final class GazeWatch: PointerWatching {
        var moves: [Int: @MainActor () -> Void] = [:]
        var losses: [Int: @MainActor () -> Void] = [:]
        var refuses = false
        private var next = 0

        func subscribe(_ onMove: @escaping @MainActor () -> Void,
                       onLost: @escaping @MainActor () -> Void) -> Int? {
            guard !refuses else { return nil }
            next += 1
            moves[next] = onMove
            losses[next] = onLost
            return next
        }

        func unsubscribe(_ token: Int) {
            moves[token] = nil
            losses[token] = nil
        }

        func deliver() { for move in moves.values { move() } }
        func die() {
            let lost = losses.values
            moves.removeAll()
            losses.removeAll()
            for onLost in lost { onLost() }
        }
    }

    private struct Rig {
        let gaze: BuddyGaze
        let watch: GazeWatch
        let now: Box
        let pointer: PointBox
    }

    private final class Box { var value: TimeInterval = 1_000 }
    private final class PointBox { var value = CGPoint(x: 900, y: 500) }

    private func rig(eyes: CGPoint = CGPoint(x: 500, y: 500)) -> Rig {
        let gaze = BuddyGaze()
        let watch = GazeWatch()
        let now = Box()
        let pointer = PointBox()
        gaze.watch = watch
        gaze.clock = { now.value }
        gaze.pointer = { pointer.value }
        gaze.eyes = { eyes }
        return Rig(gaze: gaze, watch: watch, now: now, pointer: pointer)
    }

    @Test("far away the eyes keep the mood's own look")
    func farIsRest() {
        let eyes = CGPoint(x: 500, y: 500)
        #expect(BuddyGaze.target(pointer: CGPoint(x: 900, y: 500), eyes: eyes) == .rest)
        #expect(BuddyGaze.target(pointer: CGPoint(x: 500, y: 100), eyes: eyes) == .rest)
    }

    @Test("near, the pupils lean toward the pointer and no further than the eye allows")
    func nearLeans() {
        let eyes = CGPoint(x: 500, y: 500)
        let right = BuddyGaze.target(pointer: CGPoint(x: 600, y: 500), eyes: eyes)
        #expect(right.weight == 1)
        #expect(right.x > 0.7 && right.x <= BuddyGaze.travel.width + 0.001)
        #expect(abs(right.y) < 0.001)
        // Screen y grows upward; a pointer above looks up (negative y).
        let above = BuddyGaze.target(pointer: CGPoint(x: 500, y: 600), eyes: eyes)
        #expect(above.y < 0 && above.y >= -BuddyGaze.travel.height - 0.001)
        let below = BuddyGaze.target(pointer: CGPoint(x: 500, y: 420), eyes: eyes)
        #expect(below.y > 0)
        for angle in stride(from: 0.0, to: 2 * Double.pi, by: 0.3) {
            let point = CGPoint(x: 500 + cos(angle) * 90, y: 500 + sin(angle) * 90)
            let look = BuddyGaze.target(pointer: point, eyes: eyes)
            #expect(abs(look.x) <= BuddyGaze.travel.width + 0.001)
            #expect(abs(look.y) <= BuddyGaze.travel.height + 0.001)
        }
    }

    @Test("it lets go gradually past the reach, and looks straight out on the face")
    func falloffAndFace() {
        let eyes = CGPoint(x: 500, y: 500)
        let edge = BuddyGaze.target(pointer: CGPoint(x: 500 + BuddyGaze.reach * 1.25, y: 500), eyes: eyes)
        #expect(edge.weight > 0.3 && edge.weight < 0.7)
        let face = BuddyGaze.target(pointer: CGPoint(x: 501, y: 500), eyes: eyes)
        #expect(abs(face.x) < 0.1)
        // The floating size widens the reach with the pet.
        let big = BuddyGaze.target(pointer: CGPoint(x: 500 + BuddyGaze.reach * 1.7, y: 500),
                                   eyes: eyes, scale: 2)
        #expect(big.weight == 1)
    }

    @Test("a move eases the look over its settle time, with no clock of its own")
    func eases() {
        let r = rig()
        r.gaze.setActive(true)
        #expect(r.gaze.isWatching)
        #expect(r.gaze.look(at: r.now.value) == .rest, "the first read is far away")
        r.pointer.value = CGPoint(x: 560, y: 500)
        r.watch.deliver()
        let start = r.now.value
        #expect(r.gaze.look(at: start) == .rest)
        let half = r.gaze.look(at: start + BuddyGaze.ease / 2)
        #expect(half.x > 0.2 && half.x < 0.6)
        let settled = r.gaze.look(at: start + BuddyGaze.ease)
        #expect(settled.weight == 1)
        #expect(abs(settled.x - BuddyGaze.travel.width) < 0.06)
    }

    @Test("a move that changes nothing writes nothing")
    func stillMovesWriteNothing() {
        let r = rig()
        r.gaze.setActive(true)
        r.pointer.value = CGPoint(x: 560, y: 500)
        r.watch.deliver()
        let since = r.gaze.since
        r.now.value += 5
        r.pointer.value = CGPoint(x: 560.4, y: 500.2)
        r.watch.deliver()
        #expect(r.gaze.since == since)
        r.pointer.value = CGPoint(x: 2_000, y: 500)
        r.watch.deliver()
        #expect(r.gaze.since == r.now.value, "leaving the reach eases back")
        #expect(r.gaze.to == .rest)
    }

    @Test("it lets the watch go with its last reason, and the eyes ease home")
    func releases() {
        let r = rig()
        r.gaze.setActive(true)
        r.gaze.setActive(true)
        #expect(r.watch.moves.count == 1, "one subscription, however often it is asked")
        r.pointer.value = CGPoint(x: 560, y: 500)
        r.watch.deliver()
        r.now.value += 1
        r.gaze.setActive(false)
        #expect(r.watch.moves.isEmpty)
        #expect(!r.gaze.isWatching)
        #expect(r.gaze.to == .rest)
        #expect(r.gaze.look(at: r.now.value + BuddyGaze.ease) == .rest)
    }

    @Test("a refused or dead watch leaves the eyes at rest and runs nothing")
    func refusedAndLost() {
        let r = rig()
        r.watch.refuses = true
        r.gaze.setActive(true)
        #expect(!r.gaze.isWatching)
        r.watch.refuses = false
        r.gaze.setActive(true)
        r.pointer.value = CGPoint(x: 560, y: 500)
        r.watch.deliver()
        r.watch.die()
        #expect(!r.gaze.isWatching)
        #expect(r.gaze.to == .rest)
    }

    @Test("only on screen, awake, moving and with eyes: Reduce Motion keeps them centred")
    func wanted() {
        #expect(BuddyGaze.wanted(visible: true, awake: true, still: false, mini: false))
        #expect(!BuddyGaze.wanted(visible: false, awake: true, still: false, mini: false))
        #expect(!BuddyGaze.wanted(visible: true, awake: false, still: false, mini: false))
        #expect(!BuddyGaze.wanted(visible: true, awake: true, still: true, mini: false))
        #expect(!BuddyGaze.wanted(visible: true, awake: true, still: false, mini: true))
    }

    @Test("the pose follows only in the moods that look around, pupils only")
    func poseFollows() {
        let gaze = BuddyGaze.Look(x: 0.8, y: -0.3, weight: 1)
        func figure(_ mood: NotchBuddyToy.Mood, still: Bool = false,
                    gaze: BuddyGaze.Look) -> BuddyFigure {
            BuddyFigure(character: .cat, mood: mood, tint: .blue, phase: 12,
                        hopProgress: nil, waveAge: nil, slumpAge: nil, leans: false,
                        still: still, askCount: mood == .waving ? 1 : 0, care: .content,
                        trick: nil, treatAge: nil, crumbAge: nil, gaze: gaze)
        }
        let pacing = figure(.pacing, gaze: gaze).pose
        let plain = figure(.pacing, gaze: .rest).pose
        #expect(abs(pacing.look.width - 0.8) < 0.001)
        #expect(abs(pacing.look.height + 0.3) < 0.001)
        #expect(pacing.offset == plain.offset && pacing.squash == plain.squash && pacing.lean == plain.lean)
        for mood in [NotchBuddyToy.Mood.waving, .slumped, .asleep] {
            #expect(figure(mood, gaze: gaze).pose == figure(mood, gaze: .rest).pose, "\(mood)")
        }
        #expect(figure(.pacing, still: true, gaze: gaze).pose == figure(.pacing, still: true, gaze: .rest).pose)
    }
}
