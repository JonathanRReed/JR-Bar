import AppKit
import JRBarCore
import Observation

/// The visible Music card owns its subscription, observers and progress clock.
@MainActor @Observable
final class DockMusicPreview {
    enum State: String, CaseIterable { case notRunning, stopped, paused, playing }
    private(set) var state: State = .stopped
    private(set) var media: AlcoveMedia?
    private(set) var permission: SetupPermissionStatus = .needed
    private(set) var stale = false
    private(set) var shuffle = false
    private(set) var repeatMode: DockMusicSource.Repeat = .off
    private(set) var soundVolume: Double?
    private(set) var favorite: Bool?
    private(set) var now = Date()
    private(set) var visible = false
    private(set) var busy = false
    private(set) var fullControls = false
    private(set) var requestingPermission = false
    @ObservationIgnored var onChange: () -> Void = {}
    @ObservationIgnored private let source: DockMusicSource
    @ObservationIgnored private let feed: MediaFeed
    @ObservationIgnored private let clock: () -> Date
    @ObservationIgnored private let schedule: @MainActor (@escaping @MainActor () -> Void) -> (() -> Void)
    @ObservationIgnored private let observe: @MainActor (@escaping @MainActor () -> Void) -> (() -> Void)
    @ObservationIgnored private var cancelTimer: (() -> Void)?
    @ObservationIgnored private var cancelObserver: (() -> Void)?
    @ObservationIgnored private var token: UUID?
    @ObservationIgnored private var task: Task<Void, Never>?
    @ObservationIgnored private var generation = 0
    @ObservationIgnored private var refreshAgain = false

    init(source: DockMusicSource, feed: MediaFeed, clock: @escaping () -> Date = Date.init,
         schedule: @escaping @MainActor (@escaping @MainActor () -> Void) -> (() -> Void) = DockMusicPreview.timer,
         observe: @escaping @MainActor (@escaping @MainActor () -> Void) -> (() -> Void) = DockMusicPreview.notifications) {
        self.source = source
        self.feed = feed
        self.clock = clock
        self.schedule = schedule
        self.observe = observe
    }

    var awaitingSnapshot: Bool { visible && !fullControls && !feed.hasSnapshot }
    var canControl: Bool { visible && state != .notRunning && media != nil && !stale }
    var canUseFullControls: Bool { canControl && fullControls && permission == .granted && !busy }
    var elapsed: Double { media?.liveElapsed(at: stale ? Date(timeIntervalSinceReferenceDate: media?.timestamp ?? 0) : now) ?? 0 }

    static func seek(fraction: Double, duration: Double) -> Double {
        guard fraction.isFinite, duration.isFinite, duration > 0 else { return 0 }
        return min(1, max(0, fraction)) * duration
    }
    nonisolated static func volume(_ value: Double) -> Double {
        value.isFinite ? min(100, max(0, value)).rounded() : 0
    }

    func start(fullControls: Bool) {
        guard !visible else { configure(fullControls: fullControls); return }
        visible = true
        self.fullControls = fullControls
        now = clock()
        if source.isRunning() { subscribe() }
        cancelObserver = observe { [weak self] in self?.refresh() }
        cancelTimer = schedule { [weak self] in self?.tick() }
        refresh()
    }

    func configure(fullControls: Bool) {
        guard self.fullControls != fullControls else { return }
        self.fullControls = fullControls
        generation += 1
        task?.cancel()
        task = nil
        busy = false
        permission = .needed
        favorite = nil
        soundVolume = nil
        if !fullControls { receive(feed.media) }
        refresh()
    }

    func stop() {
        visible = false
        generation += 1
        task?.cancel()
        task = nil
        busy = false
        refreshAgain = false
        cancelTimer?()
        cancelTimer = nil
        cancelObserver?()
        cancelObserver = nil
        if let token { feed.unsubscribe(token) }
        token = nil
        media = nil
        soundVolume = nil
    }

    func tick() {
        guard visible else { return }
        now = clock()
    }

    private func subscribe() {
        guard token == nil else { return }
        token = feed.subscribe { [weak self] media in self?.receive(media) }
    }

    private func receive(_ value: AlcoveMedia?) {
        guard visible else { return }
        if !source.isRunning() {
            media = nil
            state = .notRunning
        } else if let value, value.bundleIdentifier == DockMusicSource.bundleID {
            media = value
            state = value.playing ? .playing : .paused
            stale = false
        } else if !fullControls {
            media = nil
            state = .stopped
        }
        now = clock()
        onChange()
    }

