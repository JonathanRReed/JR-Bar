import Foundation
import JRBarCore

/// Synced lyrics from LRCLIB — the free, keyless service boring.notch,
/// Atoll and Notchy all draw on. The store watches the media feed: a
/// new track keys one lookup (cache first, network on a miss), and the
/// card reads `lyrics.line(at: playhead)` on its own timeline tick —
/// nothing here blocks the UI or the media push.
///
/// Honesty rules (T48):
/// * A track with no artist/title never reaches the network, and with
///   the Lyrics switch off no track does.
/// * A miss is cached too — a song with no lyrics doesn't re-fetch
///   every time it comes on — and both hits and misses persist across
///   launches (`LyricsDiskCache`), so the regular rotation asks once.
/// * Instrumental tracks (`instrumental: true`) land as a cached nil
///   the same way: silence, not a spinner.
/// * Only title/artist/album/duration leave the machine — the same
///   fields the player itself broadcasts.
@MainActor
@Observable
final class LyricsStore {
    /// The lyrics for the current track — nil while fetching, when
    /// the track has none, or when no track plays. The card hides
    /// its lyric line on nil; it never shows a stale track's words.
    private(set) var lyrics: SyncedLyrics?

    /// Track key → parsed lyrics (or nil for "known unavailable").
    /// Unbounded by design would leak across a long session — the
    /// cap drops the oldest half when hit.
    private var cache: [String: SyncedLyrics?] = [:]
    private var cacheOrder: [String] = []
    private static let cacheCap = 64

    /// The key this `lyrics` value answers — a stale fetch landing
    /// after the track changed publishes nothing.
    private var currentKey: String?
    /// In-flight keys — a second observer of the same track doesn't
    /// double the request.
    private var inFlight: Set<String> = []

    private let session: URLSession
    /// Lookups that outlive the launch — hits and misses both, so the
    /// regular rotation never re-asks LRCLIB. nil keeps memory only.
    private let disk: LyricsDiskCache?

    /// The Lyrics switch (`NotchSettings.lyrics`). Off, nothing about
    /// the track leaves the machine and the line stays down.
    var enabled: () -> Bool = { true }

    init(session: URLSession = .shared, diskURL: URL? = nil) {
        self.session = session
        disk = diskURL.map(LyricsDiskCache.init(url:))
    }

    /// The media feed's push — nil media clears the line; a new track
    /// swaps lyrics (cached — memory, then disk) or fetches (missed).
    func note(media: AlcoveMedia?) {
        guard enabled(), let media,
              let query = LyricsQuery(media: media) else {
            lyrics = nil
            currentKey = nil
            return
        }
        let key = query.cacheKey
        guard key != currentKey else { return }
        currentKey = key
        if let hit = cache[key] {
            lyrics = hit
            return
        }
        if let stored = disk?.lookup(key) {
            remember(stored, for: key)
            lyrics = stored
            return
        }
        lyrics = nil
        fetch(query, key: key)
    }

    private func remember(_ found: SyncedLyrics?, for key: String) {
        guard cache[key] == nil else { return }
        cache[key] = .some(found)
        cacheOrder.append(key)
        if cacheOrder.count > Self.cacheCap {
            for stale in cacheOrder.prefix(cacheOrder.count - Self.cacheCap) {
                cache.removeValue(forKey: stale)
            }
            cacheOrder.removeFirst(cacheOrder.count - Self.cacheCap)
        }
    }

    /// The shelf stops — the line goes down with the row.
    func reset() {
        lyrics = nil
        currentKey = nil
    }

    /// One ask per key, guarded against stale landing: whatever comes
    /// back caches under its key but publishes only if that key is
    /// still the playing track.
    private func fetch(_ query: LyricsQuery, key: String) {
        guard inFlight.insert(key).inserted else { return }
        Task {
            let found = await Self.lookup(query, session: session)
            inFlight.remove(key)
            remember(found, for: key)
            disk?.store(found, for: key)
            if currentKey == key { lyrics = found }
        }
    }

