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
