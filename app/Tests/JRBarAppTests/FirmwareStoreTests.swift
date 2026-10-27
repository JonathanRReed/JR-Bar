import Foundation
import JRBarCore
import Testing
@testable import JRBarApp

/// A stand-in for the daemon's socket: records every command the store
/// sends and answers from a script. No socket, no clock, no network.
@MainActor
final class FakeFirmwareLink {
    struct Sent: Equatable {
        var name: String
        var args: [String: JSONValue]
    }

    private(set) var sent: [Sent] = []
    /// The `firmware_status` reply; its `job` is swapped for `job` so the
    /// daemon's two views of the job agree.
    var statusText = FakeFirmwareLink.proReply
    var statusOverride: JSONValue?
    /// The job the daemon would report now; nil for none.
    var job: JSONValue?
    var statusError: Error?
    var updateReply: CoreReply?
    var updateError: Error?
    /// While set, `firmware_update` waits here before answering, so a test
    /// can look at the sheet while the reply is still out.
    var gate: CheckedContinuation<Void, Never>?
    var holdUpdate = false

    static let proReply = """
    {"catalog":[{"model":"pro","name":"SidePulse Pro","version":"1.1.0",
       "notes":["Better white balance through the diffuser.","More reliable updates."],
       "package":{"host":"raw.githubusercontent.com","name":"sidepulse-pro-1.1.0-ota.zip","bytes":137875,"cached":false},
       "drive":"SidePulse","image_bytes":136992}],
     "devices":[{"id":"SPP-000067","name":"SidePulse Pro","root":"/Volumes/SidePulse","mounted":true,"model":"pro",
       "serial":"SPP-000067","version":"1.0.2","active_slot":"A","build":"2026-08-05T23:25:42Z","uptime_ms":83257187,
       "latest":"1.1.0","update_available":true,"can_update":true,"why_not":null,
       "other_slot":{"name":"B","has_image":false,"valid":true,"version":"none"},"colour_note":false}],
     "job":null,"download_host":"raw.githubusercontent.com"}
    """

    static func json(_ text: String) -> JSONValue {
        (try? JSONDecoder().decode(JSONValue.self, from: Data(text.utf8))) ?? .null
    }

    var names: [String] { sent.map(\.name) }

    func send(_ name: String, _ args: [String: JSONValue]) async throws -> CoreReply {
        sent.append(Sent(name: name, args: args))
        switch name {
        case "firmware_status":
            if let statusError { throw statusError }
            if let statusOverride { return CoreReply(id: "1", ok: true, result: statusOverride) }
            var members = Self.json(statusText).objectValue ?? [:]
            members["job"] = job ?? .null
            return CoreReply(id: "1", ok: true, result: .object(members))
        case "firmware_update":
            if holdUpdate {
                await withCheckedContinuation { gate = $0 }
            }
            if let updateError { throw updateError }
            let started = Self.jobValue(phase: "checking", outcome: nil)
            job = started
            return updateReply ?? CoreReply(id: "2", ok: true, result: .object(["started": .bool(true), "job": started]))
        default:
            return CoreReply(id: "3", ok: false, error: CoreReplyError(code: "unknown_command", message: name))
        }
    }

    /// Lets a held `firmware_update` answer.
    func release() {
        gate?.resume()
        gate = nil
    }

    /// A job document for the Pro, as the daemon writes it, with `overrides` laid on top.
    static func jobValue(phase: String, outcome: String?, updatedAt: Double = 101,
                         overrides: [String: JSONValue] = [:]) -> JSONValue {
        var members: [String: JSONValue] = [
            "id": "fw-1", "device": "SPP-000067", "model": "pro", "name": "SidePulse Pro", "serial": "SPP-000067",
            "from_version": "1.0.2", "to_version": "1.1.0", "phase": .string(phase), "phase_label": "label",
            "outcome": outcome.map { JSONValue.string($0) } ?? .null, "code": .null, "message": .null,
            "what_to_do": .null, "source": "download", "started_at": 100.0, "phase_started_at": 100.0,
            "updated_at": .number(updatedAt), "finished_at": .null, "download": .null, "removed_sidecars": [],
            "new_slot": .null, "previous_firmware": .null, "colour_check": false, "restarted": false,
        ]
        members.merge(overrides) { _, new in new }
        return .object(members)
    }

