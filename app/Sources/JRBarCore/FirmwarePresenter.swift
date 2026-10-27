import Foundation

// MARK: - Firmware: what Settings says about a device's firmware
//
// Pure logic and plain words. The Devices page and the confirmation sheet
// draw whatever this returns; nothing in here touches the daemon or the
// clock, so every sentence is testable.

/// What a device's Firmware group is showing.
public enum FirmwareDisplay: Hashable, Sendable {
    /// No reading yet: the page has not heard back from `firmware_status`.
    case loading
    /// `firmware_status` itself failed; the reason is the daemon's sentence.
    case unavailable(String)
    /// The device is not mounted, or the daemon does not list it.
    case offline
    case upToDate(version: String)
    case updateAvailable(from: String, to: String)
    /// Cannot be updated now. `latest` is set when a newer release exists.
    case cannotUpdate(version: String?, latest: String?, reason: String)
    case running(phase: FirmwarePhase)
    case succeeded
    case failed
    case unconfirmed
}

/// The Firmware group for one device, ready to draw.
public struct FirmwareCardState: Hashable, Sendable {
    public var display: FirmwareDisplay
    /// The device's name in the app's words ("SidePulse Pro").
    public var name: String
    /// "SidePulse Pro, firmware 1.1.0 (up to date)".
    public var headline: String
    /// The sentence under it: the reason, the result, or what to do.
    public var detail: String?
    /// Release notes, only while an update is on offer.
    public var notes: [String]
    /// The "Download and update…" button is enabled.
    public var canStart: Bool
    /// Why the button is off when something other than the device is the
    /// reason (another device's update is running).
    public var blockedNote: String?
    /// The latest job for this device is running or its result is on show.
    public var job: FirmwareJob?
    public var result: FirmwareResult?

    public init(display: FirmwareDisplay, name: String, headline: String, detail: String? = nil,
                notes: [String] = [], canStart: Bool = false, blockedNote: String? = nil,
                job: FirmwareJob? = nil, result: FirmwareResult? = nil) {
        self.display = display
        self.name = name
        self.headline = headline
        self.detail = detail
        self.notes = notes
        self.canStart = canStart
        self.blockedNote = blockedNote
        self.job = job
        self.result = result
    }

    /// An update is running on this device now.
    public var isRunning: Bool {
        if case .running = display { return true }
        return false
    }
}

/// How an update ended, in the words the sheet and the group show.
public struct FirmwareResult: Hashable, Sendable {
    public enum Kind: Hashable, Sendable { case succeeded, failed, unconfirmed }

    public var kind: Kind
    public var headline: String
    /// Further sentences, in reading order.
    public var lines: [String]
    /// A Pro update that crossed the firmware that balances colour itself.
    public var colourNote: String?
    /// "It took about 1 min 12 s", when the daemon gave both times.
    public var tookLine: String?

    public init(kind: Kind, headline: String, lines: [String] = [], colourNote: String? = nil, tookLine: String? = nil) {
        self.kind = kind
        self.headline = headline
        self.lines = lines
        self.colourNote = colourNote
        self.tookLine = tookLine
    }
}

/// A running job as numbers and words.
public struct FirmwareProgress: Hashable, Sendable {
    /// The daemon's sentence for the phase ("Copying the update to the device").
    public var label: String
    /// "Step 3 of 6".
    public var step: String?
    /// "96 of 135 KB", only while downloading.
    public var download: String?
    /// A phase that needs a word of reassurance ("Please leave the device connected").
    public var reminder: String

    public init(label: String, step: String? = nil, download: String? = nil, reminder: String) {
        self.label = label
        self.step = step
        self.download = download
        self.reminder = reminder
    }
}

/// One line of the confirmation sheet.
public struct FirmwareBullet: Hashable, Sendable {
    public var symbol: String
    public var text: String

    public init(symbol: String, text: String) {
        self.symbol = symbol
        self.text = text
    }
}

/// The confirmation sheet's words, before anything is sent.
public struct FirmwareConfirmation: Hashable, Sendable {
    public var title: String
    public var summary: String
    public var bullets: [FirmwareBullet]
    /// "Download and update", or "Update" when the package is already here.
    public var confirmLabel: String
    public var cached: Bool

