import CoreGraphics
import Foundation
import JRBarCore

/// What a piece is.
enum ConfettiPieceShape: Equatable, Sendable {
    case rect, dot, streamer, diamond, star, heart
    /// The provider's own mark (Claude's asterisk, Gemini's sparkle…).
    case glyph
}

/// One burst on one screen, worked out in full the moment it fires:
/// every piece's launch, flutter, tumble and — in Rest — the ledge it
/// lands on and when. A frame only evaluates `frame(of:at:)`, so the
/// burst's whole life is known up front (the window closes on time, a
/// test can ask where any piece is at any moment, and a render proof
/// freezes exactly the frame it names). Pure: no views, no colours —
/// a piece's colour is a slot the view resolves.
struct ConfettiBurst {
    /// What the burst was asked to be.
    struct Recipe: Equatable {
        var origin: ConfettiOrigin = .notch
        var landing: ConfettiLanding = .rest
        var intensity: ConfettiIntensity = .standard
        var shapes: ConfettiShapes = .mixed
        /// Piece-count multiplier after a replay's shrink (`ConfettiView.density`).
        var density: Double = 1
        /// Hang time, 0.7…1.5 (`ConfettiSettings.duration`): slower
        /// flutter and a longer rest. Never the pop or the spray.
        var hang: Double = 1
        /// How likely each palette slot is; the view owns the colours.
        var slotWeights: [Double] = [1]
        /// How many provider glyphs the view can draw; with none, a glyph
        /// fleck is drawn as a star.
        var glyphs: Int = 0
        /// The holiday's own fleck in place of the stars, if any.
        var special: ConfettiPieceShape = .star
    }

    /// One piece's constants; its motion is evaluated, never stored.
    struct Piece: Equatable {
        var shape: ConfettiPieceShape
        /// Drawn first, smaller, slower and softer: the depth layer.
        var far: Bool
        var launch: ConfettiEmitter.Launch
        /// Flutter speed (pt/s) and how quickly the fall ramps up to it.
        var vt: Double
        var tf: Double
        /// The tumble: a unit axis, a rate (rad/s) and where it starts.
        var axisX: Double, axisY: Double, axisZ: Double
        var spin: Double
        var phase: Double
        /// The falling-leaf swing: amplitude (pt), rate (rad/s), phase,
        /// and the dip at each end of it.
        var sway: Double
        var swayRate: Double
        var swayPhase: Double
        var bob: Double
        /// Length and width-to-length; a streamer's width is `aspect`.
        var size: Double
        var aspect: Double
        /// Palette slot, and which glyph a glyph fleck draws.
        var slot: Int
        var glyph: Int
        /// How fast a streamer's ripple runs along it.
        var ripple: Double
        /// Rest: where and when it lands (`nil` in Fall and Fade).
        var landing: Landing?
        /// Seconds after its own launch at which it starts to fade, and is gone.
        var fadeFrom: Double
        var end: Double
    }

    /// Where a Rest piece comes to lie.
    struct Landing: Equatable {
        var x: Double
        /// The surface's y: a window's top edge, the Dock's top, or the bottom.
        var y: Double
        /// Seconds after launch it touches down.
        var t: Double
        /// Which of the stage's windows it lies on; nil for the Dock or
        /// the bottom edge, which never move.
        var window: Int?
        /// The flattened pose it settles into: how wide it lies, how much
        /// of it you see from the side, and which face is up.
        var lieWidth: Double
        var lieDepth: Double
        var front: Bool
    }

    /// Where one piece is at one moment, and how it looks.
    struct Frame {
        var x: Double
        var y: Double
        /// The paper's shape on screen: its swing's lean, its 3D tumble
        /// projected flat, and a landing's squash. No translation.
        var transform: CGAffineTransform
        var front: Bool
        /// Lambert shade, 0.62…1, and a specular glint, 0…1.
        var shade: Double
        var glint: Double
        var opacity: Double
        /// A streamer's ripple, 0..<1 around its wave.
        var ripple: Double
        /// Resting on a ledge (so a moved window can fade it).
        var resting: Bool
    }