    static func job(phase: String, outcome: String? = nil, updatedAt: Double = 101,
                    overrides: [String: JSONValue] = [:]) -> FirmwareJob? {
        FirmwareJob(jobValue(phase: phase, outcome: outcome, updatedAt: updatedAt, overrides: overrides))
    }
}

/// The store that holds the Firmware group and its sheet. It must read the
/// firmware status only at the three moments the design allows, and send
/// `firmware_update` only from the open confirmation sheet.
@Suite("Firmware store")
@MainActor
struct FirmwareStoreTests {
    private func make(_ link: FakeFirmwareLink = FakeFirmwareLink()) -> (FirmwareStore, FakeFirmwareLink) {
        (FirmwareStore { name, args in try await link.send(name, args) }, link)
    }

    // MARK: Reading

    @Test("opening the Devices page asks for the status once and nothing else")
    func pageAsksOnce() async {
        let (store, link) = make()
        await store.pageAppeared(stateJob: nil)
        #expect(link.names == ["firmware_status"])
        #expect(link.sent.first?.args.isEmpty == true)
        #expect(store.status?.devices.count == 1)
        // Letting the run loop turn does not make it ask again: nothing is polling.
        for _ in 0..<20 { await Task.yield() }
        #expect(link.names == ["firmware_status"])
    }

    @Test("Check again asks again, and a failed ask keeps the last good reading")
    func checkAgain() async {
        let (store, link) = make()
        await store.refresh()
        link.statusError = CoreClientError.notConnected
        await store.refresh()
        #expect(link.names == ["firmware_status", "firmware_status"])
        #expect(store.status != nil, "the last good reading is kept")
        #expect(store.statusFailure == "The monitor is not connected.")
        link.statusError = nil
        await store.refresh()
        #expect(store.statusFailure == nil)
    }

    @Test("a refused status shows the daemon's sentence")
    func refusedStatus() async {
        let (store, link) = make()
        link.statusOverride = .null
        await store.refresh()
        #expect(store.statusFailure == "The monitor's firmware answer could not be read.")
        #expect(store.status == nil)
        let card = store.cardState(settingsID: "x", kind: "pro", fallbackName: "SidePulse")
        #expect(card.display == .unavailable("The monitor's firmware answer could not be read."))
    }

    @Test("a finished job is read back once, and a running one never")
    func finishedJobReadsOnce() async throws {
        let (store, link) = make()
        await store.pageAppeared(stateJob: nil)
        store.openSheet(deviceID: "SPP-000067", settingsID: "devices.0")
        await store.startUpdate(deviceID: "SPP-000067")
        let running = try #require(FakeFirmwareLink.job(phase: "copying", updatedAt: 105))
        await store.observe(stateJob: running)
        #expect(link.names == ["firmware_status", "firmware_update"], "progress frames ask for nothing")
        let done = try #require(FakeFirmwareLink.job(phase: "done", outcome: "updated", updatedAt: 160))
        link.job = FakeFirmwareLink.jobValue(phase: "done", outcome: "updated")
        await store.observe(stateJob: done)
        #expect(link.names == ["firmware_status", "firmware_update", "firmware_status"])
        await store.observe(stateJob: done)
        #expect(link.names.count == 3, "the same finished job is read back only once")
    }

    // MARK: Starting

    @Test("nothing is sent by opening the sheet, and an update needs the sheet")
    func updateNeedsTheSheet() async {
        let (store, link) = make()
        await store.refresh()
        await store.startUpdate(deviceID: "SPP-000067")
        #expect(link.names == ["firmware_status"], "no sheet, no update")
        store.openSheet(deviceID: "SPP-000067", settingsID: "devices.0")
        #expect(link.names == ["firmware_status"], "opening the sheet sends nothing")
        await store.startUpdate(deviceID: "SPP-999999")
        #expect(link.names == ["firmware_status"], "the sheet is for another device")
        store.closeSheet()
        await store.startUpdate(deviceID: "SPP-000067")
        #expect(link.names == ["firmware_status"], "a closed sheet cannot start one")
    }

