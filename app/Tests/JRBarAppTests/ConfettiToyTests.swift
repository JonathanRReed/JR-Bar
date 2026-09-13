import Foundation
import SwiftUI
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
/// `ConfettiView` is a `View`, so its members are `@MainActor` — the
/// suite runs on the main actor or those calls trap at runtime.
@Suite @MainActor struct ConfettiPhysicsTests {
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

    // MARK: Landing modes & settings

    /// The window's life is derived, not hardcoded: for every landing
    /// mode it must cover the slowest piece's whole journey — delay,
    /// rise, and the inverse fall to that mode's end point — stretched
    /// by `duration`, plus the 0.4 s tail.
    @Test func lifeCoversTheSlowestPieceInEveryMode() {
        let screen = 900.0
        for mode in ConfettiLanding.allCases {
            let viewHeight = ConfettiView.viewHeight(for: mode, screenHeight: screen)
            var settings = ConfettiSettings()
            settings.landing = mode
            let view = ConfettiView(color: .red, flash: false, settings: settings,
                                    viewHeight: viewHeight, screenHeight: screen,
                                    bandBottom: 44)
            for piece in view.pieces {
                let endY: Double
                var extra = 0.0
                switch mode {
                case .rest:
                    if piece.shape == .streamer {
                        endY = viewHeight - 7
                        extra = 0.3
                    } else {
                        endY = viewHeight
                    }
                case .fall:
                    endY = viewHeight
                case .fade:
                    endY = min(viewHeight, screen * 0.6)
                }
                let travel = piece.delay + piece.apexT
                    + ConfettiPhysics.fallTime(vt: piece.vt,
                                               d: max(0, piece.apexH + endY - ConfettiView.muzzleY))
                    + extra
                #expect(view.life + 0.001 >= travel + 0.4,
                        "\(mode) life \(view.life) must outlast a piece's \(travel)s journey plus the tail")
            }
        }
    }

    /// `duration` stretches the timeline: the derived life scales with
    /// it, so a lingering burst keeps its window open just as long.
    @Test func durationScalesLife() {
        var settings = ConfettiSettings()
        settings.landing = .fall
        let short = ConfettiView(color: .red, flash: false, settings: settings,
                                 viewHeight: 900, screenHeight: 900, bandBottom: 44)
        settings.duration = 1.5
        let long = ConfettiView(color: .red, flash: false, settings: settings,
                                viewHeight: 900, screenHeight: 900, bandBottom: 44)
        // Different rolls of pieces — compare against each view's own
        // travel, and check the stretch itself.
        let shortTravel = ConfettiView.travelTime(pieces: short.pieces, mode: .fall,
                                                  viewHeight: 900, screenHeight: 900)
        let longTravel = ConfettiView.travelTime(pieces: long.pieces, mode: .fall,
                                                 viewHeight: 900, screenHeight: 900)
        #expect(abs(short.life - (shortTravel + 0.4)) < 0.001)
        #expect(abs(long.life - (longTravel * 1.5 + 0.4)) < 0.001)
        #expect(long.life > short.life)
    }

    /// Fade dissolves between 40% and 60% of the screen's height: full
    /// colour at the top of the band, gone by the bottom of it.
    @Test func fadeModeDissolvesBySixtyPercent() {
        let screen = 900.0
        let viewHeight = ConfettiView.viewHeight(for: .fade, screenHeight: screen)
        #expect(viewHeight >= screen * 0.6, "the window must reach the dissolve's end")
        #expect(ConfettiView.heightFade(mode: .fade, y: screen * 0.3,
                                        viewHeight: viewHeight, screenHeight: screen) == 1)
        #expect(ConfettiView.heightFade(mode: .fade, y: screen * 0.4,
                                        viewHeight: viewHeight, screenHeight: screen) == 1)
        let mid = ConfettiView.heightFade(mode: .fade, y: screen * 0.5,
                                          viewHeight: viewHeight, screenHeight: screen)
        #expect(mid > 0.01 && mid < 0.99)
        #expect(ConfettiView.heightFade(mode: .fade, y: screen * 0.6,
                                        viewHeight: viewHeight, screenHeight: screen) == 0)
        // And the shrink rides along: no shrink in the other modes.
        #expect(ConfettiView.fadeShrink(mode: .fade, heightFade: 0) < 1)
        #expect(ConfettiView.fadeShrink(mode: .rest, heightFade: 0) == 1)
    }

    /// Density scales the piece count monotonically — 0.5…2× the
    /// baseline burst.
    @Test func densityScalesPieceCount() {
        let half = ConfettiView.makePieces(density: 0.5, shapes: .mixed).count
        let one = ConfettiView.makePieces(density: 1, shapes: .mixed).count
        let two = ConfettiView.makePieces(density: 2, shapes: .mixed).count
        #expect(half < one && one < two)
        #expect(one == 140)
    }

    /// The shapes setting narrows the cast: streamers only, glyph
    /// flecks only, or the full mix.
    @Test func shapesNarrowsTheCast() {
        #expect(ConfettiView.makePieces(density: 1, shapes: .streamers)
            .allSatisfy { $0.shape == .streamer })
        #expect(ConfettiView.makePieces(density: 1, shapes: .flecks)
            .allSatisfy { $0.shape == .diamond || $0.shape == .pacDot })
    }

    /// Missing keys read as the shipped look; an unknown enum string
    /// falls back to its default instead of sinking the burst.
    @Test func settingsDecodeTolerantly() throws {
        let decode = { (json: String) throws -> ConfettiSettings in
            try JSONDecoder().decode(ConfettiSettings.self, from: Data(json.utf8))
        }
        #expect(try decode("{}") == ConfettiSettings())
        #expect(try decode(#"{"enabled": true}"#) == ConfettiSettings(enabled: true))
        let odd = try decode(#"{"landing": "warp", "palette": "neon", "shapes": "shrapnel", "density": "lots", "duration": "ages"}"#)
        #expect(odd == ConfettiSettings(), "unknown strings & mistyped numbers must all be defaults")
        let partial = try decode(#"{"landing": "fall", "palette": "rainbow"}"#)
        #expect(partial.landing == .fall && partial.palette == .rainbow)
        #expect(partial.shapes == .mixed && partial.density == 1 && partial.duration == 1)
    }
}
