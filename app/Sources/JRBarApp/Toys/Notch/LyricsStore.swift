import Foundation
import JRBarCore

/// Synced lyrics from LRCLIB — the free, keyless service boring.notch,
/// Atoll and Notchy all draw on. The store watches the media feed: a
/// new track keys one lookup (cache first, network on a miss), and the
/// card reads `lyrics.line(at: playhead)` on its own timeline tick —
/// nothing here blocks the UI or the media push.
///
/// Honesty rules (T48):
/// * A track with no artist/title never reaches the network.
/// * A miss is cached too — a song with no lyrics doesn't re-fetch
///   every time it comes on.
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

    init(session: URLSession = .shared) {
        self.session = session
    }

    /// The media feed's push — nil media clears the line; a new track
    /// swaps lyrics (cached) or fetches (missed).
    func note(media: AlcoveMedia?) {
        guard let media,
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
        lyrics = nil
        fetch(query, key: key)
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
            if cache[key] == nil {
                cache[key] = .some(found)
                cacheOrder.append(key)
                if cacheOrder.count > Self.cacheCap {
                    for stale in cacheOrder.prefix(cacheOrder.count - Self.cacheCap) {
                        cache.removeValue(forKey: stale)
                    }
                    cacheOrder.removeFirst(cacheOrder.count - Self.cacheCap)
                }
            }
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
        let parsed = SyncedLyrics.parse(syncedLyrics)
        return parsed.lines.isEmpty ? nil : parsed
    }
}
