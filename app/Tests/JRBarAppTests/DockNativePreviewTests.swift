import AppKit
import EventKit
import Foundation
import JRBarCore
import JRBarTestSupport
import os
import Testing
@testable import JRBarApp

@MainActor
@Suite("Dock native previews", .serialized, .timeLimit(.minutes(2)))
struct DockNativePreviewTests {
    static let now = Date(timeIntervalSince1970: 1_800_000_000)

    private final class Monitor: AlcoveMediaMonitor {
        var starts = 0
        var stops = 0
        var commands: [MediaRemoteBridge.Command] = []
        var seeks: [Double] = []
        var reportEmptyOnStart = false
        override func start() {
            starts += 1
            markRunning(true)
            if reportEmptyOnStart { onChange?(nil) }
        }
        override func stop() { stops += 1; markRunning(false) }
        override func send(_ command: MediaRemoteBridge.Command) { commands.append(command) }
        override func seek(to seconds: Double) { seeks.append(seconds) }
    }

    private func content(_ bundle: String) -> DockPreviewContent {
        let content = DockPreviewContent()
        content.bundleID = bundle
        return content
    }

    private func calendar(_ events: [ShelfCalendarModel.Event] = []) -> DockCalendarPreview {
        let calendar = DockCalendarPreview(reader: ShelfCalendarReader(fetch: { _ in events }))
        calendar.authorization = { .fullAccess }
        calendar.clock = { Self.now }
        calendar.scheduleRefreshOverride = {}
        return calendar
    }

    private func settle(_ calendar: DockCalendarPreview) async {
        await withCheckedContinuation { continuation in
            calendar.queue.async { DispatchQueue.main.async { continuation.resume() } }
        }
    }

    @Test("switches default on, tolerate old state, and round-trip independently")
    func switches() throws {
        let defaults = DockEnhanceSettings()
        #expect(defaults.calendarPreview && defaults.mediaPreview)
        for json in ["{}", #"{"calendarPreview":"yes","mediaPreview":null}"#] {
            let decoded = try JSONDecoder().decode(DockEnhanceSettings.self, from: Data(json.utf8))
            #expect(decoded.calendarPreview && decoded.mediaPreview)
        }
        var state = defaults
        state.calendarPreview = false
        let decoded = try JSONDecoder().decode(DockEnhanceSettings.self, from: JSONEncoder().encode(state))
        #expect(!decoded.calendarPreview && decoded.mediaPreview)
        let preferences = DockEnhancePreferences()
        preferences.read = { state }
        preferences.write = { state = $0 }
        preferences.mediaPreview = false
        #expect(!state.calendarPreview && !state.mediaPreview)
        preferences.calendarPreview = true
        #expect(state.calendarPreview && !state.mediaPreview)
    }

    @Test("off starts neither a calendar read nor a media monitor, even for Calendar")
    func noReaderWhenOff() async {
        let reads = OSAllocatedUnfairLock(initialState: 0)
        let source = ShelfCalendarReader(fetch: { _ in reads.withLock { $0 += 1 }; return [] })
        let calendar = DockCalendarPreview(reader: source)
        calendar.authorization = { .fullAccess }
        calendar.scheduleRefreshOverride = {}
        let monitor = Monitor()
        let feed = MediaFeed(monitor: monitor)
        let readers = DockNativePreviews(feed: feed, calendar: calendar)
        let card = content("com.apple.iCal")
        readers.start(content: card, settings: DockEnhanceSettings(calendarPreview: false, mediaPreview: false))
        await settle(calendar)
        #expect(reads.withLock { $0 } == 0)
        #expect(!calendar.running)
        #expect(monitor.starts == 0 && feed.readerCount == 0)
        #expect(card.calendarState == nil && card.media == nil)
        readers.stop()
    }

