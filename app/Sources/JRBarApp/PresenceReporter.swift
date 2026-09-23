import Foundation
import JRBarCore
import Observation

/// The app's half of the one presence fact (docs/CORE-PROTOCOL.md,
/// `presence`): the mic and camera reading goes to the daemon — which
/// takes the sounds off the headset, holds escalation at the light, holds
/// celebrations and turns a `call` Dot red — and the call fact comes back
/// for the toys. The reading is the notch's sensor monitor
/// (`NotchToy.onSensorsChanged`), which runs for this report while the
/// daemon is connected, whether or not anything draws the dots: a call is
/// a call with the island off.
///
/// Nothing leaves the Mac — the report goes over the daemon's local
/// socket — and nothing is read that the dots do not already read: running
/// state, never a sample or a frame.
@MainActor
final class PresenceReporter {
    private let isConnected: @MainActor () -> Bool
    /// The daemon's `state.presence`, nil while it is away.
    private let presence: @MainActor () -> CorePresence?
    /// One report; true when the daemon took it.
    private let send: @MainActor (CorePresenceReport) async -> Bool
    private let clock: @MainActor () -> Date

    /// The monitor's latest reading, as the notch hands it over.
    private(set) var reading = NotchSensorState()
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

    init(isConnected: @escaping @MainActor () -> Bool,
         presence: @escaping @MainActor () -> CorePresence?,
         send: @escaping @MainActor (CorePresenceReport) async -> Bool,
         clock: @escaping @MainActor () -> Date = { Date() }) {
        self.isConnected = isConnected
        self.presence = presence
        self.send = send
        self.clock = clock
    }

    /// The production reporter: the core's connection and presence, its
    /// `presence` command, and an observation that re-arms itself.
    convenience init(core: CoreModel) {
        self.init(isConnected: { [weak core] in core?.connection.isConnected ?? false },
                  presence: { [weak core] in core?.isLive == true ? core?.state?.presence : nil },
                  send: { [weak core] report in
                      guard let core else { return false }
                      return (try? await core.reportPresence(report))?.ok == true
                  })
        observe(core)
    }

    isolated deinit { check?.cancel() }

    /// Whether the sensor monitor must run for the report: while the
    /// daemon is there to hear it.
    var wantsSensors: Bool { isConnected() }

    /// A sensor edge from the notch's monitor.
    func noteSensors(_ state: NotchSensorState) {
        guard state != reading else { return }
        reading = state
        refresh()
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

    private func refresh() {
        let call = PresenceReporting.onCall(reading: reading, presence: presence())
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
        guard let report = reporting.due(reading: reading, connected: connected, now: clock()) else {
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
