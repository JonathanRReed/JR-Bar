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

    @Test func fallTimeInvertsFall() {
        // The streamer bounce keys off this: fall(fallTime(d)) must be d.
        for (vt, d) in [(105.0, 500.0), (130.0, 300.0), (180.0, 40.0)] {
            let t = ConfettiPhysics.fallTime(vt: vt, d: d)
            #expect(t > 0)
            #expect(abs(ConfettiPhysics.fall(vt: vt, t: t) - d) < 0.5)
        }
        #expect(ConfettiPhysics.fallTime(vt: vt, d: 0) == 0)
    }

    @Test func floorBounceSquashesHopsOnceAndRests() {
        let impact = ConfettiPhysics.floorBounce(t: 0, height: 7, duration: 0.3)
        #expect(impact.lift == 0)
        #expect(impact.squashY < 0.7 && impact.squashX > 1)   // the hard dip
        let mid = ConfettiPhysics.floorBounce(t: 0.15, height: 7, duration: 0.3)
        #expect(mid.lift > 6)                                  // top of the hop
        #expect(mid.squashY >= 1)                              // stretched in flight
        let touchdown = ConfettiPhysics.floorBounce(t: 0.31, height: 7, duration: 0.3)
        #expect(touchdown.lift == 0 && touchdown.squashY < 1)  // the softer second dip
        let rest = ConfettiPhysics.floorBounce(t: 1, height: 7, duration: 0.3)
        #expect(rest.lift == 0)
        #expect(abs(rest.squashY - 1) < 0.05 && abs(rest.squashX - 1) < 0.05)
        #expect(ConfettiPhysics.floorBounce(t: -0.1, height: 7, duration: 0.3).lift == 0)
    }
}