    let stage: ConfettiStage
    let recipe: Recipe
    let pieces: [Piece]
    /// Real seconds the burst needs: the last piece gone, plus a beat.
    let life: TimeInterval
    /// The surfaces Rest lands on, from the stage's windows.
    let ledges: [CGRect]

    // MARK: The numbers

    /// Pieces on the reference screen for each size.
    static func baseCount(_ intensity: ConfettiIntensity) -> Double {
        switch intensity {
        case .subtle: return 90
        case .standard: return 180
        case .big: return 300
        }
    }

    /// Pieces one screen throws: the size's count, scaled by the screen's
    /// area and the Amount (and a replay's shrink).
    static func count(_ intensity: ConfettiIntensity, density: Double, stage: ConfettiStage) -> Int {
        max(1, Int((baseCount(intensity) * stage.areaScale * density).rounded()))
    }

    /// By when (burst seconds, at a hang time of 1) the last piece has
    /// landed in Rest, left the screen in Fall, or dissolved in Fade.
    static func deadline(_ landing: ConfettiLanding) -> Double {
        switch landing {
        case .rest: return 3.75
        case .fall: return 4.25
        case .fade: return 3.8
        }
    }

    /// Rest: every piece has faded by here (burst seconds, hang 1).
    static let lastCall = 4.85
    /// Rest: the squash-bounce, the lie and the fade.
    static let bounce = 0.3
    static let hold = 1.2
    static let fadeOut = 0.45
    /// Fall: pieces fade over the last 12 % of the screen.
    static let fallBand = 0.12
    /// Fade: pieces dissolve between 35 % and 55 % of the screen.
    static let fadeBand = (from: 0.35, to: 0.55)

    // MARK: Firing

    init(stage: ConfettiStage, recipe: Recipe, seed: UInt64) {
        var rng = ConfettiRandom(seed: seed)
        self.stage = stage
        self.recipe = recipe
        let ledges = Self.ledges(from: stage)
        self.ledges = ledges
        let count = Self.count(recipe.intensity, density: recipe.density, stage: stage)
        var made: [Piece] = []
        made.reserveCapacity(count)
        let secondVolley = recipe.intensity == .big
        for index in 0..<count {
            var piece = Self.piece(recipe: recipe, stage: stage, using: &rng)
            // Big throws a second volley a beat after the first.
            if secondVolley, index % 3 == 2 { piece.launch.delay += 0.25 }
            Self.plan(&piece, recipe: recipe, stage: stage, ledges: ledges)
            made.append(piece)
        }
        // The far layer draws first, underneath.
        pieces = made.filter(\.far) + made.filter { !$0.far }
        life = (pieces.map { $0.launch.delay + $0.end }.max() ?? 0) + 0.1
    }