    public init(title: String, summary: String, bullets: [FirmwareBullet], confirmLabel: String, cached: Bool) {
        self.title = title
        self.summary = summary
        self.bullets = bullets
        self.confirmLabel = confirmLabel
        self.cached = cached
    }
}

public enum FirmwarePresenter {
    // MARK: Words for numbers

    /// "135 KB": whole kilobytes (1024 bytes), never under 1.
    public static func kilobytes(_ bytes: Int) -> String {
        let kb = max(1, Int((Double(max(0, bytes)) / 1024).rounded()))
        return "\(kb) KB"
    }

    /// "96 of 135 KB", or "96 KB so far" when the total is not known.
    public static func downloadProgress(_ download: FirmwareDownload) -> String {
        guard let total = download.total, total > 0 else {
            return "\(kilobytes(download.bytes)) so far"
        }
        let done = max(0, Int((Double(min(download.bytes, total)) / 1024).rounded()))
        let all = max(1, Int((Double(total) / 1024).rounded()))
        return "\(done) of \(all) KB"
    }

    /// "42 s", "1 min 12 s".
    public static func duration(_ seconds: Double) -> String {
        UsageTime.duration(seconds)
    }

    // MARK: Names

    /// The device in the app's words: the pinned release's name for its
    /// model, else the reading's own name.
    public static func name(for device: FirmwareDevice?, release: FirmwareRelease?, fallback: String) -> String {
        if let release { return release.name }
        switch device?.model {
        case "pro": return "SidePulse Pro"
        case "dot": return "SidePulse Dot"
        default: return device?.name ?? fallback
        }
    }

    // MARK: The group

    /// What a device's Firmware group shows.
    ///
    /// - `device`: the device's row in the last `firmware_status`, nil when
    ///   the reply does not list it.
    /// - `loaded`: a `firmware_status` reply has arrived at all.
    /// - `job`: the update job the daemon reports, if any.
    /// - `showFinishedJob`: the person has not closed this job's result yet.
    public static func state(deviceID: String, device: FirmwareDevice?, release: FirmwareRelease?,
                             loaded: Bool, failure: String? = nil, job: FirmwareJob?,
                             showFinishedJob: Bool, fallbackName: String) -> FirmwareCardState {
        let name = Self.name(for: device, release: release, fallback: fallbackName)
        if let job, matches(job, deviceID: deviceID, device: device) {
            if job.isRunning {
                return runningState(job, name: name)
            }
            if showFinishedJob, let result = result(for: job, name: name) {
                return finishedState(job, result: result, name: name)
            }
        }
        var base = baseState(device: device, release: release, loaded: loaded, failure: failure, name: name)
        if let job, job.isRunning, !matches(job, deviceID: deviceID, device: device) {
            let other = job.name ?? "another device"
            base.canStart = false
            base.blockedNote = "An update for the \(other) is running. Wait for it to finish."
        }
        return base
    }

    private static func matches(_ job: FirmwareJob, deviceID: String, device: FirmwareDevice?) -> Bool {
        if job.device == deviceID { return true }
        guard let device else { return false }
        return job.device == device.id
    }

    private static func runningState(_ job: FirmwareJob, name: String) -> FirmwareCardState {
        let progress = progress(for: job)
        var detail = progress.label
        if let download = progress.download { detail += ", " + download }
        let headline = "Updating the \(name) to firmware \(job.toVersion ?? "the new version")"
        return FirmwareCardState(display: .running(phase: job.phase), name: name, headline: headline,
                                 detail: detail + ". " + progress.reminder + ".", canStart: false, job: job)
    }

    private static func finishedState(_ job: FirmwareJob, result: FirmwareResult, name: String) -> FirmwareCardState {
        let display: FirmwareDisplay
        switch result.kind {
        case .succeeded: display = .succeeded
        case .failed: display = .failed
        case .unconfirmed: display = .unconfirmed
        }
        return FirmwareCardState(display: display, name: name, headline: result.headline,
                                 detail: result.lines.first, canStart: false, job: job, result: result)
    }

