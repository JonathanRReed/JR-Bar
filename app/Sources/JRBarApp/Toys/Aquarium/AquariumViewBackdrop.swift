import AppKit
import JRBarCore
import SwiftUI

/// The back wall's backdrop.
extension AquariumView {
    // MARK: Backdrop

    /// The back wall an owned backdrop item papers over the tank
    /// (docs/TOYS.md shop): "classic" leaves the open water, reefwall
    /// hangs a dim rock face with coral nubs behind the dunes, rocky
    /// stacks boulders along the back. Drawn on the still bed, dimmed
    /// into the water so it reads as metres away.
    func drawBackdrop(canvas: inout GraphicsContext, size: CGSize) {
        // Rock & sponge tones pulled toward the water's floor colour
        // so the wall recedes with the theme instead of floating on it.
        func tinted(_ r: Double, _ g: Double, _ b: Double,
                    _ toward: Double, _ alpha: Double) -> Color {
            let base = NSColor(Color(red: r, green: g, blue: b))
            return Color(nsColor: base.blended(withFraction: toward,
                                               of: floorNS) ?? base)
                .opacity(alpha)
        }
        // The wall's rumpled crest, ~40% up the tank — above the
        // seeded kelp line so the wall reads behind everything.
        func wallTop(atX x: Double) -> Double {
            let u = x / max(1, size.width)
            return size.height * 0.58
                + size.height * 0.035 * sin(u * .pi * 5.2 + Self.dunePhase2)
                + size.height * 0.014 * sin(u * .pi * 13.7 + Self.dunePhase1)
        }
        switch backdropKey {
        case "reefwall":
            var wall = Path()
            wall.move(to: CGPoint(x: 0, y: wallTop(atX: 0)))
            var x = 0.0
            while x <= size.width {
                wall.addLine(to: CGPoint(x: x, y: wallTop(atX: x)))
                x += 10
            }
            wall.addLine(to: CGPoint(x: size.width, y: size.height))
            wall.addLine(to: CGPoint(x: 0, y: size.height))
            wall.closeSubpath()
            canvas.fill(wall, with: .linearGradient(
                Gradient(stops: [
                    .init(color: tinted(0.30, 0.36, 0.40, 0.35, 0.9), location: 0),
                    .init(color: tinted(0.18, 0.23, 0.27, 0.45, 1), location: 0.45),
                    .init(color: tinted(0.06, 0.08, 0.11, 0.6, 1), location: 1),
                ]),
                startPoint: CGPoint(x: 0, y: size.height * 0.56),
                endPoint: CGPoint(x: 0, y: size.height)))
            // The crest's fade into the water above it.
            canvas.stroke(wall, with: .color(tinted(0.45, 0.52, 0.55, 0.3, 0.25)),
                          lineWidth: 1.2)
            // Rock plates: seeded courses of uneven slabs, darker
            // joints between them — a wall, not a hill.
            for row in 0..<3 {
                var px = -20.0
                var i = 0
                let rowTop = size.height * (0.60 + Double(row) * 0.13)
                while px < size.width + 20 {
                    var h = AquariumModel.stableHash("plate-\(row)-\(i)")
                    h ^= h >> 33; h &*= 0xff51afd7ed558ccd; h ^= h >> 33
                    let pw = size.height * (0.10 + Double(h & 0xFF) / 0xFF * 0.09)
                    let ph = size.height * (0.10 + Double((h >> 8) & 0xFF) / 0xFF * 0.05)
                    let py = rowTop + Double((h >> 16) & 0x3F) / 0x3F * size.height * 0.05
                    let tone = 0.20 + Double((h >> 24) & 0xFF) / 0xFF * 0.10
                    canvas.fill(Path(roundedRect: CGRect(x: px, y: py,
                                                         width: pw, height: ph),
                                     cornerRadius: ph * 0.30),
                                with: .color(tinted(tone + 0.10, tone + 0.15,
                                                    tone + 0.18, 0.4, 0.9)))
                    canvas.stroke(Path(roundedRect: CGRect(x: px, y: py,
                                                           width: pw, height: ph),
                                       cornerRadius: ph * 0.30),
                                  with: .color(tinted(0.02, 0.03, 0.05, 0.5, 0.55)),
                                  lineWidth: 1.4)
                    px += pw * (0.82 + Double((h >> 20) & 0xF) / 0xF * 0.25)
                    i += 1
                }
            }
            // Dressing: coral nubs on some plates, a few sponge
            // blobs rising off the face.
            for i in 0..<14 {
                var h = AquariumModel.stableHash("reefdress-\(i)")
                h ^= h >> 33; h &*= 0xff51afd7ed558ccd; h ^= h >> 33
                let rx = size.width * Double(h & 0xFFFF) / 0xFFFF
                let ry = wallTop(atX: rx) + size.height * 0.04
                    + Double((h >> 16) & 0xFFFF) / 0xFFFF * size.height * 0.30
                if (h >> 32) & 3 == 0 {
                    // A sponge: a small stalked blob, teal or purple.
                    let sh = size.height * 0.018
                    let spongeColor = (h >> 36) & 1 == 0
                        ? tinted(0.30, 0.55, 0.50, 0.3, 0.85)
                        : tinted(0.45, 0.35, 0.60, 0.3, 0.85)
                    canvas.fill(Path(ellipseIn: CGRect(x: rx - sh * 0.5,
                                                       y: ry - sh * 1.8,
                                                       width: sh, height: sh * 1.8)),
                                with: .color(spongeColor))
                    canvas.fill(Path(ellipseIn: CGRect(x: rx - sh * 0.18,
                                                       y: ry - sh * 1.9,
                                                       width: sh * 0.36,
                                                       height: sh * 0.36)),
                                with: .color(tinted(0.05, 0.07, 0.09, 0.5, 0.7)))
                } else if (h >> 32) & 3 == 1 {
                    // A coral nub: a warm dot cluster.
                    let nr = size.height * 0.010
                    canvas.fill(Path(ellipseIn: CGRect(x: rx - nr, y: ry - nr,
                                                       width: nr * 2, height: nr * 2)),
                                with: .color(tinted(0.78, 0.45, 0.48, 0.25, 0.8)))
                    canvas.fill(Path(ellipseIn: CGRect(x: rx + nr * 0.6,
                                                       y: ry - nr * 0.4,
                                                       width: nr * 1.2,
                                                       height: nr * 1.2)),
                                with: .color(tinted(0.70, 0.38, 0.42, 0.3, 0.7)))
                }
            }
        case "rocky":
            // Stacked boulders: a tall back course under the crest,
            // a nearer course overlapping its feet — dark joints
            // between stones, dimming with depth like the wall.
            for row in 0..<2 {
                var bx = -30.0
                var i = 0
                let baseY = size.height * (row == 0 ? 0.92 : 0.99)
                while bx < size.width + 30 {
                    var h = AquariumModel.stableHash("boulder-\(row)-\(i)")
                    h ^= h >> 33; h &*= 0xff51afd7ed558ccd; h ^= h >> 33
                    let bw = size.height * (0.16 + Double(h & 0xFF) / 0xFF * 0.12)
                    let bh = bw * (0.55 + Double((h >> 8) & 0xFF) / 0xFF * 0.28)
                    let by = baseY + Double((h >> 16) & 0x3F) / 0x3F * size.height * 0.03
                    let tone = row == 0 ? 0.30 : 0.22
                    var boulder = Path()
                    boulder.move(to: CGPoint(x: bx, y: by))
                    boulder.addCurve(to: CGPoint(x: bx + bw, y: by),
                                     control1: CGPoint(x: bx, y: by - bh * 1.5),
                                     control2: CGPoint(x: bx + bw, y: by - bh * 1.5))
                    boulder.closeSubpath()
                    canvas.fill(boulder, with: .linearGradient(
                        Gradient(colors: [tinted(tone + 0.12, tone + 0.13,
                                                 tone + 0.16, 0.4, 0.95),
                                          tinted(tone * 0.3, tone * 0.3,
                                                 tone * 0.35, 0.5, 1)]),
                        startPoint: CGPoint(x: bx + bw / 2, y: by - bh),
                        endPoint: CGPoint(x: bx + bw / 2, y: by)))
                    canvas.stroke(boulder,
                                  with: .color(tinted(0.02, 0.03, 0.04, 0.5, 0.5)),
                                  lineWidth: 1.2)
                    bx += bw * (0.80 + Double((h >> 20) & 0xF) / 0xF * 0.3)
                    i += 1
                }
            }
        default:
            break
        }
    }
}
