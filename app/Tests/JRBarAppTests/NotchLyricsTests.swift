import Foundation
import Testing
import JRBarCore
@testable import JRBarApp

/// Lyrics that keep time and keep quiet: the LRC offset applied, the
/// next line and the sweep's progress, the lookups remembered across
/// launches, and the switch that sends nothing until it is agreed to.
/// No network — every store here answers from its disk cache, a
/// recording stub or not at all.
@Suite("Notch lyrics")
@MainActor
struct NotchLyricsTests {
    private func tempURL() -> URL {
        URL(fileURLWithPath: NSTemporaryDirectory() + "jrbar-test-lyrics-\(UUID().uuidString).json")
    }

    @Test("the offset tag moves every stamp, sooner for a positive offset")
    func offset() throws {
        #expect(SyncedLyrics.offsetMilliseconds(in: "[ti:x]\n[offset:+250]\n[00:01.00] a") == 250)
        #expect(SyncedLyrics.offsetMilliseconds(in: "[offset: -500]") == -500)
        #expect(SyncedLyrics.offsetMilliseconds(in: "[00:01.00] a") == nil)
        let lrc = "[offset:500]\n[00:00.20] first\n[00:02.00] second"
        let shifted = SyncedLyrics.parse(lrc).applyingOffset(in: lrc)
        #expect(shifted.lines.map(\.time) == [0, 1.5], "clamped at the top of the track")
        let later = "[offset:-1000]\n[00:02.00] a"
        #expect(SyncedLyrics.parse(later).applyingOffset(in: later).lines.first?.time == 3)
        let record = try JSONDecoder().decode(LRCLIBRecord.self,
                                              from: Data(#"{"syncedLyrics":"[offset:1000]\n[00:03.00] hi"}"#.utf8))
        #expect(record.synced?.line(at: 2.1) == "hi", "the record's lyrics arrive on time")
    }

    @Test("the next line and how far through the current one the playhead is")
    func position() {
        let lyrics = SyncedLyrics.parse("[00:10.00] one\n[00:12.00] \n[00:14.00] two\n[00:18.00] three")
        let before = lyrics.position(at: 5)
        #expect(before.next == "one")
        #expect(before.progress == nil)
        let mid = lyrics.position(at: 15)
        #expect(mid.next == "three")
        #expect(abs((mid.progress ?? 0) - 0.25) < 0.001)
        let gap = lyrics.position(at: 12.5)
        #expect(gap.next == "two", "a breath between verses skips to the next words")
        let last = lyrics.position(at: 20)
        #expect(last.next == nil)
        #expect(last.progress == 0.5, "the last line sweeps over four seconds")
    }

    @Test("hits and misses survive a relaunch; a miss is retried after a week")
    func diskCache() {
        let url = tempURL()
        let now = Date()
        let lyrics = SyncedLyrics(lines: [.init(time: 1, text: "hello")])
        let first = LyricsDiskCache(url: url)
        #expect(first.lookup("song") == nil, "never looked up")
        first.store(lyrics, for: "song", now: now)
        first.store(nil, for: "instrumental", now: now)

        let relaunched = LyricsDiskCache(url: url)
        #expect(relaunched.lookup("song", now: now) == .some(lyrics))
        #expect(relaunched.lookup("instrumental", now: now) == .some(nil), "a remembered miss")
        #expect(relaunched.lookup("instrumental",
                                  now: now.addingTimeInterval(LyricsDiskCache.missLife + 1)) == nil,
                "lyrics get added; a week-old miss asks again")
        #expect(relaunched.lookup("song", now: now.addingTimeInterval(365 * 86_400)) == .some(lyrics))
    }

    @Test("the cache holds its cap, oldest out")
    func diskCap() {
        let cache = LyricsDiskCache(url: tempURL())
        let start = Date(timeIntervalSince1970: 1_000)
        for i in 0...LyricsDiskCache.cap {
            cache.store(nil, for: "k\(i)", now: start.addingTimeInterval(Double(i)))
        }
        #expect(cache.lookup("k0", now: start) == nil, "the oldest fell out")
        #expect(cache.lookup("k\(LyricsDiskCache.cap)", now: start) == .some(nil))
    }

    @Test("a known track answers from disk; the switch off answers nothing")
    func storeFromDisk() {
        let url = tempURL()
        let media = AlcoveMedia(title: "Papillon", artist: "Editors", playing: true)
        let key = LyricsQuery(media: media)!.cacheKey
        LyricsDiskCache(url: url).store(SyncedLyrics(lines: [.init(time: 0, text: "la")]), for: key)

        let store = LyricsStore(diskURL: url)
        store.enabled = { true }
        store.note(media: media)
        #expect(store.lyrics?.lines.first?.text == "la", "no network: the disk knew")

        let off = LyricsStore(diskURL: url)
        off.note(media: media)
        #expect(off.lyrics == nil, "a store starts off: not even the disk is read")
        #expect(!NotchSettings().lyrics, "off by default: it phones a third party")
    }