    /// Rolls one piece: its shape and size, its launch, its flutter and
    /// tumble. Terminal speeds overlap across shapes, so a falling burst
    /// never sorts itself into layers of one shape each.
    private static func piece(recipe: Recipe, stage: ConfettiStage,
                              using rng: inout ConfettiRandom) -> Piece {
        let shape = Self.shape(recipe, using: &rng)
        let far = Double.random(in: 0..<1, using: &rng) < 0.3
        var launch = ConfettiEmitter.launch(recipe.origin, on: stage, using: &rng)
        if far {
            launch.vx *= 0.8
            launch.vy *= 0.8
        }
        var size: Double
        var aspect: Double
        var vt: ClosedRange<Double>
        var spin: ClosedRange<Double>
        var sway: ClosedRange<Double>
        switch shape {
        case .rect:
            size = Double.random(in: 9...15, using: &rng)
            aspect = Double.random(in: 0.45...0.75, using: &rng)
            vt = 165...335
            spin = 5...11
            sway = 10...24
        case .dot:
            size = Double.random(in: 6...8.5, using: &rng)
            aspect = 1
            vt = 180...345
            spin = 5...10
            sway = 4...10
        case .streamer:
            size = Double.random(in: 26...40, using: &rng)
            aspect = Double.random(in: 3...4, using: &rng)
            vt = 160...300
            spin = 2.5...5
            sway = 12...26
        case .diamond:
            size = Double.random(in: 7...10.5, using: &rng)
            aspect = 1
            vt = 170...335
            spin = 5...10
            sway = 6...14
        case .star, .heart, .glyph:
            size = Double.random(in: 11...15, using: &rng)
            aspect = 1
            vt = 165...320
            spin = 3...7
            sway = 6...14
        }
        if recipe.shapes == .flecks, shape != .streamer { size *= 0.8 }
        if far { size *= 0.7 }
        // Taller screens fall a little faster, so the shower takes about
        // as long on a 5K display as on a laptop; Fade drifts, Fall hurries.
        let heightScale = min(1.3, max(0.85, (stage.height / 982).squareRoot()))
        let mode: Double
        switch recipe.landing {
        case .rest: mode = 1
        case .fall: mode = 1.1
        case .fade: mode = 0.85
        }
        let hang = min(1.5, max(0.7, recipe.hang))
        let flutter = Double.random(in: vt, using: &rng) * (far ? 0.9 : 1) * heightScale * mode / hang
        // A random tumble axis; the marks (glyphs, stars, hearts) lean
        // toward spinning in the plane, so they stay readable.
        var ax = Double.random(in: -1...1, using: &rng)
        var ay = Double.random(in: -1...1, using: &rng)
        var az = Double.random(in: -1...1, using: &rng)
        if shape == .glyph || shape == .star || shape == .heart {
            ax *= 0.45
            ay *= 0.45
            az = az < 0 ? -1 : 1
        }
        let norm = max(1e-6, (ax * ax + ay * ay + az * az).squareRoot())
        ax /= norm
        ay /= norm
        az /= norm
        let turn = Double.random(in: spin, using: &rng) * (far ? 0.8 : 1)
        return Piece(
            shape: shape, far: far, launch: launch,
            vt: flutter, tf: Double.random(in: 0.38...0.52, using: &rng),
            axisX: ax, axisY: ay, axisZ: az,
            spin: Bool.random(using: &rng) ? turn : -turn,
            phase: Double.random(in: 0...(2 * .pi), using: &rng),
            sway: Double.random(in: sway, using: &rng) * (far ? 0.7 : 1),
            swayRate: Double.random(in: 2.2...4.2, using: &rng),
            swayPhase: Double.random(in: 0...(2 * .pi), using: &rng),
            bob: Double.random(in: 1.5...3.5, using: &rng),
            size: size, aspect: aspect,
            slot: Self.slot(recipe.slotWeights, using: &rng),
            glyph: recipe.glyphs > 0 ? Int.random(in: 0..<recipe.glyphs, using: &rng) : 0,
            ripple: Double.random(in: 3...6, using: &rng),
            landing: nil, fadeFrom: 0, end: 0)
    }

    /// The shapes setting's mix. The "special" fleck is the provider's
    /// glyph when the view has one, else a star (or a holiday's heart).
    private static func shape(_ recipe: Recipe, using rng: inout ConfettiRandom) -> ConfettiPieceShape {
        let roll = Double.random(in: 0..<1, using: &rng)
        let mark: ConfettiPieceShape = recipe.glyphs > 0 ? .glyph : recipe.special
        switch recipe.shapes {
        case .mixed:
            if roll < 0.5 { return .rect }
            if roll < 0.68 { return .dot }
            if roll < 0.84 { return .streamer }
            if roll < 0.92 { return mark }
            return roll < 0.96 ? recipe.special : .diamond
        case .streamers:
            return .streamer
        case .flecks:
            if roll < 0.45 { return .diamond }
            return roll < 0.75 ? mark : .dot
        case .glyphs:
            return mark
        case .stars:
            return recipe.special
        }
    }

