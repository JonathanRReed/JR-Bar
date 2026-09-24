import AppKit
import JRBarCore
import Observation
import SwiftUI

/// Confetti (docs/TOYS.md): when one of the user's triggers lands, a
/// confetti cannon pops at the notch/Screen Bar centre and rains pieces
/// in that provider's colours down a transparent, click-through overlay,
/// then the window closes. The default trigger is the one the toy has
/// always had — a provider's *weekly* quota reset (a `quota_reset` event
/// whose `lane` is `"weekly"` or ends `-weekly`); the rest are opt-in.
/// Off by default; Reduce Motion gets a soft radial bloom instead.
///
/// It minds the room: while JR-Bar is quiet, a Focus is on or a call has
/// the mic or camera (`ToysStore.hushReason`, the call fact through
/// `ToysStore.noteCallPresence`), a burst is held and played smaller once
/// the room clears — or let go, the card's pick — and a screen a
/// fullscreen app owns is skipped, so a celebration never lands on a
/// Keynote or a video call, fullscreen or not. Anything outside
/// JR-Bar that wants a burst asks through `fire(reason: .request)`:
/// `jrbar confetti` (or a hook) has the daemon journal a `confetti`
/// event, which lands in `noteEvent`. `jrbar://confetti`, the palette's
/// Fire Confetti and the card's Try it are explicit asks right here, so
/// they go through `testBurst` and fire even while the toy is off.
@MainActor
@Observable
final class ConfettiToy: Toy {
    /// The owning store; weak, the store keeps the toy.
    weak var store: ToysStore?
    /// The burst in flight: one overlay window per attached screen,
    /// each living & dying on its own timer. A new burst replaces all
    /// of them — the single-burst policy holds per screen.
    @ObservationIgnored private var windows: [ConfettiWindow] = []

    /// Nothing runs between bursts; a burst's windows close themselves.
    func cost(at now: TimeInterval) -> String? {
        windows.isEmpty
            ? "Nothing runs between bursts · a burst draws for a few seconds, then its window closes"
            : "Drawing a burst on \(windows.count) screen\(windows.count == 1 ? "" : "s")"
    }
    /// The state-edge memory for the triggers no event carries (banked
    /// credits growing, the ask set emptying).
    @ObservationIgnored private var edges = ConfettiEdgeTracker()
    /// The burst the room is holding, newest wins: its colour, when it
    /// was held, and why — the chip says so while it waits.
    private(set) var held: (color: Color, at: Date, why: ToysHush.Reason)?
    /// Re-reads the room while a burst is held; exists only then.
    @ObservationIgnored private var recheck: Timer?
    /// When an outside caller last got a burst — `requestCooldown`.
    @ObservationIgnored private var lastRequestAt = Date.distantPast
    /// How the room is read — injectable so the tests can stage a
    /// fullscreen screen or a clear one without a window server.
    @ObservationIgnored var screensForBurst: @MainActor () -> [NSScreen?] = {
        ConfettiToy.screensWithoutFullscreenApps()
    }
    /// Stands in for the overlay windows when set — the tests count the
    /// bursts (screens, density) without putting anything on screen.
    @ObservationIgnored var presentOverride: (@MainActor (_ screens: Int, _ densityScale: Double) -> Void)?

    init() {}

    let id = "confetti"
    let name = "Confetti"
    let blurb = "A burst in the provider's colours when the moment earns it."
    let symbol = "party.popper"

    var isOn: Bool {
        get { store?.state.confetti.enabled ?? false }
        set {
            store?.state.confetti.enabled = newValue
            if !newValue { dropHeld() }
        }
    }

    var status: ToyStatus {
        guard isOn else { return .off }
        if let held { return .paused("Holding a burst — \(held.why.text)") }
        return .on
    }

    /// The card's read of the stored settings; the defaults stand in
    /// when there's no store (previews, tests).
    var settings: ConfettiSettings { store?.state.confetti ?? ConfettiSettings() }

    /// A binding into `store.state.confetti`; the store's `didSet`
    /// debounces the write, so a dragged slider doesn't stream saves.
    func bind<T>(_ keyPath: WritableKeyPath<ConfettiSettings, T>) -> Binding<T> {
        Binding(
            get: { self.store?.state.confetti[keyPath: keyPath] ?? ConfettiSettings()[keyPath: keyPath] },
            set: { self.store?.state.confetti[keyPath: keyPath] = $0 })
    }

    /// The page-wide "quiet the toys" switch, shown on this card — the
    /// burst is the toy it matters most for.
    var hushBinding: Binding<Bool> {
        Binding(get: { self.store?.state.hushDuringQuiet ?? true },
                set: {
                    self.store?.state.hushDuringQuiet = $0
                    self.roomChanged()
                })
    }

