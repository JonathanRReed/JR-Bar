import AppKit
import JRBarCore
import SwiftUI

/// The tank (docs/TOYS.md): a still `Canvas` for everything that never
/// moves (water, sand, the non-swaying decor — rasterized once by
/// `.drawingGroup` and recomposited for free), an additive light pass
/// (god rays, caustic dapples, a slow sheen drift), and a live
/// `TimelineView` + `Canvas` for the swimmers. Fish positions are
/// integrated from each `Fish`'s constants and the frame clock, so
/// `toy.fish` only has to change when the session set does, and the
/// timelines pause while the window is covered.
struct AquariumView: View {
    /// A fixed scene for the snapshot renderer (JRBarAppTests): the
    /// tank drawn without a toy. The app only ever uses `init(toy:)`.
    struct Fixture {
        var fish: [Fish]
        var showLabels = true
        var density: Double = 1
        var paused = false
        /// A synthetic game — the proof shots dress the tank with it.
        var game: AquariumGame?
        /// A pinned night factor (0…1) so proof shots don't depend on
        /// the hour they're rendered; nil follows the settings.
        var night: Double?
        /// A pinned parade position (0…1) so a proof shot catches a
        /// visitor mid-water instead of at the claim edge.
        var visitorProgress: Double?
    }

    private let toy: AquariumToy?
    private let fixture: Fixture?

    /// The game either side reads — the toy's live document, or the
    /// fixture's synthetic one.
    private var game: AquariumGame? { toy?.game ?? fixture?.game }

    /// The water column's theme key — "classic" when there's no game.
    private var themeKey: String { game?.themeID ?? "classic" }
    /// The floor's substrate key.
    private var substrateKey: String { game?.substrateID ?? "classic" }
    /// The back wall's backdrop key.
    private var backdropKey: String { game?.backdropID ?? "classic" }
    /// Themes dark enough that the warm sun glow cools to moonlight.
    private var isDarkTheme: Bool { themeKey == "midnight" || themeKey == "abyss" }
    /// The column's floor colour — what deep water attenuates toward.
    private var floorColor: Color {
        waterStops.last?.color ?? Color(red: 0.015, green: 0.06, blue: 0.22)
    }
    private var floorNS: NSColor { NSColor(floorColor) }

    /// The day/night wash's depth (0 bright … 1 deepest). `cycle`
    /// keeps the original four-minute breathe; `realTime` follows the
    /// clock — night from 21:00 to 06:00, dawn & dusk blending the
    /// edges. Reduce Motion holds a soft dusk; a fixture can pin it.
    private func nightFactor(t: Double) -> Double {
        if let pinned = fixture?.night { return pinned }
        if reduceMotion { return 0.4 }
        switch toy?.store?.state.aquarium.dayNight ?? .cycle {
        case .cycle:
            return AquariumBehavior.night(at: t)
        case .realTime:
            return AquariumBehavior.realTimeNight(
                at: Date(timeIntervalSince1970: t), calendar: .current)
        }
    }

    init(toy: AquariumToy, ambient: Bool = false) {
        self.toy = toy
        self.fixture = nil
        self.ambient = ambient
    }

    init(fixture: Fixture) {
        self.toy = nil
        self.fixture = fixture
        self.ambient = false
    }

    /// The tank as scenery rather than a window: the live wallpaper on a
    /// second display, or the idle screensaver. No chrome (no pearl
    /// count, shop or inspector — nobody is going to click it), its own
    /// covered-or-not pause instead of the window's, and it leaves the
    /// visitor queue to the real window so a parade is never counted
    /// twice.
    private let ambient: Bool
    /// The ambient panel's own visibility — a live wallpaper under a
    /// stack of windows draws nothing.
    @ViewState private var ambientVisible = true

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// W14's selection: the tapped fish's id, cleared when it leaves
    /// the tank. Drives the inspector strip — the tap already hit-tests
    /// via `hoverProbe.boxes`, selection just keeps the last hit.
    @ViewState private var selectedID: String?
    /// The shop popover's open flag.
    @ViewState private var showShop = false

