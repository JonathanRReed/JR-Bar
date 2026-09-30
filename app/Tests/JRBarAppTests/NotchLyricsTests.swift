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

    // MARK: A failed lookup is not "no lyrics"

    /// Polls `condition` on the main actor until it holds or the deadline
    /// passes. The lookup runs on a task of its own; nothing here sleeps
    /// for a fixed time.
    private func wait(upTo seconds: TimeInterval = 60, until condition: () -> Bool) async {
        let deadline = Date().addingTimeInterval(seconds)
        while !condition(), Date() < deadline {
            try? await Task.sleep(for: .milliseconds(5))
        }
    }

    @Test("a lookup that could not reach LRCLIB is not remembered as no lyrics")
    func failedLookupIsNotCached() async throws {
        let title = "Offline \(UUID().uuidString)"
        LyricsScriptedProtocol.script(title, get: .failure, search: .failure)
        let url = tempURL()
        defer { try? FileManager.default.removeItem(at: url) }
        let media = AlcoveMedia(title: title, artist: "Nobody", playing: true)
        let query = try #require(LyricsQuery(media: media))
        let store = LyricsStore(session: LyricsScriptedProtocol.session(), diskURL: url)
        store.enabled = { true }
        store.note(media: media)
        await wait { LyricsScriptedProtocol.requests(for: title) >= 2 && store.inFlight.isEmpty }
        #expect(LyricsScriptedProtocol.requests(for: title) == 2, "both endpoints were asked")
        #expect(store.inFlight.isEmpty)
        #expect(store.lyrics == nil)
        #expect(!FileManager.default.fileExists(atPath: url.path), "nothing was written to disk")
        let onDisk = LyricsDiskCache(url: url).lookup(query.cacheKey)
        #expect(onDisk == nil, "a week-long miss was never stored")
    }

    private static func reply(_ code: Int, _ body: String) -> LyricsScriptedProtocol.Reply {
        .status(code, Data(body.utf8))
    }

    private static let syncedRecord = #"{"duration":200,"syncedLyrics":"[00:01.00] la"}"#

    @Test("a lookup reads each answer honestly: words, a real none, or no answer")
    func lookupClassifiesAnswers() async {
        typealias Case = (name: String, get: LyricsScriptedProtocol.Reply,
                          search: LyricsScriptedProtocol.Reply, expected: String)
        let cases: [Case] = [
            ("transport error on both", .failure, .failure, "unavailable"),
            ("500 on both", Self.reply(500, ""), Self.reply(500, ""), "unavailable"),
            ("429 on both", Self.reply(429, ""), Self.reply(429, ""), "unavailable"),
            ("a captive portal's page", Self.reply(200, "<html>Sign in</html>"),
             Self.reply(200, "<html>Sign in</html>"), "unavailable"),
            ("404 then an empty search", Self.reply(404, ""), Self.reply(200, "[]"), "absent"),
            ("404 then only unsynced records", Self.reply(404, ""),
             Self.reply(200, #"[{"duration":200,"syncedLyrics":null}]"#), "absent"),
            ("404 then a synced record outside the window", Self.reply(404, ""),
             Self.reply(200, #"[{"duration":230,"syncedLyrics":"[00:01.00] far"}]"#), "absent"),
            ("get failed then an empty search", Self.reply(500, ""), Self.reply(200, "[]"), "unavailable"),
            ("get answered none, search failed", Self.reply(404, ""), Self.reply(503, ""), "unavailable"),
            ("synced lyrics from get", Self.reply(200, Self.syncedRecord), .failure, "la"),
            ("404 then one synced candidate", Self.reply(404, ""),
             Self.reply(200, #"[{"duration":198,"syncedLyrics":"[00:01.00] near"}]"#), "near"),
            ("an instrumental record", Self.reply(200, #"{"duration":200,"syncedLyrics":null}"#),
             Self.reply(200, "[]"), "absent"),
        ]
        for entry in cases {
            let title = "Lookup \(UUID().uuidString)"
            LyricsScriptedProtocol.script(title, get: entry.get, search: entry.search)
            let query = LyricsQuery(title: title, artist: "Nobody", duration: 200)
            let outcome = await LyricsStore.lookup(query, session: LyricsScriptedProtocol.session())
            let seen: String
            switch outcome {
            case .found(let lyrics): seen = lyrics.lines.first?.text ?? "found"
            case .absent: seen = "absent"
            case .unavailable: seen = "unavailable"
            }
            #expect(seen == entry.expected, Comment(rawValue: entry.name))
        }
    }

    /// A store over a temporary disk file and a clock the test moves.
    private final class LyricsClock {
        var date = Date(timeIntervalSince1970: 1_000_000)
        func advance(_ seconds: TimeInterval) { date = date.addingTimeInterval(seconds) }
    }

    @Test("a failed track asks again after the cool-down, and not before")
    func failedTrackCoolsDown() async {
        let first = "Cool \(UUID().uuidString)"
        let second = "Down \(UUID().uuidString)"
        LyricsScriptedProtocol.script(first, get: .failure, search: .failure)
        LyricsScriptedProtocol.script(second, get: .failure, search: .failure)
        let clock = LyricsClock()
        let url = tempURL()
        defer { try? FileManager.default.removeItem(at: url) }
        let store = LyricsStore(session: LyricsScriptedProtocol.session(), diskURL: url,
                                now: { clock.date })
        store.enabled = { true }
        let trackA = AlcoveMedia(title: first, artist: "Nobody", playing: true)
        let trackB = AlcoveMedia(title: second, artist: "Nobody", playing: true)

        store.note(media: trackA)
        await wait { store.inFlight.isEmpty }
        #expect(LyricsScriptedProtocol.requests(for: first) == 2)
        clock.advance(1)
        store.note(media: trackB)
        await wait { store.inFlight.isEmpty }
        #expect(LyricsScriptedProtocol.requests(for: second) == 2)

        // Skipping back to A inside its cool-down asks nothing.
        clock.advance(30)
        store.note(media: trackA)
        #expect(store.inFlight.isEmpty, "inside the cool-down no lookup starts")
        #expect(LyricsScriptedProtocol.requests(for: first) == 2)

        // Past it, nothing was memoized: B and then A ask again.
        clock.advance(LyricsStore.retryCooldown + 1)
        store.note(media: trackB)
        await wait { store.inFlight.isEmpty }
        store.note(media: trackA)
        await wait { store.inFlight.isEmpty }
        #expect(LyricsScriptedProtocol.requests(for: second) == 4)
        #expect(LyricsScriptedProtocol.requests(for: first) == 4)
    }

    @Test("the same track asks again on the next push once its cool-down has passed")
    func sameTrackRetries() async {
        let title = "Same \(UUID().uuidString)"
        LyricsScriptedProtocol.script(title, get: .failure, search: .failure)
        let clock = LyricsClock()
        let url = tempURL()
        defer { try? FileManager.default.removeItem(at: url) }
        let store = LyricsStore(session: LyricsScriptedProtocol.session(), diskURL: url,
                                now: { clock.date })
        store.enabled = { true }
        let playing = AlcoveMedia(title: title, artist: "Nobody", playing: true)
        let paused = AlcoveMedia(title: title, artist: "Nobody", playing: false)
        store.note(media: playing)
        await wait { store.inFlight.isEmpty }
        #expect(LyricsScriptedProtocol.requests(for: title) == 2)

        clock.advance(10)
        store.note(media: paused)
        #expect(store.inFlight.isEmpty, "a push inside the cool-down asks nothing")

        LyricsScriptedProtocol.script(title, get: Self.reply(200, Self.syncedRecord), search: .failure)
        clock.advance(LyricsStore.retryCooldown)
        store.note(media: playing)
        await wait { store.inFlight.isEmpty }
        #expect(LyricsScriptedProtocol.requests(for: title, path: "/api/get") == 2)
        #expect(store.lyrics?.lines.first?.text == "la", "the retry's answer publishes")
        store.note(media: paused)
        #expect(store.inFlight.isEmpty, "answered: a later push asks nothing more")
    }

    @Test("a genuine miss is still remembered, in memory and across a relaunch")
    func genuineMissIsRemembered() async throws {
        let title = "None \(UUID().uuidString)"
        LyricsScriptedProtocol.script(title, get: Self.reply(404, ""), search: Self.reply(200, "[]"))
        let url = tempURL()
        defer { try? FileManager.default.removeItem(at: url) }
        let media = AlcoveMedia(title: title, artist: "Nobody", playing: true)
        let query = try #require(LyricsQuery(media: media))
        let store = LyricsStore(session: LyricsScriptedProtocol.session(), diskURL: url)
        store.enabled = { true }
        store.note(media: media)
        await wait { store.inFlight.isEmpty }
        #expect(LyricsScriptedProtocol.requests(for: title) == 2)
        #expect(LyricsDiskCache(url: url).lookup(query.cacheKey) == .some(nil))

        let relaunched = LyricsStore(session: LyricsScriptedProtocol.session(), diskURL: url)
        relaunched.enabled = { true }
        relaunched.note(media: media)
        #expect(relaunched.inFlight.isEmpty, "the disk knew: no request")
        #expect(LyricsScriptedProtocol.requests(for: title) == 2)
        #expect(relaunched.lyrics == nil)
    }

    @Test("a hit is shown and stored")
    func hitIsStored() async throws {
        let title = "Hit \(UUID().uuidString)"
        LyricsScriptedProtocol.script(title, get: Self.reply(200, Self.syncedRecord), search: .failure)
        let url = tempURL()
        defer { try? FileManager.default.removeItem(at: url) }
        let media = AlcoveMedia(title: title, artist: "Nobody", playing: true)
        let query = try #require(LyricsQuery(media: media))
        let store = LyricsStore(session: LyricsScriptedProtocol.session(), diskURL: url)
        store.enabled = { true }
        store.note(media: media)
        await wait { store.inFlight.isEmpty }
        #expect(store.lyrics?.lines.first?.text == "la")
        let stored = LyricsDiskCache(url: url).lookup(query.cacheKey)
        #expect(stored??.lines.first?.text == "la")
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

/// Answers each LRCLIB endpoint with a scripted status and body, keyed by
/// the track title (a fresh UUID per test, so parallel runs never share
/// state), and counts the requests per title and path.
private final class LyricsScriptedProtocol: URLProtocol {
    enum Reply {
        case failure
        case status(Int, Data)
    }

    struct Script {
        var get: Reply
        var search: Reply
    }

    nonisolated(unsafe) private static var scripts: [String: Script] = [:]
    nonisolated(unsafe) private static var counts: [String: [String: Int]] = [:]
    private static let lock = NSLock()

    static func script(_ title: String, get: Reply, search: Reply) {
        lock.lock(); defer { lock.unlock() }
        scripts[title] = Script(get: get, search: search)
    }

    static func session() -> URLSession {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [LyricsScriptedProtocol.self]
        return URLSession(configuration: config)
    }

    /// Requests seen for a title: every path, or one (`/api/get`).
    static func requests(for title: String, path: String? = nil) -> Int {
        lock.lock(); defer { lock.unlock() }
        let byPath = counts[title] ?? [:]
        if let path { return byPath[path] ?? 0 }
        return byPath.values.reduce(0, +)
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let url = request.url
        let path = url?.path ?? ""
        let title = url.flatMap { URLComponents(url: $0, resolvingAgainstBaseURL: false) }?
            .queryItems?.first { $0.name == "track_name" }?.value ?? ""
        Self.lock.lock()
        Self.counts[title, default: [:]][path, default: 0] += 1
        let script = Self.scripts[title]
        Self.lock.unlock()
        let reply = path == "/api/search" ? script?.search : script?.get
        switch reply ?? .failure {
        case .failure:
            client?.urlProtocol(self, didFailWithError: URLError(.notConnectedToInternet))
        case .status(let code, let body):
            if let url, let response = HTTPURLResponse(url: url, statusCode: code,
                                                       httpVersion: "HTTP/1.1", headerFields: nil) {
                client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
                client?.urlProtocol(self, didLoad: body)
            }
            client?.urlProtocolDidFinishLoading(self)
        }
    }

    override func stopLoading() {}
}
