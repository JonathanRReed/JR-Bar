import AppKit
import Foundation
import JRBarLEDS

/// Where the Screen Bar's program comes from until the daemon protocol exists.
///
/// 1. `JRBAR_PROGRAM_FILE` when set -- a developer override fed from any
///    file, watched like the device file;
/// 2. `LEDS.LED` on a mounted SidePulse volume -- the hardware's own file, so
///    the on-screen band shows exactly what the device is playing. A strip is
///    preferred over a Dot; a lone Dot's two-LED program is widened to the
///    bar's eight before it is published;
/// 3. a built-in calm breathing program.
///
/// There is deliberately no daemon state file here: the monitor's programs
/// go straight to `LEDS.LED` on the volume, and a `screen-bar.led` feed was
/// sketched but never implemented -- watching for it only promised a source
/// that cannot exist.
///
/// Everything is event driven: kqueue watches on the file and its directory,
/// plus mount/unmount notifications for the SD-card volume. Reads happen off
/// the main thread because a sleeping card reader can stall a read for a
/// moment.
@MainActor
final class LEDFeed {
    enum Source: Equatable, CustomStringConvertible {
        case device(String)
        case stateFile(String)
        case builtInIdle

        var description: String {
            switch self {
            case .device(let path): return path
            case .stateFile(let path): return path
            case .builtInIdle: return "built-in idle breath"
            }
        }
    }

    /// The daemon's device vocabulary (`_device_writer_legacy.DEVICE_NAME_HINTS`,
    /// `_led_status_legacy`): a volume counts as a device when its mount name
    /// carries a hint or the firmware's own STATUS.TXT sits beside LEDS.LED;
    /// the STATUS.TXT serial prefix (SPP strip, SPD Dot) outranks the name.
    /// "sidepulse" is not in the daemon's hint table, but the live Pro mounts
    /// as bare "SidePulse" and this feed used to follow that path unconditionally.
    nonisolated static let deviceNameHints = ["sidepulsepro", "sidepulsedot", "pulsedot", "sidepulse"]

    nonisolated static func normalizedDeviceName(_ name: String) -> String {
        String(name.lowercased().filter { $0.isLetter || $0.isNumber })
    }

    nonisolated static func isDeviceName(_ name: String) -> Bool {
        let normalized = normalizedDeviceName(name)
        return deviceNameHints.contains { normalized.contains($0) }
    }

    /// The LED count the firmware's STATUS.TXT serial declares (`serial
    /// SPP-000067`): SPD is a Dot, SPP a Pro. nil when the file is missing or
    /// the first `serial` line is not a known prefix -- the name rule below
    /// answers then, exactly as `_led_count_from_serial` returns None.
    nonisolated static func serialLedCount(volumePath: String) -> Int? {
        let statusPath = (volumePath as NSString).appendingPathComponent("STATUS.TXT")
        guard let text = try? String(contentsOfFile: statusPath, encoding: .utf8) else { return nil }
        for line in text.prefix(4096).components(separatedBy: .newlines) {
            guard line.hasPrefix("serial ") else { continue }
            let parts = line.split(whereSeparator: { $0 == " " || $0 == "\t" })
            guard parts.count == 2 else { return nil }
            let prefix = parts[1].split(separator: "-", maxSplits: 1).first.map(String.init)?.uppercased() ?? ""
            return ["SPD": 2, "SPP": 8][prefix]
        }
        return nil
    }

    /// `led_count_for_target`: the serial's answer when there is one, else the
    /// mount-name hint, else the strip default. The bare "SidePulse" label is
    /// a Dot by `device_kind`'s rule -- the live Pro mounts under exactly that
    /// name and is reclassified by its SPP serial, so a name-only answer of 8
    /// here would push strip-width programs (and skip the Dot widening) on
    /// two-LED hardware.
    nonisolated static func deviceLedCount(volumePath: String) -> Int {
        if let count = serialLedCount(volumePath: volumePath) { return count }
        let name = normalizedDeviceName((volumePath as NSString).lastPathComponent)
        return name.contains("sidepulsedot") || name.contains("pulsedot") || name.hasSuffix("sidepulse") ? 2 : 8
    }

    /// True when the volume holding a candidate LEDS.LED is a two-LED Dot.
    nonisolated static func isDotVolume(_ volumePath: String) -> Bool {
        deviceLedCount(volumePath: volumePath) == 2
    }