    private static func slot(_ weights: [Double], using rng: inout ConfettiRandom) -> Int {
        let total = weights.reduce(0, +)
        guard total > 0 else { return 0 }
        var roll = Double.random(in: 0..<total, using: &rng)
        for (index, weight) in weights.enumerated() {
            roll -= weight
            if roll < 0 { return index }
        }
        return weights.count - 1
    }

    // MARK: Where it ends

    /// The windows a piece can land on: wide enough to hold one, with a
    /// top edge on the screen and clear of the menu bar (a maximised
    /// window's edge would catch the pop the instant it left the lip),
    /// and above the floor.
    static func ledges(from stage: ConfettiStage) -> [CGRect] {
        stage.windows.filter {
            $0.width >= 80 && $0.minY >= stage.menuBarBottom + 36 && $0.minY < stage.floor - 20
                && $0.maxX > 0 && $0.minX < stage.width
        }
    }

    /// The surface a piece falling at `x` meets first below `above`: the
    /// highest window top edge there that no window in front of it
    /// covers, else the floor (the Dock's top, or the bottom edge).
    static func surface(at x: Double, below above: Double, ledges: [CGRect],
                        floor: Double) -> (y: Double, window: Int?) {
        var best: (y: Double, window: Int?) = (floor, nil)
        for (index, ledge) in ledges.enumerated()
        where ledge.minX <= x && x <= ledge.maxX && ledge.minY > above && ledge.minY < best.y {
            let hidden = ledges[..<index].contains {
                $0.minX <= x && x <= $0.maxX && $0.minY < ledge.minY - 1 && ledge.minY < $0.maxY
            }
            if !hidden { best = (ledge.minY, index) }
        }
        return best
    }

    /// How much faster than its own flutter a late piece may be nudged in
    /// Fall and Fade before it fades out in the air instead. Rest has no
    /// cap: every piece lands.
    static let nudgeCap = 1.3
    /// A late piece's fade in the air, at the end of the burst.
    static let airFade = 0.5

    /// Works out a piece's end: in Rest its ledge, touchdown and fade; in
    /// Fall its trip off the bottom; in Fade its trip into the band. A
    /// piece too slow to finish by the landing's deadline is nudged
    /// faster — only as much as it needs, so most keep their own flutter;
    /// in Fall and Fade one that would need more than `nudgeCap` fades
    /// out where it is as the burst ends, so a curtain never bunches up
    /// into one line catching up with itself.
    private static func plan(_ piece: inout Piece, recipe: Recipe, stage: ConfettiStage, ledges: [CGRect]) {
        let hang = min(1.5, max(0.7, recipe.hang))
        let launch = piece.launch
        let by = deadline(recipe.landing) * hang - launch.delay
        let natural = piece.vt
        func reach(_ y: Double, cap: Double = .infinity) -> Double {
            let d = y - launch.y
            var t = ConfettiPhysics.settleTime(vy: launch.vy, tau: launch.tau, vt: piece.vt, tf: piece.tf, d: d)
            if t > by {
                let needed = ConfettiPhysics.flutterNeeded(vy: launch.vy, tau: launch.tau, tf: piece.tf,
                                                           d: d, by: by)
                if needed.isFinite, needed > piece.vt {
                    piece.vt = min(needed, natural * cap)
                    t = ConfettiPhysics.settleTime(vy: launch.vy, tau: launch.tau, vt: piece.vt, tf: piece.tf, d: d)
                }
            }
            return t
        }
        switch recipe.landing {
        case .fall, .fade:
            let target = recipe.landing == .fall ? stage.height + piece.size * 0.5 : stage.height * fadeBand.to
            let t = reach(target, cap: nudgeCap)
            piece.end = min(t, max(airFade, by))
            piece.fadeFrom = t > piece.end ? piece.end - airFade : piece.end
        case .rest:
            let apex = launch.y + ConfettiPhysics.drop(
                vy: launch.vy, tau: launch.tau, vt: piece.vt, tf: piece.tf,
                t: ConfettiPhysics.apexTime(vy: launch.vy, tau: launch.tau, vt: piece.vt, tf: piece.tf))
            let floor = min(stage.floor, stage.height) - 1
            // Where it lands depends on where it has drifted to by then,
            // and when depends on where: settle it in a few passes.
            var x = launch.x + launch.vx * launch.tau
            var surface = Self.surface(at: x, below: apex + 4, ledges: ledges, floor: floor)
            var t = 0.0
            for _ in 0..<3 {
                t = reach(surface.y - lieHeight(piece))
                x = Self.x(of: piece, at: t)
                let next = Self.surface(at: x, below: apex + 4, ledges: ledges, floor: floor)
                if next.y == surface.y, next.window == surface.window { break }
                surface = next
            }
            t = reach(surface.y - lieHeight(piece))
            x = Self.x(of: piece, at: t)
            var lieRandom = rngForLie(piece)
            let flat = Double.random(in: 0.3...0.5, using: &lieRandom)
            piece.landing = Landing(x: x, y: surface.y, t: t, window: surface.window,
                                    lieWidth: 1, lieDepth: flat, front: piece.phase < .pi)
            let lastFade = lastCall * hang - launch.delay - fadeOut
            piece.fadeFrom = max(t + bounce, min(t + bounce + hold * hang, lastFade))
            piece.end = piece.fadeFrom + fadeOut
        }
    }

