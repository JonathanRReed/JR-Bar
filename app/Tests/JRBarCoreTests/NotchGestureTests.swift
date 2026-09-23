import Foundation
import Testing
@testable import JRBarCore

/// The island's gesture machines, pure: the press-and-pull's flick and
/// travel rules, the frame spring's interruption behaviour, and the
/// capsule queue's door-side priority. Screen numbers are pointers and
/// frames, not hardware — no screen is needed for any of it.
@Suite("Notch gestures")
struct NotchGestureTests {

    // MARK: The pull — engagement and the click

    @Test("a pull under the engage travel stays the click it was")
    func shortPullIsAClick() {
        var pull = NotchPullGesture()
        pull.move(translation: 0, at: 0)
        pull.move(translation: -3, at: 0.05)
        #expect(!pull.engaged)
        #expect(pull.release(at: 0.08, surface: .rest) == .click)
        #expect(pull.release(at: 0.08, surface: .card) == .click)
    }

    @Test("an out-and-back pull is still a pull — engagement is 'it moved'")
    func outAndBackIsNotAClick() {
        var pull = NotchPullGesture()
        pull.move(translation: 0, at: 0)
        pull.move(translation: -12, at: 0.05)
        pull.move(translation: 0, at: 0.12)
        #expect(pull.engaged)
        // Back at zero the resting island has nothing to act on — a
        // retreat, never a phantom commit.
        #expect(pull.release(at: 0.14, surface: .rest) == .retreat)
    }

    // MARK: The pull — travel commits

    @Test("a slow pull past the travel threshold commits")
    func travelCommits() {
        var pull = NotchPullGesture()
        pull.move(translation: 0, at: 0)
        // Slow: ~100 pt/s spread over real time — no flick speed.
        for i in 1...10 {
            pull.move(translation: -CGFloat(i) * 5, at: Double(i) * 0.05)
        }
        #expect(pull.release(at: 0.6, surface: .rest) == .commit)
    }

    @Test("a slow pull short of the threshold retreats")
    func shortSlowPullRetreats() {
        var pull = NotchPullGesture()
        pull.move(translation: 0, at: 0)
        for i in 1...4 {
            pull.move(translation: -CGFloat(i) * 4, at: Double(i) * 0.05)
        }
        // 16 pt of slow travel — engaged, but short and slow.
        #expect(pull.release(at: 0.3, surface: .rest) == .retreat)
        #expect(pull.release(at: 0.3, surface: .card) == .retreat)
    }

    // MARK: The pull — the flick

    @Test("a fast pull commits at any travel — the flick needs no distance")
    func flickCommitsShort() {
        var pull = NotchPullGesture()
        pull.move(translation: 0, at: 0)
        pull.move(translation: -5, at: 0.010)   // engaged
        pull.move(translation: -9, at: 0.012)   // ~2000 pt/s instantaneous
        // 9 pt is far under the travel threshold — the speed carries it.
        #expect(pull.release(at: 0.014, surface: .rest) == .commit)
        #expect(pull.release(at: 0.014, surface: .card) == .commit)
    }

    @Test("a held pull released gently carries no flick — a cancel, not a swipe")
    func heldPullLosesItsFlick() {
        var pull = NotchPullGesture()
        pull.move(translation: 0, at: 0)
        pull.move(translation: -5, at: 0.010)
        pull.move(translation: -9, at: 0.012)   // fast — then the finger parks
        #expect(pull.flickSpeed(at: 0.014) < 0)
        // A quarter second of stillness bleeds the flick to nothing.
        #expect(pull.flickSpeed(at: 0.30) == 0)
        #expect(pull.release(at: 0.30, surface: .rest) == .retreat)
    }

    // MARK: The pull — what each surface answers

    @Test("the resting island only answers a pull downward")
    func restIgnoresUpward() {
        var pull = NotchPullGesture()
        pull.move(translation: 0, at: 0)
        pull.move(translation: 50, at: 0.3)
        #expect(pull.engaged)
        #expect(pull.offset(for: .rest) == 0)
        #expect(pull.release(at: 0.4, surface: .rest) == .retreat)
    }

    @Test("the grown card dismisses either way off the notch")
    func cardCommitsBothWays() {
        var down = NotchPullGesture()
        down.move(translation: 0, at: 0)
        down.move(translation: -60, at: 0.4)
        #expect(down.release(at: 0.45, surface: .card) == .commit)

        var up = NotchPullGesture()
        up.move(translation: 0, at: 0)
        up.move(translation: 60, at: 0.4)
        #expect(up.release(at: 0.45, surface: .card) == .commit)
    }

    // MARK: The pull — the damped edge

    @Test("the pull's offset is monotone and meets friction, never a wall")
    func offsetDamping() {
        func slide(for translation: CGFloat) -> CGFloat {
            var pull = NotchPullGesture()
            pull.move(translation: translation, at: 0.1)
            return pull.offset(for: .card)
        }
        let offsets = [-30, -60, -1000].map { slide(for: $0) }
        #expect(offsets[0] > offsets[1])
        #expect(offsets[1] > offsets[2])
        // A thousand points of finger still draws inside the soft
        // limit — `tanh` friction, not a wall and never past it.
        #expect(offsets[2] > -NotchPullGesture.cardSlideLimit)
        #expect(offsets[2] < 0)
        var rest = NotchPullGesture()
        rest.move(translation: -1000, at: 0.1)
        #expect(rest.offset(for: .rest) > 0)
        #expect(rest.offset(for: .rest) < NotchPullGesture.restStretchLimit)
    }

