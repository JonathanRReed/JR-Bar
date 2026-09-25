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

/// The burst's motion (`ConfettiPhysics`): spray, then flutter. These
/// replace the tests that pinned the old quadratic-drag model on purpose
/// — that model is gone, not loosened.
@Suite struct ConfettiPhysicsTests {
    @Test func sprayStartsAtZeroAndApproachesItsReach() {
        #expect(ConfettiPhysics.spray(v0: 1200, tau: 0.2, t: 0) == 0)
        let reach = 1200 * 0.2
        #expect(abs(ConfettiPhysics.spray(v0: 1200, tau: 0.2, t: 3) - reach) < 0.01)
        var last = 0.0
        for step in 1...60 {
            let d = ConfettiPhysics.spray(v0: 1200, tau: 0.2, t: Double(step) * 0.02)
            #expect(d > last, "monotone")
            #expect(d < reach, "it never passes v0·τ")
            last = d
        }
        // Linear drag: double the launch, double the reach.
        #expect(abs(ConfettiPhysics.spray(v0: 2400, tau: 0.2, t: 1) - 2 * ConfettiPhysics.spray(v0: 1200, tau: 0.2, t: 1)) < 1e-9)
    }

    @Test func settleRampsToItsFlutterSpeed() {
        #expect(ConfettiPhysics.settle(vt: 260, tf: 0.45, t: 0) == 0)
        let slope = ConfettiPhysics.settle(vt: 260, tf: 0.45, t: 5) - ConfettiPhysics.settle(vt: 260, tf: 0.45, t: 4)
        #expect(abs(slope - 260) < 0.5)
        #expect(ConfettiPhysics.settleVelocity(vt: 260, tf: 0.45, t: 0) == 0)
        #expect(ConfettiPhysics.settleVelocity(vt: 260, tf: 0.45, t: 0.45) < 260)
    }

    @Test func settleTimeInvertsTheDrop() {
        for (vy, vt, d) in [(0.0, 180.0, 500.0), (400, 260, 900), (-1800, 300, 400), (60, 220, 40)] {
            let t = ConfettiPhysics.settleTime(vy: vy, tau: 0.3, vt: vt, tf: 0.45, d: d)
            let dropped = ConfettiPhysics.drop(vy: vy, tau: 0.3, vt: vt, tf: 0.45, t: t)
            #expect(abs(dropped - d) < 0.5, "vy \(vy) vt \(vt) d \(d): dropped \(dropped)")
            #expect(t >= ConfettiPhysics.apexTime(vy: vy, tau: 0.3, vt: vt, tf: 0.45))
        }
    }

    @Test func aPieceFiredUpTurnsOverOnce() {
        let apex = ConfettiPhysics.apexTime(vy: -1800, tau: 0.35, vt: 280, tf: 0.45)
        #expect(apex > 0.2 && apex < 2)
        let top = ConfettiPhysics.drop(vy: -1800, tau: 0.35, vt: 280, tf: 0.45, t: apex)
        #expect(top < ConfettiPhysics.drop(vy: -1800, tau: 0.35, vt: 280, tf: 0.45, t: apex - 0.05))
        #expect(top < ConfettiPhysics.drop(vy: -1800, tau: 0.35, vt: 280, tf: 0.45, t: apex + 0.05))
        #expect(ConfettiPhysics.apexTime(vy: 300, tau: 0.35, vt: 280, tf: 0.45) == 0, "fired down, never rises")
    }

    @Test func flutterNeededLandsOnTime() {
        let needed = ConfettiPhysics.flutterNeeded(vy: 50, tau: 0.2, tf: 0.45, d: 900, by: 3)
        let t = ConfettiPhysics.settleTime(vy: 50, tau: 0.2, vt: needed, tf: 0.45, d: 900)
        #expect(abs(t - 3) < 0.01)
    }

    /// The flutter takes over from the spray without a jump: a piece's
    /// path is continuous everywhere, the hand-off included.
    @Test func positionIsContinuousThroughTheHandOff() {
        let burst = ConfettiBurst(stage: .reference, recipe: .init(landing: .fall), seed: 3)
        for index in burst.pieces.indices.prefix(40) {
            let piece = burst.pieces[index]
            var previous: (x: Double, y: Double)?
            for step in 0..<120 {
                let t = Double(step) / 120 * min(2, piece.end)
                let x = ConfettiBurst.x(of: piece, at: t)
                let y = ConfettiBurst.y(of: piece, at: t)
                if let previous {
                    // At most a spray's worth of speed over one step.
                    let limit = abs(piece.launch.vx) + abs(piece.launch.vy) + piece.vt + 400
                    #expect(hypot(x - previous.x, y - previous.y) < limit * (2.0 / 120) + 1)
                }
                previous = (x, y)
            }
        }
    }

