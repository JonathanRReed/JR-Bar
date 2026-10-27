import AppKit
import JRBarCore

/// Turns daemon events into things on the Mac: sounds, notifications, the
/// HUD toast, the status item's amber pulse and the stage-3 chime. The
/// decisions come from `EventPolicy`; this object only owns the players
/// and the timers.
@MainActor
final class EventCoordinator {
    let core: CoreModel
    let sounds = SoundPlayer()
    let notifications = NotificationBridge()
    let hud: NotchHUD

    var onStatusPulse: ((Bool) -> Void)?
    private(set) var isPulsing = false
    /// The Toys page's store: confetti fires on the user's triggers.
    /// Weak — the delegate owns it.
    weak var toys: ToysStore?

    /// The Agent utility's "quiet while the ask's pane is in front"
    /// setting, wired by the delegate; on by default.
    var quietWhenPaneFrontmost: @MainActor () -> Bool = { true }
    /// The Agent utility's per-provider alert rules, applied to what
    /// `EventPolicy` decided before anything plays; wired by the delegate,
    /// a pass-through until then.
    var deliveryRules: @MainActor (EventDelivery, CoreEvent) -> EventDelivery = { delivery, _ in delivery }
    /// The panel's answer desk, wired by the delegate: a banner's Approve
    /// and Deny go through it like every other surface's. Unset, a banner
    /// answers nothing.
    var askDesk: AskAnswerDesk?
    /// How long an ask banner waits for the state that carries its ask —
    /// the daemon publishes `ask_opened` just ahead of that state — before
    /// it is posted without knowing the ask's verbs.
    static let askBannerWait: Duration = .seconds(1)
    /// Ask banners waiting on that state, by identifier; a withdrawal
    /// while one waits means it is never posted.
    var bannerSink: (@MainActor (EventDelivery.Notification, String?) -> Void)?
    var scheduleAskBannerDeadline: (@MainActor @escaping () -> Void) -> Task<Void, Never> = { expire in
        Task { @MainActor in
            do { try await Task.sleep(for: EventCoordinator.askBannerWait) } catch { return }
            expire()
        }
    }
    private struct WaitingBanner {
        let token: UUID
        let notification: EventDelivery.Notification
        let session: String
        let request: String?
        let deadline: Task<Void, Never>
    }
    private var waitingAskBanners: [String: WaitingBanner] = [:]
    /// Where a banner click's refused open is said — the panel is closed
    /// when a banner is clicked, so the delegate points it at the HUD.
    /// Unset, the refusal is only logged.
    var onOpenRefused: (@MainActor (String) -> Void)?
    /// The frontmost-app read, injectable so tests can stage the pane.
    var frontmostApp: @MainActor () -> (bundleID: String?, pid: Int32?) = {
        let app = NSWorkspace.shared.frontmostApplication
        return (app?.bundleIdentifier, app?.processIdentifier)
    }
    /// The daemon's `session_in_front` for a session — true, false, or
    /// nil when it cannot be told — injectable so tests stage the
    /// verdict. Asked, never prompting, on an ask and at each stage.
    var sessionInFront: @MainActor (String) async -> Bool?
    /// The last escalation_stage the daemon announced — remembered so a
    /// frontmost flip can re-decide the noise without waiting for the
    /// next stage boundary. Its session's `ask_resolved` forgets it.
    private(set) var lastEscalation: CoreEvent?
    /// One process's parent, for the ancestry walk that skips a
    /// `session_in_front` the daemon could only answer no to; tests
    /// stage it.
    var parentPID: (Int32) -> Int32? = AskingPane.parentPID
    /// The daemon's last word on whether the owner is watching an asking
    /// session, and under which frontmost app it was read.
    private(set) var inFrontVerdict: AskingPane.Verdict?
    /// One check per session and frontmost app. A newer check or a closed
    /// ask discards the old reply, including after a reconnect.
    private struct WatchingCheck: Equatable {
        let token = UUID()
        let frontmostPID: Int32?
        let request: String?
        let askID: String?
    }
    private var inFrontChecks: [String: WatchingCheck] = [:]
    /// Where a closed-lid sleep failure is remembered as said, so one
    /// failure is said once across launches; a test hands in its own suite.
    var sleepErrorDefaults: UserDefaults = .standard
    /// Where it is said: the panel's notice queue and a local banner.
    var notices: LaunchNotices = .shared
    /// Which quiet stretches have been said, so each is said once.
    private(set) var silenceWatcher = SilentSessionWatcher()
    /// How often the clock alone is allowed to notice a silence: no state
    /// arrives while a session says nothing.
    static let silenceTick: TimeInterval = 60
    nonisolated static let sleepErrorKey = "jrbar.closedLidSleepErrorNoticed"

