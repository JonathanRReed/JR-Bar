import AppKit
import JRBarCore
import Observation
import SwiftUI

/// Confetti (docs/TOYS.md): when a provider's *weekly* quota resets — a
/// `quota_reset` event whose `lane` is `"weekly"` or ends `-weekly` — a
/// confetti cannon pops at the notch/Screen Bar centre and rains pieces
/// in that provider's colours down a transparent, click-through overlay,
/// then the window closes. Off by default; Reduce Motion gets a soft
/// radial bloom instead.
@MainActor
@Observable
final class ConfettiToy: Toy {
    /// The owning store; weak, the store keeps the toy.
    weak var store: ToysStore?
    /// The burst in flight, if any. One window at a time.
    @ObservationIgnored private var window: ConfettiWindow?

    init() {}

    let id = "confetti"
    let name = "Confetti"
    let blurb = "A burst in the provider's colours when your weekly limit resets."
    let symbol = "party.popper"

    var isOn: Bool {
        get { store?.state.confetti.enabled ?? false }
        set { store?.state.confetti.enabled = newValue }
    }

    var status: ToyStatus { isOn ? .on : .off }

    var controls: AnyView {
        AnyView(
            LabeledContent {
                Button("Test burst") { [weak self] in
                    self?.testBurst(providerColor: Color(red: 0.93, green: 0.30, blue: 0.62))
                }
            } label: {
                SettingLabel(title: "Try it", subtitle: "Fires a burst now, in the Toys tint.")
            }
        )
    }

    /// `EventCoordinator.apply` asks this before colouring the burst:
    /// true for `quota_reset` on the weekly lane only — five-hour and
    /// session resets stay quiet.
    nonisolated static func isWeeklyReset(_ event: CoreEvent) -> Bool {
        guard event.kind == "quota_reset", let lane = event.lane else { return false }
        return lane == "weekly" || lane.hasSuffix("-weekly")
    }

    /// One burst, or the soft flash under Reduce Motion. A burst already
    /// on screen is replaced — the newest reset wins.
    func fire(providerColor: Color) {
        guard isOn else { return }
        present(providerColor)
    }

    /// The card's "Test burst": an explicit ask, so it fires even while
    /// the toy is off.
    func testBurst(providerColor: Color) {
        present(providerColor)
    }

    private func present(_ color: Color) {
        window?.close()
        window = nil
        let overlay = ConfettiWindow(color: color)
        self.window = overlay
        overlay.burst { [weak self] in
            MainActor.assumeIsolated { self?.window = nil }
        }
    }
}

/// The burst's overlay: a borderless, transparent, click-through window
/// hung across the top of the notched screen at `.screenSaver` level,
/// closed by its own timer. Shares nothing with screen capture
/// (`sharingType = .none`), like the Fold overlay.
@MainActor
private final class ConfettiWindow: NSPanel {
    private let hosting: NSHostingView<ConfettiView>
    private var closer: DispatchWorkItem?

    /// How long a burst runs before the window closes: long enough for
    /// the last fluttering streamer to reach the band's fade-out.
    static let life: TimeInterval = 2.6
    /// The Reduce Motion bloom is shorter — it is one fade, not a burst.
    static let flashLife: TimeInterval = 0.9

    init(color: Color) {
        let reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        hosting = NSHostingView(rootView: ConfettiView(color: color, flash: reduceMotion))
        let screen = ScreenBarGeometry.preferredScreen() ?? NSScreen.main
        let frame = screen?.frame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        // The top band of the screen: deep enough to fall through, narrow
        // enough that the window is never a screen-sized shadow.
        let height = min(frame.height * 0.45, 380)
        super.init(contentRect: NSRect(x: frame.minX, y: frame.maxY - height, width: frame.width, height: height),
                   styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        contentView = hosting
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        ignoresMouseEvents = true
        hidesOnDeactivate = false
        isReleasedWhenClosed = false
        isExcludedFromWindowsMenu = true
        animationBehavior = .none
        isMovable = false
        collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
        level = .screenSaver
        sharingType = .none
        alphaValue = 1
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect { frameRect }

    func burst(then done: @escaping @MainActor () -> Void) {
        orderFrontRegardless()
        let life = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion ? Self.flashLife : Self.life
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated {
                self?.orderOut(nil)
                self?.closer = nil
                done()
            }
        }
        closer = work
        DispatchQueue.main.asyncAfter(deadline: .now() + life + 0.1, execute: work)
    }

    override func close() {
        closer?.cancel()
        closer = nil
        super.close()
    }
}

/// Burst ballistics in closed form: gravity plus quadratic air drag,
/// `dv/dt = −g − (g/vt²)·v|v|` with `vt` the piece's terminal speed.
/// Each axis solves to a plain log/tan expression, so a frame is pure
/// evaluation — nothing is integrated or stored per piece.
enum ConfettiPhysics {
    /// Downward acceleration, pt/s².
    static let gravity: Double = 1100

