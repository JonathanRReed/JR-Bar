import AppKit
import Carbon
import JRBarCore
import JRBarTestSupport
import Testing
@testable import JRBarApp

@MainActor
@Suite("Dock Music player", .serialized)
struct DockMusicTests {
    static let now = Date(timeIntervalSince1970: 1_800_000_000)

    final class Monitor: AlcoveMediaMonitor {
        var starts = 0
        var stops = 0
        var commands: [MediaRemoteBridge.Command] = []
        var seeks: [Double] = []
        override func start() { starts += 1; markRunning(true) }
        override func stop() { stops += 1; markRunning(false) }
        override func send(_ command: MediaRemoteBridge.Command) { commands.append(command) }
        override func seek(to seconds: Double) { seeks.append(seconds) }
    }

    @MainActor final class Fixture {
        var running = true
        var status: SetupPermissionStatus = .granted
        var asks: [Bool] = []
        var reads = 0
        var sends: [DockMusicSource.Command] = []
        var fails = false
        var at = DockMusicTests.now
        var reading = DockMusicSource.Reading()
        var scheduled = 0
        var cancelled = 0
        var removedObservers = 0
        var tick: (@MainActor () -> Void)?
        var changed: (@MainActor () -> Void)?
        let monitor = Monitor()
        lazy var feed = MediaFeed(monitor: monitor)

        var source: DockMusicSource {
            DockMusicSource(isRunning: { self.running }, permission: { ask in
                self.asks.append(ask)
                return self.status
            }, read: {
                self.reads += 1
                if self.fails { throw CancellationError() }
                return self.reading
            }, send: { self.sends.append($0) })
        }

        func makePlayer() -> DockMusicPreview {
            DockMusicPreview(source: source, feed: feed, clock: { self.at }, schedule: { tick in
                self.scheduled += 1
                self.tick = tick
                return { self.cancelled += 1 }
            }, observe: { changed in
                self.changed = changed
                return { self.removedObservers += 1 }
            })
        }
    }

    static func track(playing: Bool = true, artwork: Data? = nil) -> AlcoveMedia {
        AlcoveMedia(title: "Paper Lanterns", artist: "The Example Quartet", album: "Small Hours",
            playing: playing, artworkData: artwork, bundleIdentifier: DockMusicSource.bundleID,
            duration: 240, elapsed: 60, timestamp: now.timeIntervalSinceReferenceDate)
    }

    @Test("no-permission layer borrows the feed and never preflights Automation")
    func noPermission() {
        let fixture = Fixture()
        let player = fixture.makePlayer()
        player.start(fullControls: false)
        defer { player.stop() }
        fixture.monitor.onChange?(Self.track())
        #expect(player.state == .playing && player.media?.album == "Small Hours")
        player.send(.transport(.togglePlayPause))
        player.send(.seek(90))
        player.send(.shuffle(true))
        #expect(fixture.monitor.commands == [.togglePlayPause])
        #expect(fixture.monitor.seeks == [90])
        #expect(fixture.asks.isEmpty && fixture.reads == 0 && fixture.sends.isEmpty)
        fixture.monitor.onChange?(Self.track(playing: false))
        #expect(player.state == .paused)
        fixture.at = Self.now.addingTimeInterval(20)
        fixture.tick?()
        #expect(player.elapsed == 60)
        fixture.running = false
        player.send(.transport(.togglePlayPause))
        #expect(player.state == .notRunning && fixture.monitor.commands == [.togglePlayPause])
        fixture.running = true
        player.refresh()
        fixture.monitor.onChange?(AlcoveMedia(title: "Other player", playing: true, bundleIdentifier: "test.other"))
        player.send(.transport(.nextTrack))
        #expect(fixture.monitor.commands == [.togglePlayPause])
        #expect(player.state == .stopped && !player.canControl)
    }