    @Test("confirming sends firmware_update with confirm true and the device")
    func confirmSends() async throws {
        let (store, link) = make()
        await store.refresh()
        store.openSheet(deviceID: "SPP-000067", settingsID: "devices.0")
        #expect(store.sheetStage == .confirm)
        await store.startUpdate(deviceID: "SPP-000067")
        let sent = try #require(link.sent.last)
        #expect(sent.name == "firmware_update")
        #expect(sent.args == ["device": .string("SPP-000067"), "confirm": .bool(true)])
        #expect(link.names.filter { $0 == "firmware_update" }.count == 1)
        guard case .running(let job) = store.sheetStage else {
            Issue.record("expected the running stage, got \(store.sheetStage)"); return
        }
        #expect(job.id == "fw-1")
    }

    @Test("a device that cannot be updated now is never sent")
    func refusesLocally() async {
        let (store, link) = make()
        link.statusText = FakeFirmwareLink.proReply.replacingOccurrences(of: "\"can_update\":true", with: "\"can_update\":false")
        await store.refresh()
        store.openSheet(deviceID: "SPP-000067", settingsID: "devices.0")
        await store.startUpdate(deviceID: "SPP-000067")
        #expect(link.names == ["firmware_status"])
    }

    @Test("a second update cannot start while one runs")
    func oneAtATime() async {
        let (store, link) = make()
        await store.refresh()
        store.openSheet(deviceID: "SPP-000067", settingsID: "devices.0")
        await store.startUpdate(deviceID: "SPP-000067")
        await store.startUpdate(deviceID: "SPP-000067")
        #expect(link.names.filter { $0 == "firmware_update" }.count == 1)
    }

    @Test("a refusal shows the daemon's sentence and the sheet stays at the question")
    func refusal() async {
        let (store, link) = make()
        await store.refresh()
        link.updateReply = CoreReply(id: "2", ok: false, error: CoreReplyError(
            code: "refused", message: "This Mac is on battery at 20%. Plug in the charger first."))
        store.openSheet(deviceID: "SPP-000067", settingsID: "devices.0")
        await store.startUpdate(deviceID: "SPP-000067")
        #expect(store.startFailure == "This Mac is on battery at 20%. Plug in the charger first.")
        #expect(store.sheetStage == .confirm)
        #expect(store.canCloseSheet)
        #expect(!store.isStarting)
        // Opening the sheet again clears the old complaint.
        store.closeSheet()
        store.openSheet(deviceID: "SPP-000067", settingsID: "devices.0")
        #expect(store.startFailure == nil)
    }

    @Test("an unreachable monitor starts nothing and says so")
    func unreachable() async {
        let (store, link) = make()
        await store.refresh()
        link.updateError = CoreClientError.notConnected
        store.openSheet(deviceID: "SPP-000067", settingsID: "devices.0")
        await store.startUpdate(deviceID: "SPP-000067")
        #expect(store.startFailure == "The monitor is not connected. Nothing was started.")
        #expect(store.sheetStage == .confirm)
    }

    // MARK: The sheet while it runs, and after

    @Test("the sheet cannot be closed while an update runs, only after it finishes")
    func closing() async throws {
        let (store, link) = make()
        await store.refresh()
        store.openSheet(deviceID: "SPP-000067", settingsID: "devices.0")
        await store.startUpdate(deviceID: "SPP-000067")
        #expect(!store.canCloseSheet)
        #expect(!store.closeSheet())
        #expect(store.sheetDeviceID == "SPP-000067")
        await store.observe(stateJob: FakeFirmwareLink.job(phase: "restarting", updatedAt: 130))
        #expect(!store.closeSheet())
        let done = try #require(FakeFirmwareLink.job(phase: "done", outcome: "updated", updatedAt: 160))
        link.job = FakeFirmwareLink.jobValue(phase: "done", outcome: "updated")
        await store.observe(stateJob: done)
        guard case .finished = store.sheetStage else {
            Issue.record("expected the finished stage"); return
        }
        #expect(store.cardState(settingsID: "SPP-000067", kind: "pro", fallbackName: "Pro").display == .succeeded)
        #expect(store.closeSheet())
        #expect(store.sheetDeviceID == nil)
        let after = store.cardState(settingsID: "SPP-000067", kind: "pro", fallbackName: "Pro")
        #expect(after.result == nil, "the result is shown until it is closed, then the device speaks")
    }