    /// The LEDS.LED to follow: any mounted volume the daemon's rules would call
    /// a device -- a name hint, or STATUS.TXT beside the file. A strip wins over
    /// a Dot; equals fall to the name. nil when no device is mounted.
    nonisolated static func resolveDevicePath(volumesDirectory: String = "/Volumes", fileManager: FileManager = .default) -> String? {
        guard let names = try? fileManager.contentsOfDirectory(atPath: volumesDirectory) else { return nil }
        var candidates: [(path: String, dot: Bool, name: String)] = []
        for name in names {
            let volume = (volumesDirectory as NSString).appendingPathComponent(name)
            var isDirectory: ObjCBool = false
            guard fileManager.fileExists(atPath: volume, isDirectory: &isDirectory), isDirectory.boolValue else { continue }
            let target = (volume as NSString).appendingPathComponent("LEDS.LED")
            guard fileManager.fileExists(atPath: target) else { continue }
            let hasMarker = fileManager.fileExists(atPath: (volume as NSString).appendingPathComponent("STATUS.TXT"))
            guard isDeviceName(name) || hasMarker else { continue }
            candidates.append((target, isDotVolume(volume), name))
        }
        // The daemon's own order (`status_bar_devices`): a strip before a
        // Dot, then normalized name, then mount path -- two same-named
        // devices must resolve the same way on both sides.
        candidates.sort {
            ($0.dot ? 1 : 0, normalizedDeviceName($0.name), $0.path)
                < ($1.dot ? 1 : 0, normalizedDeviceName($1.name), $1.path)
        }
        return candidates.first?.path
    }

    /// A mounted volume that looks like a device but has no LEDS.LED yet.
    /// The firmware creates the file a beat after the mount lands, and the
    /// mount notification has already fired by then -- without a watch on
    /// the volume's own directory the device stays invisible until the next
    /// mount event. First match in the same order `resolveDevicePath` would
    /// pick; any hit re-runs resolve, which re-picks for real.
    nonisolated static func resolvePendingDeviceVolume(volumesDirectory: String = "/Volumes", fileManager: FileManager = .default) -> String? {
        guard let names = try? fileManager.contentsOfDirectory(atPath: volumesDirectory) else { return nil }
        var pending: [(path: String, dot: Bool, name: String)] = []
        for name in names {
            let volume = (volumesDirectory as NSString).appendingPathComponent(name)
            var isDirectory: ObjCBool = false
            guard fileManager.fileExists(atPath: volume, isDirectory: &isDirectory), isDirectory.boolValue else { continue }
            guard !fileManager.fileExists(atPath: (volume as NSString).appendingPathComponent("LEDS.LED")) else { continue }
            let hasMarker = fileManager.fileExists(atPath: (volume as NSString).appendingPathComponent("STATUS.TXT"))
            guard isDeviceName(name) || hasMarker else { continue }
            pending.append((volume, isDotVolume(volume), name))
        }
        pending.sort {
            ($0.dot ? 1 : 0, normalizedDeviceName($0.name), $0.path)
                < ($1.dot ? 1 : 0, normalizedDeviceName($1.name), $1.path)
        }
        return pending.first?.path
    }

    /// The idle breath from `_led_status_legacy._render_full_strip`, lifted to a
    /// soft neutral ember so a bare screen still shows a living band. The
    /// hardware idle colour (#020204) is invisible at screen contrast.
    static let idleProgram = "off 160ms cosine\n#2B2F36 1900ms cosine\noff 2550ms cosine\noff 850ms none\nrepeat"

    /// `(program, source, anchorEpoch)`: the anchor is the file's own
    /// modification instant -- the firmware restarts LEDS.LED on every
    /// write, so the bar phase-locks to the write, not to whenever the
    /// read happened to land. nil for the built-in idle breath.
    var onProgram: (@MainActor (String, Source, Double?) -> Void)?
    private(set) var source: Source = .builtInIdle
    private var fileWatcher: FileWatcher?
    private var directoryWatcher: FileWatcher?
    private var volumeWatcher: FileWatcher?
    /// The device-looking volume whose LEDS.LED has not been created yet
    /// (`resolvePendingDeviceVolume`) -- its directory watch is what lets
    /// the file's arrival re-resolve the feed.
    private var pendingDeviceWatcher: FileWatcher?
    private var pendingRead: DispatchWorkItem?
    private var lastPublished: (text: String, source: Source, mtime: Double?)?
    /// Resolve and read are independent pipelines: a scheduled read must
    /// not kill an in-flight device resolution, so they carry separate
    /// generations. A resolve still supersedes an in-flight read — it
    /// bumps the read generation too, since the source it read from is
    /// about to be replaced.
    private var resolveGeneration = 0
    private var readGeneration = 0
    /// The instant the file watcher last reported `.write`. SD-card
    /// filesystems (FAT/exFAT) quantize mtime to ~2 s, so two daemon
    /// reasserts inside one quantum carry an identical mtime and the
    /// dedupe would swallow a real firmware restart. The write event
    /// itself is the evidence — it becomes the anchor when the file's
    /// own mtime cannot tell the writes apart.
    private var writeEpoch: Double = 0

