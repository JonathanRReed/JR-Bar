import AppKit
import Foundation
import Intents
import JRBarCore
import Observation

/// The app's half of the one presence fact (docs/CORE-PROTOCOL.md,
/// `presence`): the mic and camera reading goes to the daemon — which
/// takes the sounds off the headset, holds escalation at the light, holds
/// celebrations and turns a `call` Dot red — and the call fact comes back
/// for the toys. The Mac's Focus goes with it once Focus access is
/// granted: the daemon's helper cannot read Focus, and Follow Focus
/// follows this. macOS posts no Focus change, so it is read again every
/// `focusCheckInterval` while the daemon is connected and whenever
/// another app comes forward. The reading is the notch's sensor monitor
/// (`NotchToy.onSensorsChanged`), which runs for this report while the
/// daemon is connected, whether or not anything draws the dots: a call is
/// a call with the island off.
///
/// JR-Bar's own lens is not a call. The camera reading is the whole
/// device's (`kCMIODevicePropertyDeviceIsRunningSomewhere`), so the card's
/// own Mirror reads as a camera in use; the report and the toys' fact
/// leave it out while it is up, the way the mic reading leaves JR-Bar's
/// own process out — one rule everywhere.
///
/// Nothing leaves the Mac — the report goes over the daemon's local
/// socket — and nothing is read beyond the dots' running state (never a
/// sample or a frame) and whether a Focus is on, the same bit the Menu
/// Bar's rules read.
@MainActor
final class PresenceReporter {
    private let isConnected: @MainActor () -> Bool
    /// The daemon's `state.presence`, nil while it is away.
    private let presence: @MainActor () -> CorePresence?
    /// One report; true when the daemon took it.
    private let send: @MainActor (CorePresenceReport) async -> Bool
    private let clock: @MainActor () -> Date
    /// JR-Bar's own Mirror has the camera: live, or asked for and on its
    /// way up.
    private let ownCameraLive: @MainActor () -> Bool
    /// How long the camera stays the Mirror's after it closes: its session
    /// winds down on its own queue, so the device flag still reads it for
    /// a beat. Ending it on a guess of "now" would report a call the
    /// length of that beat on every close.
    private let ownCameraGrace: TimeInterval
    /// The Mac's Focus, or nil while it cannot be read.
    private let readFocus: @MainActor () -> Bool?
    /// How often the Focus is read again while connected; nil reads it
    /// only on the reporter's own edges (the tests).
    private let focusCheckInterval: TimeInterval?

    /// The monitor's latest reading, as the notch hands it over.
    private(set) var reading = NotchSensorState()
    /// The Focus as last read; nil while it cannot be read.
    private(set) var focus: Bool?
    private(set) var reporting = PresenceReporting()
    /// The toys' call fact (`PresenceReporting.onCall`).
    private(set) var onCall = false
    var onCallChanged: (@MainActor (Bool) -> Void)?
    /// The daemon came or went, so whether the monitor must run for the
    /// report moved.
    var onDemandChanged: (@MainActor () -> Void)?

    /// One report in flight at a time: the socket keeps them in order, and
    /// its reply decides what is owed next.
    private var sending = false
    /// Bumped when the connection goes, so a reply from the old one never
    /// counts as the new one's first report.
    private var generation = 0
    private var wasConnected = false
    /// The sleeping renewal or retry, and when it wakes — a state frame
    /// that owes nothing new leaves it sleeping.
    private var check: Task<Void, Never>?
    private var checkAt: Date?
    /// The Mirror had the camera as last seen, and the beat after it
    /// closed while the camera is still counted as its own.
    private var ownCamera = false
    private var ownCameraSettling: Task<Void, Never>?
    /// The Focus re-read while connected, and the app-switch observer.
    private var focusPoll: Task<Void, Never>?
    private var activationObserver: (any NSObjectProtocol)?

