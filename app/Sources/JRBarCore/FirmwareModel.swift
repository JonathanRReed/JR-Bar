import Foundation

// MARK: - Firmware updates (docs/CORE-PROTOCOL.md, "Firmware updates")
//
// What the daemon says about a SidePulse's firmware: the `firmware_status`
// reply (the pinned releases, each device's reading, and the job) and the
// job document itself, which also rides in `state.firmware`. Every type is
// decoded by hand from a `JSONValue`: a missing key is nil, a word this
// build does not know reads as a safe value, and one malformed row never
// takes the rest down.

private func firmwareText(_ value: JSONValue, _ key: String) -> String? {
    guard let text = value[key]?.stringValue, !text.isEmpty else { return nil }
    return text
}

private func firmwareBool(_ value: JSONValue, _ key: String) -> Bool? {
    guard case .bool(let flag)? = value[key] else { return nil }
    return flag
}

private func firmwareNumber(_ value: JSONValue, _ key: String) -> Double? {
    guard case .number(let number)? = value[key], number.isFinite else { return nil }
    return number
}

private func firmwareInt(_ value: JSONValue, _ key: String) -> Int? {
    firmwareNumber(value, key).map { Int($0.rounded()) }
}

/// Where a job is. A phase this build does not know reads as `unknown`, and
/// the job's own `phase_label` sentence is what the person sees then.
public enum FirmwarePhase: String, Codable, Hashable, Sendable {
    case checking, downloading, verifying, preparing, copying, restarting, confirming, done
    case unknown

    public init(wire: String?) {
        self = wire.flatMap(FirmwarePhase.init(rawValue:)) ?? .unknown
    }
}

/// How a job ended. Anything but the three words the daemon speaks reads as
/// `unconfirmed`: never a success this build cannot vouch for.
public enum FirmwareOutcome: String, Codable, Hashable, Sendable {
    case updated, failed, unconfirmed

    public init(wire: String) {
        self = FirmwareOutcome(rawValue: wire) ?? .unconfirmed
    }
}

/// Where the package came from (`download`, `cache`, `file`).
public enum FirmwareSource: String, Codable, Hashable, Sendable {
    case download, cache, file
    case unknown
}

/// `download` while a package is being fetched: bytes so far, and the
/// total when the daemon knows it.
public struct FirmwareDownload: Codable, Hashable, Sendable {
    public var bytes: Int
    public var total: Int?

    public init(bytes: Int, total: Int? = nil) {
        self.bytes = bytes
        self.total = total
    }

    init?(_ value: JSONValue?) {
        guard let value, value.objectValue != nil else { return nil }
        bytes = max(0, firmwareInt(value, "bytes") ?? 0)
        let total = firmwareInt(value, "total")
        self.total = total.flatMap { $0 > 0 ? $0 : nil }
    }
}

/// `previous_firmware`: the old image a Pro still holds after an update.
public struct FirmwarePrevious: Codable, Hashable, Sendable {
    public var version: String?
    public var slot: String?
    public var valid: Bool
    public var firmware: String?

    public init(version: String? = nil, slot: String? = nil, valid: Bool = true, firmware: String? = nil) {
        self.version = version
        self.slot = slot
        self.valid = valid
        self.firmware = firmware
    }

    init?(_ value: JSONValue?) {
        guard let value, value.objectValue != nil else { return nil }
        version = firmwareText(value, "version")
        slot = firmwareText(value, "slot")
        valid = firmwareBool(value, "valid") ?? false
        firmware = firmwareText(value, "firmware")
    }
}

/// The job document: `state.firmware`, `firmware_status.job` and
/// `firmware_update.job`.
public struct FirmwareJob: Codable, Hashable, Sendable, Identifiable {
    public var id: String
    /// The `firmware_status` device id this job updates.
    public var device: String
    public var model: String?
    public var name: String?
    public var serial: String?
    public var fromVersion: String?
    public var toVersion: String?
    public var phase: FirmwarePhase
    /// The sentence to show for the phase; empty from a daemon that sent none.
    public var phaseLabel: String
    /// nil while it runs.
    public var outcome: FirmwareOutcome?
    public var code: String?
    public var message: String?
    public var whatToDo: String?
    public var source: FirmwareSource
    public var startedAt: Double?
    public var phaseStartedAt: Double?
    public var updatedAt: Double?
    public var finishedAt: Double?
    public var download: FirmwareDownload?
    public var removedSidecars: [String]
    public var newSlot: String?
    public var previousFirmware: FirmwarePrevious?
    public var colourCheck: Bool
    public var restarted: Bool

