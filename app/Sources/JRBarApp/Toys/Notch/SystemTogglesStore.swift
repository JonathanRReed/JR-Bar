import AppKit
import AudioToolbox
import CoreAudio
import Foundation
import IOKit.pwr_mgt
import JRBarCore
import os

/// The Control Center strip — One Switch's grammar with JR-Bar's
/// honesty rules. State is read back from the system, never asserted:
/// a Finder write that failed shows off, not the intent. Applies run
/// detached so a pend (TCC, a stuck `osascript`) can never reach the
/// render path; the read-back lands a beat later and settles the chip.
///
/// App-level: every instance is a view onto one `State`, so the notch
/// card's chips (both card surfaces build their own store), a global
/// shortcut, a `jrbar://toggle/…` link and a Shortcuts action all flip
/// the same truth and hold the same keep-awake — never two. Keep-awake is
/// the daemon's `hold_awake` lease while it is connected (the one hold the
/// agents, the CLI and a deck key share, in `state.power.hold`); the
/// app's own power assertion is only the fallback while it is away (or
/// too old for the lease), and hands itself over the moment one can take
/// it.
@MainActor
final class SystemTogglesStore {
    /// What the daemon said to a lease.
    enum LeaseAnswer: Equatable, Sendable {
        case taken
        /// Refused, in the daemon's words ("No agent is working right now.").
        case refused(String)
        /// Not connected, no answer, or a daemon without the lease: the
        /// app's own assertion stands in.
        case unavailable
    }

    /// The one strip. `SystemTogglesStore()` joins it too.
    static let shared = SystemTogglesStore()

    /// The truth every instance reads and writes.
    @MainActor
    @Observable
    final class State {
        static let shared = State()

        /// The live on-state per stateful toggle — refreshed on show,
        /// after each apply, and whenever the system says it changed.
        /// Momentary verbs never appear here.
        var isOn: [SystemToggle: Bool] = [:]
        /// A toggle mid-apply — the chip pulses rather than lie.
        var applying: Set<SystemToggle> = []
        /// The last apply's honest outcome — a denied `defaults` write or
        /// an AppleScript refusal lands here so the chip can say so.
        var lastError: String?
        /// The last verb's report when nothing failed — what Eject took
        /// and what it left.
        var lastNote: String?
        /// How soon a password follows display sleep — whether the Lock
        /// chip locks, read on each refresh.
        var lockDelay: SystemToggle.ScreenLockDelay?
        /// When a timed keep-awake lets go; nil while indefinite or off.
        var awakeUntil: Date?
        /// "Awake" holds the display on too (no screen saver, no lock)
        /// rather than only the Mac. App-local, remembered.
        var awakeKeepsDisplay: Bool
        @ObservationIgnored var awakeTimer: Task<Void, Never>?
        /// Mount paths the daemon lists as connected LED strips — Eject
        /// leaves them. Wired by the delegate to the core's devices.
        @ObservationIgnored var protectedVolumePaths: @MainActor () -> [String] = { [] }
        /// Which chips the strip shows, in order — One Switch's "choose
        /// which toggles show". Persisted app-locally.
        var strip: [SystemToggle]

        /// The app's own keep-awake assertion — the fallback while the
        /// daemon is away or cannot take the lease. Boxed nonisolated so
        /// `deinit` can release it: the assertion must not outlive the
        /// state.
        let awake = AwakeAssertion()

        /// The daemon's hold (`state.power.hold`) as last published, and
        /// whether the daemon is there at all; while it is, this is the
        /// chip's truth.
        private(set) var daemonHold: CoreAwakeHold?
        private(set) var daemonLive = false
        /// Sends the person's lease: a request is `hold_awake`, nil is
        /// `release_awake`. Wired by `attachLease`; nil keeps every hold
        /// on the app's own assertion.
        @ObservationIgnored var sendLease: (@MainActor (CoreAwakeRequest?) async -> LeaseAnswer)?
        /// The chip's clock, stepped while a countdown shows so the word
        /// under the cup counts down without a daemon frame.
        private(set) var awakeClock = Date()
        @ObservationIgnored private var awakeTick: Task<Void, Never>?
        /// The countdown's clock or the local hold's deadline is running —
        /// what "off leaves nothing behind" checks.
        var awakeClockRunning: Bool { awakeTick != nil || awakeTimer != nil }
        /// A hand-over of the app's assertion to the daemon is in flight.
        @ObservationIgnored private var handingOver = false
        /// This connection's daemon answered a lease with "no such
        /// command" (or never answered): it cannot take the hold, so the
        /// app's own assertion does the job until the next connection
        /// asks afresh — no lease re-sent on every state frame.
        @ObservationIgnored private(set) var leaseUnsupported = false
        /// Takes a power assertion of the given kind (nil when refused),
        /// and lets one go. A test hands in its own pair, so no suite
        /// holds the Mac awake.
        @ObservationIgnored var takeAssertion: @MainActor (CFString) -> IOPMAssertionID? = { kind in
            var assertion = IOPMAssertionID(0)
            let status = IOPMAssertionCreateWithName(
                kind,
                IOPMAssertionLevel(kIOPMAssertionLevelOn),
                "JR-Bar Keep Awake" as CFString,
                &assertion)
            return status == kIOReturnSuccess ? assertion : nil
        }
        @ObservationIgnored var releaseAssertion: @MainActor (IOPMAssertionID) -> Void = { _ = IOPMAssertionRelease($0) }

        /// The one hold as the chip draws it: the daemon's while it is
        /// connected, else the app's own — and the app's own whenever it
        /// holds one, so an assertion the daemon could not take is never
        /// held out of sight of the switch that lets it go.
        var awakeReading: KeepAwakeReading {
            daemonLive && !awake.held
                ? KeepAwakeReading(hold: daemonHold)
                : KeepAwakeReading(localHeld: awake.held, until: awakeUntil, display: awakeKeepsDisplay)
        }

