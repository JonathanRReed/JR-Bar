import AppKit
import JRBarCore
import SwiftUI

/// The tank's events and its stations.
extension AquariumView {
    // MARK: Events

    /// The buried treasure (docs/TOYS.md shop): a chest lid half out
    /// of the sand at its seeded spot, a glint climbing off it every
    /// few seconds. Its hitbox feeds `motion.treasureBox`; the tap
    /// digs, three digs open it.
    func drawTreasure(canvas: inout GraphicsContext, size: CGSize,
                              t: Double, now: Date) {
        guard let treasure = game?.treasure else {
            motion.treasureBox = nil
            return
        }
        let x = treasure.x * size.width
        let baseY = sandTop(atX: x, in: size) + 2
        var c = canvas
        c.translateBy(x: x, y: baseY)
        // The lid's arc peeking out of the dune, brass band catching.
        var lid = Path()
        lid.move(to: CGPoint(x: -12, y: 0))
        lid.addQuadCurve(to: CGPoint(x: 12, y: 0), control: CGPoint(x: 0, y: -16))
        lid.closeSubpath()
        c.fill(lid, with: .color(Color(red: 0.42, green: 0.27, blue: 0.13)))
        c.stroke(lid, with: .color(.black.opacity(0.3)), lineWidth: 0.8)
        c.fill(Path(CGRect(x: -2, y: -10, width: 4, height: 7)),
               with: .color(Color(red: 0.85, green: 0.70, blue: 0.30)))
        // Sand drifted over the foot.
        c.fill(Path(ellipseIn: CGRect(x: -14, y: -2, width: 28, height: 5)),
               with: .color(sandTones.frontB.opacity(0.9)))
        // The glint: a four-point star rising every ~3.5 s — seeded off
        // the treasure's own id so two treasures never sync.
        let sparklePhase = frac(t / 3.5 + Double(AquariumModel.stableHash(treasure.id) & 0xFF) / 0xFF)
        if sparklePhase < 0.4 && !reduceMotion {
            let k = sparklePhase / 0.4
            var s = canvas
            s.blendMode = .plusLighter
            s.opacity = sin(k * .pi) * 0.9
            s.translateBy(x: x + sin(k * 5) * 3, y: baseY - 10 - k * 26)
            let r = 3 + k * 4
            s.scaleBy(x: r, y: r)
            s.fill(Self.starPath, with: .color(Color(red: 1.0, green: 0.9,
                                                     blue: 0.5)))
        }
        motion.treasureBox = (treasure.id,
                              CGRect(x: x - 20, y: baseY - 22, width: 40, height: 28))
    }

    /// The third dig's payoff: a pop of gold where the lid opened,
    /// pearls & sparks thrown on seeded arcs.
    func drawGoldBursts(canvas: inout GraphicsContext, size: CGSize,
                                now: Date) {
        for burst in motion.goldBursts {
            let p = clamp01(now.timeIntervalSince(burst.bornAt) / 1.1)
            guard p < 1 else { continue }
            for i in 0..<10 {
                var h = AquariumModel.stableHash("gold-\(i)")
                h ^= h >> 33; h &*= 0xff51afd7ed558ccd; h ^= h >> 33
                let a = Double(h & 0xFF) / 0xFF * .pi - .pi * 0.95
                let dist = (18 + Double((h >> 8) & 0xFF) / 0xFF * 44) * p
                let gx = burst.x.x + cos(a) * dist
                let gy = burst.x.y + sin(a) * dist + p * p * 30
                var s = canvas
                s.blendMode = .plusLighter
                s.opacity = (1 - p) * 0.9
                let r = 2 + Double((h >> 16) & 0x3)
                s.fill(Path(ellipseIn: CGRect(x: gx - r, y: gy - r,
                                              width: r * 2, height: r * 2)),
                       with: .color(Color(red: 1.0, green: 0.85, blue: 0.40)))
            }
        }
    }

    /// The bubble-ring trick: a tapped fish blows a ring that swells
    /// and climbs — the puff's bigger cousin.
    func drawTrickRings(canvas: inout GraphicsContext, size: CGSize,
                                layouts: [String: Layout], now: Date) {
        for (id, trick) in motion.tricks where trick.kind == .ring {
            guard now < trick.until, let l = layouts[id] else { continue }
            let p = clamp01(1 - trick.until.timeIntervalSince(now)
                            / AquariumBehavior.trickDuration)
            let r = 4 + p * 20
            var c = canvas
            c.opacity = (1 - p) * 0.8
            c.stroke(Path(ellipseIn: CGRect(x: l.x - r, y: l.y - 14 - p * 30 - r,
                                            width: r * 2, height: r * 2)),
                     with: .color(.white), lineWidth: 1.6)
        }
    }

