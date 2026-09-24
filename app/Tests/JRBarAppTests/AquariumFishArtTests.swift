import Foundation
import SwiftUI
import Testing
import JRBarCore
@testable import JRBarApp

/// The fish kit's contracts: every species has a whole kit that fits
/// the tank's hover box, a still fish costs no path rebuilding, and
/// the swim clock beats faster with speed without ever jumping.
@Suite("Aquarium fish art")
@MainActor
struct AquariumFishArtTests {
    @Test("every species has a kit that stays inside its hover box")
    func kitsFit() {
        for species in FishSpecies.allCases {
            let art = CartoonFish.art(for: species)
            #expect(!art.body.isEmpty, "\(species) has a body")
            #expect(art.bounds.width > 0.3 && art.bounds.height > 0.2, "\(species) body reads")
            // The tank's hover box is ±0.62 lengths wide around the
            // fish's centre; the body itself must sit inside it.
            #expect(art.bounds.minX > -0.62 && art.bounds.maxX < 0.62, "\(species) body inside the box")
            #expect(art.eyeR > 0.05, "\(species) has a big eye")
            #expect(art.bounds.contains(art.eye), "\(species) eye is on the head")
            #expect(art.collar.bottom.y >= art.collar.top.y, "\(species) collar found")
        }
    }

    @Test("each species keeps its own silhouette")
    func silhouettesDiffer() {
        let angel = CartoonFish.art(for: .angelfish)
        let shark = CartoonFish.art(for: .shark)
        let puffer = CartoonFish.art(for: .puffer)
        let seahorse = CartoonFish.art(for: .seahorse)
        // A tall disc under sails, a blade, a ball, an upright.
        #expect(angel.extent.height > angel.extent.width)
        #expect(shark.bounds.height / shark.bounds.width < 0.4)
        #expect(puffer.bounds.height / puffer.bounds.width > 0.85)
        #expect(seahorse.upright && seahorse.bounds.height > seahorse.bounds.width)
    }

    @Test("a still fish draws its cached paths untouched")
    func stillPoseIsFree() {
        let art = CartoonFish.art(for: .clownfish)
        let resting = CartoonFish.Pose(art: art, swim: .still)
        #expect(!resting.moving)
        #expect(resting.body(art.body) == art.body)
        let swimming = CartoonFish.Pose(art: art, swim: CartoonFish.Swim(phase: 1, amplitude: 0.25))
        #expect(swimming.moving)
        #expect(swimming.body(art.body) != art.body)
    }

    @Test("the outline keeps one weight across sizes")
    func outlineWeight() {
        // In points: never hairline, never heavy.
        for length in [18.0, 40, 60, 90, 170] {
            let points = CartoonFish.outlineWidth(length) * length
            #expect(points >= 0.95 && points <= 1.9)
        }
    }

    @Test("the swim clock beats faster with speed and never jumps")
    func swimClock() {
        let clock = FishSwimClock()
        let tank = AquariumView.TankMotion()
        var still = clock.advance("a", in: tank, seed: 0, t: 100, x: 0, y: 0, length: 60, vigor: 1).phase
        var dash = clock.advance("b", in: tank, seed: 0, t: 100, x: 0, y: 0, length: 60, vigor: 1).phase
        var lastStill = still
        var lastDash = dash
        for frame in 1...90 {
            let t = 100 + Double(frame) / 30
            still = clock.advance("a", in: tank, seed: 0, t: t, x: 0, y: 0, length: 60, vigor: 1).phase
            dash = clock.advance("b", in: tank, seed: 0, t: t, x: Double(frame) * 4, y: 0,
                                 length: 60, vigor: 1).phase
            // No frame advances the beat by more than a fraction of a
            // stroke — the tail never teleports.
            #expect(still - lastStill < 1.2 && still >= lastStill)
            #expect(dash - lastDash < 1.2 && dash >= lastDash)
            lastStill = still
            lastDash = dash
        }
        #expect(dash > still * 1.5, "a fish swimming two lengths a second beats faster than one hovering")
        // A paused window picks up where it was instead of lurching.
        let before = clock.advance("a", in: tank, seed: 0, t: 104, x: 0, y: 0, length: 60, vigor: 1).phase
        let after = clock.advance("a", in: tank, seed: 0, t: 400, x: 0, y: 0, length: 60, vigor: 1).phase
        #expect(after == before)
    }