        /// A Dock choice made while the Dock utility's preview holds the
        /// Dock out: applied the moment the hold lets go, so the hold's
        /// restore can never undo it.
        @ObservationIgnored var pendingDockAutohide: Bool?
        @ObservationIgnored var listening = false

        /// The Dock's live `autohide` pair (`CoreDock`, the one the Dock
        /// utility's preview hold uses) — nil on a build where it does
        /// not resolve, and then System Events, and only last `defaults`
        /// plus a Dock restart.
        @ObservationIgnored let dockDriver: (any DockAutohideDriver)?
        /// Is the Dock utility holding the Dock out for a preview right
        /// now? Wired by the delegate; a chip flip during a hold waits.
        @ObservationIgnored var dockHoldActive: @MainActor () -> Bool = { false }

        /// Where the strip's chip choice persists — app-local defaults;
        /// a test hands in its own suite.
        @ObservationIgnored let defaults: UserDefaults

        init(dockDriver: (any DockAutohideDriver)? = CoreDockAutohideDriver(),
             defaults: UserDefaults = .standard) {
            self.dockDriver = dockDriver
            self.defaults = defaults
            self.strip = SystemTogglesStore.loadStrip(defaults: defaults)
            self.awakeKeepsDisplay = defaults.bool(forKey: SystemTogglesStore.awakeDisplayDefaultsKey)
        }

        /// Take or drop the app's own keep-awake assertion — the fallback
        /// while the daemon is away. The kind follows `awakeKeepsDisplay`:
        /// the Mac only (the display still sleeps and locks), or the
        /// display too.
        func setAwake(_ hold: Bool) {
            if hold && !awake.held {
                let kind = awakeKeepsDisplay
                    ? kIOPMAssertionTypePreventUserIdleDisplaySleep
                    : kIOPMAssertionTypeNoIdleSleep
                if let assertion = takeAssertion(kind as CFString) {
                    awake.id = assertion
                    awake.held = true
                } else {
                    lastError = "Awake: the power assertion was refused."
                }
            } else if !hold && awake.held {
                releaseAssertion(awake.id)
                awake.id = 0
                awake.held = false
            }
            if !awake.held {
                awakeTimer?.cancel()
                awakeTimer = nil
                awakeUntil = nil
            }
            syncAwakeChip()
        }

        /// Hold for `seconds`, indefinitely (nil), or let go (0) —
        /// Amphetamine's session vocabulary on the one hold: the daemon's
        /// lease while it is connected and can take one, the app's
        /// assertion otherwise — and the assertion's own switch while the
        /// app holds it, so a tap always moves the hold the chip shows.
        func holdAwake(seconds: Int?) {
            guard daemonLive, sendLease != nil, !leaseUnsupported, !awake.held else {
                holdLocally(seconds: seconds)
                return
            }
            let request: CoreAwakeRequest?
            switch seconds {
            case 0?: request = nil
            case let seconds?: request = CoreAwakeRequest(.seconds(Double(seconds)), display: awakeKeepsDisplay)
            case nil: request = CoreAwakeRequest(.indefinite, display: awakeKeepsDisplay)
            }
            lease(request) { [weak self] in self?.holdLocally(seconds: seconds) }
        }

        /// Hold until the agents working now stop — the daemon's `agents`
        /// lease, Amphetamine's "while an app runs" for agent runs. Only
        /// the monitor knows when they stop, so with none it says so in
        /// the caption rather than guessing at a deadline. An assertion
        /// the app took while the monitor was away lets go once the lease
        /// is in, never before: the Mac is held throughout.
        func holdAwakeUntilAgentsFinish() {
            guard daemonLive, sendLease != nil, !leaseUnsupported else {
                lastError = "Awake: only the monitor can tell when the agents finish, and it isn't running."
                syncAwakeChip()
                return
            }
            let request = CoreAwakeRequest(.untilAgentsFinish(sessions: nil), display: awakeKeepsDisplay)
            lease(request, fallback: nil) { [weak self] in
                guard let self, self.awake.held else { return }
                self.setAwake(false)
            }
        }

        /// One lease out; the chip pulses until the daemon answers, and
        /// its next `state.power.hold` is what settles the chip. With no
        /// daemon to take it, `fallback` does the job locally.
        private func lease(_ request: CoreAwakeRequest?, fallback: (@MainActor () -> Void)?,
                           taken: (@MainActor () -> Void)? = nil) {
            guard let sendLease else { return }
            applying.insert(.keepAwake)
            Task { [weak self] in
                let answer = await sendLease(request)
                guard let self else { return }
                self.applying.remove(.keepAwake)
                switch answer {
                case .taken:
                    if self.lastError?.hasPrefix("Awake:") == true { self.lastError = nil }
                    taken?()
                case .refused(let why):
                    self.lastError = "Awake: \(why)"
                case .unavailable:
                    if self.daemonLive { self.leaseUnsupported = true }
                    fallback?()
                }
                self.syncAwakeChip()
            }
        }

        /// The app's own assertion for `seconds`, indefinitely (nil), or
        /// let go (0).
        private func holdLocally(seconds: Int?) {
            awakeTimer?.cancel()
            awakeTimer = nil
            awakeUntil = nil
            guard seconds != 0 else {
                setAwake(false)
                return
            }
            setAwake(true)
            guard let seconds, awake.held else { return }
            awakeUntil = Date().addingTimeInterval(TimeInterval(seconds))
            awakeTimer = Task { [weak self] in
                try? await Task.sleep(nanoseconds: UInt64(seconds) * 1_000_000_000)
                guard !Task.isCancelled else { return }
                self?.setAwake(false)
            }
            syncAwakeChip()
        }

