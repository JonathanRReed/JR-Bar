import AppKit
import Foundation

/// Where the Screen Bar's program comes from until the daemon protocol exists.
///
/// 1. `/Volumes/SidePulse/LEDS.LED` -- the hardware's own file, so the on-screen
///    band shows exactly what the strip is playing;
/// 2. `~/.local/state/sidepulse/agent-monitor/screen-bar.led` -- a file the
///    monitor may start writing later (it need not exist yet);
/// 3. a built-in calm breathing program.
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

    static let devicePath = "/Volumes/SidePulse/LEDS.LED"
    static let stateDirectory = NSString(string: "~/.local/state/sidepulse/agent-monitor").expandingTildeInPath
    static let stateFilePath = stateDirectory + "/screen-bar.led"

    /// The idle breath from `_led_status_legacy._render_full_strip`, lifted to a
    /// soft neutral ember so a bare screen still shows a living band. The
    /// hardware idle colour (#020204) is invisible at screen contrast.
    static let idleProgram = "off 160ms cosine\n#2B2F36 1900ms cosine\noff 2550ms cosine\noff 850ms none\nrepeat"

    var onProgram: (@MainActor (String, Source) -> Void)?
    private(set) var source: Source = .builtInIdle
    private var fileWatcher: FileWatcher?
    private var directoryWatcher: FileWatcher?
    private var volumeWatcher: FileWatcher?
    private var pendingRead: DispatchWorkItem?
    private var lastPublished: (text: String, source: Source)?
    private var generation = 0

    func start() {
        let center = NSWorkspace.shared.notificationCenter
        center.addObserver(self, selector: #selector(volumesChanged(_:)), name: NSWorkspace.didMountNotification, object: nil)
        center.addObserver(self, selector: #selector(volumesChanged(_:)), name: NSWorkspace.didUnmountNotification, object: nil)
        // /Volumes changes also cover a card that mounts without a notification reaching us.
        volumeWatcher = FileWatcher(path: "/Volumes", mask: [.write, .link, .attrib]) { [weak self] _ in self?.resolve() }
        volumeWatcher?.start()
        resolve()
    }

    @objc private func volumesChanged(_ note: Notification) {
        resolve()
    }

    /// Developer override: `JRBAR_PROGRAM_FILE=/path/to/file.led` feeds the bar
    /// from any file (watched like the device file) without touching the strip.
    static let overridePath: String? = ProcessInfo.processInfo.environment["JRBAR_PROGRAM_FILE"].flatMap { $0.isEmpty ? nil : $0 }

    private func resolve() {
        let manager = FileManager.default
        let next: Source
        if let override = Self.overridePath {
            next = .stateFile(override)
        } else if manager.fileExists(atPath: Self.devicePath) {
            next = .device(Self.devicePath)
        } else if manager.fileExists(atPath: Self.stateDirectory) {
            next = .stateFile(Self.stateFilePath)
        } else {
            next = .builtInIdle
        }
        installWatchers(for: next)
        source = next
        scheduleRead()
    }

    private func installWatchers(for source: Source) {
        fileWatcher?.stop()
        directoryWatcher?.stop()
        fileWatcher = nil
        directoryWatcher = nil
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
                self.scheduleRead()
            }
        }
        fileWatcher?.start()
    }

    private func scheduleRead() {
        pendingRead?.cancel()
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated { self?.readAndPublish() }
        }
        pendingRead = work
        // Writers land in bursts (truncate, write, fsync); one read per burst.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.08, execute: work)
    }

    private func readAndPublish() {
        generation += 1
        let generation = generation
        let source = source
        switch source {
        case .builtInIdle:
            publish(Self.idleProgram, source: source)
        case .device(let path), .stateFile(let path):
            Task.detached(priority: .utility) {
                let text = try? String(contentsOfFile: path, encoding: .utf8)
                await MainActor.run { [weak self] in
                    guard let self, self.generation == generation else { return }
                    if let text, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        self.publish(text, source: source)
                    } else if case .stateFile = source {
                        // Nothing written yet: breathe until the monitor speaks.
                        self.publish(Self.idleProgram, source: .builtInIdle)
                    } else if !FileManager.default.fileExists(atPath: path) {
                        self.resolve()
                    }
                }
            }
        }
    }

    private func publish(_ text: String, source: Source) {
        if let last = lastPublished, last.text == text, last.source == source { return }
        lastPublished = (text, source)
        onProgram?(text, source)
    }
}