    @Test("calendar-only does not start media, media-only does not read Calendar")
    func independentReaders() async {
        let calendar = calendar()
        let monitor = Monitor()
        let feed = MediaFeed(monitor: monitor)
        let readers = DockNativePreviews(feed: feed, calendar: calendar)
        let card = content("com.apple.iCal")
        readers.start(content: card, settings: DockEnhanceSettings(calendarPreview: true, mediaPreview: false))
        await settle(calendar)
        #expect(card.calendarState == .events([]))
        #expect(monitor.starts == 0)
        readers.update(settings: DockEnhanceSettings(calendarPreview: false, mediaPreview: true))
        #expect(card.calendarState == nil && !calendar.running)
        #expect(monitor.starts == 1)
        readers.stop()
        #expect(feed.readerCount == 0 && monitor.stops == 1)
    }

    @Test("each permission refusal is explicit and makes no calendar read",
          arguments: [EKAuthorizationStatus.denied, .restricted, .notDetermined, .writeOnly])
    func noAccess(_ status: EKAuthorizationStatus) async {
        let reads = OSAllocatedUnfairLock(initialState: 0)
        let calendar = DockCalendarPreview(reader: ShelfCalendarReader(fetch: { _ in
            reads.withLock { $0 += 1 }; return []
        }))
        calendar.authorization = { status }
        calendar.scheduleRefreshOverride = {}
        var state: DockCalendarPreview.State?
        calendar.onChange = { state = $0 }
        calendar.start()
        await settle(calendar)
        #expect(state == .noAccess)
        #expect(reads.withLock { $0 } == 0)
        calendar.stop()
    }

    @Test("cache is reused for a minute, expires, and invalidates on store changes")
    func cache() {
        let reads = OSAllocatedUnfairLock(initialState: 0)
        let reader = ShelfCalendarReader(fetch: { _ in reads.withLock { $0 += 1 }; return [] })
        _ = reader.events(from: Self.now)
        _ = reader.events(from: Self.now.addingTimeInterval(59))
        #expect(reads.withLock { $0 } == 1)
        _ = reader.events(from: Self.now.addingTimeInterval(60))
        #expect(reads.withLock { $0 } == 2)
        reader.invalidate()
        _ = reader.events(from: Self.now.addingTimeInterval(61))
        #expect(reads.withLock { $0 } == 3)
    }

    @Test("a visible calendar refreshes on a store change and stops on hide")
    func storeChangesAndHide() async {
        let reads = OSAllocatedUnfairLock(initialState: 0)
        let reader = ShelfCalendarReader(fetch: { _ in reads.withLock { $0 += 1 }; return [] })
        let calendar = DockCalendarPreview(reader: reader)
        calendar.authorization = { .fullAccess }
        calendar.clock = { Self.now }
        var schedules = 0
        calendar.scheduleRefreshOverride = { schedules += 1 }
        calendar.start()
        await settle(calendar)
        #expect(reads.withLock { $0 } == 1 && schedules == 1)
        reader.notifications.post(name: .EKEventStoreChanged, object: nil)
        await settle(calendar)
        #expect(reads.withLock { $0 } == 2 && schedules == 2)
        calendar.stop()
        reader.notifications.post(name: .EKEventStoreChanged, object: nil)
        calendar.refresh()
        await settle(calendar)
        #expect(reads.withLock { $0 } == 2 && schedules == 2)
    }