        /// Switch the display option; a live hold is re-taken with the
        /// new kind so the change applies at once, deadline kept — the
        /// daemon's lease re-sent in the same shape, or the app's own
        /// assertion re-made.
        func setAwakeKeepsDisplay(_ on: Bool) {
            guard on != awakeKeepsDisplay else { return }
            awakeKeepsDisplay = on
            defaults.set(on, forKey: SystemTogglesStore.awakeDisplayDefaultsKey)
            if daemonLive, sendLease != nil, !awake.held, let hold = daemonHold, hold.isManual, let current = hold.lease {
                lease(CoreAwakeRequest(Self.sameShape(current), display: on), fallback: nil)
                return
            }
            guard awake.held else { return }
            releaseAssertion(awake.id)
            awake.held = false
            let until = awakeUntil
            let timer = awakeTimer
            awakeTimer = nil
            setAwake(true)
            if awake.held {
                awakeUntil = until
                awakeTimer = timer
            } else {
                timer?.cancel()
            }
            syncAwakeChip()
        }

        /// A lease the daemon holds, as the request that makes it again:
        /// a countdown keeps its end, an agents lease its sessions.
        static func sameShape(_ lease: CoreAwakeLease) -> CoreAwakeRequest.Shape {
            switch lease.kind {
            case "duration":
                return lease.until.map { .until($0) } ?? .indefinite
            case "agents":
                let sessions = lease.sessions ?? []
                return .untilAgentsFinish(sessions: sessions.isEmpty ? nil : sessions)
            default:
                return .indefinite
            }
        }

        // MARK: The daemon's hold

        /// Hand keep-awake to the daemon: the lease goes out as
        /// `hold_awake`/`release_awake`, and `state.power.hold` comes back
        /// as the chip's truth on every change.
        func attachLease(to core: CoreModel) {
            sendLease = { [weak core] request in
                guard let core else { return .unavailable }
                do {
                    let reply: CoreReply
                    if let request {
                        reply = try await core.holdAwake(request)
                    } else {
                        reply = try await core.releaseAwake()
                    }
                    return Self.answer(reply)
                } catch {
                    return .unavailable
                }
            }
            observeLease(core)
        }

        private func observeLease(_ core: CoreModel) {
            let live = core.isLive
            noteDaemonHold(live ? core.power?.hold : nil, live: live)
            withObservationTracking {
                _ = core.isLive
                _ = core.power?.hold
            } onChange: { [weak self, weak core] in
                Task { @MainActor [weak self, weak core] in
                    guard let self, let core else { return }
                    self.observeLease(core)
                }
            }
        }

        /// A reply as the chip reads it. A daemon too old for the lease
        /// answers `unknown_command` (or `unsupported`): the app's own
        /// assertion stands in, as it did before the lease existed.
        nonisolated static func answer(_ reply: CoreReply) -> LeaseAnswer {
            if reply.ok { return .taken }
            switch reply.error?.code {
            case "unknown_command", "unsupported": return .unavailable
            default: return .refused(reply.error?.message ?? "the monitor refused it.")
            }
        }

        /// The daemon's latest word on the hold. The moment it is back, a
        /// hold the app took while it was away becomes its lease — asked
        /// afresh of each connection, since the daemon may have changed.
        func noteDaemonHold(_ hold: CoreAwakeHold?, live: Bool) {
            if daemonHold != hold { daemonHold = hold }
            if daemonLive != live {
                if live { leaseUnsupported = false }
                daemonLive = live
            }
            if live, awake.held { handOver() }
            syncAwakeChip()
        }

        /// One hold, never two: the app's assertion becomes the daemon's
        /// lease (its deadline kept), then lets go. A lease the daemon
        /// already has — it survives a restart — stands, and the
        /// assertion simply lets go. A daemon that cannot take a lease
        /// is not asked again on every frame; the assertion stays.
        private func handOver() {
            guard !handingOver, !leaseUnsupported, let sendLease else { return }
            if daemonHold?.isManual == true {
                setAwake(false)
                return
            }
            let shape: CoreAwakeRequest.Shape = awakeUntil.map { .until($0.timeIntervalSince1970) } ?? .indefinite
            let request = CoreAwakeRequest(shape, display: awakeKeepsDisplay)
            handingOver = true
            Task { [weak self] in
                let answer = await sendLease(request)
                guard let self else { return }
                self.handingOver = false
                switch answer {
                case .taken: self.setAwake(false)
                case .unavailable: if self.daemonLive { self.leaseUnsupported = true }
                case .refused: break
                }
                self.syncAwakeChip()
            }
        }

        /// The chip's lit state and its countdown clock, from the one
        /// reading — every path that moves the hold ends here. Lit is the
        /// person's lease, the thing a tap flips; the agents' own hold
        /// and a pause for heat are the chip's word, not its light.
        func syncAwakeChip() {
            let reading = awakeReading
            if isOn[.keepAwake] != reading.leaseInForce { isOn[.keepAwake] = reading.leaseInForce }
            if reading.showsCountdown {
                guard awakeTick == nil else { return }
                awakeClock = Date()
                awakeTick = Task { [weak self] in
                    while !Task.isCancelled {
                        try? await Task.sleep(nanoseconds: 20_000_000_000)
                        guard !Task.isCancelled, let self else { return }
                        self.awakeClock = Date()
                    }
                }
            } else {
                awakeTick?.cancel()
                awakeTick = nil
            }
        }

        deinit {
            if awake.held { IOPMAssertionRelease(awake.id) }
        }
    }

    /// The box `deinit` reads — mutated only on the actor, so the
    /// unchecked-Sendable is disciplined by construction.
    final class AwakeAssertion: @unchecked Sendable {
        var id: IOPMAssertionID = 0
        var held = false
    }

