import CoreGraphics
import Foundation
import JRBarCore

/// Where a burst is staged, measured once at fire time in the overlay's
/// own space: the whole screen, top-left origin, y growing down, points.
struct ConfettiStage: Equatable, Sendable {
    var width: Double
    var height: Double
    /// The notch's housing when the screen has one: x across the top of
    /// the screen, y from 0 to its depth.
    var notch: CGRect?
    /// The menu bar's bottom edge.
    var menuBarBottom: Double
    /// JR-Bar's menu-bar icon, when it sits on this screen.
    var icon: CGRect?
    /// The top of the Dock (the visible frame's bottom), or the screen's
    /// bottom edge when the Dock is hidden or on a side.
    var floor: Double
    /// The other apps' windows on this screen, front to back: Rest lands
    /// pieces on their top edges.
    var windows: [CGRect] = []
    /// Where a bottom Dock runs across the screen, when JR-Bar can read
    /// it: Rest lands pieces on the Dock only over it, and on the bottom
    /// edge beside it. nil lets the Dock's top stand for the whole width.
    var dockSpan: ClosedRange<Double>?

    /// The area a burst's piece count is measured against: Jonathan's
    /// MacBook Pro screen, 1512 × 982.
    static let referenceArea = 1512.0 * 982.0

    /// That screen, bare: its notch (663.5–848.5 × 32), a 32-pt menu bar
    /// and no Dock or windows — the card's preview and the tests' stage.
    static let reference = ConfettiStage(width: 1512, height: 982,
                                         notch: CGRect(x: 663.5, y: 0, width: 185, height: 32),
                                         menuBarBottom: 32, icon: nil, floor: 982)

    /// How much bigger than the reference this screen is, as a piece-count
    /// multiplier: √(area ratio), kept to 0.8…1.8 so a 5K display stays
    /// full without costing three laptops' worth of drawing.
    var areaScale: Double {
        min(1.8, max(0.8, (width * height / Self.referenceArea).squareRoot()))
    }
}

/// Where a burst's pieces leave from and how they're thrown. Pure: a
/// stage, an origin and a random source in, launch numbers out — so
/// the tests can fire the same burst every run and the render proofs
/// freeze exactly the frame they name.
enum ConfettiEmitter {
    /// One thrown piece's start: where, how fast (pt/s, y down), how
    /// quickly its spray bleeds off, and when in the burst it leaves.
    struct Launch: Equatable {
        var x: Double
        var y: Double
        var vx: Double
        var vy: Double
        var tau: Double
        var delay: Double
    }

    /// The origin a screen actually fires from: the icon only on the
    /// screen that holds it — every other screen, and a parked icon,
    /// falls back to the notch's lip (or the menu bar's bottom centre).
    static func resolved(_ origin: ConfettiOrigin, on stage: ConfettiStage) -> ConfettiOrigin {
        origin == .icon && stage.icon == nil ? .notch : origin
    }

    /// Where the lip is: just under the notch's lower edge, or the menu
    /// bar's bottom centre on a screen without one.
    static func lip(of stage: ConfettiStage) -> CGRect {
        if let notch = stage.notch {
            return CGRect(x: notch.minX, y: notch.maxY, width: notch.width, height: 0)
        }
        let width = min(200, stage.width * 0.2)
        return CGRect(x: stage.width / 2 - width / 2, y: stage.menuBarBottom, width: width, height: 0)
    }

    /// The points the pieces leave from, for the tests to check the
    /// launches against (the pop draws from `lip(of:)` and the icon's
    /// frame): the lip's two lower corners and its middle, the icon's
    /// bottom centre, the two bottom corners, or none for rain (it has
    /// no cannon).
    static func muzzles(_ origin: ConfettiOrigin, on stage: ConfettiStage) -> [CGPoint] {
        switch resolved(origin, on: stage) {
        case .notch:
            let lip = lip(of: stage)
            let y = lip.minY + 2
            return [CGPoint(x: lip.minX + 5, y: y), CGPoint(x: lip.midX, y: y), CGPoint(x: lip.maxX - 5, y: y)]
        case .icon:
            let icon = stage.icon ?? .zero
            return [CGPoint(x: icon.midX, y: icon.maxY + 2)]
        case .corners:
            return [CGPoint(x: -6, y: stage.height + 8), CGPoint(x: stage.width + 6, y: stage.height + 8)]
        case .rain:
            return []
        }
    }

    /// Which way sound should sit for a burst from here, -1 … 1: centred
    /// for the lip, the corners and the rain; toward the icon for the icon.
    static func pan(_ origin: ConfettiOrigin, on stage: ConfettiStage) -> Double {
        guard resolved(origin, on: stage) == .icon, let icon = stage.icon, stage.width > 0 else { return 0 }
        return max(-1, min(1, (icon.midX / stage.width * 2 - 1) * 0.7))
    }

