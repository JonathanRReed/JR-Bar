import Foundation

/// A parsed LRC document: timestamped lines in play order. The pure
/// half of synced lyrics — no network, no clock, fully testable.
/// LRCLIB serves this format (`[mm:ss.xx]`); the parser also eats the
/// metadata tags real files carry (`[ti:]`, `[ar:]`, `[offset:]`,
/// `[la:]`) and per-word enhancement tags (`<mm:ss.xx>`), keeping only
/// timed lyric lines.
public struct SyncedLyrics: Equatable, Sendable {
    public struct Line: Equatable, Sendable {
        /// Seconds into the track.
        public let time: Double
        public let text: String
        public init(time: Double, text: String) {
            self.time = time
            self.text = text
        }
    }

    public let lines: [Line]

    public init(lines: [Line]) {
        self.lines = lines
    }

    /// Parse an LRC payload. Every `[mm:ss.xx]` (or `mm:ss.xxx` /
    /// `mm:ss`) tag on a line starts a lyric entry — a line with two
    /// tags (rare, but legal) yields two entries at the shared text.
    /// Untagged text and metadata tags (`[word:…]`) are skipped;
    /// blank lyric lines (a breath between verses) are kept, they
    /// mark a gap the selector should show as nothing.
    public static func parse(_ lrc: String) -> SyncedLyrics {
        var parsed: [Line] = []
        for raw in lrc.components(separatedBy: .newlines) {
            var rest = raw[...]
            var times: [Double] = []
            while rest.hasPrefix("["),
                  let close = rest.firstIndex(of: "]") {
                let tag = rest[rest.index(after: rest.startIndex)..<close]
                if let t = Self.stamp(String(tag)) {
                    times.append(t)
                }
                rest = rest[rest.index(after: close)...]
            }
            guard !times.isEmpty else { continue }
            // Per-word `<mm:ss.xx>` tags are karaoke furniture — the
            // line reads without them.
            let text = rest
                .replacingOccurrences(
                    of: "<\\d{1,2}:\\d{2}(\\.\\d{1,3})?>",
                    with: "",
                    options: .regularExpression)
                .trimmingCharacters(in: .whitespaces)
            for t in times { parsed.append(Line(time: t, text: text)) }
        }
        return SyncedLyrics(lines: parsed.sorted { $0.time < $1.time })
    }

    /// `mm:ss`, `mm:ss.x`, `mm:ss.xx`, `mm:ss.xxx` → seconds. nil for
    /// anything that isn't a timestamp (metadata tags included).
    static func stamp(_ tag: String) -> Double? {
        let parts = tag.split(separator: ":")
        guard parts.count == 2,
              let minutes = Double(parts[0]),
              let seconds = Double(parts[1]),
              minutes >= 0, seconds >= 0, seconds < 60 else { return nil }
        return minutes * 60 + seconds
    }

    /// The lyric at `seconds`: the last line stamped at or before it.
    /// Before the first stamp (the count-in) the answer is nil — the
    /// row shows nothing rather than flash the first line early.
    /// Binary search; the timeline asks every half second.
    public func line(at seconds: Double) -> String? {
        var lo = 0, hi = lines.count
        while lo < hi {
            let mid = (lo + hi) / 2
            if lines[mid].time <= seconds { lo = mid + 1 } else { hi = mid }
        }
        guard lo > 0 else { return nil }
        let text = lines[lo - 1].text
        return text.isEmpty ? nil : text
    }
}

/// Who the lyrics belong to — the fetch key and the cache key.
/// Built only when a source names a title AND an artist; a bare
/// "Unknown Artist" stream never reaches the network (T48's rule —
/// don't leak what wasn't reported, don't fetch what can't match).
public struct LyricsQuery: Hashable, Sendable {
    public let title: String
    public let artist: String
    public let album: String?
    /// Whole seconds — LRCLIB's strongest match signal after names.
    public let duration: Int?

    public init(title: String, artist: String,
                album: String? = nil, duration: Int? = nil) {
        self.title = title
        self.artist = artist
        self.album = album
        self.duration = duration
    }

    /// From now-playing media — nil when the source didn't name a
    /// title or artist well enough to query honestly.
    public init?(media: AlcoveMedia) {
        let title = media.title.trimmingCharacters(in: .whitespacesAndNewlines)
        let artist = (media.artist ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty, !artist.isEmpty else { return nil }
        self.init(title: title, artist: artist,
                  album: media.album?.trimmingCharacters(in: .whitespacesAndNewlines),
                  // A misbehaving source can report NaN or ∞ — a
                  // non-finite or absurd duration means "don't ask",
                  // not a trap in the query key.
                  duration: media.duration.flatMap {
                      $0.isFinite ? Int(min(max($0.rounded(), 0), 86_400)) : nil
                  })
    }

    /// The cache key: normalized so "Song (Remastered)" vs "song
    /// (remastered)" share a slot.
    public var cacheKey: String {
        [title, artist, album ?? "", duration.map(String.init) ?? ""]
            .joined(separator: "|")
            .lowercased()
    }
}