    let state: State
    private var dockDriver: (any DockAutohideDriver)? { state.dockDriver }
    private func dockHoldActive() -> Bool { state.dockHoldActive() }

    init(state: State = .shared) {
        self.state = state
    }

    var isOn: [SystemToggle: Bool] { state.isOn }
    var applying: Set<SystemToggle> { state.applying }
    var lastError: String? { state.lastError }
    var strip: [SystemToggle] { state.strip }
    /// The line under the strip: a refusal first, else the last verb's
    /// report.
    var caption: String? { state.lastError ?? state.lastNote }
    /// When the keep-awake countdown ends — the daemon's lease or the
    /// app's own; nil while it is not a countdown.
    var awakeUntil: Date? {
        if case .lease(.until(let end)) = state.awakeReading.state { return end }
        return nil
    }
    var awakeKeepsDisplay: Bool { state.awakeKeepsDisplay }

    /// The chip's word — the Lock chip says "Display" when display
    /// sleep does not actually lock; Awake names the hold's state (a
    /// countdown, the agents holding it, paused by the heat).
    func title(for toggle: SystemToggle) -> String {
        switch toggle {
        case .lock: return SystemToggle.lockTitle(delay: state.lockDelay)
        case .keepAwake: return state.awakeReading.chipTitle(now: state.awakeClock)
        default: return toggle.title
        }
    }

    /// The chip's tooltip, with the facts only the store knows.
    func help(for toggle: SystemToggle) -> String {
        if toggle == .keepAwake {
            var reading = state.awakeReading
            // Off, the tooltip says what a click would hold.
            if reading.state == .off { reading.display = state.awakeKeepsDisplay }
            return reading.chipHelp(now: state.awakeClock)
        }
        return toggle.help(on: state.isOn[toggle] ?? false, lockDelay: state.lockDelay,
                           awakeKeepsDisplay: state.awakeKeepsDisplay)
    }

    nonisolated static let awakeDisplayDefaultsKey = "keepAwakeDisplay"

    /// Keep awake for `seconds`, indefinitely (nil), or let go (0).
    func holdAwake(seconds: Int?) { state.holdAwake(seconds: seconds) }
    /// Keep awake until the agents working now finish.
    func holdAwakeUntilAgentsFinish() { state.holdAwakeUntilAgentsFinish() }
    func setAwakeKeepsDisplay(_ on: Bool) { state.setAwakeKeepsDisplay(on) }

    /// A link's or a Shortcut's `on=` for Awake: the person's lease, on
    /// or off, left alone when it is already there. The agents' own hold
    /// is not a link's to end — the caption says whose it is instead of
    /// pretending the switch moved.
    private func setAwake(_ on: Bool) {
        let reading = state.awakeReading
        if on != reading.leaseInForce {
            state.holdAwake(seconds: on ? nil : 0)
        } else if !on, case .agents = reading.state {
            state.lastNote = "Awake: the agents hold it until they stop — their switch is under Settings › Notifications › Power."
        }
    }

    private nonisolated static let log = Logger(
        subsystem: "devin.jrbar", category: "toggles")

    // MARK: - The strip

    nonisolated static let stripDefaultsKey = "systemToggleStrip"

    nonisolated static func loadStrip(defaults: UserDefaults = .standard) -> [SystemToggle] {
        guard let raw = defaults.array(forKey: stripDefaultsKey) as? [String] else {
            return SystemToggle.defaultStrip
        }
        return SystemToggle.strip(fromStored: raw)
    }

    /// Show or hide one chip on the strip; a chip joining lands at its
    /// canonical place, so the strip keeps One Switch's stable order.
    func setInStrip(_ toggle: SystemToggle, _ shown: Bool) {
        var set = Set(state.strip)
        if shown { set.insert(toggle) } else { set.remove(toggle) }
        let next = SystemToggle.allCases.filter(set.contains)
        guard next != state.strip else { return }
        state.strip = next
        state.defaults.set(next.map(\.rawValue), forKey: Self.stripDefaultsKey)
    }

    // MARK: - Reads

    /// Re-read every stateful toggle's truth — on card show, and
    /// after an apply settles. In-process reads answer inline; the
    /// `defaults` probes run detached — a card show must not pay for
    /// process lifetimes on the render path. The first call also starts
    /// the system listeners, so a chip follows F10 or Control Center
    /// while the card is open instead of going stale.
    func refresh() {
        startListening()
        for toggle in SystemToggle.allCases where !toggle.isMomentary {
            refresh(toggle)
        }
        // The Lock chip's word: `sysadminctl` reads the password delay
        // unprivileged; a changed Lock Screen setting shows on the next
        // card open.
        Task {
            let output = await Task.detached {
                Self.shellWithError("/usr/sbin/sysadminctl -screenLock status 2>&1").output
            }.value
            state.lockDelay = output.flatMap(SystemToggle.screenLockDelay(fromSysadminctl:))
        }
    }

    private func refresh(_ toggle: SystemToggle) {
        if let inline = readInline(toggle) {
            state.isOn[toggle] = inline
        } else {
            Task {
                let value = await Task.detached { Self.probe(toggle) }.value
                state.isOn[toggle] = value
            }
        }
    }

    /// The reads that cost no process: our own bookkeeping, a domain
    /// lookup, a CoreAudio property, the Dock's own live flag. `nil`
    /// means "probe it off-actor".
    private func readInline(_ toggle: SystemToggle) -> Bool? {
        switch toggle {
        case .keepAwake:
            return state.awakeReading.leaseInForce
        case .darkMode:
            // The global domain's answer — "Dark" present means on;
            // absent means light. No process needed.
            return (UserDefaults.standard.persistentDomain(
                forName: UserDefaults.globalDomain)?["AppleInterfaceStyle"] as? String) == "Dark"
        case .mute:
            return AudioMute.isMuted(.output, defaults: state.defaults)
        case .micMute:
            return AudioMute.isMuted(.input, defaults: state.defaults)
        case .dockAutoHide:
            return dockDriver?.isAutohideEnabled
        default:
            return nil
        }
    }

