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
        /// fleck is drawn as a star. With more than one (Everyone), glyph
        /// `i` belongs to palette slot `i`.
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
        /// Fall and Fade: seconds after its launch that it stops rising
        /// (0 for a piece thrown level or down). Until then it shows in
        /// full, so a piece thrown up from the corners is seen from its
        /// first frame.
        var apex: Double = 0
        /// Fade: how far down the screen (y) it starts to dissolve — the
        /// band's top, or where it peaks when that is lower.
        var dissolveFrom: Double = 0
    }

    /// Where a Rest piece comes to lie.
    struct Landing: Equatable {
        var x: Double
        /// The surface's y: a window's top edge, the Dock's top, or the bottom.
        var y: Double
        /// Seconds after launch it touches down.
        var t: Double
        /// Which of the burst's ledges it lies on; nil for the Dock or
        /// the bottom edge, which never move.
        var window: Int?
        /// The flattened pose it settles into: how much of it you see
        /// from the side, and which face is up.
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
    /// Each ledge's place in the stage's front-to-back window list, so a
    /// window in front of it can hide its edge.
    let ledgeOrder: [Int]

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
    /// Fade: pieces dissolve between 35 % and 55 % of the screen, on the
    /// way down (one that peaks lower dissolves over the same depth from
    /// its peak).
    static let fadeBand = (from: 0.35, to: 0.55)

    // MARK: Firing

    init(stage: ConfettiStage, recipe: Recipe, seed: UInt64) {
        var rng = ConfettiRandom(seed: seed)
        self.stage = stage
        self.recipe = recipe
        let order = Self.ledgeOrder(from: stage)
        ledgeOrder = order
        ledges = order.map { stage.windows[$0] }
        let count = Self.count(recipe.intensity, density: recipe.density, stage: stage)
        var made: [Piece] = []
        made.reserveCapacity(count)
        let secondVolley = recipe.intensity == .big
        for index in 0..<count {
            var piece = Self.piece(recipe: recipe, stage: stage, using: &rng)
            // Big throws a second volley a beat after the first.
            if secondVolley, index % 3 == 2 { piece.launch.delay += 0.25 }
            Self.plan(&piece, recipe: recipe, stage: stage, ledgeOrder: order)
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
        var slot = Self.slot(recipe.slotWeights, using: &rng)
        var glyph = recipe.glyphs > 0 ? Int.random(in: 0..<recipe.glyphs, using: &rng) : 0
        // Everyone: each provider's glyph sits on that provider's slot, so
        // a mark always wears its own provider's colour.
        if shape == .glyph, recipe.glyphs > 1 {
            if slot < recipe.glyphs { glyph = slot } else { slot = glyph }
        }
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
            slot: slot, glyph: glyph,
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

    /// The windows a piece can land on, as their places in the stage's
    /// front-to-back list: wide enough to hold one, with a top edge on
    /// the screen and clear of the menu bar (a maximised window's edge
    /// would catch the pop the instant it left the lip), and above the
    /// floor.
    static func ledgeOrder(from stage: ConfettiStage) -> [Int] {
        stage.windows.indices.filter {
            let window = stage.windows[$0]
            return window.width >= 80 && window.minY >= stage.menuBarBottom + 36
                && window.minY < stage.floor - 20 && window.maxX > 0 && window.minX < stage.width
        }
    }

    /// Whether the top edge of `windows[index]` can be seen at `x`: `x`
    /// is over it, and no window in front of it covers the edge there.
    /// Every window in front counts, ledge or not — a maximised window
    /// hides the edges of everything behind it.
    static func edgeShows(_ index: Int, at x: Double, in windows: [CGRect]) -> Bool {
        let ledge = windows[index]
        guard ledge.minX <= x, x <= ledge.maxX else { return false }
        return !windows[..<index].contains {
            $0.minX <= x && x <= $0.maxX && $0.minY < ledge.minY - 1 && ledge.minY < $0.maxY
        }
    }

    /// How much faster than its own flutter a late piece may be nudged in
    /// Fall and Fade before it fades out in the air instead. Rest has no
    /// cap: every piece lands.
    static let nudgeCap = 1.3
    /// A late piece's fade in the air, at the end of the burst.
    static let airFade = 0.5
    /// How far ahead of the landing's deadline (seconds, at a hang time
    /// of 1) a piece's own deadline may fall.
    static let trail = 0.7

    /// Works out a piece's end: in Rest its ledge, touchdown and fade; in
    /// Fall its trip off the bottom; in Fade its trip into the band. A
    /// piece too slow to finish by its deadline is nudged faster — only
    /// as much as it needs, so most keep their own flutter; in Fall and
    /// Fade one that would need more than `nudgeCap` fades out where it
    /// is instead. Each piece has its own deadline, up to `trail` ahead
    /// of the landing's, so the last ones trail off one by one instead
    /// of reaching the bottom together in a line.
    private static func plan(_ piece: inout Piece, recipe: Recipe, stage: ConfettiStage, ledgeOrder: [Int]) {
        let hang = min(1.5, max(0.7, recipe.hang))
        let launch = piece.launch
        var own = ownRandom(piece, salt: 0xDEAD_11E5)
        let early = Double.random(in: 0...trail, using: &own)
        let by = (deadline(recipe.landing) - early) * hang - launch.delay
        switch recipe.landing {
        case .fall, .fade:
            // Fade dissolves on the way down only: from the band's top, or
            // from where a piece thrown up from below peaks, if lower.
            let rise = ConfettiPhysics.apexTime(vy: launch.vy, tau: launch.tau, vt: piece.vt, tf: piece.tf)
            let peak = launch.y + ConfettiPhysics.drop(vy: launch.vy, tau: launch.tau, vt: piece.vt,
                                                       tf: piece.tf, t: rise)
            piece.dissolveFrom = max(stage.height * fadeBand.from, peak)
            let depth = stage.height * (fadeBand.to - fadeBand.from)
            let target = recipe.landing == .fall ? stage.height + piece.size * 0.5 : piece.dissolveFrom + depth
            let reach = timing(of: piece, to: target, by: by, cap: nudgeCap)
            piece.vt = reach.vt
            piece.apex = ConfettiPhysics.apexTime(vy: launch.vy, tau: launch.tau, vt: piece.vt, tf: piece.tf)
            piece.end = min(reach.t, max(airFade, by))
            piece.fadeFrom = reach.t > piece.end ? piece.end - airFade : piece.end
        case .rest:
            let spot = restingPlace(of: piece, stage: stage, ledgeOrder: ledgeOrder, by: by)
            piece.vt = spot.vt
            var lieRandom = ownRandom(piece, salt: 0)
            let flat = Double.random(in: 0.3...0.5, using: &lieRandom)
            piece.landing = Landing(x: spot.x, y: spot.y, t: spot.t, window: spot.window,
                                    lieDepth: flat, front: piece.phase < .pi)
            let lastFade = lastCall * hang - launch.delay - fadeOut
            piece.fadeFrom = max(spot.t + bounce, min(spot.t + bounce + hold * hang, lastFade))
            piece.end = piece.fadeFrom + fadeOut
        }
    }

    /// When a piece reaches `y`, at its own flutter — or, when that would
    /// finish after `by`, nudged faster, only as much as it needs and at
    /// most `cap` times its own speed — and the flutter that does it.
    private static func timing(of piece: Piece, to y: Double, by: Double,
                               cap: Double = .infinity) -> (t: Double, vt: Double) {
        let launch = piece.launch
        let d = y - launch.y
        let t = ConfettiPhysics.settleTime(vy: launch.vy, tau: launch.tau, vt: piece.vt, tf: piece.tf, d: d)
        guard t > by else { return (t, piece.vt) }
        let needed = ConfettiPhysics.flutterNeeded(vy: launch.vy, tau: launch.tau, tf: piece.tf, d: d, by: by)
        guard needed.isFinite, needed > piece.vt else { return (t, piece.vt) }
        let vt = min(needed, piece.vt * cap)
        return (ConfettiPhysics.settleTime(vy: launch.vy, tau: launch.tau, vt: vt, tf: piece.tf, d: d), vt)
    }

    /// Where a Rest piece comes to lie: the first surface it is over at
    /// the moment it comes down to it. The window top edges below its
    /// highest point are tried from the top down, each at the x the piece
    /// has drifted to by the time it gets that low — the first one that
    /// shows there takes it, so a piece never lies past the end of an
    /// edge, or on one a window in front hides. Then the Dock's top, where
    /// the Dock is; then the bottom edge.
    private static func restingPlace(of piece: Piece, stage: ConfettiStage, ledgeOrder: [Int], by: Double)
        -> (x: Double, y: Double, t: Double, vt: Double, window: Int?) {
        let launch = piece.launch
        let apex = ConfettiPhysics.apexTime(vy: launch.vy, tau: launch.tau, vt: piece.vt, tf: piece.tf)
        let above = launch.y + ConfettiPhysics.drop(vy: launch.vy, tau: launch.tau, vt: piece.vt,
                                                    tf: piece.tf, t: apex) + 4
        // Past its highest point a piece's x stays between where the spray
        // has carried it and where the spray ends, give or take its sway:
        // only the edges across that stretch can catch it.
        let early = launch.x + ConfettiPhysics.spray(v0: launch.vx, tau: launch.tau, t: apex)
        let late = launch.x + launch.vx * launch.tau
        let left = min(early, late) - piece.sway - 1
        let right = max(early, late) + piece.sway + 1
        let candidates = ledgeOrder.indices.filter {
            let ledge = stage.windows[ledgeOrder[$0]]
            return ledge.minY > above && ledge.maxX >= left && ledge.minX <= right
        }
        let lie = lieHeight(piece)
        let highestFirst = candidates.sorted { stage.windows[ledgeOrder[$0]].minY < stage.windows[ledgeOrder[$1]].minY }
        for index in highestFirst {
            let ledge = stage.windows[ledgeOrder[index]]
            let hit = timing(of: piece, to: ledge.minY - lie, by: by)
            let x = Self.x(of: piece, at: hit.t)
            if edgeShows(ledgeOrder[index], at: x, in: stage.windows) {
                return (x, ledge.minY, hit.t, hit.vt, index)
            }
        }
        let bottom = stage.height - 1
        let dock = min(stage.floor, stage.height) - 1
        if dock < bottom {
            let hit = timing(of: piece, to: dock - lie, by: by)
            let x = Self.x(of: piece, at: hit.t)
            if stage.dockSpan?.contains(x) ?? true { return (x, dock, hit.t, hit.vt, nil) }
        }
        let hit = timing(of: piece, to: bottom - lie, by: by)
        return (Self.x(of: piece, at: hit.t), bottom, hit.t, hit.vt, nil)
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

    /// A small random source of the piece's own, from its phase — one
    /// `salt` for its deadline, another for its lie — so neither shifts
    /// the burst's main sequence.
    private static func ownRandom(_ piece: Piece, salt: UInt64) -> ConfettiRandom {
        ConfettiRandom(seed: UInt64(bitPattern: Int64(piece.phase * 1_000_000)) ^ salt)
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
            let lie = CGAffineTransform(a: 1, b: 0, c: 0, d: landing.lieDepth, tx: 0, ty: 0)
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
            // Rising in from below, a piece shows in full; it fades only as
            // it leaves over the bottom edge.
            let band = stage.height * Self.fallBand
            let leaving = t < piece.apex ? 1 : min(1, max(0, (stage.height - y) / max(1, band)))
            opacity = leaving * airOpacity(piece, at: t)
        case .fade:
            let depth = stage.height * (Self.fadeBand.to - Self.fadeBand.from)
            let dissolve = t < piece.apex ? 0 : ConfettiPhysics.smooth((y - piece.dissolveFrom) / max(1, depth))
            opacity = (1 - dissolve) * airOpacity(piece, at: t)
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
