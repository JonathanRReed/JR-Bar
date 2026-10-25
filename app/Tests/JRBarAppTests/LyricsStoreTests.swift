import Foundation
import Testing
import JRBarCore
@testable import JRBarApp

/// The LRCLIB wire record: the decode is lenient on `duration`
/// (a record that omits it or serves a string can't sink the whole
/// `/api/search` array) and `durationSeconds` never traps on a
/// server-supplied absurdity.
@Suite(.timeLimit(.minutes(2))) struct LyricsStoreTests {

    @MainActor
    @Test("memory misses expire while playing and after reset", arguments: [false, true])
    func memoryMissExpires(_ resetFirst: Bool) async throws {
        var clock = Date(timeIntervalSince1970: 1_000)
        let store = LyricsStore(now: { clock })
        store.enabled = { true }
        var calls = 0
        store.lookupOverride = { _ in calls += 1; return .absent }
        defer { store.reset() }
        let media = AlcoveMedia(title: "Fixture", artist: "Artist", playing: true)
        let key = try #require(LyricsQuery(media: media)).cacheKey
        store.note(media: media)
        let initial = try #require(store.lookupTasks[key])
        await initial.value
        clock = clock.addingTimeInterval(LyricsDiskCache.missLife - 1)
        store.note(media: media)
        #expect(store.lookupTasks.isEmpty)
        #expect(calls == 1)
        clock = clock.addingTimeInterval(1)
        if resetFirst { store.reset() }
        store.note(media: media)
        let renewed = try #require(store.lookupTasks[key])
        await renewed.value
        #expect(calls == 2)
    }

    @MainActor
    @Test("a promoted disk miss keeps its original expiry")
    func diskMissKeepsExpiry() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("lyrics.json")
        var clock = Date(timeIntervalSince1970: 1_000)
        let media = AlcoveMedia(title: "Fixture", artist: "Artist", playing: true)
        let key = try #require(LyricsQuery(media: media)).cacheKey
        LyricsDiskCache(url: url).store(nil, for: key, now: clock)
        clock = clock.addingTimeInterval(LyricsDiskCache.missLife - 1)
        let store = LyricsStore(diskURL: url, now: { clock })
        store.enabled = { true }
        var calls = 0
        store.lookupOverride = { _ in calls += 1; return .absent }
        defer { store.reset() }
        store.note(media: media)
        #expect(store.lookupTasks.isEmpty)
        #expect(calls == 0)
        clock = clock.addingTimeInterval(1)
        store.note(media: media)
        let renewed = try #require(store.lookupTasks[key])
        await renewed.value
        #expect(calls == 1)
        #expect(LyricsDiskCache(url: url).lookup(key, now: clock.addingTimeInterval(1)) != nil)
        #expect(LyricsDiskCache(url: url).lookup(key, now: clock.addingTimeInterval(LyricsDiskCache.missLife)) == nil)
    }

    @MainActor
    @Test("lyric hits remain cached past the miss lifetime")
    func memoryHitDoesNotExpire() async throws {
        var clock = Date(timeIntervalSince1970: 1_000)
        let store = LyricsStore(now: { clock })
        store.enabled = { true }
        var calls = 0
        store.lookupOverride = { _ in
            calls += 1
            return .found(SyncedLyrics.parse("[00:01.00] Fixture words"))
        }
        defer { store.reset() }
        let media = AlcoveMedia(title: "Fixture", artist: "Artist", playing: true)
        let key = try #require(LyricsQuery(media: media)).cacheKey
        store.note(media: media)
        let initial = try #require(store.lookupTasks[key])
        await initial.value
        clock = clock.addingTimeInterval(LyricsDiskCache.missLife * 2)
        store.reset()
        store.note(media: media)
        #expect(store.lookupTasks.isEmpty)
        #expect(store.lyrics?.line(at: 2) == "Fixture words")
        #expect(calls == 1)
    }

    @MainActor
    private final class HeldLookups {
        private(set) var count = 0
        private var replies: [Int: CheckedContinuation<LyricsLookup, Never>] = [:]
        private var closed = false

        func read() async -> LyricsLookup {
            guard !closed else { return .unavailable }
            count += 1
            let index = count
            return await withCheckedContinuation { replies[index] = $0 }
        }

        func answer(_ index: Int, _ words: String) {
            replies.removeValue(forKey: index)?.resume(returning: .found(SyncedLyrics.parse("[00:01.00] \(words)")))
        }

        func close() {
            closed = true
            let outstanding = Array(replies.values)
            replies.removeAll()
            for reply in outstanding { reply.resume(returning: .unavailable) }
        }

        func waitFor(_ target: Int) async -> Bool {
            let clock = ContinuousClock()
            let deadline = clock.now.advanced(by: .seconds(5))
            while count < target, clock.now < deadline { await Task.yield() }
            return count >= target
        }
    }

    @MainActor
    @Test("revocation retires a lookup and its late reply cannot affect a re-enabled same track")
    func revokeAndReenableSameTrack() async throws {
        let held = HeldLookups()
        let store = LyricsStore()
        var enabled = true
        store.enabled = { enabled }
        store.lookupOverride = { _ in await held.read() }
        defer { held.close(); store.reset() }
        let media = AlcoveMedia(title: "Synthetic \(UUID().uuidString)", artist: "Fixture", playing: true)
        let key = try #require(LyricsQuery(media: media)).cacheKey
        store.note(media: media)
        let old = try #require(store.lookupTasks[key])
        let firstStarted = await held.waitFor(1)
        try #require(firstStarted)
        enabled = false
        store.note(media: media)
        #expect(old.isCancelled)
        #expect(store.inFlight.isEmpty)
        enabled = true
        store.note(media: media)
        let current = try #require(store.lookupTasks[key])
        let nextStarted = await held.waitFor(2)
        try #require(nextStarted)
        held.answer(1, "Old words")
        await old.value
        #expect(store.inFlight.contains(key))
        #expect(store.lyrics == nil)
        held.answer(2, "Current words")
        await current.value
        #expect(store.lyrics?.line(at: 2) == "Current words")
        store.reset()
        store.note(media: media)
        #expect(store.lyrics?.line(at: 2) == "Current words")
        #expect(held.count == 2)
    }

    @MainActor
    @Test("reset cancels a queued lookup before it can disclose a track")
    func resetBeforeLookupStarts() async throws {
        let store = LyricsStore()
        store.enabled = { true }
        var calls = 0
        store.lookupOverride = { _ in calls += 1; return .unavailable }
        let media = AlcoveMedia(title: "Queued \(UUID().uuidString)", artist: "Fixture", playing: true)
        store.note(media: media)
        let key = try #require(LyricsQuery(media: media)).cacheKey
        let queued = try #require(store.lookupTasks[key])
        store.reset()
        await queued.value
        #expect(calls == 0)
        #expect(store.inFlight.isEmpty)
    }

    @MainActor
    @Test("cancelling an exact lookup never sends its search fallback")
    func cancelledExactDoesNotSearch() async throws {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [CancelledLyricsProtocol.self]
        let session = URLSession(configuration: config)
        defer { session.invalidateAndCancel() }
        let media = AlcoveMedia(title: "Cancelled \(UUID().uuidString)", artist: "Fixture", playing: true)
        let query = try #require(LyricsQuery(media: media))
        let task = Task { await LyricsStore.lookup(query, session: session) }
        defer { task.cancel() }
        let exactStarted = await CancelledLyricsProtocol.waitForExact(title: media.title)
        try #require(exactStarted, "the synthetic exact request did not start")
        #expect(CancelledLyricsProtocol.count(title: media.title, path: "/api/get") == 1)
        task.cancel()
        let outcome = await task.value
        #expect(outcome == .unavailable)
        #expect(CancelledLyricsProtocol.count(title: media.title, path: "/api/search") == 0)
    }

    @MainActor
    @Test("consent loss before reset prevents search after an exact miss")
    func withdrawnConsentDoesNotSearch() async throws {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [CancelledLyricsProtocol.self]
        let session = URLSession(configuration: config)
        defer { session.invalidateAndCancel() }
        let media = AlcoveMedia(title: "Withdrawn \(UUID().uuidString)", artist: "Fixture", playing: true)
        let query = try #require(LyricsQuery(media: media))
        var allowed = true
        let task = Task { await LyricsStore.lookup(query, session: session, allowed: { allowed }) }
        defer { task.cancel() }
        let exactStarted = await CancelledLyricsProtocol.waitForExact(title: media.title)
        try #require(exactStarted, "the synthetic exact request did not start")
        #expect(CancelledLyricsProtocol.count(title: media.title, path: "/api/get") == 1)
        allowed = false
        #expect(!task.isCancelled)
        CancelledLyricsProtocol.releaseExact(title: media.title)
        let outcome = await task.value
        #expect(outcome == .unavailable)
        #expect(CancelledLyricsProtocol.count(title: media.title, path: "/api/search") == 0)
    }

    @Test func aRecordWithoutDurationStillDecodes() throws {
        let json = #"{"syncedLyrics":"[00:01.00] hi","plainLyrics":null}"#
            .data(using: .utf8)!
        let record = try JSONDecoder().decode(LRCLIBRecord.self, from: json)
        #expect(record.duration == nil)
        #expect(record.durationSeconds == nil)
        #expect(record.synced?.line(at: 1.5) == "hi")
    }

    @Test func aStringDurationFieldYieldsNilNotThrow() throws {
        // One bad field must not sink the decode — `try?` coalesces.
        let json = #"{"syncedLyrics":"[00:01.00] hi","duration":"200"}"#
            .data(using: .utf8)!
        let record = try JSONDecoder().decode(LRCLIBRecord.self, from: json)
        #expect(record.duration == nil)
        #expect(record.synced != nil)
    }

    @Test func anAbsentSyncedLyricsYieldsNoSync() throws {
        let json = #"{"duration":200,"syncedLyrics":null}"#.data(using: .utf8)!
        let record = try JSONDecoder().decode(LRCLIBRecord.self, from: json)
        #expect(record.synced == nil)
    }

    @Test func absurdServerDurationClampsAndNeverTraps() throws {
        let huge = #"{"duration":1e30}"#.data(using: .utf8)!
        let record = try JSONDecoder().decode(LRCLIBRecord.self, from: huge)
        #expect(record.durationSeconds == 86_400)
    }
}

