import AppKit
import JRBarCore
import JRBarLEDS
import Observation
import os
import SwiftUI

/// Notch Buddy (docs/TOYS.md): a tiny creature in the `NotchHUD` panel
/// that lives by the agent state — asleep under a nightcap when nothing
/// runs, pacing while sessions work (bouncing in place when three or
/// more work at once), waving amber while an ask is open, tumbling into
/// a slump on a failure, one hop on a completion. Reads `core.sessions`
/// only; off by default.
///
/// It is also a small pet: the pill is clickable (the panel only
/// ignores the mouse while a toast holds it), a tap counts as a pet and
/// cycles a trick — hop, spin, wave, blush — and while an ask is open
/// a tap on the "!" badge does something useful too: it opens the
/// session asking. The
/// card can name it and feed it, completed sessions land as crumbs it
/// "eats", and a day without a pat leaves it drooping.
///
/// And it roams: a drag past four points lifts it out of the notch slot
/// and parks it anywhere on screen in a panel of its own (`freePosition`
/// survives relaunches, clamped onto the visible screen), a drop back on
/// the slot — or "Dock at the notch" — sends it home. Right-click or a
/// held press opens its menu; "Tuck away" hides it until the next
/// session event or a card re-enable. Under the pointer it wears a
/// quiet caption naming the session it is watching, and the card's Size
/// slider grows the floating buddy up to 3× — the docked pill stays its
/// 18pt self.
@MainActor
@Observable
final class NotchBuddyToy: Toy {
    let core: CoreModel
    /// The owning store; weak, the store keeps the toy.
    weak var store: ToysStore?
    /// Something the panels need to re-lay out for changed: `isOn`,
    /// `tucked`, `freePosition`, `showCaption`.
    var onVisibilityChange: (@MainActor () -> Void)?
    /// Where home is, in screen coordinates — the HUD supplies it so
    /// "Float free" and a drop-on-the-notch know the dock slot.
    @ObservationIgnored var dockPointProvider: (@MainActor () -> CGPoint)?

    /// While non-nil and in the future the buddy hops once. Completions
    /// and treats both hop.
    private(set) var hopUntil: Date?
    /// When the current wave began — the ask entrance and the "!" pop
    /// once from here. `summary(at:)` maintains it because the view is
    /// the only clock that ticks the mood. Observation-ignored: the
    /// writes happen inside `summary`, which runs inside the view's
    /// animation timeline — tracking them would mutate observable
    /// state mid-render, and the timeline re-renders each frame anyway.
    @ObservationIgnored private(set) var wavingSince: Date?
    /// When the current slump began — the tumble-in rolls once from
    /// here. Same deal as `wavingSince`: `summary(at:)` maintains it.
    @ObservationIgnored private(set) var slumpedSince: Date?
    /// How many asks have opened. They alternate deterministically: odd
    /// asks wave with the "!" overhead, even asks just lean in and hold
    /// your eye. Untracked for the same reason as `wavingSince`.
    @ObservationIgnored private(set) var waveOrdinal = 0
    /// How many taps have landed — the tricks cycle through the
    /// repertoire so repeated pats never repeat the same one twice.
    private(set) var trickOrdinal = 0
    /// Which trick is up this tap.
    private(set) var trickKind: BuddyTrick.Kind = .hop
    /// When the current trick began; the view ages it out.
    private(set) var trickStartedAt: Date?
    /// When the last treat landed — the hearts burst plays from here.
    private(set) var treatBurstAt: Date?
    /// When it last ate a completion crumb — the "+1" plays from here.
    private(set) var crumbAt: Date?
    @ObservationIgnored private var wakeSnapshot: [String: SessionActivity]?

    init(core: CoreModel) {
        self.core = core
    }

    let id = "notch-buddy"
    let name = "Notch Buddy"
    let blurb = "A little guy in the notch who lives by what your agents are doing."
    let symbol = "face.smiling"

    /// On means showing: enabled and not tucked away. Flipping it back
    /// on from the card is also how a tucked buddy gets woken early.
    var isOn: Bool {
        get { (store?.state.notchBuddy.enabled ?? false) && !isTucked }
        set {
            let wasTucked = isTucked
            let from = comeBack()
            cancelTuck()
            store?.state.notchBuddy.enabled = newValue
            if newValue {
                store?.state.notchBuddy.tucked = false
                if wasTucked { arrive(fromScale: from.scale, fromOpacity: from.opacity) }
            }
            onVisibilityChange?()
        }
    }

    var status: ToyStatus {
        if store?.state.notchBuddy.enabled != true { return .off }
        return isTucked ? .paused("Tucked away") : .on
    }

    /// What it wears: the setting's pick, only if it's from the tank
    /// shop's buddy shelf and the tank owns it — one purse, one truth.
    var wearing: ShopItem? {
        guard let raw = store?.state.notchBuddy.wearing,
              let item = ShopItem(rawValue: raw), item.category == .buddy,
              store?.aquarium?.game.owns(item) == true else { return nil }
        return item
    }

    /// Puts on an owned buddy item, or takes it off (`nil`).
    func wear(_ item: ShopItem?) {
        guard let item else { store?.state.notchBuddy.wearing = nil; return }
        guard item.category == .buddy, store?.aquarium?.game.owns(item) == true else { return }
        store?.state.notchBuddy.wearing = item.rawValue
    }

    /// The floating buddy's walkabout (`BuddyStroll`) is allowed.
    var takesWalks: Bool { store?.state.notchBuddy.walkabout ?? true }
    var takesWalksBinding: Binding<Bool> {
        Binding(get: { self.takesWalks },
                set: { self.store?.state.notchBuddy.walkabout = $0 })
    }

    /// About how many minutes between walks — the card's "Time between
    /// walks". Right on the dial is longer between walks, so rarer.
    var walkEvery: Double {
        NotchBuddySettings.clampedWalkEvery(store?.state.notchBuddy.walkEvery
                                            ?? NotchBuddySettings.defaultWalkEvery)
    }
    var walkEveryBinding: Binding<Double> {
        Binding(get: { self.walkEvery },
                set: {
                    let minutes = NotchBuddySettings.clampedWalkEvery($0.rounded())
                    guard minutes != self.store?.state.notchBuddy.walkEvery else { return }
                    self.store?.state.notchBuddy.walkEvery = minutes
                })
    }

    /// Which way it is heading while strolling along an edge (+1 right,
    /// -1 left); nil the rest of the time. This is the target: the figure
    /// eases toward it through `turn`, so a change never flips the lean
    /// or the eyes in one frame. The free panel sets it at each leg,
    /// never per frame, through `setStrollHeading`.
    private(set) var strollHeading: Double?
    /// The eased turn toward `strollHeading`. Untracked: the view's own
    /// timeline draws it every frame, and a change keeps that timeline
    /// at full rate (`stayLively`).
    @ObservationIgnored private(set) var turn = BuddyTurn()

    /// A new heading to walk (nil: back to the mood's own patrol). The
    /// turn starts from wherever the figure is drawn now.
    func setStrollHeading(_ heading: Double?, at now: Date = Date()) {
        guard heading != strollHeading else { return }
        strollHeading = heading
        let still = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        if turn.retarget(heading, at: now, still: still) { stayLively(from: now) }
    }

    /// The turn as drawn at `now`, or nil while the figure is simply in
    /// its mood's own patrol.
    func turnFrame(at now: Date, still: Bool) -> BuddyTurn.Frame? {
        turn.isResting(at: now) ? nil : turn.frame(at: now, still: still)
    }

    /// Where the buddy is in life, from the crumbs it has eaten.
    var stage: BuddyStage {
        BuddyStage.of(crumbs: store?.state.notchBuddy.care.crumbsEaten ?? 0)
    }

    /// Frames the notch (or floating) buddy actually drew — its view's
    /// timeline ticks it; the card's roster strip doesn't.
    @ObservationIgnored let meter = ToyMeter()

    func cost(at now: TimeInterval) -> String? {
        guard store?.state.notchBuddy.enabled == true else { return nil }
        let drawing = meter.drawing(at: now) ?? "Not drawing right now"
        return "\(drawing) · 30 while agents work, \(Int(Self.restingFPS)) at rest, none when covered"
    }

    var controls: AnyView {
        AnyView(BuddyControlsView(toy: self))
    }

    /// The roster pick, resolved through the settings' fallback — a file
    /// from a newer build keeps its string and reads as Dot here.
    var buddyCharacter: BuddyCharacter {
        store?.state.notchBuddy.resolvedCharacter ?? .dot
    }

    /// A binding into `store.state.notchBuddy.character` as the enum;
    /// the file keeps the raw string.
    var characterBinding: Binding<BuddyCharacter> {
        Binding(get: { self.buddyCharacter },
                set: { self.store?.state.notchBuddy.character = $0.rawValue })
    }