    @Test("two tanks showing the same fish keep separate beats")
    func swimClockPerTank() {
        let clock = FishSwimClock()
        let window = AquariumView.TankMotion()
        let wallpaper = AquariumView.TankMotion()
        var oneTank = 0.0
        var twoTanks = 0.0
        let lone = FishSwimClock()
        for frame in 0...90 {
            let t = 200 + Double(frame) / 30
            // The same hovering fish, drawn at two places on two screens
            // in the same frame: neither reads the gap as a dash.
            twoTanks = clock.advance("f", in: window, seed: 0, t: t, x: 100, y: 50,
                                     length: 60, vigor: 1).phase
            _ = clock.advance("f", in: wallpaper, seed: 0, t: t, x: 900, y: 400,
                              length: 120, vigor: 1)
            oneTank = lone.advance("f", in: window, seed: 0, t: t, x: 100, y: 50,
                                   length: 60, vigor: 1).phase
        }
        #expect(twoTanks == oneTank)
    }

    @Test("with no head lead a fish draws its cached paths untouched")
    func noLeadIsFree() {
        for species in FishSpecies.allCases {
            let art = CartoonFish.art(for: species)
            let turned = CartoonFish.Pose(art: art, swim: CartoonFish.Swim(thin: 0.5, lead: 0))
            #expect(!turned.moving && !turned.warps)
            #expect(turned.body(art.body) == art.body)
            #expect(CartoonFish.HeadLead(art: art, thin: 0.5, lead: 0) == nil)
            #expect(turned.warpX(0.3) == 0.3)
        }
        // A lead does move the head.
        let art = CartoonFish.art(for: .clownfish)
        let leading = CartoonFish.Pose(art: art, swim: CartoonFish.Swim(thin: 0.5, lead: 0.3))
        #expect(leading.warps && leading.moving)
        #expect(leading.body(art.body) != art.body)
        #expect(leading.headThin < 0.5, "the head is further round than the middle")
    }

    @Test("the head lead never folds a body back on itself")
    func leadNeverFolds() {
        for species in FishSpecies.allCases where species != .seahorse {
            let art = CartoonFish.art(for: species)
            let e = art.extent
            for thin in stride(from: AquariumTurn.frontCut, through: 1.0, by: 0.05) {
                for lead in stride(from: -0.5, through: 0.5, by: 0.05) {
                    guard let warp = CartoonFish.HeadLead(art: art, thin: thin, lead: lead) else { continue }
                    var last = -Double.infinity
                    for k in 0...120 {
                        let x = e.minX + (e.maxX - e.minX) * Double(k) / 120
                        let warped = warp.x(x)
                        #expect(warped > last, "\(species) folds at x \(x), thin \(thin), lead \(lead)")
                        last = warped
                    }
                    // The middle of the body keeps the caller's squash.
                    let mid = (art.tailRootX + art.eye.x) / 2
                    #expect(abs(warp.x(mid) - mid) < 1e-9)
                }
            }
        }
    }

    @Test("the eyes stay on the body while the head leads a turn")
    func eyesStayOnTheHead() {
        for species in FishSpecies.allCases where species != .seahorse {
            let art = CartoonFish.art(for: species)
            for k in 1..<30 {
                // The head-first half of a turn, side view only.
                let pose = AquariumTurn.pose(p: Double(k) / 60, dir0: 1, arc: 1)
                guard !pose.isFront else { continue }
                let swim = CartoonFish.Swim(thin: abs(pose.c), lead: pose.lead)
                let place = CartoonFish.facePlacement(art: art, swim: swim)
                let warp = CartoonFish.HeadLead(art: art, thin: swim.thin, lead: swim.lead)
                let nose = warp?.x(art.bounds.maxX) ?? art.bounds.maxX
                let back = warp?.x(art.bounds.minX) ?? art.bounds.minX
                #expect(place.nearEye.x + art.eyeR * place.sx * 0.9 <= nose + 1e-9,
                        "\(species) at c \(pose.c): the near eye is past the nose")
                #expect(place.farEye.x - art.eyeR * place.sx * 0.9 >= back - 1e-9,
                        "\(species) at c \(pose.c): the far eye is off the back")
                #expect(place.nearEye.x >= place.farEye.x - 1e-9, "\(species): the eyes crossed")
            }
        }
    }
}