    // MARK: The frame spring

    /// Integrate `dt` steps until the spring settles or the cap passes.
    private func run(_ spring: inout NotchFrameSpring, dt: TimeInterval = 1.0 / 120,
                     maxSteps: Int = 600) -> Int {
        var steps = 0
        while spring.integrate(dt: dt), steps < maxSteps { steps += 1 }
        return steps
    }

    @Test("the spring lands exactly on its target")
    func springSettles() {
        let home = CGRect(x: 651.5, y: 934, width: 209, height: 48)
        let grown = CGRect(x: 631.5, y: 634, width: 249, height: 348)
        var spring = NotchFrameSpring(at: home)
        spring.retarget(grown, motion: NotchFrameSpring.expandMotion)
        let steps = run(&spring)
        #expect(steps > 10, "a morph takes real time — it is not a snap")
        #expect(steps < 300, "and it lands inside roughly a second")
        spring.snap()
        #expect(spring.frame == grown)
    }

    @Test("a retarget mid-flight keeps the velocity the frame had")
    func retargetContinues() {
        let home = CGRect(x: 0, y: 0, width: 200, height: 40)
        let grown = CGRect(x: 0, y: -200, width: 200, height: 240)
        var spring = NotchFrameSpring(at: home)
        spring.retarget(grown, motion: NotchFrameSpring.expandMotion)
        for _ in 0..<6 { spring.integrate(dt: 1.0 / 120) }
        let mid = spring.frame
        #expect(mid.height > home.height && mid.height < grown.height)
        // Fold home from mid-flight: the spring answers the shrink
        // with the collapse motion, and its y keeps travelling down a
        // tick before it turns — continuation, not a restart.
        spring.retarget(home, motion: NotchFrameSpring.collapseMotion)
        let before = spring.frame.minY
        spring.integrate(dt: 1.0 / 120)
        #expect(spring.frame.minY < before, "carried velocity keeps the drift first")
        let steps = run(&spring)
        spring.snap()
        #expect(steps < 300)
        #expect(spring.frame == home)
    }

    @Test("the motion picker reads growth as swell, shrink as fold")
    func motionPicker() {
        let home = CGRect(x: 0, y: 0, width: 200, height: 40)
        #expect(NotchFrameSpring.motion(from: home,
                                        to: CGRect(x: 0, y: -100, width: 240, height: 140))
                == NotchFrameSpring.expandMotion)
        #expect(NotchFrameSpring.motion(from: CGRect(x: 0, y: -100, width: 240, height: 140),
                                        to: home) == NotchFrameSpring.collapseMotion)
        // A same-size slide — a content nudge — is the quiet morph.
        #expect(NotchFrameSpring.motion(from: home,
                                        to: CGRect(x: 4, y: 0, width: 200, height: 40))
                == NotchFrameSpring.morphMotion)
    }

    @Test("a stalled tick lands the spring — sub-steps, never an explosion")
    func stalledTickIsBounded() {
        let home = CGRect(x: 0, y: 0, width: 200, height: 40)
        let grown = CGRect(x: 0, y: -200, width: 200, height: 240)
        var spring = NotchFrameSpring(at: home)
        spring.retarget(grown, motion: NotchFrameSpring.expandMotion)
        // A display link that slept a full second integrates a sane,
        // sub-stepped half-second — the frame lands near its target,
        // it does not blow past it.
        spring.integrate(dt: 1.0)
        #expect(spring.frame.height.isFinite)
        #expect(spring.frame.height <= grown.height * 1.2,
                "late ticks land, they never explode")
    }

    // MARK: Pinch

    @Test("a pinch commits once at its threshold, either way")
    func pinch() {
        var spread = NotchPinch()
        #expect(spread.add(0.1) == nil, "a wobble is not a pinch")
        #expect(spread.add(0.1) == .grow)
        #expect(spread.add(0.5) == nil, "one verdict per gesture")
        var squeeze = NotchPinch()
        #expect(squeeze.add(-0.2) == .fold)
        var back = NotchPinch()
        #expect(back.add(0.15) == nil)
        #expect(back.add(-0.3) == nil, "out and back past zero: not yet a squeeze")
        #expect(back.add(-0.1) == .fold)
    }

    // MARK: The queue's door

    @Test("an ask outranks a failure and both outrun the ambient kinds")
    func queueRank() {
        #expect(AlcoveNoticeKind.ask.queueRank < AlcoveNoticeKind.failed.queueRank)
        #expect(AlcoveNoticeKind.failed.queueRank < AlcoveNoticeKind.completed.queueRank)
        #expect(AlcoveNoticeKind.completed.queueRank < AlcoveNoticeKind.quotaReset.queueRank)
        #expect(AlcoveNoticeKind.quotaReset.queueRank < AlcoveNoticeKind.charging.queueRank)
    }

    @Test("the hover breath stays a whisper — points, not the card")
    func hoverBreathIsSmall() {
        #expect(NotchMotion.hoverGrowWidth > 0)
        #expect(NotchMotion.hoverGrowWidth < 8)
        #expect(NotchMotion.hoverGrowHeight > 0)
        #expect(NotchMotion.hoverGrowHeight < 8)
    }
}