    init(isConnected: @escaping @MainActor () -> Bool,
         presence: @escaping @MainActor () -> CorePresence?,
         send: @escaping @MainActor (CorePresenceReport) async -> Bool,
         clock: @escaping @MainActor () -> Date = { Date() },
         ownCameraLive: @escaping @MainActor () -> Bool = { false },
         ownCameraGrace: TimeInterval = PresenceReporter.mirrorWindDown,
         readFocus: @escaping @MainActor () -> Bool? = { nil },
         focusCheckInterval: TimeInterval? = nil) {
        self.isConnected = isConnected
        self.presence = presence
        self.send = send
        self.clock = clock
        self.ownCameraLive = ownCameraLive
        self.ownCameraGrace = ownCameraGrace
        self.readFocus = readFocus
        self.focusCheckInterval = focusCheckInterval
    }

    /// The Focus re-read's cadence: the same 15 s the menu bar's triggers
    /// poll it on — an edge lands well inside the daemon's 180 s.
    static let focusCheckEvery: TimeInterval = 15

    /// `INFocusStatusCenter`'s `isFocused`, only once Focus access is
    /// granted — reading it must never be what raises the prompt.
    static func systemFocus() -> Bool? {
        guard INFocusStatusCenter.default.authorizationStatus == .authorized else { return nil }
        return INFocusStatusCenter.default.focusStatus.isFocused
    }

    /// The Mirror's beat after it closes: long enough for its session's
    /// `stopRunning` and the camera daemon's flag to follow it.
    static let mirrorWindDown: TimeInterval = 3

