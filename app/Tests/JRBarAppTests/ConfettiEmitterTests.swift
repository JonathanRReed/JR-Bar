import CoreGraphics
import Foundation
import Testing
import JRBarCore
@testable import JRBarApp

/// Where the burst comes from, how wide it goes, how long it lives and
/// where it lands — on the real geometry of Jonathan's MacBook Pro (a
/// 1512 × 982 screen, the notch 663.5–848.5 × 32) and on the displays
/// he might plug in.
@Suite("Confetti emitter")
struct ConfettiEmitterTests {
    private static let notch = CGRect(x: 663.5, y: 0, width: 185, height: 32)

    private static func laptop(windows: [CGRect] = [], icon: CGRect? = nil, height: Double = 982) -> ConfettiStage {
        ConfettiStage(width: 1512, height: height, notch: notch, menuBarBottom: 32, icon: icon,
                      floor: height - 70, windows: windows)
    }

    private static func display(_ width: Double, _ height: Double) -> ConfettiStage {
        ConfettiStage(width: width, height: height, notch: nil, menuBarBottom: 24, icon: nil,
                      floor: height - 70)
    }

    // MARK: Seen from the first frame

    /// The old cannon sat inside the notch, so the pop and its first
    /// ~0.3 s were drawn into a hole. Now at 0.15 s at least 80 % of the
    /// launched pieces are out where they can be seen, and no muzzle is
    /// inside the housing.
    @Test("the notch burst is out of the notch by 0.15 s", arguments: ConfettiOrigin.allCases)
    func visibleFromTheStart(_ origin: ConfettiOrigin) {
        let stage = Self.laptop(icon: CGRect(x: 1270, y: 4, width: 26, height: 24))
        for muzzle in ConfettiEmitter.muzzles(origin, on: stage) {
            #expect(!Self.notch.contains(muzzle), "\(origin) fires from \(muzzle), inside the notch")
        }
        var launched = 0
        var hidden = 0
        for seed in 0..<20 {
            let burst = ConfettiBurst(stage: stage, recipe: .init(origin: origin), seed: UInt64(seed))
            for index in burst.pieces.indices {
                guard let frame = burst.frame(of: index, at: 0.15) else { continue }
                launched += 1
                if Self.notch.contains(CGPoint(x: frame.x, y: frame.y)) { hidden += 1 }
            }
        }
        #expect(launched > 0)
        #expect(Double(hidden) <= Double(launched) * 0.2, "\(hidden) of \(launched) hidden in the notch")
    }

    // MARK: Wide

    /// A celebration, not a puff: at 1 s the middle 90 % of the pieces
    /// span at least 45 % of the screen's width, on a laptop, a 1080p
    /// display and an ultrawide alike.
    @Test("the burst spreads across the screen", arguments: [1512.0, 1920, 3440])
    func spread(_ width: Double) {
        let stage = width == 1512 ? Self.laptop() : Self.display(width, width == 1920 ? 1080 : 1440)
        for seed in 0..<20 {
            let burst = ConfettiBurst(stage: stage, recipe: .init(origin: .notch, landing: .fall),
                                      seed: UInt64(seed))
            let xs = burst.pieces.indices.compactMap { burst.frame(of: $0, at: 1.0)?.x }.sorted()
            let low = xs[Int(Double(xs.count - 1) * 0.05)]
            let high = xs[Int(Double(xs.count - 1) * 0.95)]
            #expect((high - low) / width >= 0.45, "seed \(seed): \(Int((high - low) / width * 100)) % of \(Int(width))")
        }
    }

    /// Shapes don't sort themselves into layers as they fall: every pair
    /// of shapes' flutter speeds overlaps by at least 30 %.
    @Test("flutter speeds overlap across shapes")
    func noStratification() {
        let burst = ConfettiBurst(stage: Self.laptop(), recipe: .init(landing: .fade, glyphs: 1), seed: 4)
        var ranges: [ConfettiPieceShape: ClosedRange<Double>] = [:]
        for piece in burst.pieces where !piece.far {
            let old = ranges[piece.shape]
            ranges[piece.shape] = min(old?.lowerBound ?? piece.vt, piece.vt)...max(old?.upperBound ?? piece.vt, piece.vt)
        }
        let shapes = Array(ranges.keys)
        #expect(shapes.count >= 4)
        for a in shapes {
            for b in shapes where a != b {
                let x = ranges[a] ?? 0...0, y = ranges[b] ?? 0...0
                let overlap = min(x.upperBound, y.upperBound) - max(x.lowerBound, y.lowerBound)
                let shorter = min(x.upperBound - x.lowerBound, y.upperBound - y.lowerBound)
                #expect(overlap >= 0.3 * shorter, "\(a) \(x) and \(b) \(y) barely overlap")
            }
        }
    }

    // MARK: Short