    private static func baseState(device: FirmwareDevice?, release: FirmwareRelease?, loaded: Bool,
                                  failure: String?, name: String) -> FirmwareCardState {
        guard loaded else {
            if let failure {
                return FirmwareCardState(display: .unavailable(failure), name: name,
                                         headline: "\(name): firmware could not be read", detail: failure)
            }
            return FirmwareCardState(display: .loading, name: name, headline: "\(name): reading the firmware…")
        }
        guard let device, device.mounted else {
            return FirmwareCardState(
                display: .offline, name: name, headline: "\(name) is not connected",
                detail: "Reconnect it, then press Check firmware. JR-Bar can only read and update firmware on a connected device.")
        }
        guard let version = device.version else {
            let reason = device.whyNot?.message
                ?? "JR-Bar cannot read this device's firmware version, so it cannot offer an update."
            return FirmwareCardState(display: .cannotUpdate(version: nil, latest: device.latest, reason: reason),
                                     name: name, headline: "\(name), firmware version unknown", detail: reason)
        }
        switch device.updateAvailable {
        case .some(true):
            let latest = device.latest ?? release?.version ?? "a newer version"
            let headline = "\(name), firmware \(version): \(latest) is available"
            if device.canUpdate {
                return FirmwareCardState(display: .updateAvailable(from: version, to: latest), name: name,
                                         headline: headline, notes: release?.notes ?? [], canStart: true)
            }
            let reason = device.whyNot?.message ?? "This device cannot be updated right now."
            return FirmwareCardState(display: .cannotUpdate(version: version, latest: latest, reason: reason),
                                     name: name, headline: headline, detail: reason, notes: release?.notes ?? [])
        case .some(false):
            return FirmwareCardState(display: .upToDate(version: version), name: name,
                                     headline: "\(name), firmware \(version) (up to date)")
        case .none:
            let reason = device.whyNot?.message ?? "JR-Bar cannot tell whether a newer firmware exists for this device."
            return FirmwareCardState(display: .cannotUpdate(version: version, latest: nil, reason: reason),
                                     name: name, headline: "\(name), firmware \(version)", detail: reason)
        }
    }

    // MARK: A running job

    private static let stepOrder: [FirmwarePhase] = [
        .checking, .downloading, .verifying, .preparing, .copying, .restarting, .confirming,
    ]

    /// The phase as a sentence, a step count and download numbers.
    public static func progress(for job: FirmwareJob) -> FirmwareProgress {
        let label = job.phaseLabel.isEmpty ? fallbackLabel(job.phase) : job.phaseLabel
        var steps = stepOrder
        if job.source == .cache || job.source == .file { steps.removeAll { $0 == .downloading } }
        var step: String?
        if let index = steps.firstIndex(of: job.phase) {
            step = "Step \(index + 1) of \(steps.count)"
        }
        var download: String?
        if job.phase == .downloading, let transfer = job.download {
            download = downloadProgress(transfer)
        }
        return FirmwareProgress(label: label, step: step, download: download,
                                reminder: "Please leave the device connected")
    }

    private static func fallbackLabel(_ phase: FirmwarePhase) -> String {
        switch phase {
        case .checking: return "Checking the device"
        case .downloading: return "Downloading the update"
        case .verifying: return "Checking the download"
        case .preparing: return "Preparing the device's drive"
        case .copying: return "Copying the update to the device"
        case .restarting: return "Waiting for the device to restart"
        case .confirming: return "Confirming the new firmware"
        case .done: return "Done"
        case .unknown: return "Working on the update"
        }
    }

    // MARK: A finished job

    /// How a finished job reads; nil while it is still running.
    public static func result(for job: FirmwareJob, name: String? = nil) -> FirmwareResult? {
        guard let outcome = job.outcome else { return nil }
        let device = name ?? job.name ?? "device"
        let took = job.duration.map { "It took about \(duration($0))." }
        switch outcome {
        case .updated:
            return succeeded(job, device: device, took: took)
        case .failed:
            return failed(job, device: device)
        case .unconfirmed:
            let was = job.fromVersion.map { " Before the update it ran firmware \($0)." } ?? ""
            let advice = job.whatToDo
                ?? "Check the device and reconnect it, then press Check firmware to see which firmware it reports."
            var lines = [
                "JR-Bar copied the update, but the \(device) did not come back, so it cannot say the update worked.",
                advice + was,
            ]
            if let message = job.message, !lines.contains(message) { lines.insert(message, at: 1) }
            return FirmwareResult(kind: .unconfirmed, headline: "The \(device) did not confirm the update", lines: lines)
        }
    }

