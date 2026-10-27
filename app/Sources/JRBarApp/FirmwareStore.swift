import Foundation
import JRBarCore
import Observation

/// Settings › Devices & Lighting › Firmware: what the daemon last said about each
/// device's firmware, and the one update job.
///
/// The rules this store keeps, because nothing leaves the Mac by itself:
///
/// - `firmware_status` is asked for when Devices or Integrations appears,
///   with Integrations gated on connected, enabled hardware,
///   when the person presses Check again, and once when the daemon reports
///   a finished job. There is no timer here and none is started.
/// - `firmware_update` is sent from exactly one place, `startUpdate`, and
///   only while the confirmation sheet is open for that device and the
///   device can be updated. It always carries `confirm: true`.
/// - Nothing else triggers a download.
@MainActor
@Observable
final class FirmwareStore {
    /// How a command reaches the daemon; the tests hand in a fake.
    typealias Send = @MainActor (_ name: String, _ args: [String: JSONValue]) async throws -> CoreReply

    /// What the confirmation sheet is showing.
    enum SheetStage: Equatable {
        case confirm
        /// `firmware_update` was sent and the daemon has not answered yet.
        case starting
        case running(FirmwareJob)
        case finished(FirmwareJob)
    }

    @ObservationIgnored private let send: Send

    /// The last `firmware_status` reply; nil before the first, kept (not
    /// blanked) when a later ask fails.
    private(set) var status: FirmwareStatusReply?
    /// The sentence for a failed `firmware_status`, nil after a good one.
    private(set) var statusFailure: String?
    private(set) var isRefreshing = false
    /// The newest job document from the state frame or a reply.
    private(set) var job: FirmwareJob?
    /// A `firmware_update` is waiting on the daemon's reply.
    private(set) var isStarting = false
    /// The daemon's own sentence when it refused to start.
    private(set) var startFailure: String?
    /// The device (`firmware_status` id) whose sheet is open.
    private(set) var sheetDeviceID: String?
    /// The Settings device card the sheet was opened from, for the
    /// calibration button.
    private(set) var sheetSettingsID: String?

    /// Jobs this window watched run or started, and the ones whose result
    /// the person has closed. An old finished job seen cold is neither.
    @ObservationIgnored private var watched: Set<String> = []
    private(set) var closed: Set<String> = []
    @ObservationIgnored private var refreshedForJob: Set<String> = []

    init(send: @escaping Send) {
        self.send = send
    }

    // MARK: Asking

    /// `firmware_status`. Offline in the daemon: it reads the devices and
    /// compares with the releases the app pins. A second ask while one is
    /// out waits for that one.
    func refresh() async {
        guard !isRefreshing else { return }
        isRefreshing = true
        defer { isRefreshing = false }
        do {
            let reply = try await send("firmware_status", [:])
            guard reply.ok else {
                statusFailure = Self.sentence(reply.error, fallback: "The monitor could not read the firmware status.")
                return
            }
            guard let parsed = FirmwareStatusReply(reply.result) else {
                statusFailure = "The monitor's firmware answer could not be read."
                return
            }
            status = parsed
            statusFailure = nil
            // A fresh answer is the daemon's truth about the job, unless
            // our own start is still waiting on its reply.
            if parsed.job == nil, !isStarting { job = nil }
            receive(job: parsed.job, fromState: false)
        } catch {
            statusFailure = Self.sentence(error, fallback: MonitorWords.sentence)
        }
    }

    /// A device status page appeared: take the state frame's job and read the
    /// firmware status once.
    func pageAppeared(stateJob: FirmwareJob?) async {
        receive(job: stateJob, fromState: true)
        await refresh()
    }

    /// Reuse the device receipt without waking hardware that is off or absent.
    func integrationsAppeared(devices: [CoreDevice], live: Bool, stateJob: FirmwareJob?) async {
        guard live, devices.contains(where: {
            ($0.kind == "pro" || $0.kind == "dot") && $0.enabled != false && $0.connected == true
        }) else { return }
        await pageAppeared(stateJob: stateJob)
    }

    /// The state frame's job moved. A finished one is read back once, so the
    /// version shown after an update is the device's own word.
    func observe(stateJob: FirmwareJob?) async {
        receive(job: stateJob, fromState: true)
        guard let finished = job, !finished.isRunning, watched.contains(finished.id),
              refreshedForJob.insert(finished.id).inserted else { return }
        await refresh()
    }