    /// The `defaults read` probe — detached callers only: a process
    /// launch has no business on the render path.
    private nonisolated static func probe(_ toggle: SystemToggle) -> Bool {
        guard let probe = toggle.defaultsProbe else { return false }
        let out = shell("defaults read \(probe.domain) \(probe.key)")
        return SystemToggle.readMaps(out, onWhenAbsent: probe.onWhenAbsent)
    }

    // MARK: - Listening (the system tells us, nothing polls)

    /// Appearance and output mute can change under the strip — F10, the
    /// Control Center module, System Settings. The distributed
    /// appearance notification and a CoreAudio listener on the default
    /// output (re-armed when the default device changes) keep those
    /// chips true without a poll.
    private func startListening() {
        guard !state.listening else { return }
        state.listening = true
        let state = self.state
        DistributedNotificationCenter.default().addObserver(
            forName: Notification.Name("AppleInterfaceThemeChangedNotification"),
            object: nil, queue: .main) { _ in
                MainActor.assumeIsolated {
                    state.isOn[.darkMode] = (UserDefaults.standard.persistentDomain(
                        forName: UserDefaults.globalDomain)?["AppleInterfaceStyle"] as? String) == "Dark"
                }
            }
        AudioListener.shared.onChange = {
            Task { @MainActor in
                state.isOn[.mute] = AudioMute.isMuted(.output, defaults: state.defaults)
                state.isOn[.micMute] = AudioMute.isMuted(.input, defaults: state.defaults)
            }
        }
        AudioListener.shared.start()
    }

    // MARK: - Applies

    /// A chip tap: momentary verbs fire, stateful toggles flip and
    /// read back. One apply per toggle at a time — a double-tap waits
    /// for the read-back rather than racing the system.
    func apply(_ toggle: SystemToggle) {
        guard !state.applying.contains(toggle) else { return }
        state.lastNote = nil
        switch toggle {
        case .keepAwake:
            // The chip toggles the person's lease. With only the agents
            // holding the Mac it takes one, so it stays awake after they
            // finish; their own hold keeps its switch in Settings.
            state.holdAwake(seconds: state.awakeReading.leaseInForce ? 0 : nil)
            return
        case .mute, .micMute:
            let scope: AudioMute.Scope = toggle == .mute ? .output : .input
            let next = !AudioMute.isMuted(scope, defaults: state.defaults)
            if AudioMute.setMuted(next, scope, defaults: state.defaults) {
                state.lastError = nil
                state.isOn[toggle] = AudioMute.isMuted(scope, defaults: state.defaults)
            } else {
                state.lastError = scope == .output
                    ? "This output has no mute or volume to set."
                    : "This microphone has no mute or input level to set."
            }
            return
        case .lock, .screenSaver, .sleep:
            fire(toggle, on: true)
            return
        case .eject:
            ejectAll()
            return
        case .darkMode:
            // A refused Automation grant is said up front instead of
            // failing inside `osascript` (or raising a surprise prompt
            // the chip never mentioned).
            state.applying.insert(.darkMode)
            Task {
                let permission = await Task.detached { AutomationPermission.systemEvents(ask: false) }.value
                state.applying.remove(.darkMode)
                if permission == .denied {
                    state.lastError = AutomationPermission.deniedSentence
                    return
                }
                let current = readInline(.darkMode) ?? false
                fire(.darkMode, on: !current)
            }
            return
        case .dockAutoHide:
            setDockAutohide(!(readInline(.dockAutoHide) ?? state.isOn[.dockAutoHide] ?? false))
            return
        default:
            if let current = state.isOn[toggle] ?? readInline(toggle) {
                fire(toggle, on: !current)
            } else {
                // No read yet — probe off-actor before deciding the flip.
                Task {
                    let current = await Task.detached { Self.probe(toggle) }.value
                    state.isOn[toggle] = current
                    fire(toggle, on: !current)
                }
            }
        }
    }

    /// Set a stateful toggle to `on` — a link's `?on=1`, a Shortcuts
    /// action — or fire a verb. A toggle already there is left alone
    /// (no Finder restart for nothing).
    func set(_ toggle: SystemToggle, on: Bool) {
        guard !toggle.isMomentary else {
            if on { apply(toggle) }
            return
        }
        if toggle == .keepAwake {
            setAwake(on)
            return
        }
        if let current = state.isOn[toggle] ?? readInline(toggle), current == on { return }
        if state.isOn[toggle] == nil, readInline(toggle) == nil {
            Task {
                let current = await Task.detached { Self.probe(toggle) }.value
                state.isOn[toggle] = current
                if current != on { apply(toggle) }
            }
            return
        }
        apply(toggle)
    }