    private static func succeeded(_ job: FirmwareJob, device: String, took: String?) -> FirmwareResult {
        let version = job.toVersion ?? "the new firmware"
        var lines: [String] = []
        if let previous = job.previousFirmware, previous.valid {
            let was = previous.version ?? previous.firmware ?? "the old firmware"
            if let slot = previous.slot {
                lines.append("The previous firmware \(was) is kept in slot \(slot).")
            } else {
                lines.append("The previous firmware \(was) is kept in the other slot.")
            }
        }
        if !job.removedSidecars.isEmpty {
            let count = job.removedSidecars.count
            let noun = count == 1 ? "hidden macOS file" : "hidden macOS files"
            lines.append("JR-Bar tidied \(count) \(noun) off the drive.")
        }
        let colour = job.colourCheck && job.model != "dot"
            ? "This firmware applies its own colour gains, so colour calibration may need a re-check."
            : nil
        return FirmwareResult(kind: .succeeded, headline: "The \(device) now runs firmware \(version)",
                              lines: lines, colourNote: colour, tookLine: took)
    }

    /// A refusal or failure keeps the daemon's own sentence. Whether the
    /// device is still on its old firmware is only claimed when the daemon's
    /// code says nothing changed it.
    private static func failed(_ job: FirmwareJob, device: String) -> FirmwareResult {
        var lines: [String] = []
        if let message = job.message { lines.append(message) }
        if let todo = job.whatToDo { lines.append(todo) }
        let uncertain = job.code == "unexpected_version" || job.code == "device_changed"
        if uncertain {
            lines.append("Check which firmware the \(device) reports before you try again.")
        } else {
            let old = job.fromVersion.map { " (\($0))" } ?? ""
            lines.append("The \(device) is still on its old firmware\(old).")
        }
        return FirmwareResult(kind: .failed, headline: "The \(device) was not updated", lines: lines)
    }

    // MARK: The confirmation

    /// What the sheet says before anything is sent. Every claim here is one
    /// the daemon keeps: one file written, a pinned host, a package checked
    /// against a known hash, nothing else.
    public static func confirmation(device: FirmwareDevice, release: FirmwareRelease, downloadHost: String?,
                                    fallbackName: String) -> FirmwareConfirmation {
        let name = Self.name(for: device, release: release, fallback: fallbackName)
        let from = device.version ?? "its current firmware"
        let package = release.package
        let cached = package?.cached ?? false
        let packageHost = package?.host ?? ""
        let host = packageHost.isEmpty ? (downloadHost ?? "the release host") : packageHost
        let size = kilobytes(package?.bytes ?? 0)
        var bullets: [FirmwareBullet] = []
        if cached {
            bullets.append(FirmwareBullet(
                symbol: "internaldrive",
                text: "Firmware \(release.version) (\(size)) is already on this Mac, so nothing will be downloaded."))
        } else {
            bullets.append(FirmwareBullet(
                symbol: "arrow.down.circle",
                text: "Downloads firmware \(release.version) (\(size)) from \(host). That is the only thing sent over the network, and only because you pressed the button. JR-Bar checks the file against a fingerprint it already knows before using it."))
        }
        bullets.append(FirmwareBullet(
            symbol: "lightbulb.slash",
            text: "The LEDs on the \(name), and on its linked partner if one is connected, go still for about a minute."))
        bullets.append(FirmwareBullet(
            symbol: "doc",
            text: "Nothing else is written to the device: only the single file FIRMWARE.BIN, plus tidying hidden macOS ._ files on its drive."))
        bullets.append(FirmwareBullet(
            symbol: "powerplug",
            text: "Keep the Mac awake and plugged in, and leave the device connected, until it finishes."))
        if device.model == "pro", let kept = device.activeSlot {
            let incoming = device.otherSlot?.name.map { " while the new one goes to slot \($0)" } ?? ""
            bullets.append(FirmwareBullet(
                symbol: "square.stack.3d.up",
                text: "The firmware it runs now (\(from)) is kept in slot \(kept)\(incoming). JR-Bar has no button to switch back."))
        }
        return FirmwareConfirmation(
            title: "Update the \(name) to firmware \(release.version)?",
            summary: "The \(name) runs firmware \(from). Version \(release.version) is available.",
            bullets: bullets,
            confirmLabel: cached ? "Update" : "Download and update",
            cached: cached)
    }
}