    @Test("a finished job the window never watched is not shown as news")
    func oldJobIsQuiet() async throws {
        let (store, link) = make()
        link.job = FakeFirmwareLink.jobValue(phase: "done", outcome: "updated")
        let old = try #require(FakeFirmwareLink.job(phase: "done", outcome: "updated", updatedAt: 50))
        await store.pageAppeared(stateJob: old)
        #expect(!store.showsFinishedJob(store.job))
        let card = store.cardState(settingsID: "SPP-000067", kind: "pro", fallbackName: "Pro")
        #expect(card.result == nil)
    }

    @Test("a running job from before the window opened can be followed")
    func followsARunningJob() async throws {
        let (store, link) = make()
        let running = try #require(FakeFirmwareLink.job(phase: "restarting", updatedAt: 120))
        link.job = FakeFirmwareLink.jobValue(phase: "restarting", outcome: nil)
        await store.pageAppeared(stateJob: running)
        #expect(store.anyJobRunning)
        let card = store.cardState(settingsID: "SPP-000067", kind: "pro", fallbackName: "Pro")
        #expect(card.isRunning && !card.canStart)
        store.openSheet(deviceID: "SPP-000067", settingsID: "devices.0")
        guard case .running = store.sheetStage else {
            Issue.record("expected the running stage"); return
        }
        await store.startUpdate(deviceID: "SPP-000067")
        #expect(!link.names.contains("firmware_update"))
    }

    @Test("a stale frame cannot move a job backwards or drop a running one")
    func staleFrames() async throws {
        let (store, _) = make()
        await store.observe(stateJob: FakeFirmwareLink.job(phase: "copying", updatedAt: 130))
        await store.observe(stateJob: FakeFirmwareLink.job(phase: "downloading", updatedAt: 110))
        #expect(store.job?.phase == .copying)
        await store.observe(stateJob: nil)
        #expect(store.job?.phase == .copying, "a frame built before the start may arrive after its reply")
    }

    // MARK: Design rules

    @Test("no firmware file starts a timer, a clock or a poll")
    func noTimers() throws {
        let sources = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appending(path: "Sources/JRBarApp")
        let forbidden = ["Timer", "TimelineView", "scheduledTimer", "asyncAfter", "AsyncStream", "Task.sleep"]
        for file in ["FirmwareStore.swift", "FirmwareCard.swift"] {
            let text = try String(contentsOf: sources.appending(path: file), encoding: .utf8)
            for word in forbidden {
                #expect(!text.contains(word), "\(file) mentions \(word)")
            }
        }
        // The sheet waits one beat before opening calibration, and has no clock.
        let sheet = try String(contentsOf: sources.appending(path: "FirmwareSheet.swift"), encoding: .utf8)
        for word in ["Timer", "TimelineView", "scheduledTimer", "asyncAfter"] {
            #expect(!sheet.contains(word), "FirmwareSheet.swift mentions \(word)")
        }
    }

    @Test("firmware_update is named in exactly one place in the app")
    func oneSender() throws {
        let sources = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appending(path: "Sources")
        let walker = try #require(FileManager.default.enumerator(at: sources, includingPropertiesForKeys: nil))
        var files: [String] = []
        for case let url as URL in walker where url.pathExtension == "swift" {
            let text = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
            if text.contains("\"firmware_update\"") { files.append(url.lastPathComponent) }
        }
        #expect(files == ["FirmwareStore.swift"])
    }

    @Test("the store's Settings seat is one object, made with the Settings store")
    func settingsSeat() {
        let core = CoreModel(socketPath: "/tmp/jrbar-test-none.sock")
        let settings = SettingsStore(core: core)
        #expect(settings.firmware.status == nil, "nothing is read until the Devices page asks")
        #expect(settings.firmware.sheetDeviceID == nil)
    }
}
