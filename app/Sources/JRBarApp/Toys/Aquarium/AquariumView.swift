import AppKit
import JRBarCore
import SwiftUI

/// The tank (docs/TOYS.md): one `TimelineView` + `Canvas`. Fish
/// positions are integrated from each `Fish`'s constants and the frame
/// clock, so `toy.fish` only has to change when the session set does,
/// and the timeline pauses while the window is covered.
struct AquariumView: View {
    let toy: AquariumToy
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        // Read the observable surface in `body` so the card's tracked
        // reads stay honest even while the timeline is paused.
        let fish = toy.fish
        let showLabels = toy.store?.state.aquarium.showLabels ?? true
        let density = max(0.1, toy.store?.state.aquarium.density ?? 1)
        TimelineView(.animation(paused: toy.windowOccluded)) { context in
            let t = context.date.timeIntervalSince1970
            Canvas { canvas, size in
                drawWater(canvas: &canvas, size: size)
                drawPlankton(canvas: &canvas, size: size, t: t, density: density)
                drawBubbles(canvas: &canvas, size: size, t: t, density: density)
                for aFish in fish where !aFish.isRetired(at: context.date) {
                    drawFish(canvas: &canvas, size: size, t: t, now: context.date,
                             fish: aFish, showLabels: showLabels)
                }
                if fish.isEmpty || fish.allSatisfy({ $0.isRetired(at: context.date) }) {
                    canvas.draw(
                        Text("Nothing swimming yet")
                            .font(.callout)
                            .foregroundStyle(.white.opacity(0.45)),
                        at: CGPoint(x: size.width / 2, y: size.height / 2))
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(red: 0.02, green: 0.10, blue: 0.24))
    }

    // MARK: Water

    private func drawWater(canvas: inout GraphicsContext, size: CGSize) {
        canvas.fill(
            Path(CGRect(origin: .zero, size: size)),
            with: .linearGradient(
                Gradient(colors: [
                    Color(red: 0.16, green: 0.38, blue: 0.55),
                    Color(red: 0.06, green: 0.22, blue: 0.40),
                    Color(red: 0.02, green: 0.10, blue: 0.24),
                ]),
                startPoint: CGPoint(x: size.width / 2, y: 0),
                endPoint: CGPoint(x: size.width / 2, y: size.height)))
        canvas.fill(Path(CGRect(x: 0, y: 0, width: size.width, height: 1)),
                    with: .color(.white.opacity(0.18)))
    }

    /// Slow flecks drifting with the water. `density` scales the count.
    private func drawPlankton(canvas: inout GraphicsContext, size: CGSize, t: Double, density: Double) {
        let count = Int((24 * density).rounded())
        for i in 0..<count {
            let h = AquariumModel.stableHash("plankton-\(i)")
            let x0 = Double(h & 0xFFFF) / 0xFFFF
            let y0 = Double((h >> 16) & 0xFFFF) / 0xFFFF
            let phase = Double((h >> 32) & 0xFF) / 0xFF * .pi * 2
            let drift = (h >> 40) & 1 == 0 ? 1.0 : -1.0
            let r = 0.8 + Double((h >> 44) & 0xF) / 0xF * 1.4
            let x = frac(x0 + drift * t * 0.006) * size.width
            let y = frac(y0 + 0.02 * sin(t * 0.35 + phase)) * size.height
            canvas.fill(Path(ellipseIn: CGRect(x: x - r, y: y - r, width: r * 2, height: r * 2)),
                        with: .color(.white.opacity(0.16)))
        }
    }

    /// Ambient bubbles rising off the floor; they pop at the surface.
    private func drawBubbles(canvas: inout GraphicsContext, size: CGSize, t: Double, density: Double) {
        let count = Int((7 * density).rounded())
        for i in 0..<count {
            let h = AquariumModel.stableHash("bubble-\(i)")
            let x0 = Double(h & 0xFFFF) / 0xFFFF
            let phase = Double((h >> 16) & 0xFF) / 0xFF * .pi * 2
            let speed = 0.05 + Double((h >> 24) & 0xFF) / 0xFF * 0.05
            let r = 1.5 + Double((h >> 32) & 0xF) / 0xF * 2.5
            let rise = frac(Double((h >> 40) & 0xFF) / 0xFF + t * speed)
            if rise > 0.97 { continue }
            let x = x0 * size.width + sin(t * 1.6 + phase) * 7
            let y = size.height * (1 - rise) - 8
            canvas.stroke(Path(ellipseIn: CGRect(x: x - r, y: y - r, width: r * 2, height: r * 2)),
                          with: .color(.white.opacity(0.35)), lineWidth: 0.8)
        }
    }

    // MARK: Fish

    /// Where a fish is right now: position, which way it faces, how far
    /// through its sink or exit it is.
    private struct Layout {
        var x: Double
        var y: Double
        /// +1 faces right, -1 faces left.
        var facing: Double
        /// Radians in the fish's own frame; positive is nose down.
        var pitch: Double
        var scale: Double
        /// Sink or leave progress, 0...1.
        var progress: Double
    }

    private func layout(of fish: Fish, in size: CGSize, at t: Double, now: Date) -> Layout {
        let h = AquariumModel.stableHash(fish.id)
        // Bits the model did not spend on lane/speed/direction seed the
        // fish's start position and wobble phase.
        let x0 = Double((h >> 33) & 0x3FF) / 0x3FF
        let phase = Double((h >> 43) & 0xFF) / 0xFF * .pi * 2
        let margin = 36.0
        let top = 34.0
        let bottom = size.height - 34.0
        let laneY = top + fish.lane * max(0, bottom - top)
        let scale = 1.05 - fish.lane * 0.3

        // The swim is a triangle wave, so the fish turns at the walls
        // instead of teleporting across the tank.
        func swimX(at time: Double) -> (x: Double, facing: Double) {
            let p = x0 + fish.direction * fish.speed * time
            let m = p - (p / 2).rounded(.down) * 2
            let pos = m <= 1 ? m : 2 - m
            return (margin + pos * max(0, size.width - 2 * margin),
                    (m <= 1 ? 1.0 : -1.0) * fish.direction)
        }

        switch fish.state {
        case .swimming:
            let swim = swimX(at: t)
            return Layout(x: swim.x, y: laneY + sin(t * 1.1 + phase) * 5,
                          facing: swim.facing, pitch: 0, scale: scale, progress: 0)
        case .surfacing:
            let swim = swimX(at: t)
            return Layout(x: swim.x, y: 20 + sin(t * 2.3 + phase) * 4,
                          facing: swim.facing, pitch: 0, scale: scale, progress: 0)
        case .sinking:
            // It stops swimming where it was and drops, nose down.
            let t0 = fish.stateSince.timeIntervalSince1970
            let swim = swimX(at: t0)
            let p = min(1, max(0, now.timeIntervalSince(fish.stateSince) / 2.4))
            let eased = p * p
            return Layout(x: swim.x,
                          y: min(laneY + (size.height - 22 - laneY) * eased, size.height - 22),
                          facing: swim.facing, pitch: 0.45 * eased, scale: scale, progress: p)
        case .leaving:
            // From wherever it was, straight off the right edge.
            let t0 = fish.stateSince.timeIntervalSince1970
            let p = fish.leaveProgress(at: now)
            let start = swimX(at: t0).x
            let x = start + (size.width + margin + 60 - start) * p
            return Layout(x: x, y: laneY + sin(t * 1.1 + phase) * 5 * (1 - p),
                          facing: 1, pitch: 0, scale: scale, progress: p)
        }
    }

    private func drawFish(canvas: inout GraphicsContext, size: CGSize, t: Double, now: Date,
                          fish: Fish, showLabels: Bool) {
        let l = layout(of: fish, in: size, at: t, now: now)
        let h = AquariumModel.stableHash(fish.id)
        let phase = Double((h >> 43) & 0xFF) / 0xFF * .pi * 2
        let length = 46.0 * l.scale
        let height = 20.0 * l.scale
        let color: Color = fish.state == .sinking
            ? Color(nsColor: .secondaryLabelColor)
            : ProviderStyle.style(for: fish.providerID).accent
        let opacity = fish.state == .leaving ? 1 - 0.5 * l.progress : 1.0

        var f = canvas
        f.opacity = opacity
        f.translateBy(x: l.x, y: l.y)
        f.scaleBy(x: l.facing, y: 1)
        if l.pitch != 0 { f.rotate(by: .radians(l.pitch)) }

        // The tail goes down first, behind the body. Reduce Motion
        // stills the wag — the fish glides instead.
        let tailLength = length * 0.32
        let wag = reduceMotion ? 0 : sin(t * (4 + fish.speed * 30) + phase) * height * 0.22
        var tail = Path()
        tail.move(to: CGPoint(x: -length / 2 + 3, y: 0))
        tail.addLine(to: CGPoint(x: -length / 2 - tailLength, y: -height * 0.42 + wag))
        tail.addLine(to: CGPoint(x: -length / 2 - tailLength * 0.72, y: wag * 0.5))
        tail.addLine(to: CGPoint(x: -length / 2 - tailLength, y: height * 0.42 + wag))
        tail.closeSubpath()
        f.fill(tail, with: .color(color.opacity(0.9)))

        f.fill(Path(ellipseIn: CGRect(x: -length / 2, y: -height / 2, width: length, height: height)),
               with: .color(color))

        let eye = CGRect(x: length * 0.26, y: -height * 0.18, width: 3.2, height: 3.2)
        f.fill(Path(ellipseIn: eye), with: .color(.white.opacity(0.95)))
        f.fill(Path(ellipseIn: eye.insetBy(dx: 1, dy: 1)), with: .color(.black.opacity(0.8)))

        // An ask comes up for air: a bubble rides overhead and pops.
        if fish.state == .surfacing {
            let rise = frac(t * 0.45 + phase / (.pi * 2))
            let bx = 6.0 + sin(t * 3 + phase) * 2
            let by = -height / 2 - 6 - rise * 22
            var b = f
            b.opacity = opacity * (1 - rise) * 0.9
            b.stroke(Path(ellipseIn: CGRect(x: bx - 2.6, y: by - 2.6, width: 5.2, height: 5.2)),
                     with: .color(.white), lineWidth: 0.9)
        }

        if showLabels {
            var labelCanvas = canvas
            labelCanvas.opacity = opacity * (fish.state == .sinking ? 0.55 : 0.8)
            labelCanvas.draw(
                Text(fish.label).font(.caption2).foregroundStyle(.white),
                at: CGPoint(x: l.x, y: min(l.y + height / 2 + 11, size.height - 10)))
        }
    }

    private func frac(_ x: Double) -> Double {
        x - x.rounded(.down)
    }
}