    /// Seconds from launch to the top of the arc (v hits 0).
    static func apexTime(v0: Double, vt: Double) -> Double {
        (vt / gravity) * atan(v0 / vt)
    }

    /// Height above the launch point `t` seconds in, while still rising:
    /// v = vt·tan(C − g·t/vt) with C = atan(v0/vt), integrated once.
    static func rise(v0: Double, vt: Double, t: Double) -> Double {
        let c = atan(v0 / vt)
        let u = max(0, c - gravity * t / vt)
        return (vt * vt / gravity) * (log(cos(u)) - log(cos(c)))
    }

    /// Total rise at the apex: `(vt²/2g)·ln(1 + (v0/vt)²)`.
    static func apexHeight(v0: Double, vt: Double) -> Double {
        let r = v0 / vt
        return (vt * vt / (2 * gravity)) * log(1 + r * r)
    }

    /// Distance fallen `t` seconds after the apex: v = −vt·tanh(g·t/vt),
    /// which is exactly vt in the limit — the slow flutter.
    static func fall(vt: Double, t: Double) -> Double {
        (vt * vt / gravity) * log(cosh(gravity * t / vt))
    }

    /// Signed horizontal travel `t` seconds in. Drag bleeds the spray
    /// off fast: v = v0 / (1 + (g/vt²)·|v0|·t), integrated once.
    static func travel(v0: Double, vt: Double, t: Double) -> Double {
        let beta = gravity / (vt * vt)
        return (v0 < 0 ? -1 : 1) * (1 / beta) * log(1 + beta * abs(v0) * t)
    }
}

/// What the burst is: a cannon pop at the notch — pieces launch in an
/// up-and-out cone with a few fired sideways, drag & gravity take over,
/// and the survivors tumble & flutter down the band, easing out near the
/// bottom edge — or one soft bloom when Reduce Motion is on. Every
/// piece's constants are fixed at fire time; a frame only evaluates
/// `ConfettiPhysics` and rotates the context.
private struct ConfettiView: View {
    let color: Color
    /// Reduce Motion: a bloom, not a burst.
    let flash: Bool
    /// Provider colour in light & dark steps, plus white & a gold fleck.
    private let palette: [Color]
    private let pieces = ConfettiView.makePieces()

    /// The cannon's muzzle: notch centre, just under the top edge so the
    /// up-cone reads on screen before pieces leave it.
    private static let muzzleY: Double = 30

    private enum Shape { case rect, dot, streamer }

    /// One particle's constants; motion is evaluated, never stored.
    private struct Piece {
        var shape: Shape
        var x: Double        // launch x, as a fraction of the width
        var delay: Double    // stagger inside the pop, seconds
        var vx: Double       // sideways launch speed, pt/s (signed)
        var vy: Double       // upward launch speed, pt/s
        var vt: Double       // terminal flutter speed, pt/s
        var apexT: Double    // seconds to the top of the arc
        var apexH: Double    // height of that arc, pt
        var size: Double
        var shade: Int       // palette slot
        var phase: Double
        var spin: Double     // tumble rate, rad/s
        var twirl: Double    // vertical-axis card spin (the twinkle), rad/s
        var sway: Double     // falling drift amplitude, pt
        var swayRate: Double
    }

