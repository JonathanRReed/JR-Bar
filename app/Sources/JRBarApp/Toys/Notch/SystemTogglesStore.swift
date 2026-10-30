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
        /// Not connected, or a daemon without the lease: the app's own
        /// assertion stands in.
        case unavailable
        /// The request went out and no usable answer came back (a
        /// dropped connection, a timeout). The daemon may well hold the
        /// lease, so the app takes no second hold and does not conclude
        /// the daemon is too old; it says so and the next tap asks again.
        case failed(String)
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
        @ObservationIgnored var pendingShellTargets: [SystemToggle: Bool] = [:]
        @ObservationIgnored var shellTasks: [SystemToggle: Task<Void, Never>] = [:]
        @ObservationIgnored var refreshOwners: [SystemToggle: UUID] = [:]
        @ObservationIgnored var runCommand: @MainActor (String) async -> (output: String?, error: String?) = { command in
            await Task.detached { SystemTogglesStore.shellWithError(command) }.value
        }
        @ObservationIgnored var readToggle: @MainActor (SystemToggle) async -> Bool = { toggle in
            await Task.detached { SystemTogglesStore.probe(toggle) }.value
        }
        @ObservationIgnored var automationPermission: @MainActor () async -> AutomationPermission = {
            await Task.detached { AutomationPermission.systemEvents(ask: false) }.value
        }
        @ObservationIgnored var settleShell: @MainActor () async -> Void = {
            try? await Task.sleep(nanoseconds: 600_000_000)
        }
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
        /// When the app's own timed hold began, for the cup's steam.
        @ObservationIgnored var awakeStarted: Date?
        /// The app's own last hold, for Try again: seconds, or nil for
        /// until turned off.
        @ObservationIgnored private var lastLocalSeconds: Int?
        /// The five-minute heads-up before a timed session ends: one
        /// scheduled event, re-planned only when the hold moves.
        @ObservationIgnored let headsUp: KeepAwakeHeadsUpScheduler
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
        private var awakeReleaseFailed = false
        // A failed release preserves ownership, not a request to keep holding.
        private var awakeRequested = false

        /// The daemon's hold (`state.power.hold`) as last published, and
        /// whether the daemon is there at all; while it is, this is the
        /// chip's truth.
        private(set) var daemonHold: CoreAwakeHold?
        private(set) var daemonLive = false
        @ObservationIgnored private var daemonHello: CoreHello?
        /// Sends the person's lease: a request is `hold_awake`, nil is
        /// `release_awake`. Wired by `attachLease`; nil keeps every hold
        /// on the app's own assertion.
        @ObservationIgnored private var leaseRevision = 0
        @ObservationIgnored private(set) var leaseTask: Task<Void, Never>?
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
        @ObservationIgnored private(set) var handoverTask: Task<Void, Never>?
        @ObservationIgnored private var handoverRevision = 0
        @ObservationIgnored private var handoverRequest: CoreAwakeRequest?
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
        @ObservationIgnored var releaseAssertion: @MainActor (IOPMAssertionID) -> IOReturn = { IOPMAssertionRelease($0) }

        /// The one hold as the chip draws it: the daemon's while it is
        /// connected, else the app's own — and the app's own whenever it
        /// holds one, so an assertion the daemon could not take is never
        /// held out of sight of the switch that lets it go.
        var awakeReading: KeepAwakeReading {
            if daemonLive && !awake.held { return KeepAwakeReading(hold: daemonHold) }
            var reading = KeepAwakeReading(localHeld: awake.held, until: awakeUntil, display: awakeKeepsDisplay,
                                           startedAt: awakeUntil == nil ? nil : awakeStarted)
            reading.releaseFailed = awakeReleaseFailed
            return reading
        }

        /// A Dock choice made while the Dock utility's preview holds the
        /// Dock out: applied the moment the hold lets go, so the hold's
        /// restore can never undo it.
        @ObservationIgnored var pendingDockAutohide: Bool?
        @ObservationIgnored var listening = false
        @ObservationIgnored var listenerOwners: Set<UUID> = []
        @ObservationIgnored var appearanceObserver: NSObjectProtocol?
        @ObservationIgnored var appearanceCenter: NotificationCenter = DistributedNotificationCenter.default()
        @ObservationIgnored var startAudio: @MainActor () -> Void = { AudioListener.shared.start() }
        @ObservationIgnored var stopAudio: @MainActor () -> Void = { AudioListener.shared.stop() }

        /// The Dock's live `autohide` pair (`CoreDock`, the one the Dock
        /// utility's preview hold uses) — nil on a build where it does
        /// not resolve, and then System Events, and only last `defaults`
        /// plus a Dock restart.
        @ObservationIgnored let dockDriver: (any DockAutohideDriver)?
        /// Is the Dock utility holding the Dock out for a preview right
        /// now? Wired by the delegate; a chip flip during a hold waits.
        @ObservationIgnored var scheduleDockRetry: (@escaping @MainActor () -> Void) -> Void = { retry in
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { retry() }
        }
        @ObservationIgnored var dockHoldActive: @MainActor () -> Bool = { false }

        /// Where the strip's chip choice persists — app-local defaults;
        /// a test hands in its own suite.
        @ObservationIgnored let defaults: UserDefaults

        init(dockDriver: (any DockAutohideDriver)? = CoreDockAutohideDriver(),
             defaults: UserDefaults = .standard) {
            self.dockDriver = dockDriver
            self.defaults = defaults
            self.strip = SystemTogglesStore.loadStrip(defaults: defaults)
            SystemTogglesStore.migrateAwakeDisplay(defaults)
            self.awakeKeepsDisplay = defaults.bool(forKey: SystemTogglesStore.awakeDisplayDefaultsKey)
            self.headsUp = KeepAwakeHeadsUpScheduler(defaults: defaults)
        }

        /// Take or drop the app's own keep-awake assertion — the fallback
        /// while the daemon is away. The kind follows `awakeKeepsDisplay`:
        /// the Mac only (the display still sleeps and locks), or the
        /// display too.
        func setAwake(_ hold: Bool) {
            awakeRequested = hold
            if hold && !awake.held {
                let kind = awakeKeepsDisplay
                    ? kIOPMAssertionTypePreventUserIdleDisplaySleep
                    : kIOPMAssertionTypeNoIdleSleep
                if let assertion = takeAssertion(kind as CFString) {
                    awake.id = assertion
                    awake.held = true
                    awakeReleaseFailed = false
                    if lastError?.hasPrefix("Awake:") == true { lastError = nil }
                } else {
                    lastError = Self.refusedAssertion
                }
            } else if !hold && awake.held {
                _ = releaseLocalAwake()
            } else if hold && awakeReleaseFailed {
                awakeReleaseFailed = false
                if lastError?.hasPrefix("Awake:") == true { lastError = nil }
            }
            if !awake.held || !awakeRequested {
                awakeTimer?.cancel()
                awakeTimer = nil
                awakeUntil = nil
            }
            updateHandoverIntent()
            syncAwakeChip()
        }

        private func releaseLocalAwake() -> Bool {
            guard releaseAssertion(awake.id) == kIOReturnSuccess else {
                awakeReleaseFailed = true
                lastError = "Awake: could not stop its hold. Try turning it off again."
                return false
            }
            awake.id = 0
            awake.held = false
            awakeReleaseFailed = false
            if lastError?.hasPrefix("Awake:") == true { lastError = nil }
            return true
        }

        /// Hold for `seconds`, indefinitely (nil), or let go (0) —
        /// Amphetamine's session vocabulary on the one hold: the daemon's
        /// lease while it is connected and can take one, the app's
        /// assertion otherwise — and the assertion's own switch while the
        /// app holds it, so a tap always moves the hold the chip shows.
        func holdAwake(seconds: Int?) {
            if handingOver {
                holdLocally(seconds: seconds)
                return
            }
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
            if handingOver {
                handoverRevision += 1
                handoverRequest = request
                return
            }
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
            leaseRevision += 1
            let revision = leaseRevision
            applying.insert(.keepAwake)
            leaseTask = Task { [weak self] in
                let answer = await sendLease(request)
                guard let self, revision == self.leaseRevision else { return }
                self.leaseTask = nil
                self.applying.remove(.keepAwake)
                switch answer {
                case .taken:
                    if self.lastError?.hasPrefix("Awake:") == true { self.lastError = nil }
                    taken?()
                case .refused(let why):
                    self.lastError = "Awake: \(why)"
                case .failed(let why):
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
            lastLocalSeconds = seconds
            setAwake(true)
            guard let seconds, awake.held else { return }
            awakeStarted = Date()
            awakeUntil = Date().addingTimeInterval(TimeInterval(seconds))
            awakeTimer = Task { [weak self] in
                try? await Task.sleep(nanoseconds: UInt64(seconds) * 1_000_000_000)
                guard !Task.isCancelled else { return }
                self?.setAwake(false)
            }
            updateHandoverIntent()
            syncAwakeChip()
        }

        /// Switch the display option; a live hold is re-taken with the
        /// new kind so the change applies at once, deadline kept — the
        /// daemon's lease re-sent in the same shape, or the app's own
        /// assertion re-made.
        func setAwakeKeepsDisplay(_ on: Bool) {
            guard on != awakeKeepsDisplay else { return }
            let wasHeld = awake.held
            if wasHeld && !releaseLocalAwake() {
                syncAwakeChip()
                return
            }
            let pendingShape = handingOver ? handoverRequest?.shape : nil
            awakeKeepsDisplay = on
            defaults.set(on, forKey: SystemTogglesStore.awakeDisplayDefaultsKey)
            if handingOver, let request = handoverRequest {
                handoverRevision += 1
                handoverRequest = CoreAwakeRequest(request.shape, display: on)
            }
            if !handingOver, daemonLive, sendLease != nil, !wasHeld, let hold = daemonHold, hold.isManual, let current = hold.lease {
                lease(CoreAwakeRequest(Self.sameShape(current), display: on), fallback: nil)
                return
            }
            guard wasHeld && awakeRequested else {
                syncAwakeChip()
                return
            }
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
            if handingOver, let pendingShape {
                handoverRevision += 1
                handoverRequest = CoreAwakeRequest(pendingShape, display: on)
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
            case "process":
                return lease.pid.map { .whileRunning(pid: $0, label: lease.label) } ?? .indefinite
            default:
                return .indefinite
            }
        }

        // MARK: Extend and try again

        /// "+30 min" on the heads-up: the same countdown, ending later, on
        /// whichever hold has it — the daemon's lease or the app's own.
        /// Kept inside one lease's day.
        func extendAwake(now: Date = Date()) {
            guard case .lease(.until(let end)) = awakeReading.state else { return }
            let newEnd = KeepAwakeHeadsUp.extendedEnd(from: end, now: now)
            // The app's own countdown runs on the wall clock: measure the
            // new end from it, so the session ends where the notice said.
            let seconds = max(60, Int(newEnd.timeIntervalSinceNow.rounded()))
            if !handingOver, daemonLive, sendLease != nil, !leaseUnsupported, !awake.held {
                let display = daemonHold?.lease?.display ?? awakeKeepsDisplay
                lease(CoreAwakeRequest(.until(newEnd.timeIntervalSince1970), display: display, source: "heads_up"),
                      fallback: { [weak self] in self?.holdLocally(seconds: seconds) })
                return
            }
            let started = awakeStarted
            holdLocally(seconds: seconds)
            // The same session carries on: its steam keeps its own start.
            if awake.held, let started { awakeStarted = started }
            syncAwakeChip()
        }

        /// The hold the person asked for didn't take. Try again re-asks it:
        /// the daemon's lease in the same shape, or the app's own assertion.
        var canRetryAwake: Bool {
            if awakeReading.holdFailed, awakeReading.leaseInForce, daemonLive, sendLease != nil { return true }
            return !awake.held && awakeRequested && lastError?.hasPrefix(Self.refusedAssertion) == true
        }

        func retryAwake() {
            guard canRetryAwake else { return }
            if awakeReading.holdFailed, let current = daemonHold?.lease {
                lease(CoreAwakeRequest(Self.sameShape(current), display: current.display ?? awakeKeepsDisplay,
                                       source: "retry"), fallback: nil)
                return
            }
            holdLocally(seconds: lastLocalSeconds)
        }

        nonisolated static let refusedAssertion = "Awake: the power assertion was refused."

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
                    return Self.answer(failing: error)
                }
            }
            observeLease(core)
        }

        private func observeLease(_ core: CoreModel) {
            let live = core.isLive
            noteDaemonHold(live ? core.power?.hold : nil, live: live, hello: core.hello)
            withObservationTracking {
                _ = core.isLive
                _ = core.power?.hold
                _ = core.hello
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
        /// A request that threw is an error, not a daemon without the
        /// lease: nothing here says the hold cannot be taken.
        nonisolated static func answer(failing error: any Error) -> LeaseAnswer {
            .failed("the monitor didn't answer.")
        }

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
        func noteDaemonHold(_ hold: CoreAwakeHold?, live: Bool, hello: CoreHello? = nil) {
            if daemonHold != hold { daemonHold = hold }
            if daemonHello != hello || daemonLive != live {
                leaseRevision += 1
                leaseTask = nil
                applying.remove(.keepAwake)
            }
            if daemonHello != hello {
                daemonHello = hello
                if handingOver { handoverRevision += 1 }
                leaseUnsupported = false
            }
            if daemonLive != live {
                if handingOver { handoverRevision += 1 }
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
            guard awakeRequested else {
                setAwake(false)
                return
            }
            if daemonHold?.isManual == true {
                setAwake(false)
                return
            }
            let shape: CoreAwakeRequest.Shape = awakeUntil.map { .until($0.timeIntervalSince1970) } ?? .indefinite
            let request = CoreAwakeRequest(shape, display: awakeKeepsDisplay)
            handingOver = true
            handoverRequest = request
            handoverTask = Task { [weak self] in
                guard let self else { return }
                defer {
                    self.handingOver = false
                    self.handoverTask = nil
                    self.syncAwakeChip()
                }
                while true {
                    let revision = self.handoverRevision
                    let answer = await sendLease(self.handoverRequest)
                    if revision != self.handoverRevision {
                        guard self.daemonLive else { return }
                        continue
                    }
                    switch answer {
                    case .taken:
                        guard self.daemonLive else { return }
                        if self.lastError?.hasPrefix("Awake:") == true { self.lastError = nil }
                        self.handingOver = false
                        self.setAwake(false)
                        return
                    case .unavailable:
                        if self.daemonLive { self.leaseUnsupported = true }
                        return
                    case .refused(let why), .failed(let why):
                        self.lastError = "Awake: \(why)"
                        return
                    }
                }
            }
        }

        private func updateHandoverIntent() {
            guard handingOver else { return }
            handoverRevision += 1
            let shape: CoreAwakeRequest.Shape = awakeUntil.map { .until($0.timeIntervalSince1970) } ?? .indefinite
            handoverRequest = awakeRequested && awake.held ? CoreAwakeRequest(shape, display: awakeKeepsDisplay) : nil
        }

        /// The chip's lit state and its countdown clock, from the one
        /// reading — every path that moves the hold ends here. Lit is the
        /// person's lease, the thing a tap flips; the agents' own hold
        /// and a pause for heat are the chip's word, not its light.
        func syncAwakeChip() {
            let reading = awakeReading
            if isOn[.keepAwake] != reading.leaseInForce { isOn[.keepAwake] = reading.leaseInForce }
            headsUp.sync(reading: reading, now: Date())
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

    private let listenerOwner = UUID()

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
    /// 1: a manual session holds the computer, not the display, until the
    /// person turns "Keep the display on" on again.
    nonisolated static let awakeDisplayMigrationKey = "keepAwakeDisplayMigration"
    nonisolated static let awakeDisplayMigrationVersion = 1

    /// Once, ever: a session held the display before, so it starts this
    /// build holding the computer only. A choice made after the stamp stands.
    nonisolated static func migrateAwakeDisplay(_ defaults: UserDefaults) {
        guard defaults.integer(forKey: awakeDisplayMigrationKey) < awakeDisplayMigrationVersion else { return }
        defaults.removeObject(forKey: awakeDisplayDefaultsKey)
        defaults.set(awakeDisplayMigrationVersion, forKey: awakeDisplayMigrationKey)
    }

    /// Keep awake for `seconds`, indefinitely (nil), or let go (0).
    func holdAwake(seconds: Int?) { state.holdAwake(seconds: seconds) }
    /// Keep awake until the agents working now finish.
    func holdAwakeUntilAgentsFinish() { state.holdAwakeUntilAgentsFinish() }
    func setAwakeKeepsDisplay(_ on: Bool) { state.setAwakeKeepsDisplay(on) }
    /// "+30 min" on the five-minute heads-up.
    func extendAwake() { state.extendAwake() }
    /// Re-ask a hold that didn't take.
    var canRetryAwake: Bool { state.canRetryAwake }
    func retryAwake() { state.retryAwake() }

    /// A link's or a Shortcut's `on=` for Awake: the person's lease, on
    /// or off, left alone when it is already there. The agents' own hold
    /// is not a link's to end — the caption says whose it is instead of
    /// pretending the switch moved.
    private func setAwake(_ on: Bool) {
        let reading = state.awakeReading
        let retryCleanup = !on && reading.persistenceError == "clear_failed" && state.daemonLive
        if on != reading.leaseInForce || retryCleanup {
            state.holdAwake(seconds: on ? nil : 0)
        } else if !on, case .agents = reading.state {
            state.lastNote = "Awake: the agents hold it until they stop — their switch is under Settings › General › Power."
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

    @discardableResult
    func refresh(_ toggle: SystemToggle) -> Task<Void, Never>? {
        guard !state.applying.contains(toggle) else { return nil }
        let owner = UUID()
        state.refreshOwners[toggle] = owner
        if let inline = readInline(toggle) {
            state.isOn[toggle] = inline
            state.refreshOwners.removeValue(forKey: toggle)
            return nil
        } else {
            return Task {
                let value = await state.readToggle(toggle)
                guard state.refreshOwners[toggle] == owner,
                      !state.applying.contains(toggle) else { return }
                state.isOn[toggle] = value
                state.refreshOwners.removeValue(forKey: toggle)
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
    func startObserving() {
        state.listenerOwners.insert(listenerOwner)
        guard !state.listening else { return }
        state.listening = true
        let state = self.state
        state.appearanceObserver = state.appearanceCenter.addObserver(
            forName: Notification.Name("AppleInterfaceThemeChangedNotification"),
            object: nil, queue: .main) { _ in
                MainActor.assumeIsolated {
                    guard state.listening else { return }
                    state.isOn[.darkMode] = (UserDefaults.standard.persistentDomain(
                        forName: UserDefaults.globalDomain)?["AppleInterfaceStyle"] as? String) == "Dark"
                }
            }
        AudioListener.shared.onChange = {
            Task { @MainActor in
                guard state.listening else { return }
                state.isOn[.mute] = AudioMute.isMuted(.output, defaults: state.defaults)
                state.isOn[.micMute] = AudioMute.isMuted(.input, defaults: state.defaults)
            }
        }
        state.startAudio()
    }

    func stopObserving() {
        state.listenerOwners.remove(listenerOwner)
        guard state.listenerOwners.isEmpty, state.listening else { return }
        state.listening = false
        if let token = state.appearanceObserver { state.appearanceCenter.removeObserver(token) }
        state.appearanceObserver = nil
        AudioListener.shared.onChange = nil
        state.stopAudio()
    }

    isolated deinit { stopObserving() }

    // MARK: - Applies

    /// A chip tap: momentary verbs fire, stateful toggles flip and
    /// read back. One apply per toggle at a time — a double-tap waits
    /// for the read-back rather than racing the system.
    func apply(_ toggle: SystemToggle) {
        guard !state.applying.contains(toggle) else { return }
        state.refreshOwners.removeValue(forKey: toggle)
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
            setShellTarget(.darkMode, on: !(readInline(.darkMode) ?? false))
            return
        case .dockAutoHide:
            setDockAutohide(!(readInline(.dockAutoHide) ?? state.isOn[.dockAutoHide] ?? false))
            return
        default:
            if let current = state.isOn[toggle] ?? readInline(toggle) {
                fire(toggle, on: !current)
            } else {
                // No read yet — probe off-actor before deciding the flip.
                state.applying.insert(toggle)
                Task {
                    let current = await state.readToggle(toggle)
                    state.isOn[toggle] = current
                    let target = state.pendingShellTargets.removeValue(forKey: toggle) ?? !current
                    guard current != target else {
                        state.applying.remove(toggle)
                        return
                    }
                    fire(toggle, on: target)
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
        if [.darkMode, .desktopIcons, .hiddenFiles].contains(toggle)
            || (toggle == .dockAutoHide && dockDriver == nil && !dockHoldActive()) {
            if state.applying.contains(toggle) {
                state.pendingShellTargets[toggle] = on
                return
            }
            if let current = readInline(toggle) ?? state.isOn[toggle], current == on { return }
            setShellTarget(toggle, on: on)
            return
        }
        if let current = state.isOn[toggle] ?? readInline(toggle), current == on { return }
        if state.isOn[toggle] == nil, readInline(toggle) == nil {
            state.refreshOwners.removeValue(forKey: toggle)
            Task {
                let current = await Task.detached { Self.probe(toggle) }.value
                state.isOn[toggle] = current
                if current != on { apply(toggle) }
            }
            return
        }
        apply(toggle)
    }

    private func setShellTarget(_ toggle: SystemToggle, on: Bool) {
        state.refreshOwners.removeValue(forKey: toggle)
        if toggle == .darkMode {
            state.applying.insert(toggle)
            Task {
                let permission = await state.automationPermission()
                if permission == .denied || permission == .unavailable {
                    state.pendingShellTargets.removeValue(forKey: toggle)
                    state.applying.remove(toggle)
                    state.lastError = permission == .denied
                        ? AutomationPermission.deniedSentence : "System Events isn't running."
                    return
                }
                fire(toggle, on: state.pendingShellTargets.removeValue(forKey: toggle) ?? on)
            }
        } else if toggle == .dockAutoHide {
            setDockAutohide(on)
        } else if state.isOn[toggle] == nil {
            state.applying.insert(toggle)
            Task {
                let current = await state.readToggle(toggle)
                state.isOn[toggle] = current
                let target = state.pendingShellTargets.removeValue(forKey: toggle) ?? on
                guard current != target else {
                    state.applying.remove(toggle)
                    return
                }
                fire(toggle, on: target)
            }
        } else {
            fire(toggle, on: on)
        }
    }

    /// A shell-backed flip: run detached, read the truth back after
    /// the settle beat (Finder relaunches take a moment), and keep any
    /// stderr honest — a refused write lands in `lastError`.
    private func fire(_ toggle: SystemToggle, on: Bool, command override: String? = nil,
                      fallback: String? = nil) {
        guard let command = override ?? toggle.applyCommand(on: on) else { return }
        state.refreshOwners.removeValue(forKey: toggle)
        state.applying.insert(toggle)
        state.lastError = nil
        let task = Task {
            defer {
                state.shellTasks.removeValue(forKey: toggle)
                state.applying.remove(toggle)
                if let target = state.pendingShellTargets.removeValue(forKey: toggle) {
                    set(toggle, on: target)
                }
            }
            var result = await state.runCommand(command)
            if result.error != nil, let fallback {
                // The public path was refused (no Automation grant, most
                // likely): the last resort still gets the choice through.
                result = await state.runCommand(fallback)
            }
            if let error = result.error, !error.isEmpty {
                state.lastError = "\(toggle.title): \(error)"
                Self.log.notice("toggle \(toggle.rawValue, privacy: .public) failed: \(error, privacy: .public)")
            }
            // The read-back is the truth — the chip settles to what
            // the system reports, not what we asked for.
            if !toggle.isMomentary {
                await state.settleShell()
                if let inline = readInline(toggle) {
                    state.isOn[toggle] = inline
                } else {
                    state.isOn[toggle] = await state.readToggle(toggle)
                }
            }
        }
        state.shellTasks[toggle] = task
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
        state.refreshOwners.removeValue(forKey: .dockAutoHide)
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
        state.scheduleDockRetry { [self] in
            guard let pending = self.state.pendingDockAutohide else { return }
            if self.dockHoldActive(), attempt < 480 {
                self.waitForDockHold(attempt: attempt + 1)
                return
            }
            self.state.pendingDockAutohide = nil
            self.setDockAutohide(pending)
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
    private lazy var listeners = HALPropertyListeners(queue: queue) { [weak self] key in
        guard let self, self.started else { return }
        if Self.systemSelectors.contains(key.selector) { self.rewatchDevices() }
        self.onChange?()
    }

    private static let systemSelectors: [AudioObjectPropertySelector] = [
        kAudioHardwarePropertyDefaultOutputDevice,
        kAudioHardwarePropertyDefaultInputDevice,
    ]

    func start() {
        queue.async { [self] in
            guard !started else { return }
            started = true
            rewatchDevices()
        }
    }

    func stop() {
        queue.async { [self] in
            started = false
            listeners.reconcile([])
        }
    }

    /// Runs on `queue`; unchanged defaults keep their existing listeners.
    private func rewatchDevices() {
        guard started else { return }
        var desired = Set(Self.systemSelectors.map {
            HALPropertyListeners.Key(system: .audio, object: AudioObjectID(kAudioObjectSystemObject), selector: $0)
        })
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
                desired.insert(.init(system: .audio, object: device, selector: property, scope: scope))
            }
        }
        listeners.reconcile(desired)
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
    /// The target is not running, or macOS cannot report its permission.
    case unavailable

    nonisolated static let systemEventsBundleID = "com.apple.systemevents"
    nonisolated static let settingsURL = URL(
        string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Automation")!
    nonisolated static let deniedSentence =
        "JR-Bar may not control System Events — allow it in Privacy & Security › Automation."

    /// `ask: true` blocks until the person answers the prompt — call it
    /// off the main thread.
    nonisolated static func systemEvents(ask: Bool) -> AutomationPermission {
        target(systemEventsBundleID, ask: ask)
    }

    nonisolated static func target(_ bundleID: String, ask: Bool) -> AutomationPermission {
        target(bundleID, ask: ask, isRunning: {
            !NSRunningApplication.runningApplications(withBundleIdentifier: $0).isEmpty
        }, determine: { bundleID, ask in
            let target = NSAppleEventDescriptor(bundleIdentifier: bundleID)
            guard let desc = target.aeDesc else { return OSStatus(procNotFound) }
            return AEDeterminePermissionToAutomateTarget(desc, typeWildCard, typeWildCard, ask)
        })
    }

    nonisolated static func systemEvents(
        ask: Bool, isRunning: (String) -> Bool,
        determine: (String, Bool) -> OSStatus
    ) -> AutomationPermission {
        target(systemEventsBundleID, ask: ask, isRunning: isRunning, determine: determine)
    }

    nonisolated static func target(
        _ bundleID: String, ask: Bool, isRunning: (String) -> Bool,
        determine: (String, Bool) -> OSStatus
    ) -> AutomationPermission {
        guard isRunning(bundleID) else { return .unavailable }
        return classify(determine(bundleID, ask))
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