    @Test("progress advances by the injected clock and stops on hide")
    func timerLifecycle() {
        let fixture = Fixture()
        let player = fixture.makePlayer()
        player.start(fullControls: false)
        fixture.monitor.onChange?(Self.track())
        fixture.at = Self.now.addingTimeInterval(2)
        fixture.tick?()
        #expect(player.elapsed == 62)
        let held = player.now
        player.stop()
        fixture.at = Self.now.addingTimeInterval(30)
        fixture.tick?()
        #expect(player.now == held)
        #expect(fixture.cancelled == 1 && fixture.removedObservers == 1)
        #expect(fixture.feed.readerCount == 0 && fixture.monitor.stops == 1)
        #expect(!player.visible && player.media == nil)
    }

    @Test("hiding during a read rejects its reply and starts no further work")
    func hiddenReply() async {
        let fixture = Fixture()
        var source = fixture.source
        var player: DockMusicPreview!
        source.read = {
            fixture.reads += 1
            player.stop()
            return .init(media: Self.track())
        }
        player = DockMusicPreview(source: source, feed: fixture.feed, clock: { Self.now },
            schedule: { _ in {} }, observe: { _ in {} })
        player.start(fullControls: true)
        await player.settle()
        player.refresh()
        player.send(.transport(.nextTrack))
        #expect(player.media == nil && !player.visible && fixture.reads == 1)
        #expect(fixture.feed.readerCount == 0 && fixture.sends.isEmpty)
    }

    @Test("rich state matrix uses injected readings only",
          arguments: ["not-running", "stopped", "paused", "playing", "no-permission", "denied", "stale", "unavailable"])
    func states(_ mode: String) async {
        let fixture = Fixture()
        fixture.running = mode != "not-running"
        fixture.fails = mode == "unavailable"
        fixture.status = mode == "denied" ? .denied : mode == "no-permission" ? .needed : .granted
        fixture.reading = .init(media: mode == "stopped" ? nil : Self.track(playing: mode != "paused"),
            shuffle: true, repeatMode: .one, volume: 72, favorite: true)
        let player = fixture.makePlayer()
        player.start(fullControls: true)
        defer { player.stop() }
        if mode == "unavailable" { fixture.monitor.onChange?(Self.track()) }
        await player.settle()
        switch mode {
        case "not-running":
            #expect(player.state == .notRunning && fixture.asks.isEmpty && fixture.monitor.starts == 0)
        case "stopped": #expect(player.state == .stopped && player.media == nil)
        case "unavailable": #expect(player.stale && player.media != nil && player.soundVolume == nil)
        case "paused": #expect(player.state == .paused && player.shuffle && player.repeatMode == .one)
        case "no-permission", "denied":
            #expect(player.permission == fixture.status && fixture.reads == 0 && !player.canUseFullControls)
            #expect(fixture.asks == [false])
        case "stale":
            let last = player.media
            fixture.fails = true
            fixture.changed?()
            await player.settle()
            #expect(player.stale && player.media == last && !player.canControl)
            fixture.at = Self.now.addingTimeInterval(30)
            fixture.tick?()
            #expect(player.elapsed == 60)
        default:
            #expect(player.state == .playing && player.soundVolume == 72 && player.favorite == true)
        }
        #expect(!fixture.asks.contains(true))
    }

    @Test("Music off creates no source, clock, observer, subscription or preflight, even with media on")
    func offAndRouting() async {
        let fixture = Fixture()
        let native = DockNativePreviews(feed: fixture.feed)
        var creations = 0
        native.makeMusic = { _ in creations += 1; return fixture.makePlayer() }
        let content = DockPreviewContent()
        content.bundleID = DockMusicSource.bundleID
        var settings = DockEnhanceSettings(musicPlayer: false, musicFullControls: true)
        native.seed(content: content, settings: settings)
        native.start(content: content, settings: settings)
        #expect(creations == 0 && fixture.scheduled == 0 && fixture.asks.isEmpty)
        #expect(fixture.monitor.starts == 0 && fixture.feed.readerCount == 0 && content.media == nil)
        settings.musicPlayer = true
        native.update(settings: settings)
        await content.music?.settle()
        #expect(creations == 1 && fixture.feed.readerCount == 1)
        #expect(content.music != nil && content.media == nil && content.hasNativeCard)
        settings.musicPlayer = false
        native.update(settings: settings)
        #expect(content.music == nil && !content.musicPlayerEnabled)
        #expect(fixture.feed.readerCount == 0 && fixture.cancelled == 1)
        native.stop()
        content.bundleID = "test.other"
        native.start(content: content, settings: settings)
        fixture.monitor.onChange?(AlcoveMedia(title: "Other song", playing: true, bundleIdentifier: "test.other"))
        #expect(content.music == nil && content.media?.title == "Other song")
        native.stop()
    }