    var controls: AnyView {
        AnyView(ConfettiControlsView(toy: self))
    }

    // MARK: Asking for a burst

    /// Why a burst is asked for — the one entry point every caller uses.
    enum Reason: Equatable, Sendable {
        /// The card's Test burst: an explicit ask right here, so it
        /// fires even while the toy is off and never waits on the room.
        case test
        /// One of the card's triggers matched a daemon fact.
        case trigger
        /// A rare moment JR-Bar noticed itself — an Aquarium achievement
        /// or tank level. Needs the Milestones trigger.
        case milestone
        /// Something outside JR-Bar asked — `jrbar confetti`, a script or
        /// a hook, relayed by the daemon as a `confetti` event
        /// (`requestEventKind`). The toy must be on, the room is minded,
        /// and a repeat inside `ConfettiRoom.requestCooldown` is dropped.
        case request
    }

    /// Fires a burst for `reason`, in `provider`'s colour when one is
    /// named and known (else the Toys tint — never a grey). Returns
    /// whether the ask was taken — a held burst counts as taken; off,
    /// cooling down or an unticked trigger does not.
    @discardableResult
    func fire(reason: Reason, provider: String? = nil, at now: Date = Date()) -> Bool {
        let color = tint(for: provider)
        switch reason {
        case .test:
            present(color)
            return true
        case .trigger:
            guard isOn else { return false }
        case .milestone:
            guard isOn, settings.triggers.milestones else { return false }
        case .request:
            guard isOn, now.timeIntervalSince(lastRequestAt) >= ConfettiRoom.requestCooldown
            else { return false }
            lastRequestAt = now
        }
        mindTheRoom(color, now: now)
        return true
    }

    /// `EventCoordinator.apply` hands every daemon event here; the
    /// trigger policy decides whether it earns a burst and the
    /// `firedKeys` ring keeps each fact to once.
    func noteEvent(_ event: CoreEvent) {
        // An explicit ask relayed by the daemon (a `confetti` event from
        // a CLI or a hook) is an outside request, not a trigger: it wears
        // the named provider's colour, or the calling session's.
        if event.kind == Self.requestEventKind {
            let provider = event.provider
                ?? event.session.flatMap { store?.core.state?.session(withID: $0) }?.provider
            fire(reason: .request, provider: provider)
            return
        }
        guard let decision = ConfettiTriggerPolicy.eventFire(event, settings: settings) else { return }
        deliver(decision, event: event)
    }

    /// The event kind a daemon-relayed ask arrives as: `jrbar confetti`
    /// (`cli_control.py`) has the daemon journal one, and it lands here.
    static let requestEventKind = "confetti"

    /// Each applied state document lands here too: the banked-credits
    /// and all-clear triggers are document edges, not events. The
    /// tracker folds every state whether the toy is on or not, so a
    /// baseline never goes stale enough to fire on old news at enable.
    /// A document is also where a Focus or quiet edge arrives, so a held
    /// burst looks at the room again.
    func noteState(_ state: CoreState) {
        for decision in edges.note(state, triggers: settings.triggers) {
            deliver(decision, event: nil)
        }
        roomChanged()
    }

    /// The original trigger's lane test, kept for the tests: true for
    /// `quota_reset` on a weekly lane only — five-hour and session lanes
    /// stay quiet. The trigger policy owns the same check now.
    nonisolated static func isWeeklyReset(_ event: CoreEvent) -> Bool {
        guard event.kind == "quota_reset", let lane = event.lane else { return false }
        return ConfettiTriggerPolicy.isWeeklyLane(lane)
    }

    /// A decision becomes a burst: record its key, resolve the
    /// provider's colour the way the panel does (the fact's provider,
    /// else the event's session's), and fire — `fire` still checks the
    /// toy is on.
    private func deliver(_ decision: ConfettiFire, event: CoreEvent?) {
        guard isOn, !settings.firedKeys.contains(decision.key) else { return }
        store?.state.confetti.noteFired(decision.key)
        let provider = decision.provider
            ?? event?.session.flatMap { store?.core.state?.session(withID: $0) }?.provider
        fire(reason: .trigger, provider: provider ?? "")
    }

    /// The provider's accent, from the same table (and the same settings
    /// document) the rest of the app colours by.
    private func color(for provider: String) -> Color {
        let document = store?.core.settings.map { SettingsDocument($0.document) }
        return ProviderStyle.style(for: provider, document: document).accent
    }

    /// The card's "Test burst".
    func testBurst(providerColor: Color) {
        present(providerColor)
    }

    // MARK: The room