    /// A Standard burst is done inside 5 s in every landing on every
    /// screen height he's likely to meet — Jonathan's Fall mode included,
    /// which used to drizzle for 9.6 s — and Fall is done in 4.5 s.
    @Test("a Standard burst lives five seconds at most", arguments: [900.0, 982, 1117, 1329])
    func lifeIsBounded(_ height: Double) {
        for landing in ConfettiLanding.allCases {
            for origin in ConfettiOrigin.allCases {
                for seed in 0..<4 {
                    let burst = ConfettiBurst(stage: Self.laptop(icon: CGRect(x: 1270, y: 4, width: 26, height: 24),
                                                                  height: height),
                                              recipe: .init(origin: origin, landing: landing), seed: UInt64(seed))
                    #expect(burst.life <= 5.0, "\(landing)/\(origin) on \(Int(height)): \(burst.life) s")
                    if landing == .fall { #expect(burst.life <= 4.5) }
                    for index in burst.pieces.indices {
                        #expect(burst.frame(of: index, at: burst.life) == nil, "every piece is gone at the end")
                    }
                }
            }
        }
    }

    // MARK: Rest

    /// Rest lands every piece on something real: a window's top edge,
    /// else the Dock's top — never a line in the middle of the screen.
    @Test("Rest pieces all end on a ledge or the floor")
    func restEndsOnSurfaces() {
        let windows = [CGRect(x: 120, y: 260, width: 640, height: 520), CGRect(x: 820, y: 420, width: 560, height: 420)]
        let stage = Self.laptop(windows: windows)
        let burst = ConfettiBurst(stage: stage, recipe: .init(landing: .rest), seed: 8)
        #expect(burst.ledges == windows)
        var onWindows = 0
        for piece in burst.pieces {
            guard let landing = piece.landing else {
                Issue.record("a Rest piece with nowhere to land")
                continue
            }
            if let window = landing.window {
                let top = Double(windows[window].minY)
                #expect(abs(landing.y - top) < 0.001, "lies on window \(window)'s top edge")
                onWindows += 1
            } else {
                #expect(landing.y == stage.floor - 1 || landing.y == stage.height - 1)
            }
        }
        #expect(onWindows > burst.pieces.count / 3, "most of the burst lands on the two windows")
    }

    /// An edge shows where the window is, unless a window in front of it
    /// covers it there.
    @Test("an edge shows only where no window in front covers it")
    func edgesThatShow() {
        let front = CGRect(x: 100, y: 300, width: 500, height: 400)
        let behind = CGRect(x: 200, y: 400, width: 800, height: 300)   // its edge is hidden at x 300
        let windows = [front, behind]
        #expect(ConfettiBurst.edgeShows(0, at: 300, in: windows))
        #expect(!ConfettiBurst.edgeShows(1, at: 300, in: windows), "the front window covers it")
        #expect(ConfettiBurst.edgeShows(1, at: 800, in: windows), "right of the front window it's open")
        #expect(!ConfettiBurst.edgeShows(0, at: 700, in: windows), "past the end of the edge")
    }

    /// A maximised window is no ledge, but it still hides every edge
    /// behind it: nothing lies across the middle of its content.
    @Test("a maximised window hides the edges behind it")
    func maximisedWindowHides() {
        let windows = [CGRect(x: 0, y: 38, width: 1512, height: 944), CGRect(x: 200, y: 300, width: 800, height: 500)]
        let stage = Self.laptop(windows: windows)
        #expect(ConfettiBurst.ledgeOrder(from: stage) == [1], "only the window behind could hold a piece")
        #expect(!ConfettiBurst.edgeShows(1, at: 500, in: windows))
        for seed in 0..<6 {
            let burst = ConfettiBurst(stage: stage, recipe: .init(landing: .rest), seed: UInt64(seed))
            for piece in burst.pieces {
                #expect(piece.landing?.window == nil, "a piece on the hidden edge at \(piece.landing?.x ?? 0)")
                #expect(piece.landing?.y == stage.floor - 1)
            }
        }
    }

    /// A piece lies on the part of an edge it is over when it comes down
    /// to it — never in the air past the end of a window's top.
    @Test("a Rest piece lies within its window's edge")
    func liesOnItsEdge() {
        let windows = [CGRect(x: 120, y: 260, width: 640, height: 520), CGRect(x: 820, y: 420, width: 560, height: 420),
                       CGRect(x: 500, y: 180, width: 300, height: 200)]
        let stage = Self.laptop(windows: windows)
        var onWindows = 0
        for seed in 0..<12 {
            let burst = ConfettiBurst(stage: stage, recipe: .init(landing: .rest), seed: UInt64(seed))
            for piece in burst.pieces {
                guard let landing = piece.landing, let window = landing.window else { continue }
                onWindows += 1
                let ledge = burst.ledges[window]
                #expect(ledge.minX <= landing.x && landing.x <= ledge.maxX,
                        "lies at \(landing.x) on an edge from \(ledge.minX) to \(ledge.maxX)")
                #expect(ConfettiBurst.edgeShows(burst.ledgeOrder[window], at: landing.x, in: windows))
                #expect(abs(ConfettiBurst.x(of: piece, at: landing.t) - landing.x) < 0.001,
                        "touches down where it was flying")
            }
        }
        #expect(onWindows > 0)
    }

    /// Beside a Dock that doesn't span the screen, pieces fall to the
    /// bottom edge; over it, they land on its top.
    @Test("Rest lands on the Dock only where the Dock is")
    func dockSpan() {
        var stage = Self.laptop()
        stage.dockSpan = 378...1134
        for seed in 0..<6 {
            let burst = ConfettiBurst(stage: stage, recipe: .init(landing: .rest), seed: UInt64(seed))
            for piece in burst.pieces {
                guard let landing = piece.landing else { continue }
                if landing.y == stage.floor - 1 {
                    #expect((378...1134).contains(landing.x), "on the Dock's top at \(landing.x), beside it")
                } else {
                    // Beside the Dock when it came down past its top; its
                    // sway may carry it a little way in front of the end.
                    #expect(landing.y == stage.height - 1)
                    let inside = (378 + piece.sway + 2)...(1134 - piece.sway - 2)
                    #expect(!inside.contains(landing.x), "on the bottom edge at \(landing.x), under the Dock")
                }
            }
        }
        // Tiles along this screen's bottom give a span; a hidden Dock's
        // (parked just below the screen) and a Dock-less screen give none.
        let tiles = CGRect(x: 400, y: 918, width: 712, height: 58)
        #expect(ConfettiToy.dockSpan(tiles, on: Self.laptop()) == 394...1118)
        #expect(ConfettiToy.dockSpan(CGRect(x: 31, y: 982, width: 1450, height: 52), on: Self.laptop()) == nil)
        var bare = Self.display(1920, 1080)
        bare.floor = 1080
        #expect(ConfettiToy.dockSpan(tiles, on: bare) == nil)
    }

    /// A window that moved or closed takes its ledge with it; a piece
    /// lying there fades.
    @Test("a moved window's ledge no longer stands")
    @MainActor func ledgesThatMove() {
        let ledges = [CGRect(x: 100, y: 300, width: 500, height: 400), CGRect(x: 700, y: 200, width: 300, height: 300)]
        let now = [CGRect(x: 102, y: 301, width: 499, height: 400)]
        #expect(ConfettiBurst.standing(ledges, now: now) == [true, false])
        let watch = ConfettiLedgeWatch()
        watch.note(standing: [true, false], at: 1.5)
        watch.note(standing: [true, false], at: 2.5)
        #expect(watch.gone == [1: 1.5], "remembered from when it was first seen gone")
    }

    /// A maximised window's edge right under the menu bar is no ledge —
    /// it would catch the pop the instant it left the lip.
    @Test("an edge under the menu bar is no ledge")
    func noLedgeUnderTheBar() {
        let stage = Self.laptop(windows: [CGRect(x: 0, y: 32, width: 1512, height: 880),
                                          CGRect(x: 10, y: 300, width: 40, height: 100)])
        #expect(ConfettiBurst.ledgeOrder(from: stage).isEmpty, "too high, and too narrow")
    }

    // MARK: Origins

    /// The icon origin fires from under the icon on the screen that has
    /// it; every other screen, and a parked icon, uses the notch.
    @Test("the icon fires from its own screen; others use the notch")
    func iconOrigin() {
        let icon = CGRect(x: 1270, y: 4, width: 26, height: 24)
        let withIcon = Self.laptop(icon: icon)
        #expect(ConfettiEmitter.resolved(.icon, on: withIcon) == .icon)
        #expect(ConfettiEmitter.muzzles(.icon, on: withIcon) == [CGPoint(x: icon.midX, y: icon.maxY + 2)])
        let other = Self.display(1920, 1080)
        #expect(ConfettiEmitter.resolved(.icon, on: other) == .notch)
        #expect(ConfettiEmitter.pan(.icon, on: withIcon) > 0.3, "the pop sits toward the icon")
        #expect(ConfettiEmitter.pan(.notch, on: withIcon) == 0)
    }

    /// Without a notch, the lip is the menu bar's bottom centre.
    @Test("a notchless screen fires from the menu bar's bottom centre")
    func notchless() {
        let stage = Self.display(1920, 1080)
        let muzzles = ConfettiEmitter.muzzles(.notch, on: stage)
        #expect(muzzles.count == 3)
        #expect(muzzles.allSatisfy { $0.y == 26 })
        #expect(abs(muzzles[1].x - 960) < 0.001)
        let burst = ConfettiBurst(stage: stage, recipe: .init(origin: .notch), seed: 1)
        #expect(burst.pieces.allSatisfy { abs($0.launch.y - 26) < 0.001 })
    }

    /// The corners fire up from the bottom corners; rain has no cannon.
    @Test("corners and rain")
    func cornersAndRain() {
        let stage = Self.laptop()
        let corners = ConfettiBurst(stage: stage, recipe: .init(origin: .corners), seed: 1)
        #expect(corners.pieces.allSatisfy { $0.launch.vy < 0 && $0.launch.y > stage.height })
        #expect(ConfettiEmitter.muzzles(.rain, on: stage).isEmpty)
        let rain = ConfettiBurst(stage: stage, recipe: .init(origin: .rain), seed: 1)
        #expect(rain.pieces.allSatisfy { $0.launch.y < 0 })
    }
}
