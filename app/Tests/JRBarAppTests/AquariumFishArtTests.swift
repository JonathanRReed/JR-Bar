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
}
