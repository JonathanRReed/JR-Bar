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
/// session event or a card re-enable. Floating, it wears a quiet
/// caption naming the session it is watching, and the card's Size
/// slider grows it up to 3× — the docked pill stays its 18pt self.
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
            store?.state.notchBuddy.enabled = newValue
            if newValue { store?.state.notchBuddy.tucked = false }
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
    /// Which way it faces while strolling along an edge (+1 right, -1
    /// left); nil the rest of the time. The free panel sets it at each
    /// leg, never per frame.
    var strollHeading: Double?

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

    // MARK: Roaming

    /// Docked under the notch, or parked where the user dropped it.
    var freeSpot: BuddySpot? { store?.state.notchBuddy.freePosition }
    var isFree: Bool { freeSpot != nil }
    /// Tucked away: off the screen until the next session event (the
    /// session observer clears it) or `isOn` flips back on.
    var isTucked: Bool { store?.state.notchBuddy.tucked ?? false }
    /// The floating buddy's one-line tag under the pill.
    var showsCaption: Bool { store?.state.notchBuddy.showCaption ?? true }

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
    func parkFree(at point: CGPoint) {
        store?.state.notchBuddy.freePosition = BuddySpot(point)
        onVisibilityChange?()
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
    /// sub-agent churn, not only on mains.
    func tuckAway() {
        wakeSnapshot = Self.sessionSnapshot(core.state?.sessions ?? [])
        store?.state.notchBuddy.tucked = true
        onVisibilityChange?()
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
    /// `dragMovedAt`) with its feet up; put down, `landedAt` plays a
    /// small squash. Reduce Motion ignores all of it.
    private(set) var isDragged = false
    private(set) var dragTilt: Double = 0
    private(set) var dragMovedAt: Date?
    private(set) var landedAt: Date?

    func dragStarted() {
        isDragged = true
        dragTilt = 0
        dragMovedAt = nil
        landedAt = nil
    }

    /// `dx` is this event's horizontal travel, not the total.
    func dragMoved(dx: Double, at now: Date = Date()) {
        guard isDragged else { return }
        dragTilt = BuddyPlacement.dragTilt(dx: dx)
        dragMovedAt = now
    }

    /// Put down — the landing beat plays from `landedAt`.
    func dragEnded(at now: Date = Date()) {
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
    private func followDocument() {
        _ = sessionDigest()
        digestVersion &+= 1
    }

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
        if s.mood == .pacing || s.mood == .gathering, store?.lidClosing(at: now) == true {
            s.mood = .asleep
        }
        if let hopUntil, now < hopUntil { s.mood = .celebrating }
        if s.mood == .waving {
            if wavingSince == nil { wavingSince = now; waveOrdinal += 1 }
        } else if wavingSince != nil {
            wavingSince = nil
        }
        if s.mood == .slumped {
            if slumpedSince == nil { slumpedSince = now }
        } else if slumpedSince != nil {
            slumpedSince = nil
        }
        s.care = store?.state.notchBuddy.care.mood(at: now) ?? .content
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
        let captionItem = menuActions.item(title: "Show caption",
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

/// The card's disclosure body: the roster picker (a menu, like the Fold
/// card's "Render with"), a live strip — every buddy pacing in place,
/// the picked one lit, tap to choose — then the pet half: a name field
/// (blank keeps the character's own), a "Give treat" button that bursts
/// hearts over the button and the buddy alike, and the friendship line.
private struct BuddyControlsView: View {
    let toy: NotchBuddyToy
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

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
            .fixedSize()
            .disabled(toy.miniMode)

            Toggle(isOn: toy.presentationBinding) {
                SettingLabel(title: "Mini", subtitle: "Just the status dot — docked or floating, no body.")
            }
            .toggleStyle(.checkbox)

            Toggle(isOn: toy.wearsStripColorBinding) {
                SettingLabel(title: "Wear the Screen Bar's colour",
                             subtitle: "Docked under a lit band, it takes the band's colour instead of its own.")
            }
            .toggleStyle(.checkbox)

            if !toy.miniMode { roster }

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
                    ValueText(text: String(format: "%.2g×", toy.buddyScale))
                }
            } label: {
                SettingLabel(title: "Size",
                             subtitle: "How big the floating buddy grows — the docked slot stays its 18pt self.")
            }

            HStack(spacing: 10) {
                Button("Give treat") { toy.giveTreat() }
                    .controlSize(.small)
                    .overlay(alignment: .top) { treatHearts }
                Text(toy.careLine)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

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
                        .controlSize(.small)
                    Text("Tucked away until the next event.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            } else {
                Button(toy.isFree ? "Dock at the notch" : "Float free") {
                    toy.isFree ? toy.dock() : toy.floatFree()
                }
                .controlSize(.small)
            }
        }
    }

    /// The treat's hearts, replayed over the button — the buddy in the
    /// notch gets its own burst from the same clock. Reads
    /// `toy.treatBurstAt` in the body so the press itself re-renders.
    private var treatHearts: some View {
        let burstAt = toy.treatBurstAt
        return TimelineView(.animation(paused: reduceMotion
                                       || NSWorkspace.shared.accessibilityDisplayShouldReduceMotion)) { context in
            let age = burstAt.map { context.date.timeIntervalSince($0) } ?? .infinity
            ZStack {
                if age < 0.9 {
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

    /// One cell per character, all on the same clock, all in the idle
    /// patrol pose. Reduce Motion stills the strip — pose stays — and
    /// the paused schedule keeps a stilled strip from ticking at all.
    private var roster: some View {
        TimelineView(.animation(paused: reduceMotion
                                || NSWorkspace.shared.accessibilityDisplayShouldReduceMotion)) { context in
            HStack(spacing: 5) {
                ForEach(BuddyCharacter.allCases, id: \.self) { c in
                    cell(c, at: context.date)
                }
            }
        }
    }

    private func cell(_ c: BuddyCharacter, at now: Date) -> some View {
        let selected = toy.characterBinding.wrappedValue == c
        return BuddyFigure(character: c, mood: .pacing, tint: .accentColor,
                           phase: now.timeIntervalSince1970, hopProgress: nil,
                           waveAge: nil, slumpAge: nil, leans: false,
                           still: reduceMotion, askCount: 0, care: .content,
                           trick: nil, treatAge: nil, crumbAge: nil)
            .frame(width: 18, height: 18)
            .padding(4)
            .background(RoundedRectangle(cornerRadius: 7, style: .continuous)
                .fill(selected ? Color.accentColor.opacity(0.18) : Color.primary.opacity(0.05)))
            .overlay(RoundedRectangle(cornerRadius: 7, style: .continuous)
                .strokeBorder(selected ? Color.accentColor.opacity(0.7) : .clear, lineWidth: 1))
            .contentShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
            .onTapGesture { toy.characterBinding.wrappedValue = c }
            .help("\(c.displayName) — \(c.blurb)")
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("\(c.displayName)\(selected ? ", selected" : "")")
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
            toy.parkFree(at: CGPoint(x: panelFrame.midX, y: panelFrame.midY))
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