    /// The visitor parade (docs/TOYS.md shop): a queued passer-by
    /// crosses the back layer once — a whale's great dim silhouette
    /// spouting if it nears the surface, a diver's torch sweeping, a
    /// submarine's portholes glowing. `visitorShown` answers as the
    /// parade starts — through the post-pass drain — so a relaunch
    /// can't replay it; Reduce Motion
    /// holds the portrait still mid-tank for the same span instead of
    /// crossing, so the visit is a thing on screen, not only a toast.
    func drawVisitor(canvas: inout GraphicsContext, size: CGSize,
                             t: Double, now: Date) {
        // Claim the queue's head when the lane is free. The claim lands
        // on `activeVisitor` now; the game's `visitorShown` waits for
        // the post-pass drain like every draw-time event. A hushed room
        // (quiet, a Focus, a call) leaves the visitor in its queue until
        // it clears — asked last, so the room is only read when someone
        // is actually waiting to swim by.
        if !ambient, motion.activeVisitor == nil, now >= motion.visitorCooldownUntil,
           let next = game?.pendingVisitors.first, toy?.hushed != true {
            motion.activeVisitor = (next, now)
            motion.pendingEvents.append(.visitorShown(next))
            queueEventDrain()
        }
        guard let visitor = motion.activeVisitor else { return }
        let duration: Double = visitor.kind == .whale ? 17 : 14
        let elapsed = now.timeIntervalSince(visitor.startedAt)
        guard elapsed < duration else {
            motion.activeVisitor = nil
            motion.visitorCooldownUntil = now.addingTimeInterval(6)
            motion.pendingEvents.append(.visitorDeparted(visitor.kind))
            queueEventDrain()
            return
        }
        let p = fixture?.visitorProgress ?? (reduceMotion ? 0.5 : elapsed / duration)
        let x = size.width * (1.15 - 1.3 * p)
        switch visitor.kind {
        case .whale:
            let y = size.height * 0.24 + sin(p * .pi * 3) * 8
            var c = canvas
            c.opacity = 0.38 * sin(p * .pi)
            // A huge slate silhouette: long back, fluke, a fin.
            var body = Path()
            body.move(to: CGPoint(x: -110, y: 0))
            body.addQuadCurve(to: CGPoint(x: 40, y: -30),
                              control: CGPoint(x: -50, y: -34))
            body.addQuadCurve(to: CGPoint(x: 96, y: -4),
                              control: CGPoint(x: 78, y: -24))
            body.addQuadCurve(to: CGPoint(x: 40, y: 22),
                              control: CGPoint(x: 80, y: 12))
            body.addQuadCurve(to: CGPoint(x: -110, y: 0),
                              control: CGPoint(x: -40, y: 30))
            body.closeSubpath()
            c.translateBy(x: x, y: y)
            c.fill(body, with: .color(Color(red: 0.05, green: 0.10, blue: 0.18)))
            // The fluke.
            var fluke = Path()
            fluke.move(to: CGPoint(x: -108, y: 0))
            fluke.addQuadCurve(to: CGPoint(x: -136, y: -14),
                               control: CGPoint(x: -120, y: -8))
            fluke.addQuadCurve(to: CGPoint(x: -136, y: 12),
                               control: CGPoint(x: -126, y: 4))
            fluke.closeSubpath()
            c.fill(fluke, with: .color(Color(red: 0.05, green: 0.10, blue: 0.18)))
            // A pectoral fin.
            var fin = Path()
            fin.move(to: CGPoint(x: 20, y: 14))
            fin.addQuadCurve(to: CGPoint(x: 44, y: 30),
                             control: CGPoint(x: 30, y: 24))
            fin.addQuadCurve(to: CGPoint(x: 16, y: 20),
                             control: CGPoint(x: 24, y: 20))
            fin.closeSubpath()
            c.fill(fin, with: .color(Color(red: 0.04, green: 0.08, blue: 0.15)))
            // The spout: a white puff off the back while it's high.
            if y < size.height * 0.20 && !reduceMotion {
                for k in 0..<3 {
                    let sp = frac(t * 1.2 + Double(k) / 3)
                    var b = canvas
                    b.opacity = (1 - sp) * 0.35 * sin(p * .pi)
                    b.stroke(Path(ellipseIn: CGRect(x: x + 52 - 3 - sp * 4,
                                                    y: y - 34 - sp * 22,
                                                    width: 4 + sp * 8,
                                                    height: 4 + sp * 8)),
                             with: .color(.white), lineWidth: 0.8)
                }
            }
        case .diver:
            let y = size.height * 0.34 + sin(p * .pi * 4) * 10
            var c = canvas
            c.translateBy(x: x, y: y)
            c.opacity = 0.75 * sin(p * .pi)
            // Kick fins trailing, a tank on the back, a round head.
            c.fill(Path(ellipseIn: CGRect(x: -12, y: -5, width: 24, height: 10)),
                   with: .color(Color(red: 0.85, green: 0.80, blue: 0.20)))
            c.fill(Path(ellipseIn: CGRect(x: -16, y: -8, width: 8, height: 8)),
                   with: .color(Color(red: 0.80, green: 0.60, blue: 0.45)))
            c.fill(Path(CGRect(x: -4, y: -9, width: 9, height: 4)),
                   with: .color(Color(red: 0.60, green: 0.62, blue: 0.65)))
            let kick = reduceMotion ? 0 : sin(t * 6) * 4
            for k in [-1.0, 1.0] {
                var fin = Path()
                fin.move(to: CGPoint(x: 12, y: k * 2))
                fin.addLine(to: CGPoint(x: 22, y: k * 4 + kick))
                c.stroke(fin, with: .color(Color(red: 0.15, green: 0.15, blue: 0.18)),
                         lineWidth: 2)
            }
            // The torch: a cone of light sweeping ahead.
            var torch = c
            torch.blendMode = .plusLighter
            let sweep = reduceMotion ? 0 : sin(t * 0.9) * 0.35
            torch.rotate(by: .radians(-0.25 + sweep))
            torch.fill(Path(ellipseIn: CGRect(x: -70, y: -14, width: 80, height: 26)),
                       with: .radialGradient(
                           Gradient(colors: [Color(red: 0.95, green: 0.95,
                                                   blue: 0.75)
                                               .opacity(0.30), .clear]),
                           center: CGPoint(x: -16, y: 0), startRadius: 0,
                           endRadius: 60))
            // Bubbles off the reg.
            for k in 0..<3 {
                let bp = frac(t * 0.8 + Double(k) / 3)
                var b = canvas
                b.opacity = (1 - bp) * 0.5 * sin(p * .pi)
                b.stroke(Path(ellipseIn: CGRect(x: x - 14 - bp * 6,
                                                y: y - 12 - bp * 40,
                                                width: 2 + bp * 3, height: 2 + bp * 3)),
                         with: .color(.white), lineWidth: 0.7)
            }
        case .submarine:
            let y = size.height * 0.30
            var c = canvas
            c.translateBy(x: x, y: y)
            c.opacity = 0.65 * sin(p * .pi)
            // The hull: a cigar with a conning tower and tail fins.
            c.fill(Path(ellipseIn: CGRect(x: -46, y: -12, width: 92, height: 24)),
                   with: .color(Color(red: 0.72, green: 0.60, blue: 0.20)))
            c.fill(Path(roundedRect: CGRect(x: -10, y: -22, width: 20, height: 12),
                        cornerRadius: 4),
                   with: .color(Color(red: 0.66, green: 0.54, blue: 0.18)))
            // Periscope.
            c.stroke(Path(CGRect(x: -1, y: -30, width: 2, height: 9)),
                     with: .color(Color(red: 0.40, green: 0.34, blue: 0.14)),
                     lineWidth: 2)
            c.fill(Path(CGRect(x: -1, y: -31, width: 7, height: 3)),
                   with: .color(Color(red: 0.40, green: 0.34, blue: 0.14)))
            // Tail cross.
            for k in [-1.0, 1.0] {
                var fin = Path()
                fin.move(to: CGPoint(x: -44, y: 0))
                fin.addLine(to: CGPoint(x: -56, y: k * 12))
                c.stroke(fin, with: .color(Color(red: 0.60, green: 0.50, blue: 0.16)),
                         lineWidth: 3)
            }
            // Portholes glowing warm.
            var g = c
            g.blendMode = .plusLighter
            for k in 0..<4 {
                g.fill(Path(ellipseIn: CGRect(x: -28 + Double(k) * 16, y: -4,
                                              width: 7, height: 7)),
                       with: .color(Color(red: 1.0, green: 0.85, blue: 0.45)
                                    .opacity(0.9)))
            }
            // Prop wash: a faint churn behind.
            var churn = c
            churn.blendMode = .plusLighter
            churn.fill(Path(ellipseIn: CGRect(x: -80, y: -10, width: 30, height: 20)),
                       with: .radialGradient(
                           Gradient(colors: [.white.opacity(0.14), .clear]),
                           center: CGPoint(x: -58, y: 0), startRadius: 0,
                           endRadius: 20))
        }
    }

