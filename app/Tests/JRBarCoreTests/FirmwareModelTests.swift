import Foundation
import Testing
@testable import JRBarCore

/// The firmware vocabulary: the `firmware_status` reply, the job document
/// and `state.firmware`, decoded tolerantly, and the plain words the
/// Devices page and its confirmation sheet say about them.
@Suite("Firmware model and presenter")
struct FirmwareModelTests {
    // MARK: Fixtures

    struct NotAState: Error {}

    static let proReply = """
    {"catalog":[
      {"model":"pro","name":"SidePulse Pro","version":"1.1.0",
       "notes":["Better white balance through the diffuser.","More reliable updates."],
       "package":{"host":"raw.githubusercontent.com","name":"sidepulse-pro-1.1.0-ota.zip","bytes":137875,"cached":false},
       "drive":"SidePulse","image_bytes":136992},
      {"model":"dot","name":"SidePulse Dot","version":"1.1.14","notes":["Better drive identification."],
       "package":{"host":"raw.githubusercontent.com","name":"sidepulse-dot-1.1.14-ota.zip","bytes":20480,"cached":true},
       "drive":"PulseDot","image_bytes":19000}],
     "devices":[
      {"id":"SPP-000067","name":"SidePulse Pro","root":"/Volumes/SidePulse","mounted":true,"model":"pro",
       "serial":"SPP-000067","version":"1.0.2","active_slot":"A","build":"2026-08-05T23:25:42Z","uptime_ms":83257187,
       "latest":"1.1.0","update_available":true,"can_update":true,"why_not":null,
       "other_slot":{"name":"B","has_image":false,"valid":true,"version":"none"},"colour_note":false}],
     "job":null,"download_host":"raw.githubusercontent.com"}
    """

    static func reply(_ text: String = proReply) throws -> FirmwareStatusReply {
        let value = try JSONDecoder().decode(JSONValue.self, from: Data(text.utf8))
        return try #require(FirmwareStatusReply(value))
    }

    /// A job document: the base below, with `fields` (JSON object members)
    /// laid over it, so a fixture names only what it changes.
    static func job(_ fields: String) throws -> FirmwareJob {
        let base = """
        {"id":"fw-1","device":"SPP-000067","model":"pro","name":"SidePulse Pro","serial":"SPP-000067",
         "from_version":"1.0.2","to_version":"1.1.0","source":"download","started_at":100.0,
         "phase_started_at":100.0,"updated_at":100.0,"finished_at":null,"download":null,
         "removed_sidecars":[],"new_slot":null,"previous_firmware":null,"colour_check":false,"restarted":false}
        """
        let decoder = JSONDecoder()
        var members = try #require(decoder.decode(JSONValue.self, from: Data(base.utf8)).objectValue)
        let over = try #require(decoder.decode(JSONValue.self, from: Data(("{" + fields + "}").utf8)).objectValue)
        members.merge(over) { _, new in new }
        return try #require(FirmwareJob(JSONValue.object(members)))
    }

    static let proDevice = FirmwareDevice(
        id: "SPP-000067", name: "SidePulse Pro", root: "/Volumes/SidePulse", mounted: true, model: "pro",
        serial: "SPP-000067", version: "1.0.2", activeSlot: "A", latest: "1.1.0", updateAvailable: true,
        canUpdate: true, otherSlot: FirmwareSlot(name: "B", hasImage: false, valid: true, version: "none"))

    static let proRelease = FirmwareRelease(
        model: "pro", name: "SidePulse Pro", version: "1.1.0", notes: ["Better white balance."],
        package: FirmwarePackage(host: "raw.githubusercontent.com", name: "x.zip", bytes: 137_875, cached: false))

    // MARK: Decoding

    @Test("a realistic firmware_status reply decodes")
    func statusDecodes() throws {
        let reply = try Self.reply()
        #expect(reply.downloadHost == "raw.githubusercontent.com")
        #expect(reply.catalog.map(\.model) == ["pro", "dot"])
        let pro = try #require(reply.release(for: "pro"))
        #expect(pro.package?.bytes == 137_875)
        #expect(pro.package?.cached == false)
        #expect(pro.notes.count == 2)
        let device = try #require(reply.devices.first)
        #expect(device.version == "1.0.2" && device.updateAvailable == true && device.canUpdate)
        #expect(device.otherSlot?.name == "B")
        #expect(device.whyNot == nil)
        #expect(reply.job == nil)
    }