    public init(id: String, device: String, model: String? = nil, name: String? = nil, serial: String? = nil,
                fromVersion: String? = nil, toVersion: String? = nil, phase: FirmwarePhase = .checking,
                phaseLabel: String = "", outcome: FirmwareOutcome? = nil, code: String? = nil,
                message: String? = nil, whatToDo: String? = nil, source: FirmwareSource = .unknown,
                startedAt: Double? = nil, phaseStartedAt: Double? = nil, updatedAt: Double? = nil,
                finishedAt: Double? = nil, download: FirmwareDownload? = nil, removedSidecars: [String] = [],
                newSlot: String? = nil, previousFirmware: FirmwarePrevious? = nil,
                colourCheck: Bool = false, restarted: Bool = false) {
        self.id = id
        self.device = device
        self.model = model
        self.name = name
        self.serial = serial
        self.fromVersion = fromVersion
        self.toVersion = toVersion
        self.phase = phase
        self.phaseLabel = phaseLabel
        self.outcome = outcome
        self.code = code
        self.message = message
        self.whatToDo = whatToDo
        self.source = source
        self.startedAt = startedAt
        self.phaseStartedAt = phaseStartedAt
        self.updatedAt = updatedAt
        self.finishedAt = finishedAt
        self.download = download
        self.removedSidecars = removedSidecars
        self.newSlot = newSlot
        self.previousFirmware = previousFirmware
        self.colourCheck = colourCheck
        self.restarted = restarted
    }

    /// Tolerant: no id or no device is no job; anything else missing is nil.
    public init?(_ value: JSONValue?) {
        guard let value, value.objectValue != nil,
              let id = firmwareText(value, "id"), let device = firmwareText(value, "device") else { return nil }
        let outcomeWord = firmwareText(value, "outcome")
        self.init(
            id: id,
            device: device,
            model: firmwareText(value, "model"),
            name: firmwareText(value, "name"),
            serial: firmwareText(value, "serial"),
            fromVersion: firmwareText(value, "from_version"),
            toVersion: firmwareText(value, "to_version"),
            phase: FirmwarePhase(wire: value["phase"]?.stringValue),
            phaseLabel: value["phase_label"]?.stringValue ?? "",
            outcome: outcomeWord.map(FirmwareOutcome.init(wire:)),
            code: firmwareText(value, "code"),
            message: firmwareText(value, "message"),
            whatToDo: firmwareText(value, "what_to_do"),
            source: value["source"]?.stringValue.map { FirmwareSource(rawValue: $0) ?? .unknown } ?? .unknown,
            startedAt: firmwareNumber(value, "started_at"),
            phaseStartedAt: firmwareNumber(value, "phase_started_at"),
            updatedAt: firmwareNumber(value, "updated_at"),
            finishedAt: firmwareNumber(value, "finished_at"),
            download: FirmwareDownload(value["download"]),
            removedSidecars: (value["removed_sidecars"]?.arrayValue ?? []).compactMap(\.stringValue),
            newSlot: firmwareText(value, "new_slot"),
            previousFirmware: FirmwarePrevious(value["previous_firmware"]),
            colourCheck: firmwareBool(value, "colour_check") ?? false,
            restarted: firmwareBool(value, "restarted") ?? false
        )
    }

    enum CodingKeys: String, CodingKey {
        case id, device, model, name, serial, phase, outcome, code, message, source, download, restarted
        case fromVersion = "from_version"
        case toVersion = "to_version"
        case phaseLabel = "phase_label"
        case whatToDo = "what_to_do"
        case startedAt = "started_at"
        case phaseStartedAt = "phase_started_at"
        case updatedAt = "updated_at"
        case finishedAt = "finished_at"
        case removedSidecars = "removed_sidecars"
        case newSlot = "new_slot"
        case previousFirmware = "previous_firmware"
        case colourCheck = "colour_check"
    }

    public init(from decoder: Decoder) throws {
        let value = try JSONValue(from: decoder)
        guard let job = FirmwareJob(value) else {
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath,
                                                    debugDescription: "firmware job has no id or device"))
        }
        self = job
    }

    /// Running until the daemon names an outcome.
    public var isRunning: Bool { outcome == nil }

    /// Seconds the whole job took, once it has finished.
    public var duration: Double? {
        guard let startedAt, let finishedAt, finishedAt >= startedAt else { return nil }
        return finishedAt - startedAt
    }
}

/// One slot of a Pro's two (`other_slot`).
public struct FirmwareSlot: Codable, Hashable, Sendable {
    public var name: String?
    public var hasImage: Bool
    public var valid: Bool
    public var version: String?