    // MARK: Stations

    /// Where a station stands in this tank, in unit space — resolved from
    /// the decor actually drawn (the density's prefix, the shop's owned
    /// pieces), so a fish never works at a landmark that isn't there.
    /// nil when the tank has nothing to stand in for it: the fish keeps
    /// its patrol rather than working at an invisible spot.
    func stationAnchor(_ station: TankStation, for fish: Fish, in size: CGSize,
                               density: Double, bounds: SwimBounds) -> AquariumStations.Anchor? {
        let w = max(1, size.width), h = max(1, size.height)
        let shown = Int((Double(Self.decor.count) * min(1, density)).rounded(.up))
        let visible = Self.decor.filter { $0.id < shown }
        func first(_ kind: TankDecor.Kind) -> TankDecor? { visible.first { $0.kind == kind } }
        // Fish sharing a station spread over its pieces by seed.
        func pick(_ kind: TankDecor.Kind, deepOnly: Bool = false) -> TankDecor? {
            let list = visible.filter { $0.kind == kind && (!deepOnly || $0.depth <= 0.6) }
            return list.isEmpty ? nil : list[Int(fish.seed % UInt64(list.count))]
        }
        // The lowest line the steering lets a fish swim — just over the
        // sand, where the stones and the starfish are.
        let floor = bounds.maxY - 0.01
        func unitY(_ y: Double) -> Double { min(floor, max(bounds.minY + 0.02, y / h)) }
        switch station {
        case .kelp:
            guard let kelp = pick(.kelp, deepOnly: true) ?? pick(.kelp) else { return nil }
            return .init(x: kelp.x, y: unitY(decorBaseY(kelp, in: size) - h * 0.08),
                         spanX: 26 / w, spanY: min(0.30, 0.22 * (0.8 + kelp.scale * 0.25)))
        case .pebbles:
            guard let rock = pick(.rock) ?? pick(.shell) else { return nil }
            return .init(x: rock.x, y: floor, spanX: 30 / w, spanY: 0.04)
        case .chest:
            guard let chest = first(.chest) else { return nil }
            let lid = decorBaseY(chest, in: size) - 26 * chest.scale * Self.decorBoost - 16
            return .init(x: chest.x, y: unitY(lid), spanX: 40 / w, spanY: 0.04)
        case .current:
            // The bubble wall's curtain when the tank owns one, else the
            // column the chest burps up — both are real rising bubbles.
            if owns(.bubbleWall), let slot = AquariumModel.decorSlot(for: .bubbleWall) {
                return .init(x: slot.x, y: unitY(h * 0.45), spanX: 20 / w, spanY: 0.06)
            }
            guard let chest = first(.chest) else { return nil }
            return .init(x: chest.x, y: unitY(h * 0.40), spanX: 20 / w, spanY: 0.06)
        case .wreck:
            if owns(.shipwreck), let slot = AquariumModel.decorSlot(for: .shipwreck) {
                let hull = ownedBaseY(slot, in: size) - slot.h * h * 0.55
                return .init(x: slot.x, y: unitY(hull), spanX: slot.w * h / w * 0.55,
                             spanY: 0.07)
            }
            // No wreck bought: the coral stands in, then the chest.
            guard let piece = pick(.coral) ?? first(.chest) else { return nil }
            return .init(x: piece.x, y: unitY(decorBaseY(piece, in: size) - h * 0.12),
                         spanX: 60 / w, spanY: 0.06)
        case .bench:
            guard let star = first(.starfish) ?? first(.chest) else { return nil }
            return .init(x: star.x, y: floor, spanX: 34 / w, spanY: 0.04)
        case .survey:
            let marks = visible.filter {
                [.coral, .rock, .bottle, .shell, .starfish, .kelp].contains($0.kind)
            }
            guard marks.count >= 2 else { return nil }
            let a = Int(fish.seed % UInt64(marks.count))
            let b = (a + 1 + Int((fish.seed >> 8) % UInt64(marks.count - 1))) % marks.count
            let lane = min(floor, max(bounds.minY + 0.05, laneY(for: fish, in: size) / h))
            return .init(x: marks[a].x, y: lane, spanX: 30 / w, spanY: 0.05,
                         altX: marks[b].x, altY: lane)
        }
    }