    /// The tumble is a true 3D rotation drawn straight on: the affine's
    /// determinant is R22 (the paper's area follows its normal's pull to
    /// the eye), face and back swap with its sign, and the shade stays
    /// inside the Lambert band.
    @Test func projectionIsTheRotatedPlane() {
        var rng = ConfettiRandom(seed: 9)
        for _ in 0..<200 {
            var axis = (Double.random(in: -1...1, using: &rng), Double.random(in: -1...1, using: &rng),
                        Double.random(in: -1...1, using: &rng))
            let n = max(1e-6, (axis.0 * axis.0 + axis.1 * axis.1 + axis.2 * axis.2).squareRoot())
            axis = (axis.0 / n, axis.1 / n, axis.2 / n)
            let r = ConfettiPhysics.rotation(axis: axis, angle: Double.random(in: 0...(2 * .pi), using: &rng))
            let affine = ConfettiPhysics.projection(r)
            let determinant = affine.a * affine.d - affine.b * affine.c
            #expect(abs(determinant - r.r22) < 1e-9)
            let light = ConfettiPhysics.lighting(r)
            #expect(light.front == (r.r22 >= 0))
            #expect(light.shade >= 0.62 && light.shade <= 1)
            #expect(light.glint >= 0 && light.glint <= 1)
        }
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

/// The burst as a whole: how many pieces, how long it lives, what the
/// settings do to it.
@Suite @MainActor struct ConfettiBurstTests {
    /// Size sets the count, scaled by the screen's area and the Amount;
    /// a bigger screen gets more, capped so a 5K display stays cheap.
    @Test func countFollowsSizeAreaAndAmount() {
        let laptop = ConfettiStage.reference
        #expect(ConfettiBurst.count(.subtle, density: 1, stage: laptop) == 90)
        #expect(ConfettiBurst.count(.standard, density: 1, stage: laptop) == 180)
        #expect(ConfettiBurst.count(.big, density: 1, stage: laptop) == 300)
        #expect(ConfettiBurst.count(.standard, density: 0.5, stage: laptop) == 90)
        var wide = laptop
        wide.width = 3440
        wide.height = 1440
        let ultrawide = ConfettiBurst.count(.standard, density: 1, stage: wide)
        #expect(ultrawide > 180 && ultrawide <= Int(180 * 1.8))
        var huge = laptop
        huge.width = 6016
        huge.height = 3384
        #expect(ConfettiBurst.count(.standard, density: 1, stage: huge) == Int((180 * 1.8).rounded()))
    }

    /// The shapes setting narrows the cast; the full mix carries the
    /// provider's glyph when there is one, and a star when there isn't.
    @Test func shapesNarrowTheCast() {
        let streamers = ConfettiBurst(stage: .reference, recipe: .init(shapes: .streamers), seed: 1)
        #expect(streamers.pieces.allSatisfy { $0.shape == .streamer })
        let stars = ConfettiBurst(stage: .reference, recipe: .init(shapes: .stars), seed: 1)
        #expect(stars.pieces.allSatisfy { $0.shape == .star })
        let glyphs = ConfettiBurst(stage: .reference, recipe: .init(shapes: .glyphs, glyphs: 1), seed: 1)
        #expect(glyphs.pieces.allSatisfy { $0.shape == .glyph })
        let mixed = ConfettiBurst(stage: .reference, recipe: .init(shapes: .mixed, glyphs: 1), seed: 1)
        let cast = Set(mixed.pieces.map(\.shape))
        #expect(cast.isSuperset(of: [.rect, .dot, .streamer, .glyph]))
        let bare = ConfettiBurst(stage: .reference, recipe: .init(shapes: .mixed, glyphs: 0), seed: 1)
        #expect(!bare.pieces.contains { $0.shape == .glyph }, "no glyph to draw, no glyph fleck")
        let hearts = ConfettiBurst(stage: .reference, recipe: .init(shapes: .stars, special: .heart), seed: 1)
        #expect(hearts.pieces.allSatisfy { $0.shape == .heart })
    }

    /// Hang time slows the fall and lengthens the rest, and never the
    /// pop: the launches are the same burst's either way.
    @Test func hangTimeSlowsTheFallNotTheSpray() {
        let brisk = ConfettiBurst(stage: .reference, recipe: .init(landing: .fall, hang: 0.7), seed: 5)
        let slow = ConfettiBurst(stage: .reference, recipe: .init(landing: .fall, hang: 1.5), seed: 5)
        #expect(brisk.pieces.map(\.launch) == slow.pieces.map(\.launch), "same pop, same spray")
        #expect(slow.life > brisk.life)
        let briskMedian = brisk.pieces.map(\.vt).sorted()[brisk.pieces.count / 2]
        let slowMedian = slow.pieces.map(\.vt).sorted()[slow.pieces.count / 2]
        #expect(slowMedian < briskMedian)
    }

    /// Big throws a second volley a beat after the first.
    @Test func bigFiresTwice() {
        let big = ConfettiBurst(stage: .reference, recipe: .init(intensity: .big), seed: 2)
        let late = big.pieces.filter { $0.launch.delay >= 0.25 }
        #expect(late.count > big.pieces.count / 5)
    }

    /// In Fall a piece is nudged at most 1.3× faster to make the deadline;
    /// one that would need more fades out in the air as the burst ends,
    /// so a curtain never bunches into one line catching up with itself.
    @Test func lateFallPiecesFadeInTheAir() {
        var tall = ConfettiStage.reference
        tall.height = 1329
        let rain = ConfettiBurst(stage: tall, recipe: .init(origin: .rain, landing: .fall), seed: 6)
        let faded = rain.pieces.filter { $0.fadeFrom < $0.end }
        #expect(!faded.isEmpty, "some of a tall screen's rain fades before the bottom")
        for piece in faded {
            #expect(abs(piece.end - piece.fadeFrom - ConfettiBurst.airFade) < 1e-9)
            #expect(piece.launch.delay + piece.end <= ConfettiBurst.deadline(.fall) + 1e-9)
        }
        let index = rain.pieces.firstIndex { $0.fadeFrom < $0.end } ?? 0
        let piece = rain.pieces[index]
        let half = rain.frame(of: index, at: piece.launch.delay + piece.fadeFrom + ConfettiBurst.airFade / 2)
        #expect((half?.opacity ?? 1) < 0.6)
    }

    /// The same seed is the same burst — what the render proofs rely on.
    @Test func aSeedIsABurst() {
        let a = ConfettiBurst(stage: .reference, recipe: .init(), seed: 42)
        let b = ConfettiBurst(stage: .reference, recipe: .init(), seed: 42)
        #expect(a.pieces == b.pieces)
        #expect(a.life == b.life)
    }

    /// Missing keys read as the defaults; an unknown string or a
    /// mistyped number falls back to its default instead of sinking the
    /// burst, and an older file's Rainbow reads as Party.
    @Test func settingsDecodeTolerantly() throws {
        let decode = { (json: String) throws -> ConfettiSettings in
            try JSONDecoder().decode(ConfettiSettings.self, from: Data(json.utf8))
        }
        #expect(try decode("{}") == ConfettiSettings())
        #expect(try decode(#"{"enabled": true}"#) == ConfettiSettings(enabled: true))
        let odd = try decode(#"{"landing": "warp", "palette": "neon", "shapes": "shrapnel", "density": "lots", "duration": "ages", "origin": "moon", "intensity": 11, "screens": "some", "seasonal": "yes", "momentStyles": 2}"#)
        #expect(odd == ConfettiSettings(), "unknown strings & mistyped values must all be defaults")
        let partial = try decode(#"{"landing": "fall", "palette": "rainbow", "origin": "corners"}"#)
        #expect(partial.landing == .fall && partial.palette == .party && partial.origin == .corners)
        #expect(partial.shapes == .mixed && partial.density == 1 && partial.duration == 1)
        #expect(partial.intensity == .standard && partial.screens == .all)
        #expect(!partial.seasonal && !partial.momentStyles)
    }

    /// A search for Amount or Hang time opens Adjust, so the row it named
    /// shows; any other hit, or one in another card, leaves it folded.
    @Test func searchOpensAdjust() throws {
        let catalog = try #require(ToySearchCatalog.rows["confetti"]).map(\.title)
        for title in ConfettiAdjustDisclosure.rows {
            #expect(catalog.contains(title), "\(title) is a search row")
            let hit = SettingsSearchEntry(.toys, "Confetti", title, card: "confetti")
            #expect(ConfettiAdjustDisclosure.opens(for: hit, card: "confetti"))
            #expect(!ConfettiAdjustDisclosure.opens(for: hit, card: "aquarium"))
        }
        let origin = SettingsSearchEntry(.toys, "Confetti", "Origin", card: "confetti")
        #expect(!ConfettiAdjustDisclosure.opens(for: origin, card: "confetti"))
        #expect(!ConfettiAdjustDisclosure.opens(for: nil, card: "confetti"))
    }

    /// A search opens Adjust once. Folding the card and opening it again
    /// shows the same reveal and the same hit, and leaves Adjust as the
    /// person left it; the next search opens it again.
    @MainActor @Test func aSearchOpensAdjustOnce() {
        let toy = ConfettiToy()
        let hangTime = SettingsSearchEntry(.toys, "Confetti", "Hang time", card: "confetti")
        #expect(!ConfettiAdjustDisclosure.take(0, hit: nil, on: toy), "the card's first showing")
        #expect(ConfettiAdjustDisclosure.take(1, hit: hangTime, on: toy), "the search opens it")
        #expect(!ConfettiAdjustDisclosure.take(1, hit: hangTime, on: toy), "the card opened again")
        #expect(ConfettiAdjustDisclosure.take(2, hit: hangTime, on: toy), "a new search")
        let origin = SettingsSearchEntry(.toys, "Confetti", "Origin", card: "confetti")
        #expect(!ConfettiAdjustDisclosure.take(3, hit: origin, on: toy))
        #expect(!ConfettiAdjustDisclosure.take(nil, hit: hangTime, on: toy), "no settings store")
    }
}