    init(color: Color, flash: Bool) {
        self.color = color
        self.flash = flash
        self.palette = [
            color,
            color.mix(with: .white, by: 0.4),
            color.mix(with: .black, by: 0.25),
            .white,
            Color(red: 0.96, green: 0.76, blue: 0.28),  // warm gold fleck
        ]
    }

    var body: some View {
        TimelineView(.animation) { context in
            let elapsed = context.date.timeIntervalSince(origin)
            Canvas { canvas, size in
                if flash {
                    drawBloom(&canvas, size: size, p: min(1, elapsed / ConfettiWindow.flashLife))
                    return
                }
                drawPop(&canvas, size: size, age: elapsed)
                let endFade = min(1, max(0, (ConfettiWindow.life - elapsed) / 0.4))
                guard endFade > 0 else { return }
                for piece in pieces {
                    let age = elapsed - piece.delay
                    guard age > 0 else { continue }
                    // Rise to the apex, then fall from it at vt's mercy.
                    let y = Self.muzzleY - (age <= piece.apexT
                        ? ConfettiPhysics.rise(v0: piece.vy, vt: piece.vt, t: age)
                        : piece.apexH - ConfettiPhysics.fall(vt: piece.vt, t: age - piece.apexT))
                    guard y < size.height + 20 else { continue }
                    // Quadratic-drag spray plus a flutter that ramps in
                    // once the piece is falling.
                    let x = piece.x * size.width
                        + ConfettiPhysics.travel(v0: piece.vx, vt: piece.vt, t: age)
                        + piece.sway * sin(piece.swayRate * age + piece.phase) * min(1, age / 0.5)
                    // Ease out at the band's bottom edge, not a hard cut.
                    let fade = endFade * min(1, max(0, (size.height - y) / 56))
                    guard fade > 0.01 else { continue }
                    let tumble = piece.phase + piece.spin * age
                        + (piece.shape == .streamer ? 0.85 * sin(6.2 * age + piece.phase) : 0)
                    // A card spinning about its vertical axis reads as a
                    // scaleX oscillation — the classic confetti twinkle.
                    // A streamer twists about its long axis instead.
                    let osc = abs(cos(piece.twirl * age + piece.phase))
                    let scaleX = piece.shape == .streamer ? 1 : max(0.16, osc)
                    let scaleY = piece.shape == .streamer ? max(0.25, osc) : 1
                    var c = canvas
                    c.translateBy(x: x, y: y)
                    c.rotate(by: .radians(tumble))
                    c.scaleBy(x: scaleX, y: scaleY)
                    c.fill(path(for: piece), with: .color(palette[piece.shade].opacity(0.95 * fade)))
                }
            }
        }
        .onAppear { origin = Date() }
    }

    /// When the burst started; set on appear so `t = 0` is the pop.
    @ViewState private var origin = Date()

    private func path(for piece: Piece) -> Path {
        let s = piece.size
        switch piece.shape {
        case .rect:
            return Path(CGRect(x: -s / 2, y: -s * 0.3, width: s, height: s * 0.6))
        case .dot:
            return Path(ellipseIn: CGRect(x: -s * 0.28, y: -s * 0.28, width: s * 0.56, height: s * 0.56))
        case .streamer:
            return Path(roundedRect: CGRect(x: -s * 2.4, y: -s * 0.14, width: s * 4.8, height: s * 0.28),
                        cornerRadius: s * 0.14)
        }
    }

    /// The pop: a flash & shockwave at the muzzle, plus one beat of
    /// starburst rays. Gone in ~0.3 s, behind the pieces.
    private func drawPop(_ canvas: inout GraphicsContext, size: CGSize, age: Double) {
        guard age >= 0, age < 0.32 else { return }
        let p = age / 0.32
        let ease = 1 - (1 - p) * (1 - p)
        let muzzle = CGPoint(x: size.width / 2, y: Self.muzzleY)
        canvas.fill(Path(ellipseIn: circle(muzzle, 9 + 26 * ease)),
                    with: .color(color.opacity(0.55 * (1 - p))))
        canvas.stroke(Path(ellipseIn: circle(muzzle, 5 + 52 * ease)),
                      with: .color(color.opacity(0.5 * (1 - p))), lineWidth: 1.6)
        var rays = Path()
        for i in 0..<10 {
            let a = Double(i) * (.pi * 2 / 10) + 0.3
            let r0 = 10 + 18 * ease, r1 = r0 + 30 * ease
            rays.move(to: CGPoint(x: muzzle.x + r0 * cos(a), y: muzzle.y + r0 * sin(a)))
            rays.addLine(to: CGPoint(x: muzzle.x + r1 * cos(a), y: muzzle.y + r1 * sin(a)))
        }
        canvas.stroke(rays, with: .color(.white.opacity(0.8 * (1 - p))), lineWidth: 1.4)
    }

