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
/// It minds the room: while JR-Bar is quiet or a Focus is on
/// (`ToysStore.hushReason`), a burst is held and played smaller once the
/// room clears — or let go, the card's pick — and a screen a fullscreen
/// app owns is skipped, so a celebration never lands on a Keynote or a
/// fullscreen video call. (A call on the mic joins the room once call
/// presence is wired — `ToysStore.noteCallPresence`.) Anything outside JR-Bar that wants a burst
/// asks through `fire(reason: .request)`.
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
        /// Something outside JR-Bar asked: the jrbar:// URL scheme, a
        /// script, a hook. The toy must be on, the room is minded, and
        /// a repeat inside `ConfettiRoom.requestCooldown` is dropped.
        case request
    }

    /// Fires a burst for `reason`, in `provider`'s colour when one is
    /// named (else the Toys tint). Returns whether the ask was taken —
    /// a held burst counts as taken; off, cooling down or an unticked
    /// trigger does not.
    @discardableResult
    func fire(reason: Reason, provider: String? = nil, at now: Date = Date()) -> Bool {
        let color = provider.map { self.color(for: $0) } ?? ConfettiView.toysTint
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

    /// The event kind a daemon-relayed ask arrives as.
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
        let ownPID = ProcessInfo.processInfo.processIdentifier
        let info = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements],
                                              kCGNullWindowID) as? [[String: Any]] ?? []
        var rects: [CGRect] = []
        for entry in info {
            guard (entry[kCGWindowLayer as String] as? Int) == 0,
                  (entry[kCGWindowOwnerPID as String] as? Int32) != ownPID,
                  (entry[kCGWindowAlpha as String] as? Double ?? 1) > 0.01,
                  let bounds = entry[kCGWindowBounds as String] as? [String: Any],
                  let rect = CGRect(dictionaryRepresentation: bounds as CFDictionary)
            else { continue }
            rects.append(rect)
        }
        // The window list is top-left origin at the primary display's
        // top edge; AppKit is bottom-left.
        let primaryHeight = screens.first?.frame.maxY ?? 0
        let frames = screens.map {
            CGRect(x: $0.frame.minX, y: primaryHeight - $0.frame.maxY,
                   width: $0.frame.width, height: $0.frame.height)
        }
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

/// The card's disclosure body. Every row writes `store.state.confetti`
/// (which persists itself); "Test burst" fires with whatever is set.
private struct ConfettiControlsView: View {
    let toy: ConfettiToy

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            LabeledContent {
                Button("Test burst") { [weak toy] in
                    toy?.testBurst(providerColor: ConfettiView.toysTint)
                }
            } label: {
                SettingLabel(title: "Try it", subtitle: "Fires a burst now, with the settings below.")
            }

            Divider()
                .padding(.vertical, 4)

            SettingLabel(title: "Triggers", subtitle: "What earns a burst. The defaults are what it has always done.")

            Toggle(isOn: toy.bind(\.triggers.weeklyReset)) {
                SettingLabel(title: "Weekly reset", subtitle: "Any provider's weekly window refills.")
            }

            Toggle(isOn: toy.bind(\.triggers.sessionCompleted)) {
                SettingLabel(title: "Session completed", subtitle: "An agent finishes a run.")
            }

            Toggle(isOn: toy.bind(\.triggers.allClear)) {
                SettingLabel(title: "All caught up", subtitle: "The last open ask resolves — nothing left waiting on you.")
            }

            Toggle(isOn: toy.bind(\.triggers.codexBankedReset)) {
                SettingLabel(title: "Codex banked credits", subtitle: "The banked-credit balance grows.")
            }

            Toggle(isOn: toy.bind(\.triggers.milestones)) {
                SettingLabel(title: "Milestones", subtitle: "An Aquarium achievement or a new tank level — rare on purpose.")
            }

            if !providerChoices.isEmpty {
                Text("Every reset from")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                ForEach(providerChoices, id: \.self) { id in
                    Toggle(isOn: providerBinding(id)) {
                        SettingLabel(title: ProviderStyle.style(for: id).name,
                                     subtitle: "Any window refill — the five-hour one included.")
                    }
                }
            }

            Divider()
                .padding(.vertical, 4)

            Toggle(isOn: toy.hushBinding) {
                SettingLabel(title: "Quiet the toys during Focus and quiet hours",
                             subtitle: "While JR-Bar is quiet or a Focus is on, bursts wait and screens a fullscreen app owns are skipped. The buddy skips its completion hop, the tank saves its reward cards for later and the hinge stays silent.")
            }

            if toy.hushBinding.wrappedValue {
                Picker(selection: toy.bind(\.whenHeld)) {
                    Text("Play it smaller after").tag(ConfettiHeldBurst.later)
                    Text("Let it go").tag(ConfettiHeldBurst.drop)
                } label: {
                    SettingLabel(title: "A held burst", subtitle: "What happens once the room clears. Anything held over half an hour is let go.")
                }
                .pickerStyle(.menu)
                .fixedSize()
            }