    @Test("closing or revoking access during a read drops its result", arguments: [false, true])
    func delayedReply(_ revoked: Bool) async {
        let gate = DispatchSemaphore(value: 0)
        let entered = TestSignal()
        let event = ShelfCalendarModel.Event(title: "Synthetic event", start: Self.now,
            end: Self.now.addingTimeInterval(600), url: nil)
        let source = ShelfCalendarReader(fetch: { _ in entered.signal(); #expect(gate.wait(timeout: .now() + 10) == .success); return [event] })
        let calendar = DockCalendarPreview(reader: source)
        calendar.authorization = { .fullAccess }
        calendar.scheduleRefreshOverride = {}
        var last: DockCalendarPreview.State?
        calendar.onChange = { last = $0 }
        calendar.start()
        #expect(await entered.wait())
        if revoked { calendar.authorization = { .denied } } else { calendar.stop() }
        gate.signal()
        await settle(calendar)
        #expect(last == (revoked ? .noAccess : .loading))
        calendar.stop()
    }

    @Test("the Dock borrows the same stream and preserves playing, paused, artwork and empty states")
    func mediaStates() {
        let monitor = Monitor()
        let feed = MediaFeed(monitor: monitor)
        let notch = feed.subscribe { _ in }
        let readers = DockNativePreviews(feed: feed, calendar: calendar())
        let card = content("com.spotify.client")
        readers.start(content: card, settings: DockEnhanceSettings(calendarPreview: false))
        #expect(monitor.starts == 1 && feed.readerCount == 2)
        #expect(card.media == nil)
        for playing in [true, false] {
            let track = AlcoveMedia(title: "Synthetic song", artist: "Synthetic artist", playing: playing,
                bundleIdentifier: "com.spotify.client", duration: 200, elapsed: 25,
                timestamp: Self.now.timeIntervalSinceReferenceDate)
            monitor.onChange?(track)
            #expect(card.media == track && card.media?.artworkData == nil)
            readers.send(.togglePlayPause)
            readers.send(.nextTrack)
            readers.send(.previousTrack)
        }
        let expected: [MediaRemoteBridge.Command] = [
            .togglePlayPause, .nextTrack, .previousTrack,
            .togglePlayPause, .nextTrack, .previousTrack,
        ]
        #expect(monitor.commands == expected)
        let artwork = Data([1, 2, 3])
        monitor.onChange?(AlcoveMedia(title: "With artwork", playing: true, artworkData: artwork,
                                     bundleIdentifier: "com.spotify.client"))
        #expect(card.media?.artworkData == artwork)
        readers.seek(to: 42)
        #expect(monitor.seeks == [42])
        monitor.onChange?(nil)
        #expect(card.media == nil)
        readers.send(.nextTrack)
        readers.seek(to: 84)
        #expect(monitor.seeks == [42])
        #expect(monitor.commands.count == 6)
        readers.stop()
        #expect(feed.readerCount == 1 && monitor.stops == 0)
        feed.unsubscribe(notch)
        #expect(monitor.stops == 1)
    }

    @Test("a browser's current track appears only on its own preview and off releases its reader")
    func currentPlayerAndOff() {
        let monitor = Monitor()
        let feed = MediaFeed(monitor: monitor)
        let readers = DockNativePreviews(feed: feed, calendar: calendar())
        let card = content("test.browser")
        readers.start(content: card, settings: DockEnhanceSettings())
        monitor.onChange?(AlcoveMedia(title: "Browser song", playing: true, bundleIdentifier: "test.browser"))
        #expect(card.media?.title == "Browser song")
        monitor.onChange?(AlcoveMedia(title: "Other song", playing: true, bundleIdentifier: "com.apple.Music"))
        #expect(card.media == nil)
        readers.update(settings: DockEnhanceSettings(mediaPreview: false))
        #expect(feed.readerCount == 0 && monitor.stops == 1)
        readers.stop()
    }

    private final class ImmediateLane: DockPreviewLane {
        func run<Answer: Sendable>(_ work: @escaping @Sendable () -> Answer,
                                   then: @escaping @MainActor @Sendable (Answer) -> Void) {
            then(work())
        }
    }

    @Test("controller presents before starting readers, applies switches, and releases on hide",
          arguments: [false, true])
    func controllerLifecycle(_ enabled: Bool) async {
        let reads = OSAllocatedUnfairLock(initialState: 0)
        let calendar = DockCalendarPreview(reader: ShelfCalendarReader(fetch: { _ in
            reads.withLock { $0 += 1 }; return []
        }))
        calendar.authorization = { .fullAccess }
        calendar.scheduleRefreshOverride = {}
        let monitor = Monitor()
        let feed = MediaFeed(monitor: monitor)
        var settings = DockEnhanceSettings(calendarPreview: enabled, mediaPreview: enabled)
        let preferences = DockEnhancePreferences()
        preferences.read = { settings }
        let controller = DockEnhanceController(preferences: preferences)
        controller.nativePreviews = DockNativePreviews(feed: feed, calendar: calendar)
        let window = DockPreviewWindow(id: 1, title: "Synthetic window", minimized: false,
            fullScreen: nil, frame: CGRect(x: 0, y: 0, width: 400, height: 300),
            thumbnail: nil, element: nil, windowID: 1)
        controller.ax = DockPreviewAX(lane: ImmediateLane(), read: { _, _ in ([window], false) })
        controller.apps = DockTileApps(forTile: { _, _ in
            DockTileApp(pid: 4100, name: "Calendar", bundleID: "com.apple.iCal",
                        bundleURL: nil, icon: nil, isTerminated: false)
        }, forPID: { _ in nil })
        var presentations = 0
        controller.presenter = { [weak controller] _, _ in
            guard let controller else { return }
            presentations += 1
            #expect(reads.withLock { $0 } == 0 && monitor.starts == 0)
            #expect(controller.preview.calendarState == (enabled ? .loading : nil))
            controller.startNativePreviews()
        }
        let tile = DockAXItem(element: AXUIElementCreateSystemWide(),
            frame: CGRect(x: 100, y: 900, width: 60, height: 60), title: "Calendar",
            url: nil, kind: .app)
        controller.showPreview(for: tile, keyboardOpened: true)
        await settle(calendar)
        #expect(presentations == 1 && controller.previewUp)
        #expect(controller.preview.showsWindows)
        #expect(reads.withLock { $0 } == (enabled ? 1 : 0))
        #expect(monitor.starts == (enabled ? 1 : 0))
        settings.calendarPreview = false
        settings.mediaPreview = false
        controller.syncNativePreviews()
        #expect(!calendar.running && feed.readerCount == 0)
        #expect(controller.preview.calendarState == nil && controller.preview.media == nil)
        controller.hidePreview()
        #expect(!controller.previewUp && feed.readerCount == 0)
    }

    @Test("native cards keep windows reachable and an empty player restores them")
    func windowDisclosure() {
        let card = content("com.apple.Music")
        #expect(card.showsWindows)
        card.media = AlcoveMedia(title: "Synthetic song", playing: true)
        #expect(!card.showsWindows)
        card.nativeWindowsExpanded = true
        #expect(card.showsWindows)
        card.nativeWindowsExpanded = false
        card.selectedWindowID = 1
        #expect(card.showsWindows)
        card.selectedWindowID = nil
        card.media = nil
        #expect(card.showsWindows)
    }
    @Test("a windowless player outside the known list is discovered, and an empty stream closes safely",
          arguments: [false, true])
    func windowlessPlayer(_ playing: Bool) async {
        let monitor = Monitor()
        monitor.reportEmptyOnStart = !playing
        let feed = MediaFeed(monitor: monitor)
        let calendar = calendar()
        let preferences = DockEnhancePreferences()
        preferences.read = { DockEnhanceSettings(calendarPreview: false) }
        let controller = DockEnhanceController(preferences: preferences)
        controller.nativePreviews = DockNativePreviews(feed: feed, calendar: calendar)
        controller.ax = DockPreviewAX(lane: ImmediateLane(), read: { _, _ in ([], false) })
        controller.apps = DockTileApps(forTile: { _, _ in
            DockTileApp(pid: 4100, name: "Synthetic player", bundleID: "test.player",
                        bundleURL: nil, icon: nil, isTerminated: false)
        }, forPID: { _ in nil })
        var presentations = 0
        controller.presenter = { [weak controller] _, _ in
            presentations += 1
            controller?.startNativePreviews()
        }
        let tile = DockAXItem(element: AXUIElementCreateSystemWide(),
            frame: CGRect(x: 100, y: 900, width: 60, height: 60), title: "Synthetic player",
            url: nil, kind: .app)
        controller.showPreview(for: tile)
        if playing {
            #expect(controller.preview.mediaPending && controller.previewUp)
            monitor.onChange?(AlcoveMedia(title: "Synthetic song", playing: true, bundleIdentifier: "test.player"))
        }
        await settle(calendar)
        #expect(presentations == 1 && monitor.starts == 1)
        #expect(controller.previewUp == playing)
        #expect(!controller.preview.mediaPending)
        #expect((controller.preview.media != nil) == playing)
        controller.hidePreview()
        #expect(feed.readerCount == 0 && monitor.stops == 1)
    }

}