    /// Half the height a piece shows lying on its side: how far its
    /// centre sits above the ledge.
    private static func lieHeight(_ piece: Piece) -> Double {
        switch piece.shape {
        case .streamer: return 1.5
        case .rect: return piece.size * piece.aspect * 0.2
        default: return piece.size * 0.2
        }
    }

    /// A small per-piece random source for the lie, from its own phase,
    /// so the lie never shifts the burst's main sequence.
    private static func rngForLie(_ piece: Piece) -> ConfettiRandom {
        ConfettiRandom(seed: UInt64(bitPattern: Int64(piece.phase * 1_000_000)))
    }

    // MARK: A moment

    /// A piece's x `t` seconds after its launch, in flight.
    static func x(of piece: Piece, at t: Double) -> Double {
        let swing = sin(piece.swayRate * t + piece.swayPhase)
        return piece.launch.x + ConfettiPhysics.spray(v0: piece.launch.vx, tau: piece.launch.tau, t: t)
            + piece.sway * swing * ConfettiPhysics.swayRamp(t)
    }

    /// A piece's y `t` seconds after its launch, in flight — the bob
    /// fades out just before a landing, so a piece meets its ledge
    /// exactly.
    static func y(of piece: Piece, at t: Double) -> Double {
        let launch = piece.launch
        let fall = ConfettiPhysics.drop(vy: launch.vy, tau: launch.tau, vt: piece.vt, tf: piece.tf, t: t)
        var bob = piece.bob * cos(2 * (piece.swayRate * t + piece.swayPhase)) * ConfettiPhysics.swayRamp(t)
        if let landing = piece.landing { bob *= min(1, max(0, (landing.t - t) / 0.2)) }
        return launch.y + fall - bob
    }

