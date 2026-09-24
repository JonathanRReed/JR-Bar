import AppKit
import JRBarCore
import SwiftUI

/// The completion effects: the meal a finished run drops and the fish that come to eat it.
extension AquariumView {
    // MARK: Completion FX

    /// One dropped pellet's course: where it appeared, where it sinks
    /// to rest, and which fish comes to eat it. The course derives from
    /// the leaver's seed & `stateSince`; who eats it is planned once and
    /// remembered (`TankSwimMemory.Meal`), so the same meal replays the
    /// same way every frame.
    struct Pellet {
        var origin: CGPoint
        var rest: CGPoint
        var r: Double
        var wobble: Double
        /// The eating fish's id, if a live adult was close enough to
        /// claim it.
        var eater: String?
        /// Seconds a fish with no steering body yet (a fixture's) takes
        /// to be pulled over to it; a swimming fish gets there on its own.
        var dart: Double
        /// How far ahead of the eater's middle its mouth is, points.
        var mouth: Double
        /// Age (s since the leaver turned) at which the pellet is gone —
        /// eaten, or faded on the sand when nobody came.
        var gone: Double

        /// Where the pellet is `age` seconds into the leave: it appears
        /// where the fish finished and sinks to the sand.
        func position(at age: Double) -> CGPoint {
            let c = min(1, max(0, (age - 0.35) / 1.5))
            let sink = c * c * (3 - 2 * c)
            return CGPoint(x: origin.x + (rest.x - origin.x) * sink,
                           y: origin.y + (rest.y - origin.y) * sink)
        }
    }

    /// The meal a finished fish leaves behind: the spot it was at when
    /// it turned for the edge, plus its pellets.
    struct Meal {
        var leaver: Fish
        var spawn: CGPoint
        var pellets: [Pellet]
    }

    /// Plan each leaving fish's meal (docs/TOYS.md: a completion drops
    /// food, nearby fish come eat it). The pellets are pure functions of
    /// the leaver's seed; which fish comes for each is decided the first
    /// frame the meal is seen and held from then on, and a pellet is
    /// gone when its eater's mouth reaches it.
    func completionMeals(in size: CGSize, now: Date, roster: [Fish]) -> [Meal] {
        let margin = 36.0
        var meals: [Meal] = []
        for leaver in roster where !leaver.isFry && leaver.state == .leaving {
            // The meal's story is told for a few seconds, then the
            // leaver & its food are both off-stage.
            let age = now.timeIntervalSince(leaver.stateSince)
            guard age < 11 else { continue }
            // The meal spawns where the fish was when it turned for
            // the edge — its anchor, or the patrol sweep when no body
            // has stepped yet.
            let spawn = anchor(of: leaver, in: size)
            // The live adults who could come for the food.
            let eaters = roster.filter {
                !$0.isFry && $0.id != leaver.id
                    && ($0.state == .swimming || $0.state == .idling)
                    && !$0.isRetired(at: now)
            }
            var pellets: [Pellet] = AquariumModel.pelletSeeds(for: leaver).map { seed in
                let dx = (Double(seed & 0xFF) / 0xFF - 0.5) * 64
                let restX = min(max(spawn.x + dx, margin), size.width - margin)
                let restY = min(spawn.y + 34 + Double((seed >> 8) & 0xFF) / 0xFF * 26,
                                sandTop(atX: restX, in: size) - 6)
                return Pellet(origin: spawn, rest: CGPoint(x: restX, y: restY),
                              r: 2.4 + Double((seed >> 16) & 0xFF) / 0xFF * 1.4,
                              wobble: Double((seed >> 24) & 0xFF) / 0xFF * .pi * 2,
                              eater: nil, dart: 0, mouth: 0,
                              gone: 9 + Double((seed >> 32) & 0xFF) / 0xFF * 2)
            }
            let plan = mealPlan(for: leaver, pellets: pellets, eaters: eaters, in: size)
            for i in pellets.indices {
                // An eater that has since left the water leaves its
                // pellet to fade on the sand.
                guard let id = plan.eaters[i], let eater = eaters.first(where: { $0.id == id })
                else { continue }
                pellets[i].eater = id
                pellets[i].dart = plan.darts[i]
                pellets[i].mouth = 0.42 * drawnSize(of: eater, layout: steeringLayout(of: eater)).length
                if let eaten = plan.eatenAt[i] {
                    pellets[i].gone = eaten
                } else if motion.bodies[id] == nil {
                    pellets[i].gone = 0.85 + plan.darts[i]
                }
            }
            meals.append(Meal(leaver: leaver, spawn: spawn, pellets: pellets))
        }
        return meals
    }