    @Test("a file without the keys is off; a switch saved on before consent stays off")
    func decodesOff() throws {
        let bare = try JSONDecoder().decode(NotchSettings.self, from: Data("{}".utf8))
        #expect(!bare.lyrics)
        #expect(!bare.lyricsConsented)
        #expect(!bare.lyricsAllowed)

        let shipped = try JSONDecoder().decode(NotchSettings.self, from: Data(#"{"lyrics":true}"#.utf8))
        #expect(shipped.lyrics, "the switch keeps what was saved")
        #expect(!shipped.lyricsAllowed, "but nothing is sent without the yes")

        let agreed = try JSONDecoder().decode(NotchSettings.self,
                                              from: Data(#"{"lyrics":true,"lyricsConsented":true}"#.utf8))
        #expect(agreed.lyricsAllowed)
        let roundTrip = try JSONDecoder().decode(NotchSettings.self,
                                                 from: JSONEncoder().encode(agreed))
        #expect(roundTrip.lyricsConsented, "the yes is written back")
    }

    @Test("off, no lrclib.net request is ever built; on, the same track asks it")
    func offSendsNothing() async throws {
        let session = LyricsRecordingProtocol.session()
        let media = AlcoveMedia(title: "Unheard \(UUID().uuidString)", artist: "Nobody", playing: true)
        let store = LyricsStore(session: session)
        store.note(media: media)
        #expect(store.inFlight.isEmpty, "off: no lookup starts")
        #expect(LyricsRecordingProtocol.hosts(for: media.title).isEmpty)

        // The control: the same store and stub do reach LRCLIB once on.
        store.enabled = { true }
        store.note(media: media)
        #expect(!store.inFlight.isEmpty)
        // The lookup starts on the main actor, which a loaded parallel
        // run can hold for seconds; the wait ends as soon as it lands.
        let deadline = Date().addingTimeInterval(60)
        while LyricsRecordingProtocol.hosts(for: media.title).isEmpty, Date() < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(LyricsRecordingProtocol.hosts(for: media.title).first == "lrclib.net")
    }

    @Test("the card's offer shows only with the switch on and no yes; a click or the switch is the yes")
    func consentWiring() {
        var toys = ToysState()
        toys.notch = NotchSettings(enabled: true)
        toys.notch.lyrics = true
        let core = CoreModel()
        let store = ToysStore(core: core, settings: SettingsStore(core: core),
                              state: toys, cardModel: makeTestCardModel(),
                              notchRuntimeEnabled: false)
        let toy: NotchToy = store.notch
        let lyrics = LyricsStore()
        toy.wireLyrics(lyrics)
        #expect(!lyrics.enabled(), "a switch saved on from before is not consent")
        #expect(lyrics.offersConsent())
        #expect(toy.lyricsSubtitle.contains("LRCLIB"))
        #expect(toy.lyricsSubtitle.contains("Waiting for your yes"))

        lyrics.consent()
        #expect(store.state.notch.lyricsConsented)
        #expect(lyrics.enabled())
        #expect(!lyrics.offersConsent())

        store.state.notch.lyrics = false
        store.state.notch.lyricsConsented = false
        #expect(!lyrics.offersConsent(), "never offered while the switch is off")
        toy.lyricsBinding.wrappedValue = true
        #expect(store.state.notch.lyricsConsented, "turning it on beside the LRCLIB words is the yes")
        #expect(lyrics.enabled())
        #expect(!toy.lyricsSubtitle.contains("Waiting"))
    }
}

/// Records every request's host by track name and fails it at once, so
/// a lookup that should never start can be seen without the network.
private final class LyricsRecordingProtocol: URLProtocol {
    nonisolated(unsafe) private static var seen: [(track: String, host: String)] = []
    private static let lock = NSLock()

    static func session() -> URLSession {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [LyricsRecordingProtocol.self]
        return URLSession(configuration: config)
    }

    static func hosts(for track: String) -> [String] {
        lock.lock(); defer { lock.unlock() }
        return seen.filter { $0.track == track }.map(\.host)
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let url = request.url
        let track = url.flatMap { URLComponents(url: $0, resolvingAgainstBaseURL: false) }?
            .queryItems?.first { $0.name == "track_name" }?.value ?? ""
        Self.lock.lock()
        Self.seen.append((track, url?.host ?? ""))
        Self.lock.unlock()
        client?.urlProtocol(self, didFailWithError: URLError(.notConnectedToInternet))
    }

    override func stopLoading() {}
}
