import AppKit
import JRBarCore

/// W11's shelf utility facts: now-playing media plus the internal
/// battery, alive only while the pinned card is up. Both sources are
/// the same feeds the island runs — one Now Playing helper, one power
/// poll (`AlcovePowerFeed`) — so nothing here polls on its own or
/// invents a capability macOS does not expose.
///
/// Capability honesty (T48/AL04/AL05):
/// * Transport buttons exist only while a media source is live; a dead
///   read path or silent source resolves to `media == nil` and the row
///   says so instead of drawing fake controls.
/// * The battery row appears only when IOKit reports an internal
///   battery — a Mac without one shows no row, never a fake percent.
/// * Volume and brightness are deliberately absent: macOS owns those
///   HUDs and JR-Bar has no certified read/control path for them.
@MainActor
@Observable
final class ShelfUtilityModel {
    /// Artwork payloads above this are dropped rather than decoded —
    /// a hostile or buggy source can't push an unbounded image into
    /// the card. 4 MiB comfortably covers real album art.
    static let maxArtworkBytes = 4 * 1024 * 1024

    private let feed: MediaFeed
    private var feedToken: UUID?
    private let powerMonitor = AlcovePowerMonitor()

    /// The current now-playing media, or nil when no certified source
    /// reports one (stopped, exited, or the read path is gated and no
    /// Music payload is fresh). Drives both the row and transport
    /// gating — nil media means no controls.
    private(set) var media: AlcoveMedia?
    /// The latest power-source read; `hasBattery == false` hides the
    /// battery row entirely.
    private(set) var power = AlcovePowerMonitor.read()
    /// The weather row's fetcher — the card toggle and city ride its
    /// `settings` closure, wired by the delegate.
    let weather = NotchWeather()
    /// Synced lyrics for the playing track — LRCLIB-backed, cached,
    /// nil when the track has none or the source named too little to
    /// query. The row reads `lyrics.line(at:)` on its timeline tick.
    let lyrics = LyricsStore(diskURL: LyricsDiskCache.defaultURL())
    /// The Control Center strip — One Switch's row: keep-awake, dark
    /// mode, desktop icons, hidden files, mute, saver, lock, Dock
    /// autohide. Reads truth on show; verbs fire and never latch.
    let toggles = SystemTogglesStore()
    /// The audio visualizer's six band levels — published by the toy's
    /// `AudioLevelTap` only while it runs. `audioTapLive` is the row's
    /// signal to draw these; false falls back to the decorative bars.
    var audioLevels: [Float] = [Float](repeating: 0, count: 6)
    var audioTapLive = false
    private(set) var running = false

    /// `feed` is the shared Now Playing source; tests pass their own so
    /// a unit test never spawns the helper.
    init(feed: MediaFeed? = nil) {
        self.feed = feed ?? MediaFeed.shared
        powerMonitor.onTransition = { [weak self] _, new in self?.power = new }
    }

    func start() {
        guard !running else { return }
        running = true
        feedToken = feed.subscribe { [weak self] media in
            self?.media = media
            self?.lyrics.note(media: media)
        }
        powerMonitor.start()
        // The shared feed kept polling for the island and the ear while
        // the card was folded: take its reading now, or the row would
        // wait for the next transition showing the charge it left with.
        power = powerMonitor.current
        weather.start()
        toggles.refresh()
    }

    func stop() {
        guard running else { return }
        running = false
        if let feedToken { feed.unsubscribe(feedToken) }
        feedToken = nil
        powerMonitor.stop()
        weather.stop()
        lyrics.reset()
        // Keep-awake deliberately survives the fold: the user's
        // toggle is an app-level intent, not a card-lifetime lease —
        // and the assertion dies with the process anyway.
        media = nil
    }

    /// Transport commands ride the feed's live path (entitled adapter
    /// first, in-process bridge otherwise). No-op without a live source
    /// — sending into silence is a lie.
    func send(_ command: MediaRemoteBridge.Command) {
        guard media != nil else { return }
        feed.send(command)
    }

    /// A scrub — same live path as `send`. The caller passes the
    /// committed seconds; the optimistic playhead update belongs to
    /// the view holding the drag.
    func seek(to seconds: Double) {
        guard media != nil else { return }
        feed.seek(to: seconds)
    }

    /// The media row's in-flight scrub: the drag's playhead and how
    /// long it holds after release — the feed's own timestamp lands
    /// ~0.4 s later, so a brief hold keeps the slider from snapping
    /// back mid-flight.
    var mediaScrub: Double?
    var mediaScrubHoldUntil = Date.distantPast

    /// What the slider draws: the drag position while held (and
    /// briefly after), the feed's interpolated playhead otherwise.
    func elapsedShown(at date: Date = Date()) -> Double {
        if let mediaScrub, date < mediaScrubHoldUntil { return mediaScrub }
        return media?.liveElapsed(at: date) ?? 0
    }

    /// The drag began — the playhead follows the pointer until release.
    func beginScrub() {
        mediaScrubHoldUntil = .distantFuture
    }

    /// The drag released: seek, then hold the position a beat so the
    /// next timeline tick doesn't flash the stale feed value.
    func commitScrub() {
        if let mediaScrub { seek(to: mediaScrub) }
        mediaScrubHoldUntil = Date().addingTimeInterval(0.9)
    }

    /// Artwork for the card, or nil when the payload is absent,
    /// oversized, or not an image — the caller draws the placeholder.
    var artwork: NSImage? {
        guard let data = media?.artworkData,
              data.count <= Self.maxArtworkBytes else { return nil }
        return NSImage(data: data)
    }

    /// The source app's display name for the card's identity line,
    /// resolved from the reported bundle id; nil stays unlabeled —
    /// an unnamed source is not "Music".
    var sourceName: String? {
        guard let bundle = media?.bundleIdentifier,
              let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundle) else {
            return nil
        }
        return FileManager.default.displayName(atPath: url.path)
            .replacingOccurrences(of: ".app", with: "")
    }
}
