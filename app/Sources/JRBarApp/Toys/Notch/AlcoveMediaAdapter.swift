import AppKit
import JRBarCore

/// The entitled Now Playing reader. Since macOS 15.4 `mediaremoted`
/// refuses unentitled clients — `MRMediaRemoteGetNowPlayingInfo` called
/// in-process answers with an empty dictionary no matter what is
/// playing, and adding the private entitlement gets a signed build
/// killed at launch. The working shape (what boring.notch ships, after
/// ungive's mediaremote-adapter): `/usr/bin/perl` is a platform binary
/// that holds the entitlement, so we spawn it, DynaLoader-load the
/// embedded `jrbar_mediaremote` dylib into it, and read the JSON lines
/// it prints — one per now-playing change, `null` while nothing plays.
///
/// The dylib is compiled bytes shipped inside the app binary
/// (`AlcoveMediaAdapterAsset`), materialized to a temp file named by its
/// sha so an upgrade never runs a stale copy. Anything missing — no
/// perl, a failed write, a process that dies — drops the monitor onto
/// the in-process MediaRemote path, which still works where reads were
/// never gated.
@MainActor
final class AlcoveMediaAdapter {
    /// Fresh media (nil while nothing plays); already deduped by the
    /// helper, so every callback is a real change.
    var onChange: (@MainActor (AlcoveMedia?) -> Void)?
    /// The helper died before (or without ever) printing — the caller
    /// falls back to the in-process path for the rest of this run.
    var onFailure: (@MainActor () -> Void)?

    /// The perl driver: load the dylib, install `jrbar_mr_stream` as an
    /// xsub, call it. The function owns the process from there — it runs
    /// the run loop and exits when stdin closes.
    private static let perlDriver = """
        use DynaLoader;
        my $handle = DynaLoader::dl_load_file($ARGV[0], 0)
            or die "dl_load_file: ", DynaLoader::dl_error(), "\\n";
        my $symbol = DynaLoader::dl_find_symbol($handle, "jrbar_mr_stream")
            or die "jrbar_mr_stream not found\\n";
        DynaLoader::dl_install_xsub("main::jrbar_mr_stream", $symbol);
        &main::jrbar_mr_stream();
        """

    private var process: Process?
    private var stdin: FileHandle?
    private var stdout: FileHandle?
    /// Partial-line carry between readability callbacks.
    private var pending = Data()
    /// The first line's timer: a live helper prints `null` immediately,
    /// so silence past this means the path is dead.
    private var watchdog: DispatchWorkItem?
    private var sawFirstLine = false

    private(set) var running = false

    /// Writes the embedded dylib beside the temp dir, keyed by its sha —
    /// a new build is a new file, never an overwrite of a mapped image.
    private func materialize() -> URL? {
        guard let bytes = Data(base64Encoded: AlcoveMediaAdapterAsset.dylibBase64),
              !bytes.isEmpty else { return nil }
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("jrbar-alcove", isDirectory: true)
        let url = dir.appendingPathComponent(
            "mediaremote-\(AlcoveMediaAdapterAsset.dylibSHA256.prefix(16)).dylib")
        let fm = FileManager.default
        if fm.fileExists(atPath: url.path),
           (try? Data(contentsOf: url, options: .mappedIfSafe)) == bytes {
            return url
        }
        do {
            try fm.createDirectory(at: dir, withIntermediateDirectories: true)
            try bytes.write(to: url, options: .atomic)
            return url
        } catch {
            NSLog("JR-Bar: alcove media adapter write failed: %@", error.localizedDescription)
            return nil
        }
    }

    private var perlIsInstalled: Bool {
        FileManager.default.isExecutableFile(atPath: "/usr/bin/perl")
    }

    func start() {
        guard !running else { return }
        running = true
        pending = Data()
        guard perlIsInstalled, let dylib = materialize() else {
            fail()
            return
        }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/perl")
        process.arguments = ["-MDynaLoader", "-e", Self.perlDriver, dylib.path]
        let out = Pipe()
        let input = Pipe()
        process.standardOutput = out
        process.standardInput = input
        process.standardError = FileHandle.nullDevice
        process.terminationHandler = { [weak self] _ in
            DispatchQueue.main.async {
                MainActor.assumeIsolated { self?.terminated() }
            }
        }
        out.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let chunk = handle.availableData
            DispatchQueue.main.async {
                MainActor.assumeIsolated { self?.consume(chunk) }
            }
        }
        do {
            try process.run()
        } catch {
            out.fileHandleForReading.readabilityHandler = nil
            fail()
            return
        }
        self.process = process
        self.stdin = input.fileHandleForWriting
        self.stdout = out.fileHandleForReading
        sawFirstLine = false
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated {
                guard let self, self.running, !self.sawFirstLine else { return }
                self.fail()
            }
        }
        watchdog = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 4, execute: work)
    }

    /// A transport command — "send N" down the helper's stdin. The
    /// helper is entitled, so this works on the releases where the
    /// in-process `MRMediaRemoteSendCommand` also still works; the
    /// monitor sends through whichever path is alive.
    func send(_ command: MediaRemoteBridge.Command) {
        guard running, let stdin else { return }
        try? stdin.write(contentsOf: Data("send \(command.rawValue)\n".utf8))
    }

    func stop() {
        running = false
        watchdog?.cancel()
        watchdog = nil
        stdout?.readabilityHandler = nil
        stdout = nil
        let process = self.process
        self.process = nil
        stdin = nil
        if let process {
            // Closing stdin is the graceful exit; terminate is the
            // guarantee — the run loop stops on EOF either way.
            process.terminationHandler = nil
            process.terminate()
        }
    }

    /// The helper died: silent while nothing was ever heard (the watchdog
    /// reports it), or an ordinary drop mid-run — either way the caller
    /// moves to the in-process path for the rest of this run.
    private func terminated() {
        guard running else { return }
        fail()
    }

    private func fail() {
        guard running else { return }
        running = false
        watchdog?.cancel()
        watchdog = nil
        stdout?.readabilityHandler = nil
        stdout = nil
        process?.terminationHandler = nil
        process?.terminate()
        process = nil
        stdin = nil
        onFailure?()
    }

    /// Append the chunk, split whole lines, parse each into a media.
    private func consume(_ chunk: Data) {
        guard running else { return }
        pending.append(chunk)
        while let newline = pending.firstIndex(of: UInt8(ascii: "\n")) {
            let line = pending.prefix(upTo: newline)
            pending = pending.subdata(in: pending.index(after: newline)..<pending.endIndex)
            sawFirstLine = true
            watchdog?.cancel()
            watchdog = nil
            onChange?(Self.parse(line))
        }
    }

    /// One JSON line → media. `null` (or a payload without a title) is
    /// the helper's "nothing playing"; an unparseable line is shrugged
    /// into nil the same way — the island simply shows no media.
    static func parse(_ line: Data) -> AlcoveMedia? {
        let trimmed = line.drop(while: { $0 == UInt8(ascii: " ") || $0 == UInt8(ascii: "\t") })
        guard !trimmed.isEmpty, trimmed != Data("null".utf8) else { return nil }
        guard let object = try? JSONSerialization.jsonObject(with: trimmed),
              let payload = object as? [String: Any] else { return nil }
        return AlcoveMedia.summarize(adapter: payload)
    }
}
