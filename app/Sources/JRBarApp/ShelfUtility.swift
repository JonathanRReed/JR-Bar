import AppKit
import JRBarCore

/// W11's shelf utility facts: now-playing media plus the internal
/// battery, alive only while the pinned card is up. Both sources are
/// the same monitors the Alcove island runs — nothing here invents a
/// capability macOS does not expose.
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
        feedToken = feed.subscribe { [weak self] media in self?.media = media }
        powerMonitor.start()
    }

    func stop() {
        guard running else { return }
        running = false
        if let feedToken { feed.unsubscribe(feedToken) }
        feedToken = nil
        powerMonitor.stop()
        media = nil
    }

    /// Transport commands ride the feed's live path (entitled adapter
    /// first, in-process bridge otherwise). No-op without a live source
    /// — sending into silence is a lie.
    func send(_ command: MediaRemoteBridge.Command) {
        guard media != nil else { return }
        feed.send(command)
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