    func refresh() {
        guard visible else { return }
        guard source.isRunning() else {
            generation += 1
            task?.cancel()
            task = nil
            busy = false
            if let token { feed.unsubscribe(token) }
            token = nil
            media = nil
            state = .notRunning
            stale = false
            onChange()
            return
        }
        if state == .notRunning { state = .stopped }
        subscribe()
        guard fullControls else { onChange(); return }
        guard task == nil else { refreshAgain = true; return }
        let stamp = generation
        busy = true
        task = Task { [weak self] in
            guard let self, self.visible, self.generation == stamp, !Task.isCancelled else { return }
            let status = await self.source.permission(false)
            guard self.visible, self.generation == stamp else { return }
            self.permission = status
            if status == .granted {
                do {
                    let reading = try await self.source.read()
                    guard self.visible, self.generation == stamp else { return }
                    self.apply(reading)
                } catch {
                    guard self.visible, self.generation == stamp else { return }
                    self.stale = true
                }
            }
            self.finish()
        }
    }

    private func apply(_ reading: DockMusicSource.Reading) {
        media = reading.media
        state = reading.media.map { $0.playing ? .playing : .paused } ?? .stopped
        shuffle = reading.shuffle
        repeatMode = reading.repeatMode
        soundVolume = Self.volume(reading.volume)
        favorite = reading.favorite
        stale = false
        now = clock()
    }

    private func finish() {
        busy = false
        task = nil
        onChange()
        if refreshAgain { refreshAgain = false; refresh() }
    }

    /// The button is the only caller. Hover only uses permission(false).
    func allowFullControls(request: PermissionRequest) async {
        guard visible, state != .notRunning, !requestingPermission else { return }
        requestingPermission = true
        defer { requestingPermission = false }
        let stamp = generation
        let status = await request.perform()
        guard visible, generation == stamp else { return }
        permission = status
        refresh()
    }

    func permissionRequest() -> PermissionRequest {
        PermissionRequest.live(permission: .automation, status: { [source] in
            await source.permission(false)
        }, prompt: { [source] in
            _ = await source.permission(true)
        }, settingsURL: AutomationPermission.settingsURL)
    }

    func send(_ command: DockMusicSource.Command) {
        guard canControl, !busy else { return }
        guard source.isRunning() else { refresh(); return }
        if fullControls, permission == .granted {
            let stamp = generation
            busy = true
            task = Task { [weak self] in
                guard let self, self.visible, self.generation == stamp, !Task.isCancelled else { return }
                do {
                    guard await self.source.permission(false) == .granted else { throw CancellationError() }
                    guard self.visible, self.generation == stamp else { return }
                    try await self.source.send(command)
                } catch {
                    guard self.visible, self.generation == stamp else { return }
                    self.stale = true
                }
                guard self.visible, self.generation == stamp else { return }
                self.refreshAgain = true
                self.finish()
            }
        } else {
            // MediaRemote commands address the system player, so never send to
            // a different app that took Now Playing while Music was paused.
            guard feed.media?.bundleIdentifier == DockMusicSource.bundleID else { return }
            switch command {
            case .transport(let transport): feed.send(transport)
            case .seek(let seconds): feed.seek(to: seconds)
            default: break
            }
        }
    }

    func settle() async { await task?.value }

    static func timer(_ tick: @escaping @MainActor () -> Void) -> (() -> Void) {
        let timer = Timer(timeInterval: 1, repeats: true) { _ in
            MainActor.assumeIsolated { tick() }
        }
        RunLoop.main.add(timer, forMode: .common)
        return { timer.invalidate() }
    }

    static func notifications(_ refresh: @escaping @MainActor () -> Void) -> (() -> Void) {
        let distributed = DistributedNotificationCenter.default()
        let music = distributed.addObserver(forName: .init("com.apple.Music.playerInfo"), object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { refresh() }
        }
        let workspace = NSWorkspace.shared.notificationCenter
        let tokens = [NSWorkspace.didLaunchApplicationNotification, NSWorkspace.didTerminateApplicationNotification].map { name in
            workspace.addObserver(forName: name, object: nil, queue: .main) { note in
                let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
                guard app?.bundleIdentifier == DockMusicSource.bundleID else { return }
                MainActor.assumeIsolated { refresh() }
            }
        }
        let active = NotificationCenter.default.addObserver(forName: NSApplication.didBecomeActiveNotification,
            object: nil, queue: .main) { _ in MainActor.assumeIsolated { refresh() } }
        return {
            distributed.removeObserver(music)
            tokens.forEach { workspace.removeObserver($0) }
            NotificationCenter.default.removeObserver(active)
        }
    }
}