    /// The network half: `/api/get` with the best fields first — it's
    /// the exact-match endpoint; a miss falls to `/api/search` whose
    /// nearest-duration candidate still must carry synced lyrics.
    /// Returns nil for any failure — no lyrics is a quiet answer.
    static func lookup(_ query: LyricsQuery,
                       session: URLSession) async -> SyncedLyrics? {
        if let hit = await get(query, session: session) { return hit }
        return await search(query, session: session)
    }

    private static func get(_ query: LyricsQuery,
                            session: URLSession) async -> SyncedLyrics? {
        var items = [
            URLQueryItem(name: "track_name", value: query.title),
            URLQueryItem(name: "artist_name", value: query.artist),
        ]
        if let album = query.album, !album.isEmpty {
            items.append(URLQueryItem(name: "album_name", value: album))
        }
        if let duration = query.duration {
            items.append(URLQueryItem(name: "duration", value: String(duration)))
        }
        guard let url = url(path: "/api/get", items: items),
              let data = await data(for: url, session: session),
              !data.isEmpty,
              let record = try? JSONDecoder().decode(LRCLIBRecord.self, from: data)
        else { return nil }
        return record.synced
    }

    private static func search(_ query: LyricsQuery,
                               session: URLSession) async -> SyncedLyrics? {
        let items = [
            URLQueryItem(name: "track_name", value: query.title),
            URLQueryItem(name: "artist_name", value: query.artist),
        ]
        guard let url = url(path: "/api/search", items: items),
              let data = await data(for: url, session: session),
              let records = try? JSONDecoder().decode([LRCLIBRecord].self, from: data)
        else { return nil }
        // The best synced candidate: nearest duration to what plays,
        // within a sloppy-mastering window; un-durated queries take
        // the first synced hit.
        let synced = records.filter { $0.synced != nil }
        guard !synced.isEmpty else { return nil }
        guard let target = query.duration else { return synced[0].synced }
        return synced
            .filter { $0.durationSeconds.map { abs($0 - target) <= 6 } ?? false }
            .min { abs(($0.durationSeconds ?? 0) - target)
                 < abs(($1.durationSeconds ?? 0) - target) }?
            .synced
    }

    private static func url(path: String, items: [URLQueryItem]) -> URL? {
        var components = URLComponents()
        components.scheme = "https"
        components.host = "lrclib.net"
        components.path = path
        components.queryItems = items
        return components.url
    }

    private static func data(for url: URL,
                             session: URLSession) async -> Data? {
        var request = URLRequest(url: url)
        request.timeoutInterval = 10
        request.setValue("JR-Bar/0.9.9 (https://github.com/jonathanreed/jr-bar)",
                         forHTTPHeaderField: "User-Agent")
        guard let (data, response) = try? await session.data(for: request),
              let http = response as? HTTPURLResponse,
              (200..<300).contains(http.statusCode)
        else { return nil }
        return data
    }
}

/// The lyrics lookups kept across launches, one small JSON file under
/// Application Support/JR-Bar. A hit is kept for good; a miss for a
/// week (lyrics do get added), and the file holds at most `cap` tracks,
/// oldest out first. Loaded on first use, so a surface that never plays
/// a track never reads it.
@MainActor
final class LyricsDiskCache {
    struct Stored: Codable {
        struct Line: Codable {
            var t: Double
            var s: String
        }
        /// nil: LRCLIB had nothing synced for this track.
        var lines: [Line]?
        var at: Date
    }

    static let cap = 400
    static let missLife: TimeInterval = 7 * 24 * 3600

    static func defaultURL() -> URL {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return support.appendingPathComponent("JR-Bar", isDirectory: true)
            .appendingPathComponent("lyrics-cache.json")
    }

    let url: URL
    private var entries: [String: Stored]?

    init(url: URL) {
        self.url = url
    }

    /// `.some(nil)` is a remembered miss; nil is "never looked up".
    func lookup(_ key: String, now: Date = Date()) -> SyncedLyrics?? {
        guard let stored = load()[key] else { return nil }
        guard let lines = stored.lines else {
            return now.timeIntervalSince(stored.at) < Self.missLife ? .some(nil) : nil
        }
        return .some(SyncedLyrics(lines: lines.map { SyncedLyrics.Line(time: $0.t, text: $0.s) }))
    }