    /// A shell-backed flip: run detached, read the truth back after
    /// the settle beat (Finder relaunches take a moment), and keep any
    /// stderr honest — a refused write lands in `lastError`.
    private func fire(_ toggle: SystemToggle, on: Bool, command override: String? = nil,
                      fallback: String? = nil) {
        guard let command = override ?? toggle.applyCommand(on: on) else { return }
        state.applying.insert(toggle)
        state.lastError = nil
        Task {
            var result = await Task.detached {
                Self.shellWithError(command)
            }.value
            if result.error != nil, let fallback {
                // The public path was refused (no Automation grant, most
                // likely): the last resort still gets the choice through.
                result = await Task.detached { Self.shellWithError(fallback) }.value
            }
            state.applying.remove(toggle)
            if let error = result.error, !error.isEmpty {
                state.lastError = "\(toggle.title): \(error)"
                Self.log.notice("toggle \(toggle.rawValue, privacy: .public) failed: \(error, privacy: .public)")
            }
            // The read-back is the truth — the chip settles to what
            // the system reports, not what we asked for.
            if !toggle.isMomentary {
                try? await Task.sleep(nanoseconds: 600_000_000)
                if let inline = readInline(toggle) {
                    state.isOn[toggle] = inline
                } else {
                    state.isOn[toggle] = await Task.detached { Self.probe(toggle) }.value
                }
            }
        }
    }

    // MARK: - Dock autohide (live, never a Dock restart when avoidable)

    /// The Dock chip rides the Dock utility's own live driver — the
    /// `CoreDock` pair its preview hold uses — so the Dock hides or
    /// shows in place, with no relaunch, no Mission Control reset and
    /// no break in the utility's AX observation. System Events is the
    /// public fallback; `defaults` plus `killall Dock` only the last.
    ///
    /// While the preview holds the Dock out, the choice waits: flipping
    /// under a hold would be undone by the hold's restore, so it lands
    /// the moment the hold lets go.
    private func setDockAutohide(_ on: Bool) {
        state.lastError = nil
        if dockHoldActive() {
            state.pendingDockAutohide = on
            state.lastError = "Dock: applies when the preview closes."
            waitForDockHold()
            return
        }
        if let dockDriver {
            dockDriver.setAutohideEnabled(on)
            state.isOn[.dockAutoHide] = dockDriver.isAutohideEnabled
            if dockDriver.isAutohideEnabled != on {
                state.lastError = "Dock: the Dock kept its setting."
            }
            return
        }
        fire(.dockAutoHide, on: on, command: SystemToggle.dockAutoHide.liveApplyCommand(on: on),
             fallback: SystemToggle.dockAutoHide.applyCommand(on: on))
    }

    private func waitForDockHold(attempt: Int = 0) {
        Task {
            try? await Task.sleep(nanoseconds: 250_000_000)
            guard let pending = state.pendingDockAutohide else { return }
            if dockHoldActive(), attempt < 480 {
                waitForDockHold(attempt: attempt + 1)
                return
            }
            state.pendingDockAutohide = nil
            setDockAutohide(pending)
        }
    }

    // MARK: - Eject (NSWorkspace — public, SidePulse-aware)

    /// Alfred's Eject All without its wildcard list: every local,
    /// removable or ejectable volume goes, except a SidePulse strip —
    /// by its volume name, or because the daemon lists the mount as a
    /// connected device. The strip is the light; ejecting it would
    /// dark the desk mid-run. Unmounts run detached (a busy disk can
    /// take seconds to refuse) and the caption says what went.
    private func ejectAll() {
        state.applying.insert(.eject)
        state.lastError = nil
        let protected = Set(state.protectedVolumePaths())
        Task {
            let outcome = await Task.detached { Self.ejectRemovableVolumes(protectedPaths: protected) }.value
            state.applying.remove(.eject)
            state.lastNote = SystemToggle.ejectSummary(ejected: outcome.ejected, refused: outcome.refused,
                                                       keptLED: outcome.keptLED)
            if !outcome.refused.isEmpty, outcome.ejected.isEmpty {
                state.lastError = state.lastNote
                state.lastNote = nil
            }
        }
    }

    private nonisolated static func ejectRemovableVolumes(protectedPaths: Set<String>)
        -> (ejected: [String], refused: [(name: String, reason: String)], keptLED: [String]) {
        let keys: [URLResourceKey] = [.volumeNameKey, .volumeIsEjectableKey, .volumeIsRemovableKey,
                                      .volumeIsInternalKey, .volumeIsLocalKey, .volumeIsRootFileSystemKey]
        let urls = FileManager.default.mountedVolumeURLs(includingResourceValuesForKeys: keys,
                                                         options: [.skipHiddenVolumes]) ?? []
        var ejected: [String] = []
        var refused: [(name: String, reason: String)] = []
        var kept: [String] = []
        for url in urls {
            guard let values = try? url.resourceValues(forKeys: Set(keys)) else { continue }
            let facts = SystemToggle.VolumeFacts(
                name: values.volumeName ?? url.lastPathComponent,
                path: url.path,
                ejectable: values.volumeIsEjectable ?? false,
                removable: values.volumeIsRemovable ?? false,
                isInternal: values.volumeIsInternal ?? false,
                local: values.volumeIsLocal ?? false,
                root: values.volumeIsRootFileSystem ?? false)
            guard SystemToggle.shouldEject(facts, protectedPaths: protectedPaths) else {
                if facts.ejectable || facts.removable,
                   SystemToggle.isLEDVolume(name: facts.name) || protectedPaths.contains(facts.path) {
                    kept.append(facts.name)
                }
                continue
            }
            do {
                try NSWorkspace.shared.unmountAndEjectDevice(at: url)
                ejected.append(facts.name)
            } catch {
                refused.append((facts.name, (error as NSError).localizedFailureReason
                                    ?? "it is in use"))
            }
        }
        return (ejected, refused, kept)
    }

    // MARK: - Processes

    /// `defaults read`-style probe: stdout on success, nil on any
    /// failure — the caller's `onWhenAbsent` decides what absent means.
    private nonisolated static func shell(_ command: String) -> String? {
        shellWithError(command).output
    }