    /// Mini is the same toy without the body: `presentation` stores the
    /// raw word so a newer build's mode survives this one.
    var miniMode: Bool { store?.state.notchBuddy.miniMode ?? false }
    var presentationBinding: Binding<Bool> {
        Binding(get: { self.miniMode },
                set: { self.store?.state.notchBuddy.presentation = $0 ? "mini" : "character" })
    }

    /// Whether the slot's face is the bare status dot rather than the
    /// character: only the card's Mini presentation. A published
    /// `screen_bar` program used to claim the docked slot too, lighting
    /// the dot as an extra LED at the band's centre seam — a second
    /// light beside the one unsegmented Screen Bar. The docked character
    /// now stays and wears the band's colour instead (`seamTint`).
    var showsDot: Bool { miniMode }

    /// Whether the docked buddy wears the Screen Bar's colour while a
    /// program is published. On by default; the card can turn it off.
    var wearsStripColor: Bool { store?.state.notchBuddy.wearsStripColor ?? true }
    var wearsStripColorBinding: Binding<Bool> {
        Binding(get: { self.wearsStripColor },
                set: { self.store?.state.notchBuddy.wearsStripColor = $0 })
    }

    /// The colour the docked buddy wears: the band's centre seam at its
    /// brightest instant, normalized to full strength — a steady hue
    /// that follows the published program, never its pulse. Worn, not
    /// lit: the buddy is a creature dressed in the band's colour, not a
    /// lamp keeping time with it. nil while nothing is published, the
    /// program is dark at the seam, or the card turned it off.
    func seamTint(at epoch: TimeInterval = Date().timeIntervalSince1970) -> RGB? {
        guard wearsStripColor, let peak = stripDot(at: epoch, still: true) else { return nil }
        return Self.wornHue(peak)
    }

    /// A sampled seam colour as a hue to wear: scaled so its brightest
    /// channel is full, or nil when the seam is too dark to name a
    /// colour at all.
    static func wornHue(_ sample: RGB) -> RGB? {
        let level = sample.maxChannel
        guard level > 0.05 else { return nil }
        return RGB(r: sample.r / level, g: sample.g / level, b: sample.b / level)
    }

    /// The card's name field writes straight into the settings blob;
    /// blank keeps the character's own `defaultName`.
    var nameBinding: Binding<String> {
        Binding(get: { self.store?.state.notchBuddy.buddyName ?? "" },
                set: { self.store?.state.notchBuddy.buddyName = $0 })
    }

    /// Who the status line and the accessibility label name.
    var buddyName: String {
        store?.state.notchBuddy.resolvedName ?? buddyCharacter.defaultName
    }

    /// The Size readout: "1×", "1.25×", "2.5×" — every stop the slider
    /// has, spelled exactly.
    static func sizeWords(_ scale: Double) -> String {
        NotchBuddySettings.clampedScale(scale)
            .formatted(.number.precision(.fractionLength(0...2)).locale(Locale(identifier: "en_US_POSIX")))
            + "×"
    }

    /// The walk dial's readout: "12 min".
    static func walkWords(_ minutes: Double) -> String {
        "\(Int(NotchBuddySettings.clampedWalkEvery(minutes).rounded())) min"
    }

    // MARK: Roaming

    /// Docked under the notch, or parked where the user dropped it.
    var freeSpot: BuddySpot? { store?.state.notchBuddy.freePosition }
    var isFree: Bool { freeSpot != nil }
    /// Tucked away: off the screen until the next session event (the
    /// session observer clears it) or `isOn` flips back on.
    var isTucked: Bool { store?.state.notchBuddy.tucked ?? false }
    /// The one-line caption under the buddy while the pointer is on it,
    /// docked or floating.
    var showsCaption: Bool { store?.state.notchBuddy.showCaption ?? true }
    var showsCaptionBinding: Binding<Bool> {
        Binding(get: { self.showsCaption },
                set: { if $0 != self.showsCaption { self.toggleCaption() } })
    }

    /// The free-floating buddy's size multiplier — the card's Size
    /// slider. Docked ignores it: the notch slot is fixed at 18pt.
    var buddyScale: Double {
        NotchBuddySettings.clampedScale(store?.state.notchBuddy.scale ?? 1.0)
    }

    /// The card's Size slider. Writes re-lay the panels immediately so
    /// the floating pet grows under the thumb, not after a relaunch.
    var scaleBinding: Binding<Double> {
        Binding(get: { self.buddyScale },
                set: {
                    self.store?.state.notchBuddy.scale = NotchBuddySettings.clampedScale($0)
                    self.onVisibilityChange?()
                })
    }

    /// Where a drop landed it — the HUD moves it to the free panel.
    /// Leaving the notch is a hand-off: the free panel takes over in
    /// place (`takeHandoff`), so the pet doesn't blink out and back.
    /// `figureCentre` is where the docked figure was drawn, in screen
    /// points, when the caller knows it.
    func parkFree(at point: CGPoint, figureCentre: CGPoint? = nil, now: Date = Date()) {
        if !isFree, isOn { pendingHandoff = (now, figureCentre) }
        store?.state.notchBuddy.freePosition = BuddySpot(point)
        onVisibilityChange?()
    }

    // MARK: Arriving

    /// A docked-to-floating hand-off waiting for the free panel: when it
    /// was asked for and where the docked figure stood.
    @ObservationIgnored private var pendingHandoff: (at: Date, figureCentre: CGPoint?)?
    /// The arrival the figure is drawing, if any (`BuddyArrival`).
    @ObservationIgnored private var arrivalStart: (fromScale: Double, fromOpacity: Double, drift: CGSize, at: Date)?
    /// How long a hand-off waits for the free panel to claim it.
    static let handoffWindow: TimeInterval = 1
    /// Back from a nap, it pops up from this share of its size.
    static let wakeScale: Double = 0.55

    /// The free panel claims a fresh hand-off, once: nil when there is
    /// none, or it went stale.
    func takeHandoff(at now: Date = Date()) -> (at: Date, figureCentre: CGPoint?)? {
        defer { pendingHandoff = nil }
        guard let waiting = pendingHandoff,
              now.timeIntervalSince(waiting.at) < Self.handoffWindow else { return nil }
        return waiting
    }

    /// Grow in from `fromScale` of its size and brighten from
    /// `fromOpacity`, drifting in by `drift` (screen points, SwiftUI's
    /// y-down) over `BuddyArrival.duration`.
    func arrive(fromScale: Double, fromOpacity: Double = 1, drift: CGSize = .zero, at now: Date = Date()) {
        guard !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else { arrivalStart = nil; return }
        arrivalStart = (fromScale, fromOpacity, drift, now)
        stayLively(from: now)
    }

    /// The arrival as drawn at `now`, or nil once it has landed.
    func arrival(at now: Date) -> BuddyArrival? {
        guard let start = arrivalStart else { return nil }
        let drawn = BuddyArrival(fromScale: start.fromScale, drift: start.drift,
                                 age: now.timeIntervalSince(start.at), fromOpacity: start.fromOpacity)
        return drawn.isOver ? nil : drawn
    }

    /// Back under the notch — the menu's "Dock at the notch" and a drop
    /// on the slot both land here.
    func dock() {
        store?.state.notchBuddy.freePosition = nil
        onVisibilityChange?()
    }

    /// The undock with no drop point — the card's button parks it at the
    /// dock slot, where it can be dragged away from.
    func floatFree() {
        let fallback = NSScreen.main.map {
            CGPoint(x: $0.visibleFrame.midX, y: $0.visibleFrame.maxY - 60)
        }
        parkFree(at: dockPointProvider?() ?? fallback ?? CGPoint(x: 400, y: 700))
    }

    /// "Tuck away": hidden until the next thing happening or a card
    /// re-enable. The roster stays — it is a nap, not a farewell. The
    /// snapshot counts workers too: a tucked buddy should wake on
    /// sub-agent churn, not only on mains. It is tucked from this call
    /// on, but it ducks out over `tuckDuration` before its panel goes
    /// (straight up under the notch when docked, down to its feet when
    /// floating) rather than vanishing in one frame; Reduce Motion, or a
    /// buddy that wasn't showing, goes at once.
    /// Whether the Mac asks for less motion; a duck-out is skipped then.
    /// Tests pin it, since a CI runner may have it on.
    var reduceMotion: () -> Bool = { NSWorkspace.shared.accessibilityDisplayShouldReduceMotion }

