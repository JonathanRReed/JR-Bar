import AppKit
import JRBarCore

/// The private MediaRemote.framework — what every notch app (Alcove,
/// boring.notch) reads Now Playing through — loaded with dlopen and
/// every symbol resolved through dlsym. There is no framework link and
/// nothing is assumed: on a system where MediaRemote is absent or a
/// symbol went away the bridge just isn't built, and the island simply
/// never shows media. No errors, no crashes.
final class MediaRemoteBridge: @unchecked Sendable {
    /// `MRMediaRemoteCommand` values the island sends. The enum is
    /// NSUInteger-width; the values are stable across releases.
    enum Command: Int {
        case togglePlayPause = 2
        case nextTrack = 4
        case previousTrack = 5
    }

    private typealias InfoFunc = @convention(c) (DispatchQueue, @escaping ([String: Any]) -> Void) -> Void
    private typealias BoolFunc = @convention(c) (DispatchQueue, @escaping (Bool) -> Void) -> Void
    private typealias SendFunc = @convention(c) (Int, AnyObject?) -> Bool
    private typealias RegisterFunc = @convention(c) (DispatchQueue) -> Void
    private typealias SeekFunc = @convention(c) (Double) -> Bool

    private let getNowPlayingInfo: InfoFunc?
    private let getIsPlaying: BoolFunc?
    private let sendCommand: SendFunc?
    private let registerForNowPlayingNotifications: RegisterFunc?
    private let setElapsedTime: SeekFunc?

    /// nil when the framework or its entry points can't be resolved —
    /// a perfectly ordinary outcome, handled by never building one.
    init?() {
        guard let handle = dlopen("/System/Library/PrivateFrameworks/MediaRemote.framework/MediaRemote", RTLD_LAZY)
            ?? dlopen("/System/Library/PrivateFrameworks/MediaRemote.framework", RTLD_LAZY) else {
            return nil
        }
        func symbol<T>(_ name: String, as type: T.Type) -> T? {
            guard let pointer = dlsym(handle, name) else { return nil }
            return unsafeBitCast(pointer, to: T.self)
        }
        getNowPlayingInfo = symbol("MRMediaRemoteGetNowPlayingInfo", as: InfoFunc.self)
        getIsPlaying = symbol("MRMediaRemoteGetNowPlayingApplicationIsPlaying", as: BoolFunc.self)
        sendCommand = symbol("MRMediaRemoteSendCommand", as: SendFunc.self)
        registerForNowPlayingNotifications = symbol("MRMediaRemoteRegisterForNowPlayingNotifications",
                                                    as: RegisterFunc.self)
        setElapsedTime = symbol("MRMediaRemoteSetElapsedTime", as: SeekFunc.self)
        // Info alone is the feature; everything else is decoration on
        // top. On the way out, hand the framework back.
        guard getNowPlayingInfo != nil else { dlclose(handle); return nil }
    }

    /// Ask MediaRemote to deliver now-playing notifications to this
    /// process; a missing symbol just means we poll on our own schedule.
    func registerNotifications(on queue: DispatchQueue) {
        registerForNowPlayingNotifications?(queue)
    }

    /// The now-playing info dictionary, delivered on `queue`. A nil
    /// dictionary arrives as an empty one — callers read "no title".
    func nowPlayingInfo(on queue: DispatchQueue,
                        then handler: @escaping @Sendable ([String: Any]) -> Void) {
        guard let getNowPlayingInfo else { queue.async { handler([:]) }; return }
        getNowPlayingInfo(queue) { handler($0) }
    }

    /// Whether the now-playing app reports itself playing; nil-capable —
    /// a missing symbol leaves the playback-rate fallback inside
    /// `AlcoveMedia.summarize` to answer instead.
    func isPlaying(on queue: DispatchQueue, then handler: @escaping @Sendable (Bool?) -> Void) {
        guard let getIsPlaying else { queue.async { handler(nil) }; return }
        getIsPlaying(queue) { handler($0) }
    }

    /// A transport command. The return is MediaRemote's own "was it
    /// handled" — false when no app is listening, which is a shrug.
    @discardableResult
    func send(_ command: Command) -> Bool {
        sendCommand?(command.rawValue, nil) ?? false
    }

    /// A scrub: the playhead to `seconds` — `MRMediaRemoteSetElapsedTime`
    /// is a command the same entitlement-free surface `send` rides, so
    /// it answers where reads are gated.
    @discardableResult
    func seek(to seconds: Double) -> Bool {
        setElapsedTime?(seconds) ?? false
    }
}