    public init(name: String? = nil, hasImage: Bool = false, valid: Bool = false, version: String? = nil) {
        self.name = name
        self.hasImage = hasImage
        self.valid = valid
        self.version = version
    }

    init?(_ value: JSONValue?) {
        guard let value, value.objectValue != nil else { return nil }
        name = firmwareText(value, "name")
        hasImage = firmwareBool(value, "has_image") ?? false
        valid = firmwareBool(value, "valid") ?? false
        version = firmwareText(value, "version")
    }
}

/// `why_not`: the code and the sentence for a device that cannot be updated now.
public struct FirmwareWhyNot: Codable, Hashable, Sendable {
    public var code: String
    public var message: String

    public init(code: String, message: String) {
        self.code = code
        self.message = message
    }

    init?(_ value: JSONValue?) {
        guard let value, value.objectValue != nil else { return nil }
        code = firmwareText(value, "code") ?? "unknown"
        message = firmwareText(value, "message") ?? ""
    }
}

/// One connected (or remembered) device in the `firmware_status` reply.
public struct FirmwareDevice: Codable, Hashable, Sendable, Identifiable {
    public var id: String
    public var name: String
    public var root: String?
    public var mounted: Bool
    /// `pro` or `dot`; nil when the device could not be read.
    public var model: String?
    public var serial: String?
    public var version: String?
    public var activeSlot: String?
    public var build: String?
    public var uptimeMs: Double?
    public var latest: String?
    /// nil when the device's version cannot be read.
    public var updateAvailable: Bool?
    public var canUpdate: Bool
    public var whyNot: FirmwareWhyNot?
    public var otherSlot: FirmwareSlot?
    public var colourNote: Bool

    public init(id: String, name: String, root: String? = nil, mounted: Bool = true, model: String? = nil,
                serial: String? = nil, version: String? = nil, activeSlot: String? = nil, build: String? = nil,
                uptimeMs: Double? = nil, latest: String? = nil, updateAvailable: Bool? = nil,
                canUpdate: Bool = false, whyNot: FirmwareWhyNot? = nil, otherSlot: FirmwareSlot? = nil,
                colourNote: Bool = false) {
        self.id = id
        self.name = name
        self.root = root
        self.mounted = mounted
        self.model = model
        self.serial = serial
        self.version = version
        self.activeSlot = activeSlot
        self.build = build
        self.uptimeMs = uptimeMs
        self.latest = latest
        self.updateAvailable = updateAvailable
        self.canUpdate = canUpdate
        self.whyNot = whyNot
        self.otherSlot = otherSlot
        self.colourNote = colourNote
    }

    public init?(_ value: JSONValue?) {
        guard let value, value.objectValue != nil, let id = firmwareText(value, "id") else { return nil }
        self.init(
            id: id,
            name: firmwareText(value, "name") ?? id,
            root: firmwareText(value, "root"),
            mounted: firmwareBool(value, "mounted") ?? false,
            model: firmwareText(value, "model"),
            serial: firmwareText(value, "serial"),
            version: firmwareText(value, "version"),
            activeSlot: firmwareText(value, "active_slot"),
            build: firmwareText(value, "build"),
            uptimeMs: firmwareNumber(value, "uptime_ms"),
            latest: firmwareText(value, "latest"),
            updateAvailable: firmwareBool(value, "update_available"),
            canUpdate: firmwareBool(value, "can_update") ?? false,
            whyNot: FirmwareWhyNot(value["why_not"]),
            otherSlot: FirmwareSlot(value["other_slot"]),
            colourNote: firmwareBool(value, "colour_note") ?? false
        )
    }

    enum CodingKeys: String, CodingKey {
        case id, name, root, mounted, model, serial, version, build, latest
        case activeSlot = "active_slot"
        case uptimeMs = "uptime_ms"
        case updateAvailable = "update_available"
        case canUpdate = "can_update"
        case whyNot = "why_not"
        case otherSlot = "other_slot"
        case colourNote = "colour_note"
    }

    public init(from decoder: Decoder) throws {
        let value = try JSONValue(from: decoder)
        guard let device = FirmwareDevice(value) else {
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath,
                                                    debugDescription: "firmware device has no id"))
        }
        self = device
    }
}

/// The package a release ships as (`catalog[].package`).
public struct FirmwarePackage: Codable, Hashable, Sendable {
    public var host: String
    public var name: String?
    public var bytes: Int
    /// The verified package is already on this Mac: nothing to download.
    public var cached: Bool