            Toggle(isOn: toy.bind(\.sound)) {
                SettingLabel(title: "Sound", subtitle: "A soft pop and rustle with the burst. Silent while JR-Bar is quiet.")
            }

            Divider()
                .padding(.vertical, 4)

            Picker(selection: toy.bind(\.landing)) {
                Text("Rest").tag(ConfettiLanding.rest)
                Text("Fall").tag(ConfettiLanding.fall)
                Text("Fade").tag(ConfettiLanding.fade)
            } label: {
                SettingLabel(title: "Landing", subtitle: "Where the pieces end up.")
            }
            .pickerStyle(.segmented)

            Text(landingNote)
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Picker(selection: toy.bind(\.palette)) {
                Text("Provider").tag(ConfettiPalette.provider)
                Text("Toys tint").tag(ConfettiPalette.toys)
                Text("Rainbow").tag(ConfettiPalette.rainbow)
            } label: {
                SettingLabel(title: "Palette", subtitle: "Whose colours the burst wears.")
            }
            .pickerStyle(.menu)
            .fixedSize()

            Picker(selection: toy.bind(\.shapes)) {
                Text("Mixed").tag(ConfettiShapes.mixed)
                Text("Streamers").tag(ConfettiShapes.streamers)
                Text("Flecks").tag(ConfettiShapes.flecks)
            } label: {
                SettingLabel(title: "Shapes", subtitle: "The full mix, or one note played loud.")
            }
            .pickerStyle(.menu)
            .fixedSize()

            LabeledContent {
                HStack(spacing: 10) {
                    Slider(value: toy.bind(\.density), in: 0.5...2, step: 0.1)
                        .frame(width: 180)
                    ValueText(text: String(format: "%.1f×", toy.settings.density))
                }
            } label: {
                SettingLabel(title: "Density", subtitle: "How many pieces the cannon throws.")
            }

            LabeledContent {
                HStack(spacing: 10) {
                    Slider(value: toy.bind(\.duration), in: 0.7...1.5)
                        .frame(width: 180)
                    ValueText(text: String(format: "%.1f×", toy.settings.duration))
                }
            } label: {
                SettingLabel(title: "Duration", subtitle: "Stretches the whole burst — longer lingers.")
            }
        }
    }

    /// The line under the segmented picker, describing the mode that's
    /// on — it swaps with the selection, like the Fold card's provider
    /// note.
    private var landingNote: String {
        switch toy.settings.landing {
        case .rest:
            return "Streamers settle on the strip and rest there as litter until the burst fades."
        case .fall:
            return "The overlay spans the screen; pieces rain to the bottom edge and fade out."
        case .fade:
            return "Pieces dissolve mid-air — never landing, gone by three-fifths of the way down."
        }
    }

    /// The per-provider reset picker: the providers the daemon currently
    /// reports a quota source for — the only ones that can ever emit a
    /// `quota_reset` — plus any picked id the list no longer carries,
    /// so a provider that went quiet keeps its checkbox.
    private var providerChoices: [String] {
        var ids = Set(toy.settings.triggers.perProviderReset)
        for provider in toy.store?.core.usage ?? [] where provider.quotaSource {
            ids.insert(provider.id)
        }
        return ids.sorted { ProviderStyle.style(for: $0).name < ProviderStyle.style(for: $1).name }
    }

    /// Set membership as a binding — one row's tick adds or drops the id.
    /// Stored lowercase: `eventFire` lowercases the event's provider, so
    /// a mixed-case id must never land in the set.
    private func providerBinding(_ id: String) -> Binding<Bool> {
        Binding(
            get: { toy.settings.triggers.perProviderReset.contains(id.lowercased()) },
            set: { on in
                var picked = toy.store?.state.confetti.triggers.perProviderReset ?? []
                if on { picked.insert(id.lowercased()) } else { picked.remove(id.lowercased()) }
                toy.store?.state.confetti.triggers.perProviderReset = picked
            })
    }
}

/// The burst's overlay: a borderless, transparent, click-through window
/// hung from the top of its screen at `.screenSaver` level — one per
/// attached display, each closed by its own timer. How tall it is and
/// how long it lives are the landing mode's business, both measured off
/// that screen — Rest rains in the top band, Fall spans the screen,
/// Fade needs only the top ~70%. Shares nothing with screen capture
/// (`sharingType = .none`), like the Fold overlay.
@MainActor
private final class ConfettiWindow: NSPanel {
    private let hosting: NSHostingView<ConfettiView>
    private var closer: DispatchWorkItem?
    /// How long this burst runs: the slowest piece's travel in the
    /// chosen landing mode on this screen, plus a 0.4 s tail — derived,
    /// never a constant, so a slow streamer can never be vanished
    /// mid-air the way the hardcoded 2.6 s once did.
    private let life: TimeInterval

