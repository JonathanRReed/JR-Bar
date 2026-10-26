import AppKit
import JRBarCore
import OSLog

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
/// (`AlcoveMediaAdapterAsset`), written to a private folder under
/// Application Support, named by its sha and checked against it before
/// every launch, so an upgrade never runs a stale copy. Anything missing — no
/// perl, a failed write, a process that dies — drops the monitor onto
/// the in-process MediaRemote path, which still works where reads were
/// never gated.
@MainActor
final class AlcoveMediaAdapter {
    /// Fresh media (nil while nothing plays); already deduped by the
    /// helper, so every callback is a real change.
    var onChange: (@MainActor (AlcoveMedia?) -> Void)?
    /// The helper died before (or without ever) printing — the caller
    /// falls back to the in-process path and restarts the helper on a
    /// bounded pace (`AlcoveMediaMonitor.adapterDidFail`), until the
    /// retry budget is spent.
    var onFailure: (@MainActor () -> Void)?

    /// The perl driver: load the dylib, install `jrbar_mr_stream` as an
    /// xsub, call it. The function owns the process from there — it runs
    /// the run loop and exits when stdin closes. The watcher thread is
    /// the SIGKILL case: a dead parent never closes the pipe, so the
    /// helper reaps itself once `getppid` reports it orphaned instead of
    /// leaking a MediaRemote client.
    private static let perlDriver = """
        use DynaLoader;
        use threads;
        threads->create(sub {
            while (getppid() > 1) { sleep 2 }
            kill 'KILL', $$;
        })->detach();
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
    /// Splits and parses the helper's output off the main thread; a new
    /// one per launch, so a dead helper's last chunk never reaches the
    /// next.
    private var reader: AlcoveMediaLineReader?
    /// The live reader's token: lines still in flight from a stopped
    /// helper are dropped rather than read as the new one's.
    private var readerToken: UUID?
    /// The first line's timer: a live helper prints `null` immediately,
    /// so silence past this means the path is dead.
    private var watchdog: DispatchWorkItem?
    private var sawFirstLine = false
    /// When this helper was launched, and whether it has carried a real
    /// track yet — the evidence lines say how long each took, so the
    /// log shows whether Now Playing actually works on this build.
    private var startedAt: Date?
    private var sawTrack = false

    private(set) var running = false

    /// The helper's evidence trail: live, first track, or why it fell
    /// back. `log show --predicate 'subsystem == "devin.jrbar" AND
    /// category == "media"'` reads it.
    static let log = Logger(subsystem: "devin.jrbar", category: "media")

    /// One evidence line for the helper's first answer. Pure for the
    /// tests: milliseconds since launch, and whether it was a track.
    static func firstLineNote(after seconds: TimeInterval, track: Bool) -> String {
        "helper live after \(Int((seconds * 1000).rounded())) ms — \(track ? "a track is playing" : "nothing playing")"
    }

    /// A verified copy of the embedded dylib in a folder only this account
    /// can enter (`AlcoveMediaAdapterFiles`), hashed against the pinned
    /// sha256 on every launch; nil when it cannot be made.
    private func materialize() -> URL? {
        guard let files = AlcoveMediaAdapterFiles.live() else { return nil }
        do {
            return try files.prepare()
        } catch {
            NSLog("JR-Bar: alcove media adapter not ready: %@", String(describing: error))
            return nil
        }
    }

    func start() {
        guard !running else { return }
        running = true
        guard let dylib = materialize() else {
            fail("the helper dylib could not be written")
            return
        }
        let token = UUID()
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
                MainActor.assumeIsolated { self?.terminated(from: token) }
            }
        }
        // A line carries the cover as base64 — up to 600 KB — and the
        // helper re-sends it with every play, pause and seek. The JSON
        // and the cover are read on the reader's queue; only the parsed
        // track reaches the main thread.
        let reader = AlcoveMediaLineReader { [weak self] media in
            DispatchQueue.main.async {
                MainActor.assumeIsolated { self?.deliver(media, from: token) }
            }
        }
        self.reader = reader
        readerToken = token
        out.fileHandleForReading.readabilityHandler = { handle in
            reader.feed(handle.availableData)
        }
        do {
            try process.run()
        } catch {
            out.fileHandleForReading.readabilityHandler = nil
            fail("the helper did not launch: \(error.localizedDescription)")
            return
        }
        self.process = process
        self.stdin = input.fileHandleForWriting
        self.stdout = out.fileHandleForReading
        sawFirstLine = false
        sawTrack = false
        startedAt = Date()
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated {
                guard let self, self.running, self.readerToken == token, !self.sawFirstLine else { return }
                self.fail("the helper stayed silent for 4 s")
            }
        }
        watchdog = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 4, execute: work)
    }

    /// A transport command — "send N" down the helper's stdin. The
    /// helper is entitled, so this works on the releases where the
    /// in-process `MRMediaRemoteSendCommand` also still works; the
    /// monitor sends through whichever path is alive.
    func send(_ command: MediaRemoteBridge.Command) -> MediaTransportSubmission {
        submit(Data("send \(command.rawValue)\n".utf8))
    }

    /// A scrub: "seek <seconds>" — the helper calls
    /// `MRMediaRemoteSetElapsedTime` and refreshes, so the next line
    /// already carries the landed playhead.
    func seek(to seconds: Double) -> MediaTransportSubmission {
        submit(Data(String(format: "seek %.3f\n", seconds).utf8))
    }

    private func submit(_ data: Data) -> MediaTransportSubmission {
        guard running, let stdin else { return .unavailable }
        return Self.submit(data, write: { try stdin.write(contentsOf: $0) })
    }

    /// An error cannot prove that a pipe write delivered no bytes.
    static func submit(_ data: Data, write: (Data) throws -> Void) -> MediaTransportSubmission {
        do {
            try write(data)
            return .submitted
        } catch {
            return .uncertain
        }
    }

    func stop() {
        running = false
        watchdog?.cancel()
        watchdog = nil
        stdout?.readabilityHandler = nil
        stdout = nil
        reader = nil
        readerToken = nil
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
    /// moves to the in-process path until the retry budget is spent.
    private func terminated(from token: UUID) {
        guard running, readerToken == token else { return }
        fail(sawFirstLine ? "the helper exited mid-run" : "the helper exited before answering")
    }

    private func fail(_ reason: String) {
        guard running else { return }
        Self.log.error("Now Playing: \(reason, privacy: .public) — in-process MediaRemote from here")
        running = false
        watchdog?.cancel()
        watchdog = nil
        stdout?.readabilityHandler = nil
        stdout = nil
        reader = nil
        readerToken = nil
        process?.terminationHandler = nil
        process?.terminate()
        process = nil
        stdin = nil
        onFailure?()
    }

    /// Lines the reader parsed, in order, on the main thread: the
    /// evidence trail, the watchdog, the change.
    private func deliver(_ lines: [AlcoveMedia?], from token: UUID) {
        guard token == readerToken else { return }
        for media in lines {
            guard running, token == readerToken else { return }
            let elapsed = startedAt.map { Date().timeIntervalSince($0) } ?? 0
            if !sawFirstLine {
                Self.log.info("Now Playing: \(Self.firstLineNote(after: elapsed, track: media != nil), privacy: .public)")
            }
            if media != nil, !sawTrack {
                sawTrack = true
                if sawFirstLine {
                    Self.log.info("Now Playing: first track \(Int(elapsed.rounded())) s after launch")
                }
            }
            sawFirstLine = true
            watchdog?.cancel()
            watchdog = nil
            onChange?(media)
        }
    }

    /// One JSON line → media. `null` (or a payload without a title) is
    /// the helper's "nothing playing"; an unparseable line is shrugged
    /// into nil the same way — the island simply shows no media.
    nonisolated static func parse(_ line: Data) -> AlcoveMedia? {
        var cover: AlcoveMediaLineReader.Cover?
        return parse(line, cover: &cover)
    }

    /// The same, reusing the last line's cover: a line whose artwork
    /// string is the one before's takes that line's bytes — no second
    /// base64 decode, and the same `Data`, which later compares cost
    /// nothing. `cover` is updated to this line's.
    nonisolated static func parse(_ line: Data, cover: inout AlcoveMediaLineReader.Cover?) -> AlcoveMedia? {
        let trimmed = line.drop(while: { $0 == UInt8(ascii: " ") || $0 == UInt8(ascii: "\t") })
        guard !trimmed.isEmpty, trimmed != Data("null".utf8) else { return nil }
        guard let object = try? JSONSerialization.jsonObject(with: trimmed),
              var payload = object as? [String: Any] else { return nil }
        var artwork: Data?
        if let encoded = payload["artworkData"] as? NSString {
            payload["artworkData"] = nil
            if let last = cover, last.encoded.isEqual(to: encoded as String) {
                artwork = last.data
            } else {
                artwork = Data(base64Encoded: encoded as String)
                cover = artwork.map { AlcoveMediaLineReader.Cover(encoded: encoded, data: $0) }
            }
        }
        var media = AlcoveMedia.summarize(adapter: payload)
        media?.artworkData = artwork
        return media
    }
}

/// The helper's stdout, split into lines and parsed on a queue of its
/// own. `feed` takes each chunk as the pipe hands it over, from any
/// thread; `deliver` gets every whole line's media, in order.
final class AlcoveMediaLineReader: @unchecked Sendable {
    /// The last line's cover: its base64 text and its bytes.
    struct Cover {
        let encoded: NSString
        let data: Data
    }

    private let queue = DispatchQueue(label: "jrbar.alcove-media-reader", qos: .userInitiated)
    private let deliver: @Sendable ([AlcoveMedia?]) -> Void
    /// Only ever touched on `queue`.
    private var pending = Data()
    private var cover: Cover?
    private var discardingLine = false
    private let maxLineBytes: Int

    init(maxLineBytes: Int = 8 * 1024 * 1024,
         deliver: @escaping @Sendable ([AlcoveMedia?]) -> Void) {
        self.maxLineBytes = maxLineBytes
        self.deliver = deliver
    }

    func feed(_ chunk: Data) {
        queue.async { self.consume(chunk) }
    }

    /// Waits for every chunk fed so far — the tests' way to read the
    /// result in the same turn.
    func drain() {
        queue.sync {}
    }

    /// Oversized lines are discarded through their newline. A broken
    /// helper cannot retain an unbounded stream while the next line recovers.
    private func consume(_ chunk: Data) {
        var lines: [AlcoveMedia?] = []
        var start = chunk.startIndex
        while start < chunk.endIndex {
            let newline = chunk[start...].firstIndex(of: UInt8(ascii: "\n"))
            let end = newline ?? chunk.endIndex
            let segment = chunk[start..<end]
            if !discardingLine {
                if segment.count <= maxLineBytes - pending.count {
                    pending.append(segment)
                } else {
                    pending.removeAll(keepingCapacity: false)
                    discardingLine = true
                }
            }
            guard let newline else { break }
            if !discardingLine {
                lines.append(AlcoveMediaAdapter.parse(pending, cover: &cover))
            }
            pending.removeAll(keepingCapacity: false)
            discardingLine = false
            start = chunk.index(after: newline)
        }
        if !lines.isEmpty { deliver(lines) }
    }
}