    var body: some View {
        // Read the observable surface in `body` so the card's tracked
        // reads stay honest even while the timeline is paused.
        let fish = toy?.fish ?? fixture?.fish ?? []
        let showLabels = toy?.store?.state.aquarium.showLabels ?? fixture?.showLabels ?? true
        let density = max(0.1, toy?.store?.state.aquarium.density ?? fixture?.density ?? 1)
        let paused = ambient ? !ambientVisible
            : (toy?.windowOccluded ?? fixture?.paused ?? false)
        ZStack {
            // The still tank: water, sand and every decor piece that
            // doesn't sway. A slow two-second tick lets the day/night
            // wash keep breathing (and keeps the caption's decor
            // culling in step with retiring fish); `.drawingGroup`
            // rasterizes the result, so each live frame costs one
            // texture composite instead of ~240 path builds.
            TimelineView(.animation(minimumInterval: 2, paused: paused)) { context in
                Canvas { canvas, size in
                    drawWater(canvas: &canvas, size: size,
                              t: context.date.timeIntervalSince1970)
                    drawBackdrop(canvas: &canvas, size: size)
                    drawSand(canvas: &canvas, size: size)
                    let empty = fish.isEmpty
                        || fish.allSatisfy { $0.isRetired(at: context.date) }
                    let caption = empty ? captionLayout(canvas: &canvas, size: size) : nil
                    drawStaticDecor(canvas: &canvas, size: size, density: density,
                                    keepClear: caption?.rect)
                    // Owned back-row pieces root on the far dune —
                    // still, so they bake into the bed.
                    drawOwnedBackDecor(canvas: &canvas, size: size,
                                       t: context.date.timeIntervalSince1970)
                }
            }
            .drawingGroup(opaque: false, colorMode: .nonLinear)
            // The live timeline: 30 fps normally, a 1 fps heartbeat under
            // Reduce Motion — every draw inside already stills itself, so
            // the slow tick only keeps the sim honest (pellets still
            // sink to mouths, completions still serve their meals, a
            // visitor's still portrait still comes and goes) without
            // paying a display-rate redraw for a scene that doesn't move.
            TimelineView(.animation(minimumInterval: reduceMotion ? 1 : 1.0 / 30.0,
                                    paused: paused)) { context in
                let t = context.date.timeIntervalSince1970
                // Memoized on the fish array: the timeline ticks 30×/s
                // but the roster only moves with the sessions, so an
                // unchanged roster reuses the last sort instead of
                // rebuilding it.
                let order = fishOrder(fish)
                let empty = fish.isEmpty || fish.allSatisfy { $0.isRetired(at: context.date) }
                ZStack {
                    // The light pass: rays, caustic dapples on the dune
                    // crest and a slow sheen drift through the column.
                    // The canvas composites additively over the still
                    // tank, so these read as light, not pale decals —
                    // and the rays get to pool on the sand, which they
                    // never could while the floor drew over them.
                    Canvas { canvas, size in
                        drawGodRays(canvas: &canvas, size: size, t: t)
                        drawSandCaustics(canvas: &canvas, size: size, t: t)
                        drawWaterSheen(canvas: &canvas, size: size, t: t)
                    }
                    .blendMode(.plusLighter)
                    .allowsHitTesting(false)
                    Canvas { canvas, size in
                        // One steering step per frame before anything
                        // reads a position: wander, glass, food, school.
                        stepSwim(order.ordered, in: size, t: t, now: context.date,
                                 density: density)
                        // The empty-tank caption's capsule: decor keeps
                        // clear of it, and it draws last, over the sand.
                        let caption = empty ? captionLayout(canvas: &canvas, size: size) : nil
                        drawLiveDecor(canvas: &canvas, size: size, t: t, density: density,
                                      front: false, keepClear: caption?.rect)
                        drawJellyfish(canvas: &canvas, size: size, t: t,
                                      resident: empty || owns(.jellyfish))
                        drawPlankton(canvas: &canvas, size: size, t: t,
                                     density: density, front: false)
                        drawBubbles(canvas: &canvas, size: size, t: t, density: density)
                        // The passers-by and the sand/mid-water pets
                        // live behind the fish lane.
                        drawVisitor(canvas: &canvas, size: size, t: t, now: context.date)
                        drawManta(canvas: &canvas, size: size, t: t)
                        if owns(.seaTurtle) {
                            drawSeaTurtle(canvas: &canvas, size: size, t: t)
                        }
                        if owns(.octopus) {
                            drawOctopus(canvas: &canvas, size: size, t: t)
                        }
                        if owns(.axolotl) {
                            drawAxolotl(canvas: &canvas, size: size, t: t)
                        }
                        // A batch of finishes pops the chest: a fast
                        // plume off its lid while the milestone window
                        // is still open.
                        let leavers = order.ordered.filter {
                            !$0.isFry && $0.state == .leaving
                                && context.date.timeIntervalSince($0.stateSince)
                                    < AquariumModel.milestoneWindow
                        }
                        if leavers.count >= AquariumModel.milestoneCount,
                           let first = leavers.map(\.stateSince).min() {
                            drawChestBurst(canvas: &canvas, size: size,
                                           age: context.date.timeIntervalSince(first))
                        }
                        // Mains lay out first so fry can orbit their
                        // parents.
                        var layouts: [String: Layout] = [:]
                        for aFish in order.ordered
                        where !aFish.isFry && !aFish.isRetired(at: context.date) {
                            layouts[aFish.id] = layout(of: aFish, in: size,
                                                       at: t, now: context.date)
                        }
                        // A finished fish drops a meal: the pellets and
                        // who comes to eat them are planned before the
                        // fish draw, because an eater's dart bends its
                        // layout.
                        let meals = completionMeals(in: size, now: context.date,
                                                    roster: order.ordered)
                        applyPursuits(meals, to: &layouts, now: context.date)
                        // The nameplate's target, off the previous
                        // frame's boxes: a fish wearing the tag skips
                        // its always-on chip so the two never stack.
                        let nameplateID: String? = {
                            let probe = hoverProbe.point
                                ?? (hoverProbe.flashUntil > context.date
                                    ? hoverProbe.flashPoint : nil)
                            guard let probe else { return nil }
                            return hoverProbe.boxes.last(where: { $0.rect.contains(probe) })?.id
                        }()
                        hoverProbe.boxes.removeAll(keepingCapacity: true)
                        for aFish in order.ordered where !aFish.isRetired(at: context.date) {
                            let parent = parentContext(of: aFish, mains: order.mains,
                                                       layouts: layouts)
                            let l = layouts[aFish.id]
                                ?? layout(of: aFish, in: size, at: t,
                                          now: context.date, parent: parent)
                            layouts[aFish.id] = l
                            drawFish(canvas: &canvas, size: size, t: t, now: context.date,
                                     fish: aFish, layout: l, parent: parent,
                                     showLabels: showLabels && aFish.id != nameplateID)
                            // The hover/tap hit area: a soft-edged box
                            // around the drawn body, front-most fish wins.
                            let len = 46 * l.scale * aFish.species.sizeScale
                                * (aFish.isFry ? AquariumModel.fryScale : 1)
                            let hgt = len * aFish.species.aspect
                            hoverProbe.boxes.append((
                                aFish.id,
                                CGRect(x: l.x - len * 0.62, y: l.y - hgt * 0.85,
                                       width: len * 1.24, height: hgt * 1.7)))
                        }
                        drawTokenPasses(canvas: &canvas, roster: order.ordered,
                                        layouts: layouts, t: t, now: context.date)
                        drawMeals(canvas: &canvas, meals: meals, now: context.date)
                        drawFeed(canvas: &canvas, size: size, now: context.date)
                        drawShopDecor(canvas: &canvas, size: size, t: t)
                        // Owned front-row decor stands over the lane
                        // like the shop's first four; the buried
                        // treasure waits on the sand for its taps.
                        drawOwnedFrontDecor(canvas: &canvas, size: size, t: t)
                        drawTreasure(canvas: &canvas, size: size, t: t,
                                     now: context.date)
                        if owns(.tetraSchool) {
                            drawTetraSchool(canvas: &canvas, size: size, t: t)
                        }
                        if owns(.cleanerShrimp) {
                            drawCleanerShrimp(canvas: &canvas, size: size, t: t,
                                              layouts: layouts, roster: order.ordered,
                                              now: context.date)
                        }
                        drawDrops(canvas: &canvas, size: size, t: t,
                                  layouts: layouts)
                        drawGoldBursts(canvas: &canvas, size: size, now: context.date)
                        drawTrickRings(canvas: &canvas, size: size,
                                       layouts: layouts, now: context.date)
                        // The juice: tap/eat/collect rings and pearls
                        // arcing home to the counter.
                        drawPuffs(canvas: &canvas, size: size, now: context.date)
                        drawFlights(canvas: &canvas, size: size, now: context.date)
                        if owns(.snail) {
                            drawSnail(canvas: &canvas, size: size, t: t)
                        }
                        if owns(.hermitCrab) {
                            drawHermitCrab(canvas: &canvas, size: size, t: t)
                        }
                        drawLiveDecor(canvas: &canvas, size: size, t: t, density: density,
                                      front: true, keepClear: caption?.rect)
                        drawPlankton(canvas: &canvas, size: size, t: t,
                                     density: density, front: true)
                        // The surface draws over everything: a surfacing
                        // fish reads as under the waterline, not pasted
                        // on top.
                        drawSurface(canvas: &canvas, size: size, t: t)
                        drawGlass(canvas: &canvas, size: size)
                        // A hovered or tapped fish gets a name tag over
                        // the glass — this is how a fry says its
                        // worker's name.
                        let probe = hoverProbe.point
                            ?? (hoverProbe.flashUntil > context.date
                                ? hoverProbe.flashPoint : nil)
                        if let point = probe,
                           let hit = hoverProbe.boxes.last(where: { $0.rect.contains(point) }),
                           let l = layouts[hit.id],
                           let hitFish = order.ordered.first(where: { $0.id == hit.id }) {
                            drawNameplate(canvas: &canvas, size: size,
                                          fish: hitFish, layout: l)
                        }
                        if let caption {
                            drawEmpty(canvas: &canvas, size: size, caption: caption)
                        }
                    }
                }
            }

            // W14's inspector: the selected fish's session facts — the
            // plan's own evidence line, so the strip and the marker
            // can't disagree about why it looks the way it does.
            if let selectedID,
               let selected = fish.first(where: { $0.id == selectedID }) {
                VStack {
                    Spacer()
                    inspectorStrip(selected)
                }
                .transition(.opacity)
            }

            // The idle game's chrome (docs/TOYS.md): a pearl count &
            // streak up top, feed & shop buttons, the "while you were
            // away" card on reopen, and a small toast for game moments.
            if toy != nil, !ambient {
                VStack(spacing: 0) {
                    HStack(spacing: 8) {
                        if let game = toy?.game {
                            hudChip {
                                HStack(spacing: 4) {
                                    Image(systemName: "circle.fill")
                                        .font(.system(size: 7))
                                        .foregroundStyle(Color(red: 0.95, green: 0.90, blue: 0.75))
                                        .symbolEffect(.bounce, options: .nonRepeating,
                                                      value: game.pearls)
                                    Text("\(game.pearls)")
                                        .contentTransition(.numericText())
                                }
                            }
                            .help("Pearls — earned while sessions work, spent in the shop.")
                            if game.streakDays > 1 {
                                hudChip {
                                    HStack(spacing: 4) {
                                        Image(systemName: "flame.fill")
                                            .font(.system(size: 8))
                                            .foregroundStyle(.orange)
                                            .symbolEffect(.bounce, options: .nonRepeating,
                                                          value: game.streakDays)
                                        Text("\(game.streakDays)d")
                                    }
                                }
                                .help("Days in a row with a completed session.")
                            }
                        }
                        Spacer()
                        Button {
                            feed(at: CGPoint(x: motion.size.width * 0.5,
                                             y: motion.size.height * 0.30))
                        } label: {
                            Image(systemName: "menucard.fill")
                                .font(.system(size: 10))
                        }
                        .buttonStyle(.plain)
                        .help("Drop a pinch of food — or just tap the water.")
                        Button {
                            showShop = true
                        } label: {
                            Image(systemName: "bag.fill")
                                .font(.system(size: 10))
                        }
                        .buttonStyle(.plain)
                        .help("Tank shop — decor, pets, themes, hats.")
                        .popover(isPresented: $showShop, arrowEdge: .top) {
                            shopPanel(fish: fish)
                        }
                    }
                    .padding(.horizontal, 10)
                    .padding(.top, 8)
                    if let away = toy?.awayNotice {
                        awayBanner(away)
                            .padding(.top, 6)
                    }
                    if let n = toy?.notice {
                        // The reward card — kin to the away-summary
                        // banner: material capsule, gold accent, title
                        // + payout. Slides in from the top edge and
                        // fades out as `notice` clears.
                        HStack(spacing: 7) {
                            Image(systemName: n.symbol)
                                .font(.system(size: 12, weight: .semibold))
                                .foregroundStyle(Color(red: 1.0, green: 0.80,
                                                       blue: 0.30))
                            VStack(alignment: .leading, spacing: 1) {
                                Text(n.title)
                                    .font(.system(size: 10.5, weight: .semibold))
                                    .foregroundStyle(.white.opacity(0.95))
                                if let reward = n.reward {
                                    Text(reward)
                                        .font(.system(size: 9, weight: .medium))
                                        .foregroundStyle(.white.opacity(0.6))
                                }
                            }
                        }
                        .padding(.horizontal, 12)
                        .padding(.vertical, 7)
                        .background(.ultraThinMaterial, in: Capsule())
                        .shadow(color: .black.opacity(0.3), radius: 6, y: 2)
                        .frame(maxWidth: .infinity, alignment: .trailing)
                        .padding(.trailing, 10)
                        .padding(.top, 4)
                        .transition(.move(edge: .top).combined(with: .opacity))
                        .task(id: n.id) {
                            try? await Task.sleep(for: .seconds(4))
                            guard !Task.isCancelled else { return }
                            toy?.dismissNotice(id: n.id)
                        }
                        .allowsHitTesting(false)
                    }
                    Spacer()
                    if let toast = toy?.toast {
                        Text(toast.text)
                            .font(.system(size: 10, weight: .medium))
                            .foregroundStyle(.white.opacity(0.9))
                            .padding(.horizontal, 10)
                            .padding(.vertical, 5)
                            .background(.ultraThinMaterial, in: Capsule())
                            .padding(.bottom, 52)
                            .onTapGesture { toy?.dismissToast() }
                    }
                }
                .animation(.easeInOut(duration: 0.35), value: toy?.notice?.id)
            }
        }
        .onContinuousHover(coordinateSpace: .local) { phase in
            switch phase {
            case .active(let point): hoverProbe.point = point
            case .ended: hoverProbe.point = nil
            }
        }
        // A tap selects the fish under it (W14's inspection): the
        // inspector strip opens on the session's facts; a tap on empty
        // water clears. The flash path still covers a tap that hits
        // nothing selectable.
        .gesture(SpatialTapGesture(coordinateSpace: .local).onEnded { value in
            // The buried treasure takes the tap first — it's the
            // rarest thing on the sand; then a pearl drop collects; a
            // fish selects; open water drops a pinch of food.
            if let box = motion.treasureBox, box.rect.contains(value.location) {
                toy?.digTreasure(box.id)
                let unitX = box.rect.midX / max(1, motion.size.width)
                let unitY = box.rect.midY / max(1, motion.size.height)
                motion.puffs.append((x: unitX, y: unitY, bornAt: Date()))
                // The third dig collected: the lid pops in a gold
                // burst where it sat.
                if toy?.game.treasure == nil {
                    motion.goldBursts.append((x: CGPoint(x: box.rect.midX,
                                                         y: box.rect.midY),
                                              bornAt: Date()))
                }
                return
            }
            if let hit = motion.dropBoxes.last(where: { $0.rect.contains(value.location) }) {
                toy?.collectDrop(hit.id)
                // The pick-up juice: a bloop where it sat, and the
                // pearl arcs up to the counter.
                let unitX = hit.rect.midX / max(1, motion.size.width)
                let unitY = hit.rect.midY / max(1, motion.size.height)
                motion.puffs.append((x: unitX, y: unitY, bornAt: Date()))
                motion.flights.append((from: CGPoint(x: hit.rect.midX,
                                                     y: hit.rect.midY),
                                       bornAt: Date()))
                return
            }
            if let hit = hoverProbe.boxes.last(where: { $0.rect.contains(value.location) }) {
                selectedID = selectedID == hit.id ? nil : hit.id
                // Poking a fish startles it — a dart and a bloop, and
                // it forgives you inside a second.
                if motion.bodies[hit.id] != nil {
                    motion.startles[hit.id] = (until: Date().addingTimeInterval(0.9),
                                               from: value.location)
                    if let b = motion.bodies[hit.id] {
                        motion.puffs.append((x: b.x, y: b.y, bornAt: Date()))
                    }
                }
                // One tap in three earns a trick — a barrel roll or a
                // bubble ring — seeded off the tap count so replays
                // agree. Reduce Motion fish keep their dignity.
                if !reduceMotion {
                    motion.trickSeq += 1
                    let roll = AquariumBehavior.scramble(
                        AquariumModel.stableHash("trick-\(hit.id)")
                            &+ UInt64(motion.trickSeq))
                    if roll % 3 == 0 {
                        motion.tricks[hit.id] = (
                            kind: roll & 0x100 == 0 ? .roll : .ring,
                            until: Date().addingTimeInterval(
                                AquariumBehavior.trickDuration))
                    }
                }
            } else {
                selectedID = nil
                feed(at: value.location)
                hoverProbe.flashPoint = value.location
                hoverProbe.flashUntil = Date().addingTimeInterval(2.2)
            }
        })
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(red: 0.02, green: 0.07, blue: 0.25))
        .background {
            if ambient { WindowVisibilityReader { ambientVisible = $0 } }
        }
    }

    /// Where the pointer is and which fish it is over. A plain
    /// reference held in `ViewState`: the hover changes every frame
    /// and is consumed inside the Canvas, so tracking it as SwiftUI
    /// state would just buy extra invalidations for nothing.
    private final class HoverProbe {
        /// The live hover point, or nil when the pointer is elsewhere.
        var point: CGPoint?
        /// Where a tap landed, and until when its tag stays up.
        var flashPoint: CGPoint?
        var flashUntil = Date.distantPast
        /// This frame's fish hitboxes, in draw order (back → front).
        var boxes: [(id: String, rect: CGRect)] = []
    }

    @ViewState private var hoverProbe = HoverProbe()

    /// One pellet dropped by a tap: sinks from the tap point toward
    /// the sand, claimed by the nearest free-swimming fish, eaten on
    /// arrival. Unit tank space.
    private struct FeedPellet {
        var id: Int
        var x: Double
        var y: Double
        /// Unit depth it settles at when nobody eats it.
        var restY: Double
        var bornAt: Date
    }

    /// The tank's frame-to-frame motion state (docs/TOYS.md: steering
    /// movement — wander, boundary, food-seek, light schooling). A
    /// plain reference held in `ViewState`: positions change every
    /// frame and are consumed inside the Canvas, so tracking them as
    /// SwiftUI state would just buy invalidations.
    private final class TankMotion {
        /// Unit-space swim bodies, one per free-swimming adult fish.
        var bodies: [String: SwimBody] = [:]
        /// The unit position a fish was at when its state last
        /// changed — the anchor the rise/sink/leave poses move from.
        var anchors: [String: (state: FishState, x: Double, y: Double)] = [:]
        /// The stage the view last drew, so a growth spurt can bounce.
        var stages: [String: Int] = [:]
        /// The last frame's clock, for `dt`.
        var lastT: Double = 0
        /// Tap-dropped food sinking toward the sand.
        var pellets: [FeedPellet] = []
        var pelletSeq = 0
        /// This frame's pellet → fish claims, rebuilt per step.
        var claims: [Int: String] = [:]
        /// A fish that just ate smiles & squash-stretches until these.
        var smileUntil: [String: Date] = [:]
        var bounceUntil: [String: Date] = [:]
        /// The swimmer drifting over to look at the pointer, if any.
        var curiousID: String?
        /// Tap-startled fish dart away from the point until the date;
        /// `from` is in view points.
        var startles: [String: (until: Date, from: CGPoint)] = [:]
        /// The silent "bloop": a small ring + specks at a fed pellet, a
        /// collected drop, a tap on the glass. Unit space.
        var puffs: [(x: Double, y: Double, bornAt: Date)] = []
        /// Pearls arcing home to the counter chip, in view points.
        var flights: [(from: CGPoint, bornAt: Date)] = []
        /// The last canvas size — the tap gesture needs it and the
        /// canvas is the only place that knows it.
        var size: CGSize = .zero
        /// This frame's pearl-drop hitboxes, in draw order.
        var dropBoxes: [(id: String, rect: CGRect)] = []
        /// The buried treasure's hitbox this frame, if it's up.
        var treasureBox: (id: String, rect: CGRect)?
        /// Gold bursts where a treasure opened — view points.
        var goldBursts: [(x: CGPoint, bornAt: Date)] = []
        /// A fish mid-trick after a tap: barrel roll or bubble ring.
        var tricks: [String: (kind: TrickKind, until: Date)] = [:]
        /// Tap count feeding the seeded 1-in-3 trick roll.
        var trickSeq = 0
        /// The visitor currently parading across the back layer, and
        /// when it started — `visitorShown` was answered at the start.
        var activeVisitor: (kind: AquariumVisitor, startedAt: Date)?
        /// A beat between parades so queued visitors don't conga.
        var visitorCooldownUntil = Date.distantPast
        /// Game events the draw pass produced, waiting to be reported.
        /// `stepSwim` and the visitor parade run inside the Canvas
        /// draw closure, where game events must not land — every one
        /// applies to the document and persists, and a draw pass is no
        /// place for disk I/O (nor for re-entrant mutation: a double
        /// evaluation would double-feed). `queueEventDrain` flushes
        /// the list once the pass returns, each event reported once.
        var pendingEvents: [PendingGameEvent] = []
        /// A drain is already queued for after this pass.
        var eventDrainQueued = false
        /// Which fish are at their station this frame — the cue pass
        /// only draws a fish's work where it is actually doing it.
        var stationed: [String: TankStation] = [:]
    }

    /// A game event a draw pass produced — recorded, not applied.
    private enum PendingGameEvent {
        /// A fish reached its pellet; `fishID` is the eater.
        case pelletEaten(fishID: String)
        /// A visitor's parade across the back layer began.
        case visitorShown(AquariumVisitor)
        /// The parade ended — the visitor swam off the far edge.
        case visitorDeparted(AquariumVisitor)
    }

    /// What a tapped fish shows off (docs/TOYS.md: fish tricks).
    enum TrickKind {
        case roll
        case ring
    }

    @ViewState private var motion = TankMotion()

    /// A tap on open water drops a pinch of food: three pellets around
    /// the point, sinking toward the bed. The game hears only about
    /// the ones a fish actually eats.
    private func feed(at point: CGPoint) {
        let size = motion.size
        guard size.width > 0, size.height > 0 else { return }
        let m = motion
        for _ in 0..<3 {
            m.pelletSeq += 1
            let h = AquariumModel.stableHash("pellet-\(m.pelletSeq)")
            let jx = (Double(h & 0xFF) / 0xFF - 0.5) * 0.06
            let px = min(0.96, max(0.04, point.x / size.width + jx))
            let py = min(0.88, max(0.05, point.y / size.height))
            m.pellets.append(FeedPellet(id: m.pelletSeq, x: px, y: py,
                                        restY: 0.865, bornAt: Date()))
        }
        if m.pellets.count > 14 { m.pellets.removeFirst(m.pellets.count - 14) }
        // A tap on the glass: fish near the poke dart a beat, then come
        // back for the food — startle first, supper after. And the tap
        // itself gets the little "bloop" ring.
        let ux = point.x / size.width, uy = point.y / size.height
        for (id, b) in m.bodies {
            let dx = b.x - ux, dy = b.y - uy
            if dx * dx + dy * dy < 0.022 {
                m.startles[id] = (until: Date().addingTimeInterval(0.55), from: point)
            }
        }
        m.puffs.append((x: ux, y: uy, bornAt: Date()))
    }

    /// One step of the steering world, run at the top of every live
    /// frame: sink & claim the pellets, school the providers, then
    /// step each free-swimming fish's body — the layout pass below
    /// just reads the results. Special states (rise/sink/leave) hold
    /// their bodies still; the pose functions animate from the anchor
    /// recorded where the state changed.
    private func stepSwim(_ roster: [Fish], in size: CGSize, t: Double, now: Date,
                          density: Double = 1) {
        let m = motion
        m.size = size
        // Reduce Motion ticks once a second: let the sim absorb real
        // elapsed time so sinking food and darting fish still arrive —
        // the motion reads as a stepped drift, not a frozen tank.
        let dt = min(reduceMotion ? 1.2 : 0.12, max(0, t - m.lastT))
        m.lastT = t

        let liveIDs = Set(roster.map(\.id))
        if m.bodies.count > roster.count {
            m.bodies = m.bodies.filter { liveIDs.contains($0.key) }
            m.anchors = m.anchors.filter { liveIDs.contains($0.key) }
            m.stages = m.stages.filter { liveIDs.contains($0.key) }
            m.startles = m.startles.filter { liveIDs.contains($0.key) }
            m.stationed = m.stationed.filter { liveIDs.contains($0.key) }
        }
        // Transient FX expiry — puffs and flights are draw-only state.
        m.startles = m.startles.filter { now < $0.value.until }
        m.puffs.removeAll { now.timeIntervalSince($0.bornAt) > 0.8 }
        m.flights.removeAll { now.timeIntervalSince($0.bornAt) > 0.85 }
        m.goldBursts.removeAll { now.timeIntervalSince($0.bornAt) > 1.2 }
        m.tricks = m.tricks.filter { now < $0.value.until && liveIDs.contains($0.key) }
        if m.puffs.count > 12 { m.puffs.removeFirst(m.puffs.count - 12) }
        if m.flights.count > 8 { m.flights.removeFirst(m.flights.count - 8) }

        // Pellets sink & expire.
        for i in m.pellets.indices {
            m.pellets[i].y = min(m.pellets[i].restY,
                                 m.pellets[i].y + 0.30 * dt)
        }
        m.pellets.removeAll { now.timeIntervalSince($0.bornAt) > 24 }

        // The free swimmers: adults cruising or idling.
        let swimmers = roster.filter {
            !$0.isFry && ($0.state == .swimming || $0.state == .idling)
                && !$0.isRetired(at: now)
        }
        for fish in swimmers where m.bodies[fish.id] == nil {
            m.bodies[fish.id] = spawnBody(for: fish, in: size)
        }

        // Claims: each pellet goes to the nearest swimmer.
        m.claims.removeAll(keepingCapacity: true)
        var foodByFish: [String: (x: Double, y: Double)] = [:]
        for pellet in m.pellets {
            var best: String?
            var bestD = Double.greatestFiniteMagnitude
            for fish in swimmers {
                guard let b = m.bodies[fish.id] else { continue }
                let dx = b.x - pellet.x, dy = b.y - pellet.y
                let d = dx * dx + dy * dy
                if d < bestD { bestD = d; best = fish.id }
            }
            if let best {
                m.claims[pellet.id] = best
                foodByFish[best] = (pellet.x, pellet.y)
            }
        }

        // Light schooling: the same-provider group's centre, computed
        // without the fish's own position.
        var memberCount: [String: Int] = [:]
        var sumX: [String: Double] = [:]
        var sumY: [String: Double] = [:]
        for fish in swimmers {
            guard let b = m.bodies[fish.id] else { continue }
            memberCount[fish.providerID, default: 0] += 1
            sumX[fish.providerID, default: 0] += b.x
            sumY[fish.providerID, default: 0] += b.y
        }

        // Curiosity: the swimmer nearest the hovering pointer drifts
        // over to look at it — a weak pull, never a dart, and only
        // while the pointer is actually in the water (below the HUD,
        // above the sand). Startled or eating fish have better things
        // to do.
        var pointerUnit: (x: Double, y: Double)?
        m.curiousID = nil
        if let point = hoverProbe.point, size.width > 1,
           point.y > 44, point.y < sandTop(atX: point.x, in: size) {
            let pu = (x: Double(point.x / size.width),
                      y: Double(point.y / size.height))
            var bestD = 0.16 * 0.16
            for fish in swimmers {
                guard m.startles[fish.id] == nil,
                      foodByFish[fish.id] == nil,
                      let b = m.bodies[fish.id] else { continue }
                let dx = b.x - pu.x, dy = b.y - pu.y
                let d = dx * dx + dy * dy
                if d < bestD { bestD = d; m.curiousID = fish.id }
            }
            if m.curiousID != nil { pointerUnit = pu }
        }

        let bounds = SwimBounds(
            minX: 0.05, minY: 30 / max(1, size.height),
            maxX: 0.95, maxY: (size.height - 100) / max(1, size.height),
            margin: 0.10)

        for fish in swimmers {
            guard var body = m.bodies[fish.id] else { continue }
            var context = SwimContext(bounds: bounds)
            // A startled fish darts away from the tap — expressed as a
            // pellet just past its tail, so the food-seek does the
            // darting. Unless a real pellet already claimed it: lunch
            // outranks a scare.
            if let s = m.startles[fish.id], foodByFish[fish.id] == nil {
                let dx = body.x * size.width - s.from.x
                let dy = body.y * size.height - s.from.y
                let len = max(1, (dx * dx + dy * dy).squareRoot())
                context.food = (x: min(0.98, max(0.02, body.x + dx / len * 0.45)),
                                y: min(0.92, max(0.02, body.y + dy / len * 0.45)))
            } else {
                context.food = foodByFish[fish.id]
            }
            if let n = memberCount[fish.providerID], n > 1,
               let sx = sumX[fish.providerID], let sy = sumY[fish.providerID],
               let b = m.bodies[fish.id] {
                context.school = (x: (sx - b.x) / Double(n - 1),
                                  y: (sy - b.y) / Double(n - 1))
            }
            // Curiosity wins over schooling: it pulls toward you.
            if fish.id == m.curiousID, let pu = pointerUnit {
                context.school = pu
            }
            let hungry = toy?.game.pets[fish.id]?.hungry(at: now) ?? false
            context.wander = fish.state == .idling ? 0.5 : 1.0
            context.hunger = hungry ? 1.3 : 1.0
            context.effort = fish.state == .idling ? 0.42 : 1.0
            // At work: the plan's tool-level action has a station, and
            // the fish goes and does it there — foraging the kelp for a
            // read, circling the wreck for a test. Expressed as a slow
            // seek on the station's moving point, so the glass, the
            // food and a startle all still outrank it: lunch first, a
            // poke still scares, and the work waits a beat.
            if context.food == nil, fish.state == .swimming,
               let cue = fish.cue, cue.isFresh(at: now),
               let anchor = stationAnchor(cue.station, for: fish, in: size,
                                          density: density, bounds: bounds) {
                let goal = AquariumStations.target(for: cue.station, anchor: anchor,
                                                   t: t, seed: fish.seed)
                let dx = goal.x - body.x, dy = goal.y - body.y
                context.food = (x: min(bounds.maxX, max(bounds.minX, goal.x)),
                                y: min(bounds.maxY, max(bounds.minY, goal.y)))
                context.hunger = AquariumStations.seekHunger
                context.wander = 0.35
                context.effort = AquariumStations.effort(for: cue.station,
                                                         distance: (dx * dx + dy * dy).squareRoot())
                m.stationed[fish.id] = cue.station
            } else {
                m.stationed.removeValue(forKey: fish.id)
            }
            AquariumSteering.step(&body, dt: dt, t: t, seed: fish.seed,
                                  context: context)
            m.bodies[fish.id] = body
        }

        // A fish that reached its pellet eats it: the game hears the
        // feeding after the pass (the pending-events drain), the mouth
        // smiles, the body squash-stretches.
        var eaten: [Int] = []
        for pellet in m.pellets {
            guard let claim = m.claims[pellet.id],
                  let b = m.bodies[claim] else { continue }
            let dx = b.x - pellet.x, dy = b.y - pellet.y
            if dx * dx + dy * dy < 0.0025 {
                eaten.append(pellet.id)
                m.smileUntil[claim] = now.addingTimeInterval(3.5)
                m.bounceUntil[claim] = now.addingTimeInterval(0.7)
                // The bloop ring where it ate, and the pearl flying home.
                m.puffs.append((x: pellet.x, y: pellet.y, bornAt: now))
                m.flights.append((from: CGPoint(x: pellet.x * size.width,
                                                y: pellet.y * size.height),
                                  bornAt: now))
                // Recorded, not applied — the game write waits for the
                // drain after this draw pass.
                m.pendingEvents.append(.pelletEaten(fishID: claim))
            }
        }
        if !eaten.isEmpty {
            m.pellets.removeAll { eaten.contains($0.id) }
        }

        // Anchors & stage-change bounces for every adult, whatever
        // state it's in — a rising/sinking/leaving fish poses from
        // where the state found it.
        for fish in roster where !fish.isFry {
            let b = m.bodies[fish.id]
            if m.anchors[fish.id]?.state != fish.state {
                m.anchors[fish.id] = (fish.state, b?.x ?? 0.5, b?.y ?? 0.5)
            }
            let stage = toy?.game.pets[fish.id]?.stage ?? 0
            if let seen = m.stages[fish.id], stage != seen {
                if stage > seen { m.bounceUntil[fish.id] = now.addingTimeInterval(0.9) }
                m.stages[fish.id] = stage
            } else if m.stages[fish.id] == nil {
                m.stages[fish.id] = stage
            }
        }
        queueEventDrain()
    }

    /// Flush the game events a draw pass recorded, once the Canvas
    /// closure has returned — one queued hop per frame, so a re-entrant
    /// or multiplied evaluation can never double-apply an event. The
    /// hop runs on the next main-queue turn: same tick, after the pass.
    private func queueEventDrain() {
        let m = motion
        guard !m.eventDrainQueued, !m.pendingEvents.isEmpty else { return }
        m.eventDrainQueued = true
        DispatchQueue.main.async { [weak toy] in
            MainActor.assumeIsolated {
                m.eventDrainQueued = false
                let pending = m.pendingEvents
                m.pendingEvents.removeAll(keepingCapacity: true)
                for event in pending {
                    switch event {
                    case .pelletEaten(let fishID): toy?.pelletEaten(by: fishID)
                    case .visitorShown(let visitor): toy?.visitorShown(visitor)
                    case .visitorDeparted(let visitor): toy?.visitorDeparted(visitor)
                    }
                }
            }
        }
    }

    /// A new fish's body, seeded off its id: starts inside the glass at
    /// its lane's depth, heading the way its swim says.
    private func spawnBody(for fish: Fish, in size: CGSize) -> SwimBody {
        let h = fish.seed
        func unit(_ shift: UInt64) -> Double {
            Double((h >> shift) & 0xFFFF) / 0xFFFF
        }
        let homeY = min(0.80, max(0.14,
                                  laneY(for: fish, in: size) / max(1, size.height)))
        return SwimBody(x: 0.15 + 0.7 * unit(0),
                        y: homeY,
                        heading: fish.direction > 0 ? 0 : .pi,
                        speed: fish.speed * 1.6,
                        turnRate: 1.8 + 1.2 * unit(24),
                        energy: 0.65 + 0.7 * unit(40),
                        homeY: homeY)
    }

    /// Where a fish's current state found it, in points — the anchor
    /// the rise/sink/leave poses move from. Falls back to the old
    /// patrol sweep when no body has stepped yet (the fixture path).
    private func anchor(of fish: Fish, in size: CGSize) -> CGPoint {
        if let a = motion.anchors[fish.id] {
            return CGPoint(x: a.x * size.width, y: a.y * size.height)
        }
        let p = patrol(of: fish, in: size,
                       at: fish.stateSince.timeIntervalSince1970, margin: 36)
        return CGPoint(x: p.x, y: laneY(for: fish, in: size))
    }

    /// The roster memo's box: the mains table and the depth-sorted
    /// draw order from the last distinct fish array. A plain reference
    /// held in `ViewState`, so a hit mutates nothing SwiftUI tracks —
    /// it's a memo, not state.
    private final class FishOrder {
        /// The fish array `mains`/`ordered` were built from.
        var source: [Fish] = []
        var mains: [String: Fish] = [:]
        /// Deep lanes first: the near fish swim over them.
        var ordered: [Fish] = []
    }

    @ViewState private var orderCache = FishOrder()

    /// Resolved label glyphs, kept across frames: `resolve` +
    /// `measure` were the priciest part of drawing a fish on a busy
    /// tank, and a label's glyphs never change between reduces. A
    /// plain reference held in `ViewState` — it's a memo, not state.
    private final class TextCache {
        /// Floating name chips under swimming fish (9.5 medium).
        var chips: [String: (text: GraphicsContext.ResolvedText, size: CGSize)] = [:]
        /// The hover/tap nameplate (caption2 semibold).
        var tags: [String: (text: GraphicsContext.ResolvedText, size: CGSize)] = [:]

        func chip(for label: String, canvas: GraphicsContext)
            -> (text: GraphicsContext.ResolvedText, size: CGSize) {
            if let hit = chips[label] { return hit }
            let c = canvas
            let resolved = c.resolve(
                Text(label)
                    .font(.system(size: 9.5, weight: .medium))
                    .foregroundStyle(.white.opacity(0.90)))
            let measured = resolved.measure(in: CGSize(width: 1000, height: 40))
            if chips.count > 128 { chips.removeAll(keepingCapacity: true) }
            chips[label] = (resolved, measured)
            return (resolved, measured)
        }

        func tag(for label: String, canvas: GraphicsContext)
            -> (text: GraphicsContext.ResolvedText, size: CGSize) {
            if let hit = tags[label] { return hit }
            let c = canvas
            let resolved = c.resolve(
                Text(label)
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.white.opacity(0.97)))
            let measured = resolved.measure(in: CGSize(width: 1000, height: 40))
            if tags.count > 128 { tags.removeAll(keepingCapacity: true) }
            tags[label] = (resolved, measured)
            return (resolved, measured)
        }
    }

    @ViewState private var textCache = TextCache()

    /// The mains table and the back-to-front draw order, rebuilt only
    /// when the fish array itself changes — never twice on the same
    /// roster, no matter how often the timeline ticks.
    private func fishOrder(_ fish: [Fish]) -> (ordered: [Fish], mains: [String: Fish]) {
        let cache = orderCache
        guard cache.source != fish else { return (cache.ordered, cache.mains) }
        let mains = mainsByID(fish)
        let ordered = fish.sorted { depth(of: $0, mains: mains) > depth(of: $1, mains: mains) }
        cache.source = fish
        cache.mains = mains
        cache.ordered = ordered
        return (ordered, mains)
    }

    /// The tank's adult fish by id — fry anchor to these.
    private func mainsByID(_ fish: [Fish]) -> [String: Fish] {
        Dictionary(fish.filter { !$0.isFry }.map { ($0.id, $0) },
                   uniquingKeysWith: { first, _ in first })
    }

    /// Draw order: a fry rides at its school's depth, not its own lane.
    private func depth(of fish: Fish, mains: [String: Fish]) -> Double {
        if fish.isFry, let anchor = fish.anchorID.flatMap({ mains[$0] }) {
            return anchor.lane * 0.85
        }
        return fish.lane
    }

    /// The fish a fry schools around, with its already-computed layout.
    private func parentContext(of fish: Fish, mains: [String: Fish],
                               layouts: [String: Layout]) -> (fish: Fish, layout: Layout)? {
        guard let id = fish.anchorID, let parent = mains[id], let l = layouts[id] else { return nil }
        return (parent, l)
    }

    // MARK: Completion FX

    /// One dropped pellet's course: where it appeared, where it sinks
    /// to rest, and which fish comes to eat it. Everything derives
    /// from the leaver's seed & `stateSince`, so the same meal replays
    /// identically every frame.
    private struct Pellet {
        var origin: CGPoint
        var rest: CGPoint
        var r: Double
        var wobble: Double
        /// The eating fish's id, if a live adult was close enough to
        /// claim it.
        var eater: String?
        /// Seconds the eater needs to reach the pellet once it darts.
        var dart: Double
        /// Age (s since the leaver turned) at which the pellet is gone —
        /// eaten, or faded on the sand when nobody came.
        var gone: Double
    }

    /// The meal a finished fish leaves behind: the spot it was at when
    /// it turned for the edge, plus its pellets.
    private struct Meal {
        var leaver: Fish
        var spawn: CGPoint
        var pellets: [Pellet]
    }

    /// Plan each leaving fish's meal (docs/TOYS.md: a completion drops
    /// food, nearby fish come eat it). Pure functions of the roster &
    /// the leavers' seeds — nothing here is stateful.
    private func completionMeals(in size: CGSize, now: Date, roster: [Fish]) -> [Meal] {
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
            let t0 = leaver.stateSince.timeIntervalSince1970
            let spawn = anchor(of: leaver, in: size)
            // The live adults who could come for the food.
            let eaters = roster.filter {
                !$0.isFry && $0.id != leaver.id
                    && ($0.state == .swimming || $0.state == .idling)
                    && !$0.isRetired(at: now)
            }
            var claimed: Set<String> = []
            var pellets: [Pellet] = []
            for seed in AquariumModel.pelletSeeds(for: leaver) {
                let dx = (Double(seed & 0xFF) / 0xFF - 0.5) * 64
                let restX = min(max(spawn.x + dx, margin), size.width - margin)
                let restY = min(spawn.y + 34 + Double((seed >> 8) & 0xFF) / 0xFF * 26,
                                sandTop(atX: restX, in: size) - 6)
                var pellet = Pellet(
                    origin: spawn,
                    rest: CGPoint(x: restX, y: restY),
                    r: 2.4 + Double((seed >> 16) & 0xFF) / 0xFF * 1.4,
                    wobble: Double((seed >> 24) & 0xFF) / 0xFF * .pi * 2,
                    eater: nil, dart: 0,
                    gone: 9 + Double((seed >> 32) & 0xFF) / 0xFF * 2)
                // The nearest unclaimed live fish comes for it.
                var best: Fish?
                var bestD2 = Double.greatestFiniteMagnitude
                for e in eaters where !claimed.contains(e.id) {
                    // The eater's real spot: its steering body, else
                    // the sweep stand-in.
                    let ep = motion.bodies[e.id].map {
                        CGPoint(x: $0.x * size.width, y: $0.y * size.height)
                    } ?? CGPoint(x: patrol(of: e, in: size, at: t0, margin: margin).x,
                                 y: laneY(for: e, in: size))
                    let d2 = (ep.x - restX) * (ep.x - restX)
                        + (ep.y - restY) * (ep.y - restY)
                    if d2 < bestD2 { bestD2 = d2; best = e }
                }
                if let best {
                    claimed.insert(best.id)
                    pellet.eater = best.id
                    pellet.dart = min(2.4, max(0.5, sqrt(bestD2) / 140))
                    pellet.gone = 0.85 + pellet.dart
                }
                pellets.append(pellet)
            }
            meals.append(Meal(leaver: leaver, spawn: spawn, pellets: pellets))
        }
        return meals
    }

    /// Bend the eaters' layouts toward their pellets: a pull that
    /// swells as the fish darts over, holds while it mouths the food,
    /// then releases it back onto its patrol.
    private func applyPursuits(_ meals: [Meal], to layouts: inout [String: Layout], now: Date) {
        for meal in meals {
            let age = now.timeIntervalSince(meal.leaver.stateSince)
            for pellet in meal.pellets {
                guard let eater = pellet.eater, var l = layouts[eater] else { continue }
                // The dart starts as the pellet drops and releases a
                // beat after the fish arrives.
                let pull = smooth(clamp01((age - 0.7) / pellet.dart))
                    - smooth(clamp01((age - 0.7 - pellet.dart - 0.45) / 1.0))
                guard pull > 0.001 else { continue }
                let tx = pellet.rest.x
                let ty = pellet.rest.y - 6
                if pull > 0.15 { l.facing = tx >= l.x ? 1 : -1 }
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
    private func drawMeals(canvas: inout GraphicsContext, meals: [Meal], now: Date) {
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
                let sink = smooth(clamp01((age - 0.35) / 1.5))
                let a = appear * (1 - smooth(clamp01((age - pellet.gone) / 0.3)))
                guard a > 0.01 else { continue }
                let x = pellet.origin.x + (pellet.rest.x - pellet.origin.x) * sink
                    + (reduceMotion ? 0 : sin(age * 2.4 + pellet.wobble) * 3)
                let y = pellet.origin.y + (pellet.rest.y - pellet.origin.y) * sink
                let r = pellet.r * (0.5 + 0.5 * appear)
                canvas.fill(
                    Path(ellipseIn: CGRect(x: x - r, y: y - r, width: r * 2, height: r * 2)),
                    with: .color(Color(red: 0.55, green: 0.38, blue: 0.20).opacity(a)))
                canvas.fill(
                    Path(ellipseIn: CGRect(x: x - r * 0.4, y: y - r * 0.55,
                                           width: r * 0.8, height: r * 0.5)),
                    with: .color(Color(red: 0.85, green: 0.68, blue: 0.42).opacity(a * 0.5)))
            }
        }
    }

    /// The milestone burst: a fast plume of bubbles off the chest lid
    /// while the window is open — a batch of finishes pops the chest.
    /// Anchored to the seeded chest piece, so the plume actually rises
    /// off the lid wherever the layout put it.
    private func drawChestBurst(canvas: inout GraphicsContext, size: CGSize, age: Double) {
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

    /// The hover/tap tag: a bright capsule with the fish's label,
    /// parked just above the body. Fry get it too — this is where a
    /// worker's name shows when labels are off.
    private func drawNameplate(canvas: inout GraphicsContext, size: CGSize,
                               fish: Fish, layout l: Layout) {
        let length = 46 * l.scale * fish.species.sizeScale
            * (fish.isFry ? AquariumModel.fryScale : 1)
        let height = length * fish.species.aspect
        let tag = canvas
        let resolved: GraphicsContext.ResolvedText
        let textSize: CGSize
        (resolved, textSize) = textCache.tag(for: fish.label, canvas: canvas)
        let cx = min(max(l.x, textSize.width / 2 + 14),
                     size.width - textSize.width / 2 - 14)
        let cy = max(l.y - height * 0.5 - 18, 16)
        let rect = CGRect(x: cx - textSize.width / 2 - 9,
                          y: cy - textSize.height / 2 - 4,
                          width: textSize.width + 18, height: textSize.height + 8)
        let pill = Path(roundedRect: rect, cornerRadius: rect.height / 2)
        tag.fill(pill, with: .color(Color(red: 0.02, green: 0.08, blue: 0.16).opacity(0.78)))
        tag.stroke(pill, with: .color(.white.opacity(0.28)), lineWidth: 0.75)
        tag.draw(resolved, at: CGPoint(x: cx, y: cy), anchor: .center)
    }

    // MARK: Water

    /// The column of water itself: a many-stop gradient from the bright
    /// green-teal surface down to a deep indigo floor — more stops in
    /// the deep half now, so the column keeps a blue-green cast all the
    /// way down instead of collapsing to flat navy — a warm glow
    /// where the light comes in, and a faint cool counter-glow low on
    /// the right so the far side never goes dead flat. Drawn in the
    /// still pass; the only animated parts are the two slow washes.
    /// The water column's gradient per theme (docs/TOYS.md shop):
    /// the shop's theme items recolour the tank — a stop list per
    /// theme id, "classic" the default the game starts with.
    private var waterStops: [Gradient.Stop] {
        switch themeKey {
        case "reef":
            return [
                .init(color: Color(red: 0.36, green: 0.72, blue: 0.78), location: 0),
                .init(color: Color(red: 0.20, green: 0.58, blue: 0.72), location: 0.12),
                .init(color: Color(red: 0.10, green: 0.42, blue: 0.64), location: 0.30),
                .init(color: Color(red: 0.05, green: 0.28, blue: 0.54), location: 0.52),
                .init(color: Color(red: 0.03, green: 0.17, blue: 0.44), location: 0.72),
                .init(color: Color(red: 0.02, green: 0.10, blue: 0.34), location: 0.88),
                .init(color: Color(red: 0.015, green: 0.05, blue: 0.24), location: 1),
            ]
        case "lagoon":
            return [
                .init(color: Color(red: 0.55, green: 0.90, blue: 0.78), location: 0),
                .init(color: Color(red: 0.36, green: 0.80, blue: 0.72), location: 0.12),
                .init(color: Color(red: 0.20, green: 0.62, blue: 0.66), location: 0.30),
                .init(color: Color(red: 0.10, green: 0.42, blue: 0.56), location: 0.52),
                .init(color: Color(red: 0.05, green: 0.26, blue: 0.45), location: 0.72),
                .init(color: Color(red: 0.03, green: 0.15, blue: 0.34), location: 0.88),
                .init(color: Color(red: 0.02, green: 0.08, blue: 0.25), location: 1),
            ]
        case "twilight":
            return [
                .init(color: Color(red: 0.42, green: 0.52, blue: 0.78), location: 0),
                .init(color: Color(red: 0.28, green: 0.40, blue: 0.68), location: 0.12),
                .init(color: Color(red: 0.16, green: 0.28, blue: 0.56), location: 0.30),
                .init(color: Color(red: 0.09, green: 0.17, blue: 0.44), location: 0.52),
                .init(color: Color(red: 0.05, green: 0.10, blue: 0.34), location: 0.72),
                .init(color: Color(red: 0.03, green: 0.06, blue: 0.26), location: 0.88),
                .init(color: Color(red: 0.02, green: 0.03, blue: 0.18), location: 1),
            ]
        case "midnight":
            return [
                .init(color: Color(red: 0.10, green: 0.16, blue: 0.30), location: 0),
                .init(color: Color(red: 0.07, green: 0.12, blue: 0.27), location: 0.12),
                .init(color: Color(red: 0.05, green: 0.09, blue: 0.23), location: 0.30),
                .init(color: Color(red: 0.03, green: 0.06, blue: 0.19), location: 0.52),
                .init(color: Color(red: 0.02, green: 0.04, blue: 0.15), location: 0.72),
                .init(color: Color(red: 0.015, green: 0.03, blue: 0.12), location: 0.88),
                .init(color: Color(red: 0.01, green: 0.02, blue: 0.09), location: 1),
            ]
        case "dawn":
            return [
                .init(color: Color(red: 0.86, green: 0.62, blue: 0.66), location: 0),
                .init(color: Color(red: 0.68, green: 0.55, blue: 0.68), location: 0.12),
                .init(color: Color(red: 0.42, green: 0.48, blue: 0.66), location: 0.30),
                .init(color: Color(red: 0.22, green: 0.36, blue: 0.58), location: 0.52),
                .init(color: Color(red: 0.11, green: 0.24, blue: 0.47), location: 0.72),
                .init(color: Color(red: 0.05, green: 0.14, blue: 0.36), location: 0.88),
                .init(color: Color(red: 0.03, green: 0.08, blue: 0.26), location: 1),
            ]
        case "kelp":
            return [
                .init(color: Color(red: 0.52, green: 0.74, blue: 0.42), location: 0),
                .init(color: Color(red: 0.34, green: 0.62, blue: 0.40), location: 0.12),
                .init(color: Color(red: 0.19, green: 0.48, blue: 0.38), location: 0.30),
                .init(color: Color(red: 0.10, green: 0.34, blue: 0.34), location: 0.52),
                .init(color: Color(red: 0.05, green: 0.22, blue: 0.28), location: 0.72),
                .init(color: Color(red: 0.03, green: 0.13, blue: 0.21), location: 0.88),
                .init(color: Color(red: 0.02, green: 0.08, blue: 0.15), location: 1),
            ]
        case "abyss":
            return [
                .init(color: Color(red: 0.05, green: 0.08, blue: 0.17), location: 0),
                .init(color: Color(red: 0.035, green: 0.06, blue: 0.14), location: 0.12),
                .init(color: Color(red: 0.025, green: 0.045, blue: 0.11), location: 0.30),
                .init(color: Color(red: 0.018, green: 0.03, blue: 0.08), location: 0.52),
                .init(color: Color(red: 0.012, green: 0.02, blue: 0.06), location: 0.72),
                .init(color: Color(red: 0.008, green: 0.015, blue: 0.045), location: 0.88),
                .init(color: Color(red: 0.005, green: 0.01, blue: 0.03), location: 1),
            ]
        case "sunset":
            return [
                .init(color: Color(red: 0.92, green: 0.55, blue: 0.30), location: 0),
                .init(color: Color(red: 0.80, green: 0.42, blue: 0.38), location: 0.12),
                .init(color: Color(red: 0.55, green: 0.30, blue: 0.48), location: 0.30),
                .init(color: Color(red: 0.32, green: 0.20, blue: 0.50), location: 0.52),
                .init(color: Color(red: 0.18, green: 0.12, blue: 0.44), location: 0.72),
                .init(color: Color(red: 0.09, green: 0.07, blue: 0.34), location: 0.88),
                .init(color: Color(red: 0.05, green: 0.04, blue: 0.25), location: 1),
            ]
        case "blackwater":
            return [
                .init(color: Color(red: 0.52, green: 0.42, blue: 0.26), location: 0),
                .init(color: Color(red: 0.42, green: 0.33, blue: 0.20), location: 0.12),
                .init(color: Color(red: 0.32, green: 0.24, blue: 0.15), location: 0.30),
                .init(color: Color(red: 0.22, green: 0.16, blue: 0.10), location: 0.52),
                .init(color: Color(red: 0.14, green: 0.10, blue: 0.07), location: 0.72),
                .init(color: Color(red: 0.09, green: 0.06, blue: 0.05), location: 0.88),
                .init(color: Color(red: 0.05, green: 0.04, blue: 0.03), location: 1),
            ]
        default:
            return [
                .init(color: Color(red: 0.46, green: 0.79, blue: 0.72), location: 0),
                .init(color: Color(red: 0.27, green: 0.65, blue: 0.65), location: 0.12),
                .init(color: Color(red: 0.13, green: 0.49, blue: 0.60), location: 0.30),
                .init(color: Color(red: 0.06, green: 0.31, blue: 0.51), location: 0.52),
                .init(color: Color(red: 0.035, green: 0.19, blue: 0.41), location: 0.72),
                .init(color: Color(red: 0.02, green: 0.11, blue: 0.31), location: 0.88),
                .init(color: Color(red: 0.015, green: 0.06, blue: 0.22), location: 1),
            ]
        }
    }

    private func drawWater(canvas: inout GraphicsContext, size: CGSize, t: Double) {
        canvas.fill(
            Path(CGRect(origin: .zero, size: size)),
            with: .linearGradient(
                Gradient(stops: waterStops),
                startPoint: CGPoint(x: size.width / 2, y: 0),
                endPoint: CGPoint(x: size.width / 2, y: size.height)))
        // The dark themes' moonlight: the same warm glow dimmed &
        // cooled, and a deeper night wash below.
        let dark = isDarkTheme
        var glow = canvas
        glow.blendMode = .plusLighter
        glow.fill(Path(CGRect(origin: .zero, size: size)),
                  with: .radialGradient(
                      Gradient(colors: [(dark
                                         ? Color(red: 0.72, green: 0.80, blue: 0.98)
                                         : Color(red: 0.95, green: 0.88, blue: 0.66))
                                        .opacity(dark ? 0.13 : 0.22), .clear]),
                      center: CGPoint(x: size.width * 0.36, y: -size.height * 0.10),
                      startRadius: 0, endRadius: size.width * 0.62))
        glow.fill(Path(CGRect(origin: .zero, size: size)),
                  with: .radialGradient(
                      Gradient(colors: [Color(red: 0.20, green: 0.50, blue: 0.62)
                                        .opacity(dark ? 0.06 : 0.10), .clear]),
                      center: CGPoint(x: size.width * 0.88, y: size.height * 0.55),
                      startRadius: 0, endRadius: size.width * 0.5))
        // The day/night wash (docs/TOYS.md): the clock the settings
        // picked — the four-minute breathe or the real one. Reduce
        // Motion holds it at a soft dusk.
        let night = nightFactor(t: t)
        canvas.fill(Path(CGRect(origin: .zero, size: size)),
                    with: .color(Color(red: 0.02, green: 0.05, blue: 0.22)
                                 .opacity(dark ? 0.10 + 0.06 * night : 0.10 * night)))
        canvas.fill(Path(CGRect(origin: .zero, size: size)),
                    with: .linearGradient(
                        Gradient(stops: [
                            .init(color: Color(red: 0.99, green: 0.82, blue: 0.45)
                                    .opacity(0.05 * (1 - night)), location: 0),
                            .init(color: .clear, location: 0.5),
                        ]),
                        startPoint: .zero,
                        endPoint: CGPoint(x: 0, y: size.height)))
    }

    /// Soft light shafts leaning down from the surface. Each ray is its
    /// own layer: a gradient across the beam gives the soft edges and a
    /// masking gradient fades it with depth, so there are no hard
    /// polygon sides. They breathe & sway a couple of degrees; Reduce
    /// Motion holds them still. This draws in the additive pass, so a
    /// ray that reaches the floor lights the sand it lands on.
    private func drawGodRays(canvas: inout GraphicsContext, size: CGSize, t: Double) {
        // The abyss has no sun; blackwater's tannin murk swallows all
        // but a few shafts; night dims whatever the theme allows.
        guard themeKey != "abyss" else { return }
        let count = themeKey == "blackwater" ? 2 : 5
        let daylight = 1 - nightFactor(t: t) * 0.55
        let rayColor = Color(red: 0.86, green: 0.97, blue: 0.93)
        for i in 0..<count {
            let h = AquariumModel.stableHash("ray-\(i)")
            let jitter = Double(h & 0xFF) / 0xFF
            let phase = Double((h >> 8) & 0xFF) / 0xFF * .pi * 2
            let speed = 0.030 + Double((h >> 16) & 0xFF) / 0xFF * 0.035
            let anchorX = size.width * (0.08 + 0.21 * Double(i) + jitter * 0.07)
            let halfW = 18 + Double((h >> 24) & 0xFF) / 0xFF * 34
            let lean = 0.20 + jitter * 0.18
            let sway = reduceMotion ? 0 : sin(t * speed + phase) * 0.030
            let breathe = (reduceMotion ? 0.45 : 0.36 + 0.32 * sin(t * 0.06 + phase * 1.7))
                * daylight
            // Off-centre bright core so the beam isn't a flat band.
            let core = 0.4 + Double((h >> 32) & 0xFF) / 0xFF * 0.2

            var r = canvas
            r.blendMode = .plusLighter
            r.drawLayer { layer in
                layer.translateBy(x: anchorX, y: -14)
                layer.rotate(by: .radians(lean + sway))
                let length = size.height * 1.35
                let beam = CGRect(x: -halfW, y: 0, width: halfW * 2, height: length)
                layer.fill(Path(beam), with: .linearGradient(
                    Gradient(stops: [
                        .init(color: rayColor.opacity(0), location: 0),
                        .init(color: rayColor.opacity(0.035 * breathe), location: core - 0.28),
                        .init(color: rayColor.opacity(0.10 * breathe), location: core),
                        .init(color: rayColor.opacity(0.035 * breathe), location: core + 0.28),
                        .init(color: rayColor.opacity(0), location: 1),
                    ]),
                    startPoint: CGPoint(x: -halfW, y: 0),
                    endPoint: CGPoint(x: halfW, y: 0)))
                // Fade with depth — destinationIn keeps the soft edges.
                layer.blendMode = .destinationIn
                layer.fill(Path(beam), with: .linearGradient(
                    Gradient(stops: [
                        .init(color: .white, location: 0),
                        .init(color: .white, location: 0.45),
                        .init(color: .white.opacity(0), location: 0.95),
                    ]),
                    startPoint: .zero, endPoint: CGPoint(x: 0, y: length)))
            }
        }
    }

    /// Caustic dapples: a few soft pools of warm light riding the dune
    /// crest, wandering back and forth and breathing on slow, seeded
    /// phases — sunlight focused through the surface ripples onto the
    /// bed. Drawn in the additive pass so they read as light, and
    /// seeded through the same murmur-style scramble the speckles use
    /// so FNV-1a's low bits can't park them in a row.
    private func drawSandCaustics(canvas: inout GraphicsContext, size: CGSize, t: Double) {
        // White aragonite bounces the light back — its pools burn
        // brighter; dark gravel drinks it.
        let boost = substrateKey == "white" ? 1.7
            : substrateKey == "black" ? 0.6 : 1.0
        for i in 0..<4 {
            var h = AquariumModel.stableHash("caustic-\(i)")
            h ^= h >> 33
            h &*= 0xff51afd7ed558ccd
            h ^= h >> 33
            let x0 = Double(h & 0xFFFF) / 0xFFFF
            let phase = Double((h >> 16) & 0xFF) / 0xFF * .pi * 2
            // Ping-pong wander: sin keeps the pool sliding without the
            // wrap-around jump a `frac` drift would take at the wall.
            let wander = reduceMotion ? 0.5
                : 0.5 + 0.5 * sin(t * (0.05 + Double((h >> 24) & 0xFF) / 0xFF * 0.05) + phase)
            let cx = size.width * (0.08 + 0.84 * (x0 * 0.45 + wander * 0.55))
            let cy = sandTop(atX: cx, in: size) + 5 + Double((h >> 32) & 0xF)
            let rx = 46 + Double((h >> 40) & 0xFF) / 0xFF * 58
            let ry = rx * (0.15 + Double((h >> 48) & 0xF) / 0xF * 0.09)
            let breathe = reduceMotion ? 0.55
                : 0.55 + 0.45 * sin(t * 0.23 + phase * 1.9)
            var s = canvas
            s.translateBy(x: cx, y: cy)
            s.scaleBy(x: rx, y: ry)
            s.fill(Path(ellipseIn: CGRect(x: -1, y: -1, width: 2, height: 2)),
                   with: .radialGradient(
                       Gradient(colors: [
                           Color(red: 1.0, green: 0.94, blue: 0.74).opacity(0.10 * breathe * boost),
                           .clear]),
                       center: .zero, startRadius: 0, endRadius: 1))
        }
    }

    /// A slow luminance drift through the column: two broad, soft
    /// light pools sliding against each other on multi-minute periods.
    /// The water feels like it moves even between the rays; Reduce
    /// Motion holds both still.
    private func drawWaterSheen(canvas: inout GraphicsContext, size: CGSize, t: Double) {
        let spots: [(cx: Double, cy: Double, r: Double, period: Double,
                     phase: Double, alpha: Double)] = [
            (0.42, 0.26, 0.34, 190, 0, 0.050),
            (0.68, 0.58, 0.26, 310, 2.1, 0.034),
        ]
        for spot in spots {
            let drift = reduceMotion ? 0 : sin(t * .pi * 2 / spot.period + spot.phase)
            var s = canvas
            s.translateBy(x: size.width * (spot.cx + 0.15 * drift), y: size.height * spot.cy)
            s.rotate(by: .radians(-0.45))
            s.scaleBy(x: 1, y: 0.62)
            s.fill(Path(ellipseIn: CGRect(x: -size.width * spot.r, y: -size.width * spot.r,
                                          width: size.width * spot.r * 2,
                                          height: size.width * spot.r * 2)),
                   with: .radialGradient(
                       Gradient(colors: [
                           Color(red: 0.75, green: 0.95, blue: 0.88).opacity(spot.alpha),
                           .clear]),
                       center: .zero, startRadius: 0,
                       endRadius: size.width * spot.r))
        }
    }

    /// The water's surface: a soft bright band just under the glass,
    /// three wandering caustic bands (wide, low-contrast strokes), and
    /// the thin bright meniscus line on top.
    private func drawSurface(canvas: inout GraphicsContext, size: CGSize, t: Double) {
        canvas.fill(Path(CGRect(x: 0, y: 0, width: size.width, height: 36)),
                    with: .linearGradient(
                        Gradient(stops: [
                            .init(color: .white.opacity(0.16), location: 0),
                            .init(color: .white.opacity(0.05), location: 0.5),
                            .init(color: .clear, location: 1),
                        ]),
                        startPoint: .zero,
                        endPoint: CGPoint(x: 0, y: 36)))
        for r in 0..<3 {
            let y0 = 10 + Double(r) * 9
            let amp = 2.0 + Double(r) * 0.8
            let drift = reduceMotion ? 0 : t * (0.34 + Double(r) * 0.13)
            var wave = Path()
            wave.move(to: CGPoint(x: 0, y: y0))
            var x = 0.0
            while x <= size.width {
                let y = y0 + sin(x * 0.045 + drift + Double(r) * 2.3) * amp
                    + sin(x * 0.011 - drift * 0.6) * amp * 0.5
                wave.addLine(to: CGPoint(x: x, y: y))
                x += 8
            }
            let shimmer = reduceMotion ? 0.6 : 0.60 + 0.40 * sin(t * 0.45 + Double(r) * 2.1)
            canvas.stroke(wave,
                          with: .color(.white.opacity((0.065 - Double(r) * 0.016) * shimmer)),
                          style: StrokeStyle(lineWidth: 7 - Double(r) * 1.8, lineCap: .round))
        }
        // The meniscus: a bright hairline with a barely-there wobble,
        // plus a soft halo a couple of pixels under it.
        var line = Path()
        line.move(to: CGPoint(x: 0, y: 1.4))
        var x = 0.0
        while x <= size.width {
            line.addLine(to: CGPoint(x: x, y: 1.4
                                     + sin(x * 0.05 + (reduceMotion ? 0 : t * 0.4)) * 0.7))
            x += 8
        }
        canvas.stroke(line, with: .color(.white.opacity(0.18)), lineWidth: 3.4)
        canvas.stroke(line, with: .color(.white.opacity(0.42)), lineWidth: 1.2)
    }

    // MARK: Floor

    /// Seeded phases for the dune profile — fixed across launches.
    private static let dunePhase1 =
        Double(AquariumModel.stableHash("dune-p1") & 0xFFFF) / 0xFFFF * .pi * 2
    private static let dunePhase2 =
        Double(AquariumModel.stableHash("dune-p2") & 0xFFFF) / 0xFFFF * .pi * 2

    /// The dune crest the whole floor agrees on — closed form, so a
    /// chest, a fish shadow or a kelp root can sit exactly on the sand
    /// at any x. Three stacked harmonics give two or three overlapping
    /// rounded humps rather than a flat bar; the bed stands ~10–14% of
    /// the tank tall: a real floor, not a sliver.
    private func sandTop(atX x: Double, in size: CGSize) -> Double {
        let u = x / max(1, size.width)
        return size.height
            - (76 + 9 * sin(u * .pi * 2.3 + Self.dunePhase1)
               + 5 * sin(u * .pi * 4.9 + Self.dunePhase2)
               + 2.5 * sin(u * .pi * 8.1 + Self.dunePhase1 * 2))
    }

    /// The back dune's crest, a layer higher on screen: the bed
    /// running away from the glass. A good stone's throw behind the
    /// front crest so the two dunes read as separate layers.
    private func backDuneTop(atX x: Double, in size: CGSize) -> Double {
        let u = x / max(1, size.width)
        return sandTop(atX: x, in: size) - 30 - 8 * sin(u * .pi * 3.4 + Self.dunePhase2 * 1.7)
    }

    /// One seeded grain of sand, in unit space.
    private struct Speck {
        var x, y, r: Double
        var light: Bool
    }

    /// ~110 grains scattered over the bed, seeded once. The hash goes
    /// through the same murmur-style finalizer `decorSet` uses —
    /// FNV-1a's low bits cluster on sequential tags and would lay the
    /// grains out in rows.
    private static let sandSpeckles: [Speck] = (0..<150).map { i in
        var h = AquariumModel.stableHash("speck-\(i)")
        h ^= h >> 33
        h &*= 0xff51afd7ed558ccd
        h ^= h >> 33
        return Speck(x: Double(h & 0xFFFF) / 0xFFFF,
                     y: Double((h >> 16) & 0xFFFF) / 0xFFFF,
                     r: 0.6 + Double((h >> 32) & 0xF) / 0xF * 1.3,
                     light: (h >> 48) & 1 == 0)
    }

    /// The floor's palette per substrate (docs/TOYS.md shop): classic
    /// tan, white's bright aragonite, black's basalt gravel — the
    /// grains, crest and ripples all follow.
    private var sandTones: (backA: Color, backB: Color, frontA: Color,
                            frontB: Color, frontC: Color, crest: Color,
                            rim: Color, ripple: Color,
                            speckLight: Color, speckDark: Color) {
        switch substrateKey {
        case "white":
            return (Color(red: 0.46, green: 0.45, blue: 0.42),
                    Color(red: 0.18, green: 0.19, blue: 0.22),
                    Color(red: 0.97, green: 0.95, blue: 0.88),
                    Color(red: 0.82, green: 0.79, blue: 0.68),
                    Color(red: 0.48, green: 0.44, blue: 0.34),
                    Color(red: 1.0, green: 1.0, blue: 0.94),
                    Color(red: 1.0, green: 0.98, blue: 0.86),
                    Color(red: 0.50, green: 0.45, blue: 0.34),
                    Color(red: 1.0, green: 0.99, blue: 0.94),
                    Color(red: 0.42, green: 0.38, blue: 0.30))
        case "black":
            return (Color(red: 0.10, green: 0.11, blue: 0.14),
                    Color(red: 0.02, green: 0.02, blue: 0.04),
                    Color(red: 0.22, green: 0.23, blue: 0.28),
                    Color(red: 0.12, green: 0.13, blue: 0.16),
                    Color(red: 0.04, green: 0.04, blue: 0.05),
                    Color(red: 0.62, green: 0.65, blue: 0.72),
                    Color(red: 0.52, green: 0.55, blue: 0.62),
                    Color(red: 0.03, green: 0.03, blue: 0.04),
                    Color(red: 0.60, green: 0.63, blue: 0.70),
                    Color(red: 0.01, green: 0.01, blue: 0.02))
        default:
            return (Color(red: 0.23, green: 0.22, blue: 0.18),
                    Color(red: 0.06, green: 0.07, blue: 0.11),
                    Color(red: 0.72, green: 0.62, blue: 0.42),
                    Color(red: 0.46, green: 0.37, blue: 0.23),
                    Color(red: 0.15, green: 0.12, blue: 0.08),
                    Color(red: 0.98, green: 0.88, blue: 0.60),
                    Color(red: 0.88, green: 0.78, blue: 0.56),
                    Color(red: 0.20, green: 0.15, blue: 0.09),
                    Color(red: 0.82, green: 0.72, blue: 0.50),
                    Color(red: 0.10, green: 0.08, blue: 0.05))
        }
    }

    /// The floor: a darker back dune (the far end of the bed) with a
    /// shadowed seam above it, the lit front dune, and a scatter of
    /// seeded grains.
    private func drawSand(canvas: inout GraphicsContext, size: CGSize) {
        let sand = sandTones
        var back = Path()
        back.move(to: CGPoint(x: 0, y: backDuneTop(atX: 0, in: size)))
        var x = 0.0
        while x <= size.width {
            back.addLine(to: CGPoint(x: x, y: backDuneTop(atX: x, in: size)))
            x += 8
        }
        back.addLine(to: CGPoint(x: size.width, y: size.height))
        back.addLine(to: CGPoint(x: 0, y: size.height))
        back.closeSubpath()
        canvas.fill(back, with: .linearGradient(
            Gradient(colors: [sand.backA, sand.backB]),
            startPoint: CGPoint(x: 0, y: backDuneTop(atX: size.width / 2, in: size)),
            endPoint: CGPoint(x: 0, y: size.height)))

        // The dark band where the far end of the bed meets the back
        // wall of the tank — fakes the water depth behind the dunes.
        var seam = Path()
        seam.move(to: CGPoint(x: 0, y: backDuneTop(atX: 0, in: size) - 30))
        x = 0.0
        while x <= size.width {
            seam.addLine(to: CGPoint(x: x, y: backDuneTop(atX: x, in: size) - 30))
            x += 8
        }
        x = size.width
        while x >= 0 {
            seam.addLine(to: CGPoint(x: x, y: backDuneTop(atX: x, in: size)))
            x -= 8
        }
        seam.closeSubpath()
        canvas.fill(seam, with: .linearGradient(
            Gradient(colors: [.clear, .black.opacity(0.32)]),
            startPoint: CGPoint(x: 0, y: backDuneTop(atX: size.width / 2, in: size) - 30),
            endPoint: CGPoint(x: 0, y: backDuneTop(atX: size.width / 2, in: size))))

        var front = Path()
        var rim = Path()
        front.move(to: CGPoint(x: 0, y: sandTop(atX: 0, in: size)))
        rim.move(to: CGPoint(x: 0, y: sandTop(atX: 0, in: size)))
        x = 0.0
        while x <= size.width {
            front.addLine(to: CGPoint(x: x, y: sandTop(atX: x, in: size)))
            rim.addLine(to: CGPoint(x: x, y: sandTop(atX: x, in: size)))
            x += 6
        }
        front.addLine(to: CGPoint(x: size.width, y: size.height))
        front.addLine(to: CGPoint(x: 0, y: size.height))
        front.closeSubpath()
        canvas.fill(front, with: .linearGradient(
            Gradient(stops: [
                .init(color: sand.frontA, location: 0),
                .init(color: sand.frontB, location: 0.5),
                .init(color: sand.frontC, location: 1),
            ]),
            startPoint: CGPoint(x: 0, y: sandTop(atX: size.width / 2, in: size)),
            endPoint: CGPoint(x: 0, y: size.height)))
        // The crest catches the god rays: a broad soft glow under a
        // thin bright edge, so the dune tops read lit from above.
        var crestGlow = canvas
        crestGlow.blendMode = .plusLighter
        crestGlow.stroke(rim,
                         with: .color(sand.crest.opacity(0.14)),
                         style: StrokeStyle(lineWidth: 9, lineCap: .round))
        canvas.stroke(rim, with: .color(sand.rim.opacity(0.45)),
                      lineWidth: 1.2)
        // Wind-ripple contours: faint strokes paralleling the crest a
        // little way down the face — what makes a bar of colour read
        // as piled sand.
        for i in 0..<3 {
            let off = 13.0 + Double(i) * 15
            var ripple = Path()
            ripple.move(to: CGPoint(x: 0, y: sandTop(atX: 0, in: size) + off))
            var rx = 0.0
            while rx <= size.width {
                let u = rx / max(1, size.width)
                ripple.addLine(to: CGPoint(
                    x: rx,
                    y: sandTop(atX: rx, in: size) + off
                        + 2.4 * sin(u * .pi * 6.2 + Double(i) * 2.1 + Self.dunePhase2)))
                rx += 8
            }
            canvas.stroke(ripple,
                          with: .color(sand.ripple
                                        .opacity(0.10 - Double(i) * 0.03)),
                          style: StrokeStyle(lineWidth: 1.6 - Double(i) * 0.4, lineCap: .round))
        }

        // Grain scale & contrast per substrate: basalt gravel is
        // chunky and high-contrast, aragonite fine and bright, the
        // classic tan somewhere between.
        let grainScale = substrateKey == "black" ? 2.1
            : substrateKey == "white" ? 0.9 : 1.0
        let grainAlpha = substrateKey == "black" ? 1.6 : 1.0
        for speck in Self.sandSpeckles {
            let sx = speck.x * size.width
            let top = sandTop(atX: sx, in: size)
            let sy = top + 2 + speck.y * max(0, size.height - top - 3)
            let r = speck.r * grainScale
            canvas.fill(Path(ellipseIn: CGRect(x: sx - r, y: sy - r * 0.7,
                                               width: r * 2, height: r * 1.4)),
                        with: .color(speck.light
                                     ? sand.speckLight.opacity(min(1, 0.20 * grainAlpha))
                                     : sand.speckDark.opacity(min(1, 0.25 * grainAlpha))))
        }
    }

    /// A soft elliptical shadow pooled on the sand — the gradient is
    /// drawn in a scaled context so it fades on every side.
    private func groundShadow(canvas: inout GraphicsContext, x: Double, y: Double,
                              halfW: Double, halfH: Double = 4.5, alpha: Double) {
        var s = canvas
        s.translateBy(x: x, y: y)
        s.scaleBy(x: halfW, y: halfH)
        s.fill(Path(ellipseIn: CGRect(x: -1, y: -1, width: 2, height: 2)),
               with: .radialGradient(
                   Gradient(colors: [.black.opacity(alpha), .clear]),
                   center: .zero, startRadius: 0, endRadius: 1))
    }

    /// The glass itself: the far edges of the tank fall away, darkness
    /// pools along the bottom, and a faint reflection streaks the
    /// top-left corner — the pane you look through.
    private func drawGlass(canvas: inout GraphicsContext, size: CGSize) {
        let radius = max(size.width, size.height)
        canvas.fill(Path(CGRect(origin: .zero, size: size)),
                    with: .radialGradient(
                        Gradient(stops: [
                            .init(color: .clear, location: 0.45),
                            .init(color: .black.opacity(0.30), location: 1),
                        ]),
                        center: CGPoint(x: size.width * 0.5, y: size.height * 0.42),
                        startRadius: radius * 0.30, endRadius: radius * 0.78))
        canvas.fill(Path(CGRect(x: 0, y: size.height * 0.72,
                                width: size.width, height: size.height * 0.28)),
                    with: .linearGradient(
                        Gradient(colors: [.clear, .black.opacity(0.22)]),
                        startPoint: CGPoint(x: 0, y: size.height * 0.72),
                        endPoint: CGPoint(x: 0, y: size.height)))
        var g = canvas
        g.blendMode = .plusLighter
        g.translateBy(x: size.width * 0.14, y: size.height * 0.10)
        g.rotate(by: .radians(-0.55))
        g.fill(Path(roundedRect: CGRect(x: -size.width * 0.30, y: -18,
                                        width: size.width * 0.60, height: 36),
                    cornerRadius: 18),
               with: .linearGradient(
                   Gradient(stops: [
                       .init(color: .clear, location: 0),
                       .init(color: .white.opacity(0.055), location: 0.5),
                       .init(color: .clear, location: 1),
                   ]),
                   startPoint: CGPoint(x: 0, y: -18), endPoint: CGPoint(x: 0, y: 18)))
    }

    /// Slow flecks drifting with the water as soft glowing motes, in
    /// two depth layers — the near ones are bigger, brighter & a touch
    /// faster. `density` scales the count; Reduce Motion stills them.
    /// The seed goes through `scatter` (a murmur-style scramble):
    /// FNV-1a's low bits cluster on sequential tags, which used to
    /// park the motes in visible rows.
    private func drawPlankton(canvas: inout GraphicsContext, size: CGSize, t: Double,
                              density: Double, front: Bool) {
        let tt = reduceMotion ? 0.0 : t
        let count = Int((44 * density).rounded())
        for i in 0..<count {
            let h = scatter(AquariumModel.stableHash("plankton-field"), i)
            let isFront = (h >> 56) & 1 == 1
            guard isFront == front else { continue }
            let x0 = Double(h & 0xFFFF) / 0xFFFF
            let y0 = Double((h >> 16) & 0xFFFF) / 0xFFFF
            let phase = Double((h >> 32) & 0xFF) / 0xFF * .pi * 2
            let drift = (h >> 40) & 1 == 0 ? 1.0 : -1.0
            // Near layer 1.6–3 px, far layer 1–2.2 px.
            let r = 1.0 + Double((h >> 44) & 0xFF) / 0xFF * (front ? 2.0 : 1.2)
            let x = frac(x0 + drift * tt * (front ? 0.010 : 0.005)
                         + 0.018 * sin(tt * 0.20 + phase)) * size.width
            // Stay in the water column, off the bed.
            let y = (0.12 + frac(y0 + 0.018 * sin(tt * 0.26 + phase)) * 0.68) * size.height
            let twinkle = reduceMotion ? 0.8 : 0.55 + 0.45 * sin(t * 0.6 + phase)
            let alpha = (front ? 0.16 : 0.07)
                + Double((h >> 48) & 0xFF) / 0xFF * (front ? 0.20 : 0.11)
            // The dark themes' motes are bioluminescent — cyan/teal
            // pulses instead of dust catching light.
            let moteColor = isDarkTheme
                ? (((h >> 50) & 1) == 0
                   ? Color(red: 0.30, green: 0.95, blue: 0.85)
                   : Color(red: 0.25, green: 0.70, blue: 0.95))
                : .white
            canvas.fill(Path(ellipseIn: CGRect(x: x - r, y: y - r, width: r * 2, height: r * 2)),
                        with: .radialGradient(
                            Gradient(colors: [moteColor.opacity(alpha * twinkle
                                                                * (isDarkTheme ? 1.6 : 1)),
                                              .clear]),
                            center: CGPoint(x: x, y: y), startRadius: 0, endRadius: r))
        }
        // Deeper still in the dark themes: the lantern-fish glimmers —
        // a handful of distant dots blinking on their own slow clocks.
        if isDarkTheme && !front {
            for i in 0..<9 {
                var h = AquariumModel.stableHash("lantern-\(i)")
                h ^= h >> 33; h &*= 0xff51afd7ed558ccd; h ^= h >> 33
                let lx = Double(h & 0xFFFF) / 0xFFFF * size.width
                let ly = (0.35 + Double((h >> 16) & 0xFFFF) / 0xFFFF * 0.5) * size.height
                // Each blinks on a seeded ~2–6 s window.
                let period = 2 + Double((h >> 32) & 0xFF) / 0xFF * 4
                let on = frac(t / period + Double((h >> 40) & 0xFF) / 0xFF) < 0.18
                guard on else { continue }
                let lr = 1.2 + Double((h >> 48) & 0x3) * 0.6
                var g = canvas
                g.blendMode = .plusLighter
                g.fill(Path(ellipseIn: CGRect(x: lx - lr, y: ly - lr,
                                              width: lr * 2, height: lr * 2)),
                       with: .radialGradient(
                           Gradient(colors: [Color(red: 0.60, green: 0.95,
                                                   blue: 0.90)
                                               .opacity(0.55), .clear]),
                           center: CGPoint(x: lx, y: ly), startRadius: 0,
                           endRadius: lr * 3))
            }
        }
    }

    /// Ambient bubbles — half streaming off the chest, half seeded at
    /// random spots in the sand — each with a rim, a faint body and a
    /// glint. They wobble up from the bed and pop just under the
    /// surface. The seed goes through `scatter` so the rise phases
    /// don't fall into an evenly spaced ladder.
    private func drawBubbles(canvas: inout GraphicsContext, size: CGSize, t: Double, density: Double) {
        let count = Int((9 * density).rounded())
        let chestX = Self.decor.first(where: { $0.kind == .chest })?.x ?? 0.5
        for i in 0..<count {
            let h = scatter(AquariumModel.stableHash("bubble-seed"), i)
            let nearChest = (h >> 52) & 1 == 0
            let x0 = nearChest
                ? chestX + (Double((h >> 54) & 0xFF) / 0xFF - 0.5) * 0.10
                : Double(h & 0xFFFF) / 0xFFFF
            let phase = Double((h >> 16) & 0xFF) / 0xFF * .pi * 2
            let speed = 0.04 + Double((h >> 24) & 0xFF) / 0xFF * 0.09
            let r = 1.2 + Double((h >> 32) & 0xFF) / 0xFF * 3.4
            let rise = frac(Double((h >> 40) & 0xFF) / 0xFF + (reduceMotion ? 0 : t) * speed)
            // Each bubble staggers its own amount at its own rate.
            let wobble = 2.5 + Double((h >> 48) & 0xF) / 0xF * 8.5
            let x = x0 * size.width
                + (reduceMotion ? 0 : sin(t * (0.9 + speed * 6) + phase) * wobble)
            if rise > 0.92 {
                // The pop: a quick expanding ring just under the
                // meniscus, then gone — where a bubble's story ends.
                let pop = clamp01((rise - 0.92) / 0.08)
                let pr = r + pop * 6
                var ring = canvas
                ring.opacity = (1 - pop) * 0.35
                ring.stroke(Path(ellipseIn: CGRect(x: x - pr, y: 9 - pr,
                                                   width: pr * 2, height: pr * 2)),
                            with: .color(.white), lineWidth: 0.8)
                continue
            }
            let floorY = sandTop(atX: x, in: size) - 3
            let y = floorY - rise * (floorY - 8)
            let rect = CGRect(x: x - r, y: y - r, width: r * 2, height: r * 2)
            canvas.fill(Path(ellipseIn: rect),
                        with: .radialGradient(
                            Gradient(colors: [.white.opacity(0.14), .clear]),
                            center: CGPoint(x: x, y: y), startRadius: 0, endRadius: r))
            canvas.stroke(Path(ellipseIn: rect),
                          with: .color(.white.opacity(0.38)), lineWidth: 0.8)
            canvas.fill(Path(ellipseIn: CGRect(x: x - r * 0.45, y: y - r * 0.55,
                                               width: r * 0.35, height: r * 0.35)),
                        with: .color(.white.opacity(0.6)))
        }
    }

    // MARK: Decor

    /// The seeded layout, built once — the tank never rearranges.
    private static let decor = AquariumModel.decorSet()

    /// The bed is ~12% of the tank now; the dressing grows with it —
    /// roughly twice the original footprint.
    private static let decorBoost = 2.0

    /// The seeded dressing (docs/TOYS.md): kelp, rocks, corals, sea
    /// grass, shells, a starfish, a bottle & a treasure chest, laid
    /// out by `AquariumModel.decorSet` so the tank looks the same
    /// every launch. `density` decides how much of the set shows —
    /// the signature pieces come first, so a sparse tank keeps them.
    /// `keepClear` (the empty-tank caption's capsule) culls any piece
    /// rooted inside it — nothing sits under the plaque.
    private func decorVisible(_ piece: TankDecor, shown: Int,
                              clearZone: CGRect?, in size: CGSize) -> Bool {
        guard piece.id < shown else { return false }
        if let clearZone,
           clearZone.contains(CGPoint(x: piece.x * size.width,
                                      y: decorBaseY(piece, in: size))) {
            return false
        }
        return true
    }

    /// The still dressing → the cached bed pass: every piece that
    /// doesn't move, back layer only (deep pieces sit under the fish;
    /// near pieces stay live so nothing ends up behind a fish it
    /// should shade). Kelp & grass sway and stay out of the cache —
    /// the live pass draws them.
    private func drawStaticDecor(canvas: inout GraphicsContext, size: CGSize,
                                 density: Double, keepClear: CGRect? = nil) {
        let shown = Int((Double(Self.decor.count) * min(1, density)).rounded(.up))
        // The capsule sits on the sand face below the dune line; the
        // zone reaches up over the dune face behind it so nothing is
        // rooted inside the plaque's footprint either.
        let clearZone = keepClear?.insetBy(dx: -10, dy: -34)
        for piece in Self.decor where piece.depth <= 0.6 {
            guard decorVisible(piece, shown: shown,
                               clearZone: clearZone, in: size) else { continue }
            switch piece.kind {
            case .rock: drawRocks(canvas: &canvas, size: size, piece: piece)
            case .coral: drawCoral(canvas: &canvas, size: size, piece: piece)
            case .shell: drawShell(canvas: &canvas, size: size, piece: piece)
            case .bottle: drawBottle(canvas: &canvas, size: size, piece: piece)
            case .starfish: drawStarfish(canvas: &canvas, size: size, piece: piece)
            case .chest: drawChest(canvas: &canvas, size: size, piece: piece)
            case .kelp, .grass: break // they sway — the live pass draws them
            }
        }
    }

    /// The moving dressing → the live pass: kelp & grass on both depth
    /// passes (they sway), the chest's occasional burp bubble, and any
    /// near-glass piece — `front` splits the set at depth 0.6 so near
    /// pieces draw over the fish as foreground parallax.
    private func drawLiveDecor(canvas: inout GraphicsContext, size: CGSize, t: Double,
                               density: Double, front: Bool, keepClear: CGRect? = nil) {
        let shown = Int((Double(Self.decor.count) * min(1, density)).rounded(.up))
        let clearZone = keepClear?.insetBy(dx: -10, dy: -34)
        // The kelp forest theme thickens the stand — three extra
        // seeded strands behind the lane on top of the usual set.
        if themeKey == "kelp" && !front {
            for i in 0..<3 {
                var h = AquariumModel.stableHash("kelpx-\(i)")
                h ^= h >> 33; h &*= 0xff51afd7ed558ccd; h ^= h >> 33
                let extra = TankDecor(
                    id: 900 + i, kind: .kelp,
                    x: 0.10 + 0.80 * Double(h & 0xFFFF) / 0xFFFF,
                    depth: 0.30 + Double((h >> 16) & 0xFF) / 0xFF * 0.25,
                    scale: 0.85 + Double((h >> 24) & 0xFF) / 0xFF * 0.45,
                    bits: h)
                drawKelp(canvas: &canvas, size: size, t: t, piece: extra)
            }
        }
        for piece in Self.decor where (piece.depth > 0.6) == front {
            guard decorVisible(piece, shown: shown,
                               clearZone: clearZone, in: size) else { continue }
            switch piece.kind {
            case .kelp where front:
                // The near-glass fronds sit a hair out of focus — the
                // foreground falls off like a camera's would.
                var g = canvas
                g.addFilter(.blur(radius: 1.6))
                drawKelp(canvas: &g, size: size, t: t, piece: piece)
            case .kelp: drawKelp(canvas: &canvas, size: size, t: t, piece: piece)
            case .grass: drawGrass(canvas: &canvas, size: size, t: t, piece: piece)
            case .chest where !front:
                drawChestBurp(canvas: &canvas, size: size, t: t, piece: piece)
            case .chest: // a front chest can't sit in the bed cache — draw it live
                drawChest(canvas: &canvas, size: size, piece: piece)
                drawChestBurp(canvas: &canvas, size: size, t: t, piece: piece)
            case .rock where front: drawRocks(canvas: &canvas, size: size, piece: piece)
            case .coral where front: drawCoral(canvas: &canvas, size: size, piece: piece)
            case .shell where front: drawShell(canvas: &canvas, size: size, piece: piece)
            case .bottle where front: drawBottle(canvas: &canvas, size: size, piece: piece)
            case .starfish where front: drawStarfish(canvas: &canvas, size: size, piece: piece)
            default: break
            }
        }
    }

    /// Where a piece stands: on the dune line under it, with a couple
    /// of pixels of sink so nothing floats over the sand.
    private func decorBaseY(_ piece: TankDecor, in size: CGSize) -> Double {
        sandTop(atX: piece.x * size.width, in: size) + 2
    }

    /// Per-item hash scramble: folds an index into a piece's bits so
    /// every frond/blade/branch of one piece varies independently.
    private func scatter(_ bits: UInt64, _ k: Int) -> UInt64 {
        var h = bits &+ UInt64(k) &* 0x9E3779B97F4A7C15
        h ^= h >> 29
        h &*= 0xBF58476D1CE4E5B9
        h ^= h >> 32
        return h
    }

    /// A smoothed polyline through `pts` — midpoint anchors, point
    /// controls. The stand-in for hand-drawn curves everywhere below.
    private func smoothPath(_ pts: [CGPoint]) -> Path {
        var p = Path()
        guard pts.count > 1 else { return p }
        p.move(to: pts[0])
        for i in 1..<pts.count {
            let mid = CGPoint(x: (pts[i - 1].x + pts[i].x) / 2,
                              y: (pts[i - 1].y + pts[i].y) / 2)
            p.addQuadCurve(to: mid, control: pts[i - 1])
        }
        p.addLine(to: pts[pts.count - 1])
        return p
    }

    /// A tapered ribbon along a cubic Bézier: `fill` is the closed
    /// blade (width `w0` at the root tapering to a soft point),
    /// `midrib` the centreline for a darker stroke, `edge` one side
    /// for a highlight. Sampled once per draw — nine steps is smooth
    /// at these sizes. `belly` switches the width profile from a plain
    /// taper to a kelp blade's: narrow at the root, fullest mid-blade,
    /// soft point. `ruffle` ripples the two margins on independent
    /// phases, which is what turns a strip into a leaf.
    private func ribbon(from p0: CGPoint, c1: CGPoint, c2: CGPoint, to p1: CGPoint,
                        width w0: Double, litLeft: Bool = true,
                        steps: Int = 9,
                        belly: Double = 0, ruffle: Double = 0,
                        rufflePhase: Double = 0) -> (fill: Path, midrib: Path, edge: Path) {
        var mid: [CGPoint] = []
        var left: [CGPoint] = []
        var right: [CGPoint] = []
        mid.reserveCapacity(steps + 1)
        left.reserveCapacity(steps + 1)
        right.reserveCapacity(steps + 1)
        for i in 0...steps {
            let u = Double(i) / Double(steps)
            let v = 1 - u
            let px = v * v * v * p0.x + 3 * v * v * u * c1.x + 3 * v * u * u * c2.x + u * u * u * p1.x
            let py = v * v * v * p0.y + 3 * v * v * u * c1.y + 3 * v * u * u * c2.y + u * u * u * p1.y
            let dx = 3 * v * v * (c1.x - p0.x) + 6 * v * u * (c2.x - c1.x) + 3 * u * u * (p1.x - c2.x)
            let dy = 3 * v * v * (c1.y - p0.y) + 6 * v * u * (c2.y - c1.y) + 3 * u * u * (p1.y - c2.y)
            let len = max(0.001, (dx * dx + dy * dy).squareRoot())
            let nx = -dy / len, ny = dx / len
            let hw: Double
            if belly > 0 {
                // sin(π·(0.05+0.95u))^0.65 ≈ 0.3 at the root, 1 at
                // mid-blade, 0 at the tip — a leaf outline. The 0.9
                // floor blunts the tip: kelp ends rounded, not
                // needle-pointed.
                hw = w0 / 2 * pow(sin(.pi * (0.05 + 0.95 * u)), 0.65) + 0.9
            } else {
                hw = w0 / 2 * (1 - u) + 0.35
            }
            let hwL = hw * (1 + ruffle * sin(u * 10.5 + rufflePhase))
            let hwR = hw * (1 + ruffle * sin(u * 11.2 + rufflePhase + 2.1))
            mid.append(CGPoint(x: px, y: py))
            left.append(CGPoint(x: px + nx * hwL, y: py + ny * hwL))
            right.append(CGPoint(x: px - nx * hwR, y: py - ny * hwR))
        }
        // Closed midpoint spline through both sides.
        let outline = left + right.reversed()
        let n = outline.count
        var fill = Path()
        fill.move(to: CGPoint(x: (outline[0].x + outline[1].x) / 2,
                              y: (outline[0].y + outline[1].y) / 2))
        for i in 1...n {
            let a = outline[i % n]
            let bpt = outline[(i + 1) % n]
            fill.addQuadCurve(to: CGPoint(x: (a.x + bpt.x) / 2, y: (a.y + bpt.y) / 2),
                              control: a)
        }
        fill.closeSubpath()
        return (fill, smoothPath(mid), smoothPath(litLeft ? left : right))
    }

    /// One kelp cluster: two or three broad blades fanning from a
    /// root — narrow at the foot, fullest mid-blade, ruffled margins,
    /// a soft point — each bending in a slow S as it sways. The fill is
    /// a root→tip gradient of translucent green, so the tip reads lit
    /// and the water shows through; a midrib and a lit margin pick out
    /// the blade. Deep clusters melt toward the water colour;
    /// near-glass ones draw as wider, darker teal silhouettes over the
    /// fish — translucent, so they stay plants, not slabs. Reduce
    /// Motion freezes the sway.
    private func drawKelp(canvas: inout GraphicsContext, size: CGSize, t: Double, piece: TankDecor) {
        let b = piece.bits
        let baseX = piece.x * size.width
        let baseY = decorBaseY(piece, in: size)
        let front = piece.depth > 0.6
        let fronds = 2 + Int(scatter(b, 90) % 2)
        let wash = 1 - piece.depth
        let widthScale = size.width / 1024
        for k in 0..<fronds {
            let fb = scatter(b, k)
            let phase = Double(fb & 0xFF) / 0xFF * .pi * 2
            // Heights vary inside the cluster; the tallest fronds
            // reach ~45% of the tank.
            let hgt = min(size.height * (0.20 + Double((fb >> 8) & 0xFF) / 0xFF * 0.30)
                          * (0.8 + piece.scale * 0.25),
                          size.height * (front ? 0.55 : 0.48))
            let spread = (Double(k) - Double(fronds - 1) / 2) * 15 * piece.scale
            let lean = (Double((fb >> 16) & 0xFF) / 0xFF - 0.5) * 50 + spread
            let sway = reduceMotion ? 0
                : sin(t * (0.24 + Double((fb >> 24) & 0xFF) / 0xFF * 0.20) + phase)
                  * (9 + hgt * 0.06)
            let w0 = (32 + Double((fb >> 32) & 0xFF) / 0xFF * 14) * widthScale
                * (0.7 + piece.scale * 0.3) * (front ? 1.3 : 1.0)

            let root = CGPoint(x: baseX + spread * 0.6, y: baseY)
            let tip = CGPoint(x: baseX + lean + sway, y: baseY - hgt)
            // A gentle S: the lower third of the blade bows one side
            // of the root→tip chord, the upper third the other.
            let drift = lean + sway
            let chLen = max(1, (drift * drift + hgt * hgt).squareRoot())
            let sAmp = hgt * (0.11 + (reduceMotion ? 0 : 0.035 * sin(t * 0.4 + phase)))
            let perpX = hgt / chLen * sAmp
            let perpY = drift / chLen * sAmp
            let c1 = CGPoint(x: root.x + drift * 0.33 - perpX,
                             y: baseY - hgt * 0.33 - perpY)
            let c2 = CGPoint(x: root.x + drift * 0.68 + perpX,
                             y: baseY - hgt * 0.68 + perpY)
            let rib = ribbon(from: root, c1: c1, c2: c2, to: tip,
                             width: w0, litLeft: drift < 0, steps: 14,
                             belly: 1,
                             ruffle: 0.14 + Double((fb >> 40) & 0xFF) / 0xFF * 0.10,
                             rufflePhase: phase)

            let rootColor: Color
            let tipColor: Color
            let ribColor: Color
            let edgeColor: Color
            if front {
                // Foreground: a wide glass-side frond sliding over the
                // fish — deep teal and translucent, not a black slab.
                rootColor = Color(red: 0.03, green: 0.17, blue: 0.18).opacity(0.55)
                tipColor = Color(red: 0.09, green: 0.30, blue: 0.28).opacity(0.42)
                ribColor = Color(red: 0.01, green: 0.08, blue: 0.10).opacity(0.45)
                edgeColor = Color(red: 0.44, green: 0.70, blue: 0.62).opacity(0.36)
            } else {
                // Translucent leaf green, lit toward the tip where the
                // light gets through, melted toward the water by depth.
                let g0 = Self.waterNS.blended(
                    withFraction: 1 - wash * 0.38,
                    of: NSColor(srgbRed: 0.07, green: 0.34, blue: 0.18, alpha: 1))
                    ?? Self.waterNS
                let g1 = Self.waterNS.blended(
                    withFraction: 1 - wash * 0.30,
                    of: NSColor(srgbRed: 0.34, green: 0.68, blue: 0.38, alpha: 1))
                    ?? Self.waterNS
                rootColor = Color(nsColor: g0).opacity(0.75 - wash * 0.15)
                tipColor = Color(nsColor: g1).opacity(0.55 - wash * 0.12)
                ribColor = Color(red: 0.03, green: 0.16, blue: 0.10).opacity(0.45)
                edgeColor = Color(red: 0.60, green: 0.90, blue: 0.60)
                    .opacity(0.40 * (1 - wash * 0.5))
            }
            canvas.fill(rib.fill, with: .linearGradient(
                Gradient(stops: [
                    .init(color: rootColor, location: 0),
                    .init(color: tipColor, location: 1),
                ]),
                startPoint: root, endPoint: tip))
            canvas.stroke(rib.midrib, with: .color(ribColor),
                          style: StrokeStyle(lineWidth: max(1.2, w0 * 0.09), lineCap: .round))
            canvas.stroke(rib.edge, with: .color(edgeColor),
                          style: StrokeStyle(lineWidth: max(1.0, w0 * 0.05), lineCap: .round))
        }
    }

    /// A tuft of thin sea-grass blades — the same ribbon as kelp but
    /// short, thin and quick-swaying.
    private func drawGrass(canvas: inout GraphicsContext, size: CGSize, t: Double, piece: TankDecor) {
        let b = piece.bits
        let baseX = piece.x * size.width
        let baseY = decorBaseY(piece, in: size) + 1
        let blades = 5 + Int((b >> 36) % 4)
        let wash = 1 - piece.depth
        let green = Self.waterNS.blended(
            withFraction: 1 - wash * 0.5,
            of: NSColor(srgbRed: 0.15, green: 0.48, blue: 0.27, alpha: 1))
            ?? Self.waterNS
        let scale = piece.scale * max(0.7, min(1.5, size.height / 240)) * 1.3
        for k in 0..<blades {
            let fb = scatter(b, k &+ 11)
            let spread = (Double((fb >> 40) & 0xFF) / 0xFF - 0.5) * 16 * scale
            let hgt = (14 + Double((fb >> 8) & 0xFF) / 0xFF * 30) * scale
            let phase = Double(fb & 0xFF) / 0xFF * .pi * 2
            let sway = reduceMotion ? 0
                : sin(t * (0.5 + Double((fb >> 24) & 0xFF) / 0xFF * 0.4) + phase) * 3.5
            let root = CGPoint(x: baseX + spread * 0.3, y: baseY)
            let tip = CGPoint(x: baseX + spread + (Double((fb >> 16) & 0xFF) / 0xFF - 0.5) * 14 + sway,
                              y: baseY - hgt)
            let rib = ribbon(from: root,
                             c1: CGPoint(x: root.x, y: baseY - hgt * 0.5),
                             c2: CGPoint(x: tip.x - sway * 0.6, y: tip.y + hgt * 0.3),
                             to: tip, width: 2.6 * scale, litLeft: tip.x < baseX, steps: 6)
            canvas.fill(rib.fill,
                        with: .color(Color(nsColor: green).opacity(0.78 - wash * 0.28)))
        }
    }

    /// A couple of boulders leaning together on the dune line: tall
    /// domed stones rather than pebbles, each lit from above-left
    /// with a shaded underbelly and a cool water wash by depth. The
    /// cluster pools one shadow under itself.
    private func drawRocks(canvas: inout GraphicsContext, size: CGSize, piece: TankDecor) {
        let b = piece.bits
        let baseX = piece.x * size.width
        let baseY = decorBaseY(piece, in: size)
        let wash = 1 - piece.depth
        let scale = piece.scale * Self.decorBoost
        let count = 2 + Int(scatter(b, 7) & 1)
        groundShadow(canvas: &canvas, x: baseX, y: baseY + 2,
                     halfW: 34 * scale, halfH: 6.5, alpha: 0.30)
        for r in 0..<count {
            let rb = scatter(b, r &+ 3)
            let rw = (15 + Double(rb & 0xFF) / 0xFF * 12) * scale
            let rh = rw * (0.66 + Double((rb >> 8) & 0xFF) / 0xFF * 0.28)
            let rx = baseX + (Double(r) - Double(count - 1) / 2) * rw * 0.60
                + (Double((rb >> 16) & 0xF) - 7.5)
            // Later boulders ride up on the first, piled stone style.
            let ry = baseY - rh * 0.40 - (r > 0 ? rh * 0.14 * Double(r) : 0)
            let rect = CGRect(x: rx - rw / 2, y: ry - rh / 2, width: rw, height: rh)
            let boulder = Path(ellipseIn: rect)
            canvas.fill(boulder,
                        with: .radialGradient(
                            Gradient(colors: [Color(red: 0.50, green: 0.48, blue: 0.44)
                                                .opacity(0.92 - wash * 0.25),
                                              Color(red: 0.13, green: 0.12, blue: 0.12)
                                                .opacity(0.92 - wash * 0.2)]),
                            center: CGPoint(x: rx - rw * 0.20, y: ry - rh * 0.30),
                            startRadius: 0, endRadius: rw * 0.72))
            // The shaded underbelly, clipped to the boulder.
            var shade = canvas
            shade.clip(to: boulder)
            shade.fill(Path(ellipseIn: CGRect(x: rx - rw * 0.55, y: ry + rh * 0.05,
                                              width: rw * 1.1, height: rh * 0.7)),
                       with: .color(.black.opacity(0.30 - wash * 0.10)))
            // The lit brow.
            canvas.fill(Path(ellipseIn: CGRect(x: rx - rw * 0.30, y: ry - rh * 0.40,
                                               width: rw * 0.36, height: rh * 0.22)),
                        with: .color(.white.opacity(0.18 - wash * 0.07)))
        }
    }

    /// One of two corals by seed: a branching fan (round-stroked
    /// forks with pale tips) or a rounded brain (a domed mound with
    /// concentric grooves). Both get a ground shadow; deep corals
    /// mute toward the water colour.
    private func drawCoral(canvas: inout GraphicsContext, size: CGSize, piece: TankDecor) {
        if (piece.bits >> 40) & 1 == 0 {
            drawFanCoral(canvas: &canvas, size: size, piece: piece)
        } else {
            drawBrainCoral(canvas: &canvas, size: size, piece: piece)
        }
    }

    /// The branching fan: a trunk that forks twice, stroked dark
    /// underneath then bright over it, with paler tips.
    private func drawFanCoral(canvas: inout GraphicsContext, size: CGSize, piece: TankDecor) {
        let b = piece.bits
        let baseX = piece.x * size.width
        let baseY = decorBaseY(piece, in: size)
        let hgt = min((30 + Double(b & 0xFF) / 0xFF * 26) * piece.scale
                      * max(0.7, min(1.5, size.height / 240)) * Self.decorBoost,
                      size.height * 0.26)
        let wash = 1 - piece.depth
        // Two palettes: rose or amber.
        let bright = (b >> 48) & 1 == 0
            ? Color(red: 0.88, green: 0.46, blue: 0.48)
            : Color(red: 0.90, green: 0.60, blue: 0.34)
        let shadow = (b >> 48) & 1 == 0
            ? Color(red: 0.48, green: 0.18, blue: 0.22)
            : Color(red: 0.50, green: 0.28, blue: 0.12)
        groundShadow(canvas: &canvas, x: baseX, y: baseY + 1,
                     halfW: 14 * piece.scale * Self.decorBoost, halfH: 4.5, alpha: 0.25)

        var tips: [CGPoint] = []
        func grow(_ from: CGPoint, _ angle: Double, _ len: Double, _ forks: Int, _ w: Double) {
            let to = CGPoint(x: from.x + cos(angle) * len, y: from.y + sin(angle) * len)
            let bend = (Double((b >> UInt64(forks * 9 + 2)) & 0xFF) / 0xFF - 0.5) * 10
            var seg = Path()
            seg.move(to: from)
            seg.addQuadCurve(to: to,
                             control: CGPoint(x: (from.x + to.x) / 2 + bend,
                                              y: (from.y + to.y) / 2))
            canvas.stroke(seg, with: .color(shadow.opacity(0.8 - wash * 0.3)),
                          style: StrokeStyle(lineWidth: w + 1.6, lineCap: .round))
            canvas.stroke(seg, with: .color(bright.opacity(0.85 - wash * 0.35)),
                          style: StrokeStyle(lineWidth: w, lineCap: .round))
            guard forks > 0 else {
                tips.append(to)
                return
            }
            let spread = 0.45 + Double((b >> UInt64(forks * 7 + 12)) & 0xFF) / 0xFF * 0.4
            grow(to, angle - spread, len * 0.66, forks - 1, w * 0.72)
            grow(to, angle + spread * 0.8, len * 0.66, forks - 1, w * 0.72)
        }
        grow(CGPoint(x: baseX, y: baseY),
             -.pi / 2 + (Double((b >> 8) & 0xFF) / 0xFF - 0.5) * 0.4,
             hgt * 0.5, 2, 3.0 * piece.scale * Self.decorBoost * 0.75)
        for tip in tips {
            canvas.fill(Path(ellipseIn: CGRect(x: tip.x - 1.4, y: tip.y - 1.4,
                                               width: 2.8, height: 2.8)),
                        with: .color(Color(red: 0.98, green: 0.80, blue: 0.72)
                                        .opacity(0.7 - wash * 0.3)))
        }
    }

    /// The brain coral: a shaded dome with concentric groove arcs and
    /// a scatter of pores.
    private func drawBrainCoral(canvas: inout GraphicsContext, size: CGSize, piece: TankDecor) {
        let b = piece.bits
        let baseX = piece.x * size.width
        let baseY = decorBaseY(piece, in: size)
        let r = (13 + Double(b & 0xFF) / 0xFF * 9) * piece.scale * Self.decorBoost
        let wash = 1 - piece.depth
        groundShadow(canvas: &canvas, x: baseX, y: baseY + 1,
                     halfW: r * 1.1, halfH: 4, alpha: 0.28)
        // A squat dome.
        var dome = Path()
        dome.move(to: CGPoint(x: baseX - r, y: baseY))
        dome.addCurve(to: CGPoint(x: baseX + r, y: baseY),
                      control1: CGPoint(x: baseX - r, y: baseY - r * 1.15),
                      control2: CGPoint(x: baseX + r, y: baseY - r * 1.15))
        dome.closeSubpath()
        let purple = (b >> 48) & 1 == 0
        let lit = purple ? Color(red: 0.62, green: 0.46, blue: 0.62)
                         : Color(red: 0.72, green: 0.56, blue: 0.38)
        let dark = purple ? Color(red: 0.30, green: 0.18, blue: 0.34)
                          : Color(red: 0.36, green: 0.24, blue: 0.16)
        canvas.fill(dome, with: .radialGradient(
            Gradient(colors: [lit.opacity(0.9 - wash * 0.3), dark.opacity(0.9 - wash * 0.25)]),
            center: CGPoint(x: baseX - r * 0.2, y: baseY - r * 0.8),
            startRadius: 0, endRadius: r * 1.5))
        // The grooves: same dome shrunk, stroked into the shade.
        for g in [0.72, 0.48, 0.26] as [Double] {
            let gr = r * g
            var groove = Path()
            groove.move(to: CGPoint(x: baseX - gr, y: baseY))
            groove.addCurve(to: CGPoint(x: baseX + gr, y: baseY),
                            control1: CGPoint(x: baseX - gr, y: baseY - gr * 1.15),
                            control2: CGPoint(x: baseX + gr, y: baseY - gr * 1.15))
            canvas.stroke(groove, with: .color(dark.opacity(0.55 - wash * 0.2)),
                          style: StrokeStyle(lineWidth: max(0.8, r * 0.08), lineCap: .round))
        }
        // Pores.
        for i in 0..<5 {
            let pb = scatter(b, i &+ 31)
            let px = baseX + (Double(pb & 0xFF) / 0xFF - 0.5) * r * 1.3
            let py = baseY - Double((pb >> 8) & 0xFF) / 0xFF * r * 0.6 - r * 0.1
            canvas.fill(Path(ellipseIn: CGRect(x: px - 1, y: py - 1, width: 2, height: 2)),
                        with: .color(dark.opacity(0.5)))
        }
    }

    /// A shell on the sand — a ribbed scallop or a spiral, by seed.
    private func drawShell(canvas: inout GraphicsContext, size: CGSize, piece: TankDecor) {
        let b = piece.bits
        let baseX = piece.x * size.width
        let baseY = decorBaseY(piece, in: size) + 1
        let s = 6.5 * piece.scale * Self.decorBoost
        groundShadow(canvas: &canvas, x: baseX, y: baseY + 1,
                     halfW: s * 1.15, halfH: 2.6, alpha: 0.24)
        var c = canvas
        c.translateBy(x: baseX, y: baseY)
        c.rotate(by: .radians((Double(b & 0xFF) / 0xFF - 0.5) * 0.7))
        c.scaleBy(x: s, y: s)
        if (b >> 12) & 1 == 0 {
            // Scallop: a fan off the hinge with ribs out to the rim.
            var fan = Path()
            fan.move(to: CGPoint(x: 0, y: 0.18))
            fan.addCurve(to: CGPoint(x: -0.55, y: -0.22),
                         control1: CGPoint(x: -0.32, y: 0.10),
                         control2: CGPoint(x: -0.54, y: 0.02))
            fan.addQuadCurve(to: CGPoint(x: 0.55, y: -0.22),
                             control: CGPoint(x: 0, y: -0.75))
            fan.addCurve(to: CGPoint(x: 0, y: 0.18),
                         control1: CGPoint(x: 0.54, y: 0.02),
                         control2: CGPoint(x: 0.32, y: 0.10))
            fan.closeSubpath()
            c.fill(fan, with: .linearGradient(
                Gradient(colors: [Color(red: 0.88, green: 0.70, blue: 0.62),
                                  Color(red: 0.58, green: 0.38, blue: 0.32)]),
                startPoint: CGPoint(x: 0, y: -0.6), endPoint: CGPoint(x: 0, y: 0.2)))
            for ribX in [-0.36, -0.18, 0.0, 0.18, 0.36] as [Double] {
                var ribPath = Path()
                ribPath.move(to: CGPoint(x: 0, y: 0.14))
                ribPath.addQuadCurve(to: CGPoint(x: ribX, y: -0.44 + abs(ribX) * 0.55),
                                     control: CGPoint(x: ribX * 0.5, y: -0.12))
                c.stroke(ribPath,
                         with: .color(Color(red: 0.44, green: 0.27, blue: 0.22).opacity(0.5)),
                         lineWidth: 0.05)
            }
        } else {
            // A spiral whelk.
            c.fill(Path(ellipseIn: CGRect(x: -0.42, y: -0.42, width: 0.84, height: 0.84)),
                   with: .radialGradient(
                       Gradient(colors: [Color(red: 0.84, green: 0.68, blue: 0.52),
                                         Color(red: 0.50, green: 0.33, blue: 0.21)]),
                       center: CGPoint(x: -0.1, y: -0.12), startRadius: 0.02, endRadius: 0.55))
            var spiral = Path()
            var rr = 0.34
            var a = 0.0
            spiral.move(to: CGPoint(x: rr, y: 0))
            while a < .pi * 3.6 {
                a += 0.22
                rr *= 0.955
                spiral.addLine(to: CGPoint(x: cos(a) * rr, y: sin(a) * rr))
            }
            c.stroke(spiral,
                     with: .color(Color(red: 0.40, green: 0.25, blue: 0.16).opacity(0.6)),
                     lineWidth: 0.05)
        }
    }

    /// A bottle sunk to its shoulder: dark sea-green glass tilted into
    /// the sand, a highlight down its flank, and a lip of sand piled
    /// over its low corner.
    private func drawBottle(canvas: inout GraphicsContext, size: CGSize, piece: TankDecor) {
        let b = piece.bits
        let baseX = piece.x * size.width
        let baseY = decorBaseY(piece, in: size) + 2
        let s = 13 * piece.scale * Self.decorBoost
        let tilt = -0.5 - Double(b & 0xFF) / 0xFF * 0.3
        groundShadow(canvas: &canvas, x: baseX, y: baseY + 1,
                     halfW: s * 1.0, halfH: 3.5, alpha: 0.26)
        var c = canvas
        c.translateBy(x: baseX, y: baseY - s * 0.1)
        c.rotate(by: .radians(tilt))
        c.scaleBy(x: s, y: s)
        let glass = Color(red: 0.10, green: 0.26, blue: 0.20)
        var body = Path()
        body.addRoundedRect(in: CGRect(x: -0.55, y: -0.26, width: 0.78, height: 0.52),
                            cornerSize: CGSize(width: 0.20, height: 0.24))
        var neck = Path()
        neck.move(to: CGPoint(x: 0.20, y: -0.20))
        neck.addQuadCurve(to: CGPoint(x: 0.50, y: -0.085),
                          control: CGPoint(x: 0.36, y: -0.17))
        neck.addLine(to: CGPoint(x: 0.62, y: -0.085))
        neck.addLine(to: CGPoint(x: 0.62, y: 0.085))
        neck.addLine(to: CGPoint(x: 0.50, y: 0.085))
        neck.addQuadCurve(to: CGPoint(x: 0.20, y: 0.20),
                          control: CGPoint(x: 0.36, y: 0.17))
        neck.closeSubpath()
        c.fill(body, with: .linearGradient(
            Gradient(colors: [glass.opacity(0.85), Color(red: 0.04, green: 0.12, blue: 0.10).opacity(0.9)]),
            startPoint: CGPoint(x: 0, y: -0.3), endPoint: CGPoint(x: 0, y: 0.3)))
        c.fill(neck, with: .color(glass.opacity(0.85)))
        // The cork & a highlight down the flank.
        c.fill(Path(CGRect(x: 0.60, y: -0.075, width: 0.08, height: 0.15)),
               with: .color(Color(red: 0.55, green: 0.40, blue: 0.24).opacity(0.9)))
        c.fill(Path(roundedRect: CGRect(x: -0.42, y: -0.18, width: 0.5, height: 0.07),
                    cornerRadius: 0.035),
               with: .color(.white.opacity(0.16)))
        // A lip of sand over the low corner buries it.
        canvas.fill(Path(ellipseIn: CGRect(x: baseX - s * 0.6, y: baseY - 3,
                                           width: s * 1.1, height: 5)),
                    with: .color(Color(red: 0.48, green: 0.40, blue: 0.27).opacity(0.9)))
    }

    /// A five-pointed star resting on the sand, with a rim, a raised
    /// centre and a row of bumps down each arm.
    private static let starPath: Path = {
        var p = Path()
        for i in 0..<10 {
            let a = Double(i) * .pi / 5 - .pi / 2
            let r = i % 2 == 0 ? 0.5 : 0.22
            let pt = CGPoint(x: cos(a) * r, y: sin(a) * r)
            if i == 0 { p.move(to: pt) } else { p.addLine(to: pt) }
        }
        p.closeSubpath()
        return p
    }()

    private func drawStarfish(canvas: inout GraphicsContext, size: CGSize, piece: TankDecor) {
        let x = piece.x * size.width
        let y = decorBaseY(piece, in: size)
        let s = 16 * piece.scale * Self.decorBoost
        groundShadow(canvas: &canvas, x: x, y: y + 1.5,
                     halfW: s * 0.6, halfH: 3.5, alpha: 0.26)
        var c = canvas
        c.translateBy(x: x, y: y - s * 0.18)
        c.rotate(by: .radians(Double(piece.bits & 0xFF) / 0xFF * .pi * 2))
        c.scaleBy(x: s, y: s)
        c.fill(Self.starPath,
               with: .color(Color(red: 0.90, green: 0.55, blue: 0.35).opacity(0.9)))
        c.stroke(Self.starPath,
                 with: .color(Color(red: 0.55, green: 0.28, blue: 0.14).opacity(0.6)),
                 lineWidth: 0.05)
        // A smaller, lighter star on top reads as the raised centre.
        var inner = c
        inner.scaleBy(x: 0.5, y: 0.5)
        inner.fill(Self.starPath,
                   with: .color(Color(red: 0.96, green: 0.70, blue: 0.46).opacity(0.7)))
        // Arm bumps.
        for i in 0..<5 {
            let a = Double(i) * .pi * 2 / 5 - .pi / 2
            c.fill(Path(ellipseIn: CGRect(x: cos(a) * 0.28 - 0.035,
                                          y: sin(a) * 0.28 - 0.035,
                                          width: 0.07, height: 0.07)),
                   with: .color(Color(red: 0.60, green: 0.33, blue: 0.16).opacity(0.6)))
        }
        c.fill(Path(ellipseIn: CGRect(x: -0.09, y: -0.09, width: 0.18, height: 0.18)),
               with: .color(Color(red: 0.62, green: 0.34, blue: 0.17).opacity(0.55)))
    }

    /// The treasure chest on the dune floor: a domed lid, wood planks
    /// shaded top to bottom, brass bands & a latch, a pool of shadow
    /// under it. The chest itself is still — it lives in the cached
    /// bed pass; its one moving part (the burp bubble) is
    /// `drawChestBurp` in the live pass.
    private func drawChest(canvas: inout GraphicsContext, size: CGSize, piece: TankDecor) {
        let w = 40 * piece.scale * Self.decorBoost
        let h = 26 * piece.scale * Self.decorBoost
        let x = piece.x * size.width
        let y = decorBaseY(piece, in: size) + 2
        let wood = Color(red: 0.40, green: 0.28, blue: 0.15)
        let woodDark = Color(red: 0.24, green: 0.16, blue: 0.08)
        let brass = Color(red: 0.78, green: 0.62, blue: 0.30)

        groundShadow(canvas: &canvas, x: x, y: y + 1, halfW: w * 0.62, halfH: 5, alpha: 0.32)

        // Body planks.
        let body = CGRect(x: x - w / 2, y: y - h * 0.60, width: w, height: h * 0.60)
        canvas.fill(Path(roundedRect: body, cornerRadius: 5),
                    with: .linearGradient(
                        Gradient(colors: [wood, woodDark]),
                        startPoint: CGPoint(x: x, y: y - h * 0.60),
                        endPoint: CGPoint(x: x, y: y)))
        for seam in [-0.17, 0.17] as [Double] {
            canvas.fill(Path(CGRect(x: x + w * seam - 1.0, y: y - h * 0.58,
                                    width: 2, height: h * 0.56)),
                        with: .color(woodDark.opacity(0.6)))
        }

        // The domed lid, a shade lighter than the body.
        var lid = Path()
        lid.move(to: CGPoint(x: x - w / 2 - 2.5, y: y - h * 0.58))
        lid.addQuadCurve(to: CGPoint(x: x + w / 2 + 2.5, y: y - h * 0.58),
                         control: CGPoint(x: x, y: y - h * 1.22))
        lid.closeSubpath()
        canvas.fill(lid, with: .linearGradient(
            Gradient(colors: [Color(red: 0.52, green: 0.36, blue: 0.19), wood]),
            startPoint: CGPoint(x: x, y: y - h), endPoint: CGPoint(x: x, y: y - h * 0.58)))
        canvas.stroke(lid, with: .color(.black.opacity(0.3)), lineWidth: 1.2)
        // The lid's lit crest.
        var crest = Path()
        crest.move(to: CGPoint(x: x - w * 0.28, y: y - h * 0.94))
        crest.addQuadCurve(to: CGPoint(x: x + w * 0.28, y: y - h * 0.94),
                           control: CGPoint(x: x, y: y - h * 1.14))
        canvas.stroke(crest, with: .color(Color(red: 0.9, green: 0.75, blue: 0.5).opacity(0.4)),
                      lineWidth: 2)

        // Brass bands over the lid & body, and the latch.
        for bandX in [-0.30, 0.30] as [Double] {
            let bx = x + w * bandX
            canvas.fill(Path(CGRect(x: bx - 2.6, y: y - h * 0.60, width: 5.2, height: h * 0.60)),
                        with: .color(brass.opacity(0.75)))
            var band = Path()
            band.move(to: CGPoint(x: bx - 2.6, y: y - h * 0.58))
            band.addQuadCurve(to: CGPoint(x: bx + 2.6, y: y - h * 0.58),
                              control: CGPoint(x: bx, y: y - h * (0.58 + 0.64 * (1 - abs(bandX) * 2.2))))
            canvas.stroke(band, with: .color(brass.opacity(0.75)), lineWidth: 5.2)
        }
        let latch = CGRect(x: x - 4, y: y - h * 0.72, width: 8, height: h * 0.20)
        canvas.fill(Path(roundedRect: latch, cornerRadius: 1.6),
                    with: .color(brass.opacity(0.85)))
        canvas.fill(Path(ellipseIn: CGRect(x: x - 1.6, y: y - h * 0.66, width: 3.2, height: 4)),
                    with: .color(woodDark.opacity(0.9)))
    }

    /// Every few seconds the chest burps a single bubble, the tank's
    /// smallest joke — the only moving part, so it draws in the live
    /// pass. Reduce Motion holds it in.
    private func drawChestBurp(canvas: inout GraphicsContext, size: CGSize,
                               t: Double, piece: TankDecor) {
        guard !reduceMotion else { return }
        let h = 26 * piece.scale * Self.decorBoost
        let x = piece.x * size.width
        let y = decorBaseY(piece, in: size) + 2
        let period = 6 + Double(piece.bits & 0xFF) / 0xFF * 5
        let rise = frac(t / period + Double((piece.bits >> 8) & 0xFF) / 0xFF)
        guard rise < 0.6 else { return }
        let br = 2.0 + rise * 2.5
        let by = y - h - rise * size.height * 0.35
        canvas.stroke(Path(ellipseIn: CGRect(x: x - br, y: by - br, width: br * 2, height: br * 2)),
                      with: .color(.white.opacity(0.5 * (1 - rise / 0.6))), lineWidth: 0.8)
    }

    // MARK: Ambient life

    /// A jellyfish pulses through the mid-water every ~40 s — or, when
    /// the tank is empty (`resident`), stays on as the standing guest
    /// on a slow figure-eight, so a quiet tank still has one living
    /// thing in it. A translucent bell over four trailing tentacles.
    /// Reduce Motion parks it mid-tank, unpulsed.
    private func drawJellyfish(canvas: inout GraphicsContext, size: CGSize, t: Double,
                               resident: Bool) {
        let x: Double
        let y: Double
        let pulse: Double
        let alpha: Double
        if resident {
            if reduceMotion {
                x = size.width * 0.5
                y = size.height * 0.30
                pulse = 0
            } else {
                x = size.width * (0.5 + 0.17 * sin(t * 0.11))
                y = size.height * (0.30 + 0.05 * sin(t * 0.23 + 1.3))
                pulse = sin(t * 1.9) * 0.10
            }
            alpha = 0.62
        } else {
            let progress: Double
            if reduceMotion {
                progress = 0.45
                pulse = 0
                alpha = 0.35
            } else {
                let life = frac(t / 40 + 0.31) * 40
                guard life < 15 else { return }
                progress = life / 15
                pulse = sin(t * 1.9) * 0.10
                alpha = 0.45 * smooth(clamp01(min(progress / 0.18, (1 - progress) / 0.12)))
            }
            x = size.width * (1.08 - 1.24 * progress)
            y = size.height * (0.30 + 0.10 * sin(progress * .pi * 2 + 1))
        }
        var j = canvas
        j.opacity = alpha
        j.translateBy(x: x, y: y)
        j.scaleBy(x: 34 * (1 + pulse), y: 30 * (1 - pulse))
        var bell = Path()
        bell.move(to: CGPoint(x: -0.5, y: 0.12))
        bell.addCurve(to: CGPoint(x: 0.5, y: 0.12),
                      control1: CGPoint(x: -0.52, y: -0.52),
                      control2: CGPoint(x: 0.52, y: -0.52))
        bell.addQuadCurve(to: CGPoint(x: -0.5, y: 0.12), control: CGPoint(x: 0, y: 0.30))
        bell.closeSubpath()
        j.fill(bell, with: .linearGradient(
            Gradient(stops: [
                .init(color: Color(red: 0.97, green: 0.84, blue: 0.93).opacity(0.95), location: 0),
                .init(color: Color(red: 0.90, green: 0.72, blue: 0.85).opacity(0.45), location: 0.7),
                .init(color: Color(red: 0.85, green: 0.65, blue: 0.80).opacity(0.15), location: 1),
            ]),
            startPoint: CGPoint(x: 0, y: -0.5), endPoint: CGPoint(x: 0, y: 0.3)))
        // A rim of light along the bell's lower lip.
        var lip = Path()
        lip.move(to: CGPoint(x: -0.5, y: 0.12))
        lip.addQuadCurve(to: CGPoint(x: 0.5, y: 0.12), control: CGPoint(x: 0, y: 0.30))
        j.stroke(lip, with: .color(Color(red: 0.98, green: 0.88, blue: 0.95).opacity(0.5)),
                 lineWidth: 0.04)
        for k in 0..<4 {
            let tx = -0.30 + Double(k) * 0.20
            var tent = Path()
            tent.move(to: CGPoint(x: tx, y: 0.12))
            tent.addCurve(to: CGPoint(x: tx + sin(t * 1.3 + Double(k) * 1.7) * 0.08, y: 0.85),
                          control1: CGPoint(x: tx - 0.06, y: 0.35),
                          control2: CGPoint(x: tx + 0.06, y: 0.60))
            j.stroke(tent, with: .color(Color(red: 0.9, green: 0.75, blue: 0.85).opacity(0.6)),
                     lineWidth: 0.05)
        }
        j.fill(Path(ellipseIn: CGRect(x: -0.16, y: -0.30, width: 0.32, height: 0.30)),
               with: .color(.white.opacity(0.5)))
    }

    /// Tap-dropped food: small brown pellets sinking toward the sand
    /// with a slow sway. The claim ring under a claimed pellet shows
    /// which fish is coming for it — informational only; the eat
    /// event fires in `stepSwim` when the fish actually arrives.
    private func drawFeed(canvas: inout GraphicsContext, size: CGSize, now: Date) {
        let m = motion
        for pellet in m.pellets {
            let age = now.timeIntervalSince(pellet.bornAt)
            let appear = smooth(clamp01(age / 0.25))
            // Fading out over the last few seconds of its life keeps
            // uneaten food from popping.
            let fade = 1 - smooth(clamp01((age - 20) / 4))
            let a = appear * fade
            guard a > 0.01 else { continue }
            let sway = reduceMotion ? 0 : sin(age * 3.1 + Double(pellet.id)) * 4
            let x = pellet.x * size.width + sway
            let y = pellet.y * size.height
            let r = 2.6
            canvas.fill(
                Path(ellipseIn: CGRect(x: x - r, y: y - r, width: r * 2, height: r * 2)),
                with: .color(Color(red: 0.55, green: 0.38, blue: 0.20).opacity(a)))
            canvas.fill(
                Path(ellipseIn: CGRect(x: x - r * 0.4, y: y - r * 0.55,
                                       width: r * 0.8, height: r * 0.5)),
                with: .color(Color(red: 0.85, green: 0.68, blue: 0.42).opacity(a * 0.5)))
            if m.claims[pellet.id] != nil {
                canvas.stroke(
                    Path(ellipseIn: CGRect(x: x - r - 3, y: y - r - 3,
                                           width: (r + 3) * 2, height: (r + 3) * 2)),
                    with: .color(.white.opacity(a * 0.25)), lineWidth: 0.7)
            }
        }
    }

    /// Purchased decor (docs/TOYS.md shop): each owned decor item
    /// stands on the sand at its own seeded spot — the plant is a
    /// bright leafy tuft, the rock a big smooth lump, the chest a
    /// smaller second treasure box, the castle a tiny spired keep.
    /// Nothing here touches session state; it's pure dressing.
    private func drawShopDecor(canvas: inout GraphicsContext, size: CGSize, t: Double) {
        guard let game else { return }
        if game.owns(.plant) {
            let x = size.width * 0.115
            let baseY = sandTop(atX: x, in: size)
            var p = canvas
            p.translateBy(x: x, y: baseY)
            // Three broad leaves fanning up, swaying gently.
            for k in 0..<4 {
                let h = AquariumModel.stableHash("shop-plant-\(k)")
                let lean = (Double(h & 0xFF) / 0xFF - 0.5) * 0.9
                let reach = 30 + Double((h >> 8) & 0xFF) / 0xFF * 26
                let sway = reduceMotion ? 0 : sin(t * 0.9 + Double(k) * 1.4) * 3.5
                var leaf = Path()
                leaf.move(to: .zero)
                leaf.addQuadCurve(
                    to: CGPoint(x: lean * reach + sway, y: -reach),
                    control: CGPoint(x: lean * reach * 0.35 + sway * 0.3, y: -reach * 0.5))
                let tip = CGPoint(x: lean * reach + sway, y: -reach)
                leaf.addQuadCurve(
                    to: .zero,
                    control: CGPoint(x: tip.x * 0.55 + 5.5, y: -reach * 0.45))
                leaf.closeSubpath()
                let shade = 0.45 + Double(k) * 0.12
                p.fill(leaf, with: .color(
                    Color(red: 0.10, green: shade, blue: 0.30).opacity(0.85)))
            }
            // A small crown of pebbles at the root.
            p.fill(Path(ellipseIn: CGRect(x: -9, y: -4, width: 18, height: 6)),
                   with: .color(Color(red: 0.45, green: 0.42, blue: 0.38).opacity(0.8)))
        }
        if game.owns(.rock) {
            let x = size.width * 0.315
            let baseY = sandTop(atX: x, in: size)
            var rock = Path()
            rock.move(to: CGPoint(x: x - 26, y: baseY))
            rock.addCurve(to: CGPoint(x: x - 8, y: baseY - 30),
                          control1: CGPoint(x: x - 24, y: baseY - 22),
                          control2: CGPoint(x: x - 18, y: baseY - 30))
            rock.addCurve(to: CGPoint(x: x + 14, y: baseY - 24),
                          control1: CGPoint(x: x + 2, y: baseY - 32),
                          control2: CGPoint(x: x + 10, y: baseY - 28))
            rock.addCurve(to: CGPoint(x: x + 26, y: baseY),
                          control1: CGPoint(x: x + 22, y: baseY - 16),
                          control2: CGPoint(x: x + 26, y: baseY - 6))
            rock.closeSubpath()
            canvas.fill(rock, with: .linearGradient(
                Gradient(stops: [
                    .init(color: Color(red: 0.48, green: 0.50, blue: 0.52), location: 0),
                    .init(color: Color(red: 0.28, green: 0.30, blue: 0.33), location: 1),
                ]),
                startPoint: CGPoint(x: x, y: baseY - 32),
                endPoint: CGPoint(x: x, y: baseY)))
            canvas.stroke(rock, with: .color(.black.opacity(0.25)), lineWidth: 1)
        }
        if game.owns(.treasureChest) {
            // A second, smaller chest — the seeded one keeps the
            // milestone plume; this one is the player's trophy.
            let x = size.width * 0.68
            let baseY = sandTop(atX: x, in: size)
            var c = canvas
            c.translateBy(x: x, y: baseY)
            c.scaleBy(x: 0.72, y: 0.72)
            let body = Path(roundedRect: CGRect(x: -20, y: -16, width: 40, height: 16),
                            cornerRadius: 2)
            c.fill(body, with: .color(Color(red: 0.42, green: 0.27, blue: 0.13)))
            var lid = Path()
            lid.move(to: CGPoint(x: -20, y: -16))
            lid.addQuadCurve(to: CGPoint(x: 20, y: -16), control: CGPoint(x: 0, y: -34))
            lid.addLine(to: CGPoint(x: 20, y: -13))
            lid.addLine(to: CGPoint(x: -20, y: -13))
            lid.closeSubpath()
            c.fill(lid, with: .color(Color(red: 0.50, green: 0.33, blue: 0.16)))
            c.fill(Path(CGRect(x: -3, y: -18, width: 6, height: 8)),
                   with: .color(Color(red: 0.85, green: 0.70, blue: 0.30)))
            c.stroke(body, with: .color(.black.opacity(0.3)), lineWidth: 1)
            c.stroke(lid, with: .color(.black.opacity(0.3)), lineWidth: 1)
        }
        if game.owns(.castle) {
            let x = size.width * 0.885
            let baseY = sandTop(atX: x, in: size)
            var c = canvas
            c.translateBy(x: x, y: baseY)
            // Sized off the tank like the rest of the owned set —
            // ~110 px tall at 700, the keep a landmark, not a trinket.
            c.scaleBy(x: size.height / 242, y: size.height / 242)
            let stone = Color(red: 0.62, green: 0.60, blue: 0.66)
            let dark = Color(red: 0.40, green: 0.38, blue: 0.44)
            // Keep: a round tower with crenellations and a door.
            var keep = Path()
            keep.move(to: CGPoint(x: -14, y: 0))
            keep.addLine(to: CGPoint(x: -14, y: -34))
            keep.addLine(to: CGPoint(x: -10, y: -34))
            keep.addLine(to: CGPoint(x: -10, y: -38))
            keep.addLine(to: CGPoint(x: -5, y: -38))
            keep.addLine(to: CGPoint(x: -5, y: -34))
            keep.addLine(to: CGPoint(x: 0, y: -34))
            keep.addLine(to: CGPoint(x: 0, y: -38))
            keep.addLine(to: CGPoint(x: 5, y: -38))
            keep.addLine(to: CGPoint(x: 5, y: -34))
            keep.addLine(to: CGPoint(x: 10, y: -34))
            keep.addLine(to: CGPoint(x: 10, y: -38))
            keep.addLine(to: CGPoint(x: 14, y: -38))
            keep.addLine(to: CGPoint(x: 14, y: -34))
            keep.addLine(to: CGPoint(x: 14, y: 0))
            keep.closeSubpath()
            c.fill(keep, with: .color(stone))
            c.stroke(keep, with: .color(dark), lineWidth: 1)
            // Door & window.
            var door = Path()
            door.move(to: CGPoint(x: -4, y: 0))
            door.addLine(to: CGPoint(x: -4, y: -10))
            door.addQuadCurve(to: CGPoint(x: 4, y: -10), control: CGPoint(x: 0, y: -14))
            door.addLine(to: CGPoint(x: 4, y: 0))
            door.closeSubpath()
            c.fill(door, with: .color(dark))
            c.fill(Path(ellipseIn: CGRect(x: -2, y: -26, width: 4, height: 5)),
                   with: .color(dark))
            // Side turret with a little flag.
            c.fill(Path(CGRect(x: -26, y: -20, width: 10, height: 20)),
                   with: .color(stone))
            c.stroke(Path(CGRect(x: -26, y: -20, width: 10, height: 20)),
                     with: .color(dark), lineWidth: 1)
            var pole = Path()
            pole.move(to: CGPoint(x: -21, y: -20))
            pole.addLine(to: CGPoint(x: -21, y: -30))
            c.stroke(pole, with: .color(dark), lineWidth: 1)
            var flag = Path()
            flag.move(to: CGPoint(x: -21, y: -30))
            flag.addLine(to: CGPoint(x: -14, y: -27.5))
            flag.addLine(to: CGPoint(x: -21, y: -25))
            flag.closeSubpath()
            c.fill(flag, with: .color(Color(red: 0.80, green: 0.25, blue: 0.30)))
        }
    }

    // MARK: Backdrop

    /// The back wall an owned backdrop item papers over the tank
    /// (docs/TOYS.md shop): "classic" leaves the open water, reefwall
    /// hangs a dim rock face with coral nubs behind the dunes, rocky
    /// stacks boulders along the back. Drawn on the still bed, dimmed
    /// into the water so it reads as metres away.
    private func drawBackdrop(canvas: inout GraphicsContext, size: CGSize) {
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

    // MARK: Owned decor — back row

    /// Where an owned back-row piece roots: its slot's x on the far
    /// dune, dimmed for depth like the seeded deep pieces.
    private func ownedBaseY(_ slot: AquariumModel.DecorSlot, in size: CGSize) -> Double {
        let x = slot.x * size.width
        return slot.back ? backDuneTop(atX: x, in: size) + 2
            : sandTop(atX: x, in: size) + 2
    }

    /// A bought piece's draw scale: its unit-space width grows into
    /// `slot.w` of the tank's height (the declared footprint), so the
    /// decor sizes follow the window like the kelp does.
    private func ownedScaleW(_ slot: AquariumModel.DecorSlot,
                             unitWidth: Double, in size: CGSize) -> Double {
        slot.w * size.height / unitWidth
    }

    /// Same, landing the piece's unit-space height on `slot.h` — for
    /// the tall-thin pieces (statue, columns, lamp).
    private func ownedScaleH(_ slot: AquariumModel.DecorSlot,
                             unitHeight: Double, in size: CGSize) -> Double {
        slot.h * size.height / unitHeight
    }

    /// The bought decor rooted on the far dune (docs/TOYS.md shop):
    /// shipwreck, amphora, statue, columns, volcano — still pieces
    /// behind the fish lane, baked into the bed. Each sits under a
    /// pooled shadow, dimmed for depth.
    private func drawOwnedBackDecor(canvas: inout GraphicsContext, size: CGSize,
                                    t: Double) {
        guard let game else { return }
        func slot(_ item: ShopItem) -> AquariumModel.DecorSlot? {
            game.owns(item) ? AquariumModel.decorSlot(for: item) : nil
        }
        if let s = slot(.shipwreck) { drawShipwreck(canvas: &canvas, size: size, slot: s) }
        if let s = slot(.amphora) { drawAmphora(canvas: &canvas, size: size, slot: s) }
        if let s = slot(.sunkenStatue) { drawStatue(canvas: &canvas, size: size, slot: s) }
        if let s = slot(.ruinedColumns) { drawColumns(canvas: &canvas, size: size, slot: s) }
        if let s = slot(.volcano) {
            drawVolcano(canvas: &canvas, size: size, slot: s,
                        lit: nightFactor(t: t) > 0.45 || isDarkTheme)
        }
    }

    /// A sunken hull: broken keel listing on the dune, a snapped mast
    /// leaning off it, all dim browns behind the swimmers.
    private func drawShipwreck(canvas: inout GraphicsContext, size: CGSize,
                               slot: AquariumModel.DecorSlot) {
        let x = slot.x * size.width
        let baseY = ownedBaseY(slot, in: size)
        let s = ownedScaleW(slot, unitWidth: 90, in: size)
        groundShadow(canvas: &canvas, x: x, y: baseY + 1,
                     halfW: 46 * s, alpha: 0.20)
        var c = canvas
        c.translateBy(x: x, y: baseY)
        c.scaleBy(x: s, y: s)
        c.opacity = 0.80
        let wood = Color(red: 0.30, green: 0.22, blue: 0.14)
        let woodDark = Color(red: 0.18, green: 0.13, blue: 0.08)
        // The hull: a wallowing bowl with a jagged break amidships.
        var hull = Path()
        hull.move(to: CGPoint(x: -44, y: -26))
        hull.addQuadCurve(to: CGPoint(x: -10, y: 0), control: CGPoint(x: -40, y: -4))
        hull.addLine(to: CGPoint(x: -4, y: -8))
        hull.addLine(to: CGPoint(x: 4, y: -2))
        hull.addLine(to: CGPoint(x: 12, y: -10))
        hull.addQuadCurve(to: CGPoint(x: 44, y: -20), control: CGPoint(x: 30, y: -6))
        hull.addQuadCurve(to: CGPoint(x: 36, y: 0), control: CGPoint(x: 44, y: -8))
        hull.closeSubpath()
        c.fill(hull, with: .color(wood))
        c.stroke(hull, with: .color(woodDark), lineWidth: 1.2)
        // Plank seams.
        for k in 0..<3 {
            var seam = Path()
            let y = -6.0 - Double(k) * 7
            seam.move(to: CGPoint(x: -40, y: y))
            seam.addQuadCurve(to: CGPoint(x: 40, y: y - 4),
                              control: CGPoint(x: 0, y: y + 4))
            c.stroke(seam, with: .color(woodDark.opacity(0.5)), lineWidth: 0.8)
        }
        // The snapped mast leaning forward, tattered yard still on.
        var mast = Path()
        mast.move(to: CGPoint(x: -6, y: -10))
        mast.addLine(to: CGPoint(x: 6, y: -62))
        c.stroke(mast, with: .color(wood), lineWidth: 3.5)
        var yard = Path()
        yard.move(to: CGPoint(x: -8, y: -46))
        yard.addLine(to: CGPoint(x: 22, y: -52))
        c.stroke(yard, with: .color(woodDark), lineWidth: 2)
        var sail = Path()
        sail.move(to: CGPoint(x: -6, y: -46))
        sail.addLine(to: CGPoint(x: 18, y: -51))
        sail.addLine(to: CGPoint(x: 10, y: -30))
        sail.addLine(to: CGPoint(x: 2, y: -36))
        sail.closeSubpath()
        c.fill(sail, with: .color(Color(red: 0.45, green: 0.42, blue: 0.36)
                                  .opacity(0.55)))
    }

    /// The tipped storage jar — the octopus's home when it has one.
    private func drawAmphora(canvas: inout GraphicsContext, size: CGSize,
                             slot: AquariumModel.DecorSlot) {
        let x = slot.x * size.width
        let baseY = ownedBaseY(slot, in: size)
        let s = ownedScaleW(slot, unitWidth: 34, in: size)
        groundShadow(canvas: &canvas, x: x, y: baseY + 1,
                     halfW: 22 * s, alpha: 0.22)
        var c = canvas
        c.translateBy(x: x, y: baseY)
        c.scaleBy(x: s, y: s)
        c.rotate(by: .radians(-1.15))
        let clay = Color(red: 0.52, green: 0.36, blue: 0.24)
        let clayDark = Color(red: 0.34, green: 0.22, blue: 0.14)
        var jar = Path()
        jar.move(to: CGPoint(x: -8, y: -34))
        jar.addCurve(to: CGPoint(x: -14, y: -6),
                     control1: CGPoint(x: -16, y: -28),
                     control2: CGPoint(x: -16, y: -14))
        jar.addQuadCurve(to: CGPoint(x: 14, y: -6),
                         control: CGPoint(x: 0, y: 4))
        jar.addCurve(to: CGPoint(x: 8, y: -34),
                     control1: CGPoint(x: 16, y: -14),
                     control2: CGPoint(x: 16, y: -28))
        jar.closeSubpath()
        c.fill(jar, with: .color(clay))
        c.stroke(jar, with: .color(clayDark), lineWidth: 1)
        // Rim & the dark mouth the octopus watches from.
        c.fill(Path(ellipseIn: CGRect(x: -9, y: -37, width: 18, height: 7)),
               with: .color(clayDark))
        c.fill(Path(ellipseIn: CGRect(x: -6.5, y: -36, width: 13, height: 5)),
               with: .color(.black.opacity(0.85)))
        // A band & a handle stub.
        c.stroke(Path(ellipseIn: CGRect(x: -13, y: -20, width: 26, height: 10)),
                 with: .color(clayDark.opacity(0.6)), lineWidth: 1)
    }

    /// A bust on a plinth — someone important, once.
    private func drawStatue(canvas: inout GraphicsContext, size: CGSize,
                            slot: AquariumModel.DecorSlot) {
        let x = slot.x * size.width
        let baseY = ownedBaseY(slot, in: size)
        let s = ownedScaleH(slot, unitHeight: 45, in: size)
        groundShadow(canvas: &canvas, x: x, y: baseY + 1,
                     halfW: 20 * s, alpha: 0.22)
        var c = canvas
        c.translateBy(x: x, y: baseY)
        c.scaleBy(x: s, y: s)
        c.opacity = 0.85
        let stone = Color(red: 0.52, green: 0.55, blue: 0.58)
        let stoneDark = Color(red: 0.34, green: 0.36, blue: 0.40)
        // Plinth.
        c.fill(Path(CGRect(x: -12, y: -16, width: 24, height: 16)),
               with: .color(stoneDark))
        c.stroke(Path(CGRect(x: -12, y: -16, width: 24, height: 16)),
                 with: .color(stone.opacity(0.5)), lineWidth: 0.8)
        // Shoulders & head.
        var bust = Path()
        bust.move(to: CGPoint(x: -11, y: -16))
        bust.addQuadCurve(to: CGPoint(x: -5, y: -30), control: CGPoint(x: -11, y: -26))
        bust.addQuadCurve(to: CGPoint(x: 5, y: -30), control: CGPoint(x: 0, y: -33))
        bust.addQuadCurve(to: CGPoint(x: 11, y: -16), control: CGPoint(x: 11, y: -26))
        bust.closeSubpath()
        c.fill(bust, with: .color(stone))
        c.fill(Path(ellipseIn: CGRect(x: -6, y: -44, width: 12, height: 15)),
               with: .color(stone))
        // Nose & brow shadow — a face, barely.
        c.stroke(Path(ellipseIn: CGRect(x: -6, y: -44, width: 12, height: 15)),
                 with: .color(stoneDark), lineWidth: 0.8)
        var nose = Path()
        nose.move(to: CGPoint(x: 1, y: -38))
        nose.addLine(to: CGPoint(x: 3, y: -34))
        c.stroke(nose, with: .color(stoneDark), lineWidth: 1)
    }

    /// Three fluted columns, one fallen — the ruin's rhythm.
    private func drawColumns(canvas: inout GraphicsContext, size: CGSize,
                             slot: AquariumModel.DecorSlot) {
        let x = slot.x * size.width
        let baseY = ownedBaseY(slot, in: size)
        let s = ownedScaleH(slot, unitHeight: 72, in: size)
        groundShadow(canvas: &canvas, x: x, y: baseY + 1,
                     halfW: 44 * s, alpha: 0.20)
        var c = canvas
        c.translateBy(x: x, y: baseY)
        c.scaleBy(x: s, y: s)
        c.opacity = 0.82
        let marble = Color(red: 0.56, green: 0.58, blue: 0.62)
        let marbleDark = Color(red: 0.38, green: 0.40, blue: 0.44)
        // Two standing, heights varied, flutes stroked down.
        let heights: [(x: Double, h: Double)] = [(-28, 54), (-4, 67)]
        for col in heights {
            c.fill(Path(CGRect(x: col.x - 7, y: -col.h, width: 14, height: col.h)),
                   with: .color(marble))
            c.stroke(Path(CGRect(x: col.x - 7, y: -col.h, width: 14, height: col.h)),
                     with: .color(marbleDark), lineWidth: 1)
            for k in -1...1 {
                var flute = Path()
                flute.move(to: CGPoint(x: col.x + Double(k) * 4, y: -col.h + 3))
                flute.addLine(to: CGPoint(x: col.x + Double(k) * 4, y: -4))
                c.stroke(flute, with: .color(marbleDark.opacity(0.45)), lineWidth: 0.9)
            }
            // Capital.
            c.fill(Path(CGRect(x: col.x - 9, y: -col.h - 5, width: 18, height: 5)),
                   with: .color(marbleDark))
        }
        // The fallen one on its side out front.
        var fallen = canvas
        fallen.translateBy(x: x + 36 * s, y: baseY - 6 * s)
        fallen.scaleBy(x: s, y: s)
        fallen.rotate(by: .radians(0.22))
        fallen.opacity = 0.82
        fallen.fill(Path(roundedRect: CGRect(x: -22, y: -7, width: 44, height: 14),
                         cornerRadius: 5),
                    with: .color(marble))
        fallen.stroke(Path(roundedRect: CGRect(x: -22, y: -7, width: 44, height: 14),
                           cornerRadius: 5),
                      with: .color(marbleDark), lineWidth: 1)
    }

    /// The cone: a broad shield with a rimmed crater bowl. Its throat
    /// always smoulders a little — a warm inner glow at any hour that
    /// goes molten at night (or in the dark themes), when the live
    /// pass's `drawVolcanoGlow` adds the halo and the ember climb.
    private func drawVolcano(canvas: inout GraphicsContext, size: CGSize,
                             slot: AquariumModel.DecorSlot, lit: Bool) {
        let x = slot.x * size.width
        let baseY = ownedBaseY(slot, in: size)
        let s = ownedScaleW(slot, unitWidth: 84, in: size)
        groundShadow(canvas: &canvas, x: x, y: baseY + 1,
                     halfW: 40 * s, alpha: 0.24)
        var c = canvas
        c.translateBy(x: x, y: baseY)
        c.scaleBy(x: s, y: s)
        c.opacity = 0.90
        // The cone silhouette: a broad base sweeping to a flat rim,
        // with a shoulder kink each side so it reads as rock, not a
        // sand hump.
        var cone = Path()
        cone.move(to: CGPoint(x: -42, y: 0))
        cone.addQuadCurve(to: CGPoint(x: -30, y: -26), control: CGPoint(x: -40, y: -18))
        cone.addQuadCurve(to: CGPoint(x: -13, y: -44), control: CGPoint(x: -24, y: -40))
        cone.addLine(to: CGPoint(x: 13, y: -44))
        cone.addQuadCurve(to: CGPoint(x: 30, y: -26), control: CGPoint(x: 24, y: -40))
        cone.addQuadCurve(to: CGPoint(x: 42, y: 0), control: CGPoint(x: 40, y: -18))
        cone.closeSubpath()
        c.fill(cone, with: .linearGradient(
            Gradient(colors: [Color(red: 0.30, green: 0.26, blue: 0.24),
                              Color(red: 0.14, green: 0.11, blue: 0.11)]),
            startPoint: CGPoint(x: 0, y: -44), endPoint: CGPoint(x: 0, y: 0)))
        c.stroke(cone, with: .color(.black.opacity(0.35)), lineWidth: 1.2)
        // Flank shading: darker seams running down from the rim so the
        // cone has faces.
        for k in [-1.0, 1.0] {
            var seam = Path()
            seam.move(to: CGPoint(x: k * 12, y: -42))
            seam.addQuadCurve(to: CGPoint(x: k * 32, y: -4),
                              control: CGPoint(x: k * 20, y: -24))
            c.stroke(seam, with: .color(.black.opacity(0.22)), lineWidth: 1.4)
        }
        // The crater bowl: a dark ellipse set into the rim, its near
        // lip catching whatever heat is inside.
        let bowl = Path(ellipseIn: CGRect(x: -14, y: -50, width: 28, height: 11))
        c.fill(bowl, with: .color(lit
                                  ? Color(red: 0.55, green: 0.14, blue: 0.05)
                                  : Color(red: 0.10, green: 0.08, blue: 0.08)))
        c.stroke(bowl, with: .color(.black.opacity(0.4)), lineWidth: 0.8)
        // The smoulder: a warm breath in the throat at every hour,
        // molten once lit — plus a thin hot rim on the crater's lip.
        var g = c
        g.blendMode = .plusLighter
        g.fill(bowl, with: .radialGradient(
            Gradient(colors: [Color(red: 1.0, green: 0.5, blue: 0.12)
                                .opacity(lit ? 0.95 : 0.30), .clear]),
            center: CGPoint(x: 0, y: -45), startRadius: 0, endRadius: 18))
        // A dull orange seam down the cone's face — the lava's old path.
        var lava = Path()
        lava.move(to: CGPoint(x: 4, y: -42))
        lava.addQuadCurve(to: CGPoint(x: 12, y: -12), control: CGPoint(x: 8, y: -26))
        c.stroke(lava, with: .color(Color(red: 0.75, green: 0.25, blue: 0.08)
                                    .opacity(lit ? 0.85 : 0.18)),
                 style: StrokeStyle(lineWidth: 2.2, lineCap: .round))
    }

    /// The live side of the owned decor: the volcano's ember drift
    /// (only when the crater's lit — night or a dark theme).
    private func drawVolcanoGlow(canvas: inout GraphicsContext, size: CGSize,
                                 t: Double, slot: AquariumModel.DecorSlot) {
        let x = slot.x * size.width
        let s = ownedScaleW(slot, unitWidth: 84, in: size)
        let craterY = ownedBaseY(slot, in: size) - 45 * s
        var g = canvas
        g.blendMode = .plusLighter
        g.fill(Path(ellipseIn: CGRect(x: x - 40 * s, y: craterY - 40 * s,
                                      width: 80 * s, height: 80 * s)),
               with: .radialGradient(
                   Gradient(colors: [Color(red: 1.0, green: 0.42, blue: 0.12)
                                       .opacity(0.30), .clear]),
                   center: CGPoint(x: x, y: craterY), startRadius: 0,
                   endRadius: 40 * s))
        for i in 0..<5 {
            var h = AquariumModel.stableHash("ember-\(i)")
            h ^= h >> 33; h &*= 0xff51afd7ed558ccd; h ^= h >> 33
            let period = 4 + Double(h & 0xF) * 0.4
            let p = frac(t / period + Double((h >> 8) & 0xFF) / 0xFF)
            let ex = x + (Double((h >> 16) & 0xFF) / 0xFF - 0.5) * 18 * s
                + sin(p * 5 + Double(i)) * 5 * s
            let ey = craterY - p * 55 * s
            let er = (1.2 + Double((h >> 24) & 0x3) * 0.5) * s
            var e = canvas
            e.blendMode = .plusLighter
            e.opacity = (1 - p) * 0.9
            e.fill(Path(ellipseIn: CGRect(x: ex - er, y: ey - er,
                                          width: er * 2, height: er * 2)),
                   with: .color(Color(red: 1.0, green: 0.45, blue: 0.12)))
        }
    }

    // MARK: Owned decor — front row

    /// The bought decor on the near crest (docs/TOYS.md shop):
    /// driftwood, the anemone's swaying bed, the jelly lamp's pulsing
    /// dome, the coral garden, the bubble wall's curtain — drawn over
    /// the fish lane like the shop's original four.
    private func drawOwnedFrontDecor(canvas: inout GraphicsContext, size: CGSize,
                                     t: Double) {
        guard let game else { return }
        func slot(_ item: ShopItem) -> AquariumModel.DecorSlot? {
            game.owns(item) ? AquariumModel.decorSlot(for: item) : nil
        }
        if let s = slot(.driftwood) { drawDriftwood(canvas: &canvas, size: size, slot: s) }
        if let s = slot(.anemoneBed) { drawAnemone(canvas: &canvas, size: size, t: t, slot: s) }
        if let s = slot(.moonJellyLamp) { drawJellyLamp(canvas: &canvas, size: size, t: t, slot: s) }
        if let s = slot(.coralGarden) { drawCoralGarden(canvas: &canvas, size: size, slot: s) }
        if let s = slot(.bubbleWall) { drawBubbleWall(canvas: &canvas, size: size, t: t, slot: s) }
        // The volcano's live half rides along when the crater's lit.
        if let s = game.owns(.volcano) ? AquariumModel.decorSlot(for: .volcano) : nil,
           nightFactor(t: t) > 0.45 || isDarkTheme {
            drawVolcanoGlow(canvas: &canvas, size: size, t: t, slot: s)
        }
    }

    /// A smoothed water-logged branch, half settled into the sand.
    private func drawDriftwood(canvas: inout GraphicsContext, size: CGSize,
                               slot: AquariumModel.DecorSlot) {
        let x = slot.x * size.width
        let baseY = ownedBaseY(slot, in: size)
        let s = ownedScaleW(slot, unitWidth: 60, in: size)
        groundShadow(canvas: &canvas, x: x, y: baseY + 1,
                     halfW: 30 * s, alpha: 0.24)
        var c = canvas
        c.translateBy(x: x, y: baseY)
        c.scaleBy(x: s, y: s)
        let wood = Color(red: 0.48, green: 0.40, blue: 0.32)
        let woodDark = Color(red: 0.30, green: 0.24, blue: 0.18)
        var log = Path()
        log.move(to: CGPoint(x: -30, y: -4))
        log.addQuadCurve(to: CGPoint(x: 26, y: -14), control: CGPoint(x: -6, y: -16))
        log.addQuadCurve(to: CGPoint(x: 30, y: -6), control: CGPoint(x: 28, y: -11))
        log.addQuadCurve(to: CGPoint(x: -26, y: 0), control: CGPoint(x: 2, y: -3))
        log.closeSubpath()
        c.fill(log, with: .color(wood))
        c.stroke(log, with: .color(woodDark), lineWidth: 1)
        // A forked stub and grain lines.
        var stub = Path()
        stub.move(to: CGPoint(x: -8, y: -10))
        stub.addQuadCurve(to: CGPoint(x: -16, y: -24), control: CGPoint(x: -10, y: -18))
        c.stroke(stub, with: .color(wood), lineWidth: 4)
        for k in 0..<2 {
            var grain = Path()
            let y = -6.0 - Double(k) * 4
            grain.move(to: CGPoint(x: -26, y: y))
            grain.addQuadCurve(to: CGPoint(x: 24, y: y - 6),
                               control: CGPoint(x: -2, y: y - 2))
            c.stroke(grain, with: .color(woodDark.opacity(0.4)), lineWidth: 0.8)
        }
    }

    /// A bed of anemone tentacles, swaying in a slow wave — the live
    /// pass keeps them breathing; Reduce Motion holds a soft lean.
    private func drawAnemone(canvas: inout GraphicsContext, size: CGSize,
                             t: Double, slot: AquariumModel.DecorSlot) {
        let x = slot.x * size.width
        let baseY = ownedBaseY(slot, in: size)
        let s = ownedScaleW(slot, unitWidth: 44, in: size)
        groundShadow(canvas: &canvas, x: x, y: baseY + 1,
                     halfW: 26 * s, alpha: 0.22)
        var c = canvas
        c.translateBy(x: x, y: baseY)
        c.scaleBy(x: s, y: s)
        for i in 0..<14 {
            let h = scatter(AquariumModel.stableHash("anemone"), i)
            let rootX = (Double(h & 0xFF) / 0xFF - 0.5) * 40
            let reach = 14 + Double((h >> 8) & 0xFF) / 0xFF * 14
            let lean = (Double((h >> 16) & 0xFF) / 0xFF - 0.5) * 10
            let sway = reduceMotion ? 2.0
                : sin(t * 1.3 + Double(h >> 24 & 0xFF) * 0.1) * 4
            var tent = Path()
            tent.move(to: CGPoint(x: rootX, y: 0))
            tent.addQuadCurve(
                to: CGPoint(x: rootX + lean + sway, y: -reach),
                control: CGPoint(x: rootX + lean * 0.3, y: -reach * 0.5))
            let hue = Double((h >> 32) & 0xFF) / 0xFF
            c.stroke(tent, with: .color(
                Color(red: 0.75 + hue * 0.15, green: 0.35 + hue * 0.25,
                      blue: 0.50 + hue * 0.20).opacity(0.85)),
                     style: StrokeStyle(lineWidth: 2.6, lineCap: .round))
            // The pale tip.
            c.fill(Path(ellipseIn: CGRect(x: rootX + lean + sway - 1.8,
                                          y: -reach - 1.8,
                                          width: 3.6, height: 3.6)),
                   with: .color(Color(red: 0.95, green: 0.80, blue: 0.85)
                                .opacity(0.9)))
        }
    }

    /// A glass dome on a brass base with a moon jelly inside; its
    /// glow breathes on a six-second pulse, additive.
    private func drawJellyLamp(canvas: inout GraphicsContext, size: CGSize,
                               t: Double, slot: AquariumModel.DecorSlot) {
        let x = slot.x * size.width
        let baseY = ownedBaseY(slot, in: size)
        let s = ownedScaleH(slot, unitHeight: 52, in: size)
        groundShadow(canvas: &canvas, x: x, y: baseY + 1,
                     halfW: 16 * s, alpha: 0.22)
        let pulse = reduceMotion ? 0.6 : 0.55 + 0.45 * sin(t * .pi * 2 / 6)
        var c = canvas
        c.translateBy(x: x, y: baseY)
        c.scaleBy(x: s, y: s)
        // The glow first — under the glass it reads as coming through.
        var g = c
        g.blendMode = .plusLighter
        g.fill(Path(ellipseIn: CGRect(x: -22, y: -52, width: 44, height: 52)),
               with: .radialGradient(
                   Gradient(colors: [Color(red: 0.55, green: 0.85, blue: 0.95)
                                       .opacity(0.35 * pulse + 0.08), .clear]),
                   center: CGPoint(x: 0, y: -28), startRadius: 0, endRadius: 26))
        // Base & dome.
        c.fill(Path(roundedRect: CGRect(x: -9, y: -6, width: 18, height: 6),
                    cornerRadius: 2),
               with: .color(Color(red: 0.55, green: 0.45, blue: 0.25)))
        var dome = Path()
        dome.move(to: CGPoint(x: -11, y: -6))
        dome.addQuadCurve(to: CGPoint(x: 11, y: -6), control: CGPoint(x: 0, y: -46))
        dome.closeSubpath()
        c.fill(dome, with: .color(Color(red: 0.65, green: 0.85, blue: 0.95)
                                  .opacity(0.18)))
        c.stroke(dome, with: .color(Color(red: 0.80, green: 0.92, blue: 1.0)
                                    .opacity(0.45)),
                 lineWidth: 1)
        // The jelly: a bell & two trailing arms, brighter on the pulse.
        c.fill(Path(ellipseIn: CGRect(x: -6, y: -30, width: 12, height: 8)),
               with: .color(Color(red: 0.80, green: 0.92, blue: 1.0)
                            .opacity(0.5 + 0.3 * pulse)))
        for k in -1...1 {
            var arm = Path()
            arm.move(to: CGPoint(x: Double(k) * 3, y: -22))
            arm.addQuadCurve(to: CGPoint(x: Double(k) * 3 + sin(t + Double(k)) * 2,
                                         y: -12),
                             control: CGPoint(x: Double(k) * 3 - 2, y: -17))
            c.stroke(arm, with: .color(Color(red: 0.80, green: 0.92, blue: 1.0)
                                       .opacity(0.35 + 0.25 * pulse)),
                     lineWidth: 1)
        }
    }

    /// A cluster of varied corals — a couple of fans, a brain, a
    /// branching sprig — sharing one footprint.
    private func drawCoralGarden(canvas: inout GraphicsContext, size: CGSize,
                                 slot: AquariumModel.DecorSlot) {
        let x = slot.x * size.width
        let baseY = ownedBaseY(slot, in: size)
        let s = ownedScaleW(slot, unitWidth: 64, in: size)
        groundShadow(canvas: &canvas, x: x, y: baseY + 1,
                     halfW: 34 * s, alpha: 0.24)
        var c = canvas
        c.translateBy(x: x, y: baseY)
        c.scaleBy(x: s, y: s)
        // A fan coral each side — reuse the seeded piece's geometry in
        // miniature.
        for side in [-1.0, 1.0] {
            var fan = Path()
            let bx = side * 16
            fan.move(to: CGPoint(x: bx, y: 0))
            fan.addQuadCurve(to: CGPoint(x: bx + side * 14, y: -26),
                             control: CGPoint(x: bx + side * 2, y: -20))
            fan.addQuadCurve(to: CGPoint(x: bx + side * 6, y: -10),
                             control: CGPoint(x: bx + side * 12, y: -12))
            fan.closeSubpath()
            c.fill(fan, with: .color(Color(red: 0.82, green: 0.42, blue: 0.50)
                                     .opacity(0.85)))
            c.stroke(fan, with: .color(Color(red: 0.55, green: 0.22, blue: 0.32)),
                     lineWidth: 0.8)
        }
        // The brain mound with its grooves.
        c.fill(Path(ellipseIn: CGRect(x: -10, y: -14, width: 20, height: 14)),
               with: .color(Color(red: 0.85, green: 0.68, blue: 0.42)))
        for k in 0..<3 {
            var groove = Path()
            let gy = -12 + Double(k) * 4
            groove.move(to: CGPoint(x: -8, y: gy))
            groove.addQuadCurve(to: CGPoint(x: 8, y: gy),
                                control: CGPoint(x: 0, y: gy - 4))
            c.stroke(groove, with: .color(Color(red: 0.55, green: 0.40, blue: 0.22)),
                     lineWidth: 0.8)
        }
        // Branching sprig centre-back.
        var sprig = Path()
        sprig.move(to: CGPoint(x: 2, y: -2))
        sprig.addLine(to: CGPoint(x: 2, y: -22))
        sprig.move(to: CGPoint(x: 2, y: -14))
        sprig.addLine(to: CGPoint(x: -4, y: -20))
        sprig.move(to: CGPoint(x: 2, y: -16))
        sprig.addLine(to: CGPoint(x: 9, y: -24))
        c.stroke(sprig, with: .color(Color(red: 0.70, green: 0.45, blue: 0.70)),
                 style: StrokeStyle(lineWidth: 2.5, lineCap: .round))
    }

    /// A curtain of bubbles off an air stone — the column of fizz
    /// runs on the live pass; the stone itself is a dark pebble bar.
    private func drawBubbleWall(canvas: inout GraphicsContext, size: CGSize,
                                t: Double, slot: AquariumModel.DecorSlot) {
        let x = slot.x * size.width
        let baseY = ownedBaseY(slot, in: size)
        let s = ownedScaleW(slot, unitWidth: 40, in: size)
        // The air stone.
        canvas.fill(Path(roundedRect: CGRect(x: x - 18 * s,
                                             y: baseY - 5,
                                             width: 36 * s, height: 6),
                         cornerRadius: 3),
                    with: .color(Color(red: 0.18, green: 0.16, blue: 0.14)))
        groundShadow(canvas: &canvas, x: x, y: baseY + 1,
                     halfW: 20 * s, alpha: 0.18)
        // The curtain: several parallel bubble streams, each a seeded
        // column rising & wobbling to the surface.
        for i in 0..<5 {
            let h = scatter(AquariumModel.stableHash("bubwall"), i)
            let bx = x + (Double(i) - 2) * 6 * s
            let speed = 30 + Double(h & 0xFF) / 0xFF * 22
            for k in 0..<6 {
                let ph = frac(t * speed / 400 + Double(k) / 6
                              + Double((h >> 8) & 0xFF) / 0xFF)
                let by = baseY - 8 - ph * (baseY - 18)
                guard by > 14 else { continue }
                let wx = bx + sin(t * 2.2 + Double(k) * 1.7 + Double(i)) * 3
                let br = (1.0 + Double((h >> 16) & 0x3) * 0.5 + ph * 1.2) * s * 0.7
                var b = canvas
                b.opacity = 0.5 * (1 - ph * 0.4)
                b.stroke(Path(ellipseIn: CGRect(x: wx - br, y: by - br,
                                                width: br * 2, height: br * 2)),
                         with: .color(.white), lineWidth: 0.7)
            }
        }
    }

    /// The idle game's collectables (docs/TOYS.md): a full-grown fish
    /// sheds a pearl now and then; it rests on the sand under where
    /// the fish was, softly pulsing until tapped or the snail reaches
    /// it. Each drop's hitbox goes into `motion.dropBoxes` — the tap
    /// gesture collects through `toy.collectDrop`, which is the only
    /// mutation; the drawing itself is inert.
    private func drawDrops(canvas: inout GraphicsContext, size: CGSize, t: Double,
                           layouts: [String: Layout]) {
        guard let game else { return }
        let m = motion
        m.dropBoxes.removeAll(keepingCapacity: true)
        for drop in game.drops {
            // Anchor near the minting fish's x if it's still in the
            // tank; otherwise a stable per-drop spot along the bed.
            let unitX: Double
            if let l = layouts[drop.fishID] {
                unitX = l.x / size.width
            } else {
                let h = AquariumModel.stableHash("drop-\(drop.id)")
                unitX = 0.12 + 0.76 * Double(h & 0xFFFF) / 0xFFFF
            }
            let x = min(size.width - 16, max(16, unitX * size.width))
            let y = sandTop(atX: x, in: size) - 5
            let pulse = reduceMotion ? 0.5 : 0.5 + 0.5 * sin(t * 2.2 + Double(drop.at.truncatingRemainder(dividingBy: 6)))
            let r = 5.0 + pulse * 1.2
            // A warm halo under the pearl so it reads as a pick-up.
            var halo = canvas
            halo.blendMode = .plusLighter
            halo.fill(Path(ellipseIn: CGRect(x: x - r * 2.4, y: y - r * 2.4,
                                             width: r * 4.8, height: r * 4.8)),
                      with: .radialGradient(
                        Gradient(colors: [Color(red: 1, green: 0.92, blue: 0.70).opacity(0.28 + 0.14 * pulse),
                                          .clear]),
                        center: CGPoint(x: x, y: y), startRadius: 0, endRadius: r * 2.4))
            canvas.fill(Path(ellipseIn: CGRect(x: x - r, y: y - r, width: r * 2, height: r * 2)),
                        with: .radialGradient(
                            Gradient(stops: [
                                .init(color: .white, location: 0),
                                .init(color: Color(red: 0.95, green: 0.88, blue: 0.72), location: 0.55),
                                .init(color: Color(red: 0.72, green: 0.60, blue: 0.46), location: 1),
                            ]),
                            center: CGPoint(x: x - r * 0.3, y: y - r * 0.3),
                            startRadius: 0, endRadius: r * 1.1))
            canvas.stroke(Path(ellipseIn: CGRect(x: x - r, y: y - r, width: r * 2, height: r * 2)),
                          with: .color(.white.opacity(0.35)), lineWidth: 0.6)
            m.dropBoxes.append((drop.id, CGRect(x: x - 16, y: y - 16, width: 32, height: 32)))
        }
    }

    /// The tank's silent "bloop": an eaten pellet, a collected drop or
    /// a tap on the glass pops a small ring with three specks thrown
    /// off it. Under a second, then gone.
    private func drawPuffs(canvas: inout GraphicsContext, size: CGSize, now: Date) {
        for puff in motion.puffs {
            let p = clamp01(now.timeIntervalSince(puff.bornAt) / 0.7)
            guard p < 1 else { continue }
            let x = puff.x * size.width
            let y = puff.y * size.height
            let rr = 3 + p * 13
            var ring = canvas
            ring.opacity = (1 - p) * 0.55
            ring.stroke(Path(ellipseIn: CGRect(x: x - rr, y: y - rr,
                                               width: rr * 2, height: rr * 2)),
                        with: .color(.white), lineWidth: 1.1)
            for k in 0..<3 {
                let a = Double(k) * 2.1 + 0.4
                let bx = x + cos(a) * rr * 0.7
                let by = y + sin(a) * rr * 0.7 - p * 8
                let br = 1.2 + Double(k) * 0.5
                var speck = canvas
                speck.opacity = (1 - p) * 0.5
                speck.stroke(Path(ellipseIn: CGRect(x: bx - br, y: by - br,
                                                    width: br * 2, height: br * 2)),
                             with: .color(.white), lineWidth: 0.6)
            }
        }
    }

    /// Pearls fly home: a collected drop or an eaten pellet's pearl
    /// arcs up to the counter chip on a little hop and blinks out on
    /// arrival. Where the toast's "+1" visibly comes from.
    private func drawFlights(canvas: inout GraphicsContext, size: CGSize, now: Date) {
        // The pearl HUD chip sits top-left; the approximation is fine —
        // the flight is a flourish, not a survey.
        let target = CGPoint(x: 34, y: 20)
        for flight in motion.flights {
            let p = now.timeIntervalSince(flight.bornAt) / 0.75
            guard p < 1 else { continue }
            let at = AquariumBehavior.flightPoint(from: flight.from, to: target, p: p)
            let fade = 1 - smooth(clamp01((p - 0.85) / 0.15))
            let r = 3.4
            var f = canvas
            f.opacity = fade
            f.fill(Path(ellipseIn: CGRect(x: at.x - r, y: at.y - r,
                                          width: r * 2, height: r * 2)),
                   with: .radialGradient(
                    Gradient(colors: [.white, Color(red: 0.95, green: 0.88, blue: 0.72)]),
                    center: at, startRadius: 0, endRadius: r))
            f.stroke(Path(ellipseIn: CGRect(x: at.x - r, y: at.y - r,
                                            width: r * 2, height: r * 2)),
                     with: .color(.white.opacity(0.6)), lineWidth: 0.6)
        }
    }

    /// The hermit crab shuffles sideways along the sand, pausing to
    /// tuck into its shell. Reduce Motion parks it near the middle.
    private func drawHermitCrab(canvas: inout GraphicsContext, size: CGSize, t: Double) {
        // A slow shuttle across the bed with rest stops: walk 70% of
        // each ~90 s lap, sit tucked the rest.
        let lap = reduceMotion ? 0.45 : frac(t / 90 + 0.13)
        let walking = lap < 0.7
        let progress = walking ? lap / 0.7 : 1
        let x = size.width * (0.10 + 0.78 * progress)
        let y = sandTop(atX: x, in: size) - 2
        var c = canvas
        c.translateBy(x: x, y: y)
        c.scaleBy(x: 16, y: 12)
        let flesh = Color(red: 0.78, green: 0.42, blue: 0.30)
        let shell = Color(red: 0.68, green: 0.55, blue: 0.42)
        if walking && !reduceMotion {
            // Little stepping legs under the shell.
            let step = sin(t * 14)
            for k in 0..<3 {
                var leg = Path()
                let lx = -0.25 + Double(k) * 0.22
                leg.move(to: CGPoint(x: lx, y: -0.05))
                leg.addLine(to: CGPoint(x: lx + step * (k.isMultiple(of: 2) ? 0.10 : -0.10),
                                        y: 0.10))
                c.stroke(leg, with: .color(flesh), lineWidth: 0.06)
            }
        }
        // The borrowed shell: a bump with a spiral hint.
        var sh = Path()
        sh.move(to: CGPoint(x: -0.42, y: 0.06))
        sh.addQuadCurve(to: CGPoint(x: 0.30, y: 0.04), control: CGPoint(x: -0.05, y: 0.14))
        sh.addQuadCurve(to: CGPoint(x: 0.34, y: -0.30), control: CGPoint(x: 0.44, y: -0.08))
        sh.addQuadCurve(to: CGPoint(x: -0.20, y: -0.52), control: CGPoint(x: 0.20, y: -0.56))
        sh.addQuadCurve(to: CGPoint(x: -0.42, y: 0.06), control: CGPoint(x: -0.48, y: -0.30))
        sh.closeSubpath()
        c.fill(sh, with: .color(shell))
        c.stroke(sh, with: .color(Color(red: 0.45, green: 0.34, blue: 0.26)),
                 lineWidth: 0.04)
        c.stroke(Path(ellipseIn: CGRect(x: -0.22, y: -0.40, width: 0.24, height: 0.22)),
                 with: .color(Color(red: 0.45, green: 0.34, blue: 0.24).opacity(0.7)),
                 lineWidth: 0.045)
        // Eyes on stalks peek from under the shell lip — out when
        // walking, tucked (hidden) when resting.
        if walking {
            for dx in [0.30, 0.44] {
                var stalk = Path()
                stalk.move(to: CGPoint(x: dx - 0.06, y: -0.06))
                stalk.addQuadCurve(to: CGPoint(x: dx, y: -0.30),
                                   control: CGPoint(x: dx - 0.02, y: -0.20))
                c.stroke(stalk, with: .color(flesh), lineWidth: 0.045)
                c.fill(Path(ellipseIn: CGRect(x: dx - 0.035, y: -0.345,
                                              width: 0.07, height: 0.07)),
                       with: .color(.white))
                c.fill(Path(ellipseIn: CGRect(x: dx - 0.012, y: -0.322,
                                              width: 0.03, height: 0.03)),
                       with: .color(.black))
            }
            // One claw.
            var claw = Path()
            claw.move(to: CGPoint(x: 0.44, y: 0.04))
            claw.addQuadCurve(to: CGPoint(x: 0.62, y: -0.10),
                              control: CGPoint(x: 0.58, y: 0.02))
            claw.addQuadCurve(to: CGPoint(x: 0.52, y: 0.02),
                              control: CGPoint(x: 0.60, y: -0.02))
            claw.closeSubpath()
            c.fill(claw, with: .color(flesh))
        }
    }

    /// A snail inches along the sand — about four minutes a crossing.
    /// Reduce Motion sits it mid-tank.
    private func drawSnail(canvas: inout GraphicsContext, size: CGSize, t: Double) {
        let crawl = reduceMotion ? 0.42 : frac(t * 0.0042 + 0.6)
        let x = size.width * (0.06 + crawl * 0.88)
        // It inches along the dune crest, not the glass bottom.
        let y = sandTop(atX: x, in: size) - 1
        var s = canvas
        s.opacity = 0.85
        s.translateBy(x: x, y: y)
        s.scaleBy(x: 25, y: 19)
        let flesh = Color(red: 0.55, green: 0.45, blue: 0.34)
        var body = Path()
        body.move(to: CGPoint(x: -0.5, y: 0.05))
        body.addQuadCurve(to: CGPoint(x: 0.62, y: 0.02), control: CGPoint(x: 0.1, y: 0.16))
        body.addQuadCurve(to: CGPoint(x: 0.55, y: -0.18), control: CGPoint(x: 0.66, y: -0.08))
        body.addQuadCurve(to: CGPoint(x: -0.1, y: -0.14), control: CGPoint(x: 0.2, y: -0.26))
        body.addQuadCurve(to: CGPoint(x: -0.5, y: 0.05), control: CGPoint(x: -0.36, y: -0.08))
        body.closeSubpath()
        s.fill(body, with: .color(flesh))
        // The shell, with a hint of spiral.
        s.fill(Path(ellipseIn: CGRect(x: -0.42, y: -0.62, width: 0.58, height: 0.58)),
               with: .color(Color(red: 0.62, green: 0.40, blue: 0.24)))
        s.stroke(Path(ellipseIn: CGRect(x: -0.30, y: -0.50, width: 0.34, height: 0.34)),
                 with: .color(Color(red: 0.40, green: 0.25, blue: 0.14).opacity(0.8)),
                 lineWidth: 0.06)
        // Two eyestalks, because it is a screensaver.
        for dx in [0.42, 0.55] {
            var stalk = Path()
            stalk.move(to: CGPoint(x: dx - 0.1, y: -0.14))
            stalk.addQuadCurve(to: CGPoint(x: dx, y: -0.42), control: CGPoint(x: dx - 0.05, y: -0.30))
            s.stroke(stalk, with: .color(flesh), lineWidth: 0.05)
            s.fill(Path(ellipseIn: CGRect(x: dx - 0.045, y: -0.47, width: 0.09, height: 0.09)),
                   with: .color(.white.opacity(0.9)))
        }
    }

    // MARK: Shop pets

    /// The sea turtle: a slow glide across midwater on a long lazy
    /// sweep, rising for a breath every minute or so — a patient
    /// silhouette behind the fish lane.
    private func drawSeaTurtle(canvas: inout GraphicsContext, size: CGSize, t: Double) {
        let period = 90.0
        let phase = frac(t / period)
        // The glide: across the tank one way, back the next.
        let leg = frac(phase * 2)
        let dir = phase < 0.5 ? 1.0 : -1.0
        let x = size.width * (phase < 0.5 ? leg : 1 - leg)
        // Mostly mid-depth; the last stretch of each leg climbs to
        // sip the surface and sinks back.
        let breathe = smooth(clamp01((leg - 0.72) / 0.10))
            * smooth(clamp01((0.98 - leg) / 0.10))
        let baseY = size.height * 0.42
        let y = reduceMotion ? baseY
            : baseY + sin(t * 0.4) * 14 - breathe * (baseY - 46)
        let flap = reduceMotion ? 0 : sin(t * 2.4) * 0.35
        var c = canvas
        c.translateBy(x: x, y: y)
        c.scaleBy(x: dir, y: 1)
        c.opacity = 0.85
        let shell = Color(red: 0.30, green: 0.38, blue: 0.26)
        let skin = Color(red: 0.45, green: 0.52, blue: 0.38)
        // Flippers behind the shell so the dome sits on top.
        var front = Path()
        front.move(to: CGPoint(x: 8, y: 4))
        front.addQuadCurve(to: CGPoint(x: 24, y: 12 + flap * 8),
                           control: CGPoint(x: 18, y: 2))
        front.addQuadCurve(to: CGPoint(x: 10, y: 10),
                           control: CGPoint(x: 16, y: 10))
        front.closeSubpath()
        c.fill(front, with: .color(skin.opacity(0.9)))
        var rear = Path()
        rear.move(to: CGPoint(x: -12, y: 4))
        rear.addQuadCurve(to: CGPoint(x: -24, y: 10 - flap * 6),
                          control: CGPoint(x: -18, y: 3))
        rear.addQuadCurve(to: CGPoint(x: -12, y: 9),
                          control: CGPoint(x: -16, y: 9))
        rear.closeSubpath()
        c.fill(rear, with: .color(skin.opacity(0.85)))
        // Head poking ahead.
        c.fill(Path(ellipseIn: CGRect(x: 16, y: -5, width: 10, height: 8)),
               with: .color(skin))
        c.fill(Path(ellipseIn: CGRect(x: 22, y: -3, width: 2, height: 2)),
               with: .color(.black.opacity(0.7)))
        // The dome with its plate seams.
        let dome = Path(ellipseIn: CGRect(x: -18, y: -12, width: 38, height: 22))
        c.fill(dome, with: .color(shell))
        c.stroke(dome, with: .color(Color(red: 0.18, green: 0.24, blue: 0.16)),
                 lineWidth: 1.2)
        for k in -1...1 {
            var seam = Path()
            seam.move(to: CGPoint(x: Double(k) * 9, y: -11))
            seam.addQuadCurve(to: CGPoint(x: Double(k) * 9 + 3, y: 9),
                              control: CGPoint(x: Double(k) * 9 - 2, y: -1))
            c.stroke(seam, with: .color(Color(red: 0.18, green: 0.24, blue: 0.16)
                                        .opacity(0.5)),
                     lineWidth: 0.8)
        }
        // The breath: two bubbles off the nose on the way down.
        if breathe > 0.5 && !reduceMotion {
            for k in 0..<2 {
                let bp = frac(t * 0.9 + Double(k) * 0.5)
                var b = canvas
                b.opacity = (1 - bp) * 0.5
                b.stroke(Path(ellipseIn: CGRect(x: x + dir * 20 - 2 - bp * 4,
                                                y: y - 8 - bp * 30,
                                                width: 3 + bp * 3, height: 3 + bp * 3)),
                         with: .color(.white), lineWidth: 0.7)
            }
        }
    }

    /// The octopus: it keeps house in the amphora when the tank has
    /// one, else behind the first seeded rock. Every ~minute two eyes
    /// peek over the rim; every few it pours out, crawls a short arc
    /// across the sand, and pours back. It shades toward the
    /// substrate like the real thing.
    private func drawOctopus(canvas: inout GraphicsContext, size: CGSize, t: Double) {
        // Home: the amphora's slot, else the first rock's lee.
        let homeX: Double
        let homeY: Double
        if game?.owns(.amphora) == true,
           let s = AquariumModel.decorSlot(for: .amphora) {
            homeX = s.x * size.width
            homeY = backDuneTop(atX: s.x * size.width, in: size) - 4
        } else if let rock = Self.decor.first(where: { $0.kind == .rock }) {
            homeX = rock.x * size.width - 18
            homeY = decorBaseY(rock, in: size) - 2
        } else {
            homeX = size.width * 0.33
            homeY = sandTop(atX: homeX, in: size)
        }
        // Substrate camouflage: paler on white, darker on black.
        let mantle = substrateKey == "white"
            ? Color(red: 0.72, green: 0.55, blue: 0.48)
            : substrateKey == "black"
                ? Color(red: 0.32, green: 0.20, blue: 0.20)
                : Color(red: 0.58, green: 0.36, blue: 0.32)
        let dark = Color(red: 0.34, green: 0.20, blue: 0.18)

        // The wander: a seeded ~4-minute cycle — long home, a crawl
        // out, a pause in the open, a crawl home.
        let cycle = 240.0
        let p = frac(t / cycle + 0.31)
        // Out: p .60–.68 crawls out, .68–.82 sits out, .82–.90 crawls home.
        let outX = homeX + (homeX < size.width * 0.5 ? 1 : -1) * size.width * 0.09
        let outY = sandTop(atX: outX, in: size) - 6
        var pos = CGPoint(x: homeX, y: homeY)
        var crawl = 0.0
        if p >= 0.60, p < 0.68 {
            let k = smooth(clamp01((p - 0.60) / 0.08))
            pos = CGPoint(x: homeX + (outX - homeX) * k,
                          y: homeY + (outY - homeY) * k)
            crawl = reduceMotion ? 0 : sin(k * .pi * 6) * 0.5
        } else if p >= 0.68, p < 0.82 {
            pos = CGPoint(x: outX, y: outY)
        } else if p >= 0.82, p < 0.90 {
            let k = smooth(clamp01((p - 0.82) / 0.08))
            pos = CGPoint(x: outX + (homeX - outX) * k,
                          y: outY + (homeY - outY) * k)
            crawl = reduceMotion ? 0 : sin(k * .pi * 6) * 0.5
        }
        let out = pos.x != homeX
        // The peek: while home, eyes ride over the rim for a stretch
        // of each ~70 s sub-cycle.
        let peek = !out && frac(t / 68) < 0.5
        var c = canvas
        c.translateBy(x: pos.x, y: pos.y)
        c.opacity = out ? 0.95 : 0.9
        if out {
            // Crawling: the mantle low over eight working arms.
            for i in 0..<8 {
                let ph = Double(i) / 8 * .pi * 2 + crawl * 2
                var arm = Path()
                arm.move(to: .zero)
                arm.addQuadCurve(
                    to: CGPoint(x: cos(ph) * 12, y: 4 + sin(ph) * 4),
                    control: CGPoint(x: cos(ph) * 7, y: 2))
                c.stroke(arm, with: .color(mantle.opacity(0.9)),
                         style: StrokeStyle(lineWidth: 1.8, lineCap: .round))
            }
            c.fill(Path(ellipseIn: CGRect(x: -7, y: -14, width: 14, height: 13)),
                   with: .color(mantle))
            c.fill(Path(ellipseIn: CGRect(x: -4, y: -10, width: 3, height: 3)),
                   with: .color(dark))
            c.fill(Path(ellipseIn: CGRect(x: 2, y: -10, width: 3, height: 3)),
                   with: .color(dark))
        } else {
            // Home: the mantle slumped in/behind the pot, eyes up on a
            // peek, sunk below otherwise.
            let eyeLift = peek ? -10.0 : -3.0
            c.fill(Path(ellipseIn: CGRect(x: -8, y: -10, width: 16, height: 11)),
                   with: .color(mantle.opacity(peek ? 1 : 0.55)))
            for k in [-1.0, 1.0] {
                c.fill(Path(ellipseIn: CGRect(x: k * 4 - 1.8, y: eyeLift - 2,
                                              width: 3.6, height: 4.6)),
                       with: .color(.white.opacity(peek ? 0.9 : 0.3)))
                c.fill(Path(ellipseIn: CGRect(x: k * 4 - 0.8, y: eyeLift - 0.6,
                                              width: 1.6, height: 2.4)),
                       with: .color(dark.opacity(peek ? 1 : 0.4)))
            }
        }
    }

    /// The axolotl: a wide pink smile on legs, three gill fronds a
    /// cheek waving as it ambles the sand on a long seeded patrol;
    /// every so often it kicks up and settles a body-width over.
    private func drawAxolotl(canvas: inout GraphicsContext, size: CGSize, t: Double) {
        let period = 160.0
        let p = frac(t / period)
        // Amble mostly in place; a kick-hop at p .5 moves the yard.
        let home = size.width * 0.30
        let kick = smooth(clamp01((p - 0.48) / 0.03))
            * smooth(clamp01((0.56 - p) / 0.03))
        let x = home + 30 * smooth(clamp01(p / 0.5)) * 2 - 15
        let baseY = sandTop(atX: x, in: size) - 7
        let y = reduceMotion ? baseY : baseY - kick * 26
        var c = canvas
        c.translateBy(x: x, y: y)
        c.opacity = 0.92
        let pink = Color(red: 0.92, green: 0.60, blue: 0.62)
        let frill = Color(red: 0.95, green: 0.45, blue: 0.50)
        // Tail sweeping behind.
        var tail = Path()
        tail.move(to: CGPoint(x: -12, y: -2))
        tail.addQuadCurve(to: CGPoint(x: -26, y: -8),
                          control: CGPoint(x: -20, y: -2))
        c.stroke(tail, with: .color(pink.opacity(0.8)),
                 style: StrokeStyle(lineWidth: 5, lineCap: .round))
        // Little legs, stepping while it walks.
        for k in 0..<2 {
            let step = reduceMotion ? 0 : sin(t * 3 + Double(k) * .pi) * 1.5
            c.stroke(Path(CGRect(x: -4 + Double(k) * 12, y: 2,
                                 width: 5, height: 4)),
                     with: .color(pink), lineWidth: 3)
            _ = step
        }
        // Body & wide head.
        c.fill(Path(ellipseIn: CGRect(x: -12, y: -9, width: 30, height: 13)),
               with: .color(pink))
        c.fill(Path(ellipseIn: CGRect(x: 4, y: -13, width: 20, height: 15)),
               with: .color(pink))
        // Gill fronds, waving on their own phase.
        for side in [-1.0, 1.0] {
            for k in 0..<3 {
                let wave = reduceMotion ? 0
                    : sin(t * 2.6 + Double(k) * 1.2 + side) * 2
                var fr = Path()
                let gy = -12 + Double(k) * 4
                fr.move(to: CGPoint(x: 12 + side * 3, y: gy))
                fr.addQuadCurve(
                    to: CGPoint(x: 12 + side * (12 + Double(k) * 2), y: gy - 4 + wave),
                    control: CGPoint(x: 12 + side * 8, y: gy - 2))
                c.stroke(fr, with: .color(frill),
                         style: StrokeStyle(lineWidth: 2.2, lineCap: .round))
            }
        }
        // The famous smile & bead eyes.
        c.fill(Path(ellipseIn: CGRect(x: 14, y: -9, width: 3, height: 3)),
               with: .color(.black.opacity(0.75)))
        c.fill(Path(ellipseIn: CGRect(x: 20, y: -9, width: 3, height: 3)),
               with: .color(.black.opacity(0.75)))
        var smile = Path()
        smile.move(to: CGPoint(x: 15, y: -4))
        smile.addQuadCurve(to: CGPoint(x: 23, y: -4), control: CGPoint(x: 19, y: -1))
        c.stroke(smile, with: .color(Color(red: 0.60, green: 0.30, blue: 0.32)),
                 lineWidth: 1)
        // The kicked-up sand puff as it lands.
        if kick > 0.5 && !reduceMotion {
            for k in 0..<4 {
                let a = Double(k) * .pi * 0.5 + 0.3
                var s = canvas
                s.opacity = (kick - 0.5) * 0.6
                s.fill(Path(ellipseIn: CGRect(x: x + cos(a) * 14 - 2,
                                              y: baseY + 2 - sin(a) * 6,
                                              width: 4, height: 4)),
                       with: .color(sandTones.speckDark))
            }
        }
    }

    /// The tetra school: seven little neons sharing one wander
    /// target, each orbiting the pack on its own phase — cohesion as
    /// a swarm, not a queue.
    private func drawTetraSchool(canvas: inout GraphicsContext, size: CGSize, t: Double) {
        // The pack's shared target sweeps the midwater slowly.
        let cx = size.width * (0.5 + 0.28 * sin(t * 0.09))
        let cy = size.height * (0.42 + 0.10 * sin(t * 0.13 + 1.7))
        let heading = cos(t * 0.09) >= 0 ? 1.0 : -1.0
        for i in 0..<7 {
            let h = scatter(AquariumModel.stableHash("tetra"), i)
            let orbit = 12 + Double(h & 0xFF) / 0xFF * 26
            let phase = Double((h >> 8) & 0xFF) / 0xFF * .pi * 2
            let speed = 1.2 + Double((h >> 16) & 0xFF) / 0xFF * 1.4
            let wobble = reduceMotion ? 0.0 : t * speed
            let fx = cx + cos(wobble + phase) * orbit
            let fy = cy + sin(wobble * 1.3 + phase) * orbit * 0.45
            let len = 13.0
            let face = heading
            var c = canvas
            c.translateBy(x: fx, y: fy)
            c.scaleBy(x: face, y: 1)
            c.opacity = 0.9
            // The neon line — a glow band over the silver body.
            c.fill(Path(ellipseIn: CGRect(x: -len / 2, y: -len * 0.22,
                                          width: len, height: len * 0.44)),
                   with: .color(Color(red: 0.80, green: 0.86, blue: 0.90)))
            var glow = c
            glow.blendMode = .plusLighter
            glow.fill(Path(roundedRect: CGRect(x: -len * 0.40, y: -len * 0.10,
                                               width: len * 0.80, height: len * 0.12),
                           cornerRadius: len * 0.06),
                      with: .color(Color(red: 0.20, green: 0.85, blue: 0.95)
                                   .opacity(0.9)))
            // The red tail half.
            c.fill(Path(ellipseIn: CGRect(x: -len / 2, y: -len * 0.16,
                                          width: len * 0.45, height: len * 0.32)),
                   with: .color(Color(red: 0.90, green: 0.30, blue: 0.25)
                                .opacity(0.85)))
            c.fill(Path(ellipseIn: CGRect(x: len * 0.28, y: -len * 0.12,
                                          width: 1.6, height: 1.6)),
                   with: .color(.black.opacity(0.8)))
        }
    }

    /// The cleaner shrimp: it keeps station on a decor piece, then
    /// every ~40 s hops to the nearest idle fish, rides it a few
    /// seconds picking, and springs home.
    private func drawCleanerShrimp(canvas: inout GraphicsContext, size: CGSize,
                                   t: Double, layouts: [String: Layout],
                                   roster: [Fish], now: Date) {
        // Station: the first seeded coral or rock's top.
        let station: CGPoint
        if let perch = Self.decor.first(where: { $0.kind == .coral || $0.kind == .rock }) {
            station = CGPoint(x: perch.x * size.width,
                              y: decorBaseY(perch, in: size) - 14 * perch.scale)
        } else {
            station = CGPoint(x: size.width * 0.2,
                              y: sandTop(atX: size.width * 0.2, in: size) - 10)
        }
        // The client: the shallowest idling fish.
        let client = roster.first(where: { $0.state == .idling && !$0.isFry })
        let clientPt = client.flatMap { layouts[$0.id] }
            .map { CGPoint(x: $0.x, y: $0.y - 10) }
        // The 40 s round: out on the first ~15%, riding till ~55%,
        // home by ~70%.
        let p = frac(t / 40)
        var pos = station
        var riding = false
        if let clientPt {
            if p < 0.15 {
                let k = smooth(clamp01(p / 0.15))
                pos = CGPoint(x: station.x + (clientPt.x - station.x) * k,
                              y: station.y + (clientPt.y - station.y) * k
                                  - sin(k * .pi) * 30)
            } else if p < 0.55 {
                pos = clientPt
                riding = true
            } else if p < 0.70 {
                let k = smooth(clamp01((p - 0.55) / 0.15))
                pos = CGPoint(x: clientPt.x + (station.x - clientPt.x) * k,
                              y: clientPt.y + (station.y - clientPt.y) * k
                                  - sin(k * .pi) * 30)
            }
        }
        var c = canvas
        c.translateBy(x: pos.x, y: pos.y)
        c.opacity = 0.9
        let body = Color(red: 0.92, green: 0.75, blue: 0.70)
        let red = Color(red: 0.80, green: 0.25, blue: 0.25)
        // A slim arched body with a red saddle.
        c.fill(Path(ellipseIn: CGRect(x: -6, y: -3, width: 12, height: 6)),
               with: .color(body))
        c.fill(Path(ellipseIn: CGRect(x: -2, y: -3, width: 5, height: 6)),
               with: .color(red.opacity(0.8)))
        // Long antennae whisking ahead, busier while it works.
        let whisk = riding && !reduceMotion ? sin(t * 9) * 2 : 0
        for k in [-1.0, 1.0] {
            var ant = Path()
            ant.move(to: CGPoint(x: 5, y: -1))
            ant.addQuadCurve(to: CGPoint(x: 15, y: -6 + k * 3 + whisk),
                             control: CGPoint(x: 10, y: -3 + k))
            c.stroke(ant, with: .color(body.opacity(0.8)), lineWidth: 0.8)
        }
        c.fill(Path(ellipseIn: CGRect(x: 4, y: -2.5, width: 1.6, height: 1.6)),
               with: .color(.black.opacity(0.8)))
    }

    /// The manta: a rare wide shadow crossing the back layer every
    /// few minutes — big, dim, unhurried. Reduce Motion skips the
    /// flight entirely.
    private func drawManta(canvas: inout GraphicsContext, size: CGSize, t: Double) {
        guard !reduceMotion else { return }
        // ~6 minutes between passes, a 20 s glide across.
        let period = 360.0
        let p = frac(t / period + 0.62)
        guard p < 0.06 else { return }
        let k = p / 0.06
        let x = -80 + (size.width + 160) * k
        let y = size.height * 0.30 + sin(k * .pi * 2) * 20
        let flap = sin(t * 1.6) * 0.18
        var c = canvas
        c.translateBy(x: x, y: y)
        c.opacity = 0.35 * sin(min(1, k * .pi) * .pi)
        // The diamond: two swept wings meeting at a point, a whip
        // tail behind.
        var wing = Path()
        wing.move(to: CGPoint(x: 42, y: 0))
        wing.addQuadCurve(to: CGPoint(x: -20, y: -30 - flap * 20),
                          control: CGPoint(x: 10, y: -26 - flap * 12))
        wing.addQuadCurve(to: CGPoint(x: -34, y: 0),
                          control: CGPoint(x: -28, y: -8))
        wing.addQuadCurve(to: CGPoint(x: -20, y: 30 + flap * 20),
                          control: CGPoint(x: -28, y: 8))
        wing.addQuadCurve(to: CGPoint(x: 42, y: 0),
                          control: CGPoint(x: 10, y: 26 + flap * 12))
        wing.closeSubpath()
        c.fill(wing, with: .color(Color(red: 0.05, green: 0.09, blue: 0.14)))
        var tailP = Path()
        tailP.move(to: CGPoint(x: -34, y: 0))
        tailP.addQuadCurve(to: CGPoint(x: -72, y: 6),
                           control: CGPoint(x: -52, y: -3))
        c.stroke(tailP, with: .color(Color(red: 0.05, green: 0.09, blue: 0.14)),
                 lineWidth: 1.6)
    }

    // MARK: Events

    /// The buried treasure (docs/TOYS.md shop): a chest lid half out
    /// of the sand at its seeded spot, a glint climbing off it every
    /// few seconds. Its hitbox feeds `motion.treasureBox`; the tap
    /// digs, three digs open it.
    private func drawTreasure(canvas: inout GraphicsContext, size: CGSize,
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
    private func drawGoldBursts(canvas: inout GraphicsContext, size: CGSize,
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
    private func drawTrickRings(canvas: inout GraphicsContext, size: CGSize,
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
    private func drawVisitor(canvas: inout GraphicsContext, size: CGSize,
                             t: Double, now: Date) {
        // Claim the queue's head when the lane is free. The claim lands
        // on `activeVisitor` now; the game's `visitorShown` waits for
        // the post-pass drain like every draw-time event.
        if !ambient, motion.activeVisitor == nil, now >= motion.visitorCooldownUntil,
           let next = game?.pendingVisitors.first {
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
    private func stationAnchor(_ station: TankStation, for fish: Fish, in size: CGSize,
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
    private func drawStationCue(_ cue: FishCue, l: Layout, canvas: inout GraphicsContext,
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
    private func drawParallelMarkers(_ count: Int, l: Layout, canvas: inout GraphicsContext,
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
    private func drawTokenPasses(canvas: inout GraphicsContext, roster: [Fish],
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

    // MARK: Fish

    /// Where a fish is right now: position, which way it faces, how far
    /// through its turn it is.
    private struct Layout {
        var x: Double = 0
        var y: Double = 0
        /// +1 faces right, -1 faces left.
        var facing: Double = 1
        /// Screen-space radians; positive pitches the nose down for
        /// either facing (the draw rotates by `pitch * facing`).
        var pitch: Double = 0
        /// 1 at cruise, ~0.2 mid-turn: the fish seen head-on.
        var thin: Double = 1
        var scale: Double = 1
        var opacity: Double = 1
        /// 0 at cruise … 1 deepest into a wall turn.
        var turn: Double = 0
        /// Tail-beat amplitude multiplier (0 stills the tail).
        var wag: Double = 1
        /// Where a surfacing fish started its rise; the bubble trail
        /// climbs from there.
        var riseFrom: Double = 0
        /// The glass-tap ring's phase (0 just emitted … 1 faded) while a
        /// waiting fish pulses; -1 means no ring this frame.
        var tapRing: Double = -1
        /// How deep into a surface sip an idle fish is (0…1); the view
        /// trails a bubble off it.
        var sip: Double = 0
        /// How deep into the night doze an idling fish is (0…1); the
        /// view breathes out the occasional "z".
        var sleep: Double = 0
    }

    /// The cruise patrol: a sinusoidal sweep between the walls, so the
    /// fish eases to a stop at the glass instead of mirror-flipping.
    /// `u` is the velocity proxy (±1 mid-tank, 0 at a wall) and `turn`
    /// grows through the turnaround.
    private func patrol(of fish: Fish, in size: CGSize, at t: Double, margin: Double)
        -> (x: Double, u: Double, turn: Double) {
        let h = fish.seed
        let x0 = Double((h >> 33) & 0x3FF) / 0x3FF
        // Deep lanes swim slower: parallax.
        let omega = Double.pi * fish.speed * (1 - fish.lane * 0.3)
        // The phase picks the start point on the sweep AND the first
        // direction, so `fish.direction` still means something.
        let s = min(1, max(-1, x0 * 2 - 1))
        let phase = fish.direction > 0 ? asin(s) : Double.pi - asin(s)
        let theta = omega * t + phase
        let u = cos(theta)
        let turn = min(1, max(0, 1 - abs(u) / 0.5))
        // The nose pokes a touch past the patrol line mid-turn.
        let pos = 0.5 * (1 + sin(theta))
        let x = margin + pos * max(0, size.width - 2 * margin) + turn * 7 * sin(theta)
        return (x, u, turn)
    }

    /// The lane's resting height: near the surface at lane 0, clear of
    /// the raised bed (the highest dune crest is ~92 pt up) at lane 1.
    private func laneY(for fish: Fish, in size: CGSize) -> Double {
        let top = 34.0
        let bottom = size.height - 108.0
        return top + fish.lane * max(0, bottom - top)
    }

    private func layout(of fish: Fish, in size: CGSize, at t: Double, now: Date,
                        parent: (fish: Fish, layout: Layout)? = nil) -> Layout {
        if fish.isFry, let parent {
            return fryLayout(of: fish, at: t, now: now, parent: parent)
        }
        let h = fish.seed
        let phase = Double((h >> 43) & 0xFF) / 0xFF * .pi * 2
        // Half the fish loop up over the top, half dive under.
        let turnUp = (h >> 52) & 1 == 0
        let margin = 36.0
        let laneY = laneY(for: fish, in: size)
        let bob = reduceMotion ? 0 : sin(t * 1.1 + phase) * 5
        let p = patrol(of: fish, in: size, at: t, margin: margin)
        // The steering body this frame (nil before the first step, or
        // for fry) and where the current state found the fish.
        let body = motion.bodies[fish.id]
        let home = anchor(of: fish, in: size)

        var l = Layout()
        l.scale = 1.08 - fish.lane * 0.4
        l.riseFrom = laneY
        // The shared turn pose: the pitch stays level through cruise &
        // sweeps in at the glass (smoothstep), the head-on squash holds
        // a tighter window than the pitch, and the fish arcs a little
        // toward the side of the loop.
        let turnPitch = smooth(p.turn) * (turnUp ? -0.9 : 0.9)
        let turnArc = p.turn * (turnUp ? -6.0 : 6.0)
        let thin = 1 - smooth(clamp01(1 - abs(p.u) / 0.28)) * 0.82

        /// The steering readout: facing off the heading's x sign, pitch
        /// off its y (`asin(sin)` is the pitch both facings share), and
        /// the head-on factor doubles as the squash a vertical swim
        /// reads as.
        func steeringReadout(_ b: SwimBody)
            -> (facing: Double, pitch: Double, thin: Double, turn: Double) {
            let c = cos(b.heading)
            let headOn = abs(c)
            return (c >= 0 ? 1 : -1,
                    AquariumSteering.pitch(forHeading: b.heading),
                    0.30 + 0.70 * headOn,
                    smooth(clamp01(1 - headOn)))
        }

        switch fish.state {
        case .swimming, .idling:
            if let b = body {
                // The steering body IS the position: wander noise, a
                // soft turn off the glass, a dart at food, a weak pull
                // toward the school. `bob` rides on top so the water
                // still breathes under it.
                let s = steeringReadout(b)
                let px = b.x * size.width
                let py = b.y * size.height
                l.x = px
                l.facing = s.facing
                l.thin = s.thin
                l.turn = s.turn
                if fish.state == .swimming {
                    l.y = py + bob * (1 - s.turn * 0.5)
                    l.pitch = s.pitch
                    l.wag = 1.25
                    // The flourish: every minute or so a glad swimmer
                    // throws a barrel roll mid-stroke — a hop and a
                    // full spin, seeded so it never lands on a clock
                    // you can catch. Never near the ceiling (the roll
                    // would leave the water) or mid-startle.
                    if !reduceMotion, b.y > 0.15, motion.startles[fish.id] == nil,
                       let roll = AquariumBehavior.flourishProgress(seed: h, at: t) {
                        l.pitch += roll * .pi * 2 * AquariumBehavior.flourishDirection(seed: h)
                        l.y -= sin(roll * .pi) * 15
                        l.wag += sin(roll * .pi) * 0.6
                    }
                } else {
                    // Holds midwater on a slow drift — the body steps
                    // at a third of the effort — and still rises to
                    // sip the surface every half-minute or so.
                    // The doze: deep in the tank's night wash an idler
                    // settles toward the sand, stills its tail and dims
                    // a touch — `drawFish` breathes out the "z"s. A
                    // curious pointer is worth waking up for.
                    let doze = reduceMotion || fish.id == motion.curiousID
                        ? 0 : AquariumBehavior.doze(seed: h, night: nightFactor(t: t))
                    let sipPeriod = 26 + Double((h >> 60) & 0xF)
                    let sip = frac(t / sipPeriod + phase / (.pi * 2))
                    let sipping = (reduceMotion ? 0
                        : smooth(clamp01(sip / 0.07)) * smooth(clamp01((0.18 - sip) / 0.07)))
                        * (1 - doze)
                    l.y = py + bob * 0.6 * (1 - s.turn * 0.5)
                        - sipping * max(0, py - 34)
                    // A sleeper sinks to just off the sand under it.
                    let floorY = sandTop(atX: px, in: size) - 44
                    l.y += max(0, floorY - l.y) * doze * 0.9
                    l.pitch = s.pitch - sipping * 0.55 + doze * 0.12
                    l.wag = (0.35 + sipping * 0.7) * (1 - doze * 0.75)
                    l.sip = sipping
                    l.sleep = doze
                    l.opacity *= 1 - 0.15 * doze
                }
            } else if fish.state == .swimming {
                // No body stepped yet (first frame, a paused resume):
                // the old sine sweep stands in until one lands.
                l.x = p.x
                l.y = laneY + bob * (1 - p.turn * 0.5) + turnArc
                l.facing = p.u >= 0 ? 1 : -1
                l.pitch = turnPitch
                l.thin = thin
                l.turn = p.turn
                l.wag = 1.25
            } else {
                let d = patrol(of: fish, in: size, at: t * 0.3, margin: margin)
                let dPitch = smooth(d.turn) * (turnUp ? -0.9 : 0.9)
                let dArc = d.turn * (turnUp ? -6.0 : 6.0)
                // The fixture path dozes too — same night, same rule.
                let doze = reduceMotion ? 0
                    : AquariumBehavior.doze(seed: h, night: nightFactor(t: t))
                let sipPeriod = 26 + Double((h >> 60) & 0xF)
                let sip = frac(t / sipPeriod + phase / (.pi * 2))
                let sipping = (reduceMotion ? 0
                    : smooth(clamp01(sip / 0.07)) * smooth(clamp01((0.18 - sip) / 0.07)))
                    * (1 - doze)
                l.x = d.x
                l.y = laneY + bob * 0.6 * (1 - d.turn * 0.5) + dArc
                    - sipping * (laneY - 34)
                let floorY = sandTop(atX: l.x, in: size) - 44
                l.y += max(0, floorY - l.y) * doze * 0.9
                l.facing = d.u >= 0 ? 1 : -1
                l.pitch = dPitch - sipping * 0.55 + doze * 0.12
                l.thin = 1 - smooth(clamp01(1 - abs(d.u) / 0.28)) * 0.82
                l.turn = d.turn
                l.wag = (0.35 + sipping * 0.7) * (1 - doze * 0.75)
                l.sip = sipping
                l.sleep = doze
                l.opacity *= 1 - 0.15 * doze
            }
        case .surfacing:
            // Rises from where it was to just under the surface over
            // about a second, nose up on the way, then bobs there at
            // the glass — closer to the viewer, pulsing a soft glow
            // ring off its nose like a tap on the pane.
            let age = now.timeIntervalSince(fish.stateSince)
            let rise = smooth(clamp01(age / 1.15))
            l.riseFrom = home.y
            l.x = home.x + (reduceMotion ? 0 : sin(t * 0.7 + phase) * 6 * rise)
            l.y = l.riseFrom + (24 - l.riseFrom) * rise
                + (reduceMotion ? 0 : sin(t * 2.3 + phase) * 3.5 * rise)
            l.facing = body.map { cos($0.heading) >= 0 ? 1.0 : -1.0 } ?? (p.u >= 0 ? 1 : -1)
            l.pitch = (body.map { steeringReadout($0).pitch } ?? turnPitch)
                - (1 - rise) * 0.75
            l.thin = body.map { steeringReadout($0).thin } ?? thin
            l.turn = body.map { steeringReadout($0).turn } ?? p.turn
            l.wag = 0.45 + (1 - rise) * 0.7
            let ring = reduceMotion ? 0.55
                : frac(age / 2.2 + Double((h >> 56) & 0xF) / 0xF)
            l.tapRing = ring
            l.scale *= 1 + (0.13 + 0.05 * exp(-ring * 5)) * rise
        case .sinking:
            // It stops where it was, drops nose down onto the sand,
            // rolls onto its side for a beat, then fades out.
            let frozen = home
            let age = now.timeIntervalSince(fish.stateSince)
            let drop = clamp01(age / 2.4)
            let eased = drop * drop
            let settle = smooth(clamp01((age - 2.4) / 1.0))
            let decay = exp(-max(0, age - 2.4) * 0.5)
            let rock = reduceMotion ? 0 : sin(age * 3.0 + phase) * 0.22 * decay
            l.x = frozen.x
            // It comes to rest on the dune under it, not the glass.
            let floorY = sandTop(atX: frozen.x, in: size) - 12
            l.y = min(frozen.y + (floorY - frozen.y) * eased, floorY) + rock * 4
            l.facing = body.map { cos($0.heading) >= 0 ? 1.0 : -1.0 } ?? 1
            let pose = 0.55 * eased + (0.16 - 0.55 * eased) * settle
            let side = ((h >> 58) & 1 == 0) ? 1.3 : -1.3
            let rest = smooth(clamp01((age - 3.0) / 1.2))
            l.pitch = pose + (side - pose) * rest + rock * (1 - rest)
            // A failed fry doesn't get the full rock-on-sand: it just
            // drops & fades.
            let fade = smooth(clamp01((age - 5.6) / 2.6))
            l.opacity = (fish.isFry ? 1 - 0.7 * drop : 1 - 0.15 * drop)
                * (1 - 0.62 * fade)
            l.wag = (1 - drop) * (1 - rest)
        case .leaving:
            // From wherever it was, corkscrewing up and out the
            // top-right edge.
            let progress = fish.leaveProgress(at: now)
            let eased = smooth(progress)
            let start = home.x
            let loopPhase = progress * .pi * 3.4 + phase
            let loopR = reduceMotion ? 0 : 26 * (1 - progress)
            l.x = start + (size.width + margin + 60 - start) * eased
                + cos(loopPhase) * loopR * 0.6
            l.y = home.y + bob * (1 - progress) - eased * max(0, home.y - 10)
                + sin(loopPhase) * loopR
            l.facing = 1
            l.pitch = -0.4 * eased + sin(loopPhase + .pi / 2) * 0.35 * (1 - progress)
            l.opacity = 1 - 0.5 * progress
            l.wag = 1 + progress * 0.8
        }

        // The curious fish wiggles a little harder — it sees you.
        if fish.id == motion.curiousID { l.wag *= 1.35 }

        // A new fish swims in from the edge behind its heading instead
        // of popping into the middle of the tank.
        if fish.state == .swimming || fish.state == .idling || fish.state == .surfacing {
            let enterDuration = 2.2
            let age = now.timeIntervalSince(fish.enteredAt)
            if age < enterDuration {
                let e = 1 - pow(1 - age / enterDuration, 3)
                let edge: Double = fish.direction > 0 ? -70 : size.width + 70
                l.x = edge + (l.x - edge) * e
                l.opacity *= 0.2 + 0.8 * e
                // The turn pose fades in with the entrance: the fish
                // comes through the glass fully formed.
                l.thin = 1 - (1 - l.thin) * e
                l.turn *= e
                l.pitch *= e
            }
        }
        return l
    }

    /// A fry's place in its school (docs/TOYS.md): a loose orbit
    /// around the parent fish — per-fry radius, direction & phase
    /// from its id's hash — riding a touch higher, because fry sit up
    /// in the water. The orbit follows the parent's layout, so an
    /// ask-rise, a sink or a drift off the edge carries the school.
    private func fryLayout(of fish: Fish, at t: Double, now: Date,
                           parent: (fish: Fish, layout: Layout)) -> Layout {
        let h = fish.seed
        let phase = Double(h & 0xFF) / 0xFF * .pi * 2
        let orbitR = 30 + Double((h >> 8) & 0xFF) / 0xFF * 26
        let omega = (0.45 + Double((h >> 16) & 0xFF) / 0xFF * 0.45)
            * ((h >> 24) & 1 == 0 ? 1.0 : -1.0)
        // An idling parent's school mills about at less than half speed.
        let idle = fish.state == .idling
        let angle = phase + (reduceMotion ? 0 : omega * t * (idle ? 0.45 : 1))
        let pl = parent.layout

        var l = Layout()
        l.scale = pl.scale * 1.08
        l.riseFrom = pl.riseFrom
        l.opacity = pl.opacity
        // Little tails beat faster.
        l.wag = pl.wag * 1.4

        switch fish.state {
        case .swimming, .idling, .surfacing:
            l.x = pl.x + cos(angle) * orbitR
            l.y = pl.y + sin(angle) * orbitR * 0.5 - 12
            // Face along the orbit's travel.
            l.facing = -sin(angle) * omega >= 0 ? 1 : -1
            l.pitch = pl.pitch * 0.5 + (reduceMotion ? 0 : sin(t * 1.7 + phase) * 0.12)
        case .sinking:
            // A failed worker just fades & drops a little.
            let age = now.timeIntervalSince(fish.stateSince)
            let drop = smooth(clamp01(age / 1.6))
            l.x = pl.x + cos(angle) * orbitR * 0.7
            l.y = pl.y + sin(angle) * orbitR * 0.5 - 12 + drop * 44
            l.facing = pl.facing
            l.pitch = 0.5 * drop
            l.opacity = pl.opacity * (1 - 0.72 * drop)
            l.wag = pl.wag * (1 - drop)
        case .leaving:
            // The school spirals in as it follows its parent off.
            let progress = fish.leaveProgress(at: now)
            let shrink = orbitR * (1 - 0.55 * progress)
            l.x = pl.x + cos(angle) * shrink
            l.y = pl.y + sin(angle) * shrink * 0.5 - 12
            l.facing = 1
            l.pitch = pl.pitch
        }
        return l
    }

    // MARK: Fish shape

    /// The water colour fish & kelp wash toward with depth.
    private static let waterNS = NSColor(srgbRed: 0.05, green: 0.18, blue: 0.33, alpha: 1)

    /// W13's overlay markers — a small glyph floating just above the
    /// fish, one per plan. Each is a distinct shape so a fixture that
    /// asserts `overlay == .warningBuoy` sees the same marker the live
    /// tank draws; nothing here routes a command or answers anything.
    private func drawOverlayMarker(_ overlay: FishOverlay, l: Layout,
                                   canvas: inout GraphicsContext,
                                   length: Double, height: Double, t: Double) {
        let r = max(3.2, length * 0.10)
        let x = l.x + l.facing * length * 0.18
        let y = l.y - height * 0.5 - r - 6
        var m = canvas
        m.opacity = l.opacity * 0.9
        switch overlay {
        case .warningBuoy:
            // A warning buoy: a solid triangle riding the water line.
            var tri = Path()
            tri.move(to: CGPoint(x: x, y: y - r))
            tri.addLine(to: CGPoint(x: x + r, y: y + r * 0.7))
            tri.addLine(to: CGPoint(x: x - r, y: y + r * 0.7))
            tri.closeSubpath()
            m.fill(tri, with: .color(.orange))
        case .attentionBuoy:
            // A permission ask: a ringed dot — the lock cue reads as
            // "decide this" rather than "answer me".
            m.stroke(Path(ellipseIn: CGRect(x: x - r, y: y - r, width: r * 2, height: r * 2)),
                     with: .color(.white), lineWidth: 1.1)
            m.fill(Path(ellipseIn: CGRect(x: x - r * 0.4, y: y - r * 0.4,
                                          width: r * 0.8, height: r * 0.8)),
                   with: .color(.white))
        case .questionBubble:
            // The plain ask: the bubble is already the surfacing cue —
            // the overlay adds a steady dot inside it so a question
            // isn't mistaken for an idle sip.
            m.fill(Path(ellipseIn: CGRect(x: x - r * 0.5, y: y - r * 0.5,
                                          width: r, height: r)),
                   with: .color(.white.opacity(0.85)))
        case .pearl:
            // An unreviewed completion: a bright pearl the fish set
            /// down — a dot with a soft gleam, cleared on review.
            m.fill(Path(ellipseIn: CGRect(x: x - r * 0.6, y: y - r * 0.6,
                                          width: r * 1.2, height: r * 1.2)),
                   with: .color(.white))
            var gleam = canvas
            gleam.blendMode = .plusLighter
            gleam.opacity = l.opacity * (0.25 + 0.15 * sin(t * 1.4))
            gleam.fill(Path(ellipseIn: CGRect(x: x - r, y: y - r,
                                              width: r * 2, height: r * 2)),
                       with: .color(.cyan.opacity(0.5)))
        case .staleMarker:
            // AQ23's neutral marker: a hollow dashed ring — the fish
            // drifts, nothing precise is claimed.
            m.stroke(Path(ellipseIn: CGRect(x: x - r, y: y - r, width: r * 2, height: r * 2)),
                     with: .color(.white.opacity(0.4)),
                     style: StrokeStyle(lineWidth: 0.8, dash: [2, 3]))
        }
    }

    private func drawFish(canvas: inout GraphicsContext, size: CGSize, t: Double, now: Date,
                          fish: Fish, layout l: Layout,
                          parent: (fish: Fish, layout: Layout)?, showLabels: Bool) {
        let h = fish.seed
        let phase = Double((h >> 43) & 0xFF) / 0xFF * .pi * 2
        // Fry ride at their school's depth, a little shallower.
        let lane = fish.isFry ? (parent?.fish.lane ?? fish.lane) * 0.85 : fish.lane
        // The idle game's growth stages (docs/TOYS.md): small, grown,
        // full — a fish with no care record yet swims at stage 0.
        let care = game?.pets[fish.id]
        let stageScale = [0.74, 0.92, 1.12][min(2, max(0, care?.stage ?? 0))]
        // The cartoon kit carries each species' proportions itself, so
        // the species aspect is softened — a shark stays long, a puffer
        // stays round, and nobody pancakes.
        let cartoonAspect = sqrt(fish.species.aspect)
        let length = 46.0 * l.scale * fish.species.sizeScale
            * (fish.isFry ? AquariumModel.fryScale : 1) * stageScale
        let height = length * cartoonAspect

        // The golden ticket: ~1 fish in 24 swims in gold instead of its
        // provider colour — a seeded lottery, the same fish every
        // launch. A sinking fish is beyond vanity: it stays grey.
        let golden = !fish.isFry && fish.state != .sinking
            && AquariumBehavior.isGolden(seed: h)
        // Depth: deeper lanes dim & wash toward the water colour, with
        // a slight extra blue cast on top of the desaturation.
        let base: NSColor = fish.state == .sinking
            ? .secondaryLabelColor
            : (golden ? NSColor(srgbRed: 0.98, green: 0.76, blue: 0.22, alpha: 1)
                      : ProviderStyle.style(for: fish.providerID).nsAccent)
        // Depth attenuates toward the column's floor colour — hue as
        // well as brightness — with a touch of desaturation on top, so
        // a deep fish reads watery, not just dim.
        let washed = (base.blended(withFraction: lane * 0.30, of: .gray) ?? base)
            .blended(withFraction: lane * 0.45, of: floorNS) ?? base
        let bodyColor = Color(nsColor: washed)
        let lightColor = Color(nsColor: washed.blended(withFraction: 0.55, of: .white) ?? washed)
        let darkColor = Color(nsColor: washed.blended(withFraction: 0.38, of: .black) ?? washed)
        // The cartoon look lives on its bold outline — darker than the
        // markings, darker still on a washed-out deep-lane fish.
        let outlineColor = Color(nsColor: washed.blended(withFraction: 0.78, of: .black) ?? .black)

        // Recent session activity quickens the tail; a lagging beat in
        // the pitch gives the head the classic follow-the-tail sway.
        // Reduce Motion stills both — the fish glides, poses stay.
        let recency = fish.lastUpdate.map { now.timeIntervalSince($0) } ?? .infinity
        let vigor = 1 + 1.15 * exp(-max(0, recency) / 9)
        let beat = t * (3.0 + fish.speed * 24) * vigor + phase
        let wag = reduceMotion ? 0 : sin(beat - 0.45) * 0.26 * l.wag * (1 + l.turn * 0.3)
        let sway = reduceMotion ? 0 : sin(beat - 0.8) * 0.045 * l.wag

        // Squash-and-stretch: a fish that just ate or just grew a stage
        // pops wide and settles back over most of a second.
        var squashX = 1.0
        var squashY = 1.0
        if let until = motion.bounceUntil[fish.id], now < until {
            let k = clamp01(1 - until.timeIntervalSince(now) / 0.7)
            let s = sin(k * .pi)
            squashX = 1 + 0.16 * s
            squashY = 1 - 0.13 * s
        }

        // A fish pools a soft shadow on the sand under it; the pool
        // fades as it climbs but stays readable at mid-height — cheap
        // depth, one gradient fill.
        if fish.state != .leaving {
            let floorY = sandTop(atX: l.x, in: size) + 3
            let clearance = floorY - (l.y + height * 0.5)
            let range = size.height * 0.38
            if clearance < range {
                let fade = clamp01(1 - max(0, clearance) / range)
                groundShadow(canvas: &canvas, x: l.x, y: floorY,
                             halfW: length * 0.60, halfH: 7,
                             alpha: 0.44 * fade * l.opacity)
            }
        }

        // A trick in progress: the barrel roll is a full 360° about
        // the swim axis — the vertical squash goes through belly-up
        // and back; the bubble ring draws separately below.
        var rollY = 1.0
        if let trick = motion.tricks[fish.id], trick.kind == .roll, now < trick.until {
            let p = clamp01(1 - trick.until.timeIntervalSince(now) / AquariumBehavior.trickDuration)
            rollY = cos(p * .pi * 2)
        } else if let trick = motion.tricks[fish.id], now >= trick.until {
            motion.tricks.removeValue(forKey: fish.id)
        }

        var f = canvas
        f.opacity = l.opacity * (1 - lane * 0.28)
        // Surface refraction: anything within ~8% of the waterline
        // wobbles a touch sideways — the meniscus's parallax.
        let wobble = !reduceMotion && l.y < size.height * 0.085
            ? sin(t * 2.3 + phase) * 1.6 : 0
        f.translateBy(x: l.x + wobble, y: l.y)
        // Rotate before the body scale so the pitch is rigid (no shear)
        // and `pitch * facing` keeps "nose down" the same for both
        // facings.
        if l.pitch + sway != 0 { f.rotate(by: .radians((l.pitch + sway) * l.facing)) }
        f.scaleBy(x: l.facing * l.thin * length * squashX, y: height * squashY * rollY)

        // The mouth says the game: a smile just after a meal, a small
        // "o" while the fish is starving, a soft curve cruising. A
        // sinking fish gets the X eye and no mouth opinion.
        let dead = fish.state == .sinking
        let mouth: CartoonFish.MouthKind =
            (!dead && (motion.smileUntil[fish.id].map { now < $0 } ?? false)) ? .smile
            : (!dead && (care?.hungry(at: now) ?? false) ? .hungry : .plain)
        // The blink: a lid slides down & back every few seconds,
        // offset per fish by its seed.
        let blinkPhase = frac(t / (3.4 + Double((h >> 20) & 0xF) * 0.28) + phase)
        let blink = dead || reduceMotion ? 0.0
            : smooth(clamp01((blinkPhase - 0.94) / 0.025))
              * smooth(clamp01((1.0 - blinkPhase) / 0.025))
        CartoonFish.draw(into: &f, species: fish.species,
                         palette: CartoonFish.Palette(
                            body: bodyColor, light: lightColor,
                            dark: darkColor, outline: outlineColor),
                         wag: wag, flap: wag * 0.45,
                         mouth: mouth, blink: blink, dead: dead,
                         patternSeed: h,
                         aspectComp: length / height)
        // A purchased hat rides the head — same unit space, so the
        // pitch, flip and squash all apply to it. Failing a bought
        // hat, a full-grown fish on a streak tank goes royal: three
        // days of completions and the grown-ups wear the crown.
        // Accessories get their own slot; when the accessory is itself
        // headwear (top hat, headphones) it wins the head and the hat
        // stays in the pocket.
        if !fish.isFry {
            let art = CartoonFish.art(for: fish.species)
            let accessory = game?.accessory(for: fish.id)
            let headAccessory = accessory == .topHat || accessory == .headphones
            if !headAccessory {
                if let hat = game?.hat(for: fish.id) {
                    CartoonFish.drawHat(hat, into: &f, at: art.hatAnchor)
                } else if AquariumBehavior.wearsCrown(streakDays: game?.streakDays ?? 0,
                                                      stage: care?.stage ?? 0) {
                    CartoonFish.drawHat(.hatCrown, into: &f, at: art.hatAnchor)
                }
            }
            if let accessory {
                // The laptop only comes out while its fish is on the
                // clock; residents left theirs in the office.
                if accessory != .tinyLaptop
                    || (fish.state == .swimming && !fish.isResident) {
                    CartoonFish.drawAccessory(accessory, into: &f, art: art,
                                              trail: reduceMotion ? 0 : sin(t * 2.1 + phase))
                }
            }
        }

        // An ask comes up for air: a small trail climbs from where the
        // rise began, and a bubble rides overhead growing till it pops.
        // Fry don't get one — a worker's ask surfaces on its parent.
        if fish.state == .surfacing, !fish.isFry {
            let since = now.timeIntervalSince(fish.stateSince)
            for k in 0..<3 {
                let birth = 0.15 + Double(k) * 0.42
                let age = since - birth
                guard age > 0, age < 2.6 else { continue }
                let release = smooth(clamp01(birth / 1.15))
                let startY = l.riseFrom + (24 - l.riseFrom) * release
                let r = 1.4 + Double(k) * 0.5
                let bx = l.x - l.facing * 6 + Double(k - 1) * 4 + sin(age * 3 + Double(k) * 2.1) * 4
                let by = startY - 4 - age * 30
                guard by > 3 else { continue }
                var b = canvas
                b.opacity = l.opacity * (1 - age / 2.6) * 0.5
                b.stroke(Path(ellipseIn: CGRect(x: bx - r, y: by - r, width: r * 2, height: r * 2)),
                         with: .color(.white), lineWidth: 0.7)
            }
            let rise = frac(t * 0.45 + phase / (.pi * 2))
            let bx = l.x + l.facing * 6 + sin(t * 3 + phase) * 2
            let by = l.y - height * 0.5 - 8 - rise * 20
            let br = 2.6 + rise * 1.2
            var b = canvas
            b.opacity = l.opacity * (1 - rise) * 0.9
            b.stroke(Path(ellipseIn: CGRect(x: bx - br, y: by - br, width: br * 2, height: br * 2)),
                     with: .color(.white), lineWidth: 0.9)
        }

        // Waiting at the glass: a soft glow ring pulses off its nose,
        // like a tap on the pane asking for you.
        if l.tapRing >= 0, !fish.isFry {
            let rr = (10 + l.tapRing * 54) * (length / 46)
            var g = canvas
            g.blendMode = .plusLighter
            g.stroke(Path(ellipseIn: CGRect(x: l.x + l.facing * length * 0.30 - rr,
                                            y: l.y - 5 - rr * 0.8,
                                            width: rr * 2, height: rr * 1.6)),
                     with: .color(.white.opacity(l.opacity * (1 - l.tapRing) * 0.35)),
                     lineWidth: 1.6)
        }

        // W13's evidence overlays — one marker, only what the plan
        // cites. A buoy is a buoy: the same glyph a fixture asserts
        // the overlay enum carries, drawn small above the fish.
        if let overlay = fish.plan?.overlay, !fish.isFry {
            drawOverlayMarker(overlay, l: l, canvas: &canvas,
                              length: length, height: height, t: t)
        }

        // What it's doing, drawn where it's doing it: the station's
        // small tell, only while the fish is actually stationed and the
        // cue is fresh — a fixture with no steering draws the same tell
        // wherever the fish is, so the proof shots still show it.
        if !fish.isFry, fish.state == .swimming, let cue = fish.cue, cue.isFresh(at: now),
           motion.stationed[fish.id] != nil || motion.bodies[fish.id] == nil {
            drawStationCue(cue, l: l, canvas: &canvas, size: size,
                           length: length, height: height, t: t, phase: phase)
        }
        if !fish.isFry, fish.state == .swimming, let markers = fish.plan?.parallelMarkers,
           markers > 0 {
            drawParallelMarkers(markers, l: l, canvas: &canvas, length: length,
                                height: height, t: t, phase: phase)
        }

        // An idle fish sipping the surface leaves one small bubble.
        if l.sip > 0.4, !fish.isFry {
            let br = 1.8 + (l.sip - 0.4) * 2
            var b = canvas
            b.opacity = l.opacity * (l.sip - 0.4) * 0.9
            b.stroke(Path(ellipseIn: CGRect(x: l.x + l.facing * 5 - br,
                                            y: l.y - height * 0.5 - 8 - l.sip * 12 - br,
                                            width: br * 2, height: br * 2)),
                     with: .color(.white), lineWidth: 0.7)
        }

        // The golden one's shimmer: two seeded glints flaring and dying
        // on their own phases, readable across the tank.
        if golden, !reduceMotion {
            for k in 0..<2 {
                let gs = AquariumBehavior.scramble(h &+ UInt64(k + 1) &* 0x9E3779B97F4A7C15)
                let gp = frac(t * (0.35 + Double(k) * 0.17) + Double(gs & 0xFF) / 0xFF)
                let ga = smooth(clamp01(gp / 0.12)) * (1 - smooth(clamp01((gp - 0.45) / 0.4)))
                guard ga > 0.01 else { continue }
                var g = canvas
                g.blendMode = .plusLighter
                g.opacity = l.opacity * ga
                g.translateBy(x: l.x + (Double((gs >> 8) & 0xFF) / 0xFF - 0.5) * length * 0.8,
                              y: l.y - height * 0.7 + (Double((gs >> 16) & 0xFF) / 0xFF - 0.5) * height * 0.7)
                let gs2 = 5.5 * (0.5 + ga * 0.5)
                g.scaleBy(x: gs2, y: gs2)
                g.fill(Self.starPath, with: .color(.white.opacity(0.85)))
            }
        }

        // Doing laps: a working fish with fresh output trails small
        // bubbles off its tail — the tank's "it's on it" tell.
        if fish.state == .swimming, !fish.isFry, recency < 12, !reduceMotion {
            let trail = 1 - recency / 12
            for k in 0..<3 {
                let tp = frac(t * 0.8 + Double(k) / 3 + phase / (.pi * 2))
                let bx = l.x - l.facing * (length * 0.42 + tp * 22)
                let by = l.y + 2 - tp * 16
                let br = 1.0 + tp * 1.8
                var b = canvas
                b.opacity = l.opacity * trail * (1 - tp) * 0.5
                b.stroke(Path(ellipseIn: CGRect(x: bx - br, y: by - br,
                                                width: br * 2, height: br * 2)),
                         with: .color(.white), lineWidth: 0.6)
            }
        }

        // A dozing fish breathes out the occasional slow "z".
        if l.sleep > 0.35, !fish.isFry {
            let zc = frac(t / 3.8 + phase / (.pi * 2))
            for k in 0..<2 {
                let zz = frac(zc + Double(k) * 0.5)
                guard zz < 0.6 else { continue }
                let bz = zz / 0.6
                let bx = l.x + l.facing * length * 0.3 + bz * 10
                let by = l.y - height * 0.3 - bz * 30
                var b = canvas
                b.opacity = l.opacity * l.sleep * (1 - bz) * 0.8
                if k == 0 {
                    let (resolved, _) = textCache.tag(for: "z", canvas: canvas)
                    b.draw(resolved, at: CGPoint(x: bx, y: by), anchor: .center)
                } else {
                    let br = 1.4 + bz * 2
                    b.stroke(Path(ellipseIn: CGRect(x: bx - br, y: by - br,
                                                    width: br * 2, height: br * 2)),
                             with: .color(.white), lineWidth: 0.7)
                }
            }
        }

        // The curious fish saw the pointer: a small bright pip overhead.
        if motion.curiousID == fish.id, !fish.isFry {
            let (resolved, _) = textCache.tag(for: "!", canvas: canvas)
            var c = canvas
            c.opacity = l.opacity * 0.9
            c.draw(resolved, at: CGPoint(x: l.x, y: l.y - height * 0.5 - 13),
                   anchor: .center)
        }

        // The label rides under the fish like a floating tag: small
        // type in a thin translucent chip, tied to the body by a
        // hairline tether — not a heavy slab glued underneath.
        if showLabels, !fish.isFry {
            var lc = canvas
            lc.opacity = l.opacity * (fish.state == .sinking ? 0.45 : 0.85)
            // Resolved glyphs are cached across frames — the label
            // doesn't change between reduces, only its anchor does.
            let (resolved, textSize) = textCache.chip(for: fish.label, canvas: canvas)
            let chipX = min(max(l.x, textSize.width / 2 + 14), size.width - textSize.width / 2 - 14)
            let chipY = min(l.y + height / 2 + 14, size.height - 14)
            let chip = CGRect(x: chipX - textSize.width / 2 - 6.5,
                              y: chipY - textSize.height / 2 - 2.5,
                              width: textSize.width + 13, height: textSize.height + 5)
            // The tether: a hairline from the body's underside down to
            // the chip — invisible when the chip is clamped sideways.
            if abs(chipX - l.x) < 20 {
                var tether = Path()
                tether.move(to: CGPoint(x: l.x, y: l.y + height / 2 + 3))
                tether.addLine(to: CGPoint(x: chipX, y: chip.minY))
                lc.stroke(tether, with: .color(.white.opacity(0.16)), lineWidth: 0.7)
            }
            let pill = Path(roundedRect: chip, cornerRadius: chip.height / 2)
            lc.fill(pill, with: .color(Color(red: 0.02, green: 0.07, blue: 0.13).opacity(0.34)))
            lc.stroke(pill, with: .color(.white.opacity(0.10)), lineWidth: 0.5)
            lc.draw(resolved, at: CGPoint(x: chipX, y: chipY), anchor: .center)
        }
    }

    /// The empty-tank caption, resolved & measured once per frame so
    /// the decor pass can keep clear of it: a small translucent
    /// capsule pinned to the bottom-left with a 16 pt margin, like a
    /// gallery plaque set on the sand.
    /// W14's inspector: the selected fish's name, species, and the
    /// plan's own evidence line — so what the card says and why the
    /// fish looks the way it does are one fact. Open raises the
    /// session's terminal; it never answers or acts.
    /// The idle-game footnote on a fish: what the tank remembers about
    /// this session — growth, meals, hunger, headwear, goldenness.
    /// Nil when there's nothing to say.
    private func careNote(for fish: Fish) -> String? {
        guard let game = toy?.game else { return nil }
        var bits: [String] = []
        if let care = game.pets[fish.id] {
            if care.stage >= 2 { bits.append("full-grown") }
            else if care.stage == 1 { bits.append("grown") }
            if care.feedings > 0 {
                bits.append("\(care.feedings) meal\(care.feedings == 1 ? "" : "s")")
            }
            if care.hungry(at: Date()) { bits.append("hungry") }
        }
        if let hat = game.hat(for: fish.id) {
            bits.append("wearing \(hat.displayName.lowercased())")
        } else if AquariumBehavior.wearsCrown(streakDays: game.streakDays,
                                              stage: game.pets[fish.id]?.stage ?? 0) {
            bits.append("royal")
        }
        if !fish.isFry, AquariumBehavior.isGolden(seed: fish.seed) {
            bits.append("golden")
        }
        return bits.isEmpty ? nil : bits.joined(separator: " · ")
    }

    private func inspectorStrip(_ fish: Fish) -> some View {
        HStack(spacing: 10) {
            ProviderTile(style: ProviderStyle.style(for: fish.providerID), size: 18)
            VStack(alignment: .leading, spacing: 1) {
                Text(fish.label)
                    .font(.system(size: 11, weight: .medium))
                    .lineLimit(1)
                Text(fish.plan?.evidence ?? fish.state.rawValue)
                    .font(.system(size: 9, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                // Where it's working and what that means — the station
                // the evidence line above put it at.
                if let cue = fish.cue, cue.isFresh(at: Date()), !fish.isFry {
                    Text(cue.phrase)
                        .font(.system(size: 9, weight: .medium))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                if let note = careNote(for: fish) {
                    Text(note)
                        .font(.system(size: 9))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 6)
            // Recast every fish this provider swims as — the pick is a
            // per-provider override, so the school changes shape at once.
            Picker(selection: Binding<FishSpecies?>(
                get: { toy?.speciesOverride(for: fish.providerID) },
                set: { toy?.setSpecies($0, for: fish.providerID) })) {
                Text("Automatic").tag(FishSpecies?.none)
                ForEach(FishSpecies.allCases, id: \.self) { species in
                    Text(species.displayName).tag(FishSpecies?.some(species))
                }
            } label: {
                EmptyView()
            }
            .labelsHidden()
            .pickerStyle(.menu)
            .controlSize(.small)
            .frame(width: 108)
            .help("The fish every \(fish.providerID) session swims as.")
            if let onOpen = toy?.core.openSession {
                Button("Open") { onOpen(fish.id) }
                    .controlSize(.small)
            }
            Button {
                selectedID = nil
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 9, weight: .medium))
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Close inspector")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
        .background(.ultraThinMaterial, in: Capsule())
        .padding(.horizontal, 14)
        .padding(.bottom, 10)
    }

    // MARK: Game chrome

    /// Whether the tank owns a shop item — the fixture path owns
    /// whatever its synthetic game says.
    private func owns(_ item: ShopItem) -> Bool {
        game?.owns(item) ?? false
    }

    /// A small translucent HUD chip.
    private func hudChip<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        content()
            .font(.system(size: 10, weight: .medium))
            .foregroundStyle(.white.opacity(0.92))
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(.ultraThinMaterial, in: Capsule())
    }

    /// The "while you were away" card (docs/TOYS.md): what the closed
    /// window banked, one line, dismissed by a tap or the ×.
    private func awayBanner(_ away: AquariumAwaySummary) -> some View {
        var parts: [String] = []
        if away.pearlsEarned > 0 { parts.append("+\(away.pearlsEarned) pearls") }
        if away.completions > 0 {
            parts.append("\(away.completions) session\(away.completions == 1 ? "" : "s") finished")
        }
        if away.dropsCollected > 0 {
            parts.append("\(away.dropsCollected) drop\(away.dropsCollected == 1 ? "" : "s") collected")
        }
        return HStack(spacing: 8) {
            Text("While you were away — \(parts.joined(separator: " · "))")
                .font(.system(size: 10.5, weight: .medium))
                .foregroundStyle(.white.opacity(0.95))
                .lineLimit(2)
            Button {
                toy?.dismissAwayNotice()
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 8, weight: .bold))
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Dismiss")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
        .background(.ultraThinMaterial, in: Capsule())
        .onTapGesture { toy?.dismissAwayNotice() }
    }

    /// The shop: every `ShopItem` grouped by category, one row each —
    /// price button when buyable, a lock while the tank level is short,
    /// a state control once owned. The game's reducer is the only money
    /// handler; the rows just send events.
    private func shopPanel(fish: [Fish]) -> some View {
        let game = toy?.game ?? AquariumGame()
        let adults = fish.filter { !$0.isFry && $0.state != .leaving }
        return ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Text("Tank shop").font(.headline)
                    Spacer()
                    Text("◉ \(game.pearls)")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.secondary)
                }
                shopHeader(game)
                ForEach(ShopItem.Category.allCases, id: \.self) { category in
                    Text(category.displayName)
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(.secondary)
                    ForEach(ShopItem.allCases.filter { $0.category == category },
                            id: \.rawValue) { item in
                        shopRow(item, game: game, adults: adults)
                    }
                }
                achievementsSection(game)
            }
            .padding(14)
        }
        .frame(width: 330, height: 420)
    }

    /// The economy's vitals over the shelves: ladder rung and progress,
    /// the streak, and today's chore with its counter.
    private func shopHeader(_ game: AquariumGame) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Label("Tank level \(game.tankLevel)", systemImage: "chart.bar.fill")
                    .font(.system(size: 10, weight: .medium))
                if let next = AquariumProgression.nextLevelAt(
                    lifetimePearls: game.lifetimePearls) {
                    Text("· \(game.lifetimePearls.formatted()) / \(next.formatted()) pearls")
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 4)
                if game.streakDays > 1 {
                    Label("\(game.streakDays)d", systemImage: "flame.fill")
                        .font(.system(size: 10))
                        .foregroundStyle(.orange)
                }
            }
            if let goal = game.dailyGoal {
                HStack(spacing: 6) {
                    Image(systemName: goal.claimed
                          ? "checkmark.circle.fill" : "target")
                        .font(.system(size: 10))
                        .foregroundStyle(goal.claimed ? .green : .secondary)
                    Text(goal.kind.displayName)
                        .font(.system(size: 10))
                    Spacer(minLength: 4)
                    Text(goal.claimed ? "Done"
                         : "\(min(goal.progress, goal.target))/\(goal.target)")
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    /// One shop row: name + detail + the action the item's state asks
    /// for — buy, apply a surface, seat a wearable, or just "owned".
    /// An item on a shelf above the tank's level sits dimmed behind
    /// a lock instead.
    private func shopRow(_ item: ShopItem, game: AquariumGame,
                         adults: [Fish]) -> some View {
        let unlocked = item.isUnlocked(atLevel: game.tankLevel)
        return HStack(alignment: .firstTextBaseline, spacing: 8) {
            VStack(alignment: .leading, spacing: 1) {
                Text(item.displayName)
                    .font(.system(size: 11, weight: .medium))
                if unlocked {
                    Text(item.detail)
                        .font(.system(size: 9))
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                } else {
                    Label("Unlocks at tank level \(AquariumProgression.tierUnlockLevel(tier: item.tier))",
                          systemImage: "lock.fill")
                        .font(.system(size: 9))
                        .foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 4)
            if !unlocked {
                Image(systemName: "lock.fill")
                    .font(.system(size: 9))
                    .foregroundStyle(.tertiary)
            } else if game.owns(item) {
                ownedControl(item, game: game, adults: adults)
            } else {
                buyButton(item, game: game)
            }
        }
        .opacity(unlocked ? 1 : 0.55)
    }

    /// What an owned item offers: a surface's Use, a wearable's fish
    /// picker, or just the check that says it's in the tank.
    @ViewBuilder
    private func ownedControl(_ item: ShopItem, game: AquariumGame,
                              adults: [Fish]) -> some View {
        switch item.category {
        case .themes:
            if game.themeID == item.themeID {
                Text("In use").font(.system(size: 10))
                    .foregroundStyle(.secondary)
            } else {
                Button("Use") { toy?.selectTheme(item) }
                    .controlSize(.small)
            }
        case .substrates:
            if game.substrateID == item.substrateID
                || game.backdropID == item.backdropID {
                Text("In use").font(.system(size: 10))
                    .foregroundStyle(.secondary)
            } else {
                Button("Use") {
                    if item.substrateID != nil {
                        toy?.selectSubstrate(item)
                    } else if item.backdropID != nil {
                        toy?.selectBackdrop(item)
                    }
                }
                .controlSize(.small)
            }
        case .hats, .accessories:
            let worn = item.category == .hats ? game.hats : game.accessories
            Menu {
                ForEach(adults) { fish in
                    Button(fish.label) {
                        if item.category == .hats {
                            toy?.equipHat(item, to: fish.id)
                        } else {
                            toy?.equipAccessory(item, to: fish.id)
                        }
                    }
                }
                if worn.contains(where: { $0.value == item.rawValue }) {
                    Divider()
                    Button("Take it off") {
                        if item.category == .hats {
                            toy?.equipHat(item, to: nil)
                        } else {
                            toy?.equipAccessory(item, to: nil)
                        }
                    }
                }
            } label: {
                Text(worn.contains(where: { $0.value == item.rawValue })
                     ? "Re-seat" : "Wear")
                    .font(.system(size: 10))
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
        default:
            Image(systemName: "checkmark.circle.fill")
                .foregroundStyle(.green)
                .help("Owned")
        }
    }

    /// The price button — disabled when the bank is short; a denied
    /// tap can't get past the disabled state anyway.
    private func buyButton(_ item: ShopItem, game: AquariumGame) -> some View {
        Button("◉ \(item.price)") {
            toy?.purchase(item)
            // The purchase bloop: three little rings mid-tank.
            for k in 0..<3 {
                motion.puffs.append((x: 0.44 + Double(k) * 0.06,
                                     y: 0.30 + Double(k) * 0.05,
                                     bornAt: Date()))
            }
        }
        .controlSize(.small)
        .disabled(game.pearls < item.price)
    }

    /// The milestones, folded shut until asked: unlocked ones carry
    /// their date, locked ones sit dimmed with what they take.
    private func achievementsSection(_ game: AquariumGame) -> some View {
        DisclosureGroup {
            ForEach(AquariumAchievement.allCases, id: \.rawValue) { achievement in
                let at = game.unlocked[achievement.rawValue]
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Image(systemName: at != nil ? "checkmark.seal.fill" : "seal")
                        .font(.system(size: 10))
                        .foregroundStyle(at != nil ? .yellow : .secondary)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(achievement.title)
                            .font(.system(size: 11, weight: .medium))
                        Text(achievement.detail)
                            .font(.system(size: 9))
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                    }
                    Spacer(minLength: 4)
                    if let at {
                        Text(Date(timeIntervalSince1970: at),
                             format: .dateTime.month(.abbreviated).day())
                            .font(.system(size: 9))
                            .foregroundStyle(.secondary)
                    }
                }
                .opacity(at == nil ? 0.55 : 1)
            }
        } label: {
            Text("Achievements")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(.secondary)
        }
    }

    private func captionLayout(canvas: inout GraphicsContext, size: CGSize)
        -> (text: GraphicsContext.ResolvedText, rect: CGRect) {
        let resolved = canvas.resolve(
            Text("Quiet water — fish arrive when agents start")
                .font(.caption)
                .foregroundStyle(.white.opacity(0.62)))
        let textSize = resolved.measure(in: CGSize(width: size.width - 64, height: 40))
        let rect = CGRect(x: 16, y: size.height - 16 - textSize.height - 12,
                          width: textSize.width + 22, height: textSize.height + 12)
        return (resolved, rect)
    }

    /// A quiet tank is still a dressed tank — the jellyfish stays on
    /// as the resident and the caption capsule sits low on the left.
    private func drawEmpty(canvas: inout GraphicsContext, size: CGSize,
                           caption: (text: GraphicsContext.ResolvedText, rect: CGRect)) {
        let pill = Path(roundedRect: caption.rect, cornerRadius: caption.rect.height / 2)
        canvas.fill(pill,
                    with: .color(Color(red: 0.02, green: 0.07, blue: 0.13).opacity(0.55)))
        canvas.stroke(pill, with: .color(.white.opacity(0.10)), lineWidth: 0.75)
        canvas.draw(caption.text,
                    at: CGPoint(x: caption.rect.midX, y: caption.rect.midY),
                    anchor: .center)
    }

    private func frac(_ x: Double) -> Double {
        x - x.rounded(.down)
    }

    private func clamp01(_ x: Double) -> Double {
        min(1, max(0, x))
    }

    private func smooth(_ x: Double) -> Double {
        let c = clamp01(x)
        return c * c * (3 - 2 * c)
    }
}
