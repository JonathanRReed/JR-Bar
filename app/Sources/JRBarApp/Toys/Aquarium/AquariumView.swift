import AppKit
import JRBarCore
import SwiftUI

/// The tank (docs/TOYS.md), painted in depth order: a still far pass
/// (the water, the back wall, the far bank and the back row of bought
/// pieces), a live plant pass (the kelp and grass that sway between
/// them), a still near pass (the lit sand and every unmoving piece on
/// it) — both still passes rasterized by `.drawingGroup` on a slow tick
/// and recomposited for free — then an additive light pass (shafts,
/// the caustic net, a slow sheen) and the live `Canvas` for the
/// swimmers and everything at the glass. Fish positions are integrated
/// from each `Fish`'s constants and the frame clock, so `toy.fish` only
/// has to change when the session set does, and every timeline pauses
/// while the window is covered.
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
        /// A pinned water mood; nil is calm water.
        var mood: AquariumWaterMood?
        /// The card's settings for the shot, the swim settings included;
        /// nil builds them from `showLabels` and `density` above.
        var settings: AquariumSettings?
    }

    let toy: AquariumToy?
    let fixture: Fixture?

    /// The game either side reads — the toy's live document, or the
    /// fixture's synthetic one.
    var game: AquariumGame? { toy?.game ?? fixture?.game }

    /// The card's settings, read in one place: the toy's store, or the
    /// fixture's own.
    var tankSettings: AquariumSettings {
        if let toy { return toy.store?.state.aquarium ?? AquariumSettings() }
        if let pinned = fixture?.settings { return pinned }
        var built = AquariumSettings(showLabels: fixture?.showLabels ?? true,
                                     density: fixture?.density ?? 1,
                                     dayNight: .cycle)
        built.bubbles = built.density
        built.scenery = built.density < 1 ? .light : .full
        return built
    }

    /// The water column's theme key — "classic" when there's no game.
    var themeKey: String { game?.themeID ?? "classic" }
    /// The floor's substrate key.
    var substrateKey: String { game?.substrateID ?? "classic" }
    /// The back wall's backdrop key.
    var backdropKey: String { game?.backdropID ?? "classic" }
    /// Themes dark enough that the warm sun glow cools to moonlight —
    /// the water's own style says so.
    var isDarkTheme: Bool { water.style.dark }
    /// The column's floor colour — what deep water attenuates toward.
    var floorColor: Color {
        waterStops.last?.color ?? Color(red: 0.015, green: 0.06, blue: 0.22)
    }
    var floorNS: NSColor { NSColor(floorColor) }

    /// The day/night wash's depth (0 bright … 1 deepest). `cycle`
    /// keeps the original four-minute breathe; `realTime` follows the
    /// clock — night from 21:00 to 06:00, dawn & dusk blending the
    /// edges; `sun` blends at the real sunrise and sunset, or keeps the
    /// clock's hours where the time zone has no city; `appearance`
    /// follows Light and Dark mode, easing over two seconds when it
    /// flips; the two pinned modes hold day or night. Reduce Motion
    /// holds a soft dusk for the moving modes; a fixture can pin it.
    func nightFactor(t: Double) -> Double {
        if let pinned = fixture?.night { return pinned }
        let mode = tankSettings.dayNight
        switch mode {
        case .alwaysDay: return 0
        case .alwaysNight: return 1
        case .appearance: return AquariumNightEase.appearanceNight(at: t, still: reduceMotion)
        case .cycle, .realTime, .sun: break
        }
        if reduceMotion { return 0.4 }
        let date = Date(timeIntervalSince1970: t)
        switch mode {
        case .cycle:
            return AquariumBehavior.night(at: t)
        case .sun:
            return AquariumSun.night(at: date)
                ?? AquariumBehavior.realTimeNight(at: date, calendar: .current)
        default:
            return AquariumBehavior.realTimeNight(at: date, calendar: .current)
        }
    }

    /// The shop decor's tone for this moment (`TankPaint.Tone`): none
    /// by day in the bright themes — so the 30 fps pass converts no
    /// colours then — deepening with the night and in the dark themes.
    func decorTone() -> TankPaint.Tone {
        let night = nightFactor(t: Date().timeIntervalSince1970)
        let wash = max(isDarkTheme ? 0.40 : 0, night * 0.34)
        return TankPaint.Tone(wash: wash < 0.02 ? 0 : wash, toward: floorNS)
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
    let ambient: Bool
    /// The ambient panel's own visibility — a live wallpaper under a
    /// stack of windows draws nothing.
    @ViewState private var ambientVisible = true

    @Environment(\.accessibilityReduceMotion) var reduceMotion
    /// W14's selection: the tapped fish's id, cleared when it leaves
    /// the tank. Drives the inspector strip — the tap already hit-tests
    /// via `hoverProbe.boxes`, selection just keeps the last hit.
    @ViewState var selectedID: String?
    /// The selected resident's logbook, fetched when it's tapped.
    @ViewState var residentLog: (id: String, log: AquariumResidentLog)?
    /// The shop popover's open flag.
    @ViewState var showShop = false
    /// Light or Dark, as the window wears it — a flip starts the ease.
    @Environment(\.colorScheme) private var colorScheme
    /// When the view last saw Light and Dark flip; nil once the ease
    /// has landed.
    @ViewState private var nightFlipAt: Double?

    var body: some View {
        // Read the observable surface in `body` so the card's tracked
        // reads stay honest even while the timeline is paused.
        let fish = toy?.fish ?? fixture?.fish ?? []
        // One read of the card: the chip under each fish, and the three
        // amounts — plankton, bubbles, and how much seeded dressing (the
        // stations use the same share, so a fish never works at a rock
        // that isn't drawn).
        let settings = tankSettings
        let labelStyle = settings.labelStyle
        let showLabels = labelStyle == .always
        let plankton = max(0, settings.density)
        let bubbles = settings.bubbles
        let density = settings.scenery.fraction
        let paused = ambient ? !ambientVisible
            : (toy?.windowOccluded ?? fixture?.paused ?? false)
        let stillTick = stillPassTick(settings)
        ZStack {
            // The far tank: water, the back wall, the far bank and the
            // back row of bought pieces — everything behind the plants.
            // A slow two-second tick lets the day/night wash keep
            // breathing (quicker while a Light & Dark flip eases in —
            // `stillPassTick`); `.drawingGroup` rasterizes the result, so each
            // live frame costs one texture composite, not the paths.
            TimelineView(.animation(minimumInterval: stillTick, paused: paused)) { context in
                Canvas { canvas, size in
                    let t = context.date.timeIntervalSince1970
                    drawWater(canvas: &canvas, size: size, t: t)
                    drawBackdrop(canvas: &canvas, size: size)
                    drawFarSand(canvas: &canvas, size: size)
                    drawNight(canvas: &canvas, size: size, t: t)
                    // The Toy reef's windows and crystals shine through
                    // the night, so they draw after it.
                    drawToyReefLights(canvas: &canvas, size: size, t: t)
                    // Owned back-row pieces root on the far dune —
                    // still, so they bake in with the distance.
                    drawOwnedBackDecor(canvas: &canvas, size: size, t: t)
                }
            }
            .drawingGroup(opaque: false, colorMode: .nonLinear)
            // The plants: kelp and grass rooted on the near crest,
            // swaying between the far tank and the near still pieces,
            // so a stand grows up behind the castle and in front of the
            // wreck. Its own canvas, the only thing in it; a slow sway
            // is smooth at twenty frames a second.
            TimelineView(.animation(minimumInterval: reduceMotion ? 1 : 1.0 / 20.0,
                                    paused: paused)) { context in
                let empty = fish.isEmpty || fish.allSatisfy { $0.isRetired(at: context.date) }
                Canvas { canvas, size in
                    let caption = empty ? captionLayout(canvas: &canvas, size: size) : nil
                    drawPlants(canvas: &canvas, size: size, t: context.date.timeIntervalSince1970,
                               density: density, front: false, keepClear: caption?.rect)
                }
            }
            // The near bed: the lit sand and every piece on it that
            // doesn't sway, on the same slow tick (which also keeps the
            // caption's decor culling in step with retiring fish).
            TimelineView(.animation(minimumInterval: stillTick, paused: paused)) { context in
                Canvas { canvas, size in
                    let t = context.date.timeIntervalSince1970
                    drawSand(canvas: &canvas, size: size, t: t)
                    let empty = fish.isEmpty
                        || fish.allSatisfy { $0.isRetired(at: context.date) }
                    let caption = empty ? captionLayout(canvas: &canvas, size: size) : nil
                    drawStaticDecor(canvas: &canvas, size: size, t: t, density: density,
                                    keepClear: caption?.rect)
                    // The shop's still pieces and the front row's
                    // unmoving ones bake in too; only what sways, glows
                    // or streams stays on the live pass.
                    drawShopDecorStill(canvas: &canvas, size: size, t: t)
                    drawOwnedFrontStill(canvas: &canvas, size: size, t: t)
                }
            }
            .drawingGroup(opaque: false, colorMode: .nonLinear)
            // The light pass: the shafts, the caustic net on the sand and
            // a slow sheen drift through the column. The canvas
            // composites additively over the tank, so these read as
            // light, not pale decals. Everything in it moves a few
            // points a second, so twelve frames a second is smooth.
            TimelineView(.animation(minimumInterval: reduceMotion ? 1 : 1.0 / 12.0,
                                    paused: paused)) { context in
                let t = context.date.timeIntervalSince1970
                Canvas { canvas, size in
                    drawGodRays(canvas: &canvas, size: size, t: t)
                    drawSandCaustics(canvas: &canvas, size: size, t: t)
                    drawWaterSheen(canvas: &canvas, size: size, t: t)
                }
                .blendMode(.plusLighter)
                .allowsHitTesting(false)
            }
            // The live timeline: 30 fps normally, a 1 fps heartbeat under
            // Reduce Motion — every draw inside already stills itself, so
            // the slow tick only keeps the sim honest (pellets still
            // sink to mouths, completions still serve their meals, a
            // visitor's still portrait still comes and goes) without
            // paying a display-rate redraw for a scene that doesn't move.
            TimelineView(.animation(minimumInterval: reduceMotion ? 1 : 1.0 / 30.0,
                                    paused: paused)) { context in
                let t = context.date.timeIntervalSince1970
                // The card's measured frame rate.
                let _ = toy?.meter.tick()
                // Memoized on the fish array: the timeline ticks 30×/s
                // but the roster only moves with the sessions, so an
                // unchanged roster reuses the last sort instead of
                // rebuilding it.
                let order = fishOrder(fish)
                let empty = fish.isEmpty || fish.allSatisfy { $0.isRetired(at: context.date) }
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
                    // The castle's pennant streams over its baked
                    // keep, so it goes behind the fish as the keep
                    // does.
                    drawShopPennant(canvas: &canvas, size: size, t: t)
                    drawJellyfish(canvas: &canvas, size: size, t: t,
                                  resident: empty || owns(.jellyfish))
                    drawPlankton(canvas: &canvas, size: size, t: t,
                                 density: plankton, front: false)
                    drawBubbles(canvas: &canvas, size: size, t: t, density: bubbles)
                    // The passers-by and the sand/mid-water pets
                    // live behind the fish lane.
                    drawVisitor(canvas: &canvas, size: size, t: t, now: context.date)
                    if owns(.manta) {
                        drawManta(canvas: &canvas, size: size, t: t)
                    }
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
                        // The hover/tap hit area, front-most fish wins.
                        hoverProbe.boxes.append((aFish.id, hitBox(of: aFish, layout: l)))
                    }
                    drawTokenPasses(canvas: &canvas, roster: order.ordered,
                                    layouts: layouts, t: t, now: context.date)
                    drawMeals(canvas: &canvas, meals: meals, now: context.date)
                    drawFeed(canvas: &canvas, size: size, now: context.date)
                    // Only the decor that sways or glows draws over
                    // the lane; the still pieces baked in behind it.
                    // The buried treasure waits on the sand for its
                    // taps.
                    drawShopDecor(canvas: &canvas, size: size, t: t)
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
                    drawOyster(canvas: &canvas, size: size, t: t)
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
                    drawPlants(canvas: &canvas, size: size, t: t, density: density,
                               front: true, keepClear: caption?.rect)
                    drawPlankton(canvas: &canvas, size: size, t: t,
                                 density: plankton, front: true)
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
                    // Labels › Never keeps the tag for the fish you
                    // selected, so the inspector's fish still names itself.
                    if let point = probe,
                       let hit = hoverProbe.boxes.last(where: { $0.rect.contains(point) }),
                       labelStyle != .never || hit.id == selectedID,
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
            // The oyster's pearl takes the tap first, then the alien,
            // then the buried treasure — the rarest thing on the sand;
            // then a pearl drop collects; a fish selects; open water
            // drops a pinch of food.
            if let box = motion.oysterBox, box.contains(value.location), toy?.game.oysterReady == true {
                toy?.collectOyster()
                motion.puffs.append((x: box.midX / max(1, motion.size.width),
                                     y: box.maxY / max(1, motion.size.height) - 0.03, bornAt: Date()))
                motion.flights.append((from: CGPoint(x: box.midX, y: box.midY), bornAt: Date()))
                return
            }
            if let box = motion.alienBox, box.contains(value.location),
               let visit = motion.activeVisitor, visit.kind == .alien, motion.alienShooedAt == nil {
                tapAlien(at: value.location, visit: visit.startedAt)
                return
            }
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
        // The water runs to the window's edges, under the title bar;
        // the chrome keeps to the safe area below it.
        .ignoresSafeArea()
        .overlay {
            ZStack {
                // W14's inspector: the selected fish's session facts —
                // the plan's own evidence line, so the strip and the
                // marker can't disagree about why it looks the way it
                // does.
                if let selectedID,
                   let selected = fish.first(where: { $0.id == selectedID }) {
                    VStack {
                        Spacer()
                        inspectorStrip(selected)
                    }
                    .transition(.opacity)
                    .task(id: selected.isResident ? selected.id : nil) {
                        guard selected.isResident, let toy else { return }
                        let log = await toy.residentLog(for: selected.id)
                        residentLog = (selected.id, log)
                    }
                }
                if toy != nil, !ambient {
                    gameChrome(fish: fish)
                }
            }
        }
        .coordinateSpace(.named(Self.tankSpace))
        // The card's Look › Open the shop… lands here: the window's tank
        // shows its shop as it comes up.
        .onChange(of: toy?.store?.wantsAquariumShop ?? false, initial: true) { _, wants in
            guard wants, !ambient, let store = toy?.store else { return }
            store.wantsAquariumShop = false
            showShop = true
        }
        // Follow Light & Dark: a flip quickens the still passes until
        // the ease has landed, then they settle back to their slow tick.
        .onChange(of: colorScheme) {
            nightFlipAt = Date().timeIntervalSince1970
        }
        .task(id: nightFlipAt) {
            guard nightFlipAt != nil else { return }
            try? await Task.sleep(for: .seconds(AquariumNightEase.seconds + 0.5))
            if !Task.isCancelled { nightFlipAt = nil }
        }
    }

    /// The still passes' tick: two seconds, or quick while a Follow
    /// Light & Dark flip eases in, so the water, the back wall and the
    /// sand dim with the fish instead of stepping once at the end.
    func stillPassTick(_ settings: AquariumSettings) -> Double {
        guard settings.dayNight == .appearance, !reduceMotion, fixture?.night == nil else {
            return AquariumNightEase.restingTick
        }
        return AquariumNightEase.stillTick(flipAt: nightFlipAt, at: Date().timeIntervalSince1970)
    }

    /// The tank's own coordinate space — the canvas's points, which the
    /// chrome measures itself in so a pearl can fly home to its chip.
    nonisolated static let tankSpace = "aquarium-tank"

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
    struct FeedPellet {
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
    final class TankMotion {
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
        /// Where the pearl counter sits in the tank's points, measured
        /// by the chip itself — where a collected pearl flies home to.
        var pearlChip: CGPoint?
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
        /// Where each fish was last drawn and how its last change of
        /// state is settling (`TankSwimMemory`).
        let swim = TankSwimMemory()
        /// Where each pearl drop was first seen, in unit space, and when:
        /// it falls from there to the sand and rests at that x for good,
        /// however its fish swims on. `fromY` nil rests at once.
        var dropSpots: [String: DropSpot] = [:]
        /// The snail's errands, and the frame clock it last stepped on.
        var snail = SnailSim()
        var snailT: Double = 0
        /// Pearls the snail has picked up whose collection hasn't
        /// reached the game yet — it won't fetch one twice.
        var snailClaimed: Set<String> = []
        /// The oyster's tap box this frame, when it's in the tank.
        var oysterBox: CGRect?
        /// The alien's tap box this frame, and the taps it has taken
        /// this visit (keyed by when the visit started).
        var alienBox: CGRect?
        var alienTaps: (visit: Date, count: Int)?
        /// When the alien was shooed off, so it zips away from there,
        /// and when the last tap made it wobble.
        var alienShooedAt: Date?
        var alienWobbleAt: Date?
    }

    /// A game event a draw pass produced — recorded, not applied.
    enum PendingGameEvent {
        /// A fish reached its pellet; `fishID` is the eater.
        case pelletEaten(fishID: String)
        /// A visitor's parade across the back layer began.
        case visitorShown(AquariumVisitor)
        /// The parade ended — the visitor swam off the far edge.
        case visitorDeparted(AquariumVisitor)
        /// The snail reached a pearl and picked it up.
        case snailCollected(String)
    }

    /// What a tapped fish shows off (docs/TOYS.md: fish tricks).
    enum TrickKind {
        case roll
        case ring
    }

    @ViewState var motion = TankMotion()

    /// A tap on open water drops a pinch of food: three pellets around
    /// the point, sinking toward the bed. The game hears only about
    /// the ones a fish actually eats.
    func feed(at point: CGPoint) {
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
        toy?.playSound(.plop)
    }

    /// One step of the steering world, run at the top of every live
    /// frame: sink & claim the pellets, school the providers, then
    /// step each free-swimming fish's body — the layout pass below
    /// just reads the results. Special states (rise/sink/leave) hold
    /// their bodies still; the pose functions animate from the anchor
    /// recorded where the state changed.
    func stepSwim(_ roster: [Fish], in size: CGSize, t: Double, now: Date,
                  density: Double = 1) {
        let m = motion
        m.size = size
        // One read of the swim settings per frame.
        m.swim.settings = swimSettings
        let tuning = m.swim.settings ?? AquariumSettings()
        let tempo = AquariumSettings.clamped(tuning.swimSpeed, to: AquariumSettings.swimSpeedRange)
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
        m.swim.prune(keeping: liveIDs)
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
        // A fish back from the glass (an ask answered) or up off the sand
        // swims on from where it was last drawn, not from where its body
        // waited — so it swims back down instead of jumping.
        for fish in swimmers {
            guard let was = m.anchors[fish.id]?.state, was != .swimming, was != .idling,
                  let drawn = m.swim.drawn[fish.id], var body = m.bodies[fish.id],
                  size.width > 1, size.height > 1 else { continue }
            body.x = drawn.x / size.width
            body.y = drawn.y / size.height
            body.dir = drawn.yawCos >= 0 ? 1 : -1
            body.climb = 0
            body.pitch = drawn.pitch
            body.turn = nil
            body.throttle = 0.5
            m.bodies[fish.id] = body
        }

        // Claims: each pellet goes to the nearest swimmer.
        m.claims.removeAll(keepingCapacity: true)
        var foodByFish: [String: (x: Double, y: Double)] = [:]
        // A finished fish's meal: each eater swims for its pellet through
        // its own turn, and eats it when its mouth gets there (below).
        let meals = completionMeals(in: size, now: now, roster: roster)
        for meal in meals {
            let age = now.timeIntervalSince(meal.leaver.stateSince)
            for pellet in meal.pellets {
                guard let eater = pellet.eater, m.bodies[eater] != nil,
                      age > 0.35, age < pellet.gone else { continue }
                let at = pellet.position(at: age)
                foodByFish[eater] = (at.x / max(1, size.width), at.y / max(1, size.height))
            }
        }
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

        let maxY = (size.height - 100) / max(1, size.height)

        for fish in swimmers {
            guard var body = m.bodies[fish.id] else { continue }
            // Its tallest fin stays under the surface at its size.
            let top = min(maxY - 0.05, surfaceClearance(of: fish) / max(1, size.height))
            let bounds = SwimBounds(minX: 0.05, minY: top, maxX: 0.95, maxY: maxY, margin: 0.10)
            var context = SwimContext(bounds: bounds, pace: tuning.swimPace, tempo: tempo)
            // The body sees the glass by its drawn length.
            body.length = drawnSize(of: fish, layout: steeringLayout(of: fish)).length
                / max(1, size.width)
            // A startled fish darts away from the tap — expressed as a
            // place to flee to just past its tail, so the seek does the
            // darting and a tap behind it turns it round quick. Unless a
            // real pellet already claimed it: lunch outranks a scare.
            if let s = m.startles[fish.id], foodByFish[fish.id] == nil {
                let dx = body.x * size.width - s.from.x
                let dy = body.y * size.height - s.from.y
                let len = max(1, (dx * dx + dy * dy).squareRoot())
                context.food = (x: min(0.98, max(0.02, body.x + dx / len * 0.45)),
                                y: min(0.92, max(0.02, body.y + dy / len * 0.45)))
                context.startled = true
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
            context.idling = fish.state == .idling
            context.wander = fish.state == .idling ? 0.5 : 1.0
            context.hunger = hungry ? 1.3 : 1.0
            context.effort = fish.state == .idling ? 0.42 : 1.0
            // At work: the plan's tool-level action has a station, and
            // the fish goes and does it there — foraging the kelp for a
            // read, circling the wreck for a test. It swims to the
            // station's moving point and hovers once it arrives, so the
            // glass, the food and a startle all still outrank it: lunch
            // first, a poke still scares, and the work waits a beat.
            if context.food == nil, fish.state == .swimming,
               let cue = fish.cue, cue.isFresh(at: now),
               let anchor = stationAnchor(cue.station, for: fish, in: size,
                                          density: density, bounds: bounds) {
                let goal = AquariumStations.target(for: cue.station, anchor: anchor,
                                                   t: t, seed: fish.seed)
                let dx = goal.x - body.x, dy = goal.y - body.y
                context.station = (x: min(bounds.maxX, max(bounds.minX, goal.x)),
                                   y: min(bounds.maxY, max(bounds.minY, goal.y)))
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

        // A fish whose mouth reached its meal's pellet eats it: the
        // pellet blinks out, the mouth smiles, the body squash-stretches.
        for meal in meals {
            let age = now.timeIntervalSince(meal.leaver.stateSince)
            for (i, pellet) in meal.pellets.enumerated() {
                guard let eater = pellet.eater, let b = m.bodies[eater],
                      age > 0.35, age < pellet.gone else { continue }
                let at = pellet.position(at: age)
                let cx = b.x * size.width, cy = b.y * size.height
                let pose = AquariumTurn.pose(of: b)
                let nose = CGPoint(x: cx + pose.c * pellet.mouth * cos(b.pitch),
                                   y: cy + abs(pose.c) * pellet.mouth * sin(b.pitch))
                let bite = max(5, pellet.mouth * 0.45)
                if hypot(nose.x - at.x, nose.y - at.y) < bite
                    || hypot(cx - at.x, cy - at.y) < pellet.mouth * 0.7 {
                    mealEaten(meal.leaver, pellet: i, age: age)
                    m.smileUntil[eater] = now.addingTimeInterval(3.5)
                    m.bounceUntil[eater] = now.addingTimeInterval(0.7)
                }
            }
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
    func queueEventDrain() {
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
                    case .snailCollected(let id): toy?.snailCollected(id)
                    }
                }
            }
        }
    }

    /// A new fish's body, seeded off its id: starts inside the glass at
    /// its lane's depth, facing the way its swim says, at a calm cruise
    /// (`AquariumSteering.spawn`).
    func spawnBody(for fish: Fish, in size: CGSize) -> SwimBody {
        let homeY = min(0.80, max(0.14,
                                  laneY(for: fish, in: size) / max(1, size.height)))
        let length = drawnSize(of: fish, layout: steeringLayout(of: fish)).length
        return AquariumSteering.spawn(seed: fish.seed, fishSpeed: fish.speed,
                                      direction: fish.direction, homeY: homeY,
                                      length: length / max(1, size.width))
    }

    /// The layout a swimming fish's size is measured under: its lane's
    /// depth scale, before any rise or bounce.
    func steeringLayout(of fish: Fish) -> Layout {
        var l = Layout()
        l.scale = 1.08 - fish.lane * 0.4
        return l
    }

    /// Where a fish's current state found it, in points — the anchor
    /// the rise/sink/leave poses move from. Falls back to the old
    /// patrol sweep when no body has stepped yet (the fixture path).
    func anchor(of fish: Fish, in size: CGSize) -> CGPoint {
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
    final class TextCache {
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

    @ViewState var textCache = TextCache()

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
}
