import JRBarCore
import SwiftUI

/// Seasonal touches in the tank (`SeasonalStore`): a prop or two planted
/// on the sand toward the right, clear of the castle and the wreck, and a
/// few slow particles through the water. The props bake in with the near
/// bed's still pass; the particles ride the live pass on their own clock,
/// which holds still under Reduce Motion and while the tank rests on
/// battery, and stops with the pass when the window is covered.
extension AquariumView {
    /// Today's occasion: a fixture's, or the app's.
    var season: SeasonalOccasion? {
        if let fixture { return fixture.season }
        return toy?.store?.seasonal.occasion
    }

    /// Where the props stand: the sand at about four fifths across.
    func seasonPropBase(in size: CGSize) -> CGPoint {
        let x = Double(size.width) * 0.83
        return CGPoint(x: x, y: sandTop(atX: x, in: size) + 6)
    }

    /// The props, on the near bed's still pass.
    func drawSeasonProps(canvas: inout GraphicsContext, size: CGSize, t: Double) {
        guard let season else { return }
        let base = seasonPropBase(in: size)
        let tall = min(64, max(34, Double(size.height) * 0.12))
        SeasonLook.sandProps(&canvas, season, base: base, size: tall, sand: sandTones.frontB,
                             night: nightFactor(t: t), phase: 0)
    }

    /// The particles, on the live pass. `t` is the season clock's.
    func drawSeasonParticles(canvas: inout GraphicsContext, size: CGSize, t: Double) {
        guard let season else { return }
        let water = CGRect(x: 0, y: 0, width: size.width, height: Double(size.height) * 0.78)
        var c = canvas
        c.opacity = 0.85
        SeasonParticles.draw(&c, season, in: water, t: t)
    }
}