    public init(host: String, name: String? = nil, bytes: Int = 0, cached: Bool = false) {
        self.host = host
        self.name = name
        self.bytes = bytes
        self.cached = cached
    }

    init?(_ value: JSONValue?) {
        guard let value, value.objectValue != nil else { return nil }
        host = firmwareText(value, "host") ?? ""
        name = firmwareText(value, "name")
        bytes = max(0, firmwareInt(value, "bytes") ?? 0)
        cached = firmwareBool(value, "cached") ?? false
    }
}

/// One pinned release the app knows (`catalog[]`), with its notes in plain words.
public struct FirmwareRelease: Codable, Hashable, Sendable {
    public var model: String
    public var name: String
    public var version: String
    public var notes: [String]
    public var package: FirmwarePackage?
    public var drive: String?
    public var imageBytes: Int?

    public init(model: String, name: String, version: String, notes: [String] = [],
                package: FirmwarePackage? = nil, drive: String? = nil, imageBytes: Int? = nil) {
        self.model = model
        self.name = name
        self.version = version
        self.notes = notes
        self.package = package
        self.drive = drive
        self.imageBytes = imageBytes
    }

    public init?(_ value: JSONValue?) {
        guard let value, value.objectValue != nil,
              let model = firmwareText(value, "model"), let version = firmwareText(value, "version") else { return nil }
        self.init(
            model: model,
            name: firmwareText(value, "name") ?? model,
            version: version,
            notes: (value["notes"]?.arrayValue ?? []).compactMap(\.stringValue).filter { !$0.isEmpty },
            package: FirmwarePackage(value["package"]),
            drive: firmwareText(value, "drive"),
            imageBytes: firmwareInt(value, "image_bytes")
        )
    }

    enum CodingKeys: String, CodingKey {
        case model, name, version, notes, package, drive
        case imageBytes = "image_bytes"
    }

    public init(from decoder: Decoder) throws {
        let value = try JSONValue(from: decoder)
        guard let release = FirmwareRelease(value) else {
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath,
                                                    debugDescription: "firmware release has no model or version"))
        }
        self = release
    }
}

/// The `firmware_status` reply.
public struct FirmwareStatusReply: Codable, Hashable, Sendable {
    public var catalog: [FirmwareRelease]
    public var devices: [FirmwareDevice]
    public var job: FirmwareJob?
    public var downloadHost: String?

    public init(catalog: [FirmwareRelease] = [], devices: [FirmwareDevice] = [], job: FirmwareJob? = nil,
                downloadHost: String? = nil) {
        self.catalog = catalog
        self.devices = devices
        self.job = job
        self.downloadHost = downloadHost
    }

    public init?(_ value: JSONValue?) {
        guard let value, value.objectValue != nil else { return nil }
        self.init(
            catalog: (value["catalog"]?.arrayValue ?? []).compactMap { FirmwareRelease($0) },
            devices: (value["devices"]?.arrayValue ?? []).compactMap { FirmwareDevice($0) },
            job: FirmwareJob(value["job"]),
            downloadHost: firmwareText(value, "download_host")
        )
    }

    enum CodingKeys: String, CodingKey {
        case catalog, devices, job
        case downloadHost = "download_host"
    }

    public init(from decoder: Decoder) throws {
        let value = try JSONValue(from: decoder)
        guard let reply = FirmwareStatusReply(value) else {
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath,
                                                    debugDescription: "firmware_status is not an object"))
        }
        self = reply
    }

    /// The pinned release for a model (`pro`, `dot`).
    public func release(for model: String?) -> FirmwareRelease? {
        guard let model else { return nil }
        return catalog.first { $0.model == model }
    }

    /// The reading that belongs to a Settings device card: the row with the
    /// card's own id, else the only row of the card's kind (`pro`, `dot`).
    public func device(matching id: String, kind: String) -> FirmwareDevice? {
        if let exact = devices.first(where: { $0.id == id }) { return exact }
        let ofKind = devices.filter { $0.model == kind }
        return ofKind.count == 1 ? ofKind.first : nil
    }
}

/// The reply to `firmware_update`: started with its job, or a plain refusal.
public struct FirmwareStartReply: Hashable, Sendable {
    public var started: Bool
    public var job: FirmwareJob?

    public init(started: Bool, job: FirmwareJob? = nil) {
        self.started = started
        self.job = job
    }

    public init(_ value: JSONValue?) {
        self.init(started: value?["started"]?.boolValue ?? false, job: FirmwareJob(value?["job"]))
    }
}