    @Test("full controls send each explicit command and refresh afterward")
    func controls() async {
        let fixture = Fixture()
        fixture.reading.media = Self.track()
        let player = fixture.makePlayer()
        player.start(fullControls: true)
        defer { player.stop() }
        await player.settle()
        let commands: [DockMusicSource.Command] = [.transport(.previousTrack), .transport(.togglePlayPause),
            .transport(.nextTrack), .seek(120), .volume(25), .shuffle(true), .repeatMode(.all), .favorite(true)]
        for command in commands {
            player.send(command)
            await player.settle()
            await player.settle()
        }
        #expect(fixture.sends == commands)
        #expect(fixture.monitor.commands.isEmpty && fixture.monitor.seeks.isEmpty)
        #expect(fixture.reads == commands.count + 1)
    }

    @Test("full controls prompt only through the explicit shared request")
    func explicitPermission() async {
        let fixture = Fixture()
        fixture.status = .needed
        let player = fixture.makePlayer()
        player.start(fullControls: true)
        defer { player.stop() }
        await player.settle()
        var effects: [String] = []
        let request = PermissionRequest(status: { fixture.status }, prompt: {
            effects.append("prompt")
            _ = await fixture.source.permission(true)
            fixture.status = .granted
        }, settingsURL: AutomationPermission.settingsURL, activate: { effects.append("activate") },
            openSettings: { _ in effects.append("settings") }, explainFullAccess: {}, refresh: {})
        await player.allowFullControls(request: request)
        await player.settle()
        #expect(effects == ["activate", "prompt"] && fixture.asks.filter { $0 }.count == 1)
        fixture.status = .denied
        await player.allowFullControls(request: request)
        #expect(effects.last == "settings" && fixture.asks.filter { $0 }.count == 1)
    }

    @Test("seek, volume and repeat stay within Music's ranges")
    func maths() {
        #expect(DockMusicPreview.seek(fraction: -1, duration: 200) == 0)
        #expect(DockMusicPreview.seek(fraction: 0.25, duration: 200) == 50)
        #expect(DockMusicPreview.seek(fraction: 2, duration: 200) == 200)
        #expect(DockMusicPreview.seek(fraction: .nan, duration: 200) == 0)
        #expect(DockMusicPreview.seek(fraction: 1, duration: .infinity) == 0)
        #expect(DockMusicPreview.volume(-1) == 0 && DockMusicPreview.volume(101) == 100)
        #expect(DockMusicPreview.volume(26.6) == 27 && DockMusicPreview.volume(.nan) == 0)
        #expect(DockMusicSource.Repeat.off.next.next.next == .off)
    }