    func tuckAway(at now: Date = Date()) {
        let showing = isOn
        wakeSnapshot = Self.sessionSnapshot(core.state?.sessions ?? [])
        store?.state.notchBuddy.tucked = true
        guard showing, !reduceMotion() else {
            finishTuck()
            return
        }
        tuckingSince = now
        stayLively(from: now)
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated { self?.finishTuck() }
        }
        tuckWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.tuckDuration, execute: work)
    }

    /// The duck-out has played: the panels let it go.
    func finishTuck() {
        cancelTuck()
        onVisibilityChange?()
    }

    /// A duck-out in flight is called off (a card toggle, a wake, the
    /// end of the duck-out itself).
    private func cancelTuck() {
        tuckWork?.cancel()
        tuckWork = nil
        tuckingSince = nil
    }

    /// When the duck-out began; nil unless one is playing.
    private(set) var tuckingSince: Date?
    @ObservationIgnored private var tuckWork: DispatchWorkItem?
    static let tuckDuration: TimeInterval = 0.26

    /// Whether a home should draw it: on, or still ducking out of sight.
    var isShowing: Bool {
        isOn || (tuckingSince != nil && store?.state.notchBuddy.enabled == true)
    }

    /// Where it comes back from: `wakeScale` after a real nap, or
    /// wherever a duck-out still in flight had got to, its size and its
    /// fade both, so a wake mid-duck grows and brightens back from there
    /// instead of snapping.
    private func comeBack(at now: Date = Date()) -> (scale: Double, opacity: Double) {
        guard let tuck = tuckProgress(at: now) else { return (Self.wakeScale, 1) }
        return (Self.tuckScale(tuck), Self.tuckOpacity(tuck))
    }

    /// The duck-out's size at `progress`: an ease-in down to a quarter.
    static func tuckScale(_ progress: Double) -> Double {
        1 - 0.75 * progress * progress
    }

    /// The duck-out's fade at `progress`: an ease-in to nothing.
    static func tuckOpacity(_ progress: Double) -> Double {
        1 - progress * progress
    }

    /// 0 → 1 across the duck-out; nil unless one is playing.
    func tuckProgress(at now: Date) -> Double? {
        guard let tuckingSince else { return nil }
        return min(1, max(0, now.timeIntervalSince(tuckingSince) / Self.tuckDuration))
    }

    func toggleCaption() {
        store?.state.notchBuddy.showCaption.toggle()
        onVisibilityChange?()
    }

    /// The floating caption: the session it is watching, or just its
    /// name tag while nothing is on the clock.
    func caption(at now: Date = Date()) -> String {
        summary(at: now).focus?.line ?? buddyName
    }

    // MARK: Drag

    /// The carry's life, panel-side bookkeeping the view reads: held,
    /// it leans toward the travel direction (`dragTilt`, settling via
    /// `dragMovedAt`) with its feet up (`carryLift`); put down,
    /// `landedAt` plays a small squash and lets go of whatever lean and
    /// lift it still had (`landingTilt`, `landingLift`). Reduce Motion
    /// ignores all of it.
    private(set) var isDragged = false
    private(set) var dragTilt: Double = 0
    private(set) var dragMovedAt: Date?
    private(set) var landedAt: Date?
    /// The lean it had the moment it was put down; the landing eases it
    /// upright instead of snapping.
    private(set) var landingTilt: Double = 0
    /// When the carry began, and the lift drawn at that moment (a
    /// landing still settling); the pick-up eases up from there.
    private(set) var dragStartedAt: Date?
    private(set) var pickUpLift: Double = 0
    /// The lift it had the moment it was put down; the landing eases it
    /// back onto its feet.
    private(set) var landingLift: Double = 0

    /// How far a carry lifts it off its feet, in the figure's points
    /// (SwiftUI's y-down), and how long the pick-up and the landing take.
    /// At the floating buddy's 3× the lift is 5.4 pt, too far for a frame.
    static let carryHeight: Double = -1.8
    static let pickUpTime: TimeInterval = 0.12
    static let landingTime: TimeInterval = 0.34

    /// The carry's lift at `now`: easing up off its feet over
    /// `pickUpTime`, held while carried, and easing back down over the
    /// landing.
    func carryLift(at now: Date) -> Double {
        if isDragged {
            let age = now.timeIntervalSince(dragStartedAt ?? now)
            return pickUpLift + (Self.carryHeight - pickUpLift) * BuddyTurn.smooth(age / Self.pickUpTime)
        }
        guard let landedAt else { return 0 }
        let age = max(0, now.timeIntervalSince(landedAt))
        guard age < Self.landingTime else { return 0 }
        return landingLift * (1 - BuddyTurn.smooth(age / Self.landingTime))
    }

    func dragStarted(at now: Date = Date()) {
        pickUpLift = carryLift(at: now)
        isDragged = true
        dragStartedAt = now
        dragTilt = 0
        dragMovedAt = nil
        landedAt = nil
        landingTilt = 0
        landingLift = 0
    }

    /// `dx` is this event's horizontal travel, not the total. The lean
    /// heads toward that event's tilt on a short lag (`BuddyTurn.follow`)
    /// from what is drawn now, so a change of direction swings it
    /// through upright rather than flipping it.
    func dragMoved(dx: Double, at now: Date = Date()) {
        guard isDragged else { return }
        let dt = dragMovedAt.map { now.timeIntervalSince($0) } ?? Self.firstMoveStep
        dragTilt = BuddyTurn.follow(dangle(at: now), toward: BuddyPlacement.dragTilt(dx: dx), dt: dt)
        dragMovedAt = now
    }

    /// The first event of a carry has no event before it: it counts as
    /// one display frame's worth of travel.
    static let firstMoveStep: TimeInterval = 1.0 / 60.0
    /// How long the cursor can sit between mouse events before the
    /// dangle starts to settle.
    static let parkGrace: TimeInterval = 0.05

    /// The dangle as drawn at `now`: the followed tilt, settling on
    /// `BuddyPlacement.tiltDecay` once the cursor has parked for longer
    /// than a mouse event's gap.
    func dangle(at now: Date) -> Double {
        let parked = now.timeIntervalSince(dragMovedAt ?? now) - Self.parkGrace
        return dragTilt * BuddyPlacement.tiltDecay(age: max(0, parked))
    }

    /// Put down — the landing beat plays from `landedAt`.
    func dragEnded(at now: Date = Date()) {
        landingTilt = dangle(at: now)
        landingLift = carryLift(at: now)
        isDragged = false
        dragTilt = 0
        landedAt = now
        stayLively(from: now)
    }

    /// The carry was cut short (a toast took the panel): back to rest,
    /// no landing beat.
    func dragCancelled() {
        isDragged = false
        dragTilt = 0
        landingTilt = 0
        landingLift = 0
    }

    // MARK: Interaction

    /// The longest-waiting ask — the tap-to-open pick and the menu's
    /// "Open". An embedded ask with no `openedAt` sorts as never-opened
    /// and lands last.
    var askingSession: CoreSession? {
        core.sessions
            .filter { SessionActivity.reduce($0) == .waiting }
            .min(by: { ($0.ask?.openedAt ?? .infinity) < ($1.ask?.openedAt ?? .infinity) })
    }

    /// While an ask is open the buddy is useful: this opens the session
    /// doing the asking — that is where the answer lives — through the
    /// one opener, so a window the daemon cannot find still comes up
    /// through the Dock's locator. The buddy has no line of its own to
    /// say a refusal in; the notch's ask face and the panel carry it.
    @discardableResult
    func openAskingSession() -> Bool {
        guard let asking = askingSession else { return false }
        let open = openSession
        openInFlight = Task { _ = await open(asking.id) }
        return true
    }

    /// The one way the buddy opens a session (`SessionOpener`); tests
    /// swap it and await `openInFlight`.
    @ObservationIgnored var openSession: @MainActor (String) async -> String? = { id in
        await SessionOpener.open(id)
    }
    @ObservationIgnored private(set) var openInFlight: Task<Void, Never>?

    /// The "!" badge hangs over the figure's crown: in the pill's
    /// unscaled layout (36×30 — the 18pt figure plus its padding) it
    /// lives in the top-centre band. A tap that lands there is the ask's
    /// shortcut; anywhere else is just a pat.
    static func askBadgeZone(scale: Double) -> CGRect {
        CGRect(x: 10 * scale, y: 0, width: 16 * scale, height: 15 * scale)
    }

    /// A tap on the buddy. Always a pet; unless Reduce Motion is on it
    /// also cycles a trick. While an ask is open a tap that lands on the
    /// "!" badge opens the session doing the asking — any other tap is
    /// only a pat, so petting can't hijack the front app mid-ask. (The
    /// held-press menu's "Open" row still opens it too.)
    func tapped(at now: Date = Date(), point: CGPoint? = nil, scale: Double = 1) {
        store?.state.notchBuddy.care.pet(at: now)
        if !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
            trickKind = BuddyTrick.Kind.allCases[trickOrdinal % BuddyTrick.Kind.allCases.count]
            trickOrdinal += 1
            trickStartedAt = now
            stayLively(from: now)
        }
        if let point, askingSession != nil,
           Self.askBadgeZone(scale: scale).contains(point) {
            openAskingSession()
        }
    }

    /// The card's "Give treat": fed for a while, hearts off the crown,
    /// and the hop borrowed from completions when motion is allowed.
    func giveTreat(at now: Date = Date()) {
        store?.state.notchBuddy.care.feed(at: now)
        treatBurstAt = now
        stayLively(from: now)
        if !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
            hopUntil = now.addingTimeInterval(1.1)
        }
    }

    /// The card's friendship line under the treat button.
    var careLine: String {
        guard let care = store?.state.notchBuddy.care else { return "" }
        let pets = care.petCount == 1 ? "1 pet" : "\(care.petCount) pets"
        let crumbs = care.crumbsEaten == 1 ? "1 crumb" : "\(care.crumbsEaten) crumbs"
        switch care.mood(at: Date()) {
        case .fed: return "Blissed out — \(pets), \(crumbs)"
        case .missing: return "Misses you — \(pets), \(crumbs)"
        case .content:
            if care.petCount == 0, care.crumbsEaten == 0 {
                return "Never petted. It doesn't mind yet."
            }
            return "\(pets) · \(crumbs)"
        }
    }

    // MARK: Mood

    /// What the buddy is doing, in `SessionActivity`'s precedence: a live
    /// ask outranks a failure, a failure outranks work, work outranks
    /// sleep. Three or more working sessions is a `gathering`, not a
    /// patrol. A completion hops once and then the mood falls back.
    enum Mood: String, Sendable {
        case asleep, pacing, gathering, waving, slumped, celebrating
    }

    /// Everything the HUD reads off the session list in one tick — the
    /// pose, the badge counts, the tints and the hover line — built from
    /// one cached `SessionDigest`, so the pieces can never disagree with
    /// each other and a tick never walks the session list.
    struct BuddySummary {
        /// The pose: a live ask outranks a failure, a failure outranks
        /// work, work outranks sleep; three or more working is a
        /// `gathering`, and a completion's hop overrides it all.
        var mood = Mood.asleep
        /// Sessions doing work — the feet badge's number once it's plural.
        var working = 0
        /// Asks open right now — the "!" wears the count past one.
        var waiting = 0
        /// Failed runs in the list — the slump and the "failed" count.
        var failed = 0
        /// The provider running the most working sessions — the badge's
        /// tint. A split house still answers, and the tie breaks on the
        /// provider id so the pick can't flicker between ticks.
        var dominantProvider: String?
        /// The one provider running all the work, nil when two or more
        /// share it — the pacing tint falls back to the accent there.
        /// Ask, failed and hop keep their own colours regardless.
        var workingProvider: String?
        /// The provider display names on the clock, in session order —
        /// the hover line's tail.
        var providers: [String] = []
        /// What the buddy is called — the status line's subject.
        var name = ""
        /// How the friendship is doing — the pose's droop or blush.
        var care: BuddyCare.Mood = .content
        /// The one session it is watching — the "what is it doing" the
        /// status line's tail and the floating caption both read.
        var focus: BuddyFocus?
        /// The hover line: "Pixel is watching · 3 working · Claude ·
        /// rename-the-fish — waiting on you" — the name first, then
        /// who's on the clock, then what it's doing.
        var statusLine = ""
    }

    /// What the session list says, reduced once per change rather than
    /// once per frame: the counts, the tints and the focus pick. The
    /// view ticks up to 30 times a second and the list moves a few times
    /// a minute, so the frame only pays for the parts that age with the
    /// clock — the hop, the care mood, the wave and slump clocks.
    struct SessionDigest: Equatable {
        var working = 0
        var waiting = 0
        var failed = 0
        var dominantProvider: String?
        var workingProvider: String?
        var providers: [String] = []
        var focus: BuddyFocus?

        /// Anything on the clock — work, an ask, a failure to own up to.
        /// Nothing is asleep, and asleep only breathes.
        var isAwake: Bool { working + waiting + failed > 0 }
    }

    /// One pass over the sessions: the counts, the tints and the focus
    /// all fall out of the same `SessionActivity.reduce` calls. Pure, so
    /// the tests can pin it without a document.
    static func digest(of sessions: [CoreSession]) -> SessionDigest {
        var d = SessionDigest()
        var tally: [String: Int] = [:]
        var soleProvider: String?
        var splitWork = false
        for session in sessions {
            let activity = SessionActivity.reduce(session)
            switch activity {
            case .working:
                d.working += 1
                tally[session.provider, default: 0] += 1
                if let soleProvider, soleProvider != session.provider {
                    splitWork = true
                } else if soleProvider == nil {
                    soleProvider = session.provider
                }
            case .waiting: d.waiting += 1
            case .failed: d.failed += 1
            case .done, .ended, .idle: break
            }
            switch activity {
            case .working, .waiting, .failed:
                let name = ProviderStyle.style(for: session.provider).name
                if !d.providers.contains(name) { d.providers.append(name) }
            case .done, .ended, .idle: break
            }
        }
        d.dominantProvider = tally.max { ($0.value, $0.key) < ($1.value, $1.key) }?.key
        d.workingProvider = splitWork ? nil : soleProvider
        d.focus = BuddyFocus.pick(from: sessions)
        return d
    }

    /// The last digest and whether a newer document has landed since.
    /// The flag is set from the observation's `onChange`, which fires
    /// inside `core.state`'s willSet — synchronously, so a summary read
    /// right after a document (the tests do exactly that) can never see
    /// the old list. A lock because `onChange` is `@Sendable`.
    @ObservationIgnored private var cachedDigest = SessionDigest()
    @ObservationIgnored private let digestStale = OSAllocatedUnfairLock(initialState: true)
    /// Bumped after every document the digest has followed, outside any
    /// render — the observable edge a view that only read the cache
    /// re-renders on. The floating caption rides a 15 s timeline and
    /// would otherwise sit on a stale name until its next tick.
    private(set) var digestVersion = 0

    /// The digest for this frame: the cache, or a fresh pass when a new
    /// document landed. The pass re-arms the one-shot observation.
    func sessionDigest() -> SessionDigest {
        _ = digestVersion
        if digestStale.withLock({ $0 }) { refreshDigest() }
        return cachedDigest
    }

    private func refreshDigest() {
        digestStale.withLock { $0 = false }
        let stale = digestStale
        cachedDigest = withObservationTracking {
            let sessions = core.sessions
            tempo.note(sessions: sessions, now: Date())
            return Self.digest(of: sessions)
        } onChange: { [weak self] in
            stale.withLock { $0 = true }
            // The re-read waits for the hop: onChange runs in the
            // property's willSet, before the new document is stored.
            Task { @MainActor [weak self] in self?.followDocument() }
        }
    }

    /// A new document landed: re-read it and tell the views. A render
    /// may already have re-read it lazily — then this only bumps.
    /// Falling asleep holds the full frame rate for a beat: with nothing
    /// awake the timeline drops to its resting rate, which would draw the
    /// mood's handoff (the patrol, an ask or a slump settling into sleep)
    /// in a frame or two. A completion's hop already holds it; an ask
    /// closing, a failure clearing or a run going idle did not.
    private func followDocument() {
        let awake = sessionDigest().isAwake
        if followedAwake, !awake { stayLively() }
        followedAwake = awake
        digestVersion &+= 1
    }

    /// Whether the last document followed had anything awake in it.
    @ObservationIgnored private var followedAwake = false

    // MARK: Tempo

    /// How hard the agents are working the tools right now — RunCat's
    /// living meter, from real data: each hook event bumps a working
    /// session's `updated_at`, and the rate of those bumps sets the walk.
    @ObservationIgnored private(set) var tempo = BuddyTempo()
    /// The walk's own clock: seconds of stride, advanced at the tempo's
    /// cadence so a change of pace speeds the legs up without jumping
    /// the pose. Maintained by `walkPhase(at:)`, like `wavingSince`.
    @ObservationIgnored private var walkClock: (phase: TimeInterval, at: Date, cadence: Double)?

    /// The pacing and gathering poses' clock at `now`: a sprint while
    /// the tools are hammered, a stroll while the agents think. The
    /// cadence eases toward its target over about a second.
    func walkPhase(at now: Date) -> TimeInterval {
        let target = BuddyTempo.cadence(rate: tempo.rate(at: now))
        guard let clock = walkClock else {
            walkClock = (now.timeIntervalSince1970, now, target)
            return now.timeIntervalSince1970
        }
        let dt = min(0.25, max(0, now.timeIntervalSince(clock.at)))
        let cadence = clock.cadence + (target - clock.cadence) * min(1, dt / 0.9)
        let phase = clock.phase + dt * cadence
        walkClock = (phase, now, cadence)
        return phase
    }

    // MARK: Frame pacing

    /// A one-shot beat — a hop, a trick, the treat's hearts, a crumb, a
    /// landing — holds the timeline at the full rate until this passes.
    /// Every one of them is over inside 1.1 s; the window pads it so the
    /// last frame of the beat is never the slow one.
    private(set) var livelyUntil: Date?
    @ObservationIgnored private var livelyWork: DispatchWorkItem?
    static let livelyWindow: TimeInterval = 1.4

    private func stayLively(from now: Date = Date()) {
        let end = now.addingTimeInterval(Self.livelyWindow)
        if let current = livelyUntil, current >= end { return }
        livelyUntil = end
        livelyWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.livelyWork = nil
                self.livelyUntil = nil
            }
        }
        livelyWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + max(0.05, end.timeIntervalSinceNow),
                                      execute: work)
    }

    /// The frame budget: 30 a second while anything moves, a slow
    /// breath's worth while nothing does. Asleep, the buddy only
    /// breathes and drifts its "z"s — 2 pt in a second at the notch's
    /// 18 pt — so about four frames a second draws the same picture a
    /// display-rate timeline did. A bigger floating buddy travels more
    /// points per frame, so its resting rate grows with its size.
    static let activeInterval: TimeInterval = 1.0 / 30.0
    static let restingFPS: Double = 4

    static func frameInterval(awake: Bool, lively: Bool, dragged: Bool, scale: Double) -> TimeInterval {
        if awake || lively || dragged { return activeInterval }
        let fps = restingFPS * max(1, min(3, scale.isFinite ? scale : 1))
        return 1.0 / fps
    }

    /// The live interval the view's timeline asks for. Observable reads
    /// only, so the schedule changes the moment the fleet wakes, a beat
    /// starts or ends, or a carry begins.
    func frameInterval(scale: Double) -> TimeInterval {
        Self.frameInterval(awake: sessionDigest().isAwake, lively: livelyUntil != nil,
                           dragged: isDragged, scale: scale)
    }

    /// The summary for one frame: the cached digest plus everything that
    /// ages with the clock. Also maintains the wave & slump clocks the
    /// one-off effects play from — the view's tick is the only clock
    /// that drives them.
    func summary(at now: Date = Date()) -> BuddySummary {
        // Several readers ask — the animation timeline, the floating
        // caption's slow one, the hover line — and a slow timeline's
        // date can be seconds behind. Every reader is answered at the
        // latest time any of them has seen, so a stale one can neither
        // start an ask's entrance in the past and skip it, nor call a
        // hop that already landed back for a frame. The one thing that
        // outruns that rule is the wall clock itself being set back.
        followClockStep()
        let stamp = max(now, latestSummaryAt ?? now)
        latestSummaryAt = stamp
        let d = sessionDigest()
        var s = BuddySummary()
        s.working = d.working
        s.waiting = d.waiting
        s.failed = d.failed
        s.dominantProvider = d.dominantProvider
        s.workingProvider = d.workingProvider
        s.providers = d.providers
        if s.waiting > 0 { s.mood = .waving }
        else if s.failed > 0 { s.mood = .slumped }
        // Three or more working at once: busy is exciting, not calm.
        else if s.working >= 3 { s.mood = .gathering }
        else if s.working > 0 { s.mood = .pacing }
        // Goodnight: the lid on its way down puts the nightcap on,
        // whatever the fleet is up to — unless something asks or failed.
        if s.mood == .pacing || s.mood == .gathering, store?.lidClosing(at: stamp) == true {
            s.mood = .asleep
        }
        if let hopUntil, stamp < hopUntil { s.mood = .celebrating }
        if s.mood == .waving {
            if wavingSince == nil { wavingSince = stamp; waveOrdinal += 1 }
        } else if wavingSince != nil {
            wavingSince = nil
        }
        if s.mood == .slumped {
            if slumpedSince == nil { slumpedSince = stamp }
        } else if slumpedSince != nil {
            slumpedSince = nil
        }
        if let shown = shownMood, shown != s.mood {
            // Part-way through the last change, the pose it leaves is the
            // blend drawn right now, not the old mood whole; a quick
            // flicker between two moods carries on from where it is.
            let leaving = handoff(at: stamp)?.shares(into: shown) ?? [:]
            moodChange = (shown, leaving, stamp)
        }
        shownMood = s.mood
        s.care = store?.state.notchBuddy.care.mood(at: stamp) ?? .content
        s.name = buddyName
        s.focus = d.focus
        var parts: [String] = []
        if s.working > 0 { parts.append("\(s.working) working") }
        if s.waiting > 0 { parts.append("\(s.waiting) waiting") }
        if s.failed > 0 { parts.append("\(s.failed) failed") }
        if parts.isEmpty {
            s.statusLine = s.care == .missing
                ? "\(s.name) misses you — tap it to say hi."
                : "\(s.name) is asleep."
        } else {
            var line = "\(s.name) is watching · " + parts.joined(separator: " · ")
            // The glance answers what it is doing, not just how many:
            // the focus names the one session that matters; the
            // providers tail only earns its place when the clock is
            // split across two or more — a lone provider is already
            // named inside the focus line.
            if s.providers.count > 1 { line += " · " + s.providers.joined(separator: ", ") }
            if let focus = s.focus { line += " · \(focus.line)" }
            if s.care == .missing { line += " · misses you" }
            s.statusLine = line
        }
        return s
    }

    /// The mood the last summary settled on, and the last change: the
    /// figure eases from the old mood's pose (or the blend it was part-way
    /// through, `blend`) into the new one's over `BuddyHandoff.duration`
    /// (`handoff(at:)`). Untracked, like the wave clock: `summary`
    /// maintains them mid-render.
    @ObservationIgnored private var shownMood: Mood?
    @ObservationIgnored private(set) var moodChange: (from: Mood, blend: [Mood: Double], at: Date)?
    /// The latest time any summary was taken at.
    @ObservationIgnored private var latestSummaryAt: Date?
    /// The wall clock the mood's clocks are checked against; tests set it
    /// to step the clock back.
    @ObservationIgnored var wallClock: @MainActor () -> Date = { Date() }
    /// How far ahead of the wall clock the latest reading may run before
    /// it counts as the clock having been set back. A reader runs ahead
    /// of the real time by a frame at most, and a stale one only trails
    /// it, so a lead past this is the clock, not a reader.
    static let clockStepSlack: TimeInterval = 20

    /// The wall clock was set back (by hand, or a time sync after a long
    /// sleep): the latest reading and the mood's clocks move back with it.
    /// Otherwise every reader would be answered at a time still in the
    /// future, an ask's entrance would hold at its first frame and a mood
    /// change would show the old pose until real time caught up.
    private func followClockStep() {
        guard let latest = latestSummaryAt else { return }
        let step = wallClock().timeIntervalSince(latest)
        guard step < -Self.clockStepSlack else { return }
        latestSummaryAt = latest.addingTimeInterval(step)
        wavingSince = wavingSince?.addingTimeInterval(step)
        slumpedSince = slumpedSince?.addingTimeInterval(step)
        if let change = moodChange {
            moodChange = (change.from, change.blend, change.at.addingTimeInterval(step))
        }
    }

    /// The mood change as drawn at `now`, or nil once it has handed off.
    /// Like the summary it is answered at the latest time any reader has
    /// seen, so its age is never negative: a reader a frame behind can't
    /// hold the old pose.
    func handoff(at now: Date) -> BuddyHandoff? {
        guard let change = moodChange else { return nil }
        let at = max(now, latestSummaryAt ?? now)
        let drawn = BuddyHandoff(from: change.from, age: at.timeIntervalSince(change.at),
                                 blend: change.blend)
        return drawn.isOver ? nil : drawn
    }

    // MARK: Strip link

    /// The band's centre seam, sampled from the published `screen_bar`
    /// program — the same program text the band compiles and the
    /// hardware plays, on the daemon's anchor, so a sample can never run
    /// ahead of the band or read inverted. The docked buddy wears its
    /// still frame (`seamTint`); the live sample stays for anything
    /// that needs the seam's phase. nil means nothing is published. The
    /// cache is keyed on the program text, so a republished program pays
    /// for one parse, not one per frame.
    @ObservationIgnored private var stripCache:
        (key: String, sampler: LEDSSampler, firstSeen: TimeInterval, peak: RGB)?

    /// The seam colour at `epoch` — wall-clock seconds, the anchor's own
    /// domain, so no media-time conversion sits between the two. `still`
    /// returns the program's brightest seam instant instead — the same
    /// still frame the band holds under Reduce Motion, and the colour
    /// the docked buddy wears.
    func stripDot(at epoch: TimeInterval, still: Bool = false) -> RGB? {
        guard let surface = core.lights?.screenBar else { return nil }
        let text = surface.program
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        let ledCount = LEDSProgram.normalizedLedCount(surface.ledCount ?? ScreenBarGeometry.ledCount)
        let key = "\(ledCount)\u{1F}\(text)"
        if stripCache?.key != key {
            // The band's own acceptance rules: a program it would refuse
            // extends nothing rather than pulsing on rejected text.
            let decision = ScreenBarController.programDecision(
                text, fallback: LEDSPresentationCompiler.safeFallbackProgram)
            guard let program = decision.program else {
                stripCache = nil
                return nil
            }
            let sampler = LEDSSampler(program: program, ledCount: ledCount)
            stripCache = (key: key, sampler: sampler, firstSeen: epoch,
                          peak: Self.centrePeak(sampler: sampler, ledCount: ledCount))
        }
        guard let cache = stripCache else { return nil }
        if still { return cache.peak }
        // The anchor is the daemon's t=0 on the strip. A missing or
        // absurd one starts the program when we first saw it — the
        // band's own nil-anchor rule — and a same-program republish that
        // moved the anchor re-locks the dot on the next frame for free.
        var start = cache.firstSeen
        if let anchor = surface.anchor, anchor <= epoch + 0.05, epoch - anchor < 6 * 3600 {
            start = anchor
        }
        return Self.centreColor(sampler: cache.sampler,
                                at: max(0, epoch - start), ledCount: ledCount)
    }

    /// The brighter of the LEDs straddling the strip's middle — the seam
    /// the docked buddy sits under. Brightest, not averaged: the Dot
    /// role's own band rule, so a pulse's colour is read at full
    /// strength and a chase is caught as the wave crosses the notch.
    static func centreColor(sampler: LEDSSampler, at seconds: Double, ledCount: Int) -> RGB {
        let colors = sampler.colors(at: seconds)
        let mid = ledCount / 2
        let seam = ledCount % 2 == 0 ? [mid - 1, mid] : [mid]
        var best = RGB.black
        for index in seam where index >= 0 && index < colors.count {
            if colors[index].maxChannel > best.maxChannel { best = colors[index] }
        }
        return best
    }

    /// The seam's brightest instant across the program's first cycle —
    /// the frame Reduce Motion holds, probed the way the band's still
    /// frame probes.
    static func centrePeak(sampler: LEDSSampler, ledCount: Int) -> RGB {
        var best = centreColor(sampler: sampler, at: 0, ledCount: ledCount)
        let span = sampler.cycleDuration ?? sampler.motionEndsAt ?? 0
        if span > 0 {
            for step in 1..<12 {
                let color = centreColor(sampler: sampler, at: span * Double(step) / 12,
                                        ledCount: ledCount)
                if color.maxChannel > best.maxChannel { best = color }
            }
        }
        return best
    }

    // MARK: Menu

    /// The press-and-hold / right-click menu. `NSMenuItem.target` is
    /// weak, so the handler object lives on the toy and is re-aimed at
    /// every build — the menu itself only exists for the pop.
    @ObservationIgnored private let menuActions = BuddyMenuActions()
    @ObservationIgnored private var renamePanel: BuddyRenamePanel?
    @ObservationIgnored private var cardPanel: BuddyCardPanel?

    /// The pet menu: pet it, feed it, rename it, swap characters, open
    /// the asking session while one is up, dock or float it, toggle the
    /// caption, tuck it away. `panelFrame` is where the buddy sits when
    /// the menu opened, so "Float free" parks it in place.
    func actionMenu(panelFrame: NSRect?) -> NSMenu {
        menuActions.toy = self
        menuActions.panelFrame = panelFrame
        let menu = NSMenu()
        menu.addItem(menuActions.item(title: "Pet it", action: #selector(BuddyMenuActions.pet)))
        menu.addItem(menuActions.item(title: "Give treat", action: #selector(BuddyMenuActions.treat)))
        menu.addItem(menuActions.item(title: "Rename…", action: #selector(BuddyMenuActions.rename)))
        let roster = NSMenu()
        for character in BuddyCharacter.allCases {
            let item = menuActions.item(title: character.displayName,
                                        action: #selector(BuddyMenuActions.pickCharacter))
            item.representedObject = character.rawValue
            item.state = character == buddyCharacter ? .on : .off
            roster.addItem(item)
        }
        let rosterItem = NSMenuItem(title: "Change character", action: nil, keyEquivalent: "")
        rosterItem.submenu = roster
        menu.addItem(rosterItem)
        menu.addItem(menuActions.item(title: "About \(buddyName)…", action: #selector(BuddyMenuActions.about)))
        // Dress-up from the tank's purse: whatever the shop's buddy
        // shelf has sold, and a way back to nothing.
        let owned = ShopItem.allCases.filter {
            $0.category == .buddy && store?.aquarium?.game.owns($0) == true
        }
        if !owned.isEmpty {
            let wardrobe = NSMenu()
            let none = menuActions.item(title: "Nothing", action: #selector(BuddyMenuActions.wear(_:)))
            none.state = wearing == nil ? .on : .off
            wardrobe.addItem(none)
            for item in owned {
                let row = menuActions.item(title: item.displayName.replacingOccurrences(of: "Buddy ", with: "").capitalized,
                                           action: #selector(BuddyMenuActions.wear(_:)))
                row.representedObject = item.rawValue
                row.state = wearing == item ? .on : .off
                wardrobe.addItem(row)
            }
            let wardrobeItem = NSMenuItem(title: "Wear", action: nil, keyEquivalent: "")
            wardrobeItem.submenu = wardrobe
            menu.addItem(wardrobeItem)
        }
        // The tank's residents starve through a busy week with the
        // window shut — the buddy can drop a round in on its way past.
        if let aquarium = store?.aquarium, !aquarium.fish.isEmpty {
            menu.addItem(menuActions.item(title: "Feed the tank", action: #selector(BuddyMenuActions.feedTank)))
        }
        menu.addItem(.separator())
        if let asking = askingSession {
            let label = SessionLabel.display(label: asking.label, shortId: asking.shortId,
                                           id: asking.id, provider: asking.provider)
            menu.addItem(menuActions.item(title: "Open “\(label)”",
                                          action: #selector(BuddyMenuActions.openAsk)))
        }
        menu.addItem(menuActions.item(title: isFree ? "Dock at the notch" : "Float free",
                                      action: #selector(BuddyMenuActions.toggleDock)))
        let captionItem = menuActions.item(title: "Caption on hover",
                                           action: #selector(BuddyMenuActions.toggleCaption))
        captionItem.state = showsCaption ? .on : .off
        menu.addItem(captionItem)
        if isFree {
            let walkItem = menuActions.item(title: "Take walks",
                                            action: #selector(BuddyMenuActions.toggleWalkabout))
            walkItem.state = takesWalks ? .on : .off
            menu.addItem(walkItem)
        }
        menu.addItem(.separator())
        menu.addItem(menuActions.item(title: "Tuck away", action: #selector(BuddyMenuActions.tuck)))
        return menu
    }

    /// "Rename…" opens a small floating field under the pill; `frame` is
    /// where the buddy sits so the prompt lands next to it.
    func promptRename(near frame: NSRect?) {
        if renamePanel == nil { renamePanel = BuddyRenamePanel() }
        renamePanel?.present(near: frame, current: store?.state.notchBuddy.buddyName ?? "",
                             placeholder: buddyCharacter.defaultName) { [weak self] name in
            self?.nameBinding.wrappedValue = name
        }
    }

    /// "About Morel…": the pal card under the pill — the care log in a
    /// few lines, every one of them something that happened.
    func presentCard(near frame: NSRect?) {
        if cardPanel == nil { cardPanel = BuddyCardPanel() }
        let care = store?.state.notchBuddy.care ?? BuddyCare()
        cardPanel?.present(near: frame, character: buddyCharacter, name: buddyName,
                           card: BuddyPalCard.make(care: care))
    }

    /// Asks the buddy has watched open, by session: when each opened. A
    /// session that stops waiting closes its ask, and the longest one
    /// lands in the care log for the pal card.
    @ObservationIgnored private var openAsks: [String: Double] = [:]

    /// Follows the asks across documents. Only while enabled — a buddy
    /// that's off keeps no log.
    func noteAsks(_ sessions: [CoreSession], at now: Date = Date()) {
        guard store?.state.notchBuddy.enabled == true else {
            openAsks = [:]
            return
        }
        var still: [String: Double] = [:]
        for session in sessions where SessionActivity.reduce(session) == .waiting {
            still[session.id] = openAsks[session.id]
                ?? session.ask?.openedAt ?? now.timeIntervalSince1970
        }
        for (id, opened) in openAsks where still[id] == nil {
            store?.state.notchBuddy.care.noteAsk(lasted: now.timeIntervalSince1970 - opened)
        }
        openAsks = still
    }

    private static func sessionSnapshot(_ sessions: [CoreSession]) -> [String: SessionActivity] {
        Dictionary(sessions.map { ($0.id, SessionActivity.reduce($0)) },
                   uniquingKeysWith: { _, latest in latest })
    }

    /// The shared coordinator already observes state. Buddy only inspects
    /// it while tucked, to distinguish real activity changes from heartbeats.
    /// Historical state documents never earn completion crumbs.
    func noteState(_ state: CoreState) {
        noteAsks(state.sessions)
        guard store?.state.notchBuddy.enabled == true,
              store?.state.notchBuddy.tucked == true else {
            wakeSnapshot = nil
            return
        }
        // Workers included: sub-agent churn is activity too — a tucked
        // buddy that only watched mains would sleep through it.
        let snapshot = Self.sessionSnapshot(state.sessions)
        guard let previous = wakeSnapshot else { wakeSnapshot = snapshot; return }
        if previous != snapshot { wakeForActivity() }
    }

    /// CoreModel delivers each live event once. Disabled Buddy owns no
    /// session observer and neither animates nor changes its saved care.
    func noteEvent(_ event: CoreEvent, at now: Date = Date()) {
        guard store?.state.notchBuddy.enabled == true else { return }
        guard event.kind == "completed" || event.session != nil else { return }
        wakeForActivity()
        guard event.kind == "completed" else { return }
        // Hushed — JR-Bar quiet or a Focus (the Toys page's switch) —
        // the crumb still counts, but the hop stays put.
        if store?.hushReason(now: now) == nil {
            hopUntil = now.addingTimeInterval(1.1)
        }
        crumbAt = now
        stayLively(from: now)
        let provider = event.provider
            ?? event.session.flatMap { core.state?.session(withID: $0) }?.provider
        let before = stage
        store?.state.notchBuddy.care.eat(at: now, count: 1, provider: provider)
        // A crumb that grows it up: the hearts, once — unless hushed.
        if stage > before, store?.hushReason(now: now) == nil { treatBurstAt = now }
    }

    private func wakeForActivity() {
        guard store?.state.notchBuddy.tucked == true else { return }
        store?.state.notchBuddy.tucked = false
        wakeSnapshot = nil
        let from = comeBack()
        arrive(fromScale: from.scale, fromOpacity: from.opacity)
        cancelTuck()
        onVisibilityChange?()
    }

}

/// RunCat's tempo, from the hook stream rather than the CPU: every tool
/// event bumps its session's `updated_at`, so counting the bumps on
/// working sessions over a short window is the rate the agents are
/// working their tools. A sprint means the tools are being hammered; a
/// stroll means the agents are thinking.
struct BuddyTempo: Equatable {
    /// The window the rate is counted over.
    static let window: TimeInterval = 20
    /// Events a second that reads as a full sprint.
    static let sprintRate: Double = 0.8
    /// The walk's speed range, as a multiple of the old fixed cadence.
    static let strollCadence: Double = 0.75
    static let sprintCadence: Double = 1.7

    /// When each counted event was seen, oldest first.
    private(set) var stamps: [Date] = []
    /// Each session's `updated_at` last time we looked.
    private var lastSeen: [String: Double] = [:]

    /// One document's worth: a working session whose stamp moved since
    /// the last look is one event. A session's first sighting sets its
    /// baseline and counts nothing — a relaunch is not a burst.
    mutating func note(sessions: [CoreSession], now: Date) {
        var seen: [String: Double] = [:]
        for session in sessions {
            guard let updated = session.updatedAt else { continue }
            seen[session.id] = updated
            guard SessionActivity.reduce(session) == .working,
                  let previous = lastSeen[session.id], updated > previous else { continue }
            stamps.append(now)
        }
        lastSeen = seen
        prune(now)
    }

    private mutating func prune(_ now: Date) {
        stamps.removeAll { now.timeIntervalSince($0) > Self.window }
        if stamps.count > 200 { stamps.removeFirst(stamps.count - 200) }
    }

    /// Events a second over the window.
    func rate(at now: Date) -> Double {
        Double(stamps.filter { now.timeIntervalSince($0) <= Self.window }.count) / Self.window
    }

    /// The walk's speed for a rate: a stroll at rest, a sprint at
    /// `sprintRate` and beyond.
    static func cadence(rate: Double) -> Double {
        let k = min(1, max(0, rate.isFinite ? rate / sprintRate : 0))
        return strollCadence + (sprintCadence - strollCadence) * k
    }
}

/// The treat burst's frames on the settings card: 60 a second from the
/// press until the hearts have flown, then none — the card can stay open
/// all afternoon without a display-rate clock under a finished burst.
/// No burst (or Reduce Motion) is a single still frame.
struct BuddyBurstSchedule: TimelineSchedule {
    /// How long the hearts fly.
    static let span: TimeInterval = 0.9
    static let frameInterval: TimeInterval = 1.0 / 60.0
    /// The roster strip's cap — its idle patrol needs no more.
    static let rosterInterval: TimeInterval = 1.0 / 30.0

    /// When the burst ends; nil draws once and rests.
    let end: Date?

    func entries(from startDate: Date, mode: TimelineScheduleMode) -> AnyIterator<Date> {
        let end = self.end ?? .distantPast
        let step = mode == .lowFrequency ? Self.span : Self.frameInterval
        var next: Date? = startDate
        return AnyIterator {
            guard let current = next else { return nil }
            // One last frame lands on the end itself, where nothing draws.
            next = current < end ? min(current.addingTimeInterval(step), end) : nil
            return current
        }
    }
}

/// The card's disclosure body: the roster picker (a menu, like the Fold
/// card's "Render with"), a live strip — every buddy pacing in place,
/// the picked one lit, tap to choose — then the pet half: a name field
/// (blank keeps the character's own), a "Give treat" button that bursts
/// hearts over the button and the buddy alike, and the friendship line.
private struct BuddyControlsView: View {
    let toy: NotchBuddyToy
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// The tile under the pointer: the one character that paces.
    @ViewState private var hovered: BuddyCharacter?

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Picker(selection: toy.characterBinding) {
                ForEach(BuddyCharacter.allCases, id: \.self) { c in
                    Text(c.displayName).tag(c)
                }
            } label: {
                SettingLabel(title: "Character", subtitle: "Who lives in your notch.")
            }
            .pickerStyle(.menu)
            .disabled(toy.miniMode)

            if !toy.miniMode { roster }

            Toggle(isOn: toy.presentationBinding) {
                SettingLabel(title: "Mini", subtitle: "Just the status dot — docked or floating, no body.")
            }

            Toggle(isOn: toy.wearsStripColorBinding) {
                SettingLabel(title: "Wear the Screen Bar's colour",
                             subtitle: "Docked under a lit band, it takes the band's colour instead of its own.")
            }

            LabeledContent {
                TextField("", text: toy.nameBinding, prompt: Text(toy.buddyCharacter.defaultName))
                    .labelsHidden()
                    .textFieldStyle(.roundedBorder)
                    .frame(maxWidth: 200)
            } label: {
                SettingLabel(title: "Name", subtitle: "What it answers to. Blank keeps \(toy.buddyCharacter.defaultName).")
            }

            LabeledContent {
                HStack(spacing: 10) {
                    Slider(value: toy.scaleBinding, in: NotchBuddySettings.scaleRange, step: 0.25)
                        .frame(width: 180)
                    ValueText(text: NotchBuddyToy.sizeWords(toy.buddyScale))
                }
            } label: {
                SettingLabel(title: "Size",
                             subtitle: "How big the floating buddy grows — the docked slot stays its 18pt self.")
            }

            Toggle(isOn: toy.showsCaptionBinding) {
                SettingLabel(title: "Caption on hover",
                             subtitle: "Point at it to read what it's watching, or its name while nothing runs.")
            }

            Toggle(isOn: toy.takesWalksBinding) {
                SettingLabel(title: "Take walks",
                             subtitle: "Floating, it strolls along a window's top edge now and then while the agents work.")
            }

            LabeledContent {
                HStack(spacing: 10) {
                    // Whole minutes, but no tick marks: 38 of them read
                    // as a dotted rule, not a dial.
                    Slider(value: toy.walkEveryBinding, in: NotchBuddySettings.walkEveryRange)
                        .frame(width: 180)
                    ValueText(text: NotchBuddyToy.walkWords(toy.walkEvery))
                }
            } label: {
                SettingLabel(title: "Time between walks",
                             subtitle: "About this many minutes of work between walks.")
            }
            .disabled(!toy.takesWalks)

            HStack(spacing: 10) {
                Button("Give treat") { toy.giveTreat() }
                    .overlay(alignment: .top) { treatHearts }
                Text(toy.careLine)
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            .padding(.top, 4)

            // The pal card's history, the part the caption can't hold —
            // the same lines "About…" in its menu shows.
            let card = BuddyPalCard.make(care: toy.store?.state.notchBuddy.care ?? BuddyCare())
            let history = [card.since, card.favourite, card.longestAsk].compactMap { $0 }
            if !history.isEmpty {
                Text(history.joined(separator: " · "))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            // Roaming state at a glance: a wake-up call while tucked, a
            // dock button while it floats, and an undock that parks it
            // at the slot while docked (from there, drag it anywhere).
            if toy.isTucked {
                HStack(spacing: 10) {
                    Button("Bring it back") { toy.isOn = true }
                    Text("Tucked away until the next event.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            } else {
                Button(toy.isFree ? "Dock at the notch" : "Float free") {
                    toy.isFree ? toy.dock() : toy.floatFree()
                }
            }
        }
    }

    /// The treat's hearts, replayed over the button — the buddy in the
    /// notch gets its own burst from the same clock. Reads
    /// `toy.treatBurstAt` in the body so the press itself re-renders, and
    /// the schedule runs only through the burst: the rest of the time
    /// the card is open, and under Reduce Motion, it does not tick.
    private var treatHearts: some View {
        let burstAt = toy.treatBurstAt
        let still = reduceMotion || NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        return TimelineView(BuddyBurstSchedule(end: still ? nil : burstAt?.addingTimeInterval(BuddyBurstSchedule.span))) { context in
            let age = burstAt.map { context.date.timeIntervalSince($0) } ?? .infinity
            ZStack {
                if age < BuddyBurstSchedule.span {
                    ForEach(0..<3, id: \.self) { i in
                        let p = min(1, max(0, (age - Double(i) * 0.09) / 0.65))
                        Image(systemName: "heart.fill")
                            .font(.system(size: [4.5, 6.0, 5.0][i], weight: .bold))
                            .foregroundStyle(.pink)
                            .offset(x: [-7.0, 0.5, 7.0][i], y: -4 - p * 15)
                            .opacity(p <= 0 ? 0 : (p > 0.55 ? (1 - p) / 0.45 : 0.95))
                    }
                }
            }
        }
    }

    /// One tile per character, standing still in its patrol pose; the
    /// tile under the pointer paces, at 30 fps rather than the display's
    /// 120. Reduce Motion stills that one too. One row where the card is
    /// wide enough, two even rows where it is not (`BuddyRosterLayout`),
    /// so no tile ever runs off the card's edge — decided from the
    /// offered width, not by building both.
    private var roster: some View {
        BuddyRosterLayout(cell: Self.rosterCell, inset: Self.rosterInset, rowSpacing: 8) {
            ForEach(BuddyCharacter.allCases, id: \.self) { c in
                cell(c)
            }
        }
        .padding(.vertical, 4)
    }

    /// Each character's column: its tile and the air to the next, wide
    /// enough for "Mushroom" at full size.
    static let rosterCell: CGFloat = 48
    private static let rosterTile: CGFloat = 40
    /// The first tile's edge lines up with the labels above it.
    static let rosterInset: CGFloat = (rosterCell - rosterTile) / 2

    /// One character on a tile of its own, half again the docked size,
    /// with its name under it; the one living in the notch sits lit.
    private func cell(_ c: BuddyCharacter) -> some View {
        let selected = toy.characterBinding.wrappedValue == c
        let still = reduceMotion || NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        let tile = RoundedRectangle(cornerRadius: 11, style: .continuous)
        return VStack(spacing: 4) {
            BuddyRosterFigure(character: c, pacing: BuddyRosterPaces.paces(c, hovered: hovered, reduceMotion: still))
                .frame(width: 18, height: 18)
                .scaleEffect(1.5)
                .frame(width: Self.rosterTile, height: 38)
                .background(tile.fill(selected ? Color.accentColor.opacity(0.16) : Color.primary.opacity(0.05)))
                .overlay(tile.strokeBorder(selected ? Color.accentColor.opacity(0.75) : Color.primary.opacity(0.06),
                                           lineWidth: selected ? 1.5 : 0.5))
            Text(c.displayName)
                .font(.system(size: 9.5, weight: selected ? .semibold : .regular))
                .foregroundStyle(selected ? .primary : .secondary)
                .lineLimit(1)
                .minimumScaleFactor(0.85)
        }
        .frame(width: Self.rosterCell)
        .contentShape(Rectangle())
        .onHover { inside in
            if inside {
                hovered = c
            } else if hovered == c {
                hovered = nil
            }
        }
        .onTapGesture { toy.characterBinding.wrappedValue = c }
        .help("\(c.displayName) — \(c.blurb)")
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(c.displayName)\(selected ? ", selected" : "")")
    }
}

/// Which roster tile paces.
enum BuddyRosterPaces {
    /// Only the hovered tile, and not under Reduce Motion: the rest stand
    /// still, so an open card asks for no frames at all.
    static func paces(_ character: BuddyCharacter, hovered: BuddyCharacter?, reduceMotion: Bool) -> Bool {
        !reduceMotion && hovered == character
    }
}

/// A roster tile's figure: the still patrol pose, or — for the tile
/// under the pointer — the pose pacing on its own 30 fps clock. Only
/// that one tile's timeline runs; a still tile asks for no frames.
private struct BuddyRosterFigure: View {
    let character: BuddyCharacter
    let pacing: Bool

    var body: some View {
        if pacing {
            TimelineView(.animation(minimumInterval: BuddyBurstSchedule.rosterInterval)) { context in
                figure(phase: context.date.timeIntervalSince1970, still: false)
            }
        } else {
            figure(phase: 0, still: true)
        }
    }

    private func figure(phase: TimeInterval, still: Bool) -> some View {
        BuddyFigure(character: character, mood: .pacing, tint: .accentColor,
                    phase: phase, hopProgress: nil,
                    waveAge: nil, slumpAge: nil, leans: false,
                    still: still, askCount: 0, care: .content,
                    trick: nil, treatAge: nil, crumbAge: nil)
    }
}

/// The roster's tiles in one row when the offered width holds them all,
/// else in two even rows (the first holding the extra one) — what a
/// `ViewThatFits` over the two did, without building and measuring both
/// on every frame. Each tile is `cell` wide; the rows hang `inset` past
/// the leading edge so the first tile lines up with the labels above.
struct BuddyRosterLayout: Layout {
    let cell: CGFloat
    let inset: CGFloat
    let rowSpacing: CGFloat

    /// Tiles per row for `count` tiles in `width` points: all of them
    /// when the one row fits, else half, rounded up.
    static func perRow(count: Int, cell: CGFloat, inset: CGFloat, width: CGFloat?) -> Int {
        guard count > 0 else { return 0 }
        let oneRow = CGFloat(count) * cell - 2 * inset
        guard let width, width < oneRow else { return count }
        return (count + 1) / 2
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let perRow = Self.perRow(count: subviews.count, cell: cell, inset: inset, width: proposal.width)
        guard perRow > 0 else { return .zero }
        let rows = (subviews.count + perRow - 1) / perRow
        let height = rowHeight(subviews)
        let width = CGFloat(perRow) * cell - 2 * inset
        return CGSize(width: width, height: CGFloat(rows) * height + CGFloat(max(0, rows - 1)) * rowSpacing)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let perRow = Self.perRow(count: subviews.count, cell: cell, inset: inset, width: proposal.width ?? bounds.width)
        guard perRow > 0 else { return }
        let height = rowHeight(subviews)
        for (index, subview) in subviews.enumerated() {
            let row = index / perRow, column = index % perRow
            let origin = CGPoint(x: bounds.minX - inset + CGFloat(column) * cell,
                                 y: bounds.minY + CGFloat(row) * (height + rowSpacing))
            subview.place(at: origin, anchor: .topLeading,
                          proposal: ProposedViewSize(width: cell, height: height))
        }
    }

    private func rowHeight(_ subviews: Subviews) -> CGFloat {
        subviews.map { $0.sizeThatFits(ProposedViewSize(width: cell, height: nil)).height }.max() ?? 0
    }
}

/// Target object for the buddy's menu — `NSMenuItem.target` is weak, so
/// the toy keeps this alive and re-aims it each time the menu is built.
@MainActor
final class BuddyMenuActions: NSObject {
    weak var toy: NotchBuddyToy?
    /// Where the buddy sits right now — "Float free" parks it there.
    var panelFrame: NSRect?

    func item(title: String, action: Selector) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
        item.target = self
        return item
    }

    @objc func pet(_ sender: Any?) { toy?.tapped() }
    @objc func treat(_ sender: Any?) { toy?.giveTreat() }
    @objc func rename(_ sender: Any?) { toy?.promptRename(near: panelFrame) }
    @objc func about(_ sender: Any?) { toy?.presentCard(near: panelFrame) }
    @objc func feedTank(_ sender: Any?) { toy?.store?.aquarium?.feedAll() }

    @objc func pickCharacter(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String else { return }
        toy?.store?.state.notchBuddy.character = raw
    }

    @objc func openAsk(_ sender: Any?) { toy?.openAskingSession() }

    @objc func toggleDock(_ sender: Any?) {
        guard let toy else { return }
        if toy.isFree {
            toy.dock()
        } else if let panelFrame {
            toy.parkFree(at: CGPoint(x: panelFrame.midX, y: panelFrame.midY),
                         figureCentre: BuddyPanel.dockedFigureCentre(in: panelFrame))
        } else {
            toy.floatFree()
        }
    }

    @objc func toggleCaption(_ sender: Any?) { toy?.toggleCaption() }
    @objc func wear(_ sender: NSMenuItem) {
        toy?.wear((sender.representedObject as? String).flatMap(ShopItem.init(rawValue:)))
    }
    @objc func toggleWalkabout(_ sender: Any?) { toy?.store?.state.notchBuddy.walkabout.toggle() }
    @objc func tuck(_ sender: Any?) { toy?.tuckAway() }
}
