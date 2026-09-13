import AppKit
import JRBarCore
import Observation
import SwiftUI

/// Confetti (docs/TOYS.md): when a provider's *weekly* quota resets — a
/// `quota_reset` event whose `lane` is `"weekly"` or ends `-weekly` — a
/// short burst in that provider's colours falls from the notch/Screen
/// Bar area in a transparent, click-through overlay, then the window
/// closes. Off by default; Reduce Motion gets one soft flash instead.
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

    /// How long a burst runs before the window closes.
    static let life: TimeInterval = 1.5
    /// The Reduce Motion flash is shorter — it is one fade, not a fall.
    static let flashLife: TimeInterval = 0.6

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

/// What the burst is: pieces falling from the top edge, or one soft
/// flash when Reduce Motion is on. Particle layout is decided once at
/// fire time so the Canvas only has to integrate positions.
private struct ConfettiView: View {
    let color: Color
    /// Reduce Motion: a flash, not a fall.
    let flash: Bool
    private let pieces = ConfettiView.makePieces()

    /// One particle's constants; position is integrated per frame.
    private struct Piece {
        var x: CGFloat      // spawn x, as a fraction of the width
        var delay: Double   // staggered start, seconds
        var fall: CGFloat   // fall speed, pt/s
        var drift: CGFloat  // sideways wobble, pt
        var size: CGFloat
        var round: Bool
        var shade: Double   // palette slot
        var spin: Double
    }

    var body: some View {
        TimelineView(.animation) { context in
            let t = context.date.timeIntervalSince1970
            Canvas { canvas, size in
                if flash {
                    // One soft band of colour that fades — the whole cue
                    // in a single still shape.
                    let fade = max(0, 1 - (t - origin.timeIntervalSince1970) / ConfettiWindow.flashLife)
                    let band = CGRect(x: size.width / 2 - 160, y: 0, width: 320, height: 26)
                    canvas.fill(Path(roundedRect: band, cornerRadius: 13), with: .color(color.opacity(0.35 * fade)))
                    return
                }
                let elapsed = t - origin.timeIntervalSince1970
                for piece in pieces {
                    let age = elapsed - piece.delay
                    guard age > 0 else { continue }
                    let x = piece.x * size.width + sin(age * 3 + piece.spin) * piece.drift
                    let y = -10 + CGFloat(age) * piece.fall
                    guard y < size.height + 12 else { continue }
                    let fade = min(1, max(0, (ConfettiWindow.life - elapsed) / 0.4))
                    // A spun rect is not a CGRect: rotate a copy of the
                    // context and draw the piece centred on the origin.
                    var pieceCanvas = canvas
                    pieceCanvas.translateBy(x: x, y: y)
                    pieceCanvas.rotate(by: .radians(piece.spin + age * 2.4))
                    let rect = CGRect(x: -piece.size / 2, y: -piece.size * 0.275,
                                      width: piece.size, height: piece.size * 0.55)
                    pieceCanvas.fill(piece.round ? Path(ellipseIn: rect) : Path(rect),
                                     with: .color(palette(piece.shade).opacity(0.9 * fade)))
                }
            }
        }
        .onAppear { origin = Date() }
    }

    /// When the burst started; set on appear so `t = 0` is the pop.
    @ViewState private var origin = Date()

    /// Provider colour plus two tints of it and a light fleck.
    private func palette(_ slot: Double) -> Color {
        switch slot {
        case ..<0.5: return color
        case ..<0.75: return color.opacity(0.65)
        case ..<0.9: return .white
        default: return color
        }
    }

    private static func makePieces() -> [Piece] {
        var pieces: [Piece] = []
        var rng = SystemRandomNumberGenerator()
        for _ in 0..<64 {
            pieces.append(Piece(
                // Spawned across the notch area, not the whole screen.
                x: 0.5 + CGFloat.random(in: -0.16...0.16, using: &rng),
                delay: Double.random(in: 0...0.15, using: &rng),
                fall: CGFloat.random(in: 210...330, using: &rng),
                drift: CGFloat.random(in: 8...26, using: &rng),
                size: CGFloat.random(in: 4...8, using: &rng),
                round: Bool.random(using: &rng),
                shade: Double.random(in: 0...1, using: &rng),
                spin: Double.random(in: 0...(.pi * 2), using: &rng)
            ))
        }
        return pieces
    }
}