    /// The work itself, drawn small at the fish while it is at its
    /// station — never words, never a meter: a forager's crumbs of kelp,
    /// the sand an editor stirs, the current streaming past a shell
    /// worker, an inspector's slow sonar ring, a glint on the chest's
    /// lid, and a finished test's bubble rising green or red. Reduce
    /// Motion keeps a still version of each so the tell survives.
    func drawStationCue(_ cue: FishCue, l: Layout, canvas: inout GraphicsContext,
                                size: CGSize, length: Double, height: Double,
                                t: Double, phase: Double) {
        let mouthX = l.x + l.facing * length * 0.45
        var c = canvas
        c.opacity = l.opacity
        func dot(_ x: Double, _ y: Double, _ r: Double, _ color: Color, _ alpha: Double) {
            c.fill(Path(ellipseIn: CGRect(x: x - r, y: y - r, width: r * 2, height: r * 2)),
                   with: .color(color.opacity(alpha)))
        }
        func ring(_ x: Double, _ y: Double, _ r: Double, _ color: Color, _ alpha: Double,
                  width: Double = 0.8) {
            c.stroke(Path(ellipseIn: CGRect(x: x - r, y: y - r, width: r * 2, height: r * 2)),
                     with: .color(color.opacity(alpha)), lineWidth: width)
        }
        if let tone = cue.tone {
            // A finished test or build: one bubble rising off the fish,
            // tinted by the result — green passed, red failed.
            let tint = tone == .pass ? Color(red: 0.35, green: 0.88, blue: 0.52)
                : Color(red: 1.0, green: 0.38, blue: 0.36)
            let p = reduceMotion ? 0.3 : frac(t / 2.4 + phase / (.pi * 2))
            let r = 3.8 + p * 2.4
            let bx = l.x + l.facing * length * 0.1 + (reduceMotion ? 0 : sin(p * 9 + phase) * 2)
            let by = l.y - height * 0.6 - 6 - p * 34
            let alpha = reduceMotion ? 0.9 : 0.35 + (1 - p) * 0.6
            dot(bx, by, r, tint, alpha * 0.45)
            ring(bx, by, r, tint, alpha, width: 1.1)
            dot(bx - r * 0.35, by - r * 0.4, r * 0.25, .white, alpha * 0.8)
            return
        }
        switch cue.station {
        case .kelp:
            // Reading: two green crumbs drift off the mouth and fade.
            for k in 0..<2 {
                let p = reduceMotion ? 0.35 : frac(t / 1.6 + Double(k) * 0.5 + phase)
                let x = mouthX + l.facing * p * 9
                let y = l.y - 1 + p * 7 + (reduceMotion ? 0 : sin(p * 7 + Double(k)) * 1.5)
                dot(x, y, 1.1 + 0.4 * (1 - p), Color(red: 0.45, green: 0.78, blue: 0.40),
                    (reduceMotion ? 0.7 : (1 - p)) * 0.8)
            }
        case .pebbles:
            // Editing: little puffs of sand kicked up under the nose.
            let sand = sandTop(atX: mouthX, in: size)
            guard sand - (l.y + height * 0.5) < 60 else { return }
            for k in 0..<3 {
                let p = reduceMotion ? 0.3 : frac(t / 1.3 + Double(k) / 3 + phase)
                let x = mouthX + (Double(k) - 1) * 5 + l.facing * p * 4
                let y = sand - 3 - p * 12
                dot(x, y, 1.3 + p * 0.8, Color(red: 0.86, green: 0.78, blue: 0.60),
                    (reduceMotion ? 0.6 : (1 - p)) * 0.55)
            }
        case .current:
            // Running a command: the current streams past, small bubbles
            // rising across the body while the fish holds against it.
            for k in 0..<4 {
                let p = reduceMotion ? Double(k) / 4 : frac(t / 1.1 + Double(k) / 4 + phase)
                let x = l.x + (Double(k) - 1.5) * length * 0.22 + sin(p * 6 + Double(k)) * 1.5
                let y = l.y + height * 0.6 - p * height * 1.8
                ring(x, y, 1.0 + p * 1.1, .white, (reduceMotion ? 0.5 : sin(p * .pi)) * 0.55)
            }
        case .wreck:
            // Testing or building: a slow sonar ring off the fish as it
            // laps the structure.
            let p = reduceMotion ? 0.4 : frac(t / 2.8 + phase)
            let r = length * (0.45 + p * 0.9)
            c.stroke(Path(ellipseIn: CGRect(x: l.x - r, y: l.y - r * 0.55, width: r * 2, height: r * 1.1)),
                     with: .color(Color(red: 0.62, green: 0.86, blue: 1.0).opacity((1 - p) * 0.35)),
                     lineWidth: 0.9)
        case .chest:
            // Calling a tool server: a brass glint winks off the lid
            // below the fish.
            let p = reduceMotion ? 0.5 : frac(t / 1.9 + phase)
            let glow = sin(p * .pi)
            var g = c
            g.blendMode = .plusLighter
            g.opacity = l.opacity * glow * 0.8
            g.translateBy(x: l.x, y: l.y + height * 0.9)
            g.scaleBy(x: 4.5, y: 4.5)
            g.fill(Self.starPath, with: .color(Color(red: 1.0, green: 0.86, blue: 0.5)))
        case .survey:
            // Searching: a faint scan arc ahead of the nose.
            let p = reduceMotion ? 0.5 : frac(t / 1.5 + phase)
            var arc = Path()
            arc.addArc(center: CGPoint(x: mouthX, y: l.y), radius: 6 + p * 8,
                       startAngle: .radians(l.facing > 0 ? -0.6 : .pi - 0.6),
                       endAngle: .radians(l.facing > 0 ? 0.6 : .pi + 0.6), clockwise: false)
            c.stroke(arc, with: .color(.white.opacity((1 - p) * 0.4)), lineWidth: 0.8)
        case .bench:
            // Any other tool: a small bright tick at the mouth, working.
            let p = reduceMotion ? 0.5 : frac(t / 0.9 + phase)
            dot(mouthX + l.facing * 2, l.y, 1.2, .white, sin(p * .pi) * 0.6)
        }
    }