    @Test("missing keys and unknown words never blank the reply")
    func tolerant() throws {
        let text = """
        {"catalog":[{"model":"pro"},{"model":"pro","version":"1.1.0","notes":[1,"ok"],"future":true}],
         "devices":[{"nope":1},{"id":"x"},{"id":"y","mounted":true,"why_not":{"code":"device_busy"},"extra":{}}],
         "job":{"id":"j"}}
        """
        let reply = try Self.reply(text)
        #expect(reply.catalog.count == 1, "a release without a version is dropped, not guessed")
        #expect(reply.catalog.first?.notes == ["ok"])
        #expect(reply.devices.map(\.id) == ["x", "y"])
        #expect(reply.devices[0].mounted == false && reply.devices[0].canUpdate == false)
        #expect(reply.devices[1].whyNot?.code == "device_busy")
        #expect(reply.job == nil, "a job with no device is no job")
        #expect(FirmwareStatusReply(JSONValue.string("nope")) == nil)
    }

    @Test("an unknown phase and outcome read as safe values")
    func unknownWords() throws {
        let odd = try Self.job(#""phase":"rebooting-soon","phase_label":"Doing a thing","outcome":"exploded""#)
        #expect(odd.phase == .unknown)
        #expect(odd.outcome == .unconfirmed, "an outcome nobody knows is never a success")
        #expect(!odd.isRunning)
        let running = try Self.job(#""phase":"copying","outcome":null,"source":"somewhere""#)
        #expect(running.phase == .copying && running.isRunning && running.source == .unknown)
        #expect(FirmwarePresenter.progress(for: odd).label == "Doing a thing")
    }

    @Test("download progress and the previous firmware decode")
    func jobDetails() throws {
        let job = try Self.job("""
        "phase":"downloading","download":{"bytes":98304,"total":137875},"outcome":"updated","finished_at":172.0,
        "previous_firmware":{"version":"1.0.2","slot":"A","valid":true,"firmware":"1.0.2"},"colour_check":true,
        "removed_sidecars":["._FIRMWARE.BIN"],"new_slot":"B"
        """)
        #expect(job.download == FirmwareDownload(bytes: 98304, total: 137_875))
        #expect(job.previousFirmware?.slot == "A")
        #expect(job.colourCheck && job.newSlot == "B")
        #expect(job.duration == 72)
    }

    @Test("state.firmware is optional and a malformed job reads as none")
    func stateFrame() throws {
        func frame(_ firmware: String) throws -> CoreState {
            let line = #"{"t":"state","v":1,"generation":3,"now":1.0"# + firmware + "}"
            guard case .state(let state) = try CoreCodec.decode(line: line) else { throw NotAState() }
            return state
        }
        #expect(try frame("").firmware == nil)
        let running = try frame(#","firmware":{"id":"fw-1","device":"SPP-1","phase":"copying","outcome":null}"#)
        #expect(running.firmware?.phase == .copying)
        #expect(running.firmware?.isRunning == true)
        #expect(try frame(#","firmware":"nope""#).firmware == nil)
        #expect(try frame(#","firmware":{"phase":"copying"}"#).firmware == nil)
    }

    @Test("CoreModel carries state.firmware as its own slice")
    @MainActor
    func modelSlice() throws {
        let core = CoreModel(socketPath: "/tmp/jrbar-test-none.sock")
        #expect(core.firmware == nil)
        let job = try Self.job(#""phase":"copying","outcome":null"#)
        core.handle(.connected)
        core.apply(.state(CoreState(generation: 1, now: 1, firmware: job)))
        #expect(core.firmware?.phase == .copying)
        core.apply(.state(CoreState(generation: 2, now: 2)))
        #expect(core.firmware == nil, "a frame without the key is no job")
    }

    @Test("the daemon's own state frame still decodes, with no firmware job")
    func pythonFixture() throws {
        let state = try PythonProjectionFixtureTests.state()
        #expect(state.generation > 0)
        #expect(state.firmware == nil)
    }

    @Test("a Settings card finds its device by id, else by its only kind")
    func matching() throws {
        let reply = try Self.reply()
        #expect(reply.device(matching: "SPP-000067", kind: "pro")?.id == "SPP-000067")
        #expect(reply.device(matching: "sidepulse:pro:B293A1", kind: "pro")?.id == "SPP-000067")
        #expect(reply.device(matching: "sidepulse:dot:7F02C4", kind: "dot") == nil)
    }

    // MARK: Numbers and words

    @Test("kilobytes and download progress read as numbers and words")
    func numbers() {
        #expect(FirmwarePresenter.kilobytes(137_875) == "135 KB")
        #expect(FirmwarePresenter.kilobytes(10) == "1 KB")
        #expect(FirmwarePresenter.downloadProgress(FirmwareDownload(bytes: 98304, total: 137_875)) == "96 of 135 KB")
        #expect(FirmwarePresenter.downloadProgress(FirmwareDownload(bytes: 98304, total: nil)) == "96 KB so far")
        #expect(FirmwarePresenter.downloadProgress(FirmwareDownload(bytes: 900_000, total: 137_875)) == "135 of 135 KB")
        #expect(FirmwarePresenter.duration(42) == "42s")
        #expect(FirmwarePresenter.duration(72) == "1m 12s")
        #expect(FirmwarePresenter.duration(120) == "2m")
    }

    // MARK: The group

    private func state(device: FirmwareDevice?, job: FirmwareJob? = nil, show: Bool = false, loaded: Bool = true,
                       failure: String? = nil) -> FirmwareCardState {
        FirmwarePresenter.state(deviceID: "SPP-000067", device: device, release: Self.proRelease, loaded: loaded,
                                failure: failure, job: job, showFinishedJob: show, fallbackName: "SidePulse")
    }

    @Test("up to date, update available, cannot update, offline")
    func baseStates() {
        var current = Self.proDevice
        current.version = "1.1.0"
        current.updateAvailable = false
        current.canUpdate = false
        let upToDate = state(device: current)
        #expect(upToDate.display == .upToDate(version: "1.1.0"))
        #expect(upToDate.headline == "SidePulse Pro, firmware 1.1.0 (up to date)")
        #expect(!upToDate.canStart)

        let available = state(device: Self.proDevice)
        #expect(available.display == .updateAvailable(from: "1.0.2", to: "1.1.0"))
        #expect(available.headline == "SidePulse Pro, firmware 1.0.2: 1.1.0 is available")
        #expect(available.canStart)
        #expect(available.notes == ["Better white balance."])

        var busy = Self.proDevice
        busy.canUpdate = false
        busy.whyNot = FirmwareWhyNot(code: "device_busy", message: "The device looks busy: reading. Wait a minute and try again.")
        let cannot = state(device: busy)
        #expect(cannot.display == .cannotUpdate(version: "1.0.2", latest: "1.1.0",
                                                reason: "The device looks busy: reading. Wait a minute and try again."))
        #expect(!cannot.canStart)
        #expect(cannot.detail == "The device looks busy: reading. Wait a minute and try again.")

        var gone = Self.proDevice
        gone.mounted = false
        gone.canUpdate = false
        for device in [gone, nil] {
            let offline = state(device: device)
            #expect(offline.display == .offline)
            #expect(!offline.canStart)
            #expect(offline.detail?.contains("Reconnect") == true)
        }
    }

    @Test("an unreadable version never offers an update")
    func unreadable() {
        var unknown = Self.proDevice
        unknown.version = nil
        unknown.updateAvailable = nil
        unknown.canUpdate = false
        unknown.whyNot = FirmwareWhyNot(code: "facts_unknown", message: "JR-Bar could not read this device.")
        let card = state(device: unknown)
        #expect(!card.canStart)
        #expect(card.detail == "JR-Bar could not read this device.")
        var versionOnly = Self.proDevice
        versionOnly.updateAvailable = nil
        versionOnly.canUpdate = false
        #expect(!state(device: versionOnly).canStart)
    }

    @Test("before a reading, and after a failed one, nothing is claimed")
    func notLoaded() {
        let loading = state(device: nil, loaded: false)
        #expect(loading.display == .loading && !loading.canStart)
        let failed = state(device: nil, loaded: false, failure: "The monitor is not reachable.")
        #expect(failed.display == .unavailable("The monitor is not reachable."))
        #expect(!failed.canStart)
    }

    @Test("a running job shows its phase, and another device's job blocks this one")
    func running() throws {
        let job = try Self.job(#""phase":"downloading","phase_label":"Downloading the update","outcome":null,"download":{"bytes":98304,"total":137875}"#)
        let card = state(device: Self.proDevice, job: job)
        #expect(card.display == .running(phase: .downloading))
        #expect(card.isRunning && !card.canStart)
        #expect(card.detail == "Downloading the update, 96 of 135 KB. Please leave the device connected.")
        let dot = FirmwareDevice(id: "SPD-000010", name: "SidePulse Dot", mounted: true, model: "dot", version: "1.1.2",
                                 latest: "1.1.14", updateAvailable: true, canUpdate: true)
        let dotRelease = FirmwareRelease(model: "dot", name: "SidePulse Dot", version: "1.1.14")
        let other = FirmwarePresenter.state(deviceID: "SPD-000010", device: dot, release: dotRelease,
                                            loaded: true, job: job, showFinishedJob: false, fallbackName: "Dot")
        #expect(!other.canStart)
        #expect(other.blockedNote?.contains("SidePulse Pro") == true)
    }

    @Test("progress counts steps without the download when the package is already here")
    func steps() throws {
        let download = try Self.job(#""phase":"copying","outcome":null"#)
        #expect(FirmwarePresenter.progress(for: download).step == "Step 5 of 7")
        let cached = try Self.job(#""phase":"copying","outcome":null,"source":"cache""#)
        #expect(FirmwarePresenter.progress(for: cached).step == "Step 4 of 6")
        #expect(FirmwarePresenter.progress(for: cached).download == nil)
        #expect(FirmwarePresenter.progress(for: cached).reminder == "Please leave the device connected")
    }

    // MARK: Results

    @Test("an update that worked says what the device now runs and what is kept")
    func succeeded() throws {
        let job = try Self.job("""
        "phase":"done","outcome":"updated","finished_at":172.0,"code":null,"message":"The SidePulse Pro now runs firmware 1.1.0.",
        "previous_firmware":{"version":"1.0.2","slot":"A","valid":true,"firmware":"1.0.2"},"colour_check":true,
        "removed_sidecars":["._FIRMWARE.BIN","._x"],"new_slot":"B"
        """)
        let result = try #require(FirmwarePresenter.result(for: job))
        #expect(result.kind == .succeeded)
        #expect(result.headline == "The SidePulse Pro now runs firmware 1.1.0")
        #expect(result.lines.contains("The previous firmware 1.0.2 is kept in slot A."))
        #expect(result.lines.contains("JR-Bar tidied 2 hidden macOS files off the drive."))
        #expect(result.colourNote == "This firmware applies its own colour gains, so colour calibration may need a re-check.")
        #expect(result.tookLine == "It took about 1 min 12 s.")
        let card = state(device: Self.proDevice, job: job, show: true)
        #expect(card.display == .succeeded)
        #expect(!state(device: Self.proDevice, job: job, show: false).isRunning)
        #expect(state(device: Self.proDevice, job: job, show: false).display == .updateAvailable(from: "1.0.2", to: "1.1.0"))
    }

    @Test("a Dot's success has no previous-firmware line and no colour note")
    func dotSucceeded() throws {
        let job = try Self.job("""
        "device":"SPD-000010","model":"dot","name":"SidePulse Dot","from_version":"1.1.2","to_version":"1.1.14",
        "phase":"done","outcome":"updated","finished_at":150.0,"colour_check":false,"previous_firmware":null
        """)
        let result = try #require(FirmwarePresenter.result(for: job))
        #expect(result.headline == "The SidePulse Dot now runs firmware 1.1.14")
        #expect(result.lines.isEmpty)
        #expect(result.colourNote == nil)
    }

    @Test("a failure keeps the daemon's sentence and says the old firmware is still there")
    func failed() throws {
        let job = try Self.job("""
        "phase":"done","outcome":"failed","code":"bad_hash","finished_at":120.0,
        "message":"The download did not match the fingerprint JR-Bar expects, so it was thrown away.",
        "what_to_do":"Try again later."
        """)
        let result = try #require(FirmwarePresenter.result(for: job))
        #expect(result.kind == .failed)
        #expect(result.lines.first == "The download did not match the fingerprint JR-Bar expects, so it was thrown away.")
        #expect(result.lines.contains("Try again later."))
        #expect(result.lines.last == "The SidePulse Pro is still on its old firmware (1.0.2).")
    }

    @Test("a device that reports something unexpected is not called unchanged")
    func failedUnsure() throws {
        let job = try Self.job(#""phase":"done","outcome":"failed","code":"unexpected_version","message":"The device reports firmware 1.0.9, not 1.1.0.""#)
        let result = try #require(FirmwarePresenter.result(for: job))
        #expect(!result.lines.contains { $0.contains("still on its old firmware") })
        #expect(result.lines.last == "Check which firmware the SidePulse Pro reports before you try again.")
    }

    @Test("an unconfirmed update is never a success")
    func unconfirmed() throws {
        let job = try Self.job(#""phase":"done","outcome":"unconfirmed","code":"no_return","message":"The device's drive did not come back within two minutes.""#)
        let result = try #require(FirmwarePresenter.result(for: job))
        #expect(result.kind == .unconfirmed)
        #expect(result.headline == "The SidePulse Pro did not confirm the update")
        let words = result.lines.joined(separator: " ")
        #expect(words.contains("did not come back"))
        #expect(words.contains("Check the device and reconnect it"))
        #expect(!words.lowercased().contains("now runs"))
        #expect(state(device: Self.proDevice, job: job, show: true).display == .unconfirmed)
    }

    // MARK: The confirmation

    @Test("an uncached Pro update says what is downloaded, written and kept")
    func confirmationUncached() {
        let words = FirmwarePresenter.confirmation(device: Self.proDevice, release: Self.proRelease,
                                                   downloadHost: "raw.githubusercontent.com", fallbackName: "SidePulse")
        #expect(words.title == "Update the SidePulse Pro to firmware 1.1.0?")
        #expect(words.confirmLabel == "Download and update")
        #expect(!words.cached)
        let text = words.bullets.map(\.text)
        #expect(text.contains { $0.contains("from raw.githubusercontent.com") && $0.contains("135 KB") && $0.contains("1.1.0") })
        #expect(text.contains { $0.contains("only thing sent over the network") })
        #expect(text.contains { $0.contains("go still for about a minute") && $0.contains("linked partner") })
        #expect(text.contains("Nothing else is written to the device: only the single file FIRMWARE.BIN, plus tidying hidden macOS ._ files on its drive."))
        #expect(text.contains { $0.contains("awake and plugged in") })
        let kept = text.first { $0.contains("kept in slot") }
        #expect(kept == "The firmware it runs now (1.0.2) is kept in slot A while the new one goes to slot B. JR-Bar has no button to switch back.")
        #expect(!text.joined().lowercased().contains("roll back"))
    }

    @Test("a cached package downloads nothing and a Dot has no slot line")
    func confirmationCached() {
        var release = Self.proRelease
        release.package?.cached = true
        var dot = Self.proDevice
        dot.model = "dot"
        dot.activeSlot = nil
        dot.otherSlot = nil
        let words = FirmwarePresenter.confirmation(device: dot, release: release, downloadHost: nil, fallbackName: "Dot")
        #expect(words.cached && words.confirmLabel == "Update")
        let text = words.bullets.map(\.text)
        #expect(text.contains { $0.contains("already on this Mac") && $0.contains("nothing will be downloaded") })
        #expect(!text.contains { $0.contains("raw.githubusercontent.com") })
        #expect(!text.contains { $0.contains("kept in slot") })
    }
}