    /// Fire now on the free screens, hold for later, or let it go.
    private func mindTheRoom(_ color: Color, now: Date) {
        let hush = store?.hushReason(now: now)
        let minding = store?.state.hushDuringQuiet ?? true
        let screens = minding ? screensForBurst() : Self.allScreens()
        let free = screens.count
        switch ConfettiRoom.verdict(hush: hush, freeScreens: free, whenHeld: settings.whenHeld) {
        case .fire:
            present(color, on: screens)
        case .hold:
            held = (color, now, hush ?? .fullscreen)
            armRecheck()
        case .drop:
            dropHeld()
        }
    }

    /// Something about the room may have changed — a document, the
    /// presence edge, the switch, the recheck timer. A held burst plays
    /// (smaller) once the room is clear, and is let go once it is old.
    func roomChanged(at now: Date = Date()) {
        guard let held else { return }
        guard isOn, ConfettiRoom.stillWorthPlaying(heldAt: held.at, now: now) else {
            dropHeld()
            return
        }
        // The daemon's reading first — it is free; the window list is
        // only worth asking once nothing else is keeping the room down.
        if let hush = store?.hushReason(now: now) {
            if hush != held.why { self.held = (held.color, held.at, hush) }
            return
        }
        let minding = store?.state.hushDuringQuiet ?? true
        let screens = minding ? screensForBurst() : Self.allScreens()
        guard !screens.isEmpty else {
            if held.why != .fullscreen { self.held = (held.color, held.at, .fullscreen) }
            return
        }
        dropHeld()
        present(held.color, on: screens, densityScale: ConfettiRoom.replayDensity)
    }

    private func armRecheck() {
        guard recheck == nil else { return }
        let timer = Timer(timeInterval: ConfettiRoom.recheckInterval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.roomChanged() }
        }
        RunLoop.main.add(timer, forMode: .common)
        recheck = timer
    }

    private func dropHeld() {
        held = nil
        recheck?.invalidate()
        recheck = nil
    }

    /// Every attached screen — nil only headless, where the fallback
    /// frame stands in.
    static func allScreens() -> [NSScreen?] {
        let screens = NSScreen.screens as [NSScreen?]
        return screens.isEmpty ? [nil] : screens
    }

    /// The attached screens no fullscreen app owns. The window list's
    /// bounds and layer need no permission (only titles do); a window at
    /// the normal level exactly covering a screen — menu-bar strip and
    /// all — is a fullscreen Space. Headless reads as one free screen.
    static func screensWithoutFullscreenApps() -> [NSScreen?] {
        let screens = NSScreen.screens
        guard !screens.isEmpty else { return [nil] }
        let rects = OnScreenWindows.quartzFrames()
        // The window list is top-left origin at the primary display's
        // top edge; AppKit is bottom-left.
        let primaryHeight = screens.first?.frame.maxY ?? 0
        let frames = screens.map { OnScreenWindows.appKit($0.frame, primaryHeight: primaryHeight) }
        let covered = ConfettiRoom.coveredScreens(windows: rects, screens: frames)
        return screens.enumerated().filter { !covered.contains($0.offset) }.map { $0.element }
    }

    // MARK: The burst

    /// One burst per screen, or the soft flash under Reduce Motion. A
    /// burst already on screen is replaced — the newest wins, on every
    /// screen at once. `densityScale` shrinks a replayed hold.
    private func present(_ color: Color, on screens: [NSScreen?]? = nil, densityScale: Double = 1) {
        for window in windows { window.close() }
        // One overlay per screen — each framed & timed off its own
        // display, same physics & life rules everywhere, and each closes
        // itself, so the replaces-burst policy stays per screen.
        let targets = screens ?? Self.allScreens()
        var burstSettings = settings
        burstSettings.density *= densityScale
        if let presentOverride {
            presentOverride(targets.count, densityScale)
            return
        }
        var overlays: [ConfettiWindow] = []
        for screen in targets {
            let overlay = ConfettiWindow(color: color, settings: burstSettings,
                                         screen: screen)
            overlays.append(overlay)
            overlay.burst { [weak self, weak overlay] in
                MainActor.assumeIsolated {
                    guard let overlay else { return }
                    self?.windows.removeAll { $0 === overlay }
                }
            }
        }
        windows = overlays
        // The pop, if it's wanted and JR-Bar isn't being quiet — the
        // lights' own reading decides, whatever the hush switch says.
        if settings.sound, !targets.isEmpty, !isQuietNow() { ConfettiSound.play() }
    }

    /// JR-Bar's quiet or a Focus, from the daemon's reading — the sound's
    /// own gate, independent of the page switch.
    private func isQuietNow(now: Date = Date()) -> Bool {
        let focus = store?.core.state?.focus
        return ToysHush.quietReason(mode: focus?.mode, source: focus?.source,
                                    until: focus?.until, now: now) != nil
            || (store?.onCall ?? false)
    }
}