    /// AQ13's parallel markers: a working main session with several
    /// workers carries that many small motes circling close to its
    /// body — company, not a gauge: no track, no fill, just motes.
    func drawParallelMarkers(_ count: Int, l: Layout, canvas: inout GraphicsContext,
                                     length: Double, height: Double, t: Double, phase: Double) {
        guard count > 0 else { return }
        var c = canvas
        c.opacity = l.opacity * 0.7
        let rx = length * 0.72, ry = height * 0.95
        for k in 0..<count {
            let angle = (reduceMotion ? 0 : t * 0.9) + phase + Double(k) / Double(count) * .pi * 2
            let x = l.x + cos(angle) * rx
            let y = l.y + sin(angle) * ry * 0.6
            // Motes behind the body dim, so the ring reads as round.
            let front = sin(angle) > 0
            let r = front ? 1.7 : 1.3
            c.fill(Path(ellipseIn: CGRect(x: x - r, y: y - r, width: r * 2, height: r * 2)),
                   with: .color(.white.opacity(front ? 0.75 : 0.35)))
        }
    }

    /// AQ15's token pass: a verified delegation hands a pellet from the
    /// parent to one of its fry — the first in its school — on a loop
    /// while the plan cites it. Only a real delegation event sets the
    /// action, so proximity never draws one.
    func drawTokenPasses(canvas: inout GraphicsContext, roster: [Fish],
                                 layouts: [String: Layout], t: Double, now: Date) {
        for parent in roster where !parent.isFry && parent.plan?.action == .tokenPass {
            guard let from = layouts[parent.id],
                  let fry = roster.first(where: { $0.isFry && $0.anchorID == parent.id }),
                  let to = layouts[fry.id] else { continue }
            let p = reduceMotion ? 0.5 : frac(t / 1.6 + Double(parent.seed & 0xFF) / 0xFF)
            let e = smooth(p)
            let x = from.x + (to.x - from.x) * e
            let y = from.y + (to.y - from.y) * e - sin(p * .pi) * 10
            var c = canvas
            c.opacity = min(from.opacity, to.opacity) * (reduceMotion ? 0.9 : sin(p * .pi))
            c.fill(Path(ellipseIn: CGRect(x: x - 2.2, y: y - 2.2, width: 4.4, height: 4.4)),
                   with: .color(Color(red: 0.93, green: 0.70, blue: 0.36)))
            c.stroke(Path(ellipseIn: CGRect(x: x - 2.2, y: y - 2.2, width: 4.4, height: 4.4)),
                     with: .color(Color(red: 0.55, green: 0.36, blue: 0.14)), lineWidth: 0.6)
        }
    }
}