    /// The Reduce Motion bloom is shorter — it is one fade, not a burst.
    static let flashLife: TimeInterval = 0.9

    /// `screen` is the display this overlay covers — nil only when the
    /// Mac reports no screens at all, in which case the fallback frame
    /// stands in.
    init(color: Color, settings: ConfettiSettings, screen: NSScreen?) {
        let reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        let frame = screen?.frame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        let height = ConfettiView.viewHeight(for: settings.landing, screenHeight: frame.height)
        let bandBottom = (screen.map { ScreenBarGeometry.notchDepth(of: $0) } ?? 0) + 12
        let view = ConfettiView(color: color, flash: reduceMotion, settings: settings,
                                viewHeight: height, screenHeight: frame.height,
                                bandBottom: bandBottom)
        life = view.life
        hosting = NSHostingView(rootView: view)
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
        let span = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion ? Self.flashLife : life
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated {
                self?.orderOut(nil)
                self?.closer = nil
                done()
            }
        }
        closer = work
        DispatchQueue.main.asyncAfter(deadline: .now() + span + 0.1, execute: work)
    }

    override func close() {
        closer?.cancel()
        closer = nil
        super.close()
    }
}

/// Burst ballistics in closed form: gravity plus quadratic air drag,
/// `dv/dt = −g − (g/vt²)·v|v|` with `vt` the piece's terminal speed.
/// Each axis solves to a plain log/tan expression, so a frame is pure
/// evaluation — nothing is integrated or stored per piece.
enum ConfettiPhysics {
    /// Downward acceleration, pt/s².
    static let gravity: Double = 1100

    /// Seconds from launch to the top of the arc (v hits 0).
    static func apexTime(v0: Double, vt: Double) -> Double {
        (vt / gravity) * atan(v0 / vt)
    }

    /// Height above the launch point `t` seconds in, while still rising:
    /// v = vt·tan(C − g·t/vt) with C = atan(v0/vt), integrated once.
    static func rise(v0: Double, vt: Double, t: Double) -> Double {
        let c = atan(v0 / vt)
        let u = max(0, c - gravity * t / vt)
        return (vt * vt / gravity) * (log(cos(u)) - log(cos(c)))
    }

    /// Total rise at the apex: `(vt²/2g)·ln(1 + (v0/vt)²)`.
    static func apexHeight(v0: Double, vt: Double) -> Double {
        let r = v0 / vt
        return (vt * vt / (2 * gravity)) * log(1 + r * r)
    }

    /// Distance fallen `t` seconds after the apex: v = −vt·tanh(g·t/vt),
    /// which is exactly vt in the limit — the slow flutter.
    static func fall(vt: Double, t: Double) -> Double {
        (vt * vt / gravity) * log(cosh(gravity * t / vt))
    }

    /// Signed horizontal travel `t` seconds in. Drag bleeds the spray
    /// off fast: v = v0 / (1 + (g/vt²)·|v0|·t), integrated once.
    static func travel(v0: Double, vt: Double, t: Double) -> Double {
        let beta = gravity / (vt * vt)
        return (v0 < 0 ? -1 : 1) * (1 / beta) * log(1 + beta * abs(v0) * t)
    }

    /// Seconds after the apex at which a piece has fallen `d` points —
    /// `fall` inverted (`acosh` on e^(d·g/vt²)). Times the streamer
    /// floor bounce; nothing integrates.
    static func fallTime(vt: Double, d: Double) -> Double {
        guard d > 0 else { return 0 }
        let e = d * gravity / (vt * vt)
        // Past e ≈ 300, acosh(e^e) is e + ln 2 to every bit Double keeps.
        if e > 300 { return d / vt + vt * log(2) / gravity }
        let x = exp(e)
        return (vt / gravity) * log(x + sqrt(x * x - 1))
    }

    /// One squash-bounce on the floor, `t` seconds after touching down:
    /// a single parabolic hop `height` pt tall over `duration` s, then
    /// rest. `squashY` dips hard at impact and softer at the second
    /// touchdown, `squashX` widens to match — a ribbon hitting ground.
    static func floorBounce(t: Double, height: Double, duration: Double)
        -> (lift: Double, squashX: Double, squashY: Double) {
        guard t >= 0 else { return (0, 1, 1) }
        var dip = 0.45 * exp(-t / 0.05)
        var lift = 0.0
        var stretch = 0.0
        if t < duration {
            let u = t / duration
            lift = height * 4 * u * (1 - u)
            stretch = 0.07 * sin(.pi * u)
        } else {
            dip = max(dip, 0.28 * exp(-(t - duration) / 0.06))
        }
        return (lift, 1 + 0.5 * dip - 0.4 * stretch, 1 - dip + stretch)
    }
}