    init(core: CoreModel, hudAnchor: @escaping @MainActor () -> NSRect?) {
        self.core = core
        sessionInFront = { [weak core] session in
            guard let core, core.isLive else { return nil }
            let reply = try? await core.send("session_in_front", args: ["session": .string(session)], timeout: 3)
            return AskingPane.inFront(from: reply)
        }
        hud = NotchHUD(anchorRect: hudAnchor)
        // The chime rings on its own timer: quiet that begins while it rings
        // has to stop it, not wait for the next event.
        sounds.isHeld = { [weak core] in EventPolicy.soundsHeld(by: core?.state?.focus) }
        sounds.onMissing = { [weak core] name in core?.appendLocalLog(level: "warn", "no system sound named \(name)") }
        notifications.onLog = { [weak core] line in core?.appendLocalLog(line) }
        notifications.onOpenSession = { [weak self] session in self?.openFromBanner(session) }
        notifications.onAnswerAskNow = { [weak self] session, request, approve in
            guard let self else { return SessionOpener.notAnswering }
            return await self.answerFromBanner(session: session, request: request, approve: approve)
        }
        // One announcer at the top of the screen: the Mac's own news is
        // offered to the island first and takes the pill only when the
        // island can't; a headphone the ear already names is not said
        // twice.
        hud.islandPresent = { [weak self] notice in
            self?.toys?.notch.presentSystemNotice(notice) ?? false
        }
        hud.hudLife = { [weak self] in self?.toys?.state.notch.hudDuration ?? NotchHUD.life }
        hud.earAnnouncesAudioRoute = { [weak self] in self?.toys?.notch.earNoticesLive ?? false }
        // The Mac's Focus, said or not, is a quiet stretch the island's
        // hold follows.
        hud.announcements.onFocus = { [weak self] name, on in
            self?.toys?.notch.noteMacFocus(name: name, on: on)
        }
        hud.announcements.onFocusStopped = { [weak self] in
            self?.toys?.notch.stopObservingMacFocus()
        }
        // The coordinator lives for the app's lifetime; the observer's
        // weak self is cleanup enough (a nonisolated deinit could not
        // touch the isolated token anyway).
        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.reapplyEscalationNoise() }
        }
        // A silent session sends no state, so a slow tick counts the quiet.
        _ = Timer.scheduledTimer(withTimeInterval: Self.silenceTick, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.checkSilentSessions() }
        }
        trackState()
    }

    /// One banner for each stretch a working session has been silent past
    /// `SilentSession.threshold` with no tool open, while the person has
    /// asked for it. Held by quiet modes like any courtesy banner; left
    /// unsaid, to be said later, while the person's own terminal for that
    /// session is in front or they have snoozed it.
    func checkSilentSessions(now: Date = Date()) {
        guard let state = core.state else { return }
        let settings = core.settings.map { SettingsDocument($0.document) }
        guard settings?.bool("silent_session_banner_enabled") == true else {
            silenceWatcher = SilentSessionWatcher()
            return
        }
        let found = silenceWatcher.observe(state.mainSessions, now: now, muted: { [self] session in
            if let until = session.snoozedUntil, until > now.timeIntervalSince1970 { return true }
            return askingPaneFrontmost(sessionID: session.id)
        })
        for notice in found {
            let banner = SilentSessionWatcher.banner(for: notice, focus: state.focus)
            if let banner { notifications.deliver(banner) }
            core.appendLocalLog("session \(notice.label) quiet for \(UsageTime.duration(notice.seconds))" + (banner == nil ? " (held)" : " → banner"))
        }
    }

    /// A banner's click opens its session through `SessionOpener`, so a
    /// live session the daemon cannot find still comes up through the
    /// Dock's window locator, and a refusal is said rather than dropped.
    private func openFromBanner(_ session: String) {
        Task { [weak self] in
            guard let refusal = await SessionOpener.open(session), let self else { return }
            self.core.appendLocalLog("open_session refused: \(refusal)")
            self.onOpenRefused?(refusal)
        }
    }

    /// A banner's Approve or Deny: only for the ask the banner was posted
    /// for, still live, and only through the shared desk — its gate, its
    /// request pin, its one pending set. nil once the answer landed.
    func answerFromBanner(session: String, request: String?, approve: Bool) async -> String? {
        guard let askDesk else { return SessionOpener.notAnswering }
        // A banner that was not pinned to one request would answer whatever
        // the session asks next, long after the person last saw it.
        guard request != nil else { return NotificationBridge.unpinnedLine }
        guard let ask = NotificationBridge.liveAsk(session: session, request: request, in: core.openAsks) else {
            return NotificationBridge.replacedLine
        }
        let outcome = await askDesk.answer(ask, approve ? .approve : .deny)
        return outcome.ok ? nil : outcome.line
    }

    /// An ask's banner offers Approve and Deny only while Approve would
    /// land — `AskVerbs.approves` on the live ask — and the banner can be
    /// pinned to its request. A held question, an ask that wants a typed
    /// reply, one the daemon cannot answer from here or one with no
    /// request to pin gets a plain banner, whose click opens the session.
    nonisolated static func bannerCategory(for ask: CoreAsk?) -> EventDelivery.Notification.Category {
        guard let ask, ask.request != nil else { return .plain }
        return AskVerbs.approves(ask) ? .ask : .plain
    }

    /// Posts an ask banner once the state carrying its ask has landed (or
    /// `askBannerWait` has passed), in the category that ask's verbs
    /// allow and pinned to its request. Time-sensitive either way: the
    /// category drops the actions, never the urgency of "X needs you".
    func deliverAskBanner(_ notification: EventDelivery.Notification, session: String, request: String?) {
        let token = UUID()
        waitingAskBanners.removeValue(forKey: notification.identifier)?.deadline.cancel()
        let deadline = scheduleAskBannerDeadline { [weak self] in
            guard let self, self.waitingAskBanners[notification.identifier]?.token == token else { return }
            self.finishAskBanner(notification.identifier)
        }
        waitingAskBanners[notification.identifier] = WaitingBanner(
            token: token, notification: notification, session: session, request: request, deadline: deadline)
        deliverReadyAskBanners()
    }

    func deliverReadyAskBanners() {
        for (id, waiting) in waitingAskBanners {
            if NotificationBridge.liveAsk(session: waiting.session, request: waiting.request, in: core.openAsks) != nil {
                finishAskBanner(id)
            }
        }
    }

    private func finishAskBanner(_ id: String) {
        guard let waiting = waitingAskBanners.removeValue(forKey: id) else { return }
        waiting.deadline.cancel()
        let ask = NotificationBridge.liveAsk(session: waiting.session, request: waiting.request, in: core.openAsks)
        var banner = waiting.notification
        banner.category = Self.bannerCategory(for: ask)
        let request = ask?.request ?? waiting.request
        if let bannerSink { bannerSink(banner, request) }
        else { notifications.deliver(banner, request: request, timeSensitive: true) }
    }

    /// The parts of `state` the toys and the HUD read below: the credits
    /// and the asks (confetti), every session (the buddy), the Focus (the
    /// pill) and the closed lid. A frame that moves only something else —
    /// a health age, the daemon's clock — wakes none of them.
    static func stateFacts(_ core: CoreModel) {
        _ = core.usage
        _ = core.asks
        _ = core.allSessions
        _ = core.focus
        _ = core.power
        _ = core.connection
    }

    /// Re-arms an observation of the applied state after every document
    /// and hands it to the confetti toy: the banked-credits and
    /// all-clear triggers are document edges, not events — no `event`
    /// frame ever carries them.
    private func trackState() {
        withObservationTracking {
            Self.stateFacts(core)
        } onChange: { [weak self] in
            // onChange fires from the property's willSet — read the new
            // document after a hop, like every other observe loop does.
            Task { @MainActor [weak self] in
                guard let self else { return }
                if case .connected = self.core.connection {} else {
                    self.toys?.confetti.noteConnectionLost()
                }
                self.deliverReadyAskBanners()
                if let state = self.core.state {
                    self.toys?.confetti.noteState(state)
                    self.toys?.notchBuddy.noteState(state)
                    self.hud.announcements.noteDaemonFocus(active: state.focus?.observedActive,
                                                          identifiers: state.focus?.observedIdentifiers ?? [])
                    self.noteClosedLid(state.power?.closedLid)
                    self.checkSilentSessions()
                }
                self.trackState()
            }
        }
    }

    /// `closed_lid.sleep_error`: the daemon asked the lid-shut Mac to
    /// sleep and macOS refused. Said once per distinct (error,
    /// last_sleep_at) — a notice on the panel and a local banner, nothing
    /// off the Mac — with a way to the Power rows.
    func noteClosedLid(_ lid: CoreClosedLid?) {
        guard let error = lid?.sleepError?.trimmingCharacters(in: .whitespacesAndNewlines), !error.isEmpty else { return }
        let identity = Self.sleepErrorIdentity(error: error, lastSleepAt: lid?.lastSleepAt)
        guard sleepErrorDefaults.string(forKey: Self.sleepErrorKey) != identity else { return }
        sleepErrorDefaults.set(identity, forKey: Self.sleepErrorKey)
        let text = Self.sleepErrorText(error)
        notices.say(.init(key: "sleep-error", text: text, actionTitle: "Power") {
            _ = Task {
                await AppCommandRouter.shared.perform(.settings(page: SettingsStore.Chapter.notifications.rawValue))
            }
        })
        notices.deliverBanner("sleep-error", "The Mac did not sleep", text)
    }

    nonisolated static func sleepErrorIdentity(error: String, lastSleepAt: Double?) -> String {
        "\(error)|\(lastSleepAt.map { String(Int($0)) } ?? "never")"
    }

    /// "The Mac didn't sleep when the closed-lid hold let go: …", the
    /// error cut to a line.
    nonisolated static func sleepErrorText(_ error: String) -> String {
        let line = error.split(whereSeparator: \.isNewline).first.map(String.init) ?? error
        let cut = line.count > 120 ? String(line.prefix(119)) + "…" : line
        return "The Mac didn't sleep when the closed-lid hold let go: \(cut)"
    }

    func handle(_ event: CoreEvent) {
        if event.kind == "failed" {
            let now = Date().timeIntervalSince1970
            if event.notify == false { return }
            if let at = event.at, now < at || now >= at + 5 { return }
            if let id = event.session, let session = core.state?.session(withID: id),
               session.isSubagent || session.unlinkedWorker || session.supersedesFailure(at: event.at, now: now) { return }
        }
        if let session = event.session {
            if event.kind == "ask_opened" {
                inFrontChecks[session] = nil
                if inFrontVerdict?.session == session { inFrontVerdict = nil }
            } else if event.kind == "ask_resolved" {
                // A delayed resolution for an older request leaves the new
                // ask's check alone. Older daemons omit the request.
                if event.request == nil || inFrontChecks[session]?.request == event.request {
                    inFrontChecks[session] = nil
                }
                if inFrontVerdict?.session == session { inFrontVerdict = nil }
            }
        }
        let settings = core.settings.map { SettingsDocument($0.document) }
        let watching = askingPaneFrontmost(sessionID: event.session)
        let delivery = deliveryRules(EventPolicy.delivery(for: event, state: core.state, settings: settings,
                                                          askingFrontmost: watching), event)
        if event.kind == "escalation_stage" { lastEscalation = event }
        // The ask the stage was about is answered: an app switch has no
        // noise left to re-decide for it.
        if event.kind == "ask_resolved", lastEscalation?.session == event.session { lastEscalation = nil }
        apply(delivery, for: event)
        confirmWatching(event, decidedWatching: watching)
        var summary = "event \(event.kind)"
        if let label = event.label, !label.isEmpty { summary += " · \(label)" }
        if delivery.isSilent { summary += " (quiet)" }
        else {
            var parts: [String] = []
            if let sound = delivery.sound { parts.append(delivery.soundRepeats > 1 ? "\(sound)×\(delivery.soundRepeats)" : sound) }
            if delivery.notification != nil { parts.append("banner") }
            if let toast = delivery.toast { parts.append("hud “\(toast)”") }
            if let pulse = delivery.statusPulse { parts.append(pulse ? "pulse on" : "pulse off") }
            if delivery.chime == .start { parts.append("chime every \(Int(EventPolicy.chimeInterval)) s") }
            if delivery.takeover { parts.append("notch takeover") }
            if delivery.chime == .stop, sounds.isChiming { parts.append("chime off") }
            // A delivery whose whole job is to take a banner away has
            // nothing else to name; the log said "event ask_resolved → ".
            if parts.isEmpty, delivery.withdrawNotification != nil { parts.append("banner withdrawn") }
            summary += parts.isEmpty ? " (quiet)" : " → " + parts.joined(separator: ", ")
        }
        core.appendLocalLog(summary)
        NSLog("JR-Bar: %@", summary)
    }

    func apply(_ delivery: EventDelivery, for event: CoreEvent) {
        if let sound = delivery.sound { sounds.play(sound, repeats: delivery.soundRepeats) }
        if let identifier = delivery.withdrawNotification {
            waitingAskBanners.removeValue(forKey: identifier)?.deadline.cancel()
            notifications.withdraw(identifier: identifier)
        }
        if let notification = delivery.notification {
            if notification.category == .ask, let session = notification.session {
                deliverAskBanner(notification, session: session, request: event.request)
            } else {
                notifications.deliver(notification)
            }
        }
        if let toast = delivery.toast {
            let symbol = event.kind == "device_disconnected" ? "cable.connector.slash" : (event.kind.hasPrefix("peer") ? "person.2.wave.2" : "cable.connector")
            let settings = core.settings.map { SettingsDocument($0.document) }
            let deviceToast = DeviceConnectionState.toast(event, settings: settings, live: core.isLive)
            hud.show(deviceToast ?? toast, symbol: symbol)
        }
        if let pulse = delivery.statusPulse, pulse != isPulsing {
            isPulsing = pulse
            onStatusPulse?(pulse)
        }
        switch delivery.chime {
        case .start: sounds.startChime(EventPolicy.chimeSound, interval: EventPolicy.chimeInterval)
        case .stop: sounds.stopChime()
        case .unchanged: break
        }
        // Confetti judges every event against the user's triggers
        // itself; the toy decides whether it is on and picks the
        // provider's colour from the same table the rest of the app uses.
        toys?.confetti.noteEvent(event)
        toys?.notchBuddy.noteEvent(event)
        // A quota reset brings the aquarium's submarine by.
        toys?.aquarium?.noteEvent(event)
        // The island turns the events that matter into its transient
        // capsules — its own policy and cooldown decide whether this one
        // shows.
        toys?.notch.noteEvent(event)
        // The `takeover` tier's finale: the ask grows out of the notch
        // and holds until it is acted on. A stage below it (or a
        // watched pane) shrinks a card already up back to its capsule.
        if event.kind == "escalation_stage" {
            if delivery.takeover {
                toys?.notch.noteTakeover(event)
            } else {
                toys?.notch.releaseTakeover()
            }
        }
    }

    /// The ask the event names is on screen: the user is already looking
    /// at it, so the escalation ladder's noise stays down. The app's own
    /// read is `answer_local`'s — the host app's bundle on the frontmost
    /// app, and when the session names a process the frontmost pid on
    /// that process's ancestry (`AskingPane`) — and the daemon's
    /// `session_in_front`, while it still speaks for this session and
    /// this frontmost app, overrules it either way (`AskingPane
    /// .watching`). A remote session has no pane here at all, so it can
    /// never quiet the ladder.
    private func askingPaneFrontmost(sessionID: String?) -> Bool {
        guard quietWhenPaneFrontmost(), let sessionID,
              let session = core.state?.session(withID: sessionID), !session.remote else { return false }
        let expected = Set([session.terminal?.bundleId, session.origin?.bundleId].compactMap { $0 })
        let front = frontmostApp()
        let local = AskingPane.isFrontmost(expectedBundleIDs: expected, sessionPID: session.pid,
                                           frontmostBundleID: front.bundleID, frontmostPID: front.pid)
        let verdict = inFrontVerdict.flatMap {
            $0.speaks(for: sessionID, frontmostPID: front.pid, now: Date()) ? $0.inFront : nil
        }
        return AskingPane.watching(local: local, inFront: verdict)
    }

    /// Ask the daemon whether the owner is watching the session an ask
    /// or a stage is about — the tab, not just the app — and, when its
    /// word differs from what this event was decided on, put it right:
    /// an ask whose sound the app rule kept down chimes after all (the
    /// owner is in another tab), a stage re-decides its pulse and chime.
    /// Only while "quiet while watching" is on, for a local session,
    /// once per session and frontmost app while a check is out.
    private func confirmWatching(_ event: CoreEvent, decidedWatching: Bool) {
        guard event.kind == "ask_opened" || event.kind == "escalation_stage",
              quietWhenPaneFrontmost(), let sessionID = event.session,
              let session = core.state?.session(withID: sessionID), !session.remote else { return }
        let front = frontmostApp().pid
        if let pending = inFrontChecks[sessionID], pending.frontmostPID == front { return }
        if let verdict = inFrontVerdict, verdict.speaks(for: sessionID, frontmostPID: front, now: Date()) { return }
        // Another app is in front of a session whose process is known:
        // the daemon could only say no, and the app's rule already does.
        if AskingPane.frontmostElsewhere(sessionPID: session.pid, frontmostPID: front, parentPID: parentPID) { return }
        let ask = core.openAsks.first { $0.session == sessionID }
        let check = WatchingCheck(frontmostPID: front, request: event.request ?? ask?.request, askID: ask?.id)
        inFrontChecks[sessionID] = check
        Task { [weak self] in
            guard let self else { return }
            let inFront = await self.sessionInFront(sessionID)
            guard self.inFrontChecks[sessionID] == check else { return }
            self.inFrontChecks[sessionID] = nil
            guard self.quietWhenPaneFrontmost(), self.frontmostApp().pid == front,
                  let liveAsk = self.core.openAsks.first(where: { $0.session == sessionID }),
                  check.request.map({ $0 == liveAsk.request }) ?? (check.askID == liveAsk.id) else { return }
            self.inFrontVerdict = AskingPane.Verdict(session: sessionID, inFront: inFront,
                                                     frontmostPID: front, at: Date())
            let watching = self.askingPaneFrontmost(sessionID: sessionID)
            guard watching != decidedWatching else { return }
            if event.kind == "ask_opened", decidedWatching, !watching {
                // The app rule quieted the ask's sound; the daemon says
                // the owner is in another tab — it sounds after all.
                let settings = self.core.settings.map { SettingsDocument($0.document) }
                let delivery = self.deliveryRules(
                    EventPolicy.delivery(for: event, state: self.core.state, settings: settings,
                                         askingFrontmost: false), event)
                if let sound = delivery.sound { self.sounds.play(sound, repeats: delivery.soundRepeats) }
            } else if event.kind == "escalation_stage" {
                self.reapplyEscalationNoise()
            }
        }
    }

    /// The frontmost app changed: if the asking pane just came forward
    /// the escalation's noise goes quiet now — and walking away from a
    /// stage that had been suppressed lets it speak up without waiting
    /// for the next boundary. Only the pulse and the chime re-decide;
    /// sounds and banners already fired are gone either way.
    private func reapplyEscalationNoise() {
        guard let event = lastEscalation, asksStillOpen else { return }
        // A new app in front: the daemon's word is asked afresh, and
        // until it answers the app's own rule decides.
        confirmWatching(event, decidedWatching: askingPaneFrontmost(sessionID: event.session))
        let settings = core.settings.map { SettingsDocument($0.document) }
        let delivery = deliveryRules(EventPolicy.delivery(for: event, state: core.state, settings: settings,
                                                          askingFrontmost: askingPaneFrontmost(sessionID: event.session)), event)
        if let pulse = delivery.statusPulse, pulse != isPulsing {
            isPulsing = pulse
            onStatusPulse?(pulse)
        }
        switch delivery.chime {
        case .start: sounds.startChime(EventPolicy.chimeSound, interval: EventPolicy.chimeInterval)
        case .stop: sounds.stopChime()
        case .unchanged: break
        }
        // The pane coming forward is the person looking at the ask: the
        // takeover card shrinks back to its capsule. Walking away again
        // does not re-grow it — that waits for the next stage.
        if !delivery.takeover { toys?.notch.releaseTakeover() }
    }

    private var asksStillOpen: Bool {
        (core.state?.asks.isEmpty == false) || (core.state?.mainSessions.contains { $0.ask != nil } ?? false)
    }

    /// The daemon went away: nothing is escalating any more, and a
    /// takeover card's Approve would answer a daemon that is gone.
    func reset() {
        lastEscalation = nil
        inFrontVerdict = nil
        inFrontChecks.removeAll()
        sounds.stopChime()
        toys?.notch.releaseTakeover()
        if isPulsing {
            isPulsing = false
            onStatusPulse?(false)
        }
    }
}