    @Test("Music events target a PID and suppress consent prompts")
    func events() throws {
        var events: [NSAppleEventDescriptor] = []
        let client = MusicEvents(pid: 42, deliver: { event, timeout in
            #expect(timeout > 0 && timeout <= 3)
            events.append(event)
            return .null()
        })
        try client.send(.transport(.togglePlayPause))
        try client.send(.seek(90))
        try client.send(.volume(150))
        try client.send(.shuffle(true))
        try client.send(.repeatMode(.one))
        try client.send(.favorite(true))
        let codes = events.map { $0.attributeDescriptor(forKeyword: keyEventIDAttr)?.typeCodeValue }
        #expect(codes == [MusicEvents.code("PlPs")] + Array(repeating: MusicEvents.code("setd"), count: 5))
        #expect(events.allSatisfy { $0.attributeDescriptor(forKeyword: keyAddressAttr)?.descriptorType == typeKernelProcessID })
        #expect(events[1].paramDescriptor(forKeyword: keyDirectObject)?.forKeyword(MusicEvents.code("seld"))?.typeCodeValue == MusicEvents.code("pPos"))
        #expect(events[1].paramDescriptor(forKeyword: MusicEvents.code("data"))?.doubleValue == 90)
        #expect(events[2].paramDescriptor(forKeyword: MusicEvents.code("data"))?.int32Value == 100)
        #expect(events[3].paramDescriptor(forKeyword: MusicEvents.code("data"))?.booleanValue == true)
        #expect(events[4].paramDescriptor(forKeyword: MusicEvents.code("data"))?.enumCodeValue == MusicEvents.code("kRp1"))
        #expect(MusicEvents.sendOptions.rawValue & UInt(kAEDoNotPromptForUserConsent) != 0)
    }

    @Test("Music's dictionary replies decode paused metadata, artwork and full controls")
    func dictionaryReading() throws {
        let art = Data([1, 2, 3])
        let rawArt = try #require(NSAppleEventDescriptor(descriptorType: typeData, data: art))
        let values: [String: NSAppleEventDescriptor] = [
            "pPlS": .init(enumCode: MusicEvents.code("kPSp")), "pVol": .init(int32: 32),
            "pShE": .init(boolean: true), "pRpt": .init(enumCode: MusicEvents.code("kAll")),
            "pTrk": MusicEvents.property("pTrk"), "pnam": .init(string: "Synthetic song"),
            "pArt": .init(string: "Example artist"), "pAlb": .init(string: "Example album"),
            "pDur": .init(double: 240), "pPos": .init(double: 65), "pLov": .init(boolean: true),
            "pRaw": rawArt,
        ]
        let client = MusicEvents(pid: 42, deliver: { event, _ in
            let specifier = try #require(event.paramDescriptor(forKeyword: keyDirectObject))
            let selector = try #require(specifier.forKeyword(MusicEvents.code("seld")))
            let match = try #require(values.first { MusicEvents.code($0.key) == selector.typeCodeValue })
            let reply = NSAppleEventDescriptor(eventClass: MusicEvents.code("aevt"), eventID: MusicEvents.code("ansr"),
                targetDescriptor: .null(), returnID: AEReturnID(kAutoGenerateReturnID), transactionID: AETransactionID(kAnyTransactionID))
            reply.setParam(match.value, forKeyword: keyDirectObject)
            return reply
        })
        let reading = try client.read()
        #expect(reading.media?.title == "Synthetic song" && reading.media?.album == "Example album")
        #expect(reading.media?.playing == false && reading.media?.elapsed == 65)
        #expect(reading.media?.artworkData == art && reading.volume == 32)
        #expect(reading.shuffle && reading.repeatMode == .all && reading.favorite == true)
    }

    @Test("Music preferences default independently and survive old and malformed state")
    func settings() throws {
        for json in ["{}", #"{"musicPlayer":null,"musicFullControls":"yes"}"#] {
            let settings = try JSONDecoder().decode(DockEnhanceSettings.self, from: Data(json.utf8))
            #expect(settings.musicPlayer && !settings.musicFullControls)
        }
        var settings = DockEnhanceSettings()
        let preferences = DockEnhancePreferences()
        preferences.read = { settings }
        preferences.write = { settings = $0 }
        preferences.musicPlayer = false
        preferences.musicFullControls = true
        let decoded = try JSONDecoder().decode(DockEnhanceSettings.self, from: JSONEncoder().encode(settings))
        #expect(!decoded.musicPlayer && decoded.musicFullControls && decoded.mediaPreview)
    }
}