    /// One piece's launch. The burst is mixed from sub-bursts ("volleys")
    /// with their own spread and reach, the way canvas-confetti's
    /// Realistic preset mixes five — so no hollow cone forms. Reach is a
    /// fraction of the screen, so a wide display gets a wide burst.
    static func launch(_ origin: ConfettiOrigin, on stage: ConfettiStage,
                       using rng: inout some RandomNumberGenerator) -> Launch {
        switch resolved(origin, on: stage) {
        case .notch: return fan(from: lip(of: stage), stage: stage, room: (1, 1), using: &rng)
        case .icon:
            let icon = stage.icon ?? .zero
            let spot = CGRect(x: icon.midX - 4, y: icon.maxY, width: 8, height: 0)
            // Throw toward where the screen is: an icon near the right edge
            // sends most of its pieces left, and further, instead of half
            // of them off the edge.
            let half = max(1, stage.width / 2)
            let room = (left: min(1.5, max(0.25, icon.midX / half)),
                        right: min(1.5, max(0.25, (stage.width - icon.midX) / half)))
            return fan(from: spot, stage: stage, room: room, using: &rng)
        case .corners: return corner(stage, using: &rng)
        case .rain: return rain(stage, using: &rng)
        }
    }

    /// The lip's fan: its two lower corners fire outward, flat and fast,
    /// and a little down; the middle drops softer. Nothing is aimed up
    /// into the notch, so the pop is seen from its first frame.
    /// `room` is how much screen each side has, as a share of half the
    /// width: it sets how many pieces go each way and how far.
    private static func fan(from lip: CGRect, stage: ConfettiStage, room: (left: Double, right: Double),
                            using rng: inout some RandomNumberGenerator) -> Launch {
        let side: Double = Double.random(in: 0..<(room.left + room.right), using: &rng) < room.right ? 1 : -1
        let scale = side > 0 ? room.right : room.left
        let corner = side < 0 ? lip.minX + 5 : lip.maxX - 5
        let roll = Double.random(in: 0..<1, using: &rng)
        var x = corner
        var angle: Double          // from straight down, toward `side`
        var reach: Double          // how far the spray carries, × width
        var tau = Double.random(in: 0.15...0.23, using: &rng)
        var delay = Double.random(in: 0...0.05, using: &rng)
        if roll < 0.32 {
            // The wide volley: flat, a few a touch above level (over the
            // menu bar, never into the notch), the furthest reach.
            angle = Double.random(in: 1.1...1.62, using: &rng)
            reach = Double.random(in: 0.15...0.4, using: &rng)
        } else if roll < 0.62 {
            // The mid volley: out and down.
            angle = Double.random(in: 0.4...1.1, using: &rng)
            reach = Double.random(in: 0.08...0.25, using: &rng)
        } else if roll < 0.84 {
            // The drop: from along the lip, down into the screen — the
            // pieces that lead the shower, so it never falls as one sheet.
            x = lip.midX + Double.random(in: -0.4...0.4, using: &rng) * lip.width
            angle = Double.random(in: 0...0.95, using: &rng)
            reach = Double.random(in: 0.08...0.48, using: &rng) * stage.height / max(1, stage.width)
        } else {
            // The puff: slow pieces that linger near the lip and fill the
            // middle while the rest fly out.
            angle = Double.random(in: 0.25...1.5, using: &rng)
            reach = Double.random(in: 0.015...0.07, using: &rng)
            tau = Double.random(in: 0.2...0.3, using: &rng)
            delay = Double.random(in: 0.03...0.3, using: &rng)
        }
        let aim = side * angle
        let speed = reach * scale * stage.width / tau
        // Level or a little above it at most: a piece never heads up into
        // the notch it came out of.
        return Launch(x: x, y: lip.minY + 2, vx: speed * sin(aim), vy: speed * max(-0.05, cos(aim)),
                      tau: tau, delay: delay)
    }

    /// The Raycast look: a cannon at each bottom corner throwing up and
    /// across, so the two sprays cross over the upper middle.
    private static func corner(_ stage: ConfettiStage, using rng: inout some RandomNumberGenerator) -> Launch {
        let side: Double = Bool.random(using: &rng) ? 1 : -1   // 1: the left cannon, throwing right
        let tau = Double.random(in: 0.3...0.44, using: &rng)
        let across = Double.random(in: 0.06...0.52, using: &rng) * stage.width
        let up = Double.random(in: 0.55...0.98, using: &rng) * stage.height
        return Launch(x: side > 0 ? -6 : stage.width + 6, y: stage.height + 8,
                      vx: side * across / tau, vy: -up / tau, tau: tau,
                      delay: Double.random(in: 0...0.08, using: &rng))
    }

    /// The Messages look, and the calmest: a curtain born along the whole
    /// top edge just under the menu bar, so it never crosses the menu
    /// bar's items or the notch. Each piece starts almost still, fades in
    /// over its first beat (`ConfettiBurst.rainFadeIn`) and falls at a
    /// gentle drift; the first are in view at once and the rest keep
    /// coming for about a second.
    private static func rain(_ stage: ConfettiStage, using rng: inout some RandomNumberGenerator) -> Launch {
        Launch(x: Double.random(in: 0...stage.width, using: &rng),
               y: stage.menuBarBottom + Double.random(in: 6...16, using: &rng),
               vx: Double.random(in: -30...30, using: &rng), vy: Double.random(in: 30...90, using: &rng),
               tau: 0.4, delay: Double.random(in: 0...0.9, using: &rng))
    }
}

/// A seeded random source (SplitMix64), so a burst fired with the same
/// seed is the same burst — the tests and render proofs rely on it.
struct ConfettiRandom: RandomNumberGenerator {
    private var state: UInt64

    init(seed: UInt64) { state = seed }

    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}