/// What the burst is: a cannon pop at the notch — pieces launch in an
/// up-and-out cone with a few fired sideways, drag & gravity take over,
/// and the survivors tumble & flutter down. Where they end up is the
/// landing mode's business: Rest lets streamers squash-bounce onto the
/// band floor and lie there as ribbons, Fall rains to the screen's
/// bottom edge, Fade dissolves everything mid-air — or one soft bloom
/// when Reduce Motion is on, whichever the mode. Every piece's constants
/// are fixed at fire time; a frame only evaluates `ConfettiPhysics` and
/// rotates the context.
struct ConfettiView: View {
    let color: Color
    /// Reduce Motion: a bloom, not a burst.
    let flash: Bool
    /// Where the pieces end up.
    let landing: ConfettiLanding
    /// Timeline stretch from `settings.duration`: `elapsed / timeScale`
    /// is burst time, so the whole animation — pop, delays, flutter —
    /// slows or quickens as one piece.
    let timeScale: Double
    /// The window's height; the pieces' world.
    let viewHeight: Double
    /// The host screen's height — Fade's dissolve band is a fraction of it.
    let screenHeight: Double
    /// The bottom of the top strip (notch + bar). In Rest a piece casts
    /// its soft shadow only while it passes over it.
    let bandBottom: Double
    /// The palette choice, kept for the pop & bloom's colour.
    let paletteChoice: ConfettiPalette
    /// The resolved colours — `Piece.shade` indexes in.
    let palette: [Color]
    let pieces: [Piece]
    /// Real seconds the burst needs: the slowest piece's travel in this
    /// mode on this geometry, stretched by `timeScale`, plus a 0.4 s tail.
    let life: TimeInterval
    /// Render proofs & tests freeze the burst at this many seconds.
    var frozen: TimeInterval? = nil

    /// The cannon's muzzle: notch centre, just under the top edge so the
    /// up-cone reads on screen before pieces leave it.
    static let muzzleY: Double = 30
    /// The Toys page tint — the `toys` palette's base and the test burst's colour.
    static let toysTint = Color(red: 0.93, green: 0.30, blue: 0.62)

    enum Shape { case rect, dot, streamer, diamond, pacDot }

    /// One particle's constants; motion is evaluated, never stored.
    struct Piece {
        var shape: Shape
        var x: Double        // launch x, as a fraction of the width
        var delay: Double    // stagger inside the pop, seconds
        var vx: Double       // sideways launch speed, pt/s (signed)
        var vy: Double       // upward launch speed, pt/s
        var vt: Double       // terminal flutter speed, pt/s
        var apexT: Double    // seconds to the top of the arc
        var apexH: Double    // height of that arc, pt
        var size: Double
        var shade: Int       // palette slot
        var phase: Double
        var spin: Double     // tumble rate, rad/s
        var twirl: Double    // vertical-axis card spin (the twinkle), rad/s
        var sway: Double     // falling drift amplitude, pt
        var swayRate: Double
        var trail: Bool      // drags a faint streak for its first 0.3 s
    }

    init(color: Color, flash: Bool, settings: ConfettiSettings = ConfettiSettings(),
         viewHeight: Double = 360, screenHeight: Double = 900, bandBottom: Double = 44) {
        self.color = color
        self.flash = flash
        self.landing = settings.landing
        self.timeScale = min(1.5, max(0.7, settings.duration))
        self.viewHeight = viewHeight
        self.screenHeight = screenHeight
        self.bandBottom = bandBottom
        self.paletteChoice = settings.palette
        self.palette = Self.paletteColors(settings.palette, provider: color)
        self.pieces = Self.makePieces(density: min(2.0, max(0.5, settings.density)),
                                      shapes: settings.shapes)
        self.life = Self.travelTime(pieces: pieces, mode: settings.landing,
                                    viewHeight: viewHeight, screenHeight: screenHeight)
            * timeScale + 0.4
    }

    /// The window's height for a landing mode, measured off the screen
    /// it hangs on: Rest rains inside the top band (deep enough to fall
    /// through, narrow enough to never be a screen-sized shadow), Fall
    /// needs the whole screen, Fade only the top ~70% — its dissolve
    /// ends at 60%.
    static func viewHeight(for mode: ConfettiLanding, screenHeight: Double) -> Double {
        switch mode {
        case .rest: return min(screenHeight * 0.45, 380)
        case .fall: return screenHeight
        case .fade: return screenHeight * 0.72
        }
    }

    /// The floor streamers rest on in Rest, measured from the top.
    static func floorY(viewHeight: Double) -> Double { viewHeight - 7 }

    /// Six colour slots for a palette choice. Provider & Toys tint build
    /// the same steps around a base — light, dark, white, a gold fleck, a
    /// pale step for the glyph flecks; Rainbow is a six-colour spectrum
    /// kept inside the app's saturation range.
    static func paletteColors(_ choice: ConfettiPalette, provider color: Color) -> [Color] {
        switch choice {
        case .provider: return steps(around: color)
        case .toys: return steps(around: toysTint)
        case .rainbow:
            return [0.0, 0.08, 0.15, 0.36, 0.56, 0.76].map {
                Color(hue: $0, saturation: 0.62, brightness: 0.96)
            }
        }
    }

