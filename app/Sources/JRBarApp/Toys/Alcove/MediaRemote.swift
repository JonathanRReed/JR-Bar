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

    private let getNowPlayingInfo: InfoFunc?
    private let getIsPlaying: BoolFunc?
    private let sendCommand: SendFunc?
    private let registerForNowPlayingNotifications: RegisterFunc?

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
}

/// The island's Now Playing source: owns the MediaRemote bridge, listens
/// for the now-playing notifications MediaRemote posts (plus Music's own
/// `playerInfo` distributed note, whose payload we ignore — the refetch
/// reads MediaRemote either way), and reduces each refresh to one
/// `AlcoveMedia` for the toy. Started while the island is ours and
/// visible with `mediaEnabled` on; stopped otherwise — a parked island
/// holds no listener and asks for nothing.
@MainActor
final class AlcoveMediaMonitor {
    /// MediaRemote's distributed notification names — the constants'
    /// string values are their own names, so no symbol lookup is needed.
    static let notificationNames = [
        "kMRMediaRemoteNowPlayingInfoDidChangeNotification",
        "kMRMediaRemoteNowPlayingApplicationIsPlayingDidChangeNotification",
        "kMRMediaRemoteNowPlayingApplicationDidChangeNotification",
        "com.apple.Music.playerInfo",
    ]

    /// The queue MediaRemote answers on; the hop to main is ours.
    private let answerQueue = DispatchQueue(label: "jrbar.alcove.mediaremote", qos: .utility)
    private var bridge: MediaRemoteBridge?
    private var observers: [NSObjectProtocol] = []
    private var refreshWork: DispatchWorkItem?
    private(set) var running = false

    /// The toy's hook: the freshly reduced media (or nil when nothing
    /// plays / MediaRemote is absent).
    var onChange: (@MainActor (AlcoveMedia?) -> Void)?

    func start() {
        guard !running else { return }
        running = true
        guard let bridge = MediaRemoteBridge() else {
            // No framework: the feature silently isn't there.
            self.bridge = nil
            onChange?(nil)
            return
        }
        self.bridge = bridge
        bridge.registerNotifications(on: .main)
        let center = DistributedNotificationCenter.default()
        for name in Self.notificationNames {
            observers.append(center.addObserver(forName: Notification.Name(name), object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.scheduleRefresh() }
            })
        }
        refresh()
    }

    func stop() {
        running = false
        refreshWork?.cancel()
        refreshWork = nil
        for observer in observers { DistributedNotificationCenter.default().removeObserver(observer) }
        observers = []
        bridge = nil
        onChange?(nil)
    }

    /// A transport command plus a follow-up refresh: the notification
    /// usually arrives on its own, but the re-read keeps the capsule
    /// honest on a player that never posts one.
    func send(_ command: MediaRemoteBridge.Command) {
        bridge?.send(command)
        scheduleRefresh(after: 0.5)
    }

    /// Notifications arrive in bursts (info + is-playing + app-change
    /// for one track change); one refresh 0.2 s out answers them all.
    private func scheduleRefresh(after delay: TimeInterval = 0.2) {
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
    private func refresh() {
        guard let bridge else { onChange?(nil); return }
        let queue = answerQueue
        bridge.isPlaying(on: queue) { [weak self] playing in
            bridge.nowPlayingInfo(on: queue) { [weak self] info in
                let media = AlcoveMedia.summarize(info, isPlaying: playing)
                Task { @MainActor [weak self] in
                    self?.onChange?(media)
                }
            }
        }
    }
}