    func store(_ lyrics: SyncedLyrics?, for key: String, now: Date = Date()) {
        var all = load()
        all[key] = Stored(lines: lyrics?.lines.map { Stored.Line(t: $0.time, s: $0.text) }, at: now)
        if all.count > Self.cap {
            let oldest = all.sorted { $0.value.at < $1.value.at }.prefix(all.count - Self.cap)
            for (stale, _) in oldest { all.removeValue(forKey: stale) }
        }
        entries = all
        guard let data = try? JSONEncoder().encode(all) else { return }
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                 withIntermediateDirectories: true)
        try? data.write(to: url, options: .atomic)
    }

    private func load() -> [String: Stored] {
        if let entries { return entries }
        let read = (try? Data(contentsOf: url))
            .flatMap { try? JSONDecoder().decode([String: Stored].self, from: $0) } ?? [:]
        entries = read
        return read
    }
}

/// One LRCLIB record — both lyric fields can be null (instrumentals),
/// and plain text alone doesn't count: the row syncs or stays silent.
/// `duration` decodes leniently: a record that omits it (or serves a
/// string) yields nil rather than sinking the whole `/api/search`
/// array with one `keyNotFound`.
struct LRCLIBRecord: Decodable {
    let duration: Double?
    let syncedLyrics: String?

    private enum CodingKeys: String, CodingKey {
        case duration, syncedLyrics
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        duration = try? c.decodeIfPresent(Double.self, forKey: .duration)
        syncedLyrics = try c.decodeIfPresent(String.self, forKey: .syncedLyrics)
    }

    /// Whole seconds for the nearest-match window — a non-finite or
    /// absurd server value is "un-durated", never a trap in `Int()`.
    var durationSeconds: Int? {
        guard let duration, duration.isFinite else { return nil }
        return Int(min(max(duration.rounded(), 0), 86_400))
    }

    var synced: SyncedLyrics? {
        guard let syncedLyrics else { return nil }
        let parsed = SyncedLyrics.parse(syncedLyrics).applyingOffset(in: syncedLyrics)
        return parsed.lines.isEmpty ? nil : parsed
    }
}

extension SyncedLyrics {
    /// The LRC `[offset:±ms]` tag, applied: a positive offset makes the
    /// words arrive sooner (every stamp moves earlier by that many
    /// milliseconds), a negative one later. The parser drops the tag
    /// with the other metadata; without it a file mastered with an
    /// offset runs a beat off the music for its whole length.
    func applyingOffset(in lrc: String) -> SyncedLyrics {
        guard let offset = Self.offsetMilliseconds(in: lrc), offset != 0 else { return self }
        let shift = Double(offset) / 1000
        return SyncedLyrics(lines: lines.map { Line(time: max(0, $0.time - shift), text: $0.text) })
    }

    /// `[offset:+250]` → 250; nil when the file carries none.
    static func offsetMilliseconds(in lrc: String) -> Int? {
        for raw in lrc.components(separatedBy: .newlines) {
            let line = raw.trimmingCharacters(in: .whitespaces).lowercased()
            guard line.hasPrefix("[offset:"), line.hasSuffix("]") else { continue }
            let value = line.dropFirst("[offset:".count).dropLast()
                .trimmingCharacters(in: .whitespaces)
            return Int(value.hasPrefix("+") ? String(value.dropFirst()) : value)
        }
        return nil
    }

    /// The lyric after the one at `seconds` — the row's faint second
    /// line — and how far through the current line the playhead is
    /// (0…1), for the sweep. nil progress before the first stamp.
    func position(at seconds: Double) -> (next: String?, progress: Double?) {
        var lo = 0, hi = lines.count
        while lo < hi {
            let mid = (lo + hi) / 2
            if lines[mid].time <= seconds { lo = mid + 1 } else { hi = mid }
        }
        // `lo` is the first line still to come.
        let next = lines[lo...].first { !$0.text.isEmpty }?.text
        guard lo > 0 else { return (next, nil) }
        let start = lines[lo - 1].time
        let end = lo < lines.count ? lines[lo].time : start + 4
        let span = max(0.1, end - start)
        return (next, min(1, max(0, (seconds - start) / span)))
    }
}