/// The island's Now Playing source, two readers under one switch:
///
/// * `AlcoveMediaAdapter` — `/usr/bin/perl` (an entitled platform
///   binary) running the embedded `jrbar_mediaremote` dylib, which
///   calls MediaRemote inside that process and streams JSON lines.
///   The only path that works on macOS 15.4+, where `mediaremoted`
///   refuses unentitled readers — which is this machine.
/// * `MediaRemoteBridge` — the in-process dlopen path, kept as the
///   fallback for releases where reads were never gated (and for the
///   `send` transport, which mediaremoted never gated). Plus Music's
///   own `com.apple.Music.playerInfo` payload, which Music posts to
///   every process regardless — parsed directly when the bridge reads
///   come back empty.
///
/// Started while the island is ours and visible with `mediaEnabled`
/// on; stopped otherwise — a parked island holds no listener, no child
/// process, and asks for nothing.
@MainActor
class AlcoveMediaMonitor {
    /// MediaRemote's distributed notification names — the constants'
    /// string values are their own names, so no symbol lookup is needed.
    /// They only fire for registered readers; on gated releases they
    /// simply never arrive, which the fallback ordering already covers.
    static let notificationNames = [
        "kMRMediaRemoteNowPlayingInfoDidChangeNotification",
        "kMRMediaRemoteNowPlayingApplicationIsPlayingDidChangeNotification",
        "kMRMediaRemoteNowPlayingApplicationDidChangeNotification",
        "com.apple.Music.playerInfo",
    ]

    /// The queue MediaRemote answers on; the hop to main is ours.
    private let answerQueue = DispatchQueue(label: "jrbar.alcove.mediaremote", qos: .utility)
    private var bridge: MediaRemoteBridge?
    private var adapter: AlcoveMediaAdapter?
    private var observers: [NSObjectProtocol] = []
    private var refreshWork: DispatchWorkItem?
    /// The last media Music's `playerInfo` named — held so a bridge
    /// refresh that comes back empty (gated) can still report what the
    /// distributed note itself announced. Stale past `musicPayloadLife`.
    private var musicMedia: (media: AlcoveMedia, at: Date)?
    /// A `playerInfo` payload speaks for this long; a Music that quit
    /// mid-song stops claiming the strip once it ages out.
    private static let musicPayloadLife: TimeInterval = 10
    /// The bridge path only runs reads while the adapter is dead —
    /// otherwise a gated empty read would overwrite the helper's truth.
    private var adapterLive = false
    private(set) var running = false

    /// The toy's hook: the freshly reduced media (or nil when nothing
    /// plays / no path produced one).
    var onChange: (@MainActor (AlcoveMedia?) -> Void)?

    /// A test double's write to `running` — the real paths flip it in
    /// `start`/`stop`.
    func markRunning(_ value: Bool) { running = value }

    func start() {
        guard !running else { return }
        running = true
        // The bridge is built either way: `send` rides it in-process
        // whenever the framework resolves, reads only ever run while
        // the adapter is dead.
        bridge = MediaRemoteBridge()
        bridge?.registerNotifications(on: .main)
        let center = DistributedNotificationCenter.default()
        for name in Self.notificationNames {
            observers.append(center.addObserver(forName: Notification.Name(name), object: nil, queue: .main) { [weak self] note in
                // Music's payload is data in its own right — parse it in
                // the block so only Sendable values cross to main.
                var musicMedia: AlcoveMedia?
                var musicStopped = false
                if name == "com.apple.Music.playerInfo" {
                    let payload = note.userInfo as? [String: Any] ?? [:]
                    musicMedia = AlcoveMedia.summarize(musicPlayerInfo: payload)
                    musicStopped = (payload["Player State"] as? String) == "Stopped"
                }
                MainActor.assumeIsolated {
                    self?.noteDistributed(name: name, musicMedia: musicMedia, musicStopped: musicStopped)
                }
            })
        }
        startAdapter()
        refresh()
    }

    /// Spawn the entitled reader; a dead path (no perl, no dylib, an
    /// early exit) flips `adapterLive` off and leaves the bridge's
    /// refresh cycle in charge.
    private func startAdapter() {
        let adapter = AlcoveMediaAdapter()
        adapter.onChange = { [weak self] media in self?.noteMedia(media) }
        adapter.onFailure = { [weak self] in
            guard let self else { return }
            self.adapterLive = false
            self.adapter = nil
            self.refresh()
        }
        self.adapter = adapter
        adapterLive = true
        adapter.start()
        // The adapter reports its own death through onFailure — but a
        // `start` that silently couldn't run still needs the flag down.
        if !adapter.running { adapterLive = false }
    }

    private func noteMedia(_ media: AlcoveMedia?) {
        guard running else { return }
        onChange?(media)
    }

    /// A distributed note landed: Music's payload is data in its own
    /// right (and the only ungated source on 15.4+); the MediaRemote
    /// names are refresh triggers for the bridge path.
    private func noteDistributed(name: String, musicMedia media: AlcoveMedia?,
                                 musicStopped: Bool = false) {
        if name == "com.apple.Music.playerInfo" {
            if let media {
                musicMedia = (media, Date())
                if !adapterLive { noteMedia(media) }
            } else if musicStopped {
                // "Stopped" is a fact, not a gap — drop the held track.
                musicMedia = nil
                if !adapterLive { noteMedia(nil) }
            }
            return
        }
        scheduleRefresh()
    }