    private static func steps(around color: Color) -> [Color] {
        [color,
         color.mix(with: .white, by: 0.4),
         color.mix(with: .black, by: 0.25),
         .white,
         Color(red: 0.96, green: 0.76, blue: 0.28),  // warm gold fleck
         color.mix(with: .white, by: 0.62)]         // pale — glyph flecks
    }

    /// The colour the pop & the Reduce Motion bloom wear.
    var themeColor: Color {
        switch paletteChoice {
        case .provider: return color
        case .toys: return Self.toysTint
        case .rainbow: return .white
        }
    }

    /// Position-based alpha — how visible a piece at `y` is, per mode:
    /// Rest eases out at the band's bottom edge, Fall fades over the
    /// last ~8% of the drop, Fade dissolves between 40% & 60% of the
    /// screen's height. 1 while a piece is in open air.
    static func heightFade(mode: ConfettiLanding, y: Double,
                           viewHeight: Double, screenHeight: Double) -> Double {
        switch mode {
        case .rest:
            return min(1, max(0, (viewHeight - y) / 56))
        case .fall:
            return min(1, max(0, (viewHeight - y) / max(1, viewHeight * 0.08)))
        case .fade:
            let start = screenHeight * 0.4, end = screenHeight * 0.6
            return 1 - smooth((y - start) / max(1, end - start))
        }
    }

    /// Fade's little size shrink rides the same progress as its
    /// dissolve; the other modes keep their size.
    static func fadeShrink(mode: ConfettiLanding, heightFade: Double) -> Double {
        mode == .fade ? 1 - 0.35 * (1 - heightFade) : 1
    }

    /// Burst-time seconds until the last piece reaches its end state:
    /// in Rest a streamer's floor touchdown (plus its one bounce), every
    /// other shape's fall to the bottom edge; in Fall the bottom edge
    /// itself; in Fade the bottom of the dissolve band. The window's
    /// life is this × `timeScale` + 0.4 s — derived, never a constant,
    /// so a slow streamer can never be vanished mid-air the way the
    /// hardcoded 2.6 s once did.
    static func travelTime(pieces: [Piece], mode: ConfettiLanding,
                           viewHeight: Double, screenHeight: Double) -> Double {
        var latest = 0.0
        for piece in pieces {
            let endY: Double
            var extra = 0.0
            switch mode {
            case .rest:
                if piece.shape == .streamer {
                    endY = floorY(viewHeight: viewHeight)
                    extra = 0.3   // the squash-bounce
                } else {
                    endY = viewHeight
                }
            case .fall:
                endY = viewHeight
            case .fade:
                endY = min(viewHeight, screenHeight * 0.6)
            }
            let travel = piece.delay + piece.apexT
                + ConfettiPhysics.fallTime(vt: piece.vt,
                                           d: max(0, piece.apexH + endY - muzzleY))
                + extra
            latest = max(latest, travel)
        }
        return latest
    }

    var body: some View {
        if let frozen {
            Canvas { canvas, size in draw(&canvas, size: size, elapsed: frozen) }
        } else {
            TimelineView(.animation) { context in
                Canvas { canvas, size in
                    draw(&canvas, size: size, elapsed: context.date.timeIntervalSince(origin))
                }
            }
            .onAppear { origin = Date() }
        }
    }