    /// Reduce Motion: a gentle radial bloom of the provider colour at the
    /// notch — the whole cue, no motion.
    private func drawBloom(_ canvas: inout GraphicsContext, size: CGSize, p: Double) {
        guard p < 1 else { return }
        let ease = 1 - (1 - p) * (1 - p)
        let centre = CGPoint(x: size.width / 2, y: Self.muzzleY)
        for i in (0..<3).reversed() {
            let r = 14 + Double(i) * 18 + 110 * ease
            canvas.fill(Path(ellipseIn: circle(centre, r)),
                        with: .color(color.opacity((1 - p) * (0.26 - Double(i) * 0.07))))
        }
    }

    private func circle(_ c: CGPoint, _ r: Double) -> CGRect {
        CGRect(x: c.x - r, y: c.y - r, width: r * 2, height: r * 2)
    }

    private static func makePieces() -> [Piece] {
        var rng = SystemRandomNumberGenerator()
        return (0..<140).map { _ in
            let roll = Double.random(in: 0...1, using: &rng)
            let shape: Shape = roll < 0.55 ? .rect : roll < 0.82 ? .dot : .streamer
            // The cone: most pieces go up & out, a few are sideways spray.
            let spray = Double.random(in: 0...1, using: &rng) < 0.2
            let speed = Double.random(in: 240...640, using: &rng)
            let theta = spray
                ? Double.random(in: 1.2...1.5, using: &rng) * (Bool.random(using: &rng) ? 1 : -1)
                : Double.random(in: -1.05...1.05, using: &rng)
            let vt: Double
            let size: Double
            let sway: Double
            switch shape {
            case .rect:
                vt = Double.random(in: 150...215, using: &rng)
                size = Double.random(in: 5...9, using: &rng)
                sway = Double.random(in: 6...18, using: &rng)
            case .dot:
                vt = Double.random(in: 185...260, using: &rng)
                size = Double.random(in: 4...6.5, using: &rng)
                sway = Double.random(in: 2...6, using: &rng)
            case .streamer:
                vt = Double.random(in: 105...160, using: &rng)
                size = Double.random(in: 5.5...8, using: &rng)
                sway = Double.random(in: 8...20, using: &rng)
            }
            // Provider colour in steps, white, & a few gold flecks.
            let s = Double.random(in: 0...1, using: &rng)
            let shade = s < 0.45 ? 0 : s < 0.65 ? 1 : s < 0.8 ? 2 : s < 0.95 ? 3 : 4
            let sign = Bool.random(using: &rng) ? 1.0 : -1.0
            let vy = speed * cos(theta)
            let piece = Piece(
                shape: shape,
                x: 0.5 + Double.random(in: -0.035...0.035, using: &rng),
                delay: Double.random(in: 0...0.09, using: &rng),
                vx: speed * sin(theta),
                vy: vy,
                vt: vt,
                apexT: ConfettiPhysics.apexTime(v0: vy, vt: vt),
                apexH: ConfettiPhysics.apexHeight(v0: vy, vt: vt),
                size: size,
                shade: shade,
                phase: Double.random(in: 0...(.pi * 2), using: &rng),
                spin: sign * (shape == .streamer
                    ? Double.random(in: 0.6...1.6, using: &rng)
                    : Double.random(in: 1.2...3.6, using: &rng)),
                twirl: shape == .dot ? 0 : Double.random(in: 4...10, using: &rng),
                sway: sway,
                swayRate: Double.random(in: 2...4.4, using: &rng)
            )
            return piece
        }
    }
}