    private func receive(job incoming: FirmwareJob?, fromState: Bool) {
        guard let incoming else {
            // The state frame omits `firmware` when there is no job. A
            // running job is never dropped on that word alone: a frame
            // built before the start can arrive after its reply.
            if fromState, let current = job, !current.isRunning { job = nil }
            return
        }
        if let current = job, current.id == incoming.id, let known = current.updatedAt, let fresh = incoming.updatedAt,
           fresh < known {
            return
        }
        if incoming.isRunning { watched.insert(incoming.id) }
        job = incoming
    }

    // MARK: The sheet

    /// Opens the confirmation sheet. Sends nothing.
    func openSheet(deviceID: String, settingsID: String) {
        startFailure = nil
        sheetDeviceID = deviceID
        sheetSettingsID = settingsID
    }

    /// What the sheet shows now.
    var sheetStage: SheetStage {
        if isStarting { return .starting }
        if let id = sheetDeviceID, let job, job.device == id, watched.contains(job.id) {
            if job.isRunning { return .running(job) }
            if !closed.contains(job.id) { return .finished(job) }
        }
        return .confirm
    }

    /// The sheet may be closed: not while an update starts or runs.
    var canCloseSheet: Bool {
        switch sheetStage {
        case .starting, .running: return false
        case .confirm, .finished: return true
        }
    }

    /// Closes the sheet when that is safe, and remembers a finished result
    /// as seen. Returns whether it closed.
    @discardableResult
    func closeSheet() -> Bool {
        guard canCloseSheet else { return false }
        if case .finished(let done) = sheetStage { closed.insert(done.id) }
        sheetDeviceID = nil
        sheetSettingsID = nil
        startFailure = nil
        return true
    }

    /// An update is running on any device.
    var anyJobRunning: Bool { job?.isRunning == true }

    /// Whether a finished job's result should still show on its card.
    func showsFinishedJob(_ job: FirmwareJob?) -> Bool {
        guard let job, !job.isRunning else { return false }
        return watched.contains(job.id) && !closed.contains(job.id)
    }

    // MARK: Starting

    /// `firmware_update`, with `confirm: true`. This is the only place the
    /// command is sent, and it works only from the open confirmation sheet
    /// of a device that can be updated now and while nothing else runs.
    func startUpdate(deviceID: String) async {
        guard sheetDeviceID == deviceID, sheetStage == .confirm, !isStarting, !anyJobRunning else { return }
        guard let row = status?.devices.first(where: { $0.id == deviceID }), row.canUpdate else { return }
        isStarting = true
        startFailure = nil
        defer { isStarting = false }
        do {
            let reply = try await send("firmware_update", ["device": .string(deviceID), "confirm": .bool(true)])
            guard reply.ok else {
                startFailure = Self.sentence(reply.error, fallback: "The monitor did not start the update.")
                return
            }
            let started = FirmwareStartReply(reply.result)
            guard started.started, let begun = started.job else {
                startFailure = "The monitor did not start the update."
                return
            }
            watched.insert(begun.id)
            receive(job: begun, fromState: false)
        } catch {
            startFailure = Self.sentence(error, fallback: "\(MonitorWords.sentence) Nothing was started.")
        }
    }

    // MARK: Reading for a card

    /// The Firmware group for one Settings device card.
    func cardState(settingsID: String, kind: String, fallbackName: String) -> FirmwareCardState {
        let row = status?.device(matching: settingsID, kind: kind)
        let release = status?.release(for: row?.model ?? kind)
        return FirmwarePresenter.state(
            deviceID: row?.id ?? settingsID, device: row, release: release,
            loaded: status != nil, failure: statusFailure, job: job,
            showFinishedJob: showsFinishedJob(job), fallbackName: fallbackName)
    }

    /// The confirmation words for the open sheet's device.
    func confirmation(fallbackName: String) -> FirmwareConfirmation? {
        guard let id = sheetDeviceID, let status,
              let row = status.devices.first(where: { $0.id == id }),
              let release = status.release(for: row.model) else { return nil }
        return FirmwarePresenter.confirmation(device: row, release: release,
                                              downloadHost: status.downloadHost, fallbackName: fallbackName)
    }

    private static func sentence(_ error: Error?, fallback: String) -> String {
        if let reply = error as? CoreReplyError {
            return reply.sentence
        }
        return fallback
    }
}
