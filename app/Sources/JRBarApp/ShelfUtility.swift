import AppKit
import CoreAudio
import CoreImage
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
/// * The media row's volume slider exists only while the default
///   output has a readable hardware volume (`SystemLevelReader`, the
///   same path the level HUD reads) — an output without one draws no
///   slider rather than a dead one. Brightness stays with its keys.
@MainActor
@Observable
final class ShelfUtilityModel {
    /// Artwork payloads above this are dropped rather than decoded —
    /// a hostile or buggy source can't push an unbounded image into
    /// the card. 4 MiB comfortably covers real album art.
    nonisolated static let maxArtworkBytes = 4 * 1024 * 1024

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
        powerMonitor.onTransition = { [weak self] _, new in
            self?.power = new
            // A charger plugged in or pulled: its watts follow.
            self?.adapterWatts = new.onAC ? self?.readAdapterWatts() : nil
        }
    }

    func start() {
        guard !running else { return }
        running = true
        feedToken = feed.subscribe { [weak self] media in
            // Every helper line re-sends the whole track — a play, a
            // pause, a seek — and a row redraws for each assignment.
            guard self?.media != media else { return }
            self?.media = media
            self?.lyrics.note(media: media)
            self?.noteArtwork(media?.artworkData)
        }
        powerMonitor.start()
        // The shared feed kept polling for the island and the ear while
        // the card was folded: take its reading now, or the row would
        // wait for the next transition showing the charge it left with.
        power = powerMonitor.current
        outputVolume = SystemLevelReader.outputVolume().map(Double.init)
        adapterWatts = power.onAC ? readAdapterWatts() : nil
        weather.start()
        // The device list is a HAL walk and the switches spawn their
        // reads: the turn after the card starts to grow does. The list
        // shows only in the picker's menu while the output has a volume,
        // and the switches sit on the shelf page, so the grown card's
        // height does not wait on either. An output with no volume draws
        // its row from the list, so that list is read now.
        guard !inlineReads, outputVolume != nil else {
            refreshOutputs()
            startWatchingOutputs()
            toggles.refresh()
            return
        }
        DispatchQueue.main.async { [weak self] in
            MainActor.assumeIsolated {
                guard let self, self.running else { return }
                self.refreshOutputs()
                self.startWatchingOutputs()
                self.toggles.refresh()
            }
        }
    }

    /// The card's lyrics offer, clicked: the yes is kept and the playing
    /// track is looked up on the spot.
    func agreeToLyrics() {
        lyrics.consent()
        lyrics.note(media: media)
    }

    /// The default output's volume as the card opened, 0…1 — nil hides
    /// the slider (no hardware volume on this output).
    private(set) var outputVolume: Double?

    /// The slider's write: through the same CoreAudio path the level
    /// keys use, then read back so the slider shows what took.
    func setVolume(_ value: Double) {
        guard SystemLevelReader.setOutputVolume(Float(value)) else { return }
        outputVolume = SystemLevelReader.outputVolume().map(Double.init) ?? value
    }

    // MARK: Output route

    /// The output devices and the default among them — the route
    /// picker's list, read as the card opens, after a pick, and whenever
    /// the HAL says a device came or went or the default moved while the
    /// card is up. A test hands in its own reader, writer and watch so no
    /// suite moves the Mac's sound.
    private(set) var outputs: [CoreAudioOutputs.Device] = []
    private(set) var defaultOutput: AudioDeviceID?
    @ObservationIgnored var readOutputs: () -> (devices: [CoreAudioOutputs.Device], current: AudioDeviceID?) = {
        (CoreAudioOutputs.all(), CoreAudioDefaults.defaultOutput)
    }
    @ObservationIgnored var writeOutput: (AudioDeviceID) -> Bool = { CoreAudioOutputs.setDefault($0) }
    /// Starts listening for device changes and hands back how to stop.
    @ObservationIgnored var watchOutputs: @MainActor (@escaping @MainActor () -> Void) -> (@MainActor () -> Void) = { changed in
        let watch = CoreAudioOutputsWatch(changed)
        return { watch.stop() }
    }
    @ObservationIgnored private var outputWatchStop: (@MainActor () -> Void)?
    /// The route watch is listening — only while the card is up.
    var watchingOutputs: Bool { outputWatchStop != nil }

    /// The card opened: listen for devices and the default moving.
    func startWatchingOutputs() {
        guard outputWatchStop == nil else { return }
        outputWatchStop = watchOutputs { [weak self] in self?.refreshOutputs() }
    }

    /// The card folded: the listeners go.
    func stopWatchingOutputs() {
        outputWatchStop?()
        outputWatchStop = nil
    }

    func refreshOutputs() {
        let read = readOutputs()
        if outputs != read.devices { outputs = read.devices }
        if defaultOutput != read.current { defaultOutput = read.current }
    }

    /// The picker's write: the sound moves to `device`, then the list and
    /// the volume are read back — a device that refused stays unchecked.
    func pickOutput(_ device: CoreAudioOutputs.Device) {
        _ = writeOutput(device.id)
        refreshOutputs()
        outputVolume = SystemLevelReader.outputVolume().map(Double.init)
    }

    /// The device playing now, for the picker's glyph and help.
    var currentOutput: CoreAudioOutputs.Device? {
        outputs.first { $0.id == defaultOutput }
    }

    // MARK: Power adapter

    /// The charger's rating in watts while one is connected — boring.notch
    /// 2.8's adapter line, from public IOKit
    /// (`IOPSCopyExternalPowerAdapterDetails`). nil on battery or when
    /// macOS does not say.
    private(set) var adapterWatts: Int?
    @ObservationIgnored var readAdapterWatts: () -> Int? = { AlcovePowerMonitor.adapterWatts() }

    func stop() {
        guard running else { return }
        running = false
        if let feedToken { feed.unsubscribe(feedToken) }
        feedToken = nil
        powerMonitor.stop()
        stopWatchingOutputs()
        weather.stop()
        lyrics.reset()
        // Keep-awake deliberately survives the fold: the user's
        // toggle is an app-level intent, not a card-lifetime lease —
        // and the assertion dies with the process anyway.
        media = nil
        noteArtwork(nil)
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

    /// Artwork for the card: a thumbnail made off the main thread when
    /// the cover changes (`NotchArtworkStore`). nil for no art, and for
    /// a payload that is oversized or not an image — the row draws the
    /// placeholder. A new cover keeps the last one up for the few
    /// milliseconds its decode takes.
    private(set) var artwork: NSImage?

    // MARK: Artwork tint

    /// The artwork's own colour, made readable on black — the bars and
    /// the scrubber wear it, OneNotch's artwork-coloured media. nil for
    /// no art, or art too grey to have a colour (the row stays white).
    private(set) var artworkTint: NSColor?
    /// The cover the artwork and tint are for — the same cover resent
    /// with a pause or a seek costs nothing.
    @ObservationIgnored private var artworkSource: Data?
    /// Where covers are decoded; shared with the island's strip.
    @ObservationIgnored var artworkStore: NotchArtworkStore = .shared
    /// A headless card (tests, render proofs) reads and decodes in the
    /// turn it is asked, since it draws in that turn. A live one keeps
    /// the frame the island grows on clear: covers decode off the main
    /// thread, and the output list and the switches wait a turn.
    @ObservationIgnored var inlineReads = false

    private func noteArtwork(_ data: Data?) {
        guard data != artworkSource else { return }
        artworkSource = data
        guard let data else {
            artwork = nil
            artworkTint = nil
            return
        }
        artworkStore.art(for: data, inline: inlineReads) { [weak self] art in
            guard let self, self.artworkSource == data else { return }
            self.artwork = art?.image
            self.artworkTint = art?.tint
        }
    }

    nonisolated private static let tintContext = CIContext(options: [.workingColorSpace: NSNull()])

    /// The artwork's mean colour — one CIAreaAverage pass rendered to a
    /// single pixel. Safe off the main thread.
    nonisolated static func averageColor(of data: Data) -> (red: Double, green: Double, blue: Double)? {
        guard let image = CIImage(data: data) else { return nil }
        return averageColor(of: image)
    }

    nonisolated static func averageColor(of image: CIImage) -> (red: Double, green: Double, blue: Double)? {
        guard !image.extent.isEmpty,
              let filter = CIFilter(name: "CIAreaAverage",
                                    parameters: [kCIInputImageKey: image,
                                                 kCIInputExtentKey: CIVector(cgRect: image.extent)]),
              let output = filter.outputImage else { return nil }
        var pixel = [UInt8](repeating: 0, count: 4)
        tintContext.render(output, toBitmap: &pixel, rowBytes: 4,
                           bounds: CGRect(x: 0, y: 0, width: 1, height: 1),
                           format: .RGBA8, colorSpace: nil)
        return (Double(pixel[0]) / 255, Double(pixel[1]) / 255, Double(pixel[2]) / 255)
    }

    /// A mean colour as a tint that reads on the card: art too grey to
    /// have a colour gives none, the rest keep their hue with the
    /// brightness lifted and the saturation capped, so a dark cover
    /// never draws bars that vanish into the black.
    nonisolated static func readableTint(red: Double, green: Double,
                                         blue: Double) -> (hue: Double, saturation: Double, brightness: Double)? {
        let high = max(red, green, blue)
        let low = min(red, green, blue)
        let chroma = high - low
        let saturation = high > 0 ? chroma / high : 0
        guard saturation >= 0.18, chroma >= 0.06 else { return nil }
        var hue: Double
        if high == red {
            hue = (green - blue) / chroma
        } else if high == green {
            hue = (blue - red) / chroma + 2
        } else {
            hue = (red - green) / chroma + 4
        }
        hue /= 6
        if hue < 0 { hue += 1 }
        return (hue, min(saturation, 0.75), max(high, 0.78))
    }

    /// A click on the artwork: the player comes forward — the app the
    /// feed named, and only if it is running (nothing is launched).
    func raisePlayer() {
        guard let bundle = media?.bundleIdentifier,
              let app = NSRunningApplication.runningApplications(withBundleIdentifier: bundle).first
        else { return }
        app.activate()
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