    /// Run a `/bin/sh -c` payload with a hard ceiling — a pended TCC
    /// prompt or a stuck AppleScript must not hang the toggle row.
    /// Both pipes drain on background queues so a chatty command can't
    /// deadlock on a full pipe (the script-trigger lesson), and the
    /// exit semaphore is what bounds the wait — never the drain.
    nonisolated static func shellWithError(
        _ command: String, timeout: TimeInterval = 8
    ) -> (output: String?, error: String?) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", command]
        let out = Pipe(), err = Pipe()
        process.standardOutput = out
        process.standardError = err
        do { try process.run() } catch { return (nil, nil) }
        let drain = PipeDrain()
        let drained = DispatchGroup()
        drained.enter()
        DispatchQueue.global().async {
            drain.out = out.fileHandleForReading.readDataToEndOfFile()
            drained.leave()
        }
        drained.enter()
        DispatchQueue.global().async {
            drain.err = err.fileHandleForReading.readDataToEndOfFile()
            drained.leave()
        }
        let exited = DispatchSemaphore(value: 0)
        DispatchQueue.global().async {
            process.waitUntilExit()
            exited.signal()
        }
        if exited.wait(timeout: .now() + timeout) == .timedOut {
            process.terminate()
            _ = drained.wait(timeout: .now() + 1)
            return (nil, "timed out")
        }
        drained.wait()
        guard process.terminationStatus == 0 else {
            let text = String(data: drain.err, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            return (nil, text?.isEmpty == false ? text : "exited \(process.terminationStatus)")
        }
        return (String(data: drain.out, encoding: .utf8), nil)
    }

    /// The bag two drain queues fill while the caller waits on the
    /// child's exit — the group's `wait` orders the reads back.
    private final class PipeDrain: @unchecked Sendable {
        var out = Data()
        var err = Data()
    }
}

/// CoreAudio's change callbacks for the chips that mirror audio state:
/// the default output (and input) device, and the mute property on
/// whichever device is default now. One listener set per app; the
/// device listeners move when the default device does.
final class AudioListener: @unchecked Sendable {
    static let shared = AudioListener()

    /// Any watched property changed. Called on the listener queue.
    var onChange: (@Sendable () -> Void)?

    private let queue = DispatchQueue(label: "devin.jrbar.toggles.audio")
    private var started = false
    private var watchedDevices: [(device: AudioObjectID, address: AudioObjectPropertyAddress)] = []
    private lazy var deviceBlock: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
        self?.onChange?()
    }
    private lazy var systemBlock: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
        self?.rewatchDevices()
        self?.onChange?()
    }

    private static let systemSelectors: [AudioObjectPropertySelector] = [
        kAudioHardwarePropertyDefaultOutputDevice,
        kAudioHardwarePropertyDefaultInputDevice,
    ]

    func start() {
        queue.async { [self] in
            guard !started else { return }
            started = true
            for selector in Self.systemSelectors {
                var address = AudioObjectPropertyAddress(
                    mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal,
                    mElement: kAudioObjectPropertyElementMain)
                AudioObjectAddPropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject),
                                                    &address, queue, systemBlock)
            }
            rewatchDevices()
        }
    }

    /// Runs on `queue`: drop the old device listeners, add them on the
    /// current default output and input.
    private func rewatchDevices() {
        for var watched in watchedDevices {
            AudioObjectRemovePropertyListenerBlock(watched.device, &watched.address, queue, deviceBlock)
        }
        watchedDevices = []
        let targets: [(AudioObjectPropertySelector, AudioObjectPropertyScope)] = [
            (kAudioHardwarePropertyDefaultOutputDevice, kAudioObjectPropertyScopeGlobal),
            (kAudioHardwarePropertyDefaultInputDevice, kAudioDevicePropertyScopeInput),
        ]
        for (selector, scope) in targets {
            guard let device = Self.defaultDevice(selector) else { continue }
            for property in [kAudioDevicePropertyMute, kAudioDevicePropertyVolumeScalar] {
                var address = AudioObjectPropertyAddress(
                    mSelector: property, mScope: scope, mElement: kAudioObjectPropertyElementMain)
                guard AudioObjectHasProperty(device, &address) else { continue }
                if AudioObjectAddPropertyListenerBlock(device, &address, queue, deviceBlock) == noErr {
                    watchedDevices.append((device, address))
                }
            }
        }
    }

    static func defaultDevice(_ selector: AudioObjectPropertySelector) -> AudioObjectID? {
        CoreAudioDefaults.defaultDevice(selector)
    }
}

/// Mute for the default output or microphone, with the fallback One
/// Switch and Raycast lack: a device with no settable mute property
/// (many displays, AirPlay, some USB microphones) is muted by taking its
/// level to zero and remembering the old level, per device, to put
/// back — instead of the chip answering "no device to mute".
enum AudioMute {
    enum Scope: String, Sendable {
        case output, input

        var defaultDeviceSelector: AudioObjectPropertySelector {
            self == .output ? kAudioHardwarePropertyDefaultOutputDevice
                : kAudioHardwarePropertyDefaultInputDevice
        }

        /// Where the device's mute and level live: output devices
        /// mostly answer on the global scope, inputs on the input scope.
        var propertyScopes: [AudioObjectPropertyScope] {
            self == .output
                ? [kAudioObjectPropertyScopeGlobal, kAudioDevicePropertyScopeOutput]
                : [kAudioDevicePropertyScopeInput, kAudioObjectPropertyScopeGlobal]
        }

        var levelScope: AudioObjectPropertyScope {
            self == .output ? kAudioDevicePropertyScopeOutput : kAudioDevicePropertyScopeInput
        }
    }

    /// The saved level's defaults key — per scope and device, so an
    /// unmute on AirPods never restores the display's old level.
    nonisolated static func savedLevelKey(uid: String, scope: Scope) -> String {
        "audioMute.savedLevel.\(scope.rawValue).\(uid)"
    }

