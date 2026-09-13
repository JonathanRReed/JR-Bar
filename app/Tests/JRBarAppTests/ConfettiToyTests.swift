import Testing
import JRBarCore
@testable import JRBarApp

/// The confetti trigger: a `quota_reset` on the weekly lane only. A
/// five-hour refill or a lane-less reset must stay silent, and no other
/// event kind may borrow the lane.
@Suite struct ConfettiToyTests {
    @Test func weeklyLaneFires() {
        #expect(ConfettiToy.isWeeklyReset(CoreEvent(id: "1", kind: "quota_reset", lane: "weekly")))
    }

    @Test func scopedWeeklyLaneFires() {
        // Provider-specific weekly ids end in `-weekly` (e.g. Antigravity).
        #expect(ConfettiToy.isWeeklyReset(CoreEvent(id: "2", kind: "quota_reset", lane: "antigravity-weekly")))
    }

    @Test func fiveHourAndOtherLanesDoNotFire() {
        #expect(!ConfettiToy.isWeeklyReset(CoreEvent(id: "3", kind: "quota_reset", lane: "five-hour")))
        #expect(!ConfettiToy.isWeeklyReset(CoreEvent(id: "4", kind: "quota_reset", lane: "monthly")))
    }

    @Test func missingLaneDoesNotFire() {
        #expect(!ConfettiToy.isWeeklyReset(CoreEvent(id: "5", kind: "quota_reset")))
    }

    @Test func otherKindsWithAWeeklyLaneDoNotFire() {
        #expect(!ConfettiToy.isWeeklyReset(CoreEvent(id: "6", kind: "quota_warning", lane: "weekly")))
        #expect(!ConfettiToy.isWeeklyReset(CoreEvent(id: "7", kind: "completed", lane: "weekly")))
    }
}

/// The burst ballistics (`ConfettiPhysics`): the closed-form drag model
/// must actually rise to an apex, settle at terminal speed, and bleed
/// the sideways spray — a burst that only falls is the old toy.
@Suite struct ConfettiPhysicsTests {
    private let vt = 180.0

    @Test func launchRisesToAnApex() {
        let apex = ConfettiPhysics.apexTime(v0: 520, vt: vt)
        #expect(apex > 0.1 && apex < 0.6)
        #expect(ConfettiPhysics.rise(v0: 520, vt: vt, t: 0) == 0)
        #expect(abs(ConfettiPhysics.rise(v0: 520, vt: vt, t: apex)
                    - ConfettiPhysics.apexHeight(v0: 520, vt: vt)) < 0.5)
        #expect(ConfettiPhysics.apexHeight(v0: 520, vt: vt) > 20)
    }

    @Test func fallApproachesTerminalSpeed() {
        #expect(ConfettiPhysics.fall(vt: vt, t: 0) == 0)
        // Far past the apex the ln-cosh solution is a straight line at vt.
        let slope = ConfettiPhysics.fall(vt: vt, t: 3) - ConfettiPhysics.fall(vt: vt, t: 2)
        #expect(abs(slope - vt) < 1)
    }

    @Test func sidewaysSprayDecelerates() {
        let near = ConfettiPhysics.travel(v0: 500, vt: vt, t: 0.5)
        let far = ConfettiPhysics.travel(v0: 500, vt: vt, t: 2)
        #expect(near > 0 && far > near)
        #expect(far < 500 * 2 / 2)  // drag ate it — no coasting
        #expect(abs(ConfettiPhysics.travel(v0: -500, vt: vt, t: 1)
                    + ConfettiPhysics.travel(v0: 500, vt: vt, t: 1)) < 0.001)
    }
}