    /// One frame of the burst (or the Reduce Motion bloom), `elapsed`
    /// real seconds after the pop.
    private func draw(_ canvas: inout GraphicsContext, size: CGSize, elapsed: Double) {
        if flash {
            drawBloom(&canvas, size: size, p: min(1, elapsed / ConfettiWindow.flashLife))
            return
        }
        // `duration` stretches the whole timeline: physics & delays are
        // evaluated in burst time, the window's life in real time.
        let t = elapsed / timeScale
        drawPop(&canvas, size: size, age: t)
        let endFade = min(1, max(0, (life - elapsed) / 0.4))
        guard endFade > 0 else { return }
        let floorY = Self.floorY(viewHeight: size.height)
        for piece in pieces {
            let age = t - piece.delay
            guard age > 0 else { continue }
            // Rise to the apex, then fall from it at vt's mercy.
            let falling = age > piece.apexT
            var y = Self.muzzleY - (falling
                ? piece.apexH - ConfettiPhysics.fall(vt: piece.vt, t: age - piece.apexT)
                : ConfettiPhysics.rise(v0: piece.vy, vt: piece.vt, t: age))

            // Rest only: a streamer that reaches the floor bounces once
            // and rests there — the only pieces that ever land. The
            // remap happens before the off-band cull, or landed ribbons
            // would vanish a few frames after touchdown. Fall & Fade
            // never land.
            var impact = age   // horizontal motion freezes here
            var settle: Double?
            if landing == .rest, piece.shape == .streamer, falling, y >= floorY {
                let hit = piece.apexT + ConfettiPhysics.fallTime(
                    vt: piece.vt, d: piece.apexH + floorY - Self.muzzleY)
                if age >= hit { impact = hit; settle = age - hit }
            }
            guard settle != nil || y < size.height + 20 else { continue }

            // Quadratic-drag spray plus a flutter that ramps in once the
            // piece is falling; a landed streamer skids to a stop.
            let x = piece.x * size.width
                + ConfettiPhysics.travel(v0: piece.vx, vt: piece.vt, t: impact)
                + piece.sway * sin(piece.swayRate * impact + piece.phase)
                    * min(1, impact / 0.5)
                    * (settle.map { max(0, 1 - $0 / 0.12) } ?? 1)

            var bounce = (sx: 1.0, sy: 1.0)
            var tumble = piece.phase + piece.spin * age
                + (piece.shape == .streamer ? 0.85 * sin(6.2 * age + piece.phase) : 0)
            let twirlAngle = piece.twirl * age + piece.phase
            var osc = abs(cos(twirlAngle))
            var posFade = Self.heightFade(mode: landing, y: y,
                                          viewHeight: size.height, screenHeight: screenHeight)
            var fade = endFade * posFade
            if let settle {
                let b = ConfettiPhysics.floorBounce(t: settle, height: 7, duration: 0.3)
                y = floorY - b.lift
                bounce = (b.squashX, b.squashY)
                // Level out flat and let the twirl die as it lands.
                let t0 = piece.phase + piece.spin * impact
                    + 0.85 * sin(6.2 * impact + piece.phase)
                tumble = t0 + ((t0 / .pi).rounded() * .pi - t0)
                    * Self.smooth(min(1, settle / 0.22))
                let osc0 = abs(cos(piece.twirl * impact + piece.phase))
                osc = osc0 + (0.85 - osc0) * min(1, settle / 0.2)
                fade = endFade   // resting ribbons keep their colour
                posFade = 1
            }
            guard fade > 0.01 else { continue }

            // A card spinning about its vertical axis reads as a
            // scaleX oscillation — the classic confetti twinkle.
            // A streamer twists about its long axis instead; the
            // glyph flecks spin in-plane on their tumble alone.
            let twirls = piece.shape == .rect || piece.shape == .dot
            let shrink = Self.fadeShrink(mode: landing, heightFade: posFade)
            let scaleX = (twirls ? max(0.16, osc) : 1) * bounce.sx * shrink
            let scaleY = (piece.shape == .streamer ? max(0.25, osc) : 1) * bounce.sy * shrink

            // The piece's speed now — the motion stretch's input. Drag
            // bleeds vx; vy rides the tan rise / tanh fall curves.
            let beta = ConfettiPhysics.gravity / (piece.vt * piece.vt)
            let vxNow = piece.vx / (1 + beta * abs(piece.vx) * age)
            let vyNow: Double = falling
                ? -piece.vt * tanh(ConfettiPhysics.gravity * (age - piece.apexT) / piece.vt)
                : piece.vt * tan(atan(piece.vy / piece.vt) - ConfettiPhysics.gravity * age / piece.vt)
            let speed = settle == nil ? hypot(vxNow, vyNow) : 0

            // A few streamers drag a faint streak of colour for
            // their first 0.3 s.
            if piece.trail, age < 0.3 {
                let f = 1 - age / 0.3
                let d = max(1, hypot(piece.vx, piece.vy))
                let len = 14 * f
                var streak = Path()
                streak.move(to: CGPoint(x: x - piece.vx / d * len,
                                        y: y + piece.vy / d * len))
                streak.addLine(to: CGPoint(x: x, y: y))
                canvas.stroke(streak,
                              with: .color(palette[piece.shade].opacity(0.4 * f * endFade)),
                              style: StrokeStyle(lineWidth: 1.1, lineCap: .round))
            }

            // Paper reads two-tone: a light face up front, a darker back
            // when the twirl flips it. Pieces with no twirl (dots, glyph
            // flecks) always show their face.
            let base = palette[piece.shade]
            let flipped = piece.twirl != 0 && cos(twirlAngle) < 0
            let face = flipped ? base.mix(with: .black, by: 0.30) : base.mix(with: .white, by: 0.14)

            // Over the top strip a Rest piece casts a whisper of a
            // shadow on the band — feathered out a few points below it,
            // and never in the other modes.
            if landing == .rest, y < bandBottom + 10 {
                let near = min(1, max(0, (bandBottom + 10 - y) / 10))
                var s = canvas
                s.translateBy(x: x, y: y + 1.2)
                s.rotate(by: .radians(tumble))
                s.scaleBy(x: scaleX, y: scaleY)
                s.fill(path(for: piece), with: .color(.black.opacity(0.16 * near * fade)))
            }

            var c = canvas
            c.translateBy(x: x, y: y)
            c.rotate(by: .radians(tumble))
            // Fast pieces stretch along their travel — the suggestion of
            // motion blur, gone once they flutter down at vt.
            if speed > 430 {
                let stretch = min(0.5, (speed - 430) / 1400)
                let dir = atan2(vyNow, vxNow) - tumble
                c.rotate(by: .radians(dir))
                c.scaleBy(x: 1 + stretch, y: 1 - stretch * 0.4)
                c.rotate(by: .radians(-dir))
            }
            c.scaleBy(x: scaleX, y: scaleY)
            let shape = path(for: piece)
            c.fill(shape, with: .color(face.opacity(0.95 * fade)))
            // A thin lighter rim — the paper's edge catching light.
            c.stroke(shape, with: .color(base.mix(with: .white, by: 0.55).opacity(0.45 * fade)),
                     lineWidth: 0.6)
        }
    }