    /// Who comes for each of `leaver`'s pellets: the nearest unclaimed
    /// live fish, measured once, the first frame the meal is seen — so
    /// as the eaters swim over nobody swaps pellets and no dart shrinks.
    private func mealPlan(for leaver: Fish, pellets: [Pellet], eaters: [Fish],
                          in size: CGSize) -> TankSwimMemory.Meal {
        let memory = motion.swim
        if let plan = memory.meals[leaver.id], plan.since == leaver.stateSince,
           plan.eaters.count == pellets.count {
            return plan
        }
        let t0 = leaver.stateSince.timeIntervalSince1970
        var plan = TankSwimMemory.Meal(since: leaver.stateSince, eaters: [], darts: [], eatenAt: [])
        var claimed: Set<String> = []
        for pellet in pellets {
            var best: Fish?
            var bestD2 = Double.greatestFiniteMagnitude
            for e in eaters where !claimed.contains(e.id) {
                // The eater's real spot: its steering body, else the
                // sweep stand-in.
                let ep = motion.bodies[e.id].map {
                    CGPoint(x: $0.x * size.width, y: $0.y * size.height)
                } ?? CGPoint(x: patrol(of: e, in: size, at: t0, margin: 36).x,
                             y: laneY(for: e, in: size))
                let d2 = (ep.x - pellet.rest.x) * (ep.x - pellet.rest.x)
                    + (ep.y - pellet.rest.y) * (ep.y - pellet.rest.y)
                if d2 < bestD2 { bestD2 = d2; best = e }
            }
            if let best { claimed.insert(best.id) }
            plan.eaters.append(best?.id)
            plan.darts.append(best == nil ? 0 : dartTime(distance: sqrt(bestD2)))
            plan.eatenAt.append(nil)
        }
        memory.meals[leaver.id] = plan
        return plan
    }

    /// How long a fish with no steering body takes to be pulled
    /// `distance` points over to its pellet: a brisk dart, plus the
    /// quick turn it may need first.
    private func dartTime(distance: Double) -> Double {
        let tuning = swimTuning
        let tempo = AquariumSettings.clamped(tuning.swimSpeed, to: AquariumSettings.swimSpeedRange)
        let turn = AquariumTurn.duration(for: .food, pace: tuning.swimPace, tempo: tempo)
        return min(2.4, max(0.5, distance / 140)) + turn
    }

    /// Mark `leaver`'s pellet `index` eaten `age` seconds into the leave:
    /// it blinks out as the mouth closes on it.
    func mealEaten(_ leaver: Fish, pellet index: Int, age: Double) {
        guard var plan = motion.swim.meals[leaver.id], plan.since == leaver.stateSince,
              plan.eatenAt.indices.contains(index), plan.eatenAt[index] == nil else { return }
        plan.eatenAt[index] = age
        motion.swim.meals[leaver.id] = plan
    }

    /// A fish with no steering body yet (a fixture's) can't swim to its
    /// pellet, so it is pulled over: the pull swells as it darts, holds
    /// while it mouths the food, then releases it back onto its patrol.
    /// A swimming fish is left alone — it swims there through its own
    /// turn, and the pellet goes when its mouth arrives.
    func applyPursuits(_ meals: [Meal], to layouts: inout [String: Layout], now: Date) {
        for meal in meals {
            let age = now.timeIntervalSince(meal.leaver.stateSince)
            for pellet in meal.pellets {
                guard let eater = pellet.eater, motion.bodies[eater] == nil,
                      var l = layouts[eater] else { continue }
                let pull = smooth(clamp01((age - 0.7) / pellet.dart))
                    - smooth(clamp01((age - 0.7 - pellet.dart - 0.45) / 1.0))
                guard pull > 0.001 else { continue }
                // Mouth on the food: the pellet sits just off the nose.
                let tx = pellet.rest.x - l.yawCos * pellet.mouth
                let ty = pellet.rest.y - 6
                l.x += (tx - l.x) * pull
                l.y += (ty - l.y) * pull * 0.85
                l.pitch *= 1 - pull * 0.6
                l.wag += pull * 0.9
                layouts[eater] = l
            }
        }
    }