    /// Muted now: the device's own mute flag where it has one; else
    /// its level at zero with a saved level to return to (a level the
    /// person turned to zero by hand is not "our" mute).
    nonisolated static func isMuted(_ scope: Scope, defaults: UserDefaults) -> Bool {
        guard let device = AudioListener.defaultDevice(scope.defaultDeviceSelector) else { return false }
        if let muted = readMuteFlag(device, scope) { return muted }
        guard let uid = uid(of: device), defaults.object(forKey: savedLevelKey(uid: uid, scope: scope)) != nil,
              let level = readLevel(device, scope) else { return false }
        return level <= 0.001
    }

    /// Set mute. False when the device offers neither a settable mute
    /// nor a settable level — the chip then says so.
    nonisolated static func setMuted(_ muted: Bool, _ scope: Scope, defaults: UserDefaults) -> Bool {
        guard let device = AudioListener.defaultDevice(scope.defaultDeviceSelector) else { return false }
        if writeMuteFlag(device, scope, muted) { return true }
        guard let uid = uid(of: device), let level = readLevel(device, scope),
              levelIsSettable(device, scope) else { return false }
        let key = savedLevelKey(uid: uid, scope: scope)
        if muted {
            if level > 0.001 {
                defaults.set(Double(level), forKey: key)
            } else if defaults.object(forKey: key) == nil {
                defaults.set(0.5, forKey: key)
            }
            return writeLevel(device, scope, 0)
        }
        let restore = defaults.object(forKey: key) as? Double ?? 0.5
        defaults.removeObject(forKey: key)
        return writeLevel(device, scope, Float32(min(1, max(0.05, restore))))
    }

    // MARK: CoreAudio

    private nonisolated static func muteAddress(_ scope: AudioObjectPropertyScope) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyMute, mScope: scope,
                                   mElement: kAudioObjectPropertyElementMain)
    }

    private nonisolated static func readMuteFlag(_ device: AudioObjectID, _ scope: Scope) -> Bool? {
        for propertyScope in scope.propertyScopes {
            if let muted = CoreAudioDefaults.muted(of: device, scope: propertyScope) { return muted }
        }
        return nil
    }

    private nonisolated static func writeMuteFlag(_ device: AudioObjectID, _ scope: Scope, _ muted: Bool) -> Bool {
        for propertyScope in scope.propertyScopes {
            var address = muteAddress(propertyScope)
            guard AudioObjectHasProperty(device, &address) else { continue }
            var settable = DarwinBoolean(false)
            guard AudioObjectIsPropertySettable(device, &address, &settable) == noErr, settable.boolValue else { continue }
            var value: UInt32 = muted ? 1 : 0
            if AudioObjectSetPropertyData(device, &address, 0, nil,
                                          UInt32(MemoryLayout<UInt32>.size), &value) == noErr {
                return true
            }
        }
        return false
    }

    private nonisolated static func levelAddress(_ scope: Scope) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: kAudioHardwareServiceDeviceProperty_VirtualMainVolume,
                                   mScope: scope.levelScope, mElement: kAudioObjectPropertyElementMain)
    }

    private nonisolated static func readLevel(_ device: AudioObjectID, _ scope: Scope) -> Float32? {
        var address = levelAddress(scope)
        guard AudioObjectHasProperty(device, &address) else { return nil }
        var level: Float32 = 0
        var size = UInt32(MemoryLayout<Float32>.size)
        guard AudioObjectGetPropertyData(device, &address, 0, nil, &size, &level) == noErr else { return nil }
        return level
    }

    private nonisolated static func levelIsSettable(_ device: AudioObjectID, _ scope: Scope) -> Bool {
        var address = levelAddress(scope)
        var settable = DarwinBoolean(false)
        return AudioObjectIsPropertySettable(device, &address, &settable) == noErr && settable.boolValue
    }

    private nonisolated static func writeLevel(_ device: AudioObjectID, _ scope: Scope, _ level: Float32) -> Bool {
        var address = levelAddress(scope)
        var value = level
        return AudioObjectSetPropertyData(device, &address, 0, nil,
                                          UInt32(MemoryLayout<Float32>.size), &value) == noErr
    }

    private nonisolated static func uid(of device: AudioObjectID) -> String? {
        CoreAudioDefaults.uid(of: device)
    }
}

/// Whether JR-Bar may send System Events Apple Events — the grant the
/// Dark chip (and the Dock chip's fallback) run on. Read without asking
/// before a flip, so a refusal is said on the chip instead of failing
/// inside `osascript`; asked for explicitly only from Setup.
enum AutomationPermission: Equatable, Sendable {
    case granted
    /// Never asked: the first use will raise macOS's prompt.
    case needsConsent
    case denied
    /// System Events is not running, so macOS cannot say yet.
    case unavailable

    nonisolated static let systemEventsBundleID = "com.apple.systemevents"
    nonisolated static let settingsURL = URL(
        string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Automation")!
    nonisolated static let deniedSentence =
        "JR-Bar may not control System Events — allow it in Privacy & Security › Automation."

    /// `ask: true` blocks until the person answers the prompt — call it
    /// off the main thread.
    nonisolated static func systemEvents(ask: Bool) -> AutomationPermission {
        let target = NSAppleEventDescriptor(bundleIdentifier: systemEventsBundleID)
        guard let desc = target.aeDesc else { return .unavailable }
        return classify(AEDeterminePermissionToAutomateTarget(desc, typeWildCard, typeWildCard, ask))
    }

    nonisolated static func classify(_ status: OSStatus) -> AutomationPermission {
        switch status {
        case noErr: return .granted
        case OSStatus(errAEEventWouldRequireUserConsent): return .needsConsent
        case OSStatus(errAEEventNotPermitted): return .denied
        default: return .unavailable
        }
    }
}