    /// When the burst started; set on appear so `t = 0` is the pop.
    @ViewState private var origin = Date()

    private func path(for piece: Piece) -> Path {
        let s = piece.size
        switch piece.shape {
        case .rect:
            return Path(CGRect(x: -s / 2, y: -s * 0.3, width: s, height: s * 0.6))
        case .dot:
            return Path(ellipseIn: CGRect(x: -s * 0.28, y: -s * 0.28, width: s * 0.56, height: s * 0.56))
        case .streamer:
            return Path(roundedRect: CGRect(x: -s * 2.4, y: -s * 0.14, width: s * 4.8, height: s * 0.28),
                        cornerRadius: s * 0.14)
        case .diamond:
            // A rounded square; the in-plane spin does the diamond.
            return Path(roundedRect: CGRect(x: -s / 2, y: -s / 2, width: s, height: s),
                        cornerRadius: s * 0.22)
        case .pacDot:
            // A circle with a wedge bite — the cheapest glyph there is.
            var p = Path()
            p.move(to: .zero)
            p.addArc(center: .zero, radius: s * 0.55,
                     startAngle: .degrees(40), endAngle: .degrees(320), clockwise: false)
            p.closeSubpath()
            return p
        }
    }

    /// Smoothstep, clamped — eases a landed streamer flat.
    private static func smooth(_ t: Double) -> Double {
        let t = min(max(t, 0), 1)
        return t * t * (3 - 2 * t)
    }

    /// The pop: a flash & shockwave at the muzzle, plus one beat of
    /// starburst rays. Gone in ~0.3 s, behind the pieces.
    private func drawPop(_ canvas: inout GraphicsContext, size: CGSize, age: Double) {
        guard age >= 0, age < 0.32 else { return }
        let p = age / 0.32
        let ease = 1 - (1 - p) * (1 - p)
        let muzzle = CGPoint(x: size.width / 2, y: Self.muzzleY)
        canvas.fill(Path(ellipseIn: circle(muzzle, 9 + 26 * ease)),
                    with: .color(themeColor.opacity(0.55 * (1 - p))))
        canvas.stroke(Path(ellipseIn: circle(muzzle, 5 + 52 * ease)),
                      with: .color(themeColor.opacity(0.5 * (1 - p))), lineWidth: 1.6)
        var rays = Path()
        for i in 0..<10 {
            let a = Double(i) * (.pi * 2 / 10) + 0.3
            let r0 = 10 + 18 * ease, r1 = r0 + 30 * ease
            rays.move(to: CGPoint(x: muzzle.x + r0 * cos(a), y: muzzle.y + r0 * sin(a)))
            rays.addLine(to: CGPoint(x: muzzle.x + r1 * cos(a), y: muzzle.y + r1 * sin(a)))
        }
        canvas.stroke(rays, with: .color(.white.opacity(0.8 * (1 - p))), lineWidth: 1.4)
        // Sparks: three hot white streaks inside the cone, gone in 0.15 s.
        if age < 0.15 {
            let sp = age / 0.15
            let ease2 = 1 - (1 - sp) * (1 - sp)
            var sparks = Path()
            for i in 0..<3 {
                let a = -.pi / 2 + [-0.55, 0.08, 0.62][i]
                let r0 = 7 + 26 * ease2, r1 = r0 + 7 * (1 - sp)
                sparks.move(to: CGPoint(x: muzzle.x + r0 * cos(a), y: muzzle.y + r0 * sin(a)))
                sparks.addLine(to: CGPoint(x: muzzle.x + r1 * cos(a), y: muzzle.y + r1 * sin(a)))
            }
            canvas.stroke(sparks, with: .color(.white.opacity(0.85 * (1 - sp))), lineWidth: 1.2)
        }
    }