    /// The production reporter: the core's connection and presence, its
    /// `presence` command, the cards whose Mirror is JR-Bar's own lens,
    /// and observations that re-arm themselves.
    convenience init(core: CoreModel, cards: @escaping @MainActor () -> [NotchCardModel]) {
        self.init(isConnected: { [weak core] in core?.connection.isConnected ?? false },
                  presence: { [weak core] in core?.isLive == true ? core?.state?.presence : nil },
                  send: { [weak core] report in
                      guard let core else { return false }
                      return (try? await core.reportPresence(report))?.ok == true
                  },
                  ownCameraLive: { cards().contains(where: Self.mirrorHasCamera) },
                  readFocus: { Self.systemFocus() },
                  focusCheckInterval: Self.focusCheckEvery)
        observe(core)
        observeMirrors(cards)
        // A Focus often follows an app coming forward (a Focus filter, a
        // schedule the person just noticed): read it then too.
        activationObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.focusMayHaveChanged() }
        }
    }

    isolated deinit {
        check?.cancel()
        ownCameraSettling?.cancel()
        focusPoll?.cancel()
        if let activationObserver { NSWorkspace.shared.notificationCenter.removeObserver(activationObserver) }
    }

    /// The Focus is read again; a change is an edge the daemon hears now.
    func focusMayHaveChanged() {
        let now = readFocus()
        guard now != focus else { return }
        focus = now
        refresh()
    }

    /// The Focus re-read runs while the daemon is there to hear it.
    private func syncFocusPoll(connected: Bool) {
        focusPoll?.cancel()
        focusPoll = nil
        guard connected, let interval = focusCheckInterval else { return }
        focusPoll = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(interval))
                guard !Task.isCancelled, let self else { return }
                self.focusMayHaveChanged()
            }
        }
    }

    /// A card's Mirror has the camera: live, or asked for on a pinned
    /// card and still coming up — `mirrorSummoned` is set before the
    /// session starts, and the lens can light before the row says live.
    /// A lens refused or missing is not the Mirror's.
    static func mirrorHasCamera(_ card: NotchCardModel) -> Bool {
        card.mirror.state == .live
            || (card.pinned && card.mirrorSummoned && card.mirror.state == .off)
    }

    /// Whether the sensor monitor must run for the report: while the
    /// daemon is there to hear it.
    var wantsSensors: Bool { isConnected() }

    /// A sensor edge from the notch's monitor.
    func noteSensors(_ state: NotchSensorState) {
        guard state != reading else { return }
        reading = state
        // The closed Mirror's lens is seen to go dark: the beat is over.
        if !state.cameraInUse, ownCameraSettling != nil {
            ownCameraSettling?.cancel()
            ownCameraSettling = nil
        }
        refresh()
    }

    /// The Mirror opened or closed. The device flag has no edge of its
    /// own when another app still holds the lens, so the reading is
    /// looked at again here.
    func ownCameraChanged() {
        refresh()
    }

    /// The reading as the daemon and the toys take it: JR-Bar's own
    /// Mirror left out of the camera.
    var callReading: NotchSensorState {
        NotchSensorState(microphoneInUse: reading.microphoneInUse,
                         cameraInUse: reading.cameraInUse && !ownCamera && ownCameraSettling == nil)
    }

    /// The connection or the daemon's presence moved.
    func coreChanged() {
        let connected = isConnected()
        if connected != wasConnected {
            wasConnected = connected
            if !connected {
                reporting.reset()
                generation += 1
            }
            // A connection's first report carries the Focus as it is now.
            if connected { focus = readFocus() }
            syncFocusPoll(connected: connected)
            onDemandChanged?()
        }
        refresh()
    }

    private func observe(_ core: CoreModel) {
        withObservationTracking {
            _ = core.connection
            _ = core.state?.presence
        } onChange: { [weak self, weak core] in
            Task { @MainActor [weak self, weak core] in
                guard let self, let core else { return }
                self.coreChanged()
                self.observe(core)
            }
        }
    }

    private func observeMirrors(_ cards: @escaping @MainActor () -> [NotchCardModel]) {
        withObservationTracking {
            for card in cards() { _ = Self.mirrorHasCamera(card) }
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.ownCameraChanged()
                self.observeMirrors(cards)
            }
        }
    }

    /// Whether the Mirror has the camera moved: opening, the camera is
    /// ours at once; closing, it stays ours for the beat its session takes
    /// to wind down, then the reading is looked at again — whatever still
    /// holds the lens is another app's.
    private func noteOwnCamera() {
        let live = ownCameraLive()
        guard live != ownCamera else { return }
        ownCamera = live
        ownCameraSettling?.cancel()
        ownCameraSettling = nil
        guard !live else { return }
        let grace = ownCameraGrace
        ownCameraSettling = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(grace))
            guard !Task.isCancelled, let self else { return }
            self.ownCameraSettling = nil
            self.refresh()
        }
    }

    private func refresh() {
        noteOwnCamera()
        let call = PresenceReporting.onCall(reading: callReading, presence: presence())
        if call != onCall {
            onCall = call
            onCallChanged?(call)
        }
        pump()
    }

    /// Send what is owed, or sleep until something will be.
    private func pump() {
        guard !sending else { return }
        let connected = isConnected()
        guard let report = reporting.due(reading: callReading, focus: focus, connected: connected,
                                         now: clock()) else {
            schedule(at: reporting.nextCheck(connected: connected))
            return
        }
        schedule(at: nil)
        sending = true
        let sentFor = generation
        Task { @MainActor [weak self] in
            guard let self else { return }
            let taken = await self.send(report)
            self.sending = false
            if sentFor == self.generation {
                if taken { self.reporting.sent(report, at: self.clock()) }
                else { self.reporting.failed(report, at: self.clock()) }
            }
            self.pump()
        }
    }

    private func schedule(at date: Date?) {
        guard date != checkAt else { return }
        check?.cancel()
        check = nil
        checkAt = date
        guard let date else { return }
        let delay = max(0, date.timeIntervalSince(clock()))
        check = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(delay))
            guard !Task.isCancelled, let self else { return }
            self.check = nil
            self.checkAt = nil
            self.pump()
        }
    }
}