private final class CancelledLyricsProtocol: URLProtocol {
    nonisolated(unsafe) private static var requests: [String: [String: Int]] = [:]
    nonisolated(unsafe) private static var exactRequests: [String: CancelledLyricsProtocol] = [:]
    nonisolated(unsafe) private static var readyWaiters: [String: AsyncStream<Bool>.Continuation] = [:]
    private static let lock = NSLock()

    static func waitForExact(title: String) async -> Bool {
        let ready = AsyncStream<Bool>.makeStream()
        let alreadyStarted = lock.withLock {
            if (requests[title]?["/api/get"] ?? 0) > 0 { return true }
            readyWaiters[title] = ready.continuation
            return false
        }
        if alreadyStarted { return true }
        defer { lock.withLock { readyWaiters[title] = nil } }
        for await started in ready.stream { return started }
        return false
    }

    static func count(title: String, path: String) -> Int {
        lock.lock()
        defer { lock.unlock() }
        return requests[title]?[path] ?? 0
    }

    static func releaseExact(title: String) {
        lock.lock()
        let pending = exactRequests.removeValue(forKey: title)
        lock.unlock()
        pending?.answerNotFound()
    }

    private func answerNotFound() {
        guard let url = request.url,
              let response = HTTPURLResponse(url: url, statusCode: 404, httpVersion: nil, headerFields: nil) else { return }
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocolDidFinishLoading(self)
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let title = request.url.flatMap { URLComponents(url: $0, resolvingAgainstBaseURL: false) }?
            .queryItems?.first { $0.name == "track_name" }?.value ?? ""
        let path = request.url?.path ?? ""
        Self.lock.lock()
        Self.requests[title, default: [:]][path, default: 0] += 1
        if path == "/api/get" { Self.exactRequests[title] = self }
        let waiter = path == "/api/get" ? Self.readyWaiters.removeValue(forKey: title) : nil
        Self.lock.unlock()
        waiter?.yield(true)
        waiter?.finish()
        if path != "/api/get" { answerNotFound() }
        // Exact replies are held until cancellation or explicit release.
    }

    override func stopLoading() {
        let title = request.url.flatMap { URLComponents(url: $0, resolvingAgainstBaseURL: false) }?
            .queryItems?.first { $0.name == "track_name" }?.value ?? ""
        Self.lock.lock()
        if Self.exactRequests[title] === self { Self.exactRequests[title] = nil }
        Self.lock.unlock()
    }
}