    /// Reduce Motion: a gentle radial bloom of the provider colour at the
    /// notch — the whole cue, no motion.
    private func drawBloom(_ canvas: inout GraphicsContext, size: CGSize, p: Double) {
        guard p < 1 else { return }
        let ease = 1 - (1 - p) * (1 - p)
        let centre = CGPoint(x: size.width / 2, y: Self.muzzleY)
        for i in (0..<3).reversed() {
            let r = 14 + Double(i) * 18 + 110 * ease
            canvas.fill(Path(ellipseIn: circle(centre, r)),
                        with: .color(themeColor.opacity((1 - p) * (0.26 - Double(i) * 0.07))))
        }
    }

    private func circle(_ c: CGPoint, _ r: Double) -> CGRect {
        CGRect(x: c.x - r, y: c.y - r, width: r * 2, height: r * 2)
    }

    static func makePieces(density: Double = 1, shapes: ConfettiShapes = .mixed) -> [Piece] {
        var rng = SystemRandomNumberGenerator()
        var streamerOrdinal = 0
        let count = max(1, Int((140 * density).rounded()))
        return (0..<count).map { _ in
            let roll = Double.random(in: 0...1, using: &rng)
            // In the full mix ~8% are glyph flecks: tiny provider marks
            // that spin in-plane. The shapes setting can make the burst
            // all one note.
            let shape: Shape
            switch shapes {
            case .mixed:
                shape = roll < 0.50 ? .rect : roll < 0.76 ? .dot
                    : roll < 0.92 ? .streamer : roll < 0.96 ? .diamond : .pacDot
            case .streamers:
                shape = .streamer
            case .flecks:
                shape = roll < 0.5 ? .diamond : .pacDot
            }
            // The cone: most pieces go up & out, a few are sideways spray.
            let spray = Double.random(in: 0...1, using: &rng) < 0.2
            let speed = Double.random(in: 240...640, using: &rng)
            let theta = spray
                ? Double.random(in: 1.2...1.5, using: &rng) * (Bool.random(using: &rng) ? 1 : -1)
                : Double.random(in: -1.05...1.05, using: &rng)
            let vt: Double
            let size: Double
            let sway: Double
            switch shape {
            case .rect:
                vt = Double.random(in: 150...215, using: &rng)
                size = Double.random(in: 5...9, using: &rng)
                sway = Double.random(in: 6...18, using: &rng)
            case .dot:
                vt = Double.random(in: 185...260, using: &rng)
                size = Double.random(in: 4...6.5, using: &rng)
                sway = Double.random(in: 2...6, using: &rng)
            case .streamer:
                vt = Double.random(in: 105...160, using: &rng)
                size = Double.random(in: 5.5...8, using: &rng)
                sway = Double.random(in: 8...20, using: &rng)
            case .diamond, .pacDot:
                vt = Double.random(in: 165...235, using: &rng)
                size = Double.random(in: 3...4.5, using: &rng)
                sway = Double.random(in: 1.5...5, using: &rng)
            }
            // Provider colour in steps, white, & a few gold flecks; the
            // glyph flecks wear the provider colour or its pale step.
            let s = Double.random(in: 0...1, using: &rng)
            let shade: Int
            switch shape {
            case .diamond, .pacDot:
                shade = s < 0.6 ? 0 : 5
            case .rect, .dot, .streamer:
                shade = s < 0.45 ? 0 : s < 0.65 ? 1 : s < 0.8 ? 2 : s < 0.95 ? 3 : 4
            }
            let sign = Bool.random(using: &rng) ? 1.0 : -1.0
            let vy = speed * cos(theta)
            var piece = Piece(
                shape: shape,
                x: 0.5 + Double.random(in: -0.035...0.035, using: &rng),
                delay: Double.random(in: 0...0.09, using: &rng),
                vx: speed * sin(theta),
                vy: vy,
                vt: vt,
                apexT: ConfettiPhysics.apexTime(v0: vy, vt: vt),
                apexH: ConfettiPhysics.apexHeight(v0: vy, vt: vt),
                size: size,
                shade: shade,
                phase: Double.random(in: 0...(.pi * 2), using: &rng),
                spin: sign * (shape == .streamer
                    ? Double.random(in: 0.6...1.6, using: &rng)
                    : (shape == .diamond || shape == .pacDot)
                        ? Double.random(in: 2.5...6, using: &rng)
                        : Double.random(in: 1.2...3.6, using: &rng)),
                twirl: (shape == .rect || shape == .streamer)
                    ? Double.random(in: 4...10, using: &rng) : 0,
                sway: sway,
                swayRate: Double.random(in: 2...4.4, using: &rng),
                trail: false
            )
            // A couple of streamers drag a faint streak off the launch.
            if shape == .streamer {
                piece.trail = streamerOrdinal % 8 == 0
                streamerOrdinal += 1
            }
            return piece
        }
    }
}