    /// Whether the feed is watching. It runs only while the daemon is not
    /// live — the daemon itself writes LEDS.LED on every reassert, and the
    /// bar draws the daemon's lights then — so the delegate stops it on
    /// connect and starts it again when the daemon goes away.
    private(set) var isRunning = false

    /// Watch the volumes and resolve the source now. A second start while
    /// running changes nothing.
    func start() {
        guard !isRunning else { return }
        isRunning = true
        let center = NSWorkspace.shared.notificationCenter
        center.addObserver(self, selector: #selector(volumesChanged(_:)), name: NSWorkspace.didMountNotification, object: nil)
        center.addObserver(self, selector: #selector(volumesChanged(_:)), name: NSWorkspace.didUnmountNotification, object: nil)
        // /Volumes changes also cover a card that mounts without a notification reaching us.
        volumeWatcher = FileWatcher(path: "/Volumes", mask: [.write, .link, .attrib]) { [weak self] _ in self?.resolve() }
        volumeWatcher?.start()
        resolve()
    }

    /// Every watch and the mount notifications go, and a resolve or read
    /// on its way is dropped. The last published program stays, so a
    /// restart publishes only what changed while stopped.
    func stop() {
        guard isRunning else { return }
        isRunning = false
        let center = NSWorkspace.shared.notificationCenter
        center.removeObserver(self, name: NSWorkspace.didMountNotification, object: nil)
        center.removeObserver(self, name: NSWorkspace.didUnmountNotification, object: nil)
        volumeWatcher?.stop()
        volumeWatcher = nil
        fileWatcher?.stop()
        directoryWatcher?.stop()
        pendingDeviceWatcher?.stop()
        fileWatcher = nil
        directoryWatcher = nil
        pendingDeviceWatcher = nil
        pendingRead?.cancel()
        pendingRead = nil
        resolveGeneration += 1
        readGeneration += 1
    }

    @objc private func volumesChanged(_ note: Notification) {
        resolve()
    }

    /// Developer override: `JRBAR_PROGRAM_FILE=/path/to/file.led` feeds the bar
    /// from any file (watched like the device file) without touching the strip.
    static let overridePath: String? = ProcessInfo.processInfo.environment["JRBAR_PROGRAM_FILE"].flatMap { $0.isEmpty ? nil : $0 }

    private func resolve() {
        // A watch's delayed look-again can land after `stop`.
        guard isRunning else { return }
        resolveGeneration += 1
        readGeneration += 1
        let generation = resolveGeneration
        let override = Self.overridePath
        // The /Volumes enumeration and the STATUS.TXT reads inside it can
        // stall on a sleeping card reader; they run off the main thread and
        // the answer lands back here through the generation check.
        Task.detached(priority: .utility) {
            let devicePath = override == nil ? Self.resolveDevicePath() : nil
            let pendingVolume = override == nil ? Self.resolvePendingDeviceVolume() : nil
            await MainActor.run { [weak self] in
                guard let self, self.resolveGeneration == generation else { return }
                let next: Source
                if let override {
                    next = .stateFile(override)
                } else if let devicePath {
                    next = .device(devicePath)
                } else {
                    next = .builtInIdle
                }
                self.installWatchers(for: next, pendingVolume: pendingVolume)
                let previous = self.source
                self.source = next
                self.scheduleRead(after: Self.readDelay(from: previous, to: next))
            }
        }
    }

    private func installWatchers(for source: Source, pendingVolume: String? = nil) {
        fileWatcher?.stop()
        directoryWatcher?.stop()
        pendingDeviceWatcher?.stop()
        fileWatcher = nil
        directoryWatcher = nil
        pendingDeviceWatcher = nil
        // Write events against the old source must not anchor the new one.
        writeEpoch = 0
        if let pendingVolume {
            // A device that mounted without LEDS.LED: the create lands in
            // this directory, not in /Volumes.
            pendingDeviceWatcher = FileWatcher(path: pendingVolume, mask: [.write, .link, .attrib, .delete, .rename, .revoke]) { [weak self] _ in
                self?.resolve()
            }
            pendingDeviceWatcher?.start()
        }
        let path: String
        switch source {
        case .device(let p), .stateFile(let p): path = p
        case .builtInIdle: return
        }
        let directory = (path as NSString).deletingLastPathComponent
        directoryWatcher = FileWatcher(path: directory, mask: [.write, .link, .attrib, .delete, .rename, .revoke]) { [weak self] event in
            guard let self else { return }
            if event.contains(.delete) || event.contains(.rename) || event.contains(.revoke) {
                self.resolve()
            } else {
                // A new or replaced file: re-arm the file watch, then read.
                if self.fileWatcher?.isActive != true { self.fileWatcher?.start() }
                self.scheduleRead()
            }
        }
        directoryWatcher?.start()
        fileWatcher = FileWatcher(path: path) { [weak self] event in
            guard let self else { return }
            if event.contains(.delete) || event.contains(.rename) || event.contains(.revoke) {
                self.fileWatcher?.stop()
                // Give a rename-into-place a moment, then look again.
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { [weak self] in
                    MainActor.assumeIsolated { self?.resolve() }
                }
            } else {
                // A real byte write is a firmware restart even when the
                // quantized mtime cannot tell it from the previous one.
                if event.contains(.write) { self.writeEpoch = Date().timeIntervalSince1970 }
                self.scheduleRead()
            }
        }
        fileWatcher?.start()
    }

    /// How long a device has to come back before the bar gives up on it:
    /// the MacBook's SD reader can power the Pro off and on by itself,
    /// and the bar keeps the strip's last program on its own clock for
    /// that long instead of dropping to the idle breath and back.
    nonisolated static let unplugGrace: TimeInterval = 3

    /// When a resolve's read lands: after the unplug grace when a device
    /// just gave way to the idle breath (a remount inside it re-resolves
    /// and cancels the read), else the usual burst debounce.
    nonisolated static func readDelay(from previous: Source, to next: Source) -> TimeInterval {
        if case .device = previous, next == .builtInIdle { return unplugGrace }
        return 0.08
    }

    private func scheduleRead(after delay: TimeInterval = 0.08) {
        pendingRead?.cancel()
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated { self?.readAndPublish() }
        }
        pendingRead = work
        // Writers land in bursts (truncate, write, fsync); one read per burst.
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }

    private func readAndPublish() {
        readGeneration += 1
        let generation = readGeneration
        let source = source
        switch source {
        case .builtInIdle:
            publish(Self.idleProgram, source: source)
        case .device(let path), .stateFile(let path):
            Task.detached(priority: .utility) {
                var text = try? String(contentsOfFile: path, encoding: .utf8)
                // A Dot's program addresses two LEDs; the bar compiles at
                // eight, so it is widened before it is published.
                if let program = text, case .device = source,
                   Self.isDotVolume((path as NSString).deletingLastPathComponent),
                   let parsed = try? LEDSProgram.parse(program, ledCount: 2) {
                    text = parsed.widened(from: 2, to: 8).render()
                }
                // The write's own instant is the program's epoch: the
                // firmware restarts on every LEDS.LED write, so the anchor
                // is the file's mtime rather than this read's landing time.
                let mtime = (try? FileManager.default.attributesOfItem(atPath: path))
                    .flatMap { ($0[.modificationDate] as? Date)?.timeIntervalSince1970 }
                await MainActor.run { [weak self] in
                    guard let self, self.readGeneration == generation else { return }
                    // The later of the file's stamp and the observed write:
                    // on a coarse filesystem two restarts share one mtime,
                    // and the event instant is the only honest anchor.
                    let anchor = max(mtime ?? 0, self.writeEpoch)
                    if let text, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        self.publish(text, source: source, mtime: anchor > 0 ? anchor : nil)
                    } else if case .stateFile = source {
                        // The override file is empty or missing: breathe
                        // until it has a program.
                        self.publish(Self.idleProgram, source: .builtInIdle)
                    } else if !FileManager.default.fileExists(atPath: path) {
                        self.resolve()
                    }
                }
            }
        }
    }

    private func publish(_ text: String, source: Source, mtime: Double? = nil) {
        // Dedupe on (text, mtime), not text alone: the daemon's periodic
        // reassert rewrites LEDS.LED with identical bytes and the firmware
        // restarts the loop from line 1. An unchanged mtime is the same
        // program still running; an advanced one is a restart the bar must
        // re-anchor to, or it keeps a stale phase and visibly jumps.
        if let last = lastPublished, last.text == text, last.source == source, last.mtime == mtime { return }
        lastPublished = (text, source, mtime)
        onProgram?(text, source, mtime)
    }
}