    /// Piece `index` at burst time `time` (seconds since the pop), or
    /// nil while it hasn't launched or once it's gone.
    func frame(of index: Int, at time: Double) -> Frame? {
        let piece = pieces[index]
        let t = time - piece.launch.delay
        guard t >= 0, t < piece.end else { return nil }
        let swing = sin(piece.swayRate * t + piece.swayPhase)
        let ramp = ConfettiPhysics.swayRamp(t)
        let spin = piece.phase + piece.spin * t
        let rotation = ConfettiPhysics.rotation(axis: (piece.axisX, piece.axisY, piece.axisZ), angle: spin)
        var light = ConfettiPhysics.lighting(rotation)
        var transform = CGAffineTransform(rotationAngle: 0.35 * swing * ramp)
            .concatenating(ConfettiPhysics.projection(rotation))
        var x: Double
        var y: Double
        var opacity = 1.0
        var resting = false
        if let landing = piece.landing, t >= landing.t {
            // Down: one squash-bounce, then it eases flat onto the ledge
            // and lies there until its fade.
            let since = t - landing.t
            let bounce = ConfettiPhysics.floorBounce(t: since, height: 5, duration: 0.26)
            let settle = ConfettiPhysics.smooth(since / 0.22)
            let lie = CGAffineTransform(a: landing.lieWidth, b: 0, c: 0, d: landing.lieDepth, tx: 0, ty: 0)
            let atTouch = Self.transform(of: piece, at: landing.t)
            transform = Self.blend(atTouch, lie, settle)
                .concatenating(CGAffineTransform(scaleX: bounce.squashX, y: bounce.squashY))
            x = landing.x
            y = landing.y - Self.lieHeight(piece) - bounce.lift
            if settle >= 1 {
                light = (landing.front, 0.84, 0)
            }
            resting = true
        } else {
            x = Self.x(of: piece, at: t)
            y = Self.y(of: piece, at: t)
        }
        switch recipe.landing {
        case .fall:
            let band = stage.height * Self.fallBand
            opacity = min(1, max(0, (stage.height - y) / max(1, band))) * airOpacity(piece, at: t)
        case .fade:
            let from = stage.height * Self.fadeBand.from
            let to = stage.height * Self.fadeBand.to
            opacity = (1 - ConfettiPhysics.smooth((y - from) / max(1, to - from))) * airOpacity(piece, at: t)
            transform = transform.scaledBy(x: 1 - 0.35 * (1 - opacity), y: 1 - 0.35 * (1 - opacity))
        case .rest:
            if t > piece.fadeFrom { opacity = max(0, 1 - (t - piece.fadeFrom) / Self.fadeOut) }
        }
        return Frame(x: x, y: y, transform: transform, front: light.front, shade: light.shade,
                     glint: light.glint, opacity: opacity,
                     ripple: (piece.ripple * t / (2 * .pi)).truncatingRemainder(dividingBy: 1),
                     resting: resting)
    }

    /// Fall and Fade: a late piece's fade in the air as the burst ends.
    private func airOpacity(_ piece: Piece, at t: Double) -> Double {
        guard piece.fadeFrom < piece.end, t > piece.fadeFrom else { return 1 }
        return max(0, (piece.end - t) / (piece.end - piece.fadeFrom))
    }

    /// A piece's in-flight shape at `t` (for easing a landing from it).
    private static func transform(of piece: Piece, at t: Double) -> CGAffineTransform {
        let swing = sin(piece.swayRate * t + piece.swayPhase)
        let rotation = ConfettiPhysics.rotation(axis: (piece.axisX, piece.axisY, piece.axisZ),
                                                angle: piece.phase + piece.spin * t)
        return CGAffineTransform(rotationAngle: 0.35 * swing * ConfettiPhysics.swayRamp(t))
            .concatenating(ConfettiPhysics.projection(rotation))
    }

    private static func blend(_ a: CGAffineTransform, _ b: CGAffineTransform, _ u: Double) -> CGAffineTransform {
        CGAffineTransform(a: a.a + (b.a - a.a) * u, b: a.b + (b.b - a.b) * u,
                          c: a.c + (b.c - a.c) * u, d: a.d + (b.d - a.d) * u, tx: 0, ty: 0)
    }

    // MARK: Ledges that move

    /// Which of the planned ledges still stand, given the windows now:
    /// one stands while some window's top edge is within a few points of
    /// where it was. A piece lying on one that moved or closed fades.
    static func standing(_ ledges: [CGRect], now windows: [CGRect]) -> [Bool] {
        ledges.map { ledge in
            windows.contains {
                abs($0.minX - ledge.minX) <= 4 && abs($0.maxX - ledge.maxX) <= 4
                    && abs($0.minY - ledge.minY) <= 4
            }
        }
    }
}