    func stop() {
        running = false
        refreshWork?.cancel()
        refreshWork = nil
        adapter?.stop()
        adapter = nil
        adapterLive = false
        for observer in observers { DistributedNotificationCenter.default().removeObserver(observer) }
        observers = []
        bridge = nil
        musicMedia = nil
        onChange?(nil)
    }

    /// A transport command plus a follow-up refresh: the notification
    /// usually arrives on its own, but the re-read keeps the capsule
    /// honest on a player that never posts one.
    func send(_ command: MediaRemoteBridge.Command) {
        if adapterLive, let adapter {
            adapter.send(command)
        }
        bridge?.send(command)
        scheduleRefresh(after: 0.5)
    }

    /// A scrub — both live paths take it; the one that lands is the
    /// one mediaremoted is answering. The follow-up refresh reports
    /// the playhead where it settled.
    func seek(to seconds: Double) {
        if adapterLive, let adapter {
            adapter.seek(to: seconds)
        }
        bridge?.seek(to: seconds)
        scheduleRefresh(after: 0.4)
    }

    /// Notifications arrive in bursts (info + is-playing + app-change
    /// for one track change); one refresh 0.2 s out answers them all.
    private func scheduleRefresh(after delay: TimeInterval = 0.2) {
        guard !adapterLive else { return }
        refreshWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated { self?.refresh() }
        }
        refreshWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }

    /// One read: the is-playing flag, then the info dictionary, reduced
    /// by `AlcoveMedia.summarize` and handed to the toy on the main
    /// actor. The flag is fetched first so the dictionary — not Sendable
    /// — only ever arrives as a closure parameter, never a capture.
    /// Skipped while the adapter is alive: on gated releases the read
    /// answers empty, and empty would erase the helper's real track.
    private func refresh() {
        guard running, !adapterLive else { return }
        guard let bridge else {
            noteMedia(musicMedia.flatMap { Date().timeIntervalSince($0.at) < Self.musicPayloadLife ? $0.media : nil })
            return
        }
        let queue = answerQueue
        bridge.isPlaying(on: queue) { [weak self] playing in
            bridge.nowPlayingInfo(on: queue) { [weak self] info in
                let media = AlcoveMedia.summarize(info, isPlaying: playing)
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    // The bridge's empty read on a gated release is not
                    // "nothing playing" — Music's own note is fresher
                    // truth when it arrived recently.
                    if let media {
                        self.noteMedia(media)
                    } else if let held = self.musicMedia,
                              Date().timeIntervalSince(held.at) < Self.musicPayloadLife {
                        self.noteMedia(held.media)
                    } else {
                        self.noteMedia(nil)
                    }
                }
            }
        }
    }
}

/// The one Now Playing source every surface reads. `AlcoveMediaMonitor`
/// spawns a perl helper and registers distributed observers; two of
/// them running (the island's and the pinned card's) meant two helpers,
/// two dylib maps, and two surfaces that could disagree about the
/// track. The feed owns exactly one monitor, starts it when the first
/// reader subscribes and stops it when the last leaves, and hands
/// every reader the same `media`.
@MainActor
final class MediaFeed {
    static let shared = MediaFeed()

    private let monitor: AlcoveMediaMonitor
    private var readers: [UUID: @MainActor (AlcoveMedia?) -> Void] = [:]
    /// The latest reduce — a new reader gets it on subscribe.
    private(set) var media: AlcoveMedia?

    init(monitor: AlcoveMediaMonitor? = nil) {
        self.monitor = monitor ?? AlcoveMediaMonitor()
        self.monitor.onChange = { [weak self] media in
            guard let self else { return }
            self.media = media
            for reader in self.readers.values { reader(media) }
        }
    }

    var isRunning: Bool { monitor.running }
    var readerCount: Int { readers.count }

    /// Subscribe; the monitor starts with the first reader. The current
    /// media is delivered immediately so a late reader is never blank
    /// until the next change.
    @discardableResult
    func subscribe(_ reader: @escaping @MainActor (AlcoveMedia?) -> Void) -> UUID {
        let token = UUID()
        readers[token] = reader
        if readers.count == 1 { monitor.start() }
        reader(media)
        return token
    }

    /// Unsubscribe; the monitor stops with the last reader and the held
    /// media clears — nothing plays for nobody.
    func unsubscribe(_ token: UUID) {
        guard readers.removeValue(forKey: token) != nil else { return }
        if readers.isEmpty {
            monitor.stop()
            media = nil
        }
    }

    /// A transport command on the live path — a no-op with no source.
    func send(_ command: MediaRemoteBridge.Command) {
        guard media != nil else { return }
        monitor.send(command)
    }

    /// A scrub — same live-path rule as `send`.
    func seek(to seconds: Double) {
        guard media != nil else { return }
        monitor.seek(to: seconds)
    }
}