    /// The food & the payout: each pellet appears where the fish
    /// finished, sinks to the sand wobbling, and blinks out when its
    /// eater arrives; a gold star flares once at the spot.
    func drawMeals(canvas: inout GraphicsContext, meals: [Meal], now: Date) {
        for meal in meals {
            let age = now.timeIntervalSince(meal.leaver.stateSince)
            // The completion glint: a sparkle that swells & dies over
            // ~1.8 s where the fish turned for the edge.
            let glint = 1 - clamp01(age / 1.8)
            if glint > 0.01 {
                var g = canvas
                g.blendMode = .plusLighter
                g.opacity = glint
                g.translateBy(x: meal.spawn.x, y: meal.spawn.y - 20)
                if !reduceMotion { g.rotate(by: .radians(age * 1.6)) }
                let s = 13 * (0.55 + glint * 0.45)
                g.scaleBy(x: s, y: s)
                g.fill(Self.starPath,
                       with: .color(Color(red: 1, green: 0.87, blue: 0.40).opacity(0.8)))
                g.scaleBy(x: 0.45, y: 0.45)
                g.fill(Self.starPath, with: .color(.white.opacity(0.6)))
            }
            for pellet in meal.pellets {
                guard age > 0.35 else { continue }
                let appear = smooth(clamp01((age - 0.35) / 0.4))
                let a = appear * (1 - smooth(clamp01((age - pellet.gone) / 0.3)))
                guard a > 0.01 else { continue }
                let at = pellet.position(at: age)
                let x = at.x + (reduceMotion ? 0 : sin(age * 2.4 + pellet.wobble) * 3)
                let y = at.y
                let r = pellet.r * (0.5 + 0.5 * appear)
                CreaturePaint.pellet(&canvas, at: CGPoint(x: x, y: y), r: r, alpha: a)
            }
        }
    }

    /// The milestone burst: a fast plume of bubbles off the chest lid
    /// while the window is open — a batch of finishes pops the chest.
    /// Anchored to the seeded chest piece, so the plume actually rises
    /// off the lid wherever the layout put it.
    func drawChestBurst(canvas: inout GraphicsContext, size: CGSize, age: Double) {
        guard age < 4.2 else { return }
        let chest = Self.decor.first(where: { $0.kind == .chest })
        let chestX = (chest?.x ?? 0.85) * size.width
        // Start just over the lid: the chest stands `h` tall on the bed.
        let baseY = chest.map { decorBaseY($0, in: size) - 26 * $0.scale * Self.decorBoost }
            ?? size.height - 80
        for i in 0..<14 {
            let h = AquariumModel.stableHash("burst-\(i)")
            let u = Double(h & 0xFF) / 0xFF
            let life = 1.3 + Double((h >> 8) & 0xFF) / 0xFF * 2.0
            let p = clamp01(age / life)
            guard p < 1 else { continue }
            let wobble = reduceMotion ? 0 : sin(age * 6 + Double(i) * 2.1) * 4 * p
            let x = chestX + (u - 0.5) * 50 + wobble
            let y = baseY - p * (baseY - 8)
            let r = 1.5 + u * 2.8 + p * 1.2
            var b = canvas
            b.opacity = (1 - p) * 0.5
            b.stroke(Path(ellipseIn: CGRect(x: x - r, y: y - r, width: r * 2, height: r * 2)),
                     with: .color(.white), lineWidth: 0.8)
        }
    }

    /// The hover/tap tag: a glassy capsule with the fish's label led
    /// by a dot in its provider's colour, parked just above the body.
    /// Fry get it too — this is where a worker's name shows when
    /// labels are off.
    func drawNameplate(canvas: inout GraphicsContext, size: CGSize,
                               fish: Fish, layout l: Layout) {
        let drawn = drawnSize(of: fish, layout: l)
        // A fish flying an overlay mark keeps it in view: the tag
        // rides above the mark instead of over it.
        var mark = 0.0
        if fish.plan?.overlay != nil, !fish.isFry {
            mark = max(3.4, drawn.length * 0.10) * 2 + 6
        }
        let tag = canvas
        let resolved: GraphicsContext.ResolvedText
        let textSize: CGSize
        (resolved, textSize) = textCache.tag(for: fish.label, canvas: canvas)
        let dot = 6.0
        let width = textSize.width + dot + 22
        let cx = min(max(l.x, width / 2 + 14), size.width - width / 2 - 14)
        let cy = max(l.y - max(drawn.above, drawn.below) - 14 - mark, 16)
        let rect = CGRect(x: cx - width / 2, y: cy - textSize.height / 2 - 4,
                          width: width, height: textSize.height + 8)
        let pill = Path(roundedRect: rect, cornerRadius: rect.height / 2)
        tag.fill(pill, with: .color(Color(red: 0.02, green: 0.08, blue: 0.16).opacity(0.80)))
        tag.stroke(pill, with: .linearGradient(
            Gradient(colors: [.white.opacity(0.38), .white.opacity(0.10)]),
            startPoint: CGPoint(x: 0, y: rect.minY), endPoint: CGPoint(x: 0, y: rect.maxY)),
            lineWidth: 0.75)
        let accent = Color(nsColor: ProviderStyle.style(for: fish.providerID).nsAccent)
        let dotRect = CGRect(x: rect.minX + 9, y: cy - dot / 2, width: dot, height: dot)
        tag.fill(Path(ellipseIn: dotRect.insetBy(dx: -1.5, dy: -1.5)), with: .color(accent.opacity(0.3)))
        tag.fill(Path(ellipseIn: dotRect), with: .color(accent))
        tag.draw(resolved, at: CGPoint(x: dotRect.maxX + 5 + textSize.width / 2, y: cy), anchor: .center)
    }
}
