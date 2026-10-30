import AppKit
import JRBarCore
import Observation
import OSLog
import SwiftUI

/// Confetti (docs/TOYS.md): when one of the user's triggers lands, the
/// notch pops and a burst in that provider's colours sprays out of its
/// lower lip (or the icon, the corners, or rain) across a transparent,
/// click-through overlay, flutters down, lands on the window tops (in
/// Rest), and the window closes the moment the last piece is gone. The
/// default trigger is a confirmed quota reset on any provider lane.
/// The toy starts off and other triggers are opt-in;
/// Reduce Motion gets one soft glow at the lip instead.
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
    @ObservationIgnored private let lifecycleHandles = FeatureLifecycleHandles()
    @ObservationIgnored private var windows: [ConfettiWindow] = []
    @ObservationIgnored private var isShutdown = false

    /// Nothing runs between bursts; a burst's windows close themselves.
    /// Once one has played, the line quotes what its frames measured.
    func cost(at now: TimeInterval) -> String? {
        guard windows.isEmpty else {
            return "Drawing a burst on \(windows.count) screen\(windows.count == 1 ? "" : "s")"
        }
        guard let last = lastBurst else {
            return "Nothing runs between bursts · a burst draws for a few seconds, then its window closes"
        }
        return "Nothing runs between bursts · " + Self.measured(last)
    }

    /// "the last burst ran 4.2 s at 2.1 ms a frame (p90 2.9 ms)".
    static func measured(_ last: ConfettiDrawMeter.Summary) -> String {
        String(format: "the last burst ran %.1f s at %.1f ms a frame (p90 %.1f ms)",
               last.seconds, last.p50, last.p90)
    }

    /// What the last burst's frames cost, measured while it drew.
    @ObservationIgnored var lastBurst: ConfettiDrawMeter.Summary?
    /// The burst in flight's meter, shared by its screens.
    @ObservationIgnored private var meter: ConfettiDrawMeter?
    /// The state-edge memory for the triggers no event carries (banked
    /// credits growing, the ask set emptying).
    @ObservationIgnored private var edges = ConfettiEdgeTracker(session: UUID().uuidString)
    /// One held visual burst accounts for every fact waiting for the room.
    struct HeldBurst {
        var shot: ConfettiShot
        var why: ToysHush.Reason
        var facts: [Fact]
        var request: HeldRequest?
    }
    struct HeldRequest {
        var shot: ConfettiShot
        var since: TimeInterval
    }
    private(set) var held: HeldBurst?
    static let maximumHeldFacts = 64

    /// A fact a burst celebrates: its dedup key, the daemon's id for it
    /// when it has one, and a word for the log.
    struct Fact: Equatable {
        var key: String
        var eventID: String?
        var label: String
        var trigger: ConfettiFireReason? = nil
        var provider: String? = nil
        var since: TimeInterval = 0
    }

    private static let log = Logger(subsystem: "devin.jrbar", category: "confetti")
    /// Where a decision's one-line account goes — the unified log
    /// (`log show --predicate 'subsystem == "devin.jrbar" AND category ==
    /// "confetti"'`) and the app's own log tail. The tests swap it.
    @ObservationIgnored var logSink: (@MainActor (String) -> Void)?
    /// Where a `quota_reset`'s verdict goes — the daemon's `reset_receipt`.
    /// The tests swap it.
    @ObservationIgnored var receiptSink: (@MainActor (ConfettiResetReceipt) -> Void)?
    @ObservationIgnored var readPendingResets: (@MainActor () async throws -> [CoreEvent])?
    @ObservationIgnored private var reconciliation: Task<Void, Never>?
    private(set) var needsResetReconciliation = true
    @ObservationIgnored private var reconciliationToken: UUID?

    func waitForResetReconciliation() async { await reconciliation?.value }

    /// A full local queue keeps the daemon as the authority for omitted facts.
    func reconcileResets() {
        guard isOn, !isShutdown, needsResetReconciliation, reconciliation == nil,
              (held?.facts.count ?? 0) < Self.maximumHeldFacts else { return }
        let reader = readPendingResets
        let core = store?.core
        guard reader != nil || core?.isLive == true else { return }
        needsResetReconciliation = false
        let token = UUID()
        reconciliationToken = token
        reconciliation = Task { [weak self] in
            defer {
                if self?.reconciliationToken == token { self?.reconciliation = nil }
            }
            do {
                let events: [CoreEvent]
                if let reader { events = try await reader() }
                else if let core {
                    let reply = try await core.send("reset_status")
                    guard reply.ok else { self?.needsResetReconciliation = true; return }
                    let data = try JSONEncoder().encode(reply.result?["events"] ?? .array([]))
                    events = try JSONDecoder().decode([CoreEvent].self, from: data)
                } else { return }
                guard let self, !self.isShutdown, !Task.isCancelled,
                      self.reconciliationToken == token else { return }
                for event in events {
                    guard (self.held?.facts.count ?? 0) < Self.maximumHeldFacts else {
                        self.needsResetReconciliation = true
                        break
                    }
                    self.noteEvent(event)
                }
            } catch { self?.needsResetReconciliation = true }
        }
    }

    /// Re-reads the room while a burst is held; exists only then.
    @ObservationIgnored private var recheck: Timer?
    /// When an outside caller last got a burst — `requestCooldown`.
    @ObservationIgnored private var lastRequestAt: TimeInterval?
    /// The toy's monotonic clock, in seconds: the request cooldown and the
    /// hold limit are ages, so a wall-clock step cannot bend them. It keeps
    /// counting through sleep, so a burst held across a night is old news.
    /// The tests crank it by hand.
    @ObservationIgnored var clock: @MainActor () -> TimeInterval = {
        TimeInterval(clock_gettime_nsec_np(CLOCK_MONOTONIC)) / 1_000_000_000
    }
    /// How the room is read — injectable so the tests can stage a
    /// fullscreen screen or a clear one without a window server.
    @ObservationIgnored var screensForBurst: @MainActor () -> [NSScreen?] = {
        ConfettiToy.screensWithoutFullscreenApps()
    }
    /// Stands in for the overlay windows when set — the tests count the
    /// bursts (screens, density, pieces, colour) without putting
    /// anything on screen.
    @ObservationIgnored var presentOverride: (@MainActor (ConfettiPresentation) -> Void)?
    /// Where the pop plays: Settings › Alerts & Sounds' rules (volume, alert
    /// device, the call hold). The delegate hands in the app's own
    /// player, the one every event sound uses; without one (previews) a
    /// player is made on the first pop, and tests hand in one that
    /// records instead of playing.
    @ObservationIgnored var sounds: SoundPlayer?
    /// The last Settings search reveal the card's Adjust acted on, kept
    /// here because the card's rows are gone while it's folded.
    @ObservationIgnored var adjustReveal: Int?

    init() {}

    isolated deinit {
        recheck?.invalidate()
        for window in windows { window.close() }
    }

    /// Owner retirement ends overlays and timers without settling a held
    /// daemon fact or changing the saved toy preference.
    func shutdown() {
        guard !isShutdown else { return }
        isShutdown = true
        reconciliation?.cancel()
        reconciliation = nil
        dropHeld()
        stopBurst()
    }

    var lifecycleResources: [String: Int] {
        ["windows": lifecycleHandles.liveWindows, "timers": lifecycleHandles.liveTimers, "held burst": held == nil ? 0 : 1]
    }

    let id = "confetti"
    let name = "Confetti"
    let blurb = "Celebrate quota resets and finished runs."
    let symbol = "party.popper"

    var isOn: Bool {
        get { !isShutdown && (store?.state.confetti.enabled ?? false) }
        set {
            guard !isShutdown else { return }
            store?.state.confetti.enabled = newValue
            if !newValue {
                dropHeld(.dropped, "toy_off")
                stopBurst()
            }
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
            set: {
                self.store?.state.confetti[keyPath: keyPath] = $0
                self.roomChanged()
            })
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
        fire(reason: reason, shot: shot(for: provider, moment: reason == .milestone ? .milestone : .plain),
             at: now)
    }

    private func fire(reason: Reason, shot: ConfettiShot, at now: Date, fact: Fact? = nil) -> Bool {
        guard !isShutdown else { return false }
        switch reason {
        case .test:
            present(shot)
            return true
        case .trigger:
            guard isOn else { return false }
        case .milestone:
            guard isOn, settings.triggers.milestones else { return false }
        case .request:
            guard isOn else { return false }
            let stamp = clock()
            if let last = lastRequestAt, stamp - last < ConfettiRoom.requestCooldown { return false }
            lastRequestAt = stamp
        }
        mindTheRoom(shot, now: now, fact: fact)
        return true
    }

    /// `EventCoordinator.apply` hands every daemon event here; the
    /// trigger policy decides whether it earns a burst and the
    /// `firedKeys` ring keeps each fact to once.
    func noteEvent(_ event: CoreEvent) {
        guard !isShutdown else { return }
        // An explicit ask relayed by the daemon (a `confetti` event from
        // a CLI or a hook) is an outside request, not a trigger: it wears
        // the named provider's colour, or the calling session's.
        if event.kind == Self.requestEventKind {
            let provider = event.provider
                ?? event.session.flatMap { store?.core.state?.session(withID: $0) }?.provider
            fire(reason: .request, provider: provider)
            return
        }
        switch ConfettiTriggerPolicy.eventVerdict(event, settings: settings) {
        case .unrelated:
            return
        case .fire(let decision):
            deliver(decision, event: event)
        case .dropped(let why):
            // A trigger kind that earned nothing is worth a line: a
            // swallowed weekly reset is how this toy once failed silently.
            guard event.kind == "quota_reset" else { return }
            let fact = Fact(key: ConfettiTriggerPolicy.eventKey(event), eventID: event.eventId,
                            label: Self.label(of: event))
            // Already celebrated, too old, a trigger off: the daemon keeps
            // offering a reset until it hears it is settled, so say so.
            if held?.facts.contains(where: { $0.key == fact.key }) == true {
                removeHeldFact(fact, outcome: .dropped, reason: why.rawValue)
            } else {
                settle(fact, .dropped, why.rawValue)
            }
        }
    }

    /// "quota_reset claude weekly", for the log.
    private static func label(of event: CoreEvent) -> String {
        [event.kind, event.provider, event.lane].compactMap { $0 }.joined(separator: " ")
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
    /// The daemon connection dropped: the next document is a new run's and
    /// only seeds the edges.
    func noteConnectionLost() {
        needsResetReconciliation = true
        reconciliation?.cancel()
        reconciliation = nil
        edges.reseed(session: UUID().uuidString)
    }

    func noteState(_ state: CoreState) {
        guard !isShutdown else { return }
        reconcileResets()
        for decision in edges.note(state, triggers: settings.triggers) {
            deliver(decision, event: nil)
        }
        roomChanged()
    }

    /// A decision becomes a burst: record its key, resolve the
    /// provider's colour the way the panel does (the fact's provider,
    /// else the event's session's), and fire — `fire` still checks the
    /// toy is on.
    ///
    /// The key is written when the burst is on screen, or when it is let
    /// go for good — never while it is only held, so a quit during a call
    /// leaves the fact to be celebrated on the next launch instead of
    /// losing it.
    private func deliver(_ decision: ConfettiFire, event: CoreEvent?) {
        let provider = decision.provider
            ?? event?.session.flatMap { store?.core.state?.session(withID: $0) }?.provider
        let fact = Fact(key: decision.key, eventID: decision.eventID,
                        label: event.map { Self.label(of: $0) } ?? "\(decision.reason)",
                        trigger: decision.reason, provider: provider, since: clock())
        guard isOn else {
            // Legacy reset events still need local deduplication without a receipt ID.
            if event?.kind == "quota_reset" { settle(fact, .dropped, "toy_off") }
            return
        }
        guard !settings.firedKeys.contains(decision.key) else { return }
        pruneHeldFacts()
        // The room is already holding this very fact: a second copy (the
        // greet's replay of a reset the live frame already brought) waits
        // with it rather than queueing a second burst.
        guard held?.facts.contains(where: { $0.key == decision.key }) != true else { return }
        let moment: ConfettiShot.Moment
        switch decision.reason {
        case .milestone: moment = .milestone
        case .allClear: moment = .allClear
        default: moment = .plain
        }
        _ = fire(reason: .trigger, shot: shot(for: provider, moment: moment), at: Date(), fact: fact)
    }

    /// A burst for `provider`: its colour, and the provider itself (a
    /// known one) for its glyph flecks.
    func shot(for provider: String?, moment: ConfettiShot.Moment = .plain) -> ConfettiShot {
        let known = provider.map { $0.lowercased() }.flatMap { ProviderStyle.table[$0] != nil ? $0 : nil }
        return ConfettiShot(provider: known, tint: tint(for: provider), moment: moment)
    }

    /// The burst's colour for `provider`, from the same table (and the
    /// same settings document) the rest of the app colours by — the Toys
    /// tint when there's no provider or one the app doesn't know.
    private func tint(for provider: String?) -> Color {
        let document = store?.core.settings.map { SettingsDocument($0.document) }
        return ConfettiView.burstTint(provider: provider, document: document)
    }

    /// The card's Try it and the palette's Fire Confetti: a burst now, in
    /// the colour of the session the Screen Bar is focused on — the same
    /// one `jrbar://confetti` picks — else the Toys tint.
    func testBurst() {
        testBurst(provider: store?.focusedProvider())
    }

    /// An explicit ask in `provider`'s colour (`jrbar://confetti`'s
    /// link resolves the provider first). Fires even while the toy is off.
    func testBurst(provider: String?) {
        present(shot(for: provider))
    }

    // MARK: The room

    /// Fire now on the free screens, hold for later, or let it go.
    private func mindTheRoom(_ shot: ConfettiShot, now: Date, fact: Fact? = nil) {
        pruneHeldFacts()
        let hush = store?.hushReason(now: now)
        let minding = store?.state.hushDuringQuiet ?? true
        let screens = pickScreens(minding ? screensForBurst() : Self.allScreens())
        let free = screens.count
        switch ConfettiRoom.verdict(hush: hush, freeScreens: free, whenHeld: settings.whenHeld) {
        case .fire:
            let waiting = held?.facts ?? []
            dropHeld()
            present(shot, on: screens)
            for waitingFact in waiting { settle(waitingFact, .delivered, "after_hold") }
            settle(fact, .delivered, "presented")
        case .hold:
            if var waiting = held {
                if let fact, !waiting.facts.contains(where: { $0.key == fact.key }) {
                    if waiting.facts.count >= Self.maximumHeldFacts {
                        let oldest = waiting.facts.removeFirst()
                        needsResetReconciliation = true
                        report(oldest, .expired, "hold_capacity")
                    }
                    waiting.facts.append(fact)
                }
                if fact == nil { waiting.request = HeldRequest(shot: shot, since: clock()) }
                waiting.shot = shot
                waiting.why = hush ?? .fullscreen
                held = waiting
            } else {
                held = HeldBurst(shot: shot, why: hush ?? .fullscreen, facts: fact.map { [$0] } ?? [],
                                 request: fact == nil ? HeldRequest(shot: shot, since: clock()) : nil)
            }
            armRecheck()
            report(fact, .held, (hush ?? .fullscreen).rawValue)
        case .drop:
            dropHeld(.dropped, "room_hushed")
            settle(fact, .dropped, (hush ?? .fullscreen).rawValue)
        }
    }

    /// Something about the room may have changed — a document, the
    /// presence edge, the switch, the recheck timer. A held burst plays
    /// (smaller) once the room is clear, and is let go once it is old.
    func roomChanged(at now: Date = Date()) {
        guard !isShutdown else { return }
        guard isOn else {
            dropHeld(.dropped, "toy_off")
            stopBurst()
            return
        }
        guard held != nil else { reconcileResets(); return }
        guard settings.whenHeld == .later else {
            dropHeld(.dropped, "hold_disabled")
            return
        }
        pruneHeldFacts()
        guard let held else { return }
        // The daemon's reading first — it is free; the window list is
        // only worth asking once nothing else is keeping the room down.
        if let hush = store?.hushReason(now: now) {
            if hush != held.why {
                var updated = held
                updated.why = hush
                self.held = updated
            }
            return
        }
        let minding = store?.state.hushDuringQuiet ?? true
        let screens = pickScreens(minding ? screensForBurst() : Self.allScreens())
        guard !screens.isEmpty else {
            if held.why != .fullscreen {
                var updated = held
                updated.why = .fullscreen
                self.held = updated
            }
            return
        }
        dropHeld()
        present(held.shot, on: screens, densityScale: ConfettiRoom.replayDensity)
        for fact in held.facts { settle(fact, .delivered, "after_hold") }
        reconcileResets()
    }

    private func pruneHeldFacts() {
        guard var waiting = held else { return }
        if let request = waiting.request,
           !ConfettiRoom.stillWorthPlaying(heldFor: clock() - request.since) {
            waiting.request = nil
        }
        let triggers = settings.triggers
        var kept: [Fact] = []
        for fact in waiting.facts {
            let eligible: Bool
            switch fact.trigger {
            case .quotaReset, .providerReset:
                eligible = triggers.quotaReset || triggers.perProviderReset.contains(fact.provider?.lowercased() ?? "")
            case .sessionCompleted: eligible = triggers.sessionCompleted
            case .allClear: eligible = triggers.allClear
            case .codexBanked: eligible = triggers.codexBankedReset
            case .milestone: eligible = triggers.milestones
            case nil: eligible = true
            }
            if !eligible {
                settle(fact, .dropped, "trigger_off")
            } else if !ConfettiRoom.stillWorthPlaying(heldFor: clock() - fact.since) {
                report(fact, .expired, "held_too_long")
            } else {
                kept.append(fact)
            }
        }
        guard !kept.isEmpty || waiting.request != nil else { dropHeld(); return }
        if let request = waiting.request, request.since >= (kept.last?.since ?? -.infinity) {
            waiting.shot = request.shot
        } else if let last = kept.last {
            let moment: ConfettiShot.Moment = last.trigger == .milestone ? .milestone
                : (last.trigger == .allClear ? .allClear : .plain)
            waiting.shot = shot(for: last.provider, moment: moment)
        }
        waiting.facts = kept
        held = waiting
    }

    /// Whether the held burst's recheck timer is running (the tests).
    var isRecheckArmed: Bool { recheck != nil }

    private func armRecheck() {
        guard recheck == nil else { return }
        let timer = Timer(timeInterval: ConfettiRoom.recheckInterval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.roomChanged() }
        }
        lifecycleHandles.track(timer: timer)
        RunLoop.main.add(timer, forMode: .common)
        recheck = timer
    }

    /// Lets the held burst go. With an `outcome`, the fact it celebrated is
    /// settled that way: `dropped` closes it for good, `expired` leaves it
    /// to be offered again on a later connection.
    private func dropHeld(_ outcome: ConfettiResetReceipt.Outcome? = nil, _ reason: String = "") {
        let facts = held?.facts ?? []
        held = nil
        recheck?.invalidate()
        recheck = nil
        if let outcome {
            for fact in facts { settle(fact, outcome, reason) }
        }
    }

    private func removeHeldFact(_ fact: Fact, outcome: ConfettiResetReceipt.Outcome, reason: String) {
        held?.facts.removeAll { $0.key == fact.key }
        if held?.facts.isEmpty == true, held?.request == nil { dropHeld() }
        settle(fact, outcome, reason)
    }

    // MARK: Accounting

    /// A fact's burst reached its end: `delivered` and `dropped` are for
    /// good, so its dedup key is written and the daemon stops offering it;
    /// `expired` and `held` leave it open. Every end is logged, and a
    /// daemon fact answers the daemon with a `reset_receipt`.
    private func settle(_ fact: Fact?, _ outcome: ConfettiResetReceipt.Outcome, _ reason: String) {
        guard let fact else { return }
        if outcome == .delivered || outcome == .dropped, !settings.firedKeys.contains(fact.key) {
            store?.state.confetti.noteFired(fact.key)
        }
        if outcome == .delivered || outcome == .dropped, let id = fact.eventID {
            store?.state.confetti.noteSettledReset(id, at: Date().timeIntervalSince1970)
        }
        report(fact, outcome, reason)
    }

    /// One line in the log, and the daemon's receipt for a daemon fact.
    private func report(_ fact: Fact?, _ outcome: ConfettiResetReceipt.Outcome, _ reason: String) {
        guard let fact else { return }
        note("confetti: \(fact.label) \(outcome.rawValue) (\(reason))")
        guard let eventID = fact.eventID, !eventID.isEmpty else { return }
        let receipt = ConfettiResetReceipt(eventID: eventID, outcome: outcome, reason: reason)
        if let receiptSink {
            receiptSink(receipt)
        } else {
            guard let core = store?.core else { return }
            Task { [weak self] in
                let reply = try? await core.send("reset_receipt", args: receipt.args)
                guard let self, reply?.ok == true else { return }
                if outcome == .delivered || outcome == .dropped {
                    self.needsResetReconciliation = true
                    self.reconcileResets()
                }
            }
        }
    }

    private func note(_ line: String) {
        if let logSink {
            logSink(line)
            return
        }
        Self.log.info("\(line, privacy: .public)")
        store?.core.appendLocalLog(line)
    }

    /// The Screens pick: every free screen, or only the main one (the
    /// screen with the key window, else the menu bar's) when it's free.
    private func pickScreens(_ free: [NSScreen?]) -> [NSScreen?] {
        guard settings.screens == .main else { return free }
        guard let main = mainScreen() else { return Array(free.prefix(1)) }
        return free.filter { $0.map { $0 == main } ?? false }
    }

    /// Which screen is the main one — injectable for the tests.
    @ObservationIgnored var mainScreen: @MainActor () -> NSScreen? = { NSScreen.main ?? NSScreen.screens.first }

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

    /// One burst per screen, or the soft glow under Reduce Motion. A
    /// burst already on screen is replaced — the newest wins, on every
    /// screen at once. `densityScale` shrinks a replayed hold.
    private func present(_ shot: ConfettiShot, on screens: [NSScreen?]? = nil, densityScale: Double = 1) {
        stopBurst()
        // One overlay per screen — each staged & timed off its own
        // display, same physics & life rules everywhere, and each closes
        // itself, so the replaces-burst policy stays per screen.
        let targets = screens ?? pickScreens(Self.allScreens())
        let plan = Self.plan(settings, shot: shot, densityScale: densityScale,
                             everyone: workingProviders(), season: seasonToday())
        if let presentOverride {
            presentOverride(ConfettiPresentation(
                screens: targets.count, densityScale: densityScale,
                pieces: ConfettiBurst.count(plan.recipe.intensity, density: plan.recipe.density,
                                            stage: .reference),
                tint: shot.tint, recipe: plan.recipe))
            playPop(pan: 0)
            return
        }
        // Rest lands on windows and the Dock: read where they are once,
        // for every screen — the Dock only when one sits along a bottom.
        let rest = plan.recipe.landing == .rest
        let quartz = rest ? OnScreenWindows.quartzFrames() : []
        let dockShown = targets.contains { screen in
            screen.map { $0.visibleFrame.minY > $0.frame.minY } ?? false
        }
        let dock = rest && dockShown ? OnScreenWindows.dockBar() : nil
        let icon = store?.iconFrame()
        let meter = ConfettiDrawMeter()
        self.meter = meter
        var overlays: [ConfettiWindow] = []
        var pan = 0.0
        for screen in targets {
            let stage = Self.stage(for: screen, icon: icon, windows: quartz, dock: dock)
            if stage.icon != nil { pan = ConfettiEmitter.pan(plan.recipe.origin, on: stage) }
            let burst = ConfettiBurst(stage: stage, recipe: plan.recipe, seed: UInt64.random(in: 0...UInt64.max))
            let frame = screen?.frame ?? NSRect(x: 0, y: 0, width: stage.width, height: stage.height)
            let overlay = ConfettiWindow(burst: burst, look: plan.look, frame: frame, meter: meter)
            lifecycleHandles.track(window: overlay)
            overlays.append(overlay)
            overlay.burst { [weak self, weak overlay] in
                MainActor.assumeIsolated {
                    guard let self, !self.isShutdown, let overlay else { return }
                    self.windows.removeAll { $0 === overlay }
                    if self.windows.isEmpty { self.finishBurst() }
                }
            }
        }
        windows = overlays
        if !targets.isEmpty { playPop(pan: pan) }
    }

    /// Keeps what the finished burst's frames cost, for the card.
    private func finishBurst() {
        if let summary = meter?.summary() { lastBurst = summary }
        meter = nil
    }

    private func stopBurst() {
        for window in windows { window.close() }
        windows.removeAll()
        finishBurst()
    }

    /// What a burst is asked to be, from the settings: the moment's own
    /// style when Moment styles is on, the day's colours when Seasonal is
    /// on and it's a holiday, and the look (resolved colours and glyphs).
    static func plan(_ settings: ConfettiSettings, shot: ConfettiShot, densityScale: Double,
                     everyone: [(id: String, color: Color)], season: ConfettiSeason?)
        -> (recipe: ConfettiBurst.Recipe, look: ConfettiLook) {
        var settings = settings
        if settings.momentStyles {
            switch shot.moment {
            case .milestone:
                settings.palette = .gold
                settings.intensity = .big
                settings.origin = .corners
            case .allClear:
                settings.origin = .rain
                settings.intensity = .subtle
            case .plain:
                break
            }
        }
        let look = ConfettiView.look(settings.palette, tint: shot.tint, provider: shot.provider,
                                     everyone: everyone, season: season)
        let recipe = ConfettiBurst.Recipe(
            origin: settings.origin, landing: settings.landing, intensity: settings.intensity,
            shapes: settings.shapes,
            density: ConfettiView.density(settings: settings, densityScale: densityScale),
            hang: settings.duration, slotWeights: look.weights, glyphs: look.glyphs.count,
            special: season?.special ?? .star)
        return (recipe, look)
    }

    /// The providers working right now (the Everyone palette), each once.
    func workingProviders() -> [(id: String, color: Color)] {
        let sessions = store?.core.state?.mainSessions ?? []
        var seen = Set<String>()
        var providers: [(id: String, color: Color)] = []
        for session in sessions {
            let activity = SessionActivity.reduce(session)
            guard activity == .working || activity == .waiting,
                  case let id = session.provider.lowercased(), !id.isEmpty, seen.insert(id).inserted else { continue }
            providers.append((id, tint(for: id)))
        }
        return providers.sorted { $0.id < $1.id }
    }

    /// Today's holiday when Seasonal is on.
    private func seasonToday() -> ConfettiSeason? {
        settings.seasonal ? ConfettiSeason.on(Date()) : nil
    }

    /// A screen as a burst sees it: its size, its notch (or the island a
    /// simulated notch draws), the menu bar's bottom, the icon when it's
    /// on this screen, the Dock's top and how far across it runs, and the
    /// other apps' windows on it front to back — all measured from its
    /// top-left corner. `dock` is the Dock's tiles in the window list's
    /// space (`OnScreenWindows.dockBar`).
    static func stage(for screen: NSScreen?, icon: NSRect?, windows quartz: [CGRect],
                      dock: CGRect? = nil) -> ConfettiStage {
        guard let screen else {
            var fallback = ConfettiStage.reference
            fallback.notch = nil
            return fallback
        }
        let frame = screen.frame
        let depth = Double(ScreenBarGeometry.islandDepth(of: screen))
        var notch: CGRect?
        if let slot = ScreenBarGeometry.islandSlot(on: screen), depth > 0 {
            notch = CGRect(x: Double(slot.centerX - frame.minX) - Double(slot.width) / 2, y: 0,
                           width: Double(slot.width), height: depth)
        }
        let bar = max(Double(frame.maxY - screen.visibleFrame.maxY), depth)
        let primaryHeight = NSScreen.screens.first?.frame.maxY ?? frame.maxY
        let windows = quartz.map { OnScreenWindows.local($0, on: frame, primaryHeight: primaryHeight) }
            .filter { $0.intersects(CGRect(origin: .zero, size: frame.size)) }
        var local: CGRect?
        if let icon, frame.intersects(icon) {
            local = CGRect(x: icon.minX - frame.minX, y: frame.maxY - icon.maxY,
                           width: icon.width, height: icon.height)
        }
        var stage = ConfettiStage(width: Double(frame.width), height: Double(frame.height), notch: notch,
                                  menuBarBottom: bar > 0 ? bar : 24, icon: local,
                                  floor: Double(frame.height) - Double(screen.visibleFrame.minY - frame.minY),
                                  windows: windows)
        if let dock {
            stage.dockSpan = Self.dockSpan(OnScreenWindows.local(dock, on: frame, primaryHeight: primaryHeight),
                                           on: stage)
        }
        return stage
    }

    /// How far across a stage's bottom the Dock runs, from its tiles'
    /// frame measured from the stage's top-left corner: their span and a
    /// few points more for the glass around them — or nil when the Dock
    /// isn't along this screen's bottom edge (hidden, on a side, or on
    /// another screen), so Rest keeps the Dock's top as its floor.
    nonisolated static func dockSpan(_ tiles: CGRect, on stage: ConfettiStage) -> ClosedRange<Double>? {
        guard stage.floor < stage.height, tiles.width > 0, tiles.maxY > stage.floor, tiles.minY < stage.height,
              tiles.maxX > 0, tiles.minX < stage.width else { return nil }
        return (Double(tiles.minX) - 6)...(Double(tiles.maxX) + 6)
    }

    /// The pop, if it's wanted and JR-Bar isn't being quiet — the
    /// lights' own reading decides, whatever the hush switch says — at
    /// Settings › Alerts & Sounds' volume, a touch higher or lower each burst.
    private func playPop(pan: Double) {
        guard settings.sound, !isQuietNow() else { return }
        let player = sounds ?? SoundPlayer()
        sounds = player
        ConfettiSound.play(through: player, rate: Double.random(in: 0.94...1.06), pan: pan)
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

/// What a burst was, for the tests that stand in for the overlays: how
/// many screens, the replay's shrink, the pieces a laptop screen throws,
/// the colour it wears and the recipe it fired with.
struct ConfettiPresentation {
    var screens: Int
    var densityScale: Double
    var pieces: Int
    var tint: Color
    var recipe: ConfettiBurst.Recipe
}

/// What a burst is for: whose colours it wears (and whose glyph), and
/// which moment — a milestone and "All caught up" get their own style
/// when Moment styles is on. Resolved when it's asked for, so a held
/// burst replays in the colour it was fired in.
struct ConfettiShot: Equatable, Sendable {
    enum Moment: Equatable, Sendable { case plain, milestone, allClear }

    var provider: String?
    var tint: Color
    var moment: Moment = .plain
}

extension ConfettiView {
    /// The Amount multiplier: the setting inside its 0.5…2 range, then a
    /// replay's shrink, floored at a quarter — so a held burst replays
    /// smaller even at the lowest Amount.
    static func density(settings: ConfettiSettings, densityScale: Double) -> Double {
        max(0.25, min(2.0, max(0.5, settings.density)) * densityScale)
    }
}
